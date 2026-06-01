Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$reportShellPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'report\HtmlReportShell.ps1'
if (Test-Path -Path $reportShellPath) {
    . $reportShellPath
}

function Get-DanewUsbProvisioningDefaults {
    [pscustomobject]@{
        efi_partition_mb = 1024
        boot_label = 'DANEW_BOOT'
        data_label = 'DANEW_DATA'
        minimum_usb_gb = 16
        recommended_usb_gb = 32
        fat32_max_file_bytes = 4GB
        split_wim_file_size_mb = 3800
        max_copy_retries = 3
    }
}

function Get-DanewBuildMetrics {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BuildPath
    )

    $defaults = Get-DanewUsbProvisioningDefaults
    $sourceRoots = @('Boot', 'EFI', 'sources', 'scripts', 'tools', 'drivers', 'reports', 'logs', 'images', 'manifests', 'profiles', 'schemas', 'builds', 'Assets_danew')
    $totalBytes = 0
    foreach ($root in $sourceRoots) {
        $full = Join-Path $BuildPath $root
        if (Test-Path -Path $full) {
            $sum = 0
            $measure = Get-ChildItem -Path $full -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
            if ($measure -and $measure.PSObject.Properties['Sum'] -and $measure.Sum) {
                $sum = [int64]$measure.Sum
            }
            if ($sum -gt 0) { $totalBytes += $sum }
        }
    }

    $bootWim = Join-Path $BuildPath 'sources\boot.wim'
    $bootWimBytes = 0
    if (Test-Path -Path $bootWim) {
        $bootWimBytes = (Get-Item -Path $bootWim).Length
    }

    $totalGb = [math]::Round(($totalBytes / 1GB), 2)
    $requiredMin = [math]::Max($defaults.minimum_usb_gb, [math]::Ceiling($totalGb + 2))
    $recommended = [math]::Max($defaults.recommended_usb_gb, [math]::Ceiling($totalGb + 8))

    [pscustomobject]@{
        build_path = $BuildPath
        total_bytes = $totalBytes
        total_gb = $totalGb
        boot_wim_path = $bootWim
        boot_wim_bytes = $bootWimBytes
        boot_wim_over_fat32_limit = ($bootWimBytes -gt $defaults.fat32_max_file_bytes)
        minimum_usb_gb = $requiredMin
        recommended_usb_gb = $recommended
    }
}

function Convert-DanewSimulatedDisk {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Disk
    )

    $letters = @()
    if ($Disk.mounted_letters) { $letters = @($Disk.mounted_letters) }

    $filesystems = @()
    if ($Disk.filesystems) { $filesystems = @($Disk.filesystems) }

    [pscustomobject]@{
        disk_number = [int]$Disk.disk_number
        friendly_name = [string]$Disk.friendly_name
        manufacturer = [string]$Disk.manufacturer
        serial_number = [string]$Disk.serial_number
        size_bytes = [int64]$Disk.size_bytes
        free_bytes = [int64]$Disk.free_bytes
        size_gb = [math]::Round(([int64]$Disk.size_bytes / 1GB), 2)
        free_gb = [math]::Round(([int64]$Disk.free_bytes / 1GB), 2)
        bus_type = [string]$Disk.bus_type
        removable = [bool]$Disk.removable
        partition_style = [string]$Disk.partition_style
        filesystems = $filesystems
        mounted_letters = $letters
        usb_version = [string]$Disk.usb_version
        performance_category = [string]$Disk.performance_category
        is_boot = [bool]$Disk.is_boot
        is_system = [bool]$Disk.is_system
        contains_windows = [bool]$Disk.contains_windows
        allow_candidate = ([string]$Disk.bus_type -eq 'USB' -or [bool]$Disk.removable)
        source = 'simulated'
    }
}

function Get-DanewRealDiskContainsWindows {
    param(
        [string[]]$MountedLetters
    )

    foreach ($letter in $MountedLetters) {
        $windowsPath = Join-Path ($letter + '\\') 'Windows\System32\config\SYSTEM'
        if (Test-Path -Path $windowsPath) {
            return $true
        }
    }
    return $false
}

