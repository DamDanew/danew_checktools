[CmdletBinding()]
param(
    [string]$RootPath = (Split-Path -Parent $PSScriptRoot),
    [string]$ConfigPath,
    [switch]$Json,
    [string]$RuntimeSystemDrive,
    [ValidateSet('Interactive', 'scan-winpe', 'capability-analysis', 'generate-report', 'open-reports-folder', 'export-diagnostic-package', 'prepare-startnet', 'start-diagnostic', 'analyze-offline-logs', 'create-usb-media', 'real-winpe-validation', 'pre-real-boot-check', 'refresh-status', 'show-status', 'view-last-report', 'exit')]
    [string]$Command = 'Interactive'
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

$config = Get-DanewLauncherConfig -RootPath $RootPath -ConfigPath $ConfigPath
Write-DanewLauncherActionLog -Config $config -Action 'cli-launcher' -Status 'start' -Message 'CLI launcher started'

function Get-DanewCliStatusArtifactPath {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,
        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    if ([string]::IsNullOrWhiteSpace($Config.reports_path)) {
        return ''
    }

    return Join-Path $Config.reports_path $FileName
}

function Write-DanewCliStatusArtifacts {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Status,
        [Parameter(Mandatory = $true)]
        [object]$View,
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    $statusPath = Get-DanewCliStatusArtifactPath -Config $Config -FileName 'cli-status-snapshot.json'
    $reportRefPath = Get-DanewCliStatusArtifactPath -Config $Config -FileName 'cli-last-report-reference.json'

    if (-not [string]::IsNullOrWhiteSpace($statusPath)) {
        $Status | ConvertTo-Json -Depth 20 | Set-Content -Path $statusPath -Encoding UTF8
    }

    if (-not [string]::IsNullOrWhiteSpace($reportRefPath)) {
        [pscustomobject]@{
            timestamp = (Get-Date).ToString('s')
            last_report_path = [string]$Status.last_report_path
            selected_usb_disk = [string]$Status.selected_usb_disk
            offline_windows_detected = [string]$Status.offline_windows_detected
            view_opened = [bool]$View.opened
            view_path = [string]$View.path
            view_reason = [string]$View.reason
        } | ConvertTo-Json -Depth 20 | Set-Content -Path $reportRefPath -Encoding UTF8
    }

    return [pscustomobject]@{
        status_path = $statusPath
        report_reference_path = $reportRefPath
    }
}

function Get-DanewCliStatusResult {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ActionName,
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    $statusAction = if ($ActionName -eq 'show-status') { 'refresh-status' } else { 'refresh-status' }
    $effectiveDrive = $RuntimeSystemDrive
    if ([string]::IsNullOrWhiteSpace($effectiveDrive)) {
        $effectiveDrive = $env:SystemDrive
    }

    $statusResult = Invoke-DanewLauncherAction -Action $statusAction -RootPath $RootPath -Config $config -RuntimeSystemDrive $effectiveDrive -CurrentLocationPath (Get-Location).Path -SuppressActionLog
    $status = $statusResult.output
    $viewResult = [pscustomobject]@{ opened = $false; path = ''; reason = 'not requested' }
    if ($ActionName -eq 'view-last-report') {
        $viewAction = Invoke-DanewLauncherAction -Action 'view-last-report' -RootPath $RootPath -Config $config -SuppressActionLog
        $viewResult = $viewAction.output
    }

    $artifacts = Write-DanewCliStatusArtifacts -Status $status -View $viewResult -Config $Config
    return [pscustomobject]@{
        status = $status
        view = $viewResult
        artifacts = $artifacts
    }
}

function Format-DanewCliStatus {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Status,
        [Parameter(Mandatory = $true)]
        [object]$View,
        [string]$ActionName = 'show-status'
    )

    $lines = @(
        'Danew CLI Status',
        ('Current RootPath: ' + $Status.root_path),
        ('Runtime mode: ' + $Status.runtime_mode),
        ('Last action: ' + $Status.last_action),
        ('Last action status: ' + $Status.last_action_status),
        ('Last report path: ' + $Status.last_report_path),
        ('Selected USB disk: ' + $Status.selected_usb_disk),
        ('Offline Windows detected: ' + $Status.offline_windows_detected),
        ('Logs folder path: ' + $Status.logs_folder_path)
    )

    if ($ActionName -eq 'view-last-report') {
        $openedText = if ($View.opened) { 'Yes' } else { 'No' }
        $lines += ('Last report opened: ' + $openedText)
        $lines += ('Last report view path: ' + $View.path)
        $lines += ('Last report view reason: ' + $View.reason)
    }

    return $lines
}

