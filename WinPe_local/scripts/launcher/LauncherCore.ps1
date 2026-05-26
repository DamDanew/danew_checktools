Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$offlineEnginePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'offline\OfflineLogsEngine.ps1'
if (Test-Path -Path $offlineEnginePath) {
    . $offlineEnginePath
}

function Resolve-DanewLauncherPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [Parameter(Mandatory = $true)]
        [string]$PathValue
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $RootPath
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($PathValue)
    if ([System.IO.Path]::IsPathRooted($expanded)) {
        return $expanded
    }

    return Join-Path $RootPath $expanded
}

function Get-DanewLauncherConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [string]$ConfigPath
    )

    if (-not $ConfigPath) {
        $ConfigPath = Join-Path $RootPath 'scripts\launcher-config.json'
    }

    if (-not (Test-Path -Path $ConfigPath)) {
        throw "Launcher config missing: $ConfigPath"
    }

    $cfg = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    return [pscustomobject]@{
        config_path = $ConfigPath
        input_path = Resolve-DanewLauncherPath -RootPath $RootPath -PathValue ([string]$cfg.input_path)
        default_tier = [string]$cfg.default_tier
        reports_path = Resolve-DanewLauncherPath -RootPath $RootPath -PathValue ([string]$cfg.reports_path)
        logs_path = Resolve-DanewLauncherPath -RootPath $RootPath -PathValue ([string]$cfg.logs_path)
        launcher_log_path = Resolve-DanewLauncherPath -RootPath $RootPath -PathValue ([string]$cfg.launcher_log_path)
        gui_status_snapshot_path = if ([string]::IsNullOrWhiteSpace([string]$cfg.gui_status_snapshot_path)) { Join-Path (Resolve-DanewLauncherPath -RootPath $RootPath -PathValue ([string]$cfg.reports_path)) 'gui-status-snapshot.json' } else { Resolve-DanewLauncherPath -RootPath $RootPath -PathValue ([string]$cfg.gui_status_snapshot_path) }
        startnet_runtime_log_path = Resolve-DanewLauncherPath -RootPath $RootPath -PathValue ([string]$cfg.startnet_runtime_log_path)
        startnet_template_path = Resolve-DanewLauncherPath -RootPath $RootPath -PathValue ([string]$cfg.startnet_template_path)
        startnet_output_path = Resolve-DanewLauncherPath -RootPath $RootPath -PathValue ([string]$cfg.startnet_output_path)
        startnet_fallback_output_path = Resolve-DanewLauncherPath -RootPath $RootPath -PathValue ([string]$cfg.startnet_fallback_output_path)
    }
}

function Initialize-DanewLauncherPaths {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    foreach ($p in @($Config.reports_path, $Config.logs_path, (Split-Path -Parent $Config.launcher_log_path))) {
        if (-not [string]::IsNullOrWhiteSpace($p) -and -not (Test-Path -Path $p)) {
            New-Item -Path $p -ItemType Directory -Force | Out-Null
        }
    }

    if (-not (Test-Path -Path $Config.launcher_log_path)) {
        @() | ConvertTo-Json -Depth 5 | Set-Content -Path $Config.launcher_log_path -Encoding UTF8
    }
}

function Write-DanewLauncherActionLog {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,
        [Parameter(Mandatory = $true)]
        [string]$Action,
        [Parameter(Mandatory = $true)]
        [string]$Status,
        [string]$Message,
        [object]$Data
    )

    $entry = [pscustomobject]@{
        timestamp = (Get-Date).ToString('s')
        action = $Action
        status = $Status
        message = $Message
        data = $Data
    }

    $items = @()
    if (Test-Path -Path $Config.launcher_log_path) {
        try {
            $raw = Get-Content -Path $Config.launcher_log_path -Raw -Encoding UTF8
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $parsed = $raw | ConvertFrom-Json
                if ($parsed -is [System.Array]) {
                    $items = @($parsed)
                }
                elseif ($parsed) {
                    $items = @($parsed)
                }
            }
        }
        catch {
            $items = @()
        }
    }

    $items += $entry
    $items | ConvertTo-Json -Depth 30 | Set-Content -Path $Config.launcher_log_path -Encoding UTF8
}

function Get-DanewLauncherLatestLogEntry {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    if (-not (Test-Path -Path $Config.launcher_log_path)) {
        return $null
    }

    try {
        $raw = Get-Content -Path $Config.launcher_log_path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $null
        }

        $parsed = $raw | ConvertFrom-Json
        if ($parsed -is [System.Array]) {
            return @($parsed | Select-Object -Last 1)
        }

        return $parsed
    }
    catch {
        return $null
    }
}

