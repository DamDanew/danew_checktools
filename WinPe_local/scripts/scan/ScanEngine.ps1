function Get-DanewInputType {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath,
        [string]$BootWimPath
    )

    if ($BootWimPath -and (Test-Path -Path $BootWimPath)) {
        return 'mounted_wim'
    }

    if ((Test-Path -Path (Join-Path $InputPath 'sources\boot.wim')) -or (Test-Path -Path (Join-Path $InputPath 'Boot\BCD'))) {
        return 'usb_mirror'
    }

    return 'workdir'
}

function Get-DanewPEMachine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    if (-not (Test-Path -Path $FilePath)) {
        return 'unknown'
    }

    try {
        $bytes = [System.IO.File]::ReadAllBytes($FilePath)
        if ($bytes.Length -lt 0x40) {
            return 'unknown'
        }

        $peOffset = [System.BitConverter]::ToInt32($bytes, 0x3C)
        if ($peOffset -lt 0 -or ($peOffset + 6) -gt $bytes.Length) {
            return 'unknown'
        }

        $machine = [System.BitConverter]::ToUInt16($bytes, $peOffset + 4)
        $machineHex = ('0x{0:X4}' -f $machine)

        switch ($machineHex) {
            '0x014C' { return 'x86' }
            '0x8664' { return 'x64' }
            '0xAA64' { return 'arm64' }
            default { return 'unknown' }
        }
    }
    catch {
        return 'unknown'
    }
}

function Get-DanewWimArchitectureMetadata {
    param(
        [string]$BootWimPath,
        [int]$ImageIndex = 1
    )

    if ([string]::IsNullOrWhiteSpace($BootWimPath) -or -not (Test-Path -Path $BootWimPath)) {
        return $null
    }

    try {
        $result = & dism.exe /English /Get-WimInfo /WimFile:$BootWimPath /Index:$ImageIndex 2>$null
        if (-not $result) {
            return $null
        }

        $archLine = $result | Where-Object { $_ -match '^Architecture\s*:\s*' } | Select-Object -First 1
        $nameLine = $result | Where-Object { $_ -match '^Name\s*:\s*' } | Select-Object -First 1

        $arch = 'unknown'
        if ($archLine -match ':\s*(.+)$') {
            $raw = $Matches[1].Trim().ToLowerInvariant()
            if ($raw -match 'amd64|x64') { $arch = 'x64' }
            elseif ($raw -match 'x86') { $arch = 'x86' }
            elseif ($raw -match 'arm64') { $arch = 'arm64' }
        }

        return [pscustomobject]@{
            source = 'dism_wim_info'
            architecture = $arch
            image_name = if ($nameLine -match ':\s*(.+)$') { $Matches[1].Trim() } else { '' }
        }
    }
    catch {
        return $null
    }
}

function Get-DanewOfflineRegistryMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath
    )

    $systemHive = Join-Path $InputPath 'Windows\System32\config\SYSTEM'
    if (-not (Test-Path -Path $systemHive)) {
        return $null
    }

    $mountName = "HKLM\DANEW_SYS_" + ([guid]::NewGuid().ToString('N'))
    $loaded = $false

    try {
        & reg.exe load $mountName $systemHive *> $null
        if ($LASTEXITCODE -ne 0) {
            return $null
        }
        $loaded = $true

        $query = & reg.exe query "$mountName\ControlSet001\Control\Session Manager\Environment" /v PROCESSOR_ARCHITECTURE 2>$null
        $value = ''
        if ($query) {
            $line = $query | Where-Object { $_ -match 'PROCESSOR_ARCHITECTURE' } | Select-Object -First 1
            if ($line) {
                $value = ($line -replace '^.*PROCESSOR_ARCHITECTURE\s+REG_\w+\s+', '').Trim()
            }
        }

        $arch = 'unknown'
        if ($value -match 'AMD64|x64') { $arch = 'x64' }
        elseif ($value -match '^x86$') { $arch = 'x86' }
        elseif ($value -match 'ARM64') { $arch = 'arm64' }

        return [pscustomobject]@{
            source = 'offline_registry'
            processor_architecture = $value
            architecture = $arch
        }
    }
    catch {
        return $null
    }
    finally {
        if ($loaded) {
            & reg.exe unload $mountName *> $null
        }
    }
}

