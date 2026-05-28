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

function Add-ReportFrenchResult {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Details = ''
    )

    return [pscustomobject]@{ name = $Name; passed = $Passed; details = $Details }
}

$results = @()
$filesToParse = @(
    (Join-Path $RootPath 'scripts\report\HtmlReportShell.ps1'),
    (Join-Path $RootPath 'scripts\report\ReportEngine.ps1'),
    (Join-Path $RootPath 'scripts\offline\OfflineLogsEngine.ps1'),
    (Join-Path $RootPath 'scripts\offline\CrashAnalysisEngine.ps1'),
    (Join-Path $RootPath 'scripts\launcher\LauncherCore.ps1'),
    (Join-Path $RootPath 'scripts\launcher.ps1')
)

foreach ($file in $filesToParse) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors) | Out-Null
    $results += Add-ReportFrenchResult -Name ('parse_' + [System.IO.Path]::GetFileName($file)) -Passed (-not $errors) -Details ($(if ($errors) { ($errors | Select-Object -First 1).Message } else { 'PowerShell parser clean' }))
}

. (Join-Path $RootPath 'scripts\report\HtmlReportShell.ps1')
. (Join-Path $RootPath 'scripts\report\ReportEngine.ps1')
. (Join-Path $RootPath 'scripts\offline\OfflineLogsEngine.ps1')
. (Join-Path $RootPath 'scripts\offline\CrashAnalysisEngine.ps1')
. (Join-Path $RootPath 'scripts\launcher\LauncherCore.ps1')

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('danew-report-fr-' + [guid]::NewGuid().ToString('N'))
New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null

