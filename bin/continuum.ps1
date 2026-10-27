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
    [switch]$Fix,
    # `watch --ide`, the same way.
    [switch]$Ide,
    # `install --dry-run`, the same way (the alias carries the dash).
    [Alias('dry-run')][switch]$DryRun
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
# JetBrains IDE (R1), mirrors `watch --ide` in bin/continuum: the AI chat runs agents
# through ACP, where no hooks fire, so an outside poller shows the warning in the IDE
# through its MCP server. The IDE opens only files inside an open project, so the text
# goes to <project>/.git/continuum-warning.md: never tracked, never in `git status`.
function Get-CntIdeEndpoints {
    if ($env:CONTINUUM_IDE_MCP_URL) { return @($env:CONTINUUM_IDE_MCP_URL) }
    $names = 'rider|rustrover|idea|pycharm|goland|webstorm|clion|phpstorm|rubymine|datagrip|aqua|dataspell'
    $ports = @()
    if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
        $ids = @(Get-Process | Where-Object { $_.ProcessName -match "^($names)" } | ForEach-Object { $_.Id })
        if ($ids) {
            $ports = @(Get-NetTCPConnection -State Listen -LocalAddress 127.0.0.1 -ErrorAction SilentlyContinue |
                Where-Object { $ids -contains $_.OwningProcess } | ForEach-Object { $_.LocalPort })
        }
    } elseif (Get-Command lsof -ErrorAction SilentlyContinue) {
        $ports = @(& lsof -nP -iTCP -sTCP:LISTEN 2>$null | ForEach-Object {
            $f = $_ -split '\s+'
            if ($f.Count -ge 9 -and $f[0].ToLower() -match "^($names)" -and $f[8] -match '^127\.0\.0\.1:(\d+)$') { $Matches[1] }
        })
    }
    return @($ports | Sort-Object -Unique | ForEach-Object { "http://127.0.0.1:$_/stream" })
}

# Returns @(sessionId, body). CONTINUUM_IDE_MCP_CMD replaces the transport (tests).
function Invoke-CntIdeRpc ($Url, $Sid, $Json) {
    if ($env:CONTINUUM_IDE_MCP_CMD) {
        $parts = @($env:CONTINUUM_IDE_MCP_CMD -split '\s+' | Where-Object { $_ })
        $rest = @($parts | Select-Object -Skip 1)
        $out = @(& $parts[0] @rest $Url $Sid $Json)
        return @($out[0], (@($out | Select-Object -Skip 1) -join "`n"))
    }
    $h = @{ 'Accept' = 'application/json, text/event-stream' }
    if ($Sid) { $h['Mcp-Session-Id'] = $Sid }
    $r = Invoke-WebRequest -Uri $Url -Method Post -Body $Json -ContentType 'application/json' -Headers $h -TimeoutSec 5 -UseBasicParsing
    $newSid = $Sid
    if ($r.Headers['Mcp-Session-Id']) { $newSid = @($r.Headers['Mcp-Session-Id'])[0] }
    return @($newSid, ([string]$r.Content -replace '(?m)^data: ', ''))
}

function Show-CntIde ($Text, $Dir) {
    $top = (& git -C $Dir rev-parse --show-toplevel 2>$null)
    if (-not $top -or -not (Test-Path -PathType Container (Join-Path $top '.git'))) {
        [Console]::Error.WriteLine('continuum: --ide needs a git checkout (the warning goes to .git/continuum-warning.md)'); return $false
    }
    [System.IO.File]::WriteAllText((Join-Path $top '.git/continuum-warning.md'), $Text + "`n")
    $jtop = $top.Replace('\', '\\').Replace('"', '\"')
    foreach ($url in Get-CntIdeEndpoints) {
        try {
            $r = Invoke-CntIdeRpc $url '' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"continuum","version":"1"}}}'
            if ($r[1] -notmatch 'MCP Server') { continue }
            $sid = $r[0]
            try { Invoke-CntIdeRpc $url $sid '{"jsonrpc":"2.0","method":"notifications/initialized"}' | Out-Null } catch {}
            $r = Invoke-CntIdeRpc $url $sid ('{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"open_file_in_editor","arguments":{"filePath":".git/continuum-warning.md","rootFolder":"' + $jtop + '"}}}')
            if ($r[1] -match '"isError"\s*:\s*true|"error"\s*:') { continue }
            if ($r[1] -match '"result"') { return $true }
        } catch { continue }
    }
    [Console]::Error.WriteLine("continuum: no JetBrains IDE with $top open answered on MCP (Settings | Tools | MCP Server)")
    return $false
}

