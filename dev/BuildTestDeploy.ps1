<#[
.SYNOPSIS
Builds, publishes (ACR), and deploys the Message Center MCP server to Azure Container Apps.

.DESCRIPTION
This script can:
- Optionally bump/set the npm package version (without creating git tags)
- Optionally run a local build + smoke test (builds a Docker image, runs a local container, checks /healthz; can also run MCP smoke if a token is available)
- Build + push the container image using Azure Container Registry remote build ("az acr build")
- Deploy the new image to an Azure Container App
- Optionally wait for https://<fqdn>/healthz and/or validate POST /mcp via a tools/list call

.PARAMETER AcrName
Azure Container Registry resource name (not login server). Example: acrmcpmessagesroadmap

.PARAMETER ResourceGroupName
Azure resource group containing the ACR and the Container App.

.PARAMETER ContainerAppName
Azure Container App name to update.

.PARAMETER SkipLocalTest
Skips local build/smoke (useful for CI or when you only want ACR build + deploy).

.PARAMETER WaitForHealth
After deploy, polls https://<fqdn>/healthz until 200 or timeout.

.PARAMETER TestMcp
After deploy, POSTs a JSON-RPC tools/list request to https://<fqdn>/mcp.

.PARAMETER WhatIf
Shows what would happen without actually running ACR build or deploy.

.PARAMETER ProvisionInfra
If set, provisions/updates Azure resources with Bicep before building/deploying:
- infra/acr.bicep (creates/updates the ACR)
- infra/main.bicep (creates/updates the Container App and dependencies)
The Bicep deployment overrides messageCenterImage with the image built by this script.

.PARAMETER UseLocalDockerForAcr
If set, builds the image locally with Docker and pushes it to ACR using `docker push`.
Default behavior (when not set) uses `az acr build` (remote build) to build+push to ACR.

.EXAMPLE
# Safe local-only validation (no Azure calls):
pwsh -NoProfile -File .\mcp-message-center-server\dev\BuildTestDeploy.ps1 -AcrName acrmcpmessagesroadmap -SkipLocalTest -SkipAcrBuild -SkipDeploy

.EXAMPLE
# ACR build + deploy, then wait for health and validate /mcp:
pwsh -NoProfile -File .\mcp-message-center-server\dev\BuildTestDeploy.ps1 -AcrName acrmcpmessagesroadmap -WaitForHealth -TestMcp

.EXAMPLE
# Preview actions (no ACR build / deploy), still computes tag:
pwsh -NoProfile -File .\mcp-message-center-server\dev\BuildTestDeploy.ps1 -AcrName acrmcpmessagesroadmap -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
  # Versioning
  [Parameter(Mandatory = $false)]
  [ValidateSet('patch', 'minor', 'major', 'none')]
  [string] $BumpVersion = 'none',

  [Parameter(Mandatory = $false)]
  [string] $Version,

  # Image tag override. If not provided, computed from version + git SHA.
  [Parameter(Mandatory = $false)]
  [string] $Tag,

  # Azure settings
  [Parameter(Mandatory = $false)]
  [string] $SubscriptionId,

  [Parameter(Mandatory = $false)]
  [string] $ResourceGroupName,

  [Parameter(Mandatory = $false)]
  [string] $ContainerAppName,

  # Optional: provision infra before build/deploy
  [Parameter(Mandatory = $false)]
  [switch] $ProvisionInfra,

  # IaC paths (relative to repo root)
  [Parameter(Mandatory = $false)]
  [string] $AcrBicepFile = 'infra/acr.bicep',

  [Parameter(Mandatory = $false)]
  [string] $MainBicepFile = 'infra/main.bicep',

  [Parameter(Mandatory = $false)]
  [string] $MainParametersFile = 'infra/main.parameters.json',

  # ACR name (not login server). Example: acrmcpmessagesroadmapwu
  [Parameter(Mandatory = $true)]
  [string] $AcrName,

  # Local build/test settings
  [Parameter(Mandatory = $false)]
  [int] $LocalPort = 8080,

  # Optional: bearer token for local smoke test (api://<clientId>/access_as_user).
  # If not provided, the script will try to acquire one via scripts/GetMcpAccessToken.ps1.
  [Parameter(Mandatory = $false)]
  [string] $McpAccessToken,

  [Parameter(Mandatory = $false)]
  [switch] $SkipLocalTest,

  [Parameter(Mandatory = $false)]
  [switch] $SkipAcrBuild,

  # If set, use local Docker build + docker push (instead of az acr build).
  [Parameter(Mandatory = $false)]
  [switch] $UseLocalDockerForAcr,

  [Parameter(Mandatory = $false)]
  [switch] $SkipDeploy,

  # Optional: after deploy, poll https://<fqdn>/healthz until it returns 200
  [Parameter(Mandatory = $false)]
  [switch] $WaitForHealth,

  [Parameter(Mandatory = $false)]
  [int] $HealthTimeoutSeconds = 180,

  # Optional: after deploy, POST /mcp with a tools/list request to validate the MCP endpoint is reachable.
  [Parameter(Mandatory = $false)]
  [switch] $TestMcp,

  [Parameter(Mandatory = $false)]
  [int] $McpTimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Command([string]$Name, [string]$Hint) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Missing required command '$Name'. $Hint"
  }
}

