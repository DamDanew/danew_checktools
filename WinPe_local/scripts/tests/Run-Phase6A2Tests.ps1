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

function Add-Phase6A2Result {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Details = ''
    )

    return [pscustomobject]@{ name = $Name; passed = $Passed; details = $Details }
}

function New-Phase6A2TestRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath
    )

    $tempRoot = Join-Path $BasePath 'temp\phase6a2-tests'
    if (Test-Path -Path $tempRoot) {
        Remove-Item -Path $tempRoot -Recurse -Force
    }

    New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null
    foreach ($folder in @('scripts', 'reports', 'logs', 'vol-c', 'vol-e', 'vol-d', 'vol-small', 'vol-nodrive', 'vol-removable')) {
        New-Item -Path (Join-Path $tempRoot $folder) -ItemType Directory -Force | Out-Null
    }

    Copy-Item -Path (Join-Path $BasePath 'scripts\*') -Destination (Join-Path $tempRoot 'scripts') -Recurse -Force

    $cfgPath = Join-Path $tempRoot 'scripts\launcher-config.json'
    $cfg = Get-Content -Path (Join-Path $BasePath 'scripts\launcher-config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $cfg.input_path = 'vol-e'
    $cfg.reports_path = 'reports'
    $cfg.logs_path = 'logs'
    $cfg.launcher_log_path = 'logs/launcher-log.json'
    $cfg.gui_status_snapshot_path = 'reports/gui-status-snapshot.json'
    $cfg | ConvertTo-Json -Depth 20 | Set-Content -Path $cfgPath -Encoding UTF8

    return [pscustomobject]@{
        root = $tempRoot
        config_path = $cfgPath
    }
}

function New-Phase6A2WindowsEvidence {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VolumeRoot
    )

    foreach ($folder in @(
            'Windows\System32\config',
            'Windows\System32\winevt\Logs',
            'Windows\System32'
        )) {
        New-Item -Path (Join-Path $VolumeRoot $folder) -ItemType Directory -Force | Out-Null
    }

    Set-Content -Path (Join-Path $VolumeRoot 'Windows\System32\config\SYSTEM') -Value 'hive' -Encoding ASCII
    Set-Content -Path (Join-Path $VolumeRoot 'Windows\System32\config\SOFTWARE') -Value 'hive' -Encoding ASCII
    Set-Content -Path (Join-Path $VolumeRoot 'Windows\System32\ntoskrnl.exe') -Value 'bin' -Encoding ASCII
    Set-Content -Path (Join-Path $VolumeRoot 'Windows\explorer.exe') -Value 'bin' -Encoding ASCII
}

function New-Phase6A2StorageAnalysis {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TempRoot
    )

    $volC = Join-Path $TempRoot 'vol-c'
    $volD = Join-Path $TempRoot 'vol-d'
    $volE = Join-Path $TempRoot 'vol-e'
    $volSmall = Join-Path $TempRoot 'vol-small'
    $volNoDrive = Join-Path $TempRoot 'vol-nodrive'
    $volRemovable = Join-Path $TempRoot 'vol-removable'

    New-Phase6A2WindowsEvidence -VolumeRoot $volC
    New-Phase6A2WindowsEvidence -VolumeRoot $volNoDrive
    New-Phase6A2WindowsEvidence -VolumeRoot $volRemovable

    foreach ($folder in @('EFI', 'sources', 'scripts', 'tools', 'reports', 'diagnostics')) {
        New-Item -Path (Join-Path $volE $folder) -ItemType Directory -Force | Out-Null
    }
    Set-Content -Path (Join-Path $volE 'launcher-config.json') -Value '{}' -Encoding ASCII
    Set-Content -Path (Join-Path $volE 'scripts\DanewCheckTool.CLI.ps1') -Value 'echo off' -Encoding ASCII

    New-Item -Path (Join-Path $volD 'EFI') -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $volD 'sources') -ItemType Directory -Force | Out-Null
    Set-Content -Path (Join-Path $volD 'sources\boot.wim') -Value 'wim' -Encoding ASCII

    return [pscustomobject]@{
        disks = @(
            [pscustomobject]@{ disk_number = 0; bus_type = 'SATA' },
            [pscustomobject]@{ disk_number = 1; bus_type = 'USB' }
        )
        partitions = @(
            [pscustomobject]@{ disk_number = 0; partition_number = 1; mount_letter = 'C'; mount_path = $volC; filesystem = 'NTFS'; filesystem_label = 'Windows'; size_bytes = 250GB; accessible = $true },
            [pscustomobject]@{ disk_number = 1; partition_number = 1; mount_letter = 'D'; mount_path = $volD; filesystem = 'FAT32'; filesystem_label = 'DANEW_BOOT'; size_bytes = 1GB; accessible = $true },
            [pscustomobject]@{ disk_number = 1; partition_number = 2; mount_letter = 'E'; mount_path = $volE; filesystem = 'NTFS'; filesystem_label = 'DANEW_DATA'; size_bytes = 55GB; accessible = $true },
            [pscustomobject]@{ disk_number = 0; partition_number = 4; mount_letter = 'S'; mount_path = $volSmall; filesystem = 'NTFS'; filesystem_label = 'SmallData'; size_bytes = 4GB; accessible = $true },
            [pscustomobject]@{ disk_number = 0; partition_number = 5; mount_letter = ''; mount_path = $volNoDrive; filesystem = 'NTFS'; filesystem_label = 'NoLetter'; size_bytes = 180GB; accessible = $true },
            [pscustomobject]@{ disk_number = 1; partition_number = 3; mount_letter = 'R'; mount_path = $volRemovable; filesystem = 'NTFS'; filesystem_label = 'WINTOGO'; size_bytes = 128GB; accessible = $true }
        )
        volumes = @()
        mount_attempts = @()
        issues = @()
        candidate_paths = @()
        summary = [pscustomobject]@{
            disk_count = 2
            partition_count = 6
            volume_count = 6
            raw_partition_count = 0
            inaccessible_partition_count = 0
            mount_attempt_count = 0
        }
    }
}

