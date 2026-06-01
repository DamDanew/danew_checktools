Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$reportShellPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'report\HtmlReportShell.ps1'
if (Test-Path -Path $reportShellPath) {
    . $reportShellPath
}

function Get-DanewCrashSafeProperty {
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

function Read-DanewJsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        $DefaultValue = $null
    )

    if (-not (Test-Path -Path $Path)) {
        return $DefaultValue
    }

    try {
        $raw = Get-Content -Path $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $DefaultValue
        }
        return ($raw | ConvertFrom-Json)
    }
    catch {
        return $DefaultValue
    }
}

function Convert-DanewCrashConfidenceLevel {
    param([int]$Score)

    if ($Score -ge 75) {
        return 'High'
    }
    if ($Score -ge 40) {
        return 'Medium'
    }
    return 'Low'
}

function Convert-DanewCrashSeverityLevel {
    param(
        [string]$PrimaryCause,
        [int]$EvidenceCount,
        [int]$EventCount,
        [int]$Score
    )

    if ($PrimaryCause -in @('inaccessible SYSTEM hive', 'storage driver incompatibility', 'failing SSD', 'inaccessible NVMe controller', 'corrupted BCD', 'BitLocker lock state') -and $Score -ge 70) {
        return 'CRITICAL'
    }

    if ($EventCount -ge 6 -and $EvidenceCount -ge 3 -and $Score -ge 45) {
        return 'WARNING'
    }

    if ($EventCount -ge 3 -or $Score -ge 30) {
        return 'WARNING'
    }

    return 'INFO'
}

function Get-DanewWerMessageField {
    param(
        [string]$Message,
        [string]$FieldName
    )

    if ([string]::IsNullOrWhiteSpace($Message) -or [string]::IsNullOrWhiteSpace($FieldName)) {
        return ''
    }

    $escaped = [Regex]::Escape($FieldName)
    $match = [Regex]::Match($Message, "(?im)^\s*$escaped\s*:\s*(.*)$")
    if ($match.Success) {
        return [string]$match.Groups[1].Value.Trim()
    }

    return ''
}

function Get-DanewCrashRecordFingerprint {
    param([object]$LogRecord)

    $provider = [string](Get-DanewCrashSafeProperty -Object $LogRecord -Name 'provider' -DefaultValue '')
    $eventId = [string](Get-DanewCrashSafeProperty -Object $LogRecord -Name 'event_id' -DefaultValue '')
    $message = [string](Get-DanewCrashSafeProperty -Object $LogRecord -Name 'message' -DefaultValue '')
    $channel = [string](Get-DanewCrashSafeProperty -Object $LogRecord -Name 'channel' -DefaultValue '')

    $isWer = ($provider -match 'Windows Error Reporting') -or ($message -match '(?i)Event Name:\s*')
    if (-not $isWer) {
        $normalized = [Regex]::Replace(($provider + '|' + $eventId + '|' + $channel + '|' + $message), '\s+', ' ').Trim().ToLowerInvariant()
        return $normalized
    }

    $eventName = Get-DanewWerMessageField -Message $message -FieldName 'Event Name'
    $p1 = Get-DanewWerMessageField -Message $message -FieldName 'P1'
    $p2 = Get-DanewWerMessageField -Message $message -FieldName 'P2'
    $p3 = Get-DanewWerMessageField -Message $message -FieldName 'P3'
    $p4 = Get-DanewWerMessageField -Message $message -FieldName 'P4'
    $p5 = Get-DanewWerMessageField -Message $message -FieldName 'P5'
    $p9 = Get-DanewWerMessageField -Message $message -FieldName 'P9'

    # Report Id changes on every occurrence and is intentionally excluded from the fingerprint.
    $werKey = "wer|$eventName|$p1|$p2|$p3|$p4|$p5|$p9"
    return [Regex]::Replace($werKey, '\s+', ' ').Trim().ToLowerInvariant()
}

function Optimize-DanewCrashLogRecords {
    param(
        [AllowEmptyCollection()]
        [object[]]$LogRecords
    )

    $deduped = New-Object System.Collections.ArrayList
    $indexByFingerprint = @{}
    $removedTotal = 0
    $removedWer = 0

    foreach ($logRecord in @($LogRecords)) {
        if ($null -eq $logRecord) {
            continue
        }

        $fingerprint = Get-DanewCrashRecordFingerprint -LogRecord $logRecord
        if (-not $indexByFingerprint.ContainsKey($fingerprint)) {
            $row = [ordered]@{}
            foreach ($prop in $logRecord.PSObject.Properties) {
                $row[$prop.Name] = $prop.Value
            }
            $row['duplicate_count'] = 1

            $entry = [pscustomobject]$row
            [void]$deduped.Add($entry)
            $indexByFingerprint[$fingerprint] = @($deduped).Count - 1
            continue
        }

        $removedTotal += 1
        $provider = [string](Get-DanewCrashSafeProperty -Object $logRecord -Name 'provider' -DefaultValue '')
        $message = [string](Get-DanewCrashSafeProperty -Object $logRecord -Name 'message' -DefaultValue '')
        if (($provider -match 'Windows Error Reporting') -or ($message -match '(?i)Event Name:\s*')) {
            $removedWer += 1
        }

        $existingIndex = [int]$indexByFingerprint[$fingerprint]
        $existing = $deduped[$existingIndex]
        $existing.duplicate_count = [int](Get-DanewCrashSafeProperty -Object $existing -Name 'duplicate_count' -DefaultValue 1) + 1
    }

    return [pscustomobject]@{
        records = @($deduped)
        input_count = @($LogRecords).Count
        output_count = @($deduped).Count
        removed_duplicates = $removedTotal
        removed_wer_duplicates = $removedWer
    }
}

