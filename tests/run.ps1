# continuum test suite (PowerShell). Mirrors tests/run.sh. Mock provider, no network.
#   pwsh tests/run.ps1

$ErrorActionPreference = 'Continue'

$root = Split-Path -Parent $PSScriptRoot
$env:CLAUDE_PLUGIN_ROOT = $root
$env:CONTINUUM_PROVIDER = 'mock'
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("continuum-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

$script:pass = 0
$script:fail = 0
function Ok  ($n) { $script:pass++; Write-Host "  ok   $n" }
function Bad ($n, $why) { $script:fail++; Write-Host "  FAIL $n`n     $why" }
function Check ($n, $expect, $actual) {
    if ($actual -and ($actual -join "`n").Contains($expect)) { Ok $n }
    else { Bad $n "expected to contain '$expect', got: $actual" }
}
function Hook ($cfg, $stdin) {
    $env:CLAUDE_CONFIG_DIR = Join-Path $tmp $cfg
    $out = $stdin | & pwsh -NoProfile -File (Join-Path $root 'hooks/continuum-check.ps1') 2>$null
    return ($out -join '')
}
# NB: do not name this `Cli` - that is a built-in alias for Clear-Item, and
# aliases outrank functions in PowerShell's command resolution.
function Invoke-Continuum {
    & pwsh -NoProfile -File (Join-Path $root 'bin/continuum.ps1') @args 2>$null
}

Write-Host "cli:"
Check "status lists both windows" "5 hours" (Invoke-Continuum status)
Check "status shows weekly"       "7 days"  (Invoke-Continuum status)
Check "providers lists mock"      "mock"    (Invoke-Continuum providers)
Check "reset prints HH:MM"        ":"       (Invoke-Continuum reset)

$env:CONTINUUM_MOCK_FAIL = '1'
Invoke-Continuum status *>$null
if ($LASTEXITCODE -ne 0) { Ok "status fails when provider fails" }
else { Bad "status fails when provider fails" "exit 0" }
Remove-Item Env:CONTINUUM_MOCK_FAIL

$env:CONTINUUM_PROVIDER = 'nope'
Invoke-Continuum status *>$null
if ($LASTEXITCODE -ne 0) { Ok "unknown provider fails" } else { Bad "unknown provider fails" "exit 0" }
$env:CONTINUUM_PROVIDER = 'mock'

Write-Host "hook:"
$out = Hook 'a' '{"session_id":"a"}'
Check "blocks over threshold"  '"decision":"block"' $out
Check "reports utilization"    "86% used"           $out
Check "mentions second window" "7d window 41.0%"    $out

$out = Hook 'a' '{"session_id":"a"}'
if (-not $out) { Ok "warns once per session" } else { Bad "warns once per session" $out }

$env:CONTINUUM_MOCK = "46.0 10.0"
$out = Hook 'b' '{"session_id":"b"}'
if (-not $out) { Ok "silent under threshold" } else { Bad "silent under threshold" $out }
Remove-Item Env:CONTINUUM_MOCK

$env:CONTINUUM_MOCK = "93.2"
$out = Hook 'e' '{"session_id":"e"}'
Check "single-window provider" '"decision":"block"' $out
if ($out -notmatch 'Also:') { Ok "no phantom second window" } else { Bad "no phantom second window" $out }
Remove-Item Env:CONTINUUM_MOCK

$env:CONTINUUM_MOCK_FAIL = '1'
$out = Hook 'c' '{"session_id":"c"}'
if (-not $out) { Ok "silent when provider fails" } else { Bad "silent when provider fails" $out }
if (Test-Path (Join-Path $tmp 'c/.continuum-cache-mock.fail')) { Ok "negative cache written" }
else { Bad "negative cache written" "missing" }
Remove-Item Env:CONTINUUM_MOCK_FAIL

$out = Hook 'd' '{"session_id":"d","stop_hook_active":true}'
if (-not $out) { Ok "respects stop_hook_active" } else { Bad "respects stop_hook_active" $out }

$env:CONTINUUM_OFF = '1'
$out = Hook 'f' '{"session_id":"f"}'
if (-not $out) { Ok "respects CONTINUUM_OFF" } else { Bad "respects CONTINUUM_OFF" $out }
Remove-Item Env:CONTINUUM_OFF

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
Write-Host "`n$script:pass passed, $script:fail failed"
if ($script:fail -gt 0) { exit 1 }
