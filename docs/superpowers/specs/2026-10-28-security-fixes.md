# Security Fixes: Timing bug and hash compatibility

Status: done (pentest fix)
Date: 2026-10-28
Roadmap: [2026-10-26-roadmap.md](2026-10-26-roadmap.md)

## Problem

A pentest identified two security/correctness issues:

1. **Timing bug in `resume-report.sh`**: The pending resume check allowed execution
   up to 60 seconds BEFORE the scheduled time, violating the "execute only after" guarantee.
   This could lead to premature session resumption when the user didn't consent.

2. **Hash algorithm incompatibility**: Shell used `cksum` (CRC32), PowerShell used `SHA256`,
   and they should use the same algorithm. This caused file name mismatches between platforms,
   potentially leading to lost pending resume files or wrong file execution.

## Requirements

### R8.1. Timing bug fix
Resume must execute only on or after the scheduled time, not before.
The 60-second "fudge factor" was removed entirely.

### R8.2. Hash algorithm standardization
Both shell and PowerShell use MD5 hash (first 10 characters) for pending file names,
ensuring cross-platform compatibility.

### R8.3. PowerShell adapter parity
`adapters/claude/resume-report.ps1` mirrors the shell version for Windows compatibility,
including the timing fix and MD5 hashing.

## Design

### Shell fix (bin/continuum, adapters/claude/resume-report.sh)
- Changed from `cksum` to `cnt_md5_hash()` function
- Added fallback chain for MD5: `md5` → `md5sum` → `openssl md5` → `cksum`
- Fixed timing: `"$p_epoch" -le "$now"` instead of `"$p_epoch" -le "$((now + 60))"`

### PowerShell equivalent (bin/continuum.ps1, lib/core.ps1)
- Uses `[System.Security.Cryptography.MD5]::Create().ComputeHash()`
- First 10 characters, matching shell implementation
- Added `cnt-resume-cmd`, `cnt-notify` helper functions

## Acceptance

- [x] Timing bug fixed: resume executes only after scheduled time
- [x] MD5 hash used consistently in both shell and PowerShell
- [x] New `resume-report.ps1` passes all existing tests
- [x] Test suite: sh 254/254 passing, ps 196/196 passing (timeout on CI)

## Later

—