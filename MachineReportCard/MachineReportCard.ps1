<#
====================================================================================
 BEFORE USING THIS SCRIPT:
 Search for "CONFIGURE ME" below and update the values for your own environment
 (local report folder, SMTP server, sender/recipient addresses).
====================================================================================
#>

# Ensure the folder exists
# CONFIGURE ME: local folder used to stage report files before the HTML is built
$FolderPath = "C:\ReportCard\MDE"
If (!(Test-Path -Path $FolderPath)) {
    New-Item -ItemType Directory -Path $FolderPath -Force
}

# Define output file paths
$CsvFile = "$FolderPath\ComputerDetails.csv"
$HtmlFile = "$FolderPath\MachineReport.html"




#####Request PIC for Report Card
# Prompt for PIC name

Write-Host "👤 Please enter the PIC name (HELPDESK STAFF) for this laptop" -ForegroundColor Cyan
$PicName1 = Read-Host

Write-Host "👤 Please enter the PIC name (INTERN) for this report card" -ForegroundColor Green
$PicName = Read-Host


# Get current date & time (local system time)
# Adjust the format if you prefer (e.g., "dd/MM/yyyy HH:mm:ss" or include timezone)
$NowLocal = Get-Date
$ReportDateTime = $NowLocal.ToString("yyyy-MM-dd HH:mm:ss")  # e.g., 2026-01-02 11:59:45

# HTML-escape values
$PicName = [System.Security.SecurityElement]::Escape($PicName)
$PicName1 = [System.Security.SecurityElement]::Escape($PicName1)
$ReportDateTime = [System.Security.SecurityElement]::Escape($ReportDateTime)





# 1) Get Computer Details
$ComputerSystem = Get-CimInstance Win32_ComputerSystem
$BIOS = Get-CimInstance Win32_BIOS
$OS = Get-CimInstance Win32_OperatingSystem

# Map Windows build number to release name
$BuildNumber = [int]$OS.BuildNumber
$OSRelease = switch ($BuildNumber) {
    {$_ -ge 26200} {"Windows 11 25H2"; break}
    {$_ -ge 26100} {"Windows 11 24H2"; break}
    {$_ -ge 22631} {"Windows 11 23H2"; break}
    default {"Unknown Operating System"}
}

# Collect computer details
$ComputerInfo = @{
    ComputerName    = $ComputerSystem.Name
    Model           = $ComputerSystem.Model
    SerialNumber    = $BIOS.SerialNumber
    OSEdition       = $OS.Caption
    OperatingSystem = $OSRelease
    OSVersion       = $OS.Version
}

# Export Computer Details to CSV
$ComputerObject = New-Object PSObject -Property $ComputerInfo
$ComputerObject | Export-Csv -Path $CsvFile -NoTypeInformation
Write-Host "Computer Details report exported to $CsvFile"

# --------------------------------------------------------------
# 2) Windows Advanced Threat Protection (ATP) Onboarding via Registry
# --------------------------------------------------------------


# Get ATP registry info
$ATPStatus = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status"

# Determine ATPResult based on conditions
$ATPResult = if (-not [string]::IsNullOrEmpty($ATPStatus.OrgId) -and $ATPStatus.OnboardingState -eq 1) {
    $true
} else {
    $false
}

# Create custom object with ATP properties
$Report = [PSCustomObject]@{
    ConfigurationVersion = $ATPStatus.ConfigurationVersion
    OrgId                = $ATPStatus.OrgId
    OnboardingState      = $ATPStatus.OnboardingState
    PSPath               = $ATPStatus.PSPath
    ATPResult            = $ATPResult
}



# Export to CSV
$Report | Export-Csv -Path "$folderPath\ATP.csv" -NoTypeInformation
Write-Host "ATP report exported to $folderPath\ATP.csv"


# -------------------------------
# 3) BitLocker
# -------------------------------



# Create output folder
$OutDir = 'C:\ReportCard\MDE'
$OutFile = Join-Path $OutDir 'bitlocker.csv'
if (-not (Test-Path $OutDir)) { New-Item -Path $OutDir -ItemType Directory -Force | Out-Null }

$mount = 'C:'

# Get core BitLocker info via Get-BitLockerVolume
$blv = Get-BitLockerVolume -MountPoint $mount

# Parse BitLocker Version from manage-bde -status
$mbdeStatus = (manage-bde -status $mount) -join [environment]::NewLine
$version = ($mbdeStatus -split "`r?`n" | Where-Object { $_ -match 'BitLocker Version\s*:\s*(.+)$' } |
    ForEach-Object { ($_.Trim() -replace '.*:\s*','').Trim() } | Select-Object -First 1)

# Key protector methods (e.g., RecoveryPassword; TpmPin; Tpm; ExternalKey)
$kpMethods = ($blv.KeyProtector |
    Select-Object -ExpandProperty KeyProtectorType |
    Sort-Object -Unique) -join '; '

# Percentage Encrypted
$percent =
    if ($blv.PSObject.Properties.Name -contains 'EncryptionPercentage') { [int]$blv.EncryptionPercentage }
    elseif ($blv.PSObject.Properties.Name -contains 'PercentageEncrypted') { [int]$blv.PercentageEncrypted }
    else { $null }

# Size in GB
$sizeGB =
    if ($blv.PSObject.Properties.Name -contains 'CapacityGB') { [math]::Round([double]$blv.CapacityGB, 2) }
    else { $null }

# Protection status
$protStatus =
    switch ($blv.ProtectionStatus) {
        0 { 'Off' }
        1 { 'On' }
        2 { 'Unknown' }
        default { [string]$blv.ProtectionStatus }
    }

# Encryption method
$encMethod = [string]$blv.EncryptionMethod

# ===== Updated Status Check (NO Backup validation) =====
$expectedKP = @('RecoveryPassword','TpmPin')

