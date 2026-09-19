# continuum test suite (PowerShell). Mirrors tests/run.sh. Mock provider, no network.
#   pwsh tests/run.ps1

$ErrorActionPreference = 'Continue'

$root = Split-Path -Parent $PSScriptRoot
$env:CLAUDE_PLUGIN_ROOT = $root
$env:CONTINUUM_PROVIDER = 'mock'
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("continuum-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

$script:pass = 0
$script:fail = 0
function Ok  ($n) { $script:pass++; Write-Host "  ok   $n" }
function Bad ($n, $why) { $script:fail++; Write-Host "  FAIL $n`n     $why" }
function Check ($n, $expect, $actual) {
    if ($actual -and ($actual -join "`n").Contains($expect)) { Ok $n }
    else { Bad $n "expected to contain '$expect', got: $actual" }
}
function Hook ($cfg, $stdin) {
    $env:CLAUDE_CONFIG_DIR = Join-Path $tmp $cfg
    $out = $stdin | & pwsh -NoProfile -File (Join-Path $root 'hooks/continuum-check.ps1') 2>$null
    return ($out -join '')
}
# NB: do not name this `Cli` - that is a built-in alias for Clear-Item, and
# aliases outrank functions in PowerShell's command resolution.
function Invoke-Continuum {
    & pwsh -NoProfile -File (Join-Path $root 'bin/continuum.ps1') @args 2>$null
}

Write-Host "cli:"
Check "status lists both windows" "5 hours" (Invoke-Continuum status)
Check "status shows weekly"       "7 days"  (Invoke-Continuum status)
Check "providers lists mock"      "mock"    (Invoke-Continuum providers)
Check "reset prints HH:MM"        ":"       (Invoke-Continuum reset)

$env:CONTINUUM_MOCK_FAIL = '1'
Invoke-Continuum status *>$null
if ($LASTEXITCODE -ne 0) { Ok "status fails when provider fails" }
else { Bad "status fails when provider fails" "exit 0" }
Remove-Item Env:CONTINUUM_MOCK_FAIL

$env:CONTINUUM_PROVIDER = 'nope'
Invoke-Continuum status *>$null
if ($LASTEXITCODE -ne 0) { Ok "unknown provider fails" } else { Bad "unknown provider fails" "exit 0" }
$env:CONTINUUM_PROVIDER = 'mock'

Write-Host "resume:"
function Dry ($tmpl, $prompt) {
    $env:CONTINUUM_DRY_RUN = '1'
    if ($tmpl) { $env:CONTINUUM_RESUME_CMD = $tmpl } elseif (Test-Path Env:CONTINUUM_RESUME_CMD) { Remove-Item Env:CONTINUUM_RESUME_CMD }
    $out = Invoke-Continuum resume '23:59' $root $prompt
    Remove-Item Env:CONTINUUM_DRY_RUN -ErrorAction SilentlyContinue
    return ($out -join "`n")
}
Check "default agent is claude"   'claude --continue -p "finish it"' (Dry $null 'finish it')
Check "swappable agent"           'pwsh exec "run it"'               (Dry 'pwsh exec "{prompt}"' 'run it')
Check "template without {prompt}" 'pwsh --continue'                  (Dry 'pwsh --continue' 'ignored')
Check "hostile prompt escaped"    '`"the`"'                          (Dry 'pwsh exec "{prompt}"' 'fix "the" bug')
if (Test-Path Env:CONTINUUM_RESUME_CMD) { Remove-Item Env:CONTINUUM_RESUME_CMD }

# No dry run here: the PATH check only runs on the real scheduling path.
$env:CONTINUUM_RESUME_CMD = 'nosuchagent {prompt}'
Invoke-Continuum resume '23:59' $root 'x' *>$null
if ($LASTEXITCODE -ne 0) { Ok "missing agent fails" } else { Bad "missing agent fails" "exit 0" }
Remove-Item Env:CONTINUUM_RESUME_CMD -ErrorAction SilentlyContinue

Write-Host "watch:"
$env:CONTINUUM_MOCK = '91.0'
Check "watch fires over threshold" "resets at" (Invoke-Continuum watch 1)
Remove-Item Env:CONTINUUM_MOCK

Write-Host "hook:"
$out = Hook 'a' '{"session_id":"a"}'
Check "blocks over threshold"  '"decision":"block"' $out
Check "reports utilization"    "86% used"           $out
Check "mentions second window" "7d window 41.0%"    $out

$out = Hook 'a' '{"session_id":"a"}'
if (-not $out) { Ok "warns once per session" } else { Bad "warns once per session" $out }

$env:CONTINUUM_MOCK = "46.0 10.0"
$out = Hook 'b' '{"session_id":"b"}'
if (-not $out) { Ok "silent under threshold" } else { Bad "silent under threshold" $out }
Remove-Item Env:CONTINUUM_MOCK

$env:CONTINUUM_MOCK = "93.2"
$out = Hook 'e' '{"session_id":"e"}'
Check "single-window provider" '"decision":"block"' $out
if ($out -notmatch 'Also:') { Ok "no phantom second window" } else { Bad "no phantom second window" $out }
Remove-Item Env:CONTINUUM_MOCK

$env:CONTINUUM_MOCK_FAIL = '1'
$out = Hook 'c' '{"session_id":"c"}'
if (-not $out) { Ok "silent when provider fails" } else { Bad "silent when provider fails" $out }
if (Test-Path (Join-Path $tmp 'c/.continuum-cache-mock.fail')) { Ok "negative cache written" }
else { Bad "negative cache written" "missing" }
Remove-Item Env:CONTINUUM_MOCK_FAIL

$out = Hook 'd' '{"session_id":"d","stop_hook_active":true}'
if (-not $out) { Ok "respects stop_hook_active" } else { Bad "respects stop_hook_active" $out }

$env:CONTINUUM_OFF = '1'
$out = Hook 'f' '{"session_id":"f"}'
if (-not $out) { Ok "respects CONTINUUM_OFF" } else { Bad "respects CONTINUUM_OFF" $out }
Remove-Item Env:CONTINUUM_OFF

# Escalating tiers: each of 80/90/95/99 fires once as usage climbs, and only upward.
# CONTINUUM_CACHE_MIN=0 disables the cache, so each call re-reads the changing mock.
$env:CONTINUUM_CACHE_MIN = '0'
function EscHook($mock) {
    $env:CONTINUUM_MOCK = $mock
    Hook 'esc' '{"session_id":"esc"}'
}
Check "tier 80 warns"      "80% tier" (EscHook '82.0')
if (-not (EscHook '88.0')) { Ok "quiet between tiers" } else { Bad "quiet between tiers" "warned again at 88%" }
Check "tier 95 warns next" "95% tier" (EscHook '96.0')
if (-not (EscHook '96.0')) { Ok "same tier warns once" } else { Bad "same tier warns once" "warned twice at 96%" }
Check "tier 99 warns last" "99% tier" (EscHook '99.0')

# Re-arm: a drop below the floor (top-up, rollover) clears the flag, so the
# same tier fires again on the way back up instead of staying silent.
function RearmHook($mock) {
    $env:CONTINUUM_MOCK = $mock
    Hook 'rearm' '{"session_id":"rearm"}'
}
Check "re-arm warns at 80" "80% tier" (RearmHook '82.0')
if (-not (RearmHook '46.0')) { Ok "re-arm drop is silent" } else { Bad "re-arm drop is silent" "warned at 46%" }
if (-not (Test-Path (Join-Path $tmp 'rearm/.continuum-warned-rearm'))) { Ok "re-arm clears the flag" }
else { Bad "re-arm clears the flag" "flag still present" }
Check "re-arm warns again at 80" "80% tier" (RearmHook '83.0')
Remove-Item Env:CONTINUUM_MOCK

# The "fires once per tier (...)" line reflects the configured tiers, not a hardcoded list.
$env:CONTINUUM_TIERS = '50 75'
$env:CONTINUUM_THRESHOLD = '50'
$env:CONTINUUM_MOCK = '80.0'
$out = Hook 'cti' '{"session_id":"cti"}'
Check "message lists configured tiers" "fire once each (50/75)" $out
if ($out -notmatch '80/90/95/99') { Ok "no hardcoded tier list" } else { Bad "no hardcoded tier list" $out }
Remove-Item Env:CONTINUUM_TIERS
Remove-Item Env:CONTINUUM_THRESHOLD
Remove-Item Env:CONTINUUM_MOCK

# A custom floor drops the tiers beneath it.
$env:CONTINUUM_THRESHOLD = '90'
$env:CONTINUUM_MOCK = '85.0'
$out = Hook 'flr' '{"session_id":"flr"}'
if (-not $out) { Ok "floor silences lower tiers" } else { Bad "floor silences lower tiers" $out }
Remove-Item Env:CONTINUUM_THRESHOLD
Remove-Item Env:CONTINUUM_MOCK
Remove-Item Env:CONTINUUM_CACHE_MIN

# The hook must never exit non-zero: use a file as the config dir to simulate
# an unwritable location (mirrors the /proc/nonexistent case in run.sh).
$blocker = Join-Path $tmp 'blocker-file'
Set-Content -Path $blocker -Value 'x'
$env:CLAUDE_CONFIG_DIR = $blocker
'{"session_id":"g"}' | & pwsh -NoProfile -File (Join-Path $root 'hooks/continuum-check.ps1') *>$null
if ($LASTEXITCODE -eq 0) { Ok "exit 0 on unwritable config dir" } else { Bad "exit 0 on unwritable config dir" "non-zero exit" }

Write-Host "estimate:"
$env:CLAUDE_CONFIG_DIR = Join-Path $tmp 'cli'
Check "estimate shows time left"  "At this pace" ((Invoke-Continuum estimate) -join "`n")
Check "estimate shows utilization" "Currently"   ((Invoke-Continuum estimate) -join "`n")

Write-Host "history:"
# status writes history; estimate above already called the provider
$null = Invoke-Continuum status
Check "history shows entries" "5h:" ((Invoke-Continuum history) -join "`n")

Write-Host "cleanup:"
# Isolated dir: never write outside $tmp in tests.
$clDir = Join-Path $tmp 'cleanup_test'
New-Item -ItemType Directory -Force -Path $clDir | Out-Null
$stale = New-Item -ItemType File -Force -Path (Join-Path $clDir '.continuum-warned-stale')
$stale.LastWriteTime = (Get-Date).AddHours(-25)
$env:CLAUDE_CONFIG_DIR = $clDir
Check "cleanup reports count" "Cleaned" ((Invoke-Continuum cleanup) -join "`n")

Write-Host "weekly tiers:"
# Weekly window crosses its tier independently of primary (primary at 50% = below 80% floor)
$env:CONTINUUM_CACHE_MIN = '0'
$env:CONTINUUM_MOCK = '50.0 75.0'
$out = Hook 'wk7' '{"session_id":"wk7"}'
Check "weekly tier fires" "weekly window" $out
$out = Hook 'wk7' '{"session_id":"wk7"}'
if (-not $out) { Ok "weekly same tier quiet" } else { Bad "weekly same tier quiet" $out }
$env:CONTINUUM_MOCK = '50.0 90.0'
$out = Hook 'wk7' '{"session_id":"wk7"}'
Check "weekly next tier fires" "weekly window" $out
Remove-Item Env:CONTINUUM_MOCK
Remove-Item Env:CONTINUUM_CACHE_MIN

Write-Host "wakelock:"
$env:CLAUDE_CONFIG_DIR = Join-Path $tmp 'wl'
New-Item -ItemType Directory -Force -Path $env:CLAUDE_CONFIG_DIR | Out-Null
. (Join-Path $root 'lib/core.ps1')
# No cnt_wakelock_wrap equivalent here: Start-Job/caffeinate/systemd-inhibit
# cover the same sleeps, so test start/stop directly.
$wlFile = Start-CntWakeLock 30
if ($wlFile) {
    if (Test-Path $wlFile) { Ok "wakelock pidfile created" } else { Bad "wakelock pidfile created" "missing $wlFile" }
    $wlId = (Get-Content -Path $wlFile -Raw).Trim()
    $alive = $false
    if ($wlId -match '^job:(\d+)$') {
        $alive = (Get-Job -Id ([int]$Matches[1]) -ErrorAction SilentlyContinue) -ne $null
    } elseif ($wlId -match '^\d+$') {
        try { Get-Process -Id ([int]$wlId) -ErrorAction Stop | Out-Null; $alive = $true }
        catch { $alive = $false }
    }
    if ($alive) { Ok "wakelock process alive" } else { Bad "wakelock process alive" "dead" }
    Stop-CntWakeLock $wlFile
    if ($wlId -match '^job:(\d+)$') {
        if (-not (Get-Job -Id ([int]$Matches[1]) -ErrorAction SilentlyContinue)) { Ok "wakelock stopped" }
        else { Bad "wakelock stopped" "job still present" }
    } else {
        # Processes can linger briefly as zombies: poll instead of asserting once.
        $dead = $false
        for ($i = 0; $i -lt 50 -and -not $dead; $i++) {
            try { Get-Process -Id ([int]$wlId) -ErrorAction Stop | Out-Null; Start-Sleep -Milliseconds 100 }
            catch { $dead = $true }
        }
        if ($dead) { Ok "wakelock stopped" } else { Bad "wakelock stopped" "still alive" }
    }
    if (-not (Test-Path $wlFile)) { Ok "wakelock pidfile cleaned" } else { Bad "wakelock pidfile cleaned" "still exists" }
} else {
    Write-Host '  skip wakelock start/stop (no tool available)'
}

# nohup resume path should mention sleep inhibition (sh) - here the dry run
# at least proves scheduling with an active wakelock helper set.
$env:CONTINUUM_DRY_RUN = '1'
$env:CLAUDE_CONFIG_DIR = Join-Path $tmp 'cli'
Check "dry run resume works with wakelock" "would sleep" ((Invoke-Continuum resume '23:59' $root 'test task') -join "`n")
Remove-Item Env:CONTINUUM_DRY_RUN -ErrorAction SilentlyContinue

Write-Host "frugal gate:"
# The PreToolUse hook blocks Agent when CONTINUUM_FRUGAL=1
$env:CONTINUUM_FRUGAL = '1'
$out = '{"tool_name":"Agent"}' | & pwsh -NoProfile -File (Join-Path $root 'hooks/frugal-gate.ps1') 2>$null
Check "frugal blocks Agent" '"decision":"block"' ($out -join '')
$out = '{"tool_name":"Read"}' | & pwsh -NoProfile -File (Join-Path $root 'hooks/frugal-gate.ps1') 2>$null
if (-not ($out -join '')) { Ok "frugal allows Read" } else { Bad "frugal allows Read" ($out -join '') }
Remove-Item Env:CONTINUUM_FRUGAL
$out = '{"tool_name":"Agent"}' | & pwsh -NoProfile -File (Join-Path $root 'hooks/frugal-gate.ps1') 2>$null
if (-not ($out -join '')) { Ok "no frugal allows Agent" } else { Bad "no frugal allows Agent" ($out -join '') }

Write-Host "multi-provider:"
$env:CONTINUUM_PROVIDER = 'mock,mock'
Check "multi-provider status works" "5 hours" ((Invoke-Continuum status) -join "`n")
# Comma lists are often written with a space ("mock, mock"): it must not fail lookup.
$env:CONTINUUM_PROVIDER = 'mock, mock'
Check "multi-provider tolerates spaces" "5 hours" ((Invoke-Continuum status) -join "`n")
$env:CONTINUUM_PROVIDER = 'mock'

Write-Host "resume quoting:"
# A project dir with a single quote must not break scheduling (quote-escaping).
$qdir = Join-Path $tmp "o'brien"
New-Item -ItemType Directory -Force -Path $qdir | Out-Null
$env:CONTINUUM_DRY_RUN = '1'
Check "resume accepts quote in dir" "would sleep" ((Invoke-Continuum resume '23:59' $qdir 'test task') -join "`n")
Remove-Item Env:CONTINUUM_DRY_RUN -ErrorAction SilentlyContinue

Write-Host "spend validation:"
# Invalid cap must fail before any network call (dummy key, bad cap).
$env:ANTHROPIC_ADMIN_KEY = 'dummy'
$env:CONTINUUM_SPEND_CAP = '0'
& pwsh -NoProfile -File (Join-Path $root 'providers/spend.ps1') *>$null
if ($LASTEXITCODE -ne 0) { Ok "spend rejects zero cap" } else { Bad "spend rejects zero cap" "exit 0" }
$env:CONTINUUM_SPEND_CAP = 'abc'
& pwsh -NoProfile -File (Join-Path $root 'providers/spend.ps1') *>$null
if ($LASTEXITCODE -ne 0) { Ok "spend rejects non-numeric cap" } else { Bad "spend rejects non-numeric cap" "exit 0" }
Remove-Item Env:CONTINUUM_SPEND_CAP
Remove-Item Env:ANTHROPIC_ADMIN_KEY

Write-Host "statusline:"
# Prepare a fake cache with known data
$slDir = Join-Path $tmp 'sl_test'
New-Item -ItemType Directory -Force -Path $slDir | Out-Null
$env:CLAUDE_CONFIG_DIR = $slDir
$env:CONTINUUM_PROVIDER = 'mock'
$nowSec = [int64][datetimeoffset]::UtcNow.ToUnixTimeSeconds()
$dReset = $nowSec + 3600
$wReset = $nowSec + 4 * 86400
Set-Content -Path (Join-Path $slDir '.continuum-cache-mock') -Value @("5h 46.0 $dReset", "7d 94.0 $wReset")

function Invoke-StatuslineHook {
    $slOut = & pwsh -NoProfile -File (Join-Path $root 'hooks/statusline.ps1') 2>$null
    return ($slOut -join '')
}

$slOut = Invoke-StatuslineHook
Check "statusline shows daily percent" "46%" $slOut
Check "statusline shows weekly percent" "94%" $slOut
Check "statusline shows today for daily" "today" $slOut

# Test config commands
Check "statusline cmd shows format" "format" ((Invoke-Continuum statusline) -join "`n")

$null = Invoke-Continuum statusline today 'sehodnya'
$slOut = Invoke-StatuslineHook
Check "statusline respects today config" "sehodnya" $slOut

$null = Invoke-Continuum statusline reset
$slOut = Invoke-StatuslineHook
Check "statusline reset restores defaults" "today" $slOut

# Test format-single (no weekly data)
Set-Content -Path (Join-Path $slDir '.continuum-cache-mock') -Value @("5h 46.0 $dReset")
$slOut = Invoke-StatuslineHook
Check "statusline single shows daily" "46%" $slOut
if ($slOut -notmatch '94%') { Ok "statusline single hides weekly" } else { Bad "statusline single hides weekly" "found 94% in: $slOut" }

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
Write-Host "`n$script:pass passed, $script:fail failed"
if ($script:fail -gt 0) { exit 1 }
