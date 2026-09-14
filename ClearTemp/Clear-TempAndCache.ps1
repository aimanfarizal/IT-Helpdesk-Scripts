<#
.SYNOPSIS
    Clears Windows temp files and browser caches to free up disk space.

.DESCRIPTION
    IT Helpdesk utility script. Clears:
      - Windows Temp folder (C:\Windows\Temp)
      - Current user's Temp folder (%TEMP%)
      - Recycle Bin
      - Browser caches: Chrome, Edge, Firefox (current user profile)

    Reports how much disk space was freed before/after.
    Safe to run with a normal user account for user-level caches;
    run as Administrator to also clear C:\Windows\Temp.

.NOTES
    Author: <your name>
    Usage : Right-click > Run with PowerShell, or run from an elevated
            PowerShell prompt for full cleanup.
#>

# ---------- CONFIG ----------
$LogFile = "$env:USERPROFILE\Desktop\ClearTempCache_Log.txt"
$ErrorActionPreference = "SilentlyContinue"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] $Message"
    Write-Host $entry
    Add-Content -Path $LogFile -Value $entry
}

function Get-FolderSizeMB {
    param([string]$Path)
    if (Test-Path $Path) {
        $size = (Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue |
                 Measure-Object -Property Length -Sum).Sum
        return [math]::Round(($size / 1MB), 2)
    }
    return 0
}

# ---------- START ----------
Write-Log "===== Clear Temp & Cache script started ====="

# Check disk space before
$driveBefore = Get-PSDrive -Name C
$freeBefore = [math]::Round(($driveBefore.Free / 1GB), 2)
Write-Log "Free disk space before cleanup: $freeBefore GB"

# ---------- 1. Windows Temp (needs admin) ----------
$winTemp = "$env:SystemRoot\Temp"
$sizeBefore = Get-FolderSizeMB $winTemp
Write-Log "Clearing Windows Temp folder ($winTemp) - Size: $sizeBefore MB"
Get-ChildItem -Path $winTemp -Recurse -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Write-Log "Windows Temp folder cleared."

# ---------- 2. User Temp ----------
$userTemp = $env:TEMP
$sizeBefore = Get-FolderSizeMB $userTemp
Write-Log "Clearing User Temp folder ($userTemp) - Size: $sizeBefore MB"
Get-ChildItem -Path $userTemp -Recurse -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Write-Log "User Temp folder cleared."

# ---------- 3. Recycle Bin ----------
Write-Log "Emptying Recycle Bin..."
try {
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
    Write-Log "Recycle Bin emptied."
} catch {
    Write-Log "Could not empty Recycle Bin (may already be empty)."
}

# ---------- 4. Browser Caches ----------

# Google Chrome
$chromeCache = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache"
if (Test-Path $chromeCache) {
    $sizeBefore = Get-FolderSizeMB $chromeCache
    Write-Log "Clearing Chrome cache - Size: $sizeBefore MB"
    Remove-Item -Path "$chromeCache\*" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "Chrome cache cleared."
} else {
    Write-Log "Chrome cache not found, skipping."
}

# Microsoft Edge
$edgeCache = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache"
if (Test-Path $edgeCache) {
    $sizeBefore = Get-FolderSizeMB $edgeCache
    Write-Log "Clearing Edge cache - Size: $sizeBefore MB"
    Remove-Item -Path "$edgeCache\*" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "Edge cache cleared."
} else {
    Write-Log "Edge cache not found, skipping."
}

# Mozilla Firefox (cache is inside a randomly-named profile folder)
$firefoxProfiles = "$env:APPDATA\Mozilla\Firefox\Profiles"
if (Test-Path $firefoxProfiles) {
    Get-ChildItem -Path $firefoxProfiles -Directory | ForEach-Object {
        $ffCache = Join-Path $_.FullName "cache2"
        if (Test-Path $ffCache) {
            $sizeBefore = Get-FolderSizeMB $ffCache
            Write-Log "Clearing Firefox cache in $($_.Name) - Size: $sizeBefore MB"
            Remove-Item -Path "$ffCache\*" -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Log "Firefox cache cleared."
} else {
    Write-Log "Firefox profile folder not found, skipping."
}

# ---------- SUMMARY ----------
$driveAfter = Get-PSDrive -Name C
$freeAfter = [math]::Round(($driveAfter.Free / 1GB), 2)
$freed = [math]::Round(($freeAfter - $freeBefore), 2)

Write-Log "Free disk space after cleanup: $freeAfter GB"
Write-Log "Approximate space freed: $freed GB"
Write-Log "===== Clear Temp & Cache script finished ====="

Write-Host "`nDone! Approximate space freed: $freed GB"
Write-Host "Log saved to: $LogFile"
