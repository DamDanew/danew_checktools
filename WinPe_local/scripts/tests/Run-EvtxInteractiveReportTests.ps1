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

function Add-EvtxUxResult {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Details = ''
    )
    return [pscustomobject]@{ name = $Name; passed = $Passed; details = $Details }
}

function New-EvtxUxTestRoot {
    param([Parameter(Mandatory = $true)][string]$BasePath)

    $tempRoot = Join-Path $BasePath 'temp\evtx-ux-tests'
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
$temp = New-EvtxUxTestRoot -BasePath $RootPath

try {
    . (Join-Path $temp.root 'scripts\launcher\LauncherCore.ps1')
    . (Join-Path $temp.root 'scripts\offline\OfflineLogsEngine.ps1')

    $config = Get-DanewLauncherConfig -RootPath $temp.root -ConfigPath $temp.config_path
    Initialize-DanewLauncherPaths -Config $config

    $timelineEvents = @(
        [pscustomobject]@{ timestamp = '2026-05-28T08:50:00'; level = 'Information'; provider = 'Service Control Manager'; event_id = 7036; channel = 'System'; source_file = 'System.evtx'; message = 'Service state changed' }
        [pscustomobject]@{ timestamp = '2026-05-28T09:00:00'; level = 'Error'; provider = 'Disk'; event_id = 7; channel = 'System'; source_file = 'System.evtx'; message = 'The device has a bad block.' }
        [pscustomobject]@{ timestamp = '2026-05-28T09:01:00'; level = 'Warning'; provider = 'Ntfs'; event_id = 55; channel = 'System'; source_file = 'System.evtx'; message = 'The file system structure is corrupt.' }
        [pscustomobject]@{ timestamp = '2026-05-28T09:02:00'; level = 'Critical'; provider = 'Microsoft-Windows-Kernel-Power'; event_id = 41; channel = 'System'; source_file = 'System.evtx'; message = 'The system has rebooted without cleanly shutting down first.' }
        [pscustomobject]@{ timestamp = '2026-05-28T09:03:00'; level = 'Error'; provider = 'Microsoft-Windows-WER-SystemErrorReporting'; event_id = 1001; channel = 'System'; source_file = 'System.evtx'; message = 'The computer has rebooted from a bugcheck.' }
        [pscustomobject]@{ timestamp = '2026-05-28T09:06:00'; level = 'Error'; provider = 'WindowsUpdateClient'; event_id = 20; channel = 'System'; source_file = 'System.evtx'; message = 'Installation Failure: Windows failed to install update.' }
        [pscustomobject]@{ timestamp = '2026-05-28T09:08:00'; level = 'Error'; provider = 'Microsoft-Windows-DriverFrameworks-UserMode'; event_id = 10110; channel = 'System'; source_file = 'System.evtx'; message = 'A problem has occurred with one or more user-mode drivers.' }
    )
    $timelineSummary = [pscustomobject]@{ total_events = @($timelineEvents).Count; missing_required_logs = 0; parse_issue_count = 0 }

    $timelinePath = Join-Path $config.reports_path 'timeline-raw.html'
    Write-DanewTimelineHtml -Path $timelinePath -Events $timelineEvents -Summary $timelineSummary

    $evtxHtmlPath = Join-Path $config.reports_path 'evtx-events.html'
    $timelineHtml = Get-Content -Path $timelinePath -Raw -Encoding UTF8

    $results += Add-EvtxUxResult -Name 'timeline_raw_generated' -Passed (Test-Path -Path $timelinePath) -Details 'timeline-raw.html exists'
    $results += Add-EvtxUxResult -Name 'events_table_present' -Passed ($timelineHtml -match 'Tableau interactif des evenements Windows' -and $timelineHtml -match 'data-evtx-row') -Details 'interactive events table markers'
    $results += Add-EvtxUxResult -Name 'french_headers_present' -Passed ($timelineHtml -match 'Date/heure' -and $timelineHtml -match 'Importance SAV' -and $timelineHtml -match 'Fichier EVTX source') -Details 'French column headers visible'
    $results += Add-EvtxUxResult -Name 'global_search_present' -Passed ($timelineHtml -match 'data-report-search') -Details 'global search input present'
    $results += Add-EvtxUxResult -Name 'column_sort_present' -Passed ($timelineHtml -match 'data-sort-trigger') -Details 'column sort triggers present'
    $results += Add-EvtxUxResult -Name 'level_filters_present' -Passed ($timelineHtml -match 'data-filter-level' -and $timelineHtml -match 'Critique' -and $timelineHtml -match 'Erreur' -and $timelineHtml -match 'Avertissement' -and $timelineHtml -match 'Information') -Details 'level filters present'
    $results += Add-EvtxUxResult -Name 'family_filter_present' -Passed ($timelineHtml -match 'data-filter-family' -and $timelineHtml -match 'Crash / BSOD') -Details 'family filter present'
    $results += Add-EvtxUxResult -Name 'provider_filter_present' -Passed ($timelineHtml -match 'data-filter-provider') -Details 'provider filter present'
    $results += Add-EvtxUxResult -Name 'event_id_filter_present' -Passed ($timelineHtml -match 'data-filter-event-id') -Details 'event id filter present'
    $results += Add-EvtxUxResult -Name 'channel_filter_present' -Passed ($timelineHtml -match 'data-filter-channel') -Details 'channel filter present'
    $results += Add-EvtxUxResult -Name 'period_filter_present' -Passed ($timelineHtml -match 'data-filter-period' -and $timelineHtml -match 'Dernieres 24h' -and $timelineHtml -match '7 derniers jours' -and $timelineHtml -match '30 derniers jours') -Details 'time period filter present'
    $results += Add-EvtxUxResult -Name 'useful_only_button_present' -Passed ($timelineHtml -match 'data-action="useful-only"') -Details 'useful diagnostic button present'
    $results += Add-EvtxUxResult -Name 'importance_column_present' -Passed ($timelineHtml -match 'Importance SAV') -Details 'importance column present'
    $results += Add-EvtxUxResult -Name 'top10_section_present' -Passed ($timelineHtml -match 'Evenements importants a regarder en priorite' -and $timelineHtml -match 'data-focus-event') -Details 'top 10 section present'
    $results += Add-EvtxUxResult -Name 'clickable_rows_present' -Passed ($timelineHtml -match 'class="evtx-row"' -and $timelineHtml -match 'data-evtx-row') -Details 'rows clickable markers present'
    $results += Add-EvtxUxResult -Name 'detail_panel_present' -Passed ($timelineHtml -match 'data-evtx-detail' -and $timelineHtml -match 'Message complet') -Details 'detail panel present'
    $results += Add-EvtxUxResult -Name 'explanation_cause_advice_present' -Passed ($timelineHtml -match 'Explication' -and $timelineHtml -match 'Cause probable' -and $timelineHtml -match 'Conseils SAV') -Details 'explanation blocks present'
    $results += Add-EvtxUxResult -Name 'related_events_present' -Passed ($timelineHtml -match 'Evenements lies' -and $timelineHtml -match '\+/-5') -Details 'related events section present'
    $results += Add-EvtxUxResult -Name 'before_last_crash_button_present' -Passed ($timelineHtml -match 'data-action="before-last-crash"') -Details 'before-last-crash filter button present'
    $results += Add-EvtxUxResult -Name 'loops_section_present' -Passed ($timelineHtml -match 'Boucles et repetitions detectees' -and $timelineHtml -match 'Type de boucle') -Details 'loop detection section present'
    $results += Add-EvtxUxResult -Name 'technician_client_mode_present' -Passed ($timelineHtml -match 'Mode Technicien' -and $timelineHtml -match 'Mode Client') -Details 'reading modes present'
    $results += Add-EvtxUxResult -Name 'copy_sav_summary_present' -Passed ($timelineHtml -match 'data-action="copy-sav-summary"' -and $timelineHtml -match 'Resume SAV') -Details 'copy summary control present'
    $results += Add-EvtxUxResult -Name 'csv_export_controls_present' -Passed ($timelineHtml -match 'data-action="export-visible-csv"' -and $timelineHtml -match 'data-action="export-critical-csv"' -and $timelineHtml -match 'data-action="export-crash-csv"') -Details 'CSV export controls present'
    $results += Add-EvtxUxResult -Name 'no_external_cdn_or_script' -Passed (($timelineHtml -notmatch 'https?://') -and ($timelineHtml -notmatch '<script\s+src=')) -Details 'no CDN and no external script dependencies'
    $results += Add-EvtxUxResult -Name 'noscript_fallback_present' -Passed ($timelineHtml -match '<noscript>' -and $timelineHtml -match 'Fonctions interactives desactivees') -Details 'no-JS fallback visible'
    $results += Add-EvtxUxResult -Name 'print_css_present' -Passed ($timelineHtml -match '@media print') -Details 'print CSS present'
    $results += Add-EvtxUxResult -Name 'file_scheme_compatible' -Passed ($timelineHtml -match 'downloadTextFile' -and $timelineHtml -match 'Blob\(') -Details 'exports rely on local blob APIs compatible with file:/// mode'
    $results += Add-EvtxUxResult -Name 'evtx_events_html_generated' -Passed (Test-Path -Path $evtxHtmlPath) -Details 'evtx-events.html generated as companion report'
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

$jsonPath = Join-Path $OutputDirectory 'evtx-interactive-report-tests-report.json'
$txtPath = Join-Path $OutputDirectory 'evtx-interactive-report-tests-report.txt'

$report | ConvertTo-Json -Depth 20 | Set-Content -Path $jsonPath -Encoding UTF8

$lines = @(
    'EVTX Interactive Report Tests',
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

Write-Host ('EVTX interactive report test JSON: ' + $jsonPath)
Write-Host ('EVTX interactive report test TXT: ' + $txtPath)

if ($summary.failed -gt 0) {
    exit 1
}