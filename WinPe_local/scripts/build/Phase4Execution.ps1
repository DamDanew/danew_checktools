function Get-DanewJsonFromPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -Path $Path)) {
        throw "Missing JSON file: $Path"
    }

    return Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function New-DanewPhase4BuildId {
    return "build-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
}

function New-DanewBuildWorkspace {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath,
        [Parameter(Mandatory = $true)]
        [string]$BuildRoot,
        [Parameter(Mandatory = $true)]
        [object]$ComposerSettings,
        [ValidateSet('DryRun', 'Execute')]
        [string]$Mode
    )

    $actions = @()

    if ($Mode -eq 'Execute') {
        if (Test-Path -Path $BuildRoot) {
            Remove-Item -Path $BuildRoot -Recurse -Force
        }
        New-Item -Path $BuildRoot -ItemType Directory -Force | Out-Null
    }

    foreach ($item in $ComposerSettings.base_copy_items) {
        $src = Join-Path $InputPath $item
        $dst = Join-Path $BuildRoot $item

        if (Test-Path -Path $src) {
            if ($Mode -eq 'Execute') {
                Copy-Item -Path $src -Destination $dst -Recurse -Force
            }
            $actions += [pscustomobject]@{ type = 'base_copy'; source = $src; destination = $dst; status = 'copied' }
        }
        else {
            $actions += [pscustomobject]@{ type = 'base_copy'; source = $src; destination = $dst; status = 'missing_source' }
        }
    }

    $folders = @($ComposerSettings.folders.PSObject.Properties | ForEach-Object { $_.Value })
    foreach ($f in $folders) {
        $full = Join-Path $BuildRoot $f
        if ($Mode -eq 'Execute') {
            New-Item -Path $full -ItemType Directory -Force | Out-Null
        }
        $actions += [pscustomobject]@{ type = 'ensure_folder'; path = $full; status = 'ok' }
    }

    $startNet = Join-Path $BuildRoot 'Windows\System32\StartNet.cmd'
    $launch = Join-Path $BuildRoot 'scripts\LaunchDanewCheckTool.cmd'

    if ($Mode -eq 'Execute') {
        $startNetDir = Split-Path -Parent $startNet
        New-Item -Path $startNetDir -ItemType Directory -Force | Out-Null
        @(
            'wpeinit',
            'cmd /c X:\\scripts\\LaunchDanewCheckTool.cmd'
        ) | Set-Content -Path $startNet -Encoding ASCII

        @(
            '@echo off',
            'setlocal enabledelayedexpansion',
            'echo Danew CheckTool Build Entry',
            'set DANEW_PS=',
            'if exist X:\\Program Files\\PowerShell\\7\\pwsh.exe set DANEW_PS=X:\\Program Files\\PowerShell\\7\\pwsh.exe',
            'if not defined DANEW_PS if exist X:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe set DANEW_PS=X:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',
            'if not defined DANEW_PS (',
            '  where pwsh.exe >nul 2>nul',
            '  if not errorlevel 1 set DANEW_PS=pwsh.exe',
            ')',
            'if not defined DANEW_PS (',
            '  where powershell.exe >nul 2>nul',
            '  if not errorlevel 1 set DANEW_PS=powershell.exe',
            ')',
            'if not defined DANEW_PS (',
            '  echo [DANEW] PowerShell is not available in this WinPE image.',
            '  exit /b 127',
            ')',
            'set DANEW_ROOT=',
            'for %%L in (D E F G H I J K L M N O P Q R S T U V W Y Z) do (',
            '  if exist %%L:\\scripts\\launcher.ps1 set DANEW_ROOT=%%L:\\',
            ')',
            'if not defined DANEW_ROOT (',
            '  echo [DANEW] launcher.ps1 not found on USB partitions.',
            '  exit /b 1',
            ')',
            '"%DANEW_PS%" -NoLogo -ExecutionPolicy Bypass -File %DANEW_ROOT%scripts\\launcher.ps1 -RootPath %DANEW_ROOT% -FallbackToCli',
            'if errorlevel 1 "%DANEW_PS%" -NoLogo -ExecutionPolicy Bypass -File %DANEW_ROOT%scripts\\DanewCheckTool.CLI.ps1 -RootPath %DANEW_ROOT% -Command Interactive',
            'exit /b %errorlevel%'
        ) | Set-Content -Path $launch -Encoding ASCII
    }

    $actions += [pscustomobject]@{ type = 'startnet_prepare'; path = $startNet; status = if ($Mode -eq 'Execute') { 'written' } else { 'planned' } }
    $actions += [pscustomobject]@{ type = 'launch_prepare'; path = $launch; status = if ($Mode -eq 'Execute') { 'written' } else { 'planned' } }

    return $actions
}

