[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputPath,
    [string]$RootPath = (Split-Path -Parent $PSScriptRoot),
    [string]$EnrichmentPlanPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'reports\enrichment-plan.json'),
    [ValidateSet('DryRun', 'Execute')]
    [string]$Mode = 'DryRun',
    [string]$AssetRootPath,
    [string]$BuildId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'core\Logging.ps1')
. (Join-Path $PSScriptRoot 'catalog\CatalogService.ps1')
. (Join-Path $PSScriptRoot 'security\SecurityService.ps1')
. (Join-Path $PSScriptRoot 'report\ReportEngine.ps1')
. (Join-Path $PSScriptRoot 'build\Phase4Execution.ps1')

if (-not (Test-Path -Path $InputPath)) {
    throw "Input path not found: $InputPath"
}

if (-not (Test-Path -Path $EnrichmentPlanPath)) {
    throw "Enrichment plan not found: $EnrichmentPlanPath"
}

if (-not $AssetRootPath) {
    $AssetRootPath = $RootPath
}

$logFile = Join-Path $RootPath ("logs\phase4-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".log")
Write-DanewLog -Level INFO -Message "Starting Phase 4 build execution ($Mode)" -LogFile $logFile

$result = Invoke-DanewPhase4Execution -RootPath $RootPath -InputPath $InputPath -EnrichmentPlanPath $EnrichmentPlanPath -Mode $Mode -AssetRootPath $AssetRootPath -BuildId $BuildId

Write-DanewLog -Level INFO -Message "Build manifest: $($result.build_manifest)" -LogFile $logFile
Write-DanewLog -Level INFO -Message "Rollback manifest: $($result.rollback_manifest)" -LogFile $logFile
Write-DanewLog -Level INFO -Message "Security approval: $($result.security_approval_report)" -LogFile $logFile
Write-DanewLog -Level INFO -Message "USB validation: $($result.usb_export_validation)" -LogFile $logFile

Write-Host "Phase 4 execution complete."
Write-Host "Build manifest: $($result.build_manifest)"
Write-Host "Rollback manifest: $($result.rollback_manifest)"
Write-Host "Command plan: $($result.command_plan)"
Write-Host "Security report: $($result.security_approval_report)"
Write-Host "USB export validation: $($result.usb_export_validation)"
Write-Host "Build summary: $($result.build_summary_html)"
