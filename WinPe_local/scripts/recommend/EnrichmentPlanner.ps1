function Get-DanewDriverEnrichmentActions {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ScanResult,
        [Parameter(Mandatory = $true)]
        [object]$CatalogContext
    )

    $actions = @()
    foreach ($missingCat in $ScanResult.DriverAnalysis.categories_missing) {
        $entry = $CatalogContext.DriverEnrichmentCatalog.items | Where-Object { $_.category_id -eq $missingCat } | Select-Object -First 1
        if (-not $entry) {
            continue
        }

        $actions += [pscustomobject]@{
            category_id = $missingCat
            package_name = $entry.package_name
            priority = $entry.priority
            size_mb = $entry.size_mb
            ram_mb = $entry.ram_mb
            vendor_preferences = $entry.vendor_preferences
            action = "Inject driver package $($entry.package_name)"
        }
    }

    return $actions
}

function Get-DanewToolEnrichmentActions {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ScanResult,
        [Parameter(Mandatory = $true)]
        [object]$ProfileDefinition,
        [Parameter(Mandatory = $true)]
        [object]$CatalogContext
    )

    $detected = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($t in $ScanResult.ToolsDetected) {
        [void]$detected.Add($t)
    }

    $targets = @($ProfileDefinition.required_tools + $ProfileDefinition.recommended_tools | Select-Object -Unique)
    $actions = @()

    foreach ($tool in $targets) {
        if ($detected.Contains($tool)) {
            continue
        }

        $entry = $CatalogContext.ToolEnrichmentCatalog.items | Where-Object { $_.name -eq $tool } | Select-Object -First 1
        if (-not $entry) {
            $entry = [pscustomobject]@{
                name = $tool
                reason = 'Profile tool gap'
                priority = if (@($ProfileDefinition.required_tools) -contains $tool) { 'critical' } else { 'recommended' }
                size_mb = 10
                ram_mb = 20
            }
        }

        $actions += [pscustomobject]@{
            tool = $tool
            reason = $entry.reason
            priority = $entry.priority
            size_mb = $entry.size_mb
            ram_mb = $entry.ram_mb
            action = "Add tool $tool"
        }
    }

    return $actions
}

function Get-DanewPackageEnrichmentActions {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ScanResult,
        [Parameter(Mandatory = $true)]
        [object]$CatalogContext
    )

    $actions = @()

    if (-not $ScanResult.PackageAnalysis -or -not $ScanResult.PackageAnalysis.missing_required_packages) {
        return $actions
    }

    foreach ($pkgId in $ScanResult.PackageAnalysis.missing_required_packages) {
        $entry = $CatalogContext.WinPEPackagesCatalog.items | Where-Object { $_.id -eq $pkgId } | Select-Object -First 1
        if (-not $entry) {
            continue
        }

        $actions += [pscustomobject]@{
            package_id = $entry.id
            package_name = $entry.name
            package_pattern = $entry.package_patterns[0]
            priority = $entry.priority
            size_mb = $entry.size_mb
            ram_mb = $entry.ram_mb
            action = "Add optional package $($entry.name)"
        }
    }

    return $actions
}

function New-DanewEnrichmentPlan {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ScanResult,
        [Parameter(Mandatory = $true)]
        [object]$ProfileDefinition,
        [Parameter(Mandatory = $true)]
        [object]$CatalogContext
    )

    $driverActions = Get-DanewDriverEnrichmentActions -ScanResult $ScanResult -CatalogContext $CatalogContext
    $toolActions = Get-DanewToolEnrichmentActions -ScanResult $ScanResult -ProfileDefinition $ProfileDefinition -CatalogContext $CatalogContext
    $packageActions = Get-DanewPackageEnrichmentActions -ScanResult $ScanResult -CatalogContext $CatalogContext

    $size = 0
    $ram = 0
    foreach ($a in $driverActions) { $size += [double]$a.size_mb; $ram += [double]$a.ram_mb }
    foreach ($a in $toolActions) { $size += [double]$a.size_mb; $ram += [double]$a.ram_mb }
    foreach ($a in $packageActions) { $size += [double]$a.size_mb; $ram += [double]$a.ram_mb }

    return [pscustomobject]@{
        plan_id = ([guid]::NewGuid().ToString())
        timestamp = (Get-Date).ToString('s')
        profile = $ProfileDefinition.id
        architecture = $ScanResult.Architecture
        driver_actions = $driverActions
        tool_actions = $toolActions
        package_actions = $packageActions
        estimated_size_mb = [math]::Round($size, 2)
        estimated_ram_mb = [math]::Round($ram, 2)
        summary = "Planned enrichment: +$([math]::Round($size,2)) MB, +$([math]::Round($ram,2)) MB RAM"
    }
}

