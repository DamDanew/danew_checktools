[CmdletBinding()]
param(
    [string]$RootPath = (Split-Path -Parent $PSScriptRoot),
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'launcher\LauncherCore.ps1')
. (Join-Path $PSScriptRoot 'catalog\CatalogService.ps1')
. (Join-Path $PSScriptRoot 'scan\ScanEngine.ps1')

function New-PreBootCheckItem {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [ValidateSet('PASS', 'WARNING', 'FAIL')]
        [string]$Status,
        [Parameter(Mandatory = $true)]
        [string]$Details,
        [object]$Data
    )

    [pscustomobject]@{
        name = $Name
        status = $Status
        details = $Details
        data = $Data
    }
}

function Get-StartNetGeneratedPath {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    $candidate = @(
        $Config.startnet_output_path,
        $Config.startnet_fallback_output_path,
        (Join-Path $Config.reports_path 'StartNet.generated.cmd')
    )

    foreach ($p in $candidate) {
        if (-not [string]::IsNullOrWhiteSpace($p) -and (Test-Path -Path $p)) {
            return $p
        }
    }

    return ''
}

function Get-ExecutionPolicyCompatibility {
    $policyList = @()
    try {
        $policyList = @(Get-ExecutionPolicy -List)
    }
    catch {
        $policyList = @()
    }

    $effective = ''
    try {
        $effective = [string](Get-ExecutionPolicy)
    }
    catch {
        $effective = 'Unknown'
    }

    $supportsBypass = $false
    try {
        $supportsBypass = (Get-Command powershell.exe -ErrorAction Stop) -ne $null
    }
    catch {
        $supportsBypass = $false
    }

    $status = 'PASS'
    $details = 'Execution policy compatible with launcher usage.'

    if (-not $supportsBypass) {
        $status = 'FAIL'
        $details = 'powershell.exe unavailable; cannot apply -ExecutionPolicy Bypass path.'
    }
    elseif ($effective -eq 'Restricted') {
        $status = 'WARNING'
        $details = 'Effective policy is Restricted, relying on explicit -ExecutionPolicy Bypass in launcher commands.'
    }

    return [pscustomobject]@{
        status = $status
        details = $details
        effective_policy = $effective
        policies = $policyList
    }
}

$config = Get-DanewLauncherConfig -RootPath $RootPath -ConfigPath $ConfigPath
Initialize-DanewLauncherPaths -Config $config

$reportsDir = $config.reports_path
if (-not (Test-Path -Path $reportsDir)) {
    New-Item -Path $reportsDir -ItemType Directory -Force | Out-Null
}

$checkItems = @()

$requiredScripts = @(
    'DanewCheckTool.CLI.ps1',
    'launcher.ps1',
    'launcher\LauncherCore.ps1',
    'Invoke-DanewRealWinPEValidation.ps1'
)

$scriptResults = @()
foreach ($rel in $requiredScripts) {
    $localPath = Join-Path (Join-Path $RootPath 'scripts') $rel
    $xPath = 'X:\scripts\' + ($rel -replace '/', '\\')

    $localExists = Test-Path -Path $localPath
    $xExists = Test-Path -Path $xPath

    $status = 'PASS'
    $details = ''

    if ($env:SystemDrive -eq 'X:') {
        if ($xExists) {
            $status = 'PASS'
            $details = 'Found in X:\\scripts.'
        }
        else {
            $status = 'FAIL'
            $details = 'Missing in X:\\scripts while running in WinPE.'
        }
    }
    else {
        if ($localExists) {
            if ($xExists) {
                $status = 'PASS'
                $details = 'Found locally and on X:\\scripts.'
            }
            else {
                $status = 'WARNING'
                $details = 'Found locally; X:\\scripts not available in current environment.'
            }
        }
        else {
            $status = 'FAIL'
            $details = 'Missing in local build scripts directory.'
        }
    }

    $scriptResults += [pscustomobject]@{
        script = $rel
        status = $status
        local_path = $localPath
        local_exists = $localExists
        x_path = $xPath
        x_exists = $xExists
        details = $details
    }
}

$scriptFailCount = @($scriptResults | Where-Object { $_.status -eq 'FAIL' }).Count
$scriptWarnCount = @($scriptResults | Where-Object { $_.status -eq 'WARNING' }).Count
$scriptStatus = if ($scriptFailCount -gt 0) { 'FAIL' } elseif ($scriptWarnCount -gt 0) { 'WARNING' } else { 'PASS' }
$checkItems += New-PreBootCheckItem -Name 'required_scripts_presence' -Status $scriptStatus -Details ("fail=$scriptFailCount warning=$scriptWarnCount") -Data $scriptResults