function Invoke-Watch {
    param([int]$Every = 300, [switch]$ShowInIde)

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
                if ($ShowInIde) {
                    $text = "# continuum: $utilInt% of the usage window used`n`nResets at $when. Tell the agent in the chat to wrap up, or to save its state, then:`n`n    continuum resume $at `"`$PWD`" `"<the task to pick up>`"`n`n(Shown by ``continuum watch --ide``. This file lives in .git/ and is never committed.)"
                    Show-CntIde $text (Get-Location).Path | Out-Null
                }
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

# `install --agent <x> [--dry-run]` / `uninstall --agent <x>`; mirrors bin/continuum (R5).
# Only shapes we can edit safely: no file -> create; a file without "hooks" -> insert the
# block (backup first); hooks already there -> refuse with the snippet. Uninstall undoes
# it only while the file is unchanged since install. Never half-writes.
function Get-CntInstFile ($a) {
    # $env:HOME first: tests (and users) point it elsewhere; $HOME itself cannot be overridden.
    $HOMEDIR = $(if ($env:HOME) { $env:HOME } else { $HOME })
    switch ($a) {
        'codex'    { $h = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOMEDIR '.codex' }); return (Join-Path $h 'hooks.json') }
        'gemini'   { return (Join-Path $HOMEDIR '.gemini/settings.json') }
        'cursor'   { return (Join-Path $HOMEDIR '.cursor/hooks.json') }
        'opencode' { $c = $(if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOMEDIR '.config' }); return (Join-Path $c 'opencode/plugins/continuum.js') }
    }
}
function Get-CntInstHooks ($a, $r) {
    # JSON string of the hook command: sh on macOS/Linux, the .ps1 twin on Windows (no sh there
    # unless Git Bash), as each adapter's README shows.
    $c = {
        param($name)
        if ($IsWindows) { return "`"pwsh -NoProfile -File \`"$r/adapters/$a/$name.ps1\`"`"" }
        return "`"sh \`"$r/adapters/$a/$name.sh\`"`""
    }
    switch ($a) {
        'codex'  { return "  `"hooks`": {`n    `"Stop`": [{ `"hooks`": [{ `"type`": `"command`", `"command`": $(& $c 'stop') }] }],`n    `"PostToolUse`": [{ `"hooks`": [{ `"type`": `"command`", `"command`": $(& $c 'tool-check') }] }]`n  }" }
        'gemini' { return "  `"hooks`": {`n    `"AfterAgent`": [{ `"hooks`": [{ `"type`": `"command`", `"command`": $(& $c 'after-agent') }] }],`n    `"AfterTool`": [{ `"matcher`": `".*`", `"hooks`": [{ `"type`": `"command`", `"command`": $(& $c 'after-tool') }] }]`n  }" }
        'cursor' { return "  `"version`": 1,`n  `"hooks`": {`n    `"stop`": [{ `"command`": $(& $c 'stop') }],`n    `"postToolUse`": [{ `"command`": $(& $c 'tool-check') }]`n  }" }
    }
}
function Invoke-CntInstall {
    param([string]$Action, [string]$AgentName, [bool]$Dry)
    switch ($AgentName) {
        'claude' { 'Claude Code installs continuum as a plugin: claude plugin install continuum@continuum (or /plugin in a session). See README → Claude Code.'; return }
        'junie'  { 'Junie installs continuum as an extension: in Junie, /extensions → add the marketplace https://github.com/TropinAlexey/continuum → install continuum.'; return }
        { $_ -in 'codex', 'gemini', 'cursor', 'opencode' } { break }
        default  { [Console]::Error.WriteLine("continuum ${Action}: --agent codex|gemini|cursor|opencode (claude and junie install as plugins)"); exit 1 }
    }
    # The code path lands inside a shell command in the agent's config: allow only
    # characters that need no quoting, so no path can turn into shell syntax.
    $r = ((Resolve-Path $script:CntRoot).Path) -replace '\\', '/'
    if ($r -notmatch '^[A-Za-z0-9/._+@~:-]+$') { [Console]::Error.WriteLine("continuum ${Action}: the code path '$r' has characters that are unsafe in a hook command; install continuum to a plain path"); exit 1 }
    $f = Get-CntInstFile $AgentName
    $rec = Join-Path $script:CntState ".continuum-install-$AgentName"
    New-Item -ItemType Directory -Force -Path $script:CntState | Out-Null

    if ($AgentName -eq 'opencode') {
        $src = "$r/adapters/opencode/continuum.js"
        $item = Get-Item -Force $f -ErrorAction SilentlyContinue
        $ours = $item -and $item.LinkType -eq 'SymbolicLink' -and (@($item.Target)[0] -replace '\\', '/') -eq $src
        if ($Action -eq 'install') {
            if ($ours) { "already installed: $f"; return }
            if ($item) { [Console]::Error.WriteLine("continuum install: $f exists and is not ours; remove it, then link it to $src"); exit 1 }
            if ($Dry) { "would link $f -> $src"; return }
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $f) | Out-Null
            New-Item -ItemType SymbolicLink -Path $f -Target $src | Out-Null
            "linked $f -> $src (restart opencode)"
        } elseif ($ours) {
            if ($Dry) { "would remove $f"; return }
            Remove-Item -Force $f; "removed $f"
        } else { "nothing to uninstall: $f is not continuum's link" }
        return
    }

    # A symlinked config (dotfiles) would be replaced by a plain file on move: leave it alone.
    $fi = Get-Item -Force $f -ErrorAction SilentlyContinue
    if ($fi -and $fi.LinkType) { [Console]::Error.WriteLine("continuum ${Action}: $f is a symlink (dotfiles?); edit the file it points to by hand"); exit 1 }
    $block = Get-CntInstHooks $AgentName $r
    $sum = { param($p) (Get-FileHash -Algorithm SHA256 $p).Hash }
    if ($Action -eq 'install') {
        $cur = $(if (Test-Path $f) { [System.IO.File]::ReadAllText($f) } else { $null })
        if ($cur -and $cur.Contains("/adapters/$AgentName/")) { "already installed: $f"; return }
        if (-not $cur -or -not ($cur -replace '[\s{}]', '')) {
            $mode = 'created'; $new = "{`n$block`n}`n"
        } elseif ($cur -match '"hooks"\s*:') {
            [Console]::Error.WriteLine("continuum install: $f already has `"hooks`"; merge these entries by hand:`n$block"); exit 1
        } elseif ($cur.TrimStart()[0] -ne '{') {
            [Console]::Error.WriteLine("continuum install: $f does not start with '{'; not touching it"); exit 1
        } else {
            $mode = 'inserted'
            $k = $cur.IndexOf('{')
            $rest = $cur.Substring($k + 1)
            $new = $cur.Substring(0, $k + 1) + "`n$block," + $(if ($rest -match '^[ \t]*\r?\n') { $rest } else { "`n" + $rest })
        }
        # Never write a config we did not build in full.
        try { $null = $new | ConvertFrom-Json -ErrorAction Stop } catch { [Console]::Error.WriteLine("continuum install: could not build the new $f; not touching it"); exit 1 }
        if ($Dry) { "would write ${f}:"; $new; return }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $f) | Out-Null
        if (Test-Path $f) { Copy-Item -Force $f "$f.continuum-bak" }
        [System.IO.File]::WriteAllText("$f.continuum-tmp", $new)
        Move-Item -Force "$f.continuum-tmp" $f
        [System.IO.File]::WriteAllText($rec, "$mode`n$(& $sum $f)")
        if (Test-Path "$f.continuum-bak") { "installed: $f (backup: $f.continuum-bak)" } else { "installed: $f" }
        if ($AgentName -eq 'codex') { 'Codex runs hooks only once trusted: approve them in /hooks.' }
        return
    }
    if (-not (Test-Path $rec)) { "nothing to uninstall: continuum did not install into $f"; return }
    $lines = [System.IO.File]::ReadAllLines($rec)
    if (-not (Test-Path $f)) { Remove-Item -Force $rec; "already gone: $f"; return }
    if ((& $sum $f) -ne $lines[1]) { [Console]::Error.WriteLine("continuum uninstall: $f changed since install; remove the hooks that point to $r/adapters/$AgentName/ by hand"); exit 1 }
    if ($Dry) { "would restore $f ($($lines[0]))"; return }
    if (Test-Path "$f.continuum-bak") { Move-Item -Force "$f.continuum-bak" $f } else { Remove-Item -Force $f }
    Remove-Item -Force $rec; "uninstalled: $f"
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
    'watch'     {
        $ideOn = $Ide -or ($Arg1 -eq '--ide') -or ($Arg2 -eq '--ide')
        $sec = @($Arg1, $Arg2 | Where-Object { $_ -and $_ -ne '--ide' }) | Select-Object -First 1
        if ($sec) { Invoke-Watch ([int]$sec) -ShowInIde:$ideOn } else { Invoke-Watch -ShowInIde:$ideOn }
    }
    'resume'    { Invoke-Resume $Arg1 $Arg2 $Arg3 }
    'history'   { Invoke-CntHistory }
    'cleanup'   { Invoke-Cleanup }
    { $_ -in 'install', 'uninstall' } {
        $ag = $Agent; $dr = [bool]$DryRun
        $rest = @($Arg1, $Arg2, $Arg3, $Arg4 | Where-Object { $_ })
        for ($i = 0; $i -lt $rest.Count; $i++) {
            if ($rest[$i] -eq '--agent' -and $i + 1 -lt $rest.Count) { $ag = $rest[$i + 1]; $i++ }
            elseif ($rest[$i] -eq '--dry-run') { $dr = $true }
        }
        Invoke-CntInstall $Command $ag $dr
    }
    'doctor'    { Invoke-CntDoctor $(if ($Fix) { '--fix' } else { $Arg1 }) }
    'statusline' { Invoke-StatuslineConfig $Arg1 $Arg2 }
    default     { [Console]::Error.WriteLine("continuum: unknown command '$Command'"); exit 1 }
}
