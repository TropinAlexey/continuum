# continuum installer for Windows.
#
#   irm https://raw.githubusercontent.com/TropinAlexey/continuum/main/install.ps1 | iex
#
# What it does, and nothing else:
#   1. copies continuum into %USERPROFILE%\.continuum
#   2. adds that folder's bin to your user PATH
#   3. tells you the one line to turn on the Claude Code warning (optional)
#
# No admin rights. No service. Re-run any time to update.

$ErrorActionPreference = 'Stop'

$repo = 'https://github.com/TropinAlexey/continuum'
$dest = if ($env:CONTINUUM_HOME) { $env:CONTINUUM_HOME } else { Join-Path $HOME '.continuum' }

Write-Host "`ncontinuum installer`n"

# --- 1. get the files -------------------------------------------------
$here = if ($PSScriptRoot) { $PSScriptRoot } else { $null }
if ($here -and (Test-Path (Join-Path $here 'bin/continuum.ps1'))) {
    Write-Host "  copying from $here"
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    foreach ($d in 'bin', 'lib', 'providers', 'hooks', 'skills') {
        if (Test-Path (Join-Path $here $d)) {
            Copy-Item -Recurse -Force (Join-Path $here $d) $dest
        }
    }
} elseif (Get-Command git -ErrorAction SilentlyContinue) {
    if (Test-Path (Join-Path $dest '.git')) {
        Write-Host "  updating $dest"
        git -C $dest pull --quiet --ff-only
    } else {
        Write-Host "  cloning into $dest"
        if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
        git clone --quiet --depth 1 $repo $dest
    }
} else {
    throw 'need either a local checkout or git installed'
}

# --- 2. put continuum on the PATH -------------------------------------
$bin = Join-Path $dest 'bin'
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not $userPath) { $userPath = '' }
if (($userPath -split ';') -notcontains $bin) {
    [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $bin), 'User')
    Write-Host "  added to your PATH: $bin"
    Write-Host "  (reopen your terminal for it to take effect)"
} else {
    Write-Host "  already on PATH: $bin"
}

# A `continuum` shim so you type the name without the .ps1 extension.
$shim = Join-Path $bin 'continuum.cmd'
Set-Content -Path $shim -Encoding ascii -Value @"
@echo off
pwsh -NoProfile -File "%~dp0continuum.ps1" %*
"@

# --- 3. done ----------------------------------------------------------
Write-Host "`nDone. Reopen your terminal, then try:`n"
Write-Host "  continuum status"
Write-Host "  continuum watch`n"
Write-Host "Using Claude Code and want the automatic warning? Add this once,"
Write-Host "inside Claude Code:`n"
Write-Host "  /plugin marketplace add TropinAlexey/continuum"
Write-Host "  /plugin install continuum`n"
