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
. (Join-Path $PSScriptRoot '..\security\SecurityService.ps1')
. (Join-Path $PSScriptRoot '..\report\ReportEngine.ps1')
. (Join-Path $PSScriptRoot '..\build\Phase4Execution.ps1')

function Add-Phase4TestResult {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Details = ''
    )

    return [pscustomobject]@{ name = $Name; passed = $Passed; details = $Details }
}

function New-FakeEnrichmentPlan {
    param(
        [string]$Path,
        [string]$Architecture = 'x64',
        [string]$ToolName = 'cmd.exe',
        [string]$ToolPriority = 'critical',
        [string]$DriverCategory = 'lan',
        [string]$DriverPackage = 'Danew-DriverPack-LAN',
        [string]$PackageId = 'winpe-wmi',
        [string]$PackageName = 'WinPE-WMI'
    )

    $plan = [pscustomobject]@{
        plan_id = ([guid]::NewGuid().ToString())
        timestamp = (Get-Date).ToString('s')
        profile = 'sav-advanced'
        architecture = $Architecture
        driver_actions = @(
            [pscustomobject]@{ category_id = $DriverCategory; package_name = $DriverPackage; priority = 'critical'; size_mb = 10; ram_mb = 5; vendor_preferences = @('Intel'); action = 'Inject driver package' }
        )
        tool_actions = @(
            [pscustomobject]@{ tool = $ToolName; reason = 'test'; priority = $ToolPriority; size_mb = 1; ram_mb = 1; action = 'Add tool' }
        )
        package_actions = @(
            [pscustomobject]@{ package_id = $PackageId; package_name = $PackageName; package_pattern = $PackageName; priority = 'critical'; size_mb = 5; ram_mb = 2; action = 'Add package' }
        )
        estimated_size_mb = 16
        estimated_ram_mb = 8
    }

    $plan | ConvertTo-Json -Depth 20 | Set-Content -Path $Path -Encoding UTF8
}

$catalog = Get-DanewCatalogContext -RootPath $RootPath
$results = @()

$tempRoot = Join-Path $RootPath 'temp\phase4-tests'
if (Test-Path -Path $tempRoot) {
    Remove-Item -Path $tempRoot -Recurse -Force
}
New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null