function Get-DanewArchitecture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath,
        [object]$CatalogContext,
        [string]$BootWimPath,
        [int]$ImageIndex = 1
    )

    $evidence = @()
    $detected = 'unknown'

    $wimMeta = Get-DanewWimArchitectureMetadata -BootWimPath $BootWimPath -ImageIndex $ImageIndex
    if ($wimMeta -and $wimMeta.architecture -ne 'unknown') {
        $detected = $wimMeta.architecture
        $evidence += "dism_wim_info:$($wimMeta.architecture)"
    }

    $kernelPath = Join-Path $InputPath 'Windows\System32\ntoskrnl.exe'
    $kernelMachine = Get-DanewPEMachine -FilePath $kernelPath
    if ($kernelMachine -ne 'unknown') {
        if ($detected -eq 'unknown') {
            $detected = $kernelMachine
        }
        $evidence += "kernel_pe_machine:$kernelMachine"
    }

    $efiArm = Join-Path $InputPath 'EFI\Boot\bootaa64.efi'
    $efiX64 = Join-Path $InputPath 'EFI\Boot\bootx64.efi'
    $efiX86 = Join-Path $InputPath 'EFI\Boot\bootia32.efi'

    if (Test-Path -Path $efiArm) {
        if ($detected -eq 'unknown') { $detected = 'arm64' }
        $evidence += 'efi_bootloader:arm64'
    }
    elseif (Test-Path -Path $efiX64) {
        if ($detected -eq 'unknown') { $detected = 'x64' }
        $evidence += 'efi_bootloader:x64'
    }
    elseif (Test-Path -Path $efiX86) {
        if ($detected -eq 'unknown') { $detected = 'x86' }
        $evidence += 'efi_bootloader:x86'
    }

    if (Test-Path -Path (Join-Path $InputPath 'Windows\SysWOW64')) {
        if ($detected -eq 'unknown') { $detected = 'x64' }
        $evidence += 'syswow64_presence:x64'
    }

    $regMeta = Get-DanewOfflineRegistryMetadata -InputPath $InputPath
    if ($regMeta -and $regMeta.architecture -ne 'unknown') {
        if ($detected -eq 'unknown') {
            $detected = $regMeta.architecture
        }
        $evidence += "offline_registry:$($regMeta.architecture)"
    }

    return [pscustomobject]@{
        detected = $detected
        evidence = $evidence
        wim_metadata = $wimMeta
        registry_metadata = $regMeta
    }
}

function Get-DanewSearchNames {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Names
    )

    $all = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($n in $Names) {
        if ([string]::IsNullOrWhiteSpace($n)) { continue }
        [void]$all.Add($n)
        if ($n -notmatch '\.') {
            [void]$all.Add("$n.exe")
        }
    }
    return @($all)
}

function Find-DanewToolFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath,
        [Parameter(Mandatory = $true)]
        [string[]]$FileNames
    )

    $results = @()
    foreach ($fileName in $FileNames) {
        try {
            $hits = Get-ChildItem -Path $InputPath -Recurse -File -Filter $fileName -ErrorAction SilentlyContinue
            foreach ($h in $hits) {
                $results += [pscustomobject]@{
                    name = $fileName
                    leaf = $h.Name
                    full_path = $h.FullName
                }
            }
        }
        catch {
            continue
        }
    }
    return $results
}

