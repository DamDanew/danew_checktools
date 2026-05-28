[CmdletBinding()]
param(
    [string]$RootPath,
    [string]$OutputDirectory,
    [int]$DiskNumber = 4
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RootPath)) {
    $scriptRoot = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
        $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    }
    $RootPath = Split-Path -Parent (Split-Path -Parent $scriptRoot)
}

if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $RootPath 'reports'
}

function Add-PostUX2FResult {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Details = ''
    )

    return [pscustomobject]@{ name = $Name; passed = $Passed; details = $Details }
}

$results = @()

$dataVol = @(Get-Volume -FileSystemLabel 'DANEW_DATA' -ErrorAction SilentlyContinue | Select-Object -First 1)
$bootVol = @(Get-Volume -FileSystemLabel 'DANEW_BOOT' -ErrorAction SilentlyContinue | Select-Object -First 1)

$results += Add-PostUX2FResult -Name 'danew_data_detection' -Passed (@($dataVol).Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$dataVol[0].DriveLetter)) -Details ($(if (@($dataVol).Count -gt 0) { 'DANEW_DATA=' + [string]$dataVol[0].DriveLetter + ':' } else { 'DANEW_DATA volume not detected' }))
$results += Add-PostUX2FResult -Name 'danew_boot_detection' -Passed (@($bootVol).Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$bootVol[0].DriveLetter)) -Details ($(if (@($bootVol).Count -gt 0) { 'DANEW_BOOT=' + [string]$bootVol[0].DriveLetter + ':' } else { 'DANEW_BOOT volume not detected' }))

$bootRoot = if (@($bootVol).Count -gt 0) { [string]$bootVol[0].DriveLetter + ':' } else { '' }
$dataRoot = if (@($dataVol).Count -gt 0) { [string]$dataVol[0].DriveLetter + ':' } else { '' }

$usbSafetyPath = Join-Path $RootPath 'reports\usb-safety-validation.json'
$usbExportPath = Join-Path $RootPath 'reports\usb-export-report.json'
$usbBootValidationPath = Join-Path $RootPath 'reports\usb-boot-validation.json'
$usbDevicePath = Join-Path $RootPath 'reports\usb-device-analysis.json'

$usbSafety = if (Test-Path $usbSafetyPath) { Get-Content -Path $usbSafetyPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20 } else { $null }
$usbExport = if (Test-Path $usbExportPath) { Get-Content -Path $usbExportPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 30 } else { $null }
$usbBoot = if (Test-Path $usbBootValidationPath) { Get-Content -Path $usbBootValidationPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20 } else { $null }
$usbDevices = if (Test-Path $usbDevicePath) { Get-Content -Path $usbDevicePath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 30 } else { @() }

$results += Add-PostUX2FResult -Name 'usb_safety_validation_pass' -Passed ($usbSafety -and $usbSafety.safety_passed) -Details ($(if ($usbSafety) { 'safety_passed=' + [string]$usbSafety.safety_passed } else { 'usb-safety-validation.json missing' }))
$results += Add-PostUX2FResult -Name 'usb_export_report_pass' -Passed ($usbExport -and [string]$usbExport.status -eq 'PASS') -Details ($(if ($usbExport) { 'status=' + [string]$usbExport.status } else { 'usb-export-report.json missing' }))
$results += Add-PostUX2FResult -Name 'usb_boot_validation_pass' -Passed ($usbBoot -and [string]$usbBoot.status -eq 'PASS') -Details ($(if ($usbBoot) { 'status=' + [string]$usbBoot.status } else { 'usb-boot-validation.json missing' }))

$deviceMatch = @($usbDevices | Where-Object { [int]$_.disk_number -eq $DiskNumber } | Select-Object -First 1)
$deviceOk = $false
$deviceDetails = 'Disk not found in usb-device-analysis.json'
if ($deviceMatch) {
    $deviceOk = (($deviceMatch.bus_type -eq 'USB' -or [bool]$deviceMatch.removable) -and -not [bool]$deviceMatch.is_system -and -not [bool]$deviceMatch.is_boot -and -not [bool]$deviceMatch.contains_windows)
    $deviceDetails = 'bus=' + [string]$deviceMatch.bus_type + '; removable=' + [string]$deviceMatch.removable + '; system=' + [string]$deviceMatch.is_system + '; boot=' + [string]$deviceMatch.is_boot + '; windows=' + [string]$deviceMatch.contains_windows
}
$results += Add-PostUX2FResult -Name 'target_disk_safe' -Passed $deviceOk -Details $deviceDetails

