function Get-DanewJsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -Path $Path)) {
        throw "Missing JSON file: $Path"
    }

    return Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-DanewCatalogContext {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath
    )

    $manifestPath = Join-Path $RootPath 'manifests'
    $profilePath = Join-Path $RootPath 'profiles'

    [pscustomobject]@{
        ToolsCatalog = Get-DanewJsonFile -Path (Join-Path $manifestPath 'tools.catalog.json')
        FeaturesCatalog = Get-DanewJsonFile -Path (Join-Path $manifestPath 'features.catalog.json')
        DependencyMap = Get-DanewJsonFile -Path (Join-Path $manifestPath 'dependencies.map.json')
        ScanPaths = Get-DanewJsonFile -Path (Join-Path $manifestPath 'scan.paths.json')
        BaselineTools = Get-DanewJsonFile -Path (Join-Path $manifestPath 'required-tools.baseline.json')
        DriverClassMap = Get-DanewJsonFile -Path (Join-Path $manifestPath 'driver-class.map.json')
        ScoringWeights = Get-DanewJsonFile -Path (Join-Path $manifestPath 'scoring.weights.json')
        SecurityPolicy = Get-DanewJsonFile -Path (Join-Path $manifestPath 'security.policy.json')
        ArchitectureRules = Get-DanewJsonFile -Path (Join-Path $manifestPath 'architecture.rules.json')
        WinPEPackagesCatalog = Get-DanewJsonFile -Path (Join-Path $manifestPath 'winpe-packages.catalog.json')
        VendorNormalizationMap = Get-DanewJsonFile -Path (Join-Path $manifestPath 'vendor-normalization.map.json')
        DriverEnrichmentCatalog = Get-DanewJsonFile -Path (Join-Path $manifestPath 'driver-enrichment.catalog.json')
        ToolEnrichmentCatalog = Get-DanewJsonFile -Path (Join-Path $manifestPath 'tool-enrichment.catalog.json')
        PackageDependencyOrder = Get-DanewJsonFile -Path (Join-Path $manifestPath 'package-dependency.order.json')
        BuildComposerSettings = Get-DanewJsonFile -Path (Join-Path $manifestPath 'build-composer.settings.json')
        Profiles = @{
            minimal = Get-DanewJsonFile -Path (Join-Path $profilePath 'minimal.profile.json')
            'sav-advanced' = Get-DanewJsonFile -Path (Join-Path $profilePath 'sav-advanced.profile.json')
            'oem-expert' = Get-DanewJsonFile -Path (Join-Path $profilePath 'oem-expert.profile.json')
        }
    }
}
