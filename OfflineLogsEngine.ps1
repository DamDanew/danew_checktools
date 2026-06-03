Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$reportShellPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'report\HtmlReportShell.ps1'
if (Test-Path -Path $reportShellPath) {
    . $reportShellPath
}

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

    $hasWindows = $false
    $hasSystemHive = $false
    $hasSoftwareHive = $false
    $hasLogs = $false
    $hasExplorer = $false
    $hasKernel = $false
    $probeErrors = New-Object System.Collections.ArrayList

    try { $hasWindows = Test-Path -Path $windowsDir -ErrorAction Stop }
    catch { [void]$probeErrors.Add('Windows folder inaccessible: ' + $_.Exception.Message) }

    try { $hasSystemHive = Test-Path -Path (Join-Path $configDir 'SYSTEM') -ErrorAction Stop }
    catch { [void]$probeErrors.Add('SYSTEM hive inaccessible: ' + $_.Exception.Message) }

    try { $hasSoftwareHive = Test-Path -Path (Join-Path $configDir 'SOFTWARE') -ErrorAction Stop }
    catch { [void]$probeErrors.Add('SOFTWARE hive inaccessible: ' + $_.Exception.Message) }

    try { $hasLogs = Test-Path -Path $logsDir -ErrorAction Stop }
    catch { [void]$probeErrors.Add('EVTX logs inaccessible: ' + $_.Exception.Message) }

    try { $hasExplorer = Test-Path -Path (Join-Path $windowsDir 'explorer.exe') -ErrorAction Stop }
    catch { [void]$probeErrors.Add('explorer.exe inaccessible: ' + $_.Exception.Message) }

    try { $hasKernel = Test-Path -Path (Join-Path $system32Dir 'ntoskrnl.exe') -ErrorAction Stop }
    catch { [void]$probeErrors.Add('ntoskrnl.exe inaccessible: ' + $_.Exception.Message) }

    $score = 0
    if ($hasWindows) { $score += 20 }
    if ($hasSystemHive) { $score += 25 }
    if ($hasSoftwareHive) { $score += 20 }
    if ($hasLogs) { $score += 15 }
    if ($hasExplorer) { $score += 10 }
    if ($hasKernel) { $score += 10 }

    $confidence = 'Low'
    if ($score -ge 80) {
        $confidence = 'High'
    }
    elseif ($score -ge 50) {
        $confidence = 'Medium'
    }

    $acceptanceReasons = New-Object System.Collections.ArrayList
    if ($hasWindows) { [void]$acceptanceReasons.Add('Windows directory detected.') }
    if ($hasSystemHive) { [void]$acceptanceReasons.Add('SYSTEM hive detected.') }
    if ($hasSoftwareHive) { [void]$acceptanceReasons.Add('SOFTWARE hive detected.') }
    if ($hasLogs) { [void]$acceptanceReasons.Add('EVTX logs directory detected.') }
    if ($hasExplorer) { [void]$acceptanceReasons.Add('explorer.exe detected.') }
    if ($hasKernel) { [void]$acceptanceReasons.Add('ntoskrnl.exe detected.') }

    $rejectionReasons = New-Object System.Collections.ArrayList
    if (-not $hasWindows) { [void]$rejectionReasons.Add('Windows directory is missing or inaccessible.') }
    if (-not $hasSystemHive) { [void]$rejectionReasons.Add('SYSTEM hive is missing or inaccessible.') }
    if (-not $hasSoftwareHive) { [void]$rejectionReasons.Add('SOFTWARE hive is missing or inaccessible.') }
    if (-not $hasLogs) { [void]$rejectionReasons.Add('EVTX logs directory is missing or inaccessible.') }
    if (-not $hasExplorer) { [void]$rejectionReasons.Add('explorer.exe is missing.') }
    if (-not $hasKernel) { [void]$rejectionReasons.Add('ntoskrnl.exe is missing.') }
    foreach ($err in @($probeErrors)) {
        [void]$rejectionReasons.Add([string]$err)
    }

    $isValid = $hasWindows -and $hasSystemHive -and $hasSoftwareHive

    $accessibilityState = 'accessible'
    if (-not $hasWindows -and @($probeErrors).Count -gt 0) {
        $accessibilityState = 'inaccessible'
    }
    elseif (-not $isValid) {
        $accessibilityState = 'partial'
    }

    $reason = 'No Windows installation found.'
    if ($isValid) {
        $reason = 'Offline Windows installation detected.'
    }
    elseif ($hasWindows) {
        $reason = 'Windows candidate rejected due to missing required evidence.'
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
        has_explorer = $hasExplorer
        has_ntoskrnl = $hasKernel
        accessibility_state = $accessibilityState
        acceptance_reasons = @($acceptanceReasons)
        rejection_reasons = @($rejectionReasons)
        detection_confidence = $confidence
        evidence_score = $score
        acceptance_status = if ($isValid) { 'accepted' } else { 'rejected' }
        rejection_reason = if ($isValid) { '' } elseif (@($rejectionReasons).Count -gt 0) { [string]$rejectionReasons[0] } else { [string]$reason }
        selected_as_preferred = $false
        is_valid = $isValid
        reason = $reason
    }
}

function Find-DanewOfflineWindowsInstallations {
    param(
        [string]$InputPath,
        [string]$RootPath,
        [AllowEmptyCollection()]
        [string[]]$CandidatePaths
    )

    $candidateMap = @{}

    $roots = @()
    $explicitCandidatePaths = @($CandidatePaths | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if (@($explicitCandidatePaths).Count -gt 0) {
        $roots = @($explicitCandidatePaths)
    }
    else {
        $roots = @(Get-DanewOfflineCandidateRoots -InputPath $InputPath -RootPath $RootPath)
    }

    foreach ($candidateRoot in @($roots)) {
        $rootExists = $false
        if ([string]::IsNullOrWhiteSpace([string]$candidateRoot)) {
            continue
        }

        try {
            $rootExists = Test-Path -Path $candidateRoot -ErrorAction Stop
        }
        catch {
            $rootExists = $false
        }

        if (-not $rootExists) {
            continue
        }

        $rootKey = [string]$candidateRoot
        if ($rootKey.Length -gt 3) {
            $rootKey = $rootKey.TrimEnd('\\')
        }
        $candidateMap[$rootKey.ToLowerInvariant()] = $rootKey

        $rootWindows = Join-Path $candidateRoot 'Windows'
        if (Test-Path -Path $rootWindows) {
            $candidateMap[$rootKey.ToLowerInvariant()] = $rootKey
        }

        try {
            foreach ($windowsDir in @(Get-ChildItem -Path $candidateRoot -Directory -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -ieq 'Windows' })) {
                if ($null -eq $windowsDir -or $null -eq $windowsDir.Parent) {
                    continue
                }

                $installRoot = [string]$windowsDir.Parent.FullName
                if ($installRoot.Length -gt 3) {
                    $installRoot = $installRoot.TrimEnd('\\')
                }
                $candidateMap[$installRoot.ToLowerInvariant()] = $installRoot
            }
        }
        catch {
        }
    }

    $results = @(
        foreach ($candidate in @($candidateMap.Values)) {
            Test-DanewOfflineWindowsCandidate -CandidatePath $candidate
        }
    )

    $ranked = @(
        $results |
            Sort-Object -Property @(
                @{ Expression = 'evidence_score'; Descending = $true },
                @{ Expression = 'has_evtx_logs'; Descending = $true },
                @{ Expression = 'has_ntoskrnl'; Descending = $true },
                @{ Expression = 'has_explorer'; Descending = $true },
                @{ Expression = 'path'; Descending = $false }
            )
    )

    $preferredPath = ''
    $preferredCandidate = @($ranked | Where-Object { $_.is_valid } | Select-Object -First 1)
    if (@($preferredCandidate).Count -gt 0) {
        $preferredPath = [string]$preferredCandidate[0].path
    }

    $position = 1
    $normalized = @(
        foreach ($row in @($ranked)) {
            $isPreferred = (-not [string]::IsNullOrWhiteSpace($preferredPath)) -and ([string]$row.path -eq $preferredPath)

            [pscustomobject]@{
                path = [string]$row.path
                windows_root = [string]$row.windows_root
                windows_dir = [string]$row.windows_dir
                system32_dir = [string]$row.system32_dir
                config_dir = [string]$row.config_dir
                logs_dir = [string]$row.logs_dir
                has_windows = [bool]$row.has_windows
                has_system_hive = [bool]$row.has_system_hive
                has_software_hive = [bool]$row.has_software_hive
                has_evtx_logs = [bool]$row.has_evtx_logs
                has_explorer = [bool]$row.has_explorer
                has_ntoskrnl = [bool]$row.has_ntoskrnl
                accessibility_state = [string]$row.accessibility_state
                acceptance_reasons = @($row.acceptance_reasons)
                rejection_reasons = @($row.rejection_reasons)
                detection_confidence = [string]$row.detection_confidence
                evidence_score = [int]$row.evidence_score
                acceptance_status = if ([bool]$row.is_valid) { 'accepted' } else { 'rejected' }
                rejection_reason = if ([bool]$row.is_valid) { '' } elseif (-not [string]::IsNullOrWhiteSpace([string]$row.rejection_reason)) { [string]$row.rejection_reason } elseif (@($row.rejection_reasons).Count -gt 0) { [string]$row.rejection_reasons[0] } else { [string]$row.reason }
                selected_as_preferred = $isPreferred
                ranking_position = $position
                is_valid = [bool]$row.is_valid
                reason = [string]$row.reason
            }

            $position += 1
        }
    )

    return $normalized
}

