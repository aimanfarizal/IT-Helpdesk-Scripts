<#
====================================================================================
 Machine Report Card - AUTOPILOT / INTUNE-ONLY (cloud-native) VERSION
====================================================================================
 Adapted from the MDT + Hybrid AD + SCCM report card script.

 WHAT CHANGED FROM THE MDT/HYBRID VERSION:
   REMOVED  - Co-Management / SCCM section (root\ccm\invagt, ccmsetup.log). These
              only apply if a ConfigMgr client is installed for hybrid co-management.
              A pure Autopilot + Intune device normally has no ConfigMgr client at all,
              so this section always reported empty/false and added no value.
   CHANGED  - "Intune" section no longer just trusts dsregcmd's AzureAdJoined flag.
              It now checks three things together:
                1) AzureAdJoined = YES   (device has an Entra ID identity)
                2) DomainJoined  = NO    (confirms it's cloud-native, not hybrid)
                3) An actual MDM enrollment record exists in the registry with
                   ProviderID "MS DM Server" (confirms Intune enrollment actually
                   completed, not just that the device is Entra-joined)
   CHANGED  - LAPS now checks the BackupDirectory registry value instead of just
              key existence. On Autopilot devices this should be 1 (passwords
              backed up to Microsoft Entra ID). A value of 2 means it's still
              configured for on-prem AD, which won't work post-Autopilot.
   KEPT     - Everything else (MDATP/Defender onboarding, BitLocker, Defender AV
              status, Secure Boot, Qualys, installed software/patches, email) is
              OS/agent-level state that has nothing to do with domain join type,
              so it is unchanged.
   OPTIONAL - The ManageEngine Desktop Central ("SDP") section is left in but
              clearly marked optional - remove it if you're retiring that tool
              alongside SCCM/MDT. It's independent of AD either way.

 BEFORE USING THIS SCRIPT:
 Search for "CONFIGURE ME" below and set the local staging folder for your
 own environment. This test build has no email/SMTP step - it just writes
 MachineReport.html (and the intermediate CSVs) to that folder for review.

 NOTE: Autopilot deployment profile status, Enrollment Status Page (ESP) history,
 and Intune compliance policy state are NOT reliably readable from local registry
 keys - Microsoft doesn't publish stable local artifacts for those. If you need
 them on the report card, pull them from Microsoft Graph (deviceManagement API)
 using an app registration, rather than scraping local state. Ask if you want a
 Graph-based add-on script for that piece.
====================================================================================
#>

# Ensure the folder exists
# CONFIGURE ME: local folder used to stage report files before the HTML is built
$FolderPath = "C:\ReportCard\MDE"
If (!(Test-Path -Path $FolderPath)) {
    New-Item -ItemType Directory -Path $FolderPath -Force
}

# Define output file paths
$CsvFile  = "$FolderPath\ComputerDetails.csv"
$HtmlFile = "$FolderPath\MachineReport.html"


#####Request PIC for Report Card
Write-Host "👤 Please enter the PIC name (HELPDESK STAFF) for this laptop" -ForegroundColor Cyan
$PicName1 = Read-Host

Write-Host "👤 Please enter the PIC name (INTERN) for this report card" -ForegroundColor Green
$PicName = Read-Host

# Get current date & time (local system time)
$NowLocal = Get-Date
$ReportDateTime = $NowLocal.ToString("yyyy-MM-dd HH:mm:ss")

# HTML-escape values
$PicName        = [System.Security.SecurityElement]::Escape($PicName)
$PicName1       = [System.Security.SecurityElement]::Escape($PicName1)
$ReportDateTime = [System.Security.SecurityElement]::Escape($ReportDateTime)


# -------------------------------
# 1) Get Computer Details
# -------------------------------
$ComputerSystem = Get-CimInstance Win32_ComputerSystem
$BIOS           = Get-CimInstance Win32_BIOS
$OS             = Get-CimInstance Win32_OperatingSystem

$BuildNumber = [int]$OS.BuildNumber
$OSRelease = switch ($BuildNumber) {
    {$_ -ge 26200} {"Windows 11 25H2"; break}
    {$_ -ge 26100} {"Windows 11 24H2"; break}
    {$_ -ge 22631} {"Windows 11 23H2"; break}
    default {"Unknown Operating System"}
}

