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

function Add-UX2BResult {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Details = ''
    )

    return [pscustomobject]@{ name = $Name; passed = $Passed; details = $Details }
}

$results = @()
$launcherPath = Join-Path $RootPath 'scripts\launcher.ps1'
$htmlShellPath = Join-Path $RootPath 'scripts\report\HtmlReportShell.ps1'

$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($launcherPath, [ref]$tokens, [ref]$errors) | Out-Null
$results += Add-UX2BResult -Name 'launcher_parser_ok' -Passed (-not $errors) -Details ($(if ($errors) { ($errors | Select-Object -First 1).Message } else { 'PowerShell parser clean' }))

$launcher = Get-Content -Path $launcherPath -Raw -Encoding UTF8
$shell = Get-Content -Path $htmlShellPath -Raw -Encoding UTF8

$results += Add-UX2BResult -Name 'launcher_report_fallback_from_D' -Passed (($launcher -match 'foreach \(\$drive in @\(''E'', ''D''') -and ($launcher -match 'Add-DanewReportRoot -Path \(\$drive \+ '':\\reports''\)')) -Details 'Drive fallback scan includes D: reports root.'

$results += Add-UX2BResult -Name 'launcher_report_fallback_from_E' -Passed (($launcher -match 'foreach \(\$drive in @\(''E'', ''D''') -and ($launcher -match 'Add-DanewReportRoot -Path \(\$drive \+ '':\\reports''\)')) -Details 'Drive fallback scan includes E: reports root.'

$savFallback = $launcher -match "sav-diagnostic-report\.html', 'REPORTS_INDEX\.html', 'reports-index\.html', 'one-click-diagnostic-report\.html', 'offline-windows-failure-report\.html'"
$results += Add-UX2BResult -Name 'missing_sav_fallback_to_REPORTS_INDEX' -Passed $savFallback -Details 'SAV order: sav -> REPORTS_INDEX -> reports-index -> one-click -> offline failure.'

$timelineFallback = $launcher -match "timeline-raw\.html', 'REPORTS_INDEX\.html', 'reports-index\.html', 'timeline-raw\.json'"
$results += Add-UX2BResult -Name 'timeline_report_fallback' -Passed $timelineFallback -Details 'Timeline order keeps HTML then index fallback.'

$storageFallback = $launcher -match "storage-analysis\.html', 'storage-diagnostics\.html', 'REPORTS_INDEX\.html', 'reports-index\.html', 'storage-analysis\.json', 'storage-visibility-diagnosis\.json', 'storage-diagnostics\.json'"
$results += Add-UX2BResult -Name 'storage_report_fallback' -Passed $storageFallback -Details 'Storage order prefers HTML then index then JSON.'

$sortableJs = ($shell -match 'function initSortableTables\(\)') -and ($shell -match 'compareRowsByColumn') -and ($shell -match 'data-sort-trigger')
$results += Add-UX2BResult -Name 'sortable_table_js_present' -Passed $sortableJs -Details 'Shared shell contains local JS table sorting logic.'

$sortableMarkers = ($shell -match 'data-sortable="true"') -and ($shell -match 'data-sort-index=') -and ($shell -match 'data-sort-direction="none"')
$results += Add-UX2BResult -Name 'sortable_table_header_markers_present' -Passed $sortableMarkers -Details 'Table headers emit sortable markers for all columns.'

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

$jsonPath = Join-Path $OutputDirectory 'ux2b-tests-report.json'
$txtPath = Join-Path $OutputDirectory 'ux2b-tests-report.txt'

$report | ConvertTo-Json -Depth 20 | Set-Content -Path $jsonPath -Encoding UTF8

$lines = @(
    'UX-2B Tests',
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

Write-Host ('UX-2B test report JSON: ' + $jsonPath)
Write-Host ('UX-2B test report TXT: ' + $txtPath)

if ($summary.failed -gt 0) {
    exit 1
}