function Invoke-Az([string[]]$AzArgs) {
  $output = & az @AzArgs 2>&1
  $exit = $LASTEXITCODE

  # Do NOT use Out-String here; it wraps long lines and can corrupt tokens/values.
  $text = ''
  if ($null -ne $output) {
    if ($output -is [System.Array]) {
      $text = ($output | ForEach-Object { [string]$_ }) -join "`n"
    } else {
      $text = [string]$output
    }
  }

  if ($exit -ne 0) {
    throw "Azure CLI command failed (exit $exit): az $($AzArgs -join ' ')`n$text"
  }

  return $text.Trim()
}

function Get-RepoRoot {
  $here = Split-Path -Parent $PSCommandPath
  return (Resolve-Path (Join-Path $here '..')).Path
}

function New-DeploymentName([string]$Prefix) {
  return "$Prefix-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
}

function Read-ArmParameters([string]$Path) {
  if (-not (Test-Path -Path $Path)) {
    throw "Parameters file not found: $Path"
  }
  $raw = Get-Content -Raw -Path $Path
  return ($raw | ConvertFrom-Json -Depth 50)
}

function Get-BuildContext([string]$ServerRoot) {
  # The Dockerfile currently expects monorepo-relative COPY paths like:
  #   COPY mcp-message-center-server/src ./src
  # So for the monorepo, the build context must be the monorepo root and -f must be the server Dockerfile path.
  $serverName = Split-Path -Leaf $ServerRoot
  $monorepoRoot = (Resolve-Path (Join-Path $ServerRoot '..')).Path

  $monorepoDockerfile = Join-Path $monorepoRoot "$serverName\Dockerfile"
  if (Test-Path -LiteralPath $monorepoDockerfile) {
    return [pscustomobject]@{
      ContextDir = $monorepoRoot
      DockerfileRelativePath = "$serverName/Dockerfile"
    }
  }

  # Fallback: standalone repo layout (context is server root)
  $standaloneDockerfile = Join-Path $ServerRoot 'Dockerfile'
  if (Test-Path -LiteralPath $standaloneDockerfile) {
    return [pscustomobject]@{
      ContextDir = $ServerRoot
      DockerfileRelativePath = 'Dockerfile'
    }
  }

  throw "Could not find a Dockerfile for build context. Expected either '$monorepoDockerfile' or '$standaloneDockerfile'."
}

function Build-LocalDockerImage([string]$RepoRoot, [string]$TagValue) {
  Assert-Command 'docker' 'Install Docker Desktop and ensure the docker CLI is on PATH.'

  $build = Get-BuildContext -ServerRoot $RepoRoot
  $localImage = "mcp-message-center-server-local:$TagValue"

  Push-Location $build.ContextDir
  try {
    Write-Host "Building Docker image: $localImage"
    # Stream docker output to the host, but do not emit it as function output.
    & docker build -t $localImage -f $build.DockerfileRelativePath . 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'docker build failed' }
  } finally {
    Pop-Location
  }

  return [string]$localImage
}

