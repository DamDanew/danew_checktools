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

function Add-Phase6AResult {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Details = ''
    )

    return [pscustomobject]@{ name = $Name; passed = $Passed; details = $Details }
}

function New-Phase6ATestRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath
    )

    $tempRoot = Join-Path $BasePath 'temp\phase6a-tests'
    if (Test-Path -Path $tempRoot) {
        Remove-Item -Path $tempRoot -Recurse -Force
    }

    New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null
    foreach ($folder in @('scripts', 'reports', 'logs', 'offline-lab', 'offline-lab\fake-only\candidate-1\Windows', 'offline-lab\fake-only\candidate-1\Windows\System32', 'offline-lab\multi\install-1\Windows\System32\config', 'offline-lab\multi\install-1\Windows\System32\winevt\Logs', 'offline-lab\multi\install-2\Windows\System32\config', 'offline-lab\multi\install-2\Windows\System32\winevt\Logs', 'offline-lab\invalid-hive\Windows\System32\config', 'offline-lab\missing-system\Windows\System32\config', 'offline-lab\missing-system\Windows\System32\winevt\Logs')) {
        New-Item -Path (Join-Path $tempRoot $folder) -ItemType Directory -Force | Out-Null
    }

    Copy-Item -Path (Join-Path $BasePath 'scripts\*') -Destination (Join-Path $tempRoot 'scripts') -Recurse -Force

    # Fake Windows candidate: has Windows directory but no hives (should be detected as invalid)
    Set-Content -Path (Join-Path $tempRoot 'offline-lab\fake-only\candidate-1\Windows\System32\.danew-marker') -Value 'detected' -Encoding ASCII

    # Multiple valid installs: create minimal hives + marker binaries
    Set-Content -Path (Join-Path $tempRoot 'offline-lab\multi\install-1\Windows\System32\config\SYSTEM') -Value 'hive' -Encoding ASCII
    Set-Content -Path (Join-Path $tempRoot 'offline-lab\multi\install-1\Windows\System32\config\SOFTWARE') -Value 'hive' -Encoding ASCII
    Set-Content -Path (Join-Path $tempRoot 'offline-lab\multi\install-1\Windows\System32\explorer.exe') -Value 'bin' -Encoding ASCII
    Set-Content -Path (Join-Path $tempRoot 'offline-lab\multi\install-1\Windows\System32\ntoskrnl.exe') -Value 'bin' -Encoding ASCII

    Set-Content -Path (Join-Path $tempRoot 'offline-lab\multi\install-2\Windows\System32\config\SYSTEM') -Value 'hive' -Encoding ASCII
    Set-Content -Path (Join-Path $tempRoot 'offline-lab\multi\install-2\Windows\System32\config\SOFTWARE') -Value 'hive' -Encoding ASCII
    Set-Content -Path (Join-Path $tempRoot 'offline-lab\multi\install-2\Windows\System32\explorer.exe') -Value 'bin' -Encoding ASCII
    Set-Content -Path (Join-Path $tempRoot 'offline-lab\multi\install-2\Windows\System32\ntoskrnl.exe') -Value 'bin' -Encoding ASCII

    Set-Content -Path (Join-Path $tempRoot 'offline-lab\invalid-hive\Windows\System32\config\SYSTEM') -Value 'not-a-real-hive' -Encoding ASCII
    Set-Content -Path (Join-Path $tempRoot 'offline-lab\invalid-hive\Windows\System32\config\SOFTWARE') -Value 'not-a-real-hive' -Encoding ASCII

    Set-Content -Path (Join-Path $tempRoot 'offline-lab\missing-system\Windows\System32\config\SYSTEM') -Value 'hive' -Encoding ASCII
    Set-Content -Path (Join-Path $tempRoot 'offline-lab\missing-system\Windows\System32\config\SOFTWARE') -Value 'hive' -Encoding ASCII
    Set-Content -Path (Join-Path $tempRoot 'offline-lab\missing-system\Windows\System32\winevt\Logs\Application.evtx') -Value 'dummy' -Encoding ASCII

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

