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

function Add-PostFinalResult {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Details = ''
    )

    return [pscustomobject]@{ name = $Name; passed = $Passed; details = $Details }
}

$results = @()

$usbDevicePath = Join-Path $RootPath 'reports\usb-device-analysis.json'
$devices = @()
if (Test-Path -Path $usbDevicePath) {
    try {
        $devices = @(Get-Content -Path $usbDevicePath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20)
    }
    catch {
        $devices = @()
    }
}

$disk = @($devices | Where-Object { [int]$_.disk_number -eq $DiskNumber } | Select-Object -First 1)
$liveDisk = $null
if (@($disk).Count -eq 0) {
    try {
        $liveDisk = Get-Disk -Number $DiskNumber -ErrorAction Stop
    }
    catch {
        $liveDisk = $null
    }
}
$diskFound = @($disk).Count -gt 0
$diskDetected = $diskFound -or ($null -ne $liveDisk)
$results += Add-PostFinalResult -Name 'disk4_present_in_analysis' -Passed $diskDetected -Details ($(if ($diskFound) { 'Disk 4 found in usb-device-analysis.json' } elseif ($liveDisk) { 'Disk 4 found via Get-Disk live query' } else { 'Disk 4 missing in usb-device-analysis.json and Get-Disk' }))

if ($diskFound -or $liveDisk) {
    if ($diskFound) {
        $isUsb = ([string]$disk[0].bus_type -eq 'USB') -or [bool]$disk[0].removable
        $isSafe = (-not [bool]$disk[0].is_system) -and (-not [bool]$disk[0].is_boot) -and (-not [bool]$disk[0].contains_windows)
        $usbDetails = 'bus=' + [string]$disk[0].bus_type + '; removable=' + [string]$disk[0].removable
        $safeDetails = 'system=' + [string]$disk[0].is_system + '; boot=' + [string]$disk[0].is_boot + '; windows=' + [string]$disk[0].contains_windows
    }
    else {
        $isUsb = (([string]$liveDisk.BusType -eq 'USB') -or [bool]$liveDisk.IsBoot -eq $false)
        $isSafe = (-not [bool]$liveDisk.IsSystem) -and (-not [bool]$liveDisk.IsBoot)
        $usbDetails = 'live_bus=' + [string]$liveDisk.BusType + '; live_number=' + [string]$liveDisk.Number
        $safeDetails = 'live_isSystem=' + [string]$liveDisk.IsSystem + '; live_isBoot=' + [string]$liveDisk.IsBoot
    }
    $results += Add-PostFinalResult -Name 'disk4_usb_or_removable' -Passed $isUsb -Details $usbDetails
    $results += Add-PostFinalResult -Name 'disk4_not_system_boot_windows' -Passed $isSafe -Details $safeDetails
}
else {
    $results += Add-PostFinalResult -Name 'disk4_usb_or_removable' -Passed $false -Details 'Disk 4 not found.'
    $results += Add-PostFinalResult -Name 'disk4_not_system_boot_windows' -Passed $false -Details 'Disk 4 not found.'
}

$requiredLocal = @(
    'scripts\launcher.ps1',
    'scripts\launcher\LauncherCore.ps1',
    'scripts\DanewCheckTool.CLI.ps1',
    'scripts\offline\OfflineLogsEngine.ps1',
    'scripts\offline\CrashAnalysisEngine.ps1',
    'scripts\report\HtmlReportShell.ps1',
    'manifests\evtx-event-knowledge.json',
    'Assets_danew\danew_line_black.png',
    'Assets_danew\danew_brand_line_blue.ico',
    'scripts\winpe\WinPEPrecheckAgent.ps1',
    'scripts\Invoke-DanewRealWinPEValidation.ps1'
)