function Get-DanewRealUsbDisks {
    $all = @()
    $diskMap = @{}

    $wmiDisks = @()
    try {
        $wmiDisks = @(Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction Stop)
    }
    catch {
        $wmiDisks = @()
    }

    foreach ($wd in $wmiDisks) {
        $idx = [int]$wd.Index
        $diskMap[$idx] = $wd
    }

    $disks = @()
    try {
        $disks = @(Get-Disk -ErrorAction Stop)
    }
    catch {
        $disks = @()
    }

    foreach ($d in $disks) {
        $mountedLetters = @()
        $fileSystems = @()
        try {
            $parts = @(Get-Partition -DiskNumber $d.Number -ErrorAction Stop)
            foreach ($p in $parts) {
                if ($p.DriveLetter) { $mountedLetters += ($p.DriveLetter + ':') }
                try {
                    $vol = Get-Volume -Partition $p -ErrorAction Stop
                    if ($vol.FileSystem) { $fileSystems += [string]$vol.FileSystem }
                }
                catch {
                }
            }
        }
        catch {
        }

        $wmi = $null
        if ($diskMap.ContainsKey([int]$d.Number)) {
            $wmi = $diskMap[[int]$d.Number]
        }

        $busType = [string]$d.BusType
        $isUsb = $busType -eq 'USB'
        $isRemovable = $false
        if ($d.PSObject.Properties['IsRemovable']) {
            $isRemovable = [bool]$d.IsRemovable
        }
        elseif ($wmi -and $wmi.PNPDeviceID -match 'USBSTOR') {
            $isRemovable = $true
        }

        $isBoot = $false
        if ($d.PSObject.Properties['IsBoot']) {
            $isBoot = [bool]$d.IsBoot
        }

        $isSystem = $false
        if ($d.PSObject.Properties['IsSystem']) {
            $isSystem = [bool]$d.IsSystem
        }

        $allow = ($isUsb -or $isRemovable)

        $usbVersion = ''
        if ($wmi -and $wmi.PNPDeviceID -match 'USBSTOR') {
            if ($wmi.PNPDeviceID -match 'USB\\VID_') {
                $usbVersion = 'USB'
            }
        }

        $perf = 'Standard'
        if ($isUsb -and ($wmi -and ($wmi.Model -match '3\.2|3\.1|USB 3'))) { $perf = 'High' }
        elseif ($isUsb -and ($wmi -and ($wmi.Model -match '2\.0|USB 2'))) { $perf = 'Low' }

        $all += [pscustomobject]@{
            disk_number = [int]$d.Number
            friendly_name = [string]$d.FriendlyName
            manufacturer = if ($wmi) { [string]$wmi.Manufacturer } else { '' }
            serial_number = if ($wmi) { [string]$wmi.SerialNumber } else { '' }
            size_bytes = [int64]$d.Size
            free_bytes = 0
            size_gb = [math]::Round(([double]$d.Size / 1GB), 2)
            free_gb = 0
            bus_type = $busType
            removable = $isRemovable
            partition_style = [string]$d.PartitionStyle
            filesystems = @($fileSystems | Select-Object -Unique)
            mounted_letters = @($mountedLetters | Select-Object -Unique)
            usb_version = $usbVersion
            performance_category = $perf
            is_boot = $isBoot
            is_system = $isSystem
            contains_windows = (Get-DanewRealDiskContainsWindows -MountedLetters @($mountedLetters | Select-Object -Unique))
            allow_candidate = $allow
            source = 'real'
        }
    }

    return $all
}

function Get-DanewUsbDeviceInventory {
    param(
        [string]$SimulatedDisksPath
    )

    if ($SimulatedDisksPath) {
        if (-not (Test-Path -Path $SimulatedDisksPath)) {
            throw "Simulated disks file missing: $SimulatedDisksPath"
        }

        $sim = Get-Content -Path $SimulatedDisksPath -Raw -Encoding UTF8 | ConvertFrom-Json
        return @($sim | ForEach-Object { Convert-DanewSimulatedDisk -Disk $_ })
    }

    return @(Get-DanewRealUsbDisks)
}

function Get-DanewUsbCompatibility {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Disk,
        [Parameter(Mandatory = $true)]
        [object]$BuildMetrics,
        [switch]$LegacyBiosMode
    )

    $requiredMin = [int]$BuildMetrics.minimum_usb_gb
    $recommendedMin = [int]$BuildMetrics.recommended_usb_gb
    $sizeGb = [double]$Disk.size_gb

    $fat32Overflow = [bool]$BuildMetrics.boot_wim_over_fat32_limit
    $supportsUefi = ($Disk.partition_style -eq 'GPT' -or $Disk.partition_style -eq 'RAW' -or [string]::IsNullOrWhiteSpace([string]$Disk.partition_style))

    $status = 'PASS'
    $reasons = @()

    if ($sizeGb -lt $requiredMin) {
        $status = 'FAIL'
        $reasons += "Too small: $sizeGb GB < minimum $requiredMin GB"
    }
    elseif ($sizeGb -lt $recommendedMin) {
        if ($status -ne 'FAIL') { $status = 'WARNING' }
        $reasons += "Below recommended size: $sizeGb GB < recommended $recommendedMin GB"
    }

    if (-not $Disk.allow_candidate) {
        $status = 'FAIL'
        $reasons += 'Disk is not USB/removable candidate.'
    }

    if ($Disk.is_boot -or $Disk.is_system -or $Disk.contains_windows) {
        $status = 'FAIL'
        $reasons += 'Disk appears system/boot/windows and is unsafe.'
    }

    if ($fat32Overflow -and $status -ne 'FAIL') {
        if ($status -eq 'PASS') { $status = 'WARNING' }
        $reasons += 'FAT32 overflow detected (boot.wim > 4GB). Dual-partition strategy required.'
    }

    if ($LegacyBiosMode -and $supportsUefi -and $status -eq 'PASS') {
        $reasons += 'Legacy mode enabled (MBR optional) with UEFI compatibility kept where possible.'
    }

    [pscustomobject]@{
        disk_number = $Disk.disk_number
        status = $status
        supports_uefi = $supportsUefi
        supports_secure_boot = $supportsUefi
        supports_legacy_bios = [bool]$LegacyBiosMode
        fat32_overflow = $fat32Overflow
        required_minimum_size_gb = $requiredMin
        recommended_minimum_size_gb = $recommendedMin
        remaining_space_gb = [math]::Round(($sizeGb - $BuildMetrics.total_gb), 2)
        recommendation = if ($status -eq 'PASS') { 'Recommended: YES' } elseif ($status -eq 'WARNING') { 'Recommended: CONDITIONAL' } else { 'Recommended: NO' }
        reasons = $reasons
    }
}

