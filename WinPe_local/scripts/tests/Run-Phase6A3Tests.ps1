[CmdletBinding()]
param(
    [string]$RootPath,
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RootPath)) {
    $scriptRoot = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
        $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    }
    $RootPath = Split-Path -Parent (Split-Path -Parent $scriptRoot)
}

if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $RootPath 'reports'
}

function Add-Phase6A3Result {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Details = ''
    )

    return [pscustomobject]@{ name = $Name; passed = $Passed; details = $Details }
}

function New-Phase6A3TestRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath
    )

    $tempRoot = Join-Path $BasePath 'temp\phase6a3-tests'
    if (Test-Path -Path $tempRoot) {
        Remove-Item -Path $tempRoot -Recurse -Force
    }

    New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null
    foreach ($folder in @('scripts', 'reports', 'logs', 'vol-c', 'vol-d', 'vol-x', 'vol-usb', 'vol-noltr')) {
        New-Item -Path (Join-Path $tempRoot $folder) -ItemType Directory -Force | Out-Null
    }

    Copy-Item -Path (Join-Path $BasePath 'scripts\*') -Destination (Join-Path $tempRoot 'scripts') -Recurse -Force

    $cfgPath = Join-Path $tempRoot 'scripts\launcher-config.json'
    $cfg = Get-Content -Path (Join-Path $BasePath 'scripts\launcher-config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $cfg.input_path = 'vol-c'
    $cfg.reports_path = 'reports'
    $cfg.logs_path = 'logs'
    $cfg.launcher_log_path = 'logs/launcher-log.json'
    $cfg.gui_status_snapshot_path = 'reports/gui-status-snapshot.json'
    $cfg | ConvertTo-Json -Depth 20 | Set-Content -Path $cfgPath -Encoding UTF8

    return [pscustomobject]@{ root = $tempRoot; config_path = $cfgPath }
}

function Add-WindowsEvidence {
    param([Parameter(Mandatory = $true)][string]$Base)

    foreach ($folder in @(
            'Windows\System32\config',
            'Windows\System32\winevt\Logs',
            'Windows\System32',
            'Users',
            'Program Files'
        )) {
        New-Item -Path (Join-Path $Base $folder) -ItemType Directory -Force | Out-Null
    }

    Set-Content -Path (Join-Path $Base 'Windows\System32\config\SYSTEM') -Value 'hive' -Encoding ASCII
    Set-Content -Path (Join-Path $Base 'Windows\System32\config\SOFTWARE') -Value 'hive' -Encoding ASCII
    Set-Content -Path (Join-Path $Base 'Windows\System32\winevt\Logs\System.evtx') -Value 'evtx' -Encoding ASCII
    Set-Content -Path (Join-Path $Base 'Windows\System32\ntoskrnl.exe') -Value 'bin' -Encoding ASCII
    Set-Content -Path (Join-Path $Base 'Windows\explorer.exe') -Value 'bin' -Encoding ASCII
}

