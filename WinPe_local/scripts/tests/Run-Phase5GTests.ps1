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

. (Join-Path $RootPath 'scripts\launcher\LauncherCore.ps1')

function Add-Phase5GResult {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Details = ''
    )

    [pscustomobject]@{ name = $Name; passed = $Passed; details = $Details }
}

function New-Phase5GTestRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath
    )

    $tempRoot = Join-Path $BasePath 'temp\phase5g-tests'
    if (Test-Path -Path $tempRoot) {
        Remove-Item -Path $tempRoot -Recurse -Force
    }

    New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null
    foreach ($folder in @('scripts', 'reports', 'logs', 'builds', 'Boot', 'EFI\Boot', 'sources', 'manifests', 'schemas', 'profiles', 'offline-win\Windows', 'no-win', 'empty-input')) {
        New-Item -Path (Join-Path $tempRoot $folder) -ItemType Directory -Force | Out-Null
    }

    Copy-Item -Path (Join-Path $BasePath 'scripts\*') -Destination (Join-Path $tempRoot 'scripts') -Recurse -Force
    Copy-Item -Path (Join-Path $BasePath 'manifests\*') -Destination (Join-Path $tempRoot 'manifests') -Recurse -Force
    Copy-Item -Path (Join-Path $BasePath 'schemas\*') -Destination (Join-Path $tempRoot 'schemas') -Recurse -Force
    Copy-Item -Path (Join-Path $BasePath 'profiles\*') -Destination (Join-Path $tempRoot 'profiles') -Recurse -Force

    Set-Content -Path (Join-Path $tempRoot 'Boot\BCD') -Value 'bcd' -Encoding ASCII
    Set-Content -Path (Join-Path $tempRoot 'Boot\boot.sdi') -Value 'sdi' -Encoding ASCII
    Set-Content -Path (Join-Path $tempRoot 'EFI\Boot\bootx64.efi') -Value 'efi' -Encoding ASCII
    Set-Content -Path (Join-Path $tempRoot 'sources\boot.wim') -Value 'wim' -Encoding ASCII
    Set-Content -Path (Join-Path $tempRoot 'offline-win\Windows\ntoskrnl.exe') -Value 'kernel' -Encoding ASCII

    $cfgPath = Join-Path $tempRoot 'scripts\launcher-config.json'
    $cfg = Get-Content -Path (Join-Path $BasePath 'scripts\launcher-config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $cfg.input_path = 'offline-win'
    $cfg.reports_path = 'reports'
    $cfg.logs_path = 'logs'
    $cfg.launcher_log_path = 'logs/launcher-log.json'
    $cfg.gui_status_snapshot_path = 'reports/gui-status-snapshot.json'
    $cfg | ConvertTo-Json -Depth 20 | Set-Content -Path $cfgPath -Encoding UTF8

    return [pscustomobject]@{
        root = $tempRoot
        config_path = $cfgPath
        reports = Join-Path $tempRoot 'reports'
        logs = Join-Path $tempRoot 'logs'
    }
}

function Get-StepByOrder {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Steps,
        [Parameter(Mandatory = $true)]
        [int]$Order
    )

    return ($Steps | Where-Object { $_.order -eq $Order } | Select-Object -First 1)
}

function Invoke-WithOverrides {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,
        [scriptblock]$ScanOverride,
        [scriptblock]$CapabilityOverride,
        [scriptblock]$GenerateOverride,
        [scriptblock]$ExportOverride
    )

    $originalScan = $null
    $originalCapability = $null
    $originalGenerate = $null
    $originalExport = $null

    if (Get-Command -Name New-DanewSimpleScanSnapshot -ErrorAction SilentlyContinue) {
        $originalScan = ${function:script:New-DanewSimpleScanSnapshot}
    }
    if (Get-Command -Name Invoke-DanewCapabilityAnalysis -ErrorAction SilentlyContinue) {
        $originalCapability = ${function:script:Invoke-DanewCapabilityAnalysis}
    }
    if (Get-Command -Name Invoke-DanewGenerateReport -ErrorAction SilentlyContinue) {
        $originalGenerate = ${function:script:Invoke-DanewGenerateReport}
    }
    if (Get-Command -Name Export-DanewDiagnosticPackage -ErrorAction SilentlyContinue) {
        $originalExport = ${function:script:Export-DanewDiagnosticPackage}
    }

    try {
        if ($ScanOverride) {
            Set-Item -Path function:script:New-DanewSimpleScanSnapshot -Value $ScanOverride
        }
        if ($CapabilityOverride) {
            Set-Item -Path function:script:Invoke-DanewCapabilityAnalysis -Value $CapabilityOverride
        }
        if ($GenerateOverride) {
            Set-Item -Path function:script:Invoke-DanewGenerateReport -Value $GenerateOverride
        }
        if ($ExportOverride) {
            Set-Item -Path function:script:Export-DanewDiagnosticPackage -Value $ExportOverride
        }

        & $Action
    }
    finally {
        if ($null -ne $originalScan) {
            Set-Item -Path function:script:New-DanewSimpleScanSnapshot -Value $originalScan
        }
        if ($null -ne $originalCapability) {
            Set-Item -Path function:script:Invoke-DanewCapabilityAnalysis -Value $originalCapability
        }
        if ($null -ne $originalGenerate) {
            Set-Item -Path function:script:Invoke-DanewGenerateReport -Value $originalGenerate
        }
        if ($null -ne $originalExport) {
            Set-Item -Path function:script:Export-DanewDiagnosticPackage -Value $originalExport
        }
    }
}