function Resolve-DanewToolSourceFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AssetRootPath,
        [Parameter(Mandatory = $true)]
        [string]$ToolName
    )

    $candidateNames = @($ToolName)
    if ($ToolName -notmatch '\.') {
        $candidateNames += "$ToolName.exe"
        $candidateNames += "$ToolName.cmd"
        $candidateNames += "$ToolName.ps1"
    }

    $roots = @(
        (Join-Path $AssetRootPath 'tools'),
        (Join-Path $AssetRootPath 'scripts\TEST_TOOL'),
        $AssetRootPath
    )

    foreach ($r in $roots) {
        if (-not (Test-Path -Path $r)) { continue }
        foreach ($name in $candidateNames) {
            $hit = Get-ChildItem -Path $r -Recurse -File -Filter $name -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) {
                return $hit.FullName
            }
        }
    }

    return ''
}

function Stage-DanewToolsFromPlan {
    param(
        [Parameter(Mandatory = $true)]
        [object]$EnrichmentPlan,
        [Parameter(Mandatory = $true)]
        [string]$AssetRootPath,
        [Parameter(Mandatory = $true)]
        [string]$BuildRoot,
        [ValidateSet('DryRun', 'Execute')]
        [string]$Mode
    )

    $records = @()
    foreach ($tool in $EnrichmentPlan.tool_actions) {
        $src = Resolve-DanewToolSourceFile -AssetRootPath $AssetRootPath -ToolName $tool.tool
        $dstDir = Join-Path $BuildRoot ("tools\\" + $tool.tool)
        $dst = if ($src) { Join-Path $dstDir ([System.IO.Path]::GetFileName($src)) } else { '' }

        if ([string]::IsNullOrWhiteSpace($src)) {
            $records += [pscustomobject]@{ type = 'tool'; tool = $tool.tool; priority = $tool.priority; source = ''; destination = $dst; status = 'missing_source' }
            continue
        }

        if ($Mode -eq 'Execute') {
            New-Item -Path $dstDir -ItemType Directory -Force | Out-Null
            Copy-Item -Path $src -Destination $dst -Force
        }

        $records += [pscustomobject]@{ type = 'tool'; tool = $tool.tool; priority = $tool.priority; source = $src; destination = $dst; status = if ($Mode -eq 'Execute') { 'staged' } else { 'planned' } }
    }

    return $records
}

function Get-DanewInfArchitectures {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InfPath
    )

    if (-not (Test-Path -Path $InfPath)) {
        return @('unknown')
    }

    $content = Get-Content -Path $InfPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if (-not $content) {
        return @('unknown')
    }

    $archs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($content -match '(?i)\.NTx86') { [void]$archs.Add('x86') }
    if ($content -match '(?i)\.NTamd64') { [void]$archs.Add('x64') }
    if ($content -match '(?i)\.NTarm64') { [void]$archs.Add('arm64') }

    if (@($archs).Count -eq 0) {
        [void]$archs.Add('any')
    }

    return @($archs)
}

function Test-DanewDriverArchCompatibility {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$DriverArchitectures,
        [Parameter(Mandatory = $true)]
        [string]$TargetArchitecture
    )

    if (@($DriverArchitectures).Count -eq 0) { return $false }
    if ($DriverArchitectures -contains 'any') { return $true }
    return ($DriverArchitectures -contains $TargetArchitecture)
}

function Resolve-DanewDriverPackageSource {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AssetRootPath,
        [Parameter(Mandatory = $true)]
        [string]$PackageName,
        [Parameter(Mandatory = $true)]
        [string]$CategoryId
    )

    $candidates = @(
        (Join-Path $AssetRootPath ("drivers\\" + $PackageName)),
        (Join-Path $AssetRootPath ("drivers\\" + $CategoryId))
    )

    foreach ($c in $candidates) {
        if (Test-Path -Path $c) {
            if ((Get-ChildItem -Path $c -Recurse -File -Filter '*.inf' -ErrorAction SilentlyContinue | Select-Object -First 1)) {
                return $c
            }
        }
    }

    return ''
}