function Get-DanewInfMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InfPath
    )

    try {
        $content = Get-Content -Path $InfPath -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        return $null
    }

    $class = ''
    $provider = ''
    $manufacturer = ''
    $classGuid = ''
    $driverVer = ''

    foreach ($line in $content) {
        if (-not $class -and $line -match '^\s*Class\s*=\s*(.+)\s*$') { $class = $Matches[1].Trim() }
        if (-not $provider -and $line -match '^\s*Provider\s*=\s*(.+)\s*$') { $provider = $Matches[1].Trim().Trim('"') }
        if (-not $manufacturer -and $line -match '^\s*Manufacturer\s*=\s*(.+)\s*$') { $manufacturer = $Matches[1].Trim().Trim('"') }
        if (-not $classGuid -and $line -match '^\s*ClassGuid\s*=\s*(.+)\s*$') { $classGuid = $Matches[1].Trim() }
        if (-not $driverVer -and $line -match '^\s*DriverVer\s*=\s*(.+)\s*$') { $driverVer = $Matches[1].Trim() }
    }

    return [pscustomobject]@{
        inf_path = $InfPath
        inf_name = [System.IO.Path]::GetFileName($InfPath)
        class = $class
        provider = $provider
        manufacturer = $manufacturer
        class_guid = $classGuid
        driver_ver = $driverVer
    }
}

function Test-DanewWildcardMatch {
    param(
        [string]$Value,
        [string[]]$Patterns
    )

    if ([string]::IsNullOrWhiteSpace($Value) -or -not $Patterns) {
        return $false
    }

    foreach ($p in $Patterns) {
        if ($Value -like $p) {
            return $true
        }
    }
    return $false
}

function Get-DanewRegQueryValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$KeyPath,
        [Parameter(Mandatory = $true)]
        [string]$ValueName
    )

    try {
        $query = & reg.exe query $KeyPath /v $ValueName 2>$null
        if (-not $query) {
            return ''
        }

        $line = $query | Where-Object { $_ -match ("^\s*" + [regex]::Escape($ValueName) + "\s+") } | Select-Object -First 1
        if (-not $line) {
            return ''
        }

        return ($line -replace ('^\s*' + [regex]::Escape($ValueName) + '\s+REG_\w+\s+'), '').Trim()
    }
    catch {
        return ''
    }
}