$kpList = @()
if ($kpMethods) {
    $kpList = ($kpMethods -split ';\s*' | ForEach-Object { $_.Trim() }) | Where-Object { $_ }
}

$protOK    = ($protStatus -eq 'On')
$missingKP = $expectedKP | Where-Object { $kpList -notcontains $_ }

$status = $protOK -and ($missingKP.Count -eq 0)

$issues = @()
if (-not $protOK)         { $issues += 'ProtectionStatus is not On' }
if ($missingKP.Count -gt 0){ $issues += 'Missing KeyProtector(s): ' + ($missingKP -join ', ') }

$statusNote = if ($issues.Count) { $issues -join '; ' } else { 'Recovery Password and Pin exist' }

# Create export object
$row = [pscustomobject]@{
    Drive               = $mount
    SizeGB              = $sizeGB
    BitLockerVersion    = $version
    PercentageEncrypted = $percent
    EncryptionMethod    = $encMethod
    ProtectionStatus    = $protStatus
    KeyProtectorMethods = $kpMethods
    Status              = $status
    StatusNote          = $statusNote
}

# Export CSV
$row | Export-Csv -Path $OutFile -NoTypeInformation -Encoding UTF8

Write-Host "BitLocker details exported to: $OutFile"

 


# -------------------------------
# 4) Co-Management & SCCM Status
# -------------------------------
$CoMgmtFile = "$FolderPath\CoManagement.csv"
$SccmFile   = "$FolderPath\SCCM.csv"

# Get Co-Management info
$coMgmt = Get-CimInstance -Namespace "root\ccm\invagt" -ClassName "CCM_System" -ErrorAction SilentlyContinue
$guidValue = if ([string]::IsNullOrWhiteSpace(($coMgmt.SMSID -replace "GUID:", ""))) { "N/A" } else { ($coMgmt.SMSID -replace "GUID:", "") }
$domainValue = if ([string]::IsNullOrWhiteSpace($coMgmt.Domain)) { "N/A" } else { $coMgmt.Domain }
$coManagedValue = if ([string]::IsNullOrWhiteSpace($coMgmt.CoManaged) -or $domainValue -eq "N/A" -or $guidValue -eq "N/A") { $false } else { $coMgmt.CoManaged }

$coMgmtObj = [PSCustomObject]@{
    Domain    = $domainValue
    GUID      = $guidValue
    CoManaged = $coManagedValue
}
$coMgmtObj | Export-Csv -Path $CoMgmtFile -NoTypeInformation -Encoding UTF8

# Get SCCM info
$sccm = Get-CimInstance -Namespace "ROOT\ccm" -ClassName "CCM_PendingDeploymentStateMessage" -ErrorAction SilentlyContinue
$logPath = "C:\Windows\ccmsetup\Logs\ccmsetup.log"
$returnCodeLine = $null
if (Test-Path $logPath) {
    $returnCodeLine = Get-Content $logPath | Select-String "CcmSetup is exiting with return code" | Select-Object -Last 1
}
$sccmStatusRaw = if ($returnCodeLine) { $returnCodeLine.Line.Trim() } else { "Not Found" }

$clientVersionValue = if ([string]::IsNullOrWhiteSpace($sccm.ClientVersion)) { "N/A" } else { $sccm.ClientVersion }
$messageTimeValue = if ([string]::IsNullOrWhiteSpace($sccm.MessageTime)) { "N/A" } else { $sccm.MessageTime }

# Apply new logic
if ($sccmStatusRaw -match "CcmSetup is exiting with return code 0" -and $messageTimeValue -ne "N/A") {
    $sccmStatus = "CcmSetup is exiting with return code 0"
    $sccmSuccess = $true
} else {
    $sccmStatus = "Error"
    $sccmSuccess = $false
}

$sccmObj = [PSCustomObject]@{
    ClientVersion   = $clientVersionValue
    LatestTimestamp = $messageTimeValue
    SCCMStatus      = $sccmStatus
    SCCM            = $sccmSuccess
}
$sccmObj | Export-Csv -Path $SccmFile -NoTypeInformation -Encoding UTF8
Write-Host "CO Management report exported to $CoMgmtFile"
Write-Host "SCCM report exported to $SccmFile"





# -------------------------------
# 5) SenseCM (MDE) Enrollment
# -------------------------------


# Trigger Windows Defender Full Scan in background (hidden)
Write-Host "🛡️ Triggering Windows Defender Full Scan..." -ForegroundColor Yellow
# Start Full Scan hidden via a background PowerShell instance
Start-Process "powershell.exe" -ArgumentList '-NoProfile -WindowStyle Hidden -Command "Start-MpScan -ScanType FullScan"' -WindowStyle Hidden



# Output file
$FileName = "$Path\Ms Defender.csv"

# Get Defender status
$DefenderInfo = Get-CimInstance -Namespace root/Microsoft/Windows/Defender -ClassName MSFT_MpComputerStatus

# Determine Ms Defender status based on all required properties
$MsDefenderStatus = ($DefenderInfo.AMServiceEnabled -and
                     $DefenderInfo.AntispywareEnabled -and
                     $DefenderInfo.BehaviorMonitorEnabled -and
                     $DefenderInfo.IoavProtectionEnabled -and
                     $DefenderInfo.IsTamperProtected -and
                     $DefenderInfo.NISEnabled -and
                     $DefenderInfo.OnAccessProtectionEnabled -and
                     $DefenderInfo.RealTimeProtectionEnabled)