function Select-DanewUsbTargetDisk {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Candidates,
        [int]$TargetDiskNumber,
        [switch]$NonInteractive
    )

    if ($TargetDiskNumber -ge 0) {
        $match = $Candidates | Where-Object { $_.disk_number -eq $TargetDiskNumber } | Select-Object -First 1
        if (-not $match) {
            throw "Target disk number not found in candidate list: $TargetDiskNumber"
        }
        return $match
    }

    if ($NonInteractive) {
        $recommended = $Candidates | Where-Object { $_.compatibility.status -eq 'PASS' } | Select-Object -First 1
        if ($recommended) { return $recommended }
        throw 'No target disk provided in non-interactive mode and no PASS candidate found.'
    }

    Write-Host ''
    Write-Host 'Detected external/removable USB candidates:'
    foreach ($c in $Candidates) {
        Write-Host ('[{0}] {1} | {2} GB | {3} | {4}' -f $c.disk_number, $c.friendly_name, $c.size_gb, $c.partition_style, $c.compatibility.recommendation)
    }

    $choice = Read-Host 'Enter target disk number'
    $number = -1
    if (-not [int]::TryParse([string]$choice, [ref]$number)) {
        throw 'Invalid disk number selection.'
    }

    $selected = $Candidates | Where-Object { $_.disk_number -eq $number } | Select-Object -First 1
    if (-not $selected) {
        throw "Selected disk number not found: $number"
    }

    return $selected
}

function Test-DanewUsbSafetyValidation {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Disk,
        [Parameter(Mandatory = $true)]
        [object]$Compatibility
    )

    $violations = @()
    if (-not $Disk.allow_candidate) { $violations += 'Not USB/removable.' }
    if ($Disk.is_boot) { $violations += 'Disk flagged as boot disk.' }
    if ($Disk.is_system) { $violations += 'Disk flagged as system disk.' }
    if ($Disk.contains_windows) { $violations += 'Disk contains Windows installation.' }
    if ($Compatibility.status -eq 'FAIL') { $violations += 'Compatibility check failed.' }

    [pscustomobject]@{
        disk_number = $Disk.disk_number
        safety_passed = (@($violations).Count -eq 0)
        violations = $violations
        requires_double_confirmation = $true
    }
}

function New-DanewPartitionLayout {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Disk,
        [Parameter(Mandatory = $true)]
        [object]$BuildMetrics,
        [switch]$LegacyBiosMode
    )

    $defaults = Get-DanewUsbProvisioningDefaults
    $style = if ($LegacyBiosMode) { 'MBR' } else { 'GPT' }

    $dualPartition = $true
    if (-not $BuildMetrics.boot_wim_over_fat32_limit -and $BuildMetrics.total_gb -lt 3) {
        $dualPartition = $true
    }

    $partitions = @(
        [pscustomobject]@{
            name = 'EFI_BOOT'
            fs = 'FAT32'
            size_mb = $defaults.efi_partition_mb
            label = $defaults.boot_label
            content = @('EFI', 'Boot', 'sources')
        },
        [pscustomobject]@{
            name = 'DATA_TOOLS'
            fs = 'NTFS'
            size_mb = -1
            label = $defaults.data_label
            content = @('tools', 'drivers', 'logs', 'reports', 'diagnostics', 'backup', 'images', 'scripts', 'manifests', 'profiles', 'schemas', 'builds', 'Assets_danew')
        }
    )

    [pscustomobject]@{
        disk_number = $Disk.disk_number
        partition_style = $style
        mode = if ($LegacyBiosMode) { 'legacy_optional' } else { 'uefi_default' }
        dual_partition_required = $dualPartition
        fat32_overflow = [bool]$BuildMetrics.boot_wim_over_fat32_limit
        partitions = $partitions
    }
}