$ComputerInfo = @{
    ComputerName    = $ComputerSystem.Name
    Model           = $ComputerSystem.Model
    SerialNumber    = $BIOS.SerialNumber
    OSEdition       = $OS.Caption
    OperatingSystem = $OSRelease
    OSVersion       = $OS.Version
}

$ComputerObject = New-Object PSObject -Property $ComputerInfo
$ComputerObject | Export-Csv -Path $CsvFile -NoTypeInformation
Write-Host "Computer Details report exported to $CsvFile"


# --------------------------------------------------------------
# 2) Microsoft Defender for Endpoint (MDATP) Onboarding via Registry
# --------------------------------------------------------------
$ATPStatus = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status" -ErrorAction SilentlyContinue

$ATPResult = if (-not [string]::IsNullOrEmpty($ATPStatus.OrgId) -and $ATPStatus.OnboardingState -eq 1) {
    $true
} else {
    $false
}

$Report = [PSCustomObject]@{
    ConfigurationVersion = $ATPStatus.ConfigurationVersion
    OrgId                = $ATPStatus.OrgId
    OnboardingState      = $ATPStatus.OnboardingState
    PSPath               = $ATPStatus.PSPath
    ATPResult            = $ATPResult
}
$Report | Export-Csv -Path "$FolderPath\ATP.csv" -NoTypeInformation
Write-Host "ATP report exported to $FolderPath\ATP.csv"


# -------------------------------
# 3) BitLocker
# -------------------------------
$OutFile = Join-Path $FolderPath 'bitlocker.csv'
$mount = 'C:'

$blv = Get-BitLockerVolume -MountPoint $mount

$mbdeStatus = (manage-bde -status $mount) -join [environment]::NewLine
$version = ($mbdeStatus -split "`r?`n" | Where-Object { $_ -match 'BitLocker Version\s*:\s*(.+)$' } |
    ForEach-Object { ($_.Trim() -replace '.*:\s*','').Trim() } | Select-Object -First 1)

$kpMethods = ($blv.KeyProtector |
    Select-Object -ExpandProperty KeyProtectorType |
    Sort-Object -Unique) -join '; '

$percent =
    if ($blv.PSObject.Properties.Name -contains 'EncryptionPercentage') { [int]$blv.EncryptionPercentage }
    elseif ($blv.PSObject.Properties.Name -contains 'PercentageEncrypted') { [int]$blv.PercentageEncrypted }
    else { $null }

$sizeGB =
    if ($blv.PSObject.Properties.Name -contains 'CapacityGB') { [math]::Round([double]$blv.CapacityGB, 2) }
    else { $null }

$protStatus =
    switch ($blv.ProtectionStatus) {
        0 { 'Off' }
        1 { 'On' }
        2 { 'Unknown' }
        default { [string]$blv.ProtectionStatus }
    }

$encMethod = [string]$blv.EncryptionMethod

$expectedKP = @('RecoveryPassword','TpmPin')

$kpList = @()
if ($kpMethods) {
    $kpList = ($kpMethods -split ';\s*' | ForEach-Object { $_.Trim() }) | Where-Object { $_ }
}

$protOK    = ($protStatus -eq 'On')
$missingKP = $expectedKP | Where-Object { $kpList -notcontains $_ }

$status = $protOK -and ($missingKP.Count -eq 0)

$issues = @()
if (-not $protOK)          { $issues += 'ProtectionStatus is not On' }
if ($missingKP.Count -gt 0){ $issues += 'Missing KeyProtector(s): ' + ($missingKP -join ', ') }

$statusNote = if ($issues.Count) { $issues -join '; ' } else { 'Recovery Password and Pin exist' }

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
$row | Export-Csv -Path $OutFile -NoTypeInformation -Encoding UTF8
Write-Host "BitLocker details exported to: $OutFile"


# --------------------------------------------------------------
# 4) Entra ID Join & Intune MDM Enrollment (replaces Co-Mgmt/SCCM)
# --------------------------------------------------------------
Write-Host "⏳ Checking Entra ID join and Intune enrollment" -ForegroundColor Green

$DsRegFile = Join-Path $FolderPath "DSReg_Status.csv"

# Run dsregcmd /status and capture output
$temp = Join-Path $env:TEMP "dsreg_output.txt"
Start-Process dsregcmd.exe -ArgumentList "/status" -WindowStyle Hidden -RedirectStandardOutput $temp -Wait

