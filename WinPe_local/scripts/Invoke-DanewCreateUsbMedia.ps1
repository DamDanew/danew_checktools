[CmdletBinding()]
param(
    [string]$RootPath = (Split-Path -Parent $PSScriptRoot),
    [string]$ConfigPath,
    [ValidateSet('Analyze', 'Provision')]
    [string]$Mode = 'Analyze',
    [int]$TargetDiskNumber = -1,
    [switch]$LegacyBiosMode,
    [switch]$NonInteractive,
    [int]$ConfirmDiskNumber = -1,
    [string]$ConfirmToken,
    [string]$SimulatedDisksPath,
    [string]$SimulationRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'launcher\LauncherCore.ps1')
. (Join-Path $PSScriptRoot 'catalog\CatalogService.ps1')
. (Join-Path $PSScriptRoot 'scan\ScanEngine.ps1')
. (Join-Path $PSScriptRoot 'usb\UsbProvisioning.ps1')

$config = Get-DanewLauncherConfig -RootPath $RootPath -ConfigPath $ConfigPath
Initialize-DanewLauncherPaths -Config $config

$reportsDir = $config.reports_path
if (-not (Test-Path -Path $reportsDir)) {
    New-Item -Path $reportsDir -ItemType Directory -Force | Out-Null
}

$buildPath = $config.input_path
if (-not (Test-Path -Path $buildPath)) {
    $buildPath = $RootPath
}

$catalog = Get-DanewCatalogContext -RootPath $RootPath
$bootWimPath = Join-Path $buildPath 'sources\boot.wim'
$bootWimPackageValidation = [pscustomobject]@{
    path = $bootWimPath
    exists = (Test-Path -Path $bootWimPath)
    source = ''
    package_count = 0
    missing_required_packages = @()
    detected_packages = @()
    profile = $config.default_tier
    status = 'FAIL'
    details = 'boot.wim not found.'
}

if ($bootWimPackageValidation.exists) {
    $packageAnalysis = Get-DanewPackageAnalysis -InputPath $buildPath -BootWimPath $bootWimPath -ImageIndex 1 -CatalogContext $catalog -ProfileId $config.default_tier
    $missingPackages = @($packageAnalysis.missing_required_packages)
    $bootWimPackageValidation = [pscustomobject]@{
        path = $bootWimPath
        exists = $true
        source = $packageAnalysis.source
        package_count = $packageAnalysis.package_count
        missing_required_packages = $missingPackages
        detected_packages = @($packageAnalysis.detected_packages)
        profile = $config.default_tier
        status = if (@($missingPackages).Count -eq 0) { 'PASS' } else { 'FAIL' }
        details = if (@($missingPackages).Count -eq 0) { 'boot.wim contains all required WinPE packages.' } else { 'boot.wim missing required WinPE packages: ' + ($missingPackages -join ', ') }
    }
}

$bootWimPackageValidationPath = Join-Path $reportsDir 'boot-wim-package-validation.json'
$bootWimPackageValidation | ConvertTo-Json -Depth 30 | Set-Content -Path $bootWimPackageValidationPath -Encoding UTF8

$buildMetrics = Get-DanewBuildMetrics -BuildPath $buildPath
$inventory = @(Get-DanewUsbDeviceInventory -SimulatedDisksPath $SimulatedDisksPath)

$candidates = @($inventory | Where-Object { $_.allow_candidate })
$candidateWithCompatibility = @()
foreach ($c in $candidates) {
    $compat = Get-DanewUsbCompatibility -Disk $c -BuildMetrics $buildMetrics -LegacyBiosMode:$LegacyBiosMode
    $candidateWithCompatibility += [pscustomobject]@{
        disk_number = $c.disk_number
        friendly_name = $c.friendly_name
        manufacturer = $c.manufacturer
        serial_number = $c.serial_number
        size_gb = $c.size_gb
        free_gb = $c.free_gb
        bus_type = $c.bus_type
        removable = $c.removable
        allow_candidate = $c.allow_candidate
        partition_style = $c.partition_style
        filesystems = $c.filesystems
        mounted_letters = $c.mounted_letters
        usb_version = $c.usb_version
        performance_category = $c.performance_category
        is_boot = $c.is_boot
        is_system = $c.is_system
        contains_windows = $c.contains_windows
        compatibility = $compat
    }
}

$deviceAnalysisPath = Join-Path $reportsDir 'usb-device-analysis.json'
$candidateWithCompatibility | ConvertTo-Json -Depth 30 | Set-Content -Path $deviceAnalysisPath -Encoding UTF8

if (@($candidateWithCompatibility).Count -eq 0) {
    throw 'No safe USB/removable candidate detected.'
}

$selected = Select-DanewUsbTargetDisk -Candidates $candidateWithCompatibility -TargetDiskNumber $TargetDiskNumber -NonInteractive:$NonInteractive
$safety = Test-DanewUsbSafetyValidation -Disk $selected -Compatibility $selected.compatibility

$safetyPath = Join-Path $reportsDir 'usb-safety-validation.json'
$safety | ConvertTo-Json -Depth 20 | Set-Content -Path $safetyPath -Encoding UTF8

