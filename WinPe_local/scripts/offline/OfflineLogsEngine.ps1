Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Convert-DanewOfflineTimestamp {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return ''
    }

    try {
        return ([datetime]$Value).ToString('s')
    }
    catch {
        return [string]$Value
    }
}

function Get-DanewOfflineCandidateRoots {
    param(
        [string]$InputPath,
        [string]$RootPath
    )

    $candidates = New-Object System.Collections.ArrayList
    $hasScopedInput = $false

    if (-not [string]::IsNullOrWhiteSpace($InputPath) -and (Test-Path -Path $InputPath)) {
        [void]$candidates.Add((Resolve-Path -Path $InputPath).Path)
        $hasScopedInput = $true
    }

    if (-not [string]::IsNullOrWhiteSpace($RootPath) -and (Test-Path -Path $RootPath)) {
        [void]$candidates.Add((Resolve-Path -Path $RootPath).Path)
    }

    if (-not $hasScopedInput) {
        foreach ($drive in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
            if ($drive -and $drive.Root) {
                [void]$candidates.Add($drive.Root)
            }
        }
    }

    $expanded = New-Object System.Collections.ArrayList
    foreach ($path in @($candidates)) {
        if ([string]::IsNullOrWhiteSpace([string]$path)) {
            continue
        }

        $resolved = [string]$path
        if ($resolved.Length -gt 3) {
            $resolved = $resolved.TrimEnd('\\')
        }

        [void]$expanded.Add($resolved)

        foreach ($childName in @('offline-win', 'offline', 'mnt', 'mount', 'Windows.old')) {
            $child = Join-Path $resolved $childName
            if (Test-Path -Path $child) {
                [void]$expanded.Add($child)
            }
        }

        try {
            foreach ($childDir in @(Get-ChildItem -Path $resolved -Directory -ErrorAction SilentlyContinue)) {
                if ($null -eq $childDir) {
                    continue
                }
                [void]$expanded.Add($childDir.FullName)
            }
        }
        catch {
        }
    }

    $seen = @{}
    $unique = @()
    foreach ($path in @($expanded)) {
        if ([string]::IsNullOrWhiteSpace([string]$path)) {
            continue
        }

        $key = [string]$path
        if ($key.Length -gt 3) {
            $key = $key.TrimEnd('\\')
        }
        $norm = $key.ToLowerInvariant()
        if (-not $seen.ContainsKey($norm)) {
            $seen[$norm] = $true
            $unique += $key
        }
    }

    return $unique
}

function Test-DanewOfflineWindowsCandidate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CandidatePath
    )

    $windowsDir = Join-Path $CandidatePath 'Windows'
    $system32Dir = Join-Path $windowsDir 'System32'
    $configDir = Join-Path $system32Dir 'config'
    $logsDir = Join-Path $system32Dir 'winevt\Logs'

    $hasWindows = Test-Path -Path $windowsDir
    $hasSystemHive = Test-Path -Path (Join-Path $configDir 'SYSTEM')
    $hasSoftwareHive = Test-Path -Path (Join-Path $configDir 'SOFTWARE')
    $hasLogs = Test-Path -Path $logsDir

    $isValid = $hasWindows -and ($hasSystemHive -or $hasSoftwareHive)

    $reason = 'No Windows installation found.'
    if ($hasWindows -and -not $isValid) {
        $reason = 'Windows folder exists but offline hives are missing.'
    }
    elseif ($isValid) {
        $reason = 'Offline Windows installation detected.'
    }

    return [pscustomobject]@{
        path = $CandidatePath
        windows_root = $CandidatePath
        windows_dir = $windowsDir
        system32_dir = $system32Dir
        config_dir = $configDir
        logs_dir = $logsDir
        has_windows = $hasWindows
        has_system_hive = $hasSystemHive
        has_software_hive = $hasSoftwareHive
        has_evtx_logs = $hasLogs
        is_valid = $isValid
        reason = $reason
    }
}

function Find-DanewOfflineWindowsInstallations {
    param(
        [string]$InputPath,
        [string]$RootPath
    )

    $results = @()
    foreach ($candidate in @(Get-DanewOfflineCandidateRoots -InputPath $InputPath -RootPath $RootPath)) {
        $results += Test-DanewOfflineWindowsCandidate -CandidatePath $candidate
    }

    return $results
}

