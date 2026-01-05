<#
.SYNOPSIS
Creates or updates the server/API app registration used by this MCP server.

.DESCRIPTION
This script creates (or updates) a Microsoft Entra ID app registration that represents the MCP API and the confidential client used for
On-Behalf-Of (OBO) to Microsoft Graph.

It ensures:
- Application ID URI: api://<appId>
- Delegated scope: access_as_user (configurable)
- Required Microsoft Graph delegated permission for OBO (default: ServiceMessage.Read.All)

Optionally:
- Creates/rotates a client secret (for local/dev; prefer certificate auth for production)
- Grants tenant-wide admin consent for the configured Graph delegated permission

The script outputs a single JSON object to stdout with the created/updated IDs and the optional secret.

.PARAMETER ServerAppName
Display name for the server/API app registration.

.PARAMETER GraphDelegatedPermission
Microsoft Graph delegated permission the server needs during OBO (default: ServiceMessage.Read.All).

.PARAMETER AccessAsUserScopeName
Delegated scope exposed by the MCP API (default: access_as_user).

.PARAMETER CreateSecret
If set, creates a client secret and returns it in the JSON output. Prefer certificate auth for production.

.PARAMETER GrantAdminConsent
If set, attempts to grant tenant-wide admin consent for the Graph delegated permission. Requires an admin user and Graph permission
DelegatedPermissionGrant.ReadWrite.All at sign-in time.

.PARAMETER SecretYears
Client secret lifetime in years (default: 1).

.EXAMPLE
pwsh -NoProfile -File .\scripts\CreateServerAppRegMCP.ps1

.EXAMPLE
# Create server app + grant tenant-wide admin consent for Graph delegated permission
pwsh -NoProfile -File .\scripts\CreateServerAppRegMCP.ps1 -ServerAppName 'MessageCenter MCP Server' -GrantAdminConsent

.EXAMPLE
# Create a secret (useful for local dev; store in Key Vault for Azure)
pwsh -NoProfile -File .\scripts\CreateServerAppRegMCP.ps1 -CreateSecret | Set-Content .\server-app.json

.OUTPUTS
Writes JSON to stdout. The server appId should be used as:
- Container App env: GRAPH_CLIENT_ID
- Infra parameter: graphClientId
and callers should request tokens for: api://<serverAppId>/access_as_user
#>

[CmdletBinding()]
param(
  # Display name for the server/API app registration.
  [string]$ServerAppName = 'MessageCenterAgent-mcp-server',

  # Delegated Microsoft Graph permission needed by the server for OBO.
  [string]$GraphDelegatedPermission = 'ServiceMessage.Read.All',

  # Scope exposed by the server API.
  [string]$AccessAsUserScopeName = 'access_as_user',

  # Create (or rotate) a client secret for the server app.
  # Note: for production, prefer certificate auth.
  [switch]$CreateSecret,

  # Grant tenant-wide admin consent for the Graph delegated permission.
  # Requires an admin and Graph permission 'DelegatedPermissionGrant.ReadWrite.All'.
  [switch]$GrantAdminConsent,

  # Secret lifetime in years.
  [int]$SecretYears = 1
)

$ErrorActionPreference = 'Stop'