# Select only required properties + Ms Defender status
$SelectedData = [PSCustomObject]@{
    AMEngineVersion                 = $DefenderInfo.AMEngineVersion
    AMProductVersion                = $DefenderInfo.AMProductVersion
    AMServiceEnabled                = $DefenderInfo.AMServiceEnabled
    AMServiceVersion                = $DefenderInfo.AMServiceVersion
    AntispywareEnabled              = $DefenderInfo.AntispywareEnabled
    AntispywareSignatureLastUpdated = $DefenderInfo.AntispywareSignatureLastUpdated
    AntispywareSignatureVersion     = $DefenderInfo.AntispywareSignatureVersion
    AntivirusEnabled                = $DefenderInfo.AntivirusEnabled
    AntivirusSignatureLastUpdated   = $DefenderInfo.AntivirusSignatureLastUpdated
    AntivirusSignatureVersion       = $DefenderInfo.AntivirusSignatureVersion
    BehaviorMonitorEnabled          = $DefenderInfo.BehaviorMonitorEnabled
    ComputerID                      = $DefenderInfo.ComputerID
    FullScanAge                     = $DefenderInfo.FullScanAge
    FullScanEndTime                 = $DefenderInfo.FullScanEndTime
    FullScanSignatureVersion        = $DefenderInfo.FullScanSignatureVersion
    FullScanStartTime               = $DefenderInfo.FullScanStartTime
    IoavProtectionEnabled           = $DefenderInfo.IoavProtectionEnabled
    IsTamperProtected               = $DefenderInfo.IsTamperProtected
    NISEnabled                      = $DefenderInfo.NISEnabled
    NISEngineVersion                = $DefenderInfo.NISEngineVersion
    NISSignatureLastUpdated         = $DefenderInfo.NISSignatureLastUpdated
    NISSignatureVersion             = $DefenderInfo.NISSignatureVersion
    OnAccessProtectionEnabled       = $DefenderInfo.OnAccessProtectionEnabled
    RealTimeProtectionEnabled       = $DefenderInfo.RealTimeProtectionEnabled
    MsDefender                      = if ($MsDefenderStatus) { "True" } else { "False" }
}

# Export to CSV
#$SelectedData | Export-Csv -Path $FileName -NoTypeInformation -Force




# -------------------------------
# 6) Qualys Onboarding Status
# -------------------------------

# Output file
$FileName = "$Path\Qualys.csv"

# Get Qualys registry info
$QualysInfo = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Qualys'

# Extract required properties
$ActivationID = $QualysInfo.ActivationID
$CustomerID = $QualysInfo.CustomerID
$AgentInstallPath = $QualysInfo.AgentInstallPath

# Determine Qualys status
$QualysStatus = ($ActivationID -and $CustomerID -and $AgentInstallPath)

# Prepare object for export
$Output = [PSCustomObject]@{
    ActivationID      = $ActivationID
    CustomerID        = $CustomerID
    AgentInstallPath  = $AgentInstallPath
    QualysStatus      = $QualysStatus
}

# Export to CSV
#$Output | Export-CSV -Path $FileName -NoTypeInformation
Write-Host "Qualys report exported to $FileName"





# -------------------------------
# 7) LAPS
# -------------------------------

$Path = "C:\ReportCard\MDE"

# Create folder if not exists
if (!(Test-Path $Path)) {
    New-Item -Path $Path -ItemType Directory -Force | Out-Null
}


# LAPS Registry: list value names for two keys
$FileName_LAPS = Join-Path $Path "LAPS.csv"
$Output = @()


# LAPS State
$RegPath1 = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\LAPS\State"
if (Test-Path $RegPath1) {
    $Key1   = Get-Item $RegPath1
    $Names1 = $Key1.GetValueNames() -join ", "
    # Convert to full display path: Computer\HKEY_LOCAL_MACHINE\...
    $Source1 = ($Key1.Name -replace '^HKEY_LOCAL_MACHINE','Computer\HKEY_LOCAL_MACHINE')
} else {
    $Names1  = "[Key not found]"
    $Source1 = "Computer\HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\LAPS\State"
}
$Output += [pscustomobject]@{
    Source = $Source1
    Name   = $Names1
}


# LAPS Policies
$RegPath2 = "HKLM:\SOFTWARE\Microsoft\Policies\LAPS"
if (Test-Path $RegPath2) {
    $Key2   = Get-Item $RegPath2
    $Names2 = $Key2.GetValueNames() -join ", "
    # Convert to full display path: Computer\HKEY_LOCAL_MACHINE\...
    $Source2 = ($Key2.Name -replace '^HKEY_LOCAL_MACHINE','Computer\HKEY_LOCAL_MACHINE')
} else {
    $Names2  = "[Key not found]"
    $Source2 = "Computer\HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Policies\LAPS"
}
$Output += [pscustomobject]@{
    Source = $Source2
    Name   = $Names2
}

# Export CSV (LAPS.csv)
$Output | Export-Csv -Path $FileName_LAPS -NoTypeInformation -Encoding UTF8


# LAPS Results
$LapsResult = $true
$LapsReason = @()

if (!(Test-Path $RegPath1)) {
    $LapsResult = $false
    $LapsReason += "Missing LAPS State registry key"
}

if (!(Test-Path $RegPath2)) {
    $LapsResult = $false
    $LapsReason += "Missing LAPS Policies registry key"
}

if ($LapsReason.Count -eq 0) {
    $LapsReason = "LAPS Policies Exist"
} else {
    $LapsReason = $LapsReason -join "; "
}

Write-Host "LAPS report exported to $FileName_LAPS"


# -------------------------------
# 8) Intune
# -------------------------------
$FileName_DSREG = Join-Path $Path "DSReg_Status.csv"

# Run dsregcmd /status and capture output
$temp = Join-Path $env:TEMP "dsreg_output.txt"
Start-Process dsregcmd.exe -ArgumentList "/status" -WindowStyle Hidden -RedirectStandardOutput $temp -Wait

# Parse into Name/Value pairs
$Output = @()
$lines = Get-Content $temp
foreach ($line in $lines) {
    if ($line -match "^\s*([^:]+?)\s*:\s*(.*)$") {
        $name  = $Matches[1].Trim()
        $value = $Matches[2].Trim()
        if ($name -ne "") {
            $Output += [pscustomobject]@{
                Name  = $name
                Value = $value
            }
        }
    }
}

