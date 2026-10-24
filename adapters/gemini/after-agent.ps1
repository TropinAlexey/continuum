# Gemini CLI AfterAgent hook, PowerShell edition. Mirrors adapters/gemini/after-agent.sh.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
# A hook that errors spams the user. Nothing below may throw past this point.
trap { exit 0 }
if ($env:CONTINUUM_OFF) { exit 0 }
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib.ps1')
$root = Get-CntAdapterRoot
if (-not $root) { exit 0 }
$event = [Console]::In.ReadToEnd()
# Never deny again while Gemini is already retrying because of a hook.
if (Test-CntAdapterTrue $event 'stop_hook_active') { exit 0 }
$reason = Get-CntAdapterWarning $root (Get-CntAdapterStr $event 'session_id') 'gemini'
if (-not $reason) { exit 0 }
@{ decision = 'deny'; reason = $reason } | ConvertTo-Json -Compress