$results = @()
$temp = New-Phase6A2TestRoot -BasePath $RootPath

try {
    . (Join-Path $temp.root 'scripts\launcher\LauncherCore.ps1')

    $config = Get-DanewLauncherConfig -RootPath $temp.root -ConfigPath $temp.config_path
    Initialize-DanewLauncherPaths -Config $config

    $storage = New-Phase6A2StorageAnalysis -TempRoot $temp.root

    $exclusionsDefault = Get-DanewOfflineDiscoveryExclusions -StorageAnalysis $storage -RootPath $temp.root -ToolRootPath $config.input_path

    $case1 = @($exclusionsDefault.excluded_volumes | Where-Object { $_.filesystem_label -eq 'DANEW_BOOT' }).Count -eq 1
    $results += Add-Phase6A2Result -Name 'exclude_DANEW_BOOT' -Passed $case1 -Details ('excluded=' + [string]$case1)

    $case2 = @($exclusionsDefault.excluded_volumes | Where-Object { $_.filesystem_label -eq 'DANEW_DATA' }).Count -eq 1
    $results += Add-Phase6A2Result -Name 'exclude_DANEW_DATA' -Passed $case2 -Details ('excluded=' + [string]$case2)

    $case3 = @($exclusionsDefault.excluded_volumes | Where-Object { $_.path -eq (Join-Path $temp.root 'vol-e') -and $_.exclusion_reason -match 'Danew' }).Count -eq 1
    $results += Add-Phase6A2Result -Name 'exclude_scripts_tools_reports_volume' -Passed $case3 -Details ('excluded=' + [string]$case3)

    $storageRootMatch = [pscustomobject]@{
        disks = @([pscustomobject]@{ disk_number = 0; bus_type = 'SATA' })
        partitions = @([pscustomobject]@{ disk_number = 0; partition_number = 1; mount_letter = 'T'; mount_path = $temp.root; filesystem = 'NTFS'; filesystem_label = 'ROOT'; size_bytes = 200GB; accessible = $true })
        volumes = @(); mount_attempts = @(); issues = @(); candidate_paths = @(); summary = [pscustomobject]@{ disk_count = 1; partition_count = 1; volume_count = 1; raw_partition_count = 0; inaccessible_partition_count = 0; mount_attempt_count = 0 }
    }
    $exclusionsRoot = Get-DanewOfflineDiscoveryExclusions -StorageAnalysis $storageRootMatch -RootPath $temp.root -ToolRootPath $config.input_path
    $case4 = @($exclusionsRoot.excluded_volumes | Where-Object { $_.exclusion_reason -match 'tool root volume' }).Count -eq 1
    $results += Add-Phase6A2Result -Name 'exclude_current_RootPath_volume' -Passed $case4 -Details ('excluded=' + [string]$case4)

    $case5 = @($exclusionsDefault.excluded_volumes | Where-Object { $_.filesystem_label -eq 'WINTOGO' -and $_.exclusion_reason -match 'Removable USB' }).Count -eq 1
    $results += Add-Phase6A2Result -Name 'exclude_removable_USB_default' -Passed $case5 -Details ('excluded=' + [string]$case5)

    $case6 = @($exclusionsDefault.eligible_volumes | Where-Object { $_.mount_letter -eq 'C' }).Count -eq 1
    $results += Add-Phase6A2Result -Name 'include_real_Windows_C' -Passed $case6 -Details ('eligible=' + [string]$case6)

    $preferred = Get-DanewPreferredWindowsVolume -DiscoveryExclusions $exclusionsDefault
    $case6b = ($preferred.preferred_volume -and [string]$preferred.preferred_volume.mount_letter -eq 'C')
    $preferredLetter = ''
    if ($preferred.preferred_volume) {
        $preferredLetter = [string]$preferred.preferred_volume.mount_letter
    }
    $results += Add-Phase6A2Result -Name 'prefer_main_C_partition' -Passed $case6b -Details ('preferred=' + $preferredLetter)

    $case7 = @($exclusionsDefault.eligible_volumes | Where-Object { $_.filesystem_label -eq 'NoLetter' }).Count -eq 1
    $results += Add-Phase6A2Result -Name 'include_no_drive_letter_after_mount' -Passed $case7 -Details ('eligible=' + [string]$case7)

    $exclusionsAllowUsb = Get-DanewOfflineDiscoveryExclusions -StorageAnalysis $storage -RootPath $temp.root -ToolRootPath $config.input_path -AllowRemovableWindowsVolumes
    $case8 = @($exclusionsAllowUsb.eligible_volumes | Where-Object { $_.filesystem_label -eq 'WINTOGO' }).Count -eq 1
    $results += Add-Phase6A2Result -Name 'allow_WindowsToGo_when_explicitly_allowed' -Passed $case8 -Details ('eligible=' + [string]$case8)

    $storageNoEligible = [pscustomobject]@{
        disks = @([pscustomobject]@{ disk_number = 1; bus_type = 'USB' })
        partitions = @(
            [pscustomobject]@{ disk_number = 1; partition_number = 1; mount_letter = 'D'; mount_path = (Join-Path $temp.root 'vol-d'); filesystem = 'FAT32'; filesystem_label = 'DANEW_BOOT'; size_bytes = 1GB; accessible = $true },
            [pscustomobject]@{ disk_number = 1; partition_number = 2; mount_letter = 'E'; mount_path = (Join-Path $temp.root 'vol-e'); filesystem = 'NTFS'; filesystem_label = 'DANEW_DATA'; size_bytes = 55GB; accessible = $true }
        )
        volumes = @(); mount_attempts = @(); issues = @(); candidate_paths = @(); summary = [pscustomobject]@{ disk_count = 1; partition_count = 2; volume_count = 2; raw_partition_count = 0; inaccessible_partition_count = 0; mount_attempt_count = 0 }
    }
    $exclusionsNoEligible = Get-DanewOfflineDiscoveryExclusions -StorageAnalysis $storageNoEligible -RootPath 'X:\' -ToolRootPath 'X:\scripts'
    $caseInfoA = Get-DanewOfflineDiscoveryCase -DiscoveryExclusions $exclusionsNoEligible -Installations @() -ValidInstallations @()
    $case9 = ([string]$caseInfoA.code -eq 'B')
    $results += Add-Phase6A2Result -Name 'no_eligible_internal_disk_case' -Passed $case9 -Details ('case=' + [string]$caseInfoA.code)

    $storageEligibleNoEvidence = [pscustomobject]@{
        disks = @([pscustomobject]@{ disk_number = 0; bus_type = 'SATA' })
        partitions = @([pscustomobject]@{ disk_number = 0; partition_number = 3; mount_letter = 'Z'; mount_path = (Join-Path $temp.root 'vol-small'); filesystem = 'NTFS'; filesystem_label = 'Data'; size_bytes = 120GB; accessible = $true })
        volumes = @(); mount_attempts = @(); issues = @(); candidate_paths = @(); summary = [pscustomobject]@{ disk_count = 1; partition_count = 1; volume_count = 1; raw_partition_count = 0; inaccessible_partition_count = 0; mount_attempt_count = 0 }
    }
    $exclusionsEligible = Get-DanewOfflineDiscoveryExclusions -StorageAnalysis $storageEligibleNoEvidence -RootPath 'X:\' -ToolRootPath 'X:\scripts'
    $eligiblePaths = @($exclusionsEligible.eligible_volumes | ForEach-Object { $_.path })
    $installs = @(Find-DanewOfflineWindowsInstallations -InputPath '' -RootPath '' -CandidatePaths $eligiblePaths)
    $valid = @($installs | Where-Object { $_.is_valid })
    $caseInfoC = Get-DanewOfflineDiscoveryCase -DiscoveryExclusions $exclusionsEligible -Installations $installs -ValidInstallations $valid
    $case10 = ([string]$caseInfoC.code -eq 'C')
    $results += Add-Phase6A2Result -Name 'eligible_disk_but_inaccessible_or_missing_windows_evidence' -Passed $case10 -Details ('case=' + [string]$caseInfoC.code)
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

$jsonPath = Join-Path $OutputDirectory 'phase6a2-tests-report.json'
$txtPath = Join-Path $OutputDirectory 'phase6a2-tests-report.txt'

$report | ConvertTo-Json -Depth 25 | Set-Content -Path $jsonPath -Encoding UTF8

$lines = @(
    'Phase 6A.2 Tests',
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

Write-Host ('Phase 6A.2 test report JSON: ' + $jsonPath)
Write-Host ('Phase 6A.2 test report TXT: ' + $txtPath)

if ($summary.failed -gt 0) {
    exit 1
}