function Repair-EntraModuleVersions {
  param(
    [Parameter(Mandatory = $true)]
    [string[]] $ModuleNames
  )

  foreach ($name in $ModuleNames) {
    $available = @(Get-Module -ListAvailable -Name $name -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Version -Unique)
    if ($available.Count -le 1) { continue }

    Write-Host "Multiple versions of '$name' detected ($($available -join ', ')). Reinstalling to keep a single version..." -ForegroundColor Yellow

    try {
      if (Get-Module -Name $name -ErrorAction SilentlyContinue) {
        Remove-Module -Name $name -Force -ErrorAction Stop
      }
    } catch {
      # ignore
    }

    try {
      Uninstall-Module -Name $name -AllVersions -Force -ErrorAction Stop
    } catch {
      Write-Host "Warning: Uninstall-Module for '$name' did not fully succeed: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    Install-Module -Name $name -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
  }
}

function Import-RequiredModule {
  param(
    [Parameter(Mandatory = $true)]
    [string] $Name
  )

  $m = Get-Module -ListAvailable -Name $Name -ErrorAction SilentlyContinue
  if (-not $m) {
    Write-Host "Installing module '$Name'..." -ForegroundColor Yellow
    Install-Module -Name $Name -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
  }
  Import-Module $Name -ErrorAction Stop
}

function Get-SingleMgApplicationByDisplayName {
  param(
    [Parameter(Mandatory = $true)]
    [string] $DisplayName
  )

  $existingApps = @(Get-MgApplication -Filter "displayName eq '$DisplayName'" -All -ErrorAction Stop)
  if ($existingApps.Count -gt 1) {
    $appList = ($existingApps | Select-Object AppId, Id, CreatedDateTime | Sort-Object CreatedDateTime -Descending | Format-Table -AutoSize | Out-String)
    throw "Multiple app registrations found with displayName '$DisplayName'. Please delete duplicates or target a specific appId. Found:`n$appList"
  }
  if ($existingApps.Count -eq 1) { return $existingApps[0] }
  return $null
}

function Set-AccessAsUserScope {
  param(
    [Parameter(Mandatory = $true)]
    [object] $Application,
    [Parameter(Mandatory = $true)]
    [string] $ScopeValue
  )

  $clientId = $Application.AppId
  $identifierUri = "api://$clientId"
  $needsUpdate = $false

  $identifierUris = @()
  if ($null -ne $Application.IdentifierUris) {
    $identifierUris = @($Application.IdentifierUris)
  }
  if (-not ($identifierUris -contains $identifierUri)) {
    $identifierUris += $identifierUri
    $needsUpdate = $true
  }

  $existingScopes = @()
  if ($null -ne $Application.Api -and $null -ne $Application.Api.Oauth2PermissionScopes) {
    $existingScopes = @($Application.Api.Oauth2PermissionScopes)
  }

  $scopeId = $null
  foreach ($s in $existingScopes) {
    if ($null -ne $s -and $s.Value -eq $ScopeValue) {
      $scopeId = $s.Id
      break
    }
  }

  if (-not $scopeId) {
    $existingScopes += @{
      adminConsentDescription = "Allow the application to access the MCP API on behalf of the signed-in user."
      adminConsentDisplayName = "Access the MCP API as the signed-in user"
      id = ([guid]::NewGuid())
      isEnabled = $true
      type = "User"
      userConsentDescription = "Allow this application to access the MCP API on your behalf."
      userConsentDisplayName = "Access the MCP API on your behalf"
      value = $ScopeValue
    }
    $needsUpdate = $true
  }

  if ($needsUpdate) {
    Update-MgApplication -ApplicationId $Application.Id -IdentifierUris $identifierUris -Api @{ oauth2PermissionScopes = $existingScopes } -ErrorAction Stop
  }

  $appAfter = Get-MgApplication -ApplicationId $Application.Id -ErrorAction Stop
  $scopeIdAfter = $null
  foreach ($s in @($appAfter.Api.Oauth2PermissionScopes)) {
    if ($null -ne $s -and $s.Value -eq $ScopeValue) {
      $scopeIdAfter = $s.Id
      break
    }
  }

  return [pscustomobject]@{
    appId = $clientId
    identifierUri = $identifierUri
    scopeName = $ScopeValue
    scopeUri = "$identifierUri/$ScopeValue"
    scopeId = $scopeIdAfter
  }
}

function Get-GraphDelegatedScopeId {
  param(
    [Parameter(Mandatory = $true)]
    [string] $ScopeValue
  )

  $resp = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '00000003-0000-0000-c000-000000000000'&`$select=id,appId,oauth2PermissionScopes" -ErrorAction Stop
  $sp = $resp.value | Select-Object -First 1
  if ($null -eq $sp) {
    throw "Unable to find Microsoft Graph service principal in this tenant."
  }

  foreach ($s in @($sp.oauth2PermissionScopes)) {
    if ($null -ne $s -and $s.value -eq $ScopeValue) {
      return [Guid]$s.id
    }
  }

  $available = (@($sp.oauth2PermissionScopes) | Where-Object { $_ -and $_.value } | Select-Object -ExpandProperty value | Sort-Object) -join ', '
  throw "Could not find delegated Graph permission '$ScopeValue'. Available include: $available"
}

function Get-ServicePrincipalIdByAppId {
  param(
    [Parameter(Mandatory = $true)]
    [string] $AppId
  )

  $resp = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$AppId'&`$select=id,appId" -ErrorAction Stop
  $sp = $resp.value | Select-Object -First 1
  if ($null -eq $sp) {
    throw "Unable to find service principal for appId '$AppId' in this tenant."
  }
  return [Guid]$sp.id
}

function Grant-DelegatedAdminConsent {
  param(
    [Parameter(Mandatory = $true)]
    [Guid] $ClientServicePrincipalId,
    [Parameter(Mandatory = $true)]
    [Guid] $ResourceServicePrincipalId,
    [Parameter(Mandatory = $true)]
    [string] $ScopeValue
  )

  $filter = "clientId eq '$ClientServicePrincipalId' and resourceId eq '$ResourceServicePrincipalId' and consentType eq 'AllPrincipals'"
  $existing = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=$filter" -ErrorAction Stop

  $grant = $null
  if ($existing.value) {
    $grant = $existing.value | Select-Object -First 1
  }

  if ($null -eq $grant) {
    $body = @{ 
      clientId = "$ClientServicePrincipalId"
      consentType = 'AllPrincipals'
      resourceId = "$ResourceServicePrincipalId"
      scope = $ScopeValue
    }
    $null = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/oauth2PermissionGrants' -Body ($body | ConvertTo-Json) -ContentType 'application/json' -ErrorAction Stop
    return
  }

  $currentScopes = @()
  if ($grant.scope) {
    $currentScopes = @($grant.scope -split ' ' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  }

  if ($currentScopes -contains $ScopeValue) {
    return
  }

  $updatedScopes = @($currentScopes + @($ScopeValue) | Select-Object -Unique)
  $patchBody = @{ scope = ($updatedScopes -join ' ') }
  $null = Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants/$($grant.id)" -Body ($patchBody | ConvertTo-Json) -ContentType 'application/json' -ErrorAction Stop
}

function Set-RequiredResourceAccess {
  param(
    [Parameter(Mandatory = $true)]
    [object] $Application,
    [Parameter(Mandatory = $true)]
    [string] $ResourceAppId,
    [Parameter(Mandatory = $true)]
    [Guid] $AccessId,
    [Parameter(Mandatory = $true)]
    [ValidateSet('Scope', 'Role')]
    [string] $AccessType
  )

  $app = Get-MgApplication -ApplicationId $Application.Id -ErrorAction Stop
  $required = @()
  if ($null -ne $app.RequiredResourceAccess) {
    $required = @($app.RequiredResourceAccess)
  }

  $entry = $required | Where-Object { $_.ResourceAppId -eq $ResourceAppId } | Select-Object -First 1
  if ($null -eq $entry) {
    $entry = [pscustomobject]@{ resourceAppId = $ResourceAppId; resourceAccess = @() }
    $required += $entry
  }

  $resourceAccess = @()
  if ($null -ne $entry.ResourceAccess) {
    $resourceAccess = @($entry.ResourceAccess)
  }

  $already = $false
  foreach ($ra in $resourceAccess) {
    if ($null -ne $ra -and $ra.Id -eq $AccessId -and $ra.Type -eq $AccessType) {
      $already = $true
      break
    }
  }

  if (-not $already) {
    $resourceAccess += @([pscustomobject]@{ id = $AccessId; type = $AccessType })
    $entry.ResourceAccess = $resourceAccess

    $update = @()
    foreach ($r in $required) {
      $update += @{
        resourceAppId = $r.ResourceAppId
        resourceAccess = @($r.ResourceAccess | ForEach-Object { @{ id = $_.Id; type = $_.Type } })
      }
    }

    Update-MgApplication -ApplicationId $Application.Id -RequiredResourceAccess $update -ErrorAction Stop
  }
}

try {
  # Avoid known module mismatch issues
  Repair-EntraModuleVersions -ModuleNames @('Microsoft.Entra', 'Microsoft.Entra.Applications')

  Import-RequiredModule -Name 'Microsoft.Entra'
  Import-RequiredModule -Name 'Microsoft.Graph.Authentication'
  Import-RequiredModule -Name 'Microsoft.Graph.Applications'

  # Admin-consent automation needs DelegatedPermissionGrant.ReadWrite.All.
  $mgScopes = @('Application.ReadWrite.All')
  if ($GrantAdminConsent) {
    $mgScopes += @('DelegatedPermissionGrant.ReadWrite.All')
  }

  Connect-Entra -Scopes 'Application.ReadWrite.All' -NoWelcome
  Connect-MgGraph -Scopes $mgScopes -NoWelcome -ErrorAction Stop

  $tenantId = "$( (Get-EntraTenantDetail).Id )"

  $serverApp = Get-SingleMgApplicationByDisplayName -DisplayName $ServerAppName
  if ($null -eq $serverApp) {
    Write-Host "Creating server/API app '$ServerAppName'..." -ForegroundColor Cyan
    $created = New-EntraApplication -DisplayName $ServerAppName

    # Wait for Graph read-after-write consistency
    $serverApp = $null
    for ($i = 0; $i -lt 10 -and $null -eq $serverApp; $i++) {
      $serverApp = Get-MgApplication -Filter "appId eq '$($created.AppId)'" -Top 1 -ErrorAction Stop
      if ($null -eq $serverApp) { Start-Sleep -Seconds 2 }
    }
    if ($null -eq $serverApp) {
      throw "Created server app was not found in Microsoft Graph in time (appId: $($created.AppId))."
    }

    $null = New-EntraServicePrincipal -AppId $created.AppId
  } else {
    Write-Host "Found existing server/API app '$ServerAppName' (appId=$($serverApp.AppId))" -ForegroundColor Green
  }

  $scopeInfo = Set-AccessAsUserScope -Application $serverApp -ScopeValue $AccessAsUserScopeName

  $graphScopeId = Get-GraphDelegatedScopeId -ScopeValue $GraphDelegatedPermission
  Set-RequiredResourceAccess -Application $serverApp -ResourceAppId '00000003-0000-0000-c000-000000000000' -AccessId $graphScopeId -AccessType 'Scope'

  if ($GrantAdminConsent) {
    Write-Host "Granting admin consent for Graph delegated permission '$GraphDelegatedPermission'..." -ForegroundColor Cyan
    $serverSpId = Get-ServicePrincipalIdByAppId -AppId $serverApp.AppId
    $graphSpId = Get-ServicePrincipalIdByAppId -AppId '00000003-0000-0000-c000-000000000000'
    Grant-DelegatedAdminConsent -ClientServicePrincipalId $serverSpId -ResourceServicePrincipalId $graphSpId -ScopeValue $GraphDelegatedPermission
  }

  $secretText = $null
  if ($CreateSecret) {
    $secret = New-EntraApplicationPasswordCredential -ApplicationId $serverApp.Id -CustomKeyIdentifier "${ServerAppName}-secret" -EndDate (Get-Date).AddYears($SecretYears)
    $secretText = $secret.SecretText
  }

  $out = [ordered]@{
    tenantId = $tenantId
    server = [ordered]@{
      appName = $ServerAppName
      appId = $serverApp.AppId
      identifierUri = $scopeInfo.identifierUri
      accessAsUserScope = $scopeInfo.scopeUri
      graphDelegatedPermission = $GraphDelegatedPermission
      adminConsentGranted = [bool]$GrantAdminConsent
      clientSecret = $secretText
      notes = @(
        'Grant admin consent for the Graph delegated permission in the Entra portal (or via -GrantAdminConsent).',
        'Prefer certificate auth for production OBO (Key Vault + managed identity).' 
      )
    }
  }

  Write-Output ($out | ConvertTo-Json -Depth 6)
  exit 0
}
catch {
  Write-Error "Script failed: $($_.Exception.Message)"
  exit 1
}