function ConvertTo-DockerTag([string]$Value) {
  # Docker tags must match: [A-Za-z0-9_][A-Za-z0-9_.-]{0,127}
  $v = $Value.Trim()
  $v = $v -replace '[^A-Za-z0-9_.-]', '-'
  $v = $v.Trim('-')
  if ([string]::IsNullOrWhiteSpace($v)) {
    throw "Computed image tag is empty."
  }
  if ($v.Length -gt 128) {
    $v = $v.Substring(0, 128)
  }
  return $v
}

function Get-GitShortSha([string]$RepoRoot) {
  try {
    $sha = & git -C $RepoRoot rev-parse --short HEAD 2>$null
    if ($LASTEXITCODE -eq 0) { return ($sha | ForEach-Object { [string]$_ }).Trim() }
  } catch { }
  return "nogit"
}

function Read-PackageJsonVersion([string]$PackageJsonPath) {
  $pkg = Get-Content -Raw -LiteralPath $PackageJsonPath | ConvertFrom-Json
  return [string]$pkg.version
}

function Get-NowStamp {
  return (Get-Date).ToString('HH:mm:ss')
}

function Write-Log([string]$Message) {
  Write-Host "[$(Get-NowStamp)] $Message"
}

function Write-Section([string]$Title) {
  Write-Host ''
  Write-Host "=== $Title ===" -ForegroundColor Cyan
  Write-Host "[$(Get-NowStamp)]" -ForegroundColor DarkGray
}

function Require-Param([string]$Name, [string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) {
    throw "Missing required parameter: -$Name"
  }
  return $Value
}

function Invoke-AzStreaming([string[]]$AzArgs) {
  Write-Log "az $($AzArgs -join ' ')"
  $start = Get-Date

  & az @AzArgs 2>&1 | Out-Host
  $exit = $LASTEXITCODE

  $elapsed = [Math]::Round(((Get-Date) - $start).TotalSeconds, 1)
  if ($exit -ne 0) {
    throw "Azure CLI command failed (exit $exit) after ${elapsed}s: az $($AzArgs -join ' ')"
  }

  Write-Log "Completed in ${elapsed}s"
}

function Get-AzDeploymentProvisioningState([string]$ResourceGroup, [string]$DeploymentName) {
  $raw = Invoke-Az @(
    'deployment', 'group', 'show',
    '-g', $ResourceGroup,
    '-n', $DeploymentName,
    '--query', 'properties.provisioningState',
    '-o', 'tsv',
    '--only-show-errors'
  )
  return ($raw -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1).Trim()
}

function Get-AzDeploymentLatestOperationSummary([string]$ResourceGroup, [string]$DeploymentName) {
  # Best-effort: deployment may not have any operations yet.
  try {
    $json = Invoke-Az @(
      'deployment', 'operation', 'group', 'list',
      '-g', $ResourceGroup,
      '-n', $DeploymentName,
      '--query', "sort_by([].{t:properties.timestamp,state:properties.provisioningState,op:properties.provisioningOperation,rt:properties.targetResource.resourceType,rn:properties.targetResource.resourceName}, &t)[-1]",
      '-o', 'json',
      '--only-show-errors'
    )
    if ([string]::IsNullOrWhiteSpace($json)) { return $null }
    return ($json | ConvertFrom-Json -Depth 10)
  } catch {
    return $null
  }
}

