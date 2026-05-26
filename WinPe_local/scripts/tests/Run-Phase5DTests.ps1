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

function Add-Phase5DTestResult {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Details = ''
    )

    [pscustomobject]@{ name = $Name; passed = $Passed; details = $Details }
}

$results = @()
$tempRoot = Join-Path $RootPath 'temp\phase5d-tests'
if (Test-Path -Path $tempRoot) {
    Remove-Item -Path $tempRoot -Recurse -Force
}
New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null

try {
    $testRoot = Join-Path $tempRoot 'winpe-root'
    New-Item -Path $testRoot -ItemType Directory -Force | Out-Null

    foreach ($p in @('scripts', 'reports', 'logs', 'builds', 'Boot', 'EFI\Boot', 'sources', 'manifests', 'schemas', 'profiles', 'tools', 'drivers', 'images')) {
        New-Item -Path (Join-Path $testRoot $p) -ItemType Directory -Force | Out-Null
    }

    Copy-Item -Path (Join-Path $RootPath 'scripts\*') -Destination (Join-Path $testRoot 'scripts') -Recurse -Force
    Copy-Item -Path (Join-Path $RootPath 'manifests\*') -Destination (Join-Path $testRoot 'manifests') -Recurse -Force
    Copy-Item -Path (Join-Path $RootPath 'schemas\*') -Destination (Join-Path $testRoot 'schemas') -Recurse -Force
    Copy-Item -Path (Join-Path $RootPath 'profiles\*') -Destination (Join-Path $testRoot 'profiles') -Recurse -Force

    Set-Content -Path (Join-Path $testRoot 'Boot\BCD') -Value 'bcd' -Encoding ASCII
    Set-Content -Path (Join-Path $testRoot 'Boot\boot.sdi') -Value 'sdi' -Encoding ASCII
    Set-Content -Path (Join-Path $testRoot 'EFI\Boot\bootx64.efi') -Value 'efi' -Encoding ASCII
    Set-Content -Path (Join-Path $testRoot 'sources\boot.wim') -Value ('x' * 1024) -Encoding ASCII
    Set-Content -Path (Join-Path $testRoot 'scripts\StartNet.cmd.template') -Value '@echo off' -Encoding ASCII

    $cfgPath = Join-Path $testRoot 'scripts\launcher-config.json'
    $cfg = Get-Content -Path $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
    $cfg.input_path = '.'
    $cfg.reports_path = 'reports'
    $cfg.logs_path = 'logs'
    $cfg.launcher_log_path = 'logs/launcher-log.json'
    $cfg.startnet_output_path = 'reports/StartNet.runtime.cmd'
    $cfg.startnet_fallback_output_path = 'reports/StartNet.fallback.cmd'
    $cfg | ConvertTo-Json -Depth 20 | Set-Content -Path $cfgPath -Encoding UTF8

    $simDisksPath = Join-Path $tempRoot 'sim-disks.json'
    $simDisks = @(
        [pscustomobject]@{ disk_number = 1; friendly_name = 'Internal SSD'; manufacturer = 'NVMe'; serial_number = 'INT001'; size_bytes = 256GB; free_bytes = 100GB; bus_type = 'NVMe'; removable = $false; partition_style = 'GPT'; filesystems = @('NTFS'); mounted_letters = @('C:'); usb_version = ''; performance_category = 'High'; is_boot = $true; is_system = $true; contains_windows = $true },
        [pscustomobject]@{ disk_number = 2; friendly_name = 'USB Small'; manufacturer = 'Kingston'; serial_number = 'USB002'; size_bytes = 8GB; free_bytes = 7GB; bus_type = 'USB'; removable = $true; partition_style = 'GPT'; filesystems = @('FAT32'); mounted_letters = @('E:'); usb_version = '3.0'; performance_category = 'Low'; is_boot = $false; is_system = $false; contains_windows = $false },
        [pscustomobject]@{ disk_number = 3; friendly_name = 'USB Good'; manufacturer = 'SanDisk'; serial_number = 'USB003'; size_bytes = 64GB; free_bytes = 62GB; bus_type = 'USB'; removable = $true; partition_style = 'RAW'; filesystems = @(); mounted_letters = @(); usb_version = '3.2'; performance_category = 'High'; is_boot = $false; is_system = $false; contains_windows = $false }
    )
    $simDisks | ConvertTo-Json -Depth 20 | Set-Content -Path $simDisksPath -Encoding UTF8

    $simRoot = Join-Path $tempRoot 'sim-target'
    New-Item -Path $simRoot -ItemType Directory -Force | Out-Null

    $creator = Join-Path $testRoot 'scripts\Invoke-DanewCreateUsbMedia.ps1'

    & $creator -RootPath $testRoot -ConfigPath $cfgPath -Mode Analyze -SimulatedDisksPath $simDisksPath -NonInteractive
    $analysis = Get-Content -Path (Join-Path $testRoot 'reports\usb-device-analysis.json') -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 40
    $hasInternalExcluded = @($analysis | Where-Object { $_.disk_number -eq 1 }).Count -eq 0
    $results += Add-Phase5DTestResult -Name 'fake_internal_disks_excluded' -Passed $hasInternalExcluded

    $small = $analysis | Where-Object { $_.disk_number -eq 2 } | Select-Object -First 1
    $results += Add-Phase5DTestResult -Name 'too_small_usb_warning_or_fail' -Passed (($small.compatibility.status -eq 'FAIL') -or ($small.compatibility.status -eq 'WARNING')) -Details ([string]$small.compatibility.status)

    & $creator -RootPath $testRoot -ConfigPath $cfgPath -Mode Provision -SimulatedDisksPath $simDisksPath -SimulationRoot $simRoot -NonInteractive -TargetDiskNumber 3 -ConfirmDiskNumber 3 -ConfirmToken 'DANEW-FORMAT-DISK-3'

    $layout = Get-Content -Path (Join-Path $testRoot 'reports\partition-layout.json') -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 40
    $results += Add-Phase5DTestResult -Name 'gpt_validation' -Passed ($layout.partition_style -eq 'GPT')
    $results += Add-Phase5DTestResult -Name 'dual_partition_validation' -Passed (@($layout.partitions).Count -ge 2)

    $exportReport = Get-Content -Path (Join-Path $testRoot 'reports\usb-export-report.json') -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 60
    $results += Add-Phase5DTestResult -Name 'export_validation' -Passed (Test-Path -Path $exportReport.artifacts.export_manifest)

    $bootValidation = Get-Content -Path (Join-Path $testRoot 'reports\usb-boot-validation.json') -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 40
    $missingEfi = @($bootValidation.checks | Where-Object { $_.name -eq 'efi_bootx64' -and -not $_.exists }).Count
    $results += Add-Phase5DTestResult -Name 'missing_efi_files_detection' -Passed ($missingEfi -eq 0)

    $rollback = Get-Content -Path (Join-Path $testRoot 'reports\rollback-usb-plan.json') -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 40
    $results += Add-Phase5DTestResult -Name 'rollback_validation' -Passed (@($rollback.rollback_actions).Count -ge 1)

    $safety = Get-Content -Path (Join-Path $testRoot 'reports\usb-safety-validation.json') -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 40
    $results += Add-Phase5DTestResult -Name 'usb_safety_validation' -Passed ([bool]$safety.safety_passed)
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

$jsonPath = Join-Path $OutputDirectory 'phase5d-tests-report.json'
$txtPath = Join-Path $OutputDirectory 'phase5d-tests-report.txt'

$report | ConvertTo-Json -Depth 30 | Set-Content -Path $jsonPath -Encoding UTF8

$lines = @(
    'Phase 5D Tests',
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

Write-Host "Phase 5D test report JSON: $jsonPath"
Write-Host "Phase 5D test report TXT: $txtPath"

if ($summary.failed -gt 0) {
    exit 1
}
