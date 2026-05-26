function Test-DanewFeaturePresence {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Feature,
        [Parameter(Mandatory = $true)]
        [object]$ScanResult
    )

    $tools = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($t in $ScanResult.ToolsDetected) {
        [void]$tools.Add($t)
    }

    $runtimes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($r in $ScanResult.RuntimesDetected) {
        [void]$runtimes.Add($r)
    }

    $driverCats = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($dc in $ScanResult.DriverAnalysis.categories_present) {
        [void]$driverCats.Add($dc)
    }

    $packages = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($ScanResult.PSObject.Properties['PackageAnalysis'] -and $ScanResult.PackageAnalysis -and $ScanResult.PackageAnalysis.detected_packages) {
        foreach ($pkg in $ScanResult.PackageAnalysis.detected_packages) {
            [void]$packages.Add($pkg)
        }
    }

    $detection = $Feature.detection
    if (-not $detection) {
        return $false
    }

    $allOfFilesOk = $true
    if ($detection.PSObject.Properties['allOfFiles']) {
        foreach ($f in $detection.allOfFiles) {
            $fp = Join-Path $ScanResult.InputPath $f
            if (-not (Test-Path -Path $fp)) {
                $allOfFilesOk = $false
                break
            }
        }
    }

    $anyFileHit = $false
    if ($detection.PSObject.Properties['anyOfFiles']) {
        foreach ($f in $detection.anyOfFiles) {
            $fp = Join-Path $ScanResult.InputPath $f
            if (Test-Path -Path $fp) {
                $anyFileHit = $true
                break
            }
        }
    }

    $anyToolHit = $false
    if ($detection.PSObject.Properties['anyOfTools']) {
        foreach ($t in $detection.anyOfTools) {
            if ($tools.Contains($t) -or $tools.Contains("$t.exe")) {
                $anyToolHit = $true
                break
            }
        }
    }

    $anyRuntimeHit = $false
    if ($detection.PSObject.Properties['anyOfRuntimes']) {
        foreach ($rt in $detection.anyOfRuntimes) {
            if ($runtimes.Contains($rt)) {
                $anyRuntimeHit = $true
                break
            }
        }
    }

    $anyDriverHit = $false
    if ($detection.PSObject.Properties['anyOfDriverCategories']) {
        foreach ($dc in $detection.anyOfDriverCategories) {
            if ($driverCats.Contains($dc)) {
                $anyDriverHit = $true
                break
            }
        }
    }

    $anyPackageHit = $false
    if ($detection.PSObject.Properties['anyOfPackages']) {
        foreach ($pkgPattern in $detection.anyOfPackages) {
            foreach ($pkg in $packages) {
                if ($pkg -match [regex]::Escape($pkgPattern)) {
                    $anyPackageHit = $true
                    break
                }
            }
            if ($anyPackageHit) {
                break
            }
        }
    }

    $allDriversOk = $true
    if ($detection.PSObject.Properties['allOfDriverCategories']) {
        foreach ($dc in $detection.allOfDriverCategories) {
            if (-not $driverCats.Contains($dc)) {
                $allDriversOk = $false
                break
            }
        }
    }

    $registryOk = $true
    if ($detection.PSObject.Properties['requiresRegistryKey']) {
        $registryOk = $false
        if ($ScanResult.PSObject.Properties['RegistryAnalysis'] -and $ScanResult.RegistryAnalysis -and $ScanResult.RegistryAnalysis.system_hive_loaded) {
            $registryOk = $true
        }
    }

    $anySignals = @(@($anyFileHit, $anyToolHit, $anyRuntimeHit, $anyDriverHit, $anyPackageHit) | Where-Object { $_ })
    if ($detection.PSObject.Properties['anyOfFiles'] -or $detection.PSObject.Properties['anyOfTools'] -or $detection.PSObject.Properties['anyOfRuntimes'] -or $detection.PSObject.Properties['anyOfDriverCategories'] -or $detection.PSObject.Properties['anyOfPackages']) {
        return ($allOfFilesOk -and $allDriversOk -and $registryOk -and (@($anySignals).Count -gt 0))
    }

    return ($allOfFilesOk -and $allDriversOk -and $registryOk)
}

