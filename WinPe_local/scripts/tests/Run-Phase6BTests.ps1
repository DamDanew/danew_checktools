[CmdletBinding()]
param(
    [string]$RootPath,
    [string]$OutputDirectory
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

function Add-Phase6BResult {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Details = ''
    )

    return [pscustomobject]@{ name = $Name; passed = $Passed; details = $Details }
}

function New-Phase6BTestRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath
    )

    $tempRoot = Join-Path $BasePath 'temp\phase6b-tests'
    if (Test-Path -Path $tempRoot) {
        Remove-Item -Path $tempRoot -Recurse -Force
    }

    New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null
    foreach ($folder in @('scripts', 'reports', 'logs')) {
        New-Item -Path (Join-Path $tempRoot $folder) -ItemType Directory -Force | Out-Null
    }

    Copy-Item -Path (Join-Path $BasePath 'scripts\*') -Destination (Join-Path $tempRoot 'scripts') -Recurse -Force

    $cfgPath = Join-Path $tempRoot 'scripts\launcher-config.json'
    $cfg = Get-Content -Path (Join-Path $BasePath 'scripts\launcher-config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $cfg.input_path = 'offline-lab'
    $cfg.reports_path = 'reports'
    $cfg.logs_path = 'logs'
    $cfg.launcher_log_path = 'logs/launcher-log.json'
    $cfg.gui_status_snapshot_path = 'reports/gui-status-snapshot.json'
    $cfg | ConvertTo-Json -Depth 20 | Set-Content -Path $cfgPath -Encoding UTF8

    return [pscustomobject]@{
        root = $tempRoot
        config_path = $cfgPath
        reports_path = (Join-Path $tempRoot 'reports')
        logs_path = (Join-Path $tempRoot 'logs')
    }
}

function New-Phase6BRecord {
    param(
        [string]$Timestamp,
        [string]$Provider,
        [int]$EventId,
        [string]$Message,
        [string]$Channel = 'System'
    )

    return [pscustomobject]@{
        timestamp = $Timestamp
        provider = $Provider
        event_id = $EventId
        channel = $Channel
        message = $Message
        source_file = 'System.evtx'
        installation_root = 'offline-lab\install-1'
    }
}

function Write-Phase6BArtifacts {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ReportsPath,
        [AllowEmptyCollection()]
        [Parameter(Mandatory = $true)]
        [object[]]$Records,
        [Parameter(Mandatory = $true)]
        [object]$OfflineAnalysis,
        [Parameter(Mandatory = $true)]
        [object]$StorageDiagnostics,
        [Parameter(Mandatory = $true)]
        [object]$BitLockerAnalysis,
        [Parameter(Mandatory = $true)]
        [object]$TimelineRaw
    )

    @($Records) | ConvertTo-Json -Depth 20 | Set-Content -Path (Join-Path $ReportsPath 'evtx-events.json') -Encoding UTF8
    $OfflineAnalysis | ConvertTo-Json -Depth 20 | Set-Content -Path (Join-Path $ReportsPath 'offline-windows-analysis.json') -Encoding UTF8
    $StorageDiagnostics | ConvertTo-Json -Depth 20 | Set-Content -Path (Join-Path $ReportsPath 'storage-diagnostics.json') -Encoding UTF8
    $BitLockerAnalysis | ConvertTo-Json -Depth 20 | Set-Content -Path (Join-Path $ReportsPath 'bitlocker-analysis.json') -Encoding UTF8
    $TimelineRaw | ConvertTo-Json -Depth 20 | Set-Content -Path (Join-Path $ReportsPath 'timeline-raw.json') -Encoding UTF8
}

