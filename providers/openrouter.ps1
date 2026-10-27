# continuum provider: OpenRouter key budget, PowerShell edition. Mirrors openrouter.sh.
#
# Emits one line:
#   <window> <utilization> <reset_epoch|->
# window is day / week / month when the key's limit resets on that schedule, key otherwise.
#
#   OPENROUTER_API_KEY        - the key (required; read from nowhere else)
#   CONTINUUM_OPENROUTER_CAP  - budget in dollars for a key without a limit
#   OPENROUTER_API_BASE       - https://... or file://... (tests: recorded responses)
#
# Uses the documented GET /api/v1/key. The key goes only to that host.

Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '../lib/core.ps1')

function Fail ($msg) { [Console]::Error.WriteLine($msg); exit 1 }

$key = $env:OPENROUTER_API_KEY
if (-not $key) { Fail 'OPENROUTER_API_KEY not set' }
$base = $(if ($env:OPENROUTER_API_BASE) { $env:OPENROUTER_API_BASE } else { 'https://openrouter.ai/api/v1' })
if ($base -notmatch '^(https|file)://') { Fail 'OPENROUTER_API_BASE must be https:// or file://' }

try {
    if ($base -like 'file://*') {
        $raw = [System.IO.File]::ReadAllText(([uri]"$base/key").LocalPath)
    } else {
        $raw = (Invoke-WebRequest -Uri "$base/key" -Headers @{ Authorization = "Bearer $key" } -TimeoutSec 15 -UseBasicParsing).Content
    }
    $d = ($raw | ConvertFrom-Json).data
} catch { Fail 'openrouter: /key unavailable (offline, or the key is invalid)' }
if ($null -eq $d -or -not ($d.PSObject.Properties.Name -contains 'usage')) { Fail 'openrouter: unexpected response (no usage)' }

function Get-Field ($name) { if ($d.PSObject.Properties.Name -contains $name) { return $d.$name } return $null }
$usage = [double]$d.usage
$limit = Get-Field 'limit'
$remaining = Get-Field 'limit_remaining'
$period = Get-Field 'limit_reset'

$now = [DateTimeOffset]::UtcNow
$midnight = [DateTimeOffset]::new($now.UtcDateTime.Date.AddDays(1), [TimeSpan]::Zero)
switch ($period) {
    'daily'   { $window = 'day';   $reset = $midnight.ToUnixTimeSeconds() }
    'weekly'  { $window = 'week';  $dow = [int]$now.UtcDateTime.DayOfWeek; if ($dow -eq 0) { $dow = 7 }
                $reset = $midnight.AddDays(7 - $dow).ToUnixTimeSeconds() }
    'monthly' { $window = 'month'; $first = [DateTimeOffset]::new($now.Year, $now.Month, 1, 0, 0, 0, [TimeSpan]::Zero).AddMonths(1)
                $reset = $first.ToUnixTimeSeconds() }
    default   { $window = 'key';   $reset = '-' }
}

$inv = [Globalization.CultureInfo]::InvariantCulture
if ($null -ne $limit -and [double]$limit -gt 0) {
    if ($null -ne $remaining) { $u = ([double]$limit - [double]$remaining) / [double]$limit * 100; if ($u -lt 0) { $u = 0 } }
    else { $u = $usage / [double]$limit * 100 }
} else {
    $cap = $env:CONTINUUM_OPENROUTER_CAP
    $capVal = 0.0
    if (-not $cap) { Fail 'openrouter: the key has no limit; set CONTINUUM_OPENROUTER_CAP to a budget in dollars' }
    if (-not [double]::TryParse($cap, [Globalization.NumberStyles]::Float, $inv, [ref]$capVal) -or $capVal -le 0) { Fail "invalid CONTINUUM_OPENROUTER_CAP='$cap' (need a positive number)" }
    $window = 'key'; $reset = '-'
    $u = $usage / $capVal * 100
}
Write-Output ('{0} {1} {2}' -f $window, $u.ToString('0.0', $inv), $reset)
exit 0