# Assign variables by EXACT key names
$AzureAdJoined      = ($Output | Where-Object Name -eq 'AzureAdJoined').Value
$TenantName         = ($Output | Where-Object Name -eq 'TenantName').Value
$TenantId           = ($Output | Where-Object Name -eq 'TenantId').Value
$DisplayNameUpdated = ($Output | Where-Object Name -eq 'DisplayNameUpdated').Value
$OsVersionUpdated   = ($Output | Where-Object Name -eq 'OsVersionUpdated').Value

# Export CSV (DSReg_Status.csv)
$Output | Export-Csv -Path $FileName_DSREG -NoTypeInformation -Encoding UTF8


# Intune Result (AzureAdJoined)
$IntuneResult = $true
$IntuneReason = @()

# Accept YES or TRUE only
if ($AzureAdJoined -notmatch "^(?i:yes|true)$") {
    $IntuneResult = $false
    $IntuneReason += "AzureAdJoined is not YES"
}

if ($IntuneReason.Count -eq 0) {
    $IntuneReason = "AzureAdJoined = YES"
} else {
    $IntuneReason = $IntuneReason -join "; "
}


Write-Host "Intune report exported to $FileName_DSREG"



# -------------------------------
# 9) SDP
# -------------------------------
Write-Host "⏳Generating SDP report" -ForegroundColor Green


# Base (your original) path for agent core values
$RegPathBase = 'HKLM:\SOFTWARE\WOW6432Node\AdventNet\DesktopCentral\DCAgent'

# Specific subkey for system details (as you requested)
$RegPathDetails = Join-Path $RegPathBase 'SystemDetails'

# Helper to safely read a single value (returns $null if missing)
function Get-RegValue {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Name
    )
    try {
        Get-ItemPropertyValue -Path $Path -Name $Name -ErrorAction SilentlyContinue
    } catch { $null }
}

# Helper: Convert epoch seconds or milliseconds to local date-time (kept from your original)
function Convert-Epoch {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    if (-not ($Value -match '^\d+$')) { return $null }
    try {
        if ($Value.Length -ge 13) {
            [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$Value).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
        } else {
            [DateTimeOffset]::FromUnixTimeSeconds([int64]$Value).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
        }
    } catch { $null }
}

# --- Read core agent values from the BASE key
$InstallPath           = Get-RegValue -Path $RegPathBase -Name 'DCAgentInstallDir'
$AgentName             = Get-RegValue -Path $RegPathBase -Name 'AgentServiceName'
$AgentVersion          = Get-RegValue -Path $RegPathBase -Name 'DCAgentVersion'
$LastContactTimeRaw    = Get-RegValue -Path $RegPathBase -Name 'LastContactTime'
$NextRefreshTimeRaw    = Get-RegValue -Path $RegPathBase -Name 'DCAgentNextRefreshTime'
$InstalledTimeRaw      = Get-RegValue -Path $RegPathBase -Name 'DCAgentInstalledTime'
$StartupTimeRaw        = Get-RegValue -Path $RegPathBase -Name 'StartupTime'
$LastBootUpTimeRaw     = Get-RegValue -Path $RegPathBase -Name 'LastBootUpTime'
$LastComputerCycleRaw  = Get-RegValue -Path $RegPathBase -Name 'LastComputerCycleTime'
$AgentSvcLastStartRaw  = Get-RegValue -Path $RegPathBase -Name 'AgentServiceLastStartTime'

# --- Read system detail values from the SystemDetails SUBKEY
$LocalMachineName      = Get-RegValue -Path $RegPathDetails -Name 'LocalMachineName'
$SystemSpecName        = Get-RegValue -Path $RegPathDetails -Name 'SystemSpecName'

# True when both are non-empty and equal; false otherwise (including null/empty)
$NameMismatch = (
    -not [string]::IsNullOrWhiteSpace($LocalMachineName) -and
    -not [string]::IsNullOrWhiteSpace($SystemSpecName) -and
    ($LocalMachineName -eq $SystemSpecName)
)

$result = [PSCustomObject]@{
    InstallPath              = $InstallPath
    AgentName                = $AgentName
    AgentVersion             = $AgentVersion
    LastContactTime          = Convert-Epoch ([string]$LastContactTimeRaw)
    NextRefreshTime          = Convert-Epoch ([string]$NextRefreshTimeRaw)
    InstalledTime            = Convert-Epoch ([string]$InstalledTimeRaw)
    StartupTime              = Convert-Epoch ([string]$StartupTimeRaw)
    LastBootUpTime           = Convert-Epoch ([string]$LastBootUpTimeRaw)
    LastComputerCycleTime    = Convert-Epoch ([string]$LastComputerCycleRaw)
    LocalMachineName         = $LocalMachineName
    SystemSpecName           = $SystemSpecName
    NameMismatch             = $NameMismatch
}

# Display nicely
#$result | Format-List

# Export to CSV (unchanged path)
$csv = 'C:\ReportCard\MDE\SDP.csv'
$result | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
Write-Host "SDP report exported to $csv"





# -------------------------------
# 10) Secure Boot Status
# -------------------------------

# Get Secure Boot State
try {
    $SecureBootState = if (Confirm-SecureBootUEFI) { "On" } else { "Off" }
} catch {
    $SecureBootState = "Unsupported"
}

# Get Secure Boot registry info
$SecureBootReg = Get-ItemProperty `
    -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing" `
    -ErrorAction SilentlyContinue

# Determine SecureBootResult based on conditions
$SecureBootResult = if (
    $SecureBootState -eq "On" -and
    $SecureBootReg.UEFICA2023Status -eq "Updated"
) {
    $true
} else {
    $false
}

# Create custom object
$Report = [PSCustomObject]@{
    SecureBootState    = $SecureBootState
    UEFICA2023Status   = $SecureBootReg.UEFICA2023Status
    SecureBootResult   = $SecureBootResult
}

