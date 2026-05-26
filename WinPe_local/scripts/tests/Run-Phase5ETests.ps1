[CmdletBinding()]
param(
    [string]$RootPath = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $RootPath 'reports'
}

. (Join-Path $RootPath 'scripts\launcher\LauncherCore.ps1')

function Add-Phase5EResult {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Details = ''
    )

    [pscustomobject]@{ name = $Name; passed = $Passed; details = $Details }
}

function New-Phase5ETestRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath
    )

    $tempRoot = Join-Path $BasePath 'temp\phase5e-tests'
    if (Test-Path -Path $tempRoot) {
        Remove-Item -Path $tempRoot -Recurse -Force
    }

    New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $tempRoot 'scripts') -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $tempRoot 'reports') -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $tempRoot 'logs') -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $tempRoot 'offline-win\Windows') -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $tempRoot 'no-win') -ItemType Directory -Force | Out-Null

    $cfgPath = Join-Path $tempRoot 'scripts\launcher-config.json'
    $cfg = Get-Content -Path (Join-Path $BasePath 'scripts\launcher-config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $cfg.input_path = 'offline-win'
    $cfg.reports_path = 'reports'
    $cfg.logs_path = 'logs'
    $cfg.launcher_log_path = 'logs/launcher-log.json'
    $cfg.gui_status_snapshot_path = 'reports/gui-status-snapshot.json'
    $cfg.startnet_output_path = 'reports/StartNet.runtime.cmd'
    $cfg.startnet_fallback_output_path = 'reports/StartNet.fallback.cmd'
    $cfg | ConvertTo-Json -Depth 20 | Set-Content -Path $cfgPath -Encoding UTF8

    return [pscustomobject]@{
        root = $tempRoot
        config_path = $cfgPath
        reports = Join-Path $tempRoot 'reports'
        logs = Join-Path $tempRoot 'logs'
        offline_win = Join-Path $tempRoot 'offline-win'
        no_win = Join-Path $tempRoot 'no-win'
    }
}

function Write-LauncherLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [object[]]$Entries
    )

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    $Entries | ConvertTo-Json -Depth 20 | Set-Content -Path $Path -Encoding UTF8
}

function Write-ReportFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [object]$Content
    )

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    $Content | ConvertTo-Json -Depth 20 | Set-Content -Path $Path -Encoding UTF8
}

$results = @()
$temp = New-Phase5ETestRoot -BasePath $RootPath
$cfgResolved = Get-DanewLauncherConfig -RootPath $temp.root -ConfigPath $temp.config_path

