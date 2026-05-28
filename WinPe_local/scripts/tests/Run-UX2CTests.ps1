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

function Add-UX2CResult {
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
$results += Add-UX2CResult -Name 'launcher_parser_ok' -Passed (-not $errors) -Details ($(if ($errors) { ($errors | Select-Object -First 1).Message } else { 'PowerShell parser clean' }))

$reportDisabled = ($launcher -match 'Ouvrir le rapport SAV \(indisponible\)') -and ($launcher -match '\$button\.Enabled\s*=\s*\$false')
$results += Add-UX2CResult -Name 'sav_report_button_disabled_when_missing' -Passed $reportDisabled -Details 'Open SAV Report disabled and relabeled when report is absent.'

$reportEnabled = ($launcher -match 'OUVRIR LE RAPPORT SAV') -and ($launcher -match '\$button\.Enabled\s*=\s*\$true')
$results += Add-UX2CResult -Name 'sav_report_button_enabled_when_present' -Passed $reportEnabled -Details 'Open SAV Report enabled with standard label when report exists.'

$readyBadge = ($launcher -match '\$overallBadgeLabel\.Text\s*=\s*''En attente''') -and ($launcher -notmatch '\$overallBadgeLabel\.Text\s*=\s*''INFO''')
$results += Add-UX2CResult -Name 'initial_badge_ready_not_info' -Passed $readyBadge -Details 'Initial overall badge shows Waiting instead of INFO.'

$subtitleOk = $launcher -match '\$subtitleLabel\.Left\s*=\s*72'
$results += Add-UX2CResult -Name 'subtitle_aligned_with_logo' -Passed $subtitleOk -Details 'Subtitle offset aligns with logo and title.'

$chipsOk = ($launcher -match 'Execution :') -and ($launcher -match 'Windows :') -and ($launcher -match 'USB :')
$results += Add-UX2CResult -Name 'runtime_chips_visible' -Passed $chipsOk -Details 'Runtime/Windows/USB chips rendered in SAV summary.'

$timingLabelOk = $launcher -match '\$primaryGroup\.Controls\.Add\(\$offlineTimingLabel\)'
$results += Add-UX2CResult -Name 'offline_timing_label_visible' -Passed $timingLabelOk -Details 'Offline timing label is added to primary group.'

$infoColor = $launcher -match '(?s)INFO.*FromArgb\(37, 99, 235\)'
$runningColor = $launcher -match '(?s)RUNNING.*FromArgb\(245, 158, 11\)'
$results += Add-UX2CResult -Name 'running_color_differs_from_info' -Passed ($infoColor -and $runningColor) -Details 'RUNNING uses orange while INFO stays blue.'

$noVerbosePopup = ($launcher -notmatch 'Offline logs analysis complete\.') -and ($launcher -match 'Analyse des journaux hors ligne terminee\. Consulter le resume SAV pour le detail\.')
$results += Add-UX2CResult -Name 'offline_logs_popup_removed' -Passed $noVerbosePopup -Details 'Verbose completion popup removed and replaced with short progress line.'

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

$jsonPath = Join-Path $OutputDirectory 'ux2c-tests-report.json'
$txtPath = Join-Path $OutputDirectory 'ux2c-tests-report.txt'

$report | ConvertTo-Json -Depth 20 | Set-Content -Path $jsonPath -Encoding UTF8

$lines = @(
    'UX-2C Tests',
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

Write-Host ('UX-2C test report JSON: ' + $jsonPath)
Write-Host ('UX-2C test report TXT: ' + $txtPath)

if ($summary.failed -gt 0) {
    exit 1
}