function Invoke-DiagnosticForTest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TempRoot,
        [Parameter(Mandatory = $true)]
        [object]$Config,
        [string]$RuntimeSystemDrive = 'C:'
    )

    $progressLines = New-Object System.Collections.ArrayList
    $progress = {
        param([string]$Message)
        [void]$progressLines.Add($Message)
    }

    $result = Invoke-DanewOneClickDiagnostic -RootPath $TempRoot -Config $Config -RuntimeSystemDrive $RuntimeSystemDrive -CurrentLocationPath 'C:\' -ProgressCallback $progress
    return [pscustomobject]@{
        result = $result
        progress = @($progressLines)
    }
}

$results = @()
$temp = New-Phase5GTestRoot -BasePath $RootPath

try {
    $configBase = Get-DanewLauncherConfig -RootPath $temp.root -ConfigPath $temp.config_path

    $allPass = Invoke-WithOverrides -Action {
        Invoke-DiagnosticForTest -TempRoot $temp.root -Config $configBase
    } -ScanOverride {
        param([string]$RootPath, [object]$Config)
        $path = Join-Path $Config.reports_path 'launcher-scan-latest.json'
        [pscustomobject]@{
            scan_id = [guid]::NewGuid().ToString()
            timestamp = (Get-Date).ToString('s')
            input_path = $Config.input_path
            architecture = 'x64'
            files_scanned = 12
            tools_detected = @('powershell.exe')
            drivers_detected = @('sample.sys')
            runtimes_detected = @('powershell')
        } | ConvertTo-Json -Depth 20 | Set-Content -Path $path -Encoding UTF8
        return $path
    } -CapabilityOverride {
        param([string]$RootPath, [object]$Config)
        $capPath = Join-Path $Config.reports_path 'enrichment-plan.json'
        [pscustomobject]@{ status = 'ok'; source = 'test' } | ConvertTo-Json -Depth 10 | Set-Content -Path $capPath -Encoding UTF8
    } -GenerateOverride {
        param([string]$RootPath, [object]$Config)
        $scanPath = Join-Path $Config.reports_path 'scan-phase5g-pass.json'
        [pscustomobject]@{ status = 'ok'; source = 'test' } | ConvertTo-Json -Depth 10 | Set-Content -Path $scanPath -Encoding UTF8
    } -ExportOverride {
        param([string]$RootPath, [object]$Config)
        $folder = Join-Path $Config.reports_path 'diagnostic-pass'
        $zip = $folder + '.zip'
        New-Item -Path $folder -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $folder 'report.txt') -Value 'ok' -Encoding ASCII
        Set-Content -Path $zip -Value 'zip' -Encoding ASCII
        return [pscustomobject]@{ folder = $folder; zip = $zip }
    }

    $allPassSteps = @($allPass.result.diagnostic.steps)
    $allPassOk = (@($allPassSteps | Where-Object { $_.status -ne 'PASS' }).Count -eq 0)
    $allPassDetails = (@($allPassSteps | ForEach-Object { [string]$_.order + ':' + [string]$_.status }) -join ',')
    $results += Add-Phase5GResult -Name 'all_steps_pass' -Passed $allPassOk -Details $allPassDetails

    $scanWarning = Invoke-WithOverrides -Action {
        Invoke-DiagnosticForTest -TempRoot $temp.root -Config $configBase
    } -ScanOverride {
        param([string]$RootPath, [object]$Config)
        $path = Join-Path $Config.reports_path 'launcher-scan-latest.json'
        [pscustomobject]@{
            scan_id = [guid]::NewGuid().ToString()
            timestamp = (Get-Date).ToString('s')
            input_path = $Config.input_path
            architecture = 'x64'
            files_scanned = 0
            tools_detected = @()
            drivers_detected = @()
            runtimes_detected = @()
        } | ConvertTo-Json -Depth 20 | Set-Content -Path $path -Encoding UTF8
        return $path
    }

    $scanWarningStep = Get-StepByOrder -Steps $scanWarning.result.diagnostic.steps -Order 2
    $results += Add-Phase5GResult -Name 'scan_warning' -Passed ($scanWarningStep.status -eq 'WARNING') -Details $scanWarningStep.status

    $configNoWindows = [pscustomobject]@{
        config_path = $configBase.config_path
        input_path = Join-Path $temp.root 'no-win'
        default_tier = $configBase.default_tier
        reports_path = $configBase.reports_path
        logs_path = $configBase.logs_path
        launcher_log_path = $configBase.launcher_log_path
        gui_status_snapshot_path = $configBase.gui_status_snapshot_path
        startnet_runtime_log_path = $configBase.startnet_runtime_log_path
        startnet_template_path = $configBase.startnet_template_path
        startnet_output_path = $configBase.startnet_output_path
        startnet_fallback_output_path = $configBase.startnet_fallback_output_path
    }

    $noOffline = Invoke-DiagnosticForTest -TempRoot $temp.root -Config $configNoWindows
    $noOfflineStep = Get-StepByOrder -Steps $noOffline.result.diagnostic.steps -Order 4
    $results += Add-Phase5GResult -Name 'no_offline_windows' -Passed (($noOfflineStep.status -eq 'PASS') -and ($noOfflineStep.message -like '*No')) -Details $noOfflineStep.message

    $configNoLogs = [pscustomobject]@{
        config_path = $configBase.config_path
        input_path = $configBase.input_path
        default_tier = $configBase.default_tier
        reports_path = $configBase.reports_path
        logs_path = Join-Path $temp.root 'missing-logs-folder'
        launcher_log_path = $configBase.launcher_log_path
        gui_status_snapshot_path = $configBase.gui_status_snapshot_path
        startnet_runtime_log_path = $configBase.startnet_runtime_log_path
        startnet_template_path = $configBase.startnet_template_path
        startnet_output_path = $configBase.startnet_output_path
        startnet_fallback_output_path = $configBase.startnet_fallback_output_path
    }

    $noLogs = Invoke-DiagnosticForTest -TempRoot $temp.root -Config $configNoLogs
    $noLogsStep = Get-StepByOrder -Steps $noLogs.result.diagnostic.steps -Order 5
    $results += Add-Phase5GResult -Name 'logs_inaccessible' -Passed ($noLogsStep.status -eq 'WARNING') -Details $noLogsStep.status

    $exportUnavailable = Invoke-WithOverrides -Action {
        Invoke-DiagnosticForTest -TempRoot $temp.root -Config $configBase
    } -ExportOverride {
        param([string]$RootPath, [object]$Config)
        throw 'export unavailable for test'
    }

    $exportStep = Get-StepByOrder -Steps $exportUnavailable.result.diagnostic.steps -Order 7
    $results += Add-Phase5GResult -Name 'export_package_unavailable' -Passed ($exportStep.status -eq 'WARNING') -Details $exportStep.status

    $continueSafe = Invoke-WithOverrides -Action {
        Invoke-DiagnosticForTest -TempRoot $temp.root -Config $configBase
    } -CapabilityOverride {
        param([string]$RootPath, [object]$Config)
        throw 'capability step failed for test'
    }

    $failedStep = Get-StepByOrder -Steps $continueSafe.result.diagnostic.steps -Order 3
    $reportStepAfterFail = Get-StepByOrder -Steps $continueSafe.result.diagnostic.steps -Order 6
    $exportStepAfterFail = Get-StepByOrder -Steps $continueSafe.result.diagnostic.steps -Order 7
    $continued = ($failedStep.status -eq 'FAIL') -and ($null -ne $reportStepAfterFail) -and ($null -ne $exportStepAfterFail)
    $results += Add-Phase5GResult -Name 'one_step_failure_continues_safely' -Passed $continued -Details ($failedStep.status + '->' + $reportStepAfterFail.status + '/' + $exportStepAfterFail.status)

    $progressHasRunning = @($continueSafe.progress | Where-Object { $_ -like 'Running step */*' }).Count -ge 3
    $results += Add-Phase5GResult -Name 'progress_messages_present' -Passed $progressHasRunning -Details ([string](@($continueSafe.progress).Count))

    $jsonPath = Join-Path $temp.reports 'one-click-diagnostic-report.json'
    $htmlPath = Join-Path $temp.reports 'one-click-diagnostic-report.html'
    $artifactOk = (Test-Path -Path $jsonPath) -and (Test-Path -Path $htmlPath)
    $results += Add-Phase5GResult -Name 'one_click_reports_written' -Passed $artifactOk -Details ($jsonPath + ' | ' + $htmlPath)
}
finally {
    if (Test-Path -Path $temp.root) {
        Remove-Item -Path $temp.root -Recurse -Force
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

$jsonPath = Join-Path $OutputDirectory 'phase5g-tests-report.json'
$txtPath = Join-Path $OutputDirectory 'phase5g-tests-report.txt'

$report | ConvertTo-Json -Depth 20 | Set-Content -Path $jsonPath -Encoding UTF8

$lines = @(
    'Phase 5G Tests',
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

Write-Host "Phase 5G test report JSON: $jsonPath"
Write-Host "Phase 5G test report TXT: $txtPath"

if ($summary.failed -gt 0) {
    exit 1
}
