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

function Add-WinPEPrecheckResult {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Details = ''
    )

    [pscustomobject]@{ name = $Name; passed = $Passed; details = $Details }
}

function New-WinPEPrecheckTestRoot {
    param([Parameter(Mandatory = $true)][string]$BasePath)

    $tempRoot = Join-Path $BasePath 'temp\winpe-precheck-tests'
    if (Test-Path -Path $tempRoot) {
        Remove-Item -Path $tempRoot -Recurse -Force
    }

    New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null
    foreach ($folder in @('scripts', 'reports', 'logs', 'manifests')) {
        New-Item -Path (Join-Path $tempRoot $folder) -ItemType Directory -Force | Out-Null
    }

    Copy-Item -Path (Join-Path $BasePath 'scripts\*') -Destination (Join-Path $tempRoot 'scripts') -Recurse -Force
    Copy-Item -Path (Join-Path $BasePath 'manifests\evtx-event-knowledge.json') -Destination (Join-Path $tempRoot 'manifests\evtx-event-knowledge.json') -Force

    $toolsPath = Join-Path $tempRoot 'tools'
    if (Test-Path -Path $toolsPath) {
        Remove-Item -Path $toolsPath -Recurse -Force
    }

    $cfgPath = Join-Path $tempRoot 'scripts\launcher-config.json'
    $cfg = Get-Content -Path (Join-Path $BasePath 'scripts\launcher-config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $cfg.input_path = 'offline-lab'
    $cfg.reports_path = 'reports'
    $cfg.logs_path = 'logs'
    $cfg.launcher_log_path = 'logs/launcher-log.json'
    $cfg.startnet_output_path = 'reports/StartNet.generated.cmd'
    $cfg.startnet_fallback_output_path = 'reports/StartNet.generated.cmd'
    $cfg | ConvertTo-Json -Depth 20 | Set-Content -Path $cfgPath -Encoding UTF8

    [pscustomobject]@{
        root = $tempRoot
        config_path = $cfgPath
        reports_path = (Join-Path $tempRoot 'reports')
        tools_path = $toolsPath
    }
}

$results = @()
$temp = New-WinPEPrecheckTestRoot -BasePath $RootPath

try {
    . (Join-Path $temp.root 'scripts\launcher\LauncherCore.ps1')
    . (Join-Path $temp.root 'scripts\winpe\WinPEPrecheckAgent.ps1')

    $config = Get-DanewLauncherConfig -RootPath $temp.root -ConfigPath $temp.config_path
    Initialize-DanewLauncherPaths -Config $config

    $reportsPath = $config.reports_path
    if (Test-Path -Path $temp.tools_path) {
        Remove-Item -Path $temp.tools_path -Recurse -Force
    }

    $first = Invoke-DanewWinPEPrecheckAgent -RootPath $temp.root -Config $config -ApplyFixes
    $jsonPath = Join-Path $reportsPath 'winpe-precheck-report.json'
    $txtPath = Join-Path $reportsPath 'winpe-precheck-report.txt'
    $historyPath = Join-Path $reportsPath 'WinPE_precheck_history.json'

    $results += Add-WinPEPrecheckResult -Name 'precheck_reports_generated' -Passed ((Test-Path $jsonPath) -and (Test-Path $txtPath)) -Details 'JSON/TXT generated in reports'
    $results += Add-WinPEPrecheckResult -Name 'history_generated' -Passed (Test-Path $historyPath) -Details 'history file created'
    $results += Add-WinPEPrecheckResult -Name 'apply_fixes_created_tools_folder' -Passed (Test-Path $temp.tools_path) -Details 'missing tools folder recreated by agent'
    $results += Add-WinPEPrecheckResult -Name 'json_contains_checks' -Passed ((Get-Content -Path $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json).checks.Count -ge 5) -Details 'report contains checks'
    $results += Add-WinPEPrecheckResult -Name 'overall_status_valid' -Passed ($first.overall_status -in @('PASS', 'WARNING', 'FAIL')) -Details ('overall=' + [string]$first.overall_status)
    $results += Add-WinPEPrecheckResult -Name 'fix_actions_recorded' -Passed (@($first.fix_actions).Count -gt 0) -Details 'fix actions logged'

    $second = Invoke-DanewWinPEPrecheckAgent -RootPath $temp.root -Config $config -ApplyFixes
    $history = Get-Content -Path $historyPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $historyRunCount = 0
    if ($history -and $history.PSObject.Properties['runs']) {
        $historyRunCount = @($history.runs).Count
    }
    elseif ($history -is [System.Array]) {
        $historyRunCount = @($history).Count
    }
    elseif ($history) {
        $historyRunCount = 1
    }
    $results += Add-WinPEPrecheckResult -Name 'history_appends_runs' -Passed ($historyRunCount -ge 2) -Details ('history count=' + [string]$historyRunCount)
    $results += Add-WinPEPrecheckResult -Name 'launcher_action_exposed' -Passed ((Invoke-DanewLauncherAction -Action 'precheck-winpe' -RootPath $temp.root -Config $config -SuppressActionLog).action -eq 'precheck-winpe') -Details 'launcher action executed'
    $results += Add-WinPEPrecheckResult -Name 'repeat_run_still_generates_reports' -Passed ($second.artifacts.json -and (Test-Path $second.artifacts.json) -and (Test-Path $second.artifacts.txt)) -Details 'second run still emits artifacts'
}
finally {
    if (Test-Path -Path $temp.root) {
        try {
            Remove-Item -Path $temp.root -Recurse -Force -ErrorAction Stop
        }
        catch {
        }
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

$jsonPathOut = Join-Path $OutputDirectory 'winpe-precheck-tests-report.json'
$txtPathOut = Join-Path $OutputDirectory 'winpe-precheck-tests-report.txt'

$report | ConvertTo-Json -Depth 20 | Set-Content -Path $jsonPathOut -Encoding UTF8

$lines = @(
    'WinPE Precheck Tests',
    ('Total: ' + [string]$summary.total),
    ('Passed: ' + [string]$summary.passed),
    ('Failed: ' + [string]$summary.failed),
    ''
)
foreach ($result in @($results)) {
    $status = if ($result.passed) { 'PASS' } else { 'FAIL' }
    $lines += '[' + $status + '] ' + [string]$result.name + ' - ' + [string]$result.details
}
$lines | Set-Content -Path $txtPathOut -Encoding UTF8

Write-Host ('WinPE precheck test report JSON: ' + $jsonPathOut)
Write-Host ('WinPE precheck test report TXT: ' + $txtPathOut)

if ($summary.failed -gt 0) {
    exit 1
}
