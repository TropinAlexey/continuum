# Cursor stop hook, PowerShell edition. Mirrors adapters/cursor/stop.sh.
# On Windows, Cursor runs hook commands through PowerShell.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
# A hook that errors spams the user. Nothing below may throw past this point.
trap { exit 0 }
if ($env:CONTINUUM_OFF) { exit 0 }
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib.ps1')
$root = Get-CntAdapterRoot
if (-not $root) { exit 0 }
$event = [Console]::In.ReadToEnd()
# Only after a turn that completed, and never inside our own follow-up loop.
$status = Get-CntAdapterStr $event 'status'
if ($status -and $status -ne 'completed') { exit 0 }
$loop = Get-CntAdapterNum $event 'loop_count'
if ($loop -and $loop -gt 0) { exit 0 }
$reason = Get-CntAdapterWarning $root (Get-CntAdapterStr $event 'conversation_id') 'cursor'
if (-not $reason) { exit 0 }
@{ followup_message = $reason } | ConvertTo-Json -Compress