function Write-DanewCliResult {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Result,
        [Parameter(Mandatory = $true)]
        [string]$ActionName
    )

    if ($Json) {
        $Result | ConvertTo-Json -Depth 20
        return
    }

    foreach ($line in (Format-DanewCliStatus -Status $Result.status -View $Result.view -ActionName $ActionName)) {
        Write-Host $line
    }
}

# Always prepare StartNet once when launcher starts.
$null = Invoke-DanewLauncherAction -Action 'prepare-startnet' -RootPath $RootPath -Config $config

function Invoke-DanewCliAction {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ActionName
    )

    $result = Invoke-DanewLauncherAction -Action $ActionName -RootPath $RootPath -Config $config
    Write-Host "Action: $($result.action)"
    Write-Host "Output: $($result.output | ConvertTo-Json -Depth 8 -Compress)"
}

function Invoke-DanewCliStatusCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ActionName
    )

    $result = Get-DanewCliStatusResult -ActionName $ActionName -RootPath $RootPath -Config $config
    Write-DanewCliResult -Result $result -ActionName $ActionName
}

function Invoke-DanewCliDiagnosticCommand {
    $effectiveDrive = $RuntimeSystemDrive
    if ([string]::IsNullOrWhiteSpace($effectiveDrive)) {
        $effectiveDrive = $env:SystemDrive
    }

    $progress = {
        param([string]$Message)
        if (-not $Json) {
            Write-Host $Message
        }
    }

    $result = Invoke-DanewLauncherAction -Action 'start-diagnostic' -RootPath $RootPath -Config $config -RuntimeSystemDrive $effectiveDrive -CurrentLocationPath (Get-Location).Path -ProgressCallback $progress

    if ($Json) {
        $result.output | ConvertTo-Json -Depth 30
        return
    }

    $diag = $result.output.diagnostic
    Write-Host ''
    Write-Host 'One-Click Diagnostic Summary'
    Write-Host ('Overall: ' + $diag.summary.overall_status)
    Write-Host ('PASS: ' + $diag.summary.pass + ' WARNING: ' + $diag.summary.warning + ' FAIL: ' + $diag.summary.fail)
    Write-Host ('JSON report: ' + $result.output.artifacts.report_json_path)
    Write-Host ('HTML report: ' + $result.output.artifacts.report_html_path)
}

function Invoke-DanewCliOfflineLogsCommand {
    $result = Invoke-DanewLauncherAction -Action 'analyze-offline-logs' -RootPath $RootPath -Config $config

    if ($Json) {
        $result.output | ConvertTo-Json -Depth 40
        return
    }

    $payload = $result.output
    Write-Host ''
    Write-Host 'Offline Windows Logs Analysis Summary'
    Write-Host ('Overall: ' + [string]$payload.overall_status)
    Write-Host ('Discovered logs: ' + [string]$payload.summary.total_discovered_logs)
    Write-Host ('Events: ' + [string]$payload.summary.total_events)
    Write-Host ('Missing required logs: ' + [string]$payload.summary.missing_required_logs)
    Write-Host ('Parse issues: ' + [string]$payload.summary.parse_issue_count)
    Write-Host ('offline-windows-analysis.json: ' + [string]$payload.artifacts.offline_windows_analysis)
    Write-Host ('evtx-discovery.json: ' + [string]$payload.artifacts.evtx_discovery)
    Write-Host ('evtx-events.json: ' + [string]$payload.artifacts.evtx_events_json)
    Write-Host ('evtx-events.csv: ' + [string]$payload.artifacts.evtx_events_csv)
    Write-Host ('evtx-summary.json: ' + [string]$payload.artifacts.evtx_summary)
    Write-Host ('timeline-raw.json: ' + [string]$payload.artifacts.timeline_raw_json)
    Write-Host ('timeline-raw.html: ' + [string]$payload.artifacts.timeline_raw_html)
}

