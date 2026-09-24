# Moved to adapters/claude/stop.ps1. Kept so existing configs keep working; removed in v0.7.
$t = Join-Path $PSScriptRoot "../adapters/claude/stop.ps1"
if (Test-Path $t) { & $t }