function Get-DanewRegValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$KeyPath,
        [Parameter(Mandatory = $true)]
        [string]$ValueName
    )

    $out = $null
    try {
        $out = & reg.exe query $KeyPath /v $ValueName 2>&1
    }
    catch {
        return $null
    }

    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    foreach ($line in @($out)) {
        if ($line -match ('^\s*' + [regex]::Escape($ValueName) + '\s+REG_\w+\s+(.*)$')) {
            return $Matches[1].Trim()
        }
    }

    return $null
}

function Convert-DanewRegistryHexToDate {
    param(
        [AllowNull()]
        [string]$HexBytes
    )

    if ([string]::IsNullOrWhiteSpace($HexBytes)) {
        return ''
    }

    $clean = ($HexBytes -replace '\s+', '') -replace ',', ''
    if ([string]::IsNullOrWhiteSpace($clean)) {
        return ''
    }

    $parts = $clean -split '(..)' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if (@($parts).Count -lt 8) {
        return ''
    }

    $bytes = New-Object byte[] 8
    for ($i = 0; $i -lt 8; $i++) {
        $bytes[$i] = [Convert]::ToByte($parts[$i], 16)
    }

    try {
        $fileTime = [BitConverter]::ToInt64($bytes, 0)
        if ($fileTime -le 0) {
            return ''
        }
        return [datetime]::FromFileTimeUtc($fileTime).ToString('s')
    }
    catch {
        return ''
    }
}

function Invoke-DanewRegLoad {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HiveKey,
        [Parameter(Mandatory = $true)]
        [string]$HivePath
    )

    $output = $null
    try {
        $output = & reg.exe load $HiveKey $HivePath 2>&1
    }
    catch {
        return [pscustomobject]@{ loaded = $false; output = @($_.Exception.Message) }
    }

    if ($LASTEXITCODE -ne 0) {
        return [pscustomobject]@{ loaded = $false; output = @($output) }
    }

    return [pscustomobject]@{ loaded = $true; output = @($output) }
}

function Invoke-DanewRegUnload {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HiveKey
    )

    $output = $null
    try {
        $output = & reg.exe unload $HiveKey 2>&1
    }
    catch {
        return [pscustomobject]@{ ok = $false; output = @($_.Exception.Message) }
    }

    return [pscustomobject]@{ ok = ($LASTEXITCODE -eq 0); output = @($output) }
}