# Parse into Name/Value pairs
$DsRegOutput = @()
$lines = Get-Content $temp
foreach ($line in $lines) {
    if ($line -match "^\s*([^:]+?)\s*:\s*(.*)$") {
        $name  = $Matches[1].Trim()
        $value = $Matches[2].Trim()
        if ($name -ne "") {
            $DsRegOutput += [pscustomobject]@{
                Name  = $name
                Value = $value
            }
        }
    }
}

# Pull out the fields we care about
$AzureAdJoined      = ($DsRegOutput | Where-Object Name -eq 'AzureAdJoined').Value
$DomainJoined        = ($DsRegOutput | Where-Object Name -eq 'DomainJoined').Value
$EnterpriseJoined    = ($DsRegOutput | Where-Object Name -eq 'EnterpriseJoined').Value
$TenantName          = ($DsRegOutput | Where-Object Name -eq 'TenantName').Value
$TenantId            = ($DsRegOutput | Where-Object Name -eq 'TenantId').Value
$MdmUrl              = ($DsRegOutput | Where-Object Name -eq 'MdmUrl').Value
$DisplayNameUpdated  = ($DsRegOutput | Where-Object Name -eq 'DisplayNameUpdated').Value
$OsVersionUpdated    = ($DsRegOutput | Where-Object Name -eq 'OsVersionUpdated').Value

$DsRegOutput | Export-Csv -Path $DsRegFile -NoTypeInformation -Encoding UTF8

# Work out the join type in plain language
$JoinType =
    if ($AzureAdJoined -match '^(?i:yes)$' -and $DomainJoined -match '^(?i:yes)$') { "Hybrid Entra Joined" }
    elseif ($AzureAdJoined -match '^(?i:yes)$' -and $DomainJoined -notmatch '^(?i:yes)$') { "Microsoft Entra Joined (Autopilot)" }
    elseif ($EnterpriseJoined -match '^(?i:yes)$') { "Entra Registered (BYOD)" }
    else { "Not Joined" }

# Actual Intune MDM enrollment - confirm a real enrollment record exists,
# not just that the device has an Entra ID identity
$EnrollmentsPath = "HKLM:\SOFTWARE\Microsoft\Enrollments"
$MDMEnrollment = $null
if (Test-Path $EnrollmentsPath) {
    $MDMEnrollment = Get-ChildItem -Path $EnrollmentsPath -ErrorAction SilentlyContinue | ForEach-Object {
        Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
    } | Where-Object { $_.ProviderID -eq "MS DM Server" } | Select-Object -First 1
}
$IntuneMDMEnrolled = [bool]$MDMEnrollment

# Combined Intune/Autopilot result
$IntuneResult = $true
$IntuneReason = @()

if ($AzureAdJoined -notmatch '^(?i:yes)$') {
    $IntuneResult = $false
    $IntuneReason += "AzureAdJoined is not YES"
}
if ($DomainJoined -match '^(?i:yes)$') {
    $IntuneResult = $false
    $IntuneReason += "Device is still DomainJoined (expected NO for Autopilot)"
}
if (-not $IntuneMDMEnrolled) {
    $IntuneResult = $false
    $IntuneReason += "No Intune (MS DM Server) enrollment record found"
}

$IntuneReason = if ($IntuneReason.Count -eq 0) { "Microsoft Entra Joined and Intune enrolled" } else { $IntuneReason -join "; " }

Write-Host "Entra ID / Intune report exported to $DsRegFile"


# -------------------------------
# 5) Windows LAPS
# -------------------------------
$FileName_LAPS = Join-Path $FolderPath "LAPS.csv"
$LapsOutput = @()

$LapsPolicyPath = "HKLM:\SOFTWARE\Microsoft\Policies\LAPS"
$BackupDirectory = $null
if (Test-Path $LapsPolicyPath) {
    $BackupDirectory = (Get-ItemProperty -Path $LapsPolicyPath -Name "BackupDirectory" -ErrorAction SilentlyContinue).BackupDirectory
}

$BackupTarget = switch ($BackupDirectory) {
    1       { "Microsoft Entra ID" }
    2       { "Active Directory (legacy - not valid post-Autopilot)" }
    0       { "Disabled" }
    default { "Not Configured" }
}

$LapsOutput += [pscustomobject]@{
    Setting = "BackupDirectory"
    Value   = $BackupDirectory
    Target  = $BackupTarget
}