function Get-DanewOfflineRegistryAnalysis {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath
    )

    $systemHive = Join-Path $InputPath 'Windows\System32\config\SYSTEM'
    $softwareHive = Join-Path $InputPath 'Windows\System32\config\SOFTWARE'

    $mountSystem = "HKLM\DANEW_SYS_" + ([guid]::NewGuid().ToString('N'))
    $mountSoftware = "HKLM\DANEW_SOFT_" + ([guid]::NewGuid().ToString('N'))

    $sysLoaded = $false
    $softLoaded = $false

    $serviceKeys = @('stornvme', 'iaStorA', 'iaStorV', 'e1dexpress', 'rt640x64', 'netwtw10', 'rtwlane', 'usbxhci', 'amdw3xhc')
    $servicePresence = @{}
    foreach ($s in $serviceKeys) { $servicePresence[$s] = $false }

    try {
        if (Test-Path -Path $systemHive) {
            & reg.exe load $mountSystem $systemHive *> $null
            if ($LASTEXITCODE -eq 0) { $sysLoaded = $true }
        }

        if (Test-Path -Path $softwareHive) {
            & reg.exe load $mountSoftware $softwareHive *> $null
            if ($LASTEXITCODE -eq 0) { $softLoaded = $true }
        }

        $currentControlSet = '001'
        if ($sysLoaded) {
            $current = Get-DanewRegQueryValue -KeyPath "$mountSystem\Select" -ValueName 'Current'
            if ($current -match '^\d+$') {
                $currentControlSet = ('{0:D3}' -f [int]$current)
            }
        }

        $computerName = ''
        $archHint = ''
        $hostName = ''
        if ($sysLoaded) {
            $computerName = Get-DanewRegQueryValue -KeyPath "$mountSystem\ControlSet$currentControlSet\Control\ComputerName\ComputerName" -ValueName 'ComputerName'
            $archHint = Get-DanewRegQueryValue -KeyPath "$mountSystem\ControlSet$currentControlSet\Control\Session Manager\Environment" -ValueName 'PROCESSOR_ARCHITECTURE'
            $hostName = Get-DanewRegQueryValue -KeyPath "$mountSystem\ControlSet$currentControlSet\Services\Tcpip\Parameters" -ValueName 'Hostname'

            foreach ($svc in $serviceKeys) {
                $svcKey = "$mountSystem\ControlSet$currentControlSet\Services\$svc"
                & reg.exe query $svcKey *> $null
                if ($LASTEXITCODE -eq 0) {
                    $servicePresence[$svc] = $true
                }
            }
        }

        $productName = ''
        $currentBuild = ''
        $releaseId = ''
        $psVersion = ''
        if ($softLoaded) {
            $cvKey = "$mountSoftware\Microsoft\Windows NT\CurrentVersion"
            $productName = Get-DanewRegQueryValue -KeyPath $cvKey -ValueName 'ProductName'
            $currentBuild = Get-DanewRegQueryValue -KeyPath $cvKey -ValueName 'CurrentBuild'
            $releaseId = Get-DanewRegQueryValue -KeyPath $cvKey -ValueName 'ReleaseId'

            $psVersion = Get-DanewRegQueryValue -KeyPath "$mountSoftware\Microsoft\PowerShell\3\PowerShellEngine" -ValueName 'PowerShellVersion'
        }

        return [pscustomobject]@{
            system_hive_found = (Test-Path -Path $systemHive)
            software_hive_found = (Test-Path -Path $softwareHive)
            system_hive_loaded = $sysLoaded
            software_hive_loaded = $softLoaded
            current_control_set = $currentControlSet
            computer_name = $computerName
            product_name = $productName
            current_build = $currentBuild
            release_id = $releaseId
            architecture_hint = $archHint
            powershell_version = $psVersion
            service_presence = $servicePresence
            network_registry = [pscustomobject]@{
                hostname = $hostName
            }
        }
    }
    finally {
        if ($softLoaded) {
            & reg.exe unload $mountSoftware *> $null
        }
        if ($sysLoaded) {
            & reg.exe unload $mountSystem *> $null
        }
    }
}

function Get-DanewPackageAnalysis {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath,
        [string]$BootWimPath,
        [int]$ImageIndex = 1,
        [Parameter(Mandatory = $true)]
        [object]$CatalogContext,
        [Parameter(Mandatory = $true)]
        [string]$ProfileId
    )

    $source = 'none'
    $detected = @()
    $packages = @()

    try {
        if (Test-Path -Path (Join-Path $InputPath 'Windows')) {
            $pkgItems = @(Get-WindowsPackage -Path $InputPath -ErrorAction Stop)
            foreach ($item in $pkgItems) {
                $packages += [pscustomobject]@{ identity = [string]$item.PackageName; state = [string]$item.PackageState }
            }
            $source = 'dism_image'
        }
        elseif ($BootWimPath -and (Test-Path -Path $BootWimPath)) {
            $mountPath = Join-Path ([System.IO.Path]::GetTempPath()) ('danew-wim-pkg-' + [guid]::NewGuid().ToString('N'))
            New-Item -Path $mountPath -ItemType Directory -Force | Out-Null
            try {
                Mount-WindowsImage -ImagePath $BootWimPath -Index $ImageIndex -Path $mountPath -ReadOnly | Out-Null
                $pkgItems = @(Get-WindowsPackage -Path $mountPath -ErrorAction Stop)
                foreach ($item in $pkgItems) {
                    $packages += [pscustomobject]@{ identity = [string]$item.PackageName; state = [string]$item.PackageState }
                }
                $source = 'mounted_wim'
            }
            finally {
                $mountedImage = @(Get-WindowsImage -Mounted | Where-Object { $_.Path -eq $mountPath })
                if (@($mountedImage).Count -gt 0) {
                    Dismount-WindowsImage -Path $mountPath -Discard | Out-Null
                }
                if (Test-Path -Path $mountPath) {
                    Remove-Item -Path $mountPath -Recurse -Force
                }
            }
        }
    }
    catch {
        $packages = @()
    }

    foreach ($p in $packages) {
        if ($p.state -match 'Installed') {
            $detected += $p.identity
        }
    }

    $requiredPackageIds = @($CatalogContext.WinPEPackagesCatalog.items | Where-Object { @($_.required_profiles) -contains $ProfileId })
    $missingRequired = @()

    foreach ($req in $requiredPackageIds) {
        $hit = $false
        foreach ($pattern in $req.package_patterns) {
            foreach ($pkg in $detected) {
                if ($pkg -match [regex]::Escape($pattern)) {
                    $hit = $true
                    break
                }
            }
            if ($hit) { break }
        }

        if (-not $hit) {
            $missingRequired += $req.id
        }
    }

    return [pscustomobject]@{
        source = $source
        detected_packages = @($detected | Select-Object -Unique | Sort-Object)
        package_count = @($detected | Select-Object -Unique).Count
        missing_required_packages = @($missingRequired | Sort-Object)
        raw_count = @($packages).Count
    }
}

