import { Request, Response, NextFunction } from 'express';

/**
 * Security headers middleware
 * Adds recommended security headers to all responses
 */
export function securityHeaders(req: Request, res: Response, next: NextFunction) {
  // Prevent MIME type sniffing
  res.setHeader('X-Content-Type-Options', 'nosniff');
  
  // Prevent clickjacking
  res.setHeader('X-Frame-Options', 'DENY');
  
  // Enable XSS protection (legacy browsers)
  res.setHeader('X-XSS-Protection', '1; mode=block');
  
  // Strict Transport Security (HTTPS only)
  // Only set if the request came over HTTPS
  if (req.secure || req.headers['x-forwarded-proto'] === 'https') {
    res.setHeader('Strict-Transport-Security', 'max-age=31536000; includeSubDomains');
  }
  
  // Content Security Policy - restrictive for API server
  res.setHeader('Content-Security-Policy', "default-src 'none'; frame-ancestors 'none'");
  
  // Referrer policy
  res.setHeader('Referrer-Policy', 'no-referrer');
  
  // Permissions policy - disable all browser features
  res.setHeader('Permissions-Policy', 'geolocation=(), microphone=(), camera=()');
  
  next();
}

/**
 * Rate limiting storage
 */
interface RateLimitEntry {
  count: number;
  resetTime: number;
}

const rateLimitStore = new Map<string, RateLimitEntry>();

/**
 * Simple rate limiter middleware
 * @param maxRequests Maximum requests allowed in the window
 * @param windowMs Time window in milliseconds
 */
export function rateLimit(maxRequests: number, windowMs: number) {
  // Clean up old entries periodically
  setInterval(() => {
    const now = Date.now();
    for (const [key, entry] of rateLimitStore.entries()) {
      if (now > entry.resetTime) {
        rateLimitStore.delete(key);
      }
    }
  }, windowMs);

  return (req: Request, res: Response, next: NextFunction) => {
    // Use IP address as key, with fallback to 'unknown'
    const clientIp = 
      req.ip || 
      req.socket.remoteAddress || 
      req.headers['x-forwarded-for'] || 
      'unknown';
    
    const key = `${clientIp}:${req.path}`;
    const now = Date.now();
    
    let entry = rateLimitStore.get(key);
    
    if (!entry || now > entry.resetTime) {
      entry = {
        count: 0,
        resetTime: now + windowMs
      };
      rateLimitStore.set(key, entry);
    }
    
    entry.count++;
    
    // Set rate limit headers
    res.setHeader('X-RateLimit-Limit', maxRequests.toString());
    res.setHeader('X-RateLimit-Remaining', Math.max(0, maxRequests - entry.count).toString());
    res.setHeader('X-RateLimit-Reset', entry.resetTime.toString());
    
    if (entry.count > maxRequests) {
      res.setHeader('Retry-After', Math.ceil((entry.resetTime - now) / 1000).toString());
      res.status(429).json({
        error: 'too_many_requests',
        message: 'Rate limit exceeded. Please try again later.',
        retryAfter: Math.ceil((entry.resetTime - now) / 1000)
      });
      return;
    }
    
    next();
  };
}

/**
 * Audit logger for security events
 */
export interface AuditEvent {
  timestamp: string;
  eventType: 'auth_success' | 'auth_failure' | 'obo_success' | 'obo_failure' | 'graph_call' | 'rate_limit';
  principal?: string;
  clientIp?: string;
  userAgent?: string;
  path: string;
  method: string;
  statusCode?: number;
  error?: string;
  details?: Record<string, unknown>;
}

/**
 * Log an audit event
 * In production, this should write to a secure audit log service
 */
export function logAuditEvent(event: AuditEvent): void {
  // For now, log to console in structured format
  // In production, send to Azure Application Insights, Azure Monitor, or similar
  console.log('[AUDIT]', JSON.stringify(event));
}

/**
 * Create audit event from request
 */
export function createAuditEvent(
  req: Request,
  eventType: AuditEvent['eventType'],
  additional?: Partial<AuditEvent>
): AuditEvent {
  const clientIp = 
    req.ip || 
    req.socket.remoteAddress || 
    (Array.isArray(req.headers['x-forwarded-for']) 
      ? req.headers['x-forwarded-for'][0]
      : req.headers['x-forwarded-for']) ||
    'unknown';

  const clientIpStr = typeof clientIp === 'string' ? clientIp : String(clientIp);

  return {
    timestamp: new Date().toISOString(),
    eventType,
    clientIp: clientIpStr,
    userAgent: req.headers['user-agent'],
    path: req.path,
    method: req.method,
    ...additional
  };
}

