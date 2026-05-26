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

function Add-Phase5FResult {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Details = ''
    )

    [pscustomobject]@{ name = $Name; passed = $Passed; details = $Details }
}

function New-Phase5FTestRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath
    )

    $tempRoot = Join-Path $BasePath 'temp\phase5f-tests'
    if (Test-Path -Path $tempRoot) {
        Remove-Item -Path $tempRoot -Recurse -Force
    }

    New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null
    foreach ($folder in @('scripts', 'reports', 'logs', 'builds', 'Boot', 'EFI\Boot', 'sources', 'manifests', 'schemas', 'profiles')) {
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

    $cfgPath = Join-Path $tempRoot 'scripts\launcher-config.json'
    $cfg = Get-Content -Path (Join-Path $BasePath 'scripts\launcher-config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $cfg.input_path = '.'
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

function Write-LauncherLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [object[]]$Entries
    )

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    $Entries | ConvertTo-Json -Depth 20 | Set-Content -Path $Path -Encoding UTF8
}

function Write-ReportFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [object]$Content
    )

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    $Content | ConvertTo-Json -Depth 20 | Set-Content -Path $Path -Encoding UTF8
}

function Invoke-Phase5FCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CliPath,
        [Parameter(Mandatory = $true)]
        [string]$RootPathValue,
        [Parameter(Mandatory = $true)]
        [string]$ConfigPathValue,
        [Parameter(Mandatory = $true)]
        [string]$CommandName,
        [switch]$Json,
        [string]$RuntimeSystemDrive
    )

    $arguments = @('-NoProfile', '-File', $CliPath, '-RootPath', $RootPathValue, '-ConfigPath', $ConfigPathValue, '-Command', $CommandName)
    if ($Json) {
        $arguments += '-Json'
    }
    if (-not [string]::IsNullOrWhiteSpace($RuntimeSystemDrive)) {
        $arguments += @('-RuntimeSystemDrive', $RuntimeSystemDrive)
    }

    & pwsh @arguments
}

$results = @()
$temp = New-Phase5FTestRoot -BasePath $RootPath
$cliPath = Join-Path $temp.root 'scripts\DanewCheckTool.CLI.ps1'

