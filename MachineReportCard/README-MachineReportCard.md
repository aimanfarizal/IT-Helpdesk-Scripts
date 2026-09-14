# Machine Report Card

PowerShell scripts that generate an HTML "report card" for a Windows endpoint,
summarizing security/compliance posture (BitLocker, Defender for Endpoint,
Secure Boot, patching, etc.) for a helpdesk or deployment team to review.

Two versions are included, covering a migration from an on-prem MDT + hybrid
Active Directory + SCCM deployment model to a cloud-native Autopilot + Intune
model:

| File | Use case |
|---|---|
| `MachineReportCard_sanitized.ps1` | Legacy/hybrid environment: MDT-imaged, AD domain-joined, SCCM co-managed devices |
| `AutopilotMachineReport_sanitized.ps1` | Cloud-native environment: Windows Autopilot–deployed, Microsoft Entra ID joined, Intune-managed devices |

Pick the one that matches how the target device was deployed. Don't run the
legacy script against an Autopilot device (or vice versa) — several checks
assume a domain/ConfigMgr client that simply won't exist on the other side.

---

## What changed between the two versions

| Area | Legacy script | Autopilot script |
|---|---|---|
| Co-Management / SCCM | Reads the ConfigMgr client (`root\ccm\invagt`, `ccmsetup.log`) | **Removed** — Autopilot devices normally have no ConfigMgr client |
| Domain / Intune check | Trusts `dsregcmd`'s `AzureAdJoined` flag alone | Also confirms `DomainJoined = NO` **and** a real MDM enrollment record exists under `HKLM:\SOFTWARE\Microsoft\Enrollments` (`ProviderID = MS DM Server`) — proves Intune enrollment actually completed, not just that the device has an Entra ID identity |
| Windows LAPS | Checks that the LAPS registry keys exist | Checks the actual `BackupDirectory` value: `1` = Microsoft Entra ID (expected on Autopilot), `2` = legacy on-prem AD target |
| Everything else (BitLocker, MDATP onboarding, Defender AV, Secure Boot, Qualys, ManageEngine/SDP, installed software & patches, email) | Same OS/agent-level checks in both — these don't depend on how the device is joined | Same |

The Autopilot script's ManageEngine ("SDP") section is left in but marked
optional — remove it if you're retiring that tool alongside MDT/SCCM.

---

## Requirements

- Windows 10/11, run **elevated** (Administrator or SYSTEM) — BitLocker,
  Secure Boot, and several registry paths require admin rights to read.
- PowerShell 5.1 or later (Windows PowerShell, not PowerShell 7, is the safer
  bet since `Get-BitLockerVolume` and the Defender CIM classes are most
  reliably available there).
- Run locally, on the endpoint being reported on. Both scripts read local
  state only — nothing is queried remotely or via Microsoft Graph.
- **Legacy script only:** device should be AD domain-joined, with a ConfigMgr
  client installed, for the Co-Management/SCCM section to return real data.
- **Autopilot script only:** device should be Microsoft Entra ID joined and
  Intune-enrolled for the Entra/Intune section to report `True`.

---

## Configuration

Both scripts have a `# CONFIGURE ME` comment at every value you need to set
for your environment before running:

- **Both scripts** — `$FolderPath`, the local folder used to stage the CSVs
  and the final `MachineReport.html` (defaults to `C:\ReportCard\MDE`).
- **Legacy script only** — the SMTP block near the bottom (`$SmtpServer`,
  `$From`, `$To`) used to email the finished report.

> The Autopilot script currently has its email step removed for testing — it
> stops after writing `MachineReport.html`, and leaves the intermediate CSVs
> in `$FolderPath` for you to inspect. Re-add a `Send-MailMessage` block
> (mirroring the legacy script's EMAIL section) once you're ready to wire it
> into production.

---

## Usage

```powershell
# From an elevated PowerShell prompt
.\MachineReportCard_sanitized.ps1
# or
.\AutopilotMachineReport_sanitized.ps1
```

You'll be prompted for two names (helpdesk staff PIC and intern PIC) that get
stamped on the report footer. The finished report lands at
`<FolderPath>\MachineReport.html`.

---

## Known limitations

- **Autopilot deployment profile / Enrollment Status Page (ESP) history /
  Intune compliance policy state are not included.** Microsoft doesn't
  publish stable local artifacts for these — they live in Intune/Entra and
  are best pulled from the Microsoft Graph `deviceManagement` API rather than
  scraped from local registry keys. A Graph-based companion script is a
  natural next step if you need them on the card.
- `Win32_Product` (used for the Installed Software table) is known to trigger
  a Windows Installer self-repair pass on every app it enumerates. It's kept
  here for simplicity, but for a production/scheduled rollout consider
  swapping it for a registry-based scan of the `Uninstall` keys instead.
- The legacy script's Co-Management/SCCM section will report `N/A`/`False`
  on any device without a ConfigMgr client — that's expected, not a bug.

## Disclaimer

Provided as-is. Placeholder paths, emails, and SMTP settings must be updated
for your own environment before use — test on a handful of non-production
devices before rolling either script out broadly.
