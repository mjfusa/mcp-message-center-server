param(
	[int]$Top = 10,
	[int]$Skip = 0,
	[string]$Filter = "",
	[string]$OrderBy = "lastModifiedDateTime desc",
	[bool]$Count = $true,
	[string]$Prefer = "odata.maxpagesize=5",
	[string]$McpUrl = "http://localhost:8080/mcp",

	# Optional: A direct Microsoft Graph access token (local testing / legacy flow).
	# This will be passed as tool argument `accessToken`.
	[string]$GraphAccessToken = "",

	# Optional: A user access token for THIS MCP API (api://<clientId>/access_as_user).
	# If provided, it will be sent as Authorization header so the server can do OBO.
	[string]$McpAccessToken = ""
)

function Remove-ControlChars([string]$Value) {
	if ([string]::IsNullOrEmpty($Value)) { return $Value }
	# VS Code PowerShell shell integration can inject ANSI/OSC sequences into captured output.
	# Those sequences include both control chars AND printable payload (e.g. "]633;..."), which can corrupt JWTs.
	# Remove common ANSI sequences first, then strip any remaining control chars.
	$clean = $Value
	# OSC sequences: ESC ] ... BEL  OR  ESC ] ... ESC \
	$clean = $clean -replace "\x1b\][^\x07\x1b]*(?:\x07|\x1b\\\\)", ''
	# CSI sequences: ESC [ ... <final>
	$clean = $clean -replace "\x1b\[[0-?]*[ -/]*[@-~]", ''
	# Remaining control chars
	$clean = $clean -replace "[\x00-\x1F\x7F]", ''
	return $clean
}

$McpAccessToken = Remove-ControlChars $McpAccessToken
$GraphAccessToken = Remove-ControlChars $GraphAccessToken

function Assert-LooksLikeJwt([string]$Name, [string]$Token) {
	if ([string]::IsNullOrWhiteSpace($Token)) { return }
	if ($Token -notmatch '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$') {
		throw "$Name does not look like a JWT after sanitization. Re-run in a plain terminal (or disable VS Code shell integration) and try again. Length=$($Token.Length)"
	}
}

Assert-LooksLikeJwt 'McpAccessToken' $McpAccessToken
Assert-LooksLikeJwt 'GraphAccessToken' $GraphAccessToken

$arguments = @{
	orderby = $OrderBy
	count   = $Count
	prefer  = $Prefer
}

if ($PSBoundParameters.ContainsKey('Top')) {
	$arguments.top = $Top
}

if ($PSBoundParameters.ContainsKey('Skip')) {
	$arguments.skip = $Skip
}

if ($Filter) {
	$arguments.filter = $Filter
}

if ($GraphAccessToken) {
	$arguments.accessToken = $GraphAccessToken
}

$body = @{
	jsonrpc = "2.0"
	id      = 1
	method  = "tools/call"
	params  = @{
		name      = "getMessages"
		arguments = $arguments
	}
} | ConvertTo-Json -Depth 10

$headers = @{ Accept = "application/json, text/event-stream" }
if ($McpAccessToken) {
	$headers.Authorization = "Bearer $McpAccessToken"
}

# MCP Streamable HTTP transport expects an initialize handshake before calling tools.
# Without this, the server can respond 400 with an empty body.
$initBody = @{
	jsonrpc = "2.0"
	id      = 0
	method  = "initialize"
	params  = @{
		protocolVersion = "2024-11-05"
		capabilities    = @{
			roots        = @{
				listChanged = $true
			}
			sampling     = @{}
			elicitation  = @{}
		}
		clientInfo      = @{
			name    = "PowerShell"
			title   = "PowerShell initialize"
			version = "1.0.0"
		}
	}
} | ConvertTo-Json -Depth 10

$initResp = Invoke-WebRequest `
	-Method Post `
	-Uri $McpUrl `
	-ContentType "application/json" `
	-Headers $headers `
	-Body $initBody `
	-SkipHttpErrorCheck

if ($initResp.StatusCode -lt 200 -or $initResp.StatusCode -ge 300) {
	throw "Initialize failed ($($initResp.StatusCode)):\n$($initResp.Content)"
}

$resp = Invoke-WebRequest `
	-Method Post `
	-Uri $McpUrl `
	-ContentType "application/json" `
	-Headers $headers `
	-Body $body `
	-SkipHttpErrorCheck

if ($resp.StatusCode -lt 200 -or $resp.StatusCode -ge 300) {
	throw "Request failed ($($resp.StatusCode)):\n$($resp.Content)"
}

$contentType = ($resp.Headers['Content-Type'] | ForEach-Object { [string]$_ }) -join '; '
$raw = [string]$resp.Content

if ($contentType -match 'text/event-stream' -or $raw -match '(?m)^\s*data:') {
	# Streamable HTTP transport may respond using SSE. Extract the last JSON payload.
	$dataLines = $raw -split "`r?`n" | Where-Object { $_ -match '^\s*data:\s*\S' } | ForEach-Object { $_ -replace '^\s*data:\s*', '' }
	$last = $dataLines | Where-Object { $_ -ne '[DONE]' } | Select-Object -Last 1
	if (-not $last) {
		$raw
		return
	}
	($last | ConvertFrom-Json) | ConvertTo-Json -Depth 50
	return
}

($raw | ConvertFrom-Json) | ConvertTo-Json -Depth 50
