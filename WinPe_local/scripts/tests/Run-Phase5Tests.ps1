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

function Invoke-StartNetRuntimeSelectionScenario {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TemplateContent,
        [Parameter(Mandatory = $true)]
        [string]$ScenarioRoot,
        [switch]$CreatePwsh,
        [switch]$CreateWindowsPowerShell
    )

    $scenarioRootFull = [System.IO.Path]::GetFullPath($ScenarioRoot)
    $pwshPath = Join-Path $scenarioRootFull 'pwsh\pwsh.exe'
    $windowsPowerShellPath = Join-Path $scenarioRootFull 'powershell\powershell.exe'
    $resultPath = Join-Path $scenarioRootFull 'selected-runtime.txt'
    $scriptPath = Join-Path $scenarioRootFull 'SelectRuntime.cmd'
    $pathIsolationDir = Join-Path $scenarioRootFull 'path-bin'

    New-Item -Path $scenarioRootFull -ItemType Directory -Force | Out-Null
    New-Item -Path $pathIsolationDir -ItemType Directory -Force | Out-Null

    if (($TemplateContent -notmatch 'if exist X:\\Program Files\\PowerShell\\7\\pwsh\.exe set DANEW_PS=X:\\Program Files\\PowerShell\\7\\pwsh\.exe') -or
        ($TemplateContent -notmatch 'if not defined DANEW_PS if exist X:\\Windows\\System32\\WindowsPowerShell\\v1\.0\\powershell\.exe set DANEW_PS=X:\\Windows\\System32\\WindowsPowerShell\\v1\.0\\powershell\.exe')) {
        throw 'Template content no longer matches the expected runtime selection order.'
    }

    if ($CreatePwsh) {
        $pwshDir = Split-Path -Parent $pwshPath
        New-Item -Path $pwshDir -ItemType Directory -Force | Out-Null
        Set-Content -Path $pwshPath -Value 'pwsh' -Encoding ASCII
    }

    if ($CreateWindowsPowerShell) {
        $powershellDir = Split-Path -Parent $windowsPowerShellPath
        New-Item -Path $powershellDir -ItemType Directory -Force | Out-Null
        Set-Content -Path $windowsPowerShellPath -Value 'powershell' -Encoding ASCII
    }

    $scenarioLines = @(
        '@echo off',
        'setlocal',
        "set PATH=$pathIsolationDir",
        'set DANEW_PS=',
        "if exist $pwshPath set DANEW_PS=$pwshPath",
        "if not defined DANEW_PS if exist $windowsPowerShellPath set DANEW_PS=$windowsPowerShellPath",
        'if not defined DANEW_PS (',
        '  where pwsh.exe >nul 2>nul',
        '  if not errorlevel 1 set DANEW_PS=pwsh.exe',
        ')',
        'if not defined DANEW_PS (',
        '  where powershell.exe >nul 2>nul',
        '  if not errorlevel 1 set DANEW_PS=powershell.exe',
        ')',
        ("echo DANEW_PS=%DANEW_PS%>`"{0}`"" -f $resultPath)
    )

    $scenarioLines | Set-Content -Path $scriptPath -Encoding ASCII

    $output = & cmd.exe /c $scriptPath 2>&1 | Out-String
    $selectedRuntime = ''
    if (Test-Path -Path $resultPath) {
        $selectedRuntime = (Get-Content -Path $resultPath -Raw -Encoding ASCII).Trim()
    }

    return [pscustomobject]@{
        output = $output.Trim()
        selected_runtime = $selectedRuntime
        pwsh_path = $pwshPath
        windows_powershell_path = $windowsPowerShellPath
    }
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
    $startNetContent = Get-Content -Path $prep.output.target_path -Raw -Encoding ASCII
    $prefersPwsh = ($startNetContent -match 'X:\\Program Files\\PowerShell\\7\\pwsh\.exe') -and ($startNetContent -match 'where pwsh\.exe')
    $results += Add-Phase5TestResult -Name 'startnet_prefers_pwsh_release' -Passed $prefersPwsh
    $windowsPwshFallback = $startNetContent -match 'if not defined DANEW_PS if exist X:\\Windows\\System32\\WindowsPowerShell\\v1\.0\\powershell\.exe set DANEW_PS=X:\\Windows\\System32\\WindowsPowerShell\\v1\.0\\powershell\.exe'
    $results += Add-Phase5TestResult -Name 'startnet_fallback_to_windows_powershell' -Passed $windowsPwshFallback
    $missingRuntimeMessage = ($startNetContent -match 'POWERSHELL_MISSING') -and ($startNetContent -match 'PowerShell is not available in this WinPE image') -and ($startNetContent -match 'goto :END')
    $results += Add-Phase5TestResult -Name 'startnet_missing_runtime_guard' -Passed $missingRuntimeMessage
    $runtimeScenarioRoot = Join-Path $testRoot 'runtime-selection'
    $preferPwshScenario = Invoke-StartNetRuntimeSelectionScenario -TemplateContent $startNetContent -ScenarioRoot (Join-Path $runtimeScenarioRoot 'prefer-pwsh') -CreatePwsh -CreateWindowsPowerShell
    $results += Add-Phase5TestResult -Name 'startnet_runtime_selection_prefers_pwsh' -Passed ($preferPwshScenario.selected_runtime -eq ('DANEW_PS=' + $preferPwshScenario.pwsh_path)) -Details $preferPwshScenario.selected_runtime
    $fallbackScenario = Invoke-StartNetRuntimeSelectionScenario -TemplateContent $startNetContent -ScenarioRoot (Join-Path $runtimeScenarioRoot 'fallback-powershell') -CreateWindowsPowerShell
    $results += Add-Phase5TestResult -Name 'startnet_runtime_selection_fallback_powershell' -Passed ($fallbackScenario.selected_runtime -eq ('DANEW_PS=' + $fallbackScenario.windows_powershell_path)) -Details $fallbackScenario.selected_runtime
    $missingScenario = Invoke-StartNetRuntimeSelectionScenario -TemplateContent $startNetContent -ScenarioRoot (Join-Path $runtimeScenarioRoot 'missing-runtime')
    $results += Add-Phase5TestResult -Name 'startnet_runtime_selection_missing_runtime' -Passed ($missingScenario.selected_runtime -eq 'DANEW_PS=') -Details $missingScenario.selected_runtime

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