$startNetPath = Get-StartNetGeneratedPath -Config $config
$startNetStatus = 'FAIL'
$startNetDetails = 'StartNet.cmd not generated.'
$startNetData = [pscustomobject]@{ path = $startNetPath; has_launcher = $false; has_fallback = $false; has_cli = $false }

if (-not [string]::IsNullOrWhiteSpace($startNetPath) -and (Test-Path -Path $startNetPath)) {
    $content = Get-Content -Path $startNetPath -Raw -Encoding UTF8
    $hasLauncher = $content -match 'launcher\.ps1'
    $hasFallbackSwitch = $content -match '-FallbackToCli'
    $hasCliFallback = $content -match 'DanewCheckTool\.CLI\.ps1'

    $startNetData = [pscustomobject]@{
        path = $startNetPath
        has_launcher = $hasLauncher
        has_fallback = $hasFallbackSwitch
        has_cli = $hasCliFallback
    }

    if ($hasLauncher -and $hasFallbackSwitch -and $hasCliFallback) {
        $startNetStatus = 'PASS'
        $startNetDetails = 'StartNet generated and launcher/fallback commands are present.'
    }
    else {
        $startNetStatus = 'FAIL'
        $startNetDetails = 'StartNet generated but expected launcher/fallback commands are incomplete.'
    }
}

$checkItems += New-PreBootCheckItem -Name 'startnet_generation' -Status $startNetStatus -Details $startNetDetails -Data $startNetData

$bootWimPath = Join-Path $config.input_path 'sources\boot.wim'
$bootWimPackageStatus = 'FAIL'
$bootWimPackageDetails = 'boot.wim not found in build input.'
$bootWimPackageData = [pscustomobject]@{
    path = $bootWimPath
    exists = $false
    source = ''
    package_count = 0
    missing_required_packages = @()
    detected_packages = @()
    profile = $config.default_tier
}

if (Test-Path -Path $bootWimPath) {
    $catalog = Get-DanewCatalogContext -RootPath $RootPath
    $packageAnalysis = Get-DanewPackageAnalysis -InputPath $config.input_path -BootWimPath $bootWimPath -ImageIndex 1 -CatalogContext $catalog -ProfileId $config.default_tier
    $missingPackages = @($packageAnalysis.missing_required_packages)
    $bootWimPackageData = [pscustomobject]@{
        path = $bootWimPath
        exists = $true
        source = $packageAnalysis.source
        package_count = $packageAnalysis.package_count
        missing_required_packages = $missingPackages
        detected_packages = @($packageAnalysis.detected_packages)
        profile = $config.default_tier
    }

    if (@($missingPackages).Count -eq 0) {
        $bootWimPackageStatus = 'PASS'
        $bootWimPackageDetails = 'boot.wim contains all required WinPE packages for the selected profile.'
    }
    else {
        $bootWimPackageStatus = 'FAIL'
        $bootWimPackageDetails = 'boot.wim is missing required WinPE packages: ' + ($missingPackages -join ', ')
    }
}

$checkItems += New-PreBootCheckItem -Name 'boot_wim_required_packages' -Status $bootWimPackageStatus -Details $bootWimPackageDetails -Data $bootWimPackageData

$psCommand = Get-Command -Name powershell.exe -ErrorAction SilentlyContinue
$psStatus = if ($psCommand) { 'PASS' } else { 'FAIL' }
$psDetails = if ($psCommand) { 'powershell.exe detected.' } else { 'powershell.exe not detected.' }
$psSource = ''
if ($psCommand) {
    $psSource = $psCommand.Source
}
$checkItems += New-PreBootCheckItem -Name 'powershell_presence' -Status $psStatus -Details $psDetails -Data @{ source = $psSource }

$policy = Get-ExecutionPolicyCompatibility
$checkItems += New-PreBootCheckItem -Name 'execution_policy_compatibility' -Status $policy.status -Details $policy.details -Data @{ effective = $policy.effective_policy; list = $policy.policies }

$requiredFolders = @('X:\scripts', 'X:\reports', 'X:\logs', 'X:\tools')
$folderData = @()
foreach ($folder in $requiredFolders) {
    $exists = Test-Path -Path $folder
    $folderStatus = if ($exists) { 'PASS' } elseif ($env:SystemDrive -eq 'X:') { 'FAIL' } else { 'WARNING' }
    $folderData += [pscustomobject]@{ folder = $folder; exists = $exists; status = $folderStatus }
}
$folderFail = @($folderData | Where-Object { $_.status -eq 'FAIL' }).Count
$folderWarn = @($folderData | Where-Object { $_.status -eq 'WARNING' }).Count
$folderStatus = if ($folderFail -gt 0) { 'FAIL' } elseif ($folderWarn -gt 0) { 'WARNING' } else { 'PASS' }
$folderDetails = if ($folderStatus -eq 'PASS') { 'All required X: folders exist.' } elseif ($folderStatus -eq 'FAIL') { 'Missing required X: folders in WinPE runtime.' } else { 'X: folders not all present in non-WinPE environment (expected before real boot).' }
$checkItems += New-PreBootCheckItem -Name 'required_x_folders' -Status $folderStatus -Details $folderDetails -Data $folderData

