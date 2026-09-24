# Claude Code Stop hook, PowerShell edition. Mirrors adapters/claude/stop.sh: a thin
# adapter - all the logic lives in `continuum.ps1 check`. This only translates
# Claude's event into its arguments, and its warning into a blocking reply.
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

$event = [Console]::In.ReadToEnd()

# Never re-block while Claude is already handling a block (infinite loop guard).
if ($event -match '"stop_hook_active"\s*:\s*true') { exit 0 }

$sid = 'unknown'
if ($event -match '"session_id"\s*:\s*"([^"]+)"') { $sid = $Matches[1] }

$reason = & (Join-Path $root 'bin/continuum.ps1') check --session $sid --agent claude
$reason = ($reason | Out-String).Trim()
if (-not $reason) { exit 0 }

@{ decision = 'block'; reason = $reason } | ConvertTo-Json -Compress