function Invoke-Phase6BCase {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,
        [AllowEmptyCollection()]
        [Parameter(Mandatory = $true)]
        [object[]]$Records,
        [Parameter(Mandatory = $true)]
        [object]$OfflineAnalysis,
        [Parameter(Mandatory = $true)]
        [object]$StorageDiagnostics,
        [Parameter(Mandatory = $true)]
        [object]$BitLockerAnalysis
    )

    $timelineRaw = [pscustomobject]@{
        timestamp = (Get-Date).ToString('s')
        events = @($Records)
        issues = @()
    }

    Write-Phase6BArtifacts -ReportsPath $Config.reports_path -Records $Records -OfflineAnalysis $OfflineAnalysis -StorageDiagnostics $StorageDiagnostics -BitLockerAnalysis $BitLockerAnalysis -TimelineRaw $timelineRaw

    $offlineStub = [pscustomobject]@{
        artifacts = [pscustomobject]@{
            evtx_events_json = (Join-Path $Config.reports_path 'evtx-events.json')
            offline_windows_analysis = (Join-Path $Config.reports_path 'offline-windows-analysis.json')
            storage_diagnostics = (Join-Path $Config.reports_path 'storage-diagnostics.json')
            bitlocker_analysis = (Join-Path $Config.reports_path 'bitlocker-analysis.json')
            timeline_raw_json = (Join-Path $Config.reports_path 'timeline-raw.json')
        }
    }

    return Invoke-DanewCrashCauseAnalysis -RootPath $Config.root_path -Config $Config -OfflineAnalysis $offlineStub
}

$results = @()
$temp = New-Phase6BTestRoot -BasePath $RootPath