function Get-DanewCrashClassification {
    param(
        [AllowEmptyCollection()]
        [object[]]$LogRecords
    )

    $classified = New-Object System.Collections.ArrayList
    $signals = @{}

    foreach ($logRecord in @($LogRecords)) {
        $provider = [string](Get-DanewCrashSafeProperty -Object $logRecord -Name 'provider' -DefaultValue '')
        $eventId = [int](Get-DanewCrashSafeProperty -Object $logRecord -Name 'event_id' -DefaultValue 0)
        $message = [string](Get-DanewCrashSafeProperty -Object $logRecord -Name 'message' -DefaultValue '')
        $channel = [string](Get-DanewCrashSafeProperty -Object $logRecord -Name 'channel' -DefaultValue '')
        $text = ($provider + ' ' + $message + ' ' + $channel).ToLowerInvariant()

        $categories = New-Object System.Collections.ArrayList
        $criticality = 0

        if ($provider -match 'Kernel-Power' -or $eventId -eq 41) { [void]$categories.Add('Kernel-Power shutdown'); $criticality += 4 }
        if ($provider -match 'BugCheck' -or $eventId -eq 1001 -or $text -match 'bugcheck|bsod|blue screen|stop code|0x7b') { [void]$categories.Add('BugCheck / BSOD'); $criticality += 5 }
        if ($provider -match 'WHEA' -or $eventId -in @(17,18,19,47)) { [void]$categories.Add('WHEA hardware errors'); $criticality += 4 }
        if ($provider -match 'WindowsUpdateClient' -or $text -match 'windows update|update') { [void]$categories.Add('Windows Update failure'); $criticality += 3 }
        if ($provider -match 'DriverFrameworks' -or $text -match 'driverframeworks|driver framework') { [void]$categories.Add('DriverFrameworks issues'); $criticality += 3 }
        if ($provider -match 'Service Control Manager' -or $eventId -in @(7000,7001,7009,7011,7031,7034)) { [void]$categories.Add('Service startup failures'); $criticality += 2 }
        if ($provider -match 'Ntfs' -or $provider -match 'Disk' -or $eventId -in @(7,11,15,51,55,57,129,153,157,161)) { [void]$categories.Add('Disk / Storage'); $criticality += 4 }
        if ($eventId -in @(55,57) -or $text -match 'ntfs|file system corruption|corrupt') { [void]$categories.Add('NTFS corruption'); $criticality += 4 }
        if ($text -match 'inaccessible_boot_device|0x7b|boot device') { [void]$categories.Add('Boot / BCD'); $criticality += 5 }
        if ($provider -match 'BitLocker|FVE' -or $text -match 'bitlocker|encrypted volume|locked') { [void]$categories.Add('BitLocker related issues'); $criticality += 3 }
        if ($text -match 'unexpected reboot|reboot|shutdown') { [void]$categories.Add('Unexpected reboot'); $criticality += 2 }
        if ($text -match 'thermal|temperature|overheat|power') { [void]$categories.Add('Thermal / power instability'); $criticality += 2 }
        if ($text -match 'recovery loop|restart loop|boot failure') { [void]$categories.Add('Recovery loop indicators'); $criticality += 3 }
        if ($eventId -in @(7045,4697) -or $text -match 'malware|persistence|service installed') { [void]$categories.Add('Security / malware persistence indicators'); $criticality += 2 }
        if ($text -match 'memory|page fault|0x1a|0x50|0xc4') { [void]$categories.Add('Memory instability'); $criticality += 3 }
        if (@($categories).Count -eq 0) { [void]$categories.Add('Unclassified') }

        foreach ($category in @($categories)) {
            if (-not $signals.ContainsKey($category)) {
                $signals[$category] = 0
            }
            $signals[$category] += 1
        }

        [void]$classified.Add([pscustomobject]@{
            timestamp = [string](Get-DanewCrashSafeProperty -Object $logRecord -Name 'timestamp' -DefaultValue '')
            provider = $provider
            event_id = $eventId
            channel = $channel
            message = $message
            categories = @($categories)
            criticality = $criticality
            source_file = [string](Get-DanewCrashSafeProperty -Object $logRecord -Name 'source_file' -DefaultValue '')
            installation_root = [string](Get-DanewCrashSafeProperty -Object $logRecord -Name 'installation_root' -DefaultValue '')
        })
    }

    return [pscustomobject]@{
        records = @($classified.ToArray())
        category_counts = [pscustomobject]$signals
    }
}

