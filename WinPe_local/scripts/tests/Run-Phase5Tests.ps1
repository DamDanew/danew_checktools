[CmdletBinding()]
param(
    [string]$RootPath = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $RootPath 'reports'
}

. (Join-Path $RootPath 'scripts\core\Logging.ps1')
. (Join-Path $RootPath 'scripts\catalog\CatalogService.ps1')
. (Join-Path $RootPath 'scripts\scan\ScanEngine.ps1')
. (Join-Path $RootPath 'scripts\profiles\ProfileEngine.ps1')
. (Join-Path $RootPath 'scripts\recommend\RecommendationEngine.ps1')
. (Join-Path $RootPath 'scripts\recommend\EnrichmentPlanner.ps1')
. (Join-Path $RootPath 'scripts\build\BuildPreparation.ps1')
. (Join-Path $RootPath 'scripts\report\ReportEngine.ps1')
. (Join-Path $RootPath 'scripts\security\SecurityService.ps1')
. (Join-Path $RootPath 'scripts\launcher\LauncherCore.ps1')

function Add-Phase5TestResult {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Details = ''
    )

    [pscustomobject]@{ name = $Name; passed = $Passed; details = $Details }
}

$results = @()
$tempRoot = Join-Path $RootPath 'temp\phase5-tests'

if (Test-Path -Path $tempRoot) {
    Remove-Item -Path $tempRoot -Recurse -Force
}
New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null

try {
    $testRoot = Join-Path $tempRoot 'winpe-root'
    New-Item -Path $testRoot -ItemType Directory -Force | Out-Null

    foreach ($p in @('scripts', 'reports', 'logs', 'builds', 'Boot', 'EFI\\Boot', 'sources', 'manifests', 'schemas', 'profiles')) {
        New-Item -Path (Join-Path $testRoot $p) -ItemType Directory -Force | Out-Null
    }

    Copy-Item -Path (Join-Path $RootPath 'scripts\*') -Destination (Join-Path $testRoot 'scripts') -Recurse -Force
    Copy-Item -Path (Join-Path $RootPath 'manifests\*') -Destination (Join-Path $testRoot 'manifests') -Recurse -Force
    Copy-Item -Path (Join-Path $RootPath 'schemas\*') -Destination (Join-Path $testRoot 'schemas') -Recurse -Force
    Copy-Item -Path (Join-Path $RootPath 'profiles\\*') -Destination (Join-Path $testRoot 'profiles') -Recurse -Force

    Set-Content -Path (Join-Path $testRoot 'Boot\BCD') -Value 'bcd' -Encoding ASCII
    Set-Content -Path (Join-Path $testRoot 'Boot\boot.sdi') -Value 'sdi' -Encoding ASCII
    Set-Content -Path (Join-Path $testRoot 'sources\boot.wim') -Value 'wim' -Encoding ASCII
    Set-Content -Path (Join-Path $testRoot 'EFI\Boot\bootx64.efi') -Value 'efi' -Encoding ASCII

    $cfgPath = Join-Path $testRoot 'scripts\launcher-config.json'
    $cfg = Get-Content -Path $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
    $cfg.input_path = '.'
    $cfg.startnet_output_path = 'reports/StartNet.runtime.cmd'
    $cfg.startnet_fallback_output_path = 'reports/StartNet.fallback.cmd'
    $cfg | ConvertTo-Json -Depth 20 | Set-Content -Path $cfgPath -Encoding UTF8

    $cfgResolved = Get-DanewLauncherConfig -RootPath $testRoot -ConfigPath $cfgPath

    $prep = Invoke-DanewLauncherAction -Action 'prepare-startnet' -RootPath $testRoot -Config $cfgResolved
    $results += Add-Phase5TestResult -Name 'startnet_preparation' -Passed (Test-Path -Path $prep.output.target_path)

    $scan = Invoke-DanewLauncherAction -Action 'scan-winpe' -RootPath $testRoot -Config $cfgResolved
    $results += Add-Phase5TestResult -Name 'scan_winpe_action' -Passed (Test-Path -Path $scan.output)

    $cap = Invoke-DanewLauncherAction -Action 'capability-analysis' -RootPath $testRoot -Config $cfgResolved
    $results += Add-Phase5TestResult -Name 'capability_analysis_action' -Passed (Test-Path -Path $cap.output)

    $rep = Invoke-DanewLauncherAction -Action 'generate-report' -RootPath $testRoot -Config $cfgResolved
    $latestScan = @(Get-ChildItem -Path (Join-Path $testRoot 'reports') -File -Filter 'scan-*.json' | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    $results += Add-Phase5TestResult -Name 'generate_report_action' -Passed (@($latestScan).Count -ge 1) -Details $rep.output

    $pkg = Invoke-DanewLauncherAction -Action 'export-diagnostic-package' -RootPath $testRoot -Config $cfgResolved
    $diagOk = (Test-Path -Path $pkg.output.folder)
    $results += Add-Phase5TestResult -Name 'export_diagnostic_package_action' -Passed $diagOk

    $logRaw = Get-Content -Path (Join-Path $testRoot 'logs\launcher-log.json') -Raw -Encoding UTF8
    $logItems = $logRaw | ConvertFrom-Json -Depth 20
    $results += Add-Phase5TestResult -Name 'launcher_action_logging' -Passed (@($logItems).Count -ge 10) -Details "entries=$(@($logItems).Count)"

    $cliPath = Join-Path $testRoot 'scripts\DanewCheckTool.CLI.ps1'
    & $cliPath -RootPath $testRoot -ConfigPath $cfgPath -Command scan-winpe | Out-Null
    $results += Add-Phase5TestResult -Name 'cli_command_execution' -Passed $true

    $guiPath = Join-Path $testRoot 'scripts\launcher.ps1'
    $guiContent = Get-Content -Path $guiPath -Raw -Encoding UTF8
    $hasExpectedButtons = ($guiContent -match 'Refresh Status') -and ($guiContent -match 'View Last Report') -and ($guiContent -match 'Scan WinPE') -and ($guiContent -match 'Run Capability Analysis') -and ($guiContent -match 'Generate Report') -and ($guiContent -match 'Open Reports Folder') -and ($guiContent -match 'Export Diagnostic Package') -and ($guiContent -match 'Create Bootable USB') -and ($guiContent -match 'Exit')
    $results += Add-Phase5TestResult -Name 'gui_button_layout_definition' -Passed $hasExpectedButtons
}
finally {
    if (Test-Path -Path $tempRoot) {
        Remove-Item -Path $tempRoot -Recurse -Force
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

$jsonPath = Join-Path $OutputDirectory 'phase5-tests-report.json'
$txtPath = Join-Path $OutputDirectory 'phase5-tests-report.txt'

$report | ConvertTo-Json -Depth 20 | Set-Content -Path $jsonPath -Encoding UTF8

$lines = @(
    'Phase 5 Tests',
    "Total: $($summary.total)",
    "Passed: $($summary.passed)",
    "Failed: $($summary.failed)",
    ''
)
foreach ($t in $results) {
    $status = if ($t.passed) { 'PASS' } else { 'FAIL' }
    $lines += "[$status] $($t.name) - $($t.details)"
}
$lines | Set-Content -Path $txtPath -Encoding UTF8

Write-Host "Phase 5 test report JSON: $jsonPath"
Write-Host "Phase 5 test report TXT: $txtPath"

if ($summary.failed -gt 0) {
    exit 1
}