function Get-DanewSimulatedScanForPlan {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ScanResult,
        [Parameter(Mandatory = $true)]
        [object]$EnrichmentPlan
    )

    $simTools = @($ScanResult.ToolsDetected)
    foreach ($toolAction in $EnrichmentPlan.tool_actions) {
        $simTools += $toolAction.tool
    }
    $simTools = @($simTools | Select-Object -Unique)

    $simDriverPresent = @($ScanResult.DriverAnalysis.categories_present)
    foreach ($driverAction in $EnrichmentPlan.driver_actions) {
        $simDriverPresent += $driverAction.category_id
    }
    $simDriverPresent = @($simDriverPresent | Select-Object -Unique)

    $simDriverMissing = @($ScanResult.DriverAnalysis.categories_missing | Where-Object { $simDriverPresent -notcontains $_ })

    $simPackages = @()
    if ($ScanResult.PackageAnalysis -and $ScanResult.PackageAnalysis.detected_packages) {
        $simPackages += $ScanResult.PackageAnalysis.detected_packages
    }
    foreach ($packageAction in $EnrichmentPlan.package_actions) {
        if ($packageAction.package_pattern) {
            $simPackages += $packageAction.package_pattern
        }
        else {
            $simPackages += $packageAction.package_name
        }
    }
    $simPackages = @($simPackages | Select-Object -Unique)

    return [pscustomobject]@{
        InputPath = $ScanResult.InputPath
        InputType = $ScanResult.InputType
        Architecture = $ScanResult.Architecture
        ArchitectureDetails = $ScanResult.ArchitectureDetails
        FilesScanned = $ScanResult.FilesScanned
        ToolsDetected = $simTools
        ToolMatches = $ScanResult.ToolMatches
        DriversDetected = $ScanResult.DriversDetected
        DriverAnalysis = [pscustomobject]@{
            inf_count = $ScanResult.DriverAnalysis.inf_count
            sys_count = $ScanResult.DriverAnalysis.sys_count
            classes_detected = $ScanResult.DriverAnalysis.classes_detected
            categories_present = $simDriverPresent
            categories_missing = $simDriverMissing
            evidence = $ScanResult.DriverAnalysis.evidence
            inf_metadata = $ScanResult.DriverAnalysis.inf_metadata
        }
        DriverVendorAnalysis = $ScanResult.DriverVendorAnalysis
        RegistryAnalysis = $ScanResult.RegistryAnalysis
        PackageAnalysis = [pscustomobject]@{
            source = $ScanResult.PackageAnalysis.source
            detected_packages = $simPackages
            package_count = @($simPackages).Count
            missing_required_packages = @()
            raw_count = $ScanResult.PackageAnalysis.raw_count
        }
        PeValidation = $ScanResult.PeValidation
        RuntimesDetected = $ScanResult.RuntimesDetected
    }
}

function Get-DanewScoreDeltaFromPlan {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ScanResult,
        [Parameter(Mandatory = $true)]
        [object]$BeforeScore,
        [Parameter(Mandatory = $true)]
        [object]$ProfileDefinition,
        [Parameter(Mandatory = $true)]
        [object]$CatalogContext,
        [Parameter(Mandatory = $true)]
        [object]$EnrichmentPlan
    )

    $simScan = Get-DanewSimulatedScanForPlan -ScanResult $ScanResult -EnrichmentPlan $EnrichmentPlan
    $afterScore = Get-DanewCapabilityScore -ScanResult $simScan -ProfileDefinition $ProfileDefinition -CatalogContext $CatalogContext

    $delta = [pscustomobject]@{
        system_recovery = ($afterScore.system_recovery - $BeforeScore.system_recovery)
        networking = ($afterScore.networking - $BeforeScore.networking)
        disk_recovery = ($afterScore.disk_recovery - $BeforeScore.disk_recovery)
        gui = ($afterScore.gui - $BeforeScore.gui)
        crash_analysis = ($afterScore.crash_analysis - $BeforeScore.crash_analysis)
        global = ($afterScore.global - $BeforeScore.global)
    }

    $beforeMissing = @($BeforeScore.feature_status | Where-Object { -not $_.present } | ForEach-Object { $_.id })
    $afterMissing = @($afterScore.feature_status | Where-Object { -not $_.present } | ForEach-Object { $_.id })
    $recovered = @($beforeMissing | Where-Object { $afterMissing -notcontains $_ } | Select-Object -Unique)

    return [pscustomobject]@{
        before = [pscustomobject]@{
            system_recovery = $BeforeScore.system_recovery
            networking = $BeforeScore.networking
            disk_recovery = $BeforeScore.disk_recovery
            gui = $BeforeScore.gui
            crash_analysis = $BeforeScore.crash_analysis
            global = $BeforeScore.global
        }
        after = [pscustomobject]@{
            system_recovery = $afterScore.system_recovery
            networking = $afterScore.networking
            disk_recovery = $afterScore.disk_recovery
            gui = $afterScore.gui
            crash_analysis = $afterScore.crash_analysis
            global = $afterScore.global
        }
        delta = $delta
        features_recovered = $recovered
    }
}