function Get-DanewCrashTimelineIntelligence {
    param(
        [AllowEmptyCollection()]
        [object[]]$LogRecords,
        [AllowEmptyCollection()]
        [object[]]$ClassifiedRecords
    )

    $ordered = @($LogRecords | Sort-Object timestamp)
    $intelligence = New-Object System.Collections.ArrayList

    $kernelPowerEvents = @($ClassifiedRecords | Where-Object { $_.categories -contains 'Kernel-Power shutdown' })
    if (@($kernelPowerEvents).Count -ge 2) {
        [void]$intelligence.Add([pscustomobject]@{
                pattern = 'Repeated Kernel-Power loops'
                confidence = 'Medium'
                evidence = @($kernelPowerEvents | Select-Object -First 6)
                summary = 'Multiple Kernel-Power shutdown events were detected.'
            })
    }

    $bugcheckEvents = @($ClassifiedRecords | Where-Object { $_.categories -contains 'BugCheck / BSOD' })
    if (@($bugcheckEvents).Count -ge 2) {
        [void]$intelligence.Add([pscustomobject]@{
                pattern = 'Repeated BugCheck loops'
                confidence = 'High'
                evidence = @($bugcheckEvents | Select-Object -First 6)
                summary = 'Multiple bugcheck events were detected across the timeline.'
            })
    }

    $updateEvents = @($ClassifiedRecords | Where-Object { $_.categories -contains 'Windows Update failure' })
    $driverEvents = @($ClassifiedRecords | Where-Object { $_.categories -contains 'DriverFrameworks issues' -or $_.categories -contains 'Driver failure' })
    $storageEvents = @($ClassifiedRecords | Where-Object { $_.categories -contains 'Disk / Storage' -or $_.categories -contains 'NTFS corruption' })

    if (@($updateEvents).Count -gt 0 -and @($bugcheckEvents).Count -gt 0) {
        [void]$intelligence.Add([pscustomobject]@{
                pattern = 'Update -> reboot -> crash chain'
                confidence = 'High'
                evidence = @(@($updateEvents | Select-Object -First 3) + @($bugcheckEvents | Select-Object -First 3))
                summary = 'A Windows Update sequence is followed by a crash/bugcheck sequence.'
            })
    }

    if (@($storageEvents).Count -gt 0 -and @($bugcheckEvents).Count -gt 0) {
        [void]$intelligence.Add([pscustomobject]@{
                pattern = 'Escalating storage errors'
                confidence = 'High'
                evidence = @(@($storageEvents | Select-Object -First 4) + @($bugcheckEvents | Select-Object -First 2))
                summary = 'Storage errors escalate into boot or bugcheck symptoms.'
            })
    }

    if (@($driverEvents).Count -gt 0 -and @($bugcheckEvents).Count -gt 0) {
        [void]$intelligence.Add([pscustomobject]@{
                pattern = 'Driver failure after reboot'
                confidence = 'Medium'
                evidence = @(@($driverEvents | Select-Object -First 4) + @($bugcheckEvents | Select-Object -First 2))
                summary = 'Driver installation or framework issues appear close to crash events.'
            })
    }

    return [pscustomobject]@{
        ordered_events = $ordered
        intelligence = @($intelligence)
    }
}

function Get-DanewCrashEvidenceCorrelation {
    param(
        [AllowEmptyCollection()]
        [object[]]$LogRecords,
        [Parameter(Mandatory = $true)]
        [object]$StorageDiagnostics,
        [Parameter(Mandatory = $true)]
        [object]$BitLockerAnalysis,
        [Parameter(Mandatory = $true)]
        [object]$OfflineAnalysis,
        [Parameter(Mandatory = $true)]
        [object]$TimelineIntelligence
    )

    $correlations = New-Object System.Collections.ArrayList
    $records = @($LogRecords | Sort-Object timestamp)
    $updateEvents = @($records | Where-Object { ([string]$_.provider -match 'WindowsUpdateClient') -or ($_.categories -contains 'Windows Update failure') })
    $driverEvents = @($records | Where-Object { $_.categories -contains 'DriverFrameworks issues' -or $_.categories -contains 'Service startup failures' })
    $bugcheckEvents = @($records | Where-Object { $_.categories -contains 'BugCheck / BSOD' })
    $kernelPowerEvents = @($records | Where-Object { $_.categories -contains 'Kernel-Power shutdown' })
    $storageEvents = @($records | Where-Object { $_.categories -contains 'Disk / Storage' -or $_.categories -contains 'NTFS corruption' -or $_.categories -contains 'Boot / BCD' })
    $wheaEvents = @($records | Where-Object { $_.categories -contains 'WHEA hardware errors' })

    if (@($updateEvents).Count -gt 0 -and @($bugcheckEvents).Count -gt 0) {
        [void]$correlations.Add([pscustomobject]@{
                type = 'Update to crash chain'
                score = 85
                summary = 'Windows Update is followed by a crash sequence.'
                supporting_events = @(@($updateEvents | Select-Object -First 3) + @($bugcheckEvents | Select-Object -First 3))
            })
    }

    if (@($updateEvents).Count -gt 0 -and @($driverEvents).Count -gt 0 -and @($bugcheckEvents).Count -gt 0) {
        [void]$correlations.Add([pscustomobject]@{
                type = 'Storage driver incompatibility after update'
                score = 90
                summary = 'Update, driver installation, and crash events align with a storage driver incompatibility.'
                supporting_events = @(@($updateEvents | Select-Object -First 2) + @($driverEvents | Select-Object -First 2) + @($bugcheckEvents | Select-Object -First 2))
            })
    }

    if (@($storageEvents).Count -gt 0 -and @($bugcheckEvents).Count -gt 0) {
        [void]$correlations.Add([pscustomobject]@{
                type = 'Storage corruption with boot crash'
                score = 80
                summary = 'Storage and NTFS/boot events are correlated with bugcheck symptoms.'
                supporting_events = @(@($storageEvents | Select-Object -First 5) + @($bugcheckEvents | Select-Object -First 2))
            })
    }

    if (@($wheaEvents).Count -gt 0) {
        [void]$correlations.Add([pscustomobject]@{
                type = 'Hardware instability'
                score = 75
                summary = 'WHEA hardware errors are present and suggest platform instability.'
                supporting_events = @($wheaEvents | Select-Object -First 5)
            })
    }

    if (@($kernelPowerEvents).Count -ge 2 -and @($bugcheckEvents).Count -eq 0) {
        [void]$correlations.Add([pscustomobject]@{
                type = 'Power instability loop'
                score = 65
                summary = 'Repeated Kernel-Power shutdowns without explicit bugcheck suggest power instability.'
                supporting_events = @($kernelPowerEvents | Select-Object -First 6)
            })
    }

    if ([int]@($StorageDiagnostics.evidence).Count -gt 0 -and ([string]$OfflineAnalysis.detection_confidence -ne 'Low')) {
        [void]$correlations.Add([pscustomobject]@{
                type = 'Offline storage evidence correlation'
                score = 70
                summary = 'Storage diagnostics and offline Windows analysis both indicate a common failure path.'
                supporting_events = @()
            })
    }

    return [pscustomobject]@{
        correlations = @($correlations)
    }
}

