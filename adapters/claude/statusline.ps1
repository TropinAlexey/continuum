# Claude Code status line, PowerShell edition. Mirrors adapters/claude/statusline.sh.
#
# Shows utilization% with color coding and optional reset times.
# Colors: green <80, yellow 80-94, red >=95.
# Config: .continuum-statusline.conf in the continuum state dir, shared with the sh
# hook (managed by `continuum.ps1 statusline`).
#
# Difference from the sh hook: no background refresh - Start-Job is too heavy
# for a prompt hook. A cache that is plainly wrong - missing, older than 10 min,
# or past its window's reset - triggers one synchronous read (so a fresh session
# shows current numbers before its first request); otherwise the cache is
# displayed as-is.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# A status line must never break the prompt: stay silent on any failure.
trap { exit 0 }

if ($env:CONTINUUM_STATE_DIR) { $cfgDir = $env:CONTINUUM_STATE_DIR }
elseif ($env:XDG_STATE_HOME) { $cfgDir = Join-Path $env:XDG_STATE_HOME 'continuum' }
else { $cfgDir = Join-Path $HOME '.local/state/continuum' }

$prov = $env:CONTINUUM_PROVIDER
if (-not $prov) { $prov = 'anthropic' }
if ($prov -match ',') { $prov = ($prov -split ',')[0] }
$prov = ($prov.Trim() -replace '[^A-Za-z0-9_-]', '_')
if (-not $prov) { $prov = 'anthropic' }

$cache = Join-Path $cfgDir ".continuum-cache-$prov"
$conf  = Join-Path $cfgDir '.continuum-statusline.conf'

