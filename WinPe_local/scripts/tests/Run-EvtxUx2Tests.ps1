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

function Add-EvtxUx2Result {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Details = ''
    )
    return [pscustomobject]@{ name = $Name; passed = $Passed; details = $Details }
}

function New-EvtxUx2TestRoot {
    param([Parameter(Mandatory = $true)][string]$BasePath)

    $tempRoot = Join-Path $BasePath 'temp\evtx-ux2-tests'
    if (Test-Path -Path $tempRoot) {
        Remove-Item -Path $tempRoot -Recurse -Force
    }

    New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null
    foreach ($folder in @('scripts', 'reports', 'logs', 'manifests')) {
        New-Item -Path (Join-Path $tempRoot $folder) -ItemType Directory -Force | Out-Null
    }

    Copy-Item -Path (Join-Path $BasePath 'scripts\*') -Destination (Join-Path $tempRoot 'scripts') -Recurse -Force
    Copy-Item -Path (Join-Path $BasePath 'manifests\evtx-event-knowledge.json') -Destination (Join-Path $tempRoot 'manifests\evtx-event-knowledge.json') -Force

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
    }
}

$results = @()
$temp = New-EvtxUx2TestRoot -BasePath $RootPath

try {
    . (Join-Path $temp.root 'scripts\launcher\LauncherCore.ps1')
    . (Join-Path $temp.root 'scripts\offline\OfflineLogsEngine.ps1')

    $config = Get-DanewLauncherConfig -RootPath $temp.root -ConfigPath $temp.config_path
    Initialize-DanewLauncherPaths -Config $config

    $timelineEvents = @(
        [pscustomobject]@{ timestamp = '2026-05-28T08:50:00'; level = 'Information'; provider = 'Service Control Manager'; event_id = 7036; channel = 'System'; source_file = 'System.evtx'; message = 'Service state changed' }
        [pscustomobject]@{ timestamp = '2026-05-28T09:00:00'; level = 'Error'; provider = 'Disk'; event_id = 11; channel = 'System'; source_file = 'System.evtx'; message = 'The driver detected a controller error.' }
        [pscustomobject]@{ timestamp = '2026-05-28T09:01:00'; level = 'Warning'; provider = 'Storport'; event_id = 129; channel = 'System'; source_file = 'System.evtx'; message = 'Reset to device issued.' }
        [pscustomobject]@{ timestamp = '2026-05-28T09:02:00'; level = 'Critical'; provider = 'Microsoft-Windows-Kernel-Power'; event_id = 41; channel = 'System'; source_file = 'System.evtx'; message = 'The system has rebooted without cleanly shutting down first.' }
        [pscustomobject]@{ timestamp = '2026-05-28T09:03:00'; level = 'Error'; provider = 'Microsoft-Windows-WER-SystemErrorReporting'; event_id = 1001; channel = 'System'; source_file = 'System.evtx'; message = 'The computer has rebooted from a bugcheck.' }
        [pscustomobject]@{ timestamp = '2026-05-28T09:06:00'; level = 'Error'; provider = 'WindowsUpdateClient'; event_id = 20; channel = 'System'; source_file = 'System.evtx'; message = 'Installation Failure: Windows failed to install update.' }
        [pscustomobject]@{ timestamp = '2026-05-28T09:08:00'; level = 'Error'; provider = 'Microsoft-Windows-DriverFrameworks-UserMode'; event_id = 10110; channel = 'System'; source_file = 'System.evtx'; message = 'A problem has occurred with one or more user-mode drivers.' }
    )
    $timelineSummary = [pscustomobject]@{ total_events = @($timelineEvents).Count; missing_required_logs = 0; parse_issue_count = 0 }

    $timelinePath = Join-Path $config.reports_path 'timeline-raw.html'
    $timelineJsonPath = Join-Path $config.reports_path 'timeline-raw.json'
    $eventsCsvPath = Join-Path $config.reports_path 'evtx-events.csv'
    $eventsJsonPath = Join-Path $config.reports_path 'evtx-events.json'
    $summaryJsonPath = Join-Path $config.reports_path 'evtx-summary.json'

    Write-DanewTimelineHtml -Path $timelinePath -Events $timelineEvents -Summary $timelineSummary
    ([pscustomobject]@{ events = $timelineEvents; issues = @() } | ConvertTo-Json -Depth 20) | Set-Content -Path $timelineJsonPath -Encoding UTF8
    $timelineEvents | Select-Object timestamp, level, provider, event_id, channel, source_file, message | Export-Csv -Path $eventsCsvPath -NoTypeInformation -Encoding UTF8
    $timelineEvents | ConvertTo-Json -Depth 20 | Set-Content -Path $eventsJsonPath -Encoding UTF8
    $timelineSummary | ConvertTo-Json -Depth 20 | Set-Content -Path $summaryJsonPath -Encoding UTF8

    $exports = Write-DanewEvtxTargetedExports -RootPath $temp.root -ReportsPath $config.reports_path -Events $timelineEvents -Summary $timelineSummary

    $filteredPath = Join-Path $config.reports_path 'evtx-filtered-events.csv'
    $criticalPath = Join-Path $config.reports_path 'evtx-critical-events.csv'
    $crashPath = Join-Path $config.reports_path 'evtx-crash-window.csv'
    $summaryTxtPath = Join-Path $config.reports_path 'evtx-sav-summary.txt'

    $results += Add-EvtxUx2Result -Name 'powershell_exports_generated' -Passed (($exports.generated -eq $true) -and (Test-Path $filteredPath) -and (Test-Path $criticalPath) -and (Test-Path $crashPath) -and (Test-Path $summaryTxtPath)) -Details 'all four targeted exports generated'
    $results += Add-EvtxUx2Result -Name 'exports_written_under_reports' -Passed ((Split-Path -Parent $filteredPath) -eq $config.reports_path -and (Split-Path -Parent $criticalPath) -eq $config.reports_path -and (Split-Path -Parent $crashPath) -eq $config.reports_path -and (Split-Path -Parent $summaryTxtPath) -eq $config.reports_path) -Details 'targeted files are under reports path'

    $criticalRows = @()
    if (Test-Path -Path $criticalPath) {
        $criticalRows = @(Import-Csv -Path $criticalPath)
    }
    $criticalOnly = $true
    foreach ($row in @($criticalRows)) {
        $importance = 0
        [void][int]::TryParse([string]$row.importance_sav, [ref]$importance)
        if (-not ([string]$row.level_fr -eq 'Critique' -or $importance -ge 80)) {
            $criticalOnly = $false
            break
        }
    }
    $results += Add-EvtxUx2Result -Name 'critical_export_only_critical_high_importance' -Passed ($criticalOnly -and @($criticalRows).Count -gt 0) -Details 'critical export constrained to Critique or importance>=80'

    $crashRows = @()
    if (Test-Path -Path $crashPath) {
        $crashRows = @(Import-Csv -Path $crashPath)
    }
    $hasCrashRef = @($crashRows | Where-Object { [string]$_.event_id -in @('41', '1001') }).Count -gt 0
    $results += Add-EvtxUx2Result -Name 'crash_window_export_covers_last_crash' -Passed ($hasCrashRef -and @($crashRows).Count -ge 2) -Details 'crash-window export includes crash anchors and nearby events'

    $summaryContent = ''
    if (Test-Path -Path $summaryTxtPath) {
        $summaryContent = Get-Content -Path $summaryTxtPath -Raw -Encoding UTF8
    }
    $results += Add-EvtxUx2Result -Name 'sav_summary_txt_generated' -Passed ((-not [string]::IsNullOrWhiteSpace($summaryContent)) -and ($summaryContent -match 'Resume SAV EVTX')) -Details 'evtx-sav-summary.txt created with content'

    $results += Add-EvtxUx2Result -Name 'knowledge_rules_loaded' -Passed ([int]$exports.knowledge_rules_loaded -gt 0) -Details ('loaded rules=' + [string]$exports.knowledge_rules_loaded)

    $results += Add-EvtxUx2Result -Name 'existing_reports_not_broken' -Passed ((Test-Path $timelinePath) -and (Test-Path $timelineJsonPath) -and (Test-Path $eventsCsvPath)) -Details 'timeline-raw.html/json and evtx-events.csv still present'

    $launcherAction = Invoke-DanewLauncherAction -Action 'export-evtx-targeted' -RootPath $temp.root -Config $config -SuppressActionLog
    $results += Add-EvtxUx2Result -Name 'launcher_action_export_evtx_targeted' -Passed (($launcherAction.action -eq 'export-evtx-targeted') -and ($launcherAction.output.generated -eq $true)) -Details 'launcher action callable and successful'

    $cliFile = Join-Path $temp.root 'scripts\DanewCheckTool.CLI.ps1'
    $cliText = Get-Content -Path $cliFile -Raw -Encoding UTF8
    $launcherFile = Join-Path $temp.root 'scripts\launcher.ps1'
    $launcherText = Get-Content -Path $launcherFile -Raw -Encoding UTF8
    $results += Add-EvtxUx2Result -Name 'cli_and_launcher_expose_action' -Passed (($cliText -match 'export-evtx-targeted') -and ($launcherText -match 'export-evtx-targeted')) -Details 'CLI and launcher expose export action'
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

$jsonPath = Join-Path $OutputDirectory 'evtx-ux2-tests-report.json'
$txtPath = Join-Path $OutputDirectory 'evtx-ux2-tests-report.txt'

$report | ConvertTo-Json -Depth 20 | Set-Content -Path $jsonPath -Encoding UTF8

$lines = @(
    'EVTX UX-2 Tests',
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

Write-Host ('EVTX UX-2 test report JSON: ' + $jsonPath)
Write-Host ('EVTX UX-2 test report TXT: ' + $txtPath)

if ($summary.failed -gt 0) {
    exit 1
}