$guiFallbackValid = $false
$guiFallbackReason = ''
if (-not [string]::IsNullOrWhiteSpace($startNetPath) -and (Test-Path -Path $startNetPath)) {
    $startNetText = Get-Content -Path $startNetPath -Raw -Encoding UTF8
    $launcherText = Get-Content -Path (Join-Path $RootPath 'scripts\launcher.ps1') -Raw -Encoding UTF8

    $hasStartNetFallbackCall = ($startNetText -match 'launcher\.ps1') -and ($startNetText -match '-FallbackToCli')
    $launcherCanFallback = ($launcherText -match '\[switch\]\$FallbackToCli') -and ($launcherText -match 'DanewCheckTool\.CLI\.ps1')
    $guiFallbackValid = $hasStartNetFallbackCall -and $launcherCanFallback
    $guiFallbackReason = if ($guiFallbackValid) { 'GUI fallback command chain is valid.' } else { 'GUI fallback command chain is incomplete.' }
}
else {
    $guiFallbackReason = 'StartNet generated file missing; cannot validate fallback command chain.'
}
$guiFallbackStatus = 'FAIL'
if ($guiFallbackValid) {
    $guiFallbackStatus = 'PASS'
}
$checkItems += New-PreBootCheckItem -Name 'gui_fallback_command_valid' -Status $guiFallbackStatus -Details $guiFallbackReason

$cliPath = Join-Path $RootPath 'scripts\DanewCheckTool.CLI.ps1'
$cliValid = $false
$cliReason = ''
if (Test-Path -Path $cliPath) {
    $cliText = Get-Content -Path $cliPath -Raw -Encoding UTF8
    $hasValidateSet = $cliText.Contains('real-winpe-validation')
    $hasBranch = $cliText.Contains("$" + "Command -eq 'real-winpe-validation'")
    $hasValidationScriptCall = $cliText.Contains('Invoke-DanewRealWinPEValidation.ps1')

    $cliValid = $hasValidateSet -and $hasBranch -and $hasValidationScriptCall
    $cliReason = if ($cliValid) { 'CLI real-winpe-validation command is wired correctly.' } else { 'CLI real-winpe-validation command wiring is incomplete.' }
}
else {
    $cliReason = 'CLI script missing.'
}
$cliValidationStatus = 'FAIL'
if ($cliValid) {
    $cliValidationStatus = 'PASS'
}
$checkItems += New-PreBootCheckItem -Name 'cli_real_winpe_validation_command_valid' -Status $cliValidationStatus -Details $cliReason

$failCount = @($checkItems | Where-Object { $_.status -eq 'FAIL' }).Count
$warningCount = @($checkItems | Where-Object { $_.status -eq 'WARNING' }).Count
$passCount = @($checkItems | Where-Object { $_.status -eq 'PASS' }).Count

$overallStatus = if ($failCount -gt 0) { 'FAIL' } elseif ($warningCount -gt 0) { 'WARNING' } else { 'PASS' }

$result = [pscustomobject]@{
    timestamp = (Get-Date).ToString('s')
    root_path = $RootPath
    system_drive = $env:SystemDrive
    overall_status = $overallStatus
    summary = [pscustomobject]@{
        pass = $passCount
        warning = $warningCount
        fail = $failCount
    }
    checks = $checkItems
}

$jsonPath = Join-Path $reportsDir 'pre-real-boot-check.json'
$txtPath = Join-Path $reportsDir 'pre-real-boot-check.txt'

$result | ConvertTo-Json -Depth 50 | Set-Content -Path $jsonPath -Encoding UTF8

$lines = @(
    'Danew Pre-Real-Boot Check',
    ('Timestamp: ' + $result.timestamp),
    ('RootPath: ' + $result.root_path),
    ('SystemDrive: ' + $result.system_drive),
    ('OverallStatus: ' + $result.overall_status),
    ('PASS: ' + $result.summary.pass),
    ('WARNING: ' + $result.summary.warning),
    ('FAIL: ' + $result.summary.fail),
    ''
)

foreach ($c in $checkItems) {
    $lines += ('[' + $c.status + '] ' + $c.name + ' - ' + $c.details)
}

$lines | Set-Content -Path $txtPath -Encoding UTF8

Write-Host "Pre-real-boot JSON: $jsonPath"
Write-Host "Pre-real-boot TXT: $txtPath"
Write-Host "Overall status: $overallStatus"