try {
    $config = [pscustomobject]@{ reports_path = $tempRoot }

    $diagnostic = [pscustomobject]@{
        timestamp = '2026-01-01T10:00:00'
        root_path = 'X:\'
        runtime_mode = 'WinPE'
        summary = [pscustomobject]@{ total = 3; pass = 2; warning = 1; fail = 0; overall_status = 'WARNING' }
        steps = @(
            [pscustomobject]@{ order = 1; label = 'Scan'; status = 'PASS'; message = 'Completed'; details = 'ok' },
            [pscustomobject]@{ order = 2; label = 'Offline'; status = 'WARNING'; message = 'Partial'; details = 'warn' }
        )
    }
    $oneClickOutput = Write-DanewOneClickDiagnosticReport -Diagnostic $diagnostic -Config $config

    $timelinePath = Join-Path $tempRoot 'timeline-raw.html'
    Write-DanewTimelineHtml -Path $timelinePath -Events @(
        [pscustomobject]@{ timestamp = '2026-01-01T10:00:00'; level = 'Error'; provider = 'Disk'; event_id = '7'; channel = 'System'; source_file = 'System.evtx'; message = 'Disk error' }
    ) -Summary ([pscustomobject]@{ total_events = 1; missing_required_logs = 0; parse_issue_count = 0 })

    $savPath = Join-Path $tempRoot 'sav-diagnostic-report.html'
    $savDiagnostic = [pscustomobject]@{
        timestamp = '2026-01-01T10:05:00'
        impact = 'Windows may be unable to boot or may be crashing soon after boot.'
        root_path = 'X:\'
        detection_confidence = 'High'
        severity = 'CRITICAL'
        root_cause_analysis = [pscustomobject]@{
            primary_cause = [pscustomobject]@{ cause = 'failing SSD'; confidence = 'High'; score = 88 }
            all_causes = @(
                [pscustomobject]@{ cause = 'failing SSD'; confidence = 'High'; score = 88; reason = 'Storage evidence' },
                [pscustomobject]@{ cause = 'BitLocker lock state'; confidence = 'Medium'; score = 72; reason = 'Lock evidence' }
            )
        }
        severity_analysis = [pscustomobject]@{ overall = 'CRITICAL' }
        classification = [pscustomobject]@{ records = @([pscustomobject]@{ timestamp = '2026-01-01T09:55:00'; event_id = '41'; provider = 'Kernel-Power'; categories = @('Power'); message = 'Unexpected shutdown' }) }
        timeline_intelligence = [pscustomobject]@{ intelligence = @([pscustomobject]@{ pattern = 'disk degradation'; confidence = 'High'; summary = 'Disk and NTFS errors repeat before crash.' }) }
        recommendations = @(
            'Run a non-destructive SSD health check and verify controller visibility.',
            'Do not perform repairs from this phase; keep the analysis read-only.'
        )
    }
    Write-DanewSavDiagnosticReportHtml -Path $savPath -CrashAnalysis $savDiagnostic

    $generalReport = [pscustomobject]@{
        scan_id = 'scan-001'
        timestamp = '2026-01-01T09:00:00'
        architecture = 'x64'
        input = [pscustomobject]@{ path = 'X:\input'; input_type = 'folder' }
        score = [pscustomobject]@{ global = 81 }
        recommendations = @(
            [pscustomobject]@{ priority = 'HIGH'; feature = 'Storage'; recommendation = 'Keep offline artifacts.' }
        )
    }
    $generalOutput = Export-DanewReports -ReportObject $generalReport -OutputDirectory $tempRoot -BaseName 'general-report'

    $indexPrimary = Join-Path $tempRoot 'REPORTS_INDEX.html'
    $indexAlias = Join-Path $tempRoot 'reports-index.html'

    $oneClickHtml = Get-Content -Path $oneClickOutput.html -Raw -Encoding UTF8
    $timelineHtml = Get-Content -Path $timelinePath -Raw -Encoding UTF8
    $savHtml = Get-Content -Path $savPath -Raw -Encoding UTF8
    $generalHtml = Get-Content -Path $generalOutput.html -Raw -Encoding UTF8
    $indexHtml = Get-Content -Path $indexPrimary -Raw -Encoding UTF8
    $jsonText = Get-Content -Path $generalOutput.json -Raw -Encoding UTF8
    $launcherSource = Get-Content -Path (Join-Path $RootPath 'scripts\launcher.ps1') -Raw -Encoding UTF8

    $results += Add-ReportFrenchResult -Name 'reports_index_french' -Passed ($indexHtml -match 'Index des rapports Danew' -and $indexHtml -match 'Rapports disponibles' -and $indexHtml -match 'Derniere mise a jour') -Details 'reports index titles localized'
    $results += Add-ReportFrenchResult -Name 'timeline_report_french' -Passed ($timelineHtml -match 'Chronologie hors ligne Danew' -and $timelineHtml -match 'Vue d ensemble de la chronologie' -and $timelineHtml -match 'Evenements de la chronologie') -Details 'timeline headings localized'
    $results += Add-ReportFrenchResult -Name 'sav_report_french' -Passed ($savHtml -match 'Rapport de diagnostic SAV Danew' -and $savHtml -match 'Resume executif' -and $savHtml -match 'Prochaines actions recommandees') -Details 'sav headings localized'
    $results += Add-ReportFrenchResult -Name 'one_click_report_french' -Passed ($oneClickHtml -match 'Diagnostic Danew en un clic' -and $oneClickHtml -match 'Resume d execution' -and $oneClickHtml -match 'Details des etapes') -Details 'one-click headings localized'
    $results += Add-ReportFrenchResult -Name 'general_report_french' -Passed ($generalHtml -match 'Rapport WinPE Danew' -and $generalHtml -match 'Recommandations') -Details 'general report headings localized'
    $results += Add-ReportFrenchResult -Name 'english_main_titles_removed' -Passed (($savHtml -notmatch '<h1>Danew SAV Diagnostic Report</h1>|<h2>Executive Summary</h2>|<h2>Recommended Next Steps</h2>') -and ($timelineHtml -notmatch '<h1>Danew Offline Timeline</h1>|<h2>Timeline Overview</h2>|<h2>Timeline Events</h2>') -and ($indexHtml -notmatch '<h1>Danew Reports Index</h1>|<h2>Available Reports</h2>')) -Details 'legacy English visible headings absent from main technician-facing sections'
    $results += Add-ReportFrenchResult -Name 'json_keys_unchanged' -Passed ($jsonText -match '"scan_id"' -and $jsonText -match '"recommendations"' -and $jsonText -notmatch '"id_analyse"|"recommandations_affichage"') -Details 'JSON property names preserved'
    $results += Add-ReportFrenchResult -Name 'interactive_features_preserved' -Passed ($savHtml -match 'data-sort-trigger' -and $savHtml -match 'data-report-search' -and $savHtml -match 'data-section-toggle') -Details 'sort/search/filter shell remains present'
    $results += Add-ReportFrenchResult -Name 'no_external_dependencies' -Passed (($savHtml -notmatch 'https?://') -and ($timelineHtml -notmatch 'https?://') -and ($indexHtml -notmatch 'https?://')) -Details 'no CDN or external assets introduced'
    $results += Add-ReportFrenchResult -Name 'filenames_unchanged' -Passed ((Test-Path -Path $indexPrimary) -and (Test-Path -Path $indexAlias) -and (Test-Path -Path (Join-Path $tempRoot 'sav-diagnostic-report.html')) -and (Test-Path -Path (Join-Path $tempRoot 'timeline-raw.html')) -and (Test-Path -Path (Join-Path $tempRoot 'one-click-diagnostic-report.html'))) -Details 'report filenames unchanged'
    $results += Add-ReportFrenchResult -Name 'launcher_buttons_localized' -Passed ($launcherSource -match 'ANALYSER LES JOURNAUX WINDOWS' -and $launcherSource -match 'ANALYSER LES CAUSES DE CRASH' -and $launcherSource -match 'OUVRIR LE RAPPORT SAV' -and $launcherSource -match 'OUVRIR LE DOSSIER DES RAPPORTS' -and ($launcherSource -match 'VERIFIER WINPE' -or $launcherSource -match 'VÉRIFIER WINPE')) -Details 'launcher visible buttons localized'
    $results += Add-ReportFrenchResult -Name 'print_stylesheet_preserved' -Passed (($savHtml -match '@media print') -and ($timelineHtml -match '@media print') -and ($indexHtml -match '@media print')) -Details 'print stylesheet still present'
    $results += Add-ReportFrenchResult -Name 'noscript_fallback_french' -Passed (($savHtml -match '<noscript>') -and ($savHtml -match 'Fonctions interactives desactivees') -and ($indexHtml -match 'Ce rapport reste entierement lisible sans JavaScript')) -Details 'fallback remains visible without JS and localized'
}
finally {
    if (Test-Path -Path $tempRoot) {
        Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
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

$jsonPath = Join-Path $OutputDirectory 'report-fr-tests-report.json'
$txtPath = Join-Path $OutputDirectory 'report-fr-tests-report.txt'

$report | ConvertTo-Json -Depth 20 | Set-Content -Path $jsonPath -Encoding UTF8

$lines = @(
    'Report French Localization Tests',
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

Write-Host ('Report FR test report JSON: ' + $jsonPath)
Write-Host ('Report FR test report TXT: ' + $txtPath)

if ($summary.failed -gt 0) {
    exit 1
}