function Wait-AzDeploymentGroup([string]$ResourceGroup, [string]$DeploymentName, [int]$TimeoutSeconds = 1800) {
  $start = Get-Date
  $deadline = $start.AddSeconds($TimeoutSeconds)
  $lastOpPrintedAt = [datetime]::MinValue

  while ((Get-Date) -lt $deadline) {
    $state = Get-AzDeploymentProvisioningState -ResourceGroup $ResourceGroup -DeploymentName $DeploymentName
    $elapsed = (Get-Date) - $start
    Write-Log "Deployment '$DeploymentName' state: $state (elapsed $([int]$elapsed.TotalMinutes)m$([int]$elapsed.Seconds)s)"

    # Print the latest operation summary at most every ~20s.
    if (((Get-Date) - $lastOpPrintedAt).TotalSeconds -ge 20) {
      $op = Get-AzDeploymentLatestOperationSummary -ResourceGroup $ResourceGroup -DeploymentName $DeploymentName
      if ($op) {
        Write-Log "Latest op: $($op.op) $($op.rt)/$($op.rn) => $($op.state)"
      }
      $lastOpPrintedAt = Get-Date
    }

    if ($state -eq 'Succeeded') {
      return
    }

    if ($state -eq 'Failed') {
      $err = Invoke-Az @(
        'deployment', 'group', 'show',
        '-g', $ResourceGroup,
        '-n', $DeploymentName,
        '--query', 'properties.error',
        '-o', 'jsonc',
        '--only-show-errors'
      )
      throw "Deployment '$DeploymentName' failed. Error: $err"
    }

    Start-Sleep -Seconds 5
  }

  throw "Timed out waiting for deployment '$DeploymentName' after ${TimeoutSeconds}s"
}

function Start-AzDeploymentGroupNoWait([string]$ResourceGroup, [string]$DeploymentName, [string]$TemplateFile, [string[]]$ParameterArgs) {
  $args = @(
    'deployment', 'group', 'create',
    '-g', $ResourceGroup,
    '-n', $DeploymentName,
    '-f', $TemplateFile
  ) + $ParameterArgs + @(
    '--no-wait',
    '--only-show-errors',
    '-o', 'none'
  )

  Write-Log "Starting deployment '$DeploymentName' (no-wait)"
  $null = Invoke-Az $args
}

function Start-LocalServerAndSmoke([string]$RepoRoot, [int]$Port) {
  Write-Section "Local build + smoke"

  Assert-Command 'docker' 'Install Docker Desktop and ensure the docker CLI is on PATH.'

  if ($WhatIfPreference) {
    Write-Host 'Skipping local Docker build/run (-WhatIf).'
    return
  }

  $localImage = Build-LocalDockerImage -RepoRoot $RepoRoot -TagValue $Tag
  $script:LocalDockerImage = $localImage
  $containerName = "mc-local-$PID"

  $started = $false
  try {
    Write-Host "Starting container '$containerName' on http://localhost:$Port ..."
    # Internal container port is 8080 for this app; map it to the requested local port.
    & docker run --rm -d --name $containerName -p "${Port}:8080" -e PORT=8080 $localImage | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'docker run failed' }
    $started = $true

    $deadline = (Get-Date).AddSeconds(30)
    $healthUrl = "http://localhost:$Port/healthz"
    do {
      Start-Sleep -Milliseconds 500
      try {
        $resp = Invoke-WebRequest -Uri $healthUrl -Method GET -TimeoutSec 5 -SkipHttpErrorCheck
        if ($resp.StatusCode -eq 200) { break }
      } catch {
        # ignore until deadline
      }
    } while ((Get-Date) -lt $deadline)

    if ((Get-Date) -ge $deadline) {
      throw "Timed out waiting for $healthUrl"
    }

    # Optional MCP smoke (tools/list)
    $token = $script:McpAccessToken

    if (-not $token) {
      # Best-effort: try to acquire a token using the existing helper script.
      # This requires az login + GRAPH_CLIENT_ID in env/.env.local.
      $tokenScript = Join-Path $RepoRoot 'scripts\GetMcpAccessToken.ps1'
      if (Test-Path -LiteralPath $tokenScript) {
        try {
          & az account show --only-show-errors | Out-Null
          if ($LASTEXITCODE -eq 0) {
            $token = (& pwsh -NoProfile -File $tokenScript) | Select-Object -Last 1
          }
        } catch {
          # ignore
        }
      }
    }

    if ($token) {
      Write-Host 'Testing local MCP endpoint: POST /mcp (tools/list)'
      $body = @{ jsonrpc = '2.0'; id = 1; method = 'tools/list'; params = @{} } | ConvertTo-Json -Depth 10
      $resp = Invoke-WebRequest -Method Post -Uri "http://localhost:$Port/mcp" -ContentType 'application/json' -Headers @{ Authorization = "Bearer $token"; Accept = 'application/json, text/event-stream' } -Body $body -TimeoutSec $McpTimeoutSeconds -SkipHttpErrorCheck
      if ($resp.StatusCode -lt 200 -or $resp.StatusCode -ge 300) {
        throw "Local MCP smoke failed ($($resp.StatusCode)): $([string]$resp.Content)"
      }
      Write-Host 'Local MCP smoke succeeded.' -ForegroundColor Green
    } else {
      Write-Host 'Skipping local MCP smoke: no access token available.' -ForegroundColor Yellow
      Write-Host 'Provide -McpAccessToken, or set GRAPH_CLIENT_ID and run `az login` so the script can acquire one.'
    }

    Write-Host 'Local health check OK.' -ForegroundColor Green
  } catch {
    if ($started) {
      Write-Host ''
      Write-Host 'Docker logs (last 200 lines):' -ForegroundColor Yellow
      try { & docker logs --tail 200 $containerName 2>$null } catch { }
    }
    throw
  } finally {
    if ($started) {
      Write-Host "Stopping container '$containerName'..."
      try { & docker rm -f $containerName 2>$null | Out-Null } catch { }
    }
  }
}

