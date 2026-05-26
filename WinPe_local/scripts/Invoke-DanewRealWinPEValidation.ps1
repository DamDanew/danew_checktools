[CmdletBinding()]
param(
    [string]$RootPath = (Split-Path -Parent $PSScriptRoot),
    [string]$ConfigPath,
    [switch]$SkipUsbExport
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'core\Logging.ps1')
. (Join-Path $PSScriptRoot 'catalog\CatalogService.ps1')
. (Join-Path $PSScriptRoot 'scan\ScanEngine.ps1')
. (Join-Path $PSScriptRoot 'profiles\ProfileEngine.ps1')
. (Join-Path $PSScriptRoot 'recommend\RecommendationEngine.ps1')
. (Join-Path $PSScriptRoot 'recommend\EnrichmentPlanner.ps1')
. (Join-Path $PSScriptRoot 'build\BuildPreparation.ps1')
. (Join-Path $PSScriptRoot 'report\ReportEngine.ps1')
. (Join-Path $PSScriptRoot 'security\SecurityService.ps1')
. (Join-Path $PSScriptRoot 'launcher\LauncherCore.ps1')

function Get-DanewDriveTypeLabel {
    param(
        [int]$DriveType
    )

    switch ($DriveType) {
        2 { 'Removable' }
        3 { 'Fixed' }
        4 { 'Network' }
        5 { 'CDROM' }
        6 { 'RAMDisk' }
        default { 'Unknown' }
    }
}

function Get-DanewDetectedDrives {
    $logicalDisks = @()
    try {
        $logicalDisks = @(Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction Stop)
    }
    catch {
        $logicalDisks = @()
    }

    if (@($logicalDisks).Count -gt 0) {
        return @($logicalDisks | ForEach-Object {
                [pscustomobject]@{
                    letter = [string]$_.DeviceID
                    drive_type = Get-DanewDriveTypeLabel -DriveType ([int]$_.DriveType)
                    file_system = [string]$_.FileSystem
                    size_gb = if ($_.Size) { [math]::Round(([double]$_.Size / 1GB), 2) } else { 0 }
                    free_gb = if ($_.FreeSpace) { [math]::Round(([double]$_.FreeSpace / 1GB), 2) } else { 0 }
                    volume_name = [string]$_.VolumeName
                    root_accessible = Test-Path -Path ($_.DeviceID + '\\')
                }
            })
    }

    $letters = @('A'..'Z')
    return @($letters | ForEach-Object {
            $drive = $_ + ':'
            [pscustomobject]@{
                letter = $drive
                drive_type = 'Unknown'
                file_system = ''
                size_gb = 0
                free_gb = 0
                volume_name = ''
                root_accessible = Test-Path -Path ($drive + '\\')
            }
        } | Where-Object { $_.root_accessible })
}

function Get-DanewOfflineWindowsDetection {
    param(
        [object[]]$Drives
    )

    $items = @()
    foreach ($d in $Drives) {
        $root = $d.letter + '\\'
        $windowsPath = Join-Path $root 'Windows'
        $system32Path = Join-Path $windowsPath 'System32'
        $systemHive = Join-Path $system32Path 'config\\SYSTEM'
        $softwareHive = Join-Path $system32Path 'config\\SOFTWARE'
        $eventLogs = Join-Path $system32Path 'winevt\\Logs'

        $isWindowsInstall = (Test-Path -Path $windowsPath) -and (Test-Path -Path $systemHive)

        $items += [pscustomobject]@{
            drive = $d.letter
            windows_path = $windowsPath
            is_windows_installation = $isWindowsInstall
            has_system_hive = (Test-Path -Path $systemHive)
            has_software_hive = (Test-Path -Path $softwareHive)
            has_event_logs_folder = (Test-Path -Path $eventLogs)
            event_logs_path = $eventLogs
        }
    }

    return $items
}

function Test-DanewPathWrite {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        if (-not (Test-Path -Path $Path)) {
            New-Item -Path $Path -ItemType Directory -Force | Out-Null
        }
        $probe = Join-Path $Path ('probe-' + [guid]::NewGuid().ToString() + '.tmp')
        'ok' | Set-Content -Path $probe -Encoding ASCII
        Remove-Item -Path $probe -Force -ErrorAction SilentlyContinue
        return $true
    }
    catch {
        return $false
    }
}