function Confirm-DanewUsbOperation {
    param(
        [Parameter(Mandatory = $true)]
        [int]$DiskNumber,
        [switch]$NonInteractive,
        [int]$ConfirmDiskNumber,
        [string]$ConfirmToken
    )

    $expectedToken = 'DANEW-FORMAT-DISK-' + $DiskNumber

    if ($NonInteractive) {
        if ($ConfirmDiskNumber -ne $DiskNumber) {
            throw "Non-interactive confirmation failed: ConfirmDiskNumber must be $DiskNumber"
        }
        if ([string]::IsNullOrWhiteSpace($ConfirmToken) -or $ConfirmToken -ne $expectedToken) {
            throw "Non-interactive confirmation failed: ConfirmToken must be $expectedToken"
        }
        return $true
    }

    $confirmDisk = Read-Host ("Confirm disk number to format ({0})" -f $DiskNumber)
    $n = -1
    [void][int]::TryParse([string]$confirmDisk, [ref]$n)
    if ($n -ne $DiskNumber) {
        throw 'Disk number confirmation mismatch. Operation cancelled.'
    }

    $token = Read-Host ("Type confirmation token: {0}" -f $expectedToken)
    if ($token -ne $expectedToken) {
        throw 'Confirmation token mismatch. Operation cancelled.'
    }

    return $true
}

function Get-DanewDiskStateSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Disk,
        [string]$SimulationRoot
    )

    $timestamp = (Get-Date).ToString('s')
    if ($SimulationRoot) {
        return [pscustomobject]@{
            timestamp = $timestamp
            disk_number = $Disk.disk_number
            simulated = $true
            simulation_root = $SimulationRoot
            partition_style = $Disk.partition_style
            mounted_letters = $Disk.mounted_letters
            filesystems = $Disk.filesystems
        }
    }

    $parts = @()
    try {
        $parts = @(Get-Partition -DiskNumber $Disk.disk_number -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{
                    partition_number = $_.PartitionNumber
                    drive_letter = if ($_.DriveLetter) { $_.DriveLetter + ':' } else { '' }
                    size_bytes = $_.Size
                    type = [string]$_.Type
                    gpt_type = [string]$_.GptType
                }
            })
    }
    catch {
        $parts = @()
    }

    [pscustomobject]@{
        timestamp = $timestamp
        disk_number = $Disk.disk_number
        simulated = $false
        partition_style = $Disk.partition_style
        mounted_letters = $Disk.mounted_letters
        filesystems = $Disk.filesystems
        partitions = $parts
    }
}

function Invoke-DanewUsbPartitioningEngine {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Disk,
        [Parameter(Mandatory = $true)]
        [object]$Layout,
        [switch]$Execute,
        [string]$SimulationRoot
    )

    if (-not $Execute) {
        return [pscustomobject]@{
            executed = $false
            mode = 'dry-run'
            boot_path = ''
            data_path = ''
            actions = @('Partitioning planned only')
        }
    }

    if ($SimulationRoot) {
        $diskRoot = Join-Path $SimulationRoot ('disk-' + $Disk.disk_number)
        $bootPath = Join-Path $diskRoot 'BOOT'
        $dataPath = Join-Path $diskRoot 'DATA'
        New-Item -Path $bootPath -ItemType Directory -Force | Out-Null
        New-Item -Path $dataPath -ItemType Directory -Force | Out-Null

        return [pscustomobject]@{
            executed = $true
            mode = 'simulation'
            boot_path = $bootPath
            data_path = $dataPath
            actions = @('Created simulated BOOT and DATA folders')
        }
    }

    $diskNumber = [int]$Disk.disk_number

    Set-Disk -Number $diskNumber -IsReadOnly $false -ErrorAction Stop
    Clear-Disk -Number $diskNumber -RemoveData -Confirm:$false -ErrorAction Stop

    $postClear = Get-Disk -Number $diskNumber -ErrorAction Stop
    if ([string]$postClear.PartitionStyle -eq 'RAW') {
        Initialize-Disk -Number $diskNumber -PartitionStyle $Layout.partition_style -ErrorAction Stop
    }

    $efiBytes = [int64]$Layout.partitions[0].size_mb * 1MB
    $p1 = New-Partition -DiskNumber $diskNumber -Size $efiBytes -AssignDriveLetter -ErrorAction Stop
    $p2 = New-Partition -DiskNumber $diskNumber -UseMaximumSize -AssignDriveLetter -ErrorAction Stop

    $v1 = Format-Volume -Partition $p1 -FileSystem FAT32 -NewFileSystemLabel $Layout.partitions[0].label -Confirm:$false -Force -ErrorAction Stop
    $v2 = Format-Volume -Partition $p2 -FileSystem NTFS -NewFileSystemLabel $Layout.partitions[1].label -Confirm:$false -Force -ErrorAction Stop

    $bootPath = $v1.DriveLetter + ':\'
    $dataPath = $v2.DriveLetter + ':\'

    [pscustomobject]@{
        executed = $true
        mode = 'real'
        boot_path = $bootPath
        data_path = $dataPath
        actions = @('Disk cleared', 'Disk initialized', 'FAT32/NTFS partitions created')
    }
}