function Get-DanewNormalizedVendor {
    param(
        [string]$Provider,
        [string]$Manufacturer,
        [Parameter(Mandatory = $true)]
        [object]$CatalogContext
    )

    $source = ''
    if (-not [string]::IsNullOrWhiteSpace($Provider)) {
        $source = $Provider
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Manufacturer)) {
        $source = $Manufacturer
    }

    if ([string]::IsNullOrWhiteSpace($source)) {
        return 'Unknown'
    }

    $normalized = $source.ToLowerInvariant()
    foreach ($rule in $CatalogContext.VendorNormalizationMap.rules) {
        foreach ($pattern in $rule.patterns) {
            if ($normalized.Contains($pattern.ToLowerInvariant())) {
                return $rule.canonical
            }
        }
    }

    return 'Unknown'
}

function Get-DanewDriverVendorAnalysis {
    param(
        [Parameter(Mandatory = $false)]
        [object[]]$InfMetadata,
        [Parameter(Mandatory = $true)]
        [object]$CatalogContext
    )

    if (-not $InfMetadata) {
        $InfMetadata = @()
    }

    $vendorCounts = @{}
    foreach ($tv in $CatalogContext.VendorNormalizationMap.target_vendors) {
        $vendorCounts[$tv] = 0
    }
    $vendorCounts['Unknown'] = 0

    $unknownVendors = @()
    $samples = @()

    foreach ($inf in $InfMetadata) {
        $normalized = Get-DanewNormalizedVendor -Provider $inf.provider -Manufacturer $inf.manufacturer -CatalogContext $CatalogContext
        if (-not $vendorCounts.ContainsKey($normalized)) {
            $vendorCounts[$normalized] = 0
        }
        $vendorCounts[$normalized] += 1

        if ($normalized -eq 'Unknown') {
            $raw = if ($inf.provider) { $inf.provider } else { $inf.manufacturer }
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $unknownVendors += $raw
            }
        }

        $samples += [pscustomobject]@{
            inf_name = $inf.inf_name
            class = $inf.class
            provider = $inf.provider
            manufacturer = $inf.manufacturer
            normalized_vendor = $normalized
        }
    }

    return [pscustomobject]@{
        vendor_counts = $vendorCounts
        unknown_vendors = @($unknownVendors | Select-Object -Unique | Sort-Object)
        inf_samples = @($samples | Select-Object -First 100)
    }
}