try {
    $assetRoot = Join-Path $tempRoot 'assets'
    $inputRoot = Join-Path $tempRoot 'input'
    $planPath = Join-Path $tempRoot 'enrichment-plan.json'

    New-Item -Path (Join-Path $assetRoot 'tools') -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $assetRoot 'drivers\Danew-DriverPack-LAN') -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $assetRoot 'packages\WinPE-WMI') -ItemType Directory -Force | Out-Null

    New-Item -Path (Join-Path $inputRoot 'Boot') -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $inputRoot 'EFI\Boot') -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $inputRoot 'sources') -ItemType Directory -Force | Out-Null

    Set-Content -Path (Join-Path $inputRoot 'Boot\boot.sdi') -Value 'boot-sdi' -Encoding ASCII
    Set-Content -Path (Join-Path $inputRoot 'Boot\BCD') -Value 'bcd' -Encoding ASCII
    Set-Content -Path (Join-Path $inputRoot 'EFI\Boot\bootx64.efi') -Value 'efi' -Encoding ASCII
    Set-Content -Path (Join-Path $inputRoot 'sources\boot.wim') -Value 'wim' -Encoding ASCII

    Set-Content -Path (Join-Path $assetRoot 'tools\cmd.exe') -Value 'fake-cmd' -Encoding ASCII
    @(
        '[Version]',
        'Signature="$Windows NT$"',
        '[Manufacturer]',
        'Intel=Intel,NTamd64',
        '[Intel.NTamd64]',
        '%Device%=Install,PCI\\VEN_8086&DEV_1234'
    ) | Set-Content -Path (Join-Path $assetRoot 'drivers\Danew-DriverPack-LAN\lan.inf') -Encoding ASCII
    Set-Content -Path (Join-Path $assetRoot 'drivers\Danew-DriverPack-LAN\lan.sys') -Value 'sys' -Encoding ASCII
    Set-Content -Path (Join-Path $assetRoot 'packages\WinPE-WMI\winpe-wmi.cab') -Value 'cab' -Encoding ASCII

    New-FakeEnrichmentPlan -Path $planPath

    $exec1 = Invoke-DanewPhase4Execution -RootPath $RootPath -InputPath $inputRoot -EnrichmentPlanPath $planPath -Mode Execute -AssetRootPath $assetRoot -BuildId 'phase4-test-exec'
    $bm1 = Get-DanewJsonFromPath -Path $exec1.build_manifest
    $results += Add-Phase4TestResult -Name 'fake_enrichment_execution' -Passed (Test-Path -Path $exec1.build_manifest) -Details "actions=$(@($bm1.actions).Count)"

    New-FakeEnrichmentPlan -Path $planPath -ToolName 'cmd.exe' -ToolPriority 'critical'
    Set-Content -Path (Join-Path $assetRoot 'tools\cmd.exe') -Value 'unsigned' -Encoding ASCII
    $exec2 = Invoke-DanewPhase4Execution -RootPath $RootPath -InputPath $inputRoot -EnrichmentPlanPath $planPath -Mode Execute -AssetRootPath $assetRoot -BuildId 'phase4-test-unsigned'
    $sec2 = Get-DanewJsonFromPath -Path $exec2.security_approval_report
    $results += Add-Phase4TestResult -Name 'blocked_unsigned_tool' -Passed (-not $sec2.approved)

    New-FakeEnrichmentPlan -Path $planPath -ToolName 'smartctl' -ToolPriority 'critical'
    Set-Content -Path (Join-Path $assetRoot 'tools\smartctl.exe') -Value 'hash-mismatch' -Encoding ASCII
    $exec3 = Invoke-DanewPhase4Execution -RootPath $RootPath -InputPath $inputRoot -EnrichmentPlanPath $planPath -Mode Execute -AssetRootPath $assetRoot -BuildId 'phase4-test-hash'
    $sec3 = Get-DanewJsonFromPath -Path $exec3.security_approval_report
    $hasHashViolation = @($sec3.violations | Where-Object { -not $_.sha256_ok }).Count -ge 1
    $results += Add-Phase4TestResult -Name 'hash_mismatch' -Passed $hasHashViolation

    New-FakeEnrichmentPlan -Path $planPath -DriverCategory 'wifi' -DriverPackage 'MissingPack'
    $exec4 = Invoke-DanewPhase4Execution -RootPath $RootPath -InputPath $inputRoot -EnrichmentPlanPath $planPath -Mode DryRun -AssetRootPath $assetRoot -BuildId 'phase4-test-missing-inf'
    $bm4 = Get-DanewJsonFromPath -Path $exec4.build_manifest
    $missingInf = @($bm4.actions | Where-Object { $_.type -eq 'driver' -and $_.status -eq 'missing_inf' }).Count -ge 1
    $results += Add-Phase4TestResult -Name 'missing_inf' -Passed $missingInf

    New-Item -Path (Join-Path $assetRoot 'drivers\Danew-DriverPack-LAN') -ItemType Directory -Force | Out-Null
    @(
        '[Version]',
        'Signature="$Windows NT$"',
        '[Manufacturer]',
        'Intel=Intel,NTx86',
        '[Intel.NTx86]',
        '%Device%=Install,PCI\\VEN_8086&DEV_1111'
    ) | Set-Content -Path (Join-Path $assetRoot 'drivers\Danew-DriverPack-LAN\wrong.inf') -Encoding ASCII
    New-FakeEnrichmentPlan -Path $planPath -DriverCategory 'lan' -DriverPackage 'Danew-DriverPack-LAN' -Architecture 'x64'
    $exec5 = Invoke-DanewPhase4Execution -RootPath $RootPath -InputPath $inputRoot -EnrichmentPlanPath $planPath -Mode DryRun -AssetRootPath $assetRoot -BuildId 'phase4-test-wrong-arch'
    $bm5 = Get-DanewJsonFromPath -Path $exec5.build_manifest
    $wrongArch = @($bm5.actions | Where-Object { $_.type -eq 'driver' -and $_.status -eq 'wrong_architecture' }).Count -ge 1
    $results += Add-Phase4TestResult -Name 'wrong_architecture_driver' -Passed $wrongArch

    $planOrder = [pscustomobject]@{
        plan_id = ([guid]::NewGuid().ToString())
        timestamp = (Get-Date).ToString('s')
        profile = 'sav-advanced'
        architecture = 'x64'
        driver_actions = @()
        tool_actions = @()
        package_actions = @(
            [pscustomobject]@{ package_id = 'winpe-powershell'; package_name = 'WinPE-PowerShell'; package_pattern = 'WinPE-PowerShell'; priority = 'critical'; size_mb = 1; ram_mb = 1; action = 'x' },
            [pscustomobject]@{ package_id = 'winpe-wmi'; package_name = 'WinPE-WMI'; package_pattern = 'WinPE-WMI'; priority = 'critical'; size_mb = 1; ram_mb = 1; action = 'x' }
        )
        estimated_size_mb = 2
        estimated_ram_mb = 2
    }
    $planOrder | ConvertTo-Json -Depth 20 | Set-Content -Path $planPath -Encoding UTF8
    Set-Content -Path (Join-Path $assetRoot 'packages\WinPE-WMI\a.cab') -Value 'cab' -Encoding ASCII
    New-Item -Path (Join-Path $assetRoot 'packages\WinPE-PowerShell') -ItemType Directory -Force | Out-Null
    Set-Content -Path (Join-Path $assetRoot 'packages\WinPE-PowerShell\b.cab') -Value 'cab' -Encoding ASCII
    $exec6 = Invoke-DanewPhase4Execution -RootPath $RootPath -InputPath $inputRoot -EnrichmentPlanPath $planPath -Mode DryRun -AssetRootPath $assetRoot -BuildId 'phase4-test-order'
    $cmd = Get-Content -Path $exec6.command_plan -Raw -Encoding UTF8
    $idxWmi = $cmd.IndexOf('a.cab')
    $idxPs = $cmd.IndexOf('b.cab')
    $results += Add-Phase4TestResult -Name 'package_dependency_ordering' -Passed (($idxWmi -ge 0) -and ($idxPs -ge 0) -and ($idxWmi -lt $idxPs))

    Remove-Item -Path (Join-Path $inputRoot 'Boot\BCD') -Force
    New-FakeEnrichmentPlan -Path $planPath
    $exec7 = Invoke-DanewPhase4Execution -RootPath $RootPath -InputPath $inputRoot -EnrichmentPlanPath $planPath -Mode DryRun -AssetRootPath $assetRoot -BuildId 'phase4-test-usb-validation'
    $usb7 = Get-DanewJsonFromPath -Path $exec7.usb_export_validation
    $results += Add-Phase4TestResult -Name 'usb_export_validation' -Passed (-not $usb7.ready_for_export)

    $rollback7 = Get-DanewJsonFromPath -Path $exec7.rollback_manifest
    $results += Add-Phase4TestResult -Name 'rollback_manifest_validation' -Passed (@($rollback7.rollback_actions).Count -ge 1)
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

$jsonPath = Join-Path $OutputDirectory 'phase4-tests-report.json'
$txtPath = Join-Path $OutputDirectory 'phase4-tests-report.txt'

$report | ConvertTo-Json -Depth 20 | Set-Content -Path $jsonPath -Encoding UTF8

$lines = @(
    'Phase 4 Tests',
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

Write-Host "Phase 4 test report JSON: $jsonPath"
Write-Host "Phase 4 test report TXT: $txtPath"

if ($summary.failed -gt 0) {
    exit 1
}