function Stage-DanewDriversFromPlan {
    param(
        [Parameter(Mandatory = $true)]
        [object]$EnrichmentPlan,
        [Parameter(Mandatory = $true)]
        [string]$AssetRootPath,
        [Parameter(Mandatory = $true)]
        [string]$BuildRoot,
        [Parameter(Mandatory = $true)]
        [string]$Architecture,
        [ValidateSet('DryRun', 'Execute')]
        [string]$Mode
    )

    $records = @()

    foreach ($driver in $EnrichmentPlan.driver_actions) {
        $srcDir = Resolve-DanewDriverPackageSource -AssetRootPath $AssetRootPath -PackageName $driver.package_name -CategoryId $driver.category_id
        $dstDir = Join-Path $BuildRoot ("drivers\\" + $driver.category_id)

        if ([string]::IsNullOrWhiteSpace($srcDir)) {
            $records += [pscustomobject]@{ type = 'driver'; category_id = $driver.category_id; source = ''; destination = $dstDir; status = 'missing_inf' }
            continue
        }

        $infFiles = @(Get-ChildItem -Path $srcDir -Recurse -File -Filter '*.inf' -ErrorAction SilentlyContinue)
        if (@($infFiles).Count -eq 0) {
            $records += [pscustomobject]@{ type = 'driver'; category_id = $driver.category_id; source = $srcDir; destination = $dstDir; status = 'missing_inf' }
            continue
        }

        $archMismatch = $false
        $archEvidence = @()
        foreach ($inf in $infFiles) {
            $archs = Get-DanewInfArchitectures -InfPath $inf.FullName
            $archEvidence += ($inf.Name + ':' + ($archs -join '|'))
            if (-not (Test-DanewDriverArchCompatibility -DriverArchitectures $archs -TargetArchitecture $Architecture)) {
                $archMismatch = $true
            }
        }

        if ($archMismatch) {
            $records += [pscustomobject]@{ type = 'driver'; category_id = $driver.category_id; source = $srcDir; destination = $dstDir; status = 'wrong_architecture'; arch_evidence = $archEvidence }
            continue
        }

        if ($Mode -eq 'Execute') {
            New-Item -Path $dstDir -ItemType Directory -Force | Out-Null
            Copy-Item -Path (Join-Path $srcDir '*') -Destination $dstDir -Recurse -Force
        }

        $records += [pscustomobject]@{ type = 'driver'; category_id = $driver.category_id; source = $srcDir; destination = $dstDir; inf_count = @($infFiles).Count; status = if ($Mode -eq 'Execute') { 'staged' } else { 'planned' }; arch_evidence = $archEvidence }
    }

    return $records
}

function Resolve-DanewPackageSourceFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AssetRootPath,
        [Parameter(Mandatory = $true)]
        [string]$PackageName,
        [string]$PackagePattern
    )

    $roots = @(
        (Join-Path $AssetRootPath ("packages\\" + $PackageName)),
        (Join-Path $AssetRootPath ("packages\\" + $PackagePattern)),
        (Join-Path $AssetRootPath 'packages')
    )

    foreach ($r in $roots) {
        if (-not (Test-Path -Path $r)) { continue }
        $files = @(Get-ChildItem -Path $r -Recurse -File -Include *.cab,*.msu -ErrorAction SilentlyContinue)
        if (@($files).Count -gt 0) {
            return $files
        }
    }

    return @()
}

function Get-DanewOrderedPackageActions {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$PackageActions,
        [Parameter(Mandatory = $true)]
        [object]$CatalogContext
    )

    $order = @($CatalogContext.PackageDependencyOrder.order)
    $rank = @{}
    $i = 0
    foreach ($id in $order) {
        $rank[$id] = $i
        $i += 1
    }

    return @($PackageActions | Sort-Object {
            if ($rank.ContainsKey($_.package_id)) { $rank[$_.package_id] } else { 9999 }
        }, package_id)
}

