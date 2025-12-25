# Message Center MCP Server (infra)

This folder is a **standalone** Azure Container Apps deployment for the Message Center MCP server.

## Prereqs (Azure)

- Azure CLI installed and logged in: `az login`
- Resource group already created (this repo does not auto-create it):

```pwsh
az group create -n <resourceGroup> -l <location>
```

## Required Azure permissions (important)

This deployment creates RBAC role assignments (for Key Vault secret reads + ACR pulls). The identity running the deployment typically needs:

- `Owner` on the resource group, **or**
- `Contributor` + `User Access Administrator` on the resource group (or equivalent permissions allowing `Microsoft.Authorization/roleAssignments/write`).

## Deploy

### 1) Create an Azure Container Registry (ACR) (optional)

This repo includes a small Bicep file that provisions an ACR:

```pwsh
$resourceGroup = '<resourceGroup>'
$acrName = '<acrNameLowercase>'

# NOTE: deployment name is NOT the ACR name.
# It's only the ARM deployment record name (Azure CLI defaults it from the template filename if you omit -n).
$deploymentName = 'acr-' + (Get-Date -Format 'yyyyMMdd-HHmmss')

az deployment group create `
  -g $resourceGroup `
  -n $deploymentName `
  -f infra/acr.bicep `
  -p acrName=$acrName
```

Get the ACR login server (you’ll use this in `messageCenterImage`):

```pwsh
$resourceGroup = '<resourceGroup>'
$acrName = '<acrNameLowercase>'

$acrLoginServer = az acr show `
  -g $resourceGroup `
  -n $acrName `
  --query loginServer `
  -o tsv

$acrLoginServer
```

### 2) Build/push the container image (this creates `messageCenterImage`)

`messageCenterImage` is just a **container image reference**. You create it by building this repo into a Docker image and pushing it to ACR.

From the repo root:

```pwsh
az acr build \
  --registry <acrNameLowercase> \
  --image mcp-message-center-server:v1.0.0 \
  .
```

Important: `--registry` expects the registry name (e.g. `acrmcpmessagecenter`), not the ARM deployment name (e.g. `acr-20251223-164815`).

That produces an image reference like:

```
<acrLoginServer>/mcp-message-center-server:v1.0.0
```

### Optional: use the existing build+deploy script

If you already provisioned the Azure resources (ACR + Container App), you can use the repo script that:
- builds + pushes the image with `az acr build`
- updates the Container App to the new image (`az containerapp update`)

```pwsh
pwsh -NoProfile -File .\dev\BuildTestDeploy.ps1 `
  -ResourceGroupName <resourceGroup> `
  -AcrName <acrNameLowercase> `
  -ContainerAppName <containerAppName> `
  -SkipLocalTest
```

This script does **not** provision infrastructure; it expects the ACR and Container App to already exist.

### One-command flow: provision infra + build + deploy

If you want a single command that:
1) provisions/updates infra (ACR + Container App)
2) builds + pushes the image
3) deploys the image

use `-ProvisionInfra`:

```pwsh
pwsh -NoProfile -File .\dev\BuildTestDeploy.ps1 `
  -ProvisionInfra `
  -ResourceGroupName <resourceGroup> `
  -AcrName <acrNameLowercase> `
  -SkipLocalTest `
  -WaitForHealth
```

Optional: if you prefer building locally and pushing with Docker (instead of `az acr build`), add `-UseLocalDockerForAcr`:

```pwsh
pwsh -NoProfile -File .\dev\BuildTestDeploy.ps1 `
  -ProvisionInfra `
  -UseLocalDockerForAcr `
  -ResourceGroupName <resourceGroup> `
  -AcrName <acrNameLowercase> `
  -SkipLocalTest `
  -WaitForHealth
```

Note: when `-ProvisionInfra` is used, the Container App name is derived from `namePrefix` in `infra/main.parameters.json` as `<namePrefix>-mcp-mc`.

- Build/push your image to ACR (or use an existing image reference)
- Update `infra/main.parameters.json` with your image reference and settings
- Deploy:

```pwsh
$deploymentName = 'main-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
az deployment group create `
  -g <resourceGroup> `
  -n $deploymentName `
  -f infra/main.bicep `
  -p infra/main.parameters.json