function Get-DanewFeatureStatus {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ScanResult,
        [Parameter(Mandatory = $true)]
        [object]$ProfileDefinition,
        [Parameter(Mandatory = $true)]
        [object]$CatalogContext
    )

    $status = @()
    foreach ($f in $CatalogContext.FeaturesCatalog.items) {
        if (@($f.required_profiles) -notcontains $ProfileDefinition.id) {
            continue
        }

        $present = Test-DanewFeaturePresence -Feature $f -ScanResult $ScanResult
        $status += [pscustomobject]@{
            id = $f.id
            name = $f.name
            domain = $f.domain
            score_weight = [int]$f.score_weight
            present = [bool]$present
        }
    }

    return $status
}

function Get-DanewCapabilityScore {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ScanResult,
        [Parameter(Mandatory = $true)]
        [object]$ProfileDefinition,
        [Parameter(Mandatory = $true)]
        [object]$CatalogContext
    )

    $featureStatus = Get-DanewFeatureStatus -ScanResult $ScanResult -ProfileDefinition $ProfileDefinition -CatalogContext $CatalogContext
    $domains = @('system_recovery', 'networking', 'disk_recovery', 'gui', 'crash_analysis')

    $domainScores = @{}
    foreach ($d in $domains) {
        $features = @($featureStatus | Where-Object { $_.domain -eq $d })
        $max = 0
        $current = 0
        foreach ($f in $features) {
            $w = [int]$f.score_weight
            $max += $w
            if ($f.present) {
                $current += $w
            }
        }

        $pct = if ($max -eq 0) { 0 } else { [math]::Round(($current / $max) * 100) }
        $domainScores[$d] = [math]::Min($pct, 100)
    }

    $weightsObj = $null
    if ($CatalogContext.ScoringWeights.profiles.PSObject.Properties[$ProfileDefinition.id]) {
        $weightsObj = $CatalogContext.ScoringWeights.profiles.PSObject.Properties[$ProfileDefinition.id].Value
    }
    $global = 0
    $weightTotal = 0

    foreach ($d in $domains) {
        $w = 20
        if ($weightsObj -and $weightsObj.domain_weights -and $weightsObj.domain_weights.PSObject.Properties[$d]) {
            $w = [double]$weightsObj.domain_weights.$d
        }
        $weightTotal += $w
        $global += ($domainScores[$d] * $w)
    }

    if ($weightTotal -gt 0) {
        $global = [math]::Round($global / $weightTotal)
    }

    return [pscustomobject]@{
        system_recovery = [int]$domainScores['system_recovery']
        networking = [int]$domainScores['networking']
        disk_recovery = [int]$domainScores['disk_recovery']
        gui = [int]$domainScores['gui']
        crash_analysis = [int]$domainScores['crash_analysis']
        global = [math]::Min([int]$global, 100)
        feature_status = $featureStatus
    }
}

