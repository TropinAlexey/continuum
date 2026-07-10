# continuum provider: Anthropic (PowerShell edition).
#
# Emits:
#   5h <utilization> <reset_epoch>
#   7d <utilization> <reset_epoch>
#
# Reads https://api.anthropic.com/api/oauth/usage - the endpoint behind `/usage`.
# It is NOT a public API and may change without notice. Nothing is sent anywhere
# except that host, and only as an Authorization header.

Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '../lib/core.ps1')

$token = Get-CntToken
if (-not $token) {
    [Console]::Error.WriteLine('no OAuth token found - are you logged in to Claude Code?')
    exit 1
}

try {
    $resp = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' -TimeoutSec 15 -Headers @{
        'Authorization'   = "Bearer $token"
        'anthropic-beta'  = 'oauth-2025-04-20'
    }
} catch {
    [Console]::Error.WriteLine('usage endpoint unavailable (rate limited, offline, or token expired)')
    exit 1
}

if (-not $resp.five_hour) {
    [Console]::Error.WriteLine('unexpected response from usage endpoint')
    exit 1
}

function Write-Window {
    param([string]$Label, $Block)
    if (-not $Block) { return }
    $epoch = '-'
    if ($Block.resets_at) {
        try { $epoch = ConvertTo-CntEpoch $Block.resets_at } catch { $epoch = '-' }
    }
    Write-Output ("{0} {1} {2}" -f $Label, $Block.utilization, $epoch)
}

Write-Window '5h' $resp.five_hour
Write-Window '7d' $resp.seven_day

exit 0