function New-BaseStorage {
    param(
        [Parameter(Mandatory = $true)][string]$TempRoot
    )

    $c = Join-Path $TempRoot 'vol-c'
    $d = Join-Path $TempRoot 'vol-d'
    $x = Join-Path $TempRoot 'vol-x'
    $u = Join-Path $TempRoot 'vol-usb'
    $n = Join-Path $TempRoot 'vol-noltr'

    Add-WindowsEvidence -Base $c

    return [pscustomobject]@{
        disks = @(
            [pscustomobject]@{ disk_number = 0; bus_type = 'NVMe'; size_bytes = 512GB },
            [pscustomobject]@{ disk_number = 1; bus_type = 'SATA'; size_bytes = 256GB },
            [pscustomobject]@{ disk_number = 2; bus_type = 'USB'; size_bytes = 128GB }
        )
        partitions = @(
            [pscustomobject]@{ disk_number = 0; partition_number = 1; gpt_type = 'C12A7328-F81F-11D2-BA4B-00A0C93EC93B'; filesystem='FAT32'; filesystem_label='SYSTEM'; mount_letter=''; mount_path=''; size_bytes=300MB; accessible=$false },
            [pscustomobject]@{ disk_number = 0; partition_number = 2; gpt_type = 'E3C9E316-0B5C-4DB8-817D-F92DF00215AE'; filesystem=''; filesystem_label=''; mount_letter=''; mount_path=''; size_bytes=16MB; accessible=$false },
            [pscustomobject]@{ disk_number = 0; partition_number = 3; gpt_type = 'EBD0A0A2-B9E5-4433-87C0-68B6B72699C7'; filesystem='NTFS'; filesystem_label='Windows'; mount_letter='C'; mount_path=$c; size_bytes=220GB; accessible=$true },
            [pscustomobject]@{ disk_number = 0; partition_number = 4; gpt_type = 'DE94BBA4-06D1-4D40-A16A-BFD50179D6AC'; filesystem='NTFS'; filesystem_label='Recovery'; mount_letter=''; mount_path=''; size_bytes=1GB; accessible=$false },
            [pscustomobject]@{ disk_number = 1; partition_number = 1; gpt_type = 'EBD0A0A2-B9E5-4433-87C0-68B6B72699C7'; filesystem='NTFS'; filesystem_label='Data'; mount_letter='D'; mount_path=$d; size_bytes=180GB; accessible=$true },
            [pscustomobject]@{ disk_number = 1; partition_number = 2; gpt_type = 'EBD0A0A2-B9E5-4433-87C0-68B6B72699C7'; filesystem='NTFS'; filesystem_label='NoLetter'; mount_letter=''; mount_path=$n; size_bytes=150GB; accessible=$true },
            [pscustomobject]@{ disk_number = 2; partition_number = 1; gpt_type = 'EBD0A0A2-B9E5-4433-87C0-68B6B72699C7'; filesystem='NTFS'; filesystem_label='WINTOGO'; mount_letter='X'; mount_path=$u; size_bytes=120GB; accessible=$true },
            [pscustomobject]@{ disk_number = 2; partition_number = 2; gpt_type = 'EBD0A0A2-B9E5-4433-87C0-68B6B72699C7'; filesystem='NTFS'; filesystem_label='DANEW_DATA'; mount_letter='E'; mount_path=$x; size_bytes=90GB; accessible=$true }
        )
        volumes = @()
        mount_attempts = @(
            [pscustomobject]@{ disk_number = 1; partition_number = 2; temporary_drive_letter = 'W'; access_path = 'W:\'; status = 'mounted'; message = 'Temporary mount succeeded.'; has_system_hive = $true; has_software_hive = $true; has_system_evtx = $true; has_ntoskrnl = $true; has_explorer = $true; has_users = $true; has_program_files = $true }
        )
        issues = @()
        candidate_paths = @($c,$d,$n,$u,$x)
        summary = [pscustomobject]@{ disk_count = 3; partition_count = 8; volume_count = 5; raw_partition_count = 0; inaccessible_partition_count = 3; mount_attempt_count = 1 }
    }
}

$results = @()
$temp = New-Phase6A3TestRoot -BasePath $RootPath

try {
    . (Join-Path $temp.root 'scripts\launcher\LauncherCore.ps1')

    $storage = New-BaseStorage -TempRoot $temp.root
    $allowRemovable = $false

    # Case 1: Windows on C:
    $ex1 = Get-DanewOfflineDiscoveryExclusions -StorageAnalysis $storage -RootPath 'X:\' -ToolRootPath 'X:\scripts' -AllowRemovableWindowsVolumes:$allowRemovable
    $pd1 = Get-DanewPrimaryDiskAnalysis -StorageAnalysis $storage -AllowRemovableWindowsVolumes:$allowRemovable
    $bl1 = [pscustomobject]@{ volumes=@(); summary=[pscustomobject]@{locked_or_protected_count=0} }
    $rank1 = Get-DanewWindowsVolumeRanking -StorageAnalysis $storage -DiscoveryExclusions $ex1 -PrimaryDiskAnalysis $pd1 -BitLockerAnalysis $bl1
    $results += Add-Phase6A3Result -Name 'windows_on_C' -Passed ([string]$rank1.preferred_windows_volume.mount_letter -eq 'C') -Details ('preferred=' + [string]$rank1.preferred_windows_volume.mount_letter)

    # Case 2: Windows on D:\
    $storage2 = $storage.PSObject.Copy()
    Remove-Item -Path (Join-Path $temp.root 'vol-c\Windows') -Recurse -Force
    Add-WindowsEvidence -Base (Join-Path $temp.root 'vol-d')
    $ex2 = Get-DanewOfflineDiscoveryExclusions -StorageAnalysis $storage -RootPath 'X:\' -ToolRootPath 'X:\scripts'
    $rank2 = Get-DanewWindowsVolumeRanking -StorageAnalysis $storage -DiscoveryExclusions $ex2 -PrimaryDiskAnalysis $pd1 -BitLockerAnalysis $bl1
    $results += Add-Phase6A3Result -Name 'windows_on_D' -Passed ([string]$rank2.preferred_windows_volume.mount_letter -eq 'D') -Details ('preferred=' + [string]$rank2.preferred_windows_volume.mount_letter)

    # Restore C evidence for remaining tests
    Add-WindowsEvidence -Base (Join-Path $temp.root 'vol-c')

    # Case 3: partition without drive letter
    $case3 = @($ex1.eligible_volumes | Where-Object { [string]$_.filesystem_label -eq 'NoLetter' }).Count -eq 1
    $results += Add-Phase6A3Result -Name 'windows_partition_without_letter' -Passed $case3 -Details ('eligible=' + [string]$case3)

    # Case 4: temporary mount W used
    $case4 = @($storage.mount_attempts | Where-Object { $_.temporary_drive_letter -eq 'W' -and $_.status -eq 'mounted' }).Count -eq 1
    $results += Add-Phase6A3Result -Name 'temporary_mount_W' -Passed $case4 -Details ('mounted=' + [string]$case4)

    # Case 5: internal visible no OS
    $storage5 = [pscustomobject]@{
        disks = @([pscustomobject]@{ disk_number = 0; bus_type = 'NVMe'; size_bytes = 256GB })
        partitions = @([pscustomobject]@{ disk_number = 0; partition_number = 1; gpt_type = 'EBD0A0A2-B9E5-4433-87C0-68B6B72699C7'; filesystem='NTFS'; filesystem_label='Data'; mount_letter='Q'; mount_path=(Join-Path $temp.root 'vol-x'); size_bytes=80GB; accessible=$true })
        volumes=@(); mount_attempts=@(); issues=@(); candidate_paths=@(); summary=[pscustomobject]@{ disk_count = 1; partition_count = 1; volume_count = 1; raw_partition_count = 0; inaccessible_partition_count = 0; mount_attempt_count = 0 }
    }
    $pd5 = Get-DanewPrimaryDiskAnalysis -StorageAnalysis $storage5
    $ex5 = Get-DanewOfflineDiscoveryExclusions -StorageAnalysis $storage5 -RootPath 'X:\' -ToolRootPath 'X:\scripts'
    $rank5 = Get-DanewWindowsVolumeRanking -StorageAnalysis $storage5 -DiscoveryExclusions $ex5 -PrimaryDiskAnalysis $pd5 -BitLockerAnalysis $bl1
    $vis5 = Get-DanewStorageVisibilityDiagnosis -StorageAnalysis $storage5 -PrimaryDiskAnalysis $pd5 -WindowsVolumeRanking $rank5
    $results += Add-Phase6A3Result -Name 'internal_visible_no_os' -Passed ([string]$vis5.storage_visibility_case -eq 'B') -Details ('case=' + [string]$vis5.storage_visibility_case)

    # Case 6: no internal disk visible
    $storage6 = [pscustomobject]@{ disks=@([pscustomobject]@{ disk_number = 2; bus_type = 'USB'; size_bytes = 64GB }); partitions=@(); volumes=@(); mount_attempts=@(); issues=@(); candidate_paths=@(); summary=[pscustomobject]@{ disk_count = 1; partition_count = 0; volume_count = 0; raw_partition_count = 0; inaccessible_partition_count = 0; mount_attempt_count = 0 } }
    $pd6 = Get-DanewPrimaryDiskAnalysis -StorageAnalysis $storage6
    $rank6 = [pscustomobject]@{ ranked_volumes = @() }
    $vis6 = Get-DanewStorageVisibilityDiagnosis -StorageAnalysis $storage6 -PrimaryDiskAnalysis $pd6 -WindowsVolumeRanking $rank6
    $results += Add-Phase6A3Result -Name 'no_internal_disk_visible' -Passed ([string]$vis6.storage_visibility_case -eq 'A') -Details ('case=' + [string]$vis6.storage_visibility_case)

    # Case 7: EFI + Recovery present OS missing
    $storage7 = [pscustomobject]@{
        disks = @([pscustomobject]@{ disk_number = 0; bus_type = 'NVMe'; size_bytes = 256GB })
        partitions = @(
            [pscustomobject]@{ disk_number = 0; partition_number = 1; gpt_type = 'C12A7328-F81F-11D2-BA4B-00A0C93EC93B'; filesystem='FAT32'; filesystem_label='SYSTEM'; mount_letter=''; mount_path=''; size_bytes=300MB; accessible=$false },
            [pscustomobject]@{ disk_number = 0; partition_number = 2; gpt_type = 'DE94BBA4-06D1-4D40-A16A-BFD50179D6AC'; filesystem='NTFS'; filesystem_label='Recovery'; mount_letter=''; mount_path=''; size_bytes=1GB; accessible=$false }
        )
        volumes=@(); mount_attempts=@(); issues=@(); candidate_paths=@(); summary=[pscustomobject]@{ disk_count = 1; partition_count = 2; volume_count = 0; raw_partition_count = 0; inaccessible_partition_count = 2; mount_attempt_count = 0 }
    }
    $pd7 = Get-DanewPrimaryDiskAnalysis -StorageAnalysis $storage7
    $rank7 = [pscustomobject]@{ ranked_volumes = @() }
    $vis7 = Get-DanewStorageVisibilityDiagnosis -StorageAnalysis $storage7 -PrimaryDiskAnalysis $pd7 -WindowsVolumeRanking $rank7
    $results += Add-Phase6A3Result -Name 'efi_recovery_os_missing' -Passed ([string]$vis7.storage_visibility_case -eq 'D') -Details ('case=' + [string]$vis7.storage_visibility_case)

    # Case 8: BitLocker locked probable OS
    $storage8 = [pscustomobject]@{
        disks = @([pscustomobject]@{ disk_number = 0; bus_type = 'NVMe'; size_bytes = 256GB })
        partitions = @([pscustomobject]@{ disk_number = 0; partition_number = 3; gpt_type = 'EBD0A0A2-B9E5-4433-87C0-68B6B72699C7'; filesystem='NTFS'; filesystem_label='Windows'; mount_letter=''; mount_path=(Join-Path $temp.root 'vol-noltr'); size_bytes=120GB; accessible=$false })
        volumes=@(); mount_attempts=@(); issues=@(); candidate_paths=@(); summary=[pscustomobject]@{ disk_count = 1; partition_count = 1; volume_count = 1; raw_partition_count = 0; inaccessible_partition_count = 1; mount_attempt_count = 0 }
    }
    $pd8 = Get-DanewPrimaryDiskAnalysis -StorageAnalysis $storage8
    $ex8 = Get-DanewOfflineDiscoveryExclusions -StorageAnalysis $storage8 -RootPath 'X:\' -ToolRootPath 'X:\scripts'
    $rank8 = Get-DanewWindowsVolumeRanking -StorageAnalysis $storage8 -DiscoveryExclusions $ex8 -PrimaryDiskAnalysis $pd8 -BitLockerAnalysis $bl1
    $vis8 = Get-DanewStorageVisibilityDiagnosis -StorageAnalysis $storage8 -PrimaryDiskAnalysis $pd8 -WindowsVolumeRanking $rank8
    $results += Add-Phase6A3Result -Name 'bitlocker_locked_probable_os' -Passed ($vis8.bitlocker_suspected) -Details ('bitlocker_suspected=' + [string]$vis8.bitlocker_suspected)

    # Case 9: DANEW_DATA excluded even with windows-like folders
    Add-WindowsEvidence -Base (Join-Path $temp.root 'vol-x')
    $ex9 = Get-DanewOfflineDiscoveryExclusions -StorageAnalysis $storage -RootPath 'X:\' -ToolRootPath 'X:\scripts'
    $case9 = @($ex9.excluded_volumes | Where-Object { [string]$_.filesystem_label -eq 'DANEW_DATA' }).Count -eq 1
    $results += Add-Phase6A3Result -Name 'danew_data_excluded_with_windows_like_folders' -Passed $case9 -Details ('excluded=' + [string]$case9)

    # Case 10: multiple candidates choose best
    Add-WindowsEvidence -Base (Join-Path $temp.root 'vol-d')
    $ex10 = Get-DanewOfflineDiscoveryExclusions -StorageAnalysis $storage -RootPath 'X:\' -ToolRootPath 'X:\scripts'
    $rank10 = Get-DanewWindowsVolumeRanking -StorageAnalysis $storage -DiscoveryExclusions $ex10 -PrimaryDiskAnalysis $pd1 -BitLockerAnalysis $bl1
    $results += Add-Phase6A3Result -Name 'multiple_candidates_choose_best' -Passed ([string]$rank10.preferred_windows_volume.mount_letter -eq 'C') -Details ('preferred=' + [string]$rank10.preferred_windows_volume.mount_letter)

    # Case 11: disk 0 internal priority
    $pd11 = Get-DanewPrimaryDiskAnalysis -StorageAnalysis $storage
    $results += Add-Phase6A3Result -Name 'disk0_internal_priority' -Passed ([int]$pd11.preferred_primary_disk.disk_number -eq 0) -Details ('preferred_disk=' + [string]$pd11.preferred_primary_disk.disk_number)

    # Case 12: USB Windows To Go excluded unless allowed
    Add-WindowsEvidence -Base (Join-Path $temp.root 'vol-usb')
    $ex12a = Get-DanewOfflineDiscoveryExclusions -StorageAnalysis $storage -RootPath 'X:\' -ToolRootPath 'X:\scripts'
    $excludedUsb = @($ex12a.excluded_volumes | Where-Object { [string]$_.filesystem_label -eq 'WINTOGO' }).Count -eq 1
    $ex12b = Get-DanewOfflineDiscoveryExclusions -StorageAnalysis $storage -RootPath 'X:\' -ToolRootPath 'X:\scripts' -AllowRemovableWindowsVolumes
    $allowedUsb = @($ex12b.eligible_volumes | Where-Object { [string]$_.filesystem_label -eq 'WINTOGO' }).Count -eq 1
    $results += Add-Phase6A3Result -Name 'usb_windows_to_go_policy' -Passed ($excludedUsb -and $allowedUsb) -Details ('excluded=' + [string]$excludedUsb + '; allowed=' + [string]$allowedUsb)
}
finally {
    if (Test-Path -Path $temp.root) {
        try {
            Remove-Item -Path $temp.root -Recurse -Force -ErrorAction Stop
        }
        catch {
        }
    }
}

$summary = [pscustomobject]@{
    total = @($results).Count
    passed = @($results | Where-Object { $_.passed }).Count
    failed = @($results | Where-Object { -not $_.passed }).Count
}

$report = [pscustomobject]@{
    timestamp = (Get-Date).ToString('s')
    summary = $summary
    tests = $results
}

if (-not (Test-Path -Path $OutputDirectory)) {
    New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
}

$jsonPath = Join-Path $OutputDirectory 'phase6a3-tests-report.json'
$txtPath = Join-Path $OutputDirectory 'phase6a3-tests-report.txt'

$report | ConvertTo-Json -Depth 25 | Set-Content -Path $jsonPath -Encoding UTF8

$lines = @(
    'Phase 6A.3 Tests',
    ('Total: ' + [string]$summary.total),
    ('Passed: ' + [string]$summary.passed),
    ('Failed: ' + [string]$summary.failed),
    ''
)
foreach ($t in @($results)) {
    $status = if ($t.passed) { 'PASS' } else { 'FAIL' }
    $lines += '[' + $status + '] ' + [string]$t.name + ' - ' + [string]$t.details
}
$lines | Set-Content -Path $txtPath -Encoding UTF8

Write-Host ('Phase 6A.3 test report JSON: ' + $jsonPath)
Write-Host ('Phase 6A.3 test report TXT: ' + $txtPath)

if ($summary.failed -gt 0) {
    exit 1
}
