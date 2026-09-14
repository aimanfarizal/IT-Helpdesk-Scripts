# Clear-TempAndCache.ps1

A PowerShell script for IT Helpdesk officers to quickly free up disk space
on a user's Windows machine by clearing temp files, the Recycle Bin, and
browser caches (Chrome, Edge, Firefox).

## What it does
- Clears `C:\Windows\Temp` (requires admin rights)
- Clears the current user's `%TEMP%` folder
- Empties the Recycle Bin
- Clears cache folders for Chrome, Edge, and Firefox
- Logs every step with timestamps to a log file on the Desktop
- Reports total disk space freed at the end

## When to use it
- User reports "my laptop is slow" or "disk full" warnings
- Before/after a software install that needs free disk space
- Routine maintenance during a support ticket

## How to run
1. Right-click the script → **Run with PowerShell** (user-level cleanup only), OR
2. Open an **elevated (Administrator)** PowerShell window and run:
   ```powershell
   .\Clear-TempAndCache.ps1
   ```
   Running as Administrator is needed to also clear `C:\Windows\Temp`.

> Note: You may need to allow script execution first:
> ```powershell
> Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
> ```

## Output
- Console output showing each step and final space freed
- A log file saved to `Desktop\ClearTempCache_Log.txt` for ticket documentation

## Sample output
```
[2026-09-14 10:32:01] ===== Clear Temp & Cache script started =====
[2026-09-14 10:32:01] Free disk space before cleanup: 12.4 GB
[2026-09-14 10:32:03] Clearing Windows Temp folder (C:\Windows\Temp) - Size: 210.5 MB
[2026-09-14 10:32:05] Windows Temp folder cleared.
...
[2026-09-14 10:32:20] Free disk space after cleanup: 13.1 GB
[2026-09-14 10:32:20] Approximate space freed: 0.7 GB
```

## Notes
- Safe to run — only clears cache/temp data, never user documents.
- Some browser files may be skipped if the browser is currently open and
  locking files; closing browsers first gives the most thorough cleanup.
- Tested on Windows 10/11.
