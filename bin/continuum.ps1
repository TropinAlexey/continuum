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
    $summary = ($allLines | ForEach-Object { $p = $_.Split(' '); "$($p[0]):$($p[1])%" }) -join ' '
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

    # The prompt ends up inside the command string: neutralise quotes.
    $cmd = $tmpl.Replace('{prompt}', ($Prompt -replace "'", "''"))

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

    # Detached: survives closing the terminal, does NOT survive a reboot.
    $inner = "Start-Sleep -Seconds $delay; Set-Location '$Dir'; $cmd *>> '$log'"
    $ps = (Get-Process -Id $PID).Path
    $proc = Start-Process -FilePath $ps -WindowStyle Hidden -PassThru `
                          -ArgumentList '-NoProfile', '-NonInteractive', '-Command', $inner

    "Resuming in {0} min (at {1}) in {2}: `"{3}`"" -f [int]($delay / 60), $Hhmm, $Dir, $Prompt
    "Scheduled, PID {0}. Cancel: Stop-Process -Id {0}   Log: {1}" -f $proc.Id, $log
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
    foreach ($pattern in @('.continuum-warned-*', '.continuum-warned7d-*', '.continuum-cache-*')) {
        Get-ChildItem -Path $script:CntCfg -Filter $pattern -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } | ForEach-Object {
                Remove-Item $_.FullName -Force; $cleaned++
            }
    }
    "Cleaned $cleaned stale files."
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
    default     { [Console]::Error.WriteLine("continuum: unknown command '$Command'"); exit 1 }
}
