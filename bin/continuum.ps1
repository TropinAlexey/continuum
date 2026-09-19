# continuum - see the limit coming, decide what to do, pick up where you stopped.
#
#   continuum.ps1 status         utilization of every window the provider reports
#   continuum.ps1 reset          local HH:mm when the primary window rolls over (+90s)
#   continuum.ps1 estimate       extrapolate time remaining at current pace
#   continuum.ps1 providers      list available providers
#   continuum.ps1 resume HH:MM [dir] [prompt]
#                                schedule `claude --continue` for after the reset
#   continuum.ps1 history        show recent usage snapshots
#   continuum.ps1 cleanup        remove stale flag/cache files (>24h old)
#   continuum.ps1 statusline [key value | reset]
#                                show or configure status-line format

param(
    [Parameter(Position = 0)][string]$Command = 'status',
    [Parameter(Position = 1)][string]$Arg1,
    [Parameter(Position = 2)][string]$Arg2,
    [Parameter(Position = 3)][string]$Arg3
)

# param() must be the first statement in the file - everything else comes after.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '../lib/core.ps1')

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
    $hist = Join-Path $script:CntCfg '.continuum-history.log'
    New-Item -ItemType Directory -Force -Path $script:CntCfg 2>$null | Out-Null
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
# Claude Code by default; point it at any CLI that resumes a session headless:
#   $env:CONTINUUM_RESUME_CMD = 'codex exec "{prompt}"'
function Get-CntResumeCmd {
    if ($env:CONTINUUM_RESUME_CMD) { return $env:CONTINUUM_RESUME_CMD }
    return 'claude --continue -p "{prompt}" --permission-mode acceptEdits'
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

    $log = Join-Path $script:CntCfg 'continuum-resume.log'
    New-Item -ItemType Directory -Force -Path $script:CntCfg | Out-Null
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
    $hist = Join-Path $script:CntCfg '.continuum-history.log'
    if (-not (Test-Path $hist)) { 'No history yet. History is recorded on each status check.'; return }
    Get-Content $hist | Select-Object -Last 20
}

function Invoke-Cleanup {
    $cleaned = 0
    $cutoff = (Get-Date).AddHours(-24)
    foreach ($pattern in @('.continuum-warned-*', '.continuum-warned7d-*', '.continuum-cache-*', '.continuum-wakelock-*')) {
        Get-ChildItem -Path $script:CntCfg -Filter $pattern -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } | ForEach-Object {
                Remove-Item $_.FullName -Force; $cleaned++
            }
    }
    "Cleaned $cleaned stale files."
}

# Show or configure the status-line format (mirrors `continuum statusline`).
# Shares .continuum-statusline.conf with hooks/statusline.ps1 and the sh hook.
function Get-CntSlConfValue {
    param([string]$Key, [string]$Default)
    $conf = Join-Path $script:CntCfg '.continuum-statusline.conf'
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
    $conf = Join-Path $script:CntCfg '.continuum-statusline.conf'
    New-Item -ItemType Directory -Force -Path $script:CntCfg | Out-Null
    $kept = @()
    if (Test-Path $conf) {
        $kept = @(Get-Content -Path $conf | Where-Object { -not $_.StartsWith("$Key=", [StringComparison]::Ordinal) })
    }
    Set-Content -Path $conf -Value ($kept + @("$Key=$Val"))
}

function Invoke-StatuslineConfig {
    param([string]$Key, [string]$Val)
    $conf = Join-Path $script:CntCfg '.continuum-statusline.conf'

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
    'watch'     { if ($Arg1) { Invoke-Watch ([int]$Arg1) } else { Invoke-Watch } }
    'resume'    { Invoke-Resume $Arg1 $Arg2 $Arg3 }
    'history'   { Invoke-History }
    'cleanup'   { Invoke-Cleanup }
    'statusline' { Invoke-StatuslineConfig $Arg1 $Arg2 }
    default     { [Console]::Error.WriteLine("continuum: unknown command '$Command'"); exit 1 }
}