/**
 * Validate environment configuration on startup
 */
export interface ConfigValidation {
  valid: boolean;
  errors: string[];
  warnings: string[];
}

export function validateConfiguration(): ConfigValidation {
  const errors: string[] = [];
  const warnings: string[] = [];
  
  const isProduction = (process.env.NODE_ENV ?? '').toLowerCase() === 'production';
  
  // Critical checks
  if (!process.env.GRAPH_CLIENT_ID) {
    errors.push('GRAPH_CLIENT_ID is required');
  }
  
  if (!process.env.GRAPH_TENANT_ID) {
    warnings.push('GRAPH_TENANT_ID is not set, falling back to other tenant ID env vars');
  }
  
  // Production-specific checks
  if (isProduction) {
    if ((process.env.MCP_REQUIRE_AUTH ?? '').toLowerCase() !== 'true') {
      errors.push('MCP_REQUIRE_AUTH must be true in production');
    }
    
    if ((process.env.ALLOW_GRAPH_BEARER_TOKEN ?? '').toLowerCase() === 'true') {
      errors.push('ALLOW_GRAPH_BEARER_TOKEN must not be enabled in production (confused deputy risk)');
    }
    
    if ((process.env.ALLOW_MCP_ACCESS_TOKEN_ARG ?? '').toLowerCase() === 'true') {
      warnings.push('ALLOW_MCP_ACCESS_TOKEN_ARG is enabled in production - this bypasses proper authentication');
    }
    
    if (!process.env.GRAPH_CLIENT_SECRET && !process.env.GRAPH_CLIENT_CERT_KEYVAULT_URL) {
      errors.push('Production requires either GRAPH_CLIENT_SECRET or certificate configuration (GRAPH_CLIENT_CERT_KEYVAULT_URL)');
    }
    
    if (process.env.GRAPH_CLIENT_SECRET) {
      warnings.push('Using client secret authentication - certificate authentication is more secure');
    }
    
    if (!process.env.PUBLIC_BASE_URL) {
      warnings.push('PUBLIC_BASE_URL is not set - will be derived from request headers');
    }
  }
  
  // Certificate configuration validation
  const hasCertVaultUrl = !!process.env.GRAPH_CLIENT_CERT_KEYVAULT_URL;
  const hasCertSecretName = !!process.env.GRAPH_CLIENT_CERT_SECRET_NAME;
  const hasCertThumbprint = !!process.env.GRAPH_CLIENT_CERT_THUMBPRINT;
  
  if (hasCertVaultUrl || hasCertSecretName || hasCertThumbprint) {
    if (!hasCertVaultUrl) {
      errors.push('GRAPH_CLIENT_CERT_KEYVAULT_URL is required when using certificate auth');
    }
    if (!hasCertSecretName) {
      errors.push('GRAPH_CLIENT_CERT_SECRET_NAME is required when using certificate auth');
    }
    if (!hasCertThumbprint) {
      errors.push('GRAPH_CLIENT_CERT_THUMBPRINT is required when using certificate auth');
    }
  }
  
  // Redirect URI validation
  const redirectUris = process.env.MCP_OAUTH_REDIRECT_URI_PREFIXES;
  if (redirectUris) {
    const uris = redirectUris.split(',');
    for (const uri of uris) {
      try {
        new URL(uri.trim());
      } catch {
        warnings.push(`Invalid redirect URI in allowlist: ${uri}`);
      }
    }
  }
  
  return {
    valid: errors.length === 0,
    errors,
    warnings
  };
}

/**
 * Print configuration validation results
 */
export function printConfigValidation(validation: ConfigValidation): void {
  if (validation.errors.length > 0) {
    console.error('\n❌ Configuration Errors:');
    validation.errors.forEach(error => console.error(`  - ${error}`));
  }
  
  if (validation.warnings.length > 0) {
    console.warn('\n⚠️  Configuration Warnings:');
    validation.warnings.forEach(warning => console.warn(`  - ${warning}`));
  }
  
  if (validation.valid && validation.warnings.length === 0) {
    console.log('✅ Configuration validation passed');
  }
  
  if (!validation.valid) {
    console.error('\n❌ Server configuration is invalid. Please fix the errors above.');
    process.exit(1);
  }
}