function Get-DanewInputDeviceStatus {
    $keyboardCount = 0
    $mouseCount = 0

    try {
        $keyboardCount = @(Get-CimInstance -ClassName Win32_Keyboard -ErrorAction Stop).Count
    }
    catch {
        $keyboardCount = 0
    }

    try {
        $mouseCount = @(Get-CimInstance -ClassName Win32_PointingDevice -ErrorAction Stop).Count
    }
    catch {
        $mouseCount = 0
    }

    [pscustomobject]@{
        keyboard_detected = ($keyboardCount -gt 0)
        keyboard_count = $keyboardCount
        mouse_detected = ($mouseCount -gt 0)
        mouse_count = $mouseCount
    }
}

function Get-DanewNetworkStatus {
    $upAdapters = @()
    $hasDefaultGateway = $false
    $testPing = $false

    try {
        $upAdapters = @(Get-NetIPConfiguration -ErrorAction Stop | Where-Object { $_.NetAdapter.Status -eq 'Up' })
        $hasDefaultGateway = @($upAdapters | Where-Object { $_.IPv4DefaultGateway -or $_.IPv6DefaultGateway }).Count -gt 0
        if ($hasDefaultGateway) {
            $testPing = Test-Connection -ComputerName '1.1.1.1' -Count 1 -Quiet -ErrorAction SilentlyContinue
        }
    }
    catch {
        $upAdapters = @()
        $hasDefaultGateway = $false
        $testPing = $false
    }

    [pscustomobject]@{
        adapters_up = @($upAdapters).Count
        has_default_gateway = $hasDefaultGateway
        internet_ping_ok = [bool]$testPing
        network_available = ((@($upAdapters).Count -gt 0) -and $hasDefaultGateway)
    }
}

function Test-DanewGuiEvidence {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LauncherLogPath
    )

    if (-not (Test-Path -Path $LauncherLogPath)) {
        return [pscustomobject]@{ gui_ok = $false; reason = 'launcher log not found' }
    }

    $items = @()
    try {
        $raw = Get-Content -Path $LauncherLogPath -Raw -Encoding UTF8
        $parsed = $raw | ConvertFrom-Json
        $items = if ($parsed -is [System.Array]) { @($parsed) } elseif ($parsed) { @($parsed) } else { @() }
    }
    catch {
        return [pscustomobject]@{ gui_ok = $false; reason = 'launcher log invalid json' }
    }

    $guiOk = @($items | Where-Object { $_.action -eq 'gui-launcher' -and $_.status -eq 'ok' }).Count -gt 0
    [pscustomobject]@{ gui_ok = $guiOk; reason = if ($guiOk) { 'gui-launcher ok found' } else { 'gui-launcher ok not found' } }
}

function Test-DanewGuiCapability {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        return [pscustomobject]@{ gui_capable = $true; reason = 'WinForms assemblies available' }
    }
    catch {
        return [pscustomobject]@{ gui_capable = $false; reason = $_.Exception.Message }
    }
}

function Test-DanewCliFallbackEvidence {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LauncherLogPath
    )

    if (-not (Test-Path -Path $LauncherLogPath)) {
        return [pscustomobject]@{ fallback_ok = $false; reason = 'launcher log not found' }
    }

    $items = @()
    try {
        $raw = Get-Content -Path $LauncherLogPath -Raw -Encoding UTF8
        $parsed = $raw | ConvertFrom-Json
        $items = if ($parsed -is [System.Array]) { @($parsed) } elseif ($parsed) { @($parsed) } else { @() }
    }
    catch {
        return [pscustomobject]@{ fallback_ok = $false; reason = 'launcher log invalid json' }
    }

    $fallbackOk = @($items | Where-Object { $_.action -eq 'cli-fallback' -and $_.status -eq 'ok' }).Count -gt 0
    [pscustomobject]@{ fallback_ok = $fallbackOk; reason = if ($fallbackOk) { 'cli-fallback ok found' } else { 'cli-fallback ok not found (run fallback scenario once)' } }
}

function Test-DanewStartNetRuntimeEvidence {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StartNetRuntimeLogPath
    )

    if (-not (Test-Path -Path $StartNetRuntimeLogPath)) {
        return [pscustomobject]@{ startnet_ok = $false; entries = 0; reason = 'startnet runtime log missing' }
    }

    $lines = @(Get-Content -Path $StartNetRuntimeLogPath -Encoding UTF8 -ErrorAction SilentlyContinue)
    $hasBegin = @($lines | Where-Object { $_ -match 'STARTNET_BEGIN' }).Count -gt 0
    $hasLauncherInvoke = @($lines | Where-Object { $_ -match 'LAUNCHER_INVOKE_GUI' }).Count -gt 0

    [pscustomobject]@{
        startnet_ok = ($hasBegin -and $hasLauncherInvoke)
        entries = @($lines).Count
        reason = if ($hasBegin -and $hasLauncherInvoke) { 'startnet markers found' } else { 'missing expected startnet markers' }
    }
}