# npm is only required when bumping/setting the package version.
if ($BumpVersion -ne 'none' -or $Version) {
  Assert-Command 'npm' 'Install Node.js (>= 20) and npm.'
}
Assert-Command 'az' 'Install Azure CLI: https://learn.microsoft.com/cli/azure/install-azure-cli'

$repoRoot = Get-RepoRoot
$packageJsonPath = Join-Path $repoRoot 'package.json'

if (-not (Test-Path -LiteralPath $packageJsonPath)) {
  throw "Expected file not found: $packageJsonPath"
}

Write-Section 'Version + tag'

# Optionally bump/set npm version
if ($BumpVersion -ne 'none' -or $Version) {
  Push-Location $repoRoot
  try {
    if ($Version) {
      Write-Host "Setting npm package version to $Version (no git tag)..."
      & npm version $Version --no-git-tag-version
      if ($LASTEXITCODE -ne 0) { throw 'npm version failed' }
    } elseif ($BumpVersion -ne 'none') {
      Write-Host "Bumping npm package version ($BumpVersion) (no git tag)..."
      & npm version $BumpVersion --no-git-tag-version
      if ($LASTEXITCODE -ne 0) { throw 'npm version failed' }
    }
  } finally {
    Pop-Location
  }
}

$currentVersion = Read-PackageJsonVersion -PackageJsonPath $packageJsonPath
$gitSha = Get-GitShortSha -RepoRoot $repoRoot

if (-not $Tag) {
  $Tag = ConvertTo-DockerTag -Value "$currentVersion-$gitSha"
} else {
  $Tag = ConvertTo-DockerTag -Value $Tag
}

Write-Host "Package version: $currentVersion"
Write-Host "Image tag:       $Tag"

if (-not $SkipLocalTest) {
  Start-LocalServerAndSmoke -RepoRoot $repoRoot -Port $LocalPort
} else {
  Write-Section 'Local build + smoke'
  Write-Host 'Skipping local test (-SkipLocalTest).'
}

$imageTag = "mcp-message-center-server:$Tag"
$imageRef = $null

$script:LocalDockerImage = $null

$acrBicepPath = $null
$mainBicepPath = $null
$mainParametersPath = $null
$expectedContainerAppName = $ContainerAppName

if ($ProvisionInfra) {
  $acrBicepPath = (Resolve-Path (Join-Path $repoRoot $AcrBicepFile)).Path
  $mainBicepPath = (Resolve-Path (Join-Path $repoRoot $MainBicepFile)).Path
  $mainParametersPath = (Resolve-Path (Join-Path $repoRoot $MainParametersFile)).Path

  $armParams = Read-ArmParameters -Path $mainParametersPath
  $namePrefix = $armParams.parameters.namePrefix.value
  if (-not $namePrefix) {
    throw "Could not read parameters.namePrefix.value from $mainParametersPath"
  }
  $expectedContainerAppName = "$namePrefix-mcp-mc"

  if ($ContainerAppName -ne $expectedContainerAppName) {
    Write-Warning "-ContainerAppName '$ContainerAppName' does not match namePrefix '$namePrefix' from $MainParametersFile. Using '$expectedContainerAppName' for health/MCP checks."
  }
}

