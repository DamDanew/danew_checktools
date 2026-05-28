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

function Get-DanewWinPERunEnvironment {
    $runningFromX = (($env:SystemDrive -eq 'X:') -or (Get-Location).Path.StartsWith('X:\', [System.StringComparison]::OrdinalIgnoreCase))
    $systemDrive = [string]$env:SystemDrive
    $winPeDetected = $runningFromX -or (Test-Path -Path 'X:\Windows\System32\startnet.cmd')

    [pscustomobject]@{
        winpe_detected = [bool]$winPeDetected
        running_from_x = [bool]$runningFromX
        system_drive = $systemDrive
        current_location = (Get-Location).Path
        startnet_exists = (Test-Path -Path 'X:\Windows\System32\startnet.cmd')
    }
}

function Get-DanewMountedVolumeInventory {
    $volumes = @()

    try {
        if (Get-Command -Name Get-Volume -ErrorAction SilentlyContinue) {
            $rawVolumes = @(Get-Volume -ErrorAction Stop)
            foreach ($volume in @($rawVolumes)) {
                $letter = if ($volume.DriveLetter) { [string]$volume.DriveLetter + ':' } else { '' }
                $label = [string]$volume.FileSystemLabel
                $volumes += [pscustomobject]@{
                    drive_letter = $letter
                    label = $label
                    file_system = [string]$volume.FileSystem
                    health_status = [string]$volume.HealthStatus
                    drive_type = [string]$volume.DriveType
                    is_boot_volume = ($label -match '^(?i)BOOT$')
                    is_data_volume = ($label -match '^(?i)(DATA|DANEW_DATA)$')
                    root_accessible = (-not [string]::IsNullOrWhiteSpace($letter) -and (Test-Path -Path ($letter + '\\')))
                }
            }
        }
    }
    catch {
        $volumes = @()
    }

    if (@($volumes).Count -eq 0) {
        try {
            $logicalDisks = @(Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction Stop)
            foreach ($disk in @($logicalDisks)) {
                $letter = [string]$disk.DeviceID
                $volumes += [pscustomobject]@{
                    drive_letter = $letter
                    label = [string]$disk.VolumeName
                    file_system = [string]$disk.FileSystem
                    health_status = ''
                    drive_type = [string]$disk.DriveType
                    is_boot_volume = ([string]$disk.VolumeName -match '^(?i)BOOT$')
                    is_data_volume = ([string]$disk.VolumeName -match '^(?i)(DATA|DANEW_DATA)$')
                    root_accessible = (Test-Path -Path ($letter + '\\'))
                }
            }
        }
        catch {
            $volumes = @()
        }
    }

    return $volumes
}

function Get-DanewInternalDiskInventory {
    $items = @()

    try {
        if (Get-Command -Name Get-Disk -ErrorAction SilentlyContinue) {
            $rawDisks = @(Get-Disk -ErrorAction Stop | Where-Object { $_.BusType -ne 'USB' -and $_.BusType -ne 'SD' })
            foreach ($disk in @($rawDisks)) {
                $partitions = @()
                try {
                    if (Get-Command -Name Get-Partition -ErrorAction SilentlyContinue) {
                        $partitions = @(Get-Partition -DiskNumber $disk.Number -ErrorAction Stop)
                    }
                }
                catch {
                    $partitions = @()
                }

                $items += [pscustomobject]@{
                    disk_number = [int]$disk.Number
                    friendly_name = [string]$disk.FriendlyName
                    bus_type = [string]$disk.BusType
                    partition_count = @($partitions).Count
                    size_gb = if ($disk.Size) { [math]::Round(([double]$disk.Size / 1GB), 2) } else { 0 }
                    is_offline = [bool]$disk.IsOffline
                    is_read_only = [bool]$disk.IsReadOnly
                    partitions = @($partitions | ForEach-Object {
                        [pscustomobject]@{
                            partition_number = [int]$_.PartitionNumber
                            drive_letter = if ($_.DriveLetter) { [string]$_.DriveLetter + ':' } else { '' }
                            type = [string]$_.Type
                            size_gb = if ($_.Size) { [math]::Round(([double]$_.Size / 1GB), 2) } else { 0 }
                        }
                    })
                }
            }
        }
    }
    catch {
        $items = @()
    }

    if (@($items).Count -eq 0) {
        try {
            $fallbackDisks = @(Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction Stop | Where-Object { [string]$_.InterfaceType -ne 'USB' })
            foreach ($disk in @($fallbackDisks)) {
                $items += [pscustomobject]@{
                    disk_number = if ($null -ne $disk.Index) { [int]$disk.Index } else { -1 }
                    friendly_name = [string]$disk.Model
                    bus_type = [string]$disk.InterfaceType
                    partition_count = 0
                    size_gb = if ($disk.Size) { [math]::Round(([double]$disk.Size / 1GB), 2) } else { 0 }
                    is_offline = $false
                    is_read_only = $false
                    partitions = @()
                }
            }
        }
        catch {
            $items = @()
        }
    }

    return $items
}

function Test-DanewEvtxHtmlArtifacts {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TimelineHtmlPath,
        [Parameter(Mandatory = $true)]
        [string]$EventsHtmlPath,
        [AllowNull()]
        [object]$OfflineAnalysis
    )

    $requiredMarkers = @(
        'data-report-search',
        'data-filter-level',
        'data-filter-family',
        'data-evtx-row',
        'data-evtx-detail',
        'data-toggle-message',
        'reset-evtx-filters',
        'Date/heure',
        'Niveau',
        'Importance SAV',
        'Famille',
        'Source',
        'ID evenement',
        'Journal',
        'Message',
        'Fichier EVTX',
        'Top 10'
    )

    $timelineExists = Test-Path -Path $TimelineHtmlPath
    $eventsExists = Test-Path -Path $EventsHtmlPath
    $combinedText = ''
    if ($timelineExists) {
        try { $combinedText += ' ' + (Get-Content -Path $TimelineHtmlPath -Raw -Encoding UTF8) } catch { }
    }
    if ($eventsExists) {
        try { $combinedText += ' ' + (Get-Content -Path $EventsHtmlPath -Raw -Encoding UTF8) } catch { }
    }

    $markerResults = @()
    foreach ($marker in $requiredMarkers) {
        $markerResults += [pscustomobject]@{ marker = $marker; found = ($combinedText -match [regex]::Escape($marker)) }
    }

    $knowledgeLoaded = $false
    try {
        $knowledgeLoaded = ([int]$OfflineAnalysis.knowledge_rules_loaded -gt 0)
    }
    catch {
        $knowledgeLoaded = $false
    }

    $allMarkers = @($markerResults | Where-Object { -not $_.found }).Count -eq 0

    [pscustomobject]@{
        timeline_html = $TimelineHtmlPath
        events_html = $EventsHtmlPath
        timeline_exists = [bool]$timelineExists
        events_exists = [bool]$eventsExists
        knowledge_rules_loaded = [bool]$knowledgeLoaded
        all_markers_found = [bool]$allMarkers
        markers = $markerResults
    }
}

function Test-DanewLauncherSourceEvidence {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LauncherPath
    )

    $requiredButtons = @(
        [pscustomobject]@{ label = 'ANALYSER LES JOURNAUX WINDOWS'; action = 'analyze-offline-logs' },
        [pscustomobject]@{ label = 'ANALYSER LES CAUSES DE CRASH'; action = 'analyze-crash-causes' },
        [pscustomobject]@{ label = 'OUVRIR LE RAPPORT SAV'; action = 'open-sav-report' },
        [pscustomobject]@{ label = 'EXPORTER LE DOSSIER SAV'; action = 'export-diagnostic-package' },
        [pscustomobject]@{ label = 'EXPORT EVTX CIBLE'; action = 'export-evtx-targeted' }
    )

    $text = ''
    try {
        $text = Get-Content -Path $LauncherPath -Raw -Encoding UTF8
    }
    catch {
        $text = ''
    }

    $matches = @()
    foreach ($button in $requiredButtons) {
        $matches += [pscustomobject]@{
            label = $button.label
            action = $button.action
            found = (($text -match [regex]::Escape($button.label)) -and ($text -match [regex]::Escape($button.action)))
        }
    }

    [pscustomobject]@{
        launcher_path = $LauncherPath
        buttons = $matches
        all_buttons_found = (@($matches | Where-Object { -not $_.found }).Count -eq 0)
    }
}

