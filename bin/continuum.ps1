# continuum - see the limit coming, decide what to do, pick up where you stopped.
#
#   continuum.ps1 status         utilization of every window the provider reports
#   continuum.ps1 reset          local HH:mm when the primary window rolls over (+90s)
#   continuum.ps1 estimate       extrapolate time remaining at current pace
#   continuum.ps1 providers      list available providers
#   continuum.ps1 check [--session ID] [--agent NAME]
#                                print a warning if a new tier was crossed, else nothing
#   continuum.ps1 resume HH:MM [dir] [prompt]
#                                schedule the agent to pick up after the reset
#   continuum.ps1 history        show recent usage snapshots
#   continuum.ps1 cleanup        remove stale flag/cache files (>24h old)
#   continuum.ps1 statusline [key value | reset]
#                                show or configure status-line format

param(
    [Parameter(Position = 0)][string]$Command = 'status',
    [Parameter(Position = 1)][string]$Arg1,
    [Parameter(Position = 2)][string]$Arg2,
    [Parameter(Position = 3)][string]$Arg3,
    [Parameter(Position = 4)][string]$Arg4,
    # `check --session X --agent Y`: under `pwsh -File` the double-dash names bind
    # here; called in-process they arrive positionally. Both paths are handled.
    [string]$Session,
    [string]$Agent
)

# param() must be the first statement in the file - everything else comes after.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '../lib/core.ps1')
Set-CntRootPointer

function Format-Label {
    param([string]$W)
    switch ($W) {
        '5h' { return '5 hours ' }
        '7d' { return '7 days  ' }
        default { return $W.PadRight(8) }
    }
}

function Invoke-Status {
    $allLines = @(Read-CntUsage)
    foreach ($line in $allLines) {
        $p = $line.Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
        $when = '?'
        if ($p.Count -ge 3 -and $p[2] -ne '-') {
            try { $when = ConvertTo-CntHhmm ([int64]$p[2]) } catch { $when = '?' }
        }
        '{0} {1,5}%   resets at {2}' -f (Format-Label $p[0]), $p[1], $when
    }
    # Append to history log
    $hist = Join-Path $script:CntState '.continuum-history.log'
    New-Item -ItemType Directory -Force -Path $script:CntState 2>$null | Out-Null
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm'
    $summary = ($allLines | ForEach-Object { $p = $_.Split(' ', [StringSplitOptions]::RemoveEmptyEntries); "$($p[0]):$($p[1])%" }) -join ' '
    try { Add-Content -Path $hist -Value "$ts  $summary" } catch {}
}

function Invoke-Reset {
    $first = @(Read-CntUsage)[0].Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
    if ($first.Count -lt 3 -or $first[2] -eq '-') {
        throw "provider '$($script:CntProvider)' reports no reset time"
    }
    # +90s margin: wake up after the reset, not a second before it
    ConvertTo-CntHhmm ([int64]$first[2]) 90
}

# Which agent to wake up. {prompt} is replaced with the task description.
# CONTINUUM_RESUME_CMD wins; otherwise the preset for CONTINUUM_AGENT (default claude).
# Presets arrive with each agent's adapter, once its headless flags are verified.
function Get-CntResumePreset {
    param([string]$Agent)
    switch ($Agent) {
        'claude' { return 'claude --continue -p "{prompt}" --permission-mode acceptEdits' }
        default  { return $null }
    }
}

