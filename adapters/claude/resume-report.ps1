# Claude Code SessionStart hook, PowerShell edition.
# Reports completed resume runs and executes pending resumes after compaction.
# Mirrors adapters/claude/resume-report.sh for Windows compatibility.
#
# Claude Code runs hooks under PowerShell on Windows when Git Bash is absent.
# Wire it up with "shell": "powershell" - see the README.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# A SessionStart hook must never break the prompt: stay silent on any failure.
trap { exit 0 }

# Find the code: explicit env, the plugin root, this checkout, or the pointer the
# CLI leaves in the state dir (for copies living in an agent's config dir).
$root = $null
$candidates = @($env:CONTINUUM_ROOT, $env:CLAUDE_PLUGIN_ROOT, (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if ($env:CONTINUUM_STATE_DIR) { $state = $env:CONTINUUM_STATE_DIR }
elseif ($env:XDG_STATE_HOME) { $state = Join-Path $env:XDG_STATE_HOME 'continuum' }
else { $state = Join-Path $HOME '.local/state/continuum' }
$pointer = Join-Path $state 'root'
if (Test-Path $pointer) { $candidates += [System.IO.File]::ReadAllText($pointer).Trim() }
foreach ($c in $candidates) {
    if ($c -and (Test-Path (Join-Path $c 'bin/continuum.ps1'))) { $root = $c; break }
}
if (-not $root) { exit 0 }
. (Join-Path $root 'lib/core.ps1')

$LOG = Join-Path $state 'continuum-resume.log'

#$ Get current project directory from the event
$hookEvent = [Console]::In.ReadToEnd()
$projDir = $PWD
if ($hookEvent -match '"cwd"\s*:\s*"([^"]+)"') { $projDir = $Matches[1] }
elseif ($hookEvent -match '"project_path"\s*:\s*"([^"]+)"') { $projDir = $Matches[1] }

# Check for pending resumes for this project and execute if due
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
# Use MD5 hash (same as bin/continuum.ps1) for pending filename compatibility
# First 10 chars of MD5 hash, matching the pattern in bin/continuum.ps1
$projHash = [System.BitConverter]::ToString([System.Security.Cryptography.MD5]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($projDir))).Replace('-', '').Substring(0, 10)
$pendingFile = Join-Path $state ".continuum-pending-resume-$projHash"

if (Test-Path $pendingFile) {
    $content = Get-Content -Path $pendingFile -Raw
    $parts = $content -split '\|'
    if ($parts.Count -ge 4) {
        $pDir = $parts[0]
        $pEpoch = [int64]$parts[1]
        $pPrompt = $parts[2]
        $pAgent = $parts[3]
        $pScheduler = if ($parts.Count -gt 4) { $parts[4] } else { '' }

        # CRITICAL: Must execute only AFTER scheduled time, not before
        if ($pDir -eq $projDir -and $pEpoch -le $now) {
            Write-Host '[continuum] Pending resume found for this project, executing now...'

            # Cancel the OS-level scheduled job if possible
            if ($pScheduler) {
                switch -Regex ($pScheduler) {
                    '^launchd:.*' {
                        $label = $pScheduler -replace '^launchd:', ''
                        launchctl remove $label 2>$null
                    }
                    '^systemd:.*' {
                        $unit = $pScheduler -replace '^systemd:', ''
                        systemctl --user stop "${unit}.timer" 2>$null
                    }
                    '^daemon:.*' {
                        $pid = $pScheduler -replace '^daemon:', ''
                        kill $pid 2>$null
                    }
                    '^nohup:.*' {
                        $pid = $pScheduler -replace '^nohup:', ''
                        kill $pid 2>$null
                    }
                }
            }

            # Remove pending file so we don't execute again
            Remove-Item -Path $pendingFile -Force -ErrorAction SilentlyContinue

            # Get resume command
            $continueCmd = $null
            try { $continueCmd = cnt-resume-cmd } catch { $continueCmd = 'claude --continue -p "{prompt}" --permission-mode acceptEdits' }
            $extendedPrompt = "$pPrompt. Work autonomously: do not ask questions or wait for confirmation — make reasonable decisions, commit results when done, and report what you did in the final message."

            Write-Output ""
            Write-Host "### $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - resumed in $projDir (post-compaction)"
            Write-Output ""
            Push-Location $projDir
            try {
                & sh -c "$continueCmd" 2>> $LOG
                $status = $LASTEXITCODE
            } catch {
                $status = 1
            }
            Pop-Location
            Write-Output "### end (exit $status) - $projDir"

            if ($status -eq 0) {
                Write-Host '[continuum] Resume completed successfully.'
            } else {
                Write-Host "[continuum] Resume failed (exit $status). Check $LOG"
            }

            # Send notification
            cnt-notify "continuum" "Resume $status in $(Split-Path -Leaf $projDir)"
        }
    }
}

# `continuum limit-hit` leaves a note when the limit ran out mid-turn; show it at the
# next session start, once (last 24 h), without control characters.
$notes = Join-Path $state '.continuum-limit-notes'
if (Test-Path $notes) {
    $cutoff = $now - 86400
    Get-Content -Path $notes | ForEach-Object {
        if ($_ -match '^\d+') {
            $ts = [int64]($_.Split("`t")[0])
            if ($ts -ge $cutoff) {
                $msg = ($_ -split "	")[1]
                $msg = $msg -replace '[\x01-\x1F\x7F]', ''
                Write-Host "[continuum] $msg"
            }
        }
    }
    Remove-Item -Path $notes -Force -ErrorAction SilentlyContinue
}

if (Test-Path $LOG) { exit 0 }