$LapsResult = ($BackupDirectory -eq 1)
$LapsReason = if ($LapsResult) { "Passwords backed up to Microsoft Entra ID" } else { "BackupDirectory is not set to 1 (Entra ID)" }

$LapsOutput | Export-Csv -Path $FileName_LAPS -NoTypeInformation -Encoding UTF8
Write-Host "LAPS report exported to $FileName_LAPS"


# --------------------------------------------------------------
# 6) Windows Defender for Endpoint - Antivirus/Real-time status
# --------------------------------------------------------------
Write-Host "🛡️ Triggering Windows Defender Full Scan..." -ForegroundColor Yellow
Start-Process "powershell.exe" -ArgumentList '-NoProfile -WindowStyle Hidden -Command "Start-MpScan -ScanType FullScan"' -WindowStyle Hidden

$DefenderInfo = Get-CimInstance -Namespace root/Microsoft/Windows/Defender -ClassName MSFT_MpComputerStatus

$MsDefenderStatus = ($DefenderInfo.AMServiceEnabled -and
                     $DefenderInfo.AntispywareEnabled -and
                     $DefenderInfo.BehaviorMonitorEnabled -and
                     $DefenderInfo.IoavProtectionEnabled -and
                     $DefenderInfo.IsTamperProtected -and
                     $DefenderInfo.NISEnabled -and
                     $DefenderInfo.OnAccessProtectionEnabled -and
                     $DefenderInfo.RealTimeProtectionEnabled)

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


# -------------------------------
# 7) Qualys Onboarding Status
# -------------------------------
$QualysInfo = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Qualys' -ErrorAction SilentlyContinue

$ActivationID     = $QualysInfo.ActivationID
$CustomerID       = $QualysInfo.CustomerID
$AgentInstallPath = $QualysInfo.AgentInstallPath

$QualysStatus = [bool]($ActivationID -and $CustomerID -and $AgentInstallPath)
Write-Host "Qualys status checked"


# --------------------------------------------------------------------------
# 8) [OPTIONAL] ManageEngine Desktop Central ("SDP") - remove if not in use
#    This is independent of AD/Entra either way; keep only if you still run it
# --------------------------------------------------------------------------
$RegPathBase    = 'HKLM:\SOFTWARE\WOW6432Node\AdventNet\DesktopCentral\DCAgent'
$RegPathDetails = Join-Path $RegPathBase 'SystemDetails'

function Get-RegValue {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Name
    )
    try {
        Get-ItemPropertyValue -Path $Path -Name $Name -ErrorAction SilentlyContinue
    } catch { $null }
}

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

$InstallPath          = Get-RegValue -Path $RegPathBase -Name 'DCAgentInstallDir'
$AgentName            = Get-RegValue -Path $RegPathBase -Name 'AgentServiceName'
$AgentVersion         = Get-RegValue -Path $RegPathBase -Name 'DCAgentVersion'
$InstalledTimeRaw     = Get-RegValue -Path $RegPathBase -Name 'DCAgentInstalledTime'
$LastComputerCycleRaw = Get-RegValue -Path $RegPathBase -Name 'LastComputerCycleTime'

$LocalMachineName = Get-RegValue -Path $RegPathDetails -Name 'LocalMachineName'
$SystemSpecName   = Get-RegValue -Path $RegPathDetails -Name 'SystemSpecName'

$NameMismatch = (
    -not [string]::IsNullOrWhiteSpace($LocalMachineName) -and
    -not [string]::IsNullOrWhiteSpace($SystemSpecName) -and
    ($LocalMachineName -eq $SystemSpecName)
)

$sdpResult = [PSCustomObject]@{
    InstallPath           = $InstallPath
    AgentName             = $AgentName
    AgentVersion          = $AgentVersion
    InstalledTime         = Convert-Epoch ([string]$InstalledTimeRaw)
    LastComputerCycleTime = Convert-Epoch ([string]$LastComputerCycleRaw)
    LocalMachineName      = $LocalMachineName
    SystemSpecName        = $SystemSpecName
    NameMismatch          = $NameMismatch
}
$csv = Join-Path $FolderPath 'SDP.csv'
$sdpResult | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
Write-Host "SDP report exported to $csv"


# -------------------------------
# 9) Secure Boot Status
# -------------------------------
try {
    $SecureBootState = if (Confirm-SecureBootUEFI) { "On" } else { "Off" }
} catch {
    $SecureBootState = "Unsupported"
}

