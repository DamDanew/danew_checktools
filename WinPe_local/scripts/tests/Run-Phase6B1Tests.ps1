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

function Add-Phase6B1Result {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Details = ''
    )

    return [pscustomobject]@{ name = $Name; passed = $Passed; details = $Details }
}

function New-Phase6B1TestRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath
    )

    $tempRoot = Join-Path $BasePath 'temp\phase6b1-tests'
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
    }
}

$results = @()
$temp = New-Phase6B1TestRoot -BasePath $RootPath

try {
    . (Join-Path $temp.root 'scripts\launcher\LauncherCore.ps1')

    $config = Get-DanewLauncherConfig -RootPath $temp.root -ConfigPath $temp.config_path
    Initialize-DanewLauncherPaths -Config $config

    $oneClickDiagnostic = [pscustomobject]@{
        timestamp = '2026-05-28T09:10:00'
        root_path = $temp.root
        runtime_mode = 'offline'
        summary = [pscustomobject]@{
            overall_status = 'WARNING'
            total = 3
            pass = 1
            warning = 1
            fail = 1
        }
        steps = @(
            [pscustomobject]@{ order = 1; label = 'Mount scan'; status = 'PASS'; message = 'Volumes detected'; details = 'Primary disk visible' }
            [pscustomobject]@{ order = 2; label = 'Registry access'; status = 'WARNING'; message = 'SYSTEM hive unavailable'; details = 'Fallback to log-only mode' }
            [pscustomobject]@{ order = 3; label = 'Crash analysis'; status = 'FAIL'; message = 'Storage issue suspected'; details = 'Intel RST/VMD issue' }
        )
    }
    $oneClickOutput = Write-DanewOneClickDiagnosticReport -Diagnostic $oneClickDiagnostic -Config $config

    $timelineEvents = @(
        [pscustomobject]@{ timestamp = '2026-05-28T09:00:00'; level = 'Error'; provider = 'Disk'; event_id = 7; channel = 'System'; source_file = 'System.evtx'; message = 'The device has a bad block.' }
        [pscustomobject]@{ timestamp = '2026-05-28T09:03:00'; level = 'Warning'; provider = 'Ntfs'; event_id = 55; channel = 'System'; source_file = 'System.evtx'; message = 'The file system structure is corrupt.' }
    )
    $timelineSummary = [pscustomobject]@{ total_events = 2; missing_required_logs = 1; parse_issue_count = 0 }
    $timelinePath = Join-Path $config.reports_path 'timeline-raw.html'
    Write-DanewTimelineHtml -Path $timelinePath -Events $timelineEvents -Summary $timelineSummary

    $savPath = Join-Path $config.reports_path 'sav-diagnostic-report.html'
    $savDiagnostic = [pscustomobject]@{
        timestamp = '2026-05-28T09:12:00'
        root_path = $temp.root
        detection_confidence = 'High'
        impact = 'Windows may be unable to boot.'
        classification = [pscustomobject]@{
            records = @(
                [pscustomobject]@{ timestamp = '2026-05-28T09:00:00'; event_id = 7; provider = 'Disk'; categories = @('storage'); message = 'The device has a bad block.' }
            )
        }
        root_cause_analysis = [pscustomobject]@{
            primary_cause = [pscustomobject]@{ cause = 'failing SSD'; confidence = 'High'; score = 92; reason = 'Disk errors and NTFS corruption align.' }
            secondary_causes = @()
            all_causes = @(
                [pscustomobject]@{ cause = 'failing SSD'; confidence = 'High'; score = 92; reason = 'Disk errors and NTFS corruption align.' },
                [pscustomobject]@{ cause = 'corrupted NTFS filesystem'; confidence = 'Medium'; score = 71; reason = 'Filesystem errors appear immediately after disk errors.' }
            )
        }
        severity_analysis = [pscustomobject]@{ overall = 'CRITICAL' }
        timeline_intelligence = [pscustomobject]@{
            intelligence = @(
                [pscustomobject]@{ pattern = 'disk degradation'; confidence = 'High'; summary = 'Disk and NTFS errors repeat before crash.' }
            )
        }
        recommendations = @(
            'Run a non-destructive SSD health check and verify controller visibility.',
            'Do not perform repairs from this phase; keep the analysis read-only.'
        )
    }
    Write-DanewSavDiagnosticReportHtml -Path $savPath -CrashAnalysis $savDiagnostic

    $indexPrimary = Join-Path $config.reports_path 'REPORTS_INDEX.html'
    $indexAlias = Join-Path $config.reports_path 'reports-index.html'

    $oneClickHtml = Get-Content -Path $oneClickOutput.html -Raw -Encoding UTF8
    $timelineHtml = Get-Content -Path $timelinePath -Raw -Encoding UTF8
    $savHtml = Get-Content -Path $savPath -Raw -Encoding UTF8
    $indexHtml = Get-Content -Path $indexPrimary -Raw -Encoding UTF8
    $aliasHtml = Get-Content -Path $indexAlias -Raw -Encoding UTF8

    $results += Add-Phase6B1Result -Name 'one_click_uses_interactive_shell' -Passed ($oneClickHtml -match 'data-report-shell="danew"' -and $oneClickHtml -match 'report-toolbar' -and $oneClickHtml -match 'data-report-search') -Details 'one-click-diagnostic-report.html shell markers'
    $results += Add-Phase6B1Result -Name 'one_click_steps_are_filterable' -Passed ($oneClickHtml -match 'data-search-row=' -and $oneClickHtml -match 'Filtrer les etapes par libelle') -Details 'step rows carry searchable attributes'
    $results += Add-Phase6B1Result -Name 'timeline_uses_interactive_shell' -Passed ($timelineHtml -match 'Chronologie hors ligne Danew' -and $timelineHtml -match 'data-search-row=' -and $timelineHtml -match 'timeline-raw.json') -Details 'timeline report upgraded'
    $results += Add-Phase6B1Result -Name 'sav_report_uses_interactive_shell' -Passed ($savHtml -match 'Rapport de diagnostic SAV Danew' -and $savHtml -match 'Prochaines actions recommandees' -and $savHtml -match 'data-section-toggle') -Details 'sav report upgraded'
    $results += Add-Phase6B1Result -Name 'reports_index_written' -Passed ((Test-Path -Path $indexPrimary) -and (Test-Path -Path $indexAlias) -and $indexHtml -match 'Index des rapports Danew' -and $indexHtml -match 'sav-diagnostic-report.html' -and $indexHtml -match 'timeline-raw.html') -Details 'index and alias created'
    $results += Add-Phase6B1Result -Name 'reports_index_alias_matches' -Passed ($indexHtml -eq $aliasHtml) -Details 'primary and alias content identical'
    $results += Add-Phase6B1Result -Name 'noscript_fallback_present' -Passed ($oneClickHtml -match '<noscript>' -and $timelineHtml -match '<noscript>' -and $savHtml -match '<noscript>') -Details 'noscript readability notice present'
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

$jsonPath = Join-Path $OutputDirectory 'phase6b1-tests-report.json'
$txtPath = Join-Path $OutputDirectory 'phase6b1-tests-report.txt'

$report | ConvertTo-Json -Depth 20 | Set-Content -Path $jsonPath -Encoding UTF8

$lines = @(
    'Phase 6B.1 Tests',
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

Write-Host ('Phase 6B.1 test report JSON: ' + $jsonPath)
Write-Host ('Phase 6B.1 test report TXT: ' + $txtPath)

if ($summary.failed -gt 0) {
    exit 1
}