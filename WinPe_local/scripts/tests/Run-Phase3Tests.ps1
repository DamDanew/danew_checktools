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

. (Join-Path $PSScriptRoot '..\catalog\CatalogService.ps1')
. (Join-Path $PSScriptRoot '..\scan\ScanEngine.ps1')
. (Join-Path $PSScriptRoot '..\profiles\ProfileEngine.ps1')
. (Join-Path $PSScriptRoot '..\recommend\RecommendationEngine.ps1')
. (Join-Path $PSScriptRoot '..\recommend\EnrichmentPlanner.ps1')

function Add-TestResult {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [bool]$Passed,
        [string]$Details = ''
    )

    return [pscustomobject]@{
        name = $Name
        passed = $Passed
        details = $Details
    }
}

$catalog = Get-DanewCatalogContext -RootPath $RootPath
$profile = Get-DanewProfile -ProfileId 'sav-advanced' -CatalogContext $catalog
$results = @()

$tempRoot = Join-Path $RootPath 'temp\phase3-tests'
if (Test-Path -Path $tempRoot) {
    Remove-Item -Path $tempRoot -Recurse -Force
}
New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null

try {
    $case1 = Join-Path $tempRoot 'registry-fake-hives'
    New-Item -Path (Join-Path $case1 'Windows\System32\config') -ItemType Directory -Force | Out-Null
    Set-Content -Path (Join-Path $case1 'Windows\System32\config\SYSTEM') -Value 'fake' -Encoding ASCII
    Set-Content -Path (Join-Path $case1 'Windows\System32\config\SOFTWARE') -Value 'fake' -Encoding ASCII
    $reg1 = Get-DanewOfflineRegistryAnalysis -InputPath $case1
    $results += Add-TestResult -Name 'fake_registry_hive_case' -Passed ($reg1.system_hive_found -and $reg1.software_hive_found) -Details "loaded SYS=$($reg1.system_hive_loaded), SOFT=$($reg1.software_hive_loaded)"

    $case2 = Join-Path $tempRoot 'registry-missing-hives'
    New-Item -Path $case2 -ItemType Directory -Force | Out-Null
    $reg2 = Get-DanewOfflineRegistryAnalysis -InputPath $case2
    $results += Add-TestResult -Name 'missing_registry_hive_case' -Passed ((-not $reg2.system_hive_found) -and (-not $reg2.software_hive_found))

    $infRoot = Join-Path $tempRoot 'inf-vendors'
    New-Item -Path $infRoot -ItemType Directory -Force | Out-Null

    $vendorMap = @(
        @{ Name = 'intel.inf'; Provider = 'Intel' },
        @{ Name = 'realtek.inf'; Provider = 'Realtek' },
        @{ Name = 'qualcomm.inf'; Provider = 'Qualcomm Atheros' },
        @{ Name = 'mediatek.inf'; Provider = 'MediaTek' },
        @{ Name = 'broadcom.inf'; Provider = 'Broadcom' },
        @{ Name = 'microsoft.inf'; Provider = 'Microsoft' },
        @{ Name = 'amd.inf'; Provider = 'Advanced Micro Devices' },
        @{ Name = 'nvidia.inf'; Provider = 'NVIDIA' },
        @{ Name = 'unknown.inf'; Provider = 'Contoso Labs' }
    )

    $infMeta = @()
    foreach ($v in $vendorMap) {
        $infPath = Join-Path $infRoot $v.Name
        $infLines = @(
            '[Version]',
            'Signature="$Windows NT$"',
            'Class=Net',
            ('Provider="' + $v.Provider + '"'),
            ('Manufacturer="' + $v.Provider + '"')
        )
        $infLines | Set-Content -Path $infPath -Encoding ASCII
        $meta = Get-DanewInfMetadata -InfPath $infPath
        if ($meta) { $infMeta += $meta }
    }

    $vendorAnalysis = Get-DanewDriverVendorAnalysis -InfMetadata $infMeta -CatalogContext $catalog
    $knownVendorHits = ($vendorAnalysis.vendor_counts['Intel'] -ge 1 -and $vendorAnalysis.vendor_counts['Realtek'] -ge 1 -and $vendorAnalysis.vendor_counts['NVIDIA'] -ge 1)
    $unknownHit = @($vendorAnalysis.unknown_vendors).Count -ge 1
    $results += Add-TestResult -Name 'fake_inf_vendor_case' -Passed ($knownVendorHits -and $unknownHit)

    $mockScan = [pscustomobject]@{
        InputPath = $RootPath
        InputType = 'workdir'
        Architecture = 'x64'
        ArchitectureDetails = [pscustomobject]@{ detected = 'x64'; evidence = @() }
        FilesScanned = 1
        ToolsDetected = @('dism.exe')
        ToolMatches = @()
        DriversDetected = @()
        DriverAnalysis = [pscustomobject]@{
            inf_count = 0
            sys_count = 0
            classes_detected = @()
            categories_present = @('nvme')
            categories_missing = @('lan', 'wifi', 'usb3')
            evidence = @()
            inf_metadata = @()
        }
        DriverVendorAnalysis = $vendorAnalysis
        RegistryAnalysis = $reg1
        PackageAnalysis = [pscustomobject]@{
            source = 'test'
            detected_packages = @('WinPE-WMI')
            package_count = 1
            missing_required_packages = @('winpe-powershell', 'winpe-netfx')
            raw_count = 1
        }
        PeValidation = [pscustomobject]@{ checked = 0; compatible = 0; incompatible = 0; unknown = 0; details = @() }
        RuntimesDetected = @()
    }

    $plan = New-DanewEnrichmentPlan -ScanResult $mockScan -ProfileDefinition $profile -CatalogContext $catalog
    $results += Add-TestResult -Name 'missing_driver_category_case' -Passed (@($plan.driver_actions).Count -ge 2) -Details "driver_actions=$(@($plan.driver_actions).Count)"

    $before = Get-DanewCapabilityScore -ScanResult $mockScan -ProfileDefinition $profile -CatalogContext $catalog
    $delta = Get-DanewScoreDeltaFromPlan -ScanResult $mockScan -BeforeScore $before -ProfileDefinition $profile -CatalogContext $catalog -EnrichmentPlan $plan
    $results += Add-TestResult -Name 'score_delta_case' -Passed ($delta.delta.global -ge 0) -Details "delta_global=$($delta.delta.global)"

    $pkgMissing = Get-DanewPackageAnalysis -InputPath $case2 -BootWimPath '' -ImageIndex 1 -CatalogContext $catalog -ProfileId 'sav-advanced'
    $results += Add-TestResult -Name 'package_detection_case' -Passed (@($pkgMissing.missing_required_packages).Count -ge 1) -Details "missing_packages=$(@($pkgMissing.missing_required_packages).Count)"
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

$jsonPath = Join-Path $OutputDirectory 'phase3-tests-report.json'
$txtPath = Join-Path $OutputDirectory 'phase3-tests-report.txt'

$report | ConvertTo-Json -Depth 20 | Set-Content -Path $jsonPath -Encoding UTF8

$lines = @(
    "Phase 3 Tests",
    "Total: $($summary.total)",
    "Passed: $($summary.passed)",
    "Failed: $($summary.failed)",
    ""
)

foreach ($t in $results) {
    $status = if ($t.passed) { 'PASS' } else { 'FAIL' }
    $lines += "[$status] $($t.name) - $($t.details)"
}
$lines | Set-Content -Path $txtPath -Encoding UTF8

Write-Host "Phase 3 test report JSON: $jsonPath"
Write-Host "Phase 3 test report TXT: $txtPath"

if ($summary.failed -gt 0) {
    exit 1
}