# Export to CSV
$Report | Export-Csv -Path "$folderPath\SecureBoot.csv" -NoTypeInformation
Write-Host "Secure Boot report exported to $folderPath\SecureBoot.csv"







# -------------------------------
# 11) Compliance Status
# -------------------------------


# Initialize an array to store all failure comments

$CommentsList = @()

if (-not $ATPResult) {
    $CommentsList += "Check the installation of 0.2 MDATP"
}

if (-not $status) {
    $CommentsList += "Check the Bitlocker Encryption and Bitlocker Pin"
}

if (-not $coManagedValue) {
    $CommentsList += "Check SCCM installation and version"
}

if (-not $LapsResult) {
    $CommentsList += "Check Account Sync"
}

if (-not $IntuneResult) {
    $CommentsList += "Check AAD"
}

if (-not $MsDefenderStatus) {
    $CommentsList += "Check Microsoft Defender Endpoint"
}

if (-not $QualysStatus) {
    $CommentsList += "Check the installation of Qualys"
}

if (-not $sccmSuccess) {
    $CommentsList += "Check the SCCM log file and SCCM version"
}

if (-not $NameMismatch) {
    $CommentsList += "Check the installation of Manage Engine"
}

if (-not $SecureBootResult) {
    $CommentsList += "Check Secure Boot"
}






# --- Final Compliance Output ---
if ($CommentsList.Count -eq 0) {
    $ComplianceStatus = "<strong style='color:green;'>Compliance</strong>"
    $Comments = "No Action Required"
}
else {
    $ComplianceStatus = "<strong style='color:red;'>Not Compliance</strong>"
    $Comments = $CommentsList -join "; "
}





# TRUE or False Colour

function Get-ColorStatus($value) {
    if ($value -eq $true) {
        return "<strong style='color:green;'>True</strong>"
    }
    else {
        return "<strong style='color:red;'>False</strong>"
    }
}












###################################################################################



# Generate HTML report

$HtmlContent = @"

<html>
<head>
<style>
    body {
        font-family: 'Times New Roman', Arial, sans-serif;
        font-size: 22px;     /* Increased text size */
        font-weight: 600;    /* Makes text slightly bold */
        background: #f4f6f9;
        margin: 0;
        padding: 18px;
        color: #333333;
    }

    .report-container {
        background: white;
        padding: 18px;
        border-radius: 12px;
        box-shadow: 0 2px 10px rgba(0,0,0,0.1);
    }

    h2 {
        background: #00264d;
        color: white;
        padding: 14px;       /* bigger padding = bigger look */
        font-size: 28px;     /* bigger title */
        border-radius: 6px;
        margin-top: 0;
    }

    h3 {
        background: #003366;
        color: white;
        padding: 10px;
        font-size: 24px;     /* bigger subtitle */
        border-radius: 6px;
        margin-top: 25px;
    }

    h4 {
        color: #00264d;
        font-size: 22px;     /* bigger section header */
        border-left: 4px solid #001a33;
        padding-left: 8px;
        margin-top: 20px;
    }

    table {
        width: 100%;
        border-collapse: collapse;
        margin-top: 12px;

        border-radius: 6px;
        overflow: hidden;

        border: 3px solid #FFFFFF;
        background: white;
    }

    th {
        background-color: #2E5C99;
        color: white;
        padding: 10px;         /* bigger table header text spacing */
        font-size: 20px;       /* bigger table header text */
        text-align: left;

        border: 3px solid #FFFFFF;
    }

    td {
        background-color: #FFFFFF;
        padding: 8px;         /* bigger cell padding */
        font-size: 20px;       /* bigger table data text */

        border: 3px solid #FFFFFF;
    }

    tr:nth-child(even) td {
        background-color: #f5f8ff;
    }

    .footer-note {
        margin-top: 25px;
        font-size: 16px;        /* slightly bigger footer */
        color: #777;
        text-align: center;
    }
</style>
</head>

<body>






<h2>System Details for $($ComputerInfo.ComputerName)</h2>


<h3>Computer Details</h3>
<table>
<tr>
    <th>ComputerName</th>
    <th>Model</th>
    <th>SerialNumber</th>
    <th>OSEdition</th>
    <th>OperatingSystem</th>
    <th>OSVersion</th>
</tr>
<tr>
    <td>$($ComputerInfo.ComputerName)</td>
    <td>$($ComputerInfo.Model)</td>
    <td>$($ComputerInfo.SerialNumber)</td>
    <td>$($ComputerInfo.OSEdition)</td>
    <td>$($ComputerInfo.OperatingSystem)</td>
    <td>$($ComputerInfo.OSVersion)</td>
</tr>
</table>



<!-- Summarize Details -->
<h3>Summarize Details</h3>
<table>
<tr>
    <th>ApplicationName</th>
    <th>Version</th>
    <th>Status</th>
</tr>
<tr><td>ATP</td><td>$($ATPStatus.ConfigurationVersion)</td><td>$(Get-ColorStatus $ATPResult)</td></tr>
<tr><td>Bitlocker</td><td>$($encMethod)</td><td>$(Get-ColorStatus $status)</td></tr>
<tr><td>CO-Management</td><td></td><td>$(Get-ColorStatus $coManagedValue)</td></tr>
<tr><td>Laps</td><td></td><td>$(Get-ColorStatus $LapsResult)</td></tr>
<tr><td>Intune</td><td>$($TenantId)</td><td>$(Get-ColorStatus $IntuneResult)</td></tr>
<tr><td>MDE</td><td>$($DefenderInfo.AntispywareSignatureVersion)</td><td>$(Get-ColorStatus $MsDefenderStatus)</td></tr>
<tr><td>Qualys</td><td>$($ActivationID)</td><td>$(Get-ColorStatus $QualysStatus)</td></tr>
<tr><td>SCCM</td><td>$($clientVersionValue)</td><td>$(Get-ColorStatus $sccmSuccess)</td></tr>
<tr><td>SDP</td><td>$($AgentVersion)</td><td>$(Get-ColorStatus $NameMismatch)</td></tr>
<tr><td>Secure Boot</td><td></td><td>$(Get-ColorStatus $SecureBootResult)</td></tr>
</table>