function Get-DanewNormalizedPath {
    param(
        [AllowNull()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }

    $normalized = [string]$Path
    try {
        if (Test-Path -Path $normalized) {
            $normalized = (Resolve-Path -Path $normalized).Path
        }
    }
    catch {
    }

    if ($normalized.Length -gt 3) {
        $normalized = $normalized.TrimEnd('\\')
    }

    return $normalized
}

function Get-DanewPathRoot {
    param(
        [AllowNull()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }

    try {
        return [System.IO.Path]::GetPathRoot($Path)
    }
    catch {
        return ''
    }
}

function Test-DanewPathContainsDanewMarker {
    param(
        [AllowNull()]
        [string]$BasePath
    )

    if ([string]::IsNullOrWhiteSpace($BasePath)) {
        return [pscustomobject]@{ contains_marker = $false; evidence = @() }
    }

    $baseExists = $false
    try {
        $baseExists = Test-Path -Path $BasePath -ErrorAction Stop
    }
    catch {
        return [pscustomobject]@{ contains_marker = $false; evidence = @('marker probe skipped: ' + $_.Exception.Message) }
    }

    if (-not $baseExists) {
        return [pscustomobject]@{ contains_marker = $false; evidence = @() }
    }

    $evidence = New-Object System.Collections.ArrayList
    $markers = @(
        'scripts',
        'tools',
        'reports',
        'diagnostics',
        'launcher-config.json',
        'scripts\\DanewCheckTool.CLI.ps1',
        'scripts\\launcher.ps1',
        'scripts\\launcher\\LauncherCore.ps1',
        'scripts\\offline\\OfflineLogsEngine.ps1'
    )

    foreach ($marker in @($markers)) {
        $candidate = Join-Path $BasePath $marker
        try {
            if (Test-Path -Path $candidate -ErrorAction Stop) {
                [void]$evidence.Add('contains ' + $marker)
            }
        }
        catch {
            [void]$evidence.Add('probe failed for ' + $marker + ': ' + $_.Exception.Message)
        }
    }

    return [pscustomobject]@{
        contains_marker = (@($evidence).Count -gt 0)
        evidence = @($evidence)
    }
}

function Get-DanewOfflineDiscoveryExclusions {
    param(
        [Parameter(Mandatory = $true)]
        [object]$StorageAnalysis,
        [string]$RootPath,
        [string]$ToolRootPath,
        [switch]$AllowRemovableWindowsVolumes,
        [int64]$MinimumWindowsOsBytes = 20GB
    )

    $rows = New-Object System.Collections.ArrayList
    $excluded = New-Object System.Collections.ArrayList
    $eligible = New-Object System.Collections.ArrayList

    $systemDriveRoot = Get-DanewPathRoot -Path $env:SystemDrive
    $normalizedRootPath = Get-DanewNormalizedPath -Path $RootPath
    $normalizedToolPath = Get-DanewNormalizedPath -Path $ToolRootPath

    $diskMap = @{}
    foreach ($disk in @($StorageAnalysis.disks)) {
        if ($null -eq $disk) {
            continue
        }
        $diskNumber = [int](Get-DanewSafeProperty -Object $disk -Name 'disk_number' -DefaultValue -1)
        $diskMap[[string]$diskNumber] = $disk
    }

    foreach ($part in @($StorageAnalysis.partitions)) {
        if ($null -eq $part) {
            continue
        }

        $diskNumber = [int](Get-DanewSafeProperty -Object $part -Name 'disk_number' -DefaultValue -1)
        $mountPath = Get-DanewNormalizedPath -Path ([string](Get-DanewSafeProperty -Object $part -Name 'mount_path' -DefaultValue ''))
        $label = [string](Get-DanewSafeProperty -Object $part -Name 'filesystem_label' -DefaultValue '')
        $labelUpper = $label.ToUpperInvariant()
        $fs = [string](Get-DanewSafeProperty -Object $part -Name 'filesystem' -DefaultValue '')
        $sizeBytes = [int64](Get-DanewSafeProperty -Object $part -Name 'size_bytes' -DefaultValue 0)
        $partitionRoot = Get-DanewPathRoot -Path $mountPath
        $partAccessible = [bool](Get-DanewSafeProperty -Object $part -Name 'accessible' -DefaultValue $false)

        $disk = $null
        if ($diskMap.ContainsKey([string]$diskNumber)) {
            $disk = $diskMap[[string]$diskNumber]
        }

        $busType = ''
        if ($disk) {
            $busType = [string](Get-DanewSafeProperty -Object $disk -Name 'bus_type' -DefaultValue '')
        }

        $isRemovableUsb = ($busType -match '(?i)^USB$')

        $windowsEvidence = New-Object System.Collections.ArrayList
        if (-not [string]::IsNullOrWhiteSpace($mountPath) -and $partAccessible -and (Test-Path -Path $mountPath)) {
            foreach ($rel in @(
                    'Windows\\System32\\config\\SYSTEM',
                    'Windows\\System32\\config\\SOFTWARE',
                    'Windows\\System32\\winevt\\Logs',
                    'Windows\\System32\\ntoskrnl.exe',
                    'Windows\\explorer.exe'
                )) {
                $probe = Join-Path $mountPath $rel
                if (Test-Path -Path $probe) {
                    [void]$windowsEvidence.Add('contains ' + $rel)
                }
            }
        }

        $strongWindowsEvidence = (@($windowsEvidence | Where-Object { $_ -match 'SYSTEM|SOFTWARE|winevt\\\\Logs' }).Count -ge 2)

        $markerCheck = [pscustomobject]@{ contains_marker = $false; evidence = @() }
        if ($partAccessible -and -not [string]::IsNullOrWhiteSpace($mountPath)) {
            $markerCheck = Test-DanewPathContainsDanewMarker -BasePath $mountPath
        }
        $evidence = New-Object System.Collections.ArrayList
        foreach ($ev in @($markerCheck.evidence)) {
            [void]$evidence.Add([string]$ev)
        }

        $eligibleForScan = $true
        $exclusionReason = ''

        if ($labelUpper -eq 'DANEW_BOOT') {
            $eligibleForScan = $false
            $exclusionReason = 'Danew USB BOOT partition detected'
            [void]$evidence.Add('label DANEW_BOOT')
        }
        elseif ($labelUpper -eq 'DANEW_DATA') {
            $eligibleForScan = $false
            $exclusionReason = 'Danew USB DATA partition detected'
            [void]$evidence.Add('label DANEW_DATA')
        }
        elseif (-not [string]::IsNullOrWhiteSpace($systemDriveRoot) -and -not [string]::IsNullOrWhiteSpace($partitionRoot) -and $partitionRoot.ToLowerInvariant() -eq $systemDriveRoot.ToLowerInvariant()) {
            $eligibleForScan = $false
            $exclusionReason = 'Current WinPE boot volume excluded'
            [void]$evidence.Add('matches runtime system drive ' + [string]$systemDriveRoot)
        }
        elseif ((-not [string]::IsNullOrWhiteSpace($normalizedRootPath) -and -not [string]::IsNullOrWhiteSpace($mountPath) -and $normalizedRootPath.ToLowerInvariant().StartsWith($mountPath.ToLowerInvariant())) -or
            (-not [string]::IsNullOrWhiteSpace($normalizedToolPath) -and -not [string]::IsNullOrWhiteSpace($mountPath) -and $normalizedToolPath.ToLowerInvariant().StartsWith($mountPath.ToLowerInvariant()))) {
            $eligibleForScan = $false
            $exclusionReason = 'Current tool root volume excluded'
            if (-not [string]::IsNullOrWhiteSpace($normalizedRootPath) -and $normalizedRootPath.ToLowerInvariant().StartsWith($mountPath.ToLowerInvariant())) { [void]$evidence.Add('contains RootPath ' + [string]$normalizedRootPath) }
            if (-not [string]::IsNullOrWhiteSpace($normalizedToolPath) -and $normalizedToolPath.ToLowerInvariant().StartsWith($mountPath.ToLowerInvariant())) { [void]$evidence.Add('contains tool input path ' + [string]$normalizedToolPath) }
        }
        elseif ([bool]$markerCheck.contains_marker) {
            $eligibleForScan = $false
            $exclusionReason = 'Danew tool/media markers detected'
        }
        elseif ($isRemovableUsb -and -not $AllowRemovableWindowsVolumes) {
            $eligibleForScan = $false
            $exclusionReason = 'Removable USB volume excluded by policy'
            [void]$evidence.Add('disk bus type is USB')
        }
        elseif ($sizeBytes -gt 0 -and $sizeBytes -lt $MinimumWindowsOsBytes -and -not $strongWindowsEvidence) {
            $eligibleForScan = $false
            $exclusionReason = 'Volume below minimum OS size threshold'
            [void]$evidence.Add('size_bytes=' + [string]$sizeBytes + '; minimum=' + [string]$MinimumWindowsOsBytes)
        }

        if ($strongWindowsEvidence) {
            [void]$evidence.Add('strong Windows evidence present')
        }

        $row = [pscustomobject]@{
            disk_number = $diskNumber
            partition_number = [int](Get-DanewSafeProperty -Object $part -Name 'partition_number' -DefaultValue -1)
            path = $mountPath
            mount_letter = [string](Get-DanewSafeProperty -Object $part -Name 'mount_letter' -DefaultValue '')
            filesystem = $fs
            filesystem_label = $label
            size_bytes = $sizeBytes
            bus_type = $busType
            removable_usb = $isRemovableUsb
            accessible = $partAccessible
            strong_windows_evidence = $strongWindowsEvidence
            eligible_for_offline_windows_scan = $eligibleForScan
            exclusion_reason = $exclusionReason
            evidence = @($evidence)
        }

        [void]$rows.Add($row)

        if ($eligibleForScan) {
            [void]$eligible.Add($row)
        }
        else {
            [void]$excluded.Add($row)
        }
    }

    return [pscustomobject]@{
        timestamp = (Get-Date).ToString('s')
        scanned_volumes = @($rows)
        excluded_volumes = @($excluded)
        eligible_volumes = @($eligible)
        summary = [pscustomobject]@{
            scanned_count = @($rows).Count
            excluded_count = @($excluded).Count
            eligible_count = @($eligible).Count
        }
    }
}

function Get-DanewOfflineDiscoveryCase {
    param(
        [Parameter(Mandatory = $true)]
        [object]$DiscoveryExclusions,
        [AllowEmptyCollection()]
        [object[]]$Installations,
        [AllowEmptyCollection()]
        [object[]]$ValidInstallations
    )

    $eligibleCount = @($DiscoveryExclusions.eligible_volumes).Count
    $validCount = @($ValidInstallations).Count
    $installCount = @($Installations).Count

    if ($validCount -gt 0) {
        return [pscustomobject]@{
            code = 'OK'
            message = 'Offline Windows installation detected on eligible volume.'
        }
    }

    if ($eligibleCount -eq 0) {
        $onlyDanewOrTool = (@($DiscoveryExclusions.excluded_volumes).Count -gt 0)
        foreach ($item in @($DiscoveryExclusions.excluded_volumes)) {
            $reason = [string](Get-DanewSafeProperty -Object $item -Name 'exclusion_reason' -DefaultValue '')
            if ($reason -notmatch '(?i)Danew|tool root|WinPE boot volume') {
                $onlyDanewOrTool = $false
                break
            }
        }

        if ($onlyDanewOrTool) {
            return [pscustomobject]@{
                code = 'B'
                message = 'Only Danew USB/tool partitions were found and correctly excluded.'
            }
        }

        return [pscustomobject]@{
            code = 'A'
            message = 'No eligible internal Windows volume found.'
        }
    }

    if ($eligibleCount -gt 0 -and $validCount -eq 0) {
        $suffix = ''
        if ($installCount -eq 0) {
            $suffix = ' No Windows structure was found on eligible volumes.'
        }

        return [pscustomobject]@{
            code = 'C'
            message = 'Eligible internal disk found but Windows evidence missing or inaccessible.' + $suffix
        }
    }

    return [pscustomobject]@{
        code = 'UNKNOWN'
        message = 'Offline discovery state could not be classified.'
    }
}

function Get-DanewPreferredWindowsVolume {
    param(
        [Parameter(Mandatory = $true)]
        [object]$DiscoveryExclusions
    )

    $ranked = New-Object System.Collections.ArrayList

    foreach ($volume in @($DiscoveryExclusions.eligible_volumes)) {
        if ($null -eq $volume) {
            continue
        }

        $score = 0
        $reasons = New-Object System.Collections.ArrayList
        $mountLetter = [string](Get-DanewSafeProperty -Object $volume -Name 'mount_letter' -DefaultValue '')
        $busType = [string](Get-DanewSafeProperty -Object $volume -Name 'bus_type' -DefaultValue '')
        $fs = [string](Get-DanewSafeProperty -Object $volume -Name 'filesystem' -DefaultValue '')
        $label = [string](Get-DanewSafeProperty -Object $volume -Name 'filesystem_label' -DefaultValue '')
        $sizeBytes = [int64](Get-DanewSafeProperty -Object $volume -Name 'size_bytes' -DefaultValue 0)
        $diskNumber = [int](Get-DanewSafeProperty -Object $volume -Name 'disk_number' -DefaultValue -1)
        $strongWindows = [bool](Get-DanewSafeProperty -Object $volume -Name 'strong_windows_evidence' -DefaultValue $false)
        $accessible = [bool](Get-DanewSafeProperty -Object $volume -Name 'accessible' -DefaultValue $false)

        if ($accessible) {
            $score += 30
            [void]$reasons.Add('volume accessible')
        }

        if ($strongWindows) {
            $score += 40
            [void]$reasons.Add('strong Windows evidence present')
        }

        if ($mountLetter -ieq 'C') {
            $score += 35
            [void]$reasons.Add('drive letter is C')
        }

        if ($diskNumber -eq 0) {
            $score += 15
            [void]$reasons.Add('disk number is 0')
        }

        if ($busType -notmatch '(?i)^USB$') {
            $score += 10
            [void]$reasons.Add('internal bus preferred')
        }

        if ($fs -match '(?i)^NTFS$|^ReFS$') {
            $score += 10
            [void]$reasons.Add('Windows-friendly filesystem')
        }

        if ($sizeBytes -ge 80GB) {
            $score += 10
            [void]$reasons.Add('size >= 80GB')
        }
        elseif ($sizeBytes -ge 30GB) {
            $score += 5
            [void]$reasons.Add('size >= 30GB')
        }

        if ($label -match '(?i)windows|os|system') {
            $score += 5
            [void]$reasons.Add('label suggests OS partition')
        }

        [void]$ranked.Add([pscustomobject]@{
                path = [string](Get-DanewSafeProperty -Object $volume -Name 'path' -DefaultValue '')
                mount_letter = $mountLetter
                disk_number = $diskNumber
                filesystem = $fs
                filesystem_label = $label
                bus_type = $busType
                size_bytes = $sizeBytes
                strong_windows_evidence = $strongWindows
                score = $score
                ranking_reasons = @($reasons)
            })
    }

    $ordered = @($ranked | Sort-Object -Property @{ Expression = 'score'; Descending = $true }, @{ Expression = 'disk_number'; Descending = $false }, @{ Expression = 'mount_letter'; Descending = $false })
    $preferred = $null
    if (@($ordered).Count -gt 0) {
        $preferred = $ordered[0]
    }

    return [pscustomobject]@{
        preferred_volume = $preferred
        ranked_eligible_volumes = $ordered
    }
}

function Get-DanewPrimaryDiskAnalysis {
    param(
        [Parameter(Mandatory = $true)]
        [object]$StorageAnalysis,
        [switch]$AllowRemovableWindowsVolumes,
        [int64]$MinimumWindowsOsBytes = 20GB
    )

    $diskLayouts = @{}
    foreach ($part in @($StorageAnalysis.partitions)) {
        $dn = [int](Get-DanewSafeProperty -Object $part -Name 'disk_number' -DefaultValue -1)
        if (-not $diskLayouts.ContainsKey([string]$dn)) {
            $diskLayouts[[string]$dn] = [pscustomobject]@{ efi = 0; msr = 0; basic = 0; recovery = 0; large_ntfs = 0 }
        }

        $gpt = [string](Get-DanewSafeProperty -Object $part -Name 'gpt_type' -DefaultValue '')
        $fs = [string](Get-DanewSafeProperty -Object $part -Name 'filesystem' -DefaultValue '')
        $size = [int64](Get-DanewSafeProperty -Object $part -Name 'size_bytes' -DefaultValue 0)

        if ($gpt -match 'C12A7328-F81F-11D2-BA4B-00A0C93EC93B') { $diskLayouts[[string]$dn].efi += 1 }
        if ($gpt -match 'E3C9E316-0B5C-4DB8-817D-F92DF00215AE') { $diskLayouts[[string]$dn].msr += 1 }
        if ($gpt -match 'DE94BBA4-06D1-4D40-A16A-BFD50179D6AC') { $diskLayouts[[string]$dn].recovery += 1 }
        if ($gpt -match 'EBD0A0A2-B9E5-4433-87C0-68B6B72699C7') { $diskLayouts[[string]$dn].basic += 1 }
        if ($fs -match '(?i)^NTFS$|^ReFS$' -and $size -ge $MinimumWindowsOsBytes) { $diskLayouts[[string]$dn].large_ntfs += 1 }
    }

    $rows = New-Object System.Collections.ArrayList
    foreach ($disk in @($StorageAnalysis.disks)) {
        $dn = [int](Get-DanewSafeProperty -Object $disk -Name 'disk_number' -DefaultValue -1)
        $bus = [string](Get-DanewSafeProperty -Object $disk -Name 'bus_type' -DefaultValue '')
        $size = [int64](Get-DanewSafeProperty -Object $disk -Name 'size_bytes' -DefaultValue 0)
        $isUsb = ($bus -match '(?i)^USB$')
        $isInternal = (-not $isUsb) -or $AllowRemovableWindowsVolumes
        $layout = if ($diskLayouts.ContainsKey([string]$dn)) { $diskLayouts[[string]$dn] } else { [pscustomobject]@{ efi = 0; msr = 0; basic = 0; recovery = 0; large_ntfs = 0 } }

        $score = 0
        $reasons = New-Object System.Collections.ArrayList

        if ($dn -eq 0) { $score += 30; [void]$reasons.Add('disk 0 priority') }
        if ($isInternal) { $score += 30; [void]$reasons.Add('internal disk') } else { $score -= 100; [void]$reasons.Add('USB/removable disk') }
        if ($bus -match '(?i)NVMe|SATA|SCSI|RAID|eMMC|ATA') { $score += 15; [void]$reasons.Add('internal storage bus type') }
        if ($size -ge 120GB) { $score += 15; [void]$reasons.Add('disk size >= 120GB') } elseif ($size -ge 60GB) { $score += 10; [void]$reasons.Add('disk size >= 60GB') }

        if ($layout.efi -gt 0 -and $layout.msr -gt 0 -and $layout.basic -gt 0) {
            $score += 20
            [void]$reasons.Add('GPT Windows-style layout (EFI+MSR+Basic)')
        }
        elseif ($layout.basic -gt 0 -and $layout.efi -gt 0) {
            $score += 10
            [void]$reasons.Add('EFI + Basic partition layout')
        }

        if ($layout.recovery -gt 0) {
            $score += 5
            [void]$reasons.Add('recovery partition present')
        }

        if ($layout.large_ntfs -gt 0) {
            $score += 15
            [void]$reasons.Add('large NTFS/ReFS partition present')
        }

        [void]$rows.Add([pscustomobject]@{
                disk_number = $dn
                bus_type = $bus
                size_bytes = $size
                is_internal = $isInternal
                layout = $layout
                score = $score
                ranking_reasons = @($reasons)
            })
    }

    $ranked = @($rows | Sort-Object -Property @{ Expression = 'score'; Descending = $true }, @{ Expression = 'disk_number'; Descending = $false })
    $preferred = if (@($ranked).Count -gt 0) { $ranked[0] } else { $null }
    $internalVisible = @($ranked | Where-Object { $_.is_internal }).Count -gt 0

    return [pscustomobject]@{
        timestamp = (Get-Date).ToString('s')
        disks = $ranked
        preferred_primary_disk = $preferred
        primary_disk_status = if ($internalVisible) { 'internal-visible' } else { 'no-internal-disk-visible' }
        summary = [pscustomobject]@{
            total_disks = @($ranked).Count
            internal_disks = @($ranked | Where-Object { $_.is_internal }).Count
            preferred_disk_number = if ($preferred) { [int]$preferred.disk_number } else { -1 }
        }
    }
}

function Get-DanewWindowsEvidenceFromPath {
    param(
        [string]$Path,
        [bool]$IsInternalDisk,
        [int]$DiskNumber,
        [string]$BusType,
        [string]$FileSystem,
        [int64]$SizeBytes,
        [string]$Label,
        [switch]$IsDanewMarker,
        [switch]$IsUsb
    )

    $score = 0
    $evidence = New-Object System.Collections.ArrayList

    $hasSystemHive = $false
    $hasSoftwareHive = $false
    $hasEvtx = $false
    $hasKernel = $false
    $hasExplorer = $false
    $hasUsers = $false
    $hasProgramFiles = $false

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        try { $hasSystemHive = Test-Path -Path (Join-Path $Path 'Windows\System32\config\SYSTEM') -ErrorAction Stop } catch {}
        try { $hasSoftwareHive = Test-Path -Path (Join-Path $Path 'Windows\System32\config\SOFTWARE') -ErrorAction Stop } catch {}
        try { $hasEvtx = Test-Path -Path (Join-Path $Path 'Windows\System32\winevt\Logs\System.evtx') -ErrorAction Stop } catch {}
        try { $hasKernel = Test-Path -Path (Join-Path $Path 'Windows\System32\ntoskrnl.exe') -ErrorAction Stop } catch {}
        try { $hasExplorer = Test-Path -Path (Join-Path $Path 'Windows\explorer.exe') -ErrorAction Stop } catch {}
        try { $hasUsers = Test-Path -Path (Join-Path $Path 'Users') -ErrorAction Stop } catch {}
        try { $hasProgramFiles = Test-Path -Path (Join-Path $Path 'Program Files') -ErrorAction Stop } catch {}
    }

    if ($hasSystemHive) { $score += 35; [void]$evidence.Add('SYSTEM hive') }
    if ($hasSoftwareHive) { $score += 25; [void]$evidence.Add('SOFTWARE hive') }
    if ($hasEvtx) { $score += 20; [void]$evidence.Add('System.evtx') }
    if ($hasKernel) { $score += 15; [void]$evidence.Add('ntoskrnl.exe') }
    if ($hasExplorer) { $score += 10; [void]$evidence.Add('explorer.exe') }
    if ($hasUsers) { $score += 5; [void]$evidence.Add('Users') }
    if ($hasProgramFiles) { $score += 5; [void]$evidence.Add('Program Files') }
    if ([string]$FileSystem -match '(?i)^NTFS$|^ReFS$') { $score += 10; [void]$evidence.Add('NTFS/ReFS') }
    if ($IsInternalDisk) { $score += 20; [void]$evidence.Add('internal disk') }
    if ($DiskNumber -eq 0) { $score += 10; [void]$evidence.Add('disk 0') }
    if ($IsUsb) { $score -= 100; [void]$evidence.Add('USB penalty') }
    if ($IsDanewMarker) { $score -= 100; [void]$evidence.Add('DANEW marker penalty') }

    $classification = 'Rejected'
    if ($score -ge 100 -and $hasSystemHive -and $hasSoftwareHive) {
        $classification = 'Confirmed Windows volume'
    }
    elseif ($score -ge 65) {
        $classification = 'Probable Windows volume'
    }
    elseif ($score -ge 35) {
        $classification = 'Weak Windows candidate'
    }

    return [pscustomobject]@{
        score = $score
        classification = $classification
        has_system_hive = $hasSystemHive
        has_software_hive = $hasSoftwareHive
        has_evtx = $hasEvtx
        has_ntoskrnl = $hasKernel
        has_explorer = $hasExplorer
        has_users = $hasUsers
        has_program_files = $hasProgramFiles
        evidence = @($evidence)
    }
}

function Get-DanewWindowsVolumeRanking {
    param(
        [Parameter(Mandatory = $true)]
        [object]$StorageAnalysis,
        [Parameter(Mandatory = $true)]
        [object]$DiscoveryExclusions,
        [Parameter(Mandatory = $true)]
        [object]$PrimaryDiskAnalysis,
        [Parameter(Mandatory = $true)]
        [object]$BitLockerAnalysis
    )

    $diskMap = @{}
    foreach ($d in @($PrimaryDiskAnalysis.disks)) {
        $diskMap[[string]$d.disk_number] = $d
    }

    $partMap = @{}
    foreach ($p in @($StorageAnalysis.partitions)) {
        $key = ([string](Get-DanewSafeProperty -Object $p -Name 'disk_number' -DefaultValue -1)) + ':' + ([string](Get-DanewSafeProperty -Object $p -Name 'partition_number' -DefaultValue -1))
        $partMap[$key] = $p
    }

    $mountAttemptMap = @{}
    foreach ($ma in @($StorageAnalysis.mount_attempts)) {
        $key = ([string](Get-DanewSafeProperty -Object $ma -Name 'disk_number' -DefaultValue -1)) + ':' + ([string](Get-DanewSafeProperty -Object $ma -Name 'partition_number' -DefaultValue -1))
        $mountAttemptMap[$key] = $ma
    }

    $rows = New-Object System.Collections.ArrayList
    foreach ($v in @($DiscoveryExclusions.scanned_volumes)) {
        $dn = [int](Get-DanewSafeProperty -Object $v -Name 'disk_number' -DefaultValue -1)
        $pn = [int](Get-DanewSafeProperty -Object $v -Name 'partition_number' -DefaultValue -1)
        $key = [string]$dn + ':' + [string]$pn

        $isEligible = [bool](Get-DanewSafeProperty -Object $v -Name 'eligible_for_offline_windows_scan' -DefaultValue $false)
        $isUsb = [bool](Get-DanewSafeProperty -Object $v -Name 'removable_usb' -DefaultValue $false)
        $path = [string](Get-DanewSafeProperty -Object $v -Name 'path' -DefaultValue '')
        $fs = [string](Get-DanewSafeProperty -Object $v -Name 'filesystem' -DefaultValue '')
        $label = [string](Get-DanewSafeProperty -Object $v -Name 'filesystem_label' -DefaultValue '')
        $size = [int64](Get-DanewSafeProperty -Object $v -Name 'size_bytes' -DefaultValue 0)
        $bus = [string](Get-DanewSafeProperty -Object $v -Name 'bus_type' -DefaultValue '')

        $isInternalDisk = $true
        if ($diskMap.ContainsKey([string]$dn)) {
            $isInternalDisk = [bool](Get-DanewSafeProperty -Object $diskMap[[string]$dn] -Name 'is_internal' -DefaultValue $true)
        }

        $marker = ([string](Get-DanewSafeProperty -Object $v -Name 'exclusion_reason' -DefaultValue '') -match '(?i)Danew')
        $evidenceScore = Get-DanewWindowsEvidenceFromPath -Path $path -IsInternalDisk:$isInternalDisk -DiskNumber $dn -BusType $bus -FileSystem $fs -SizeBytes $size -Label $label -IsDanewMarker:$marker -IsUsb:$isUsb

        $bitLockerSuspected = $false
        if ($isInternalDisk -and -not [bool](Get-DanewSafeProperty -Object $v -Name 'accessible' -DefaultValue $false) -and $fs -match '(?i)^NTFS$|^ReFS$' -and $size -ge 40GB) {
            $bitLockerSuspected = $true
            $evidenceScore = [pscustomobject]@{
                score = ([int]$evidenceScore.score + 15)
                classification = if ([int]$evidenceScore.score -ge 35) { 'Probable Windows volume' } else { [string]$evidenceScore.classification }
                has_system_hive = [bool]$evidenceScore.has_system_hive
                has_software_hive = [bool]$evidenceScore.has_software_hive
                has_evtx = [bool]$evidenceScore.has_evtx
                has_ntoskrnl = [bool]$evidenceScore.has_ntoskrnl
                has_explorer = [bool]$evidenceScore.has_explorer
                has_users = [bool]$evidenceScore.has_users
                has_program_files = [bool]$evidenceScore.has_program_files
                evidence = @(@($evidenceScore.evidence) + @('possible BitLocker lock or inaccessible filesystem'))
            }
        }

        $tmpMount = $null
        if ($mountAttemptMap.ContainsKey($key)) {
            $tmpMount = $mountAttemptMap[$key]
        }

        [void]$rows.Add([pscustomobject]@{
                disk_number = $dn
                partition_number = $pn
                path = $path
                mount_letter = [string](Get-DanewSafeProperty -Object $v -Name 'mount_letter' -DefaultValue '')
                filesystem = $fs
                filesystem_label = $label
                size_bytes = $size
                bus_type = $bus
                eligible = $isEligible
                exclusion_reason = [string](Get-DanewSafeProperty -Object $v -Name 'exclusion_reason' -DefaultValue '')
                windows_score = [int]$evidenceScore.score
                windows_classification = [string]$evidenceScore.classification
                windows_evidence = @($evidenceScore.evidence)
                bitlocker_suspected = $bitLockerSuspected
                temporary_mount = $tmpMount
            })
    }

    $ranked = @($rows | Sort-Object -Property @{ Expression = 'windows_score'; Descending = $true }, @{ Expression = 'disk_number'; Descending = $false }, @{ Expression = 'mount_letter'; Descending = $false })
    $preferred = if (@($ranked).Count -gt 0) { $ranked[0] } else { $null }

    return [pscustomobject]@{
        timestamp = (Get-Date).ToString('s')
        preferred_windows_volume = $preferred
        ranked_volumes = $ranked
        summary = [pscustomobject]@{
            confirmed_count = @($ranked | Where-Object { $_.windows_classification -eq 'Confirmed Windows volume' }).Count
            probable_count = @($ranked | Where-Object { $_.windows_classification -eq 'Probable Windows volume' }).Count
            weak_count = @($ranked | Where-Object { $_.windows_classification -eq 'Weak Windows candidate' }).Count
            rejected_count = @($ranked | Where-Object { $_.windows_classification -eq 'Rejected' }).Count
        }
    }
}

function Get-DanewStorageVisibilityDiagnosis {
    param(
        [Parameter(Mandatory = $true)]
        [object]$StorageAnalysis,
        [Parameter(Mandatory = $true)]
        [object]$PrimaryDiskAnalysis,
        [Parameter(Mandatory = $true)]
        [object]$WindowsVolumeRanking
    )

    $internalDisks = @($PrimaryDiskAnalysis.disks | Where-Object { $_.is_internal })
    $internalVisible = (@($internalDisks).Count -gt 0)
    $internalPartitions = @($StorageAnalysis.partitions | Where-Object {
            $dn = [string](Get-DanewSafeProperty -Object $_ -Name 'disk_number' -DefaultValue -1)
            @($internalDisks | Where-Object { [string]$_.disk_number -eq $dn }).Count -gt 0
        })

    $osLike = @($internalPartitions | Where-Object {
            [string](Get-DanewSafeProperty -Object $_ -Name 'filesystem' -DefaultValue '') -match '(?i)^NTFS$|^ReFS$' -and [int64](Get-DanewSafeProperty -Object $_ -Name 'size_bytes' -DefaultValue 0) -ge 30GB
        })

    $efiCount = @($internalPartitions | Where-Object { [string](Get-DanewSafeProperty -Object $_ -Name 'gpt_type' -DefaultValue '') -match 'C12A7328-F81F-11D2-BA4B-00A0C93EC93B' }).Count
    $recoveryCount = @($internalPartitions | Where-Object { [string](Get-DanewSafeProperty -Object $_ -Name 'gpt_type' -DefaultValue '') -match 'DE94BBA4-06D1-4D40-A16A-BFD50179D6AC' }).Count
    $inaccessibleNtfs = @($osLike | Where-Object { -not [bool](Get-DanewSafeProperty -Object $_ -Name 'accessible' -DefaultValue $false) }).Count

    $case = 'B'
    $message = 'Internal disk visible but no Windows OS partition detected.'
    $driverSuspected = $false
    $bitlockerSuspected = $false

    if (-not $internalVisible) {
        $case = 'A'
        $message = 'No internal disk visible from WinPE.'
        $driverSuspected = $true
    }
    elseif (@($osLike).Count -eq 0 -and $efiCount -gt 0 -and $recoveryCount -gt 0) {
        $case = 'D'
        $message = 'EFI/Recovery partitions visible but OS partition missing.'
    }
    elseif (@($osLike).Count -gt 0 -and $inaccessibleNtfs -gt 0) {
        $case = 'C'
        $message = 'Internal disk visible, OS-like NTFS partition present but inaccessible.'
        $bitlockerSuspected = $true
    }

    return [pscustomobject]@{
        timestamp = (Get-Date).ToString('s')
        storage_visibility_case = $case
        message = $message
        internal_disk_visible = $internalVisible
        os_like_partition_count = @($osLike).Count
        inaccessible_os_like_partition_count = $inaccessibleNtfs
        efi_count = $efiCount
        recovery_count = $recoveryCount
        storage_driver_suspected = $driverSuspected
        bitlocker_suspected = $bitlockerSuspected
    }
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
            if (-not [string]::IsNullOrWhiteSpace($current) -and $null -ne ($current -as [int])) {
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

    # Build XML only when a field fallback is required.
    $needsXmlFallback = [string]::IsNullOrWhiteSpace($message) -or
        [string]::IsNullOrWhiteSpace($level) -or
        [string]::IsNullOrWhiteSpace($task) -or
        [string]::IsNullOrWhiteSpace($opcode) -or
        [string]::IsNullOrWhiteSpace($keywords)

    $xml = $null
    if ($needsXmlFallback) {
        try {
            $xml = [xml]$Event.ToXml()
        }
        catch {
        }
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
        [int]$MaxEventsPerLog = 2000,
        [switch]$EnableParallelPerLog = $true,
        [int]$MaxParallelJobs = 2,
        [int[]]$LevelFilter = @()
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
    }

    $readableItems = @($DiscoveryItems | Where-Object {
            $_.exists -and ($_.status -notin @('corrupted', 'inaccessible'))
        })

    $effectiveLevelFilter = @($LevelFilter | Where-Object { $_ -gt 0 } | Select-Object -Unique)
    $filterXPath = ''
    if (@($effectiveLevelFilter).Count -gt 0) {
        $filterXPath = '*[System[(' + (($effectiveLevelFilter | ForEach-Object { 'Level=' + [string]$_ }) -join ' or ') + ')]]'
    }

    $parallelAvailable = $EnableParallelPerLog -and ($MaxParallelJobs -gt 1) -and (@($readableItems).Count -gt 1) -and ($null -ne (Get-Command -Name Start-Job -ErrorAction SilentlyContinue))

    if ($parallelAvailable) {
        if ($MaxParallelJobs -gt 8) { $MaxParallelJobs = 8 }

        $pending = New-Object System.Collections.ArrayList
        foreach ($item in @($readableItems)) {
            [void]$pending.Add($item)
        }

        $jobs = New-Object System.Collections.ArrayList
        while (@($pending).Count -gt 0 -or @($jobs).Count -gt 0) {
            while (@($pending).Count -gt 0 -and @($jobs).Count -lt $MaxParallelJobs) {
                $nextItem = $pending[0]
                $pending.RemoveAt(0)

                $job = Start-Job -ScriptBlock {
                    param(
                        [string]$FilePath,
                        [string]$InstallationRoot,
                        [int]$MaxPerLog,
                        [string]$FilterXPath,
                        [string]$LevelFilterCsv
                    )

                    $localEvents = New-Object System.Collections.ArrayList
                    $localIssues = New-Object System.Collections.ArrayList
                    $localLevelFilter = @()
                    if (-not [string]::IsNullOrWhiteSpace($LevelFilterCsv)) {
                        $localLevelFilter = @($LevelFilterCsv -split ',' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
                    }

                    try {
                        if ($MaxPerLog -gt 0) {
                            if ([string]::IsNullOrWhiteSpace($FilterXPath)) {
                                $records = @(Get-WinEvent -Path $FilePath -Oldest -MaxEvents $MaxPerLog -ErrorAction Stop)
                            }
                            else {
                                $records = @(Get-WinEvent -Path $FilePath -FilterXPath $FilterXPath -Oldest -MaxEvents $MaxPerLog -ErrorAction SilentlyContinue)
                            }
                        }
                        else {
                            if ([string]::IsNullOrWhiteSpace($FilterXPath)) {
                                $records = @(Get-WinEvent -Path $FilePath -Oldest -ErrorAction Stop)
                            }
                            else {
                                $records = @(Get-WinEvent -Path $FilePath -FilterXPath $FilterXPath -Oldest -ErrorAction SilentlyContinue)
                            }
                        }

                        foreach ($record in @($records)) {
                            try {
                                if (@($localLevelFilter).Count -gt 0 -and ([int]$record.Level) -notin $localLevelFilter) {
                                    continue
                                }

                                $message = ''
                                try { $message = [string]$record.FormatDescription() } catch {}

                                $level = [string]$record.LevelDisplayName
                                $task = [string]$record.TaskDisplayName
                                $opcode = [string]$record.OpcodeDisplayName
                                $keywords = ''
                                try {
                                    if ($record.KeywordsDisplayNames) {
                                        $keywords = [string](@($record.KeywordsDisplayNames) -join '; ')
                                    }
                                }
                                catch {}

                                $needsXmlFallback = [string]::IsNullOrWhiteSpace($message) -or
                                    [string]::IsNullOrWhiteSpace($level) -or
                                    [string]::IsNullOrWhiteSpace($task) -or
                                    [string]::IsNullOrWhiteSpace($opcode) -or
                                    [string]::IsNullOrWhiteSpace($keywords)

                                $xml = $null
                                if ($needsXmlFallback) {
                                    try { $xml = [xml]$record.ToXml() } catch {}
                                }

                                if ([string]::IsNullOrWhiteSpace($message) -and $xml -and $xml.Event -and $xml.Event.RenderingInfo -and $xml.Event.RenderingInfo.Message) {
                                    $message = [string]$xml.Event.RenderingInfo.Message
                                }
                                if ([string]::IsNullOrWhiteSpace($level) -and $xml -and $xml.Event -and $xml.Event.RenderingInfo -and $xml.Event.RenderingInfo.Level) {
                                    $level = [string]$xml.Event.RenderingInfo.Level
                                }
                                if ([string]::IsNullOrWhiteSpace($task) -and $xml -and $xml.Event -and $xml.Event.RenderingInfo -and $xml.Event.RenderingInfo.Task) {
                                    $task = [string]$xml.Event.RenderingInfo.Task
                                }
                                if ([string]::IsNullOrWhiteSpace($opcode) -and $xml -and $xml.Event -and $xml.Event.RenderingInfo -and $xml.Event.RenderingInfo.Opcode) {
                                    $opcode = [string]$xml.Event.RenderingInfo.Opcode
                                }
                                if ([string]::IsNullOrWhiteSpace($keywords) -and $xml -and $xml.Event -and $xml.Event.RenderingInfo -and $xml.Event.RenderingInfo.Keywords) {
                                    $keywords = [string]$xml.Event.RenderingInfo.Keywords
                                }

                                $timestamp = ''
                                try {
                                    $timestamp = ([datetime]$record.TimeCreated).ToString('s')
                                }
                                catch {
                                    $timestamp = [string]$record.TimeCreated
                                }

                                [void]$localEvents.Add([pscustomobject]@{
                                        timestamp = $timestamp
                                        level = $level
                                        provider = [string]$record.ProviderName
                                        event_id = [int]$record.Id
                                        channel = [string]$record.LogName
                                        computer = [string]$record.MachineName
                                        task_category = $task
                                        opcode = $opcode
                                        keywords = $keywords
                                        message = $message
                                        source_file = $FilePath
                                        installation_root = $InstallationRoot
                                    })
                            }
                            catch {
                                [void]$localIssues.Add([pscustomobject]@{
                                        file_path = $FilePath
                                        installation_root = $InstallationRoot
                                        issue = 'partial-record'
                                        message = $_.Exception.Message
                                    })
                            }
                        }
                    }
                    catch {
                        [void]$localIssues.Add([pscustomobject]@{
                                file_path = $FilePath
                                installation_root = $InstallationRoot
                                issue = 'read-failure'
                                message = $_.Exception.Message
                            })
                    }

                    [pscustomobject]@{
                        events = @($localEvents)
                        issues = @($localIssues)
                    }
                } -ArgumentList ([string]$nextItem.file_path), ([string]$nextItem.installation_root), ([int]$MaxEventsPerLog), ([string]$filterXPath), ([string](@($effectiveLevelFilter) -join ','))

                [void]$jobs.Add($job)
            }

            $completed = @(Wait-Job -Job @($jobs) -Any -Timeout 2)
            foreach ($done in @($completed)) {
                if ($null -eq $done) { continue }

                $payload = @(Receive-Job -Job $done -ErrorAction SilentlyContinue)
                foreach ($chunk in @($payload)) {
                    if ($chunk -and $chunk.PSObject.Properties['events']) {
                        foreach ($evt in @($chunk.events)) {
                            [void]$events.Add($evt)
                        }
                    }
                    if ($chunk -and $chunk.PSObject.Properties['issues']) {
                        foreach ($iss in @($chunk.issues)) {
                            [void]$issues.Add($iss)
                        }
                    }
                }

                Remove-Job -Job $done -Force -ErrorAction SilentlyContinue
                [void]$jobs.Remove($done)
            }
        }
    }
    else {
        foreach ($item in @($readableItems)) {
            try {
                if ($MaxEventsPerLog -gt 0) {
                    if ([string]::IsNullOrWhiteSpace($filterXPath)) {
                        $records = @(Get-WinEvent -Path $item.file_path -Oldest -MaxEvents $MaxEventsPerLog -ErrorAction Stop)
                    }
                    else {
                        $records = @(Get-WinEvent -Path $item.file_path -FilterXPath $filterXPath -Oldest -MaxEvents $MaxEventsPerLog -ErrorAction SilentlyContinue)
                    }
                }
                else {
                    if ([string]::IsNullOrWhiteSpace($filterXPath)) {
                        $records = @(Get-WinEvent -Path $item.file_path -Oldest -ErrorAction Stop)
                    }
                    else {
                        $records = @(Get-WinEvent -Path $item.file_path -FilterXPath $filterXPath -Oldest -ErrorAction SilentlyContinue)
                    }
                }

                foreach ($record in @($records)) {
                    try {
                        if (@($effectiveLevelFilter).Count -gt 0 -and ([int]$record.Level) -notin $effectiveLevelFilter) {
                            continue
                        }

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
        $levelCounts = @($eventsArray | Group-Object level | Sort-Object @{Expression={@($_.Group).Count}; Descending=$true} | ForEach-Object {
                [pscustomobject]@{ level = [string]$_.Name; count = @($_.Group).Count }
            })
    }

    $providerCounts = @()
    if (@($eventsArray).Count -gt 0) {
        $providerCounts = @($eventsArray | Group-Object provider | Sort-Object @{Expression={@($_.Group).Count}; Descending=$true} | Select-Object -First 25 | ForEach-Object {
                [pscustomobject]@{ provider = [string]$_.Name; count = @($_.Group).Count }
            })
    }

    $eventIdCounts = @()
    if (@($eventsArray).Count -gt 0) {
        $eventIdCounts = @($eventsArray | Group-Object event_id | Sort-Object @{Expression={@($_.Group).Count}; Descending=$true} | Select-Object -First 25 | ForEach-Object {
                [pscustomobject]@{ event_id = [string]$_.Name; count = @($_.Group).Count }
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

function Get-DanewEvtxKnowledgeItems {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath
    )

    $knowledgePath = Join-Path $RootPath 'manifests\evtx-event-knowledge.json'
    if (-not (Test-Path -Path $knowledgePath)) {
        return @()
    }

    try {
        return @(Get-Content -Path $knowledgePath -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    catch {
        return @()
    }
}

function Get-DanewEvtxTargetedExportModel {
    param(
        [object[]]$Events,
        [object]$Summary,
        [object[]]$KnowledgeItems
    )

    $eventsArray = @($Events)
    $knowledgeArray = @($KnowledgeItems)
    $knowledgeMatchCache = @{}

    function Get-EvtxLevelFr {
        param([AllowNull()][object]$Level)
        $raw = [string]$Level
        if ([string]::IsNullOrWhiteSpace($raw)) { return 'Information' }
        if ($raw -match '(?i)critical|critique') { return 'Critique' }
        if ($raw -match '(?i)error|erreur') { return 'Erreur' }
        if ($raw -match '(?i)warn|avert') { return 'Avertissement' }
        return 'Information'
    }

    function Get-EvtxFamily {
        param(
            [AllowNull()][object]$Provider,
            [AllowNull()][object]$EventId,
            [AllowNull()][object]$Channel,
            [AllowNull()][object]$Message
        )

        $provider = ([string]$Provider).ToLowerInvariant()
        $id = [string]$EventId
        $channel = ([string]$Channel).ToLowerInvariant()
        $message = ([string]$Message).ToLowerInvariant()

        if ($provider -match 'kernel-power|bugcheck|wer-systemerrorreporting' -or $id -eq '41' -or $id -eq '1001') { return 'Crash / BSOD' }
        if ($provider -match 'kernel-boot|boot|bcd|winload' -or $message -match 'boot|demarrage|bcd') { return 'Demarrage / boot' }
        if ($provider -match 'disk|ntfs|stor|nvme|iastor|vmd' -or $id -in @('7', '11', '51', '55', '98', '129', '140', '153', '157')) { return 'Disque / NTFS' }
        if ($provider -match 'driverframeworks|driver|pnp') { return 'Pilotes' }
        if ($provider -match 'windowsupdateclient|update') { return 'Windows Update' }
        if ($provider -match 'whea') { return 'Materiel / WHEA' }
        if ($provider -match 'service control manager|service') { return 'Services' }
        if ($provider -match 'bitlocker|fve') { return 'BitLocker / Chiffrement' }
        if ($channel -match 'security' -or $provider -match 'security|audit') { return 'Securite' }
        return 'Autres'
    }

    function Get-EvtxKnowledge {
        param(
            [AllowNull()][object]$Provider,
            [AllowNull()][object]$EventId
        )

        $provider = [string]$Provider
        $idText = [string]$EventId
        $idInt = 0
        [void][int]::TryParse($idText, [ref]$idInt)

        $cacheKey = $provider.ToLowerInvariant() + '|' + [string]$idInt
        if ($knowledgeMatchCache.ContainsKey($cacheKey)) {
            return $knowledgeMatchCache[$cacheKey]
        }

        foreach ($item in @($knowledgeArray)) {
            if ($null -eq $item) { continue }

            $providerRule = [string]($item.provider)
            $providerOk = $false
            if ([string]::IsNullOrWhiteSpace($providerRule)) {
                $providerOk = $true
            }
            elseif ($provider -like "*$providerRule*") {
                $providerOk = $true
            }

            if (-not $providerOk) { continue }

            $ids = @()
            if ($item.PSObject.Properties['event_ids']) {
                $ids = @($item.event_ids)
            }
            if (@($ids).Count -gt 0) {
                $idHit = $false
                foreach ($candidate in @($ids)) {
                    $candidateInt = 0
                    if ([int]::TryParse([string]$candidate, [ref]$candidateInt) -and $candidateInt -eq $idInt) {
                        $idHit = $true
                        break
                    }
                }
                if (-not $idHit) { continue }
            }

            $knowledgeMatchCache[$cacheKey] = $item
            return $item
        }

        $knowledgeMatchCache[$cacheKey] = $null
        return $null
    }

    function Get-KnowledgeText {
        param(
            [AllowNull()][object]$Knowledge,
            [string]$Preferred,
            [string]$Legacy,
            [string]$DefaultValue
        )

        if ($Knowledge) {
            if ($Knowledge.PSObject.Properties[$Preferred] -and -not [string]::IsNullOrWhiteSpace([string]$Knowledge.$Preferred)) {
                return [string]$Knowledge.$Preferred
            }
            if ($Knowledge.PSObject.Properties[$Legacy] -and -not [string]::IsNullOrWhiteSpace([string]$Knowledge.$Legacy)) {
                return [string]$Knowledge.$Legacy
            }
        }
        return $DefaultValue
    }

    function Get-KnowledgeList {
        param(
            [AllowNull()][object]$Knowledge,
            [string]$Preferred,
            [string]$Legacy,
            [string[]]$DefaultValues
        )

        if ($Knowledge) {
            if ($Knowledge.PSObject.Properties[$Preferred]) {
                $items = @($Knowledge.$Preferred | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                if (@($items).Count -gt 0) { return $items }
            }
            if ($Knowledge.PSObject.Properties[$Legacy]) {
                $itemsLegacy = @($Knowledge.$Legacy | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                if (@($itemsLegacy).Count -gt 0) { return $itemsLegacy }
            }
        }
        return @($DefaultValues)
    }

    function Get-EvtxImportance {
        param(
            [AllowNull()][object]$Event,
            [AllowNull()][object]$Knowledge,
            [bool]$NearCrash,
            [int]$RepetitionCount
        )

        $score = 0
        if ($Knowledge -and $Knowledge.PSObject.Properties['importance_sav']) {
            $kValue = 0
            if ([int]::TryParse([string]$Knowledge.importance_sav, [ref]$kValue)) {
                $score = $kValue
            }
        }
        elseif ($Knowledge -and $Knowledge.PSObject.Properties['importance']) {
            $kValueLegacy = 0
            if ([int]::TryParse([string]$Knowledge.importance, [ref]$kValueLegacy)) {
                $score = $kValueLegacy
            }
        }

        if ($score -le 0) {
            $score = 5
            $provider = ([string]$Event.provider).ToLowerInvariant()
            $id = [string]$Event.event_id
            $levelFr = Get-EvtxLevelFr -Level $Event.level

            if ($id -eq '1001' -or $provider -match 'bugcheck|wer-systemerrorreporting') { $score = 95 }
            elseif ($id -eq '41' -or $provider -match 'kernel-power') { $score = 92 }
            elseif ($provider -match '^disk$' -and $id -in @('7', '11', '51', '129', '153', '157')) { $score = 90 }
            elseif ($provider -match 'ntfs' -and $id -in @('55', '98', '140')) { $score = 88 }
            elseif ($provider -match 'storport') { $score = 88 }
            elseif ($provider -match 'whea') { $score = 85 }
            elseif ($provider -match 'windowsupdateclient' -and $levelFr -in @('Erreur', 'Critique')) { $score = 75 }
            elseif ($provider -match 'driverframeworks' -and $levelFr -in @('Erreur', 'Critique')) { $score = 72 }
            elseif ($provider -match 'service control manager' -and $id -in @('7000', '7001', '7023', '7031', '7034')) { $score = 70 }
            elseif ($provider -match 'bitlocker|fve') { $score = 78 }
            elseif ($provider -match 'kernel-boot|boot|bcd|winload') { $score = 80 }
            elseif ($levelFr -eq 'Avertissement') { $score = 30 }
            elseif ($levelFr -eq 'Information') { $score = 5 }
        }

        if ($NearCrash) { $score += 6 }
        if ($RepetitionCount -ge 8) { $score += 6 }
        elseif ($RepetitionCount -ge 4) { $score += 3 }
        if ($score -gt 100) { $score = 100 }
        if ($score -lt 0) { $score = 0 }
        return [int]$score
    }

    $sortedByTime = @($eventsArray | Sort-Object timestamp)
    $crashCandidates = @($sortedByTime | Where-Object {
            $provider = ([string]$_.provider).ToLowerInvariant()
            $id = [string]$_.event_id
            ($id -eq '41') -or ($id -eq '1001') -or ($provider -match 'kernel-power|bugcheck|wer-systemerrorreporting')
        })
    $lastCrash = $null
    if (@($crashCandidates).Count -gt 0) {
        $lastCrash = @($crashCandidates)[-1]
    }

    $crashWindowStart = $null
    $crashWindowEnd = $null
    if ($lastCrash -and -not [string]::IsNullOrWhiteSpace([string]$lastCrash.timestamp)) {
        try {
            $lastCrashTs = [datetime]::Parse([string]$lastCrash.timestamp)
            $crashWindowStart = $lastCrashTs.AddMinutes(-30)
            $crashWindowEnd = $lastCrashTs.AddMinutes(10)
        }
        catch {
            $crashWindowStart = $null
            $crashWindowEnd = $null
        }
    }

    $repeatMap = @{}
    foreach ($evt in @($eventsArray)) {
        $repeatKey = ([string]$evt.provider) + '|' + ([string]$evt.event_id)
        if (-not $repeatMap.ContainsKey($repeatKey)) { $repeatMap[$repeatKey] = 0 }
        $repeatMap[$repeatKey] = [int]$repeatMap[$repeatKey] + 1
    }

    $enriched = @()
    foreach ($evt in @($sortedByTime)) {
        $timestampText = [string]$evt.timestamp
        $providerText = [string]$evt.provider
        $eventIdText = [string]$evt.event_id
        $channelText = [string]$evt.channel
        $sourceFileText = [string]$evt.source_file
        $messageText = [string]$evt.message
        if ([string]::IsNullOrWhiteSpace($messageText)) { $messageText = '-' }

        $levelFr = Get-EvtxLevelFr -Level $evt.level
        $knowledge = Get-EvtxKnowledge -Provider $providerText -EventId $eventIdText
        $family = Get-EvtxFamily -Provider $providerText -EventId $eventIdText -Channel $channelText -Message $messageText
        if ($knowledge -and $knowledge.PSObject.Properties['family'] -and -not [string]::IsNullOrWhiteSpace([string]$knowledge.family)) {
            $family = [string]$knowledge.family
        }

        $nearCrash = $false
        $eventTs = $null
        if (-not [string]::IsNullOrWhiteSpace($timestampText)) {
            try {
                $eventTs = [datetime]::Parse($timestampText)
            }
            catch {
                $eventTs = $null
            }
        }

        if ($null -ne $eventTs -and $lastCrash) {
            try {
                $crashTs = [datetime]::Parse([string]$lastCrash.timestamp)
                $delta = [math]::Abs(($eventTs - $crashTs).TotalMinutes)
                if ($delta -le 5.0) { $nearCrash = $true }
            }
            catch {
            }
        }

        $repeatKey = $providerText + '|' + $eventIdText
        $repeatCount = 1
        if ($repeatMap.ContainsKey($repeatKey)) {
            $repeatCount = [int]$repeatMap[$repeatKey]
        }

        $importance = Get-EvtxImportance -Event $evt -Knowledge $knowledge -NearCrash:$nearCrash -RepetitionCount $repeatCount
        $isUseful = ($importance -ge 60) -or ($levelFr -in @('Critique', 'Erreur'))

        $explanation = Get-KnowledgeText -Knowledge $knowledge -Preferred 'explanation_fr' -Legacy 'explanation' -DefaultValue 'Evenement Windows a verifier dans le contexte de la panne.'
        $probableCause = Get-KnowledgeText -Knowledge $knowledge -Preferred 'probable_cause_fr' -Legacy 'cause_probable' -DefaultValue 'Cause a confirmer avec la chronologie et les evenements voisins.'
        $impact = Get-KnowledgeText -Knowledge $knowledge -Preferred 'impact_fr' -Legacy 'impact_possible' -DefaultValue 'Impact non determine a ce stade.'
        $recommendedChecks = Get-KnowledgeList -Knowledge $knowledge -Preferred 'recommended_checks_fr' -Legacy 'sav_advice' -DefaultValues @('Comparer cet evenement avec les erreurs de stockage, de boot et les crashs proches.')

        $enriched += [pscustomobject]@{
            timestamp = $timestampText
            timestamp_obj = $eventTs
            level_fr = $levelFr
            importance_sav = [int]$importance
            family = $family
            provider = $providerText
            event_id = $eventIdText
            channel = $channelText
            source_file = $sourceFileText
            message = $messageText
            useful = [bool]$isUseful
            near_crash = [bool]$nearCrash
            repeat_count = [int]$repeatCount
            explanation_fr = $explanation
            probable_cause_fr = $probableCause
            impact_fr = $impact
            recommended_checks_fr = @($recommendedChecks)
        }
    }

    $criticalHigh = @($enriched | Where-Object { $_.level_fr -eq 'Critique' -or [int]$_.importance_sav -ge 80 })
    $filteredUseful = @($enriched | Where-Object { $_.useful })
    $crashWindow = @()
    if ($crashWindowStart -and $crashWindowEnd) {
        $crashWindow = @($enriched | Where-Object {
                $_.timestamp_obj -and $_.timestamp_obj -ge $crashWindowStart -and $_.timestamp_obj -le $crashWindowEnd
            })
    }

    return [pscustomobject]@{
        knowledge_rules_loaded = @($knowledgeArray).Count
        total_events = @($eventsArray).Count
        all = @($enriched)
        filtered = @($filteredUseful)
        critical_high = @($criticalHigh)
        crash_window = @($crashWindow)
        last_crash = $lastCrash
        crash_window_start = if ($crashWindowStart) { $crashWindowStart.ToString('s') } else { '' }
        crash_window_end = if ($crashWindowEnd) { $crashWindowEnd.ToString('s') } else { '' }
        summary = $Summary
    }
}

function Write-DanewEvtxTargetedExports {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [Parameter(Mandatory = $true)]
        [string]$ReportsPath,
        [object[]]$Events,
        [object]$Summary
    )

    if (-not (Test-Path -Path $ReportsPath)) {
        New-Item -Path $ReportsPath -ItemType Directory -Force | Out-Null
    }

    $knowledgeItems = Get-DanewEvtxKnowledgeItems -RootPath $RootPath
    $model = Get-DanewEvtxTargetedExportModel -Events $Events -Summary $Summary -KnowledgeItems $knowledgeItems

    $filteredPath = Join-Path $ReportsPath 'evtx-filtered-events.csv'
    $criticalPath = Join-Path $ReportsPath 'evtx-critical-events.csv'
    $crashWindowPath = Join-Path $ReportsPath 'evtx-crash-window.csv'
    $savSummaryPath = Join-Path $ReportsPath 'evtx-sav-summary.txt'

    $csvProjection = @('timestamp', 'level_fr', 'importance_sav', 'family', 'provider', 'event_id', 'channel', 'source_file', 'message', 'explanation_fr', 'probable_cause_fr', 'impact_fr')

    $filteredRows = @($model.filtered | Select-Object $csvProjection)
    if (@($filteredRows).Count -gt 0) {
        $filteredRows | Export-Csv -Path $filteredPath -NoTypeInformation -Encoding UTF8
    }
    else {
        'timestamp,level_fr,importance_sav,family,provider,event_id,channel,source_file,message,explanation_fr,probable_cause_fr,impact_fr' | Set-Content -Path $filteredPath -Encoding ASCII
    }

    $criticalRows = @($model.critical_high | Select-Object $csvProjection)
    if (@($criticalRows).Count -gt 0) {
        $criticalRows | Export-Csv -Path $criticalPath -NoTypeInformation -Encoding UTF8
    }
    else {
        'timestamp,level_fr,importance_sav,family,provider,event_id,channel,source_file,message,explanation_fr,probable_cause_fr,impact_fr' | Set-Content -Path $criticalPath -Encoding ASCII
    }

    $crashRows = @($model.crash_window | Select-Object $csvProjection)
    if (@($crashRows).Count -gt 0) {
        $crashRows | Export-Csv -Path $crashWindowPath -NoTypeInformation -Encoding UTF8
    }
    else {
        'timestamp,level_fr,importance_sav,family,provider,event_id,channel,source_file,message,explanation_fr,probable_cause_fr,impact_fr' | Set-Content -Path $crashWindowPath -Encoding ASCII
    }

    $top3 = @($model.critical_high | Sort-Object @{ Expression = { [int]$_.importance_sav }; Descending = $true }, @{ Expression = { [string]$_.timestamp }; Descending = $true } | Select-Object -First 3)
    $summaryLines = @(
        'Resume SAV EVTX (PowerShell)',
        ('Generation: ' + (Get-Date).ToString('s')),
        ('Total evenements: ' + [string]$model.total_events),
        ('Evenements filtres (utiles): ' + [string]@($model.filtered).Count),
        ('Evenements critiques / importance >= 80: ' + [string]@($model.critical_high).Count),
        ('Evenements dans la fenetre de crash: ' + [string]@($model.crash_window).Count),
        ('Dernier crash: ' + $(if ($model.last_crash) { ([string]$model.last_crash.timestamp + ' - ' + [string]$model.last_crash.provider + ' ' + [string]$model.last_crash.event_id) } else { 'Aucun' })),
        ('Fenetre crash: ' + $(if (-not [string]::IsNullOrWhiteSpace([string]$model.crash_window_start)) { ([string]$model.crash_window_start + ' -> ' + [string]$model.crash_window_end) } else { 'Non applicable' })),
        ('Regles de connaissance chargees: ' + [string]$model.knowledge_rules_loaded),
        ''
    )

    if (@($top3).Count -gt 0) {
        $summaryLines += 'Top evenements prioritaires :'
        foreach ($item in @($top3)) {
            $summaryLines += ('- [' + [string]$item.importance_sav + '] ' + [string]$item.timestamp + ' | ' + [string]$item.provider + ' ' + [string]$item.event_id + ' | ' + [string]$item.probable_cause_fr)
            foreach ($check in @($item.recommended_checks_fr)) {
                $summaryLines += ('  * ' + [string]$check)
            }
        }
    }
    else {
        $summaryLines += 'Aucun evenement prioritaire detecte.'
    }

    $summaryLines | Set-Content -Path $savSummaryPath -Encoding UTF8

    return [pscustomobject]@{
        generated = $true
        reports_path = $ReportsPath
        knowledge_rules_loaded = $model.knowledge_rules_loaded
        total_events = $model.total_events
        filtered_events = @($model.filtered).Count
        critical_high_events = @($model.critical_high).Count
        crash_window_events = @($model.crash_window).Count
        last_crash_timestamp = if ($model.last_crash) { [string]$model.last_crash.timestamp } else { '' }
        crash_window_start = [string]$model.crash_window_start
        crash_window_end = [string]$model.crash_window_end
        artifacts = [pscustomobject]@{
            evtx_filtered_events_csv = $filteredPath
            evtx_critical_events_csv = $criticalPath
            evtx_crash_window_csv = $crashWindowPath
            evtx_sav_summary_txt = $savSummaryPath
        }
    }
}

function Invoke-DanewEvtxTargetedExportsAction {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    $eventsPath = Join-Path $Config.reports_path 'evtx-events.json'
    $summaryPath = Join-Path $Config.reports_path 'evtx-summary.json'

    if (-not (Test-Path -Path $eventsPath)) {
        return [pscustomobject]@{
            generated = $false
            status = 'WARNING'
            message = "Aucun journal EVTX analyse. Lancez d'abord l'analyse des journaux Windows."
            reports_path = $Config.reports_path
            artifacts = [pscustomobject]@{
                evtx_filtered_events_csv = ''
                evtx_critical_events_csv = ''
                evtx_crash_window_csv = ''
                evtx_sav_summary_txt = ''
            }
        }
    }

    $events = @()
    try {
        $events = @(Get-Content -Path $eventsPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    catch {
        throw ('Unable to read EVTX events source: ' + $eventsPath + ' | ' + $_.Exception.Message)
    }

    $summary = [pscustomobject]@{
        total_events = @($events).Count
        missing_required_logs = 0
        parse_issue_count = 0
    }
    if (Test-Path -Path $summaryPath) {
        try {
            $loadedSummary = Get-Content -Path $summaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($loadedSummary) {
                $summary = $loadedSummary
            }
        }
        catch {
        }
    }

    return (Write-DanewEvtxTargetedExports -RootPath $RootPath -ReportsPath $Config.reports_path -Events $events -Summary $summary)
}

function Write-DanewTimelineHtml {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [object[]]$Events,
        [object]$Summary
    )

    $eventsArray = @($Events)
    $renderedEvents = @($eventsArray | Select-Object -First 4000)

    $knowledgePath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'manifests\evtx-event-knowledge.json'
    $knowledgeItems = @()
    $knowledgeMatchCache = @{}
    if (Test-Path -Path $knowledgePath) {
        try {
            $knowledgeItems = @(Get-Content -Path $knowledgePath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 30)
        }
        catch {
            $knowledgeItems = @()
        }
    }

    function Get-EvtxLevelFr {
        param([AllowNull()][object]$Level)
        $raw = [string]$Level
        if ([string]::IsNullOrWhiteSpace($raw)) { return 'Information' }
        if ($raw -match '(?i)critical|critique') { return 'Critique' }
        if ($raw -match '(?i)error|erreur') { return 'Erreur' }
        if ($raw -match '(?i)warn|avert') { return 'Avertissement' }
        return 'Information'
    }

    function Get-EvtxFamily {
        param(
            [AllowNull()][object]$Provider,
            [AllowNull()][object]$EventId,
            [AllowNull()][object]$Channel,
            [AllowNull()][object]$Message
        )

        $provider = ([string]$Provider).ToLowerInvariant()
        $id = [string]$EventId
        $channel = ([string]$Channel).ToLowerInvariant()
        $message = ([string]$Message).ToLowerInvariant()

        if ($provider -match 'kernel-power|bugcheck|wer-systemerrorreporting' -or $id -eq '41' -or $id -eq '1001') { return 'Crash / BSOD' }
        if ($provider -match 'kernel-boot|boot' -or $message -match 'boot|demarrage') { return 'Demarrage / boot' }
        if ($provider -match 'disk|ntfs|stor|nvme|iaStor|vmd' -or $id -in @('7', '51', '55', '153')) { return 'Disque / NTFS' }
        if ($provider -match 'driverframeworks|driver|pnp') { return 'Pilotes' }
        if ($provider -match 'windowsupdateclient|update') { return 'Windows Update' }
        if ($provider -match 'whea') { return 'Materiel / WHEA' }
        if ($provider -match 'service control manager|service') { return 'Services' }
        if ($channel -match 'security' -or $provider -match 'security|audit') { return 'Securite' }
        return 'Autres'
    }

    function Get-EvtxKnowledge {
        param(
            [AllowNull()][object]$Provider,
            [AllowNull()][object]$EventId,
            [AllowNull()][object]$Level,
            [AllowNull()][object]$Channel
        )

        $provider = [string]$Provider
        $idText = [string]$EventId
        $idInt = 0
        [void][int]::TryParse($idText, [ref]$idInt)

        $cacheKey = $provider.ToLowerInvariant() + '|' + [string]$idInt
        if ($knowledgeMatchCache.ContainsKey($cacheKey)) {
            return $knowledgeMatchCache[$cacheKey]
        }

        foreach ($item in @($knowledgeItems)) {
            if ($null -eq $item) { continue }

            $providerRule = [string]($item.provider)
            $providerOk = $false
            if ([string]::IsNullOrWhiteSpace($providerRule)) {
                $providerOk = $true
            }
            elseif ($provider -like "*$providerRule*") {
                $providerOk = $true
            }

            if (-not $providerOk) { continue }

            $ids = @()
            if ($item.PSObject.Properties['event_ids']) {
                $ids = @($item.event_ids)
            }
            if (@($ids).Count -gt 0) {
                $idHit = $false
                foreach ($candidate in @($ids)) {
                    $candidateInt = 0
                    if ([int]::TryParse([string]$candidate, [ref]$candidateInt) -and $candidateInt -eq $idInt) {
                        $idHit = $true
                        break
                    }
                }
                if (-not $idHit) { continue }
            }

            $knowledgeMatchCache[$cacheKey] = $item
            return $item
        }

        $knowledgeMatchCache[$cacheKey] = $null
        return $null
    }

    function Get-EvtxImportance {
        param(
            [AllowNull()][object]$Event,
            [AllowNull()][object]$Knowledge,
            [bool]$NearCrash,
            [int]$RepetitionCount
        )

        if ($Knowledge -and $Knowledge.PSObject.Properties['importance_sav']) {
            $kValue = 0
            if ([int]::TryParse([string]$Knowledge.importance_sav, [ref]$kValue)) {
                $score = $kValue
            }
            else {
                $score = 0
            }
        }
        elseif ($Knowledge -and $Knowledge.PSObject.Properties['importance']) {
            $kValue = 0
            if ([int]::TryParse([string]$Knowledge.importance, [ref]$kValue)) {
                $score = $kValue
            }
            else {
                $score = 0
            }
        }
        else {
            $score = 5
            $provider = ([string]$Event.provider).ToLowerInvariant()
            $id = [string]$Event.event_id
            $levelFr = Get-EvtxLevelFr -Level $Event.level

            if ($id -eq '1001' -or $provider -match 'bugcheck|wer-systemerrorreporting') { $score = 95 }
            elseif ($id -eq '41' -or $provider -match 'kernel-power') { $score = 90 }
            elseif ($provider -match '^disk$' -and $id -in @('7', '51', '153')) { $score = 90 }
            elseif ($provider -match 'ntfs' -and $id -eq '55') { $score = 90 }
            elseif ($provider -match 'whea') { $score = 85 }
            elseif ($provider -match 'windowsupdateclient' -and $levelFr -in @('Erreur', 'Critique')) { $score = 75 }
            elseif ($provider -match 'driverframeworks' -and $levelFr -in @('Erreur', 'Critique')) { $score = 70 }
            elseif ($provider -match 'service control manager' -and $levelFr -in @('Erreur', 'Critique')) { $score = 65 }
            elseif ($levelFr -eq 'Avertissement') { $score = 30 }
            elseif ($levelFr -eq 'Information') { $score = 5 }
        }

        if ($NearCrash) { $score += 6 }
        if ($RepetitionCount -ge 8) { $score += 6 }
        elseif ($RepetitionCount -ge 4) { $score += 3 }
        if ($score -gt 100) { $score = 100 }
        if ($score -lt 0) { $score = 0 }
        return [int]$score
    }

    $crashCandidates = @($renderedEvents | Where-Object {
            $provider = ([string]$_.provider).ToLowerInvariant()
            $id = [string]$_.event_id
            ($id -eq '41') -or ($id -eq '1001') -or ($provider -match 'kernel-power|bugcheck|wer-systemerrorreporting')
        } | Sort-Object timestamp)
    $lastCrash = $null
    if (@($crashCandidates).Count -gt 0) {
        $lastCrash = @($crashCandidates)[-1]
    }

    $startTime = $null
    $endTime = $null
    if (@($renderedEvents).Count -gt 0) {
        $sortedByTime = @($renderedEvents | Sort-Object timestamp)
        $startTime = [string]$sortedByTime[0].timestamp
        $endTime = [string]$sortedByTime[-1].timestamp
    }

    $journalList = @($renderedEvents | ForEach-Object { [string]$_.channel } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    $providerList = @($renderedEvents | ForEach-Object { [string]$_.provider } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    $idList = @($renderedEvents | ForEach-Object { [string]$_.event_id } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)

    $repeatMap = @{}
    foreach ($evt in @($renderedEvents)) {
        $repeatKey = ([string]$evt.provider) + '|' + ([string]$evt.event_id)
        if (-not $repeatMap.ContainsKey($repeatKey)) { $repeatMap[$repeatKey] = 0 }
        $repeatMap[$repeatKey] = [int]$repeatMap[$repeatKey] + 1
    }

    $enrichedRows = @()
    $rowsHtml = @()
    $eventLinks = @()
    $criticalCount = 0
    $errorCount = 0
    $warnCount = 0
    $infoCount = 0

    foreach ($evt in @($renderedEvents)) {
        $timestampText = [string]$evt.timestamp
        $providerText = [string]$evt.provider
        $eventIdText = [string]$evt.event_id
        $channelText = [string]$evt.channel
        $sourceFileText = [string]$evt.source_file
        $messageText = [string]$evt.message
        if ([string]::IsNullOrWhiteSpace($messageText)) { $messageText = '-' }

        $messageSingleLine = (($messageText -replace "`r", ' ') -replace "`n", ' ').Trim()
        $levelFr = Get-EvtxLevelFr -Level $evt.level
        $family = Get-EvtxFamily -Provider $providerText -EventId $eventIdText -Channel $channelText -Message $messageText
        $knowledge = Get-EvtxKnowledge -Provider $providerText -EventId $eventIdText -Level $evt.level -Channel $channelText
        if ($knowledge -and $knowledge.PSObject.Properties['family'] -and -not [string]::IsNullOrWhiteSpace([string]$knowledge.family)) {
            $family = [string]$knowledge.family
        }

        $nearCrash = $false
        if ($lastCrash -and -not [string]::IsNullOrWhiteSpace($timestampText) -and -not [string]::IsNullOrWhiteSpace([string]$lastCrash.timestamp)) {
            try {
                $tsEvt = [datetime]::Parse($timestampText)
                $tsCrash = [datetime]::Parse([string]$lastCrash.timestamp)
                $delta = [math]::Abs(($tsEvt - $tsCrash).TotalMinutes)
                if ($delta -le 5.0) { $nearCrash = $true }
            }
            catch {
            }
        }

        $repeatKey = $providerText + '|' + $eventIdText
        $repeatCount = 1
        if ($repeatMap.ContainsKey($repeatKey)) {
            $repeatCount = [int]$repeatMap[$repeatKey]
        }

        $importance = Get-EvtxImportance -Event $evt -Knowledge $knowledge -NearCrash:$nearCrash -RepetitionCount $repeatCount
        $isUseful = ($importance -ge 60) -or ($levelFr -in @('Critique', 'Erreur'))

        switch ($levelFr) {
            'Critique' { $criticalCount++ }
            'Erreur' { $errorCount++ }
            'Avertissement' { $warnCount++ }
            default { $infoCount++ }
        }

        $explanation = 'Evenement Windows a verifier dans le contexte de la panne.'
        $causeProbable = 'Cause a confirmer avec la chronologie et les evenements voisins.'
        $impactPossible = 'Impact non determine a ce stade.'
        $savAdvice = @('Comparer cet evenement avec les erreurs de stockage, de boot et les crashs proches.')
        $clientSummary = 'Un evenement systeme a ete detecte.'

        if ($knowledge) {
            if ($knowledge.PSObject.Properties['explanation_fr']) { $explanation = [string]$knowledge.explanation_fr }
            elseif ($knowledge.PSObject.Properties['explanation']) { $explanation = [string]$knowledge.explanation }

            if ($knowledge.PSObject.Properties['probable_cause_fr']) { $causeProbable = [string]$knowledge.probable_cause_fr }
            elseif ($knowledge.PSObject.Properties['cause_probable']) { $causeProbable = [string]$knowledge.cause_probable }

            if ($knowledge.PSObject.Properties['impact_fr']) { $impactPossible = [string]$knowledge.impact_fr }
            elseif ($knowledge.PSObject.Properties['impact_possible']) { $impactPossible = [string]$knowledge.impact_possible }

            if ($knowledge.PSObject.Properties['recommended_checks_fr']) {
                $savAdvice = @($knowledge.recommended_checks_fr | ForEach-Object { [string]$_ })
            }
            elseif ($knowledge.PSObject.Properties['sav_advice']) {
                $savAdvice = @($knowledge.sav_advice | ForEach-Object { [string]$_ })
            }

            if ($knowledge.PSObject.Properties['client_summary']) { $clientSummary = [string]$knowledge.client_summary }
        }

        $eventObj = [pscustomobject]@{
            timestamp = $timestampText
            level_fr = $levelFr
            importance = $importance
            family = $family
            provider = $providerText
            event_id = $eventIdText
            channel = $channelText
            message = $messageSingleLine
            message_full = $messageText
            source_file = $sourceFileText
            useful = $isUseful
            explanation = $explanation
            cause_probable = $causeProbable
            impact_possible = $impactPossible
            sav_advice = @($savAdvice)
            client_summary = $clientSummary
            repeat_count = $repeatCount
            near_crash = $nearCrash
        }
        $enrichedRows += $eventObj
    }

    $top10 = @($enrichedRows | Sort-Object @{ Expression = { [int]$_.importance }; Descending = $true }, @{ Expression = { [int]$_.repeat_count }; Descending = $true }, @{ Expression = { [string]$_.timestamp }; Descending = $true } | Select-Object -First 10)

    $topRowsHtml = @()
    $topIndex = 0
    foreach ($item in @($top10)) {
        $topIndex++
        $filterRef = ConvertTo-DanewReportHtmlText ($item.provider + '|' + $item.event_id)
        $topRowsHtml += @"
<tr data-search-row="$(ConvertTo-DanewReportHtmlText ($item.provider + ' ' + $item.event_id + ' ' + $item.family + ' ' + $item.message))">
<td>$topIndex</td>
<td><button type="button" class="link-button" data-focus-event="$filterRef">$(ConvertTo-DanewReportHtmlText $item.provider) $(ConvertTo-DanewReportHtmlText $item.event_id)</button></td>
<td>$([System.Security.SecurityElement]::Escape([string]$item.level_fr))</td>
<td>$([System.Security.SecurityElement]::Escape([string]$item.importance))</td>
<td>$([System.Security.SecurityElement]::Escape([string]$item.family))</td>
<td>$([System.Security.SecurityElement]::Escape([string]$item.timestamp))</td>
</tr>
"@
    }
    if (@($topRowsHtml).Count -eq 0) {
        $topRowsHtml += '<tr data-search-row="vide"><td colspan="6">Aucun evenement prioritaire detecte.</td></tr>'
    }

    $rowIndex = 0
    foreach ($item in @($enrichedRows)) {
        $rowIndex++
        $eventKey = 'evt-' + [string]$rowIndex
        $searchBlob = ConvertTo-DanewReportHtmlText ($item.timestamp, $item.level_fr, $item.importance, $item.family, $item.provider, $item.event_id, $item.channel, $item.message, $item.source_file -join ' ')
        $messagePreview = [string]$item.message
        if ($messagePreview.Length -gt 180) {
            $messagePreview = $messagePreview.Substring(0, 180) + ' ...'
        }

        $messageCollapsed = '<div class="msg-preview">' + (ConvertTo-DanewReportHtmlText $messagePreview) + '</div><div class="msg-full" hidden>' + (ConvertTo-DanewReportHtmlText $item.message_full) + '</div><button type="button" class="link-button" data-toggle-message>Afficher plus</button>'

        $rowsHtml += @"
<tr class="evtx-row" data-evtx-row data-search-row="$searchBlob" data-row-index="$rowIndex" data-ts="$(ConvertTo-DanewReportHtmlText $item.timestamp)" data-level="$(ConvertTo-DanewReportHtmlText $item.level_fr)" data-importance="$([int]$item.importance)" data-family="$(ConvertTo-DanewReportHtmlText $item.family)" data-provider="$(ConvertTo-DanewReportHtmlText $item.provider)" data-event-id="$(ConvertTo-DanewReportHtmlText $item.event_id)" data-channel="$(ConvertTo-DanewReportHtmlText $item.channel)" data-source-file="$(ConvertTo-DanewReportHtmlText $item.source_file)" data-useful="$(if ($item.useful) { '1' } else { '0' })" data-event-ref="$(ConvertTo-DanewReportHtmlText ($item.provider + '|' + $item.event_id))">
<td>$([System.Security.SecurityElement]::Escape([string]$item.timestamp))</td>
<td><span class="badge-level badge-level-$(ConvertTo-DanewReportToken $item.level_fr)">$([System.Security.SecurityElement]::Escape([string]$item.level_fr))</span></td>
<td>$([System.Security.SecurityElement]::Escape([string]$item.importance))</td>
<td>$([System.Security.SecurityElement]::Escape([string]$item.family))</td>
<td>$([System.Security.SecurityElement]::Escape([string]$item.provider))</td>
<td>$([System.Security.SecurityElement]::Escape([string]$item.event_id))</td>
<td>$([System.Security.SecurityElement]::Escape([string]$item.channel))</td>
<td>$messageCollapsed</td>
<td>$([System.Security.SecurityElement]::Escape([string]$item.source_file))</td>
</tr>
"@

        $relatedPayload = @()
        try {
            $eventTime = [datetime]::Parse([string]$item.timestamp)
            foreach ($peer in @($enrichedRows)) {
                if ([string]::IsNullOrWhiteSpace([string]$peer.timestamp)) { continue }
                $peerTime = $null
                try { $peerTime = [datetime]::Parse([string]$peer.timestamp) } catch { $peerTime = $null }
                if ($null -eq $peerTime) { continue }
                $deltaMin = [math]::Round(($peerTime - $eventTime).TotalMinutes, 2)
                if ([math]::Abs($deltaMin) -le 5.0 -and -not ($peer.timestamp -eq $item.timestamp -and $peer.provider -eq $item.provider -and $peer.event_id -eq $item.event_id)) {
                    $relatedPayload += [pscustomobject]@{ delta_min = $deltaMin; label = ($peer.provider + ' ' + $peer.event_id + ' - ' + $peer.level_fr) }
                }
            }
        }
        catch {
            $relatedPayload = @()
        }

        $eventLinks += [pscustomobject]@{
            key = $eventKey
            provider_id = ($item.provider + '|' + $item.event_id)
            data = [pscustomobject]@{
                timestamp = $item.timestamp
                level = $item.level_fr
                importance = $item.importance
                family = $item.family
                provider = $item.provider
                event_id = $item.event_id
                channel = $item.channel
                source_file = $item.source_file
                message_full = $item.message_full
                explanation = $item.explanation
                cause_probable = $item.cause_probable
                impact_possible = $item.impact_possible
                sav_advice = @($item.sav_advice)
                client_summary = $item.client_summary
                related = @($relatedPayload | Sort-Object delta_min)
            }
        }
    }

    $lastCrashText = 'Aucun crash majeur detecte'
    $lastCrashWindowStart = ''
    $lastCrashWindowEnd = ''
    if ($lastCrash) {
        $lastCrashText = [string]$lastCrash.timestamp + ' - ' + [string]$lastCrash.provider + ' ' + [string]$lastCrash.event_id
        try {
            $lastCrashTs = [datetime]::Parse([string]$lastCrash.timestamp)
            $lastCrashWindowStart = $lastCrashTs.AddMinutes(-30).ToString('s')
            $lastCrashWindowEnd = $lastCrashTs.ToString('s')
        }
        catch {
            $lastCrashWindowStart = ''
            $lastCrashWindowEnd = ''
        }
    }

    $usefulCount = @($enrichedRows | Where-Object { $_.useful }).Count

    $loopRows = @()
    $loopSignals = @(
        [pscustomobject]@{ name = 'Boucle Kernel-Power 41'; pattern = { param($e) ([string]$e.provider -match 'Kernel-Power') -and ([string]$e.event_id -eq '41') }; threshold = 3; explanation = 'Boucle de redemarrage suspectee.'; severity = 'Critique' }
        [pscustomobject]@{ name = 'Boucle BugCheck 1001'; pattern = { param($e) ([string]$e.event_id -eq '1001') -or ([string]$e.provider -match 'WER-SystemErrorReporting|BugCheck') }; threshold = 2; explanation = 'Crash BSOD repete.'; severity = 'Critique' }
        [pscustomobject]@{ name = 'Boucle erreurs disque'; pattern = { param($e) ([string]$e.provider -match '^Disk$') -and ([string]$e.event_id -in @('7', '51', '153')) }; threshold = 3; explanation = 'Instabilite stockage repetee.'; severity = 'Critique' }
        [pscustomobject]@{ name = 'Boucle erreurs NTFS'; pattern = { param($e) ([string]$e.provider -match 'Ntfs') -and ([string]$e.event_id -eq '55') }; threshold = 2; explanation = 'Corruption NTFS repetee.'; severity = 'Critique' }
        [pscustomobject]@{ name = 'Boucle echec Windows Update'; pattern = { param($e) ([string]$e.provider -match 'WindowsUpdateClient') -and ([string]$e.level_fr -in @('Erreur', 'Critique')) }; threshold = 3; explanation = 'Mises a jour en echec a repetition.'; severity = 'Alerte' }
        [pscustomobject]@{ name = 'Boucle echec services critiques'; pattern = { param($e) ([string]$e.provider -match 'Service Control Manager') -and ([string]$e.level_fr -in @('Erreur', 'Critique')) }; threshold = 3; explanation = 'Services critiques en echec repetitif.'; severity = 'Alerte' }
    )

    foreach ($rule in @($loopSignals)) {
        $matches = @($enrichedRows | Where-Object { & $rule.pattern $_ })
        if (@($matches).Count -ge [int]$rule.threshold) {
            $ordered = @($matches | Sort-Object timestamp)
            $loopRows += [pscustomobject]@{
                loop_type = [string]$rule.name
                occurrences = @($matches).Count
                period = ([string]$ordered[0].timestamp + ' -> ' + [string]$ordered[-1].timestamp)
                severity = [string]$rule.severity
                explanation = [string]$rule.explanation
            }
        }
    }

    foreach ($kv in $repeatMap.GetEnumerator()) {
        if ([int]$kv.Value -ge 6) {
            $parts = [string]$kv.Key -split '\|', 2
            $pName = if (@($parts).Count -gt 0) { $parts[0] } else { 'Provider inconnu' }
            $eventIdPart = if (@($parts).Count -gt 1) { $parts[1] } else { '-' }
            $loopRows += [pscustomobject]@{
                loop_type = 'Repetition Event ID'
                occurrences = [int]$kv.Value
                period = 'Voir la chronologie filtrable'
                severity = 'Alerte'
                explanation = ('Evenement repete : ' + $pName + ' ' + $eventIdPart)
            }
        }
    }

    $loopRows = @($loopRows | Sort-Object @{ Expression = { [int]$_.occurrences }; Descending = $true }, loop_type)
    $loopRowsHtml = @()
    foreach ($loop in @($loopRows)) {
        $loopRowsHtml += @"
<tr data-search-row="$(ConvertTo-DanewReportHtmlText ($loop.loop_type + ' ' + $loop.explanation + ' ' + $loop.severity))">
<td>$([System.Security.SecurityElement]::Escape([string]$loop.loop_type))</td>
<td>$([System.Security.SecurityElement]::Escape([string]$loop.occurrences))</td>
<td>$([System.Security.SecurityElement]::Escape([string]$loop.period))</td>
<td>$([System.Security.SecurityElement]::Escape([string]$loop.severity))</td>
<td>$([System.Security.SecurityElement]::Escape([string]$loop.explanation))</td>
</tr>
"@
    }
    if (@($loopRowsHtml).Count -eq 0) {
        $loopRowsHtml += '<tr data-search-row="aucune boucle"><td colspan="5">Aucune boucle significative detectee.</td></tr>'
    }

    $notice = ''
    if (@($eventsArray).Count -gt 4000) {
        $notice = '<p><b>Note :</b> la vue HTML est limitee aux 4000 premiers evenements. Les donnees completes restent disponibles dans timeline-raw.json.</p>'
    }

    $mainTable = New-DanewReportTableHtml -Headers @('Date/heure', 'Niveau', 'Importance SAV', 'Famille', 'Source', 'ID evenement', 'Journal', 'Message', 'Fichier EVTX source') -Rows $rowsHtml -EmptyMessage 'Aucun evenement ne correspond au filtre courant.'
    $top10Table = New-DanewReportTableHtml -Headers @('#', 'Evenement', 'Niveau', 'Importance SAV', 'Famille', 'Date/heure') -Rows $topRowsHtml -EmptyMessage 'Aucun evenement prioritaire a afficher.'
    $loopTable = New-DanewReportTableHtml -Headers @('Type de boucle', 'Occurrences', 'Periode', 'Gravite', 'Explication SAV') -Rows $loopRowsHtml -EmptyMessage 'Aucune boucle detectee.'

    $eventsJson = @($eventLinks | ForEach-Object {
            [pscustomobject]@{
                key = $_.key
                provider_id = $_.provider_id
                payload = $_.data
            }
        }) | ConvertTo-Json -Depth 30 -Compress

    $providerOptionsHtml = @('<option value="">Tous</option>')
    foreach ($p in @($providerList)) {
        $providerOptionsHtml += '<option value="' + (ConvertTo-DanewReportHtmlText $p) + '">' + (ConvertTo-DanewReportHtmlText $p) + '</option>'
    }
    $idOptionsHtml = @('<option value="">Tous</option>')
    foreach ($id in @($idList)) {
        $idOptionsHtml += '<option value="' + (ConvertTo-DanewReportHtmlText $id) + '">' + (ConvertTo-DanewReportHtmlText $id) + '</option>'
    }
    $journalOptionsHtml = @('<option value="">Tous</option>')
    foreach ($j in @($journalList)) {
        $journalOptionsHtml += '<option value="' + (ConvertTo-DanewReportHtmlText $j) + '">' + (ConvertTo-DanewReportHtmlText $j) + '</option>'
    }

    $additionalToolbarHtml = @"
<select data-filter-level>
<option value="">Tous niveaux</option>
<option value="Critique">Critique</option>
<option value="Erreur">Erreur</option>
<option value="Avertissement">Avertissement</option>
<option value="Information">Information</option>
</select>
<select data-filter-family>
<option value="">Toutes familles</option>
<option value="Demarrage / boot">Demarrage / boot</option>
<option value="Crash / BSOD">Crash / BSOD</option>
<option value="Disque / NTFS">Disque / NTFS</option>
<option value="Pilotes">Pilotes</option>
<option value="Windows Update">Windows Update</option>
<option value="Materiel / WHEA">Materiel / WHEA</option>
<option value="Services">Services</option>
<option value="Securite">Securite</option>
<option value="Autres">Autres</option>
</select>
<select data-filter-provider>
$(($providerOptionsHtml -join ''))
</select>
<select data-filter-event-id>
$(($idOptionsHtml -join ''))
</select>
<select data-filter-channel>
$(($journalOptionsHtml -join ''))
</select>
<select data-filter-period>
<option value="all">Tout afficher</option>
<option value="24h">Dernieres 24h</option>
<option value="7d">7 derniers jours</option>
<option value="30d">30 derniers jours</option>
</select>
<button type="button" data-action="useful-only">Afficher uniquement les evenements utiles au diagnostic</button>
<button type="button" data-action="before-last-crash">Voir les evenements avant le dernier crash</button>
<button type="button" data-action="reset-evtx-filters">Reinitialiser les filtres</button>
<button type="button" data-action="copy-sav-summary">Copier le resume SAV</button>
<button type="button" data-action="export-visible-csv">Exporter les evenements filtres en CSV</button>
<button type="button" data-action="export-critical-csv">Exporter uniquement les evenements critiques</button>
<button type="button" data-action="export-crash-csv">Exporter la chronologie de panne</button>
<button type="button" data-action="export-sav-summary">Exporter le resume SAV</button>
<button type="button" data-action="mode-technicien" class="primary-button">Mode Technicien</button>
<button type="button" data-action="mode-client">Mode Client</button>
<span class="inline-chip" data-visible-counter>0 ligne visible</span>
"@

    $primaryCause = if (@($top10).Count -gt 0) { [string]$top10[0].cause_probable } else { 'Cause principale a confirmer selon les filtres.' }
    $savSeverity = if ($criticalCount -gt 0) { 'Critique' } elseif ($errorCount -gt 0) { 'Erreur' } elseif ($warnCount -gt 0) { 'Avertissement' } else { 'Information' }
    $savSummaryText = @"
Resume SAV :
Le PC presente des evenements critiques autour du stockage, du demarrage ou des crashs.
Cause probable : $primaryCause
Gravite : $savSeverity
Action recommandee : sauvegarder les donnees, verifier le stockage, puis poursuivre le diagnostic en lecture seule.
"@.Trim()

    $additionalContentHtml = @"
<aside class="evtx-detail-panel" data-evtx-detail>
<h2>Detail evenement</h2>
<div class="detail-grid">
<div><b>Date/heure :</b> <span data-detail-ts>-</span></div>
<div><b>Niveau :</b> <span data-detail-level>-</span></div>
<div><b>Source :</b> <span data-detail-provider>-</span></div>
<div><b>ID evenement :</b> <span data-detail-id>-</span></div>
<div><b>Journal :</b> <span data-detail-channel>-</span></div>
<div><b>Importance SAV :</b> <span data-detail-importance>-</span></div>
</div>
<h3>Message complet</h3>
<pre data-detail-message>-</pre>
<h3>Explication</h3>
<p data-detail-explanation>-</p>
<h3>Cause probable</h3>
<p data-detail-cause>-</p>
<h3>Impact possible</h3>
<p data-detail-impact>-</p>
<h3>Conseils SAV</h3>
<ul data-detail-advice><li>-</li></ul>
<h3>Evenements lies</h3>
<ul data-detail-related><li>-</li></ul>
</aside>
<section class="report-card" data-client-summary-panel hidden>
<div class="section-head"><div><h2>Mode Client</h2><p class="section-caption">Resume simplifie non technique de la situation.</p></div></div>
<div class="section-body">
<p data-client-summary>Selectionner un evenement pour afficher un resume simplifie.</p>
<textarea data-sav-summary-box rows="7" style="width:100%;font-family:Consolas,""Cascadia Mono"",monospace;">$(ConvertTo-DanewReportHtmlText $savSummaryText)</textarea>
</div>
</section>
"@

    $additionalStyleHtml = @"
<style>
.badge-level-good { background: #dcfce7; color: #166534; padding: 4px 8px; border-radius: 10px; font-weight: 700; }
.badge-level-warn { background: #ffedd5; color: #9a3412; padding: 4px 8px; border-radius: 10px; font-weight: 700; }
.badge-level-danger { background: #fee2e2; color: #991b1b; padding: 4px 8px; border-radius: 10px; font-weight: 700; }
.badge-level-neutral { background: #dbeafe; color: #1e3a8a; padding: 4px 8px; border-radius: 10px; font-weight: 700; }
.inline-chip { padding: 8px 10px; border: 1px solid var(--line); border-radius: 999px; background: #fff; font-size: 12px; }
.link-button { border: 0; background: transparent; color: #0f4f9f; cursor: pointer; text-decoration: underline; padding: 0; font: inherit; }
.msg-preview { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 540px; }
.msg-full { white-space: pre-wrap; margin-top: 6px; max-height: 140px; overflow: auto; border: 1px solid var(--line); border-radius: 8px; padding: 6px; background: #f8fafc; }
.evtx-row { cursor: pointer; }
.evtx-row.row-selected { outline: 2px solid #115e59; outline-offset: -2px; }
.evtx-detail-panel { position: sticky; bottom: 0; margin-top: 14px; border: 1px solid var(--line); border-radius: 18px; background: #ffffff; padding: 14px 16px; box-shadow: var(--shadow); }
.evtx-detail-panel h2, .evtx-detail-panel h3 { margin: 6px 0; }
.evtx-detail-panel pre { max-height: 160px; overflow: auto; border: 1px solid var(--line); border-radius: 8px; padding: 8px; background: #f8fafc; white-space: pre-wrap; }
.detail-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 8px; }
[data-client-mode="1"] [data-tech-only="1"] { display: none !important; }
@media print {
    .evtx-detail-panel, [data-action="copy-sav-summary"], [data-action="export-visible-csv"], [data-action="export-critical-csv"], [data-action="export-crash-csv"], [data-action="export-sav-summary"], [data-action="reset-evtx-filters"] { display: none !important; }
}
</style>
"@

    $additionalScriptHtml = @"
<script>
(function () {
    var eventDb = $eventsJson;
    var mapByRef = {};
    for (var i = 0; i < eventDb.length; i++) {
        mapByRef[eventDb[i].provider_id + '::' + eventDb[i].payload.timestamp] = eventDb[i].payload;
    }

    var root = document.querySelector('[data-report-shell="danew"]');
    if (!root) { return; }

    var rows = Array.prototype.slice.call(document.querySelectorAll('[data-evtx-row]'));
    var searchBox = document.querySelector('[data-report-search]');
    var levelFilter = document.querySelector('[data-filter-level]');
    var familyFilter = document.querySelector('[data-filter-family]');
    var providerFilter = document.querySelector('[data-filter-provider]');
    var eventIdFilter = document.querySelector('[data-filter-event-id]');
    var channelFilter = document.querySelector('[data-filter-channel]');
    var periodFilter = document.querySelector('[data-filter-period]');
    var visibleCounter = document.querySelector('[data-visible-counter]');
    var usefulToggle = document.querySelector('[data-action="useful-only"]');
    var beforeCrashButton = document.querySelector('[data-action="before-last-crash"]');
    var resetButton = document.querySelector('[data-action="reset-evtx-filters"]');
    var copySummaryButton = document.querySelector('[data-action="copy-sav-summary"]');
    var exportVisibleButton = document.querySelector('[data-action="export-visible-csv"]');
    var exportCriticalButton = document.querySelector('[data-action="export-critical-csv"]');
    var exportCrashButton = document.querySelector('[data-action="export-crash-csv"]');
    var exportSummaryButton = document.querySelector('[data-action="export-sav-summary"]');
    var modeTechButton = document.querySelector('[data-action="mode-technicien"]');
    var modeClientButton = document.querySelector('[data-action="mode-client"]');
    var clientPanel = document.querySelector('[data-client-summary-panel]');
    var clientSummary = document.querySelector('[data-client-summary]');
    var summaryBox = document.querySelector('[data-sav-summary-box]');

    var detailTs = document.querySelector('[data-detail-ts]');
    var detailLevel = document.querySelector('[data-detail-level]');
    var detailProvider = document.querySelector('[data-detail-provider]');
    var detailId = document.querySelector('[data-detail-id]');
    var detailChannel = document.querySelector('[data-detail-channel]');
    var detailImportance = document.querySelector('[data-detail-importance]');
    var detailMessage = document.querySelector('[data-detail-message]');
    var detailExplanation = document.querySelector('[data-detail-explanation]');
    var detailCause = document.querySelector('[data-detail-cause]');
    var detailImpact = document.querySelector('[data-detail-impact]');
    var detailAdvice = document.querySelector('[data-detail-advice]');
    var detailRelated = document.querySelector('[data-detail-related]');

    var showUsefulOnly = false;
    var beforeCrashMode = false;
    var crashWindowStart = $(if ([string]::IsNullOrWhiteSpace($lastCrashWindowStart)) { 'null' } else { '"' + (ConvertTo-DanewReportHtmlText $lastCrashWindowStart) + '"' });
    var crashWindowEnd = $(if ([string]::IsNullOrWhiteSpace($lastCrashWindowEnd)) { 'null' } else { '"' + (ConvertTo-DanewReportHtmlText $lastCrashWindowEnd) + '"' });

    function normalize(v) { return (v || '').toString().toLowerCase(); }
    function parseDate(v) {
        var d = new Date(v);
        return isNaN(d.getTime()) ? null : d;
    }

    function downloadTextFile(fileName, content, mimeType) {
        var blob = new Blob([content], { type: mimeType || 'text/plain;charset=utf-8' });
        var url = URL.createObjectURL(blob);
        var a = document.createElement('a');
        a.href = url;
        a.download = fileName;
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        URL.revokeObjectURL(url);
    }

    function rowPassesFilters(row) {
        var term = searchBox ? normalize(searchBox.value) : '';
        if (term) {
            var searchText = normalize(row.getAttribute('data-search-row'));
            if (searchText.indexOf(term) === -1) { return false; }
        }

        if (levelFilter && levelFilter.value && row.getAttribute('data-level') !== levelFilter.value) { return false; }
        if (familyFilter && familyFilter.value && row.getAttribute('data-family') !== familyFilter.value) { return false; }
        if (providerFilter && providerFilter.value && row.getAttribute('data-provider') !== providerFilter.value) { return false; }
        if (eventIdFilter && eventIdFilter.value && row.getAttribute('data-event-id') !== eventIdFilter.value) { return false; }
        if (channelFilter && channelFilter.value && row.getAttribute('data-channel') !== channelFilter.value) { return false; }

        if (showUsefulOnly && row.getAttribute('data-useful') !== '1') { return false; }

        var ts = parseDate(row.getAttribute('data-ts'));
        if (periodFilter && periodFilter.value !== 'all' && ts) {
            var now = new Date();
            var limit = null;
            if (periodFilter.value === '24h') { limit = 24 * 60 * 60 * 1000; }
            if (periodFilter.value === '7d') { limit = 7 * 24 * 60 * 60 * 1000; }
            if (periodFilter.value === '30d') { limit = 30 * 24 * 60 * 60 * 1000; }
            if (limit !== null && (now.getTime() - ts.getTime()) > limit) { return false; }
        }

        if (beforeCrashMode && crashWindowStart && crashWindowEnd && ts) {
            var start = parseDate(crashWindowStart);
            var end = parseDate(crashWindowEnd);
            if (start && end && (ts < start || ts > end)) { return false; }
        }

        return true;
    }

    function updateVisibleCounter(count) {
        if (visibleCounter) {
            visibleCounter.textContent = count + (count > 1 ? ' lignes visibles' : ' ligne visible');
        }
    }

    function applyAllFilters() {
        var visible = 0;
        rows.forEach(function (row) {
            var ok = rowPassesFilters(row);
            row.hidden = !ok;
            if (ok) { visible++; }
        });
        updateVisibleCounter(visible);
    }

    function getVisibleRows() {
        return rows.filter(function (r) { return !r.hidden; });
    }

    function rowsToCsv(targetRows) {
        var header = ['Date/heure','Niveau','Importance SAV','Famille','Source','ID evenement','Journal','Message','Fichier EVTX source'];
        var lines = [header.join(';')];
        targetRows.forEach(function (row) {
            var values = [
                row.getAttribute('data-ts') || '',
                row.getAttribute('data-level') || '',
                row.getAttribute('data-importance') || '',
                row.getAttribute('data-family') || '',
                row.getAttribute('data-provider') || '',
                row.getAttribute('data-event-id') || '',
                row.getAttribute('data-channel') || '',
                (row.querySelector('.msg-full') ? row.querySelector('.msg-full').textContent : ''),
                row.getAttribute('data-source-file') || ''
            ].map(function (v) {
                var safe = (v || '').toString().replace(/"/g, '""');
                return '"' + safe + '"';
            });
            lines.push(values.join(';'));
        });
        return lines.join('\r\n');
    }

    function setDetail(payload) {
        if (!payload) { return; }
        detailTs.textContent = payload.timestamp || '-';
        detailLevel.textContent = payload.level || '-';
        detailProvider.textContent = payload.provider || '-';
        detailId.textContent = payload.event_id || '-';
        detailChannel.textContent = payload.channel || '-';
        detailImportance.textContent = payload.importance || '-';
        detailMessage.textContent = payload.message_full || '-';
        detailExplanation.textContent = payload.explanation || '-';
        detailCause.textContent = payload.cause_probable || '-';
        detailImpact.textContent = payload.impact_possible || '-';

        detailAdvice.innerHTML = '';
        (payload.sav_advice || []).forEach(function (line) {
            var li = document.createElement('li');
            li.textContent = line;
            detailAdvice.appendChild(li);
        });
        if (!detailAdvice.children.length) {
            var li = document.createElement('li');
            li.textContent = '-';
            detailAdvice.appendChild(li);
        }

        detailRelated.innerHTML = '';
        (payload.related || []).forEach(function (item) {
            var li = document.createElement('li');
            var delta = item.delta_min;
            var prefix = delta < 0 ? Math.abs(delta) + ' min avant' : (delta > 0 ? delta + ' min apres' : 'Meme minute');
            li.textContent = prefix + ' : ' + item.label;
            detailRelated.appendChild(li);
        });
        if (!detailRelated.children.length) {
            var liR = document.createElement('li');
            liR.textContent = 'Aucun evenement lie dans la fenetre +/-5 minutes.';
            detailRelated.appendChild(liR);
        }

        if (clientSummary) {
            clientSummary.textContent = payload.client_summary || payload.explanation || 'Resume non disponible.';
        }
    }

    function selectRow(row) {
        rows.forEach(function (r) { r.classList.remove('row-selected'); });
        row.classList.add('row-selected');
        var ref = row.getAttribute('data-event-ref') + '::' + row.getAttribute('data-ts');
        setDetail(mapByRef[ref]);
    }

    rows.forEach(function (row) {
        row.addEventListener('click', function (event) {
            if (event.target && event.target.hasAttribute('data-toggle-message')) {
                return;
            }
            selectRow(row);
        });

        var toggle = row.querySelector('[data-toggle-message]');
        if (toggle) {
            toggle.addEventListener('click', function (event) {
                event.stopPropagation();
                var full = row.querySelector('.msg-full');
                if (!full) { return; }
                var hidden = full.hasAttribute('hidden');
                if (hidden) {
                    full.removeAttribute('hidden');
                    toggle.textContent = 'Afficher moins';
                } else {
                    full.setAttribute('hidden', 'hidden');
                    toggle.textContent = 'Afficher plus';
                }
            });
        }
    });

    document.querySelectorAll('[data-focus-event]').forEach(function (btn) {
        btn.addEventListener('click', function () {
            var target = btn.getAttribute('data-focus-event');
            rows.forEach(function (row) {
                if (row.getAttribute('data-event-ref') === target) {
                    row.scrollIntoView({ behavior: 'smooth', block: 'center' });
                    selectRow(row);
                }
            });
        });
    });

    [searchBox, levelFilter, familyFilter, providerFilter, eventIdFilter, channelFilter, periodFilter].forEach(function (ctrl) {
        if (ctrl) { ctrl.addEventListener('input', applyAllFilters); ctrl.addEventListener('change', applyAllFilters); }
    });

    if (usefulToggle) {
        usefulToggle.addEventListener('click', function () {
            showUsefulOnly = !showUsefulOnly;
            usefulToggle.textContent = showUsefulOnly ? 'Afficher tous les evenements' : 'Afficher uniquement les evenements utiles au diagnostic';
            applyAllFilters();
        });
    }

    if (beforeCrashButton) {
        beforeCrashButton.addEventListener('click', function () {
            beforeCrashMode = !beforeCrashMode;
            beforeCrashButton.textContent = beforeCrashMode ? 'Afficher toute la chronologie' : 'Voir les evenements avant le dernier crash';
            applyAllFilters();
        });
    }

    if (resetButton) {
        resetButton.addEventListener('click', function () {
            if (searchBox) { searchBox.value = ''; }
            if (levelFilter) { levelFilter.value = ''; }
            if (familyFilter) { familyFilter.value = ''; }
            if (providerFilter) { providerFilter.value = ''; }
            if (eventIdFilter) { eventIdFilter.value = ''; }
            if (channelFilter) { channelFilter.value = ''; }
            if (periodFilter) { periodFilter.value = 'all'; }
            showUsefulOnly = false;
            beforeCrashMode = false;
            if (usefulToggle) { usefulToggle.textContent = 'Afficher uniquement les evenements utiles au diagnostic'; }
            if (beforeCrashButton) { beforeCrashButton.textContent = 'Voir les evenements avant le dernier crash'; }
            applyAllFilters();
        });
    }

    if (copySummaryButton) {
        copySummaryButton.addEventListener('click', function () {
            var text = summaryBox ? summaryBox.value : '';
            if (!text) { return; }
            if (navigator.clipboard && navigator.clipboard.writeText) {
                navigator.clipboard.writeText(text).catch(function () {});
            }
            if (summaryBox) {
                summaryBox.focus();
                summaryBox.select();
            }
        });
    }

    if (exportVisibleButton) {
        exportVisibleButton.addEventListener('click', function () {
            downloadTextFile('timeline-visible-events.csv', rowsToCsv(getVisibleRows()), 'text/csv;charset=utf-8');
        });
    }

    if (exportCriticalButton) {
        exportCriticalButton.addEventListener('click', function () {
            var subset = getVisibleRows().filter(function (row) {
                var level = row.getAttribute('data-level');
                return level === 'Critique' || level === 'Erreur';
            });
            downloadTextFile('timeline-critical-events.csv', rowsToCsv(subset), 'text/csv;charset=utf-8');
        });
    }

    if (exportCrashButton) {
        exportCrashButton.addEventListener('click', function () {
            var subset = rows.filter(function (row) {
                var p = normalize(row.getAttribute('data-provider'));
                var id = row.getAttribute('data-event-id') || '';
                return id === '41' || id === '1001' || p.indexOf('kernel-power') !== -1 || p.indexOf('bugcheck') !== -1 || p.indexOf('wer-systemerrorreporting') !== -1;
            });
            downloadTextFile('timeline-crash-events.csv', rowsToCsv(subset), 'text/csv;charset=utf-8');
        });
    }

    if (exportSummaryButton) {
        exportSummaryButton.addEventListener('click', function () {
            var text = summaryBox ? summaryBox.value : '';
            downloadTextFile('timeline-sav-summary.txt', text, 'text/plain;charset=utf-8');
        });
    }

    if (modeTechButton) {
        modeTechButton.addEventListener('click', function () {
            root.removeAttribute('data-client-mode');
            if (clientPanel) { clientPanel.hidden = true; }
        });
    }

    if (modeClientButton) {
        modeClientButton.addEventListener('click', function () {
            root.setAttribute('data-client-mode', '1');
            if (clientPanel) { clientPanel.hidden = false; }
        });
    }

    applyAllFilters();
    if (rows.length > 0) {
        selectRow(rows[0]);
    }
}());
</script>
"@

    $metrics = @(
        (New-DanewMetricCardHtml -Label 'Total evenements' -Value $Summary.total_events -Tone 'info')
        (New-DanewMetricCardHtml -Label 'Critiques' -Value $criticalCount -Tone 'danger')
        (New-DanewMetricCardHtml -Label 'Erreurs' -Value $errorCount -Tone 'warn')
        (New-DanewMetricCardHtml -Label 'Avertissements' -Value $warnCount -Tone 'warn')
        (New-DanewMetricCardHtml -Label 'Informations' -Value $infoCount -Tone 'neutral')
        (New-DanewMetricCardHtml -Label 'Evenements utiles au diagnostic' -Value $usefulCount -Tone 'good')
    ) -join ''

    $meta = New-DanewReportMetaListHtml -Items @(
        [pscustomobject]@{ label = 'Periode couverte'; value = $(if ($startTime -and $endTime) { $startTime + ' -> ' + $endTime } else { 'Indisponible' }) }
        [pscustomobject]@{ label = 'Journaux analyses'; value = $(if (@($journalList).Count -gt 0) { (@($journalList) -join ', ') } else { 'Indisponible' }) }
        [pscustomobject]@{ label = 'Dernier crash detecte'; value = $lastCrashText }
        [pscustomobject]@{ label = 'Cause probable principale'; value = $primaryCause }
        [pscustomobject]@{ label = 'Source JSON complete'; value = 'timeline-raw.json' }
        [pscustomobject]@{ label = 'Export CSV complet'; value = 'evtx-events.csv' }
    )

    $overviewBody = '<p><b>Vue d ensemble de la chronologie</b></p>' +
        '<div class="split-grid">' +
        (New-DanewMetricCardHtml -Label 'Etat du flux EVTX' -Value $(if ([int]$Summary.parse_issue_count -gt 0) { 'Alerte' } else { 'Stable' }) -Tone $(if ([int]$Summary.parse_issue_count -gt 0) { 'warning' } else { 'pass' })) +
        (New-DanewMetricCardHtml -Label 'Couverture des journaux' -Value $(if ([int]$Summary.missing_required_logs -gt 0) { 'Partielle' } else { 'Complete' }) -Tone $(if ([int]$Summary.missing_required_logs -gt 0) { 'warning' } else { 'pass' })) +
        '</div>' + $notice +
        '<p><b>Resume technicien :</b> Utiliser les filtres pour isoler les evenements critiques, puis ouvrir une ligne pour la vue detaillee SAV et la correlation +/-5 minutes.</p>'

    $eventsTableBody = '<p><b>Evenements de la chronologie</b></p>' + $mainTable

    $sections = @(
        (New-DanewReportSectionHtml -Title 'Resume SAV exploitable' -Caption 'Synthese directe pour lecture technicien, sans action destructive.' -SearchText 'resume sav critique erreurs avertissements information' -BodyHtml $overviewBody)
        (New-DanewReportSectionHtml -Title 'Evenements importants a regarder en priorite' -Caption 'Top 10 selon severite, importance SAV, proximite crash et repetition.' -SearchText 'top 10 evenements prioritaires crash bugcheck disk ntfs whea update' -BodyHtml $top10Table)
        (New-DanewReportSectionHtml -Title 'Tableau interactif des evenements Windows' -Caption 'Recherche globale, tri, filtres, detail au clic, export cible et modes de lecture.' -SearchText 'tableau interactif evenements windows filtres tri export detail' -BodyHtml $eventsTableBody)
        (New-DanewReportSectionHtml -Title 'Boucles et repetitions detectees' -Caption 'Detection de redemarrages, crashs, erreurs disque, services et updates en boucle.' -SearchText 'boucles repetitions kernel power bugcheck disk ntfs update services' -BodyHtml $loopTable -Collapsed $true)
    )

    $html = New-DanewInteractiveReportHtml -Title 'Chronologie hors ligne Danew' -Subtitle 'Rapport EVTX interactif pour diagnostic SAV: tri, filtres, scoring, correlation et detail explicatif.' -Status $(if ([int]$Summary.parse_issue_count -gt 0 -or [int]$Summary.missing_required_logs -gt 0) { 'WARNING' } else { 'PASS' }) -Eyebrow 'Diagnostic evenements Windows' -HeroMetricsHtml ('<div class="hero-metrics">' + $metrics + '</div>') -MetaHtml $meta -Sections $sections -SearchPlaceholder 'Rechercher un evenement, un provider, un id, un message ou une famille' -AdditionalToolbarHtml $additionalToolbarHtml -AdditionalContentHtml $additionalContentHtml -AdditionalStyleHtml $additionalStyleHtml -AdditionalScriptHtml $additionalScriptHtml

    $html | Set-Content -Path $Path -Encoding UTF8

    $evtxEventsHtmlPath = Join-Path (Split-Path -Parent $Path) 'evtx-events.html'
    $html | Set-Content -Path $evtxEventsHtmlPath -Encoding UTF8

    Update-DanewInteractiveReportsIndex -ReportsPath (Split-Path -Parent $Path) | Out-Null
}

function Write-DanewFastTimelineHtml {
        param(
                [Parameter(Mandatory = $true)]
                [string]$Path,
                [object[]]$Events,
                [object]$Summary,
                [string]$ByFileHtmlPath,
                [string]$TimelineJsonPath
        )

        $eventsArray = @($Events)
        $summaryObject = if ($Summary) { $Summary } else { [pscustomobject]@{} }
        $totalEvents = @($eventsArray).Count
        if ($summaryObject.PSObject.Properties['total_events']) {
                $totalEvents = [int]$summaryObject.total_events
        }
        $missingRequiredLogs = 0
        if ($summaryObject.PSObject.Properties['missing_required_logs']) {
                $missingRequiredLogs = [int]$summaryObject.missing_required_logs
        }
        $parseIssueCount = 0
        if ($summaryObject.PSObject.Properties['parse_issue_count']) {
                $parseIssueCount = [int]$summaryObject.parse_issue_count
        }

        $byFileName = if ([string]::IsNullOrWhiteSpace($ByFileHtmlPath)) { 'evtx-by-file.html' } else { Split-Path -Leaf $ByFileHtmlPath }
        $timelineJsonName = if ([string]::IsNullOrWhiteSpace($TimelineJsonPath)) { 'timeline-raw.json' } else { Split-Path -Leaf $TimelineJsonPath }

        $html = @"
<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Chronologie hors ligne Danew - Mode rapide</title>
    <style>
        body { font-family: Segoe UI, Arial, sans-serif; margin: 0; background: #f8fafc; color: #0f172a; }
        .wrap { max-width: 980px; margin: 0 auto; padding: 28px; }
        .panel { background: #ffffff; border: 1px solid #cbd5e1; border-radius: 14px; padding: 20px 22px; box-shadow: 0 10px 30px rgba(15, 23, 42, 0.08); }
        h1 { margin: 0 0 12px 0; font-size: 28px; }
        p { line-height: 1.5; }
        .badge { display: inline-block; margin-bottom: 14px; padding: 6px 10px; border-radius: 999px; background: #dbeafe; color: #1d4ed8; font-weight: 700; }
        .metrics { display: flex; flex-wrap: wrap; gap: 12px; margin: 18px 0; }
        .metric { min-width: 180px; background: #f8fafc; border: 1px solid #e2e8f0; border-radius: 10px; padding: 12px 14px; }
        .metric-label { font-size: 12px; text-transform: uppercase; color: #64748b; margin-bottom: 6px; }
        .metric-value { font-size: 22px; font-weight: 700; }
        .actions { display: flex; flex-wrap: wrap; gap: 12px; margin-top: 18px; }
        .action { display: inline-block; padding: 10px 14px; border-radius: 10px; text-decoration: none; font-weight: 700; }
        .primary { background: #2563eb; color: #ffffff; }
        .secondary { background: #e2e8f0; color: #0f172a; }
        .note { margin-top: 18px; color: #475569; }
    </style>
</head>
<body>
    <div class="wrap">
        <div class="panel">
            <div class="badge">Mode rapide optimise</div>
            <h1>Chronologie hors ligne Danew</h1>
            <p>Le mode rapide evite le rendu interactif complet pour accelerer l analyse initiale. Utilisez la vue par fichier pour la priorisation SAV, ou le JSON brut si vous avez besoin d un traitement detaille.</p>
            <div class="metrics">
                <div class="metric"><div class="metric-label">Evenements</div><div class="metric-value">$totalEvents</div></div>
                <div class="metric"><div class="metric-label">Logs requis manquants</div><div class="metric-value">$missingRequiredLogs</div></div>
                <div class="metric"><div class="metric-label">Problemes de lecture</div><div class="metric-value">$parseIssueCount</div></div>
            </div>
            <div class="actions">
                <a class="action primary" href="$byFileName">Ouvrir la vue rapide par fichier EVTX</a>
                <a class="action secondary" href="$timelineJsonName">Ouvrir le JSON brut timeline-raw</a>
            </div>
            <p class="note">Pour retrouver la chronologie HTML detaillee, relancez une analyse complete des journaux Windows.</p>
        </div>
    </div>
</body>
</html>
"@

        Set-Content -Path $Path -Value $html -Encoding UTF8
        Update-DanewInteractiveReportsIndex -ReportsPath (Split-Path -Parent $Path) | Out-Null
}

function Write-DanewEvtxByFileHtml {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [object[]]$Events,
        [object]$Summary
    )

    $eventsArray = @($Events)
    $renderedEvents = @($eventsArray | Select-Object -First 8000)

    function Get-EvtxLevelFr {
        param([AllowNull()][object]$Level)
        $raw = [string]$Level
        if ([string]::IsNullOrWhiteSpace($raw)) { return 'Information' }
        if ($raw -match '(?i)critical|critique') { return 'Critique' }
        if ($raw -match '(?i)error|erreur') { return 'Erreur' }
        if ($raw -match '(?i)warn|avert') { return 'Avertissement' }
        return 'Information'
    }

    function Get-EvtxFamily {
        param(
            [AllowNull()][object]$Provider,
            [AllowNull()][object]$EventId,
            [AllowNull()][object]$Channel,
            [AllowNull()][object]$Message
        )

        $provider = ([string]$Provider).ToLowerInvariant()
        $id = [string]$EventId
        $channel = ([string]$Channel).ToLowerInvariant()
        $message = ([string]$Message).ToLowerInvariant()

        if ($provider -match 'kernel-power|bugcheck|wer-systemerrorreporting' -or $id -eq '41' -or $id -eq '1001') { return 'Crash / BSOD' }
        if ($provider -match 'kernel-boot|boot|bcd|winload' -or $message -match 'boot|demarrage|bcd') { return 'Demarrage / boot' }
        if ($provider -match 'disk|ntfs|stor|nvme|iastor|vmd' -or $id -in @('7', '11', '51', '55', '98', '129', '140', '153', '157')) { return 'Disque / NTFS' }
        if ($provider -match 'driverframeworks|driver|pnp') { return 'Pilotes' }
        if ($provider -match 'whea') { return 'Materiel / WHEA' }
        if ($provider -match 'service control manager|service') { return 'Services' }
        if ($provider -match 'windowsupdateclient|update') { return 'Windows Update' }
        if ($provider -match 'bitlocker|fve') { return 'BitLocker / Chiffrement' }
        if ($channel -match 'security' -or $provider -match 'security|audit') { return 'Securite' }
        return 'Autres'
    }

    function Get-EvtxQuickScore {
        param([AllowNull()][object]$Event)

        $provider = ([string]$Event.provider).ToLowerInvariant()
        $id = [string]$Event.event_id
        $levelFr = [string]$Event.level_fr

        if ($id -eq '1001' -or $provider -match 'bugcheck|wer-systemerrorreporting') { return 95 }
        if ($id -eq '41' -or $provider -match 'kernel-power') { return 92 }
        if ($provider -match '^disk$' -and $id -in @('7', '11', '51', '153')) { return 90 }
        if ($provider -match 'ntfs' -and $id -in @('55', '98', '140')) { return 88 }
        if ($provider -match 'whea') { return 85 }
        if ($provider -match 'windowsupdateclient' -and $levelFr -in @('Erreur', 'Critique')) { return 76 }
        if ($provider -match 'bitlocker|fve') { return 78 }
        if ($provider -match 'service control manager|service' -and $levelFr -in @('Erreur', 'Critique')) { return 72 }
        if ($levelFr -eq 'Critique') { return 75 }
        if ($levelFr -eq 'Erreur') { return 62 }
        if ($levelFr -eq 'Avertissement') { return 30 }
        return 5
    }

    $normalized = @()
    foreach ($evt in @($renderedEvents)) {
        $providerText = [string]$evt.provider
        $idText = [string]$evt.event_id
        $channelText = [string]$evt.channel
        $messageText = [string]$evt.message
        if ([string]::IsNullOrWhiteSpace($messageText)) { $messageText = '-' }
        $sourceFileText = [string]$evt.source_file
        if ([string]::IsNullOrWhiteSpace($sourceFileText)) { $sourceFileText = 'unknown.evtx' }

        $levelFr = Get-EvtxLevelFr -Level $evt.level
        $family = Get-EvtxFamily -Provider $providerText -EventId $idText -Channel $channelText -Message $messageText
        $score = Get-EvtxQuickScore -Event ([pscustomobject]@{ provider = $providerText; event_id = $idText; level_fr = $levelFr })

        $normalized += [pscustomobject]@{
            timestamp = [string]$evt.timestamp
            level_fr = $levelFr
            family = $family
            provider = $providerText
            event_id = $idText
            channel = $channelText
            source_file = $sourceFileText
            message = $messageText
            score = [int]$score
        }
    }

    $totalEvents = @($normalized).Count
    $fastLevelRows = @($normalized | Where-Object { $_.level_fr -in @('Critique', 'Erreur', 'Avertissement') })

    $filesGrouped = @($normalized | Group-Object source_file | Sort-Object -Property Count, Name -Descending)
    $fileVolumeRowsHtml = @()
    foreach ($grp in @($filesGrouped | Select-Object -First 12)) {
        $errorCount = @($grp.Group | Where-Object { $_.level_fr -in @('Critique', 'Erreur', 'Avertissement') }).Count
        $fileVolumeRowsHtml += @"
<tr>
<td>$([System.Security.SecurityElement]::Escape([string]$grp.Name))</td>
<td>$([string]$grp.Count)</td>
<td>$([string]$errorCount)</td>
</tr>
"@
    }
    if (@($fileVolumeRowsHtml).Count -eq 0) {
        $fileVolumeRowsHtml += '<tr><td colspan="3">Aucun evenement EVTX disponible.</td></tr>'
    }

    $causeRows = @($fastLevelRows | Group-Object { ([string]$_.provider + '|' + [string]$_.event_id + '|' + [string]$_.family) } | Sort-Object -Property Count, Name -Descending | Select-Object -First 8)
    $topCauseRowsHtml = @()
    foreach ($cause in @($causeRows)) {
        $parts = [string]$cause.Name -split '\|', 3
        $providerName = if (@($parts).Count -gt 0) { $parts[0] } else { '' }
        $eventIdName = if (@($parts).Count -gt 1) { $parts[1] } else { '' }
        $familyName = if (@($parts).Count -gt 2) { $parts[2] } else { 'Autres' }
        $topCauseRowsHtml += @"
<tr>
<td>$([System.Security.SecurityElement]::Escape($providerName))</td>
<td>$([System.Security.SecurityElement]::Escape($eventIdName))</td>
<td>$([System.Security.SecurityElement]::Escape($familyName))</td>
<td>$([string]$cause.Count)</td>
</tr>
"@
    }
    if (@($topCauseRowsHtml).Count -eq 0) {
        $topCauseRowsHtml += '<tr><td colspan="4">Aucune cause dominante detectee.</td></tr>'
    }

    $topEventsRowsHtml = @()
    $topEvents = @($normalized | Sort-Object @{ Expression = { [int]$_.score }; Descending = $true }, @{ Expression = { [string]$_.timestamp }; Descending = $true } | Select-Object -First 10)
    foreach ($item in @($topEvents)) {
        $topEventsRowsHtml += @"
<tr>
<td>$([System.Security.SecurityElement]::Escape([string]$item.timestamp))</td>
<td>$([System.Security.SecurityElement]::Escape([string]$item.level_fr))</td>
<td>$([System.Security.SecurityElement]::Escape([string]$item.family))</td>
<td>$([System.Security.SecurityElement]::Escape([string]$item.provider))</td>
<td>$([System.Security.SecurityElement]::Escape([string]$item.event_id))</td>
<td>$([string]$item.score)</td>
</tr>
"@
    }
    if (@($topEventsRowsHtml).Count -eq 0) {
        $topEventsRowsHtml += '<tr><td colspan="6">Aucun evenement prioritaire.</td></tr>'
    }

    $byFileSections = @()
    $fileIndex = 0
    foreach ($fileGroup in @($filesGrouped)) {
        $fileIndex++
        $rows = @($fileGroup.Group)
        $errorCount = @($rows | Where-Object { $_.level_fr -in @('Critique', 'Erreur', 'Avertissement') }).Count
        $familyGroups = @($rows | Group-Object family | Sort-Object -Property Count, Name -Descending)

        $familyBlocks = @()
        foreach ($familyGroup in @($familyGroups)) {
            $familyRows = @($familyGroup.Group | Sort-Object @{ Expression = { [string]$_.timestamp }; Descending = $true })
            $eventRowsHtml = @()
            foreach ($row in @($familyRows)) {
                $rowClass = if ($row.level_fr -in @('Critique', 'Erreur', 'Avertissement')) { 'is-error' } else { 'is-all' }
                $eventRowsHtml += @"
<tr class="evtx-row $rowClass" data-level="$([System.Security.SecurityElement]::Escape([string]$row.level_fr))">
<td>$([System.Security.SecurityElement]::Escape([string]$row.timestamp))</td>
<td>$([System.Security.SecurityElement]::Escape([string]$row.level_fr))</td>
<td>$([System.Security.SecurityElement]::Escape([string]$row.provider))</td>
<td>$([System.Security.SecurityElement]::Escape([string]$row.event_id))</td>
<td>$([System.Security.SecurityElement]::Escape([string]$row.channel))</td>
<td>$([System.Security.SecurityElement]::Escape([string]$row.message))</td>
</tr>
"@
            }

            if (@($eventRowsHtml).Count -eq 0) {
                $eventRowsHtml += '<tr><td colspan="6">Aucun evenement dans cette famille.</td></tr>'
            }

            $familyBlocks += @"
<details class="family-block" open>
<summary>$([System.Security.SecurityElement]::Escape([string]$familyGroup.Name)) - $([string]$familyGroup.Count) evenement(s)</summary>
<div class="family-body">
<table class="dense-table">
<thead><tr><th>Date/heure</th><th>Niveau</th><th>Source</th><th>ID</th><th>Journal</th><th>Message</th></tr></thead>
<tbody>
$(($eventRowsHtml -join "`n"))
</tbody>
</table>
</div>
</details>
"@
        }

        $fileOpen = if ($fileIndex -le 2) { ' open' } else { '' }
        $byFileSections += @"
<details class="file-block"$fileOpen>
<summary>$([System.Security.SecurityElement]::Escape([string]$fileGroup.Name)) - total $([string]$fileGroup.Count), critique/erreur/avert. $([string]$errorCount)</summary>
<div class="file-body">
$(($familyBlocks -join "`n"))
</div>
</details>
"@
    }

    if (@($byFileSections).Count -eq 0) {
        $byFileSections += '<p>Aucun evenement EVTX a afficher par fichier.</p>'
    }

    $statusText = if ([int](Get-DanewSafeProperty -Object $Summary -Name 'parse_issue_count' -DefaultValue 0) -gt 0 -or [int](Get-DanewSafeProperty -Object $Summary -Name 'missing_required_logs' -DefaultValue 0) -gt 0) { 'WARNING' } else { 'PASS' }
    $limitNotice = if (@($eventsArray).Count -gt 8000) { '<p class="note">La vue rapide est limitee aux 8000 premiers evenements. Le flux complet reste disponible dans evtx-events.json et timeline-raw.json.</p>' } else { '' }

    $html = @"
<html>
<head>
<meta charset="utf-8" />
<title>EVTX rapide par fichier</title>
<style>
body { font-family: Segoe UI, Arial, sans-serif; background: #f8fafc; color: #1f2937; margin: 18px; }
.hero { background: #ffffff; border: 1px solid #dbe3ea; border-radius: 14px; padding: 14px; margin-bottom: 14px; }
.hero h1 { margin: 0 0 8px 0; font-size: 22px; }
.hero p { margin: 4px 0; }
.chips { display: flex; gap: 8px; flex-wrap: wrap; margin-top: 10px; }
.chip { background: #eef2ff; color: #1d4ed8; border: 1px solid #c7d2fe; border-radius: 999px; padding: 4px 10px; font-weight: 600; }
.toolbar { display: flex; gap: 8px; flex-wrap: wrap; margin: 12px 0; }
.toolbar button { border: 1px solid #cbd5e1; border-radius: 10px; background: #ffffff; padding: 8px 12px; cursor: pointer; font-weight: 600; }
.toolbar button.active { background: #1d4ed8; color: #ffffff; border-color: #1d4ed8; }
.card { background: #ffffff; border: 1px solid #dbe3ea; border-radius: 14px; padding: 12px; margin-bottom: 12px; }
table { width: 100%; border-collapse: collapse; }
th, td { border: 1px solid #dbe3ea; padding: 7px; vertical-align: top; text-align: left; }
th { background: #eef3f7; }
.dense-table td, .dense-table th { font-size: 12px; }
.file-block, .family-block { border: 1px solid #dbe3ea; border-radius: 10px; padding: 8px; background: #ffffff; margin-bottom: 10px; }
.file-block > summary, .family-block > summary { cursor: pointer; font-weight: 700; }
.file-body { margin-top: 8px; }
.family-body { margin-top: 8px; }
.note { font-size: 12px; color: #475569; }
[data-mode="errors"] .evtx-row:not(.is-error) { display: none; }
</style>
</head>
<body data-mode="errors">
<section class="hero">
<h1>EVTX rapide par fichier</h1>
<p>Statut global: <b>$statusText</b> | Total evenements: <b>$totalEvents</b> | Critique/Erreur/Avertissement: <b>$([string]@($fastLevelRows).Count)</b></p>
<p>Mode rapide: critiques, erreurs et avertissements par type (familles) avec regroupement par fichier EVTX. Mode complet: tous les evenements.</p>
<div class="chips">
<span class="chip">Top causes</span>
<span class="chip">Top evenements</span>
<span class="chip">Volume par fichier</span>
<span class="chip">Sections pliables par famille</span>
</div>
$limitNotice
</section>

<section class="toolbar">
<button type="button" data-mode-btn="errors" class="active">Mode 1: Rapide - Critique/Erreur/Avert.</button>
<button type="button" data-mode-btn="all">Mode 2: Complet - Tous les evenements</button>
</section>

<section class="card">
<h2>Resume court</h2>
<h3>Top causes</h3>
<table>
<thead><tr><th>Source</th><th>ID evenement</th><th>Famille</th><th>Occurrences (Critique/Erreur/Avert.)</th></tr></thead>
<tbody>
$(($topCauseRowsHtml -join "`n"))
</tbody>
</table>
</section>

<section class="card">
<h3>Top evenements</h3>
<table>
<thead><tr><th>Date/heure</th><th>Niveau</th><th>Famille</th><th>Source</th><th>ID</th><th>Score</th></tr></thead>
<tbody>
$(($topEventsRowsHtml -join "`n"))
</tbody>
</table>
</section>

<section class="card">
<h3>Volume de logs par fichier EVTX</h3>
<table>
<thead><tr><th>Fichier EVTX</th><th>Total evenements</th><th>Critique/Erreur/Avert.</th></tr></thead>
<tbody>
$(($fileVolumeRowsHtml -join "`n"))
</tbody>
</table>
</section>

<section class="card">
<h2>Lecture par fichier et par famille</h2>
$(($byFileSections -join "`n"))
</section>

<script>
(function () {
    var root = document.body;
    var buttons = document.querySelectorAll('[data-mode-btn]');
    function setMode(mode) {
        root.setAttribute('data-mode', mode);
        buttons.forEach(function (btn) {
            if (btn.getAttribute('data-mode-btn') === mode) {
                btn.classList.add('active');
            } else {
                btn.classList.remove('active');
            }
        });
    }
    buttons.forEach(function (btn) {
        btn.addEventListener('click', function () {
            setMode(btn.getAttribute('data-mode-btn'));
        });
    });
    setMode('errors');
}());
</script>
</body>
</html>
"@

    $html | Set-Content -Path $Path -Encoding UTF8
    Update-DanewInteractiveReportsIndex -ReportsPath (Split-Path -Parent $Path) | Out-Null
}

function Get-DanewSafeProperty {
    param(
        [AllowNull()]
        [object]$Object,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        $DefaultValue = $null
    )

    if ($null -eq $Object) {
        return $DefaultValue
    }

    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) {
        return $DefaultValue
    }

    return $prop.Value
}

function Get-DanewStorageMountCandidates {
    $letters = @('W', 'Y', 'Z')
    $used = @{}
    foreach ($d in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if ($d -and $d.Name) {
            $used[[string]$d.Name] = $true
        }
    }

    $free = @()
    foreach ($ltr in $letters) {
        if (-not $used.ContainsKey($ltr)) {
            $free += $ltr
        }
    }
    return $free
}

function Get-DanewStorageAnalysis {
    param(
        [string]$InputPath,
        [string]$RootPath
    )

    $disks = New-Object System.Collections.ArrayList
    $partitions = New-Object System.Collections.ArrayList
    $volumes = New-Object System.Collections.ArrayList
    $mountAttempts = New-Object System.Collections.ArrayList
    $issues = New-Object System.Collections.ArrayList

    $storageAvailable = (Get-Command -Name Get-Disk -ErrorAction SilentlyContinue) -and (Get-Command -Name Get-Partition -ErrorAction SilentlyContinue)
    if (-not $storageAvailable) {
        [void]$issues.Add('Storage cmdlets are unavailable in this environment.')
    }

    if ($storageAvailable) {
        foreach ($disk in @(Get-Disk -ErrorAction SilentlyContinue)) {
            if ($null -eq $disk) {
                continue
            }

            $diskNumber = [int](Get-DanewSafeProperty -Object $disk -Name 'Number' -DefaultValue -1)
            $busType = [string](Get-DanewSafeProperty -Object $disk -Name 'BusType' -DefaultValue '')
            [void]$disks.Add([pscustomobject]@{
                    disk_number = $diskNumber
                    friendly_name = [string](Get-DanewSafeProperty -Object $disk -Name 'FriendlyName' -DefaultValue '')
                    serial_number = [string](Get-DanewSafeProperty -Object $disk -Name 'SerialNumber' -DefaultValue '')
                    bus_type = $busType
                    partition_style = [string](Get-DanewSafeProperty -Object $disk -Name 'PartitionStyle' -DefaultValue '')
                    operational_status = [string](Get-DanewSafeProperty -Object $disk -Name 'OperationalStatus' -DefaultValue '')
                    is_offline = [bool](Get-DanewSafeProperty -Object $disk -Name 'IsOffline' -DefaultValue $false)
                    is_read_only = [bool](Get-DanewSafeProperty -Object $disk -Name 'IsReadOnly' -DefaultValue $false)
                    size_bytes = [int64](Get-DanewSafeProperty -Object $disk -Name 'Size' -DefaultValue 0)
                })

            if ([bool](Get-DanewSafeProperty -Object $disk -Name 'IsOffline' -DefaultValue $false)) {
                [void]$issues.Add('Disk ' + [string]$diskNumber + ' is offline.')
            }

            foreach ($part in @(Get-Partition -DiskNumber $diskNumber -ErrorAction SilentlyContinue)) {
                if ($null -eq $part) {
                    continue
                }

                $partNumber = [int](Get-DanewSafeProperty -Object $part -Name 'PartitionNumber' -DefaultValue -1)
                $vol = $null
                try {
                    $vol = Get-Volume -Partition $part -ErrorAction SilentlyContinue
                }
                catch {
                    $vol = $null
                }

                $volumeGuidPath = ''
                if ($vol) {
                    $volumeGuidPath = [string](Get-DanewSafeProperty -Object $vol -Name 'Path' -DefaultValue '')
                }

                $driveLetter = ''
                if ($vol) {
                    $driveLetterValue = Get-DanewSafeProperty -Object $vol -Name 'DriveLetter' -DefaultValue $null
                    if ($null -ne $driveLetterValue -and -not [string]::IsNullOrWhiteSpace([string]$driveLetterValue)) {
                        $driveLetter = [string]$driveLetterValue
                    }
                }

                $accessPath = ''
                if (-not [string]::IsNullOrWhiteSpace($driveLetter)) {
                    $accessPath = $driveLetter + ':\\'
                }
                elseif (-not [string]::IsNullOrWhiteSpace($volumeGuidPath)) {
                    $accessPath = $volumeGuidPath
                }

                $accessible = $false
                $accessError = ''
                if (-not [string]::IsNullOrWhiteSpace($accessPath)) {
                    try {
                        $accessible = Test-Path -Path $accessPath -ErrorAction Stop
                    }
                    catch {
                        $accessible = $false
                        $accessError = $_.Exception.Message
                    }
                }

                $partitionObj = [pscustomobject]@{
                    disk_number = $diskNumber
                    partition_number = $partNumber
                    guid = [string](Get-DanewSafeProperty -Object $part -Name 'Guid' -DefaultValue '')
                    gpt_type = [string](Get-DanewSafeProperty -Object $part -Name 'GptType' -DefaultValue '')
                    mbr_type = [string](Get-DanewSafeProperty -Object $part -Name 'MbrType' -DefaultValue '')
                    partition_type = [string](Get-DanewSafeProperty -Object $part -Name 'Type' -DefaultValue '')
                    is_active = [bool](Get-DanewSafeProperty -Object $part -Name 'IsActive' -DefaultValue $false)
                    is_hidden = [bool](Get-DanewSafeProperty -Object $part -Name 'IsHidden' -DefaultValue $false)
                    is_read_only = [bool](Get-DanewSafeProperty -Object $part -Name 'IsReadOnly' -DefaultValue $false)
                    size_bytes = [int64](Get-DanewSafeProperty -Object $part -Name 'Size' -DefaultValue 0)
                    offset_bytes = [int64](Get-DanewSafeProperty -Object $part -Name 'Offset' -DefaultValue 0)
                    mount_letter = $driveLetter
                    mount_path = $accessPath
                    filesystem = if ($vol) { [string](Get-DanewSafeProperty -Object $vol -Name 'FileSystem' -DefaultValue '') } else { '' }
                    filesystem_label = if ($vol) { [string](Get-DanewSafeProperty -Object $vol -Name 'FileSystemLabel' -DefaultValue '') } else { '' }
                    health_status = if ($vol) { [string](Get-DanewSafeProperty -Object $vol -Name 'HealthStatus' -DefaultValue '') } else { '' }
                    operational_status = if ($vol) { [string](Get-DanewSafeProperty -Object $vol -Name 'OperationalStatus' -DefaultValue '') } else { '' }
                    size_remaining_bytes = if ($vol) { [int64](Get-DanewSafeProperty -Object $vol -Name 'SizeRemaining' -DefaultValue 0) } else { 0 }
                    accessible = $accessible
                    accessibility_error = $accessError
                }

                if ($partitionObj.filesystem -match '^RAW$') {
                    [void]$issues.Add('RAW partition detected on disk ' + [string]$diskNumber + ', partition ' + [string]$partNumber + '.')
                }

                if (-not $partitionObj.accessible -and -not [string]::IsNullOrWhiteSpace($partitionObj.mount_path)) {
                    [void]$issues.Add('Inaccessible partition path: ' + [string]$partitionObj.mount_path)
                }

                [void]$partitions.Add($partitionObj)

                if ($vol) {
                    [void]$volumes.Add([pscustomobject]@{
                            disk_number = $diskNumber
                            partition_number = $partNumber
                            drive_letter = $driveLetter
                            volume_guid_path = $volumeGuidPath
                            filesystem = [string](Get-DanewSafeProperty -Object $vol -Name 'FileSystem' -DefaultValue '')
                            health_status = [string](Get-DanewSafeProperty -Object $vol -Name 'HealthStatus' -DefaultValue '')
                            size_bytes = [int64](Get-DanewSafeProperty -Object $vol -Name 'Size' -DefaultValue 0)
                            size_remaining_bytes = [int64](Get-DanewSafeProperty -Object $vol -Name 'SizeRemaining' -DefaultValue 0)
                        })
                }

                $isInternalDisk = ($busType -notmatch '(?i)^USB$')
                $isWindowsFs = ([string]$partitionObj.filesystem -match '(?i)^NTFS$|^ReFS$')

                if ([string]::IsNullOrWhiteSpace($driveLetter) -and $isInternalDisk -and $isWindowsFs -and (Get-Command -Name Add-PartitionAccessPath -ErrorAction SilentlyContinue) -and (Get-Command -Name Remove-PartitionAccessPath -ErrorAction SilentlyContinue)) {
                    $tmpLetter = ''
                    $tmpPath = ''
                    $mountStatus = 'skipped'
                    $mountMessage = 'No free drive letter available.'
                    $probeSystem = $false
                    $probeSoftware = $false
                    $probeEvtx = $false
                    $probeKernel = $false
                    $probeExplorer = $false
                    $probeUsers = $false
                    $probeProgramFiles = $false
                    foreach ($candidateLetter in @(Get-DanewStorageMountCandidates)) {
                        $tmpPath = $candidateLetter + ':\\'
                        try {
                            Add-PartitionAccessPath -DiskNumber $diskNumber -PartitionNumber $partNumber -AccessPath $tmpPath -ErrorAction Stop
                            $tmpLetter = $candidateLetter
                            $mountStatus = 'mounted'
                            $mountMessage = 'Temporary mount succeeded.'
                            try {
                                $null = Get-ChildItem -Path $tmpPath -ErrorAction Stop | Select-Object -First 1

                                $probeSystem = Test-Path -Path (Join-Path $tmpPath 'Windows\System32\config\SYSTEM') -ErrorAction SilentlyContinue
                                $probeSoftware = Test-Path -Path (Join-Path $tmpPath 'Windows\System32\config\SOFTWARE') -ErrorAction SilentlyContinue
                                $probeEvtx = Test-Path -Path (Join-Path $tmpPath 'Windows\System32\winevt\Logs\System.evtx') -ErrorAction SilentlyContinue
                                $probeKernel = Test-Path -Path (Join-Path $tmpPath 'Windows\System32\ntoskrnl.exe') -ErrorAction SilentlyContinue
                                $probeExplorer = Test-Path -Path (Join-Path $tmpPath 'Windows\explorer.exe') -ErrorAction SilentlyContinue
                                $probeUsers = Test-Path -Path (Join-Path $tmpPath 'Users') -ErrorAction SilentlyContinue
                                $probeProgramFiles = Test-Path -Path (Join-Path $tmpPath 'Program Files') -ErrorAction SilentlyContinue
                            }
                            catch {
                                $mountStatus = 'inaccessible'
                                $mountMessage = $_.Exception.Message
                            }
                            break
                        }
                        catch {
                            $mountStatus = 'denied'
                            $mountMessage = $_.Exception.Message
                        }
                    }

                    [void]$mountAttempts.Add([pscustomobject]@{
                            disk_number = $diskNumber
                            partition_number = $partNumber
                            temporary_drive_letter = $tmpLetter
                            access_path = $tmpPath
                            status = $mountStatus
                            message = $mountMessage
                            has_system_hive = $probeSystem
                            has_software_hive = $probeSoftware
                            has_system_evtx = $probeEvtx
                            has_ntoskrnl = $probeKernel
                            has_explorer = $probeExplorer
                            has_users = $probeUsers
                            has_program_files = $probeProgramFiles
                        })

                    if (-not [string]::IsNullOrWhiteSpace($tmpLetter)) {
                        try {
                            Remove-PartitionAccessPath -DiskNumber $diskNumber -PartitionNumber $partNumber -AccessPath ($tmpLetter + ':') -ErrorAction Stop
                        }
                        catch {
                            [void]$issues.Add('Failed to remove temporary mount for disk ' + [string]$diskNumber + ' partition ' + [string]$partNumber + ': ' + $_.Exception.Message)
                        }
                    }
                }
            }
        }
    }
    else {
        try {
            foreach ($logical in @(Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction SilentlyContinue)) {
                if ($null -eq $logical) {
                    continue
                }

                $path = [string]$logical.DeviceID + '\\'
                [void]$volumes.Add([pscustomobject]@{
                        disk_number = -1
                        partition_number = -1
                        drive_letter = [string]$logical.DeviceID
                        volume_guid_path = ''
                        filesystem = [string]$logical.FileSystem
                        health_status = ''
                        size_bytes = [int64]$logical.Size
                        size_remaining_bytes = [int64]$logical.FreeSpace
                    })

                [void]$partitions.Add([pscustomobject]@{
                        disk_number = -1
                        partition_number = -1
                        guid = ''
                        gpt_type = ''
                        mbr_type = ''
                        partition_type = 'logical-disk'
                        is_active = $false
                        is_hidden = $false
                        is_read_only = $false
                        size_bytes = [int64]$logical.Size
                        offset_bytes = 0
                        mount_letter = [string]$logical.DeviceID
                        mount_path = $path
                        filesystem = [string]$logical.FileSystem
                        filesystem_label = [string]$logical.VolumeName
                        health_status = ''
                        operational_status = ''
                        size_remaining_bytes = [int64]$logical.FreeSpace
                        accessible = (Test-Path -Path $path)
                        accessibility_error = ''
                    })
            }
        }
        catch {
            [void]$issues.Add('Fallback storage enumeration failed: ' + $_.Exception.Message)
        }
    }

    $candidatePaths = New-Object System.Collections.ArrayList
    foreach ($part in @($partitions)) {
        $mountPath = [string](Get-DanewSafeProperty -Object $part -Name 'mount_path' -DefaultValue '')
        if (-not [string]::IsNullOrWhiteSpace($mountPath)) {
            [void]$candidatePaths.Add($mountPath)
        }
    }

    foreach ($p in @($InputPath, $RootPath)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$p) -and (Test-Path -Path $p)) {
            [void]$candidatePaths.Add((Resolve-Path -Path $p).Path)
        }
    }

    $uniqueCandidates = @{}
    foreach ($candidate in @($candidatePaths)) {
        $text = [string]$candidate
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        if ($text.Length -gt 3) {
            $text = $text.TrimEnd('\\')
        }

        $uniqueCandidates[$text.ToLowerInvariant()] = $text
    }

    return [pscustomobject]@{
        timestamp = (Get-Date).ToString('s')
        disks = @($disks)
        partitions = @($partitions)
        volumes = @($volumes)
        mount_attempts = @($mountAttempts)
        issues = @($issues)
        candidate_paths = @($uniqueCandidates.Values)
        summary = [pscustomobject]@{
            disk_count = @($disks).Count
            partition_count = @($partitions).Count
            volume_count = @($volumes).Count
            raw_partition_count = @($partitions | Where-Object { [string]$_.filesystem -eq 'RAW' }).Count
            inaccessible_partition_count = @($partitions | Where-Object { -not [bool]$_.accessible }).Count
            mount_attempt_count = @($mountAttempts).Count
        }
    }
}

function Get-DanewBitLockerAnalysis {
    param(
        [Parameter(Mandatory = $true)]
        [object]$StorageAnalysis
    )

    $items = New-Object System.Collections.ArrayList
    $issues = New-Object System.Collections.ArrayList

    $bitLockerCmd = Get-Command -Name Get-BitLockerVolume -ErrorAction SilentlyContinue
    $driveLetters = @($StorageAnalysis.partitions | ForEach-Object { [string]$_.mount_letter } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)

    if ($bitLockerCmd) {
        foreach ($letter in @($driveLetters)) {
            try {
                $bl = Get-BitLockerVolume -MountPoint ($letter + ':') -ErrorAction Stop
                [void]$items.Add([pscustomobject]@{
                        mount_point = $letter + ':'
                        protection_status = [string](Get-DanewSafeProperty -Object $bl -Name 'ProtectionStatus' -DefaultValue '')
                        lock_status = [string](Get-DanewSafeProperty -Object $bl -Name 'LockStatus' -DefaultValue '')
                        volume_status = [string](Get-DanewSafeProperty -Object $bl -Name 'VolumeStatus' -DefaultValue '')
                        encryption_percentage = [int](Get-DanewSafeProperty -Object $bl -Name 'EncryptionPercentage' -DefaultValue 0)
                        encryption_method = [string](Get-DanewSafeProperty -Object $bl -Name 'EncryptionMethod' -DefaultValue '')
                        metadata_accessible = $true
                        source = 'Get-BitLockerVolume'
                    })
            }
            catch {
                [void]$items.Add([pscustomobject]@{
                        mount_point = $letter + ':'
                        protection_status = 'Unknown'
                        lock_status = 'Unknown'
                        volume_status = 'Unknown'
                        encryption_percentage = 0
                        encryption_method = ''
                        metadata_accessible = $false
                        source = 'Get-BitLockerVolume'
                    })
                [void]$issues.Add('BitLocker metadata unavailable for ' + $letter + ': ' + $_.Exception.Message)
            }
        }
    }
    else {
        [void]$issues.Add('BitLocker cmdlets are unavailable in this environment.')
        foreach ($letter in @($driveLetters)) {
            [void]$items.Add([pscustomobject]@{
                    mount_point = $letter + ':'
                    protection_status = 'Unknown'
                    lock_status = 'Unknown'
                    volume_status = 'Unknown'
                    encryption_percentage = 0
                    encryption_method = ''
                    metadata_accessible = $false
                    source = 'Unavailable'
                })
        }
    }

    $lockedCount = @($items | Where-Object { ([string]$_.lock_status -match 'Locked') -or ([string]$_.protection_status -match 'On|Protected') }).Count
    return [pscustomobject]@{
        timestamp = (Get-Date).ToString('s')
        volumes = @($items)
        issues = @($issues)
        summary = [pscustomobject]@{
            volume_count = @($items).Count
            locked_or_protected_count = $lockedCount
            metadata_unavailable_count = @($items | Where-Object { -not [bool]$_.metadata_accessible }).Count
        }
    }
}

function Get-DanewPartitionRoleAnalysis {
    param(
        [Parameter(Mandatory = $true)]
        [object]$StorageAnalysis,
        [AllowEmptyCollection()]
        [object[]]$Installations
    )

    $installRoots = @{}
    foreach ($inst in @($Installations)) {
        $path = [string](Get-DanewSafeProperty -Object $inst -Name 'path' -DefaultValue '')
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            $normalized = $path
            if ($normalized.Length -gt 3) {
                $normalized = $normalized.TrimEnd('\\')
            }
            $installRoots[$normalized.ToLowerInvariant()] = $true
        }
    }

    $rows = @()
    foreach ($part in @($StorageAnalysis.partitions)) {
        $role = 'Unknown'
        $reasons = New-Object System.Collections.ArrayList
        $gptType = [string]$part.gpt_type
        $fs = [string]$part.filesystem
        $label = [string]$part.filesystem_label
        $size = [int64]$part.size_bytes
        $mount = [string]$part.mount_path

        if ($gptType -match 'C12A7328-F81F-11D2-BA4B-00A0C93EC93B') {
            $role = 'EFI'
            [void]$reasons.Add('EFI GPT type detected.')
        }
        elseif ($gptType -match 'E3C9E316-0B5C-4DB8-817D-F92DF00215AE') {
            $role = 'MSR'
            [void]$reasons.Add('MSR GPT type detected.')
        }
        elseif ($gptType -match 'DE94BBA4-06D1-4D40-A16A-BFD50179D6AC' -or $label -match '(?i)recovery') {
            $role = 'Recovery'
            [void]$reasons.Add('Recovery partition signature detected.')
        }
        elseif (-not [string]::IsNullOrWhiteSpace($mount)) {
            $candidate = $mount
            if ($candidate.Length -gt 3) {
                $candidate = $candidate.TrimEnd('\\')
            }
            if ($installRoots.ContainsKey($candidate.ToLowerInvariant())) {
                $role = 'Windows OS'
                [void]$reasons.Add('Windows installation evidence mapped to this partition.')
            }
        }

        if ($role -eq 'Unknown' -and ($fs -match 'NTFS|ReFS|exFAT|FAT32')) {
            if ($fs -match 'FAT32' -and $size -gt 0 -and $size -lt 600MB) {
                $role = 'EFI'
                [void]$reasons.Add('FAT32 partition under 600MB suggests EFI role.')
            }
            else {
                $role = 'Data'
                [void]$reasons.Add('Mounted data filesystem without OS evidence.')
            }
        }

        $rows += [pscustomobject]@{
            disk_number = [int]$part.disk_number
            partition_number = [int]$part.partition_number
            mount_path = [string]$part.mount_path
            mount_letter = [string]$part.mount_letter
            filesystem = $fs
            role = $role
            reasons = @($reasons)
        }
    }

    return [pscustomobject]@{
        timestamp = (Get-Date).ToString('s')
        partitions = $rows
        summary = [pscustomobject]@{
            efi_count = @($rows | Where-Object { $_.role -eq 'EFI' }).Count
            msr_count = @($rows | Where-Object { $_.role -eq 'MSR' }).Count
            recovery_count = @($rows | Where-Object { $_.role -eq 'Recovery' }).Count
            windows_os_count = @($rows | Where-Object { $_.role -eq 'Windows OS' }).Count
            data_count = @($rows | Where-Object { $_.role -eq 'Data' }).Count
            unknown_count = @($rows | Where-Object { $_.role -eq 'Unknown' }).Count
        }
    }
}

function ConvertTo-DanewConfidenceLevel {
    param(
        [int]$Score
    )

    if ($Score -ge 75) {
        return 'High'
    }

    if ($Score -ge 40) {
        return 'Medium'
    }

    return 'Low'
}

function Get-DanewStorageDiagnostics {
    param(
        [Parameter(Mandatory = $true)]
        [object]$StorageAnalysis,
        [Parameter(Mandatory = $true)]
        [object]$BitLockerAnalysis,
        [Parameter(Mandatory = $true)]
        [object]$PartitionRoleAnalysis,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Installations,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$ValidInstallations,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$DiscoveryItems,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$RegistryDetails
    )

    $causes = New-Object System.Collections.ArrayList
    $evidence = New-Object System.Collections.ArrayList

    $diskCount = [int]$StorageAnalysis.summary.disk_count
    $partCount = [int]$StorageAnalysis.summary.partition_count
    $rawCount = [int]$StorageAnalysis.summary.raw_partition_count
    $efiCount = [int]$PartitionRoleAnalysis.summary.efi_count
    $lockedCount = [int]$BitLockerAnalysis.summary.locked_or_protected_count
    $validCount = @($ValidInstallations).Count
    $missingRequiredEvtx = @($DiscoveryItems | Where-Object { $_.status -eq 'missing-required' }).Count
    $inaccessibleEvtx = @($DiscoveryItems | Where-Object { $_.status -in @('inaccessible', 'corrupted') }).Count
    $registryWarnings = @($RegistryDetails | Where-Object { [string]$_.status -ne 'PASS' }).Count

    [void]$evidence.Add('Disks visible: ' + [string]$diskCount)
    [void]$evidence.Add('Partitions visible: ' + [string]$partCount)
    [void]$evidence.Add('EFI partitions: ' + [string]$efiCount)
    [void]$evidence.Add('Valid Windows installations: ' + [string]$validCount)
    [void]$evidence.Add('BitLocker locked/protected volumes: ' + [string]$lockedCount)
    [void]$evidence.Add('RAW partitions: ' + [string]$rawCount)

    if ($diskCount -eq 0) {
        [void]$causes.Add([pscustomobject]@{ cause = 'inaccessible storage controller'; confidence = 'High'; evidence = 'No disks are visible in WinPE.' })
        [void]$causes.Add([pscustomobject]@{ cause = 'missing NVMe visibility'; confidence = 'Medium'; evidence = 'No block device detected; NVMe device may be hidden by driver limitations.' })
    }

    if ($diskCount -gt 0 -and $partCount -eq 0) {
        [void]$causes.Add([pscustomobject]@{ cause = 'corrupted GPT'; confidence = 'Medium'; evidence = 'Disks are present but no partitions are visible.' })
    }

    if ($rawCount -gt 0) {
        [void]$causes.Add([pscustomobject]@{ cause = 'RAW filesystem'; confidence = 'High'; evidence = [string]$rawCount + ' RAW partition(s) detected.' })
    }

    if ($lockedCount -gt 0) {
        [void]$causes.Add([pscustomobject]@{ cause = 'BitLocker locked'; confidence = 'High'; evidence = [string]$lockedCount + ' protected/locked volume(s) detected.' })
    }

    if ($validCount -eq 0 -and $efiCount -gt 0) {
        [void]$causes.Add([pscustomobject]@{ cause = 'missing OS partition'; confidence = 'Medium'; evidence = 'EFI partition exists but no valid Windows OS partition detected.' })
    }

    if ($validCount -eq 0 -and @($Installations).Count -gt 0) {
        [void]$causes.Add([pscustomobject]@{ cause = 'corrupted Windows installation'; confidence = 'Medium'; evidence = 'Windows candidates were found but failed validation checks.' })
    }

    if ($registryWarnings -gt 0) {
        [void]$causes.Add([pscustomobject]@{ cause = 'inaccessible SYSTEM hive'; confidence = 'Medium'; evidence = [string]$registryWarnings + ' installation(s) reported registry metadata extraction warnings.' })
    }

    if ($missingRequiredEvtx -gt 0 -or $inaccessibleEvtx -gt 0) {
        [void]$causes.Add([pscustomobject]@{ cause = 'inaccessible EVTX logs'; confidence = 'Medium'; evidence = 'Required logs missing=' + [string]$missingRequiredEvtx + ', inaccessible/corrupted=' + [string]$inaccessibleEvtx + '.' })
    }

    if (@($causes | Where-Object { $_.cause -eq 'inaccessible storage controller' }).Count -gt 0) {
        [void]$causes.Add([pscustomobject]@{ cause = 'Intel RST/VMD unsupported'; confidence = 'Low'; evidence = 'Storage not visible in WinPE may indicate RST/VMD controller mode without proper support.' })
    }

    $qualityScore = 0
    if ($diskCount -gt 0) { $qualityScore += 20 }
    if ($partCount -gt 0) { $qualityScore += 20 }
    if ($validCount -gt 0) { $qualityScore += 25 }
    if ($registryWarnings -eq 0) { $qualityScore += 15 }
    if ($missingRequiredEvtx -eq 0 -and $inaccessibleEvtx -eq 0) { $qualityScore += 10 }
    if ($lockedCount -eq 0) { $qualityScore += 10 }

    return [pscustomobject]@{
        timestamp = (Get-Date).ToString('s')
        probable_causes = @($causes)
        evidence = @($evidence)
        diagnostics_confidence = ConvertTo-DanewConfidenceLevel -Score $qualityScore
        quality_score = $qualityScore
    }
}

function Write-DanewOfflineFailureReportHtml {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [object]$FailureReport
    )

    $causeRows = @()
    foreach ($cause in @($FailureReport.probable_causes)) {
        $causeRows += @"
<tr>
<td>$([System.Security.SecurityElement]::Escape((Get-DanewLocalizedCauseText $cause.cause)))</td>
<td>$([System.Security.SecurityElement]::Escape((Get-DanewLocalizedConfidenceText $cause.confidence)))</td>
<td>$([System.Security.SecurityElement]::Escape([string]$cause.evidence))</td>
</tr>
"@
    }

    $evidenceList = @()
    foreach ($item in @($FailureReport.evidence)) {
        $evidenceList += '<li>' + [System.Security.SecurityElement]::Escape([string]$item) + '</li>'
    }

    $html = @"
<html>
<head>
<title>Rapport d echec Windows hors ligne Danew</title>
<style>
body { font-family: Segoe UI, Arial, sans-serif; background: #f8fafc; color: #1f2937; margin: 22px; }
.card { background: #ffffff; border: 1px solid #dbe3ea; border-radius: 12px; padding: 16px; margin-bottom: 14px; }
table { width: 100%; border-collapse: collapse; }
th, td { border: 1px solid #dbe3ea; padding: 8px; text-align: left; vertical-align: top; }
th { background: #eef3f7; }
</style>
</head>
<body>
<div class="card">
<h2>Installation Windows hors ligne non detectee</h2>
<p><b>Confiance :</b> $([System.Security.SecurityElement]::Escape((Get-DanewLocalizedConfidenceText $FailureReport.confidence)))</p>
<p><b>Details de detection :</b></p>
<ul>
<li>Partition EFI detectee : $([System.Security.SecurityElement]::Escape((Get-DanewLocalizedBooleanText $FailureReport.detection_details.efi_partition_detected)))</li>
<li>Ruche SYSTEM Windows accessible : $([System.Security.SecurityElement]::Escape((Get-DanewLocalizedBooleanText $FailureReport.detection_details.system_hive_accessible)))</li>
<li>Journaux EVTX accessibles : $([System.Security.SecurityElement]::Escape((Get-DanewLocalizedBooleanText $FailureReport.detection_details.evtx_accessible)))</li>
<li>Peripherique de stockage visible : $([System.Security.SecurityElement]::Escape((Get-DanewLocalizedBooleanText $FailureReport.detection_details.storage_device_visible)))</li>
<li>Partition montee : $([System.Security.SecurityElement]::Escape((Get-DanewLocalizedBooleanText $FailureReport.detection_details.partition_mounted)))</li>
</ul>
</div>
<div class="card">
<h3>Causes possibles</h3>
<table>
<thead><tr><th>Cause</th><th>Confiance</th><th>Preuves</th></tr></thead>
<tbody>
$causeRows
</tbody>
</table>
</div>
<div class="card">
<h3>Preuves</h3>
<ul>
$evidenceList
</ul>
</div>
</body>
</html>
"@

    $html | Set-Content -Path $Path -Encoding UTF8
}

function Write-DanewOfflineAnalysisProgress {
    param(
        [scriptblock]$ProgressCallback,
        [datetime]$StartedAt,
        [int]$Step,
        [int]$TotalSteps,
        [string]$Message
    )

    if (-not $ProgressCallback) {
        return
    }

    if ($TotalSteps -le 0) {
        $TotalSteps = 1
    }

    if ($Step -lt 0) {
        $Step = 0
    }
    elseif ($Step -gt $TotalSteps) {
        $Step = $TotalSteps
    }

    $percent = [int][math]::Round(($Step * 100.0) / $TotalSteps)
    $elapsed = (Get-Date).ToUniversalTime() - $StartedAt.ToUniversalTime()
    $elapsedSec = [int][math]::Round($elapsed.TotalSeconds)
    $etaSec = 0
    if ($percent -gt 0 -and $percent -lt 100) {
        $totalEstimateSec = [int][math]::Round(($elapsedSec * 100.0) / $percent)
        $etaSec = [math]::Max(0, $totalEstimateSec - $elapsedSec)
    }

    $elapsedText = ('{0:00}:{1:00}' -f [int]([math]::Floor($elapsedSec / 60)), [int]($elapsedSec % 60))
    $etaText = ('{0:00}:{1:00}' -f [int]([math]::Floor($etaSec / 60)), [int]($etaSec % 60))
    $line = ('[{0}%] Step {1}/{2} - {3} | Elapsed {4} | ETA {5}' -f $percent, $Step, $TotalSteps, $Message, $elapsedText, $etaText)
    & $ProgressCallback $line
}

function Invoke-DanewOfflineLogsAnalysis {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [Parameter(Mandatory = $true)]
        [object]$Config,
        [int]$MaxEventsPerLog = 2000,
        [scriptblock]$ProgressCallback
    )

    $analysisStartedAt = Get-Date
    $totalProgressSteps = 12

    $effectiveMaxEventsPerLog = [int]$MaxEventsPerLog
    if ($Config -and $Config.PSObject.Properties['offline_max_events_per_log']) {
        $configuredMaxText = [string](Get-DanewSafeProperty -Object $Config -Name 'offline_max_events_per_log' -DefaultValue $effectiveMaxEventsPerLog)
        if ($configuredMaxText -match '^\d+$') {
            $effectiveMaxEventsPerLog = [int]$configuredMaxText
        }
    }

    $fastModeRaw = Get-DanewSafeProperty -Object $Config -Name 'offline_fast_mode' -DefaultValue $false
    $fastModeEnabled = ($fastModeRaw -eq $true) -or ([string]$fastModeRaw -match '^(?i:true|1|yes|on)$')
    if ($fastModeEnabled -and $effectiveMaxEventsPerLog -gt 500) {
        $effectiveMaxEventsPerLog = 500
    }

    $levelFilterRaw = Get-DanewSafeProperty -Object $Config -Name 'offline_event_level_filter' -DefaultValue @()
    $levelFilter = @()
    foreach ($level in @($levelFilterRaw)) {
        if ([string]$level -match '^\d+$') {
            $levelFilter += [int]$level
        }
    }
    if ($fastModeEnabled -and @($levelFilter).Count -eq 0) {
        $levelFilter = @(1, 2, 3)
    }

    $parallelRaw = Get-DanewSafeProperty -Object $Config -Name 'offline_parallel_evtx' -DefaultValue $true
    $parallelEnabled = -not (($parallelRaw -eq $false) -or ([string]$parallelRaw -match '^(?i:false|0|no|off)$'))

    $parallelJobs = [int](Get-DanewSafeProperty -Object $Config -Name 'offline_evtx_parallel_jobs' -DefaultValue 2)
    if ($parallelJobs -lt 1) { $parallelJobs = 1 }
    if ($parallelJobs -gt 8) { $parallelJobs = 8 }

    Write-DanewOfflineAnalysisProgress -ProgressCallback $ProgressCallback -StartedAt $analysisStartedAt -Step 1 -TotalSteps $totalProgressSteps -Message 'Initialize offline analysis'

    if (-not (Test-Path -Path $Config.reports_path)) {
        New-Item -Path $Config.reports_path -ItemType Directory -Force | Out-Null
    }

    $storageAnalysisPath = Join-Path $Config.reports_path 'storage-analysis.json'
    $primaryDiskAnalysisPath = Join-Path $Config.reports_path 'primary-disk-analysis.json'
    $temporaryMountAnalysisPath = Join-Path $Config.reports_path 'temporary-mount-analysis.json'
    $windowsVolumeRankingPath = Join-Path $Config.reports_path 'windows-volume-ranking.json'
    $storageVisibilityDiagnosisPath = Join-Path $Config.reports_path 'storage-visibility-diagnosis.json'
    $storageDiagnosticsPath = Join-Path $Config.reports_path 'storage-diagnostics.json'
    $partitionRolePath = Join-Path $Config.reports_path 'partition-role-analysis.json'
    $bitLockerPath = Join-Path $Config.reports_path 'bitlocker-analysis.json'
    $analysisPath = Join-Path $Config.reports_path 'offline-windows-analysis.json'
    $offlineDiscoveryExclusionsPath = Join-Path $Config.reports_path 'offline-discovery-exclusions.json'
    $discoveryPath = Join-Path $Config.reports_path 'evtx-discovery.json'
    $eventsPath = Join-Path $Config.reports_path 'evtx-events.json'
    $eventsCsvPath = Join-Path $Config.reports_path 'evtx-events.csv'
    $evtxFilteredEventsCsvPath = Join-Path $Config.reports_path 'evtx-filtered-events.csv'
    $evtxCriticalEventsCsvPath = Join-Path $Config.reports_path 'evtx-critical-events.csv'
    $evtxCrashWindowCsvPath = Join-Path $Config.reports_path 'evtx-crash-window.csv'
    $evtxSavSummaryTxtPath = Join-Path $Config.reports_path 'evtx-sav-summary.txt'
    $summaryPath = Join-Path $Config.reports_path 'evtx-summary.json'
    $timelineJsonPath = Join-Path $Config.reports_path 'timeline-raw.json'
    $timelineHtmlPath = Join-Path $Config.reports_path 'timeline-raw.html'
    $evtxByFileHtmlPath = Join-Path $Config.reports_path 'evtx-by-file.html'
    $artifactWriteTimingsPath = Join-Path $Config.reports_path 'offline-artifact-write-timings.json'
    $failureJsonPath = Join-Path $Config.reports_path 'offline-windows-failure-report.json'
    $failureHtmlPath = Join-Path $Config.reports_path 'offline-windows-failure-report.html'

    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $artifactWriteTimings = New-Object System.Collections.ArrayList

    function Invoke-DanewTimedArtifactWrite {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Name,
            [Parameter(Mandatory = $true)]
            [scriptblock]$Action
        )

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $status = 'PASS'
        $errorMessage = ''
        try {
            & $Action
        }
        catch {
            $status = 'FAIL'
            $errorMessage = $_.Exception.Message
            throw
        }
        finally {
            $stopwatch.Stop()
            $elapsedMs = [int][math]::Round($stopwatch.Elapsed.TotalMilliseconds)
            [void]$artifactWriteTimings.Add([pscustomobject]@{
                    name = $Name
                    duration_ms = $elapsedMs
                    status = $status
                    error = $errorMessage
                })
            if ($ProgressCallback) {
                & $ProgressCallback ('[timing] ' + $Name + ' = ' + [string]$elapsedMs + ' ms')
            }
        }
    }

    $storageAnalysis = [pscustomobject]@{ disks = @(); partitions = @(); volumes = @(); mount_attempts = @(); issues = @(); candidate_paths = @(); summary = [pscustomobject]@{ disk_count = 0; partition_count = 0; volume_count = 0; raw_partition_count = 0; inaccessible_partition_count = 0; mount_attempt_count = 0 } }
    $primaryDiskAnalysis = [pscustomobject]@{ disks = @(); preferred_primary_disk = $null; primary_disk_status = 'unknown'; summary = [pscustomobject]@{ total_disks = 0; internal_disks = 0; preferred_disk_number = -1 } }
    $temporaryMountAnalysis = [pscustomobject]@{ attempts = @(); summary = [pscustomobject]@{ attempted_count = 0; mounted_count = 0; inaccessible_count = 0; denied_count = 0 } }
    $windowsVolumeRanking = [pscustomobject]@{ preferred_windows_volume = $null; ranked_volumes = @(); summary = [pscustomobject]@{ confirmed_count = 0; probable_count = 0; weak_count = 0; rejected_count = 0 } }
    $storageVisibilityDiagnosis = [pscustomobject]@{ storage_visibility_case = 'B'; message = 'Internal disk visible but no Windows OS partition detected.'; internal_disk_visible = $false; os_like_partition_count = 0; inaccessible_os_like_partition_count = 0; efi_count = 0; recovery_count = 0; storage_driver_suspected = $false; bitlocker_suspected = $false }
    Write-DanewOfflineAnalysisProgress -ProgressCallback $ProgressCallback -StartedAt $analysisStartedAt -Step 2 -TotalSteps $totalProgressSteps -Message 'Collect storage analysis'
    try {
        $storageAnalysis = Get-DanewStorageAnalysis -InputPath $Config.input_path -RootPath $RootPath
    }
    catch {
        [void]$errors.Add('Storage analysis failed: ' + $_.Exception.Message)
    }

    $bitLockerAnalysis = [pscustomobject]@{ volumes = @(); issues = @(); summary = [pscustomobject]@{ volume_count = 0; locked_or_protected_count = 0; metadata_unavailable_count = 0 } }
    Write-DanewOfflineAnalysisProgress -ProgressCallback $ProgressCallback -StartedAt $analysisStartedAt -Step 3 -TotalSteps $totalProgressSteps -Message 'Evaluate BitLocker and protection state'
    try {
        $bitLockerAnalysis = Get-DanewBitLockerAnalysis -StorageAnalysis $storageAnalysis
    }
    catch {
        [void]$warnings.Add('BitLocker analysis failed: ' + $_.Exception.Message)
    }

    $temporaryMountAnalysis = [pscustomobject]@{
        timestamp = (Get-Date).ToString('s')
        attempts = @($storageAnalysis.mount_attempts)
        summary = [pscustomobject]@{
            attempted_count = @($storageAnalysis.mount_attempts).Count
            mounted_count = @($storageAnalysis.mount_attempts | Where-Object { $_.status -eq 'mounted' }).Count
            inaccessible_count = @($storageAnalysis.mount_attempts | Where-Object { $_.status -eq 'inaccessible' }).Count
            denied_count = @($storageAnalysis.mount_attempts | Where-Object { $_.status -eq 'denied' }).Count
        }
    }

    $installations = @()
    $discoveryExclusions = [pscustomobject]@{ scanned_volumes = @(); excluded_volumes = @(); eligible_volumes = @(); summary = [pscustomobject]@{ scanned_count = 0; excluded_count = 0; eligible_count = 0 } }
    $preferredWindowsVolume = [pscustomobject]@{ preferred_volume = $null; ranked_eligible_volumes = @() }
    $discoveryCase = [pscustomobject]@{ code = 'UNKNOWN'; message = 'Offline discovery was not evaluated.' }
    Write-DanewOfflineAnalysisProgress -ProgressCallback $ProgressCallback -StartedAt $analysisStartedAt -Step 4 -TotalSteps $totalProgressSteps -Message 'Rank candidate volumes and run offline Windows discovery'
    try {
        $allowRemovable = [bool](Get-DanewSafeProperty -Object $Config -Name 'offline_allow_removable_windows_volumes' -DefaultValue $false)
        $primaryDiskAnalysis = Get-DanewPrimaryDiskAnalysis -StorageAnalysis $storageAnalysis -AllowRemovableWindowsVolumes:($allowRemovable)
        $discoveryExclusions = Get-DanewOfflineDiscoveryExclusions -StorageAnalysis $storageAnalysis -RootPath $RootPath -ToolRootPath $Config.input_path -AllowRemovableWindowsVolumes:($allowRemovable)
        $windowsVolumeRanking = Get-DanewWindowsVolumeRanking -StorageAnalysis $storageAnalysis -DiscoveryExclusions $discoveryExclusions -PrimaryDiskAnalysis $primaryDiskAnalysis -BitLockerAnalysis $bitLockerAnalysis
        $storageVisibilityDiagnosis = Get-DanewStorageVisibilityDiagnosis -StorageAnalysis $storageAnalysis -PrimaryDiskAnalysis $primaryDiskAnalysis -WindowsVolumeRanking $windowsVolumeRanking
        $preferredWindowsVolume = Get-DanewPreferredWindowsVolume -DiscoveryExclusions $discoveryExclusions

        $eligiblePaths = @($windowsVolumeRanking.ranked_volumes | Where-Object { $_.eligible -and $_.windows_classification -ne 'Rejected' } | ForEach-Object { [string](Get-DanewSafeProperty -Object $_ -Name 'path' -DefaultValue '') } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if (@($eligiblePaths).Count -eq 0) {
            $eligiblePaths = @($preferredWindowsVolume.ranked_eligible_volumes | ForEach-Object { [string](Get-DanewSafeProperty -Object $_ -Name 'path' -DefaultValue '') } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
        $inputForDiscovery = $Config.input_path
        if (@($eligiblePaths).Count -gt 0) {
            $inputForDiscovery = [string]$eligiblePaths[0]
        }

        $installations = @(Find-DanewOfflineWindowsInstallations -InputPath $inputForDiscovery -RootPath $RootPath -CandidatePaths $eligiblePaths)
    }
    catch {
        [void]$errors.Add('Offline Windows discovery failed: ' + $_.Exception.Message)
    }

    $validInstallations = @($installations | Where-Object { $_.is_valid })
    $inaccessibleCandidates = @($installations | Where-Object { [string](Get-DanewSafeProperty -Object $_ -Name 'accessibility_state' -DefaultValue '') -eq 'inaccessible' })
    $rejectedCandidates = @($installations | Where-Object { -not [bool]$_.is_valid })

    $discoveryCase = Get-DanewOfflineDiscoveryCase -DiscoveryExclusions $discoveryExclusions -Installations $installations -ValidInstallations $validInstallations

    if (@($validInstallations).Count -eq 0) {
        [void]$warnings.Add('No valid offline Windows installation detected. ' + [string]$discoveryCase.message)
        [void]$warnings.Add([string]$storageVisibilityDiagnosis.message)
    }

    $partitionRoleAnalysis = [pscustomobject]@{ partitions = @(); summary = [pscustomobject]@{ efi_count = 0; msr_count = 0; recovery_count = 0; windows_os_count = 0; data_count = 0; unknown_count = 0 } }
    Write-DanewOfflineAnalysisProgress -ProgressCallback $ProgressCallback -StartedAt $analysisStartedAt -Step 5 -TotalSteps $totalProgressSteps -Message 'Classify partition roles'
    try {
        $partitionRoleAnalysis = Get-DanewPartitionRoleAnalysis -StorageAnalysis $storageAnalysis -Installations $installations
    }
    catch {
        [void]$warnings.Add('Partition role classification failed: ' + $_.Exception.Message)
    }

    $registryDetails = @()
    $discoveryItems = @()
    Write-DanewOfflineAnalysisProgress -ProgressCallback $ProgressCallback -StartedAt $analysisStartedAt -Step 6 -TotalSteps $totalProgressSteps -Message 'Extract registry metadata and EVTX discovery list'

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
    $parseModeLabel = if ($parallelEnabled -and $parallelJobs -gt 1) { ('parallel x' + [string]$parallelJobs) } else { 'serial' }
    if (@($levelFilter).Count -gt 0) {
        $parseModeLabel += ', niveaux ' + ([string](@($levelFilter) -join '/'))
    }
    Write-DanewOfflineAnalysisProgress -ProgressCallback $ProgressCallback -StartedAt $analysisStartedAt -Step 7 -TotalSteps $totalProgressSteps -Message ('Parse EVTX records (max ' + [string]$effectiveMaxEventsPerLog + '/log, ' + $parseModeLabel + ')')
    try {
        $parseResult = Get-DanewEvtxEventRecords -DiscoveryItems $discoveryItems -MaxEventsPerLog $effectiveMaxEventsPerLog -EnableParallelPerLog:($parallelEnabled) -MaxParallelJobs $parallelJobs -LevelFilter $levelFilter
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

    Write-DanewOfflineAnalysisProgress -ProgressCallback $ProgressCallback -StartedAt $analysisStartedAt -Step 8 -TotalSteps $totalProgressSteps -Message 'Build event summary and timeline model'
    $summary = Get-DanewEvtxSummary -Events $events -DiscoveryItems $discoveryItems -Issues $issues

    $storageDiagnostics = [pscustomobject]@{ probable_causes = @(); evidence = @(); diagnostics_confidence = 'Low'; quality_score = 0 }
    Write-DanewOfflineAnalysisProgress -ProgressCallback $ProgressCallback -StartedAt $analysisStartedAt -Step 9 -TotalSteps $totalProgressSteps -Message 'Compute storage diagnostics and confidence'
    try {
        $storageDiagnostics = Get-DanewStorageDiagnostics -StorageAnalysis $storageAnalysis -BitLockerAnalysis $bitLockerAnalysis -PartitionRoleAnalysis $partitionRoleAnalysis -Installations $installations -ValidInstallations $validInstallations -DiscoveryItems $discoveryItems -RegistryDetails $registryDetails
    }
    catch {
        [void]$warnings.Add('Storage diagnostics failed: ' + $_.Exception.Message)
    }

    $evidenceScore = 0
    if (@($storageAnalysis.disks).Count -gt 0) { $evidenceScore += 20 }
    if (@($storageAnalysis.partitions).Count -gt 0) { $evidenceScore += 20 }
    if (@($validInstallations).Count -gt 0) { $evidenceScore += 25 }
    if (@($registryDetails | Where-Object { $_.status -eq 'PASS' }).Count -gt 0) { $evidenceScore += 15 }
    if (@($discoveryItems | Where-Object { $_.status -eq 'readable' }).Count -gt 0) { $evidenceScore += 10 }
    if ([int]$bitLockerAnalysis.summary.locked_or_protected_count -eq 0) { $evidenceScore += 10 }
    $confidence = ConvertTo-DanewConfidenceLevel -Score $evidenceScore

    $failureNeeded = (@($validInstallations).Count -eq 0)
    $failureReport = [pscustomobject]@{
        timestamp = (Get-Date).ToString('s')
        status = if ($failureNeeded) { 'generated' } else { 'not-required' }
        confidence = $confidence
        probable_causes = @($storageDiagnostics.probable_causes)
        evidence = @($storageDiagnostics.evidence)
        detected_partitions = @($storageAnalysis.partitions)
        accessible_volumes = @($storageAnalysis.partitions | Where-Object { [bool]$_.accessible })
        inaccessible_volumes = @($storageAnalysis.partitions | Where-Object { -not [bool]$_.accessible })
        detected_efi_partitions = @($partitionRoleAnalysis.partitions | Where-Object { $_.role -eq 'EFI' })
        detected_windows_candidates = @($installations)
        rejection_reasons = @($rejectedCandidates | ForEach-Object { [pscustomobject]@{ path = [string]$_.path; reasons = @($_.rejection_reasons) } })
        discovery_case = [string]$discoveryCase.code
        discovery_case_message = [string]$discoveryCase.message
        primary_disk_status = [string]$primaryDiskAnalysis.primary_disk_status
        storage_visibility_case = [string]$storageVisibilityDiagnosis.storage_visibility_case
        storage_visibility_message = [string]$storageVisibilityDiagnosis.message
        preferred_windows_volume = if ($windowsVolumeRanking.preferred_windows_volume) { $windowsVolumeRanking.preferred_windows_volume } else { $preferredWindowsVolume.preferred_volume }
        ranked_eligible_volumes = if (@($windowsVolumeRanking.ranked_volumes).Count -gt 0) { @($windowsVolumeRanking.ranked_volumes) } else { @($preferredWindowsVolume.ranked_eligible_volumes) }
        temporary_mount_attempts = @($temporaryMountAnalysis.attempts)
        detection_details = [pscustomobject]@{
            efi_partition_detected = if ([int]$partitionRoleAnalysis.summary.efi_count -gt 0) { 'YES' } else { 'NO' }
            system_hive_accessible = if (@($registryDetails | Where-Object { $_.status -eq 'PASS' }).Count -gt 0) { 'YES' } else { 'NO' }
            evtx_accessible = if (@($discoveryItems | Where-Object { $_.status -eq 'readable' }).Count -gt 0) { 'YES' } else { 'NO' }
            storage_device_visible = if (@($storageAnalysis.disks).Count -gt 0 -or @($storageAnalysis.partitions).Count -gt 0) { 'YES' } else { 'NO' }
            partition_mounted = if (@($storageAnalysis.partitions | Where-Object { [bool]$_.accessible }).Count -gt 0) { 'PARTIAL' } else { 'NO' }
            preferred_windows_path = if ($windowsVolumeRanking.preferred_windows_volume) { [string]$windowsVolumeRanking.preferred_windows_volume.path } elseif ($preferredWindowsVolume.preferred_volume) { [string]$preferredWindowsVolume.preferred_volume.path } else { '' }
            preferred_windows_score = if ($windowsVolumeRanking.preferred_windows_volume) { [int]$windowsVolumeRanking.preferred_windows_volume.windows_score } elseif ($preferredWindowsVolume.preferred_volume) { [int]$preferredWindowsVolume.preferred_volume.score } else { 0 }
            c_drive_checked = if (@($windowsVolumeRanking.ranked_volumes | Where-Object { [string]$_.mount_letter -eq 'C' }).Count -gt 0) { 'YES' } else { 'NO' }
            temporary_mount_attempted = if ([int]$temporaryMountAnalysis.summary.attempted_count -gt 0) { 'YES' } else { 'NO' }
            bitlocker_suspected = if ($storageVisibilityDiagnosis.bitlocker_suspected) { 'YES' } else { 'NO' }
            storage_driver_suspected = if ($storageVisibilityDiagnosis.storage_driver_suspected) { 'YES' } else { 'NO' }
        }
    }

    $analysis = [pscustomobject]@{
        timestamp = (Get-Date).ToString('s')
        root_path = $RootPath
        input_path = $Config.input_path
        scanned_volumes = @($discoveryExclusions.scanned_volumes)
        excluded_volumes = @($discoveryExclusions.excluded_volumes)
        eligible_volumes = @($discoveryExclusions.eligible_volumes)
        primary_disk_analysis = $primaryDiskAnalysis
        temporary_mount_analysis = $temporaryMountAnalysis
        windows_volume_ranking = $windowsVolumeRanking
        storage_visibility_diagnosis = $storageVisibilityDiagnosis
        primary_disk_status = [string]$primaryDiskAnalysis.primary_disk_status
        storage_visibility_case = [string]$storageVisibilityDiagnosis.storage_visibility_case
        preferred_windows_volume = if ($windowsVolumeRanking.preferred_windows_volume) { $windowsVolumeRanking.preferred_windows_volume } else { $preferredWindowsVolume.preferred_volume }
        ranked_eligible_volumes = if (@($windowsVolumeRanking.ranked_volumes).Count -gt 0) { @($windowsVolumeRanking.ranked_volumes) } else { @($preferredWindowsVolume.ranked_eligible_volumes) }
        installation_candidates = $installations
        valid_installations = $validInstallations
        inaccessible_candidates = $inaccessibleCandidates
        rejected_candidates = $rejectedCandidates
        rejection_reasons = @($rejectedCandidates | ForEach-Object { [pscustomobject]@{ path = [string]$_.path; reasons = @($_.rejection_reasons) } })
        discovery_case = [string]$discoveryCase.code
        discovery_case_message = [string]$discoveryCase.message
        detection_confidence = $confidence
        evidence_score = $evidenceScore
        storage_summary = $storageAnalysis.summary
        bitlocker_summary = $bitLockerAnalysis.summary
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

    $storageAnalysisReport = [pscustomobject]@{
        timestamp = $storageAnalysis.timestamp
        disks = @($storageAnalysis.disks)
        partitions = @($storageAnalysis.partitions)
        volumes = @($storageAnalysis.volumes)
        mount_attempts = @($storageAnalysis.mount_attempts)
        issues = @($storageAnalysis.issues)
        candidate_paths = @($storageAnalysis.candidate_paths)
        summary = $storageAnalysis.summary
        scanned_volumes = @($discoveryExclusions.scanned_volumes)
        excluded_volumes = @($discoveryExclusions.excluded_volumes)
        eligible_volumes = @($discoveryExclusions.eligible_volumes)
        discovery_case = [string]$discoveryCase.code
        discovery_case_message = [string]$discoveryCase.message
        primary_disk_status = [string]$primaryDiskAnalysis.primary_disk_status
        storage_visibility_case = [string]$storageVisibilityDiagnosis.storage_visibility_case
        preferred_windows_volume = if ($windowsVolumeRanking.preferred_windows_volume) { $windowsVolumeRanking.preferred_windows_volume } else { $preferredWindowsVolume.preferred_volume }
        ranked_eligible_volumes = if (@($windowsVolumeRanking.ranked_volumes).Count -gt 0) { @($windowsVolumeRanking.ranked_volumes) } else { @($preferredWindowsVolume.ranked_eligible_volumes) }
    }

    Write-DanewOfflineAnalysisProgress -ProgressCallback $ProgressCallback -StartedAt $analysisStartedAt -Step 10 -TotalSteps $totalProgressSteps -Message 'Write JSON and CSV artifacts'
    Invoke-DanewTimedArtifactWrite -Name 'storage-analysis.json' -Action {
        $storageAnalysisReport | ConvertTo-Json -Depth 40 | Set-Content -Path $storageAnalysisPath -Encoding UTF8
    }
    Invoke-DanewTimedArtifactWrite -Name 'primary-disk-analysis.json' -Action {
        $primaryDiskAnalysis | ConvertTo-Json -Depth 40 | Set-Content -Path $primaryDiskAnalysisPath -Encoding UTF8
    }
    Invoke-DanewTimedArtifactWrite -Name 'temporary-mount-analysis.json' -Action {
        $temporaryMountAnalysis | ConvertTo-Json -Depth 40 | Set-Content -Path $temporaryMountAnalysisPath -Encoding UTF8
    }
    Invoke-DanewTimedArtifactWrite -Name 'windows-volume-ranking.json' -Action {
        $windowsVolumeRanking | ConvertTo-Json -Depth 40 | Set-Content -Path $windowsVolumeRankingPath -Encoding UTF8
    }
    Invoke-DanewTimedArtifactWrite -Name 'storage-visibility-diagnosis.json' -Action {
        $storageVisibilityDiagnosis | ConvertTo-Json -Depth 40 | Set-Content -Path $storageVisibilityDiagnosisPath -Encoding UTF8
    }
    Invoke-DanewTimedArtifactWrite -Name 'offline-discovery-exclusions.json' -Action {
        $discoveryExclusions | ConvertTo-Json -Depth 40 | Set-Content -Path $offlineDiscoveryExclusionsPath -Encoding UTF8
    }
    Invoke-DanewTimedArtifactWrite -Name 'storage-diagnostics.json' -Action {
        $storageDiagnostics | ConvertTo-Json -Depth 40 | Set-Content -Path $storageDiagnosticsPath -Encoding UTF8
    }
    Invoke-DanewTimedArtifactWrite -Name 'partition-role-analysis.json' -Action {
        $partitionRoleAnalysis | ConvertTo-Json -Depth 40 | Set-Content -Path $partitionRolePath -Encoding UTF8
    }
    Invoke-DanewTimedArtifactWrite -Name 'bitlocker-analysis.json' -Action {
        $bitLockerAnalysis | ConvertTo-Json -Depth 40 | Set-Content -Path $bitLockerPath -Encoding UTF8
    }
    Invoke-DanewTimedArtifactWrite -Name 'offline-windows-analysis.json' -Action {
        $analysis | ConvertTo-Json -Depth 40 | Set-Content -Path $analysisPath -Encoding UTF8
    }
    Invoke-DanewTimedArtifactWrite -Name 'evtx-discovery.json' -Action {
        @($discoveryItems) | ConvertTo-Json -Depth 30 | Set-Content -Path $discoveryPath -Encoding UTF8
    }
    Invoke-DanewTimedArtifactWrite -Name 'evtx-events.json' -Action {
        @($events) | ConvertTo-Json -Depth 30 | Set-Content -Path $eventsPath -Encoding UTF8
    }

    $csvRows = @($events | Select-Object timestamp, level, provider, event_id, channel, computer, task_category, opcode, keywords, source_file, installation_root, message)
    Invoke-DanewTimedArtifactWrite -Name 'evtx-events.csv' -Action {
        if (@($csvRows).Count -gt 0) {
            $csvRows | Export-Csv -Path $eventsCsvPath -NoTypeInformation -Encoding UTF8
        }
        else {
            'timestamp,level,provider,event_id,channel,computer,task_category,opcode,keywords,source_file,installation_root,message' | Set-Content -Path $eventsCsvPath -Encoding ASCII
        }
    }

    Invoke-DanewTimedArtifactWrite -Name 'evtx-summary.json' -Action {
        $summary | ConvertTo-Json -Depth 20 | Set-Content -Path $summaryPath -Encoding UTF8
    }
    Invoke-DanewTimedArtifactWrite -Name 'timeline-raw.json' -Action {
        $timeline | ConvertTo-Json -Depth 40 | Set-Content -Path $timelineJsonPath -Encoding UTF8
    }

    $targetedExports = $null
    Invoke-DanewTimedArtifactWrite -Name 'evtx-targeted-exports' -Action {
        $targetedExports = Write-DanewEvtxTargetedExports -RootPath $RootPath -ReportsPath $Config.reports_path -Events $events -Summary $summary
    }

    Write-DanewOfflineAnalysisProgress -ProgressCallback $ProgressCallback -StartedAt $analysisStartedAt -Step 11 -TotalSteps $totalProgressSteps -Message 'Write timeline HTML and failure report'
    Invoke-DanewTimedArtifactWrite -Name 'timeline-raw.html' -Action {
        if ($fastModeEnabled) {
            Write-DanewFastTimelineHtml -Path $timelineHtmlPath -Events $events -Summary $summary -ByFileHtmlPath $evtxByFileHtmlPath -TimelineJsonPath $timelineJsonPath
        }
        else {
            Write-DanewTimelineHtml -Path $timelineHtmlPath -Events $events -Summary $summary
        }
    }
    try {
        Invoke-DanewTimedArtifactWrite -Name 'evtx-by-file.html' -Action {
            Write-DanewEvtxByFileHtml -Path $evtxByFileHtmlPath -Events $events -Summary $summary
        }
    }
    catch {
        [void]$warnings.Add('EVTX by-file HTML generation failed: ' + $_.Exception.Message)
        $evtxByFileHtmlPath = ''
    }

    if ($failureNeeded) {
        Invoke-DanewTimedArtifactWrite -Name 'offline-windows-failure-report.json' -Action {
            $failureReport | ConvertTo-Json -Depth 40 | Set-Content -Path $failureJsonPath -Encoding UTF8
        }
        Invoke-DanewTimedArtifactWrite -Name 'offline-windows-failure-report.html' -Action {
            Write-DanewOfflineFailureReportHtml -Path $failureHtmlPath -FailureReport $failureReport
        }
    }
    else {
        Invoke-DanewTimedArtifactWrite -Name 'offline-windows-failure-report-cleanup' -Action {
        if (Test-Path -Path $failureJsonPath) {
            Remove-Item -Path $failureJsonPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -Path $failureHtmlPath) {
            Remove-Item -Path $failureHtmlPath -Force -ErrorAction SilentlyContinue
        }
        }
    }

    $artifactWriteTimingReport = [pscustomobject]@{
        timestamp = (Get-Date).ToString('s')
        total_duration_ms = [int](@($artifactWriteTimings | Measure-Object -Property duration_ms -Sum).Sum)
        steps = @($artifactWriteTimings)
    }
    $artifactWriteTimingReport | ConvertTo-Json -Depth 10 | Set-Content -Path $artifactWriteTimingsPath -Encoding UTF8

    $overall = 'PASS'
    if (@($errors).Count -gt 0) {
        $overall = 'FAIL'
    }
    elseif (@($warnings).Count -gt 0) {
        $overall = 'WARNING'
    }

    Write-DanewOfflineAnalysisProgress -ProgressCallback $ProgressCallback -StartedAt $analysisStartedAt -Step 12 -TotalSteps $totalProgressSteps -Message ('Completed with overall status ' + $overall)

    return [pscustomobject]@{
        overall_status = $overall
        summary = $summary
        discovery_case = [string]$discoveryCase.code
        discovery_case_message = [string]$discoveryCase.message
        primary_disk_status = [string]$primaryDiskAnalysis.primary_disk_status
        storage_visibility_case = [string]$storageVisibilityDiagnosis.storage_visibility_case
        preferred_windows_volume = if ($windowsVolumeRanking.preferred_windows_volume) { $windowsVolumeRanking.preferred_windows_volume } else { $preferredWindowsVolume.preferred_volume }
        temporary_mount_attempts = @($temporaryMountAnalysis.attempts)
        warnings = @($warnings)
        errors = @($errors)
        artifacts = [pscustomobject]@{
            storage_analysis = $storageAnalysisPath
            primary_disk_analysis = $primaryDiskAnalysisPath
            temporary_mount_analysis = $temporaryMountAnalysisPath
            windows_volume_ranking = $windowsVolumeRankingPath
            storage_visibility_diagnosis = $storageVisibilityDiagnosisPath
            offline_discovery_exclusions = $offlineDiscoveryExclusionsPath
            storage_diagnostics = $storageDiagnosticsPath
            partition_role_analysis = $partitionRolePath
            bitlocker_analysis = $bitLockerPath
            offline_windows_analysis = $analysisPath
            evtx_discovery = $discoveryPath
            evtx_events_json = $eventsPath
            evtx_events_csv = $eventsCsvPath
            evtx_filtered_events_csv = $evtxFilteredEventsCsvPath
            evtx_critical_events_csv = $evtxCriticalEventsCsvPath
            evtx_crash_window_csv = $evtxCrashWindowCsvPath
            evtx_sav_summary_txt = $evtxSavSummaryTxtPath
            evtx_summary = $summaryPath
            timeline_raw_json = $timelineJsonPath
            timeline_raw_html = $timelineHtmlPath
            evtx_by_file_html = $evtxByFileHtmlPath
            artifact_write_timings = $artifactWriteTimingsPath
            offline_windows_failure_report_json = if ($failureNeeded) { $failureJsonPath } else { '' }
            offline_windows_failure_report_html = if ($failureNeeded) { $failureHtmlPath } else { '' }
        }
        evtx_targeted_exports = $targetedExports
        failure_report = $failureReport
    }
}
