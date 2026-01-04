# Microsoft Message Center MCP Server (Microsoft Graph)

This MCP (Model Context Protocol) server exposes a tool (**getMessages**) for querying Microsoft Admin Center Message Center messages via the [/admin/serviceAnnouncement/messages](https://learn.microsoft.com/en-us/graph/api/serviceannouncement-list-messages?view=graph-rest-1.0&tabs=http) API.

This project generates the MCP input schema for the `getMessages` MCP tool from the OpenAPI description in the spec for the graph API in the spec `openapi.json`.

## Endpoints
- Health check:
  - `GET /healthz`
  - Returns `200 OK` if the server is running.

- Discovery:
  - `GET /.well-known/openid-configuration` or `GET /discover`
  - Returns MCP service discovery information.

- MCP endpoint:
  - `POST /mcp`
  - Accepts MCP tool requests for Message Center message query operations.
  - Requires authentication/authorization (see below).
  - Supports both JSON and SSE response formats based on `Accept` header.

## MCP protocol methods (JSON-RPC)

This server supports the standard MCP JSON-RPC methods over `POST /mcp` (handled by the MCP SDK + Streamable HTTP transport. Both implemented here: https://github.com/modelcontextprotocol/typescript-sdk).

- `initialize`
  - MCP handshake method (clients typically call this automatically).
  - Returns `serverInfo` and `capabilities`.

- `tools/list`
  - Lists the available tools and their input schemas.

- `tools/call`
  - Calls a tool by name with an `arguments` object. Calls the `getMessages` tool in this server.

Examples (JSON-RPC 2.0):

- List tools:
```json
{ "jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {} }
```

- Call `getMessages`:
```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "tools/call",
  "params": {
    "name": "getMessages",
    "arguments": { "top": 5, "count": true }
  }
}
```

## MCP Tool
- `getMessages`
  - Fetch Message Center messages with OData query support.
  - See [Microsoft Graph docs](https://learn.microsoft.com/en-us/graph/api/serviceannouncement-list-messages?view=graph-rest-1.0&tabs=http) for details on supported query parameters.
  - Supports OData parameters: `filter`, `orderby`, `top`, `skip`, `count`.
  - `top=0` is allowed for count-only queries (returns empty `value` with `@odata.count`).
  - Requires Microsoft Graph **Message Center Reader** role.
  - Authentication: The server will attempt to acquire a token using OBO (On-Behalf-Of) flow based on the caller's token.
  - If the caller's token is already a Microsoft Graph token, it will be used as-is.
  - If no valid token can be acquired, the server returns `401 InvalidAuthenticationToken`.
  - If the caller's token lacks the required role, Microsoft Graph returns `403 Forbidden`.
  - The server propagates this `403` back to the caller.
  - accessToken (optional): MCP-only argument to provide a Microsoft Graph access token directly.
    - If provided, this token is used as-is for Microsoft Graph calls.
    - Useful for testing or scenarios where the caller manages tokens directly.
    - Production safety: this bypass is disabled when `NODE_ENV=production` unless `ALLOW_MCP_ACCESS_TOKEN_ARG=true`.

## Quick start

Local (no Azure):

- `cd mcp-message-center-server`
- Create your local env file:
  - Copy `mcp-message-center-server/.env.local.sample` to `mcp-message-center-server/.env.local`
  - Fill in required values (see **Environment variables (reference)** below)
- Note: the server will auto-load `.env.local` on startup, but it does not override environment variables that are already set in the process environment. If you change `.env.local`, restart the server to pick up changes.
- `npm install`
- `npm run dev`
- Verify health: `http://localhost:8080/healthz`

Then call the tool (recommended path):

- Prereq: configure the MCP API client ID (same app registration the server uses).
  - Create/configure the Microsoft Entra app registration first (see **App registration requirements (Microsoft Entra ID)** below).
  - Preferred: set `GRAPH_CLIENT_ID` (and usually `GRAPH_TENANT_ID`) in `mcp-message-center-server/.env.local`.
  - Alternative: pass `-ApiClientId <clientId>` to `scripts/GetMcpAccessToken.ps1`.
- Get an MCP API token (first time may require consent):
  - If you set `GRAPH_CLIENT_ID` in `.env.local`:
    - `pwsh -File mcp-message-center-server/scripts/GetMcpAccessToken.ps1 -Login -TenantId <tenantGuidOrDomain>`
  - Or pass the client id explicitly:
    - `pwsh -File mcp-message-center-server/scripts/GetMcpAccessToken.ps1 -Login -TenantId <tenantGuidOrDomain> -ApiClientId <mcpApiClientId>`
- Fetch messages:
  - `pwsh -File mcp-message-center-server/scripts/GetMessages.ps1 -McpAccessToken (pwsh -File mcp-message-center-server/scripts/GetMcpAccessToken.ps1) -Top 5 -Count:$true`

## Authentication overview

Preferred for most clients (including declarative agents):

- Send `Authorization: Bearer <user token for this MCP API>` to `POST /mcp`
- Server uses OBO to acquire a delegated Microsoft Graph token

Token types (common point of confusion):

- **MCP API user token** (audience = this MCP API, e.g. `api://<clientId>`)
  - How you get it: `scripts/GetMcpAccessToken.ps1` (via Azure CLI)
  - Where it is used: sent to this server as `Authorization: Bearer <token>` on `POST /mcp`
- **Microsoft Graph token** (audience = Microsoft Graph)
  - How you get it: acquired by the server using OBO, or provided directly via testing bypass
  - Where it is used: the server uses it to call Microsoft Graph

Important security note:

- This server expects the `Authorization` header on `POST /mcp` to be an **MCP API access token** (audience = this MCP API).
- Sending a Microsoft Graph token as the caller credential is **disabled by default** (confused deputy risk). If you need this for local debugging only, set `ALLOW_GRAPH_BEARER_TOKEN=true`.

Testing-only bypasses:

- Provide a Graph token via the MCP tool argument `accessToken`, or set `GRAPH_ACCESS_TOKEN`
- These bypasses are disabled when `NODE_ENV=production` unless `ALLOW_MCP_ACCESS_TOKEN_ARG=true`

## Setting up Client / Agent app registrations

This section describes the recommended **separate app registration** model for Teams declarative agents ("Option B"):

- **Teams OAuth client app**: used only for the OAuth authorization-code flow.
- **Server/API app**: represents this MCP API (token audience) and is the confidential client that performs OBO to Microsoft Graph.

Important: **only the server/API app exposes** the `access_as_user` scope. Client apps do **not** create/"expose" `access_as_user` themselves.

### 1) Server/API app registration (owned by the server)

- **Expose an API**
  - Application ID URI: `api://<serverApiAppId>`
  - Delegated scope: `access_as_user`
- **API permissions (Microsoft Graph)**
  - Add **Delegated** permission: `ServiceMessage.Read.All`
  - Grant **admin consent**
- Configure the server to use this app as `GRAPH_CLIENT_ID` (and its credential as `GRAPH_CLIENT_SECRET` or `GRAPH_CLIENT_CERT_*`).

### 2) Teams OAuth client app registration (owned by the client/agent)

- **Authentication**
  - Add Web redirect URI: `https://teams.microsoft.com/api/platform/v1.0/oAuthRedirect`
- **API permissions**
  - Add delegated permission to the server/API app scope: `api://<serverApiAppId>/access_as_user`
  - Grant admin consent (or have the appropriate admin consent it)
- **Teams Developer Portal OAuth settings**
  - Use Entra v2 endpoints:
    - Authorization: `https://login.microsoftonline.com/<tenantId>/oauth2/v2.0/authorize`
    - Token: `https://login.microsoftonline.com/<tenantId>/oauth2/v2.0/token`
  - Requested scopes should include: `api://<serverApiAppId>/access_as_user`

### Common error (AADSTS500131)

If OBO fails with an error like:

- "Assertion audience does not match the Client app presenting the assertion"

it usually means the client obtained a token with the wrong audience (e.g., `aud = api://<clientAppId>`). The client must request a token for the **server/API app audience** (e.g., `aud = api://<serverApiAppId>`) and send that as the `Authorization: Bearer ...` token to `POST /mcp`.

## Prereqs

- Node.js `>= 20`
- This server listens on **port 8080** by default.

## Deploy script prereqs (Azure)

The repo includes an end-to-end deploy helper: [dev/BuildTestDeploy.ps1](dev/BuildTestDeploy.ps1).

Prereqs:

- PowerShell 7+ (`pwsh`)
- Azure CLI (`az`) installed and authenticated (`az login`)
- Azure permissions (at least):
  - Read ACR metadata (`az acr show`)
  - Build/push to ACR (either `az acr build` or `docker push` depending on flags)
  - Update the Container App (`az containerapp update`) if deploying
- Docker Desktop/Engine if you do **local build + smoke** (default). Use `-SkipLocalTest` to avoid requiring Docker.
- Node/npm only if using `-BumpVersion` or `-Version` (the script runs `npm version`).

Required parameters:

- Always: `-AcrName <acrName>`
- If you are doing any Azure/ACR action (default unless `-SkipAcrBuild -SkipDeploy`): `-ResourceGroupName <rg>`
- If deploying (default unless `-SkipDeploy`): `-ContainerAppName <containerAppName>`

Common error:

- If `-ResourceGroupName` is omitted, Azure CLI fails with:
  - `az acr show ... -g  --query loginServer ... ERROR: argument --resource-group/-g: expected one argument`

Examples:

- Local-only validation (no Azure calls):
  - `pwsh -NoProfile -File .\mcp-message-center-server\dev\BuildTestDeploy.ps1 -AcrName <acrName> -SkipLocalTest -SkipAcrBuild -SkipDeploy`
- ACR build + deploy (plus health and MCP checks):
  - `pwsh -NoProfile -File .\mcp-message-center-server\dev\BuildTestDeploy.ps1 -AcrName <acrName> -ResourceGroupName <rg> -ContainerAppName <app> -WaitForHealth -TestMcp`

How to find `-ContainerAppName`:

- If you run with `-ProvisionInfra`, the script derives the Container App name from `infra/main.parameters.json`:
  - `ContainerAppName = "<namePrefix>-mcp-mc"`
  - Example: if `namePrefix` is `mcagent`, the Container App name is `mcagent-mcp-mc`.
- If the Container App already exists, list it:
  - `az containerapp list -g <rg> --query "[].name" -o tsv`

Common infra error (when using `-ProvisionInfra`):

- `AlreadyInUse: The registry DNS name <name>.azurecr.io is already in use.`
  - Fix: choose a globally-unique `-AcrName`.

If infra fails with a Key Vault "already exists"/name collision:

- Key Vault names are globally unique.
- Either choose a unique `keyVaultName` in `infra/main.parameters.json`, or set:
  - `useExistingKeyVault=true`
  - `existingKeyVaultResourceGroupName=<rg>` (only if the existing vault is in a different RG)


## Build and run

From the repo root:

- Install dependencies (recommended):
  - `cd mcp-message-center-server; npm install`

- Generate schemas from OpenAPI:
  - `npm --prefix mcp-message-center-server run generate`
- Build:
  - `npm --prefix mcp-message-center-server run build`
- Run (prod build):
  - `npm --prefix mcp-message-center-server run start`
- Run (dev watch):
  - `npm --prefix mcp-message-center-server run dev`

If you are already in the `mcp-message-center-server` folder, do **not** use `--prefix` (it becomes relative to the current directory and can create a duplicated path). Use:
- `npm install`
- `npm run dev`

<!-- Note: in the monorepo, there is no root `package.json`. If you run `npm install` or `npm run ...` from the monorepo root without `--prefix`, you may get `ENOENT`. -->

Health check:
- `http://localhost:8080/healthz`

MCP endpoint:
- `http://localhost:8080/mcp`

Local verification checklist:

- Confirm the server is running: `http://localhost:8080/healthz`
- If you see `No connection could be made (localhost:8080)`, the server is not running, crashed, or is listening on a different port.
- If you see `401 Unauthorized: missing Authorization bearer token`, pass an MCP API token (see **Smoke test using OBO**) or (for local dev only) set `MCP_REQUIRE_AUTH=false`.
- If you see `401 Unauthorized: invalid access token`, ensure your token is:
  - issued by the configured tenant (`GRAPH_TENANT_ID` / `MCP_OAUTH_TENANT_ID`)
  - audience = this MCP API (e.g. `api://<serverApiAppId>`)
  - includes the required delegated scope (default: `access_as_user`, configurable via `MCP_OAUTH_REQUIRED_SCOPES`)

## App registration requirements (Microsoft Entra ID)

This server always requires a **server/API** Microsoft Entra app registration that acts as:

- The **MCP API resource** (audience for callers of `POST /mcp`)
- The **confidential client** used by the server to perform OBO to Microsoft Graph

Additionally, this repo can optionally expose `/authorize` + `/token` as a convenience OAuth proxy for some clients (see `.env.local` comments). In that proxy mode, the server/API app registration is also used as the OAuth client.

Minimum configuration:

- **Expose an API**
  - Set the Application ID URI (recommended): `api://<clientId>`
  - Add an OAuth2 delegated scope named: `access_as_user`
    - This is the scope requested by the helper scripts (e.g., `api://<clientId>/access_as_user`).

- **API permissions (Microsoft Graph)**
  - Add **Delegated** permission: `ServiceMessage.Read.All`
  - Grant **admin consent** for the tenant
  - Note: the calling **user** still needs the Microsoft 365 admin role (e.g., *Message Center Reader*) for Message Center access.

- **Authentication (redirect URIs)**
  - Add the redirect URI your client uses for the auth code flow.
    - Default for `scripts/SmokeTokenProxyPkce.ps1`: `http://127.0.0.1:8400/`
    - If using **Copilot** / **Teams** declarative agents: `https://teams.microsoft.com/api/platform/v1.0/oAuthRedirect`
  - The server also enforces an allowlist for redirect URIs (see `MCP_OAUTH_REDIRECT_URI_PREFIXES`). Ensure your app registration redirect URIs are compatible with that allowlist.

- **Certificates & secrets**
  - Local/dev (simplest): create a **client secret** and set `GRAPH_CLIENT_SECRET` (and optionally `MCP_OAUTH_CLIENT_SECRET`).
  - Azure-hosted (recommended): add a **certificate** to the app registration (public key), store the private key PEM in Key Vault, and configure:
    - `GRAPH_CLIENT_CERT_THUMBPRINT`
    - `GRAPH_CLIENT_CERT_KEYVAULT_URL`
    - `GRAPH_CLIENT_CERT_SECRET_NAME` (this is only the secret name, not the secret value)
    - Optional: `GRAPH_CLIENT_CERT_SECRET_VERSION`

Key Vault secret format note:

- This server reads the private key using the **Key Vault Secrets** API.
- Ensure the private key exists as a **secret** named `GRAPH_CLIENT_CERT_SECRET_NAME`.
  - The secret value can be raw PEM, or JSON like `{"privateKey":"..."}`.

### Key Vault + certificate setup (Azure-hosted)

This is the recommended configuration for production deployments:

- Upload the **public certificate** to the Entra app registration (so Entra can validate signed assertions).
- Store the **private key** as a Key Vault **secret** (so the server can sign assertions).
- Allow the Container App’s managed identity to read that secret at runtime.

Managed identity details:

- In this repo’s Azure deployment, the Container App always has a **system-assigned managed identity** enabled.
  - That identity is granted `Key Vault Secrets User` on the Key Vault so the server can read the private key secret.
- If you enable managed identity pulls from ACR (`acrUseManagedIdentity=true` in infra parameters), the deployment also creates a **user-assigned** identity (default name: `<namePrefix>-acr-pull`) and grants it `AcrPull` on the ACR.

Artifacts (same certificate):

- Public cert: `.cer` (or PEM containing `-----BEGIN CERTIFICATE-----`)
  - Goes to: Entra App Registration → Certificates & secrets → Certificates
- Private key: `*.key.pem` (PKCS#8 PEM containing `-----BEGIN PRIVATE KEY-----`)
  - Goes to: Key Vault → Secrets (as the secret value)

Thumbprint:

- Configure `GRAPH_CLIENT_CERT_THUMBPRINT` to match the uploaded public cert.

Generate a cert locally (helper script):

```pwsh
pwsh -NoProfile -File mcp-message-center-server/scripts/CreateCertificate.ps1 \
  -Name graph-client-cert \
  -DnsName localhost \
  -OutputDir .\certs \
  -IncludeClientAuthEku
```

Upload the public cert to Entra:

- Upload `.\certs\graph-client-cert.cer`

Store the private key in Key Vault (recommended: use `--file` so PEM formatting is preserved):

```pwsh
az keyvault secret set \
  --vault-name <yourKeyVaultName> \
  --name <yourSecretName> \
  --file .\certs\graph-client-cert.key.pem
```

Required Azure roles (RBAC-enabled Key Vault):

- Container App runtime identity: `Key Vault Secrets User` on the Key Vault
  - Allows reading the private key secret at startup
- Human/operator creating/updating the secret: `Key Vault Secrets Officer` (or `Key Vault Administrator`) on the Key Vault

PEM formatting note:

- Best practice is to store a properly formatted multi-line PEM.
- If the PEM newlines are collapsed into a single line, the server attempts to normalize it at runtime, but using `--file` avoids issues.

Common failure modes:

- **403 from Key Vault at runtime**: Container App managed identity is missing `Key Vault Secrets User` on the vault.
- **Secret not found**: `GRAPH_CLIENT_CERT_SECRET_NAME` points to the wrong secret name, or the secret exists under a different vault than `GRAPH_CLIENT_CERT_KEYVAULT_URL`.
- **Invalid/mismatched thumbprint**: `GRAPH_CLIENT_CERT_THUMBPRINT` does not match the certificate uploaded to the app registration.
- **Wrong Key Vault object type**: you created a Key Vault *certificate* object but did not create a *secret* with the private key; this server reads via the Secrets API.
- **Bad private key format**: the secret value is not a private key PEM (PKCS#8 `BEGIN PRIVATE KEY`). Prefer uploading via `az keyvault secret set --file`.

For the full Azure deployment flow (including how the infra wires these settings), see `infra/README.md`.

## Configuration (OBO for declarative agents)

For **Microsoft declarative agent clients** (non-interactive callers), the recommended pattern is:

- The client calls `POST /mcp` with `Authorization: Bearer <user token for this MCP API>`.
- This server uses **On-Behalf-Of (OBO)** to exchange that token for a **Microsoft Graph delegated** access token.
- Microsoft Graph enforces the user role requirement (e.g., Message Center Reader).

Required variables (same app registration as above):
- `GRAPH_TENANT_ID=...`
- `GRAPH_CLIENT_ID=...`

Credential options (choose one):

- **Preferred (Azure-hosted)**: certificate private key loaded from **Azure Key Vault** using managed identity
  - `GRAPH_CLIENT_CERT_KEYVAULT_URL=https://<vault>.vault.azure.net/`
  - `GRAPH_CLIENT_CERT_SECRET_NAME=<secretName>`
  - `GRAPH_CLIENT_CERT_THUMBPRINT=<hexThumbprint>`
  - Optional: `GRAPH_CLIENT_CERT_SECRET_VERSION=<version>`

Note: the `/token` OAuth proxy endpoint also uses these credentials. If no client secret is configured (`MCP_OAUTH_CLIENT_SECRET`/`GRAPH_CLIENT_SECRET`), it will authenticate to Entra using `private_key_jwt` with the Key Vault certificate settings.

Optional variables:
- `GRAPH_OBO_SCOPES=https://graph.microsoft.com/.default`
  - Default is `https://graph.microsoft.com/.default` (recommended when Graph delegated permissions are pre-consented).
- `MCP_REQUIRE_AUTH=true`
  - When set, `POST /mcp` returns `401` if the `Authorization` header is missing.

Notes:
- If a caller sends a **Graph** token directly in `Authorization`, the server will use it as-is.
- The legacy dev/test paths still work (tool arg `accessToken` or `GRAPH_ACCESS_TOKEN`).
  - When `NODE_ENV=production`, these dev/test bypasses are disabled unless `ALLOW_MCP_ACCESS_TOKEN_ARG=true`.

## OAuth redirect allowlist (VS Code + Teams)

This server intentionally enforces an allowlist for `redirect_uri` on the `/authorize` and `/token` endpoints to avoid becoming an open OAuth proxy.

Defaults:
- VS Code loopback (`http://127.0.0.1`, `http://localhost`)
- Teams declarative agent redirect (`https://teams.microsoft.com/api/platform/v1.0/oAuthRedirect`)

If you use a different redirect (e.g., a custom localhost hostname or a different Teams endpoint), set:
- `MCP_OAUTH_REDIRECT_URI_PREFIXES=<comma-separated prefixes>`

Example:
- `MCP_OAUTH_REDIRECT_URI_PREFIXES=http://127.0.0.1,http://localhost,https://teams.microsoft.com/api/platform/v1.0/oAuthRedirect`

## Smoke tests

PowerShell scripts are in `mcp-message-center-server/scripts/`.

### Build + validate (PowerShell)

Use `dev/BuildTestDeploy.ps1` when you want a repeatable build + health/MCP validation flow:

- **Local Docker build + /healthz smoke (no Azure calls)**
  - Builds a local Docker image, runs a local container, checks `GET /healthz`.
  - Requires Docker Desktop.
  - Command:
    - `pwsh -NoProfile -File mcp-message-center-server/dev/BuildTestDeploy.ps1 -AcrName <anyString> -SkipAcrBuild -SkipDeploy`

- **Azure deploy validation**
  - After deploying to Azure Container Apps, validate:
    - `-WaitForHealth` (polls `https://<fqdn>/healthz`)
    - `-TestMcp` (POSTs a JSON-RPC `tools/list` request to `https://<fqdn>/mcp`)
  - Command:
    - `pwsh -NoProfile -File mcp-message-center-server/dev/BuildTestDeploy.ps1 -AcrName <acrName> -WaitForHealth -TestMcp`

Notes:

- The simplest “one-liner” is:
  - `pwsh -NoProfile -File mcp-message-center-server/scripts/GetAccessTokenAndMessages.ps1`
- This one-liner works from any current directory and validates the OBO path by:
  - Getting an MCP API token via Azure CLI
  - Calling `POST /mcp` using that token
- When copying commands from chat/Markdown, paste the literal `.ps1` path (not a Markdown link). VS Code content-reference URLs like `http://_vscodecontentref_/...` are not valid commands.

- Fetch messages (local server URL by default):
  - `pwsh -File mcp-message-center-server/scripts/GetMessages.ps1 -Top 5 -Count:$true`
  - For Azure-hosted, pass the full MCP URL:
    - `pwsh -File mcp-message-center-server/scripts/GetMessages.ps1 -McpUrl https://<fqdn>/mcp -McpAccessToken (pwsh -File mcp-message-center-server/scripts/GetMcpAccessToken.ps1) -Top 5 -Count:$true`

- Smoke test `/authorize` + `/token` proxy using PKCE (manual paste of the redirect URL):
  - `pwsh -File mcp-message-center-server/scripts/SmokeTokenProxyPkce.ps1`

### Smoke test using OBO (non-interactive)

If you want to test the OBO path end-to-end (send a user token for this MCP API to `/mcp`):

1) Get an MCP API user token via Azure CLI (first time may require consent):

- First-time interactive consent/login:
  - If you set `GRAPH_CLIENT_ID` in `.env.local`:
    - `pwsh -File mcp-message-center-server/scripts/GetMcpAccessToken.ps1 -Login -TenantId <tenantGuidOrDomain>`
  - Or pass the client id explicitly:
    - `pwsh -File mcp-message-center-server/scripts/GetMcpAccessToken.ps1 -Login -TenantId <tenantGuidOrDomain> -ApiClientId <mcpApiClientId>`

- Subsequent token fetch (prints the token):
  - `pwsh -File mcp-message-center-server/scripts/GetMcpAccessToken.ps1`

2) Call `getMessages` with the MCP token:

- `pwsh -File mcp-message-center-server/scripts/GetMessages.ps1 -McpAccessToken (pwsh -File mcp-message-center-server/scripts/GetMcpAccessToken.ps1) -Top 5 -Count:$true`

If you see `401 InvalidAuthenticationToken` with `Access token is empty`, you have not completed sign-in for the currently running server process.

## Schema generation

Tool input schemas are generated from:
- `openapi/openapi.json`

Generated file:
- `mcp-message-center-server/src/generated/messagesInputSchema.ts`

The `accessToken` tool argument remains MCP-only (not in OpenAPI) and is layered on top of the generated schema.

## MCP request header

When calling `/mcp` directly, include:
- `Accept: application/json, text/event-stream`

The provided scripts already set this header.

## Calling `/mcp` directly (PowerShell)

The scripts in `mcp-message-center-server/scripts/` are the easiest way to call the server. If you want to call `/mcp` directly, these examples work on Windows PowerShell / pwsh:

- List tools:

```powershell
$body = @{ jsonrpc = '2.0'; id = 1; method = 'tools/list'; params = @{} } | ConvertTo-Json -Depth 10
Invoke-RestMethod -Method Post -Uri 'http://localhost:8080/mcp' -ContentType 'application/json' -Headers @{ Accept = 'application/json, text/event-stream' } -Body $body
```

- Call `getMessages` (using an MCP API token):

```powershell
$mcpToken = pwsh -File mcp-message-center-server/scripts/GetMcpAccessToken.ps1
$body = @{ jsonrpc = '2.0'; id = 2; method = 'tools/call'; params = @{ name = 'getMessages'; arguments = @{ top = 5; count = $true } } } | ConvertTo-Json -Depth 10
Invoke-RestMethod -Method Post -Uri 'http://localhost:8080/mcp' -ContentType 'application/json' -Headers @{ Accept = 'application/json, text/event-stream'; Authorization = "Bearer $mcpToken" } -Body $body
```

## Response format

- Tool results are returned as MCP `content` (text) and may also include `structuredContent`.
- Responses can be JSON or SSE depending on the `Accept` header.

## Environment variables (reference)

For a complete template, see [mcp-message-center-server/.env.local.sample](mcp-message-center-server/.env.local.sample).

Common variables:

- Required for OBO: `GRAPH_TENANT_ID`, `GRAPH_CLIENT_ID`
- Confidential client (choose one):
  - `GRAPH_CLIENT_SECRET` (local/dev), or
  - `GRAPH_CLIENT_CERT_THUMBPRINT`, `GRAPH_CLIENT_CERT_KEYVAULT_URL`, `GRAPH_CLIENT_CERT_SECRET_NAME` (+ optional `GRAPH_CLIENT_CERT_SECRET_VERSION`) (Azure-hosted)
- OAuth proxy: `MCP_OAUTH_REDIRECT_URI_PREFIXES`, `MCP_OAUTH_SCOPES` (optional)
- Behavior toggles: `MCP_REQUIRE_AUTH`, `ALLOW_MCP_ACCESS_TOKEN_ARG`, `PUBLIC_BASE_URL`, `PORT`

## Troubleshooting

- `Cannot GET /mcp`: expected. MCP requests use `POST /mcp`.
- `401` from this server: missing `Authorization` header while `MCP_REQUIRE_AUTH=true`, or caller token is invalid.
- `401 Unauthorized: missing Authorization bearer token`: you called `POST /mcp` without `Authorization: Bearer <MCP API token>`.
- `No connection could be made (localhost:8080)`: the server is not running, crashed, or is listening on a different port.
- `AADSTS65001` / `consent_required`: run `scripts/GetMcpAccessToken.ps1 -Login -TenantId <tenantGuidOrDomain>` once to complete interactive consent (and ensure `GRAPH_CLIENT_ID` is set, or pass `-ApiClientId <mcpApiClientId>`).
- `401` from Graph:
  - OBO token exchange failed (app registration missing delegated Graph permission/admin consent), or
  - caller did not send an MCP API token (so the server could not do OBO)
- `403` from Graph: the user likely lacks the required Microsoft 365 admin role (e.g., Message Center Reader).
- `accessToken_disabled`: you are using the testing bypass in production; switch to OBO or set `ALLOW_MCP_ACCESS_TOKEN_ARG=true` explicitly.
- Key Vault error: `Public network access is disabled and request is not from a trusted service nor via an approved private link`
  - Meaning: the server is configured to load the Entra client certificate private key from Azure Key Vault (`GRAPH_CLIENT_CERT_KEYVAULT_URL` / `GRAPH_CLIENT_CERT_SECRET_NAME`), but Key Vault networking is blocking the request.
  - Local/dev fix (simplest): use a client secret instead of Key Vault.
    - Set `GRAPH_CLIENT_SECRET` (and optionally `MCP_OAUTH_CLIENT_SECRET`) in `.env.local`.
    - Clear/unset `GRAPH_CLIENT_CERT_KEYVAULT_URL`, `GRAPH_CLIENT_CERT_SECRET_NAME`, and `GRAPH_CLIENT_CERT_THUMBPRINT` so the server doesn’t try Key Vault.
  - Azure-hosted fix: configure Key Vault access so the workload can reach it (e.g., private endpoint + VNet integration), or adjust Key Vault network settings per your org policy.
  - When might enabling **public** Key Vault access be appropriate?
    - Short-lived dev/test or break-glass debugging where you don’t have private networking available yet, but you still need the workload to start.
    - Small/sandbox deployments where organizational policy allows public endpoints and the workload’s outbound egress is tightly controlled.
    - Cases where the platform team explicitly prefers public endpoints plus layered controls (RBAC, audit, and network restrictions) over managing private endpoints.
  - Default recommendation: keep Key Vault public network access **disabled** for production and use private connectivity (private endpoint/VNet integration) whenever your org supports it.
- Key Vault error: `A secret with (name/id) <name> was not found in this key vault`
  - Meaning: `GRAPH_CLIENT_CERT_SECRET_NAME` does not exist under **Key Vault → Secrets**, or the server is pointing at the wrong vault.
  - Fix: create or recover the secret under Key Vault **Secrets** using the exact name in `GRAPH_CLIENT_CERT_SECRET_NAME`.

## Build/test/deploy automation

This repo includes an end-to-end PowerShell script:

- [mcp-message-center-server/dev/BuildTestDeploy.ps1](mcp-message-center-server/dev/BuildTestDeploy.ps1)

Common runs:

- Safe validation (no Azure calls):
  - `pwsh -NoProfile -File mcp-message-center-server/dev/BuildTestDeploy.ps1 -AcrName <acrName> -SkipLocalTest -SkipAcrBuild -SkipDeploy`

- ACR build + deploy to Azure Container Apps, then verify health + MCP endpoint:
  - `pwsh -NoProfile -File mcp-message-center-server/dev/BuildTestDeploy.ps1 -AcrName <acrName> -WaitForHealth -TestMcp`

## OAuth flow diagram

```javascript
Client (VS Code)
  |
  | (1) GET http://localhost:8080/authorize?client_id=...&redirect_uri=http://127.0.0.1:<port>/&code_challenge=...
  v
MCP Server (/authorize)
  |
  | (2) 302 redirect to Entra authorize endpoint
  v
Entra ID (MCP API)
  |
  | (3) User signs in + consents
  | (4) Redirects back to VS Code loopback redirect_uri with ?code=...&state=...
  v
Client (VS Code)
  |
  | (5) POST http://localhost:8080/token (includes code + code_verifier)
  v
MCP Server (/token)
  |
  | (6) Proxies token exchange to Entra /token
  v
Entra ID (MCP API)
  |
  | (7) Returns MCP-API access_token (+ refresh_token if allowed)
  v
Client (VS Code)
  |
  | (8) Now call POST /mcp with Authorization: Bearer <MCP-API token>
  v
MCP Server -> (OBO) -> Entra -> Graph
```

## Setting up Azure resources
See [infra/README.md](infra/README.md) for standalone deployment instructions.

## Related projects
- [mcp-roadmap-server](../mcp-roadmap-server/README.md): MCP server for Microsoft 365 Roadmap data.
- [modelcontextprotocol/typescript-sdk](https://github.com/modelcontextprotocol/typescript-sdk): TypeScript SDK for building MCP servers and clients.
- [Microsoft Graph Message Center API docs](https://learn.microsoft.com/en-us/graph/api/serviceannouncement-list-messages?view=graph-rest-1.0&tabs=http)
- **Message Center Agent:** https://github.com/microsoft/Message-Center-Agent