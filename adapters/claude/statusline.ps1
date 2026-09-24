# Claude Code status line, PowerShell edition. Mirrors adapters/claude/statusline.sh.
#
# Shows utilization% with color coding and optional reset times.
# Colors: green <80, yellow 80-94, red >=95.
# Config: .continuum-statusline.conf in the continuum state dir, shared with the sh
# hook (managed by `continuum.ps1 statusline`).
#
# Difference from the sh hook: no background refresh - Start-Job is too heavy
# for a prompt hook. A missing cache triggers one synchronous read; a present
# cache is displayed as-is. Prime it with `continuum.ps1 status`.

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

if (-not (Test-Path $cache)) {
    # @() is load-bearing: a one-element array unrolls to a scalar.
    try { $lines = @(Read-CntUsage) }
    catch { exit 0 }
    if (-not $lines) { exit 0 }
    Set-Content -Path $cache -Value $lines
} else {
    $lines = @(Get-Content -Path $cache)
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

$fmt       = Get-SlConf 'FORMAT' '{d%}% d {dr} | {w%}% w {wr}'
$fmtSingle = Get-SlConf 'FORMAT_SINGLE' '{d%}% d {dr}'
$timeFmt   = Get-SlConf 'TIME_FORMAT' '%H:%M'
$dateFmt   = Get-SlConf 'DATE_FORMAT' '%d.%m'
$todayWord = Get-SlConf 'TODAY' 'today'

$esc = [char]27
# NB: ${esc}, not $esc - "$esc[" would parse as an indexer into $esc.
$dColored = "${esc}[$(Get-SlColor $dPct)m${dPct}%${esc}[0m"
$dResetStr = Format-SlReset $dReset

if ($null -ne $wPct) {
    $wColored = "${esc}[$(Get-SlColor $wPct)m${wPct}%${esc}[0m"
    $wResetStr = Format-SlReset $wReset
    $out = $fmt
    $out = Invoke-SlSub $out '{w%}' $wColored
    $out = Invoke-SlSub $out '{wr}' $wResetStr
} else {
    $out = $fmtSingle
}
$out = Invoke-SlSub $out '{d%}' $dColored
$out = Invoke-SlSub $out '{dr}' $dResetStr
Write-Output $out