function Get-DanewCrashRootCauseAnalysis {
    param(
        [AllowEmptyCollection()]
        [object[]]$ClassifiedRecords,
        [Parameter(Mandatory = $true)]
        [object]$StorageDiagnostics,
        [Parameter(Mandatory = $true)]
        [object]$BitLockerAnalysis,
        [Parameter(Mandatory = $true)]
        [object]$OfflineAnalysis,
        [Parameter(Mandatory = $true)]
        [object]$EvidenceCorrelation,
        [Parameter(Mandatory = $true)]
        [object]$TimelineIntelligence
    )

    $records = @($ClassifiedRecords | Where-Object { $null -ne $_ })
    $causeRows = New-Object System.Collections.ArrayList

    function Add-CauseRow {
        param(
            [string]$Cause,
            [int]$Score,
            [object[]]$Evidence,
            [string]$Reason
        )

        [void]$causeRows.Add([pscustomobject]@{
                cause = $Cause
                score = $Score
                confidence = (Convert-DanewCrashConfidenceLevel -Score $Score)
                evidence_count = @($Evidence).Count
                evidence_quality = if (@($Evidence).Count -ge 4) { 'High' } elseif (@($Evidence).Count -ge 2) { 'Medium' } else { 'Low' }
                related_events = $Evidence
                timeline_references = @($TimelineIntelligence.intelligence | Select-Object -ExpandProperty pattern)
                reason = $Reason
            })
    }

    $recordCount = @($records).Count
    $validRecords = @($records | Where-Object { $null -ne $_ })
    $bugchecks = @($validRecords | Where-Object { $_.categories -contains 'BugCheck / BSOD' })
    $storage = @($validRecords | Where-Object { $_.categories -contains 'Disk / Storage' -or $_.categories -contains 'NTFS corruption' -or $_.categories -contains 'Boot / BCD' })
    $updates = @($validRecords | Where-Object { $_.categories -contains 'Windows Update failure' })
    $drivers = @($validRecords | Where-Object { $_.categories -contains 'DriverFrameworks issues' -or $_.categories -contains 'Service startup failures' })
    $whea = @($validRecords | Where-Object { $_.categories -contains 'WHEA hardware errors' })
    $kernelPower = @($validRecords | Where-Object { $_.categories -contains 'Kernel-Power shutdown' })
    $rstLikeDrivers = @($validRecords | Where-Object { $_.provider -match 'iaStor|RST|VMD|storport|RaidPort' -or [string]$_.message -match 'iaStor|RST|VMD|RaidPort' })
    $bootDeviceCrash = @($bugchecks | Where-Object { [string]$_.message -match 'INACCESSIBLE_BOOT_DEVICE|0x0000007B|0x7B' })
    $bitlockerVolumes = @($BitLockerAnalysis.volumes | Where-Object { ([string]$_.lock_status -match 'Locked') -or ([string]$_.protection_status -match 'On|Protected') })

    if (@($bitlockerVolumes).Count -gt 0) {
        Add-CauseRow -Cause 'BitLocker lock state' -Score 85 -Evidence @($bitlockerVolumes) -Reason 'BitLocker protected or locked volumes are present.'
    }

    if (([int](Get-DanewCrashSafeProperty -Object $OfflineAnalysis -Name 'warning_count' -DefaultValue 0)) -gt 0 -and ([string](Get-DanewCrashSafeProperty -Object $OfflineAnalysis -Name 'detection_confidence' -DefaultValue 'Low')) -ne 'High') {
        Add-CauseRow -Cause 'inaccessible SYSTEM hive' -Score 60 -Evidence @($OfflineAnalysis) -Reason 'Offline analysis reports registry access warnings or low detection confidence.'
    }

    if ($recordCount -gt 0) {
        if (@($storage).Count -gt 0 -and @($bugchecks).Count -gt 0) {
            Add-CauseRow -Cause 'corrupted NTFS filesystem' -Score 82 -Evidence @($storage) -Reason 'NTFS or storage events align with bugcheck symptoms.'
            Add-CauseRow -Cause 'boot partition corruption' -Score 76 -Evidence @($storage) -Reason 'Boot-related events and storage symptoms point to boot path corruption.'
        }

        if (@($storage).Count -gt 0 -and ([string]$OfflineAnalysis.detection_confidence -ne 'High')) {
            Add-CauseRow -Cause 'failing SSD' -Score 78 -Evidence @($storage) -Reason 'Repeated storage warnings indicate device degradation.'
            Add-CauseRow -Cause 'inaccessible NVMe controller' -Score 75 -Evidence @($storage) -Reason 'Storage visibility issues are consistent with controller access problems.'
        }

        if (@($updates).Count -gt 0 -and @($bugchecks).Count -gt 0) {
            Add-CauseRow -Cause 'failed Windows Update' -Score 80 -Evidence @($updates + $bugchecks) -Reason 'Update activity precedes crash events.'
        }

        if (@($rstLikeDrivers).Count -gt 0 -and (@($bugchecks).Count -gt 0 -or @($bootDeviceCrash).Count -gt 0)) {
            Add-CauseRow -Cause 'bad driver installation' -Score 72 -Evidence @($drivers + $bugchecks) -Reason 'Driver/framework failures appear before the crash.'
            Add-CauseRow -Cause 'Intel RST/VMD issue' -Score 88 -Evidence @($rstLikeDrivers + $storage + $bootDeviceCrash) -Reason 'Storage controller evidence and boot-device failures match an RST/VMD compatibility issue.'
        }
    }

    if (@($whea).Count -gt 0) {
        Add-CauseRow -Cause 'thermal instability' -Score 68 -Evidence @($whea) -Reason 'WHEA hardware errors can indicate thermal or power instability.'
        Add-CauseRow -Cause 'memory instability' -Score 64 -Evidence @($whea) -Reason 'Hardware error patterns can also be consistent with memory instability.'
    }

    if (@($kernelPower).Count -ge 2 -and @($bugchecks).Count -eq 0) {
        Add-CauseRow -Cause 'thermal / power instability' -Score 60 -Evidence @($kernelPower) -Reason 'Repeated Kernel-Power shutdowns without bugcheck are consistent with unstable power delivery.'
    }

    if (@($records | Where-Object { $_.categories -contains 'Security / malware persistence indicators' }).Count -gt 0) {
        Add-CauseRow -Cause 'security or malware persistence indicators' -Score 48 -Evidence @($records | Where-Object { $_.categories -contains 'Security / malware persistence indicators' }) -Reason 'Suspicious persistence indicators were detected in the log stream.'
    }

    if (@($causeRows).Count -eq 0) {
        Add-CauseRow -Cause 'unclassified crash path' -Score 20 -Evidence @($records | Select-Object -First 5) -Reason 'No strong causal pattern could be established from available evidence.'
    }

    $ordered = @($causeRows | Sort-Object score -Descending)
    $primary = $ordered | Select-Object -First 1
    $secondary = @($ordered | Select-Object -Skip 1)

    return [pscustomobject]@{
        primary_cause = $primary
        secondary_causes = $secondary
        all_causes = $ordered
    }
}