try {
    . (Join-Path $temp.root 'scripts\launcher\LauncherCore.ps1')

    $config = Get-DanewLauncherConfig -RootPath $temp.root -ConfigPath $temp.config_path
    Initialize-DanewLauncherPaths -Config $config
    $config | Add-Member -NotePropertyName root_path -NotePropertyValue $temp.root -Force

    $baseStorage = [pscustomobject]@{ probable_causes = @(); evidence = @(); diagnostics_confidence = 'Low'; quality_score = 0 }
    $baseBitLocker = [pscustomobject]@{ volumes = @(); summary = [pscustomobject]@{ locked_or_protected_count = 0; volume_count = 0; metadata_unavailable_count = 0 } }
    $baseOffline = [pscustomobject]@{ warning_count = 0; detection_confidence = 'High' }

    $case1 = Invoke-Phase6BCase -Config $config -Records @(
        (New-Phase6BRecord -Timestamp '2026-05-27T10:00:00' -Provider 'Microsoft-Windows-Kernel-Power' -EventId 41 -Message 'Kernel-Power unexpected shutdown'),
        (New-Phase6BRecord -Timestamp '2026-05-27T10:07:00' -Provider 'Microsoft-Windows-Kernel-Power' -EventId 41 -Message 'Kernel-Power unexpected shutdown'),
        (New-Phase6BRecord -Timestamp '2026-05-27T10:14:00' -Provider 'Microsoft-Windows-Kernel-Power' -EventId 41 -Message 'Kernel-Power unexpected shutdown')
    ) -OfflineAnalysis $baseOffline -StorageDiagnostics $baseStorage -BitLockerAnalysis $baseBitLocker
    $results += Add-Phase6BResult -Name 'repeated_Kernel-Power' -Passed ($case1.root_cause_analysis.primary_cause.cause -eq 'thermal / power instability') -Details ([string]$case1.root_cause_analysis.primary_cause.cause)

    $case2 = Invoke-Phase6BCase -Config $config -Records @(
        (New-Phase6BRecord -Timestamp '2026-05-27T14:22:00' -Provider 'Microsoft-Windows-WindowsUpdateClient' -EventId 19 -Message 'Windows Update installed successfully'),
        (New-Phase6BRecord -Timestamp '2026-05-27T14:31:00' -Provider 'Microsoft-Windows-DriverFrameworks-UserMode/Operational' -EventId 10110 -Message 'Driver framework failure after update'),
        (New-Phase6BRecord -Timestamp '2026-05-27T14:34:00' -Provider 'Microsoft-Windows-WER-SystemErrorReporting' -EventId 1001 -Message 'BugCheck 0x0000007E')
    ) -OfflineAnalysis $baseOffline -StorageDiagnostics $baseStorage -BitLockerAnalysis $baseBitLocker
    $results += Add-Phase6BResult -Name 'update_then_BSOD' -Passed ($case2.root_cause_analysis.primary_cause.cause -eq 'failed Windows Update') -Details ([string]$case2.root_cause_analysis.primary_cause.cause)

    $case3Storage = [pscustomobject]@{ probable_causes = @([pscustomobject]@{ cause = 'inaccessible NVMe controller'; confidence = 'High' }); evidence = @('NVMe not visible'); diagnostics_confidence = 'Medium'; quality_score = 70 }
    $case3 = Invoke-Phase6BCase -Config $config -Records @(
        (New-Phase6BRecord -Timestamp '2026-05-27T09:01:00' -Provider 'iaStorAC' -EventId 129 -Message 'Reset to device, \Device\RaidPort0, was issued.'),
        (New-Phase6BRecord -Timestamp '2026-05-27T09:03:00' -Provider 'Microsoft-Windows-WER-SystemErrorReporting' -EventId 1001 -Message 'INACCESSIBLE_BOOT_DEVICE (0x0000007B)')
    ) -OfflineAnalysis $baseOffline -StorageDiagnostics $case3Storage -BitLockerAnalysis $baseBitLocker
    $results += Add-Phase6BResult -Name 'inaccessible_boot_device' -Passed ($case3.root_cause_analysis.primary_cause.cause -eq 'Intel RST/VMD issue') -Details ([string]$case3.root_cause_analysis.primary_cause.cause)

    $case4Storage = [pscustomobject]@{ probable_causes = @([pscustomobject]@{ cause = 'corrupted NTFS filesystem'; confidence = 'High' }); evidence = @('NTFS corruption'); diagnostics_confidence = 'Medium'; quality_score = 70 }
    $case4 = Invoke-Phase6BCase -Config $config -Records @(
        (New-Phase6BRecord -Timestamp '2026-05-27T08:10:00' -Provider 'Ntfs' -EventId 55 -Message 'The file system structure on the disk is corrupt and unusable.'),
        (New-Phase6BRecord -Timestamp '2026-05-27T08:15:00' -Provider 'Disk' -EventId 7 -Message 'The device, \Device\Harddisk0, has a bad block.'),
        (New-Phase6BRecord -Timestamp '2026-05-27T08:17:00' -Provider 'Microsoft-Windows-WER-SystemErrorReporting' -EventId 1001 -Message 'BugCheck NTFS_FILE_SYSTEM')
    ) -OfflineAnalysis $baseOffline -StorageDiagnostics $case4Storage -BitLockerAnalysis $baseBitLocker
    $results += Add-Phase6BResult -Name 'NTFS_corruption_chain' -Passed ($case4.root_cause_analysis.primary_cause.cause -eq 'corrupted NTFS filesystem') -Details ([string]$case4.root_cause_analysis.primary_cause.cause)

    $case5Offline = [pscustomobject]@{ warning_count = 1; detection_confidence = 'Low' }
    $case5 = Invoke-Phase6BCase -Config $config -Records @() -OfflineAnalysis $case5Offline -StorageDiagnostics $baseStorage -BitLockerAnalysis $baseBitLocker
    $results += Add-Phase6BResult -Name 'missing_SYSTEM_hive' -Passed ($case5.root_cause_analysis.primary_cause.cause -eq 'inaccessible SYSTEM hive') -Details ([string]$case5.root_cause_analysis.primary_cause.cause)

    $case6 = Invoke-Phase6BCase -Config $config -Records @(
        (New-Phase6BRecord -Timestamp '2026-05-27T11:05:00' -Provider 'Microsoft-Windows-WHEA-Logger' -EventId 17 -Message 'A corrected hardware error has occurred.'),
        (New-Phase6BRecord -Timestamp '2026-05-27T11:07:00' -Provider 'Microsoft-Windows-WHEA-Logger' -EventId 18 -Message 'A fatal hardware error has occurred.'),
        (New-Phase6BRecord -Timestamp '2026-05-27T11:09:00' -Provider 'Microsoft-Windows-WHEA-Logger' -EventId 19 -Message 'Hardware error reported.')
    ) -OfflineAnalysis $baseOffline -StorageDiagnostics $baseStorage -BitLockerAnalysis $baseBitLocker
    $results += Add-Phase6BResult -Name 'WHEA_hardware_errors' -Passed ($case6.root_cause_analysis.primary_cause.cause -eq 'thermal instability') -Details ([string]$case6.root_cause_analysis.primary_cause.cause)

    $case7Storage = [pscustomobject]@{ probable_causes = @([pscustomobject]@{ cause = 'failing SSD'; confidence = 'High' }); evidence = @('Disk 7/51/153 pattern'); diagnostics_confidence = 'Medium'; quality_score = 70 }
    $case7Offline = [pscustomobject]@{ warning_count = 0; detection_confidence = 'Medium' }
    $case7 = Invoke-Phase6BCase -Config $config -Records @(
        (New-Phase6BRecord -Timestamp '2026-05-27T12:00:00' -Provider 'Disk' -EventId 7 -Message 'The device has a bad block.'),
        (New-Phase6BRecord -Timestamp '2026-05-27T12:04:00' -Provider 'Disk' -EventId 153 -Message 'I/O operation was retried.'),
        (New-Phase6BRecord -Timestamp '2026-05-27T12:08:00' -Provider 'Disk' -EventId 51 -Message 'An error was detected on device during a paging operation.')
    ) -OfflineAnalysis $case7Offline -StorageDiagnostics $case7Storage -BitLockerAnalysis $baseBitLocker
    $results += Add-Phase6BResult -Name 'storage_degradation' -Passed ($case7.root_cause_analysis.primary_cause.cause -eq 'failing SSD') -Details ([string]$case7.root_cause_analysis.primary_cause.cause)

    $case8 = Invoke-Phase6BCase -Config $config -Records @(
        (New-Phase6BRecord -Timestamp '2026-05-27T13:00:00' -Provider 'Microsoft-Windows-WindowsUpdateClient' -EventId 19 -Message 'Update applied.'),
        (New-Phase6BRecord -Timestamp '2026-05-27T13:04:00' -Provider 'iaStorAC' -EventId 129 -Message 'Reset to device, \Device\RaidPort0, was issued.'),
        (New-Phase6BRecord -Timestamp '2026-05-27T13:06:00' -Provider 'Microsoft-Windows-DriverFrameworks-KernelMode/Operational' -EventId 10111 -Message 'Driver framework error.'),
        (New-Phase6BRecord -Timestamp '2026-05-27T13:08:00' -Provider 'Microsoft-Windows-WER-SystemErrorReporting' -EventId 1001 -Message 'INACCESSIBLE_BOOT_DEVICE (0x0000007B)')
    ) -OfflineAnalysis $baseOffline -StorageDiagnostics $case3Storage -BitLockerAnalysis $baseBitLocker
    $results += Add-Phase6BResult -Name 'multiple_simultaneous_causes' -Passed ($case8.root_cause_analysis.primary_cause.cause -eq 'Intel RST/VMD issue') -Details ([string]$case8.root_cause_analysis.primary_cause.cause)

    $case9 = Invoke-Phase6BCase -Config $config -Records @(
        (New-Phase6BRecord -Timestamp '2026-05-27T15:00:00' -Provider 'Service Control Manager' -EventId 7045 -Message 'A service was installed in the system.')
    ) -OfflineAnalysis $baseOffline -StorageDiagnostics $baseStorage -BitLockerAnalysis $baseBitLocker
    $results += Add-Phase6BResult -Name 'malware_persistence' -Passed ($case9.root_cause_analysis.primary_cause.cause -eq 'security or malware persistence indicators') -Details ([string]$case9.root_cause_analysis.primary_cause.cause)

    $case10BitLocker = [pscustomobject]@{ volumes = @([pscustomobject]@{ mount_point = 'C:'; lock_status = 'Locked'; protection_status = 'On'; volume_status = 'FullyEncrypted'; encryption_percentage = 100 }) ; summary = [pscustomobject]@{ locked_or_protected_count = 1; volume_count = 1; metadata_unavailable_count = 0 } }
    $case10 = Invoke-Phase6BCase -Config $config -Records @() -OfflineAnalysis $baseOffline -StorageDiagnostics $baseStorage -BitLockerAnalysis $case10BitLocker
    $results += Add-Phase6BResult -Name 'BitLocker_lock' -Passed ($case10.root_cause_analysis.primary_cause.cause -eq 'BitLocker lock state') -Details ([string]$case10.root_cause_analysis.primary_cause.cause)

    $case11 = Invoke-Phase6BCase -Config $config -Records @(
        (New-Phase6BRecord -Timestamp '2026-05-27T16:00:00' -Provider 'Microsoft-Windows-WHEA-Logger' -EventId 17 -Message 'Corrected hardware error.'),
        (New-Phase6BRecord -Timestamp '2026-05-27T16:04:00' -Provider 'Microsoft-Windows-Kernel-Power' -EventId 41 -Message 'Unexpected shutdown.'),
        (New-Phase6BRecord -Timestamp '2026-05-27T16:08:00' -Provider 'Microsoft-Windows-Kernel-Power' -EventId 41 -Message 'Unexpected shutdown.')
    ) -OfflineAnalysis $baseOffline -StorageDiagnostics $baseStorage -BitLockerAnalysis $baseBitLocker
    $results += Add-Phase6BResult -Name 'thermal_shutdown_patterns' -Passed ($case11.root_cause_analysis.primary_cause.cause -eq 'thermal instability') -Details ([string]$case11.root_cause_analysis.primary_cause.cause)

    $case12 = Invoke-Phase6BCase -Config $config -Records @(
        (New-Phase6BRecord -Timestamp '2026-05-27T17:30:00' -Provider 'Custom-Log' -EventId 1234 -Message 'Unrelated informational record.')
    ) -OfflineAnalysis $baseOffline -StorageDiagnostics $baseStorage -BitLockerAnalysis $baseBitLocker
    $results += Add-Phase6BResult -Name 'partial_logs_only' -Passed ($case12.root_cause_analysis.primary_cause.cause -eq 'unclassified crash path') -Details ([string]$case12.root_cause_analysis.primary_cause.cause)
}
finally {
    if (Test-Path -Path $temp.root) {
        try {
            Remove-Item -Path $temp.root -Recurse -Force -ErrorAction Stop
        }
        catch {
        }
    }
}

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

$jsonPath = Join-Path $OutputDirectory 'phase6b-tests-report.json'
$txtPath = Join-Path $OutputDirectory 'phase6b-tests-report.txt'

$report | ConvertTo-Json -Depth 25 | Set-Content -Path $jsonPath -Encoding UTF8

$lines = @(
    'Phase 6B Tests',
    ('Total: ' + [string]$summary.total),
    ('Passed: ' + [string]$summary.passed),
    ('Failed: ' + [string]$summary.failed),
    ''
)
foreach ($t in @($results)) {
    $status = if ($t.passed) { 'PASS' } else { 'FAIL' }
    $lines += '[' + $status + '] ' + [string]$t.name + ' - ' + [string]$t.details
}
$lines | Set-Content -Path $txtPath -Encoding UTF8

Write-Host ('Phase 6B test report JSON: ' + $jsonPath)
Write-Host ('Phase 6B test report TXT: ' + $txtPath)

if ($summary.failed -gt 0) {
    exit 1
}
