# continuum - shared helpers, PowerShell edition (Windows without Git Bash).
#
# Mirrors lib/core.sh. Same provider protocol: a provider prints one line per
# usage window on stdout,
#
#     <window> <utilization> <reset_epoch>
#
# the first line being the primary window. On failure it writes to stderr and
# exits non-zero, printing nothing.
#
# Targets Windows PowerShell 5.1 as well as pwsh 7: no ternaries, no ??.

Set-StrictMode -Version 2.0

if ($env:CLAUDE_CONFIG_DIR) { $script:CntCfg = $env:CLAUDE_CONFIG_DIR }
else { $script:CntCfg = Join-Path $HOME '.claude' }

if ($env:CONTINUUM_PROVIDER) { $script:CntProvider = $env:CONTINUUM_PROVIDER }
else { $script:CntProvider = 'anthropic' }

if ($env:CLAUDE_PLUGIN_ROOT) { $script:CntRoot = $env:CLAUDE_PLUGIN_ROOT }
else { $script:CntRoot = Split-Path -Parent $PSScriptRoot }

function Get-CntProviders {
    foreach ($d in @((Join-Path $script:CntRoot 'providers'), (Join-Path $script:CntCfg 'providers'))) {
        if (Test-Path $d) {
            Get-ChildItem -Path $d -Filter '*.ps1' | ForEach-Object { $_.BaseName }
        }
    }
}

function Get-CntProviderPath {
    param([string]$Name)
    foreach ($d in @((Join-Path $script:CntRoot 'providers'), (Join-Path $script:CntCfg 'providers'))) {
        $p = Join-Path $d "$Name.ps1"
        if (Test-Path $p) { return $p }
    }
    return $null
}

# Returns the provider's lines as a string array. Throws on failure.
function Read-CntUsage {
    $p = Get-CntProviderPath $script:CntProvider
    if (-not $p) {
        throw "unknown provider '$($script:CntProvider)' (have: $((Get-CntProviders) -join ' '))"
    }
    $global:LASTEXITCODE = 0        # StrictMode: never read it before it exists
    $lines = & $p
    if ($LASTEXITCODE -ne 0) { throw "provider '$($script:CntProvider)' failed" }
    if (-not $lines) { throw "provider '$($script:CntProvider)' returned nothing" }
    return @($lines | Where-Object { $_ -and $_.Trim() })
}

# "2026-07-09T17:40:00.180+00:00" -> unix epoch seconds
function ConvertTo-CntEpoch {
    param([string]$Iso)
    $dt = [datetimeoffset]::Parse($Iso, [cultureinfo]::InvariantCulture)
    return [int64]$dt.ToUnixTimeSeconds()
}

# epoch (+ optional margin) -> local HH:mm
function ConvertTo-CntHhmm {
    param([int64]$Epoch, [int]$MarginSeconds = 0)
    $dt = [datetimeoffset]::FromUnixTimeSeconds($Epoch + $MarginSeconds).ToLocalTime()
    return $dt.ToString('HH:mm')
}

# "19:40" -> seconds until the next local occurrence of that time
function Get-CntHhmmDelay {
    param([string]$Hhmm)
    if ($Hhmm -notmatch '^([01]?[0-9]|2[0-3]):[0-5][0-9]$') {
        throw "invalid time: $Hhmm (expected HH:MM)"
    }
    $parts  = $Hhmm.Split(':')
    $now    = Get-Date
    $target = $now.Date.AddHours([int]$parts[0]).AddMinutes([int]$parts[1])
    if ($target -le $now) { $target = $target.AddDays(1) }   # already passed -> tomorrow
    return [int]($target - $now).TotalSeconds
}

# Token lookup, Windows edition: env var, then Claude Code's credentials file.
# There is no Keychain here; Claude Code stores JSON under the config dir.
#
# WARNING: returns your OAuth access token. Never write it to a log or transcript.
function Get-CntToken {
    if ($env:CLAUDE_CODE_OAUTH_TOKEN) { return $env:CLAUDE_CODE_OAUTH_TOKEN }
    $f = Join-Path $script:CntCfg '.credentials.json'
    if (Test-Path $f) {
        $raw = Get-Content -Raw -Path $f | ConvertFrom-Json
        if ($raw.claudeAiOauth -and $raw.claudeAiOauth.accessToken) { return $raw.claudeAiOauth.accessToken }
        if ($raw.accessToken) { return $raw.accessToken }
    }
    return $null
}
