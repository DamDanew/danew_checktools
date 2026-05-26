[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputPath,

    [ValidateSet('minimal','sav-advanced','oem-expert')]
    [string]$TargetTier = 'sav-advanced',

    [ValidateSet('Simulation','PlanOnly')]
    [string]$Mode = 'Simulation',

    [string]$BootWimPath,

    [int]$ImageIndex = 1,

    [string]$RootPath = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'core\Logging.ps1')
. (Join-Path $PSScriptRoot 'catalog\CatalogService.ps1')
. (Join-Path $PSScriptRoot 'scan\ScanEngine.ps1')
. (Join-Path $PSScriptRoot 'profiles\ProfileEngine.ps1')
. (Join-Path $PSScriptRoot 'recommend\RecommendationEngine.ps1')
. (Join-Path $PSScriptRoot 'build\BuildPreparation.ps1')
. (Join-Path $PSScriptRoot 'report\ReportEngine.ps1')
. (Join-Path $PSScriptRoot 'cache\CacheService.ps1')
. (Join-Path $PSScriptRoot 'security\SecurityService.ps1')

if (-not (Test-Path -Path $InputPath)) {
    throw "Input path not found: $InputPath"
}

$logFile = Join-Path $RootPath ("logs\foundation-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".log")
Write-DanewLog -Level INFO -Message "Starting Danew foundation scan" -LogFile $logFile

$catalog = Get-DanewCatalogContext -RootPath $RootPath
$scan = Invoke-DanewScan -InputPath $InputPath -CatalogContext $catalog -BootWimPath $BootWimPath -ImageIndex $ImageIndex -ProfileId $TargetTier
$profileDef = Get-DanewProfile -ProfileId $TargetTier -CatalogContext $catalog
$coverage = Get-DanewProfileCoverage -ScanResult $scan -ProfileDefinition $profileDef
$score = Get-DanewCapabilityScore -ScanResult $scan -ProfileDefinition $profileDef -CatalogContext $catalog
$securityValidation = Invoke-DanewSecurityValidation -InputPath $InputPath -CatalogContext $catalog
$recommendations = Get-DanewRecommendations -ScanResult $scan -ProfileDefinition $profileDef -CatalogContext $catalog -FeatureStatus $score.feature_status -SecurityValidation $securityValidation
$buildPlan = New-DanewBuildPreparationPlan -Recommendations $recommendations -ProfileId $TargetTier -Architecture $scan.Architecture -Mode $Mode

$report = [pscustomobject]@{
    scan_id = [guid]::NewGuid().ToString()
    timestamp = (Get-Date).ToString('s')
    input = [pscustomobject]@{
        path = $InputPath
        input_type = $scan.InputType
    }
    architecture = $scan.Architecture
    architecture_details = $scan.ArchitectureDetails
    inventory = [pscustomobject]@{
        files_scanned = $scan.FilesScanned
        tools_detected = $scan.ToolsDetected
        drivers_detected = $scan.DriversDetected
        runtimes_detected = $scan.RuntimesDetected
    }
    driver_analysis = $scan.DriverAnalysis
    pe_validation = $scan.PeValidation
    security_validation = $securityValidation
    feature_status = $score.feature_status
    profile = $coverage
    score = [pscustomobject]@{
        system_recovery = $score.system_recovery
        networking = $score.networking
        disk_recovery = $score.disk_recovery
        gui = $score.gui
        crash_analysis = $score.crash_analysis
        global = $score.global
    }
    recommendations = $recommendations
    build_plan = $buildPlan
}

$reportName = "scan-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
$exported = Export-DanewReports -ReportObject $report -OutputDirectory (Join-Path $RootPath 'reports') -BaseName $reportName
$historyEntry = Add-DanewBuildHistoryEntry -RootPath $RootPath -BuildPlan $buildPlan -Recommendations $recommendations

Write-DanewLog -Level INFO -Message "Report exported to $($exported.json)" -LogFile $logFile
Write-DanewLog -Level INFO -Message $buildPlan.summary -LogFile $logFile
Write-Host "Foundation scan complete."
Write-Host "JSON report: $($exported.json)"
Write-Host "Build history ID: $($historyEntry.build_id)"
