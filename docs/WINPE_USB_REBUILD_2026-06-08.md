# WinPE USB rebuild - 2026-06-08

## Purpose

This branch records the validated WinPE USB rebuild used for the Danew SAV diagnostic key.
It is intended as a recovery point and regression reference before future USB media changes.

## Target media

- Disk number: 4
- Friendly name: Realtek RTL9210 NVME
- Serial: 012345681403
- BOOT partition: `D:` / `DANEW_BOOT` / FAT32
- DATA partition: `E:` / `DANEW_DATA` / NTFS

## Rebuild command

```powershell
& .\WinPe_local\scripts\Invoke-DanewCreateUsbMedia.ps1 `
  -RootPath .\WinPe_local `
  -Mode Provision `
  -TargetDiskNumber 4 `
  -NonInteractive `
  -ConfirmDiskNumber 4 `
  -ConfirmToken 'DANEW-FORMAT-DISK-4'
```

## Important fixes captured here

- Added a DISM fallback for WinPE package detection when `Get-WindowsPackage` returns no packages.
- Repaired `WinPe_local\sources\boot.wim` with the required WinPE packages before provisioning:
  `WinPE-WMI`, `WinPE-Scripting`, `WinPE-NetFx`, `WinPE-PowerShell`, `WinPE-MDAC`, `WinPE-StorageWMI`.
- Kept the launcher compatible with strict WinPE validation by removing non-ASCII launcher text and restoring the expected toggle labels:
  `AFFICHER LES OUTILS AVANCES`, `MASQUER LES OUTILS AVANCES`,
  `AFFICHER LES DETAILS TECHNIQUES`, `MASQUER LES DETAILS TECHNIQUES`.
- Preserved the offline report viewer improvement that opens HTML reports through the built-in WinForms WebBrowser/MSHTML path before falling back to native TXT/CSV companions.

## Validation summary

All checks below passed after provisioning and final report sync to `E:\reports`.

| Check | Result |
| --- | --- |
| USB provision report | PASS |
| Boot validation | PASS |
| boot.wim package validation | PASS |
| Post browser USB validation | 36 / 36 |
| Post final USB validation | 52 / 52 |
| Post UX2B USB validation | 9 / 9 |
| Post UX2F USB validation | 13 / 13 |
| Recursive manifest hash check | 1807 files, 0 failures |
| Targeted USB sync check | SYNC OK |

## Key hashes

```text
boot.wim SHA256:
485A1D97C10580C24B71E04345ECACE033CB9A996A3C877FCD7285D3DAA9BEF6

launcher.ps1 SHA256:
FC89966DB8CE14EC4D2BBDE1AC69425A6331FDBD7D592A0918ECB7994CD5DD47
```

## Reports to inspect

- `WinPe_local\reports\usb-export-report.json`
- `WinPe_local\reports\usb-boot-validation.json`
- `WinPe_local\reports\boot-wim-package-validation.json`
- `WinPe_local\reports\post-final-usb-validation.json`
- `WinPe_local\reports\post-browser-usb-validation.json`
- `WinPe_local\reports\post-ux2b-usb-validation.json`
- `WinPe_local\reports\post-ux2f-usb-validation.json`

## Regression guard

Before changing the USB creation flow again, rerun:

```powershell
& .\WinPe_local\scripts\Invoke-DanewCreateUsbMedia.ps1 -RootPath .\WinPe_local -Mode Analyze -TargetDiskNumber 4 -NonInteractive
& .\WinPe_local\scripts\tests\Run-PostBrowserUsbValidation.ps1 -RootPath .\WinPe_local
& .\WinPe_local\scripts\tests\Run-PostFinalUsbValidation.ps1 -RootPath .\WinPe_local
& .\WinPe_local\scripts\tests\Run-PostUX2BUsbValidation.ps1 -RootPath .\WinPe_local
& .\WinPe_local\scripts\tests\Run-PostUX2FUsbValidation.ps1 -RootPath .\WinPe_local
```
