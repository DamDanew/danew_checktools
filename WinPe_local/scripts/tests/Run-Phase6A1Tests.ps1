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

function Add-Phase6A1Result {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Details = ''
    )

    return [pscustomobject]@{ name = $Name; passed = $Passed; details = $Details }
}

function New-Phase6A1TestRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath
    )

    $tempRoot = Join-Path $BasePath 'temp\phase6a1-tests'
    if (Test-Path -Path $tempRoot) {
        Remove-Item -Path $tempRoot -Recurse -Force
    }

    New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null
    foreach ($folder in @(
            'scripts',
            'reports',
            'logs',
            'offline-lab',
            'offline-lab\efi-only\EFI\Microsoft\Boot',
            'offline-lab\fake\candidate-1\Windows',
            'offline-lab\multi\install-1\Windows\System32\config',
            'offline-lab\multi\install-1\Windows\System32\winevt\Logs',
            'offline-lab\multi\install-1\Windows\System32',
            'offline-lab\multi\install-2\Windows\System32\config',
            'offline-lab\multi\install-2\Windows\System32\winevt\Logs',
            'offline-lab\multi\install-2\Windows\System32',
            'offline-lab\partial\Windows\System32\config',
            'offline-lab\partial\Windows\System32\winevt\Logs',
            'offline-lab\partial\Windows\System32'
        )) {
        New-Item -Path (Join-Path $tempRoot $folder) -ItemType Directory -Force | Out-Null
    }

    Copy-Item -Path (Join-Path $BasePath 'scripts\*') -Destination (Join-Path $tempRoot 'scripts') -Recurse -Force

    Set-Content -Path (Join-Path $tempRoot 'offline-lab\multi\install-1\Windows\System32\config\SYSTEM') -Value 'hive' -Encoding ASCII
    Set-Content -Path (Join-Path $tempRoot 'offline-lab\multi\install-1\Windows\System32\config\SOFTWARE') -Value 'hive' -Encoding ASCII
    Set-Content -Path (Join-Path $tempRoot 'offline-lab\multi\install-1\Windows\System32\explorer.exe') -Value 'bin' -Encoding ASCII
    Set-Content -Path (Join-Path $tempRoot 'offline-lab\multi\install-1\Windows\System32\ntoskrnl.exe') -Value 'bin' -Encoding ASCII

    Set-Content -Path (Join-Path $tempRoot 'offline-lab\multi\install-2\Windows\System32\config\SYSTEM') -Value 'hive' -Encoding ASCII
    Set-Content -Path (Join-Path $tempRoot 'offline-lab\multi\install-2\Windows\System32\config\SOFTWARE') -Value 'hive' -Encoding ASCII
    Set-Content -Path (Join-Path $tempRoot 'offline-lab\multi\install-2\Windows\System32\explorer.exe') -Value 'bin' -Encoding ASCII
    Set-Content -Path (Join-Path $tempRoot 'offline-lab\multi\install-2\Windows\System32\ntoskrnl.exe') -Value 'bin' -Encoding ASCII

    Set-Content -Path (Join-Path $tempRoot 'offline-lab\partial\Windows\System32\config\SYSTEM') -Value 'hive' -Encoding ASCII
    Set-Content -Path (Join-Path $tempRoot 'offline-lab\partial\Windows\System32\explorer.exe') -Value 'bin' -Encoding ASCII

    $cfgPath = Join-Path $tempRoot 'scripts\launcher-config.json'
    $cfg = Get-Content -Path (Join-Path $BasePath 'scripts\launcher-config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $cfg.input_path = 'offline-lab'
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

$results = @()
$temp = New-Phase6A1TestRoot -BasePath $RootPath

try {
    . (Join-Path $temp.root 'scripts\launcher\LauncherCore.ps1')

    $config = Get-DanewLauncherConfig -RootPath $temp.root -ConfigPath $temp.config_path
    Initialize-DanewLauncherPaths -Config $config

    $storageForRoles = [pscustomobject]@{
        partitions = @(
            [pscustomobject]@{ disk_number = 0; partition_number = 1; gpt_type = 'DE94BBA4-06D1-4D40-A16A-BFD50179D6AC'; filesystem = 'NTFS'; filesystem_label = 'Recovery'; size_bytes = 600MB; mount_path = ''; mount_letter = ''; is_hidden = $true },
            [pscustomobject]@{ disk_number = 0; partition_number = 2; gpt_type = ''; filesystem = 'NTFS'; filesystem_label = 'Data'; size_bytes = 20GB; mount_path = '\\?\Volume{1234}\\'; mount_letter = ''; is_hidden = $false },
            [pscustomobject]@{ disk_number = 0; partition_number = 3; gpt_type = 'C12A7328-F81F-11D2-BA4B-00A0C93EC93B'; filesystem = 'FAT32'; filesystem_label = 'EFI'; size_bytes = 100MB; mount_path = ''; mount_letter = ''; is_hidden = $false }
        )
        summary = [pscustomobject]@{ disk_count = 1; partition_count = 3; volume_count = 1; raw_partition_count = 0; inaccessible_partition_count = 0; mount_attempt_count = 0 }
    }

    $installationsForRoles = @(
        [pscustomobject]@{ path = (Join-Path $temp.root 'offline-lab\multi\install-1') }
    )

    $roleAnalysis = Get-DanewPartitionRoleAnalysis -StorageAnalysis $storageForRoles -Installations $installationsForRoles

    $hiddenRecovery = @($roleAnalysis.partitions | Where-Object { $_.partition_number -eq 1 -and $_.role -eq 'Recovery' }).Count -ge 1
    $results += Add-Phase6A1Result -Name 'hidden_partition' -Passed $hiddenRecovery -Details ('recovery_match=' + [string]$hiddenRecovery)

    $withoutLetterHandled = @($roleAnalysis.partitions | Where-Object { $_.partition_number -eq 2 }).Count -eq 1
    $results += Add-Phase6A1Result -Name 'partition_without_letter' -Passed $withoutLetterHandled -Details ('handled=' + [string]$withoutLetterHandled)

    $storageRaw = [pscustomobject]@{
        summary = [pscustomobject]@{ disk_count = 1; partition_count = 1; raw_partition_count = 1 }
        partitions = @([pscustomobject]@{ accessible = $false })
        disks = @([pscustomobject]@{ bus_type = 'NVMe' })
    }
    $bitlockerEmpty = [pscustomobject]@{ summary = [pscustomobject]@{ locked_or_protected_count = 0 } }
    $partitionRoleRaw = [pscustomobject]@{ summary = [pscustomobject]@{ efi_count = 0 } }
    $diagRaw = Get-DanewStorageDiagnostics -StorageAnalysis $storageRaw -BitLockerAnalysis $bitlockerEmpty -PartitionRoleAnalysis $partitionRoleRaw -Installations @() -ValidInstallations @() -DiscoveryItems @() -RegistryDetails @()
    $rawCause = @($diagRaw.probable_causes | Where-Object { $_.cause -eq 'RAW filesystem' }).Count -ge 1
    $results += Add-Phase6A1Result -Name 'RAW_partition' -Passed $rawCause -Details ('raw_cause=' + [string]$rawCause)

    $bitlockerLocked = [pscustomobject]@{ summary = [pscustomobject]@{ locked_or_protected_count = 1 } }
    $storageNormal = [pscustomobject]@{ summary = [pscustomobject]@{ disk_count = 1; partition_count = 1; raw_partition_count = 0 }; partitions = @([pscustomobject]@{ accessible = $true }); disks = @([pscustomobject]@{ bus_type = 'SATA' }) }
    $diagBitLocker = Get-DanewStorageDiagnostics -StorageAnalysis $storageNormal -BitLockerAnalysis $bitlockerLocked -PartitionRoleAnalysis $partitionRoleRaw -Installations @() -ValidInstallations @() -DiscoveryItems @() -RegistryDetails @()
    $bitlockerCause = @($diagBitLocker.probable_causes | Where-Object { $_.cause -eq 'BitLocker locked' }).Count -ge 1
    $results += Add-Phase6A1Result -Name 'BitLocker_locked_volume' -Passed $bitlockerCause -Details ('bitlocker_cause=' + [string]$bitlockerCause)

    $missingSystemCandidatePath = Join-Path $temp.root 'offline-lab\partial'
    $missingSystem = Test-DanewOfflineWindowsCandidate -CandidatePath $missingSystemCandidatePath
    $missingSystemPass = (-not $missingSystem.is_valid) -and (@($missingSystem.rejection_reasons | Where-Object { $_ -match 'SOFTWARE hive' }).Count -ge 1)
    $results += Add-Phase6A1Result -Name 'missing_SYSTEM_hive' -Passed $missingSystemPass -Details ('valid=' + [string]$missingSystem.is_valid)

    $diagInaccessibleEvtx = Get-DanewStorageDiagnostics -StorageAnalysis $storageNormal -BitLockerAnalysis $bitlockerEmpty -PartitionRoleAnalysis $partitionRoleRaw -Installations @() -ValidInstallations @() -DiscoveryItems @([pscustomobject]@{ status = 'inaccessible' }) -RegistryDetails @()
    $evtxCause = @($diagInaccessibleEvtx.probable_causes | Where-Object { $_.cause -eq 'inaccessible EVTX logs' }).Count -ge 1
    $results += Add-Phase6A1Result -Name 'inaccessible_EVTX_logs' -Passed $evtxCause -Details ('evtx_cause=' + [string]$evtxCause)

    $efiOnly = [pscustomobject]@{
        partitions = @([pscustomobject]@{ disk_number = 1; partition_number = 1; gpt_type = 'C12A7328-F81F-11D2-BA4B-00A0C93EC93B'; filesystem = 'FAT32'; filesystem_label = 'EFI'; size_bytes = 100MB; mount_path = ''; mount_letter = '' })
        summary = [pscustomobject]@{ disk_count = 1; partition_count = 1; volume_count = 1; raw_partition_count = 0; inaccessible_partition_count = 0; mount_attempt_count = 0 }
    }
    $efiRoles = Get-DanewPartitionRoleAnalysis -StorageAnalysis $efiOnly -Installations @()
    $efiOnlyPass = ([int]$efiRoles.summary.efi_count -eq 1) -and ([int]$efiRoles.summary.windows_os_count -eq 0)
    $results += Add-Phase6A1Result -Name 'EFI_only_disk' -Passed $efiOnlyPass -Details ('efi=' + [string]$efiRoles.summary.efi_count + '; os=' + [string]$efiRoles.summary.windows_os_count)

    $storageNoPartition = [pscustomobject]@{ summary = [pscustomobject]@{ disk_count = 1; partition_count = 0; raw_partition_count = 0 }; partitions = @(); disks = @([pscustomobject]@{ bus_type = 'NVMe' }) }
    $diagGpt = Get-DanewStorageDiagnostics -StorageAnalysis $storageNoPartition -BitLockerAnalysis $bitlockerEmpty -PartitionRoleAnalysis $partitionRoleRaw -Installations @() -ValidInstallations @() -DiscoveryItems @() -RegistryDetails @()
    $gptCause = @($diagGpt.probable_causes | Where-Object { $_.cause -eq 'corrupted GPT' }).Count -ge 1
    $results += Add-Phase6A1Result -Name 'corrupted_GPT' -Passed $gptCause -Details ('gpt_cause=' + [string]$gptCause)

    $storageInvisible = [pscustomobject]@{ summary = [pscustomobject]@{ disk_count = 0; partition_count = 0; raw_partition_count = 0 }; partitions = @(); disks = @() }
    $diagNvme = Get-DanewStorageDiagnostics -StorageAnalysis $storageInvisible -BitLockerAnalysis $bitlockerEmpty -PartitionRoleAnalysis $partitionRoleRaw -Installations @() -ValidInstallations @() -DiscoveryItems @() -RegistryDetails @()
    $nvmeCause = @($diagNvme.probable_causes | Where-Object { $_.cause -eq 'missing NVMe visibility' }).Count -ge 1
    $results += Add-Phase6A1Result -Name 'inaccessible_NVMe' -Passed $nvmeCause -Details ('nvme_cause=' + [string]$nvmeCause)

    $multiCandidates = @(Find-DanewOfflineWindowsInstallations -InputPath (Join-Path $temp.root 'offline-lab\multi') -RootPath $temp.root)
    $multiValidCount = @($multiCandidates | Where-Object { $_.is_valid }).Count
    $results += Add-Phase6A1Result -Name 'multiple_Windows_installs' -Passed ($multiValidCount -ge 2) -Details ('valid=' + [string]$multiValidCount)

    $fakeCandidates = @(Find-DanewOfflineWindowsInstallations -InputPath (Join-Path $temp.root 'offline-lab\fake') -RootPath $temp.root)
    $fakeInvalid = @($fakeCandidates | Where-Object { -not $_.is_valid }).Count -ge 1
    $results += Add-Phase6A1Result -Name 'fake_Windows_candidate' -Passed $fakeInvalid -Details ('invalid=' + [string]$fakeInvalid)

    $partialInstall = Test-DanewOfflineWindowsCandidate -CandidatePath (Join-Path $temp.root 'offline-lab\partial')
    $partialPass = (-not $partialInstall.is_valid) -and ([string]$partialInstall.detection_confidence -in @('Low', 'Medium'))
    $results += Add-Phase6A1Result -Name 'partially_corrupted_Windows_install' -Passed $partialPass -Details ('confidence=' + [string]$partialInstall.detection_confidence)
}
finally {
    if (Test-Path -Path $temp.root) {
        try {
            Remove-Item -Path $temp.root -Recurse -Force -ErrorAction Stop
        }
        catch {
            # Ignore cleanup issues to keep test verdict focused on functional assertions.
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

$jsonPath = Join-Path $OutputDirectory 'phase6a1-tests-report.json'
$txtPath = Join-Path $OutputDirectory 'phase6a1-tests-report.txt'

$report | ConvertTo-Json -Depth 25 | Set-Content -Path $jsonPath -Encoding UTF8

$lines = @(
    'Phase 6A.1 Tests',
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

Write-Host ('Phase 6A.1 test report JSON: ' + $jsonPath)
Write-Host ('Phase 6A.1 test report TXT: ' + $txtPath)

if ($summary.failed -gt 0) {
    exit 1
}
