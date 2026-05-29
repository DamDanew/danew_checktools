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

function Add-UXEncodingResult {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Details = ''
    )

    return [pscustomobject]@{ name = $Name; passed = $Passed; details = $Details }
}

$results = @()
$launcherPath = Join-Path $RootPath 'scripts\launcher.ps1'
$launcherContent = Get-Content -Path $launcherPath -Raw -Encoding UTF8

$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($launcherPath, [ref]$tokens, [ref]$errors) | Out-Null
$results += Add-UXEncodingResult -Name 'launcher_parser_ok' -Passed (-not $errors) -Details ($(if ($errors) { ($errors | Select-Object -First 1).Message } else { 'PowerShell parser clean' }))

$uiLinePattern = "(New-DanewActionButton\s+-Text\s+'|New-DanewPrimaryDiagnosticButton\s+-Name\s+'[^']+'\s+-Text\s+'|\.Text\s*=\s+'|Show-DanewSecondaryPanelDialog\s+-Title\s+'|New-DanewSummaryFieldLabel\s+-Caption\s+')"
$uiLines = @($launcherContent -split "`r?`n" | Where-Object { $_ -match $uiLinePattern })
$uiWithAccents = @($uiLines | Where-Object { $_ -match '[^\x00-\x7F]' })
$results += Add-UXEncodingResult -Name 'launcher_gui_labels_ascii_only' -Passed (@($uiWithAccents).Count -eq 0) -Details ($(if (@($uiWithAccents).Count -eq 0) { 'All WinForms visible labels are ASCII-safe.' } else { 'Non-ASCII lines: ' + [string]@($uiWithAccents).Count }))

$mojibakePatterns = @(
    [string][char]0x00C3,
    [string][char]0x00C2,
    (([string][char]0x00E2) + ([string][char]0x20AC))
)
$mojibakeFound = @($mojibakePatterns | Where-Object { $launcherContent -match [regex]::Escape($_) })
$results += Add-UXEncodingResult -Name 'known_mojibake_absent' -Passed (@($mojibakeFound).Count -eq 0) -Details ($(if (@($mojibakeFound).Count -eq 0) { 'No mojibake markers found in launcher.ps1.' } else { 'Found: ' + ($mojibakeFound -join ', ') }))

$requiredLabels = @(
    'ANALYSE RAPIDE',
    'CRIT/ERR/AVERT.',
    'Critique',
    'Erreur',
    'Avert.',
    'Evenements/log',
    'Tout',
    'ANALYSE COMPLETE',
    'ANALYSER CAUSES',
    'OUVRIR LE RAPPORT SAV',
    'COMPLET TOUS LES LOGS',
    'RAPIDE CRIT/ERR/AVERT.',
    'EXPORTER LE DOSSIER SAV',
    'EXPORT EVTX CIBLE',
    'ACTIONS RECOMMANDEES',
    'AFFICHER LES OUTILS AVANCES',
    'MASQUER LES OUTILS AVANCES',
    'AFFICHER LES DETAILS TECHNIQUES',
    'MASQUER LES DETAILS TECHNIQUES',
    'OUTILS AVANCES',
    'ACTUALISER LE RESUME',
    'SCAN CAPACITES WINPE',
    'VERIFIER WINPE',
    'GENERER LE RAPPORT DE BASE',
    'DIAGNOSTIC AVANCE'
)
$missingLabels = @($requiredLabels | Where-Object { $launcherContent -notmatch [regex]::Escape($_) })
$results += Add-UXEncodingResult -Name 'ascii_safe_gui_wording_present' -Passed (@($missingLabels).Count -eq 0) -Details ($(if (@($missingLabels).Count -eq 0) { 'ASCII-safe GUI wording detected.' } else { 'Missing labels: ' + ($missingLabels -join ', ') }))

$reportSources = @(
    (Join-Path $RootPath 'scripts\\report\\HtmlReportShell.ps1')
)
$missingMetaSource = @()
foreach ($source in @($reportSources)) {
    if (-not (Test-Path -Path $source)) {
        $missingMetaSource += ('missing_file:' + $source)
        continue
    }

    $sourceText = Get-Content -Path $source -Raw -Encoding UTF8
    if ($sourceText -notmatch '<meta\s+charset="utf-8"') {
        $missingMetaSource += [System.IO.Path]::GetFileName($source)
    }
}

$results += Add-UXEncodingResult -Name 'html_report_utf8_meta_preserved' -Passed (@($missingMetaSource).Count -eq 0) -Details ($(if (@($missingMetaSource).Count -eq 0) { 'UTF-8 meta charset preserved in report templates.' } else { 'Missing in: ' + ($missingMetaSource -join ', ') }))

$engine = if (Get-Command -Name powershell -ErrorAction SilentlyContinue) { 'powershell' } else { 'pwsh' }

$ux2Script = Join-Path $RootPath 'scripts\tests\Run-UX2Tests.ps1'
$ux2ExitCode = 1
$ux2Output = ''
try {
    $ux2Output = & $engine -NoProfile -ExecutionPolicy Bypass -File $ux2Script -RootPath $RootPath -OutputDirectory $OutputDirectory 2>&1 | Out-String
    $ux2ExitCode = $LASTEXITCODE
}
catch {
    $ux2Output = $_.Exception.Message
    $ux2ExitCode = 1
}
$results += Add-UXEncodingResult -Name 'existing_ux2_tests_pass' -Passed ($ux2ExitCode -eq 0) -Details ('exit=' + [string]$ux2ExitCode)

$reportFrScript = Join-Path $RootPath 'scripts\tests\Run-ReportFrenchTests.ps1'
$reportFrExitCode = 1
$reportFrOutput = ''
try {
    $reportFrOutput = & $engine -NoProfile -ExecutionPolicy Bypass -File $reportFrScript -RootPath $RootPath -OutputDirectory $OutputDirectory 2>&1 | Out-String
    $reportFrExitCode = $LASTEXITCODE
}
catch {
    $reportFrOutput = $_.Exception.Message
    $reportFrExitCode = 1
}
$results += Add-UXEncodingResult -Name 'existing_report_french_tests_pass' -Passed ($reportFrExitCode -eq 0) -Details ('exit=' + [string]$reportFrExitCode)

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

$jsonPath = Join-Path $OutputDirectory 'ux-encoding-tests-report.json'
$txtPath = Join-Path $OutputDirectory 'ux-encoding-tests-report.txt'

$report | ConvertTo-Json -Depth 20 | Set-Content -Path $jsonPath -Encoding UTF8

$lines = @(
    'UX Encoding Tests',
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

Write-Host ('UX encoding test report JSON: ' + $jsonPath)
Write-Host ('UX encoding test report TXT: ' + $txtPath)

if ($summary.failed -gt 0) {
    exit 1
}