if (-not $SkipAcrBuild -or -not $SkipDeploy) {
  Write-Section 'Azure login'

  # Fail fast on common missing parameters.
  $ResourceGroupName = Require-Param 'ResourceGroupName' $ResourceGroupName
  if (-not $SkipDeploy) {
    $ContainerAppName = Require-Param 'ContainerAppName' $ContainerAppName
  }

  # Ensure az login
  try {
    $null = Invoke-Az @('account', 'show', '--only-show-errors')
  } catch {
    throw 'Not logged into Azure CLI. Run: az login'
  }

  if ($SubscriptionId) {
    Write-Host "Setting subscription: $SubscriptionId"
    $null = Invoke-Az @('account', 'set', '--subscription', $SubscriptionId, '--only-show-errors')
  }

  if ($ProvisionInfra) {
    Write-Section 'Provision infrastructure (Bicep)'

    # Validate resource group exists (we intentionally do not auto-create it).
    try {
      $null = Invoke-Az @('group', 'show', '-n', $ResourceGroupName, '--only-show-errors')
    } catch {
      throw "Resource group '$ResourceGroupName' not found. Create it first (example): az group create -n $ResourceGroupName -l <location>"
    }

    $acrDeploymentName = New-DeploymentName -Prefix 'acr'
    if ($PSCmdlet.ShouldProcess($ResourceGroupName, "Deploy ACR (az deployment group create -n $acrDeploymentName -f $AcrBicepFile)")) {
      Start-AzDeploymentGroupNoWait -ResourceGroup $ResourceGroupName -DeploymentName $acrDeploymentName -TemplateFile $acrBicepPath -ParameterArgs @(
        '-p', "acrName=$AcrName"
      )
      Wait-AzDeploymentGroup -ResourceGroup $ResourceGroupName -DeploymentName $acrDeploymentName -TimeoutSeconds 900
    }
  }

  $rawLoginServer = Invoke-Az @('acr', 'show', '-n', $AcrName, '-g', $ResourceGroupName, '--query', 'loginServer', '-o', 'tsv', '--only-show-errors')
  $loginServer = ($rawLoginServer -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1).Trim()
  $imageRef = "$loginServer/$imageTag"

  Write-Host "ACR login server: $loginServer"
  Write-Host "Image ref:        $imageRef"
} else {
  Write-Section 'Azure login'
  Write-Host 'Skipping Azure/ACR lookup (-SkipAcrBuild and -SkipDeploy).'
  $imageRef = "<skipped>/$imageTag"
}

if (-not $SkipAcrBuild) {
  Write-Section 'Build + push image (ACR build)'

  if ($UseLocalDockerForAcr) {
    Assert-Command 'docker' 'Install Docker Desktop and ensure the docker CLI is on PATH.'

    if ($PSCmdlet.ShouldProcess($AcrName, "docker build + docker push $imageRef")) {
      if (-not $script:LocalDockerImage) {
        Write-Host 'Local Docker image not built yet; building now for ACR push...'
        $script:LocalDockerImage = Build-LocalDockerImage -RepoRoot $repoRoot -TagValue $Tag
      }

      # Login docker to ACR (requires AcrPush permissions for the current az identity).
      $null = Invoke-Az @('acr', 'login', '-n', $AcrName, '-g', $ResourceGroupName, '--only-show-errors')

      Write-Host "Tagging: $($script:LocalDockerImage) -> $imageRef"
      & docker tag $script:LocalDockerImage $imageRef
      if ($LASTEXITCODE -ne 0) { throw 'docker tag failed' }

      Write-Host "Pushing: $imageRef"
      & docker push $imageRef
      if ($LASTEXITCODE -ne 0) { throw 'docker push failed' }
    }
  } else {
    if ($PSCmdlet.ShouldProcess($AcrName, "az acr build -t $imageTag")) {
      $build = Get-BuildContext -ServerRoot $repoRoot
      Push-Location $build.ContextDir
      try {
        # Uses ACR build so Docker is not required locally.
        Invoke-AzStreaming @(
          'acr', 'build',
          '-r', $AcrName,
          '-t', $imageTag,
          '-f', $build.DockerfileRelativePath,
          '.'
        )
      } finally {
        Pop-Location
      }
    }
  }
} else {
  Write-Section 'Build + push image (ACR build)'
  Write-Host 'Skipping ACR build (-SkipAcrBuild).'
}