function Copy-DanewItemWithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,
        [Parameter(Mandatory = $true)]
        [string]$Destination,
        [int]$MaxRetries = 3
    )

    $attempt = 0
    while ($attempt -lt $MaxRetries) {
        try {
            $attempt += 1
            if ((Get-Item -Path $Source).PSIsContainer) {
                New-Item -Path $Destination -ItemType Directory -Force | Out-Null
                Copy-Item -Path (Join-Path $Source '*') -Destination $Destination -Recurse -Force
            }
            else {
                $dstDir = Split-Path -Parent $Destination
                if ($dstDir -and -not (Test-Path -Path $dstDir)) {
                    New-Item -Path $dstDir -ItemType Directory -Force | Out-Null
                }
                Copy-Item -Path $Source -Destination $Destination -Force
            }
            return [pscustomobject]@{ success = $true; attempts = $attempt; message = 'copied' }
        }
        catch {
            if ($attempt -ge $MaxRetries) {
                return [pscustomobject]@{ success = $false; attempts = $attempt; message = $_.Exception.Message }
            }
        }
    }
}

function Invoke-DanewUsbExport {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BuildPath,
        [Parameter(Mandatory = $true)]
        [object]$BuildMetrics,
        [Parameter(Mandatory = $true)]
        [object]$Layout,
        [Parameter(Mandatory = $true)]
        [object]$PartitionResult,
        [Parameter(Mandatory = $true)]
        [string]$ReportsDirectory,
        [switch]$Execute
    )

    $defaults = Get-DanewUsbProvisioningDefaults
    $copied = @()
    $manifest = @()
    $warnings = @()

    $bootTarget = [string](Get-DanewSafeProperty -Object $PartitionResult -Name 'boot_path' -DefaultValue '')
    $dataTarget = [string](Get-DanewSafeProperty -Object $PartitionResult -Name 'data_path' -DefaultValue '')
    $isSimulatedPartitionResult = ([string](Get-DanewSafeProperty -Object $PartitionResult -Name 'mode' -DefaultValue '') -eq 'simulation')

    function ConvertTo-DanewDriveRootPath {
        param([string]$PathValue)
        if ([string]::IsNullOrWhiteSpace($PathValue)) {
            return ''
        }
        $trimmed = [string]$PathValue
        if ($trimmed -match '^[A-Za-z]:\\+$') {
            return ([string]$trimmed.Substring(0, 2) + '\')
        }
        if ($trimmed -match '^[A-Za-z]:$') {
            return ([string]$trimmed + '\')
        }
        return ''
    }

    if (-not $Execute) {
        if ([string]::IsNullOrWhiteSpace([string]$bootTarget)) { $bootTarget = 'PLANNED_BOOT' }
        if ([string]::IsNullOrWhiteSpace([string]$dataTarget)) { $dataTarget = 'PLANNED_DATA' }
    }
    elseif ($isSimulatedPartitionResult) {
        if ([string]::IsNullOrWhiteSpace($bootTarget) -or [string]::IsNullOrWhiteSpace($dataTarget)) {
            throw ('USB export aborted: simulated partition result is missing BOOT/DATA paths. bootTarget=' + [string]$bootTarget + '; dataTarget=' + [string]$dataTarget)
        }
    }
    else {
        # Some WinPE stacks can return empty DriveLetter from Format-Volume even though volumes are mounted.
        $bootTarget = ConvertTo-DanewDriveRootPath -PathValue $bootTarget
        $dataTarget = ConvertTo-DanewDriveRootPath -PathValue $dataTarget
        if ([string]::IsNullOrWhiteSpace($bootTarget) -or [string]::IsNullOrWhiteSpace($dataTarget)) {
            $bootVol = $null
            $dataVol = $null
            try {
                $bootVol = Get-Volume -FileSystemLabel $Layout.partitions[0].label -ErrorAction SilentlyContinue | Select-Object -First 1
            }
            catch {
                $bootVol = $null
            }

            try {
                $dataVol = Get-Volume -FileSystemLabel $Layout.partitions[1].label -ErrorAction SilentlyContinue | Select-Object -First 1
            }
            catch {
                $dataVol = $null
            }

            if ($bootVol -and $bootVol.DriveLetter -and ([string]$bootVol.DriveLetter -match '^[A-Za-z]$')) {
                $bootTarget = [string]$bootVol.DriveLetter + ':\'
            }
            if ($dataVol -and $dataVol.DriveLetter -and ([string]$dataVol.DriveLetter -match '^[A-Za-z]$')) {
                $dataTarget = [string]$dataVol.DriveLetter + ':\'
            }
        }

        $bootTarget = ConvertTo-DanewDriveRootPath -PathValue $bootTarget
        $dataTarget = ConvertTo-DanewDriveRootPath -PathValue $dataTarget
        if ([string]::IsNullOrWhiteSpace($bootTarget) -or [string]::IsNullOrWhiteSpace($dataTarget)) {
            throw ('USB export aborted: unable to resolve BOOT/DATA target paths after partitioning. bootTarget=' + [string]$bootTarget + '; dataTarget=' + [string]$dataTarget)
        }
    }

    $bootMap = @(
        [pscustomobject]@{ src = (Join-Path $BuildPath 'EFI'); dst = (Join-Path $bootTarget 'EFI') },
        [pscustomobject]@{ src = (Join-Path $BuildPath 'Boot'); dst = (Join-Path $bootTarget 'Boot') },
            [pscustomobject]@{ src = (Join-Path $BuildPath 'sources\boot.wim'); dst = (Join-Path $bootTarget 'sources\boot.wim') },
            [pscustomobject]@{ src = (Join-Path $BuildPath 'scripts'); dst = (Join-Path $bootTarget 'scripts') },
            [pscustomobject]@{ src = (Join-Path $BuildPath 'manifests'); dst = (Join-Path $bootTarget 'manifests') },
            [pscustomobject]@{ src = (Join-Path $BuildPath 'Assets_danew'); dst = (Join-Path $bootTarget 'Assets_danew') }
    )

    $dataMap = @(
        [pscustomobject]@{ src = (Join-Path $BuildPath 'scripts'); dst = (Join-Path $dataTarget 'scripts') },
        [pscustomobject]@{ src = (Join-Path $BuildPath 'tools'); dst = (Join-Path $dataTarget 'tools') },
        [pscustomobject]@{ src = (Join-Path $BuildPath 'drivers'); dst = (Join-Path $dataTarget 'drivers') },
        [pscustomobject]@{ src = (Join-Path $BuildPath 'logs'); dst = (Join-Path $dataTarget 'logs') },
        [pscustomobject]@{ src = (Join-Path $BuildPath 'reports'); dst = (Join-Path $dataTarget 'reports') },
        [pscustomobject]@{ src = (Join-Path $BuildPath 'images'); dst = (Join-Path $dataTarget 'images') },
        [pscustomobject]@{ src = (Join-Path $BuildPath 'manifests'); dst = (Join-Path $dataTarget 'manifests') },
        [pscustomobject]@{ src = (Join-Path $BuildPath 'profiles'); dst = (Join-Path $dataTarget 'profiles') },
        [pscustomobject]@{ src = (Join-Path $BuildPath 'schemas'); dst = (Join-Path $dataTarget 'schemas') },
        [pscustomobject]@{ src = (Join-Path $BuildPath 'builds'); dst = (Join-Path $dataTarget 'builds') },
        [pscustomobject]@{ src = (Join-Path $BuildPath 'Assets_danew'); dst = (Join-Path $dataTarget 'Assets_danew') }
    )

    foreach ($item in @($bootMap + $dataMap)) {
        if ([string]::IsNullOrWhiteSpace([string]$item.src) -or [string]::IsNullOrWhiteSpace([string]$item.dst)) {
            throw ('USB export aborted: invalid map entry. BuildPath=' + [string]$BuildPath + '; bootTarget=' + [string]$bootTarget + '; dataTarget=' + [string]$dataTarget + '; src=' + [string]$item.src + '; dst=' + [string]$item.dst)
        }

        if (-not (Test-Path -Path $item.src)) {
            $manifest += [pscustomobject]@{ source = $item.src; destination = $item.dst; status = 'missing_source' }
            continue
        }

        if (-not $Execute) {
            $manifest += [pscustomobject]@{ source = $item.src; destination = $item.dst; status = 'planned' }
            continue
        }

        $copyResult = Copy-DanewItemWithRetry -Source $item.src -Destination $item.dst -MaxRetries $defaults.max_copy_retries
        $status = if ($copyResult.success) { 'copied' } else { 'failed' }
        $manifest += [pscustomobject]@{ source = $item.src; destination = $item.dst; status = $status; attempts = $copyResult.attempts; message = $copyResult.message }

        if ($copyResult.success -and -not (Get-Item -Path $item.src).PSIsContainer) {
            $srcHash = (Get-FileHash -Path $item.src -Algorithm SHA256).Hash
            $dstHash = (Get-FileHash -Path $item.dst -Algorithm SHA256).Hash
            $hashOk = ($srcHash -eq $dstHash)
            $copied += [pscustomobject]@{ source = $item.src; destination = $item.dst; sha256_source = $srcHash; sha256_destination = $dstHash; hash_ok = $hashOk }
        }
    }

    if ($Execute) {
        $compatMain = Join-Path -Path $bootTarget -ChildPath 'scripts\main.cmd'
        if ([string]::IsNullOrWhiteSpace([string]$compatMain)) {
            throw ('USB export aborted: failed to build compatibility script path from bootTarget=' + [string]$bootTarget)
        }

        $compatLines = @(
            '@echo off',
            'setlocal enabledelayedexpansion',
            'set DANEW_PS=',
            'if exist X:\Program Files\PowerShell\7\pwsh.exe set DANEW_PS=X:\Program Files\PowerShell\7\pwsh.exe',
            'if not defined DANEW_PS if exist X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe set DANEW_PS=X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
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
            '  echo [DANEW] Add WinPE-PowerShell optional component before booting this media.',
            '  exit /b 127',
            ')',
            'set DANEW_ROOT=',
            'for %%L in (D E F G H I J K L M N O P Q R S T U V W Y Z) do (',
            '  if exist %%L:\scripts\launcher.ps1 set DANEW_ROOT=%%L:\',
            ')',
            'if not defined DANEW_ROOT (',
            '  echo [DANEW] launcher.ps1 not found on USB partitions.',
            '  exit /b 1',
            ')',
            '"%DANEW_PS%" -NoLogo -ExecutionPolicy Bypass -File %DANEW_ROOT%scripts\launcher.ps1 -RootPath %DANEW_ROOT% -FallbackToCli',
            'if errorlevel 1 "%DANEW_PS%" -NoLogo -ExecutionPolicy Bypass -File %DANEW_ROOT%scripts\DanewCheckTool.CLI.ps1 -RootPath %DANEW_ROOT% -Command Interactive',
            'exit /b %errorlevel%'
        )

        $compatDir = Split-Path -Parent $compatMain
        if ([string]::IsNullOrWhiteSpace([string]$compatDir)) {
            $compatDir = Join-Path -Path $bootTarget -ChildPath 'scripts'
        }
        if (-not (Test-Path -Path $compatDir)) {
            New-Item -Path $compatDir -ItemType Directory -Force | Out-Null
        }
        $compatLines | Set-Content -Path $compatMain -Encoding ASCII
        $manifest += [pscustomobject]@{ source = '[generated]'; destination = $compatMain; status = 'generated'; attempts = 1; message = 'compatibility main.cmd bridge created' }
    }

    if ($BuildMetrics.boot_wim_over_fat32_limit) {
        $warnings += 'boot.wim exceeds FAT32 limit; dual-partition strategy selected. For strict FAT32 media, split WIM may be required.'
    }

    $exportManifestPath = Join-Path $ReportsDirectory 'export-manifest.json'
    $copiedFilesPath = Join-Path $ReportsDirectory 'copied-files.json'

    $manifest | ConvertTo-Json -Depth 20 | Set-Content -Path $exportManifestPath -Encoding UTF8
    $copied | ConvertTo-Json -Depth 20 | Set-Content -Path $copiedFilesPath -Encoding UTF8

    [pscustomobject]@{
        export_manifest_path = $exportManifestPath
        copied_files_path = $copiedFilesPath
        manifest = $manifest
        copied_files = $copied
        warnings = $warnings
    }
}

function Test-DanewUsbBootValidation {
    param(
        [Parameter(Mandatory = $true)]
        [object]$PartitionResult,
        [switch]$Execute
    )

    $boot = $PartitionResult.boot_path
    $data = $PartitionResult.data_path

    if (-not $Execute) {
        if ([string]::IsNullOrWhiteSpace([string]$boot)) { $boot = 'PLANNED_BOOT' }
        if ([string]::IsNullOrWhiteSpace([string]$data)) { $data = 'PLANNED_DATA' }
    }

    $checks = @(
        [pscustomobject]@{ name = 'efi_bootx64'; path = (Join-Path $boot 'EFI\Boot\bootx64.efi'); required = $true },
        [pscustomobject]@{ name = 'bcd'; path = (Join-Path $boot 'Boot\BCD'); required = $true },
        [pscustomobject]@{ name = 'boot_wim'; path = (Join-Path $boot 'sources\boot.wim'); required = $true },
        [pscustomobject]@{ name = 'compat_main_cmd'; path = (Join-Path $boot 'scripts\main.cmd'); required = $true },
        [pscustomobject]@{ name = 'startnet_template'; path = (Join-Path $data 'scripts\StartNet.cmd.template'); required = $true },
        [pscustomobject]@{ name = 'launcher'; path = (Join-Path $data 'scripts\launcher.ps1'); required = $true },
        [pscustomobject]@{ name = 'cli'; path = (Join-Path $data 'scripts\DanewCheckTool.CLI.ps1'); required = $true },
        [pscustomobject]@{ name = 'manifest_tools_catalog'; path = (Join-Path $data 'manifests\tools.catalog.json'); required = $true },
        [pscustomobject]@{ name = 'profile_sav_advanced'; path = (Join-Path $data 'profiles\sav-advanced.profile.json'); required = $true },
        [pscustomobject]@{ name = 'schema_scan_report'; path = (Join-Path $data 'schemas\scan-report.schema.json'); required = $true },
        [pscustomobject]@{ name = 'build_history'; path = (Join-Path $data 'builds\build-history.json'); required = $true }
    )

    $resultChecks = @()
    foreach ($c in $checks) {
        $exists = if ($Execute) { Test-Path -Path $c.path } else { $true }
        $resultChecks += [pscustomobject]@{ name = $c.name; path = $c.path; exists = $exists; required = $c.required }
    }

    $missing = @($resultChecks | Where-Object { $_.required -and -not $_.exists }).Count
    $status = if ($missing -eq 0) { 'PASS' } else { 'FAIL' }

    [pscustomobject]@{
        status = $status
        missing_required = $missing
        checks = $resultChecks
    }
}

function Export-DanewUsbSummaryHtml {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [object]$Report
    )

    $warnings = @($Report.warnings)
    $warningItems = if (@($warnings).Count -gt 0) {
        (@($warnings) | ForEach-Object { '<li>' + [System.Security.SecurityElement]::Escape([string]$_) + '</li>' }) -join ''
    }
    else {
        '<li>Aucun avertissement.</li>'
    }

    $metrics = @(
        (New-DanewMetricCardHtml -Label 'Statut global' -Value (Get-DanewLocalizedStatusText $Report.status) -Tone ([string]$Report.status))
        (New-DanewMetricCardHtml -Label 'Mode' -Value ([string]$Report.mode) -Tone 'info')
        (New-DanewMetricCardHtml -Label 'Disque cible' -Value ([string]$Report.target_disk_number) -Tone 'neutral')
        (New-DanewMetricCardHtml -Label 'Taille build (Go)' -Value ([string](Get-DanewSafeProperty -Object $Report.build_metrics -Name 'total_gb' -DefaultValue '0')) -Tone 'good')
    ) -join ''

    $meta = New-DanewReportMetaListHtml -Items @(
        [pscustomobject]@{ label = 'Nom cible'; value = [string](Get-DanewSafeProperty -Object $Report -Name 'target_friendly_name' -DefaultValue '') }
        [pscustomobject]@{ label = 'Validation demarrage'; value = (Get-DanewLocalizedStatusText (Get-DanewSafeProperty -Object $Report.boot_validation -Name 'status' -DefaultValue 'Unknown')) }
        [pscustomobject]@{ label = 'Securite USB'; value = (Get-DanewLocalizedBooleanText (Get-DanewSafeProperty -Object $Report.safety -Name 'safety_passed' -DefaultValue $false)) }
        [pscustomobject]@{ label = 'Generation'; value = [string](Get-DanewSafeProperty -Object $Report -Name 'timestamp' -DefaultValue '') }
    )

    $artifactsRows = @()
    foreach ($prop in @($Report.artifacts.PSObject.Properties)) {
        $artifactName = [string]$prop.Name
        $artifactPath = [string]$prop.Value
        $searchText = [System.Security.SecurityElement]::Escape(($artifactName + ' ' + $artifactPath))
        $artifactsRows += @"
<tr data-search-row="$searchText">
<td>$([System.Security.SecurityElement]::Escape($artifactName))</td>
<td>$([System.Security.SecurityElement]::Escape($artifactPath))</td>
</tr>
"@
    }

    if (@($artifactsRows).Count -eq 0) {
        $artifactsRows += '<tr data-search-row="none"><td colspan="2">Aucun artefact reference.</td></tr>'
    }

    $sections = @(
        (New-DanewReportSectionHtml -Title 'Resume export USB' -Caption 'Synthese operationnelle de la preparation de la cle.' -SearchText ('usb summary status mode disk ' + [string]$Report.status) -BodyHtml ('<div class="split-grid">' + (New-DanewMetricCardHtml -Label 'Validation demarrage' -Value (Get-DanewLocalizedStatusText (Get-DanewSafeProperty -Object $Report.boot_validation -Name 'status' -DefaultValue 'Unknown')) -Tone (Get-DanewSafeProperty -Object $Report.boot_validation -Name 'status' -DefaultValue 'neutral')) + (New-DanewMetricCardHtml -Label 'Securite' -Value (Get-DanewLocalizedBooleanText (Get-DanewSafeProperty -Object $Report.safety -Name 'safety_passed' -DefaultValue $false)) -Tone $(if ([bool](Get-DanewSafeProperty -Object $Report.safety -Name 'safety_passed' -DefaultValue $false)) { 'good' } else { 'danger' })) + '</div>'))
        (New-DanewReportSectionHtml -Title 'Avertissements' -Caption 'Points a verifier avant usage terrain.' -SearchText ('warnings ' + (@($warnings) -join ' ')) -BodyHtml ('<ul class="report-list">' + $warningItems + '</ul>') -Collapsed $true)
        (New-DanewReportSectionHtml -Title 'Artefacts generes' -Caption 'References des sorties JSON/validation produites.' -SearchText 'artifacts export report boot validation rollback' -BodyHtml (New-DanewReportTableHtml -Headers @('Artefact', 'Chemin') -Rows $artifactsRows -EmptyMessage 'Aucun artefact ne correspond au filtre courant.'))
    )

    $html = New-DanewInteractiveReportHtml -Title 'Resume export USB Danew' -Subtitle 'Rapport interactif de preparation media USB avec recherche, tri et impression.' -Status ([string]$Report.status) -Eyebrow 'Provisioning USB' -HeroMetricsHtml ('<div class="hero-metrics">' + $metrics + '</div>') -MetaHtml $meta -Sections $sections -SearchPlaceholder 'Filtrer le resume, les avertissements ou les artefacts'
    $html | Set-Content -Path $Path -Encoding UTF8
}
