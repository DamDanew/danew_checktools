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

. (Join-Path $RootPath 'scripts\launcher\LauncherCore.ps1')

function Add-BrowserIntegrationResult {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Details = ''
    )

    return [pscustomobject]@{ name = $Name; passed = $Passed; details = $Details }
}

function New-BrowserIntegrationFixture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [string]$BrowserExe = ''
    )

    $root = Join-Path $env:TEMP ('danew-browser-' + $Name + '-' + ([guid]::NewGuid().ToString('N')))
    foreach ($folder in @('reports', 'logs', 'scripts', 'tools\browser')) {
        New-Item -Path (Join-Path $root $folder) -ItemType Directory -Force | Out-Null
    }

    foreach ($report in @('REPORTS_INDEX.html', 'reports-index.html', 'sav-diagnostic-report.html', 'timeline-raw.html', 'evtx-events.html')) {
        '<html><body>fixture</body></html>' | Set-Content -Path (Join-Path $root ('reports\' + $report)) -Encoding UTF8
    }

    foreach ($txt in @('evtx-sav-summary.txt', 'winpe-real-run-summary.txt', 'REPORTS_README.txt')) {
        'fixture fallback' | Set-Content -Path (Join-Path $root ('reports\' + $txt)) -Encoding UTF8
    }

    if (-not [string]::IsNullOrWhiteSpace($BrowserExe)) {
        'fixture browser placeholder' | Set-Content -Path (Join-Path $root ('tools\browser\' + $BrowserExe)) -Encoding ASCII
    }

    $config = [pscustomobject]@{
        reports_path = Join-Path $root 'reports'
        logs_path = Join-Path $root 'logs'
        launcher_log_path = Join-Path $root 'logs\launcher-log.json'
        gui_status_snapshot_path = Join-Path $root 'reports\gui-status-snapshot.json'
    }

    Initialize-DanewLauncherPaths -Config $config
    return [pscustomobject]@{ root = $root; config = $config }
}

$results = @()

$noBrowser = New-BrowserIntegrationFixture -Name 'missing'
$noBrowserResult = Export-DanewBrowserDetection -RootPath $noBrowser.root -Config $noBrowser.config
$results += Add-BrowserIntegrationResult -Name 'no_browser_warning_not_crash' -Passed ($noBrowserResult.detection.status -eq 'WARNING' -and -not $noBrowserResult.detection.executable_exists) -Details ('status=' + [string]$noBrowserResult.detection.status)

foreach ($browser in @('chromium.exe', 'chrome.exe', 'msedge.exe')) {
    $fixture = New-BrowserIntegrationFixture -Name ($browser -replace '\.exe$', '') -BrowserExe $browser
    $detected = Export-DanewBrowserDetection -RootPath $fixture.root -Config $fixture.config
    $results += Add-BrowserIntegrationResult -Name (($browser -replace '\.exe$', '') + '_present_pass') -Passed ($detected.detection.status -eq 'PASS' -and $detected.detection.browser_executable -eq $browser) -Details ('path=' + [string]$detected.detection.browser_path)
}

$commandGenerated = @($noBrowserResult.detection.report_opening | Where-Object { $_.name -eq 'REPORTS_INDEX.html' -and $_.exists -and -not [string]::IsNullOrWhiteSpace([string]$_.open_command) }).Count -eq 1
$results += Add-BrowserIntegrationResult -Name 'report_open_command_generated' -Passed $commandGenerated -Details 'REPORTS_INDEX.html has a prepared command.'

$fallbackMessageOk = ([string]$noBrowserResult.detection.fallback_message -eq 'Navigateur HTML non disponible. Consultez les rapports TXT/CSV dans le dossier reports.')
$fallbackTxtOk = @($noBrowserResult.detection.fallback_txt | Where-Object { $_.exists }).Count -ge 3
$results += Add-BrowserIntegrationResult -Name 'fallback_txt_message_exists' -Passed ($fallbackMessageOk -and $fallbackTxtOk) -Details ('fallback_txt=' + [string]@($noBrowserResult.detection.fallback_txt | Where-Object { $_.exists }).Count)

$launcherPath = Join-Path $RootPath 'scripts\launcher.ps1'
$launcher = Get-Content -Path $launcherPath -Raw -Encoding UTF8
$launcherButtonsOk = ($launcher -match 'open-sav-report') -and ($launcher -match 'open-timeline-report') -and ($launcher -match 'Open-DanewReportFile') -and ($launcher -match 'Navigateur HTML non disponible')
$results += Add-BrowserIntegrationResult -Name 'launcher_report_buttons_still_work' -Passed $launcherButtonsOk -Details 'Report button handlers and fallback message present.'

$noHardDependency = ($noBrowserResult.detection.status -eq 'WARNING') -and ($launcher -notmatch 'throw.+browser') -and ($launcher -notmatch 'WebView2|Electron|PresentationFramework')
$results += Add-BrowserIntegrationResult -Name 'no_hard_dependency_on_browser' -Passed $noHardDependency -Details 'Missing browser is warning only.'

$browserFiles = @(
    (Join-Path $RootPath 'scripts\launcher.ps1'),
    (Join-Path $RootPath 'scripts\SetHtmlAssociation.cmd'),
    (Join-Path $RootPath 'scripts\OpenReportsIndex.cmd'),
    (Join-Path $RootPath 'scripts\launcher\LauncherCore.ps1')
)
$internetHits = @()
foreach ($file in @($browserFiles)) {
    $internetHits += @(Select-String -Path $file -Pattern 'https?://|Invoke-WebRequest|curl |wget ' -ErrorAction SilentlyContinue)
}
$results += Add-BrowserIntegrationResult -Name 'no_internet_dependency' -Passed (@($internetHits).Count -eq 0 -and -not [bool]$noBrowserResult.detection.internet_required) -Details ('internet_hits=' + [string]@($internetHits).Count)

$reportNames = @($noBrowserResult.detection.report_opening | ForEach-Object { $_.name })
$expectedNames = @('REPORTS_INDEX.html', 'reports-index.html', 'sav-diagnostic-report.html', 'timeline-raw.html', 'evtx-events.html')
$pathsUnchanged = @($expectedNames | Where-Object { $_ -notin $reportNames }).Count -eq 0
$results += Add-BrowserIntegrationResult -Name 'existing_report_paths_unchanged' -Passed $pathsUnchanged -Details ('reports=' + ($reportNames -join ', '))

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

$jsonPath = Join-Path $OutputDirectory 'browser-integration-tests-report.json'
$txtPath = Join-Path $OutputDirectory 'browser-integration-tests-report.txt'

$report | ConvertTo-Json -Depth 30 | Set-Content -Path $jsonPath -Encoding UTF8

$lines = @(
    'Browser Integration Tests',
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

Write-Host ('Browser integration test report JSON: ' + $jsonPath)
Write-Host ('Browser integration test report TXT: ' + $txtPath)

if ($summary.failed -gt 0) {
    exit 1
}