$layout = New-DanewPartitionLayout -Disk $selected -BuildMetrics $buildMetrics -LegacyBiosMode:$LegacyBiosMode
$layoutPath = Join-Path $reportsDir 'partition-layout.json'
$layout | ConvertTo-Json -Depth 30 | Set-Content -Path $layoutPath -Encoding UTF8

$beforeState = Get-DanewDiskStateSnapshot -Disk $selected -SimulationRoot $SimulationRoot
$beforeStatePath = Join-Path $reportsDir 'disk-before-state.json'
$beforeState | ConvertTo-Json -Depth 30 | Set-Content -Path $beforeStatePath -Encoding UTF8

$executeProvision = ($Mode -eq 'Provision')
if ($executeProvision) {
    if ($bootWimPackageValidation.status -ne 'PASS') {
        throw ('boot.wim package validation failed. ' + $bootWimPackageValidation.details)
    }

    if (-not $safety.safety_passed) {
        throw 'USB safety validation failed. Provisioning blocked.'
    }

    [void](Confirm-DanewUsbOperation -DiskNumber ([int]$selected.disk_number) -NonInteractive:$NonInteractive -ConfirmDiskNumber $ConfirmDiskNumber -ConfirmToken $ConfirmToken)
}

$partitionResult = Invoke-DanewUsbPartitioningEngine -Disk $selected -Layout $layout -Execute:$executeProvision -SimulationRoot $SimulationRoot

$exportResult = Invoke-DanewUsbExport -BuildPath $buildPath -BuildMetrics $buildMetrics -Layout $layout -PartitionResult $partitionResult -ReportsDirectory $reportsDir -Execute:$executeProvision
$bootValidation = Test-DanewUsbBootValidation -PartitionResult $partitionResult -Execute:$executeProvision

$bootValidationPath = Join-Path $reportsDir 'usb-boot-validation.json'
$bootValidation | ConvertTo-Json -Depth 30 | Set-Content -Path $bootValidationPath -Encoding UTF8

$afterState = Get-DanewDiskStateSnapshot -Disk $selected -SimulationRoot $SimulationRoot
$afterStatePath = Join-Path $reportsDir 'disk-after-state.json'
$afterState | ConvertTo-Json -Depth 30 | Set-Content -Path $afterStatePath -Encoding UTF8

$rollbackPlan = [pscustomobject]@{
    disk_number = $selected.disk_number
    mode = if ($executeProvision) { 'post-provision' } else { 'analysis-only' }
    rollback_actions = @(
        [pscustomobject]@{ order = 1; action = 'Recreate target USB partitions as needed'; note = 'Use captured disk-before-state.json for comparison.' },
        [pscustomobject]@{ order = 2; action = 'Restore backup/diagnostics files from data partition backup folder'; note = 'Manual restoration recommended.' },
        [pscustomobject]@{ order = 3; action = 'Re-run pre-real-boot-check and real-winpe-validation'; note = 'Validate media before reuse.' }
    )
}
$rollbackPath = Join-Path $reportsDir 'rollback-usb-plan.json'
$rollbackPlan | ConvertTo-Json -Depth 20 | Set-Content -Path $rollbackPath -Encoding UTF8

$status = 'PASS'
if ($bootWimPackageValidation.status -eq 'FAIL' -or -not $safety.safety_passed -or $bootValidation.status -eq 'FAIL') {
    $status = 'FAIL'
}
elseif ($selected.compatibility.status -eq 'WARNING' -or @($exportResult.warnings).Count -gt 0 -or -not $executeProvision) {
    $status = 'WARNING'
}

$report = [pscustomobject]@{
    timestamp = (Get-Date).ToString('s')
    status = $status
    mode = if ($executeProvision) { 'Provision' } else { 'Analyze' }
    target_disk_number = $selected.disk_number
    target_friendly_name = $selected.friendly_name
    build_metrics = $buildMetrics
    safety = $safety
    partition_result = $partitionResult
    boot_validation = $bootValidation
    boot_wim_package_validation = $bootWimPackageValidation
    warnings = @($exportResult.warnings)
    artifacts = [pscustomobject]@{
        boot_wim_package_validation = $bootWimPackageValidationPath
        usb_device_analysis = $deviceAnalysisPath
        usb_safety_validation = $safetyPath
        partition_layout = $layoutPath
        export_manifest = $exportResult.export_manifest_path
        copied_files = $exportResult.copied_files_path
        usb_boot_validation = $bootValidationPath
        rollback_plan = $rollbackPath
        disk_before_state = $beforeStatePath
        disk_after_state = $afterStatePath
    }
}

$exportReportPath = Join-Path $reportsDir 'usb-export-report.json'
$report | ConvertTo-Json -Depth 50 | Set-Content -Path $exportReportPath -Encoding UTF8

$summaryPath = Join-Path $reportsDir 'export-summary.html'
Export-DanewUsbSummaryHtml -Path $summaryPath -Report $report

Write-Host "USB device analysis: $deviceAnalysisPath"
Write-Host "USB safety validation: $safetyPath"
Write-Host "Partition layout: $layoutPath"
Write-Host "Export report: $exportReportPath"
Write-Host "Boot validation: $bootValidationPath"
Write-Host "Rollback plan: $rollbackPath"
Write-Host "Summary HTML: $summaryPath"
Write-Host "Global status: $status"
