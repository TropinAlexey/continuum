# Stop hook, PowerShell edition. Mirrors hooks/continuum-check.sh.
#
# Claude Code runs hooks under PowerShell on Windows when Git Bash is absent.
# Wire it up with  "shell": "powershell"  - see the README.
#
#   $env:CONTINUUM_THRESHOLD   percent, default 80
#   $env:CONTINUUM_PROVIDER    default anthropic
#   $env:CONTINUUM_OFF         set to anything to disable

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# A Stop hook that errors spams the user. Nothing below may throw past this point.
trap { exit 0 }

if ($env:CONTINUUM_OFF) { exit 0 }

if ($env:CLAUDE_PLUGIN_ROOT) { $root = $env:CLAUDE_PLUGIN_ROOT }
else { $root = Split-Path -Parent $PSScriptRoot }
. (Join-Path $root 'lib/core.ps1')

$event = [Console]::In.ReadToEnd()

# Never re-block while Claude is already handling a block (infinite loop guard).
if ($event -match '"stop_hook_active"\s*:\s*true') { exit 0 }

$sid = 'unknown'
if ($event -match '"session_id"\s*:\s*"([^"]+)"') { $sid = $Matches[1] }

New-Item -ItemType Directory -Force -Path $script:CntCfg | Out-Null

$flag = Join-Path $script:CntCfg ".continuum-warned-$sid"
if (Test-Path $flag) { exit 0 }                 # warn only once per session

# Providers hit rate-limited endpoints and this runs after every turn: cache hard,
# and back off after a failure ("negative cache").
$ttl    = 10
if ($env:CONTINUUM_CACHE_MIN) { $ttl = [int]$env:CONTINUUM_CACHE_MIN }
$cache  = Join-Path $script:CntCfg ".continuum-cache-$($script:CntProvider)"
$failed = "$cache.fail"
$fresh  = { param($f) (Test-Path $f) -and ((Get-Date) - (Get-Item $f).LastWriteTime).TotalMinutes -lt $ttl }

if (& $fresh $failed) { exit 0 }                # recently failed - do not retry yet

if (& $fresh $cache) {
    $lines = @(Get-Content -Path $cache)
} else {
    # @() is load-bearing: a function returning a one-element array unrolls it to a
    # scalar, and then $lines[0] would index into a string's characters.
    try { $lines = @(Read-CntUsage) }
    catch { New-Item -ItemType File -Force -Path $failed | Out-Null; exit 0 }
    Set-Content -Path $cache -Value $lines
    Remove-Item -Path $failed -ErrorAction SilentlyContinue
}

# First line is the primary window: <window> <utilization> <reset_epoch>
$first = $lines[0].Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
if ($first.Count -lt 2) { exit 0 }

$utilInt = [int][math]::Floor([double]::Parse($first[1], [cultureinfo]::InvariantCulture))

$threshold = 80
if ($env:CONTINUUM_THRESHOLD) { $threshold = [int]$env:CONTINUUM_THRESHOLD }
if ($utilInt -lt $threshold) { exit 0 }

$when = ''
if ($first.Count -ge 3 -and $first[2] -ne '-') {
    try { $when = ", resets at $(ConvertTo-CntHhmm ([int64]$first[2]))" } catch { $when = '' }
}

# Any window beyond the first, for context ("7d window 41.0%").
$rest = ''
if ($lines.Count -gt 1) {
    $extra = $lines[1..($lines.Count - 1)] | ForEach-Object {
        $p = $_.Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
        "$($p[0]) window $($p[1])%"
    }
    $rest = ". Also: " + ($extra -join ', ')
}

Set-Content -Path $flag -Value $utilInt

$reason = "[continuum] The primary usage window is $utilInt% used (threshold $threshold%)$when$rest. " +
          "Do not end the turn silently: run the session-budget skill - briefly state where we stopped, " +
          "then use AskUserQuestion to ask the user how to spend the rest of the window, offering the " +
          "options from that skill. This warning fires once per session."

# Stop hook contract: {"decision":"block","reason":"..."} feeds the reason back to Claude.
@{ decision = 'block'; reason = $reason } | ConvertTo-Json -Compress