$SecureBootReg = Get-ItemProperty `
    -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing" `
    -ErrorAction SilentlyContinue

$SecureBootResult = if (
    $SecureBootState -eq "On" -and
    $SecureBootReg.UEFICA2023Status -eq "Updated"
) { $true } else { $false }

$SBReport = [PSCustomObject]@{
    SecureBootState  = $SecureBootState
    UEFICA2023Status = $SecureBootReg.UEFICA2023Status
    SecureBootResult = $SecureBootResult
}
$SBReport | Export-Csv -Path "$FolderPath\SecureBoot.csv" -NoTypeInformation
Write-Host "Secure Boot report exported to $FolderPath\SecureBoot.csv"


# -------------------------------
# 10) Compliance Status
# -------------------------------
$CommentsList = @()

if (-not $ATPResult)          { $CommentsList += "Check the installation of MDATP" }
if (-not $status)             { $CommentsList += "Check the Bitlocker Encryption and Bitlocker Pin" }
if (-not $IntuneResult)       { $CommentsList += "Check Entra ID join / Intune enrollment ($IntuneReason)" }
if (-not $LapsResult)         { $CommentsList += "Check Windows LAPS Entra ID backup ($LapsReason)" }
if (-not $MsDefenderStatus)   { $CommentsList += "Check Microsoft Defender Endpoint" }
if (-not $QualysStatus)       { $CommentsList += "Check the installation of Qualys" }
if (-not $NameMismatch)       { $CommentsList += "Check the installation of Manage Engine" }
if (-not $SecureBootResult)   { $CommentsList += "Check Secure Boot" }

if ($CommentsList.Count -eq 0) {
    $ComplianceStatus = "<strong style='color:green;'>Compliance</strong>"
    $Comments = "No Action Required"
}
else {
    $ComplianceStatus = "<strong style='color:red;'>Not Compliance</strong>"
    $Comments = $CommentsList -join "; "
}

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
###################################################################################
$HtmlContent = @"

