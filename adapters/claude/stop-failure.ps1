# Claude Code (and Junie) StopFailure hook, PowerShell edition. Mirrors
# adapters/claude/stop-failure.sh: the limit ran out mid-turn; all the logic lives in
# `continuum.ps1 limit-hit`. No decision control here; output ignored; always exit 0.
#
# Claude Code runs hooks under PowerShell on Windows when Git Bash is absent.
# Wire it up with  "shell": "powershell"  - see the README.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# A Stop hook that errors spams the user. Nothing below may throw past this point.
trap { exit 0 }

if ($env:CONTINUUM_OFF) { exit 0 }

# Find the code: explicit env, the plugin root, this checkout, or the pointer the
# CLI leaves in the state dir (for copies living in an agent's config dir).
$root = $null
$candidates = @($env:CONTINUUM_ROOT, $env:CLAUDE_PLUGIN_ROOT, (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if ($env:CONTINUUM_STATE_DIR) { $state = $env:CONTINUUM_STATE_DIR }
elseif ($env:XDG_STATE_HOME) { $state = Join-Path $env:XDG_STATE_HOME 'continuum' }
else { $state = Join-Path $HOME '.local/state/continuum' }
$pointer = Join-Path $state 'root'
if (Test-Path $pointer) { $candidates += [System.IO.File]::ReadAllText($pointer).Trim() }
foreach ($c in $candidates) {
    if ($c -and (Test-Path (Join-Path $c 'bin/continuum.ps1'))) { $root = $c; break }
}
if (-not $root) { exit 0 }

$hookEvent = [Console]::In.ReadToEnd()

if ($hookEvent -notmatch '"error"\s*:\s*"rate_limit"') { exit 0 }

function Get-Str ($name) {
    if ($hookEvent -match ('"' + $name + '"\s*:\s*"([^"]*)"')) { return $Matches[1] }
    return ''
}
$sid = Get-Str 'session_id'
if (-not $sid) { $sid = 'unknown' }

# Junie's events carry project_path and no transcript_path; its cwd is ~/.junie, the
# project is project_path. Claude Code's cwd is the project.
$agent = 'claude'; $dir = Get-Str 'cwd'
if ($hookEvent -match '"project_path"\s*:' -and $hookEvent -notmatch '"transcript_path"\s*:') {
    $agent = 'junie'; $dir = Get-Str 'project_path'
}
# JSON escapes backslashes in Windows paths.
$dir = $dir -replace '\\\\', '\'
if (-not $dir -or -not (Test-Path $dir)) { $dir = (Get-Location).Path }

& (Join-Path $root 'bin/continuum.ps1') limit-hit $sid $agent $dir *> $null
exit 0
