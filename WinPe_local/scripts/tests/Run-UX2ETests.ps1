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

function Add-UX2EResult {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Details = ''
    )

    return [pscustomobject]@{ name = $Name; passed = $Passed; details = $Details }
}

$results = @()
$launcherPath = Join-Path $RootPath 'scripts\launcher.ps1'
$launcher = Get-Content -Path $launcherPath -Raw -Encoding UTF8

$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($launcherPath, [ref]$tokens, [ref]$errors) | Out-Null
$results += Add-UX2EResult -Name 'launcher_parser_ok' -Passed (-not $errors) -Details ($(if ($errors) { ($errors | Select-Object -First 1).Message } else { 'PowerShell parser clean' }))

$recommendedRow = ($launcher -match '\$recommendedActionValueLabel\s*=\s*New-DanewSummaryValueLabel.*-Left\s+16\s+-Top\s+240\s+-Width\s+832')
$results += Add-UX2EResult -Name 'recommended_action_full_width' -Passed $recommendedRow -Details 'Recommended action spans full summary width.'

$criticalVisible = ($launcher -match '\$criticalEventsValueLabel\s*=\s*New-DanewSummaryValueLabel.*-Left\s+568')
$results += Add-UX2EResult -Name 'critical_events_visible' -Passed $criticalVisible -Details 'Critical events stays in row 2.'

$noOverlap = ($launcher -match '\$criticalEventsValueLabel.*-Top\s+184') -and ($launcher -match '\$recommendedActionValueLabel.*-Top\s+240')
$results += Add-UX2EResult -Name 'no_overlap_recommended_vs_critical' -Passed $noOverlap -Details 'Recommended action row is below critical events.'

$fitsScreen = ($launcher -match '\$statusGroup\.Height\s*=\s*276') -and ($launcher -match '\$simpleActionsGroup\.Top\s*=\s*538')
$results += Add-UX2EResult -Name 'summary_fits_1366x768' -Passed $fitsScreen -Details 'Summary size and spacing fit within 1366x768.'

$noScroll = ($launcher -match '\$form\.AutoScroll\s*=\s*\$false')
$results += Add-UX2EResult -Name 'no_main_scroll' -Passed $noScroll -Details 'Main form has no scrollbars.'

$primaryButtons = ($launcher -match 'ANALYSER LES JOURNAUX WINDOWS') -and ($launcher -match 'ANALYSER LES CAUSES DE CRASH')
$reportsVisible = ($launcher -match '\$simpleActionsGroup\.Top\s*=\s*538') -and ($launcher -match 'Rapports et actions')
$results += Add-UX2EResult -Name 'primary_and_reports_visible' -Passed ($primaryButtons -and $reportsVisible) -Details 'Primary buttons and report actions remain visible.'

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

$jsonPath = Join-Path $OutputDirectory 'ux2e-tests-report.json'
$txtPath = Join-Path $OutputDirectory 'ux2e-tests-report.txt'

$report | ConvertTo-Json -Depth 20 | Set-Content -Path $jsonPath -Encoding UTF8

$lines = @(
    'UX-2E Tests',
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

Write-Host ('UX-2E test report JSON: ' + $jsonPath)
Write-Host ('UX-2E test report TXT: ' + $txtPath)

if ($summary.failed -gt 0) {
    exit 1
}