function Get-DanewOfflineHiveMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InstallInfo
    )

    $result = [ordered]@{
        installation_root = [string]$InstallInfo.windows_root
        status = 'WARNING'
        message = 'Registry metadata unavailable.'
        product_name = ''
        current_build = ''
        display_version = ''
        edition_id = ''
        release_id = ''
        registered_owner = ''
        computer_name = ''
        current_control_set = ''
        last_shutdown_utc = ''
        driver_hints = @()
        boot_hints = @()
    }

    $systemHivePath = Join-Path $InstallInfo.config_dir 'SYSTEM'
    $softwareHivePath = Join-Path $InstallInfo.config_dir 'SOFTWARE'

    if (-not (Test-Path -Path $systemHivePath) -and -not (Test-Path -Path $softwareHivePath)) {
        $result.message = 'SYSTEM and SOFTWARE hives are missing.'
        return [pscustomobject]$result
    }

    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $sysHiveKey = "HKLM\DANEW_${token}_SYS"
    $swHiveKey = "HKLM\DANEW_${token}_SOF"

    $sysLoaded = $false
    $swLoaded = $false
    $errors = New-Object System.Collections.ArrayList

    try {
        if (Test-Path -Path $systemHivePath) {
            $loadSys = Invoke-DanewRegLoad -HiveKey $sysHiveKey -HivePath $systemHivePath
            $sysLoaded = [bool]$loadSys.loaded
            if (-not $sysLoaded) {
                [void]$errors.Add('Failed to load SYSTEM hive.')
            }
        }

        if (Test-Path -Path $softwareHivePath) {
            $loadSw = Invoke-DanewRegLoad -HiveKey $swHiveKey -HivePath $softwareHivePath
            $swLoaded = [bool]$loadSw.loaded
            if (-not $swLoaded) {
                [void]$errors.Add('Failed to load SOFTWARE hive.')
            }
        }

        if (-not $sysLoaded -and -not $swLoaded) {
            $result.message = 'Registry hive load failed.'
            return [pscustomobject]$result
        }

        if ($swLoaded) {
            $cvKey = "$swHiveKey\Microsoft\Windows NT\CurrentVersion"
            $result.product_name = [string](Get-DanewRegValue -KeyPath $cvKey -ValueName 'ProductName')
            $result.current_build = [string](Get-DanewRegValue -KeyPath $cvKey -ValueName 'CurrentBuildNumber')
            $result.display_version = [string](Get-DanewRegValue -KeyPath $cvKey -ValueName 'DisplayVersion')
            $result.edition_id = [string](Get-DanewRegValue -KeyPath $cvKey -ValueName 'EditionID')
            $result.release_id = [string](Get-DanewRegValue -KeyPath $cvKey -ValueName 'ReleaseId')
            $result.registered_owner = [string](Get-DanewRegValue -KeyPath $cvKey -ValueName 'RegisteredOwner')
        }

        if ($sysLoaded) {
            $selectKey = "$sysHiveKey\Select"
            $current = [string](Get-DanewRegValue -KeyPath $selectKey -ValueName 'Current')
            if (-not [string]::IsNullOrWhiteSpace($current) -and ($current -as [int]) -ne $null) {
                $ccs = 'ControlSet{0:d3}' -f ([int]$current)
                $result.current_control_set = $ccs

                $compKey = "$sysHiveKey\$ccs\Control\ComputerName\ComputerName"
                $result.computer_name = [string](Get-DanewRegValue -KeyPath $compKey -ValueName 'ComputerName')

                $windowsKey = "$sysHiveKey\$ccs\Control\Windows"
                $shutdownRaw = [string](Get-DanewRegValue -KeyPath $windowsKey -ValueName 'ShutdownTime')
                $result.last_shutdown_utc = Convert-DanewRegistryHexToDate -HexBytes $shutdownRaw
            }

            $driversDir = Join-Path $InstallInfo.windows_dir 'System32\drivers'
            if (Test-Path -Path $driversDir) {
                $driverHints = @(Get-ChildItem -Path $driversDir -Filter '*.sys' -File -ErrorAction SilentlyContinue | Select-Object -First 20 -ExpandProperty Name)
                $result.driver_hints = @($driverHints)
            }

            $bootHints = @()
            foreach ($item in @(
                    (Join-Path $InstallInfo.windows_dir 'System32\winload.efi'),
                    (Join-Path $InstallInfo.windows_dir 'System32\winresume.efi')
                )) {
                if (Test-Path -Path $item) {
                    $bootHints += (Split-Path -Leaf $item)
                }
            }
            $result.boot_hints = @($bootHints)
        }

        if (@($errors).Count -gt 0) {
            $result.status = 'WARNING'
            $result.message = (@($errors) -join ' ')
        }
        else {
            $result.status = 'PASS'
            $result.message = 'Offline registry metadata extracted.'
        }

        return [pscustomobject]$result
    }
    finally {
        if ($sysLoaded) {
            $null = Invoke-DanewRegUnload -HiveKey $sysHiveKey
        }
        if ($swLoaded) {
            $null = Invoke-DanewRegUnload -HiveKey $swHiveKey
        }
    }
}

function Get-DanewExpectedEvtxMap {
    return @(
        [pscustomobject]@{ channel = 'System'; file_name = 'System.evtx'; required = $true },
        [pscustomobject]@{ channel = 'Application'; file_name = 'Application.evtx'; required = $true },
        [pscustomobject]@{ channel = 'Setup'; file_name = 'Setup.evtx'; required = $true },
        [pscustomobject]@{ channel = 'Security'; file_name = 'Security.evtx'; required = $false },
        [pscustomobject]@{ channel = 'Microsoft-Windows-Kernel-Boot/Operational'; file_name = 'Microsoft-Windows-Kernel-Boot%4Operational.evtx'; required = $false },
        [pscustomobject]@{ channel = 'Microsoft-Windows-User Profile Service/Operational'; file_name = 'Microsoft-Windows-User Profile Service%4Operational.evtx'; required = $false },
        [pscustomobject]@{ channel = 'Microsoft-Windows-AppReadiness/Admin'; file_name = 'Microsoft-Windows-AppReadiness%4Admin.evtx'; required = $false },
        [pscustomobject]@{ channel = 'Microsoft-Windows-DriverFrameworks-UserMode/Operational'; file_name = 'Microsoft-Windows-DriverFrameworks-UserMode%4Operational.evtx'; required = $false },
        [pscustomobject]@{ channel = 'Microsoft-Windows-DriverFrameworks-KernelMode/Operational'; file_name = 'Microsoft-Windows-DriverFrameworks-KernelMode%4Operational.evtx'; required = $false }
    )
}

