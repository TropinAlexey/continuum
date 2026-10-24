# Gemini CLI AfterTool hook, PowerShell edition. Mirrors adapters/gemini/after-tool.sh.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
# A hook that errors spams the user. Nothing below may throw past this point.
trap { exit 0 }
if ($env:CONTINUUM_OFF) { exit 0 }
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib.ps1')
$root = Get-CntAdapterRoot
if (-not $root) { exit 0 }
$event = [Console]::In.ReadToEnd()
$reason = Get-CntAdapterWarning $root (Get-CntAdapterStr $event 'session_id') 'gemini'
if (-not $reason) { exit 0 }
@{ hookSpecificOutput = @{ hookEventName = 'AfterTool'; additionalContext = $script:CntMidturnPrefix + $reason } } | ConvertTo-Json -Compress