if ($Command -ne 'Interactive') {
    if ($Command -eq 'real-winpe-validation') {
        $validationScript = Join-Path $PSScriptRoot 'Invoke-DanewRealWinPEValidation.ps1'
        & $validationScript -RootPath $RootPath -ConfigPath $ConfigPath
        Write-DanewLauncherActionLog -Config $config -Action 'cli-launcher' -Status 'ok' -Message 'CLI command completed: real-winpe-validation'
        exit 0
    }

    if ($Command -eq 'pre-real-boot-check') {
        $preCheckScript = Join-Path $PSScriptRoot 'Invoke-DanewPreRealBootCheck.ps1'
        & $preCheckScript -RootPath $RootPath -ConfigPath $ConfigPath
        Write-DanewLauncherActionLog -Config $config -Action 'cli-launcher' -Status 'ok' -Message 'CLI command completed: pre-real-boot-check'
        exit 0
    }

    if ($Command -eq 'create-usb-media') {
        $usbScript = Join-Path $PSScriptRoot 'Invoke-DanewCreateUsbMedia.ps1'
        & $usbScript -RootPath $RootPath -ConfigPath $ConfigPath -Mode Provision
        Write-DanewLauncherActionLog -Config $config -Action 'cli-launcher' -Status 'ok' -Message 'CLI command completed: create-usb-media'
        exit 0
    }

    if ($Command -eq 'start-diagnostic') {
        Invoke-DanewCliDiagnosticCommand
        Write-DanewLauncherActionLog -Config $config -Action 'cli-launcher' -Status 'ok' -Message 'CLI command completed: start-diagnostic'
        exit 0
    }

    if ($Command -eq 'analyze-offline-logs') {
        Invoke-DanewCliOfflineLogsCommand
        Write-DanewLauncherActionLog -Config $config -Action 'cli-launcher' -Status 'ok' -Message 'CLI command completed: analyze-offline-logs'
        exit 0
    }

    if ($Command -eq 'refresh-status' -or $Command -eq 'show-status' -or $Command -eq 'view-last-report') {
        Invoke-DanewCliStatusCommand -ActionName $Command
        Write-DanewLauncherActionLog -Config $config -Action 'cli-launcher' -Status 'ok' -Message ('CLI command completed: ' + $Command)
        exit 0
    }

    if ($Command -eq 'exit') {
        Invoke-DanewCliAction -ActionName 'exit'
        Write-DanewLauncherActionLog -Config $config -Action 'cli-launcher' -Status 'ok' -Message 'CLI launcher exited'
        exit 0
    }

    Invoke-DanewCliAction -ActionName $Command
    Write-DanewLauncherActionLog -Config $config -Action 'cli-launcher' -Status 'ok' -Message ('CLI command completed: ' + $Command)
    exit 0
}

while ($true) {
    Write-Host ''
    Write-Host 'Danew WinPE Check Tool - CLI'
    Write-Host '1. Refresh Status'
    Write-Host '2. Show Status'
    Write-Host '3. View Last Report'
    Write-Host '4. Scan WinPE'
    Write-Host '5. Run Capability Analysis'
    Write-Host '6. Generate Report'
    Write-Host '7. Open Reports Folder'
    Write-Host '8. Export Diagnostic Package'
    Write-Host '9. Start Diagnostic'
    Write-Host '10. Analyze Offline Windows Logs'
    Write-Host '11. Create Bootable USB'
    Write-Host '12. Exit'

    $choice = Read-Host 'Select action (1-12)'
    switch ($choice) {
        '1' { Invoke-DanewCliStatusCommand -ActionName 'refresh-status' }
        '2' { Invoke-DanewCliStatusCommand -ActionName 'show-status' }
        '3' { Invoke-DanewCliStatusCommand -ActionName 'view-last-report' }
        '4' { Invoke-DanewCliAction -ActionName 'scan-winpe' }
        '5' { Invoke-DanewCliAction -ActionName 'capability-analysis' }
        '6' { Invoke-DanewCliAction -ActionName 'generate-report' }
        '7' { Invoke-DanewCliAction -ActionName 'open-reports-folder' }
        '8' { Invoke-DanewCliAction -ActionName 'export-diagnostic-package' }
        '9' { Invoke-DanewCliDiagnosticCommand }
        '10' { Invoke-DanewCliOfflineLogsCommand }
        '11' { Invoke-DanewCliAction -ActionName 'create-usb-media' }
        '12' {
            Invoke-DanewCliAction -ActionName 'exit'
            break
        }
        default { Write-Host 'Invalid choice.' }
    }
}

Write-DanewLauncherActionLog -Config $config -Action 'cli-launcher' -Status 'ok' -Message 'CLI interactive session closed'