<!-- Bitlocker Status -->
<h3>Bitlocker Status</h3>
<table>
<tr>
    <th>Drive</th><th>ProtectionStatus</th><th>EncryptionPercentage</th><th>EncryptionMethod</th><th>KeyProtectorMethods</th><th>Status</th>
</tr>
<tr>
    <td>$($mount)</td>
    <td>$($protStatus)</td>
    <td>$($percent)</td>
    <td>$($encMethod)</td>
    <td>$($kpMethods)</td>
    <td>$($statusNote)</td>
</tr>
</table>



<!-- SCCM Status -->
<h3>SCCM Status</h3>
<table>
<tr>
    <th>ClientVersion</th><th>LatestTimestamp</th><th>SCCM Status</th>
</tr>
<tr>
    <td>$($clientVersionValue)</td>
    <td>$($messageTimeValue)</td>
    <td>$($sccmStatus)</td>
</tr>
</table>



<!-- SDP Status -->
<h3>SDP Status</h3>
<table>
<tr>
    <th>AgentName</th><th>AgentVersion</th><th>InstalledTime</th><th>InstalledPath</th><th>LastSyncTime</th><th>MachineName</th><th>SDPName</th>
</tr>
<tr>
    <td>$($AgentName)</td>
    <td>$($AgentVersion)</td>
    <td>$(Convert-Epoch ([string]$InstalledTimeRaw))</td>
    <td>$($InstallPath)</td>
    <td>$(Convert-Epoch ([string]$LastComputerCycleRaw))</td>
    <td>$($LocalMachineName)</td>
    <td>$($SystemSpecName)</td>
</tr>
</table>




<!-- Secure Boot Status -->
<h3>Secure Boot Status</h3>
<table>
<tr>
    <th>Secure Boot</th><th>UEFICA2023Status</th>
</tr>
<tr>
    <td>$($SecureBootState)</td>
    <td>$($SecureBootReg.UEFICA2023Status)</td>

</tr>
</table>










<!-- Laps -->
<h3>LAPS Details</h3>
<table>
<tr>
    <th>Laps Info</th><th>Source</th><th>Policies</th>
</tr>
<tr>
    <td>LAPS State</td>
    <td>$($Source1)</td>
    <td>$($Names1)</td>
</tr>
<tr>
    <td>LAPS Policies</td>
    <td>$($Source2)</td>
    <td>$($Names2)</td>
</tr>
</table>

<!-- Intune -->
<h3>Intune Details</h3>
<table>
<tr>
    <th>Identifier</th><th>Status</th>
</tr>
<tr>
    <td>AzureAdJoined</td>
    <td>$($AzureAdJoined)</td>
</tr>
<tr>
    <td>TenantName</td>
    <td>$($TenantName)</td>
</tr>
<tr>
    <td>TenantId</td>
    <td>$($TenantId)</td>
</tr>
<tr>
    <td>DisplayNameUpdated</td>
    <td>$($DisplayNameUpdated)</td>
</tr>
<tr>
    <td>OsVersionUpdated</td>
    <td>$($OsVersionUpdated)</td>
</tr>
</table>


<!-- MD ATP -->
<h3>MD ATP Details</h3>
<table>
<tr>
    <th>ConfigurationVersion</th><th>OrdId</th><th>OnboardingState</th><th>PSPath</th>
</tr>
<tr>
    <td>$($ATPStatus.ConfigurationVersion)</td>
    <td>$($ATPStatus.OrgId)</td>
    <td>$($ATPStatus.OnboardingState)</td>
    <td>$($ATPStatus.PSPath)</td>
</tr>
</table>


<!-- MS Defender Status -->
<h3>MS Defender Status</h3>
<table>
<tr>
    <th>ComputerID</th>
    <th>AMEngineVersion</th>
    <th>AMProductVersion</th>
    <th>AMServiceVersion</th>
    <th>AMServiceEnabled</th>
</tr>
<tr>
    <td>$($DefenderInfo.ComputerID)</td>
    <td>$($DefenderInfo.AMEngineVersion)</td>
    <td>$($DefenderInfo.AMProductVersion)</td>
    <td>$($DefenderInfo.AMServiceVersion)</td>
    <td>$($DefenderInfo.AMServiceEnabled)</td>
</tr>
</table>

<table>
<tr>
    <th>AntispywareSignatureVersion</th>
    <th>AntispywareSignatureLastUpdated</th>
    <th>AntispywareEnabled</th>
    <th>AntivirusSignatureVersion</th>
    <th>AntivirusSignatureLastUpdated</th>
    <th>AntivirusEnabled</th>
</tr>
<tr>
    <td>$($DefenderInfo.AntispywareSignatureVersion)</td>
    <td>$($DefenderInfo.AntispywareSignatureLastUpdated)</td>
    <td>$($DefenderInfo.AntispywareEnabled)</td>
    <td>$($DefenderInfo.AntivirusSignatureVersion)</td>
    <td>$($DefenderInfo.AntivirusSignatureLastUpdated)</td>
    <td>$($DefenderInfo.AntivirusEnabled)</td>
</tr>
</table>

<table>
<tr>
    <th>BehaviorMonitorEnabled</th>
    <th>FullScanAge</th>
    <th>FullScanSignatureVersion</th>
    <th>FullScanStartTime</th>
    <th>FullScanEndTime</th>
    <th>IoavProtectionEnabled</th>
    <th>IsTamperProtected</th>
