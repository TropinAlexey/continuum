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
    [string]$Agent,
    # `doctor --fix` binds here under `pwsh -File`, positionally in-process.
    [switch]$Fix
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
# CONTINUUM_RESUME_CMD wins; then the bb thread (BB_THREAD_ID); otherwise the preset
# for CONTINUUM_AGENT (default claude). Presets arrive with each agent's adapter,
# once its headless flags are verified.
function Get-CntResumePreset {
    param([string]$Agent)
    switch ($Agent) {
        'claude'   { return 'claude --continue -p "{prompt}" --permission-mode acceptEdits' }
        'codex'    { return 'codex exec resume --last -c sandbox_mode=workspace-write "{prompt}"' }
        'gemini'   { return 'gemini --resume latest --approval-mode auto_edit -p "{prompt}"' }
        'cursor'   { return 'agent -p --continue "{prompt}"' }
        'opencode' { return 'opencode run --continue "{prompt}"' }
        'junie'    { return 'junie --skip-update-check --resume --task "{prompt}"' }
        default  { return $null }
    }
}

# Inside a bb thread (bb.app sets BB_THREAD_ID for the agent it runs) the resume goes
# back into that same thread, not into a separate headless session. The id is baked in
# now: the scheduled job runs later without the agent's environment.
function Get-CntBbResume {
    $id = $env:BB_THREAD_ID
    if (-not $id -or $id -notmatch '^[A-Za-z0-9_-]+$') { return $null }
    # Absolute path: the scheduled job may run with a shorter PATH than this shell.
    # Unquoted in the template, so a path with a space falls back to the bare name.
    $bb = ''
    $cmd = Get-Command bb -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { $bb = $cmd.Source }
    if (-not $bb) {
        $home_bb = Join-Path (Join-Path $HOME '.bb') (Join-Path 'bin' 'bb')
        if (Test-Path $home_bb) { $bb = $home_bb }
    }
    if (-not $bb -or $bb -match ' ') { $bb = 'bb' }
    return "$bb thread tell $id `"{prompt}`""
}

function Get-CntResumeCmd {
    if ($env:CONTINUUM_RESUME_CMD) { return $env:CONTINUUM_RESUME_CMD }
    $bb = Get-CntBbResume
    if ($bb) { return $bb }
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
    if ($wlFile) { $wlCleanup = "; Stop-CntWakeLock '$($wlFile.Replace("'", "''"))'" }

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
        # Junie has no question tool and its Stop hook fires right before it submits
        # the task, so the question goes at the end of the final message.
        'junie'  { return 'Do not end the task silently: run the session-budget skill - briefly state where we stopped, then end your final message by asking the user how to spend the rest of the window, offering the options from that skill. To schedule a resume: CONTINUUM_AGENT=junie continuum resume.' }
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
            $when7 = ''
            $p7 = $lines[1].Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
            if ($p7.Count -ge 3 -and $p7[2] -match '^[0-9]+$') {
                try { $when7 = ConvertTo-CntDayHhmm ([int64]$p7[2]) } catch { $when7 = '' }
            }
            $resets7 = if ($when7) { ", resets $when7" } else { '' }
            if ($reason) {
                $reason += ". The weekly window also crossed the $tier7% tier ($util7Int% used$resets7)"
            } else {
                $reason = "[continuum] The weekly window is $util7Int% used (crossed the $tier7% tier)$resets7"
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

# The limit ran out in the middle of a turn (StopFailure / rate_limit in Claude Code and
# Junie); mirrors `continuum limit-hit`. Nobody can be asked at that moment, so this only
# tells: a line in the resume log, a desktop notification, a note the next session start
# shows once. With CONTINUUM_RESUME_ON_LIMIT=1 - consent given in advance - it also
# schedules a resume for the reset. Never throws: a failing hook must not spam the user.
function Invoke-LimitHit {
    param([string]$SessionId, [string]$AgentName, [string]$Dir)
    try {
        $sid = ($(if ($SessionId) { $SessionId } else { 'unknown' }) -replace '[^A-Za-z0-9_-]', '_')
        $agentName = $AgentName
        if (-not $agentName) { $agentName = $(if ($env:CONTINUUM_AGENT) { $env:CONTINUUM_AGENT } else { 'claude' }) }
        if (-not $Dir) { $Dir = (Get-Location).Path }
        if ($env:CONTINUUM_OFF) { return }
        New-Item -ItemType Directory -Force -Path $script:CntState | Out-Null

        # No network from a turn that just failed on the limit: the exhausted window is the
        # cached line with the highest utilization (primary or weekly).
        $cacheKey = ($script:CntProvider -replace '[^A-Za-z0-9_,-]', '_')
        $cache = Join-Path $script:CntState ".continuum-cache-$cacheKey"
        $nr = 0; $reset = ''; $bu = -1.0
        if (Test-Path $cache) {
            $i = 0
            foreach ($line in [System.IO.File]::ReadAllLines($cache)) {
                $i++
                $p = $line.Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
                if ($p.Count -lt 3) { continue }
                $u = 0.0
                if (-not [double]::TryParse($p[1], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$u)) { continue }
                if ($nr -eq 0 -or $u -gt $bu) { $bu = $u; $nr = $i; $reset = $p[2] }
            }
        }
        if ($reset -notmatch '^[0-9]{1,12}$') { $reset = '' }
        $when = ''
        if ($reset) {
            if ($nr -eq 1) { $when = ConvertTo-CntHhmm ([int64]$reset) } else { $when = ConvertTo-CntDayHhmm ([int64]$reset) }
        }

        # Once per session per window.
        $flag = Join-Path $script:CntState ".continuum-limit-$sid"
        $mark = $(if ($reset) { $reset } else { '-' })
        if ((Test-Path $flag) -and ([System.IO.File]::ReadAllText($flag).Trim() -eq $mark)) { return }
        [System.IO.File]::WriteAllText($flag, $mark)

        $msg = "limit hit in $(Split-Path -Leaf $Dir)"
        if ($when) { $msg += ", resets $when" }
        if ($env:CONTINUUM_RESUME_ON_LIMIT -eq '1') {
            $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            if (-not $reset) {
                $msg += '. No reset time known, so no resume was scheduled - run continuum resume with your task'
            } elseif ([int64]$reset -le $now -or ([int64]$reset - $now) -gt 86400) {
                # `continuum resume` takes HH:MM (the next 24 h); a weekly reset days away
                # would fire too early and hit the limit again.
                $msg += '. The reset is more than a day away, so no resume was scheduled - run continuum resume with your task then'
            } else {
                $sha = [System.Security.Cryptography.SHA256]::Create()
                $hash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Dir))[0..7] | ForEach-Object { $_.ToString('x2') })
                $rflag = Join-Path $script:CntState ".continuum-limit-resume-$hash"
                if ((Test-Path $rflag) -and ([System.IO.File]::ReadAllText($rflag).Trim() -eq $reset)) {
                    $msg += '. A resume for this directory is already scheduled'
                } else {
                    $hhmm = ConvertTo-CntHhmm ([int64]$reset) 90
                    $task = 'The previous turn stopped on the usage limit. Continue the interrupted work from where it stopped'
                    $prev = $env:CONTINUUM_AGENT
                    try {
                        $env:CONTINUUM_AGENT = $agentName
                        $out = @(Invoke-Resume $hhmm $Dir $task) -join "`n"
                        [System.IO.File]::WriteAllText($rflag, $reset)
                        $first = @($out -split "`n" | Where-Object { $_ -match '^(would|Scheduled)' })[0]
                        $msg += ". Resume scheduled for $hhmm (CONTINUUM_RESUME_ON_LIMIT=1). $first"
                    } catch {
                        $msg += ". Scheduling the resume failed: $($_.Exception.Message)"
                    } finally {
                        if ($null -eq $prev) { Remove-Item Env:CONTINUUM_AGENT -ErrorAction SilentlyContinue } else { $env:CONTINUUM_AGENT = $prev }
                    }
                }
            }
        } else {
            $msg += ' - run continuum resume with your task'
        }

        # The directory name ends up in the log, the note and the agent's context at the next
        # session start: no control characters (a newline or tab would forge note lines).
        $msg = $msg -replace '[\x00-\x1f\x7f]', ''
        $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Add-Content -Path (Join-Path $script:CntState 'continuum-resume.log') -Value "`n### limit hit - $stamp - $msg"
        Add-Content -Path (Join-Path $script:CntState '.continuum-limit-notes') -Value ("{0}`t{1}" -f [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(), $msg)
        Send-CntNotification 'continuum' $msg
        $msg
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

function Invoke-CntHistory {
    $hist = Join-Path $script:CntState '.continuum-history.log'
    if (-not (Test-Path $hist)) { 'No history yet. History is recorded on each status check.'; return }
    Get-Content $hist | Select-Object -Last 20
}

# Why does the warning not fire? Mirrors `continuum doctor`: one line per check - ok /
# warn / fail / skip - and exit 1 on any fail. Read-only; -Fix (`doctor --fix`) applies
# only the safe fixes (statusline copy, root pointer). Never edits settings.json hooks.
function Invoke-CntDoctor {
    param([string]$Opt)
    $fix = ($Opt -eq '--fix')
    $script:docFails = 0
    function Say ($level, $text) { '{0,-4} {1}' -f $level, $text; if ($level -eq 'fail') { $script:docFails++ } }
    function Get-Ver ($f) {
        if ((Test-Path $f) -and ([System.IO.File]::ReadAllText($f) -match '"version"\s*:\s*"([^"]*)"')) { return $Matches[1] }
        return ''
    }
    $mine = Get-Ver (Join-Path $script:CntRoot '.claude-plugin/plugin.json')

    $lines = $null
    try { $lines = @(Read-CntUsage 2>$null 3>$null 6>$null) } catch { $lines = $null }
    if ($lines) {
        $p = $lines[0].Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
        Say 'ok' "provider $($script:CntProvider): $($p[0]) $($p[1])%"
    } else {
        Say 'fail' "provider $($script:CntProvider) gives no numbers (offline, rate limited, or no token): continuum status"
    }

    try {
        New-Item -ItemType Directory -Force -Path $script:CntState | Out-Null
        $probe = Join-Path $script:CntState '.continuum-doctor'
        [System.IO.File]::WriteAllText($probe, ''); Remove-Item -Force $probe
        Say 'ok' "state dir $($script:CntState)"
    } catch { Say 'fail' "state dir $($script:CntState) is not writable" }

    $ptrFile = Join-Path $script:CntState 'root'
    $ptr = ''
    if (Test-Path $ptrFile) { $ptr = [System.IO.File]::ReadAllText($ptrFile).Trim() }
    if ($ptr -and (Test-Path (Join-Path $ptr 'bin/continuum.ps1'))) {
        Say 'ok' "root pointer $ptr"
    } elseif ($fix) {
        try { Set-CntRootPointer; Say 'ok' "root pointer rewritten: $($script:CntRoot)" } catch { Say 'fail' "root pointer: cannot write $ptrFile" }
    } else {
        Say 'warn' "root pointer $(if ($ptr) { $ptr } else { 'missing' }) (a statusline copy cannot find the code): continuum doctor --fix"
    }

    $cdir = $(if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' })
    $settings = Join-Path $cdir 'settings.json'
    if (-not (Test-Path $settings)) {
        Say 'skip' "Claude Code: no $settings"
    } else {
        $sj = [System.IO.File]::ReadAllText($settings)
        if ($sj -match '"continuum@[^"]*"\s*:\s*true') { Say 'ok' 'Claude Code plugin enabled' }
        else { Say 'fail' "Claude Code plugin not enabled in ${settings}: /plugin install continuum@continuum" }
        $legacy = @([regex]::Matches($sj, 'token-budget-check\.sh|\.claude/lib/usage\.sh|/hooks/continuum-check\.(sh|ps1)') | ForEach-Object { $_.Value } | Sort-Object -Unique)
        if ($legacy.Count) { Say 'warn' "old hooks still wired in ${settings}: $($legacy -join ' ') - remove them from `"hooks`" (the plugin brings its own)" }
        else { Say 'ok' 'no old hooks in settings.json' }
        $copy = Join-Path $cdir 'hooks/statusline.ps1'
        $src = Join-Path $script:CntRoot 'adapters/claude/statusline.ps1'
        if (-not (Test-Path $copy) -or -not ([System.IO.File]::ReadAllText($copy) -match 'continuum')) {
            Say 'skip' 'statusline copy: none'
        } elseif ([System.IO.File]::ReadAllText($copy) -eq [System.IO.File]::ReadAllText($src)) {
            Say 'ok' 'statusline copy current'
        } elseif ($fix) {
            try { Copy-Item -Force $src $copy; Say 'ok' "statusline copy refreshed: $copy" } catch { Say 'fail' "statusline copy: cannot write $copy" }
        } else {
            Say 'warn' "statusline copy $copy differs from this version: continuum doctor --fix"
        }
        $cacheDir = Join-Path $cdir 'plugins/cache/continuum/continuum'
        $cached = ''
        if (Test-Path $cacheDir) {
            $cached = @(Get-ChildItem -Directory $cacheDir | ForEach-Object { $_.Name } | Where-Object { $_ -match '^\d+(\.\d+)*$' } |
                Sort-Object { [version]$_ }) | Select-Object -Last 1
        }
        if ($cached -and $mine -and $cached -ne $mine) { Say 'warn' "Claude Code runs plugin $cached, this code is ${mine}: /plugin update continuum, then restart the session" }
        elseif ($cached) { Say 'ok' "Claude Code plugin version $cached" }
    }

    $jhome = $(if ($env:JUNIE_HOME) { $env:JUNIE_HOME } else { Join-Path $HOME '.junie' })
    $jext = @(Get-ChildItem -Directory -Path (Join-Path $jhome 'extensions') -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'continuum' } | Where-Object { Test-Path $_ }) | Select-Object -First 1
    if (-not $jext) {
        Say 'skip' 'Junie: continuum extension not installed'
    } else {
        $jv = Get-Ver (Join-Path $jext '.claude-plugin/plugin.json')
        if ($mine -and $jv -ne $mine) { Say 'warn' "Junie extension is $(if ($jv) { $jv } else { 'unknown' }), this code is ${mine}: in Junie, /extensions -> update continuum" }
        else { Say 'ok' "Junie extension $jv" }
    }
    if ($script:docFails -gt 0) { exit 1 }
}

function Invoke-Cleanup {
    $cleaned = 0
    $cutoff = (Get-Date).AddHours(-24)
    foreach ($pattern in @('.continuum-warned-*', '.continuum-warned7d-*', '.continuum-cache-*', '.continuum-wakelock-*', '.continuum-limit-*')) {
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
        "  format        = $(Get-CntSlConfValue 'FORMAT' '{d%} d {dr} | {w%} w {wr}')"
        "  format-single = $(Get-CntSlConfValue 'FORMAT_SINGLE' '{d%} d {dr}')"
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
    'limit-hit' { Invoke-LimitHit $Arg1 $Arg2 $Arg3 }
    'watch'     { if ($Arg1) { Invoke-Watch ([int]$Arg1) } else { Invoke-Watch } }
    'resume'    { Invoke-Resume $Arg1 $Arg2 $Arg3 }
    'history'   { Invoke-CntHistory }
    'cleanup'   { Invoke-Cleanup }
    'doctor'    { Invoke-CntDoctor $(if ($Fix) { '--fix' } else { $Arg1 }) }
    'statusline' { Invoke-StatuslineConfig $Arg1 $Arg2 }
    default     { [Console]::Error.WriteLine("continuum: unknown command '$Command'"); exit 1 }
}