function Get-DanewEvtxDiscovery {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InstallInfo
    )

    $items = @()
    foreach ($evtx in @(Get-DanewExpectedEvtxMap)) {
        $path = Join-Path $InstallInfo.logs_dir $evtx.file_name
        $exists = Test-Path -Path $path
        $size = 0
        $lastWrite = ''
        $status = 'missing'
        $message = ''

        if ($exists) {
            try {
                $file = Get-Item -Path $path -ErrorAction Stop
                $size = [int64]$file.Length
                $lastWrite = Convert-DanewOfflineTimestamp -Value $file.LastWriteTimeUtc

                try {
                    $null = Get-WinEvent -Path $path -MaxEvents 1 -ErrorAction Stop
                    $status = 'readable'
                    $message = 'Log is readable.'
                }
                catch {
                    $text = $_.Exception.Message
                    if ($text -match 'corrupt|damaged|invalid') {
                        $status = 'corrupted'
                    }
                    elseif ($text -match 'access is denied|permission') {
                        $status = 'inaccessible'
                    }
                    else {
                        $status = 'warning'
                    }
                    $message = $text
                }
            }
            catch {
                $status = 'inaccessible'
                $message = $_.Exception.Message
            }
        }
        else {
            if ($evtx.required) {
                $status = 'missing-required'
                $message = 'Required log is missing.'
            }
            else {
                $status = 'missing-optional'
                $message = 'Optional log is missing.'
            }
        }

        $items += [pscustomobject]@{
            installation_root = [string]$InstallInfo.windows_root
            channel = [string]$evtx.channel
            file_name = [string]$evtx.file_name
            file_path = $path
            required = [bool]$evtx.required
            exists = [bool]$exists
            size_bytes = $size
            last_modified_utc = $lastWrite
            status = $status
            message = $message
        }
    }

    return $items
}

function Convert-DanewWinEventRecord {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Eventing.Reader.EventRecord]$Event,
        [Parameter(Mandatory = $true)]
        [string]$SourceFile,
        [Parameter(Mandatory = $true)]
        [string]$InstallationRoot
    )

    $xml = $null
    try {
        $xml = [xml]$Event.ToXml()
    }
    catch {
    }

    $message = ''
    try {
        $message = [string]$Event.FormatDescription()
    }
    catch {
    }

    if ([string]::IsNullOrWhiteSpace($message) -and $xml -and $xml.Event -and $xml.Event.RenderingInfo -and $xml.Event.RenderingInfo.Message) {
        $message = [string]$xml.Event.RenderingInfo.Message
    }

    $level = [string]$Event.LevelDisplayName
    if ([string]::IsNullOrWhiteSpace($level) -and $xml -and $xml.Event -and $xml.Event.RenderingInfo -and $xml.Event.RenderingInfo.Level) {
        $level = [string]$xml.Event.RenderingInfo.Level
    }

    $task = [string]$Event.TaskDisplayName
    if ([string]::IsNullOrWhiteSpace($task) -and $xml -and $xml.Event -and $xml.Event.RenderingInfo -and $xml.Event.RenderingInfo.Task) {
        $task = [string]$xml.Event.RenderingInfo.Task
    }

    $opcode = [string]$Event.OpcodeDisplayName
    if ([string]::IsNullOrWhiteSpace($opcode) -and $xml -and $xml.Event -and $xml.Event.RenderingInfo -and $xml.Event.RenderingInfo.Opcode) {
        $opcode = [string]$xml.Event.RenderingInfo.Opcode
    }

    $keywords = ''
    try {
        if ($Event.KeywordsDisplayNames) {
            $keywords = [string](@($Event.KeywordsDisplayNames) -join '; ')
        }
    }
    catch {
    }

    if ([string]::IsNullOrWhiteSpace($keywords) -and $xml -and $xml.Event -and $xml.Event.RenderingInfo -and $xml.Event.RenderingInfo.Keywords) {
        $keywords = [string]$xml.Event.RenderingInfo.Keywords
    }

    return [pscustomobject]@{
        timestamp = Convert-DanewOfflineTimestamp -Value $Event.TimeCreated
        level = $level
        provider = [string]$Event.ProviderName
        event_id = [int]$Event.Id
        channel = [string]$Event.LogName
        computer = [string]$Event.MachineName
        task_category = $task
        opcode = $opcode
        keywords = $keywords
        message = $message
        source_file = $SourceFile
        installation_root = $InstallationRoot
    }
}