function Get-DanewCrashSeverityAnalysis {
    param(
        [Parameter(Mandatory = $true)]
        [object]$RootCauseAnalysis,
        [Parameter(Mandatory = $true)]
        [object]$OfflineAnalysis,
        [Parameter(Mandatory = $true)]
        [object]$StorageDiagnostics
    )

    $rows = New-Object System.Collections.ArrayList
    foreach ($cause in @($RootCauseAnalysis.all_causes)) {
        $severity = 'INFO'
        if ([string]$cause.cause -in @('storage driver incompatibility', 'Intel RST/VMD issue', 'failing SSD', 'inaccessible NVMe controller', 'BitLocker lock state', 'corrupted NTFS filesystem', 'boot partition corruption', 'failed Windows Update')) {
            $severity = if ([int]$cause.score -ge 80) { 'CRITICAL' } else { 'WARNING' }
        }
        elseif ([int]$cause.score -ge 60) {
            $severity = 'WARNING'
        }

        [void]$rows.Add([pscustomobject]@{
                cause = [string]$cause.cause
                severity = $severity
                score = [int]$cause.score
                confidence = [string]$cause.confidence
            })
    }

    $overall = 'INFO'
    if (@($rows | Where-Object { $_.severity -eq 'CRITICAL' }).Count -gt 0) {
        $overall = 'CRITICAL'
    }
    elseif (@($rows | Where-Object { $_.severity -eq 'WARNING' }).Count -gt 0) {
        $overall = 'WARNING'
    }

    return [pscustomobject]@{
        overall = $overall
        causes = @($rows)
    }
}