<html>
<head>
<style>
    body {
        font-family: 'Times New Roman', Arial, sans-serif;
        font-size: 22px;
        font-weight: 600;
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
        padding: 14px;
        font-size: 28px;
        border-radius: 6px;
        margin-top: 0;
    }
    h3 {
        background: #003366;
        color: white;
        padding: 10px;
        font-size: 24px;
        border-radius: 6px;
        margin-top: 25px;
    }
    h4 {
        color: #00264d;
        font-size: 22px;
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
        padding: 10px;
        font-size: 20px;
        text-align: left;
        border: 3px solid #FFFFFF;
    }
    td {
        background-color: #FFFFFF;
        padding: 8px;
        font-size: 20px;
        border: 3px solid #FFFFFF;
    }
    tr:nth-child(even) td { background-color: #f5f8ff; }
    .footer-note {
        margin-top: 25px;
        font-size: 16px;
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
    <th>ComputerName</th><th>Model</th><th>SerialNumber</th><th>OSEdition</th><th>OperatingSystem</th><th>OSVersion</th>
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
    <th>ApplicationName</th><th>Version</th><th>Status</th>
</tr>
<tr><td>MDATP</td><td>$($ATPStatus.ConfigurationVersion)</td><td>$(Get-ColorStatus $ATPResult)</td></tr>
<tr><td>Bitlocker</td><td>$($encMethod)</td><td>$(Get-ColorStatus $status)</td></tr>
<tr><td>Entra ID Join</td><td>$($JoinType)</td><td>$(Get-ColorStatus ($AzureAdJoined -match '^(?i:yes)$'))</td></tr>
<tr><td>Intune MDM Enrollment</td><td>$($TenantId)</td><td>$(Get-ColorStatus $IntuneMDMEnrolled)</td></tr>
<tr><td>Windows LAPS</td><td>$($BackupTarget)</td><td>$(Get-ColorStatus $LapsResult)</td></tr>
<tr><td>MDE (Defender AV)</td><td>$($DefenderInfo.AntispywareSignatureVersion)</td><td>$(Get-ColorStatus $MsDefenderStatus)</td></tr>
<tr><td>Qualys</td><td>$($ActivationID)</td><td>$(Get-ColorStatus $QualysStatus)</td></tr>
<tr><td>SDP (ManageEngine)</td><td>$($AgentVersion)</td><td>$(Get-ColorStatus $NameMismatch)</td></tr>
<tr><td>Secure Boot</td><td></td><td>$(Get-ColorStatus $SecureBootResult)</td></tr>
</table>

<!-- Bitlocker Status -->
<h3>Bitlocker Status</h3>
<table>
<tr><th>Drive</th><th>ProtectionStatus</th><th>EncryptionPercentage</th><th>EncryptionMethod</th><th>KeyProtectorMethods</th><th>Status</th></tr>
<tr>
    <td>$($mount)</td>
    <td>$($protStatus)</td>
    <td>$($percent)</td>
    <td>$($encMethod)</td>
    <td>$($kpMethods)</td>
    <td>$($statusNote)</td>
</tr>
</table>

<!-- Entra ID / Autopilot Join Status -->
<h3>Entra ID Join &amp; Autopilot Status</h3>
<table>
<tr><th>Identifier</th><th>Value</th></tr>
<tr><td>Join Type</td><td>$($JoinType)</td></tr>
<tr><td>AzureAdJoined</td><td>$($AzureAdJoined)</td></tr>
<tr><td>DomainJoined</td><td>$($DomainJoined)</td></tr>
<tr><td>TenantName</td><td>$($TenantName)</td></tr>
<tr><td>TenantId</td><td>$($TenantId)</td></tr>
<tr><td>MdmUrl</td><td>$($MdmUrl)</td></tr>
<tr><td>DisplayNameUpdated</td><td>$($DisplayNameUpdated)</td></tr>
<tr><td>OsVersionUpdated</td><td>$($OsVersionUpdated)</td></tr>
</table>

<!-- Intune MDM Enrollment -->
<h3>Intune MDM Enrollment</h3>
<table>
<tr><th>Enrolled (MS DM Server record found)</th><th>Result</th></tr>
<tr><td>$($IntuneMDMEnrolled)</td><td>$(Get-ColorStatus $IntuneResult)</td></tr>
</table>
<h4>Reason: $($IntuneReason)</h4>

<!-- Windows LAPS -->
<h3>Windows LAPS</h3>
<table>
<tr><th>BackupDirectory Value</th><th>Backup Target</th><th>Result</th></tr>
<tr>
    <td>$($BackupDirectory)</td>
    <td>$($BackupTarget)</td>
    <td>$(Get-ColorStatus $LapsResult)</td>
</tr>
</table>

<!-- MD ATP -->
<h3>MDATP Onboarding Details</h3>
<table>
<tr><th>ConfigurationVersion</th><th>OrgId</th><th>OnboardingState</th><th>PSPath</th></tr>
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
<tr><th>ComputerID</th><th>AMEngineVersion</th><th>AMProductVersion</th><th>AMServiceVersion</th><th>AMServiceEnabled</th></tr>
<tr>
    <td>$($DefenderInfo.ComputerID)</td>
    <td>$($DefenderInfo.AMEngineVersion)</td>
    <td>$($DefenderInfo.AMProductVersion)</td>
    <td>$($DefenderInfo.AMServiceVersion)</td>
    <td>$($DefenderInfo.AMServiceEnabled)</td>
</tr>
</table>

<table>
<tr><th>AntispywareSignatureVersion</th><th>AntispywareSignatureLastUpdated</th><th>AntispywareEnabled</th><th>AntivirusSignatureVersion</th><th>AntivirusSignatureLastUpdated</th><th>AntivirusEnabled</th></tr>
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
<tr><th>BehaviorMonitorEnabled</th><th>FullScanAge</th><th>FullScanSignatureVersion</th><th>FullScanStartTime</th><th>FullScanEndTime</th><th>IoavProtectionEnabled</th><th>IsTamperProtected</th></tr>
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
<tr><th>NISEngineVersion</th><th>NISSignatureLastUpdated</th><th>NISSignatureVersion</th><th>NISEnabled</th><th>OnAccessProtectionEnabled</th><th>RealTimeProtectionEnabled</th></tr>
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
<tr><th>ActivationID</th><th>CustomerID</th><th>AgentInstallPath</th></tr>
<tr>
    <td>$($ActivationID)</td>
    <td>$($CustomerID)</td>
    <td>$($AgentInstallPath)</td>
</tr>
</table>

<!-- SDP (ManageEngine) Status - optional, remove if not in use -->
<h3>SDP (ManageEngine Desktop Central) Status</h3>
<table>
<tr><th>AgentName</th><th>AgentVersion</th><th>InstalledTime</th><th>InstalledPath</th><th>LastSyncTime</th><th>MachineName</th><th>SDPName</th></tr>
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
<tr><th>Secure Boot</th><th>UEFICA2023Status</th></tr>
<tr>
    <td>$($SecureBootState)</td>
    <td>$($SecureBootReg.UEFICA2023Status)</td>
</tr>
</table>

</body>
</html>
"@
$HtmlContent | Out-File -FilePath $HtmlFile -Encoding UTF8


#######################################################################################
Write-Host "⏳Getting Installed Software" -ForegroundColor Green

$htmlPath = "$HtmlFile"

$software = Get-CimInstance -ClassName Win32_Product |
Where-Object { $_.Name -and $_.Name.Trim() -ne "" } |
Select-Object @{Name='Name';Expression={$_.Name}},
              @{Name='Version';Expression={$_.Version}},
              @{Name='InstallDate';Expression={$_.InstallDate}},
              @{Name='Vendor';Expression={$_.Vendor}},
              @{Name='InstallLocation';Expression={$_.InstallLocation}} |
Sort-Object Name

$rowsSW = foreach ($app in $software) {
    $name    = if ($app.Name)             { $app.Name }             else { '-' }
    $version = if ($app.Version)          { $app.Version }          else { '-' }
    $dateRaw = if ($app.InstallDate)      { $app.InstallDate }      else { '-' }
    $vendor  = if ($app.Vendor)           { $app.Vendor }           else { '-' }
    $path    = if ($app.InstallLocation)  { $app.InstallLocation }  else { '-' }

    $installDate =
        if ($dateRaw -is [string] -and $dateRaw -match '^\d{8}$') {
            try { [datetime]::ParseExact($dateRaw, 'yyyyMMdd', $null).ToString('yyyy-MM-dd') }
            catch { $dateRaw }
        } else { $dateRaw }

    "<tr><td>$name</td><td>$version</td><td>$installDate</td><td>$vendor</td><td>$path</td></tr>"
}

$softwareTable = @"
<h3>Installed Software</h3>
<table>
<tr><th>Name</th><th>Version</th><th>Install Date</th><th>Vendor</th><th>Install Location</th></tr>
$($rowsSW -join "`n")
</table>
"@

$htmlContent = Get-Content $htmlPath -Raw
$htmlContent = $htmlContent -replace '</body>', "$softwareTable`n</body>"
$htmlContent | Out-File -FilePath $htmlPath -Encoding UTF8


#######################################################################################
Write-Host "⏳Getting Installed Patches" -ForegroundColor Green

$htmlPath = "$HtmlFile"

$hotfixes = Get-CimInstance -ClassName Win32_QuickFixEngineering |
Sort-Object InstalledOn

$rows = foreach ($hf in $hotfixes) {
    $description = $hf.Description
    $hotfixID    = $hf.HotFixID
    $installedBy = $hf.InstalledBy
    $installedOn = $hf.InstalledOn

    "<tr><td>$hotfixID</td><td>$description</td><td>$installedOn</td><td>$installedBy</td></tr>"
}

$hotfixTable = @"
<h3>Installed Patches</h3>
<table>
<tr><th>HotFixID</th><th>Description</th><th>InstalledOn</th><th>InstalledBy</th></tr>
$($rows -join "`n")
</table>
<h4>Prepare by: $PicName</h4>
<h4>PIC: $PicName1</h4>
<h4>Prepare on: $ReportDateTime</h4>
"@

$htmlContent = Get-Content $htmlPath -Raw
$htmlContent = $htmlContent -replace '</body>', "$hotfixTable`n</body>"
$htmlContent | Out-File -FilePath $htmlPath -Encoding UTF8
Write-Host "✅ HTML report generated: $HtmlFile" -ForegroundColor Green
Write-Host "📄 Report ready for review at $HtmlFile" -ForegroundColor Cyan

# NOTE: Email sending removed for testing. The intermediate CSV files
# (ComputerDetails.csv, ATP.csv, bitlocker.csv, DSReg_Status.csv, LAPS.csv,
# SDP.csv, SecureBoot.csv) are intentionally left in C:\ReportCard\MDE so you can
# inspect them alongside MachineReport.html. Re-add the email block (and the
# CSV cleanup step, if you still want it) once you're ready to move this back
# into production.
