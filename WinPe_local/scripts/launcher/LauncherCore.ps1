Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$reportShellPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'report\HtmlReportShell.ps1'
if (Test-Path -Path $reportShellPath) {
    . $reportShellPath
}

$offlineEnginePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'offline\OfflineLogsEngine.ps1'
if (Test-Path -Path $offlineEnginePath) {
    . $offlineEnginePath
}

$winpePrecheckAgentPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'winpe\WinPEPrecheckAgent.ps1'
if (Test-Path -Path $winpePrecheckAgentPath) {
    . $winpePrecheckAgentPath
}

$crashEnginePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'offline\CrashAnalysisEngine.ps1'
if (Test-Path -Path $crashEnginePath) {
    . $crashEnginePath
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

function Get-DanewBrowserCandidatePaths {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    $candidates = New-Object System.Collections.ArrayList

    function Add-DanewBrowserCandidatePath {
        param(
            [string]$BasePath,
            [string]$Source
        )

        if ([string]::IsNullOrWhiteSpace($BasePath)) {
            return
        }

        foreach ($exeName in @('chromium.exe', 'chrome.exe', 'msedge.exe', 'FirefoxPortable.exe', 'firefox.exe')) {
            $path = ''
            try {
                $path = Join-Path $BasePath ('tools\browser\' + $exeName)
            }
            catch {
                $base = [string]$BasePath
                if (-not $base.EndsWith('\')) {
                    $base += '\'
                }
                $path = $base + 'tools\browser\' + $exeName
            }
            if (-not @($candidates | Where-Object { $_.path -ieq $path })) {
                [void]$candidates.Add([pscustomobject]@{
                        path = $path
                        executable = $exeName
                        source = $Source
                    })
            }
        }
    }

    Add-DanewBrowserCandidatePath -BasePath $RootPath -Source 'root'

    if ($Config -and $Config.PSObject.Properties['reports_path']) {
        try {
            $reportsParent = Split-Path -Parent ([string]$Config.reports_path)
            Add-DanewBrowserCandidatePath -BasePath $reportsParent -Source 'reports-parent'
        }
        catch {
        }
    }

    $disableDriveScan = ([string]$env:DANEW_BROWSER_DISABLE_DRIVE_SCAN -eq '1')
    if (-not $disableDriveScan) {
        try {
            $dataVolumes = @(Get-Volume -FileSystemLabel 'DANEW_DATA' -ErrorAction SilentlyContinue)
            foreach ($volume in $dataVolumes) {
                if (-not [string]::IsNullOrWhiteSpace([string]$volume.DriveLetter)) {
                    Add-DanewBrowserCandidatePath -BasePath ([string]$volume.DriveLetter + ':\') -Source 'DANEW_DATA'
                }
            }
        }
        catch {
        }

        foreach ($drive in @('E', 'D', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'Y', 'Z')) {
            Add-DanewBrowserCandidatePath -BasePath ($drive + ':\') -Source 'drive-scan'
        }
    }

    return @($candidates)
}

function Get-DanewPortableBrowserDetection {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    Initialize-DanewLauncherPaths -Config $Config

    $candidates = @(Get-DanewBrowserCandidatePaths -RootPath $RootPath -Config $Config)
    $candidateResults = @()
    $detected = $null

    foreach ($candidate in @($candidates)) {
        $exists = Test-Path -Path ([string]$candidate.path)
        $version = ''
        if ($exists) {
            try {
                $item = Get-Item -Path ([string]$candidate.path) -ErrorAction Stop
                if ($item.VersionInfo -and -not [string]::IsNullOrWhiteSpace([string]$item.VersionInfo.ProductVersion)) {
                    $version = [string]$item.VersionInfo.ProductVersion
                }
                elseif ($item.VersionInfo -and -not [string]::IsNullOrWhiteSpace([string]$item.VersionInfo.FileVersion)) {
                    $version = [string]$item.VersionInfo.FileVersion
                }
            }
            catch {
                $version = ''
            }
        }

        $entry = [pscustomobject]@{
            path = [string]$candidate.path
            executable = [string]$candidate.executable
            source = [string]$candidate.source
            exists = $exists
            version = $version
        }
        $candidateResults += $entry

        if ($exists -and -not $detected) {
            $detected = $entry
        }
    }

    $fallbackTxt = @()
    foreach ($name in @('evtx-sav-summary.txt', 'winpe-real-run-summary.txt', 'REPORTS_README.txt')) {
        $path = Join-Path ([string]$Config.reports_path) $name
        $fallbackTxt += [pscustomobject]@{
            name = $name
            path = $path
            exists = (Test-Path -Path $path)
        }
    }

    function Get-DanewBrowserOpenCommandText {
        param(
            [object]$Browser,
            [string]$TargetPath
        )

        if (-not $Browser) {
            return ''
        }

        $exe = [System.IO.Path]::GetFileName([string]$Browser.path).ToLowerInvariant()
        if ($exe -like 'firefox*') {
            return '"' + [string]$Browser.path + '" -new-window "' + $TargetPath + '"'
        }

        $profileDir = Join-Path ([string]$Config.reports_path) 'browser-profile'
        $args = @(
            '--no-first-run',
            '--no-default-browser-check',
            '--disable-background-networking',
            '--disable-component-update',
            '--disable-crash-reporter',
            '--disable-breakpad',
            '--disable-crashpad',
            '--disable-features=Crashpad',
            '--disable-gpu',
            '--allow-file-access-from-files',
            ('--user-data-dir="' + $profileDir + '"'),
            ('"' + $TargetPath + '"')
        )
        return '"' + [string]$Browser.path + '" ' + ($args -join ' ')
    }

    $reports = @()
    foreach ($name in @('REPORTS_INDEX.html', 'reports-index.html', 'sav-diagnostic-report.html', 'timeline-raw.html', 'evtx-by-file.html', 'evtx-events.html')) {
        $path = Join-Path ([string]$Config.reports_path) $name
        $exists = Test-Path -Path $path
        $reports += [pscustomobject]@{
            name = $name
            path = $path
            exists = $exists
            status = if ($exists) { 'PASS' } else { 'WARNING' }
            open_command = if ($detected -and $exists) { Get-DanewBrowserOpenCommandText -Browser $detected -TargetPath $path } elseif ($exists) { 'start "" "' + $path + '"' } else { '' }
        }
    }

    $status = if ($detected) { 'PASS' } else { 'WARNING' }
    $message = if ($detected) { 'Portable HTML browser available.' } else { 'Navigateur HTML non disponible. Consultez les rapports TXT/CSV dans le dossier reports.' }

    return [pscustomobject]@{
        timestamp = (Get-Date).ToString('s')
        status = $status
        message = $message
        browser_path = if ($detected) { [string]$detected.path } else { '' }
        browser_executable = if ($detected) { [string]$detected.executable } else { '' }
        browser_version = if ($detected) { [string]$detected.version } else { '' }
        executable_exists = [bool]$detected
        launch_test_possible = [bool]$detected
        launch_test_status = if ($detected) { 'READY' } else { 'SKIPPED' }
        candidates = $candidateResults
        report_opening = $reports
        fallback_message = 'Navigateur HTML non disponible. Consultez les rapports TXT/CSV dans le dossier reports.'
        fallback_txt = $fallbackTxt
        internet_required = $false
    }
}

function Export-DanewBrowserDetection {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    $detection = Get-DanewPortableBrowserDetection -RootPath $RootPath -Config $Config
    $jsonPath = Join-Path ([string]$Config.reports_path) 'browser-detection.json'
    $txtPath = Join-Path ([string]$Config.reports_path) 'browser-detection.txt'

    $detection | ConvertTo-Json -Depth 30 | Set-Content -Path $jsonPath -Encoding UTF8

    $lines = @(
        'Danew Browser Detection',
        ('Status: ' + [string]$detection.status),
        ('Message: ' + [string]$detection.message),
        ('Browser path: ' + [string]$detection.browser_path),
        ('Browser executable: ' + [string]$detection.browser_executable),
        ('Browser version: ' + [string]$detection.browser_version),
        ('Executable exists: ' + [string]$detection.executable_exists),
        ('Launch test possible: ' + [string]$detection.launch_test_possible),
        ('Internet required: False'),
        '',
        'Report opening validation:'
    )
    foreach ($report in @($detection.report_opening)) {
        $lines += ('[' + [string]$report.status + '] ' + [string]$report.name + ' -> ' + [string]$report.path)
        if (-not [string]::IsNullOrWhiteSpace([string]$report.open_command)) {
            $lines += ('  command: ' + [string]$report.open_command)
        }
    }

    $lines += ''
    $lines += 'TXT fallback:'
    $lines += [string]$detection.fallback_message
    foreach ($fallback in @($detection.fallback_txt)) {
        $state = if ($fallback.exists) { 'PASS' } else { 'WARNING' }
        $lines += ('[' + $state + '] ' + [string]$fallback.name + ' -> ' + [string]$fallback.path)
    }

    $lines | Set-Content -Path $txtPath -Encoding UTF8

    return [pscustomobject]@{
        detection = $detection
        artifacts = [pscustomobject]@{
            json = $jsonPath
            txt = $txtPath
        }
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
    $json = $items | ConvertTo-Json -Depth 30
    $lastError = $null
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            $json | Set-Content -Path $Config.launcher_log_path -Encoding UTF8 -ErrorAction Stop
            return
        }
        catch {
            $lastError = $_
            Start-Sleep -Milliseconds (50 * $attempt)
        }
    }

    if ($lastError) {
        throw $lastError
    }
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
    $browserDetection = Get-DanewPortableBrowserDetection -RootPath $RootPath -Config $Config

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
        browser_html_status = if ($browserDetection.browser_path) { 'Available' } else { 'Missing' }
        browser_html_path = if ($browserDetection.browser_path) { [string]$browserDetection.browser_path } else { 'Navigateur HTML non disponible. Consultez les rapports TXT/CSV dans le dossier reports.' }
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
            Get-ChildItem -Path $src -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in @('.json', '.txt', '.log', '.csv', '.html', '.ps1', '.cmd') } |
                ForEach-Object {
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

function Export-DanewEvtxZipPackage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    if (-not (Test-Path -Path $Config.reports_path)) {
        New-Item -Path $Config.reports_path -ItemType Directory -Force | Out-Null
    }

    $discoveryPath = Join-Path $Config.reports_path 'evtx-discovery.json'
    if (-not (Test-Path -Path $discoveryPath)) {
        return [pscustomobject]@{
            generated = $false
            status = 'warning'
            message = 'evtx-discovery.json absent. Lancez d abord une analyse des journaux Windows.'
            machine_name = ''
            timestamp = ''
            folder = ''
            zip = ''
            copied_evtx_count = 0
            copied_file_count = 0
        }
    }

    $discovery = @()
    try {
        $parsed = Get-Content -Path $discoveryPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($parsed -is [System.Array]) {
            $discovery = @($parsed)
        }
        elseif ($null -ne $parsed) {
            $discovery = @($parsed)
        }
    }
    catch {
        return [pscustomobject]@{
            generated = $false
            status = 'error'
            message = ('Impossible de lire evtx-discovery.json: ' + $_.Exception.Message)
            machine_name = ''
            timestamp = ''
            folder = ''
            zip = ''
            copied_evtx_count = 0
            copied_file_count = 0
        }
    }

    $readableEvtx = @()
    foreach ($entry in $discovery) {
        if ($null -eq $entry) { continue }
        $status = [string]$entry.status
        $sourcePath = [string]$entry.file_path
        if ([string]::IsNullOrWhiteSpace($sourcePath)) { continue }
        if ($status -ne 'readable') { continue }
        if (-not (Test-Path -Path $sourcePath)) { continue }
        $readableEvtx += @($sourcePath)
    }

    if (@($readableEvtx).Count -eq 0) {
        return [pscustomobject]@{
            generated = $false
            status = 'warning'
            message = 'Aucun fichier EVTX lisible detecte pour creer le ZIP.'
            machine_name = ''
            timestamp = ''
            folder = ''
            zip = ''
            copied_evtx_count = 0
            copied_file_count = 0
        }
    }

    $machineName = [string]$env:COMPUTERNAME
    $eventsPath = Join-Path $Config.reports_path 'evtx-events.json'
    if (Test-Path -Path $eventsPath) {
        try {
            $eventRows = Get-Content -Path $eventsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($eventRow in @($eventRows)) {
                foreach ($candidateRow in @($eventRow)) {
                    if ($null -eq $candidateRow -or -not $candidateRow.PSObject.Properties['computer']) {
                        continue
                    }

                    $candidateMachine = [string]($candidateRow.PSObject.Properties['computer'].Value)
                    if (-not [string]::IsNullOrWhiteSpace($candidateMachine)) {
                        $machineName = $candidateMachine
                        break
                    }
                }

                if (-not [string]::IsNullOrWhiteSpace($machineName)) {
                    break
                }
            }
        }
        catch {
        }
    }

    if ([string]::IsNullOrWhiteSpace($machineName)) {
        $machineName = 'unknown-machine'
    }

    $machineName = ($machineName -replace '[^A-Za-z0-9._-]', '_').Trim('_')
    if ([string]::IsNullOrWhiteSpace($machineName)) {
        $machineName = 'unknown-machine'
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $baseName = $machineName + '-' + $timestamp + '-evtx'
    $exportRoot = Join-Path $Config.reports_path 'Export_EVENTS'
    if (-not (Test-Path -Path $exportRoot)) {
        New-Item -Path $exportRoot -ItemType Directory -Force | Out-Null
    }

    $exportFolderBase = Join-Path $exportRoot $baseName
    $exportFolder = $exportFolderBase
    $suffix = 1
    while (Test-Path -Path $exportFolder) {
        $exportFolder = $exportFolderBase + '-' + [string]$suffix
        $suffix += 1
    }
    New-Item -Path $exportFolder -ItemType Directory -Force | Out-Null

    $copiedCount = 0
    foreach ($sourcePath in $readableEvtx) {
        $targetName = Split-Path -Leaf $sourcePath
        $targetPath = Join-Path $exportFolder $targetName
        $nameSuffix = 1
        while (Test-Path -Path $targetPath) {
            $targetName = ([string]$nameSuffix) + '-' + (Split-Path -Leaf $sourcePath)
            $targetPath = Join-Path $exportFolder $targetName
            $nameSuffix += 1
        }
        Copy-Item -Path $sourcePath -Destination $targetPath -Force
        $copiedCount += 1
    }

    $reportArtifacts = @(
        'evtx-discovery.json',
        'evtx-summary.json',
        'evtx-events.csv',
        'evtx-events.json',
        'evtx-filtered-events.csv',
        'evtx-critical-events.csv',
        'evtx-crash-window.csv',
        'evtx-sav-summary.txt'
    )
    foreach ($name in $reportArtifacts) {
        $artifactPath = Join-Path $Config.reports_path $name
        if (-not (Test-Path -Path $artifactPath)) { continue }
        Copy-Item -Path $artifactPath -Destination (Join-Path $exportFolder $name) -Force
    }

    $zipPath = $exportFolder + '.zip'
    $zipDone = $false
    if (Get-Command -Name Compress-Archive -ErrorAction SilentlyContinue) {
        try {
            Compress-Archive -Path (Join-Path $exportFolder '*') -DestinationPath $zipPath -Force
            $zipDone = $true
        }
        catch {
            $zipDone = $false
        }
    }

    $copiedFiles = @(Get-ChildItem -Path $exportFolder -File -ErrorAction SilentlyContinue)
    return [pscustomobject]@{
        generated = $zipDone
        status = if ($zipDone) { 'ok' } else { 'warning' }
        message = if ($zipDone) { 'Export ZIP EVTX genere.' } else { 'Archive ZIP indisponible, dossier export genere.' }
        machine_name = $machineName
        timestamp = $timestamp
        folder = $exportFolder
        zip = if ($zipDone) { $zipPath } else { '' }
        copied_evtx_count = $copiedCount
        copied_file_count = @($copiedFiles).Count
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
        $rowSearch = ConvertTo-DanewReportHtmlText ($step.order, $step.label, $step.status, $step.message, $step.details -join ' ')
        $stepRows += @"
    <tr data-search-row="$rowSearch">
<td>$(Convert-DanewHtmlText $step.order)</td>
<td>$(Convert-DanewHtmlText $step.label)</td>
<td>$(Convert-DanewHtmlText (Get-DanewLocalizedStatusText $step.status))</td>
<td>$(Convert-DanewHtmlText $step.message)</td>
<td>$(Convert-DanewHtmlText $step.details)</td>
</tr>
"@
    }

    $metrics = @(
        (New-DanewMetricCardHtml -Label 'Etapes totales' -Value $Diagnostic.summary.total -Tone 'info')
        (New-DanewMetricCardHtml -Label 'Pass' -Value $Diagnostic.summary.pass -Tone 'pass')
        (New-DanewMetricCardHtml -Label 'Alerte' -Value $Diagnostic.summary.warning -Tone 'warning')
        (New-DanewMetricCardHtml -Label 'Echec' -Value $Diagnostic.summary.fail -Tone 'fail')
    ) -join ''

    $meta = New-DanewReportMetaListHtml -Items @(
        [pscustomobject]@{ label = 'Horodatage'; value = $Diagnostic.timestamp }
        [pscustomobject]@{ label = 'Chemin racine'; value = $Diagnostic.root_path }
        [pscustomobject]@{ label = 'Mode d execution'; value = $Diagnostic.runtime_mode }
    )

    $sections = @(
        (New-DanewReportSectionHtml -Title 'Resume d execution' -Caption 'Les compteurs ci-dessous refletent l execution courante du diagnostic en un clic.' -SearchText ('summary overall status ' + [string]$Diagnostic.summary.overall_status) -BodyHtml ('<div class="split-grid">' + (New-DanewMetricCardHtml -Label 'Statut global' -Value (Get-DanewLocalizedStatusText $Diagnostic.summary.overall_status) -Tone $Diagnostic.summary.overall_status) + (New-DanewMetricCardHtml -Label 'Diagnostic genere' -Value 'Oui' -Tone 'ready') + '</div>'))
        (New-DanewReportSectionHtml -Title 'Details des etapes' -Caption 'Recherche par numero d etape, libelle, statut ou message.' -SearchText 'steps diagnostic execution details' -BodyHtml (New-DanewReportTableHtml -Headers @('#', 'Etape', 'Statut', 'Message', 'Details') -Rows $stepRows -EmptyMessage 'Aucune etape de diagnostic ne correspond au filtre courant.'))
    )

    $html = New-DanewInteractiveReportHtml -Title 'Diagnostic Danew en un clic' -Subtitle 'Resume d execution du launcher avec recherche hors ligne, impression et sections repliables.' -Status ([string]$Diagnostic.summary.overall_status) -Eyebrow 'Diagnostic operationnel' -HeroMetricsHtml ('<div class="hero-metrics">' + $metrics + '</div>') -MetaHtml $meta -Sections $sections -SearchPlaceholder 'Filtrer les etapes par libelle, statut, message ou detail'

    $html | Set-Content -Path $htmlPath -Encoding UTF8
    Update-DanewInteractiveReportsIndex -ReportsPath $Config.reports_path | Out-Null

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

function Export-DanewStartNetAutoLaunch {
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

function Copy-DanewLauncherConfigWithOverrides {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,
        [Parameter(Mandatory = $true)]
        [hashtable]$Overrides
    )

    $copy = [ordered]@{}
    foreach ($property in @($Config.PSObject.Properties)) {
        $copy[$property.Name] = $property.Value
    }
    foreach ($key in @($Overrides.Keys)) {
        $copy[[string]$key] = $Overrides[$key]
    }

    return [pscustomobject]$copy
}

function Get-DanewLauncherConfigValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [object]$DefaultValue = $null
    )

    if ($Config -and $Config.PSObject.Properties[$Name]) {
        return $Config.PSObject.Properties[$Name].Value
    }

    return $DefaultValue
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
                $prep = Export-DanewStartNetAutoLaunch -RootPath $RootPath -Config $Config
                $result = [pscustomobject]@{ action = $Action; output = $prep }
            }
            'start-diagnostic' {
                $diag = Invoke-DanewOneClickDiagnostic -RootPath $RootPath -Config $Config -RuntimeSystemDrive $RuntimeSystemDrive -CurrentLocationPath $CurrentLocationPath -ProgressCallback $ProgressCallback
                $result = [pscustomobject]@{ action = $Action; output = $diag }
            }
            'analyze-offline-logs' {
                $offline = Invoke-DanewOfflineLogsAnalysis -RootPath $RootPath -Config $Config -ProgressCallback $ProgressCallback
                $result = [pscustomobject]@{ action = $Action; output = $offline }
            }
            'analyze-offline-logs-fast' {
                $configuredFastMax = [int](Get-DanewLauncherConfigValue -Config $Config -Name 'offline_max_events_per_log' -DefaultValue 500)
                $configuredFastLevels = @(Get-DanewLauncherConfigValue -Config $Config -Name 'offline_event_level_filter' -DefaultValue @(1, 2, 3))
                if (@($configuredFastLevels).Count -eq 0) {
                    $configuredFastLevels = @(1, 2, 3)
                }

                $fastConfig = Copy-DanewLauncherConfigWithOverrides -Config $Config -Overrides @{
                    offline_fast_mode = $true
                    offline_max_events_per_log = $configuredFastMax
                    offline_event_level_filter = @($configuredFastLevels)
                    offline_analysis_mode = 'fast-critical-error-warning'
                }
                $offline = Invoke-DanewOfflineLogsAnalysis -RootPath $RootPath -Config $fastConfig -MaxEventsPerLog $configuredFastMax -ProgressCallback $ProgressCallback
                $result = [pscustomobject]@{ action = $Action; output = $offline }
            }
            'analyze-offline-logs-full' {
                $fullConfig = Copy-DanewLauncherConfigWithOverrides -Config $Config -Overrides @{
                    offline_fast_mode = $false
                    offline_event_level_filter = @()
                    offline_analysis_mode = 'full'
                }
                $offline = Invoke-DanewOfflineLogsAnalysis -RootPath $RootPath -Config $fullConfig -ProgressCallback $ProgressCallback
                $result = [pscustomobject]@{ action = $Action; output = $offline }
            }
            'analyze-crash-causes' {
                $eventsPath = Join-Path $Config.reports_path 'evtx-events.json'
                $offlineAnalysisPath = Join-Path $Config.reports_path 'offline-windows-analysis.json'
                $storagePath = Join-Path $Config.reports_path 'storage-diagnostics.json'
                $bitlockerPath = Join-Path $Config.reports_path 'bitlocker-analysis.json'
                $timelinePath = Join-Path $Config.reports_path 'timeline-raw.json'

                $canReuseOfflineArtifacts = (Test-Path -Path $eventsPath) -and (Test-Path -Path $offlineAnalysisPath)

                if ($canReuseOfflineArtifacts) {
                    Write-DanewDiagnosticProgress -ProgressCallback $ProgressCallback -Message '[5%] Step 1/2 - Reutilisation des artefacts hors ligne existants'
                    $offline = [pscustomobject]@{
                        artifacts = [pscustomobject]@{
                            evtx_events_json = $eventsPath
                            offline_windows_analysis = $offlineAnalysisPath
                            storage_diagnostics = $storagePath
                            bitlocker_analysis = $bitlockerPath
                            timeline_raw_json = $timelinePath
                        }
                    }
                }
                else {
                    Write-DanewDiagnosticProgress -ProgressCallback $ProgressCallback -Message '[5%] Step 1/2 - Analyse des journaux hors ligne pour crash'
                    $offline = Invoke-DanewOfflineLogsAnalysis -RootPath $RootPath -Config $Config -ProgressCallback $ProgressCallback
                }
                Write-DanewDiagnosticProgress -ProgressCallback $ProgressCallback -Message '[92%] Step 2/2 - Correlation et determination des causes de crash'
                $crash = Invoke-DanewCrashCauseAnalysis -RootPath $RootPath -Config $Config -OfflineAnalysis $offline
                Write-DanewDiagnosticProgress -ProgressCallback $ProgressCallback -Message '[100%] Step 2/2 - Analyse causes de crash terminee'
                $result = [pscustomobject]@{ action = $Action; output = $crash }
            }
            'precheck-winpe' {
                $precheck = Invoke-DanewWinPEPrecheckAgent -RootPath $RootPath -Config $Config -ApplyFixes
                $result = [pscustomobject]@{ action = $Action; output = $precheck }
            }
            'export-evtx-targeted' {
                $exports = Invoke-DanewEvtxTargetedExportsAction -RootPath $RootPath -Config $Config
                $result = [pscustomobject]@{ action = $Action; output = $exports }
            }
            'export-evtx-zip' {
                $exports = Export-DanewEvtxZipPackage -RootPath $RootPath -Config $Config
                $result = [pscustomobject]@{ action = $Action; output = $exports }
            }
            'check-browser' {
                $browser = Export-DanewBrowserDetection -RootPath $RootPath -Config $Config
                $result = [pscustomobject]@{ action = $Action; output = $browser }
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