function Export-DanewValidationText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [object]$Validation
    )

    $lines = @(
        'Danew Real WinPE Validation',
        ('Timestamp: ' + $Validation.timestamp),
        ('RootPath: ' + $Validation.root_path),
        ('RunningFromX: ' + $Validation.boot.running_from_x),
        ('StartNetAutoLaunch: ' + $Validation.startnet.startnet_ok),
        ('GuiOpenedEvidence: ' + $Validation.launcher.gui.gui_ok),
        ('GuiCapability: ' + $Validation.launcher.gui_capability.gui_capable),
        ('CliFallbackEvidence: ' + $Validation.launcher.cli_fallback.fallback_ok),
        ('LauncherLogWritable: ' + $Validation.paths.launcher_log_writable),
        ('ReportsWritable: ' + $Validation.paths.reports_writable),
        ('KeyboardDetected: ' + $Validation.input_devices.keyboard_detected),
        ('MouseDetected: ' + $Validation.input_devices.mouse_detected),
        ('VisibleDrives: ' + $Validation.drives.visible_drive_count),
        ('OfflineWindowsFound: ' + $Validation.offline_windows.found_count),
        ('C_Windows_EventLogs_Access: ' + $Validation.offline_windows.c_windows_event_logs_access),
        ('NetworkAvailable: ' + $Validation.network.network_available),
        ('UsbExportAttempted: ' + $Validation.usb_export.attempted),
        ('UsbExportSuccess: ' + $Validation.usb_export.success),
        ('OverallPassed: ' + $Validation.overall_passed)
    )

    $lines | Set-Content -Path $Path -Encoding UTF8
}

$config = Get-DanewLauncherConfig -RootPath $RootPath -ConfigPath $ConfigPath
Initialize-DanewLauncherPaths -Config $config

$reportsPath = $config.reports_path
if (-not (Test-Path -Path $reportsPath)) {
    New-Item -Path $reportsPath -ItemType Directory -Force | Out-Null
}

$startnetRuntimeLogPath = $config.startnet_runtime_log_path
if ([string]::IsNullOrWhiteSpace($startnetRuntimeLogPath)) {
    $startnetRuntimeLogPath = Join-Path $reportsPath 'startnet-runtime-log.txt'
}

if (-not (Test-Path -Path $startnetRuntimeLogPath)) {
    'No StartNet runtime log captured yet.' | Set-Content -Path $startnetRuntimeLogPath -Encoding UTF8
}

Write-DanewLauncherActionLog -Config $config -Action 'phase5b-validation' -Status 'start' -Message 'Real WinPE validation started'

$drives = Get-DanewDetectedDrives
$offlineWindows = Get-DanewOfflineWindowsDetection -Drives $drives

$drivesOutPath = Join-Path $reportsPath 'detected-drives.json'
$offlineOutPath = Join-Path $reportsPath 'offline-windows-detection.json'

$drives | ConvertTo-Json -Depth 20 | Set-Content -Path $drivesOutPath -Encoding UTF8
$offlineWindows | ConvertTo-Json -Depth 20 | Set-Content -Path $offlineOutPath -Encoding UTF8

$startNetEvidence = Test-DanewStartNetRuntimeEvidence -StartNetRuntimeLogPath $startnetRuntimeLogPath
$guiEvidence = Test-DanewGuiEvidence -LauncherLogPath $config.launcher_log_path
$guiCapability = Test-DanewGuiCapability
$fallbackEvidence = Test-DanewCliFallbackEvidence -LauncherLogPath $config.launcher_log_path

if (-not $fallbackEvidence.fallback_ok) {
    try {
        $launcherPath = Join-Path $RootPath 'scripts\launcher.ps1'
        & $launcherPath -RootPath $RootPath -ConfigPath $ConfigPath -FallbackToCli -ForceGuiInitFailure -CliFallbackCommand scan-winpe | Out-Null
        $fallbackEvidence = Test-DanewCliFallbackEvidence -LauncherLogPath $config.launcher_log_path
    }
    catch {
        $fallbackEvidence = [pscustomobject]@{ fallback_ok = $false; reason = 'fallback test execution failed: ' + $_.Exception.Message }
    }
}

$reportsWritable = Test-DanewPathWrite -Path $reportsPath
$logsWritable = Test-DanewPathWrite -Path $config.logs_path
$launcherLogWritable = Test-DanewPathWrite -Path (Split-Path -Parent $config.launcher_log_path)

$inputStatus = Get-DanewInputDeviceStatus
$networkStatus = Get-DanewNetworkStatus

