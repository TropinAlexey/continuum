# continuum provider: Anthropic API spend (API-key billing, not subscription).
# PowerShell edition. Mirrors providers/spend.sh.
#
#   $env:ANTHROPIC_ADMIN_KEY   - admin API key
#   $env:CONTINUUM_SPEND_CAP   - monthly budget in dollars (default: 100)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib/core.ps1')

$key = $env:ANTHROPIC_ADMIN_KEY
if (-not $key) { throw 'ANTHROPIC_ADMIN_KEY not set' }

$cap = 100
if ($env:CONTINUUM_SPEND_CAP) { $cap = [double]$env:CONTINUUM_SPEND_CAP }

$now = Get-Date
$start = $now.ToString('yyyy-MM-01')
$end = $now.ToString('yyyy-MM-') + [DateTime]::DaysInMonth($now.Year, $now.Month)

$headers = @{
    'x-api-key'          = $key
    'anthropic-version'  = '2023-06-01'
}
$url = "https://api.anthropic.com/v1/billing/usage?start_date=$start&end_date=$end"

try {
    $resp = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 15
    $cost = if ($resp.total_cost) { [double]$resp.total_cost } else { 0 }
} catch {
    throw 'billing endpoint unavailable (check ANTHROPIC_ADMIN_KEY)'
}

$util = [math]::Round(($cost / $cap) * 100, 1)
"month $util -"
