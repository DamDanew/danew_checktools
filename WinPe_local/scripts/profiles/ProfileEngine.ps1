function Get-DanewProfile {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('minimal','sav-advanced','oem-expert')]
        [string]$ProfileId,
        [Parameter(Mandatory = $true)]
        [object]$CatalogContext
    )

    return $CatalogContext.Profiles[$ProfileId]
}

function Get-DanewProfileCoverage {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ScanResult,
        [Parameter(Mandatory = $true)]
        [object]$ProfileDefinition
    )

    $detected = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($t in $ScanResult.ToolsDetected) {
        [void]$detected.Add($t)
    }

    $missingRequired = @()
    foreach ($req in $ProfileDefinition.required_tools) {
        if (-not $detected.Contains($req)) {
            $missingRequired += $req
        }
    }

    [pscustomobject]@{
        ProfileId = $ProfileDefinition.id
        RequiredToolCount = @($ProfileDefinition.required_tools).Count
        MissingRequiredTools = $missingRequired
        CoveragePercent = if (@($ProfileDefinition.required_tools).Count -eq 0) {
            100
        }
        else {
            [math]::Round(((@($ProfileDefinition.required_tools).Count - $missingRequired.Count) / @($ProfileDefinition.required_tools).Count) * 100)
        }
    }
}
