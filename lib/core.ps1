# continuum - shared helpers, PowerShell edition (Windows without Git Bash).
#
# Mirrors lib/core.sh. Same provider protocol: a provider prints one line per
# usage window on stdout,
#
#     <window> <utilization> <reset_epoch>
#
# the first line being the primary window. On failure it writes to stderr and
# exits non-zero, printing nothing.
#
# Targets Windows PowerShell 5.1 as well as pwsh 7: no ternaries, no ??.

Set-StrictMode -Version 2.0

# State (cache, flags, logs, config, user providers) is continuum's own, not any
# agent's - and the same dir the sh core uses, so Git Bash and PowerShell on one
# machine share it. Not ~/.continuum: the installer keeps the code there.
if ($env:CONTINUUM_STATE_DIR) { $script:CntState = $env:CONTINUUM_STATE_DIR }
elseif ($env:XDG_STATE_HOME) { $script:CntState = Join-Path $env:XDG_STATE_HOME 'continuum' }
else { $script:CntState = Join-Path $HOME '.local/state/continuum' }
$script:CntCfg = $script:CntState   # deprecated alias, kept for third-party providers

if ($env:CONTINUUM_PROVIDER) { $script:CntProvider = $env:CONTINUUM_PROVIDER }
else { $script:CntProvider = 'anthropic' }

# CLAUDE_PLUGIN_ROOT is honoured for compatibility: Claude Code sets it for hooks.
if ($env:CONTINUUM_ROOT) { $script:CntRoot = $env:CONTINUUM_ROOT }
elseif ($env:CLAUDE_PLUGIN_ROOT) { $script:CntRoot = $env:CLAUDE_PLUGIN_ROOT }
else { $script:CntRoot = Split-Path -Parent $PSScriptRoot }

# One-time migration from ~/.claude, where state lived before the agent-neutral
# layout. Mirrors cnt_migrate: copy what is worth keeping (never cache/flags),
# never overwrite, never delete the originals, never throw. No marker on error.
function Invoke-CntMigrate {
    if ($env:CONTINUUM_STATE_DIR) { return }
    $marker = Join-Path $script:CntState '.migrated'
    if (Test-Path $marker) { return }
    try {
        if ($env:CLAUDE_CONFIG_DIR) { $old = $env:CLAUDE_CONFIG_DIR } else { $old = Join-Path $HOME '.claude' }
        New-Item -ItemType Directory -Force -Path $script:CntState | Out-Null
        if (Test-Path $old) {
            foreach ($f in '.continuum-statusline.conf', '.continuum-history.log', 'continuum-resume.log') {
                $src = Join-Path $old $f; $dst = Join-Path $script:CntState $f
                if ((Test-Path $src) -and -not (Test-Path $dst)) { Copy-Item -Path $src -Destination $dst }
            }
            $oldProv = Join-Path $old 'providers'
            if (Test-Path $oldProv) {
                $newProv = Join-Path $script:CntState 'providers'
                foreach ($p in @(Get-ChildItem -Path $oldProv -File | Where-Object { $_.Extension -in '.sh', '.ps1' })) {
                    New-Item -ItemType Directory -Force -Path $newProv | Out-Null
                    $dst = Join-Path $newProv $p.Name
                    if (-not (Test-Path $dst)) { Copy-Item -Path $p.FullName -Destination $dst }
                }
            }
        }
        New-Item -ItemType File -Force -Path $marker | Out-Null
    } catch { }
}
Invoke-CntMigrate

# Record where the code lives, for scripts started without any environment
# (a statusline copied into an agent's config dir). Never throws.
function Set-CntRootPointer {
    try {
        $f = Join-Path $script:CntState 'root'
        $root = (Resolve-Path $script:CntRoot).Path
        if ((Test-Path $f) -and ([System.IO.File]::ReadAllText($f).Trim() -eq $root)) { return }
        New-Item -ItemType Directory -Force -Path $script:CntState | Out-Null
        [System.IO.File]::WriteAllText($f, "$root`n")
    } catch { }
}