$targets = @('D:\', 'E:\')
foreach ($target in @($targets)) {
    $targetName = $target.Substring(0, 1)
    $exists = Test-Path -Path $target
    $results += Add-PostFinalResult -Name ('target_' + $targetName + '_present') -Passed $exists -Details ($(if ($exists) { 'present' } else { 'missing' }))
    if (-not $exists) {
        continue
    }

    foreach ($rel in @($requiredLocal)) {
        $src = Join-Path $RootPath $rel
        $dst = Join-Path $target $rel
        $name = ($rel -replace '[\\/:]', '_')

        $srcExists = Test-Path -Path $src
        $dstExists = Test-Path -Path $dst
        $results += Add-PostFinalResult -Name ('exists_' + $targetName + '_' + $name) -Passed ($srcExists -and $dstExists) -Details ('src=' + [string]$srcExists + '; dst=' + [string]$dstExists)

        if ($srcExists -and $dstExists) {
            $srcHash = (Get-FileHash -Algorithm SHA256 -Path $src).Hash
            $dstHash = (Get-FileHash -Algorithm SHA256 -Path $dst).Hash
            $results += Add-PostFinalResult -Name ('hash_' + $targetName + '_' + $name) -Passed ($srcHash -eq $dstHash) -Details ('src=' + $srcHash + '; dst=' + $dstHash)
        }
    }
}

$launcherUsb = 'E:\scripts\launcher.ps1'
if (-not (Test-Path -Path $launcherUsb)) {
    $launcherUsb = 'D:\scripts\launcher.ps1'
}

if (Test-Path -Path $launcherUsb) {
    $launcherText = Get-Content -Path $launcherUsb -Raw -Encoding UTF8

    $nonAscii = @(Select-String -Path $launcherUsb -Pattern '[^\x00-\x7F]')
    $results += Add-PostFinalResult -Name 'usb_launcher_non_ascii_absent' -Passed (@($nonAscii).Count -eq 0) -Details ('non_ascii_lines=' + [string]@($nonAscii).Count)

    $mojiPattern = ([string][char]0x00C3) + '|' + ([string][char]0x00C2) + '|' + (([string][char]0x00E2) + ([string][char]0x20AC))
    $moji = @(Select-String -Path $launcherUsb -Pattern $mojiPattern)
    $results += Add-PostFinalResult -Name 'usb_launcher_mojibake_markers_absent' -Passed (@($moji).Count -eq 0) -Details ('mojibake_hits=' + [string]@($moji).Count)

    $labels = @(
        'ANALYSER LES JOURNAUX WINDOWS',
        'ANALYSER LES CAUSES DE CRASH',
        'OUVRIR LE RAPPORT SAV',
        'OUVRIR LE RAPPORT CHRONOLOGIQUE',
        'EXPORTER LE DOSSIER SAV',
        'EXPORT EVTX CIBLE',
        'ACTIONS RECOMMANDEES',
        'AFFICHER LES OUTILS AVANCES',
        'MASQUER LES OUTILS AVANCES',
        'AFFICHER LES DETAILS TECHNIQUES',
        'MASQUER LES DETAILS TECHNIQUES',
        'ACTUALISER LE RESUME',
        'SCAN CAPACITES WINPE',
        'VERIFIER WINPE',
        'GENERER LE RAPPORT DE BASE'
    )
    $missing = @($labels | Where-Object { $launcherText -notmatch [regex]::Escape($_) })
    $results += Add-PostFinalResult -Name 'usb_launcher_required_labels_present' -Passed (@($missing).Count -eq 0) -Details ($(if (@($missing).Count -eq 0) { 'OK' } else { 'missing=' + ($missing -join ', ') }))
}
else {
    $results += Add-PostFinalResult -Name 'usb_launcher_non_ascii_absent' -Passed $false -Details 'launcher.ps1 missing on USB targets'
    $results += Add-PostFinalResult -Name 'usb_launcher_mojibake_markers_absent' -Passed $false -Details 'launcher.ps1 missing on USB targets'
    $results += Add-PostFinalResult -Name 'usb_launcher_required_labels_present' -Passed $false -Details 'launcher.ps1 missing on USB targets'
}

$summary = [pscustomobject]@{
    total = @($results).Count
    passed = @($results | Where-Object { $_.passed }).Count
    failed = @($results | Where-Object { -not $_.passed }).Count
}

$report = [pscustomobject]@{
    timestamp = (Get-Date).ToString('s')
    disk_number = $DiskNumber
    summary = $summary
    tests = $results
}

if (-not (Test-Path -Path $OutputDirectory)) {
    New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
}

$jsonPath = Join-Path $OutputDirectory 'post-final-usb-validation.json'
$txtPath = Join-Path $OutputDirectory 'post-final-usb-validation.txt'

$report | ConvertTo-Json -Depth 30 | Set-Content -Path $jsonPath -Encoding UTF8

$lines = @(
    'Post Final USB Validation',
    ('Disk: ' + [string]$DiskNumber),
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

Write-Host ('Post final USB validation JSON: ' + $jsonPath)
Write-Host ('Post final USB validation TXT: ' + $txtPath)

if ($summary.failed -gt 0) {
    exit 1
}
