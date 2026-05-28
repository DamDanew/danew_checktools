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

function Add-UX2DResult {
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
$results += Add-UX2DResult -Name 'launcher_parser_ok' -Passed (-not $errors) -Details ($(if ($errors) { ($errors | Select-Object -First 1).Message } else { 'PowerShell parser clean' }))

$waitingText = $launcher -match '\$summaryLabel\.Text\s*=\s*''Status: Waiting for analysis''' 
$results += Add-UX2DResult -Name 'initial_state_waiting' -Passed $waitingText -Details 'Initial status says Waiting for analysis.'

$badgeWaiting = $launcher -match '\$overallBadgeLabel\.Text\s*=\s*''Waiting''' 
$results += Add-UX2DResult -Name 'badge_waiting_text' -Passed $badgeWaiting -Details 'Overall badge shows Waiting text.'

$noCaseText = ($launcher -notmatch '\/\s*case\s*[A-D]')
$results += Add-UX2DResult -Name 'no_case_wording_in_summary' -Passed $noCaseText -Details 'Case A/B/C/D not present in main summary text.'

$recommendedDims = ($launcher -match '\$recommendedActionValueLabel\s*=\s*New-DanewSummaryValueLabel.*-Width\s+260\s+-Height\s+36')
$results += Add-UX2DResult -Name 'recommended_action_not_truncated' -Passed $recommendedDims -Details 'Recommended action uses expanded size to avoid truncation.'

$primaryButtons = ($launcher -match "ANALYZE WINDOWS LOGS") -and ($launcher -match "ANALYZE CRASH CAUSES")
$noMainScrollbar = ($launcher -match '\$form\.AutoScroll\s*=\s*\$false')
$results += Add-UX2DResult -Name 'primary_buttons_visible_without_scroll' -Passed ($primaryButtons -and $noMainScrollbar) -Details 'Primary diagnostic buttons remain visible without scroll.'

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

$jsonPath = Join-Path $OutputDirectory 'ux2d-tests-report.json'
$txtPath = Join-Path $OutputDirectory 'ux2d-tests-report.txt'

$report | ConvertTo-Json -Depth 20 | Set-Content -Path $jsonPath -Encoding UTF8

$lines = @(
    'UX-2D Tests',
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

Write-Host ('UX-2D test report JSON: ' + $jsonPath)
Write-Host ('UX-2D test report TXT: ' + $txtPath)

if ($summary.failed -gt 0) {
    exit 1
}