function Get-DanewEvtxEventRecords {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$DiscoveryItems,
        [int]$MaxEventsPerLog = 2000
    )

    $events = New-Object System.Collections.ArrayList
    $issues = New-Object System.Collections.ArrayList

    foreach ($item in @($DiscoveryItems)) {
        if (-not $item.exists) {
            continue
        }

        if ($item.status -in @('corrupted', 'inaccessible')) {
            [void]$issues.Add([pscustomobject]@{
                    file_path = [string]$item.file_path
                    installation_root = [string]$item.installation_root
                    issue = [string]$item.status
                    message = [string]$item.message
                })
            continue
        }

        try {
            $records = @(Get-WinEvent -Path $item.file_path -Oldest -ErrorAction Stop)
            if ($MaxEventsPerLog -gt 0 -and @($records).Count -gt $MaxEventsPerLog) {
                $records = @($records | Select-Object -First $MaxEventsPerLog)
            }

            foreach ($record in @($records)) {
                try {
                    $converted = Convert-DanewWinEventRecord -Event $record -SourceFile $item.file_path -InstallationRoot $item.installation_root
                    [void]$events.Add($converted)
                }
                catch {
                    [void]$issues.Add([pscustomobject]@{
                            file_path = [string]$item.file_path
                            installation_root = [string]$item.installation_root
                            issue = 'partial-record'
                            message = $_.Exception.Message
                        })
                }
            }
        }
        catch {
            [void]$issues.Add([pscustomobject]@{
                    file_path = [string]$item.file_path
                    installation_root = [string]$item.installation_root
                    issue = 'read-failure'
                    message = $_.Exception.Message
                })
        }
    }

    $sorted = @($events | Sort-Object timestamp, event_id)
    return [pscustomobject]@{
        events = $sorted
        issues = @($issues)
    }
}

function Get-DanewEvtxSummary {
    param(
        [object[]]$Events,
        [object[]]$DiscoveryItems,
        [object[]]$Issues
    )

    $eventsArray = @($Events)
    $discoveryArray = @($DiscoveryItems)
    $issuesArray = @($Issues)

    $levelCounts = @()
    if (@($eventsArray).Count -gt 0) {
        $levelCounts = @($eventsArray | Group-Object level | Sort-Object Count -Descending | ForEach-Object {
                [pscustomobject]@{ level = [string]$_.Name; count = [int]$_.Count }
            })
    }

    $providerCounts = @()
    if (@($eventsArray).Count -gt 0) {
        $providerCounts = @($eventsArray | Group-Object provider | Sort-Object Count -Descending | Select-Object -First 25 | ForEach-Object {
                [pscustomobject]@{ provider = [string]$_.Name; count = [int]$_.Count }
            })
    }

    $eventIdCounts = @()
    if (@($eventsArray).Count -gt 0) {
        $eventIdCounts = @($eventsArray | Group-Object event_id | Sort-Object Count -Descending | Select-Object -First 25 | ForEach-Object {
                [pscustomobject]@{ event_id = [string]$_.Name; count = [int]$_.Count }
            })
    }

    return [pscustomobject]@{
        total_discovered_logs = @($discoveryArray).Count
        missing_required_logs = @($discoveryArray | Where-Object { $_.status -eq 'missing-required' }).Count
        inaccessible_logs = @($discoveryArray | Where-Object { $_.status -in @('inaccessible', 'corrupted') }).Count
        total_events = @($eventsArray).Count
        parse_issue_count = @($issuesArray).Count
        levels = $levelCounts
        providers = $providerCounts
        event_ids = $eventIdCounts
    }
}

function ConvertTo-DanewCsvFriendly {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return ''
    }

    return [string]$Value
}