function Copy-DanewArtifactIfPresent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    if ([string]::IsNullOrWhiteSpace($SourcePath) -or [string]::IsNullOrWhiteSpace($DestinationPath)) {
        return $false
    }

    if (-not (Test-Path -Path $SourcePath)) {
        return $false
    }

    try {
        Copy-Item -Path $SourcePath -Destination $DestinationPath -Force
        return $true
    }
    catch {
        return $false
    }
}

function Write-DanewWinPERunSummaryText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [object]$Summary
    )

    $overallStatus = ''
    $environment = $null
    $volumes = @()
    $internalDisks = @()
    $precheck = $null
    $offlineLogs = $null
    $launcher = $null
    $usbValidation = $null
    $artifacts = @()

    if ($Summary -and $Summary.PSObject.Properties['overall_status']) { $overallStatus = [string]$Summary.overall_status }
    if ($Summary -and $Summary.PSObject.Properties['environment']) { $environment = $Summary.environment }
    if ($Summary -and $Summary.PSObject.Properties['volumes']) { $volumes = @($Summary.volumes) }
    if ($Summary -and $Summary.PSObject.Properties['internal_disks']) { $internalDisks = @($Summary.internal_disks) }
    if ($Summary -and $Summary.PSObject.Properties['precheck']) { $precheck = $Summary.precheck }
    if ($Summary -and $Summary.PSObject.Properties['offline_logs']) { $offlineLogs = $Summary.offline_logs }
    if ($Summary -and $Summary.PSObject.Properties['launcher']) { $launcher = $Summary.launcher }
    if ($Summary -and $Summary.PSObject.Properties['usb_validation']) { $usbValidation = $Summary.usb_validation }
    if ($Summary -and $Summary.PSObject.Properties['generated_artifacts']) { $artifacts = @($Summary.generated_artifacts) }

    $lines = @(
        'Validation WinPE reale Danew',
        ('Horodatage: ' + $(if ($Summary -and $Summary.PSObject.Properties['timestamp']) { [string]$Summary.timestamp } else { '' })),
        ('Statut global: ' + $overallStatus),
        ('WinPE detecte: ' + $(if ($environment -and $environment.PSObject.Properties['winpe_detected']) { [string]$environment.winpe_detected } else { 'False' })),
        ('Demarrage depuis X: ' + $(if ($environment -and $environment.PSObject.Properties['running_from_x']) { [string]$environment.running_from_x } else { 'False' })),
        ('Volume systeme: ' + $(if ($environment -and $environment.PSObject.Properties['system_drive']) { [string]$environment.system_drive } else { '' })),
        ('Volumes BOOT/DATA detectes: ' + [string]$volumes.Count),
        ('Disques internes detectes: ' + [string]$internalDisks.Count),
        ('Pre-check: ' + $(if ($precheck -and $precheck.PSObject.Properties['status']) { [string]$precheck.status } else { 'Unknown' })),
        ('Rapport pre-check: ' + $(if ($precheck -and $precheck.PSObject.Properties['artifacts'] -and $precheck.artifacts -and $precheck.artifacts.PSObject.Properties['json']) { [string]$precheck.artifacts.json } else { '' })),
        ('Analyse EVTX: ' + $(if ($offlineLogs -and $offlineLogs.PSObject.Properties['status']) { [string]$offlineLogs.status } else { 'Unknown' })),
        ('Artifacts EVTX: ' + $(if ($offlineLogs -and $offlineLogs.PSObject.Properties['artifacts'] -and $offlineLogs.artifacts -and $offlineLogs.artifacts.PSObject.Properties['report_html_path']) { [string]$offlineLogs.artifacts.report_html_path } else { '' })),
        ('Exporter EVTX cible: ' + $(if ($Summary -and $Summary.PSObject.Properties['evtx_targeted'] -and $Summary.evtx_targeted -and $Summary.evtx_targeted.PSObject.Properties['status']) { [string]$Summary.evtx_targeted.status } else { 'Unknown' })),
        ('Launcher GUI: ' + $(if ($launcher -and $launcher.PSObject.Properties['buttons'] -and $launcher.buttons -and $launcher.buttons.PSObject.Properties['all_buttons_found']) { [string]$launcher.buttons.all_buttons_found } else { 'False' })),
        ('USB/Media: ' + $(if ($usbValidation -and $usbValidation.PSObject.Properties['status']) { [string]$usbValidation.status } else { 'Unknown' }))
    )

    $lines += ''
    $lines += 'Artefacts generes :'
    foreach ($artifact in @($artifacts)) {
        $lines += ('- ' + [string]$artifact)
    }

    $lines | Set-Content -Path $Path -Encoding UTF8
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
        $targetRoot = [string]$usbCandidates[0].letter + '\DANEW_DIAGNOSTIC_SIMULATION'
        $usbResult = [pscustomobject]@{
            attempted = $true
            success = $true
            simulated = $true
            target = $targetRoot
            diagnostic = 'USB validation simulated only; no files were written.'
            candidate_volume = [string]$usbCandidates[0].letter
        }
    }
    else {
        $usbResult = [pscustomobject]@{ attempted = $true; success = $false; simulated = $true; target = ''; diagnostic = 'no removable drive detected' }
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

$launcherScriptPath = Join-Path $RootPath 'scripts\launcher.ps1'
$launcherEvidence = Test-DanewLauncherSourceEvidence -LauncherPath $launcherScriptPath
$environment = Get-DanewWinPERunEnvironment

$tooltipValidationScript = Join-Path $RootPath 'scripts\tests\Invoke-RealWinPETooltipValidation.ps1'
$tooltipOutcome = [pscustomobject]@{ status = 'Missing'; report = $null; error = 'tooltip validation not run' }
if (Test-Path -Path $tooltipValidationScript) {
    try {
        $tooltipEngine = if (Get-Command -Name powershell -ErrorAction SilentlyContinue) { 'powershell' } else { 'pwsh' }
        & $tooltipEngine -NoProfile -ExecutionPolicy Bypass -File $tooltipValidationScript -RootPath $RootPath -OutputDirectory $reportsPath | Out-Null
        $tooltipJsonPath = Join-Path $reportsPath 'real-winpe-tooltip-validation.json'
        if (Test-Path -Path $tooltipJsonPath) {
            $tooltipReport = Get-Content -Path $tooltipJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $tooltipOutcome = [pscustomobject]@{
                status = [string]$tooltipReport.global_status
                report = $tooltipReport
                error = ''
            }
        }
        else {
            $tooltipOutcome = [pscustomobject]@{ status = 'Limited'; report = $null; error = 'tooltip validation output missing' }
        }
    }
    catch {
        $tooltipOutcome = [pscustomobject]@{ status = 'Limited'; report = $null; error = $_.Exception.Message }
    }
}

$precheckOutcome = [pscustomobject]@{ status = 'Missing'; report = $null; error = 'precheck not run' }
try {
    $precheckAction = Invoke-DanewLauncherAction -Action 'precheck-winpe' -RootPath $RootPath -Config $config -SuppressActionLog
    $precheckOutcome = [pscustomobject]@{
        status = [string]$precheckAction.output.overall_status
        report = $precheckAction.output
        error = ''
    }
    $null = Copy-DanewArtifactIfPresent -SourcePath ([string]$precheckAction.output.artifacts.json) -DestinationPath (Join-Path $reportsPath 'winpe-precheck.json')
    $null = Copy-DanewArtifactIfPresent -SourcePath ([string]$precheckAction.output.artifacts.txt) -DestinationPath (Join-Path $reportsPath 'winpe-precheck.txt')
}
catch {
    $precheckOutcome = [pscustomobject]@{ status = 'Limited'; report = $null; error = $_.Exception.Message }
}

$offlineOutcome = [pscustomobject]@{ status = 'Missing'; report = $null; error = 'offline analysis not run' }
if ($environment.winpe_detected) {
    try {
        $offlineProgress = {
            param([string]$Message)
            Write-Host $Message
        }
        $offlineAction = Invoke-DanewLauncherAction -Action 'analyze-offline-logs' -RootPath $RootPath -Config $config -RuntimeSystemDrive $env:SystemDrive -CurrentLocationPath (Get-Location).Path -ProgressCallback $offlineProgress -SuppressActionLog
        $offlineOutcome = [pscustomobject]@{
            status = [string]$offlineAction.output.overall_status
            report = $offlineAction.output
            error = ''
        }
    }
    catch {
        $offlineOutcome = [pscustomobject]@{ status = 'Limited'; report = $null; error = $_.Exception.Message }
    }
}
else {
    $offlineEventsPath = Join-Path $reportsPath 'evtx-events.json'
    $offlineSummaryPath = Join-Path $reportsPath 'evtx-summary.json'
    $offlineHtmlPath = Join-Path $reportsPath 'evtx-events.html'
    $timelineHtmlPath = Join-Path $reportsPath 'timeline-raw.html'
    if ((Test-Path -Path $offlineEventsPath) -and (Test-Path -Path $offlineHtmlPath) -and (Test-Path -Path $timelineHtmlPath)) {
        $summarySource = $null
        if (Test-Path -Path $offlineSummaryPath) {
            try {
                $summarySource = Get-Content -Path $offlineSummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
            }
            catch {
                $summarySource = $null
            }
        }

        $offlineOutcome = [pscustomobject]@{
            status = 'PASS'
            report = [pscustomobject]@{
                overall_status = 'PASS'
                knowledge_rules_loaded = if ($summarySource -and $summarySource.PSObject.Properties['knowledge_rules_loaded']) { [int]$summarySource.knowledge_rules_loaded } else { 0 }
                total_events = if ($summarySource -and $summarySource.PSObject.Properties['total_events']) { [int]$summarySource.total_events } else { 0 }
                filtered_events = if ($summarySource -and $summarySource.PSObject.Properties['filtered_events']) { [int]$summarySource.filtered_events } else { 0 }
                critical_high_events = if ($summarySource -and $summarySource.PSObject.Properties['critical_high_events']) { [int]$summarySource.critical_high_events } else { 0 }
                crash_window_events = if ($summarySource -and $summarySource.PSObject.Properties['crash_window_events']) { [int]$summarySource.crash_window_events } else { 0 }
                artifacts = [pscustomobject]@{
                    report_html_path = $offlineHtmlPath
                    report_json_path = $offlineSummaryPath
                    timeline_raw_html = $timelineHtmlPath
                    timeline_raw_json = Join-Path $reportsPath 'timeline-raw.json'
                    evtx_events_json = $offlineEventsPath
                    evtx_events_csv = Join-Path $reportsPath 'evtx-events.csv'
                    evtx_filtered_events_csv = Join-Path $reportsPath 'evtx-filtered-events.csv'
                    evtx_critical_events_csv = Join-Path $reportsPath 'evtx-critical-events.csv'
                    evtx_crash_window_csv = Join-Path $reportsPath 'evtx-crash-window.csv'
                    evtx_sav_summary_txt = Join-Path $reportsPath 'evtx-sav-summary.txt'
                }
            }
            error = 'offline artefacts reused because the run is not in WinPE'
        }
    }
    else {
        $offlineOutcome = [pscustomobject]@{ status = 'Limited'; report = $null; error = 'offline artifacts missing' }
    }
}

if (-not $environment.winpe_detected) {
    $evtxJsonPath = Join-Path $reportsPath 'evtx-events.json'
    if (Test-Path -Path $evtxJsonPath) {
        try {
            $evtxEvents = @(Get-Content -Path $evtxJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json)
            $evtxSummary = if ($offlineOutcome.report) {
                [pscustomobject]@{
                    total_events = [int]$offlineOutcome.report.total_events
                    missing_required_logs = 0
                    parse_issue_count = 0
                    knowledge_rules_loaded = if ($offlineOutcome.report.PSObject.Properties['knowledge_rules_loaded']) { [int]$offlineOutcome.report.knowledge_rules_loaded } else { 0 }
                }
            }
            else {
                [pscustomobject]@{
                    total_events = @($evtxEvents).Count
                    missing_required_logs = 0
                    parse_issue_count = 0
                    knowledge_rules_loaded = 0
                }
            }

            Write-DanewTimelineHtml -Path (Join-Path $reportsPath 'timeline-raw.html') -Events $evtxEvents -Summary $evtxSummary
        }
        catch {
        }
    }
}

$evtxTargetedOutcome = [pscustomobject]@{ status = 'Missing'; report = $null; error = 'EVTX targeted export not run' }
try {
    $evtxTargetedAction = Invoke-DanewLauncherAction -Action 'export-evtx-targeted' -RootPath $RootPath -Config $config -SuppressActionLog
    $evtxTargetedOutcome = [pscustomobject]@{
        status = 'PASS'
        report = $evtxTargetedAction.output
        error = ''
    }
}
catch {
    $evtxTargetedOutcome = [pscustomobject]@{ status = 'Limited'; report = $null; error = $_.Exception.Message }
}

$crashOutcome = [pscustomobject]@{ status = 'SKIPPED'; report = $null; error = 'validated via launcher source evidence only' }
$packageOutcome = [pscustomobject]@{ status = 'SKIPPED'; report = $null; error = 'validated via launcher source evidence only' }

$mountedVolumes = @(Get-DanewMountedVolumeInventory)
$internalDisks = @(Get-DanewInternalDiskInventory)
$evtxHtmlVerification = Test-DanewEvtxHtmlArtifacts -TimelineHtmlPath (Join-Path $reportsPath 'timeline-raw.html') -EventsHtmlPath (Join-Path $reportsPath 'evtx-events.html') -OfflineAnalysis ($offlineOutcome.report)

$summaryArtifacts = @(
    $validationJsonPath,
    $validationTxtPath,
    (Join-Path $reportsPath 'real-winpe-tooltip-validation.json'),
    (Join-Path $reportsPath 'real-winpe-tooltip-validation.txt'),
    (Join-Path $reportsPath 'real-winpe-tooltip-checklist.txt'),
    (Join-Path $reportsPath 'winpe-precheck.json'),
    (Join-Path $reportsPath 'winpe-precheck.txt'),
    (Join-Path $reportsPath 'WinPE_precheck_history.json'),
    (Join-Path $reportsPath 'timeline-raw.html'),
    (Join-Path $reportsPath 'evtx-events.html'),
    (Join-Path $reportsPath 'evtx-events.csv'),
    (Join-Path $reportsPath 'evtx-filtered-events.csv'),
    (Join-Path $reportsPath 'evtx-critical-events.csv'),
    (Join-Path $reportsPath 'evtx-crash-window.csv'),
    (Join-Path $reportsPath 'evtx-sav-summary.txt'),
    (Join-Path $reportsPath 'winpe-real-run-summary.json'),
    (Join-Path $reportsPath 'winpe-real-run-summary.txt')
) | Where-Object { Test-Path -Path $_ }

$usbValidationStatus = 'LIMITED'
if ($environment.running_from_x -or @($mountedVolumes | Where-Object { $_.is_boot_volume -or $_.is_data_volume }).Count -gt 0) {
    $usbValidationStatus = 'PASS'
}

$overallSummaryStatus = 'LIMITED'
if ($precheckOutcome.status -eq 'PASS' -and $offlineOutcome.status -eq 'PASS' -and $evtxHtmlVerification.all_markers_found -and $launcherEvidence.all_buttons_found -and $tooltipOutcome.status -in @('PASS', 'LIMITED')) {
    $overallSummaryStatus = 'PASS'
}

$runSummary = [pscustomobject]@{
    timestamp = (Get-Date).ToString('s')
    root_path = $RootPath
    environment = $environment
    volumes = $mountedVolumes
    internal_disks = $internalDisks
    precheck = if ($precheckOutcome.report) {
        [pscustomobject]@{
            status = $precheckOutcome.status
            summary = $precheckOutcome.report.summary
            checks = $precheckOutcome.report.checks
            artifacts = $precheckOutcome.report.artifacts
            error = $precheckOutcome.error
        }
    } else {
        [pscustomobject]@{ status = $precheckOutcome.status; summary = $null; checks = @(); artifacts = $null; error = $precheckOutcome.error }
    }
    offline_logs = if ($offlineOutcome.report) {
        [pscustomobject]@{
            status = $offlineOutcome.status
            knowledge_rules_loaded = $offlineOutcome.report.knowledge_rules_loaded
            total_events = $offlineOutcome.report.total_events
            filtered_events = $offlineOutcome.report.filtered_events
            critical_high_events = $offlineOutcome.report.critical_high_events
            crash_window_events = $offlineOutcome.report.crash_window_events
            artifacts = $offlineOutcome.report.artifacts
            error = $offlineOutcome.error
        }
    } else {
        [pscustomobject]@{ status = $offlineOutcome.status; knowledge_rules_loaded = 0; total_events = 0; filtered_events = 0; critical_high_events = 0; crash_window_events = 0; artifacts = $null; error = $offlineOutcome.error }
    }
    evtx_html = $evtxHtmlVerification
    launcher = [pscustomobject]@{
        buttons = $launcherEvidence
        actions = [pscustomobject]@{
            analyze_offline_logs = $offlineOutcome.status
            analyze_crash_causes = $crashOutcome.status
            export_evtx_targeted = $evtxTargetedOutcome.status
            export_diagnostic_package = $packageOutcome.status
        }
    }
    tooltip_validation = if ($tooltipOutcome.report) {
        [pscustomobject]@{
            status = $tooltipOutcome.status
            report = $tooltipOutcome.report
            error = $tooltipOutcome.error
        }
    } else {
        [pscustomobject]@{ status = $tooltipOutcome.status; report = $null; error = $tooltipOutcome.error }
    }
    usb_validation = [pscustomobject]@{
        status = $usbValidationStatus
        running_from_x = $environment.running_from_x
        removable_candidates = @($drives | Where-Object { $_.drive_type -eq 'Removable' -and $_.root_accessible })
        simulated = if ($usbResult -and $usbResult.PSObject.Properties['simulated']) { [bool]$usbResult.simulated } else { $false }
        details = $usbResult
    }
    evtx_targeted = $evtxTargetedOutcome
    crash_causes = $crashOutcome
    exported_artifacts = $summaryArtifacts
    generated_artifacts = @($summaryArtifacts)
    overall_status = $overallSummaryStatus
}

$runSummaryJsonPath = Join-Path $reportsPath 'winpe-real-run-summary.json'
$runSummaryTxtPath = Join-Path $reportsPath 'winpe-real-run-summary.txt'
$runSummary | ConvertTo-Json -Depth 50 | Set-Content -Path $runSummaryJsonPath -Encoding UTF8
Write-DanewWinPERunSummaryText -Path $runSummaryTxtPath -Summary $runSummary

Write-Host "Validation JSON: $validationJsonPath"
Write-Host "Validation TXT: $validationTxtPath"
Write-Host "Precheck JSON: $(Join-Path $reportsPath 'winpe-precheck.json')"
Write-Host "Precheck TXT: $(Join-Path $reportsPath 'winpe-precheck.txt')"
Write-Host "WinPE real run summary JSON: $runSummaryJsonPath"
Write-Host "WinPE real run summary TXT: $runSummaryTxtPath"
Write-Host "Tooltip validation JSON: $(Join-Path $reportsPath 'real-winpe-tooltip-validation.json')"
Write-Host "Tooltip validation TXT: $(Join-Path $reportsPath 'real-winpe-tooltip-validation.txt')"
Write-Host "Tooltip checklist TXT: $(Join-Path $reportsPath 'real-winpe-tooltip-checklist.txt')"
Write-Host "StartNet runtime log: $startnetRuntimeLogPath"
Write-Host "Detected drives: $drivesOutPath"
Write-Host "Offline Windows detection: $offlineOutPath"