function Get-CntProviders {
    # NB: collect first, sort after - a pipeline directly on the function
    # body (`} | Sort-Object`) is a parse error in PowerShell.
    $all = foreach ($d in @((Join-Path $script:CntRoot 'providers'), (Join-Path $script:CntState 'providers'))) {
        if (Test-Path $d) {
            Get-ChildItem -Path $d -Filter '*.ps1' | ForEach-Object { $_.BaseName }
        }
    }
    $all | Sort-Object -Unique
}

function Get-CntProviderPath {
    param([string]$Name)
    foreach ($d in @((Join-Path $script:CntRoot 'providers'), (Join-Path $script:CntState 'providers'))) {
        $p = Join-Path $d "$Name.ps1"
        if (Test-Path $p) { return $p }
    }
    return $null
}

# Read a single provider's output as a string array. Throws on failure.
function Read-CntUsageSingle {
    param([string]$Name)
    $p = Get-CntProviderPath $Name
    if (-not $p) {
        throw "unknown provider '$Name' (have: $((Get-CntProviders) -join ' '))"
    }
    $global:LASTEXITCODE = 0
    $lines = & $p
    if ($LASTEXITCODE -ne 0) { throw "provider '$Name' failed" }
    if (-not $lines) { throw "provider '$Name' returned nothing" }
    return @($lines | Where-Object { $_ -and $_.Trim() })
}

# Returns the provider's lines as a string array.
# Supports comma-separated providers: runs all, keeps highest-utilization primary line.
function Read-CntUsage {
    if ($script:CntProvider -notmatch ',') {
        return Read-CntUsageSingle $script:CntProvider
    }
    $provs = $script:CntProvider -split ','
    $bestUtil = 0; $bestLine = ''; $rest = @()
    foreach ($prov in $provs) {
        $prov = $prov.Trim()
        if (-not $prov) { continue }
        try {
            $lines = @(Read-CntUsageSingle $prov)
        } catch { continue }
        $f = $lines[0].Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
        # A custom provider returning garbage must not throw: treat as zero
        # so a healthy provider still wins instead of failing the whole read.
        $u = 0
        try { $u = [double]::Parse($f[1], [cultureinfo]::InvariantCulture) } catch { $u = 0 }
        if ($u -gt $bestUtil) { $bestUtil = $u; $bestLine = $lines[0] }
        if ($lines.Count -gt 1) { $rest += $lines[1..($lines.Count - 1)] }
    }
    if (-not $bestLine) { throw 'all providers failed' }
    $result = @($bestLine) + $rest
    return $result
}

# "2026-07-09T17:40:00.180+00:00" -> unix epoch seconds
function ConvertTo-CntEpoch {
    param([string]$Iso)
    $dt = [datetimeoffset]::Parse($Iso, [cultureinfo]::InvariantCulture)
    return [int64]$dt.ToUnixTimeSeconds()
}

# epoch (+ optional margin) -> local HH:mm
function ConvertTo-CntHhmm {
    param([int64]$Epoch, [int]$MarginSeconds = 0)
    $dt = [datetimeoffset]::FromUnixTimeSeconds($Epoch + $MarginSeconds).ToLocalTime()
    return $dt.ToString('HH:mm')
}

# "19:40" -> seconds until the next local occurrence of that time
function Get-CntHhmmDelay {
    param([string]$Hhmm)
    if ($Hhmm -notmatch '^([01]?[0-9]|2[0-3]):[0-5][0-9]$') {
        throw "invalid time: $Hhmm (expected HH:MM)"
    }
    $parts  = $Hhmm.Split(':')
    $now    = Get-Date
    $target = $now.Date.AddHours([int]$parts[0]).AddMinutes([int]$parts[1])
    if ($target -le $now) { $target = $target.AddDays(1) }   # already passed -> tomorrow
    return [int]($target - $now).TotalSeconds
}

