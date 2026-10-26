# Claude Code PostToolUse hook, PowerShell edition. Mirrors adapters/claude/tool-check.sh:
# the same warning as stop.ps1, but in the middle of a turn, handed to Claude as
# additionalContext. Tiers, cache and per-session flags are shared with stop.ps1.
#
# Claude Code runs hooks under PowerShell on Windows when Git Bash is absent.
# Wire it up with  "shell": "powershell"  - see the README.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Runs after every tool call: nothing below may throw past this point.
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

# Inside a subagent there is nobody to ask, and firing there would use up the tier
# before the main conversation sees it. Subagent tool calls carry agent_id.
if ($hookEvent -match '"agent_id"\s*:') { exit 0 }

$sid = 'unknown'
if ($hookEvent -match '"session_id"\s*:\s*"([^"]+)"') { $sid = $Matches[1] }

# Junie CLI installs this plugin from the marketplace and runs the same hooks; its
# events carry project_path, Claude Code's do not.
$agent = 'claude'
if ($hookEvent -match '"project_path"\s*:') { $agent = 'junie' }
# Junie fires PreToolUse but not PostToolUse, so this hook is wired to both; Claude
# Code keeps the PostToolUse one and skips the duplicate.
$hook = 'PostToolUse'
if ($hookEvent -match '"hook_event_name"\s*:\s*"PreToolUse"') { $hook = 'PreToolUse' }
if ($hook -eq 'PreToolUse' -and $agent -ne 'junie') { exit 0 }

$reason = & (Join-Path $root 'bin/continuum.ps1') check --session $sid --agent $agent
$reason = ($reason | Out-String).Trim()
if (-not $reason) { exit 0 }

$reason = "Mid-turn usage check. Finish the step you are on and leave the work in a consistent state (commit or a note), then act on this: $reason"

@{ hookSpecificOutput = @{ hookEventName = $hook; additionalContext = $reason } } | ConvertTo-Json -Compress
