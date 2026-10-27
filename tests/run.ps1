# continuum test suite (PowerShell). Mirrors tests/run.sh. Mock provider, no network.
#   pwsh tests/run.ps1

$ErrorActionPreference = 'Continue'

$root = Split-Path -Parent $PSScriptRoot
$env:CLAUDE_PLUGIN_ROOT = $root
$env:CONTINUUM_PROVIDER = 'mock'
# The suite may itself run inside a bb thread; resume presets must not see it.
Remove-Item Env:BB_THREAD_ID -ErrorAction SilentlyContinue
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("continuum-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
# State goes to $tmp, never to the real home: tests that need their own state
# dir override CONTINUUM_STATE_DIR.
$env:CONTINUUM_STATE_DIR = Join-Path $tmp 'state'

$script:pass = 0
$script:fail = 0
function Ok  ($n) { $script:pass++; Write-Host "  ok   $n" }
function Bad ($n, $why) { $script:fail++; Write-Host "  FAIL $n`n     $why" }
function Check ($n, $expect, $actual) {
    if ($actual -and ($actual -join "`n").Contains($expect)) { Ok $n }
    else { Bad $n "expected to contain '$expect', got: $actual" }
}
function Hook ($cfg, $stdin) {
    $env:CONTINUUM_STATE_DIR = Join-Path $tmp $cfg
    $out = $stdin | & pwsh -NoProfile -File (Join-Path $root 'adapters/claude/stop.ps1') 2>$null
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

$env:CONTINUUM_AGENT = 'claude'
Check "agent preset claude" 'claude --continue' (Dry $null 'x')
foreach ($pair in @(@('codex', 'codex exec resume --last'), @('gemini', 'gemini --resume latest'), @('cursor', 'agent -p --continue'), @('opencode', 'opencode run --continue'), @('junie', 'junie --skip-update-check --resume --task'))) {
    $env:CONTINUUM_AGENT = $pair[0]
    Check "agent preset $($pair[0])" $pair[1] (Dry $null 'x')
}
$env:CONTINUUM_AGENT = 'nope'
$env:CONTINUUM_DRY_RUN = '1'
Invoke-Continuum resume '23:59' $root 'x' *>$null
if ($LASTEXITCODE -ne 0) { Ok "unknown agent without command fails" } else { Bad "unknown agent without command fails" "exit 0" }
Remove-Item Env:CONTINUUM_DRY_RUN
Check "explicit command beats preset" 'pwsh exec "y' (Dry 'pwsh exec "{prompt}"' 'y')
$env:BB_THREAD_ID = 'th_1-A'
Check "bb thread beats agent preset" 'thread tell th_1-A "x' (Dry $null 'x')
Check "explicit command beats bb thread" 'pwsh exec "y' (Dry 'pwsh exec "{prompt}"' 'y')
$env:BB_THREAD_ID = 't;rm -rf'
$env:CONTINUUM_AGENT = 'claude'
Check "unsafe bb thread id ignored" 'claude --continue' (Dry $null 'x')
Remove-Item Env:BB_THREAD_ID
Remove-Item Env:CONTINUUM_AGENT
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

# The hook must never exit non-zero: use a file as the state dir to simulate
# an unwritable location (mirrors the /proc/nonexistent case in run.sh).
$blocker = Join-Path $tmp 'blocker-file'
Set-Content -Path $blocker -Value 'x'
$env:CONTINUUM_STATE_DIR = $blocker
'{"session_id":"g"}' | & pwsh -NoProfile -File (Join-Path $root 'adapters/claude/stop.ps1') *>$null
if ($LASTEXITCODE -eq 0) { Ok "exit 0 on unwritable state dir" } else { Bad "exit 0 on unwritable state dir" "non-zero exit" }

Write-Host "check (agent-neutral):"
function Chk ($dir) {
    $env:CONTINUUM_STATE_DIR = Join-Path $tmp "chk/$dir"
    $o = Invoke-Continuum check --session s @args
    $env:CONTINUUM_STATE_DIR = Join-Path $tmp 'state'
    return ($o -join "`n")
}
$out = Chk 'g'
Check "check warns over threshold" "[continuum] The primary usage window is 86% used" $out
Check "check generic wording"      "ask the user how to spend the rest" $out
if ($out -match 'AskUserQuestion|"decision"') { Bad "check output is agent-neutral" $out } else { Ok "check output is agent-neutral" }
$out = Chk 'g'
if (-not $out) { Ok "check warns once per tier" } else { Bad "check warns once per tier" "warned twice" }
Check "check claude wording" "use AskUserQuestion" (Chk 'c' --agent claude)
$env:CONTINUUM_AGENT = 'claude'
Check "check agent from env" "use AskUserQuestion" (Chk 'e')
Remove-Item Env:CONTINUUM_AGENT
$env:CONTINUUM_MOCK = '46.0 10.0'
$out = Chk 'u'
if (-not $out) { Ok "check silent under threshold" } else { Bad "check silent under threshold" $out }
Remove-Item Env:CONTINUUM_MOCK
$env:CONTINUUM_MOCK_FAIL = '1'
$out = Chk 'f'
if (-not $out) { Ok "check silent when provider fails" } else { Bad "check silent when provider fails" $out }
Remove-Item Env:CONTINUUM_MOCK_FAIL
Invoke-Continuum check --bogus x *>$null
if ($LASTEXITCODE -ne 0) { Ok "check rejects bad args" } else { Bad "check rejects bad args" "exit 0" }
# The Claude adapter must produce exactly what the pre-adapter hook did.
Check "adapter keeps claude text" 'then use AskUserQuestion to ask the user how to spend the rest of the window, offering the options from that skill.' (Hook 'ad' '{"session_id":"ad"}')
$out = Hook 'ad2' '{"session_id": "ad2", "stop_hook_active": true}'
if (-not $out) { Ok "adapter respects spaced stop_hook_active" } else { Bad "adapter respects spaced stop_hook_active" $out }
$env:CONTINUUM_STATE_DIR = Join-Path $tmp 'fw'
$out = '{"session_id":"fw"}' | & pwsh -NoProfile -File (Join-Path $root 'hooks/continuum-check.ps1') 2>$null
Check "old hook path still works" '"decision":"block"' ($out -join '')
$env:CONTINUUM_STATE_DIR = Join-Path $tmp 'state'

Write-Host "state dir:"
function StateDir ($stateDir, $xdg, $home_) {
    $script = "`$env:CONTINUUM_STATE_DIR = '$stateDir'; `$env:XDG_STATE_HOME = '$xdg'; " +
        "if (-not `$env:CONTINUUM_STATE_DIR) { Remove-Item Env:CONTINUUM_STATE_DIR -ErrorAction SilentlyContinue }; " +
        "if (-not `$env:XDG_STATE_HOME) { Remove-Item Env:XDG_STATE_HOME -ErrorAction SilentlyContinue }; " +
        "Set-Variable -Name HOME -Value '$home_' -Force -Scope Global -ErrorAction SilentlyContinue; " +
        ". '$root/lib/core.ps1'; `$script:CntState"
    return (& pwsh -NoProfile -Command $script 2>$null) -join ''
}
$h0 = Join-Path $tmp 'h0'
Check "state dir from CONTINUUM_STATE_DIR" (Join-Path $tmp 'x1') (StateDir (Join-Path $tmp 'x1') '' $h0)
Check "state dir from XDG_STATE_HOME" (Join-Path (Join-Path $tmp 'x2') 'continuum') (StateDir '' (Join-Path $tmp 'x2') $h0)

Write-Host "migration:"
$mClaude = Join-Path $tmp 'mh/.claude'
$ms = Join-Path $tmp 'mh/state'
New-Item -ItemType Directory -Force -Path (Join-Path $mClaude 'providers'), $ms | Out-Null
Set-Content -Path (Join-Path $mClaude '.continuum-statusline.conf') -Value 'TODAY=sehodnya'
Set-Content -Path (Join-Path $mClaude 'continuum-resume.log') -Value 'old log'
Set-Content -Path (Join-Path $mClaude '.continuum-cache-mock') -Value 'cache'
Set-Content -Path (Join-Path $mClaude '.continuum-history.log') -Value 'old hist'
Set-Content -Path (Join-Path $mClaude 'providers/mine.ps1') -Value "'x 1 -'"
Set-Content -Path (Join-Path $ms '.continuum-history.log') -Value 'kept'
# Migration is skipped when CONTINUUM_STATE_DIR is explicit, so point XDG at it.
function Migrate {
    $saved = $env:CONTINUUM_STATE_DIR
    Remove-Item Env:CONTINUUM_STATE_DIR
    $env:XDG_STATE_HOME = Join-Path $tmp 'mh'
    $env:CLAUDE_CONFIG_DIR = $mClaude
    Rename-Item -Path $ms -NewName 'continuum' -ErrorAction SilentlyContinue
    $o = Invoke-Continuum providers
    Rename-Item -Path (Join-Path $tmp 'mh/continuum') -NewName 'state' -ErrorAction SilentlyContinue
    Remove-Item Env:XDG_STATE_HOME, Env:CLAUDE_CONFIG_DIR
    $env:CONTINUUM_STATE_DIR = $saved
    return ($o -join "`n")
}
$out = Migrate
Check "migration copies statusline conf" "sehodnya" ((Get-Content (Join-Path $ms '.continuum-statusline.conf') -ErrorAction SilentlyContinue) -join '')
Check "migration copies resume log" "old log" ((Get-Content (Join-Path $ms 'continuum-resume.log') -ErrorAction SilentlyContinue) -join '')
Check "migration copies user providers" "mine" $out
Check "migration never overwrites" "kept" ((Get-Content (Join-Path $ms '.continuum-history.log')) -join '')
if (-not (Test-Path (Join-Path $ms '.continuum-cache-mock'))) { Ok "migration skips cache" } else { Bad "migration skips cache" "copied" }
if (Test-Path (Join-Path $ms '.migrated')) { Ok "migration leaves a marker" } else { Bad "migration leaves a marker" "missing" }
if (Test-Path (Join-Path $mClaude 'continuum-resume.log')) { Ok "migration keeps originals" } else { Bad "migration keeps originals" "deleted" }
Set-Content -Path (Join-Path $mClaude '.continuum-statusline.conf') -Value 'NEW=1'
$null = Migrate
Check "migration runs once" "sehodnya" ((Get-Content (Join-Path $ms '.continuum-statusline.conf')) -join '')

Write-Host "root pointer:"
$rp = Join-Path $tmp 'rp'
New-Item -ItemType Directory -Force -Path (Join-Path $rp 'copy') | Out-Null
$env:CONTINUUM_STATE_DIR = Join-Path $rp 'state'
$null = Invoke-Continuum providers
Check "cli records root pointer" ((Resolve-Path $root).Path) ((Get-Content (Join-Path $rp 'state/root') -ErrorAction SilentlyContinue) -join '')
Copy-Item (Join-Path $root 'adapters/claude/statusline.ps1') (Join-Path $rp 'copy/statusline.ps1')
$savedRoot = $env:CLAUDE_PLUGIN_ROOT
Remove-Item Env:CLAUDE_PLUGIN_ROOT
$out = & pwsh -NoProfile -File (Join-Path $rp 'copy/statusline.ps1') 2>$null
$env:CLAUDE_PLUGIN_ROOT = $savedRoot
Check "copied statusline finds core via pointer" "86%" ($out -join '')
$env:CONTINUUM_STATE_DIR = Join-Path $tmp 'state'

Write-Host "estimate:"
$env:CONTINUUM_STATE_DIR = Join-Path $tmp 'cli'
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
$env:CONTINUUM_STATE_DIR = $clDir
Check "cleanup reports count" "Cleaned" ((Invoke-Continuum cleanup) -join "`n")

Write-Host "weekly tiers:"
# Weekly window crosses its tier independently of primary (primary at 50% = below 80% floor)
$env:CONTINUUM_CACHE_MIN = '0'
$env:CONTINUUM_MOCK = '50.0 75.0'
$out = Hook 'wk7' '{"session_id":"wk7"}'
Check "weekly tier fires" "weekly window" $out
if ("$out" -match 'tier\), resets [A-Z][a-z]{2} [0-2][0-9]:[0-5][0-9]') { Ok "weekly reset day+time" } else { Bad "weekly reset day+time" "$out" }
$out = Hook 'wk7' '{"session_id":"wk7"}'
if (-not $out) { Ok "weekly same tier quiet" } else { Bad "weekly same tier quiet" $out }
$env:CONTINUUM_MOCK = '50.0 90.0'
$out = Hook 'wk7' '{"session_id":"wk7"}'
Check "weekly next tier fires" "weekly window" $out
$env:CONTINUUM_MOCK = '96.0 96.0'
$out = Hook 'wk7b' '{"session_id":"wk7b"}'
if ("$out" -match 'also crossed the 95% tier \(96% used, resets [A-Z][a-z]{2} ') { Ok "weekly reset in combined warning" } else { Bad "weekly reset in combined warning" "$out" }
Remove-Item Env:CONTINUUM_MOCK
Remove-Item Env:CONTINUUM_CACHE_MIN

Write-Host "wakelock:"
$env:CONTINUUM_STATE_DIR = Join-Path $tmp 'wl'
New-Item -ItemType Directory -Force -Path $env:CONTINUUM_STATE_DIR | Out-Null
. (Join-Path $root 'lib/core.ps1')
# No cnt_wakelock_wrap equivalent here: Start-Job/caffeinate/systemd-inhibit
# cover the same sleeps, so test start/stop directly.
$wlFile = Start-CntWakeLock 30
if ($wlFile) {
    if (Test-Path $wlFile) { Ok "wakelock pidfile created" } else { Bad "wakelock pidfile created" "missing $wlFile" }
    $wlId = (Get-Content -Path $wlFile -Raw).Trim()
    $alive = $false
    if ($wlId -match '^job:(\d+)$') {
        $alive = $null -ne (Get-Job -Id ([int]$Matches[1]) -ErrorAction SilentlyContinue)
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
$env:CONTINUUM_STATE_DIR = Join-Path $tmp 'cli'
Check "dry run resume works with wakelock" "would sleep" ((Invoke-Continuum resume '23:59' $root 'test task') -join "`n")
Remove-Item Env:CONTINUUM_DRY_RUN -ErrorAction SilentlyContinue

Write-Host "frugal gate:"
# The PreToolUse hook blocks Agent when CONTINUUM_FRUGAL=1
$env:CONTINUUM_FRUGAL = '1'
$out = '{"tool_name":"Agent"}' | & pwsh -NoProfile -File (Join-Path $root 'adapters/claude/frugal-gate.ps1') 2>$null
Check "frugal blocks Agent" '"decision":"block"' ($out -join '')
$out = '{"tool_name":"Read"}' | & pwsh -NoProfile -File (Join-Path $root 'adapters/claude/frugal-gate.ps1') 2>$null
if (-not ($out -join '')) { Ok "frugal allows Read" } else { Bad "frugal allows Read" ($out -join '') }
Remove-Item Env:CONTINUUM_FRUGAL
$out = '{"tool_name":"Agent"}' | & pwsh -NoProfile -File (Join-Path $root 'adapters/claude/frugal-gate.ps1') 2>$null
if (-not ($out -join '')) { Ok "no frugal allows Agent" } else { Bad "no frugal allows Agent" ($out -join '') }

Write-Host "mid-turn check:"
# PostToolUse: the same warning as Stop, as additionalContext, sharing tiers and flags.
function Tool ($cfg, $stdin) {
    $env:CONTINUUM_STATE_DIR = Join-Path $tmp $cfg
    $out = $stdin | & pwsh -NoProfile -File (Join-Path $root 'adapters/claude/tool-check.ps1') 2>$null
    return ($out -join '')
}
$out = Tool 'mt' '{"session_id":"mt","tool_name":"Bash"}'
Check "mid-turn uses PostToolUse" '"hookEventName":"PostToolUse"' $out
Check "mid-turn sends additionalContext" '"additionalContext":"Mid-turn usage check.' $out
Check "mid-turn keeps claude text" 'use AskUserQuestion' $out
if ($out -notmatch '"decision"') { Ok "mid-turn never blocks" } else { Bad "mid-turn never blocks" $out }
if (-not (Tool 'mt' '{"session_id":"mt","tool_name":"Bash"}')) { Ok "mid-turn fires once per tier" } else { Bad "mid-turn fires once per tier" "warned twice" }
if (-not (Hook 'mt' '{"session_id":"mt"}')) { Ok "Stop silent after mid-turn warned" } else { Bad "Stop silent after mid-turn warned" "warned twice" }
Hook 'mts' '{"session_id":"mts"}' | Out-Null
if (-not (Tool 'mts' '{"session_id":"mts"}')) { Ok "mid-turn silent after Stop warned" } else { Bad "mid-turn silent after Stop warned" "warned twice" }
$out = Tool 'mta' '{"session_id":"mta","agent_id":"a1","agent_type":"Explore"}'
if (-not $out) { Ok "mid-turn silent inside a subagent" } else { Bad "mid-turn silent inside a subagent" $out }
Check "subagent does not use up the tier" "Mid-turn usage check" (Tool 'mta' '{"session_id":"mta"}')
$env:CONTINUUM_MOCK = '46.0 10.0'
if (-not (Tool 'mtu' '{"session_id":"mtu"}')) { Ok "mid-turn silent under threshold" } else { Bad "mid-turn silent under threshold" "warned" }
Remove-Item Env:CONTINUUM_MOCK
$env:CONTINUUM_OFF = '1'
if (-not (Tool 'mto' '{"session_id":"mto"}')) { Ok "mid-turn respects CONTINUUM_OFF" } else { Bad "mid-turn respects CONTINUUM_OFF" "warned" }
Remove-Item Env:CONTINUUM_OFF
if ((Get-Content -Raw (Join-Path $root 'hooks/hooks.json')).Contains('adapters/claude/tool-check.sh')) { Ok "hooks.json wires the mid-turn check" } else { Bad "hooks.json wires the mid-turn check" "missing" }

Write-Host "junie (runs the Claude plugin's hooks):"
# Junie fires PreToolUse (no PostToolUse) and tags every event with project_path.
if (-not (Tool 'jc' '{"hook_event_name":"PreToolUse","session_id":"jc","tool_name":"Bash"}')) { Ok "claude skips the PreToolUse duplicate" } else { Bad "claude skips the PreToolUse duplicate" "warned" }
$out = Tool 'jt' '{"hook_event_name":"PreToolUse","session_id":"jt","project_path":"/p","tool_name":"Bash"}'
Check "junie mid-turn on PreToolUse" '"hookEventName":"PreToolUse"' $out
Check "junie gets its own hint" 'end your final message by asking' $out
if ($out -notmatch 'AskUserQuestion') { Ok "junie hint has no AskUserQuestion" } else { Bad "junie hint has no AskUserQuestion" $out }
Check "claude stays claude with a nested project_path" 'use AskUserQuestion' (Tool 'jn' '{"hook_event_name":"PostToolUse","session_id":"jn","transcript_path":"/t.jsonl","tool_input":{"project_path":"/x"}}')
$out = Hook 'js' '{"hook_event_name":"Stop","session_id":"js","project_path":"/p","stop_hook_active":false}'
Check "junie stop names the resume preset" 'CONTINUUM_AGENT=junie continuum resume' $out

Write-Host "doctor:"
$dr = Join-Path $tmp 'dr'
foreach ($d in @('claude/hooks', 'claude/plugins/cache/continuum/continuum/0.1.0', 'junie/extensions/m/continuum/.claude-plugin', 'st')) { New-Item -ItemType Directory -Force -Path (Join-Path $dr $d) | Out-Null }
Set-Content -Path (Join-Path $dr 'claude/settings.json') -Value '{ "enabledPlugins": { "continuum@continuum": true } }'
Set-Content -Path (Join-Path $dr 'junie/extensions/m/continuum/.claude-plugin/plugin.json') -Value '{ "version": "0.0.1" }'
Set-Content -Path (Join-Path $dr 'claude/hooks/statusline.ps1') -Value '# continuum old'
function Doc ($opt) {
    $env:CLAUDE_CONFIG_DIR = Join-Path $dr 'claude'; $env:JUNIE_HOME = Join-Path $dr 'junie'; $env:CONTINUUM_STATE_DIR = Join-Path $dr 'st'
    $o = & pwsh -NoProfile -File (Join-Path $root 'bin/continuum.ps1') doctor $opt 2>&1
    $script:docRc = $LASTEXITCODE
    Remove-Item Env:CLAUDE_CONFIG_DIR, Env:JUNIE_HOME -ErrorAction SilentlyContinue
    return ($o -join "`n")
}
$out = Doc ''
Check "doctor: provider ok" 'ok   provider mock: 5h 86.5%' $out
Check "doctor: plugin enabled" 'ok   Claude Code plugin enabled' $out
Check "doctor: stale statusline copy" 'warn statusline copy' $out
Check "doctor: old plugin version" 'warn Claude Code runs plugin 0.1.0' $out
Check "doctor: old Junie extension" 'warn Junie extension is 0.0.1' $out
if ($script:docRc -eq 0) { Ok "doctor: warnings alone exit 0" } else { Bad "doctor: warnings alone exit 0" "rc=$script:docRc" }
$out = Doc '--fix'
Check "doctor --fix refreshes the copy" 'ok   statusline copy refreshed' $out
Set-Content -Path (Join-Path $dr 'claude/settings.json') -Value '{ "hooks": { "Stop": [{ "hooks": [{ "command": "sh ~/.claude/hooks/token-budget-check.sh" }] }] } }'
$before = Get-Content -Raw (Join-Path $dr 'claude/settings.json')
$out = Doc '--fix'
Check "doctor: plugin not enabled fails" 'fail Claude Code plugin not enabled' $out
Check "doctor: old hooks found" 'warn old hooks still wired' $out
if ($script:docRc -eq 1) { Ok "doctor: a fail exits 1" } else { Bad "doctor: a fail exits 1" "rc=$script:docRc" }
if ((Get-Content -Raw (Join-Path $dr 'claude/settings.json')) -eq $before) { Ok "doctor --fix never edits settings.json" } else { Bad "doctor --fix never edits settings.json" "changed" }
$env:CONTINUUM_STATE_DIR = Join-Path $tmp 'state'

Write-Host "install --agent:"
$ih = Join-Path $tmp 'ih'; New-Item -ItemType Directory -Force -Path $ih | Out-Null
function Ci {
    $saveHome = $env:HOME
    $env:HOME = $ih; $env:CONTINUUM_STATE_DIR = Join-Path $ih 'st'; $env:XDG_CONFIG_HOME = Join-Path $ih '.config'; $env:CODEX_HOME = Join-Path $ih '.codex'
    $o = & pwsh -NoProfile -File (Join-Path $root 'bin/continuum.ps1') @args 2>&1
    $script:ciRc = $LASTEXITCODE
    $env:HOME = $saveHome; Remove-Item Env:XDG_CONFIG_HOME, Env:CODEX_HOME -ErrorAction SilentlyContinue
    return ($o -join "`n")
}
function Test-Json ($p) { try { $null = Get-Content -Raw $p | ConvertFrom-Json -ErrorAction Stop; return $true } catch { return $false } }
$cx = Join-Path $ih '.codex/hooks.json'
Check "install creates the codex hooks file" 'installed: ' (Ci install --agent codex)
if (Test-Json $cx) { Ok "install writes valid JSON (created)" } else { Bad "install writes valid JSON (created)" (Get-Content -Raw $cx) }
Check "install points at this code" '/adapters/codex/' (Get-Content -Raw $cx)
Check "install twice changes nothing" 'already installed' (Ci install --agent codex)
$gm = Join-Path $ih '.gemini/settings.json'; New-Item -ItemType Directory -Force -Path (Split-Path $gm) | Out-Null
Set-Content -Path $gm -Value "{`n  `"theme`": `"dark`"`n}"; $gOrig = Get-Content -Raw $gm
Ci install --agent gemini | Out-Null
if (Test-Json $gm) { Ok "install merges into a file without hooks" } else { Bad "install merges into a file without hooks" (Get-Content -Raw $gm) }
Check "install keeps the other settings" '"theme": "dark"' (Get-Content -Raw $gm)
Ci uninstall --agent gemini | Out-Null
if ((Get-Content -Raw $gm) -eq $gOrig) { Ok "uninstall restores the file exactly" } else { Bad "uninstall restores the file exactly" (Get-Content -Raw $gm) }
$cu = Join-Path $ih '.cursor/hooks.json'; New-Item -ItemType Directory -Force -Path (Split-Path $cu) | Out-Null
Set-Content -Path $cu -Value '{"version":1,"hooks":{"stop":[]}}'; $cOrig = Get-Content -Raw $cu
$out = Ci install --agent cursor
Check "install refuses existing hooks" 'merge these entries by hand' $out
if ((Get-Content -Raw $cu) -eq $cOrig -and $script:ciRc -eq 1) { Ok "a refused install leaves the file alone" } else { Bad "a refused install leaves the file alone" "rc=$script:ciRc" }
Ci uninstall --agent codex | Out-Null
if (-not (Test-Path $cx)) { Ok "uninstall removes a file it created" } else { Bad "uninstall removes a file it created" 'still there' }
Check "dry run prints the change" 'would write' (Ci install --agent codex --dry-run)
if (-not (Test-Path $cx)) { Ok "dry run writes nothing" } else { Bad "dry run writes nothing" 'written' }
if (-not $IsWindows) {
    $real = Join-Path $ih 'real.json'; Set-Content -Path $real -Value '{}'
    Remove-Item -Force $cu; New-Item -ItemType SymbolicLink -Path $cu -Target $real | Out-Null
    Check "install refuses a symlinked config" 'is a symlink' (Ci install --agent cursor)
    if ((Get-Item -Force $cu).LinkType) { Ok "the symlink stays a symlink" } else { Bad "the symlink stays a symlink" 'replaced' }
}
Ci install --agent codex | Out-Null; Add-Content -Path $cx -Value ' '
Check "uninstall refuses a file changed since install" 'changed since install' (Ci uninstall --agent codex)
$env:CONTINUUM_STATE_DIR = Join-Path $tmp 'state'

Write-Host "watch --ide (JetBrains MCP):"
$ideStub = Join-Path $tmp 'ide_stub.ps1'
Set-Content -Path $ideStub -Value @'
Add-Content -Path $env:IDE_LOG -Value ("{0} {1}" -f $args[1], $args[2])
if ($args[2] -match '"initialize"') { 'sid-1'; '{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"RustRover MCP Server"}}}' }
elseif ($args[2] -match 'tools/call') { 'sid-1'; '{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"[success]"}]}}' }
else { 'sid-1'; '' }
'@
$ideRepo = Join-Path $tmp 'ide_repo'; New-Item -ItemType Directory -Force -Path $ideRepo | Out-Null; & git -C $ideRepo init -q
$ideLog = Join-Path $tmp 'ide.log'
function Iw ($dir, $a1, $a2) {
    $env:IDE_LOG = $ideLog; $env:CONTINUUM_IDE_MCP_CMD = "pwsh -NoProfile -File $ideStub"; $env:CONTINUUM_IDE_MCP_URL = 'http://127.0.0.1:1/stream'
    Push-Location $dir
    $o = & pwsh -NoProfile -File (Join-Path $root 'bin/continuum.ps1') watch $a1 $a2 2>&1
    Pop-Location
    Remove-Item Env:IDE_LOG, Env:CONTINUUM_IDE_MCP_CMD, Env:CONTINUUM_IDE_MCP_URL -ErrorAction SilentlyContinue
    return ($o -join "`n")
}
Set-Content -Path $ideLog -Value ''
$out = Iw $ideRepo '--ide' '1'
Check "watch --ide still prints the warning" 'continuum: 86% used' $out
Check "watch --ide writes the warning file" '86% of the usage window used' (Get-Content -Raw (Join-Path $ideRepo '.git/continuum-warning.md') -ErrorAction SilentlyContinue)
Check "watch --ide opens it in the IDE" '"name":"open_file_in_editor","arguments":{"filePath":".git/continuum-warning.md","rootFolder":"' (Get-Content -Raw $ideLog)
if (-not (& git -C $ideRepo status --porcelain)) { Ok "watch --ide leaves git status clean" } else { Bad "watch --ide leaves git status clean" "dirty" }
Set-Content -Path $ideLog -Value ''
Iw $ideRepo '1' $null | Out-Null
if (-not (Get-Content -Raw $ideLog).Trim()) { Ok "watch without --ide sends nothing to the IDE" } else { Bad "watch without --ide sends nothing to the IDE" (Get-Content -Raw $ideLog) }

Write-Host "limit hit mid-turn (StopFailure):"
# rate_limit -> log line, notification, note for the next start; never a resume
# unless CONTINUUM_RESUME_ON_LIMIT=1. The notifier is swapped for a recorder.
$lhRec = Join-Path $tmp 'lh_rec.ps1'
Set-Content -Path $lhRec -Value 'Add-Content -Path $env:LH_OUT -Value ("{0}|{1}" -f $args[0], $args[1])'
$lhDir = Join-Path $tmp 'lh_proj'; New-Item -ItemType Directory -Force -Path $lhDir | Out-Null
$lhDirJson = $lhDir.Replace('\', '\\')
$nowLh = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
function Lh ($cfg, $l1, $l2, $stdin) {
    $st = Join-Path $tmp $cfg; New-Item -ItemType Directory -Force -Path $st | Out-Null
    Set-Content -Path (Join-Path $st '.continuum-cache-mock') -Value @($l1, $l2)
    $env:LH_OUT = Join-Path $st 'notified'
    $env:CONTINUUM_NOTIFY_CMD = "pwsh -NoProfile -File $lhRec"
    $env:CONTINUUM_STATE_DIR = $st
    $stdin | & pwsh -NoProfile -File (Join-Path $root 'adapters/claude/stop-failure.ps1') *> $null
    Remove-Item Env:CONTINUUM_NOTIFY_CMD, Env:LH_OUT -ErrorAction SilentlyContinue
    $f = Join-Path $st 'notified'
    if (Test-Path $f) { return (Get-Content -Raw $f) } else { return '' }
}
$p1 = "5h 100.0 $($nowLh + 3600)"; $w1 = "7d 60.0 $($nowLh + 4 * 86400)"
$evC = '{"hook_event_name":"StopFailure","session_id":"c1","transcript_path":"/t.jsonl","cwd":"' + $lhDirJson + '","error":"rate_limit","error_details":"429"}'
$out = Lh 'lh1' $p1 $w1 $evC
Check "limit hit notifies" 'continuum|limit hit in lh_proj, resets ' $out
Check "limit hit asks for a resume by hand" 'run continuum resume with your task' $out
if ($out -notmatch 'Resume scheduled') { Ok "limit hit never resumes without consent" } else { Bad "limit hit never resumes without consent" $out }
$out = Lh 'lh1' $p1 $w1 $evC
if (@($out.Trim() -split "`n").Count -eq 1) { Ok "limit hit once per session per window" } else { Bad "limit hit once per session per window" $out }
$out = Lh 'lh2' $p1 $w1 '{"session_id":"c2","transcript_path":"/t","error":"server_error"}'
if (-not $out) { Ok "other StopFailure errors stay silent" } else { Bad "other StopFailure errors stay silent" $out }
$env:CONTINUUM_RESUME_ON_LIMIT = '1'; $env:CONTINUUM_DRY_RUN = '1'
$out = Lh 'lh5' $p1 $w1 ('{"session_id":"j2","project_path":"' + $lhDirJson + '","error":"rate_limit"}')
Check "consent in advance schedules a resume" 'Resume scheduled for ' $out
Check "the resume uses the agent's preset" 'junie --skip-update-check --resume --task' $out
$out = Lh 'lh6' "5h 40.0 $($nowLh + 3600)" "7d 100.0 $($nowLh + 4 * 86400)" $evC
Check "no resume when the reset is days away" 'more than a day away' $out
Remove-Item Env:CONTINUUM_RESUME_ON_LIMIT, Env:CONTINUUM_DRY_RUN
# Control characters in the directory name must not forge note lines (not possible on
# Windows: such names are invalid there).
if (-not $IsWindows) {
    $st7 = Join-Path $tmp 'lh7'; New-Item -ItemType Directory -Force -Path $st7 | Out-Null
    Copy-Item (Join-Path $tmp 'lh1/.continuum-cache-mock') $st7
    $nlDir = Join-Path $tmp "lh_bad`n1793000000`tforged"; New-Item -ItemType Directory -Force -Path $nlDir | Out-Null
    $env:CONTINUUM_STATE_DIR = $st7; $env:CONTINUUM_NOTIFY_CMD = "pwsh -NoProfile -File $lhRec"; $env:LH_OUT = Join-Path $st7 'notified'
    & pwsh -NoProfile -File (Join-Path $root 'bin/continuum.ps1') limit-hit c9 claude $nlDir *> $null
    Remove-Item Env:CONTINUUM_NOTIFY_CMD, Env:LH_OUT -ErrorAction SilentlyContinue
    $n = @(Get-Content (Join-Path $st7 '.continuum-limit-notes')).Count
    if ($n -eq 1) { Ok "control chars cannot forge note lines" } else { Bad "control chars cannot forge note lines" "$n lines" }
}
$hj = Get-Content -Raw (Join-Path $root 'hooks/hooks.json')
if ($hj.Contains('"matcher": "rate_limit"') -and $hj.Contains('stop-failure.sh')) { Ok "hooks.json wires StopFailure rate_limit" } else { Bad "hooks.json wires StopFailure rate_limit" "missing" }
$env:CONTINUUM_STATE_DIR = Join-Path $tmp 'state'
$env:CONTINUUM_STATE_DIR = Join-Path $tmp 'state'

Write-Host "other agents:"
# Every adapter: the reply shape its agent expects, the loop guard, the tier shared
# between its end-of-turn and mid-turn hooks, and silence on any failure.
function Ad ($script, $cfg, $stdin) {
    $env:CONTINUUM_STATE_DIR = Join-Path $tmp $cfg
    $out = $stdin | & pwsh -NoProfile -File (Join-Path $root "adapters/$script") 2>$null
    return ($out -join '')
}
Check "codex stop blocks" '"decision":"block"' (Ad 'codex/stop.ps1' 'cx1' '{"session_id":"c1"}')
if (-not (Ad 'codex/stop.ps1' 'cx2' '{"session_id":"c2","stop_hook_active":true}')) { Ok "codex respects stop_hook_active" } else { Bad "codex respects stop_hook_active" "warned" }
Check "codex mid-turn context" '"hookEventName":"PostToolUse"' (Ad 'codex/tool-check.ps1' 'cx3' '{"session_id":"c3"}')
if (-not (Ad 'codex/stop.ps1' 'cx3' '{"session_id":"c3"}')) { Ok "codex tier shared by both hooks" } else { Bad "codex tier shared by both hooks" "warned twice" }
Check "gemini after-agent denies" '"decision":"deny"' (Ad 'gemini/after-agent.ps1' 'gm1' '{"session_id":"g1"}')
if (-not (Ad 'gemini/after-agent.ps1' 'gm2' '{"session_id":"g2","stop_hook_active":true}')) { Ok "gemini respects stop_hook_active" } else { Bad "gemini respects stop_hook_active" "warned" }
Check "gemini mid-turn context" '"hookEventName":"AfterTool"' (Ad 'gemini/after-tool.ps1' 'gm3' '{"session_id":"g3"}')
Check "cursor stop follows up" '"followup_message":"[continuum]' (Ad 'cursor/stop.ps1' 'cu1' '{"conversation_id":"u1","status":"completed","loop_count":0}')
if (-not (Ad 'cursor/stop.ps1' 'cu2' '{"conversation_id":"u2","status":"completed","loop_count":1}')) { Ok "cursor respects loop_count" } else { Bad "cursor respects loop_count" "warned" }
if (-not (Ad 'cursor/stop.ps1' 'cu3' '{"conversation_id":"u3","status":"aborted","loop_count":0}')) { Ok "cursor silent after an aborted turn" } else { Bad "cursor silent after an aborted turn" "warned" }
Check "cursor mid-turn context" '"additional_context":"Mid-turn usage check.' (Ad 'cursor/tool-check.ps1' 'cu4' '{"conversation_id":"u4"}')
if (-not (Ad 'cursor/stop.ps1' 'cu4' '{"conversation_id":"u4","status":"completed","loop_count":0}')) { Ok "cursor tier shared by both hooks" } else { Bad "cursor tier shared by both hooks" "warned twice" }
$f = 0
foreach ($a in @('codex/stop.ps1', 'codex/tool-check.ps1', 'gemini/after-agent.ps1', 'gemini/after-tool.ps1', 'cursor/stop.ps1', 'cursor/tool-check.ps1')) {
    $env:CONTINUUM_OFF = '1'
    if (Ad $a 'off' '{"session_id":"o","conversation_id":"o"}') { Bad "$a respects CONTINUUM_OFF" "warned"; $f = 1 }
    Remove-Item Env:CONTINUUM_OFF
    $env:CONTINUUM_MOCK = '46.0 10.0'
    if (Ad $a 'low' '{"session_id":"l","conversation_id":"l"}') { Bad "$a silent under threshold" "warned"; $f = 1 }
    Remove-Item Env:CONTINUUM_MOCK
    $j = Ad $a ("json" + ($a -replace '[/.]', '_')) '{"session_id":"j","conversation_id":"j"}'
    try { $j | ConvertFrom-Json | Out-Null } catch { Bad "$a prints valid JSON" $j; $f = 1 }
}
if ($f -eq 0) { Ok "adapters: CONTINUUM_OFF, under threshold, valid JSON" }
if (Get-Command node -ErrorAction SilentlyContinue) {
    $env:CONTINUUM_ROOT = $root
    $env:CONTINUUM_STATE_DIR = Join-Path $tmp 'oc'
    $oc = (& node (Join-Path $root 'tests/opencode.mjs') (Join-Path $root 'adapters/opencode/continuum.js') 2>&1) -join "`n"
    Remove-Item Env:CONTINUUM_ROOT
    foreach ($want in @('idle prompts the session', 'idle fires once per tier', 'child session is skipped', 'mid-turn appends to tool output', 'off is silent')) {
        Check "opencode: $want" "ok $want" $oc
    }
} else { Write-Host '  skip opencode plugin (no node)' }
$env:CONTINUUM_STATE_DIR = Join-Path $tmp 'state'

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
$env:CONTINUUM_STATE_DIR = $slDir
$env:CONTINUUM_PROVIDER = 'mock'
$nowSec = [int64][datetimeoffset]::UtcNow.ToUnixTimeSeconds()
$dReset = $nowSec + 3600
$wReset = $nowSec + 4 * 86400
Set-Content -Path (Join-Path $slDir '.continuum-cache-mock') -Value @("5h 46.0 $dReset", "7d 94.0 $wReset")

function Invoke-StatuslineHook {
    $slOut = & pwsh -NoProfile -File (Join-Path $root 'adapters/claude/statusline.ps1') 2>$null
    return ($slOut -join '')
}

$slOut = Invoke-StatuslineHook
Check "statusline shows daily percent" "46%" $slOut
Check "statusline shows weekly percent" "94%" $slOut
Check "statusline shows today for daily" "today" $slOut
if ($slOut -notmatch '\x1b\[0m%') { Ok "statusline no double percent" } else { Bad "statusline no double percent" "got: $slOut" }
$null = Invoke-Continuum statusline format '{d%}% d {dr} | {w%}% w {wr}'
$slOut = Invoke-StatuslineHook
if ($slOut -notmatch '\x1b\[0m%') { Ok "statusline legacy format no double percent" } else { Bad "statusline legacy format no double percent" "got: $slOut" }

# A cache past its window's reset (or long untouched) is refreshed synchronously.
$sfDir = Join-Path $tmp 'sl_stale'
New-Item -ItemType Directory -Force -Path $sfDir | Out-Null
$sfCache = Join-Path $sfDir '.continuum-cache-mock'
$env:CONTINUUM_STATE_DIR = $sfDir
Set-Content -Path $sfCache -Value @("5h 12.0 $($nowSec - 60)", "7d 20.0 $wReset")
$env:CONTINUUM_MOCK = '77.0 33.0'
Check "statusline refreshes past-reset cache before render" "77%" (Invoke-StatuslineHook)
Set-Content -Path $sfCache -Value @("5h 12.0 $dReset", "7d 20.0 $wReset")
(Get-Item -Force $sfCache).LastWriteTime = [datetime]'2020-01-01'
$env:CONTINUUM_MOCK = '78.0 33.0'
Check "statusline refreshes old cache before render" "78%" (Invoke-StatuslineHook)
Set-Content -Path $sfCache -Value @("5h 12.0 $dReset", "7d 20.0 $wReset")
$env:CONTINUUM_MOCK = '79.0 33.0'
Check "statusline shows fresh cache as-is" "12%" (Invoke-StatuslineHook)
# Provider down: old cache stays, a .retry marker backs off further attempts.
Set-Content -Path $sfCache -Value @("5h 12.0 $($nowSec - 60)", "7d 20.0 $wReset")
$env:CONTINUUM_MOCK_FAIL = '1'
Check "statusline keeps old cache when provider fails" "12%" (Invoke-StatuslineHook)
Remove-Item Env:CONTINUUM_MOCK_FAIL
if (Test-Path "$sfCache.retry") { Ok "statusline failed refresh leaves retry marker" } else { Bad "statusline failed refresh leaves retry marker" "missing" }
$env:CONTINUUM_MOCK = '80.0 33.0'
Check "statusline backs off while retry marker is fresh" "12%" (Invoke-StatuslineHook)
(Get-Item -Force "$sfCache.retry").LastWriteTime = [datetime]'2020-01-01'
$env:CONTINUUM_MOCK = '81.0 33.0'
Check "statusline retries after backoff" "81%" (Invoke-StatuslineHook)
if (-not (Test-Path "$sfCache.retry")) { Ok "statusline success clears retry marker" } else { Bad "statusline success clears retry marker" "still there" }
Set-Content -Path $sfCache -Value @("5h 12.0 99999999999999999999999")
$env:CONTINUUM_MOCK = '82.0 33.0'
Check "statusline survives garbage epoch" "12%" (Invoke-StatuslineHook)
# Leftover tmp files from a killed refresh are swept once old.
$oldTmp = "$sfCache.111.tmp"; $newTmp = "$sfCache.222.tmp"
Set-Content -Path $oldTmp -Value ''; (Get-Item -Force $oldTmp).LastWriteTime = (Get-Date).AddHours(-1)
Set-Content -Path $newTmp -Value ''
Invoke-StatuslineHook | Out-Null
if (-not (Test-Path $oldTmp)) { Ok "statusline sweeps old tmp files" } else { Bad "statusline sweeps old tmp files" "left" }
if (Test-Path $newTmp) { Ok "statusline keeps fresh tmp files" } else { Bad "statusline keeps fresh tmp files" "removed" }
Remove-Item Env:CONTINUUM_MOCK
$env:CONTINUUM_STATE_DIR = $slDir

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
