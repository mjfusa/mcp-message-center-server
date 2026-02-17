# Security Scan Notes

## CodeQL Analysis Results

### False Positives

#### Missing Rate Limiting Alerts (js/missing-rate-limiting)

**Alert 1**: `/authorize` endpoint (lines 674-716)
**Alert 2**: `/mcp` endpoint (lines 819-886)

**Status**: False Positive

**Explanation**: Both endpoints ARE rate-limited using our custom `rateLimit()` middleware:
- `/authorize`: Limited to 10 requests per minute (line 673)
- `/mcp`: Limited to 100 requests per minute (line 818)
- `/token`: Limited to 20 requests per minute (line 721)

CodeQL does not recognize our custom rate-limiting middleware because it's not a standard Express middleware like `express-rate-limit`. However, our implementation:

1. Uses a Map-based in-memory store to track request counts per IP
2. Returns HTTP 429 (Too Many Requests) when limits are exceeded
3. Sets appropriate rate limit headers (X-RateLimit-Limit, X-RateLimit-Remaining, X-RateLimit-Reset)
4. Properly cleans up expired entries

**Verification**: Manual testing confirms rate limiting works correctly:
```bash
# Test shows HTTP 429 after 10 requests to /authorize
Request 11: HTTP 429
✓ Rate limiting working
```

### Security Measures Implemented

1. **Token Validation**: Full JWT signature verification using Microsoft Entra JWKS
2. **Rate Limiting**: All authentication and API endpoints protected
3. **Security Headers**: HSTS, CSP, X-Frame-Options, X-Content-Type-Options, etc.
4. **Audit Logging**: Structured logging of all authentication events
5. **Configuration Validation**: Prevents insecure production deployments
6. **Defense in Depth**: Multiple layers of validation and protection

### Recommended Actions

No action required. The CodeQL alerts are false positives. The application has comprehensive rate limiting, authentication, and security controls in place.
