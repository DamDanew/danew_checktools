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

function Write-DanewTimelineHtml {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [object[]]$Events,
        [object]$Summary
    )

    $rows = @()
    $index = 0
    foreach ($evt in @($Events)) {
        $index += 1
        if ($index -gt 4000) {
            break
        }

        $rowSearch = ConvertTo-DanewReportHtmlText ($evt.timestamp, $evt.level, $evt.provider, $evt.event_id, $evt.channel, $evt.source_file, $evt.message -join ' ')
        $rows += @"
<tr data-search-row="$rowSearch">
<td>$([System.Security.SecurityElement]::Escape([string]$evt.timestamp))</td>
<td>$([System.Security.SecurityElement]::Escape([string]$evt.level))</td>
<td>$([System.Security.SecurityElement]::Escape([string]$evt.provider))</td>
<td>$([System.Security.SecurityElement]::Escape([string]$evt.event_id))</td>
<td>$([System.Security.SecurityElement]::Escape([string]$evt.channel))</td>
<td>$([System.Security.SecurityElement]::Escape([string]$evt.source_file))</td>
<td>$([System.Security.SecurityElement]::Escape([string]$evt.message))</td>
</tr>
"@
    }

    $notice = ''
    if (@($Events).Count -gt 4000) {
        $notice = '<p><b>Note:</b> HTML view truncated to first 4000 events. Full data is available in timeline-raw.json.</p>'
    }

    $metrics = @(
        (New-DanewMetricCardHtml -Label 'Total events' -Value $Summary.total_events -Tone 'info')
        (New-DanewMetricCardHtml -Label 'Missing required logs' -Value $Summary.missing_required_logs -Tone $(if ([int]$Summary.missing_required_logs -gt 0) { 'warning' } else { 'pass' }))
        (New-DanewMetricCardHtml -Label 'Parse issues' -Value $Summary.parse_issue_count -Tone $(if ([int]$Summary.parse_issue_count -gt 0) { 'warning' } else { 'pass' }))
        (New-DanewMetricCardHtml -Label 'Rendered rows' -Value @($rows).Count -Tone 'ready')
    ) -join ''

    $meta = New-DanewReportMetaListHtml -Items @(
        [pscustomobject]@{ label = 'Timeline source'; value = 'timeline-raw.json' }
        [pscustomobject]@{ label = 'HTML cap'; value = '4000 rows' }
        [pscustomobject]@{ label = 'Offline mode'; value = 'embedded CSS and JS only' }
    )

    $overviewBody = '<div class="split-grid">' + (New-DanewMetricCardHtml -Label 'Event stream status' -Value $(if ([int]$Summary.parse_issue_count -gt 0) { 'warning' } else { 'stable' }) -Tone $(if ([int]$Summary.parse_issue_count -gt 0) { 'warning' } else { 'pass' })) + (New-DanewMetricCardHtml -Label 'Log coverage' -Value $(if ([int]$Summary.missing_required_logs -gt 0) { 'partial' } else { 'complete' }) -Tone $(if ([int]$Summary.missing_required_logs -gt 0) { 'warning' } else { 'pass' })) + '</div>' + $notice
    $sections = @(
        (New-DanewReportSectionHtml -Title 'Timeline Overview' -Caption 'Use the filter box to narrow by provider, level, source file, or message text.' -SearchText 'timeline overview total events missing logs parse issues' -BodyHtml $overviewBody)
        (New-DanewReportSectionHtml -Title 'Timeline Events' -Caption 'The HTML report renders the first 4000 events. The JSON artifact remains the full source of truth.' -SearchText 'timeline events provider level event id message source file' -BodyHtml (New-DanewReportTableHtml -Headers @('Timestamp', 'Level', 'Provider', 'Event ID', 'Channel', 'Source File', 'Message') -Rows $rows -EmptyMessage 'No events match the current filter.'))
    )

    $html = New-DanewInteractiveReportHtml -Title 'Danew Offline Timeline' -Subtitle 'Searchable event chronology for offline EVTX analysis with print-safe output.' -Status $(if ([int]$Summary.parse_issue_count -gt 0 -or [int]$Summary.missing_required_logs -gt 0) { 'WARNING' } else { 'PASS' }) -Eyebrow 'Timeline raw view' -HeroMetricsHtml ('<div class="hero-metrics">' + $metrics + '</div>') -MetaHtml $meta -Sections $sections -SearchPlaceholder 'Filter events by provider, level, event id, source file, or message'

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
<td>$([System.Security.SecurityElement]::Escape([string]$cause.cause))</td>
<td>$([System.Security.SecurityElement]::Escape([string]$cause.confidence))</td>
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
<title>Danew Offline Windows Failure Report</title>
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
<h2>Offline Windows installation not detected</h2>
<p><b>Confidence:</b> $([System.Security.SecurityElement]::Escape([string]$FailureReport.confidence))</p>
<p><b>Detection details:</b></p>
<ul>
<li>EFI partition detected: $([System.Security.SecurityElement]::Escape([string]$FailureReport.detection_details.efi_partition_detected))</li>
<li>Windows SYSTEM hive accessible: $([System.Security.SecurityElement]::Escape([string]$FailureReport.detection_details.system_hive_accessible))</li>
<li>EVTX logs accessible: $([System.Security.SecurityElement]::Escape([string]$FailureReport.detection_details.evtx_accessible))</li>
<li>Storage device visible: $([System.Security.SecurityElement]::Escape([string]$FailureReport.detection_details.storage_device_visible))</li>
<li>Partition mounted: $([System.Security.SecurityElement]::Escape([string]$FailureReport.detection_details.partition_mounted))</li>
</ul>
</div>
<div class="card">
<h3>Possible causes</h3>
<table>
<thead><tr><th>Cause</th><th>Confidence</th><th>Evidence</th></tr></thead>
<tbody>
$causeRows
</tbody>
</table>
</div>
<div class="card">
<h3>Evidence</h3>
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
    $summaryPath = Join-Path $Config.reports_path 'evtx-summary.json'
    $timelineJsonPath = Join-Path $Config.reports_path 'timeline-raw.json'
    $timelineHtmlPath = Join-Path $Config.reports_path 'timeline-raw.html'
    $failureJsonPath = Join-Path $Config.reports_path 'offline-windows-failure-report.json'
    $failureHtmlPath = Join-Path $Config.reports_path 'offline-windows-failure-report.html'

    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList

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
    Write-DanewOfflineAnalysisProgress -ProgressCallback $ProgressCallback -StartedAt $analysisStartedAt -Step 7 -TotalSteps $totalProgressSteps -Message 'Parse EVTX records'
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
    $storageAnalysisReport | ConvertTo-Json -Depth 40 | Set-Content -Path $storageAnalysisPath -Encoding UTF8
    $primaryDiskAnalysis | ConvertTo-Json -Depth 40 | Set-Content -Path $primaryDiskAnalysisPath -Encoding UTF8
    $temporaryMountAnalysis | ConvertTo-Json -Depth 40 | Set-Content -Path $temporaryMountAnalysisPath -Encoding UTF8
    $windowsVolumeRanking | ConvertTo-Json -Depth 40 | Set-Content -Path $windowsVolumeRankingPath -Encoding UTF8
    $storageVisibilityDiagnosis | ConvertTo-Json -Depth 40 | Set-Content -Path $storageVisibilityDiagnosisPath -Encoding UTF8
    $discoveryExclusions | ConvertTo-Json -Depth 40 | Set-Content -Path $offlineDiscoveryExclusionsPath -Encoding UTF8
    $storageDiagnostics | ConvertTo-Json -Depth 40 | Set-Content -Path $storageDiagnosticsPath -Encoding UTF8
    $partitionRoleAnalysis | ConvertTo-Json -Depth 40 | Set-Content -Path $partitionRolePath -Encoding UTF8
    $bitLockerAnalysis | ConvertTo-Json -Depth 40 | Set-Content -Path $bitLockerPath -Encoding UTF8
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
    Write-DanewOfflineAnalysisProgress -ProgressCallback $ProgressCallback -StartedAt $analysisStartedAt -Step 11 -TotalSteps $totalProgressSteps -Message 'Write timeline HTML and failure report'
    Write-DanewTimelineHtml -Path $timelineHtmlPath -Events $events -Summary $summary

    if ($failureNeeded) {
        $failureReport | ConvertTo-Json -Depth 40 | Set-Content -Path $failureJsonPath -Encoding UTF8
        Write-DanewOfflineFailureReportHtml -Path $failureHtmlPath -FailureReport $failureReport
    }
    else {
        if (Test-Path -Path $failureJsonPath) {
            Remove-Item -Path $failureJsonPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -Path $failureHtmlPath) {
            Remove-Item -Path $failureHtmlPath -Force -ErrorAction SilentlyContinue
        }
    }

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
            evtx_summary = $summaryPath
            timeline_raw_json = $timelineJsonPath
            timeline_raw_html = $timelineHtmlPath
            offline_windows_failure_report_json = if ($failureNeeded) { $failureJsonPath } else { '' }
            offline_windows_failure_report_html = if ($failureNeeded) { $failureHtmlPath } else { '' }
        }
        failure_report = $failureReport
    }
}
