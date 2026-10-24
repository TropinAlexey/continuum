# Shared by the adapters for agents whose hooks are commands speaking JSON on
# stdin/stdout (codex, gemini, cursor). PowerShell edition of adapters/lib.sh;
# dot-sourced, not run.

$script:CntMidturnPrefix = 'Mid-turn usage check. Finish the step you are on and leave the work in a consistent state (commit or a note), then act on this: '

# Find the code: explicit env, this checkout, or the pointer the CLI leaves in the
# state dir (for copies living in an agent's config dir).
function Get-CntAdapterRoot {
    $candidates = @($env:CONTINUUM_ROOT, (Split-Path -Parent $PSScriptRoot))
    if ($env:CONTINUUM_STATE_DIR) { $state = $env:CONTINUUM_STATE_DIR }
    elseif ($env:XDG_STATE_HOME) { $state = Join-Path $env:XDG_STATE_HOME 'continuum' }
    else { $state = Join-Path $HOME '.local/state/continuum' }
    $pointer = Join-Path $state 'root'
    if (Test-Path $pointer) { $candidates += [System.IO.File]::ReadAllText($pointer).Trim() }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path (Join-Path $c 'bin/continuum.ps1'))) { return $c }
    }
    return $null
}

# The first string value of "key" in the event, or $null.
function Get-CntAdapterStr ([string]$Json, [string]$Key) {
    if ($Json -match ('"' + $Key + '"\s*:\s*"([^"]*)"')) { return $Matches[1] }
    return $null
}

# The first number value of "key" in the event, or $null.
function Get-CntAdapterNum ([string]$Json, [string]$Key) {
    if ($Json -match ('"' + $Key + '"\s*:\s*(\d+)')) { return [int]$Matches[1] }
    return $null
}

function Test-CntAdapterTrue ([string]$Json, [string]$Key) {
    return [bool]($Json -match ('"' + $Key + '"\s*:\s*true'))
}

# The warning text, or '' when there is nothing to say.
function Get-CntAdapterWarning ([string]$Root, [string]$SessionId, [string]$Agent) {
    if (-not $SessionId) { $SessionId = 'unknown' }
    $w = & (Join-Path $Root 'bin/continuum.ps1') check --session $SessionId --agent $Agent
    return ($w | Out-String).Trim()
}
