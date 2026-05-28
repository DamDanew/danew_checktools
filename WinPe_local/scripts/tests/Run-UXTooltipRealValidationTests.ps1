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

function Add-UXTooltipRealValidationResult {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Details = ''
    )

    return [pscustomobject]@{ name = $Name; passed = $Passed; details = $Details }
}

$results = @()
$helperScript = Join-Path $RootPath 'scripts\tests\Invoke-RealWinPETooltipValidation.ps1'
$results += Add-UXTooltipRealValidationResult -Name 'helper_script_exists' -Passed (Test-Path -Path $helperScript) -Details $helperScript

$tempRoot = Join-Path $env:TEMP ('danew-tooltip-' + [guid]::NewGuid().ToString('N'))
New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null
$tempOut = Join-Path $tempRoot 'reports'
New-Item -Path $tempOut -ItemType Directory -Force | Out-Null

$launcherSource = Join-Path $RootPath 'scripts\launcher.ps1'
$launcherFixture = Join-Path $tempRoot 'launcher-mojibake.ps1'
Copy-Item -Path $launcherSource -Destination $launcherFixture -Force
$launcherText = Get-Content -Path $launcherFixture -Raw -Encoding UTF8
$launcherText = $launcherText -replace 'Cree un package SAV avec les rapports, journaux et exports disponibles\.', 'Cree un package SAV avec les rapports, journaux et exports disponibles. Ã'
Set-Content -Path $launcherFixture -Value $launcherText -Encoding UTF8

$engine = if (Get-Command -Name powershell -ErrorAction SilentlyContinue) { 'powershell' } else { 'pwsh' }

$nominalExit = 1
$nominalOutput = ''
try {
    $nominalOutput = & $engine -NoProfile -ExecutionPolicy Bypass -File $helperScript -RootPath $RootPath -OutputDirectory $tempOut 2>&1 | Out-String
    $nominalExit = $LASTEXITCODE
}
catch {
    $nominalOutput = $_.Exception.Message
    $nominalExit = 1
}
$results += Add-UXTooltipRealValidationResult -Name 'nominal_helper_exit_zero' -Passed ($nominalExit -eq 0) -Details ('exit=' + [string]$nominalExit)

$nominalJson = Join-Path $tempOut 'real-winpe-tooltip-validation.json'
$nominalChecklist = Join-Path $tempOut 'real-winpe-tooltip-checklist.txt'
$results += Add-UXTooltipRealValidationResult -Name 'nominal_outputs_written' -Passed ((Test-Path -Path $nominalJson) -and (Test-Path -Path $nominalChecklist)) -Details ('json=' + [string](Test-Path -Path $nominalJson) + '; checklist=' + [string](Test-Path -Path $nominalChecklist))

$nominalReport = $null
if (Test-Path -Path $nominalJson) {
    $nominalReport = Get-Content -Path $nominalJson -Raw -Encoding UTF8 | ConvertFrom-Json
}
$results += Add-UXTooltipRealValidationResult -Name 'nominal_status_limited_or_pass' -Passed ($null -ne $nominalReport -and $nominalReport.global_status -in @('LIMITED', 'PASS')) -Details ($(if ($nominalReport) { 'status=' + [string]$nominalReport.global_status } else { 'missing report' }))
$results += Add-UXTooltipRealValidationResult -Name 'nominal_static_validation_pass' -Passed ($null -ne $nominalReport -and $nominalReport.static_status -eq 'PASS') -Details ($(if ($nominalReport) { 'static=' + [string]$nominalReport.static_status } else { 'missing report' }))
$results += Add-UXTooltipRealValidationResult -Name 'nominal_manual_checklist_required' -Passed ($null -ne $nominalReport -and [bool]$nominalReport.manual_visual_validation_required) -Details 'Manual checklist is required for real hover confirmation.'

$fixtureExit = 1
$fixtureOut = Join-Path $tempRoot 'fixture-reports'
New-Item -Path $fixtureOut -ItemType Directory -Force | Out-Null
try {
    $null = & $engine -NoProfile -ExecutionPolicy Bypass -File $helperScript -RootPath $RootPath -OutputDirectory $fixtureOut -LauncherPath $launcherFixture 2>&1 | Out-String
    $fixtureExit = $LASTEXITCODE
}
catch {
    $fixtureExit = 1
}
$results += Add-UXTooltipRealValidationResult -Name 'fixture_helper_fails_on_mojibake' -Passed ($fixtureExit -ne 0) -Details ('exit=' + [string]$fixtureExit)

$fixtureJson = Join-Path $fixtureOut 'real-winpe-tooltip-validation.json'
$fixtureReport = $null
if (Test-Path -Path $fixtureJson) {
    $fixtureReport = Get-Content -Path $fixtureJson -Raw -Encoding UTF8 | ConvertFrom-Json
}
$results += Add-UXTooltipRealValidationResult -Name 'fixture_report_written' -Passed (Test-Path -Path $fixtureJson) -Details $fixtureJson
$results += Add-UXTooltipRealValidationResult -Name 'fixture_detects_mojibake' -Passed ($null -ne $fixtureReport -and [int]$fixtureReport.mojibake_hits -gt 0) -Details ($(if ($fixtureReport) { 'mojibake_hits=' + [string]$fixtureReport.mojibake_hits } else { 'missing report' }))
$results += Add-UXTooltipRealValidationResult -Name 'fixture_static_validation_fails' -Passed ($null -ne $fixtureReport -and $fixtureReport.static_status -eq 'FAIL') -Details ($(if ($fixtureReport) { 'static=' + [string]$fixtureReport.static_status } else { 'missing report' }))

$encodingScript = Join-Path $RootPath 'scripts\tests\Run-UXEncodingTests.ps1'
$encodingExit = 1
try {
    $null = & $engine -NoProfile -ExecutionPolicy Bypass -File $encodingScript -RootPath $RootPath -OutputDirectory $OutputDirectory 2>&1 | Out-String
    $encodingExit = $LASTEXITCODE
}
catch {
    $encodingExit = 1
}
$results += Add-UXTooltipRealValidationResult -Name 'existing_encoding_tests_pass' -Passed ($encodingExit -eq 0) -Details ('exit=' + [string]$encodingExit)

$summary = [pscustomobject]@{
    total = @($results).Count
    passed = @($results | Where-Object { $_.passed }).Count
    failed = @($results | Where-Object { -not $_.passed }).Count
}

$report = [pscustomobject]@{
    timestamp = (Get-Date).ToString('s')
    root_path = $RootPath
    output_directory = $OutputDirectory
    summary = $summary
    tests = $results
}

if (-not (Test-Path -Path $OutputDirectory)) {
    New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
}

$jsonPath = Join-Path $OutputDirectory 'ux-tooltip-real-validation-tests-report.json'
$txtPath = Join-Path $OutputDirectory 'ux-tooltip-real-validation-tests-report.txt'

$report | ConvertTo-Json -Depth 20 | Set-Content -Path $jsonPath -Encoding UTF8

$lines = @(
    'UX Tooltip Real Validation Tests',
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

Write-Host ('UX tooltip real validation test report JSON: ' + $jsonPath)
Write-Host ('UX tooltip real validation test report TXT: ' + $txtPath)

if ($summary.failed -gt 0) {
    exit 1
}
