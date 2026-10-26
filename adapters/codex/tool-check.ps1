# Codex CLI PostToolUse hook, PowerShell edition. Mirrors adapters/codex/tool-check.sh.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
# A hook that errors spams the user. Nothing below may throw past this point.
trap { exit 0 }
if ($env:CONTINUUM_OFF) { exit 0 }
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib.ps1')
$root = Get-CntAdapterRoot
if (-not $root) { exit 0 }
$hookEvent = [Console]::In.ReadToEnd()
$reason = Get-CntAdapterWarning $root (Get-CntAdapterStr $hookEvent 'session_id') 'codex'
if (-not $reason) { exit 0 }
@{ hookSpecificOutput = @{ hookEventName = 'PostToolUse'; additionalContext = $script:CntMidturnPrefix + $reason } } | ConvertTo-Json -Compress
