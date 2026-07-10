# continuum - see the limit coming, decide what to do, pick up where you stopped.
#
#   continuum.ps1 status         utilization of every window the provider reports
#   continuum.ps1 reset          local HH:mm when the primary window rolls over (+90s)
#   continuum.ps1 providers      list available providers
#   continuum.ps1 resume HH:MM [dir] [prompt]
#                                schedule `claude --continue` for after the reset

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
    foreach ($line in @(Read-CntUsage)) {
        $p = $line.Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
        $when = '?'
        if ($p.Count -ge 3 -and $p[2] -ne '-') {
            try { $when = ConvertTo-CntHhmm ([int64]$p[2]) } catch { $when = '?' }
        }
        '{0} {1,5}%   resets at {2}' -f (Format-Label $p[0]), $p[1], $when
    }
}

function Invoke-Reset {
    $first = @(Read-CntUsage)[0].Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
    if ($first.Count -lt 3 -or $first[2] -eq '-') {
        throw "provider '$($script:CntProvider)' reports no reset time"
    }
    # +90s margin: wake up after the reset, not a second before it
    ConvertTo-CntHhmm ([int64]$first[2]) 90
}

function Invoke-Resume {
    param([string]$Hhmm, [string]$Dir, [string]$Prompt)

    if (-not $Hhmm) { throw 'continuum resume: need HH:MM' }
    if (-not $Dir)  { $Dir = $PWD.Path }
    if (-not $Prompt) { $Prompt = 'continue, please' }
    if (-not (Test-Path $Dir)) { throw "no such directory: $Dir" }
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { throw '`claude` not found in PATH' }

    $delay = Get-CntHhmmDelay $Hhmm
    $log   = Join-Path $script:CntCfg 'continuum-resume.log'
    New-Item -ItemType Directory -Force -Path $script:CntCfg | Out-Null
    Add-Content -Path $log -Value "`n=== scheduled $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') for $Hhmm in $Dir"

    # Detached: survives closing the terminal, does NOT survive a reboot.
    $inner = "Start-Sleep -Seconds $delay; Set-Location '$Dir'; " +
             "claude --continue -p '$($Prompt -replace "'", "''")' --permission-mode acceptEdits " +
             "*>> '$log'"
    $ps = (Get-Process -Id $PID).Path
    $proc = Start-Process -FilePath $ps -WindowStyle Hidden -PassThru `
                          -ArgumentList '-NoProfile', '-NonInteractive', '-Command', $inner

    "Resuming in {0} min (at {1}) in {2}: `"{3}`"" -f [int]($delay / 60), $Hhmm, $Dir, $Prompt
    "Scheduled, PID {0}. Cancel: Stop-Process -Id {0}   Log: {1}" -f $proc.Id, $log
    'It runs headless with acceptEdits - it will edit code unattended.'
}

switch ($Command) {
    'status'    { Invoke-Status }
    'reset'     { Invoke-Reset }
    'providers' { Get-CntProviders }
    'resume'    { Invoke-Resume $Arg1 $Arg2 $Arg3 }
    default     { [Console]::Error.WriteLine("continuum: unknown command '$Command'"); exit 1 }
}