function Stage-DanewPackagesFromPlan {
    param(
        [Parameter(Mandatory = $true)]
        [object]$EnrichmentPlan,
        [Parameter(Mandatory = $true)]
        [string]$AssetRootPath,
        [Parameter(Mandatory = $true)]
        [string]$BuildRoot,
        [Parameter(Mandatory = $true)]
        [object]$CatalogContext,
        [ValidateSet('DryRun', 'Execute')]
        [string]$Mode
    )

    $ordered = Get-DanewOrderedPackageActions -PackageActions @($EnrichmentPlan.package_actions) -CatalogContext $CatalogContext
    $records = @()

    foreach ($pkg in $ordered) {
        $srcFiles = Resolve-DanewPackageSourceFiles -AssetRootPath $AssetRootPath -PackageName $pkg.package_name -PackagePattern $pkg.package_pattern
        $dstDir = Join-Path $BuildRoot ("packages\\" + $pkg.package_id)

        if (@($srcFiles).Count -eq 0) {
            $records += [pscustomobject]@{ type = 'package'; package_id = $pkg.package_id; destination = $dstDir; status = 'missing_package_files' }
            continue
        }

        $stagedFiles = @()
        if ($Mode -eq 'Execute') {
            New-Item -Path $dstDir -ItemType Directory -Force | Out-Null
            foreach ($file in $srcFiles) {
                $target = Join-Path $dstDir $file.Name
                Copy-Item -Path $file.FullName -Destination $target -Force
                $stagedFiles += $target
            }
        }
        if ($Mode -eq 'DryRun') {
            foreach ($file in $srcFiles) {
                $stagedFiles += (Join-Path $dstDir $file.Name)
            }
        }

        $records += [pscustomobject]@{ type = 'package'; package_id = $pkg.package_id; package_name = $pkg.package_name; destination = $dstDir; files = $stagedFiles; status = if ($Mode -eq 'Execute') { 'staged' } else { 'planned' } }
    }

    return $records
}

function New-DanewCommandPlan {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [object[]]$DriverRecords = @(),
        [object[]]$PackageRecords = @()
    )

    $lines = @(
        '$MountedImagePath = "<MountedImagePath>"',
        'Write-Host "Danew command plan"',
        ''
    )

    foreach ($d in $DriverRecords) {
        if ($d.status -in @('staged', 'planned')) {
            $driverPath = $d.destination -replace '\\', '\\\\'
            $lines += ('dism.exe /English /Image:$MountedImagePath /Add-Driver /Driver:"{0}" /Recurse' -f $driverPath)
        }
    }

    foreach ($p in $PackageRecords) {
        if ($p.status -in @('staged', 'planned')) {
            foreach ($f in $p.files) {
                $packagePath = $f -replace '\\', '\\\\'
                $lines += ('dism.exe /English /Image:$MountedImagePath /Add-Package /PackagePath:"{0}"' -f $packagePath)
            }
        }
    }

    $lines | Set-Content -Path $Path -Encoding UTF8
}

function Invoke-DanewSecurityGateForBuild {
    param(
        [object[]]$ToolRecords = @(),
        [Parameter(Mandatory = $true)]
        [object]$CatalogContext
    )

    $violations = @()
    $checked = 0
    $blocked = 0

    foreach ($rec in $ToolRecords) {
        if ($rec.status -notin @('staged', 'planned')) { continue }
        if ([string]::IsNullOrWhiteSpace($rec.destination) -or -not (Test-Path -Path $rec.destination)) {
            continue
        }

        $checked += 1
        $entry = $CatalogContext.ToolsCatalog.items | Where-Object { $_.name -eq $rec.tool } | Select-Object -First 1
        $isCritical = $false
        if ($entry -and $entry.priority -eq 'critical') { $isCritical = $true }
        if ($rec.priority -eq 'critical') { $isCritical = $true }

        $sigOk = Test-DanewSignature -FilePath $rec.destination
        $hashOk = $true
        if ($entry -and -not [string]::IsNullOrWhiteSpace($entry.download_url)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$entry.sha256)) {
                $hashOk = Test-DanewSha256 -FilePath $rec.destination -ExpectedSha256 $entry.sha256
            }
            else {
                $hashOk = $false
            }
        }
        $vendor = if ($entry) { [string]$entry.vendor } else { '' }
        $signerVendor = Get-DanewSignerVendor -FilePath $rec.destination
        if (-not [string]::IsNullOrWhiteSpace($signerVendor)) {
            $vendor = $signerVendor
        }
        $vendorOk = Test-DanewVendorTrust -Vendor $vendor -SecurityPolicy $CatalogContext.SecurityPolicy

        if ($isCritical -and (-not $sigOk -or -not $hashOk -or -not $vendorOk)) {
            $blocked += 1
            $violations += [pscustomobject]@{
                tool = $rec.tool
                file = $rec.destination
                signature_ok = $sigOk
                sha256_ok = $hashOk
                vendor_ok = $vendorOk
                severity = 'critical'
                message = 'Critical tool blocked by security gate'
            }
        }
    }

    return [pscustomobject]@{
        approved = ($blocked -eq 0)
        checked = $checked
        blocked = $blocked
        violations = $violations
    }
}