function Write-DanewSavDiagnosticReportHtml {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [object]$CrashAnalysis
    )

    $causeRows = @()
    foreach ($cause in @($CrashAnalysis.root_cause_analysis.all_causes)) {
        $rowSearch = ConvertTo-DanewReportHtmlText ($cause.cause, $cause.confidence, $cause.score, $cause.reason -join ' ')
        $causeRows += @"
    <tr data-search-row="$rowSearch">
<td>$([System.Security.SecurityElement]::Escape((Get-DanewLocalizedCauseText $cause.cause)))</td>
<td>$([System.Security.SecurityElement]::Escape((Get-DanewLocalizedConfidenceText $cause.confidence)))</td>
<td>$([System.Security.SecurityElement]::Escape([string]$cause.score))</td>
<td>$([System.Security.SecurityElement]::Escape([string]$cause.reason))</td>
</tr>
"@
    }

    $eventRows = @()
    foreach ($classifiedRecord in @($CrashAnalysis.classification.records | Select-Object -First 25)) {
        $duplicateCount = [int](Get-DanewCrashSafeProperty -Object $classifiedRecord -Name 'duplicate_count' -DefaultValue 1)
        $messageText = [string]$classifiedRecord.message
        if ($duplicateCount -gt 1) {
            $messageText = "$messageText [x$duplicateCount]"
        }

        $rowSearch = ConvertTo-DanewReportHtmlText ($classifiedRecord.timestamp, $classifiedRecord.event_id, $classifiedRecord.provider, (@($classifiedRecord.categories) -join '; '), $messageText -join ' ')
        $eventRows += @"
    <tr data-search-row="$rowSearch">
<td>$([System.Security.SecurityElement]::Escape([string]$classifiedRecord.timestamp))</td>
<td>$([System.Security.SecurityElement]::Escape([string]$classifiedRecord.event_id))</td>
<td>$([System.Security.SecurityElement]::Escape([string]$classifiedRecord.provider))</td>
<td>$([System.Security.SecurityElement]::Escape([string](@($classifiedRecord.categories) -join '; ')))</td>
<td>$([System.Security.SecurityElement]::Escape($messageText))</td>
</tr>
"@
    }

    $explanation = ''
    if ($CrashAnalysis.root_cause_analysis.primary_cause) {
        $explanation = @"
<p><b>Cause probable :</b> $([System.Security.SecurityElement]::Escape((Get-DanewLocalizedCauseText $CrashAnalysis.root_cause_analysis.primary_cause.cause)))</p>
<p><b>Confiance :</b> $([System.Security.SecurityElement]::Escape((Get-DanewLocalizedConfidenceText $CrashAnalysis.root_cause_analysis.primary_cause.confidence)))</p>
<p><b>Severite :</b> $([System.Security.SecurityElement]::Escape((Get-DanewLocalizedStatusText $CrashAnalysis.severity_analysis.overall)))</p>
<p><b>Impact :</b> $([System.Security.SecurityElement]::Escape((Get-DanewLocalizedImpactText $CrashAnalysis.impact)))</p>
"@
    }

    $recommendations = @()
    foreach ($line in @($CrashAnalysis.recommendations)) {
        $recommendations += '<li>' + [System.Security.SecurityElement]::Escape((Get-DanewLocalizedRecommendationText $line)) + '</li>'
    }

    $timelineRows = @()
    foreach ($item in @($CrashAnalysis.timeline_intelligence.intelligence)) {
        $rowSearch = ConvertTo-DanewReportHtmlText ($item.pattern, $item.confidence, $item.summary -join ' ')
        $timelineRows += @"
<tr data-search-row="$rowSearch">
<td>$([System.Security.SecurityElement]::Escape([string]$item.pattern))</td>
<td>$([System.Security.SecurityElement]::Escape((Get-DanewLocalizedConfidenceText $item.confidence)))</td>
<td>$([System.Security.SecurityElement]::Escape([string]$item.summary))</td>
</tr>
"@
    }

    $metrics = @(
        (New-DanewMetricCardHtml -Label 'Severite' -Value (Get-DanewLocalizedStatusText $CrashAnalysis.severity_analysis.overall) -Tone $CrashAnalysis.severity_analysis.overall)
        (New-DanewMetricCardHtml -Label 'Confiance principale' -Value (Get-DanewLocalizedConfidenceText (Get-DanewCrashSafeProperty -Object $CrashAnalysis.root_cause_analysis.primary_cause -Name 'confidence' -DefaultValue 'Unknown')) -Tone (Get-DanewCrashSafeProperty -Object $CrashAnalysis.root_cause_analysis.primary_cause -Name 'confidence' -DefaultValue 'neutral'))
        (New-DanewMetricCardHtml -Label 'Causes suivies' -Value @($CrashAnalysis.root_cause_analysis.all_causes).Count -Tone 'info')
        (New-DanewMetricCardHtml -Label 'Recommandations' -Value @($CrashAnalysis.recommendations).Count -Tone 'ready')
    ) -join ''

    $meta = New-DanewReportMetaListHtml -Items @(
        [pscustomobject]@{ label = 'Horodatage'; value = $CrashAnalysis.timestamp }
        [pscustomobject]@{ label = 'Impact'; value = (Get-DanewLocalizedImpactText $CrashAnalysis.impact) }
        [pscustomobject]@{ label = 'Chemin racine'; value = $CrashAnalysis.root_path }
        [pscustomobject]@{ label = 'Confiance de detection'; value = (Get-DanewLocalizedConfidenceText $CrashAnalysis.detection_confidence) }
    )

    $summaryBody = $explanation + '<div class="split-grid">' + (New-DanewMetricCardHtml -Label 'Cause principale' -Value (Get-DanewLocalizedCauseText (Get-DanewCrashSafeProperty -Object $CrashAnalysis.root_cause_analysis.primary_cause -Name 'cause' -DefaultValue 'Unknown')) -Tone $CrashAnalysis.severity_analysis.overall) + (New-DanewMetricCardHtml -Label 'Impact' -Value (Get-DanewLocalizedImpactText $CrashAnalysis.impact) -Tone 'warn') + '</div>'
    $recommendationBody = '<ul class="report-list">' + ($recommendations -join '') + '</ul>'
    $sections = @(
        (New-DanewReportSectionHtml -Title 'Resume executif' -Caption 'Le bandeau de synthese reprend la chaine de cause racine la plus probable sans lancer de reparation.' -SearchText ('summary primary cause severity impact ' + [string](Get-DanewCrashSafeProperty -Object $CrashAnalysis.root_cause_analysis.primary_cause -Name 'cause' -DefaultValue '')) -BodyHtml $summaryBody)
        (New-DanewReportSectionHtml -Title 'Causes principales et secondaires' -Caption 'Recherche par texte de cause, score, confiance ou justification.' -SearchText 'causes confidence score reason root cause analysis' -BodyHtml (New-DanewReportTableHtml -Headers @('Cause', 'Confiance', 'Score', 'Justification') -Rows $causeRows -EmptyMessage 'Aucune cause ne correspond au filtre courant.'))
        (New-DanewReportSectionHtml -Title 'Intelligence de chronologie' -Caption 'Synthese de motifs extraite des enregistrements classes.' -SearchText 'timeline intelligence patterns confidence summary' -BodyHtml (New-DanewReportTableHtml -Headers @('Motif', 'Confiance', 'Resume') -Rows $timelineRows -EmptyMessage 'Aucune ligne de chronologie ne correspond au filtre courant.') -Collapsed $true)
        (New-DanewReportSectionHtml -Title 'Classification des evenements' -Caption '25 premiers enregistrements classes pour un triage rapide.' -SearchText 'event classification provider category message' -BodyHtml (New-DanewReportTableHtml -Headers @('Horodatage', 'ID evenement', 'Fournisseur', 'Categorie', 'Message') -Rows $eventRows -EmptyMessage 'Aucun evenement classe ne correspond au filtre courant.') -Collapsed $true)
        (New-DanewReportSectionHtml -Title 'Prochaines actions recommandees' -Caption 'Actions en lecture seule uniquement. Les reparations restent hors de cette phase.' -SearchText ('recommendations next steps ' + (@($CrashAnalysis.recommendations) -join ' ')) -BodyHtml $recommendationBody)
    )

    $html = New-DanewInteractiveReportHtml -Title 'Rapport de diagnostic SAV Danew' -Subtitle 'Rapport hors ligne oriente crash avec recherche sur les causes, motifs de chronologie et prochaines actions ciblees.' -Status ([string]$CrashAnalysis.severity_analysis.overall) -Eyebrow 'Analyse SAV / crash' -HeroMetricsHtml ('<div class="hero-metrics">' + $metrics + '</div>') -MetaHtml $meta -Sections $sections -SearchPlaceholder 'Filtrer les causes, motifs de chronologie, fournisseurs ou recommandations'

    $html | Set-Content -Path $Path -Encoding UTF8
    Update-DanewInteractiveReportsIndex -ReportsPath (Split-Path -Parent $Path) | Out-Null
}