function Get-DanewDriverAnalysis {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath,
        [Parameter(Mandatory = $true)]
        [object]$CatalogContext,
        [Parameter(Mandatory = $true)]
        [string]$ProfileId
    )

    $infFiles = Get-ChildItem -Path $InputPath -Recurse -File -Filter '*.inf' -ErrorAction SilentlyContinue
    $sysFiles = Get-ChildItem -Path $InputPath -Recurse -File -Filter '*.sys' -ErrorAction SilentlyContinue

    $infMetadata = @()
    foreach ($inf in $infFiles) {
        $meta = Get-DanewInfMetadata -InfPath $inf.FullName
        if ($meta) {
            $infMetadata += $meta
        }
    }

    $present = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $categoryEvidence = @()

    foreach ($category in $CatalogContext.DriverClassMap.categories) {
        $matched = $false

        foreach ($inf in $infMetadata) {
            $classMatch = $false
            $providerMatch = $false
            $infNameMatch = $false

            if ($category.class_names -and $inf.class) {
                $classMatch = @($category.class_names | Where-Object { $_ -ieq $inf.class }).Count -gt 0
            }

            if ($category.provider_patterns -and $inf.provider) {
                foreach ($pp in $category.provider_patterns) {
                    if ($inf.provider.ToLowerInvariant().Contains($pp.ToLowerInvariant())) {
                        $providerMatch = $true
                        break
                    }
                }
            }

            if ($category.inf_name_patterns -and $inf.inf_name) {
                $infNameMatch = Test-DanewWildcardMatch -Value $inf.inf_name -Patterns $category.inf_name_patterns
            }

            if ($classMatch -or $providerMatch -or $infNameMatch) {
                $matched = $true
                $categoryEvidence += [pscustomobject]@{
                    category = $category.id
                    source = 'inf'
                    inf_name = $inf.inf_name
                    provider = $inf.provider
                    class = $inf.class
                }
                break
            }
        }

        if (-not $matched -and $category.sys_name_patterns) {
            foreach ($sys in $sysFiles) {
                if (Test-DanewWildcardMatch -Value $sys.Name -Patterns $category.sys_name_patterns) {
                    $matched = $true
                    $categoryEvidence += [pscustomobject]@{
                        category = $category.id
                        source = 'sys'
                        sys_name = $sys.Name
                    }
                    break
                }
            }
        }

        if ($matched) {
            [void]$present.Add($category.id)
        }
    }

    $requiredForProfile = @($CatalogContext.DriverClassMap.categories | Where-Object { @($_.required_profiles) -contains $ProfileId })
    $missing = @()
    foreach ($c in $requiredForProfile) {
        if (-not $present.Contains($c.id)) {
            $missing += $c.id
        }
    }

    $classesDetected = @()
    foreach ($m in $infMetadata) {
        if ($m -and $m.PSObject.Properties['class'] -and -not [string]::IsNullOrWhiteSpace($m.class)) {
            $classesDetected += $m.class
        }
    }

    return [pscustomobject]@{
        inf_count = @($infFiles).Count
        sys_count = @($sysFiles).Count
        classes_detected = @($classesDetected | Select-Object -Unique | Sort-Object)
        categories_present = @($present | Sort-Object)
        categories_missing = @($missing | Sort-Object)
        evidence = $categoryEvidence
        inf_metadata = $infMetadata
    }
}

function Get-DanewPEValidation {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ToolFileMatches,
        [Parameter(Mandatory = $true)]
        [string]$Architecture
    )

    $details = @()

    foreach ($m in $ToolFileMatches) {
        if ($m.leaf -notmatch '\.exe$|\.dll$|\.efi$|\.sys$') {
            continue
        }

        $machine = Get-DanewPEMachine -FilePath $m.full_path
        $isCompatible = $false

        switch ($Architecture) {
            'x64' { $isCompatible = ($machine -in @('x64', 'x86')) }
            'x86' { $isCompatible = ($machine -eq 'x86') }
            'arm64' { $isCompatible = ($machine -eq 'arm64') }
            default { $isCompatible = ($machine -ne 'unknown') }
        }

        $details += [pscustomobject]@{
            tool = $m.name
            file = $m.full_path
            machine = $machine
            compatible = $isCompatible
        }
    }

    $checked = @($details).Count
    $compatible = @($details | Where-Object { $_.compatible }).Count
    $incompatible = @($details | Where-Object { -not $_.compatible -and $_.machine -ne 'unknown' }).Count
    $unknown = @($details | Where-Object { $_.machine -eq 'unknown' }).Count

    return [pscustomobject]@{
        checked = $checked
        compatible = $compatible
        incompatible = $incompatible
        unknown = $unknown
        details = $details
    }
}