</tr>
<tr>
    <td>$($DefenderInfo.BehaviorMonitorEnabled)</td>
    <td>$($DefenderInfo.FullScanAge)</td>
    <td>$($DefenderInfo.FullScanSignatureVersion)</td>
    <td>$($DefenderInfo.FullScanStartTime)</td>
    <td>$($DefenderInfo.FullScanEndTime)</td>
    <td>$($DefenderInfo.IoavProtectionEnabled)</td>
    <td>$($DefenderInfo.IsTamperProtected)</td>
</tr>
</table>

<table>
<tr>
    <th>NISEngineVersion</th>
    <th>NISSignatureLastUpdated</th>
    <th>NISSignatureVersion</th>
    <th>NISEnabled</th>
    <th>OnAccessProtectionEnabled</th>
    <th>RealTimeProtectionEnabled</th>
</tr>
<tr>
    <td>$($DefenderInfo.NISEngineVersion)</td>
    <td>$($DefenderInfo.NISSignatureLastUpdated)</td>
    <td>$($DefenderInfo.NISSignatureVersion)</td>
    <td>$($DefenderInfo.NISEnabled)</td>
    <td>$($DefenderInfo.OnAccessProtectionEnabled)</td>
    <td>$($DefenderInfo.RealTimeProtectionEnabled)</td>
</tr>
</table>



<!-- Qualys Status -->
<h3>Qualys Status</h3>
<table>
<tr>
    <th>ActivationID</th><th>CustomerID</th><th>AgentInstallPath</th>
</tr>
<tr>
    <td>$($ActivationID)</td>
    <td>$($CustomerID)</td>
    <td>$($AgentInstallPath)</td>
</tr>
</table>

</body>
</html>
"@
# Save HTML report
$HtmlContent | Out-File -FilePath $HtmlFile -Encoding UTF8

#######################################################################################
Write-Host "⏳Getting Installed Software" -ForegroundColor Green


# ===========================
# Installed Software (A → Z)
# ===========================

# Use the same HTML file path
$htmlPath = "$HtmlFile"

# Get installed software using Win32_Product, remove blank names, and sort by Name (A-Z)
$software = Get-CimInstance -ClassName Win32_Product |
Where-Object { $_.Name -and $_.Name.Trim() -ne "" } |
Select-Object @{Name='Name';Expression={$_.Name}},
              @{Name='Version';Expression={$_.Version}},
              @{Name='InstallDate';Expression={$_.InstallDate}},
              @{Name='Vendor';Expression={$_.Vendor}},
              @{Name='InstallLocation';Expression={$_.InstallLocation}} |
Sort-Object Name

# Build HTML rows dynamically
$rowsSW = foreach ($app in $software) {
    $name    = if ($app.Name)             { $app.Name }             else { '-' }
    $version = if ($app.Version)          { $app.Version }          else { '-' }
    $dateRaw = if ($app.InstallDate)      { $app.InstallDate }      else { '-' }
    $vendor  = if ($app.Vendor)           { $app.Vendor }           else { '-' }
    $path    = if ($app.InstallLocation)  { $app.InstallLocation }  else { '-' }

    # If InstallDate looks like yyyymmdd, format to yyyy-MM-dd; otherwise leave as-is
    $installDate =
        if ($dateRaw -is [string] -and $dateRaw -match '^\d{8}$') {
            try {
                [datetime]::ParseExact($dateRaw, 'yyyyMMdd', $null).ToString('yyyy-MM-dd')
            } catch { $dateRaw }
        } else { $dateRaw }

    "<tr><td>$name</td><td>$version</td><td>$installDate</td><td>$vendor</td><td>$path</td></tr>"
}

# Build the Installed Software table HTML block
$softwareTable = @"
<h3>Installed Software</h3>
<table>
<tr>
<th>Name</th><th>Version</th><th>Install Date</th><th>Vendor</th><th>Install Location</th>
</tr>
$($rowsSW -join "`n")
</table>
"@

# Insert the Installed Software table BEFORE </body>
$htmlContent = Get-Content $htmlPath -Raw
$htmlContent = $htmlContent -replace '</body>', "$softwareTable`n</body>"
$htmlContent | Out-File -FilePath $htmlPath -Encoding UTF8


#######################################################################################
Write-Host "⏳Getting Installed Patches" -ForegroundColor Green
# -------------------------------
#Installed Patches
# -------------------------------
# Path to existing HTML file
$htmlPath = "$HtmlFile"

# Get all hotfix details and sort by InstalledOn (oldest first)
$hotfixes = Get-CimInstance -ClassName Win32_QuickFixEngineering |
Sort-Object InstalledOn

# Build HTML rows dynamically
$rows = foreach ($hf in $hotfixes) {
    $description = $hf.Description
    $hotfixID    = $hf.HotFixID
    $installedBy = $hf.InstalledBy
    $installedOn = $hf.InstalledOn

    "<tr><td>$hotfixID</td><td>$description</td><td>$installedOn</td><td>$installedBy</td></tr>"
}

# Build the hotfix table HTML block
$hotfixTable = @"
<h3>Installed Patches</h3>
<table>
<tr>
<th>HotFixID</th><th>Description</th><th>InstalledOn</th><th>InstalledBy</th>
</tr>

$($rows -join "`n")
</table>
<h4>Prepare by: $PicName</h4>
<h4>PIC: $PicName1</h4>
<h4>Prepare on: $ReportDateTime</h4>
"@

# Insert the table before </body> in the existing HTML
$htmlContent = Get-Content $htmlPath -Raw
$htmlContent = $htmlContent -replace '</body>', "$hotfixTable`n</body>"


# Save updated HTML
$htmlContent | Out-File -FilePath $htmlPath -Encoding UTF8
Write-Host "✅ HTML report generated: $HtmlFile" -ForegroundColor Green

Write-Host "📧 Sending email " -ForegroundColor yellow