function Get-DanewLauncherLatestReportPath {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    if ([string]::IsNullOrWhiteSpace($Config.reports_path) -or -not (Test-Path -Path $Config.reports_path)) {
        return ''
    }

    $excludedNames = @(
        'launcher-log.json',
        'gui-status-snapshot.json',
        'startnet-runtime-log.txt',
        'StartNet.generated.cmd',
        'StartNet.runtime.cmd',
        'StartNet.fallback.cmd'
    )

    $candidates = @(Get-ChildItem -Path $Config.reports_path -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Extension -in @('.json', '.txt', '.html', '.csv') -and ($excludedNames -notcontains $_.Name)
        } |
        Sort-Object LastWriteTime -Descending)

    if (@($candidates).Count -eq 0) {
        return ''
    }

    return $candidates[0].FullName
}

function Get-DanewLauncherSelectedUsbDisk {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    if ([string]::IsNullOrWhiteSpace($Config.reports_path) -or -not (Test-Path -Path $Config.reports_path)) {
        return 'Unknown'
    }

    $usbReportPath = Join-Path $Config.reports_path 'usb-export-report.json'
    if (-not (Test-Path -Path $usbReportPath)) {
        return 'Unknown'
    }

    try {
        $report = Get-Content -Path $usbReportPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $diskNumber = $null
        if ($report.PSObject.Properties['target_disk_number']) {
            $diskNumber = $report.target_disk_number
        }
        elseif ($report.PSObject.Properties['disk_number']) {
            $diskNumber = $report.disk_number
        }

        if ($null -eq $diskNumber -or [string]::IsNullOrWhiteSpace([string]$diskNumber)) {
            return 'Unknown'
        }

        return 'Disk ' + [string]$diskNumber
    }
    catch {
        return 'Unknown'
    }
}

function Get-DanewOfflineWindowsDisplayValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    if ([string]::IsNullOrWhiteSpace($Config.input_path) -or -not (Test-Path -Path $Config.input_path)) {
        return 'Unknown'
    }

    if (Test-Path -Path (Join-Path $Config.input_path 'Windows')) {
        return 'Yes'
    }

    return 'No'
}

function Get-DanewLauncherRuntimeMode {
    param(
        [string]$RuntimeSystemDrive
    )

    $drive = $RuntimeSystemDrive
    if ([string]::IsNullOrWhiteSpace($drive)) {
        $drive = $env:SystemDrive
    }

    if ([string]::IsNullOrWhiteSpace($drive)) {
        return 'Unknown'
    }

    if ($drive -eq 'X:') {
        return 'WinPE'
    }

    return 'Local'
}

function Get-DanewLauncherStatusSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [Parameter(Mandatory = $true)]
        [object]$Config,
        [string]$RuntimeSystemDrive,
        [string]$CurrentLocationPath
    )

    $runtimeMode = Get-DanewLauncherRuntimeMode -RuntimeSystemDrive $RuntimeSystemDrive
    if ([string]::IsNullOrWhiteSpace($CurrentLocationPath)) {
        $CurrentLocationPath = (Get-Location).Path
    }

    $latestLogEntry = Get-DanewLauncherLatestLogEntry -Config $Config
    $lastAction = 'Unknown'
    $lastActionStatus = 'Unknown'
    if ($latestLogEntry) {
        if ($latestLogEntry.PSObject.Properties['action'] -and -not [string]::IsNullOrWhiteSpace([string]$latestLogEntry.action)) {
            $lastAction = [string]$latestLogEntry.action
        }
        if ($latestLogEntry.PSObject.Properties['status'] -and -not [string]::IsNullOrWhiteSpace([string]$latestLogEntry.status)) {
            $lastActionStatus = [string]$latestLogEntry.status
        }
    }

    $lastReportPath = Get-DanewLauncherLatestReportPath -Config $Config
    if ([string]::IsNullOrWhiteSpace($lastReportPath)) {
        $lastReportPath = 'Unknown'
    }

    $selectedUsbDisk = Get-DanewLauncherSelectedUsbDisk -Config $Config
    $offlineWindows = Get-DanewOfflineWindowsDisplayValue -Config $Config
    $logsFolder = if ([string]::IsNullOrWhiteSpace($Config.logs_path)) { 'Unknown' } else { $Config.logs_path }
    $statusSnapshotPath = if ([string]::IsNullOrWhiteSpace($Config.gui_status_snapshot_path)) { Join-Path $Config.reports_path 'gui-status-snapshot.json' } else { $Config.gui_status_snapshot_path }

    $snapshot = [pscustomobject]@{
        timestamp = (Get-Date).ToString('s')
        root_path = $RootPath
        runtime_mode = $runtimeMode
        current_location = $CurrentLocationPath
        last_action = $lastAction
        last_action_status = $lastActionStatus
        last_report_path = $lastReportPath
        selected_usb_disk = $selectedUsbDisk
        offline_windows_detected = $offlineWindows
        logs_folder_path = $logsFolder
        snapshot_path = $statusSnapshotPath
    }

    if (-not [string]::IsNullOrWhiteSpace($statusSnapshotPath)) {
        $targetDir = Split-Path -Parent $statusSnapshotPath
        if ($targetDir -and -not (Test-Path -Path $targetDir)) {
            New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
        }
        $snapshot | ConvertTo-Json -Depth 20 | Set-Content -Path $statusSnapshotPath -Encoding UTF8
    }

    return $snapshot
}

