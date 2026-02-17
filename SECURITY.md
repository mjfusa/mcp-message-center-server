# Security Best Practices

## Authentication Architecture

This MCP server implements OAuth 2.0 On-Behalf-Of (OBO) flow for delegated access to Microsoft Graph. The architecture follows Microsoft's recommended practices for multi-tenant applications.

### Authentication Flow

1. **Client Authentication**: Clients (e.g., Teams declarative agents, VS Code) authenticate users and obtain an access token for this MCP API
2. **Token Validation**: Server validates the incoming token (signature, issuer, audience, expiry, scopes)
3. **On-Behalf-Of (OBO)**: Server exchanges the validated user token for a Microsoft Graph token using OBO flow
4. **Graph API Call**: Server calls Microsoft Graph on behalf of the authenticated user

### Security Principles

#### Defense in Depth

Multiple layers of security:
- Token signature verification using Microsoft Entra JWKS
- Audience validation (must be this MCP API)
- Issuer validation (must be configured tenant)
- Scope validation (must include required delegated scopes)
- Token expiry validation
- Proper error handling without information leakage

#### Least Privilege

- Server only requests necessary Microsoft Graph permissions
- Default scope: `ServiceMessage.Read.All` (delegated)
- Admin consent required for production use
- Users can only access resources they have permissions for

#### Separation of Concerns

- **Server/API App Registration**: Represents this MCP API, performs OBO
- **Client App Registration**: Represents the client application, requests user consent
- Clear boundary: clients get tokens for the API, not for Graph directly

## Production Security Configuration

### Required Settings

```bash
# Production mode - enforces secure defaults
NODE_ENV=production

# Authentication MUST be required
MCP_REQUIRE_AUTH=true

# Configure tenant and client
GRAPH_TENANT_ID=<your-tenant-id>
GRAPH_CLIENT_ID=<your-app-id>
```

### Credential Management

**Preferred: Certificate-based authentication**

```bash
# Store certificate private key in Azure Key Vault
GRAPH_CLIENT_CERT_KEYVAULT_URL=https://<vault-name>.vault.azure.net/
GRAPH_CLIENT_CERT_SECRET_NAME=graph-client-cert
GRAPH_CLIENT_CERT_THUMBPRINT=<cert-thumbprint-hex>

# Use managed identity to access Key Vault (no credentials needed)
```

**Alternative: Client secret (less secure)**

```bash
# Only if certificate auth is not available
# NEVER commit secrets to source control
GRAPH_CLIENT_SECRET=<secret-from-key-vault>
```

### Disabled Features

These testing bypasses MUST be disabled in production:

```bash
# NEVER enable these in production
# ALLOW_GRAPH_BEARER_TOKEN=false  # Default: false
# ALLOW_MCP_ACCESS_TOKEN_ARG=false  # Default: false in production
```

## Development vs Production

### Development Environment

Local development can use relaxed settings for convenience:

```bash
# .env.local (NEVER commit)
MCP_REQUIRE_AUTH=false  # Allow unauthenticated requests
GRAPH_CLIENT_SECRET=<dev-secret>  # Client secret for local testing
```

### Production Environment

Production MUST use secure configuration:

- `NODE_ENV=production` enforces secure defaults
- `MCP_REQUIRE_AUTH=true` required
- Certificate-based auth with Key Vault
- Managed identity for Key Vault access
- All testing bypasses disabled
- HTTPS-only access
- Security headers enabled

## Common Security Pitfalls

### ❌ Confused Deputy Attack

**Problem**: Allowing clients to send Graph tokens directly

```typescript
// DANGEROUS - DO NOT USE IN PRODUCTION
ALLOW_GRAPH_BEARER_TOKEN=true
```

**Why it's dangerous**: 
- Bypasses audience validation
- Makes auditing impossible (who called the API?)
- Violates the delegation model

**Solution**: Always use OBO flow with proper audience validation

### ❌ Token Argument Bypass

**Problem**: Accepting Graph tokens as tool arguments

```typescript
// DANGEROUS - DO NOT USE IN PRODUCTION
tools/call { name: "getMessages", arguments: { accessToken: "<graph-token>" } }
```

**Why it's dangerous**:
- Circumvents authentication middleware
- No token validation
- Opens door to token theft/replay attacks

**Solution**: Require Authorization header, use OBO flow

### ❌ Open Redirect

**Problem**: Accepting arbitrary redirect URIs

```typescript
// DANGEROUS - Insufficient validation
if (redirectUri.startsWith('http://')) { /* allow */ }
```

**Why it's dangerous**:
- OAuth authorization code theft
- Phishing attacks

**Solution**: Strict allowlist with exact hostname matching

### ❌ Missing Token Validation

**Problem**: Decoding JWTs without signature verification

```typescript
// DANGEROUS - Only decodes, doesn't verify
const payload = decodeJwtPayload(token);
if (isGraphAudience(payload.aud)) { /* use token */ }
```

**Why it's dangerous**:
- Attacker can forge tokens
- No authenticity guarantee

**Solution**: Always use `jwtVerify()` with JWKS before trusting claims

## Audit Logging

Authentication events are logged with:
- Timestamp
- Principal ID (user)
- Action (token validation, OBO, Graph call)
- Result (success/failure)
- Client IP (when available)
- Error details (on failure)

## Rate Limiting

The server implements rate limiting to prevent abuse:
- Per-IP limits on auth endpoints
- Per-user limits on MCP endpoint
- Exponential backoff on repeated failures

## Incident Response

If you suspect a security issue:

1. **Do not disclose publicly** - use responsible disclosure
2. **Rotate credentials immediately** - client secrets, certificates
3. **Review audit logs** - identify affected users
4. **Revoke compromised tokens** - in Azure portal
5. **Update redirect URI allowlist** - remove suspicious entries

## Security Updates

- Keep dependencies updated (`npm audit`, `npm update`)
- Monitor Microsoft Graph API deprecations
- Subscribe to Azure security advisories
- Review access logs regularly

## References

- [Microsoft Identity Platform Best Practices](https://learn.microsoft.com/en-us/azure/active-directory/develop/identity-platform-integration-checklist)
- [OAuth 2.0 Threat Model](https://datatracker.ietf.org/doc/html/rfc6819)
- [Microsoft Graph Security Best Practices](https://learn.microsoft.com/en-us/graph/security-authorization)