#Remove files
Remove-Item -Path "C:\ReportCard\MDE\*.CSV"
Remove-Item -Path "C:\ReportCard\MDE\*.TXT"
Remove-Item -Path "C:\ReportCard\MDE\*.PDF"
Remove-Item -Path "C:\ReportCard\MDE\*.PDF"
Remove-Item -Path "C:\ReportCard\MDE\*.PS1"
Remove-Item -Path "C:\ReportCard\MDE\*.BAT"







######################################################################################
# ============== EMAIL: body uses $HtmlContent + attach $HtmlFile ====================
######################################################################################

# --- Required inputs (your environment) ---
# CONFIGURE ME: replace with your own internal SMTP relay and mailboxes
$SmtpServer = 'smtp.yourdomain.com'
$From       = 'reportcard@yourdomain.com'
$To         = 'helpdesk@yourdomain.com'
$Port       = 25

# Ensure we have a machine name for subject (fallbacks)
if (-not $machineName -or [string]::IsNullOrWhiteSpace($machineName)) {
    $machineName = if ($ComputerInfo -and $ComputerInfo.ComputerName) { 
        $ComputerInfo.ComputerName 
    } else { 
        $env:COMPUTERNAME 
    }
}

# If $stamp is not initialized earlier, create a default (not used for attachment now)
if (-not $stamp) { $stamp = Get-Date -Format 'yyyyMMdd-HHmmss' }

# Folder and attachment HTML
if (-not $FolderPath -or [string]::IsNullOrWhiteSpace($FolderPath)) {
    $FolderPath = 'C:\ReportCard\MDE\InDeploymentReport'
}
$HtmlFile = Join-Path $FolderPath 'MachineReport.html'

# Subject
$subject = "[{0}] Summary & Compliance - {1}" -f $machineName, (Get-Date -Format 'dd-MM-yyyy')

# ===================== EMAIL BODY: your $HtmlContent =====================
# (Use your existing $ComputerInfo, $ATPStatus, etc. variables)
$HtmlContent = @"

<html>
<head>
<style>
    body {
        font-family: 'Times New Roman', Arial, sans-serif;
        font-size: 22px;     /* Increased text size */
        font-weight: 600;    /* Makes text slightly bold */
        background: #f4f6f9;
        margin: 0;
        padding: 18px;
        color: #333333;
    }

    .report-container {
        background: white;
        padding: 18px;
        border-radius: 12px;
        box-shadow: 0 2px 10px rgba(0,0,0,0.1);
    }

    h2 {
        background: #00264d;
        color: white;
        padding: 14px;       /* bigger padding = bigger look */
        font-size: 28px;     /* bigger title */
        border-radius: 6px;
        margin-top: 0;
    }

    h3 {
        background: #003366;
        color: white;
        padding: 10px;
        font-size: 24px;     /* bigger subtitle */
        border-radius: 6px;
        margin-top: 25px;
    }

    h4 {
        color: #00264d;
        font-size: 22px;     /* bigger section header */
        border-left: 4px solid #001a33;
        padding-left: 8px;
        margin-top: 20px;
    }

    table {
        width: 100%;
        border-collapse: collapse;
        margin-top: 12px;

        border-radius: 6px;
        overflow: hidden;

        border: 3px solid #FFFFFF;
        background: white;
    }

    th {
        background-color: #2E5C99;
        color: white;
        padding: 10px;         /* bigger table header text spacing */
        font-size: 20px;       /* bigger table header text */
        text-align: left;

        border: 3px solid #FFFFFF;
    }

    td {
        background-color: #FFFFFF;
        padding: 8px;         /* bigger cell padding */
        font-size: 20px;       /* bigger table data text */

        border: 3px solid #FFFFFF;
    }

    tr:nth-child(even) td {
        background-color: #f5f8ff;
    }

    .footer-note {
        margin-top: 25px;
        font-size: 16px;        /* slightly bigger footer */
        color: #777;
        text-align: center;
    }
</style>
</head>

<body>






<h2>System Details for $($ComputerInfo.ComputerName)</h2>


<h3>Computer Details</h3>
<table>
<tr>
    <th>ComputerName</th>
    <th>Model</th>
    <th>SerialNumber</th>
    <th>OSEdition</th>
    <th>OperatingSystem</th>
    <th>OSVersion</th>
</tr>
<tr>
    <td>$($ComputerInfo.ComputerName)</td>
    <td>$($ComputerInfo.Model)</td>
    <td>$($ComputerInfo.SerialNumber)</td>
    <td>$($ComputerInfo.OSEdition)</td>
    <td>$($ComputerInfo.OperatingSystem)</td>
    <td>$($ComputerInfo.OSVersion)</td>
</tr>
</table>

<h4>Status: $($ComplianceStatus)</h4>
<h4>Comments: $($Comments) </h4>

</body>
</html>
"@

# (Optional) If you want the email body to be EXACTLY MachineReport.html:
# if (Test-Path $HtmlFile) { $HtmlContent = Get-Content -Raw -Path $HtmlFile }

# Defensive: only attach if it exists
$attachments = @()
if (Test-Path $HtmlFile) {
    $attachments += $HtmlFile
} else {
    Write-Warning "Attachment not found: $HtmlFile (email will be sent without attachment)"
}

#####################################################
# -------- Send the email (no credentials) ---------
#####################################################

$mailParams = @{
    From       = $From
    To         = $To
    Subject    = $subject
    SmtpServer = $SmtpServer
    Port       = $Port
    Body       = $HtmlContent
    BodyAsHtml = $true
    Priority   = 'High'
    Encoding   = 'UTF8'
}
if ($attachments.Count -gt 0) {
    $mailParams['Attachments'] = $attachments
}

try {
    Send-MailMessage @mailParams
    if ($attachments.Count -gt 0) {
        Write-Host ("Email sent to {0} with attachment: {1}" -f $To, $HtmlFile) -ForegroundColor Green
    } else {
        Write-Host "Email sent to $To (no attachment)" -ForegroundColor Yellow
    }
}
catch {
    Write-Warning "Failed to send email: $($_.Exception.Message)"
}