function Get-DanewRecommendations {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ScanResult,
        [Parameter(Mandatory = $true)]
        [object]$ProfileDefinition,
        [Parameter(Mandatory = $true)]
        [object]$CatalogContext,
        [object]$FeatureStatus,
        [object]$SecurityValidation
    )

    $detected = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($t in $ScanResult.ToolsDetected) {
        [void]$detected.Add($t)
    }

    $recos = @()

    foreach ($tool in $ProfileDefinition.required_tools) {
        if (-not $detected.Contains($tool)) {
            $entry = $CatalogContext.ToolsCatalog.items | Where-Object { $_.name -eq $tool } | Select-Object -First 1
            $recos += [pscustomobject]@{
                feature = "Tool requirement: $tool"
                status = 'Missing'
                present = @()
                missing = @($tool)
                recommendation = "Add $tool to satisfy profile $($ProfileDefinition.id)"
                priority = 'critical'
                size_impact_mb = if ($entry) { $entry.size_mb } else { 0 }
                ram_impact_mb = 0
            }
        }
    }

    foreach ($tool in $ProfileDefinition.recommended_tools) {
        if (-not $detected.Contains($tool)) {
            $entry = $CatalogContext.ToolsCatalog.items | Where-Object { $_.name -eq $tool } | Select-Object -First 1
            $recos += [pscustomobject]@{
                feature = "Recommended tool: $tool"
                status = 'Partially Supported'
                present = @()
                missing = @($tool)
                recommendation = "Consider adding $tool for richer diagnostics"
                priority = if ($entry) { $entry.priority } else { 'recommended' }
                size_impact_mb = if ($entry) { $entry.size_mb } else { 0 }
                ram_impact_mb = if ($tool -eq 'EvtxECmd') { 120 } else { 40 }
            }
        }
    }

    if ($FeatureStatus) {
        foreach ($f in $FeatureStatus) {
            if (-not $f.present) {
                $recos += [pscustomobject]@{
                    feature = "Feature gap: $($f.name)"
                    status = 'Missing'
                    present = @()
                    missing = @($f.id)
                    recommendation = "Add components required for feature $($f.name)"
                    priority = if (@($ProfileDefinition.required_features) -contains $f.id) { 'critical' } else { 'recommended' }
                    size_impact_mb = 0
                    ram_impact_mb = 0
                }
            }
        }
    }

    foreach ($cat in $ScanResult.DriverAnalysis.categories_missing) {
        $recos += [pscustomobject]@{
            feature = "Driver category: $cat"
            status = 'Missing'
            present = @($ScanResult.DriverAnalysis.categories_present)
            missing = @($cat)
            recommendation = "Inject offline driver package for category $cat"
            priority = 'recommended'
            size_impact_mb = 30
            ram_impact_mb = 20
        }
    }

    if ($ScanResult.PSObject.Properties['PackageAnalysis'] -and $ScanResult.PackageAnalysis -and $ScanResult.PackageAnalysis.missing_required_packages) {
        foreach ($pkg in $ScanResult.PackageAnalysis.missing_required_packages) {
            $catalogEntry = $CatalogContext.WinPEPackagesCatalog.items | Where-Object { $_.id -eq $pkg } | Select-Object -First 1
            $recos += [pscustomobject]@{
                feature = "WinPE package: $pkg"
                status = 'Missing'
                present = @($ScanResult.PackageAnalysis.detected_packages)
                missing = @($pkg)
                recommendation = "Add optional package $pkg into offline image"
                priority = if ($catalogEntry) { $catalogEntry.priority } else { 'recommended' }
                size_impact_mb = if ($catalogEntry) { $catalogEntry.size_mb } else { 0 }
                ram_impact_mb = if ($catalogEntry) { $catalogEntry.ram_mb } else { 0 }
            }
        }
    }

    $incompat = @($ScanResult.PeValidation.details | Where-Object { -not $_.compatible -and $_.machine -ne 'unknown' })
    foreach ($inc in $incompat) {
        $recos += [pscustomobject]@{
            feature = "Binary compatibility: $($inc.tool)"
            status = 'Unsupported'
            present = @($inc.machine)
            missing = @($ScanResult.Architecture)
            recommendation = "Replace binary with architecture-compatible build for $($ScanResult.Architecture)"
            priority = 'critical'
            size_impact_mb = 0
            ram_impact_mb = 0
        }
    }

    if ($SecurityValidation -and $SecurityValidation.violations) {
        foreach ($v in $SecurityValidation.violations) {
            $recos += [pscustomobject]@{
                feature = "Security policy: $($v.tool)"
                status = 'Non Compliant'
                present = @($v.file)
                missing = @($v.type)
                recommendation = $v.message
                priority = if ($v.severity -eq 'critical') { 'critical' } else { 'recommended' }
                size_impact_mb = 0
                ram_impact_mb = 0
            }
        }
    }

    return $recos
}