try {
    $reportPath = Join-Path $temp.reports 'phase5e-last-report.json'
    Write-ReportFile -Path $reportPath -Content ([pscustomobject]@{ name = 'phase5e-last-report'; timestamp = (Get-Date).ToString('s') })

    Write-LauncherLog -Path (Join-Path $temp.logs 'launcher-log.json') -Entries @(
        [pscustomobject]@{ timestamp = '2026-05-26T10:00:00'; action = 'scan-winpe'; status = 'ok'; message = 'scan complete' },
        [pscustomobject]@{ timestamp = '2026-05-26T10:01:00'; action = 'generate-report'; status = 'ok'; message = 'report complete' }
    )

    $statusLocal = Invoke-DanewLauncherAction -Action 'refresh-status' -RootPath $temp.root -Config $cfgResolved -RuntimeSystemDrive 'C:' -CurrentLocationPath 'C:\' -SuppressActionLog
    $snapshotLocal = $statusLocal.output
    $snapshotPathLocal = Join-Path $temp.reports 'gui-status-snapshot.json'
    $snapshotLocalData = Get-Content -Path $snapshotPathLocal -Raw -Encoding UTF8 | ConvertFrom-Json
    $results += Add-Phase5EResult -Name 'local_mode_snapshot' -Passed (($snapshotLocal.runtime_mode -eq 'Local') -and ($snapshotLocalData.runtime_mode -eq 'Local')) -Details $snapshotLocal.runtime_mode
    $results += Add-Phase5EResult -Name 'offline_windows_yes' -Passed ($snapshotLocal.offline_windows_detected -eq 'Yes') -Details $snapshotLocal.offline_windows_detected
    $results += Add-Phase5EResult -Name 'last_action_from_log' -Passed (($snapshotLocal.last_action -eq 'generate-report') -and ($snapshotLocal.last_action_status -eq 'ok')) -Details ($snapshotLocal.last_action + ':' + $snapshotLocal.last_action_status)
    $results += Add-Phase5EResult -Name 'last_report_detected' -Passed ($snapshotLocal.last_report_path -eq $reportPath) -Details $snapshotLocal.last_report_path
    $results += Add-Phase5EResult -Name 'gui_status_snapshot_written' -Passed (Test-Path -Path $snapshotPathLocal) -Details $snapshotPathLocal

    $statusWinPe = Get-DanewLauncherStatusSnapshot -RootPath $temp.root -Config $cfgResolved -RuntimeSystemDrive 'X:' -CurrentLocationPath 'X:\Windows\System32'
    $results += Add-Phase5EResult -Name 'winpe_mode_simulation' -Passed ($statusWinPe.runtime_mode -eq 'WinPE') -Details $statusWinPe.runtime_mode

    $cfgMissingReports = Get-DanewLauncherConfig -RootPath $temp.root -ConfigPath $temp.config_path
    $cfgMissingReports = [pscustomobject]@{
        config_path = $cfgMissingReports.config_path
        input_path = $cfgMissingReports.input_path
        default_tier = $cfgMissingReports.default_tier
        reports_path = Join-Path $temp.root 'missing-reports'
        logs_path = $cfgMissingReports.logs_path
        launcher_log_path = $cfgMissingReports.launcher_log_path
        gui_status_snapshot_path = Join-Path $temp.root 'missing-reports\gui-status-snapshot.json'
        startnet_runtime_log_path = $cfgMissingReports.startnet_runtime_log_path
        startnet_template_path = $cfgMissingReports.startnet_template_path
        startnet_output_path = $cfgMissingReports.startnet_output_path
        startnet_fallback_output_path = $cfgMissingReports.startnet_fallback_output_path
    }
    $statusMissingReports = Get-DanewLauncherStatusSnapshot -RootPath $temp.root -Config $cfgMissingReports -RuntimeSystemDrive 'C:' -CurrentLocationPath 'C:\'
    $results += Add-Phase5EResult -Name 'missing_report_path' -Passed ($statusMissingReports.last_report_path -eq 'Unknown') -Details $statusMissingReports.last_report_path

    $cfgNoUsb = [pscustomobject]@{
        config_path = $cfgResolved.config_path
        input_path = $cfgResolved.input_path
        default_tier = $cfgResolved.default_tier
        reports_path = Join-Path $temp.root 'no-usb-reports'
        logs_path = $cfgResolved.logs_path
        launcher_log_path = Join-Path $temp.root 'no-usb-reports\launcher-log.json'
        gui_status_snapshot_path = Join-Path $temp.root 'no-usb-reports\gui-status-snapshot.json'
        startnet_runtime_log_path = $cfgResolved.startnet_runtime_log_path
        startnet_template_path = $cfgResolved.startnet_template_path
        startnet_output_path = $cfgResolved.startnet_output_path
        startnet_fallback_output_path = $cfgResolved.startnet_fallback_output_path
    }
    New-Item -Path $cfgNoUsb.reports_path -ItemType Directory -Force | Out-Null
    New-Item -Path $cfgNoUsb.logs_path -ItemType Directory -Force | Out-Null
    $statusNoUsb = Get-DanewLauncherStatusSnapshot -RootPath $temp.root -Config $cfgNoUsb -RuntimeSystemDrive 'C:' -CurrentLocationPath 'C:\'
    $results += Add-Phase5EResult -Name 'no_selected_usb_disk' -Passed ($statusNoUsb.selected_usb_disk -eq 'Unknown') -Details $statusNoUsb.selected_usb_disk

    $usbReportPath = Join-Path $temp.reports 'usb-export-report.json'
    Write-ReportFile -Path $usbReportPath -Content ([pscustomobject]@{ target_disk_number = 4; target_friendly_name = 'USB KEY'; status = 'PASS' })
    $statusUsb = Get-DanewLauncherStatusSnapshot -RootPath $temp.root -Config $cfgResolved -RuntimeSystemDrive 'C:' -CurrentLocationPath 'C:\'
    $results += Add-Phase5EResult -Name 'selected_usb_disk_present' -Passed ($statusUsb.selected_usb_disk -eq 'Disk 4') -Details $statusUsb.selected_usb_disk

    Write-LauncherLog -Path (Join-Path $temp.logs 'launcher-log.json') -Entries @(
        [pscustomobject]@{ timestamp = '2026-05-26T10:00:00'; action = 'scan-winpe'; status = 'ok'; message = 'scan complete' },
        [pscustomobject]@{ timestamp = '2026-05-26T10:02:00'; action = 'generate-report'; status = 'error'; message = 'report failed' }
    )
    $statusFailed = Get-DanewLauncherStatusSnapshot -RootPath $temp.root -Config $cfgResolved -RuntimeSystemDrive 'C:' -CurrentLocationPath 'C:\'
    $results += Add-Phase5EResult -Name 'failed_last_action' -Passed ($statusFailed.last_action_status -eq 'error') -Details $statusFailed.last_action_status

    $view = Invoke-DanewLauncherAction -Action 'view-last-report' -RootPath $temp.root -Config $cfgResolved -SuppressActionLog
    $expectedLatestReport = Get-DanewLauncherLatestReportPath -Config $cfgResolved
    $results += Add-Phase5EResult -Name 'view_last_report_action' -Passed ($view.output.path -eq $expectedLatestReport) -Details $view.output.path
}
finally {
    if (Test-Path -Path $temp.root) {
        Remove-Item -Path $temp.root -Recurse -Force
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

$jsonPath = Join-Path $OutputDirectory 'phase5e-tests-report.json'
$txtPath = Join-Path $OutputDirectory 'phase5e-tests-report.txt'

$report | ConvertTo-Json -Depth 20 | Set-Content -Path $jsonPath -Encoding UTF8

$lines = @(
    'Phase 5E Tests',
    "Total: $($summary.total)",
    "Passed: $($summary.passed)",
    "Failed: $($summary.failed)",
    ''
)
foreach ($t in $results) {
    $status = if ($t.passed) { 'PASS' } else { 'FAIL' }
    $lines += "[$status] $($t.name) - $($t.details)"
}
$lines | Set-Content -Path $txtPath -Encoding UTF8

Write-Host "Phase 5E test report JSON: $jsonPath"
Write-Host "Phase 5E test report TXT: $txtPath"

if ($summary.failed -gt 0) {
    exit 1
}
