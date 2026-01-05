<#
.SYNOPSIS
Creates or updates a client app registration that can request MCP API tokens.

.DESCRIPTION
This script creates (or updates) a Microsoft Entra ID app registration for an MCP client (Teams OAuth app, VS Code extension,
local tooling like Bruno, etc.).

It configures:
- Redirect URIs (web and/or public client)
- Public client settings (recommended for local tooling: auth code + PKCE, no secret)
- Delegated permission to the server/API app's scope: api://<serverAppId>/access_as_user

The client app does NOT need Microsoft Graph permissions for the OBO pattern; only the server/API app needs Graph delegated permissions.

The script outputs a single JSON object to stdout with the created/updated IDs and the optional secret.

.PARAMETER ClientAppName
Display name for the client app registration.

.PARAMETER ServerAppId
Application (client) ID of the server/API app registration. This must match the server's GRAPH_CLIENT_ID.

.PARAMETER AccessAsUserScopeName
Scope name exposed by the server/API app (default: access_as_user).

.PARAMETER WebRedirectUris
Redirect URIs for web clients (default includes Teams OAuth redirect).

.PARAMETER PublicRedirectUris
Redirect URIs for public clients (default includes localhost examples).

.PARAMETER IsPublicClient
If true (default), configures the app as a public client (recommended for local tooling). If false, you may also set -CreateSecret.

.PARAMETER CreateSecret
If set and IsPublicClient is false, creates a client secret and returns it in the JSON output.

.PARAMETER SecretYears
Client secret lifetime in years (default: 1).

.EXAMPLE
# Create a public client app for local tooling (Bruno/postman-style) and localhost redirects
pwsh -NoProfile -File .\scripts\CreateClientAppRegMCP.ps1 -ServerAppId '<serverAppId-guid>'

.EXAMPLE
# Create a Teams OAuth client app (web redirect) and a public client redirect
pwsh -NoProfile -File .\scripts\CreateClientAppRegMCP.ps1 -ServerAppId '<serverAppId-guid>' \
  -WebRedirectUris 'https://teams.microsoft.com/api/platform/v1.0/oAuthRedirect' \
  -PublicRedirectUris 'http://localhost:3000/callback'

.OUTPUTS
Writes JSON to stdout. Use client.appId when configuring your client OAuth settings.
#>