function Write-DanewTimelineHtml {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [object[]]$Events,
        [object]$Summary
    )

    $rows = @()
    $index = 0
    foreach ($event in @($Events)) {
        $index += 1
        if ($index -gt 4000) {
            break
        }

        $rows += @"
<tr>
<td>$([System.Security.SecurityElement]::Escape([string]$event.timestamp))</td>
<td>$([System.Security.SecurityElement]::Escape([string]$event.level))</td>
<td>$([System.Security.SecurityElement]::Escape([string]$event.provider))</td>
<td>$([System.Security.SecurityElement]::Escape([string]$event.event_id))</td>
<td>$([System.Security.SecurityElement]::Escape([string]$event.channel))</td>
<td>$([System.Security.SecurityElement]::Escape([string]$event.source_file))</td>
<td>$([System.Security.SecurityElement]::Escape([string]$event.message))</td>
</tr>
"@
    }

    $notice = ''
    if (@($Events).Count -gt 4000) {
        $notice = '<p><b>Note:</b> HTML view truncated to first 4000 events. Full data is available in timeline-raw.json.</p>'
    }

    $html = @"
<html>
<head>
<title>Danew Offline Timeline</title>
<style>
body { font-family: Segoe UI, Arial, sans-serif; background: #f7f9fb; color: #1f2937; margin: 20px; }
.card { background: #ffffff; border: 1px solid #d9e2ec; border-radius: 10px; padding: 14px 16px; margin-bottom: 12px; }
table { width: 100%; border-collapse: collapse; }
th, td { border: 1px solid #d9e2ec; padding: 6px 8px; text-align: left; vertical-align: top; font-size: 12px; }
th { background: #eef3f8; }
</style>
</head>
<body>
<div class="card">
<h2>Danew Offline Timeline</h2>
<p>Total events: $($Summary.total_events)</p>
<p>Missing required logs: $($Summary.missing_required_logs)</p>
<p>Parse issues: $($Summary.parse_issue_count)</p>
$notice
</div>
<div class="card">
<table>
<thead>
<tr><th>Timestamp</th><th>Level</th><th>Provider</th><th>Event ID</th><th>Channel</th><th>Source File</th><th>Message</th></tr>
</thead>
<tbody>
$rows
</tbody>
</table>
</div>
</body>
</html>
"@

    $html | Set-Content -Path $Path -Encoding UTF8
}

function Invoke-DanewOfflineLogsAnalysis {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [Parameter(Mandatory = $true)]
        [object]$Config,
        [int]$MaxEventsPerLog = 2000
    )

    if (-not (Test-Path -Path $Config.reports_path)) {
        New-Item -Path $Config.reports_path -ItemType Directory -Force | Out-Null
    }

    $analysisPath = Join-Path $Config.reports_path 'offline-windows-analysis.json'
    $discoveryPath = Join-Path $Config.reports_path 'evtx-discovery.json'
    $eventsPath = Join-Path $Config.reports_path 'evtx-events.json'
    $eventsCsvPath = Join-Path $Config.reports_path 'evtx-events.csv'
    $summaryPath = Join-Path $Config.reports_path 'evtx-summary.json'
    $timelineJsonPath = Join-Path $Config.reports_path 'timeline-raw.json'
    $timelineHtmlPath = Join-Path $Config.reports_path 'timeline-raw.html'

    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList

    $installations = @()
    try {
        $installations = @(Find-DanewOfflineWindowsInstallations -InputPath $Config.input_path -RootPath $RootPath)
    }
    catch {
        [void]$errors.Add('Offline Windows discovery failed: ' + $_.Exception.Message)
    }

    $validInstallations = @($installations | Where-Object { $_.is_valid })
    if (@($validInstallations).Count -eq 0) {
        [void]$warnings.Add('No valid offline Windows installation detected.')
    }

    $registryDetails = @()
    $discoveryItems = @()

    foreach ($install in @($validInstallations)) {
        try {
            $registryItem = Get-DanewOfflineHiveMetadata -InstallInfo $install
            $registryDetails += $registryItem
            if ($registryItem.status -ne 'PASS') {
                [void]$warnings.Add('Registry warning for ' + [string]$install.windows_root + ': ' + [string]$registryItem.message)
            }
        }
        catch {
            [void]$errors.Add('Registry extraction failed for ' + [string]$install.windows_root + ': ' + $_.Exception.Message)
        }

        try {
            $discoveryItems += @(Get-DanewEvtxDiscovery -InstallInfo $install)
        }
        catch {
            [void]$errors.Add('EVTX discovery failed for ' + [string]$install.windows_root + ': ' + $_.Exception.Message)
        }
    }

    foreach ($entry in @($discoveryItems)) {
        if ($entry.status -eq 'missing-required') {
            [void]$warnings.Add('Missing required EVTX log: ' + [string]$entry.file_path)
        }
        elseif ($entry.status -eq 'inaccessible') {
            [void]$warnings.Add('Inaccessible EVTX log: ' + [string]$entry.file_path)
        }
        elseif ($entry.status -eq 'corrupted') {
            [void]$warnings.Add('Corrupted EVTX log: ' + [string]$entry.file_path)
        }
    }

    $parseResult = [pscustomobject]@{ events = @(); issues = @() }
    try {
        $parseResult = Get-DanewEvtxEventRecords -DiscoveryItems $discoveryItems -MaxEventsPerLog $MaxEventsPerLog
    }
    catch {
        [void]$errors.Add('EVTX parsing failed: ' + $_.Exception.Message)
    }

    $events = @($parseResult.events)
    $issues = @($parseResult.issues)

    foreach ($issue in @($issues)) {
        if ($issue.issue -eq 'partial-record') {
            [void]$warnings.Add('Partial record detected in ' + [string]$issue.file_path)
        }
        else {
            [void]$warnings.Add('EVTX issue in ' + [string]$issue.file_path + ': ' + [string]$issue.issue)
        }
    }

    $summary = Get-DanewEvtxSummary -Events $events -DiscoveryItems $discoveryItems -Issues $issues

    $analysis = [pscustomobject]@{
        timestamp = (Get-Date).ToString('s')
        root_path = $RootPath
        input_path = $Config.input_path
        installation_candidates = $installations
        valid_installations = $validInstallations
        registry_metadata = $registryDetails
        warning_count = @($warnings).Count
        error_count = @($errors).Count
        warnings = @($warnings)
        errors = @($errors)
    }

    $timeline = [pscustomobject]@{
        timestamp = (Get-Date).ToString('s')
        events = $events
        issues = $issues
    }

    $analysis | ConvertTo-Json -Depth 40 | Set-Content -Path $analysisPath -Encoding UTF8
    @($discoveryItems) | ConvertTo-Json -Depth 30 | Set-Content -Path $discoveryPath -Encoding UTF8
    @($events) | ConvertTo-Json -Depth 30 | Set-Content -Path $eventsPath -Encoding UTF8

    $csvRows = @($events | Select-Object timestamp, level, provider, event_id, channel, computer, task_category, opcode, keywords, source_file, installation_root, message)
    if (@($csvRows).Count -gt 0) {
        $csvRows | Export-Csv -Path $eventsCsvPath -NoTypeInformation -Encoding UTF8
    }
    else {
        'timestamp,level,provider,event_id,channel,computer,task_category,opcode,keywords,source_file,installation_root,message' | Set-Content -Path $eventsCsvPath -Encoding ASCII
    }

    $summary | ConvertTo-Json -Depth 20 | Set-Content -Path $summaryPath -Encoding UTF8
    $timeline | ConvertTo-Json -Depth 40 | Set-Content -Path $timelineJsonPath -Encoding UTF8
    Write-DanewTimelineHtml -Path $timelineHtmlPath -Events $events -Summary $summary

    $overall = 'PASS'
    if (@($errors).Count -gt 0) {
        $overall = 'FAIL'
    }
    elseif (@($warnings).Count -gt 0) {
        $overall = 'WARNING'
    }

    return [pscustomobject]@{
        overall_status = $overall
        summary = $summary
        warnings = @($warnings)
        errors = @($errors)
        artifacts = [pscustomobject]@{
            offline_windows_analysis = $analysisPath
            evtx_discovery = $discoveryPath
            evtx_events_json = $eventsPath
            evtx_events_csv = $eventsCsvPath
            evtx_summary = $summaryPath
            timeline_raw_json = $timelineJsonPath
            timeline_raw_html = $timelineHtmlPath
        }
    }
}