$paths = @(
    @{ name = 'launcher.ps1'; local = Join-Path $RootPath 'scripts\launcher.ps1'; rel = 'scripts\launcher.ps1' },
    @{ name = 'LauncherCore.ps1'; local = Join-Path $RootPath 'scripts\launcher\LauncherCore.ps1'; rel = 'scripts\launcher\LauncherCore.ps1' },
    @{ name = 'DanewCheckTool.CLI.ps1'; local = Join-Path $RootPath 'scripts\DanewCheckTool.CLI.ps1'; rel = 'scripts\DanewCheckTool.CLI.ps1' },
    @{ name = 'OfflineLogsEngine.ps1'; local = Join-Path $RootPath 'scripts\offline\OfflineLogsEngine.ps1'; rel = 'scripts\offline\OfflineLogsEngine.ps1' },
    @{ name = 'CrashAnalysisEngine.ps1'; local = Join-Path $RootPath 'scripts\offline\CrashAnalysisEngine.ps1'; rel = 'scripts\offline\CrashAnalysisEngine.ps1' }
)

foreach ($item in $paths) {
    $localHash = if (Test-Path $item.local) { (Get-FileHash -Algorithm SHA256 -Path $item.local).Hash } else { '' }
    $bootHash = ''
    $dataHash = ''
    if ($bootRoot -ne '') {
        $bootPath = Join-Path $bootRoot $item.rel
        if (Test-Path $bootPath) { $bootHash = (Get-FileHash -Algorithm SHA256 -Path $bootPath).Hash }
    }
    if ($dataRoot -ne '') {
        $dataPath = Join-Path $dataRoot $item.rel
        if (Test-Path $dataPath) { $dataHash = (Get-FileHash -Algorithm SHA256 -Path $dataPath).Hash }
    }
    $hashOk = ($localHash -ne '') -and ($localHash -eq $bootHash) -and ($localHash -eq $dataHash)
    $results += Add-PostUX2FResult -Name ('hash_sync_' + $item.name) -Passed $hashOk -Details ('local=' + $localHash + '; boot=' + $bootHash + '; data=' + $dataHash)
}

$bootLauncher = if ($bootRoot -ne '') { Join-Path $bootRoot 'scripts\launcher.ps1' } else { '' }
$dataLauncher = if ($dataRoot -ne '') { Join-Path $dataRoot 'scripts\launcher.ps1' } else { '' }

$launcherParseOk = $true
$parseDetails = @()
foreach ($path in @($bootLauncher, $dataLauncher)) {
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path $path)) {
        $launcherParseOk = $false
        $parseDetails += 'missing=' + $path
        continue
    }
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors) {
        $launcherParseOk = $false
        $parseDetails += 'parse_fail=' + $path
    }
    else {
        $parseDetails += 'parse_ok=' + $path
    }
}
$results += Add-PostUX2FResult -Name 'launcher_parse_validation' -Passed $launcherParseOk -Details ($parseDetails -join '; ')

$uiStringsOk = $false
$uiDetails = 'launcher.ps1 missing on USB'
if ($dataLauncher -and (Test-Path $dataLauncher)) {
    $content = Get-Content -Path $dataLauncher -Raw -Encoding UTF8
    $need = @('ANALYZE WINDOWS LOGS', 'ANALYZE CRASH CAUSES', 'Diagnostic Summary', 'Recommended next action')
    $missing = @($need | Where-Object { $content -notmatch [regex]::Escape($_) })
    $oldTitlePresent = $content -match 'Probable Cause and Severity'
    $uiStringsOk = (@($missing).Count -eq 0) -and (-not $oldTitlePresent)
    $uiDetails = 'missing=' + ($missing -join ', ') + '; old_title=' + [string]$oldTitlePresent
}
$results += Add-PostUX2FResult -Name 'usb_ui_strings_ok' -Passed $uiStringsOk -Details $uiDetails

$summary = [pscustomobject]@{
    total = @($results).Count
    passed = @($results | Where-Object { $_.passed }).Count
    failed = @($results | Where-Object { -not $_.passed }).Count
}

$report = [pscustomobject]@{
    timestamp = (Get-Date).ToString('s')
    summary = $summary
    tests = $results
}

if (-not (Test-Path -Path $OutputDirectory)) {
    New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
}

$jsonPath = Join-Path $OutputDirectory 'post-ux2f-usb-validation.json'
$txtPath = Join-Path $OutputDirectory 'post-ux2f-usb-validation.txt'

$report | ConvertTo-Json -Depth 20 | Set-Content -Path $jsonPath -Encoding UTF8

$lines = @(
    'Post UX-2F USB Validation',
    ('Total: ' + [string]$summary.total),
    ('Passed: ' + [string]$summary.passed),
    ('Failed: ' + [string]$summary.failed),
    ''
)
foreach ($result in @($results)) {
    $status = if ($result.passed) { 'PASS' } else { 'FAIL' }
    $lines += '[' + $status + '] ' + [string]$result.name + ' - ' + [string]$result.details
}
$lines | Set-Content -Path $txtPath -Encoding UTF8

Write-Host ('Post UX-2F USB validation JSON: ' + $jsonPath)
Write-Host ('Post UX-2F USB validation TXT: ' + $txtPath)

if ($summary.failed -gt 0) {
    exit 1
}