# Token lookup, Windows edition: env var, then Claude Code's credentials file.
# There is no Keychain here; Claude Code stores JSON under the config dir.
#
# WARNING: returns your OAuth access token. Never write it to a log or transcript.
# Desktop notification, best-effort
function Send-CntNotification {
    param([string]$Title, [string]$Message)
    try {
        [void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms')
        $n = New-Object System.Windows.Forms.NotifyIcon
        $n.Icon = [System.Drawing.SystemIcons]::Information
        $n.BalloonTipTitle = $Title
        $n.BalloonTipText = $Message
        $n.Visible = $true
        $n.ShowBalloonTip(5000)
    } catch {}
}

# --- wakelock (prevent system sleep during scheduled resume) ----------
# Windows: SetThreadExecutionState via P/Invoke (works on 5.1+).
# macOS/Linux pwsh: caffeinate / systemd-inhibit (same as the sh version).

function Start-CntWakeLock {
    param([int]$Seconds)
    $pidFile = Join-Path $script:CntState ".continuum-wakelock-$([int](Get-Date -UFormat %s)).pid"
    if ($IsWindows -or (-not (Test-Path variable:IsWindows) -and $env:OS -eq 'Windows_NT')) {
        # Launch a hidden job that holds ES_CONTINUOUS|ES_SYSTEM_REQUIRED
        $job = Start-Job -ScriptBlock {
            param($dur)
            Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public class WakeLock { [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f); }'
            [WakeLock]::SetThreadExecutionState(0x80000003) | Out-Null  # ES_CONTINUOUS | ES_SYSTEM_REQUIRED
            Start-Sleep -Seconds $dur
            [WakeLock]::SetThreadExecutionState(0x80000000) | Out-Null  # ES_CONTINUOUS (clear)
        } -ArgumentList $Seconds
        # A missing config dir must not leave an orphaned job behind.
        try { Set-Content -Path $pidFile -Value "job:$($job.Id)" -NoNewline -ErrorAction Stop }
        catch {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            return ''
        }
    } elseif ($IsMacOS) {
        # NB: no -WindowStyle here: Start-Process on Unix PowerShell does not
        # support it and throws, which would disable the wakelock entirely.
        $p = Start-Process -FilePath 'caffeinate' -ArgumentList '-i', '-t', $Seconds -PassThru 2>$null
        if ($p) {
            try { Set-Content -Path $pidFile -Value $p.Id -NoNewline -ErrorAction Stop }
            catch { Stop-Process -InputObject $p -ErrorAction SilentlyContinue; return '' }
        }
        else { return '' }
    } elseif ($IsLinux -and (Get-Command systemd-inhibit -ErrorAction SilentlyContinue)) {
        $p = Start-Process -FilePath 'systemd-inhibit' `
            -ArgumentList '--what=idle:sleep','--who=continuum','--why=resume','sleep',$Seconds `
            -PassThru 2>$null
        if ($p) {
            try { Set-Content -Path $pidFile -Value $p.Id -NoNewline -ErrorAction Stop }
            catch { Stop-Process -InputObject $p -ErrorAction SilentlyContinue; return '' }
        }
        else { return '' }
    } else { return '' }
    return $pidFile
}

function Stop-CntWakeLock {
    param([string]$PidFile)
    if (-not $PidFile -or -not (Test-Path $PidFile)) { return }
    $id = Get-Content -Path $PidFile -Raw
    if ($id -match '^job:(\d+)$') {
        Stop-Job -Id ([int]$Matches[1]) -ErrorAction SilentlyContinue
        Remove-Job -Id ([int]$Matches[1]) -Force -ErrorAction SilentlyContinue
    } elseif ($id -match '^\d+$') {
        Stop-Process -Id ([int]$id) -ErrorAction SilentlyContinue
    }
    Remove-Item -Path $PidFile -Force -ErrorAction SilentlyContinue
}