function Test-DanewUsbExportValidation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BuildRoot,
        [Parameter(Mandatory = $true)]
        [object]$ComposerSettings,
        [Parameter(Mandatory = $true)]
        [object]$EnrichmentPlan,
        [object[]]$DriverRecords = @()
    )

    $required = @()
    foreach ($rel in $ComposerSettings.required_usb_paths) {
        $full = Join-Path $BuildRoot $rel
        $required += [pscustomobject]@{ path = $rel; exists = (Test-Path -Path $full) }
    }

    $arch = [string]$EnrichmentPlan.architecture
    if ($ComposerSettings.required_efi_by_arch.PSObject.Properties[$arch]) {
        foreach ($efiRel in $ComposerSettings.required_efi_by_arch.PSObject.Properties[$arch].Value) {
            $efiFull = Join-Path $BuildRoot $efiRel
            $required += [pscustomobject]@{ path = $efiRel; exists = (Test-Path -Path $efiFull) }
        }
    }

    $wrongArch = @($DriverRecords | Where-Object { $_.status -eq 'wrong_architecture' }).Count
    $archConsistency = ($wrongArch -eq 0)

    $sizeBytes = 0
    if (Test-Path -Path $BuildRoot) {
        $sizeBytes = (Get-ChildItem -Path $BuildRoot -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        if (-not $sizeBytes) { $sizeBytes = 0 }
    }

    $ready = (@($required | Where-Object { -not $_.exists }).Count -eq 0) -and $archConsistency

    return [pscustomobject]@{
        ready_for_export = $ready
        required_paths = $required
        architecture_consistency = $archConsistency
        estimated_size_mb = [math]::Round($EnrichmentPlan.estimated_size_mb, 2)
        estimated_ram_mb = [math]::Round($EnrichmentPlan.estimated_ram_mb, 2)
        actual_build_size_mb = [math]::Round(($sizeBytes / 1MB), 2)
        wrong_architecture_driver_count = $wrongArch
    }
}

function Export-DanewBuildSummaryHtml {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [object]$BuildManifest,
        [Parameter(Mandatory = $true)]
        [object]$SecurityReport,
        [Parameter(Mandatory = $true)]
        [object]$UsbValidation
    )

    $html = @"
<html>
<head><title>Resume de build Danew</title></head>
<body>
<h1>Resume de build Danew</h1>
<p><b>ID build :</b> $($BuildManifest.build_id)</p>
<p><b>Mode :</b> $($BuildManifest.mode)</p>
<p><b>Profil :</b> $($BuildManifest.profile)</p>
<p><b>Architecture :</b> $($BuildManifest.architecture)</p>
<p><b>Validation securite approuvee :</b> $(Get-DanewLocalizedBooleanText $SecurityReport.approved)</p>
<p><b>Export USB pret :</b> $(Get-DanewLocalizedBooleanText $UsbValidation.ready_for_export)</p>
<h2>Compteurs d actions</h2>
<ul>
<li>Actions totales : $(@($BuildManifest.actions).Count)</li>
<li>Violations de securite : $(@($SecurityReport.violations).Count)</li>
<li>Chemins USB requis manquants : $(@($UsbValidation.required_paths | Where-Object { -not $_.exists }).Count)</li>
</ul>
</body>
</html>
"@

    $html | Set-Content -Path $Path -Encoding UTF8
}