function Open-DanewLatestReport {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    $reportPath = Get-DanewLauncherLatestReportPath -Config $Config
    if ([string]::IsNullOrWhiteSpace($reportPath)) {
        return [pscustomobject]@{
            opened = $false
            path = 'Unknown'
            reason = 'No report file found.'
        }
    }

    $explorer = Join-Path $env:WINDIR 'explorer.exe'
    if (Test-Path -Path $explorer) {
        try {
            Start-Process -FilePath $explorer -ArgumentList ("/select,`"$reportPath`"") | Out-Null
            return [pscustomobject]@{
                opened = $true
                path = $reportPath
                reason = 'Explorer opened the report location.'
            }
        }
        catch {
            return [pscustomobject]@{
                opened = $false
                path = $reportPath
                reason = $_.Exception.Message
            }
        }
    }

    return [pscustomobject]@{
        opened = $false
        path = $reportPath
        reason = 'Explorer is not available.'
    }
}

function New-DanewSimpleScanSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    $catalog = Get-DanewCatalogContext -RootPath $RootPath
    $scan = Invoke-DanewScan -InputPath $Config.input_path -CatalogContext $catalog -ProfileId $Config.default_tier

    $snapshot = [pscustomobject]@{
        scan_id = [guid]::NewGuid().ToString()
        timestamp = (Get-Date).ToString('s')
        input_path = $Config.input_path
        architecture = $scan.Architecture
        files_scanned = $scan.FilesScanned
        tools_detected = $scan.ToolsDetected
        drivers_detected = $scan.DriversDetected
        runtimes_detected = $scan.RuntimesDetected
    }

    $outPath = Join-Path $Config.reports_path 'launcher-scan-latest.json'
    $snapshot | ConvertTo-Json -Depth 10 | Set-Content -Path $outPath -Encoding UTF8
    return $outPath
}

function Invoke-DanewCapabilityAnalysis {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    $foundation = Join-Path $RootPath 'scripts\Invoke-DanewWinPEFoundation.ps1'
    & $foundation -InputPath $Config.input_path -TargetTier $Config.default_tier -Mode PlanOnly -RootPath $RootPath | Out-Null
}

function Invoke-DanewGenerateReport {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    $foundation = Join-Path $RootPath 'scripts\Invoke-DanewWinPEFoundation.ps1'
    & $foundation -InputPath $Config.input_path -TargetTier $Config.default_tier -Mode Simulation -RootPath $RootPath | Out-Null
}

function Open-DanewReportsFolder {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    if (-not (Test-Path -Path $Config.reports_path)) {
        New-Item -Path $Config.reports_path -ItemType Directory -Force | Out-Null
    }

    $explorer = Join-Path $env:WINDIR 'explorer.exe'
    if (Test-Path -Path $explorer) {
        Start-Process -FilePath $explorer -ArgumentList $Config.reports_path | Out-Null
        return 'opened'
    }

    Write-Host "Reports folder: $($Config.reports_path)"
    return 'printed'
}

function Export-DanewDiagnosticPackage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $diagFolderBase = Join-Path $Config.reports_path ("diagnostic-" + $timestamp)
    $diagFolder = $diagFolderBase
    $suffix = 1
    while (Test-Path -Path $diagFolder) {
        $diagFolder = $diagFolderBase + '-' + [string]$suffix
        $suffix += 1
    }
    New-Item -Path $diagFolder -ItemType Directory -Force | Out-Null

    $sources = @(
        $Config.reports_path,
        $Config.logs_path,
        (Join-Path $RootPath 'scripts\launcher-config.json'),
        (Join-Path $RootPath 'scripts\StartNet.cmd.template')
    )

    foreach ($src in $sources) {
        if (-not (Test-Path -Path $src)) { continue }

        if ((Get-Item -Path $src).PSIsContainer) {
            Get-ChildItem -Path $src -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in @('.json', '.txt', '.log', '.csv', '.html', '.ps1', '.cmd') } |
                ForEach-Object {
                    if ($_.FullName.StartsWith($diagFolder, [System.StringComparison]::OrdinalIgnoreCase)) {
                        return
                    }
                    $target = Join-Path $diagFolder $_.Name
                    if ([string]::Equals([string]$_.FullName, [string]$target, [System.StringComparison]::OrdinalIgnoreCase)) {
                        return
                    }
                    Copy-Item -Path $_.FullName -Destination $target -Force
                }
        }
        else {
            $target = Join-Path $diagFolder (Split-Path -Leaf $src)
            if (-not [string]::Equals([string]$src, [string]$target, [System.StringComparison]::OrdinalIgnoreCase)) {
                Copy-Item -Path $src -Destination $target -Force
            }
        }
    }

    $zipPath = $diagFolder + '.zip'
    $zipDone = $false
    if (Get-Command -Name Compress-Archive -ErrorAction SilentlyContinue) {
        try {
            Compress-Archive -Path (Join-Path $diagFolder '*') -DestinationPath $zipPath -Force
            $zipDone = $true
        }
        catch {
            $zipDone = $false
        }
    }

    return [pscustomobject]@{
        folder = $diagFolder
        zip = if ($zipDone) { $zipPath } else { '' }
    }
}

function Convert-DanewHtmlText {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return ''
    }

    $text = [string]$Value
    $text = $text -replace '&', '&amp;'
    $text = $text -replace '<', '&lt;'
    $text = $text -replace '>', '&gt;'
    $text = $text -replace '"', '&quot;'
    return $text
}

function Write-DanewDiagnosticProgress {
    param(
        [scriptblock]$ProgressCallback,
        [string]$Message
    )

    if ($ProgressCallback) {
        & $ProgressCallback $Message
    }
}

function Write-DanewOneClickDiagnosticReport {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Diagnostic,
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    if (-not (Test-Path -Path $Config.reports_path)) {
        New-Item -Path $Config.reports_path -ItemType Directory -Force | Out-Null
    }

    $jsonPath = Join-Path $Config.reports_path 'one-click-diagnostic-report.json'
    $htmlPath = Join-Path $Config.reports_path 'one-click-diagnostic-report.html'

    $Diagnostic | ConvertTo-Json -Depth 30 | Set-Content -Path $jsonPath -Encoding UTF8

    $stepRows = @()
    foreach ($step in @($Diagnostic.steps)) {
        $stepRows += @"
<tr>
<td>$(Convert-DanewHtmlText $step.order)</td>
<td>$(Convert-DanewHtmlText $step.label)</td>
<td>$(Convert-DanewHtmlText $step.status)</td>
<td>$(Convert-DanewHtmlText $step.message)</td>
<td>$(Convert-DanewHtmlText $step.details)</td>
</tr>
"@
    }

    $html = @"
<html>
<head>
<title>Danew One-Click Diagnostic</title>
<style>
body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; color: #1f2937; background: #f8fafc; }
.card { background: #ffffff; border: 1px solid #dbe3ea; border-radius: 12px; padding: 18px 20px; margin-bottom: 16px; box-shadow: 0 1px 2px rgba(15, 23, 42, 0.06); }
h1 { margin: 0 0 8px 0; font-size: 26px; }
h2 { margin-top: 0; font-size: 18px; }
table { width: 100%; border-collapse: collapse; background: #ffffff; }
th, td { border: 1px solid #dbe3ea; padding: 8px 10px; text-align: left; vertical-align: top; }
th { background: #eef3f7; }
.pass { color: #0f766e; font-weight: 600; }
.warning { color: #b45309; font-weight: 600; }
.fail { color: #b91c1c; font-weight: 600; }
.meta { color: #475569; }
</style>
</head>
<body>
<div class="card">
<h1>Danew One-Click Diagnostic</h1>
<div class="meta">Timestamp: $(Convert-DanewHtmlText $Diagnostic.timestamp)</div>
<div class="meta">Root path: $(Convert-DanewHtmlText $Diagnostic.root_path)</div>
<div class="meta">Runtime mode: $(Convert-DanewHtmlText $Diagnostic.runtime_mode)</div>
<div class="meta">Overall status: <span class="$(Convert-DanewHtmlText ($Diagnostic.summary.overall_status.ToLowerInvariant()))">$(Convert-DanewHtmlText $Diagnostic.summary.overall_status)</span></div>
</div>
<div class="card">
<h2>Summary</h2>
<div class="meta">Total steps: $(Convert-DanewHtmlText $Diagnostic.summary.total)</div>
<div class="meta">Pass: $(Convert-DanewHtmlText $Diagnostic.summary.pass)</div>
<div class="meta">Warning: $(Convert-DanewHtmlText $Diagnostic.summary.warning)</div>
<div class="meta">Fail: $(Convert-DanewHtmlText $Diagnostic.summary.fail)</div>
</div>
<div class="card">
<h2>Steps</h2>
<table>
<thead><tr><th>#</th><th>Step</th><th>Status</th><th>Message</th><th>Details</th></tr></thead>
<tbody>
$stepRows
</tbody>
</table>
</div>
</body>
</html>
"@

    $html | Set-Content -Path $htmlPath -Encoding UTF8

    return [pscustomobject]@{
        json = $jsonPath
        html = $htmlPath
    }
}

function Invoke-DanewOneClickDiagnostic {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [Parameter(Mandatory = $true)]
        [object]$Config,
        [string]$RuntimeSystemDrive,
        [string]$CurrentLocationPath,
        [scriptblock]$ProgressCallback
    )

    $effectiveDrive = $RuntimeSystemDrive
    if ([string]::IsNullOrWhiteSpace($effectiveDrive)) {
        $effectiveDrive = $env:SystemDrive
    }

    if ([string]::IsNullOrWhiteSpace($CurrentLocationPath)) {
        $CurrentLocationPath = (Get-Location).Path
    }

    $steps = @()
    $totalSteps = 7

    $statusSnapshot = $null
    $scanSnapshot = $null
    $capabilityPath = Join-Path $Config.reports_path 'enrichment-plan.json'
    $reportPath = ''
    $packageFolder = ''
    $packageZip = ''

    for ($stepIndex = 1; $stepIndex -le $totalSteps; $stepIndex++) {
        switch ($stepIndex) {
            1 {
                Write-DanewDiagnosticProgress -ProgressCallback $ProgressCallback -Message ('Running step 1/7 - Refresh status')
                try {
                    $statusSnapshot = Get-DanewLauncherStatusSnapshot -RootPath $RootPath -Config $Config -RuntimeSystemDrive $effectiveDrive -CurrentLocationPath $CurrentLocationPath
                    $steps += [pscustomobject]@{
                        order = 1
                        label = 'Refresh status'
                        status = 'PASS'
                        message = 'Status snapshot written.'
                        details = ('Runtime=' + $statusSnapshot.runtime_mode + '; Last=' + $statusSnapshot.last_action + ':' + $statusSnapshot.last_action_status)
                    }
                    Write-DanewDiagnosticProgress -ProgressCallback $ProgressCallback -Message ('PASS 1/7 - Refresh status')
                }
                catch {
                    $steps += [pscustomobject]@{
                        order = 1
                        label = 'Refresh status'
                        status = 'FAIL'
                        message = $_.Exception.Message
                        details = 'Status snapshot unavailable.'
                    }
                    Write-DanewDiagnosticProgress -ProgressCallback $ProgressCallback -Message ('FAIL 1/7 - Refresh status: ' + $_.Exception.Message)
                }
            }
            2 {
                Write-DanewDiagnosticProgress -ProgressCallback $ProgressCallback -Message ('Running step 2/7 - Scan WinPE')
                try {
                    $scanPath = New-DanewSimpleScanSnapshot -RootPath $RootPath -Config $Config
                    $scanSnapshot = Get-Content -Path $scanPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    $filesScanned = 0
                    if ($scanSnapshot.PSObject.Properties['FilesScanned']) {
                        $filesScanned = [int]$scanSnapshot.FilesScanned
                    }
                    elseif ($scanSnapshot.PSObject.Properties['files_scanned']) {
                        $filesScanned = [int]$scanSnapshot.files_scanned
                    }

                    $scanStatus = if ($filesScanned -le 0) { 'WARNING' } else { 'PASS' }
                    $scanMessage = if ($scanStatus -eq 'WARNING') { 'Scan completed but no files were found.' } else { 'Scan completed.' }
                    $steps += [pscustomobject]@{
                        order = 2
                        label = 'Scan WinPE'
                        status = $scanStatus
                        message = $scanMessage
                        details = ('FilesScanned=' + [string]$filesScanned + '; Path=' + $scanPath)
                    }
                    Write-DanewDiagnosticProgress -ProgressCallback $ProgressCallback -Message ($scanStatus + ' 2/7 - Scan WinPE')
                }
                catch {
                    $steps += [pscustomobject]@{
                        order = 2
                        label = 'Scan WinPE'
                        status = 'FAIL'
                        message = $_.Exception.Message
                        details = 'Scan snapshot unavailable.'
                    }
                    Write-DanewDiagnosticProgress -ProgressCallback $ProgressCallback -Message ('FAIL 2/7 - Scan WinPE: ' + $_.Exception.Message)
                }
            }
            3 {
                Write-DanewDiagnosticProgress -ProgressCallback $ProgressCallback -Message ('Running step 3/7 - Run capability analysis')
                try {
                    Invoke-DanewCapabilityAnalysis -RootPath $RootPath -Config $Config
                    $exists = Test-Path -Path $capabilityPath
                    $capabilityStatus = if ($exists) { 'PASS' } else { 'WARNING' }
                    $steps += [pscustomobject]@{
                        order = 3
                        label = 'Run capability analysis'
                        status = $capabilityStatus
                        message = if ($exists) { 'Capability analysis completed.' } else { 'Capability analysis completed without plan artifact.' }
                        details = $capabilityPath
                    }
                    Write-DanewDiagnosticProgress -ProgressCallback $ProgressCallback -Message ($capabilityStatus + ' 3/7 - Run capability analysis')
                }
                catch {
                    $steps += [pscustomobject]@{
                        order = 3
                        label = 'Run capability analysis'
                        status = 'FAIL'
                        message = $_.Exception.Message
                        details = 'Capability analysis failed.'
                    }
                    Write-DanewDiagnosticProgress -ProgressCallback $ProgressCallback -Message ('FAIL 3/7 - Run capability analysis: ' + $_.Exception.Message)
                }
            }
            4 {
                Write-DanewDiagnosticProgress -ProgressCallback $ProgressCallback -Message ('Running step 4/7 - Detect offline Windows installation')
                try {
                    $offlineWindows = Get-DanewOfflineWindowsDisplayValue -Config $Config
                    $offlineStatus = if ($offlineWindows -eq 'Unknown') { 'WARNING' } else { 'PASS' }
                    $steps += [pscustomobject]@{
                        order = 4
                        label = 'Detect offline Windows installation'
                        status = $offlineStatus
                        message = ('Offline Windows: ' + $offlineWindows)
                        details = $Config.input_path
                    }
                    Write-DanewDiagnosticProgress -ProgressCallback $ProgressCallback -Message ($offlineStatus + ' 4/7 - Detect offline Windows installation')
                }
                catch {
                    $steps += [pscustomobject]@{
                        order = 4
                        label = 'Detect offline Windows installation'
                        status = 'FAIL'
                        message = $_.Exception.Message
                        details = 'Offline Windows detection failed.'
                    }
                    Write-DanewDiagnosticProgress -ProgressCallback $ProgressCallback -Message ('FAIL 4/7 - Detect offline Windows installation: ' + $_.Exception.Message)
                }
            }
            5 {
                Write-DanewDiagnosticProgress -ProgressCallback $ProgressCallback -Message ('Running step 5/7 - Verify Windows logs access')
                try {
                    $logsAccessible = $false
                    if (-not [string]::IsNullOrWhiteSpace($Config.logs_path)) {
                        if (Test-Path -Path $Config.logs_path) {
                            Get-ChildItem -Path $Config.logs_path -ErrorAction Stop | Out-Null
                            $logsAccessible = $true
                        }
                    }

                    $logsStatus = if ($logsAccessible) { 'PASS' } else { 'WARNING' }
                    $steps += [pscustomobject]@{
                        order = 5
                        label = 'Verify Windows logs access'
                        status = $logsStatus
                        message = if ($logsAccessible) { 'Logs folder is accessible.' } else { 'Logs folder is not accessible.' }
                        details = $Config.logs_path
                    }
                    Write-DanewDiagnosticProgress -ProgressCallback $ProgressCallback -Message ($logsStatus + ' 5/7 - Verify Windows logs access')
                }
                catch {
                    $steps += [pscustomobject]@{
                        order = 5
                        label = 'Verify Windows logs access'
                        status = 'WARNING'
                        message = $_.Exception.Message
                        details = $Config.logs_path
                    }
                    Write-DanewDiagnosticProgress -ProgressCallback $ProgressCallback -Message ('WARNING 5/7 - Verify Windows logs access: ' + $_.Exception.Message)
                }
            }
            6 {
                Write-DanewDiagnosticProgress -ProgressCallback $ProgressCallback -Message ('Running step 6/7 - Generate report')
                try {
                    Invoke-DanewGenerateReport -RootPath $RootPath -Config $Config
                    $reportPath = Get-DanewLauncherLatestReportPath -Config $Config
                    if ([string]::IsNullOrWhiteSpace($reportPath)) {
                        $reportPath = Join-Path $Config.reports_path 'report-unknown.txt'
                    }
                    $steps += [pscustomobject]@{
                        order = 6
                        label = 'Generate report'
                        status = 'PASS'
                        message = 'Report generated.'
                        details = $reportPath
                    }
                    Write-DanewDiagnosticProgress -ProgressCallback $ProgressCallback -Message 'PASS 6/7 - Generate report'
                }
                catch {
                    $steps += [pscustomobject]@{
                        order = 6
                        label = 'Generate report'
                        status = 'FAIL'
                        message = $_.Exception.Message
                        details = 'Report generation failed.'
                    }
                    Write-DanewDiagnosticProgress -ProgressCallback $ProgressCallback -Message ('FAIL 6/7 - Generate report: ' + $_.Exception.Message)
                }
            }
            7 {
                Write-DanewDiagnosticProgress -ProgressCallback $ProgressCallback -Message ('Running step 7/7 - Export diagnostic package')
                try {
                    $package = Export-DanewDiagnosticPackage -RootPath $RootPath -Config $Config
                    $packageFolder = [string]$package.folder
                    $packageZip = [string]$package.zip
                    $exportStatus = if (-not [string]::IsNullOrWhiteSpace($packageZip)) { 'PASS' } elseif (-not [string]::IsNullOrWhiteSpace($packageFolder)) { 'WARNING' } else { 'WARNING' }
                    $steps += [pscustomobject]@{
                        order = 7
                        label = 'Export diagnostic package'
                        status = $exportStatus
                        message = if ($exportStatus -eq 'PASS') { 'Diagnostic package exported.' } else { 'Diagnostic package folder exported without a zip.' }
                        details = if (-not [string]::IsNullOrWhiteSpace($packageZip)) { $packageZip } else { $packageFolder }
                    }
                    Write-DanewDiagnosticProgress -ProgressCallback $ProgressCallback -Message ($exportStatus + ' 7/7 - Export diagnostic package')
                }
                catch {
                    $steps += [pscustomobject]@{
                        order = 7
                        label = 'Export diagnostic package'
                        status = 'WARNING'
                        message = $_.Exception.Message
                        details = 'Export diagnostic package unavailable.'
                    }
                    Write-DanewDiagnosticProgress -ProgressCallback $ProgressCallback -Message ('WARNING 7/7 - Export diagnostic package: ' + $_.Exception.Message)
                }
            }
        }
    }

    $passCount = @($steps | Where-Object { $_.status -eq 'PASS' }).Count
    $warningCount = @($steps | Where-Object { $_.status -eq 'WARNING' }).Count
    $failCount = @($steps | Where-Object { $_.status -eq 'FAIL' }).Count
    $overallStatus = 'PASS'
    if ($failCount -gt 0) {
        $overallStatus = 'FAIL'
    }
    elseif ($warningCount -gt 0) {
        $overallStatus = 'WARNING'
    }

    $diagnostic = [pscustomobject]@{
        timestamp = (Get-Date).ToString('s')
        root_path = $RootPath
        runtime_mode = Get-DanewLauncherRuntimeMode -RuntimeSystemDrive $effectiveDrive
        current_location = $CurrentLocationPath
        status_snapshot_path = if ($statusSnapshot -and $statusSnapshot.PSObject.Properties['snapshot_path']) { [string]$statusSnapshot.snapshot_path } else { '' }
        scan_snapshot_path = if ($scanSnapshot) { Join-Path $Config.reports_path 'launcher-scan-latest.json' } else { '' }
        report_path = $reportPath
        package_folder = $packageFolder
        package_zip = $packageZip
        report_json_path = ''
        report_html_path = ''
        steps = $steps
        summary = [pscustomobject]@{
            total = $totalSteps
            pass = $passCount
            warning = $warningCount
            fail = $failCount
            overall_status = $overallStatus
        }
    }

    $artifacts = Write-DanewOneClickDiagnosticReport -Diagnostic $diagnostic -Config $Config
    $diagnostic.report_json_path = $artifacts.json
    $diagnostic.report_html_path = $artifacts.html

    return [pscustomobject]@{
        diagnostic = $diagnostic
        artifacts = [pscustomobject]@{
            report_json_path = $artifacts.json
            report_html_path = $artifacts.html
            status_snapshot_path = $diagnostic.status_snapshot_path
            scan_snapshot_path = $diagnostic.scan_snapshot_path
            report_path = $diagnostic.report_path
            package_folder = $diagnostic.package_folder
            package_zip = $diagnostic.package_zip
        }
    }
}

function Prepare-DanewStartNetAutoLaunch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    if (-not (Test-Path -Path $Config.startnet_template_path)) {
        throw "StartNet template missing: $($Config.startnet_template_path)"
    }

    $template = Get-Content -Path $Config.startnet_template_path -Raw -Encoding UTF8
    $content = $template.Replace('__ROOT__', $RootPath)

    $targetPath = $Config.startnet_output_path
    $writtenToFallback = $false

    try {
        $targetDir = Split-Path -Parent $targetPath
        if ($targetDir -and -not (Test-Path -Path $targetDir)) {
            New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
        }
        $content | Set-Content -Path $targetPath -Encoding ASCII
    }
    catch {
        $writtenToFallback = $true
        $fallbackDir = Split-Path -Parent $Config.startnet_fallback_output_path
        if ($fallbackDir -and -not (Test-Path -Path $fallbackDir)) {
            New-Item -Path $fallbackDir -ItemType Directory -Force | Out-Null
        }
        $content | Set-Content -Path $Config.startnet_fallback_output_path -Encoding ASCII
        $targetPath = $Config.startnet_fallback_output_path
    }

    return [pscustomobject]@{
        target_path = $targetPath
        fallback_used = $writtenToFallback
    }
}

function Invoke-DanewCreateUsbMedia {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    $usbScript = Join-Path $RootPath 'scripts\Invoke-DanewCreateUsbMedia.ps1'
    if (-not (Test-Path -Path $usbScript)) {
        throw "USB provisioning script missing: $usbScript"
    }

    & $usbScript -RootPath $RootPath -ConfigPath $Config.config_path -Mode Provision
    return (Join-Path $Config.reports_path 'usb-export-report.json')
}

function Invoke-DanewLauncherAction {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Action,
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [Parameter(Mandatory = $true)]
        [object]$Config,
        [string]$RuntimeSystemDrive,
        [string]$CurrentLocationPath,
        [scriptblock]$ProgressCallback,
        [switch]$SuppressActionLog
    )

    Initialize-DanewLauncherPaths -Config $Config
    if (-not $SuppressActionLog) {
        Write-DanewLauncherActionLog -Config $Config -Action $Action -Status 'start' -Message 'Action started'
    }

    try {
        switch ($Action) {
            'refresh-status' {
                $status = Get-DanewLauncherStatusSnapshot -RootPath $RootPath -Config $Config -RuntimeSystemDrive $RuntimeSystemDrive -CurrentLocationPath $CurrentLocationPath
                $result = [pscustomobject]@{ action = $Action; output = $status }
            }
            'view-last-report' {
                $view = Open-DanewLatestReport -Config $Config
                $result = [pscustomobject]@{ action = $Action; output = $view }
            }
            'scan-winpe' {
                $scanPath = New-DanewSimpleScanSnapshot -RootPath $RootPath -Config $Config
                $result = [pscustomobject]@{ action = $Action; output = $scanPath }
            }
            'capability-analysis' {
                Invoke-DanewCapabilityAnalysis -RootPath $RootPath -Config $Config
                $result = [pscustomobject]@{ action = $Action; output = (Join-Path $Config.reports_path 'enrichment-plan.json') }
            }
            'generate-report' {
                Invoke-DanewGenerateReport -RootPath $RootPath -Config $Config
                $result = [pscustomobject]@{ action = $Action; output = $Config.reports_path }
            }
            'open-reports-folder' {
                $openResult = Open-DanewReportsFolder -Config $Config
                $result = [pscustomobject]@{ action = $Action; output = $openResult }
            }
            'export-diagnostic-package' {
                $pkg = Export-DanewDiagnosticPackage -RootPath $RootPath -Config $Config
                $result = [pscustomobject]@{ action = $Action; output = $pkg }
            }
            'prepare-startnet' {
                $prep = Prepare-DanewStartNetAutoLaunch -RootPath $RootPath -Config $Config
                $result = [pscustomobject]@{ action = $Action; output = $prep }
            }
            'start-diagnostic' {
                $diag = Invoke-DanewOneClickDiagnostic -RootPath $RootPath -Config $Config -RuntimeSystemDrive $RuntimeSystemDrive -CurrentLocationPath $CurrentLocationPath -ProgressCallback $ProgressCallback
                $result = [pscustomobject]@{ action = $Action; output = $diag }
            }
            'analyze-offline-logs' {
                $offline = Invoke-DanewOfflineLogsAnalysis -RootPath $RootPath -Config $Config
                $result = [pscustomobject]@{ action = $Action; output = $offline }
            }
            'create-usb-media' {
                $usbReport = Invoke-DanewCreateUsbMedia -RootPath $RootPath -Config $Config
                $result = [pscustomobject]@{ action = $Action; output = $usbReport }
            }
            'exit' {
                $result = [pscustomobject]@{ action = $Action; output = 'exit' }
            }
            default {
                throw "Unsupported launcher action: $Action"
            }
        }

        if (-not $SuppressActionLog) {
            Write-DanewLauncherActionLog -Config $Config -Action $Action -Status 'ok' -Message 'Action completed' -Data $result.output
        }
        return $result
    }
    catch {
        if (-not $SuppressActionLog) {
            Write-DanewLauncherActionLog -Config $Config -Action $Action -Status 'error' -Message $_.Exception.Message
        }
        throw
    }
}