function Invoke-DanewCrashCauseAnalysis {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [Parameter(Mandatory = $true)]
        [object]$Config,
        [object]$OfflineAnalysis,
        [int]$MaxEventsPerLog = 2000
    )

    if (-not (Test-Path -Path $Config.reports_path)) {
        New-Item -Path $Config.reports_path -ItemType Directory -Force | Out-Null
    }

    if ($null -eq $OfflineAnalysis) {
        $OfflineAnalysis = [pscustomobject]@{ artifacts = [pscustomobject]@{} }
    }

    $offlineArtifacts = Get-DanewCrashSafeProperty -Object $OfflineAnalysis -Name 'artifacts' -DefaultValue ([pscustomobject]@{})
    $eventsPath = [string](Get-DanewCrashSafeProperty -Object $offlineArtifacts -Name 'evtx_events_json' -DefaultValue (Join-Path $Config.reports_path 'evtx-events.json'))
    $analysisPath = [string](Get-DanewCrashSafeProperty -Object $offlineArtifacts -Name 'offline_windows_analysis' -DefaultValue (Join-Path $Config.reports_path 'offline-windows-analysis.json'))
    $storagePath = [string](Get-DanewCrashSafeProperty -Object $offlineArtifacts -Name 'storage_diagnostics' -DefaultValue (Join-Path $Config.reports_path 'storage-diagnostics.json'))
    $bitLockerPath = [string](Get-DanewCrashSafeProperty -Object $offlineArtifacts -Name 'bitlocker_analysis' -DefaultValue (Join-Path $Config.reports_path 'bitlocker-analysis.json'))
    $timelinePath = [string](Get-DanewCrashSafeProperty -Object $offlineArtifacts -Name 'timeline_raw_json' -DefaultValue (Join-Path $Config.reports_path 'timeline-raw.json'))

    $classificationPath = Join-Path $Config.reports_path 'event-classification.json'
    $evidenceCorrelationPath = Join-Path $Config.reports_path 'evidence-correlation.json'
    $rootCausePath = Join-Path $Config.reports_path 'root-cause-analysis.json'
    $confidencePath = Join-Path $Config.reports_path 'confidence-analysis.json'
    $timelineIntelPath = Join-Path $Config.reports_path 'timeline-intelligence.json'
    $multiCausePath = Join-Path $Config.reports_path 'multi-cause-analysis.json'
    $severityPath = Join-Path $Config.reports_path 'severity-analysis.json'
    $savJsonPath = Join-Path $Config.reports_path 'sav-diagnostic-report.json'
    $savHtmlPath = Join-Path $Config.reports_path 'sav-diagnostic-report.html'

    $logRecords = @()
    $offlineSummary = Read-DanewJsonFile -Path $analysisPath -DefaultValue ([pscustomobject]@{})
    $storageDiagnostics = Read-DanewJsonFile -Path $storagePath -DefaultValue ([pscustomobject]@{ probable_causes = @(); evidence = @() })
    $bitLockerAnalysis = Read-DanewJsonFile -Path $bitLockerPath -DefaultValue ([pscustomobject]@{ volumes = @(); summary = [pscustomobject]@{ locked_or_protected_count = 0 } })
    $logRecords = Read-DanewJsonFile -Path $eventsPath -DefaultValue @()
    if ($null -eq $logRecords -or (@($logRecords).Count -eq 1 -and ($null -eq $logRecords[0] -or $logRecords[0] -is [System.String]))) {
        $logRecords = @()
    }

    $optimizedLogs = Optimize-DanewCrashLogRecords -LogRecords $logRecords
    $recordsForAnalysis = @($optimizedLogs.records)

    $classify = Get-DanewCrashClassification -LogRecords $recordsForAnalysis
    $timeline = Get-DanewCrashTimelineIntelligence -LogRecords $recordsForAnalysis -ClassifiedRecords $classify.records
    $correlation = Get-DanewCrashEvidenceCorrelation -LogRecords $classify.records -StorageDiagnostics $storageDiagnostics -BitLockerAnalysis $bitLockerAnalysis -OfflineAnalysis $offlineSummary -TimelineIntelligence $timeline
    $rootCause = Get-DanewCrashRootCauseAnalysis -ClassifiedRecords $classify.records -StorageDiagnostics $storageDiagnostics -BitLockerAnalysis $bitLockerAnalysis -OfflineAnalysis $offlineSummary -EvidenceCorrelation $correlation -TimelineIntelligence $timeline
    $severity = Get-DanewCrashSeverityAnalysis -RootCauseAnalysis $rootCause -OfflineAnalysis $offlineSummary -StorageDiagnostics $storageDiagnostics

    if (([int](Get-DanewCrashSafeProperty -Object $offlineSummary -Name 'warning_count' -DefaultValue 0)) -gt 0 -and ([int](Get-DanewCrashSafeProperty -Object $bitLockerAnalysis.summary -Name 'locked_or_protected_count' -DefaultValue 0)) -eq 0) {
        $systemHiveCause = [pscustomobject]@{
            cause = 'inaccessible SYSTEM hive'
            score = 60
            confidence = 'Medium'
            evidence_count = 1
            evidence_quality = 'Medium'
            related_events = @()
            timeline_references = @()
            reason = 'Offline analysis reports registry access warnings and no stronger log evidence is available.'
        }
        $rootCause = [pscustomobject]@{
            primary_cause = $systemHiveCause
            secondary_causes = @()
            all_causes = @($systemHiveCause)
        }
        $severity = [pscustomobject]@{
            overall = 'WARNING'
            causes = @([pscustomobject]@{ cause = 'inaccessible SYSTEM hive'; severity = 'WARNING'; score = 60; confidence = 'Medium' })
        }
    }

    $confidenceRows = @()
    foreach ($cause in @($rootCause.all_causes)) {
        $confidenceRows += [pscustomobject]@{
            cause = [string]$cause.cause
            confidence = [string]$cause.confidence
            score = [int]$cause.score
            evidence_count = [int]$cause.evidence_count
            evidence_quality = [string]$cause.evidence_quality
        }
    }

    $recommendations = @()
    if ($rootCause.primary_cause) {
        switch ([string]$rootCause.primary_cause.cause) {
            'Intel RST/VMD issue' { $recommendations += 'Verify BIOS storage mode and inject the matching Intel RST/VMD driver if required.' }
            'failing SSD' { $recommendations += 'Run a non-destructive SSD health check and verify controller visibility.' }
            'inaccessible NVMe controller' { $recommendations += 'Verify NVMe visibility in firmware and storage driver support in WinPE.' }
            'failed Windows Update' { $recommendations += 'Review the last update window and compare it with the crash timeline.' }
            'corrupted NTFS filesystem' { $recommendations += 'Inspect the NTFS corruption pattern and preserve the disk state for offline analysis.' }
            'BitLocker lock state' { $recommendations += 'Confirm whether the target volume is intentionally locked and whether recovery metadata is available.' }
            'thermal instability' { $recommendations += 'Check thermal history and cooling/power stability around the crash window.' }
            'memory instability' { $recommendations += 'Correlate the crash window with hardware memory diagnostics if available.' }
            default { $recommendations += 'Correlate the primary cause with the offline storage and registry evidence.' }
        }
    }
    if (@($recommendations).Count -eq 0) {
        $recommendations += 'Review storage, driver, and timeline evidence for the strongest failure chain.'
    }
    $recommendations += 'Do not perform repairs from this phase; keep the analysis read-only.'

    $impact = 'Windows may be unable to boot or may be crashing soon after boot.'
    if ($rootCause.primary_cause -and [string]$rootCause.primary_cause.cause -eq 'BitLocker lock state') {
        $impact = 'Windows volumes may be inaccessible until the lock state is resolved outside this phase.'
    }

    $crash = [pscustomobject]@{
        timestamp = (Get-Date).ToString('s')
        root_path = $RootPath
        detection_confidence = if ($rootCause.primary_cause) { [string]$rootCause.primary_cause.confidence } else { 'Low' }
        severity = $severity.overall
        impact = $impact
        classification = $classify
        evidence_correlation = $correlation
        root_cause_analysis = $rootCause
        confidence_analysis = [pscustomobject]@{ causes = $confidenceRows }
        timeline_intelligence = $timeline
        multi_cause_analysis = [pscustomobject]@{
            primary = $rootCause.primary_cause
            secondary = $rootCause.secondary_causes
            cascading = @($correlation.correlations | Select-Object -First 3)
        }
        severity_analysis = $severity
        recommendations = $recommendations
        record_optimization = [pscustomobject]@{
            input_count = [int]$optimizedLogs.input_count
            output_count = [int]$optimizedLogs.output_count
            removed_duplicates = [int]$optimizedLogs.removed_duplicates
            removed_wer_duplicates = [int]$optimizedLogs.removed_wer_duplicates
        }
        report_paths = [pscustomobject]@{
            classification = $classificationPath
            evidence_correlation = $evidenceCorrelationPath
            root_cause_analysis = $rootCausePath
            confidence_analysis = $confidencePath
            timeline_intelligence = $timelineIntelPath
            multi_cause_analysis = $multiCausePath
            severity_analysis = $severityPath
            sav_diagnostic_report_json = $savJsonPath
            sav_diagnostic_report_html = $savHtmlPath
        }
    }

    $classify | ConvertTo-Json -Depth 20 | Set-Content -Path $classificationPath -Encoding UTF8
    $correlation | ConvertTo-Json -Depth 20 | Set-Content -Path $evidenceCorrelationPath -Encoding UTF8
    $rootCause | ConvertTo-Json -Depth 20 | Set-Content -Path $rootCausePath -Encoding UTF8
    [pscustomobject]@{ causes = $confidenceRows } | ConvertTo-Json -Depth 15 | Set-Content -Path $confidencePath -Encoding UTF8
    $timeline | ConvertTo-Json -Depth 20 | Set-Content -Path $timelineIntelPath -Encoding UTF8
    $crash.multi_cause_analysis | ConvertTo-Json -Depth 18 | Set-Content -Path $multiCausePath -Encoding UTF8
    $severity | ConvertTo-Json -Depth 18 | Set-Content -Path $severityPath -Encoding UTF8
    $crash | ConvertTo-Json -Depth 25 | Set-Content -Path $savJsonPath -Encoding UTF8
    Write-DanewSavDiagnosticReportHtml -Path $savHtmlPath -CrashAnalysis $crash

    return $crash
}