function Get-CntResumeCmd {
    if ($env:CONTINUUM_RESUME_CMD) { return $env:CONTINUUM_RESUME_CMD }
    $agent = 'claude'
    if ($env:CONTINUUM_AGENT) { $agent = $env:CONTINUUM_AGENT }
    $preset = Get-CntResumePreset $agent
    if (-not $preset) { throw "no resume preset for agent '$agent' - set CONTINUUM_RESUME_CMD, e.g. 'myagent run `"{prompt}`"'" }
    return $preset
}

function Invoke-Resume {
    param([string]$Hhmm, [string]$Dir, [string]$Prompt)

    if (-not $Hhmm) { throw 'continuum resume: need HH:MM' }
    if (-not $Dir)  { $Dir = $PWD.Path }
    if (-not $Prompt) { $Prompt = 'continue, please' }
    if (-not (Test-Path $Dir)) { throw "no such directory: $Dir" }

    $tmpl = Get-CntResumeCmd

    # The prompt ends up as PowerShell code inside -Command: neutralise the
    # characters that would otherwise expand or break quoting at resume time
    # ($, backtick) or at schedule time ("). Single quotes are doubled for
    # templates that place {prompt} inside '...'. Mirrors the sh escaping.
    $escPrompt = $Prompt.Replace('`', '``').Replace('$', '`$').Replace('"', '`"').Replace("'", "''")
    $cmd = $tmpl.Replace('{prompt}', $escPrompt)

    $delay = Get-CntHhmmDelay $Hhmm

    # Dry run prints the command it *would* run - the agent need not be installed here.
    if ($env:CONTINUUM_DRY_RUN) {
        "would sleep $delay then run in ${Dir}: $cmd"
        return
    }

    $agent = $tmpl.Split(' ')[0]
    if (-not (Get-Command $agent -ErrorAction SilentlyContinue)) { throw "'$agent' not found in PATH" }

    $log = Join-Path $script:CntState 'continuum-resume.log'
    New-Item -ItemType Directory -Force -Path $script:CntState | Out-Null
    Add-Content -Path $log -Value "`n=== scheduled $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') for $Hhmm in $Dir"

    # Wakelock: prevent system sleep during wait + execution.
    $wlFile = Start-CntWakeLock ($delay + 7200)
    $wlCleanup = ''
    if ($wlFile) { $wlCleanup = "; Stop-CntWakeLock '$wlFile'" }

    # Detached: survives closing the terminal, does NOT survive a reboot.
    # The wakelock is released after the task finishes (or on cancel).
    # Paths are single-quote escaped: a project dir like C:\o'brien must not
    # break out of Set-Location '...'.
    $corePs1 = Join-Path $PSScriptRoot '../lib/core.ps1'
    $escCore = $corePs1.Replace("'", "''")
    $escDir = $Dir.Replace("'", "''")
    $escLog = $log.Replace("'", "''")
    $inner = ". '$escCore'; Start-Sleep -Seconds $delay; Set-Location '$escDir'; $cmd *>> '$escLog'$wlCleanup"
    $ps = (Get-Process -Id $PID).Path
    $proc = Start-Process -FilePath $ps -WindowStyle Hidden -PassThru `
                          -ArgumentList '-NoProfile', '-NonInteractive', '-Command', $inner

    "Resuming in {0} min (at {1}) in {2}: `"{3}`"" -f [int]($delay / 60), $Hhmm, $Dir, $Prompt
    "Scheduled, PID {0}. Cancel: Stop-Process -Id {0}   Log: {1}" -f $proc.Id, $log
    if ($wlFile) { 'Sleep inhibited (wakelock). Releases after task completion.' }
    'It runs headless - it will edit code unattended.'
}

# The closing sentence tells the agent how to ask the user. Only the wording depends
# on the agent: the tiers, cache and flags do not. Mirrors cnt_ask_hint.
function Get-CntAskHint {
    param([string]$Agent)
    switch ($Agent) {
        'claude' { return 'Do not end the turn silently: run the session-budget skill - briefly state where we stopped, then use AskUserQuestion to ask the user how to spend the rest of the window, offering the options from that skill.' }
        default  { return 'Do not end the turn silently: briefly state where we stopped, then ask the user how to spend the rest of the window - finish and wrap up, finish the current batch, save state and schedule a resume after the reset (continuum resume), frugal mode, cheap tasks only, or carry on.' }
    }
}

# Agent-neutral core of every in-session warning (mirrors `continuum check`). Returns
# the warning when usage crosses a tier not yet warned about in this session, and
# nothing otherwise. Never throws except on bad arguments: a failing provider must
# never break an agent turn. Adapters translate their agent's event into -Session
# and this text into its reply.
function Invoke-Check {
    param([string[]]$CheckArgs, [string]$SessionArg, [string]$AgentArg)
    $sid = 'default'
    $agent = 'generic'
    if ($env:CONTINUUM_AGENT) { $agent = $env:CONTINUUM_AGENT }
    if ($SessionArg) { $sid = $SessionArg }
    if ($AgentArg) { $agent = $AgentArg }
    $a = @($CheckArgs | Where-Object { $_ })
    for ($i = 0; $i -lt $a.Count; $i += 2) {
        if ($i + 1 -ge $a.Count) { throw "continuum check: $($a[$i]) needs a value" }
        switch ($a[$i]) {
            '--session' { $sid = $a[$i + 1] }
            '--agent'   { $agent = $a[$i + 1] }
            default     { throw "continuum check: unknown argument '$($a[$i])'" }
        }
    }
    if ($env:CONTINUUM_OFF) { return }
    # The session id lands in a filename: allowlist it to close path traversal.
    if ($sid -notmatch '^[A-Za-z0-9_-]+$') {
        $sid = ($sid -replace '[^A-Za-z0-9_-]', '_')
        if (-not $sid) { $sid = 'unknown' }
    }

    try {
        New-Item -ItemType Directory -Force -Path $script:CntState | Out-Null

        $flag = Join-Path $script:CntState ".continuum-warned-$sid"
        # NB: no early "warn once then exit" here: tiers escalate (80->90->95->99),
        # so the flag stores the highest tier warned and is compared numerically below.

        # Providers hit rate-limited endpoints and this runs after every turn: cache hard,
        # and back off after a failure ("negative cache").
        $ttl    = 10
        if ($env:CONTINUUM_CACHE_MIN) { $ttl = [int]$env:CONTINUUM_CACHE_MIN }
        $cacheKey = ($script:CntProvider -replace '[^A-Za-z0-9_,-]', '_')
        $cache  = Join-Path $script:CntState ".continuum-cache-$cacheKey"
        $failed = "$cache.fail"
        # NB: Get-Item throws on dotfiles under macOS PowerShell (Test-Path on the
        # same path returns True), so read mtime via .NET which works everywhere.
        $fresh  = { param($f) (Test-Path $f) -and ((Get-Date) - [System.IO.File]::GetLastWriteTime($f)).TotalMinutes -lt $ttl }

        if (& $fresh $failed) { return }                # recently failed - do not retry yet

        if (& $fresh $cache) {
            $lines = @(Get-Content -Path $cache)
        } else {
            # @() is load-bearing: a function returning a one-element array unrolls it to a
            # scalar, and then $lines[0] would index into a string's characters.
            try { $lines = @(Read-CntUsage) }
            catch { New-Item -ItemType File -Force -Path $failed | Out-Null; return }
            Set-Content -Path $cache -Value $lines
            Remove-Item -Path $failed -ErrorAction SilentlyContinue
        }

        # First line is the primary window: <window> <utilization> <reset_epoch>
        $first = $lines[0].Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
        if ($first.Count -lt 2) { return }

        # A custom provider returning garbage must not throw past the trap: parse defensively.
        $utilInt = 0
        try { $utilInt = [int][math]::Floor([double]::Parse($first[1], [cultureinfo]::InvariantCulture)) } catch { $utilInt = 0 }

        $threshold = 80
        if ($env:CONTINUUM_THRESHOLD) { $threshold = [int]$env:CONTINUUM_THRESHOLD }

        # Escalating tiers for primary window
        $warned = 0
        if (Test-Path $flag) { $warned = [int](Get-Content $flag) }

        $tierList = @(80, 90, 95, 99)
        if ($env:CONTINUUM_TIERS) { $tierList = @($env:CONTINUUM_TIERS -split '\s+' | ForEach-Object { [int]$_ }) }
        $tier = 0; $tiersStr = ''
        foreach ($t in $tierList) {
            if ($t -lt $threshold) { continue }
            $tiersStr += $(if ($tiersStr) { "/$t" } else { "$t" })
            if ($utilInt -ge $t -and $t -gt $tier) { $tier = $t }
        }

        # If utilization dropped below the floor (limit top-up, window rollover),
        # re-arm: tiers fire again on the way back up. Mirrors the sh hook.
        if ($utilInt -lt $threshold -and (Test-Path $flag)) { Remove-Item -Path $flag -Force -ErrorAction SilentlyContinue }

        # Weekly window tiers
        $flag7 = Join-Path $script:CntState ".continuum-warned7d-$sid"
        $warned7 = 0
        if (Test-Path $flag7) { $warned7 = [int](Get-Content $flag7) }

        $threshold7 = 70
        if ($env:CONTINUUM_THRESHOLD_7D) { $threshold7 = [int]$env:CONTINUUM_THRESHOLD_7D }
        $tierList7 = @(70, 85, 95)
        if ($env:CONTINUUM_TIERS_7D) { $tierList7 = @($env:CONTINUUM_TIERS_7D -split '\s+' | ForEach-Object { [int]$_ }) }
        $tier7 = 0; $tiers7Str = ''; $util7Int = 0
        if ($lines.Count -gt 1) {
            $second = $lines[1].Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
            if ($second.Count -ge 2) {
                try { $util7Int = [int][math]::Floor([double]::Parse($second[1], [cultureinfo]::InvariantCulture)) } catch { $util7Int = 0 }
                foreach ($t in $tierList7) {
                    if ($t -lt $threshold7) { continue }
                    $tiers7Str += $(if ($tiers7Str) { "/$t" } else { "$t" })
                    if ($util7Int -ge $t -and $t -gt $tier7) { $tier7 = $t }
                }
            }
        }

        # Re-arm the weekly flag on drop below its floor, same as the primary window.
        if ($lines.Count -gt 1 -and $util7Int -lt $threshold7 -and (Test-Path $flag7)) {
            Remove-Item -Path $flag7 -Force -ErrorAction SilentlyContinue
        }

        $primaryNew = ($tier -gt 0 -and $tier -gt $warned)
        $weeklyNew  = ($tier7 -gt 0 -and $tier7 -gt $warned7)
        if (-not $primaryNew -and -not $weeklyNew) { return }

        $when = ''
        if ($first.Count -ge 3 -and $first[2] -ne '-') {
            try { $when = ConvertTo-CntHhmm ([int64]$first[2]) } catch { $when = '' }
        }

        $rest = ''
        if ($lines.Count -gt 1) {
            $extra = $lines[1..($lines.Count - 1)] | ForEach-Object {
                $p = $_.Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
                "$($p[0]) window $($p[1])%"
            }
            $rest = $extra -join ', '
        }

        $reason = ''
        if ($primaryNew) {
            Set-Content -Path $flag -Value $tier
            $reason = "[continuum] The primary usage window is $utilInt% used (crossed the $tier% tier)"
            if ($when) { $reason += ", resets at $when" }
        }
        if ($weeklyNew) {
            Set-Content -Path $flag7 -Value $tier7
            if ($reason) {
                $reason += ". The weekly window also crossed the $tier7% tier ($util7Int% used)"
            } else {
                $reason = "[continuum] The weekly window is $util7Int% used (crossed the $tier7% tier)"
                if ($when) { $reason += ". Primary: $utilInt%, resets at $when" }
            }
        }
        if ($rest -and $primaryNew) { $reason += ". Also: $rest" }
        $reason += ". $(Get-CntAskHint $agent)"
        if ($primaryNew) { $reason += " Primary tiers fire once each ($tiersStr)." }
        if ($weeklyNew)  { $reason += " Weekly tiers fire once each ($tiers7Str)." }
        $reason
    } catch { return }
}

# Harness-independent fallback: no hooks, no plugin, works with any agent in any
# shell. Poll until the threshold is crossed, say so, exit. Run it in a spare pane.
function Invoke-Watch {
    param([int]$Every = 300)

    $threshold = 80
    if ($env:CONTINUUM_THRESHOLD) { $threshold = [int]$env:CONTINUUM_THRESHOLD }

    while ($true) {
        $lines = $null
        try { $lines = @(Read-CntUsage) } catch { $lines = $null }
        if ($lines) {
            $f = $lines[0].Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
            $utilInt = [int][math]::Floor([double]::Parse($f[1], [cultureinfo]::InvariantCulture))
            if ($utilInt -ge $threshold) {
                $when = '?'; $at = '?'
                if ($f.Count -ge 3 -and $f[2] -ne '-') {
                    $when = ConvertTo-CntHhmm ([int64]$f[2])
                    $at   = ConvertTo-CntHhmm ([int64]$f[2]) 90
                }
                Write-Host "`acontinuum: $utilInt% used, resets at $when"
                Write-Host "Wrap up, or: continuum resume $at `"`$PWD`" `"<task>`""
                return
            }
            Write-Host "continuum: $utilInt% used, below $threshold%"
        }
        Start-Sleep -Seconds $Every
    }
}

function Invoke-Estimate {
    $first = @(Read-CntUsage)[0].Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
    if ($first.Count -lt 3 -or $first[2] -eq '-') { throw 'no reset time available' }
    $util = [double]::Parse($first[1], [cultureinfo]::InvariantCulture)
    $utilI = [int][math]::Floor($util)
    if ($utilI -le 0) { 'No usage yet.'; return }
    $now = [datetimeoffset]::UtcNow.ToUnixTimeSeconds()
    $reset = [int64]$first[2]
    $remaining = $reset - $now
    if ($remaining -le 0) { 'Window has already reset.'; return }
    $left = [int]($remaining * (100 - $utilI) / $utilI)
    if ($left -ge 3600) {
        'At this pace, ~{0}h {1}m left before 100%' -f [int]($left / 3600), [int](($left % 3600) / 60)
    } elseif ($left -ge 60) {
        'At this pace, ~{0} min left before 100%' -f [int]($left / 60)
    } else {
        'At this pace, less than a minute left.'
    }
    $when = ConvertTo-CntHhmm $reset
    "Currently $($first[1])% used, window resets at $when"
}

function Invoke-History {
    $hist = Join-Path $script:CntState '.continuum-history.log'
    if (-not (Test-Path $hist)) { 'No history yet. History is recorded on each status check.'; return }
    Get-Content $hist | Select-Object -Last 20
}

function Invoke-Cleanup {
    $cleaned = 0
    $cutoff = (Get-Date).AddHours(-24)
    foreach ($pattern in @('.continuum-warned-*', '.continuum-warned7d-*', '.continuum-cache-*', '.continuum-wakelock-*')) {
        # NB: -Force is load-bearing - without it the provider skips dotfiles
        # on some platforms (macOS) and cleanup would silently clean nothing.
        Get-ChildItem -Path $script:CntState -Force -Filter $pattern -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } | ForEach-Object {
                Remove-Item $_.FullName -Force; $cleaned++
            }
    }
    "Cleaned $cleaned stale files."
}

# Show or configure the status-line format (mirrors `continuum statusline`).
# Shares .continuum-statusline.conf with adapters/claude/statusline.ps1 and the sh status line.
function Get-CntSlConfValue {
    param([string]$Key, [string]$Default)
    $conf = Join-Path $script:CntState '.continuum-statusline.conf'
    if (Test-Path $conf) {
        foreach ($line in (Get-Content -Path $conf)) {
            if ($line.StartsWith("$Key=", [StringComparison]::Ordinal)) {
                $v = $line.Substring($Key.Length + 1)
                if ($v) { return $v }
                return $Default
            }
        }
    }
    return $Default
}

function Set-CntSlConfValue {
    param([string]$Key, [string]$Val)
    $conf = Join-Path $script:CntState '.continuum-statusline.conf'
    New-Item -ItemType Directory -Force -Path $script:CntState | Out-Null
    $kept = @()
    if (Test-Path $conf) {
        $kept = @(Get-Content -Path $conf | Where-Object { -not $_.StartsWith("$Key=", [StringComparison]::Ordinal) })
    }
    Set-Content -Path $conf -Value ($kept + @("$Key=$Val"))
}

function Invoke-StatuslineConfig {
    param([string]$Key, [string]$Val)
    $conf = Join-Path $script:CntState '.continuum-statusline.conf'

    if (-not $Key) {
        "Status-line config ($conf):"
        "  format        = $(Get-CntSlConfValue 'FORMAT' '{d%}% d {dr} | {w%}% w {wr}')"
        "  format-single = $(Get-CntSlConfValue 'FORMAT_SINGLE' '{d%}% d {dr}')"
        "  time          = $(Get-CntSlConfValue 'TIME_FORMAT' '%H:%M')"
        "  date          = $(Get-CntSlConfValue 'DATE_FORMAT' '%d.%m')"
        "  today         = $(Get-CntSlConfValue 'TODAY' 'today')"
        ""
        "Tokens: {d%} daily%, {w%} weekly%, {dr} daily reset, {wr} weekly reset"
        return
    }

    if ($Key -eq 'reset') {
        Remove-Item -Path $conf -Force -ErrorAction SilentlyContinue
        'Status-line config reset to defaults.'
        return
    }

    if (-not $Val) { throw 'continuum statusline: need a value' }

    switch ($Key) {
        'format'        { Set-CntSlConfValue 'FORMAT' $Val }
        'format-single' { Set-CntSlConfValue 'FORMAT_SINGLE' $Val }
        'time'          { Set-CntSlConfValue 'TIME_FORMAT' $Val }
        'date'          { Set-CntSlConfValue 'DATE_FORMAT' $Val }
        'today'         { Set-CntSlConfValue 'TODAY' $Val }
        default         { throw "continuum statusline: unknown key '$Key'`n  keys: format, format-single, time, date, today" }
    }
    "Set $Key = $Val"
}

switch ($Command) {
    'status'    { Invoke-Status }
    'reset'     { Invoke-Reset }
    'estimate'  { Invoke-Estimate }
    'providers' { Get-CntProviders }
    'check'     { Invoke-Check @($Arg1, $Arg2, $Arg3, $Arg4) $Session $Agent }
    'watch'     { if ($Arg1) { Invoke-Watch ([int]$Arg1) } else { Invoke-Watch } }
    'resume'    { Invoke-Resume $Arg1 $Arg2 $Arg3 }
    'history'   { Invoke-History }
    'cleanup'   { Invoke-Cleanup }
    'statusline' { Invoke-StatuslineConfig $Arg1 $Arg2 }
    default     { [Console]::Error.WriteLine("continuum: unknown command '$Command'"); exit 1 }
}