function New-InstallInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot
    )

    return [pscustomobject]@{
        path = $InstallRoot
        windows_root = $InstallRoot
        windows_dir = Join-Path $InstallRoot 'Windows'
        system32_dir = Join-Path $InstallRoot 'Windows\System32'
        config_dir = Join-Path $InstallRoot 'Windows\System32\config'
        logs_dir = Join-Path $InstallRoot 'Windows\System32\winevt\Logs'
        has_windows = $true
        has_system_hive = $true
        has_software_hive = $true
        has_evtx_logs = $true
        is_valid = $true
        reason = 'Offline Windows installation detected.'
    }
}

function Invoke-WithOfflineOverrides {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,
        [scriptblock]$FindOverride,
        [scriptblock]$RegistryOverride,
        [scriptblock]$DiscoveryOverride,
        [scriptblock]$EventsOverride
    )

    $originalFind = $null
    $originalRegistry = $null
    $originalDiscovery = $null
    $originalEvents = $null

    if (Get-Command -Name Find-DanewOfflineWindowsInstallations -ErrorAction SilentlyContinue) {
        $originalFind = ${function:script:Find-DanewOfflineWindowsInstallations}
    }
    if (Get-Command -Name Get-DanewOfflineHiveMetadata -ErrorAction SilentlyContinue) {
        $originalRegistry = ${function:script:Get-DanewOfflineHiveMetadata}
    }
    if (Get-Command -Name Get-DanewEvtxDiscovery -ErrorAction SilentlyContinue) {
        $originalDiscovery = ${function:script:Get-DanewEvtxDiscovery}
    }
    if (Get-Command -Name Get-DanewEvtxEventRecords -ErrorAction SilentlyContinue) {
        $originalEvents = ${function:script:Get-DanewEvtxEventRecords}
    }

    try {
        if ($FindOverride) {
            Set-Item -Path function:script:Find-DanewOfflineWindowsInstallations -Value $FindOverride
        }
        if ($RegistryOverride) {
            Set-Item -Path function:script:Get-DanewOfflineHiveMetadata -Value $RegistryOverride
        }
        if ($DiscoveryOverride) {
            Set-Item -Path function:script:Get-DanewEvtxDiscovery -Value $DiscoveryOverride
        }
        if ($EventsOverride) {
            Set-Item -Path function:script:Get-DanewEvtxEventRecords -Value $EventsOverride
        }

        & $Action
    }
    finally {
        if ($null -ne $originalFind) {
            Set-Item -Path function:script:Find-DanewOfflineWindowsInstallations -Value $originalFind
        }
        if ($null -ne $originalRegistry) {
            Set-Item -Path function:script:Get-DanewOfflineHiveMetadata -Value $originalRegistry
        }
        if ($null -ne $originalDiscovery) {
            Set-Item -Path function:script:Get-DanewEvtxDiscovery -Value $originalDiscovery
        }
        if ($null -ne $originalEvents) {
            Set-Item -Path function:script:Get-DanewEvtxEventRecords -Value $originalEvents
        }
    }
}

function New-FakeEvent {
    param(
        [int]$Index,
        [string]$InstallRoot,
        [string]$SourceFile
    )

    return [pscustomobject]@{
        timestamp = (Get-Date).AddMinutes($Index).ToString('s')
        level = 'Information'
        provider = 'Danew-Test'
        event_id = 1000 + $Index
        channel = 'System'
        computer = 'OFFLINE-PC'
        task_category = 'Test'
        opcode = 'Info'
        keywords = 'None'
        message = 'Synthetic event ' + [string]$Index
        source_file = $SourceFile
        installation_root = $InstallRoot
    }
}

$results = @()
$temp = New-Phase6ATestRoot -BasePath $RootPath

