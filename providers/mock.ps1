# continuum provider: mock (PowerShell). Canned numbers, no network.
#
# Test rig and template in one. Copy it, replace the Write-Output lines with a
# real lookup, done.
#
#   $env:CONTINUUM_MOCK      = "86.5 41.0"   primary and secondary utilization
#   $env:CONTINUUM_MOCK_FAIL = "1"           pretend the source is unreachable

Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '../lib/core.ps1')

# A provider that cannot answer writes to stderr, prints nothing, exits non-zero.
# Never guess, never print a fake zero.
if ($env:CONTINUUM_MOCK_FAIL) {
    [Console]::Error.WriteLine('mock: pretending the source is down')
    exit 1
}

$spec = '86.5 41.0'
if ($env:CONTINUUM_MOCK) { $spec = $env:CONTINUUM_MOCK }
$parts = $spec.Split(' ', [StringSplitOptions]::RemoveEmptyEntries)

$now = [int64][datetimeoffset]::UtcNow.ToUnixTimeSeconds()

# <window> <utilization> <reset_epoch>  -- first line is the one the hook watches.
Write-Output ("5h {0} {1}" -f $parts[0], ($now + 3600))
if ($parts.Count -gt 1) {
    Write-Output ("7d {0} {1}" -f $parts[1], ($now + 4 * 86400))
}

exit 0