if (-not $SkipDeploy) {
  Write-Section 'Deploy to Azure Container Apps'

  if ($ProvisionInfra) {
    $mainDeploymentName = New-DeploymentName -Prefix 'main'
    if ($PSCmdlet.ShouldProcess($ResourceGroupName, "Deploy infra (az deployment group create -n $mainDeploymentName -f $MainBicepFile)")) {
      Start-AzDeploymentGroupNoWait -ResourceGroup $ResourceGroupName -DeploymentName $mainDeploymentName -TemplateFile $mainBicepPath -ParameterArgs @(
        '-p', $mainParametersPath,
        "messageCenterImage=$imageRef"
      )
      Wait-AzDeploymentGroup -ResourceGroup $ResourceGroupName -DeploymentName $mainDeploymentName -TimeoutSeconds 1800
    }
  } else {
    if ($PSCmdlet.ShouldProcess($ContainerAppName, "az containerapp update --image $imageRef")) {
      $null = Invoke-Az @(
        'containerapp', 'update',
        '-g', $ResourceGroupName,
        '-n', $ContainerAppName,
        '--image', $imageRef,
        '--only-show-errors'
      )
    }
  }

  if ($WhatIfPreference) {
    Write-Host 'Skipping FQDN/health/MCP checks (-WhatIf).'
    $rawFqdn = ''
  } else {
    $rawFqdn = Invoke-Az @('containerapp', 'show', '-g', $ResourceGroupName, '-n', $expectedContainerAppName, '--query', 'properties.configuration.ingress.fqdn', '-o', 'tsv', '--only-show-errors')
  }
  $fqdnLine = ($rawFqdn -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)
  $fqdn = if ($fqdnLine) { $fqdnLine.Trim() } else { '' }
  if ($fqdn) {
    Write-Host "FQDN: https://$fqdn" -ForegroundColor Green
  }

  if ($WaitForHealth -and $fqdn) {
    Write-Host "Waiting for health: https://$fqdn/healthz (timeout ${HealthTimeoutSeconds}s)"
    $deadline = (Get-Date).AddSeconds($HealthTimeoutSeconds)
    do {
      try {
        $resp = Invoke-WebRequest -Uri "https://$fqdn/healthz" -Method GET -TimeoutSec 10 -SkipHttpErrorCheck
        if ($resp.StatusCode -eq 200) {
          Write-Host 'Health check OK.' -ForegroundColor Green
          break
        }
      } catch {
        # ignore and retry
      }

      Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)

    if ((Get-Date) -ge $deadline) {
      throw "Timed out waiting for https://$fqdn/healthz"
    }
  }

  if ($TestMcp -and $fqdn) {
    Write-Host "Testing MCP endpoint: https://$fqdn/mcp (tools/list)" -ForegroundColor Cyan
    $body = @{ jsonrpc = '2.0'; id = 1; method = 'tools/list'; params = @{} } | ConvertTo-Json -Depth 10
    $resp = Invoke-WebRequest -Method Post -Uri "https://$fqdn/mcp" -ContentType 'application/json' -Headers @{ Accept = 'application/json, text/event-stream' } -Body $body -TimeoutSec $McpTimeoutSeconds -SkipHttpErrorCheck
    if ($resp.StatusCode -lt 200 -or $resp.StatusCode -ge 300) {
      throw "MCP test failed ($($resp.StatusCode)): $([string]$resp.Content)"
    }
    Write-Host 'MCP endpoint OK.' -ForegroundColor Green
  }
} else {
  Write-Section 'Deploy to Azure Container Apps'
  Write-Host 'Skipping deploy (-SkipDeploy).'
}

Write-Section 'Summary'
Write-Host "Version:  $currentVersion"
Write-Host "Image:    $imageRef"
Write-Host 'Done.'