[CmdletBinding()]
param(
  # Display name for the client app registration.
  [string]$ClientAppName = 'MessageCenterAgent-mcp-client',

  # The server/API app registration appId (GUID). This is the audience your MCP server expects.
  [Parameter(Mandatory = $true)]
  [string]$ServerAppId,

  # Scope name exposed by the server/API app.
  [string]$AccessAsUserScopeName = 'access_as_user',

  # Redirect URIs for common clients.
  [uri[]]$WebRedirectUris = @(
    'https://teams.microsoft.com/api/platform/v1.0/oAuthRedirect'
  ),
  [uri[]]$PublicRedirectUris = @(
    'http://localhost:3000/callback',
    'http://localhost:8082/'
  ),

  # Whether this is a public client (recommended for Bruno/local tooling).
  [bool]$IsPublicClient = $true,

  # If IsPublicClient is false, optionally create a client secret.
  [switch]$CreateSecret,
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

function Get-ServerAccessAsUserScopeId {
  param(
    [Parameter(Mandatory = $true)]
    [object] $ServerApplication,
    [Parameter(Mandatory = $true)]
    [string] $ScopeValue
  )

  # We only need the scopeId to grant the client permission.
  $server = Get-MgApplication -ApplicationId $ServerApplication.Id -ErrorAction Stop
  $scopeId = $null
  if ($null -ne $server.Api -and $null -ne $server.Api.Oauth2PermissionScopes) {
    foreach ($s in @($server.Api.Oauth2PermissionScopes)) {
      if ($null -ne $s -and $s.Value -eq $ScopeValue) {
        $scopeId = $s.Id
        break
      }
    }
  }

  if (-not $scopeId) {
    throw "Server/API app does not expose delegated scope '$ScopeValue'. Create it on the server app first."
  }

  return [Guid]$scopeId
}

function Set-ClientRedirectUris {
  param(
    [Parameter(Mandatory = $true)]
    [object] $Application,
    [uri[]] $WebUris,
    [uri[]] $PublicUris,
    [bool] $PublicClient
  )

  $app = Get-MgApplication -ApplicationId $Application.Id -ErrorAction Stop

  if ($WebUris -and $WebUris.Count -gt 0) {
    $existingWeb = @()
    if ($null -ne $app.Web -and $null -ne $app.Web.RedirectUris) {
      $existingWeb = @($app.Web.RedirectUris)
    }
    $merged = @($existingWeb)
    foreach ($u in $WebUris) {
      $uriText = $u.AbsoluteUri
      if (-not ($merged -contains $uriText)) { $merged += $uriText }
    }
    if ($merged.Count -ne $existingWeb.Count) {
      Update-MgApplication -ApplicationId $Application.Id -Web @{ redirectUris = $merged } -ErrorAction Stop
    }
  }

  if ($PublicClient -and $PublicUris -and $PublicUris.Count -gt 0) {
    $existingPub = @()
    if ($null -ne $app.PublicClient -and $null -ne $app.PublicClient.RedirectUris) {
      $existingPub = @($app.PublicClient.RedirectUris)
    }
    $merged = @($existingPub)
    foreach ($u in $PublicUris) {
      $uriText = $u.AbsoluteUri
      if (-not ($merged -contains $uriText)) { $merged += $uriText }
    }
    if ($merged.Count -ne $existingPub.Count) {
      Update-MgApplication -ApplicationId $Application.Id -PublicClient @{ redirectUris = $merged } -ErrorAction Stop
    }

    # Mark as fallback public client so tools can use auth code + PKCE without a secret.
    Set-EntraApplication -ApplicationId $Application.Id -IsFallbackPublicClient $true -ErrorAction Stop
  }
}

try {
  Repair-EntraModuleVersions -ModuleNames @('Microsoft.Entra', 'Microsoft.Entra.Applications')

  Import-RequiredModule -Name 'Microsoft.Entra'
  Import-RequiredModule -Name 'Microsoft.Graph.Authentication'
  Import-RequiredModule -Name 'Microsoft.Graph.Applications'

  Connect-Entra -Scopes 'Application.ReadWrite.All' -NoWelcome
  Connect-MgGraph -Scopes 'Application.ReadWrite.All' -NoWelcome -ErrorAction Stop

  $tenantId = "$( (Get-EntraTenantDetail).Id )"

  $serverApp = Get-MgApplication -Filter "appId eq '$ServerAppId'" -Top 1 -ErrorAction Stop
  if ($null -eq $serverApp) {
    throw "Could not find server/API app registration with appId '$ServerAppId'."
  }

  $scopeId = Get-ServerAccessAsUserScopeId -ServerApplication $serverApp -ScopeValue $AccessAsUserScopeName

  $clientApp = Get-SingleMgApplicationByDisplayName -DisplayName $ClientAppName
  if ($null -eq $clientApp) {
    Write-Host "Creating client app '$ClientAppName'..." -ForegroundColor Cyan
    $created = New-EntraApplication -DisplayName $ClientAppName

    $clientApp = $null
    for ($i = 0; $i -lt 10 -and $null -eq $clientApp; $i++) {
      $clientApp = Get-MgApplication -Filter "appId eq '$($created.AppId)'" -Top 1 -ErrorAction Stop
      if ($null -eq $clientApp) { Start-Sleep -Seconds 2 }
    }
    if ($null -eq $clientApp) {
      throw "Created client app was not found in Microsoft Graph in time (appId: $($created.AppId))."
    }

    $null = New-EntraServicePrincipal -AppId $created.AppId
  } else {
    Write-Host "Found existing client app '$ClientAppName' (appId=$($clientApp.AppId))" -ForegroundColor Green
  }

  Set-ClientRedirectUris -Application $clientApp -WebUris $WebRedirectUris -PublicUris $PublicRedirectUris -PublicClient:$IsPublicClient

  # Grant delegated permission to server API scope
  Set-RequiredResourceAccess -Application $clientApp -ResourceAppId $ServerAppId -AccessId $scopeId -AccessType 'Scope'

  $secretText = $null
  if (-not $IsPublicClient -and $CreateSecret) {
    $secret = New-EntraApplicationPasswordCredential -ApplicationId $clientApp.Id -CustomKeyIdentifier "${ClientAppName}-secret" -EndDate (Get-Date).AddYears($SecretYears)
    $secretText = $secret.SecretText
  }

  $out = [ordered]@{
    tenantId = $tenantId
    client = [ordered]@{
      appName = $ClientAppName
      appId = $clientApp.AppId
      isPublicClient = $IsPublicClient
      webRedirectUris = @($WebRedirectUris | ForEach-Object { $_.AbsoluteUri })
      publicRedirectUris = @($PublicRedirectUris | ForEach-Object { $_.AbsoluteUri })
      serverApiScope = "api://$ServerAppId/$AccessAsUserScopeName"
      clientSecret = $secretText
      notes = @(
        'Client app does not need Microsoft Graph permissions for the OBO pattern.',
        'If using a public client, do not use a client secret; use auth code + PKCE.'
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
