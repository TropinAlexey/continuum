# PreToolUse hook, PowerShell edition. Mirrors hooks/frugal-gate.sh.
# When CONTINUUM_FRUGAL=1, blocks expensive tool calls (Agent subagents).

Set-StrictMode -Version 2.0
trap { exit 0 }

if (-not $env:CONTINUUM_FRUGAL) { exit 0 }

$event = [Console]::In.ReadToEnd()

if ($event -match '"tool_name"\s*:\s*"Agent"') {
    @{ decision = 'block'; reason = '[continuum] Frugal mode is active — subagent calls are blocked to conserve budget. Disable with CONTINUUM_FRUGAL= or pick ''Carry on'' at the next budget check.' } | ConvertTo-Json -Compress
}