try {
    Write-LauncherLog -Path (Join-Path $temp.logs 'launcher-log.json') -Entries @(
        [pscustomobject]@{ timestamp = '2026-05-26T10:00:00'; action = 'scan-winpe'; status = 'ok'; message = 'scan complete' },
        [pscustomobject]@{ timestamp = '2026-05-26T10:01:00'; action = 'generate-report'; status = 'ok'; message = 'report complete' }
    )
    Write-ReportFile -Path (Join-Path $temp.reports 'phase5f-last-report.json') -Content ([pscustomobject]@{ name = 'phase5f-last-report'; timestamp = (Get-Date).ToString('s') })
    Write-ReportFile -Path (Join-Path $temp.reports 'usb-export-report.json') -Content ([pscustomobject]@{ target_disk_number = 4; status = 'PASS' })

    Invoke-Phase5FCommand -CliPath $cliPath -RootPathValue $temp.root -ConfigPathValue $temp.config_path -CommandName 'refresh-status' -RuntimeSystemDrive 'C:' | Out-Null
    $statusPath = Join-Path $temp.reports 'cli-status-snapshot.json'
    $status = Get-Content -Path $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $results += Add-Phase5FResult -Name 'local_mode' -Passed (($status.runtime_mode -eq 'Local') -and ($status.last_action -eq 'prepare-startnet') -and ($status.last_action_status -eq 'ok')) -Details $status.runtime_mode

    Invoke-Phase5FCommand -CliPath $cliPath -RootPathValue $temp.root -ConfigPathValue $temp.config_path -CommandName 'show-status' -RuntimeSystemDrive 'X:' | Out-Null
    $statusWinPe = Get-Content -Path $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $results += Add-Phase5FResult -Name 'simulated_winpe_mode' -Passed ($statusWinPe.runtime_mode -eq 'WinPE') -Details $statusWinPe.runtime_mode

    $missingReportsRoot = Join-Path $temp.root 'missing-reports'
    New-Item -Path $missingReportsRoot -ItemType Directory -Force | Out-Null
    $cfgMissing = Get-Content -Path $temp.config_path -Raw -Encoding UTF8 | ConvertFrom-Json
    $cfgMissing.reports_path = 'missing-reports'
    $cfgMissing.gui_status_snapshot_path = 'missing-reports/gui-status-snapshot.json'
    $cfgMissingPath = Join-Path $temp.root 'scripts\launcher-config-missing.json'
    $cfgMissing | ConvertTo-Json -Depth 20 | Set-Content -Path $cfgMissingPath -Encoding UTF8
    Invoke-Phase5FCommand -CliPath $cliPath -RootPathValue $temp.root -ConfigPathValue $cfgMissingPath -CommandName 'show-status' -RuntimeSystemDrive 'C:' | Out-Null
    $missingStatus = Get-Content -Path (Join-Path $missingReportsRoot 'gui-status-snapshot.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $results += Add-Phase5FResult -Name 'missing_reports' -Passed ($missingStatus.last_report_path -eq 'Unknown') -Details $missingStatus.last_report_path

    $cfgNoUsb = Get-Content -Path $temp.config_path -Raw -Encoding UTF8 | ConvertFrom-Json
    $cfgNoUsbPath = Join-Path $temp.root 'scripts\launcher-config-no-usb.json'
    $cfgNoUsb.gui_status_snapshot_path = 'reports/gui-status-snapshot.json'
    $cfgNoUsbPath = Join-Path $temp.root 'scripts\launcher-config-no-usb.json'
    $cfgNoUsb | ConvertTo-Json -Depth 20 | Set-Content -Path $cfgNoUsbPath -Encoding UTF8
    Remove-Item -Path (Join-Path $temp.reports 'usb-export-report.json') -Force
    Invoke-Phase5FCommand -CliPath $cliPath -RootPathValue $temp.root -ConfigPathValue $cfgNoUsbPath -CommandName 'show-status' -RuntimeSystemDrive 'C:' | Out-Null
    $noUsbStatus = Get-Content -Path $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $results += Add-Phase5FResult -Name 'missing_usb' -Passed ($noUsbStatus.selected_usb_disk -eq 'Unknown') -Details $noUsbStatus.selected_usb_disk

    Write-LauncherLog -Path (Join-Path $temp.logs 'launcher-log.json') -Entries @(
        [pscustomobject]@{ timestamp = '2026-05-26T10:00:00'; action = 'scan-winpe'; status = 'ok'; message = 'scan complete' },
        [pscustomobject]@{ timestamp = '2026-05-26T10:02:00'; action = 'generate-report'; status = 'error'; message = 'report failed' }
    )
    $failedConfig = Get-DanewLauncherConfig -RootPath $temp.root -ConfigPath $temp.config_path
    $failedSnapshot = Get-DanewLauncherStatusSnapshot -RootPath $temp.root -Config $failedConfig -RuntimeSystemDrive 'C:' -CurrentLocationPath 'C:\'
    $failedStatus = $failedSnapshot
    $results += Add-Phase5FResult -Name 'failed_last_action' -Passed ($failedStatus.last_action_status -eq 'error') -Details $failedStatus.last_action_status

    $jsonOutput = & pwsh -NoProfile -File $cliPath -RootPath $temp.root -ConfigPath $temp.config_path -Command show-status -Json -RuntimeSystemDrive C:\
    $parsedJson = $jsonOutput | ConvertFrom-Json
    $results += Add-Phase5FResult -Name 'json_mode' -Passed (($parsedJson.status.runtime_mode -eq 'Local') -and ($parsedJson.status.last_report_path -ne '')) -Details $parsedJson.status.runtime_mode

    Invoke-Phase5FCommand -CliPath $cliPath -RootPathValue $temp.root -ConfigPathValue $temp.config_path -CommandName 'view-last-report' -RuntimeSystemDrive 'C:' | Out-Null
    $reportReferencePath = Join-Path $temp.reports 'cli-last-report-reference.json'
    $reference = Get-Content -Path $reportReferencePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $results += Add-Phase5FResult -Name 'view_last_report_reference' -Passed (($reference.view_opened -ne $null) -and ($reference.view_path -ne '')) -Details $reference.view_path
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

$jsonPath = Join-Path $OutputDirectory 'phase5f-tests-report.json'
$txtPath = Join-Path $OutputDirectory 'phase5f-tests-report.txt'

$report | ConvertTo-Json -Depth 20 | Set-Content -Path $jsonPath -Encoding UTF8

$lines = @(
    'Phase 5F Tests',
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

Write-Host "Phase 5F test report JSON: $jsonPath"
Write-Host "Phase 5F test report TXT: $txtPath"

if ($summary.failed -gt 0) {
    exit 1
}