function Invoke-DanewScan {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath,
        [Parameter(Mandatory = $true)]
        [object]$CatalogContext,
        [string]$BootWimPath,
        [int]$ImageIndex = 1,
        [string]$ProfileId = 'sav-advanced'
    )

    $toolNames = @($CatalogContext.BaselineTools.tools)
    $extraTools = @($CatalogContext.ToolsCatalog.items.name)
    $allTools = @($toolNames + $extraTools | Select-Object -Unique)
    $searchNames = Get-DanewSearchNames -Names $allTools

    $toolMatches = Find-DanewToolFiles -InputPath $InputPath -FileNames $searchNames
    $detectedTools = @($toolMatches.leaf | Select-Object -Unique)

    $driverPatterns = @('*.sys', '*.inf', '*.cat')
    $driversFound = @()
    foreach ($p in $driverPatterns) {
        $driversFound += Get-ChildItem -Path $InputPath -Recurse -File -Filter $p -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
    }
    $driversFound = @($driversFound | Select-Object -Unique)

    $runtimeHints = @()
    if ($detectedTools -contains 'powershell.exe' -or $detectedTools -contains 'pwsh.exe') { $runtimeHints += 'powershell' }
    if (Get-ChildItem -Path $InputPath -Recurse -File -Filter 'msvcp*.dll' -ErrorAction SilentlyContinue) { $runtimeHints += 'vcpp' }
    if (Get-ChildItem -Path $InputPath -Recurse -File -Filter 'dotnet.exe' -ErrorAction SilentlyContinue) { $runtimeHints += 'dotnet' }
    if (Get-ChildItem -Path $InputPath -Recurse -File -Filter 'mscoree.dll' -ErrorAction SilentlyContinue) { $runtimeHints += 'netfx' }

    $archDetails = Get-DanewArchitecture -InputPath $InputPath -CatalogContext $CatalogContext -BootWimPath $BootWimPath -ImageIndex $ImageIndex
    $driverAnalysis = Get-DanewDriverAnalysis -InputPath $InputPath -CatalogContext $CatalogContext -ProfileId $ProfileId
    $driverVendorAnalysis = Get-DanewDriverVendorAnalysis -InfMetadata $driverAnalysis.inf_metadata -CatalogContext $CatalogContext
    $registryAnalysis = Get-DanewOfflineRegistryAnalysis -InputPath $InputPath
    $packageAnalysis = Get-DanewPackageAnalysis -InputPath $InputPath -BootWimPath $BootWimPath -ImageIndex $ImageIndex -CatalogContext $CatalogContext -ProfileId $ProfileId
    $peValidation = Get-DanewPEValidation -ToolFileMatches $toolMatches -Architecture $archDetails.detected

    [pscustomobject]@{
        InputPath = $InputPath
        InputType = Get-DanewInputType -InputPath $InputPath -BootWimPath $BootWimPath
        Architecture = $archDetails.detected
        ArchitectureDetails = $archDetails
        FilesScanned = (Get-ChildItem -Path $InputPath -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
        ToolsDetected = @($detectedTools | Sort-Object)
        ToolMatches = $toolMatches
        DriversDetected = @($driversFound | Sort-Object)
        DriverAnalysis = $driverAnalysis
        DriverVendorAnalysis = $driverVendorAnalysis
        RegistryAnalysis = $registryAnalysis
        PackageAnalysis = $packageAnalysis
        PeValidation = $peValidation
        RuntimesDetected = @($runtimeHints | Select-Object -Unique | Sort-Object)
    }
}
