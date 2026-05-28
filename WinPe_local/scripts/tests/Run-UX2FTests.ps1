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

function Add-UX2FResult {
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
$results += Add-UX2FResult -Name 'launcher_parser_ok' -Passed (-not $errors) -Details ($(if ($errors) { ($errors | Select-Object -First 1).Message } else { 'PowerShell parser clean' }))

$summaryTitleOk = $launcher -match '\$resultTitleLabel\.Text\s*=\s*''Diagnostic Summary''' 
$results += Add-UX2FResult -Name 'diagnostic_summary_title' -Passed $summaryTitleOk -Details 'Diagnostic Summary title visible.'

$oldTitleAbsent = $launcher -notmatch 'Probable Cause and Severity'
$results += Add-UX2FResult -Name 'old_title_removed' -Passed $oldTitleAbsent -Details 'Old title removed from UI.'

$recommendedNeutral = $launcher -match '(?s)Recommended Actions'' -Action ''recommended-actions''.*?-Tone ''neutral''' 
$results += Add-UX2FResult -Name 'recommended_actions_not_orange' -Passed $recommendedNeutral -Details 'Recommended Actions button uses neutral styling.'

$primaryButtons = ($launcher -match 'ANALYZE WINDOWS LOGS') -and ($launcher -match 'ANALYZE CRASH CAUSES')
$noMainScroll = ($launcher -match '\$form\.AutoScroll\s*=\s*\$false')
$results += Add-UX2FResult -Name 'primary_buttons_visible_without_scroll' -Passed ($primaryButtons -and $noMainScroll) -Details 'Primary buttons remain visible without scroll.'

$recommendedFullWidth = ($launcher -match '\$recommendedActionValueLabel\s*=\s*New-DanewSummaryValueLabel.*-Width\s+832')
$results += Add-UX2FResult -Name 'recommended_action_full_width' -Passed $recommendedFullWidth -Details 'Recommended next action spans full width.'

$openSavOk = ($launcher -match 'Open-DanewReportFile') -and ($launcher -match 'Get-DanewFirstExistingReportPath')
$results += Add-UX2FResult -Name 'open_sav_report_wired' -Passed $openSavOk -Details 'Open SAV report handler still present.'

$handlersOk = ($launcher -match "-Action 'analyze-offline-logs'") -and ($launcher -match "-Action 'analyze-crash-causes'") -and ($launcher -match 'Invoke-GuiAction')
$results += Add-UX2FResult -Name 'analyze_handlers_present' -Passed $handlersOk -Details 'Analyze Windows Logs and Crash Causes handlers still present.'

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

$jsonPath = Join-Path $OutputDirectory 'ux2f-tests-report.json'
$txtPath = Join-Path $OutputDirectory 'ux2f-tests-report.txt'

$report | ConvertTo-Json -Depth 20 | Set-Content -Path $jsonPath -Encoding UTF8

$lines = @(
    'UX-2F Tests',
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

Write-Host ('UX-2F test report JSON: ' + $jsonPath)
Write-Host ('UX-2F test report TXT: ' + $txtPath)

if ($summary.failed -gt 0) {
    exit 1
}