function Invoke-DanewPhase4Execution {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [Parameter(Mandatory = $true)]
        [string]$InputPath,
        [Parameter(Mandatory = $true)]
        [string]$EnrichmentPlanPath,
        [ValidateSet('DryRun', 'Execute')]
        [string]$Mode = 'DryRun',
        [string]$AssetRootPath,
        [string]$BuildId
    )

    if (-not $AssetRootPath) {
        $AssetRootPath = $RootPath
    }
    if (-not $BuildId) {
        $BuildId = New-DanewPhase4BuildId
    }

    $catalog = Get-DanewCatalogContext -RootPath $RootPath
    $enrichmentPlan = Get-DanewJsonFromPath -Path $EnrichmentPlanPath

    $buildRoot = Join-Path $RootPath ("builds\\" + $BuildId)
    $reportsRoot = Join-Path $RootPath 'reports'

    if (-not (Test-Path -Path $reportsRoot)) {
        New-Item -Path $reportsRoot -ItemType Directory -Force | Out-Null
    }

    $composerActions = New-DanewBuildWorkspace -InputPath $InputPath -BuildRoot $buildRoot -ComposerSettings $catalog.BuildComposerSettings -Mode $Mode
    $toolRecords = Stage-DanewToolsFromPlan -EnrichmentPlan $enrichmentPlan -AssetRootPath $AssetRootPath -BuildRoot $buildRoot -Mode $Mode
    $driverRecords = Stage-DanewDriversFromPlan -EnrichmentPlan $enrichmentPlan -AssetRootPath $AssetRootPath -BuildRoot $buildRoot -Architecture $enrichmentPlan.architecture -Mode $Mode
    $packageRecords = Stage-DanewPackagesFromPlan -EnrichmentPlan $enrichmentPlan -AssetRootPath $AssetRootPath -BuildRoot $buildRoot -CatalogContext $catalog -Mode $Mode

    $securityReport = Invoke-DanewSecurityGateForBuild -ToolRecords @($toolRecords) -CatalogContext $catalog
    $usbValidation = Test-DanewUsbExportValidation -BuildRoot $buildRoot -ComposerSettings $catalog.BuildComposerSettings -EnrichmentPlan $enrichmentPlan -DriverRecords @($driverRecords)

    $commandPlanPath = Join-Path $reportsRoot 'command-plan.ps1'
    if ($Mode -eq 'Execute') {
        New-DanewCommandPlan -Path $commandPlanPath -DriverRecords @($driverRecords) -PackageRecords @($packageRecords)
    }
    else {
        New-DanewCommandPlan -Path $commandPlanPath -DriverRecords @($driverRecords) -PackageRecords @($packageRecords)
    }

    $allActions = @($composerActions + $toolRecords + $driverRecords + $packageRecords)

    $buildManifest = [pscustomobject]@{
        build_id = $BuildId
        timestamp = (Get-Date).ToString('s')
        mode = $Mode
        profile = $enrichmentPlan.profile
        architecture = $enrichmentPlan.architecture
        build_root = $buildRoot
        input_path = $InputPath
        enrichment_plan_path = $EnrichmentPlanPath
        security_gate_passed = [bool]$securityReport.approved
        usb_export_ready = [bool]$usbValidation.ready_for_export
        actions = $allActions
    }

    $rollback = [pscustomobject]@{
        build_id = $BuildId
        timestamp = (Get-Date).ToString('s')
        rollback_actions = @(
            [pscustomobject]@{ type = 'remove_path'; path = $buildRoot; reason = 'remove composed build root' }
        )
    }

    $buildManifestPath = Join-Path $reportsRoot 'build-manifest.json'
    $rollbackPath = Join-Path $reportsRoot 'rollback-manifest.json'
    $securityPath = Join-Path $reportsRoot 'security-approval-report.json'
    $usbPath = Join-Path $reportsRoot 'usb-export-validation.json'
    $summaryPath = Join-Path $reportsRoot 'build-summary.html'

    $buildManifest | ConvertTo-Json -Depth 40 | Set-Content -Path $buildManifestPath -Encoding UTF8
    $rollback | ConvertTo-Json -Depth 20 | Set-Content -Path $rollbackPath -Encoding UTF8
    $securityReport | ConvertTo-Json -Depth 20 | Set-Content -Path $securityPath -Encoding UTF8
    $usbValidation | ConvertTo-Json -Depth 20 | Set-Content -Path $usbPath -Encoding UTF8
    Export-DanewBuildSummaryHtml -Path $summaryPath -BuildManifest $buildManifest -SecurityReport $securityReport -UsbValidation $usbValidation

    return [pscustomobject]@{
        build_manifest = $buildManifestPath
        rollback_manifest = $rollbackPath
        command_plan = $commandPlanPath
        security_approval_report = $securityPath
        usb_export_validation = $usbPath
        build_summary_html = $summaryPath
        build_root = $buildRoot
        security_gate_passed = [bool]$securityReport.approved
        usb_export_ready = [bool]$usbValidation.ready_for_export
    }
}
