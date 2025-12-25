$t = (& (Join-Path $PSScriptRoot 'GetMcpAccessToken.ps1')).Trim()
& (Join-Path $PSScriptRoot 'GetMessages.ps1') -Top 5 -McpAccessToken $t