# Find the code: explicit env, the plugin root, this checkout, or the pointer the
# CLI leaves in the state dir (for a copy living in an agent's config dir).
$root = $null
$candidates = @($env:CONTINUUM_ROOT, $env:CLAUDE_PLUGIN_ROOT, (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$pointer = Join-Path $cfgDir 'root'
if (Test-Path $pointer) { $candidates += [System.IO.File]::ReadAllText($pointer).Trim() }
foreach ($c in $candidates) {
    if ($c -and (Test-Path (Join-Path $c 'lib/core.ps1'))) { $root = $c; break }
}
if (-not $root) { exit 0 }
. (Join-Path $root 'lib/core.ps1')

# A failed refresh leaves a .retry marker: for 2 min after it the cache is shown
# as-is, or an offline machine would stall every render on the provider.
$retry = "$cache.retry"
$lines = $null
$stale = $true
if (Test-Path $cache) {
    $lines = @(Get-Content -Path $cache)
    $stale = ((Get-Date) - (Get-Item -Force $cache).LastWriteTime).TotalMinutes -gt 10
    if (-not $stale -and $lines) {
        $r = ($lines[0] -split '\s+')
        # Length cap: a garbage epoch must not overflow [long].
        if ($r.Count -ge 3 -and $r[2] -match '^\d{1,12}$' -and [long]$r[2] -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) { $stale = $true }
    }
}
if ($stale -and (Test-Path $retry) -and ((Get-Date) - (Get-Item -Force $retry).LastWriteTime).TotalMinutes -lt 2) { $stale = $false }
if ($stale) {
    # @() is load-bearing: a one-element array unrolls to a scalar.
    $fresh = $null
    try { $fresh = @(Read-CntUsage) } catch { $fresh = $null }
    if ($fresh) {
        $lines = $fresh
        # tmp+move: two sessions refreshing at once must not interleave writes.
        $tmpFile = "$cache.$PID.tmp"
        try {
            New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
            Set-Content -Path $tmpFile -Value $lines
            Move-Item -Force -Path $tmpFile -Destination $cache
            Remove-Item -Force -ErrorAction SilentlyContinue $retry
        } catch { Remove-Item -Force -ErrorAction SilentlyContinue $tmpFile }
    } else {
        try { New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null; Set-Content -Path $retry -Value '' } catch { }
    }
}
if (-not $lines) { exit 0 }

$first = $lines[0].Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
if ($first.Count -lt 2) { exit 0 }
$dPct = 0
try { $dPct = [int][math]::Floor([double]::Parse($first[1], [cultureinfo]::InvariantCulture)) }
catch { exit 0 }
$dReset = '-'
if ($first.Count -ge 3) { $dReset = $first[2] }

$wPct = $null
$wReset = '-'
if ($lines.Count -gt 1) {
    $second = $lines[1].Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
    if ($second.Count -ge 2) {
        try { $wPct = [int][math]::Floor([double]::Parse($second[1], [cultureinfo]::InvariantCulture)) }
        catch { $wPct = $null }
    }
    if ($second.Count -ge 3) { $wReset = $second[2] }
}

function Get-SlColor([int]$Pct) {
    if ($Pct -ge 95) { return '31' }
    if ($Pct -ge 80) { return '33' }
    return '32'
}

function Get-SlConf {
    param([string]$Key, [string]$Default)
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

# The conf file is shared with the sh hook, which uses strftime. Map the
# common specifiers to .NET; anything else passes through untouched.
function ConvertFrom-Strftime([string]$Fmt) {
    $r = $Fmt.Replace('%%', "`0")
    $r = $r.Replace('%H', 'HH').Replace('%M', 'mm').Replace('%d', 'dd')
    $r = $r.Replace('%m', 'MM').Replace('%Y', 'yyyy')
    return $r.Replace("`0", '%')
}

# Reset epoch -> "today HH:MM" or "DD.MM HH:MM".
function Format-SlReset([string]$Epoch) {
    if (-not $Epoch -or $Epoch -eq '-') { return '' }
    $e = 0
    try { $e = [int64]$Epoch } catch { return '' }
    $dt = [datetimeoffset]::FromUnixTimeSeconds($e).ToLocalTime()
    $today = (Get-Date).ToString((ConvertFrom-Strftime $dateFmt))
    $rdate = $dt.ToString((ConvertFrom-Strftime $dateFmt))
    $rtime = $dt.ToString((ConvertFrom-Strftime $timeFmt))
    if ($today -ceq $rdate) { return "$todayWord $rtime" }
    return "$rdate $rtime"
}

# Replace the first occurrence of $Token with $Rep in $S.
function Invoke-SlSub([string]$S, [string]$Token, [string]$Rep) {
    $i = $S.IndexOf($Token, [StringComparison]::Ordinal)
    if ($i -lt 0) { return $S }
    return $S.Substring(0, $i) + $Rep + $S.Substring($i + $Token.Length)
}

$fmt       = Get-SlConf 'FORMAT' '{d%} d {dr} | {w%} w {wr}'
$fmtSingle = Get-SlConf 'FORMAT_SINGLE' '{d%} d {dr}'
$timeFmt   = Get-SlConf 'TIME_FORMAT' '%H:%M'
$dateFmt   = Get-SlConf 'DATE_FORMAT' '%d.%m'
$todayWord = Get-SlConf 'TODAY' 'today'

$esc = [char]27
# NB: ${esc}, not $esc - "$esc[" would parse as an indexer into $esc.
$dColored = "${esc}[$(Get-SlColor $dPct)m${dPct}%${esc}[0m"
$dResetStr = Format-SlReset $dReset

# {d%}/{w%} already carry the '%'; old defaults added another ("86%%"),
# so a saved "{d%}%" collapses to "{d%}".
if ($null -ne $wPct) {
    $wColored = "${esc}[$(Get-SlColor $wPct)m${wPct}%${esc}[0m"
    $wResetStr = Format-SlReset $wReset
    $out = Invoke-SlSub $fmt '{w%}%' '{w%}'
    $out = Invoke-SlSub $out '{w%}' $wColored
    $out = Invoke-SlSub $out '{wr}' $wResetStr
} else {
    $out = $fmtSingle
}
$out = Invoke-SlSub $out '{d%}%' '{d%}'
$out = Invoke-SlSub $out '{d%}' $dColored
$out = Invoke-SlSub $out '{dr}' $dResetStr
Write-Output $out