$offlineFound = @($offlineWindows | Where-Object { $_.is_windows_installation }).Count
$cEvtPath = 'C:\Windows\System32\winevt\Logs'
$cEvtAccess = Test-Path -Path $cEvtPath

$usbResult = [pscustomobject]@{ attempted = $false; success = $false; target = ''; diagnostic = '' }
if (-not $SkipUsbExport) {
    $usbCandidates = @($drives | Where-Object { $_.drive_type -eq 'Removable' -and $_.root_accessible })
    if (@($usbCandidates).Count -gt 0) {
        try {
            $pkg = Export-DanewDiagnosticPackage -RootPath $RootPath -Config $config
            $targetRoot = Join-Path ($usbCandidates[0].letter + '\\') 'DanewDiagnostic'
            New-Item -Path $targetRoot -ItemType Directory -Force | Out-Null
            if (-not [string]::IsNullOrWhiteSpace([string]$pkg.zip) -and (Test-Path -Path $pkg.zip)) {
                Copy-Item -Path $pkg.zip -Destination (Join-Path $targetRoot (Split-Path -Leaf $pkg.zip)) -Force
                $usbResult = [pscustomobject]@{ attempted = $true; success = $true; target = $targetRoot; diagnostic = $pkg.zip }
            }
            elseif (Test-Path -Path $pkg.folder) {
                Copy-Item -Path $pkg.folder -Destination $targetRoot -Recurse -Force
                $usbResult = [pscustomobject]@{ attempted = $true; success = $true; target = $targetRoot; diagnostic = $pkg.folder }
            }
            else {
                $usbResult = [pscustomobject]@{ attempted = $true; success = $false; target = $targetRoot; diagnostic = 'diagnostic package not found' }
            }
        }
        catch {
            $usbResult = [pscustomobject]@{ attempted = $true; success = $false; target = ''; diagnostic = $_.Exception.Message }
        }
    }
    else {
        $usbResult = [pscustomobject]@{ attempted = $true; success = $false; target = ''; diagnostic = 'no removable drive detected' }
    }
}

$runningFromX = (($env:SystemDrive -eq 'X:') -or (Get-Location).Path.StartsWith('X:\\', [System.StringComparison]::OrdinalIgnoreCase))
$visibleDriveCount = @($drives).Count

$validation = [pscustomobject]@{
    timestamp = (Get-Date).ToString('s')
    root_path = $RootPath
    boot = [pscustomobject]@{
        system_drive = $env:SystemDrive
        running_from_x = $runningFromX
    }
    startnet = $startNetEvidence
    launcher = [pscustomobject]@{
        gui = $guiEvidence
        gui_capability = $guiCapability
        cli_fallback = $fallbackEvidence
    }
    paths = [pscustomobject]@{
        reports_path = $reportsPath
        logs_path = $config.logs_path
        launcher_log_path = $config.launcher_log_path
        startnet_runtime_log_path = $startnetRuntimeLogPath
        reports_writable = $reportsWritable
        logs_writable = $logsWritable
        launcher_log_writable = $launcherLogWritable
    }
    drives = [pscustomobject]@{
        visible_drive_count = $visibleDriveCount
        drives_file = $drivesOutPath
    }
    offline_windows = [pscustomobject]@{
        found_count = $offlineFound
        detection_file = $offlineOutPath
        c_windows_event_logs_access = $cEvtAccess
        c_windows_event_logs_path = $cEvtPath
    }
    input_devices = $inputStatus
    network = $networkStatus
    usb_export = $usbResult
}

$validation | Add-Member -NotePropertyName overall_passed -NotePropertyValue (
    $validation.startnet.startnet_ok -and
    $validation.paths.reports_writable -and
    $validation.paths.launcher_log_writable -and
    ($validation.drives.visible_drive_count -gt 0)
)

$validationJsonPath = Join-Path $reportsPath 'real-winpe-validation.json'
$validationTxtPath = Join-Path $reportsPath 'real-winpe-validation.txt'

$validation | ConvertTo-Json -Depth 30 | Set-Content -Path $validationJsonPath -Encoding UTF8
Export-DanewValidationText -Path $validationTxtPath -Validation $validation

Write-DanewLauncherActionLog -Config $config -Action 'phase5b-validation' -Status 'ok' -Message 'Real WinPE validation completed' -Data @{ output = $validationJsonPath }

Write-Host "Validation JSON: $validationJsonPath"
Write-Host "Validation TXT: $validationTxtPath"
Write-Host "StartNet runtime log: $startnetRuntimeLogPath"
Write-Host "Detected drives: $drivesOutPath"
Write-Host "Offline Windows detection: $offlineOutPath"