```

## Parameters (`infra/main.parameters.json`)

This repo uses an ARM parameters file to provide inputs to `infra/main.bicep`.

Tip: start from `infra/main.parameters.sample.json` and copy it to `infra/main.parameters.json`.

Every parameter in `infra/main.parameters.json`:

- `location`
  - Azure region for all resources (example: `westus`).
  - If omitted from parameters, `main.bicep` defaults to the resource group location.

- `namePrefix`
  - Prefix for resource names.
  - Determines the Container App name as: `<namePrefix>-mcp-mc`.

- `messageCenterImage`
  - Full container image reference.
  - Format: `<acrLoginServer>/mcp-message-center-server:<tag>`.
  - Note: if you deploy using `dev/BuildTestDeploy.ps1 -ProvisionInfra`, the script passes `messageCenterImage=<computedImageRef>` automatically (based on the ACR login server + tag), so you typically do **not** need to manually update the `<acrLoginServer>` portion.

- `minReplicas`
  - Minimum replicas for the Container App.
  - `0` enables scale-to-zero.

- `maxReplicas`
  - Maximum replicas for the Container App.

- `graphTenantId`
  - Microsoft Entra tenant ID (GUID) used by the server for auth (OBO to Graph).
  - Also used as the Key Vault tenant.

- `graphClientId`
  - Application (client) ID (GUID) of the Entra app registration used for:
    - the MCP API audience (`api://<clientId>`), and
    - the confidential client credentials for OBO.

- `keyVaultName`
  - Name of the Azure Key Vault to create/use (globally unique).
  - The server reads the certificate private key from this vault.

- `graphClientCertSecretName`
  - Key Vault **secret name** (not the secret value) containing the Graph client certificate private key (PEM).

- `graphClientCertThumbprint`
  - Thumbprint (hex) of the **public** certificate uploaded to the app registration.
  - Must match the private key stored in Key Vault.

- `publicBaseUrl`
  - Optional override for `PUBLIC_BASE_URL`.
  - If empty, the deployment computes it as `https://<appFqdn>`.
  - Set this when you put the app behind a custom domain / reverse proxy and want discovery + redirects to use that public URL.

- `acrUseManagedIdentity`
  - Controls how the Container App pulls the image from ACR:
    - `true` (recommended): uses a managed identity for `AcrPull`.
      - This template creates/uses a user-assigned identity named `<namePrefix>-acr-pull`.
    - `false` (bootstrap mode): uses ACR admin credentials via `listCredentials()`.
  - Keep `true` for production.

## Managed identities (what gets created)

This deployment uses managed identities automatically (no manual identity creation step is required):

- **Container App system-assigned managed identity**
  - Always enabled by `infra/main.bicep`.
  - Used to read the Graph client certificate private key from Key Vault.
  - `infra/main.bicep` creates the role assignment: `Key Vault Secrets User` on the Key Vault.

- **User-assigned managed identity for ACR pulls** (optional)
  - Created only when `acrUseManagedIdentity=true`.
  - Name defaults to `<namePrefix>-acr-pull`.
  - Attached to the Container App and used for image pulls.
  - `infra/main.bicep` creates the role assignment: `AcrPull` on the ACR.

Note: `infra/main.bicep` also defines additional advanced parameters with defaults (for example, ingress port and zone redundancy). They are not required in `infra/main.parameters.json` unless you want to override defaults.

## Notes

- This deployment expects the ACR in your image reference to already exist (it uses it as an `existing` resource).
- No secrets are committed. Certificate private key should be stored in Key Vault and referenced by name.

## Production behavior (`NODE_ENV=production`)

This Azure Container Apps deployment explicitly sets `NODE_ENV=production` in the Container App environment variables (see `infra/main.bicep`). As a result, the server treats Azure-hosted deployments as **production**.

In production mode, the server disables the “testing bypass” paths that let callers provide a Microsoft Graph token directly:

- MCP tool argument: `accessToken`
- Environment variable: `GRAPH_ACCESS_TOKEN`

These are rejected unless you explicitly opt in by setting:

- `ALLOW_MCP_ACCESS_TOKEN_ARG=true`

Recommendation: keep this disabled in production and rely on the normal flow (callers send an MCP API token to `POST /mcp`, and the server performs OBO to Microsoft Graph).

If you need to temporarily enable the bypass for debugging, set the env var on the Container App (example):

```pwsh
az containerapp update \
  -g <resourceGroup> \
  -n <containerAppName> \
  --set-env-vars ALLOW_MCP_ACCESS_TOKEN_ARG=true
```

## Key Vault + certificate (Graph OBO auth)

### Purpose

When this server runs in Azure, it should authenticate to Microsoft Entra ID as a **confidential client** so it can perform the **On-Behalf-Of (OBO)** flow and call Microsoft Graph.

Recommended pattern:

- Store the **private key** for an app-registration certificate in **Azure Key Vault** (as a *secret* value).
- The Container App uses its **managed identity** to read that Key Vault secret at runtime.
- The Entra app registration uses the **public key** (certificate) so Entra can validate the signed client assertion.

This avoids hardcoding a client secret in the container image.

### What you need

You will manage two artifacts for the same certificate:

- **Public cert** (upload to Entra App Registration)
  - File: `.cer` (recommended)
  - Also OK: PEM containing `-----BEGIN CERTIFICATE-----`
- **Private key** (store in Key Vault secret)
  - File: `*.key.pem` containing `-----BEGIN PRIVATE KEY-----` (PKCS#8)
  - Store as a Key Vault **secret** value (not a Key Vault *certificate* object)

You will also need the certificate **thumbprint** (hex) to configure the app.

### Step-by-step

1) Create a certificate (local)

Use the helper script in this repo:

```pwsh
pwsh -NoProfile -File .\scripts\CreateCertificate.ps1 \
  -Name graph-client-cert \
  -DnsName localhost \
  -OutputDir .\certs \
  -IncludeClientAuthEku
```

This produces:

- `.\certs\graph-client-cert.cer` (public cert for Entra upload)
- `.\certs\graph-client-cert.key.pem` (private key PEM for Key Vault secret)
- Prints `Thumbprint: <HEX>`

2) Upload the public cert to the Entra app registration

In the Entra App Registration for your `graphClientId`:

- Certificates & secrets
  - Certificates
    - Upload certificate: use the `.cer` file

Record the thumbprint, and set it in your parameters:

- `graphClientCertThumbprint` in `infra/main.parameters.json`

3) Store the private key in Key Vault (as a secret)

Upload the `.key.pem` file as the secret value. This preserves the PEM formatting and avoids copy/paste issues.

```pwsh
az keyvault secret set \
  --vault-name kvmessagecentermcp \
  --name sec-message-center-mcp \
  --file .\certs\graph-client-cert.key.pem
```

4) Ensure parameters match the Key Vault settings

In `infra/main.parameters.json`:

- `keyVaultName`: the vault name (globally unique)
- `graphClientCertSecretName`: the secret name (example: `sec-message-center-mcp`)
- `graphClientCertThumbprint`: the uploaded certificate thumbprint

5) Required RBAC roles

Key Vault is RBAC-enabled in this deployment.

- **For the Container App runtime identity (required)**
  - Role: `Key Vault Secrets User`
  - Scope: the Key Vault resource
  - Purpose: allows the app to call `getSecret` at runtime

- **For the human/operator setting the secret (required for setup)**
  - One of:
    - `Key Vault Secrets Officer` (recommended) or
    - `Key Vault Administrator`
  - Scope: the Key Vault resource
  - Purpose: allows `az keyvault secret set`

6) Restart after changing the secret

The server caches the private key in memory. If you rotate/update the Key Vault secret, restart the Container App revision to pick it up.

### Common failure modes

- **403 from Key Vault at runtime**: the Container App managed identity is missing `Key Vault Secrets User` on the vault.
- **Secret not found**: the secret name in `graphClientCertSecretName` does not exist under Key Vault **Secrets**.
- **Thumbprint mismatch**: `graphClientCertThumbprint` does not match the certificate uploaded to the Entra app registration.
- **Wrong Key Vault object type**: a Key Vault *certificate* was created but the private key was not stored as a *secret* value; the app reads via the Secrets API.
- **Private key PEM is not valid**: store a PKCS#8 PEM (`BEGIN PRIVATE KEY`). Upload via `az keyvault secret set --file` to preserve formatting.

### Quick verification (no secret output)

Confirm the secret exists (metadata only):

```pwsh
az keyvault secret show \
  --vault-name kvmessagecentermcp \
  --name sec-message-center-mcp \
  --query "{id:id, enabled:attributes.enabled, updated:attributes.updated}" \
  -o jsonc
```

Confirm the Container App is configured with the correct Key Vault inputs:

```pwsh
az containerapp show -g rg-mcp-message-center -n mcagent-mcp-mc \
  --query "{kvUrl:properties.template.containers[0].env[?name=='GRAPH_CLIENT_CERT_KEYVAULT_URL'].value|[0], kvSecret:properties.template.containers[0].env[?name=='GRAPH_CLIENT_CERT_SECRET_NAME'].value|[0], thumb:properties.template.containers[0].env[?name=='GRAPH_CLIENT_CERT_THUMBPRINT'].value|[0]}" \
  -o jsonc
```