try {
    . (Join-Path $temp.root 'scripts\launcher\LauncherCore.ps1')

    $config = Get-DanewLauncherConfig -RootPath $temp.root -ConfigPath $temp.config_path
    Initialize-DanewLauncherPaths -Config $config

    $validRoot = Join-Path $temp.root 'offline-lab\multi\install-1'
    $installInfo = New-InstallInfo -InstallRoot $validRoot
    $sourceFile = Join-Path $installInfo.logs_dir 'System.evtx'

    $validCase = Invoke-WithOfflineOverrides -Action {
        Invoke-DanewLauncherAction -Action 'analyze-offline-logs' -RootPath $temp.root -Config $config
    } -FindOverride {
        param([string]$InputPath, [string]$RootPath)
        return @($installInfo)
    } -RegistryOverride {
        param([object]$InstallInfo)
        return [pscustomobject]@{
            installation_root = [string]$InstallInfo.windows_root
            status = 'PASS'
            message = 'ok'
            product_name = 'Windows 11 Pro'
            current_build = '22631'
            display_version = '23H2'
            edition_id = 'Professional'
            release_id = '2009'
            registered_owner = 'Danew'
            computer_name = 'OFFLINE-PC'
            current_control_set = 'ControlSet001'
            last_shutdown_utc = ''
            driver_hints = @('disk.sys')
            boot_hints = @('winload.efi')
        }
    } -DiscoveryOverride {
        param([object]$InstallInfo)
        return @([pscustomobject]@{
                installation_root = [string]$InstallInfo.windows_root
                channel = 'System'
                file_name = 'System.evtx'
                file_path = $sourceFile
                required = $true
                exists = $true
                size_bytes = 1024
                last_modified_utc = (Get-Date).ToString('s')
                status = 'readable'
                message = 'ok'
            })
    } -EventsOverride {
        param([object[]]$DiscoveryItems, [int]$MaxEventsPerLog)
        return [pscustomobject]@{
            events = @((New-FakeEvent -Index 1 -InstallRoot $installInfo.windows_root -SourceFile $sourceFile))
            issues = @()
        }
    }

    $validOutput = $validCase.output
    $validPass = ($validOutput.overall_status -eq 'PASS') -and ($validOutput.summary.total_events -eq 1) -and (Test-Path -Path $validOutput.artifacts.timeline_raw_html)
    $results += Add-Phase6AResult -Name 'valid_evtx' -Passed $validPass -Details ([string]$validOutput.overall_status + '; events=' + [string]$validOutput.summary.total_events)

    $fastCase = Invoke-WithOfflineOverrides -Action {
        Invoke-DanewLauncherAction -Action 'analyze-offline-logs-fast' -RootPath $temp.root -Config $config
    } -FindOverride {
        param([string]$InputPath, [string]$RootPath)
        return @($installInfo)
    } -RegistryOverride {
        param([object]$InstallInfo)
        return [pscustomobject]@{
            installation_root = [string]$InstallInfo.windows_root
            status = 'PASS'
            message = 'ok'
            product_name = 'Windows 11 Pro'
            current_build = '26100'
            display_version = '24H2'
            edition_id = 'Professional'
            release_id = '24H2'
            registered_owner = 'Danew'
            computer_name = 'OFFLINE-PC'
            current_control_set = 'ControlSet001'
            last_shutdown_utc = ''
            driver_hints = @('disk.sys')
            boot_hints = @('winload.efi')
        }
    } -DiscoveryOverride {
        param([object]$InstallInfo)
        return @([pscustomobject]@{
                installation_root = [string]$InstallInfo.windows_root
                channel = 'System'
                file_name = 'System.evtx'
                file_path = $sourceFile
                required = $true
                exists = $true
                size_bytes = 1024
                last_modified_utc = (Get-Date).ToString('s')
                status = 'readable'
                message = 'ok'
            })
    } -EventsOverride {
        param([object[]]$DiscoveryItems, [int]$MaxEventsPerLog)
        return [pscustomobject]@{
            events = @((New-FakeEvent -Index 1 -InstallRoot $installInfo.windows_root -SourceFile $sourceFile))
            issues = @()
        }
    }

    $fastOutput = $fastCase.output
    $fastTimelineHtml = Get-Content -Path $fastOutput.artifacts.timeline_raw_html -Raw -Encoding UTF8
    $fastPass = ($fastOutput.overall_status -eq 'PASS') -and (Test-Path -Path $fastOutput.artifacts.timeline_raw_html) -and ($fastTimelineHtml -match 'Mode rapide optimise') -and ($fastTimelineHtml -match 'evtx-by-file.html')
    $results += Add-Phase6AResult -Name 'fast_mode_writes_lightweight_timeline_html' -Passed $fastPass -Details 'fast analysis writes lightweight timeline shell with by-file link'

    $corruptedCase = Invoke-WithOfflineOverrides -Action {
        Invoke-DanewLauncherAction -Action 'analyze-offline-logs' -RootPath $temp.root -Config $config
    } -FindOverride {
        param([string]$InputPath, [string]$RootPath)
        return @($installInfo)
    } -RegistryOverride {
        param([object]$InstallInfo)
        return [pscustomobject]@{ installation_root = [string]$InstallInfo.windows_root; status = 'PASS'; message = 'ok'; product_name = ''; current_build = ''; display_version = ''; edition_id = ''; release_id = ''; registered_owner = ''; computer_name = ''; current_control_set = ''; last_shutdown_utc = ''; driver_hints = @(); boot_hints = @() }
    } -DiscoveryOverride {
        param([object]$InstallInfo)
        return @([pscustomobject]@{
                installation_root = [string]$InstallInfo.windows_root
                channel = 'System'
                file_name = 'System.evtx'
                file_path = $sourceFile
                required = $true
                exists = $true
                size_bytes = 2048
                last_modified_utc = (Get-Date).ToString('s')
                status = 'corrupted'
                message = 'corrupted file'
            })
    } -EventsOverride {
        param([object[]]$DiscoveryItems, [int]$MaxEventsPerLog)
        return [pscustomobject]@{
            events = @()
            issues = @([pscustomobject]@{ file_path = $sourceFile; installation_root = $installInfo.windows_root; issue = 'read-failure'; message = 'corrupted' })
        }
    }

    $corruptedOutput = $corruptedCase.output
    $corruptedPass = ($corruptedOutput.overall_status -eq 'WARNING') -and ($corruptedOutput.summary.parse_issue_count -ge 1)
    $results += Add-Phase6AResult -Name 'corrupted_evtx' -Passed $corruptedPass -Details ('overall=' + [string]$corruptedOutput.overall_status + '; issues=' + [string]$corruptedOutput.summary.parse_issue_count)

    $missingInstall = Test-DanewOfflineWindowsCandidate -CandidatePath (Join-Path $temp.root 'offline-lab\missing-system')
    $missingDiscovery = @(Get-DanewEvtxDiscovery -InstallInfo $missingInstall)
    $missingSystem = @($missingDiscovery | Where-Object { $_.file_name -eq 'System.evtx' } | Select-Object -First 1)
    $missingPass = ($null -ne $missingSystem) -and ($missingSystem.status -eq 'missing-required')
    $results += Add-Phase6AResult -Name 'missing_system_evtx' -Passed $missingPass -Details ([string]$missingSystem.status)

    $inaccessibleCase = Invoke-WithOfflineOverrides -Action {
        Invoke-DanewLauncherAction -Action 'analyze-offline-logs' -RootPath $temp.root -Config $config
    } -FindOverride {
        param([string]$InputPath, [string]$RootPath)
        return @($installInfo)
    } -RegistryOverride {
        param([object]$InstallInfo)
        return [pscustomobject]@{ installation_root = [string]$InstallInfo.windows_root; status = 'PASS'; message = 'ok'; product_name = ''; current_build = ''; display_version = ''; edition_id = ''; release_id = ''; registered_owner = ''; computer_name = ''; current_control_set = ''; last_shutdown_utc = ''; driver_hints = @(); boot_hints = @() }
    } -DiscoveryOverride {
        param([object]$InstallInfo)
        return @([pscustomobject]@{
                installation_root = [string]$InstallInfo.windows_root
                channel = 'System'
                file_name = 'System.evtx'
                file_path = $sourceFile
                required = $true
                exists = $true
                size_bytes = 0
                last_modified_utc = ''
                status = 'inaccessible'
                message = 'access denied'
            })
    } -EventsOverride {
        param([object[]]$DiscoveryItems, [int]$MaxEventsPerLog)
        return [pscustomobject]@{ events = @(); issues = @() }
    }

    $inaccessibleOutput = $inaccessibleCase.output
    $inaccessiblePass = ($inaccessibleOutput.overall_status -eq 'WARNING') -and ($inaccessibleOutput.summary.inaccessible_logs -ge 1)
    $results += Add-Phase6AResult -Name 'inaccessible_logs' -Passed $inaccessiblePass -Details ('overall=' + [string]$inaccessibleOutput.overall_status + '; inaccessible=' + [string]$inaccessibleOutput.summary.inaccessible_logs)

    $fakeCandidates = @(Find-DanewOfflineWindowsInstallations -InputPath (Join-Path $temp.root 'offline-lab\fake-only') -RootPath $temp.root)
    $fakeMatch = @($fakeCandidates | Where-Object { $_.has_windows -and -not $_.is_valid })
    $fakeQuality = @($fakeMatch | Where-Object {
            $_.acceptance_status -eq 'rejected' -and
            -not [string]::IsNullOrWhiteSpace([string]$_.rejection_reason) -and
            $_.PSObject.Properties['evidence_score'] -and
            $_.PSObject.Properties['detection_confidence'] -and
            $_.PSObject.Properties['selected_as_preferred']
        })
    $results += Add-Phase6AResult -Name 'fake_windows_install' -Passed (@($fakeQuality).Count -ge 1) -Details ('matches=' + [string](@($fakeQuality).Count))

    $multiCandidates = @(Find-DanewOfflineWindowsInstallations -InputPath (Join-Path $temp.root 'offline-lab\multi') -RootPath $temp.root)
    $multiValid = @($multiCandidates | Where-Object { $_.is_valid })
    $preferred = @($multiCandidates | Where-Object { $_.selected_as_preferred })
    $topScore = if (@($multiCandidates).Count -gt 0) { ($multiCandidates | Measure-Object -Property evidence_score -Maximum).Maximum } else { -1 }
    $preferredTop = @($preferred | Where-Object { $_.evidence_score -eq $topScore -and $_.acceptance_status -eq 'accepted' })
    $multiHasSchema = @($multiCandidates | Where-Object {
            $_.PSObject.Properties['evidence_score'] -and
            $_.PSObject.Properties['detection_confidence'] -and
            $_.PSObject.Properties['acceptance_status'] -and
            $_.PSObject.Properties['rejection_reason'] -and
            $_.PSObject.Properties['selected_as_preferred']
        }).Count -eq @($multiCandidates).Count
    $multiPass = (@($multiValid).Count -ge 2) -and (@($preferred).Count -eq 1) -and (@($preferredTop).Count -eq 1) -and $multiHasSchema
    $results += Add-Phase6AResult -Name 'multiple_installs' -Passed $multiPass -Details ('valid=' + [string](@($multiValid).Count) + '; preferred=' + [string](@($preferred).Count))

    $invalidInstall = Test-DanewOfflineWindowsCandidate -CandidatePath (Join-Path $temp.root 'offline-lab\invalid-hive')
    $invalidRegistry = Get-DanewOfflineHiveMetadata -InstallInfo $invalidInstall
    $invalidPass = ($invalidRegistry.status -eq 'WARNING')
    $results += Add-Phase6AResult -Name 'invalid_hive' -Passed $invalidPass -Details ([string]$invalidRegistry.message)

    $partialCase = Invoke-WithOfflineOverrides -Action {
        Invoke-DanewLauncherAction -Action 'analyze-offline-logs' -RootPath $temp.root -Config $config
    } -FindOverride {
        param([string]$InputPath, [string]$RootPath)
        return @($installInfo)
    } -RegistryOverride {
        param([object]$InstallInfo)
        return [pscustomobject]@{ installation_root = [string]$InstallInfo.windows_root; status = 'PASS'; message = 'ok'; product_name = ''; current_build = ''; display_version = ''; edition_id = ''; release_id = ''; registered_owner = ''; computer_name = ''; current_control_set = ''; last_shutdown_utc = ''; driver_hints = @(); boot_hints = @() }
    } -DiscoveryOverride {
        param([object]$InstallInfo)
        return @([pscustomobject]@{
                installation_root = [string]$InstallInfo.windows_root
                channel = 'System'
                file_name = 'System.evtx'
                file_path = $sourceFile
                required = $true
                exists = $true
                size_bytes = 500
                last_modified_utc = (Get-Date).ToString('s')
                status = 'readable'
                message = 'ok'
            })
    } -EventsOverride {
        param([object[]]$DiscoveryItems, [int]$MaxEventsPerLog)
        return [pscustomobject]@{
            events = @(
                (New-FakeEvent -Index 1 -InstallRoot $installInfo.windows_root -SourceFile $sourceFile),
                (New-FakeEvent -Index 2 -InstallRoot $installInfo.windows_root -SourceFile $sourceFile)
            )
            issues = @([pscustomobject]@{ file_path = $sourceFile; installation_root = $installInfo.windows_root; issue = 'partial-record'; message = 'one record skipped' })
        }
    }

    $partialOutput = $partialCase.output
    $partialPass = ($partialOutput.overall_status -eq 'WARNING') -and ($partialOutput.summary.parse_issue_count -ge 1) -and ($partialOutput.summary.total_events -eq 2)
    $results += Add-Phase6AResult -Name 'partial_records' -Passed $partialPass -Details ('events=' + [string]$partialOutput.summary.total_events + '; issues=' + [string]$partialOutput.summary.parse_issue_count)

    $largeCase = Invoke-WithOfflineOverrides -Action {
        Invoke-DanewLauncherAction -Action 'analyze-offline-logs' -RootPath $temp.root -Config $config
    } -FindOverride {
        param([string]$InputPath, [string]$RootPath)
        return @($installInfo)
    } -RegistryOverride {
        param([object]$InstallInfo)
        return [pscustomobject]@{ installation_root = [string]$InstallInfo.windows_root; status = 'PASS'; message = 'ok'; product_name = ''; current_build = ''; display_version = ''; edition_id = ''; release_id = ''; registered_owner = ''; computer_name = ''; current_control_set = ''; last_shutdown_utc = ''; driver_hints = @(); boot_hints = @() }
    } -DiscoveryOverride {
        param([object]$InstallInfo)
        return @([pscustomobject]@{
                installation_root = [string]$InstallInfo.windows_root
                channel = 'System'
                file_name = 'System.evtx'
                file_path = $sourceFile
                required = $true
                exists = $true
                size_bytes = 999999
                last_modified_utc = (Get-Date).ToString('s')
                status = 'readable'
                message = 'ok'
            })
    } -EventsOverride {
        param([object[]]$DiscoveryItems, [int]$MaxEventsPerLog)
        $many = @()
        for ($i = 1; $i -le 1200; $i++) {
            $many += New-FakeEvent -Index $i -InstallRoot $installInfo.windows_root -SourceFile $sourceFile
        }
        return [pscustomobject]@{ events = $many; issues = @() }
    }

    $largeOutput = $largeCase.output
    $largeCsv = [string]$largeOutput.artifacts.evtx_events_csv
    $csvLineCount = 0
    if (Test-Path -Path $largeCsv) {
        $csvLineCount = @(Get-Content -Path $largeCsv -Encoding UTF8).Count
    }
    $largePass = ($largeOutput.summary.total_events -eq 1200) -and (Test-Path -Path $largeCsv) -and ($csvLineCount -gt 1000)
    $results += Add-Phase6AResult -Name 'large_evtx' -Passed $largePass -Details ('events=' + [string]$largeOutput.summary.total_events + '; csv_lines=' + [string]$csvLineCount)
}
finally {
    if (Test-Path -Path $temp.root) {
        Remove-Item -Path $temp.root -Recurse -Force
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

$jsonPath = Join-Path $OutputDirectory 'phase6a-tests-report.json'
$txtPath = Join-Path $OutputDirectory 'phase6a-tests-report.txt'

$report | ConvertTo-Json -Depth 25 | Set-Content -Path $jsonPath -Encoding UTF8

$lines = @(
    'Phase 6A Tests',
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

Write-Host ('Phase 6A test report JSON: ' + $jsonPath)
Write-Host ('Phase 6A test report TXT: ' + $txtPath)

if ($summary.failed -gt 0) {
    exit 1
}
