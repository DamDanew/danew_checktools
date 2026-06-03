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

function Convert-DanewCrashTimestamp {
    param([AllowNull()][object]$Value)

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    $parsed = [datetime]::MinValue
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $styles = [System.Globalization.DateTimeStyles]::AssumeLocal
    if ([datetime]::TryParse($text, $culture, $styles, [ref]$parsed)) {
        return $parsed
    }
    if ([datetime]::TryParse($text, [ref]$parsed)) {
        return $parsed
    }

    return $null
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
        if ($provider -match 'Winlogon' -or $channel -match 'Winlogon' -or $eventId -in @(4006,1074)) { [void]$categories.Add('Winlogon / login failure'); $criticality += 3 }
        if ($provider -match 'Servicing|CBS|UpdateOrchestrator' -or $channel -match 'Servicing|UpdateOrchestrator|Setup' -or $text -match 'kb\d{6,}') { [void]$categories.Add('Windows Update / KB servicing'); $criticality += 3 }
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
            level = [string](Get-DanewCrashSafeProperty -Object $logRecord -Name 'level' -DefaultValue '')
            level_fr = [string](Get-DanewCrashSafeProperty -Object $logRecord -Name 'level_fr' -DefaultValue '')
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
    $kbEvents = @($ClassifiedRecords | Where-Object {
            ($_.categories -contains 'Windows Update / KB servicing') -or
            ([string]$_.message -match 'KB\d{6,}') -or
            ([string]$_.provider -match 'Servicing|CBS|UpdateOrchestrator|WindowsUpdateClient')
        })

    if (@($updateEvents).Count -gt 0 -and @($bugcheckEvents).Count -gt 0) {
        [void]$intelligence.Add([pscustomobject]@{
                pattern = 'Update -> reboot -> crash chain'
                confidence = 'High'
                evidence = @(@($updateEvents | Select-Object -First 3) + @($bugcheckEvents | Select-Object -First 3))
                summary = 'A Windows Update sequence is followed by a crash/bugcheck sequence.'
            })
    }

    $kbCrashPairs = New-Object System.Collections.ArrayList
    foreach ($kbEvent in @($kbEvents)) {
        $kbTime = Convert-DanewCrashTimestamp -Value $kbEvent.timestamp
        if ($null -eq $kbTime) { continue }

        foreach ($bugcheckEvent in @($bugcheckEvents)) {
            $crashTime = Convert-DanewCrashTimestamp -Value $bugcheckEvent.timestamp
            if ($null -eq $crashTime) { continue }
            if ($crashTime -lt $kbTime) { continue }

            $delta = $crashTime - $kbTime
            if ($delta.TotalHours -le 24) {
                $kbMatch = [Regex]::Match([string]$kbEvent.message, 'KB\d{6,}', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                $kbName = if ($kbMatch.Success) { $kbMatch.Value.ToUpperInvariant() } else { 'KB non precisee' }
                [void]$kbCrashPairs.Add([pscustomobject]@{
                        kb = $kbName
                        delta_minutes = [int][Math]::Round($delta.TotalMinutes)
                        kb_event = $kbEvent
                        crash_event = $bugcheckEvent
                    })
                break
            }
        }
    }

    if (@($kbCrashPairs).Count -gt 0) {
        $firstPair = @($kbCrashPairs)[0]
        [void]$intelligence.Add([pscustomobject]@{
                pattern = 'KB -> crash within 24h'
                confidence = if (@($kbCrashPairs).Count -ge 2) { 'High' } else { 'Medium' }
                evidence = @($kbCrashPairs | Select-Object -First 5)
                summary = ('A Windows update package ({0}) is followed by a BugCheck/BSOD within {1} minutes.' -f [string]$firstPair.kb, [int]$firstPair.delta_minutes)
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

    # DISM/CBS text log correlations (events injected by Read-DanewDismCbsTextLogs)
    $dismCbsEvents = @($ClassifiedRecords | Where-Object {
        (Get-DanewCrashSafeProperty -Object $_ -Name 'provider' -DefaultValue '') -match 'Microsoft-Windows-DISM|Microsoft-Windows-CBS' -or
        (Get-DanewCrashSafeProperty -Object $_ -Name 'channel'  -DefaultValue '') -match 'DISM/TextLog|CBS/TextLog'
    })
    $winlogonEvents = @($ClassifiedRecords | Where-Object { $_.categories -contains 'Winlogon / login failure' })
    $ntfsEvents = @($ClassifiedRecords | Where-Object { $_.categories -contains 'NTFS corruption' -or $_.categories -contains 'Disk / Storage' })

    if (@($dismCbsEvents).Count -gt 0 -and @($bugcheckEvents).Count -gt 0) {
        $hasPreciseTs = @($dismCbsEvents | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.timestamp) }).Count -gt 0
        [void]$intelligence.Add([pscustomobject]@{
            pattern    = 'DISM/CBS servicing before crash'
            confidence = if ($hasPreciseTs) { 'Medium' } else { 'Low' }
            evidence   = @(@($dismCbsEvents | Select-Object -First 3) + @($bugcheckEvents | Select-Object -First 2))
            summary    = 'DISM or CBS servicing errors were found in text logs before a BugCheck/BSOD event.'
        })
    }

    if (@($dismCbsEvents).Count -gt 0 -and @($winlogonEvents).Count -gt 0) {
        [void]$intelligence.Add([pscustomobject]@{
            pattern    = 'CBS/DISM servicing before login failure'
            confidence = 'Medium'
            evidence   = @(@($dismCbsEvents | Select-Object -First 3) + @($winlogonEvents | Select-Object -First 2))
            summary    = 'CBS or DISM servicing errors precede Winlogon or login failure events.'
        })
    }

    if (@($dismCbsEvents | Where-Object { [string]$_.message -match '(?i)corruption|corrupt' }).Count -gt 0 -and @($ntfsEvents).Count -gt 0) {
        [void]$intelligence.Add([pscustomobject]@{
            pattern    = 'CBS/DISM corruption marker with storage errors'
            confidence = 'Medium'
            evidence   = @(@($dismCbsEvents | Where-Object { [string]$_.message -match '(?i)corruption|corrupt' } | Select-Object -First 3) + @($ntfsEvents | Select-Object -First 2))
            summary    = 'CBS or DISM reported image corruption, correlated with NTFS or storage errors.'
        })
    }

    # Supplementary patterns for full SAV coverage
    $serviceEvents2  = @($ClassifiedRecords | Where-Object { $_.categories -contains 'Service startup failures' })
    $wheaEvents2     = @($ClassifiedRecords | Where-Object { $_.categories -contains 'WHEA hardware errors' })
    $rstVmdRecords   = @($ClassifiedRecords | Where-Object {
        (Get-DanewCrashSafeProperty -Object $_ -Name 'provider' -DefaultValue '') -match 'iaStor|RST|VMD|storport' -or
        (Get-DanewCrashSafeProperty -Object $_ -Name 'message'  -DefaultValue '') -match 'iaStor|RST|VMD|RaidPort'
    })
    $bootDevCrashes  = @($bugcheckEvents | Where-Object {
        (Get-DanewCrashSafeProperty -Object $_ -Name 'message' -DefaultValue '') -match 'INACCESSIBLE_BOOT_DEVICE|0x7B'
    })

    if (@($ntfsEvents).Count -gt 0 -and @($winlogonEvents).Count -gt 0) {
        [void]$intelligence.Add([pscustomobject]@{
            pattern    = 'NTFS corruption before login failure'
            confidence = 'Medium'
            evidence   = @(@($ntfsEvents | Select-Object -First 3) + @($winlogonEvents | Select-Object -First 2))
            summary    = 'NTFS or storage corruption events precede Winlogon or login failure events.'
        })
    }

    if (@($kernelPowerEvents).Count -gt 0 -and @($ntfsEvents).Count -gt 0) {
        [void]$intelligence.Add([pscustomobject]@{
            pattern    = 'Kernel-Power reboot triggering NTFS repair'
            confidence = 'Medium'
            evidence   = @(@($kernelPowerEvents | Select-Object -First 3) + @($ntfsEvents | Select-Object -First 2))
            summary    = 'Unexpected Kernel-Power shutdowns are followed by NTFS filesystem repair or corruption events.'
        })
    }

    if (@($driverEvents).Count -gt 0 -and @($serviceEvents2).Count -ge 2) {
        [void]$intelligence.Add([pscustomobject]@{
            pattern    = 'Driver failure causing repeated service crashes'
            confidence = 'Medium'
            evidence   = @(@($driverEvents | Select-Object -First 3) + @($serviceEvents2 | Select-Object -First 3))
            summary    = 'Driver or framework failures appear to trigger repeated service startup failures.'
        })
    }

    if (@($serviceEvents2).Count -ge 2 -and (@($kernelPowerEvents).Count -gt 0 -or @($winlogonEvents).Count -gt 0)) {
        [void]$intelligence.Add([pscustomobject]@{
            pattern    = 'Repeated service failures causing boot or login instability'
            confidence = 'Medium'
            evidence   = @(@($serviceEvents2 | Select-Object -First 4) + @($kernelPowerEvents | Select-Object -First 2))
            summary    = 'Multiple service startup failures correlate with boot instability or Winlogon/login failures.'
        })
    }

    if (@($wheaEvents2).Count -gt 0) {
        [void]$intelligence.Add([pscustomobject]@{
            pattern    = 'WHEA hardware error indicating platform instability'
            confidence = if (@($wheaEvents2).Count -ge 3) { 'High' } else { 'Medium' }
            evidence   = @($wheaEvents2 | Select-Object -First 5)
            summary    = 'WHEA hardware errors indicate potential CPU, memory, or platform instability.'
        })
    }

    if (@($rstVmdRecords).Count -gt 0 -and @($bootDevCrashes).Count -gt 0) {
        [void]$intelligence.Add([pscustomobject]@{
            pattern    = 'Intel RST/VMD issue causing INACCESSIBLE_BOOT_DEVICE'
            confidence = 'High'
            evidence   = @(@($rstVmdRecords | Select-Object -First 3) + @($bootDevCrashes | Select-Object -First 2))
            summary    = 'Intel RST/VMD storage controller events are followed by INACCESSIBLE_BOOT_DEVICE crash.'
        })
    }

    return [pscustomobject]@{
        ordered_events = $ordered
        intelligence   = @($intelligence)
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
    $kbCrashPatterns = @($TimelineIntelligence.intelligence | Where-Object { [string]$_.pattern -eq 'KB -> crash within 24h' })
    $dismCbsRecords = @($validRecords | Where-Object {
        (Get-DanewCrashSafeProperty -Object $_ -Name 'provider' -DefaultValue '') -match 'Microsoft-Windows-DISM|Microsoft-Windows-CBS' -or
        (Get-DanewCrashSafeProperty -Object $_ -Name 'channel'  -DefaultValue '') -match 'DISM/TextLog|CBS/TextLog'
    })
    $dismCbsBeforeCrash = @($TimelineIntelligence.intelligence | Where-Object { [string]$_.pattern -match 'DISM|CBS' })
    $dismCbsCorruption = @($dismCbsRecords | Where-Object { [string]$_.message -match '(?i)corruption|corrupt|failed|cannot' })

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

        if (@($kbCrashPatterns).Count -gt 0) {
            Add-CauseRow -Cause 'failed Windows Update KB sequence' -Score 84 -Evidence @($kbCrashPatterns) -Reason 'A specific Windows update package is followed by BugCheck/BSOD evidence within 24 hours.'
        }

        # DISM/CBS text log causes
        if (@($dismCbsBeforeCrash).Count -gt 0 -and @($bugchecks).Count -gt 0) {
            Add-CauseRow -Cause 'DISM/CBS servicing failure before crash' -Score 72 -Evidence @($dismCbsRecords | Select-Object -First 4) -Reason 'DISM or CBS servicing errors in text logs precede BugCheck/BSOD events.'
        }

        if (@($dismCbsCorruption).Count -gt 0) {
            $hasCrashOrStorage = @($bugchecks).Count -gt 0 -or @($storage).Count -gt 0
            Add-CauseRow -Cause 'CBS package servicing issue before login failure' -Score $(if ($hasCrashOrStorage) { 68 } else { 48 }) -Evidence @($dismCbsCorruption | Select-Object -First 4) -Reason 'CBS or DISM reported corruption or failure during package servicing. May cause login or boot failure.'
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
        if ([string]$cause.cause -in @('storage driver incompatibility', 'Intel RST/VMD issue', 'failing SSD', 'inaccessible NVMe controller', 'BitLocker lock state', 'corrupted NTFS filesystem', 'boot partition corruption', 'failed Windows Update', 'failed Windows Update KB sequence')) {
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

function Get-DanewSavClientText {
    param([AllowNull()][object]$PrimaryCause)
    $cause = [string](Get-DanewCrashSafeProperty -Object $PrimaryCause -Name 'cause' -DefaultValue '')
    switch ($cause) {
        'Intel RST/VMD issue'                     { return "Votre PC ne parvient plus a acceder au disque dur apres une mise a jour du BIOS ou des pilotes de stockage." }
        'corrupted NTFS filesystem'               { return "Des donnees importantes du systeme Windows ont ete endommagees, ce qui empeche le demarrage normal." }
        'boot partition corruption'               { return "La partition de demarrage Windows est corrompue. Le PC ne peut plus trouver le systeme pour demarrer." }
        'failing SSD'                             { return "Le disque dur de l ordinateur presente des signes de defaillance. Une sauvegarde des donnees est urgente." }
        'inaccessible NVMe controller'            { return "Le controleur de stockage interne n est pas reconnu. Le disque semble inaccessible au demarrage." }
        'failed Windows Update'                   { return "Une mise a jour Windows a provoque un probleme de demarrage. Le systeme doit etre restaure ou la mise a jour annulee." }
        'failed Windows Update KB sequence'       { return "Une mise a jour Windows recente a provoque un probleme de demarrage." }
        'DISM/CBS servicing failure before crash' { return "Une operation de maintenance Windows a echoue et semble etre a l origine du probleme." }
        'CBS package servicing issue before login failure' { return "Un probleme de maintenance systeme empeche la connexion a Windows." }
        'BitLocker lock state'                    { return "Le disque Windows est verrouille par BitLocker. La cle de recuperation est necessaire pour acceder aux donnees." }
        'inaccessible SYSTEM hive'                { return "Les parametres systeme de Windows sont inaccessibles ou endommages." }
        'thermal / power instability'             { return "L ordinateur s est eteint de maniere anormale, probablement a cause d un probleme d alimentation ou de temperature." }
        'thermal instability'                     { return "L ordinateur surchauffe ou a un probleme d alimentation. Un nettoyage ou controle materiel est recommande." }
        'memory instability'                      { return "La memoire RAM de l ordinateur presente des anomalies. Un test memoire complet est necessaire." }
        'security or malware persistence indicators' { return "Des indicateurs suspects ont ete detectes dans les journaux systeme. Une analyse antivirus hors ligne est recommandee." }
        default                                   { return "Windows a rencontre une erreur critique qui l empeche de demarrer normalement." }
    }
}

function Get-DanewSavPatternActions {
    param([string]$PatternName)
    $map = @{
        'Update -> reboot -> crash chain'                        = @(
            [pscustomobject]@{ label='Lister les KB installees'; cmd='dism /image:<LETTRE_WINDOWS>:\ /get-packages | findstr /i KB'; desc='Lister les mises a jour presentes dans l image offline' }
            [pscustomobject]@{ label='Exporter historique MAJ'; cmd='wmic qfe list brief /format:csv > kb-history.csv'; desc='Exporter la liste des mises a jour Windows installees' }
        )
        'KB -> crash within 24h'                                = @(
            [pscustomobject]@{ label='Lister les KB installees'; cmd='dism /image:<LETTRE_WINDOWS>:\ /get-packages | findstr /i KB'; desc='Lister les mises a jour presentes dans l image offline' }
            [pscustomobject]@{ label='Exporter historique MAJ'; cmd='wmic qfe list brief /format:csv > kb-history.csv'; desc='Exporter la liste des mises a jour Windows installees' }
        )
        'failed Windows Update KB sequence'                     = @(
            [pscustomobject]@{ label='Lister les KB installees'; cmd='dism /image:<LETTRE_WINDOWS>:\ /get-packages | findstr /i KB'; desc='Lister les mises a jour presentes dans l image offline' }
            [pscustomobject]@{ label='DISM CheckHealth'; cmd='dism /image:<LETTRE_WINDOWS>:\ /cleanup-image /checkhealth'; desc='Verifier integrite image Windows offline' }
        )
        'Escalating storage errors'                             = @(
            [pscustomobject]@{ label='CHKDSK scan (lecture seule)'; cmd='chkdsk <LETTRE_WINDOWS>: /scan'; desc='Verifier NTFS sans modification - lecture seule' }
            [pscustomobject]@{ label='SFC offline'; cmd='sfc /scannow /offbootdir=<LETTRE_WINDOWS>:\ /offwindir=<LETTRE_WINDOWS>:\Windows'; desc='Verifier les fichiers systeme Windows offline' }
            [pscustomobject]@{ label='SMART rapide'; cmd='wmic diskdrive get status,model,size /format:csv'; desc='Etat SMART des disques detectes' }
        )
        'Storage corruption with boot crash'                    = @(
            [pscustomobject]@{ label='CHKDSK scan (lecture seule)'; cmd='chkdsk <LETTRE_WINDOWS>: /scan'; desc='Verifier NTFS sans modification' }
            [pscustomobject]@{ label='DISM CheckHealth'; cmd='dism /image:<LETTRE_WINDOWS>:\ /cleanup-image /checkhealth'; desc='Verifier integrite image Windows offline' }
            [pscustomobject]@{ label='SMART rapide'; cmd='wmic diskdrive get status,model,size /format:csv'; desc='Etat SMART des disques' }
        )
        'NTFS corruption before login failure'                  = @(
            [pscustomobject]@{ label='CHKDSK scan (lecture seule)'; cmd='chkdsk <LETTRE_WINDOWS>: /scan'; desc='Verifier NTFS sans modification - lecture seule' }
            [pscustomobject]@{ label='SFC offline'; cmd='sfc /scannow /offbootdir=<LETTRE_WINDOWS>:\ /offwindir=<LETTRE_WINDOWS>:\Windows'; desc='Verifier les fichiers systeme Windows offline' }
        )
        'DISM/CBS servicing before crash'                       = @(
            [pscustomobject]@{ label='Copier CBS.log'; cmd='copy <LETTRE_WINDOWS>:\Windows\Logs\CBS\CBS.log .\CBS-export.log'; desc='Exporter le journal CBS pour analyse' }
            [pscustomobject]@{ label='Copier DISM.log'; cmd='copy <LETTRE_WINDOWS>:\Windows\Logs\DISM\dism.log .\DISM-export.log'; desc='Exporter le journal DISM pour analyse' }
            [pscustomobject]@{ label='DISM CheckHealth'; cmd='dism /image:<LETTRE_WINDOWS>:\ /cleanup-image /checkhealth'; desc='Verifier integrite image Windows offline' }
        )
        'CBS/DISM servicing before login failure'               = @(
            [pscustomobject]@{ label='Copier CBS.log'; cmd='copy <LETTRE_WINDOWS>:\Windows\Logs\CBS\CBS.log .\CBS-export.log'; desc='Exporter le journal CBS pour analyse' }
            [pscustomobject]@{ label='SFC offline'; cmd='sfc /scannow /offbootdir=<LETTRE_WINDOWS>:\ /offwindir=<LETTRE_WINDOWS>:\Windows'; desc='Verifier les fichiers systeme Windows offline' }
            [pscustomobject]@{ label='Verifier Userinit'; cmd='reg load HKLM\OFFLINE <LETTRE_WINDOWS>:\Windows\System32\config\SOFTWARE && reg query "HKLM\OFFLINE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v Userinit'; desc='Verifier la valeur Userinit dans le registre Winlogon' }
        )
        'CBS/DISM corruption marker with storage errors'        = @(
            [pscustomobject]@{ label='Copier CBS.log'; cmd='copy <LETTRE_WINDOWS>:\Windows\Logs\CBS\CBS.log .\CBS-export.log'; desc='Exporter le journal CBS pour analyse' }
            [pscustomobject]@{ label='DISM CheckHealth'; cmd='dism /image:<LETTRE_WINDOWS>:\ /cleanup-image /checkhealth'; desc='Verifier integrite image Windows offline' }
            [pscustomobject]@{ label='CHKDSK scan (lecture seule)'; cmd='chkdsk <LETTRE_WINDOWS>: /scan'; desc='Verifier NTFS sans modification' }
        )
        'Driver failure after reboot'                           = @(
            [pscustomobject]@{ label='Exporter liste pilotes'; cmd='driverquery /FO csv > drivers-export.csv'; desc='Exporter la liste des pilotes installes' }
            [pscustomobject]@{ label='Verifier mode stockage BIOS'; cmd='echo Verifier BIOS: Storage > AHCI/RAID/VMD mode'; desc='Aller dans BIOS et verifier le mode de stockage' }
        )
        'Driver failure causing repeated service crashes'       = @(
            [pscustomobject]@{ label='Exporter liste pilotes'; cmd='driverquery /FO csv > drivers-export.csv'; desc='Exporter la liste des pilotes installes' }
            [pscustomobject]@{ label='Lister services defaillants'; cmd='sc query type= all state= all | findstr /i "failed stopped"'; desc='Lister les services arretes ou en echec' }
        )
        'Repeated service failures causing boot or login instability' = @(
            [pscustomobject]@{ label='Lister services'; cmd='sc query type= all state= all'; desc='Lister tous les services et leur etat' }
            [pscustomobject]@{ label='SFC offline'; cmd='sfc /scannow /offbootdir=<LETTRE_WINDOWS>:\ /offwindir=<LETTRE_WINDOWS>:\Windows'; desc='Verifier les fichiers systeme Windows offline' }
        )
        'Power instability loop'                                = @(
            [pscustomobject]@{ label='Rapport energie'; cmd='powercfg /energy'; desc='Analyser la consommation et les problemes energie' }
            [pscustomobject]@{ label='SMART rapide'; cmd='wmic diskdrive get status,model,size /format:csv'; desc='Etat SMART des disques' }
        )
        'Kernel-Power reboot triggering NTFS repair'            = @(
            [pscustomobject]@{ label='Rapport energie'; cmd='powercfg /energy'; desc='Analyser la consommation et les problemes energie' }
            [pscustomobject]@{ label='CHKDSK scan (lecture seule)'; cmd='chkdsk <LETTRE_WINDOWS>: /scan'; desc='Verifier NTFS sans modification' }
        )
        'WHEA hardware error indicating platform instability'   = @(
            [pscustomobject]@{ label='Info memoire RAM'; cmd='wmic memorychip get capacity,manufacturer,speed /format:csv > memory-info.csv'; desc='Exporter les informations sur les barrettes RAM' }
            [pscustomobject]@{ label='Planifier test memoire'; cmd='mdsched.exe'; desc='Lancer le diagnosticateur de memoire Windows (redemarrage requis)' }
            [pscustomobject]@{ label='SMART rapide'; cmd='wmic diskdrive get status,model,size /format:csv'; desc='Etat SMART des disques' }
        )
        'Intel RST/VMD issue causing INACCESSIBLE_BOOT_DEVICE'  = @(
            [pscustomobject]@{ label='Verifier mode stockage BIOS'; cmd='echo Verifier BIOS: Storage Controller > AHCI ou RST/VMD mode'; desc='Aller dans BIOS et verifier le mode de stockage - AHCI vs RAID/VMD' }
            [pscustomobject]@{ label='Exporter liste pilotes'; cmd='driverquery /FO csv > drivers-export.csv'; desc='Exporter la liste des pilotes installes pour identifier pilote RST' }
            [pscustomobject]@{ label='SMART rapide'; cmd='wmic diskdrive get status,model,size /format:csv'; desc='Etat SMART des disques detectes' }
        )
        'Hardware instability'                                  = @(
            [pscustomobject]@{ label='Info materiel'; cmd='wmic computersystem get model,manufacturer,totalphysicalmemory /format:csv'; desc='Informations sur le materiel de la machine' }
            [pscustomobject]@{ label='SMART rapide'; cmd='wmic diskdrive get status,model,size /format:csv'; desc='Etat SMART des disques' }
        )
    }
    $result = $map[$PatternName]
    if ($null -eq $result) {
        return @([pscustomobject]@{ label='Exporter infos systeme'; cmd='msinfo32 /report sysinfo-export.txt'; desc='Exporter les informations systeme completes' })
    }
    return $result
}

function Write-DanewSavDiagnosticReportHtml {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [object]$CrashAnalysis
    )

    # ---- Cause rows ----
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

    # ---- Event rows (top 50, enhanced with family) ----
    $eventRows = @()
    foreach ($classifiedRecord in @($CrashAnalysis.classification.records | Select-Object -First 50)) {
        $dupCount  = [int](Get-DanewCrashSafeProperty -Object $classifiedRecord -Name 'duplicate_count' -DefaultValue 1)
        $msgText   = [string](Get-DanewCrashSafeProperty -Object $classifiedRecord -Name 'message' -DefaultValue '')
        if ($dupCount -gt 1) { $msgText = "$msgText [x$dupCount]" }
        $ts   = [string](Get-DanewCrashSafeProperty -Object $classifiedRecord -Name 'timestamp'  -DefaultValue '')
        $eid  = [string](Get-DanewCrashSafeProperty -Object $classifiedRecord -Name 'event_id'   -DefaultValue '')
        $prov = [string](Get-DanewCrashSafeProperty -Object $classifiedRecord -Name 'provider'   -DefaultValue '')
        $cats = @(Get-DanewCrashSafeProperty -Object $classifiedRecord -Name 'categories' -DefaultValue @()) -join '; '
        $crit = [int](Get-DanewCrashSafeProperty -Object $classifiedRecord -Name 'criticality' -DefaultValue 0)
        $msgShort = if ($msgText.Length -gt 130) { $msgText.Substring(0, 130) + '...' } else { $msgText }
        $critTone = if ($crit -ge 5) { 'danger' } elseif ($crit -ge 3) { 'warn' } else { 'neutral' }
        $rowSearch = ConvertTo-DanewReportHtmlText (($ts, $eid, $prov, $cats, $msgShort) -join ' ')
        $eventRows += "<tr data-search-row=`"$rowSearch`" data-family=`"$([System.Security.SecurityElement]::Escape($cats))`"><td>$([System.Security.SecurityElement]::Escape($ts))</td><td>$([System.Security.SecurityElement]::Escape($eid))</td><td>$([System.Security.SecurityElement]::Escape($prov))</td><td>$([System.Security.SecurityElement]::Escape($cats))</td><td><span class='report-badge report-badge-$critTone'>$([System.Security.SecurityElement]::Escape([string]$crit))</span></td><td>$([System.Security.SecurityElement]::Escape($msgShort))</td></tr>"
    }

    # ---- Timeline intelligence rows ----
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

    # ---- Explanation / recommendations ----
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

    # ---- Client text (simple, non-technical) ----
    $clientText = Get-DanewSavClientText -PrimaryCause $CrashAnalysis.root_cause_analysis.primary_cause
    $clientTextHtml = '<div class="client-text-box"><span class="client-text-icon" aria-hidden="true">&#128100;</span><div><strong>Information client :</strong> ' + [System.Security.SecurityElement]::Escape($clientText) + '</div></div>'

    # ---- Critical timeline (criticality >= 3, max 40 events) ----
    $critAllRecords = @($CrashAnalysis.classification.records | Where-Object {
        [int](Get-DanewCrashSafeProperty -Object $_ -Name 'criticality' -DefaultValue 0) -ge 3
    } | Sort-Object { [string](Get-DanewCrashSafeProperty -Object $_ -Name 'timestamp' -DefaultValue '') })
    $critTotalCount = @($critAllRecords).Count
    $critTimelineRows = @()
    foreach ($rec in @($critAllRecords | Select-Object -First 40)) {
        $cats  = @(Get-DanewCrashSafeProperty -Object $rec -Name 'categories' -DefaultValue @()) -join '; '
        $crit  = [int](Get-DanewCrashSafeProperty -Object $rec -Name 'criticality' -DefaultValue 0)
        $ts    = [string](Get-DanewCrashSafeProperty -Object $rec -Name 'timestamp'  -DefaultValue '')
        $eid   = [string](Get-DanewCrashSafeProperty -Object $rec -Name 'event_id'   -DefaultValue '')
        $prov  = [string](Get-DanewCrashSafeProperty -Object $rec -Name 'provider'   -DefaultValue '')
        $msg   = [string](Get-DanewCrashSafeProperty -Object $rec -Name 'message'    -DefaultValue '')
        $msgS  = if ($msg.Length -gt 120) { $msg.Substring(0, 120) + '...' } else { $msg }
        $critTone = if ($crit -ge 5) { 'danger' } elseif ($crit -ge 4) { 'warn' } else { 'neutral' }
        $rs    = ConvertTo-DanewReportHtmlText (($ts, $eid, $prov, $cats, $msgS) -join ' ')
        $critTimelineRows += "<tr data-search-row=`"$rs`"><td>$([System.Security.SecurityElement]::Escape($ts))</td><td>$([System.Security.SecurityElement]::Escape($cats))</td><td>$([System.Security.SecurityElement]::Escape($prov))</td><td>$([System.Security.SecurityElement]::Escape($eid))</td><td><span class='report-badge report-badge-$critTone'>$([System.Security.SecurityElement]::Escape([string]$crit))</span></td><td>$([System.Security.SecurityElement]::Escape($msgS))</td></tr>"
    }
    $critNotice = if ($critTotalCount -gt 40) { '<p class="section-caption">Affichage limite aux 40 premiers evenements critiques sur ' + $critTotalCount + ' detectes.</p>' } else { '' }

    # ---- Pattern cards with safe actions ----
    $allPatterns  = @($CrashAnalysis.timeline_intelligence.intelligence)
    $patternCount = @($allPatterns).Count
    $patternCardsHtml = '<p class="section-caption">Aucun pattern de panne detecte dans les journaux disponibles.</p>'
    if ($patternCount -gt 0) {
        $cards = @()
        foreach ($pat in $allPatterns) {
            $patName = [string](Get-DanewCrashSafeProperty -Object $pat -Name 'pattern'    -DefaultValue 'Pattern inconnu')
            $patConf = [string](Get-DanewCrashSafeProperty -Object $pat -Name 'confidence' -DefaultValue 'Low')
            $patSumm = [string](Get-DanewCrashSafeProperty -Object $pat -Name 'summary'    -DefaultValue '')
            $patEv   = @(Get-DanewCrashSafeProperty -Object $pat -Name 'evidence' -DefaultValue @())
            $confTone = switch ($patConf) { 'High' { 'danger' } 'Medium' { 'warn' } default { 'neutral' } }

            $evItems = @()
            foreach ($ev in @($patEv | Select-Object -First 3)) {
                $evTs   = [string](Get-DanewCrashSafeProperty -Object $ev -Name 'timestamp' -DefaultValue '')
                $evProv = [string](Get-DanewCrashSafeProperty -Object $ev -Name 'provider'  -DefaultValue '')
                $evMsg  = [string](Get-DanewCrashSafeProperty -Object $ev -Name 'message'   -DefaultValue '')
                $evMsgS = if ($evMsg.Length -gt 100) { $evMsg.Substring(0, 100) + '...' } else { $evMsg }
                $evItems += '<div class="pat-ev-item"><span class="pat-ev-ts">' + [System.Security.SecurityElement]::Escape($evTs) + '</span><span class="pat-ev-prov">' + [System.Security.SecurityElement]::Escape($evProv) + '</span><span class="pat-ev-msg">' + [System.Security.SecurityElement]::Escape($evMsgS) + '</span></div>'
            }

            $patActions = Get-DanewSavPatternActions -PatternName $patName
            $actHtml = ''
            foreach ($action in $patActions) {
                $aLabel = [System.Security.SecurityElement]::Escape([string]$action.label)
                $aCmd   = [System.Security.SecurityElement]::Escape([string]$action.cmd)
                $aDesc  = [System.Security.SecurityElement]::Escape([string]$action.desc)
                $actHtml += '<div class="pat-action-row"><button type="button" class="sav-copy-btn" data-cmd="' + $aCmd + '" data-label="' + $aLabel + '" onclick="danewCopyCmd(this)">&#128203; ' + $aLabel + '</button><code class="sav-cmd-code">' + $aCmd + '</code><span class="sav-cmd-desc">' + $aDesc + '</span></div>'
            }
            $actWrap = if ($actHtml) { '<details class="pat-actions-wrap"><summary>Actions SAV disponibles (copie seule — adapter &lt;LETTRE_WINDOWS&gt; avant usage)</summary><div class="pat-actions">' + $actHtml + '</div></details>' } else { '' }

            $cards += '<div class="pattern-card"><div class="pat-header"><span class="pat-name">' + [System.Security.SecurityElement]::Escape($patName) + '</span><span class="report-badge report-badge-' + $confTone + '">' + [System.Security.SecurityElement]::Escape($patConf) + '</span></div><p class="pat-summary">' + [System.Security.SecurityElement]::Escape($patSumm) + '</p><div class="pat-evidence">' + ($evItems -join '') + '</div>' + $actWrap + '</div>'
        }
        $patternCardsHtml = $cards -join ''
    }

    # ---- DISM/CBS section ----
    $dismCbsClassified = @($CrashAnalysis.classification.records | Where-Object {
        (Get-DanewCrashSafeProperty -Object $_ -Name 'provider' -DefaultValue '') -match 'Microsoft-Windows-DISM|Microsoft-Windows-CBS' -or
        (Get-DanewCrashSafeProperty -Object $_ -Name 'channel'  -DefaultValue '') -match 'DISM/TextLog|CBS/TextLog'
    })
    $dismCbsSectionHtml = ''
    if (@($dismCbsClassified).Count -gt 0) {
        $dismKbs    = @($dismCbsClassified | Where-Object { [string](Get-DanewCrashSafeProperty -Object $_ -Name 'message' -DefaultValue '') -match 'KB\d{6,}' })
        $dismErrors = @($dismCbsClassified | Where-Object {
            $lf = [string](Get-DanewCrashSafeProperty -Object $_ -Name 'level_fr' -DefaultValue '')
            $l  = [string](Get-DanewCrashSafeProperty -Object $_ -Name 'level'    -DefaultValue '')
            $lf -eq 'Erreur' -or $l -eq 'Error'
        })
        $dismClientMsg = '<p class="client-text-box"><span aria-hidden="true">&#128100;</span> <strong>Information client :</strong> Windows semble avoir effectue ou tente une operation de maintenance ou de mise a jour systeme (DISM/CBS) avant l incident.</p>'
        $dismRows = @()
        foreach ($ev in @($dismCbsClassified | Select-Object -First 20)) {
            $dts  = [string](Get-DanewCrashSafeProperty -Object $ev -Name 'timestamp' -DefaultValue '')
            $dlf  = [string](Get-DanewCrashSafeProperty -Object $ev -Name 'level_fr'  -DefaultValue '')
            if ([string]::IsNullOrWhiteSpace($dlf)) { $dlf = [string](Get-DanewCrashSafeProperty -Object $ev -Name 'level' -DefaultValue '') }
            $dmsg = [string](Get-DanewCrashSafeProperty -Object $ev -Name 'message' -DefaultValue '')
            $dmsS = if ($dmsg.Length -gt 180) { $dmsg.Substring(0, 180) } else { $dmsg }
            $drs  = ConvertTo-DanewReportHtmlText (($dts, $dlf, $dmsg) -join ' ')
            $dismRows += "<tr data-search-row=`"$drs`"><td>$([System.Security.SecurityElement]::Escape($dts))</td><td>$([System.Security.SecurityElement]::Escape($dlf))</td><td>$([System.Security.SecurityElement]::Escape($dmsS))</td></tr>"
        }
        $dStatLine = '<p>Evenements DISM/CBS : <b>' + @($dismCbsClassified).Count + '</b> &nbsp;|&nbsp; Erreurs : <b>' + @($dismErrors).Count + '</b> &nbsp;|&nbsp; KB references : <b>' + @($dismKbs).Count + '</b></p>'
        $dismCbsSectionHtml = New-DanewReportSectionHtml -Title 'Journaux DISM/CBS (maintenance systeme)' -Caption 'Evenements extraits des journaux texte DISM.log et CBS.log. Peuvent expliquer les echecs de mise a jour ou de reparation.' -SearchText 'dism cbs servicing KB maintenance update log' -BodyHtml ($dismClientMsg + $dStatLine + (New-DanewReportTableHtml -Headers @('Horodatage', 'Niveau', 'Message') -Rows $dismRows -EmptyMessage 'Aucun evenement DISM/CBS.')) -Collapsed $true
    }

    # ---- Safe actions section (consolidated per pattern family) ----
    $safeActFamilies = [ordered]@{
        'Stockage / NTFS'       = @(
            [pscustomobject]@{ label='CHKDSK scan (lecture seule)'; cmd='chkdsk <LETTRE_WINDOWS>: /scan'; desc='Verifier NTFS sans modification — lecture seule' }
            [pscustomobject]@{ label='SFC offline'; cmd='sfc /scannow /offbootdir=<LETTRE_WINDOWS>:\ /offwindir=<LETTRE_WINDOWS>:\Windows'; desc='Verifier les fichiers systeme Windows offline' }
            [pscustomobject]@{ label='SMART rapide'; cmd='wmic diskdrive get status,model,size /format:csv'; desc='Etat SMART des disques detectes' }
        )
        'Windows Update / KB'   = @(
            [pscustomobject]@{ label='Lister les KB installees'; cmd='dism /image:<LETTRE_WINDOWS>:\ /get-packages | findstr /i KB'; desc='Lister les mises a jour presentes dans l image offline' }
            [pscustomobject]@{ label='DISM CheckHealth'; cmd='dism /image:<LETTRE_WINDOWS>:\ /cleanup-image /checkhealth'; desc='Verifier integrite image Windows offline' }
            [pscustomobject]@{ label='Exporter historique MAJ'; cmd='wmic qfe list brief /format:csv > kb-history.csv'; desc='Exporter la liste des mises a jour Windows' }
        )
        'DISM / CBS'            = @(
            [pscustomobject]@{ label='Copier CBS.log'; cmd='copy <LETTRE_WINDOWS>:\Windows\Logs\CBS\CBS.log .\CBS-export.log'; desc='Exporter le journal CBS pour analyse' }
            [pscustomobject]@{ label='Copier DISM.log'; cmd='copy <LETTRE_WINDOWS>:\Windows\Logs\DISM\dism.log .\DISM-export.log'; desc='Exporter le journal DISM pour analyse' }
            [pscustomobject]@{ label='DISM RestoreHealth (offline)'; cmd='dism /image:<LETTRE_WINDOWS>:\ /cleanup-image /restorehealth'; desc='Reparer l image Windows offline — adapter le chemin si necessaire, necessite source ISO ou reseau' }
        )
        'Winlogon / Login'      = @(
            [pscustomobject]@{ label='Verifier Userinit'; cmd='reg load HKLM\OFFLINE <LETTRE_WINDOWS>:\Windows\System32\config\SOFTWARE && reg query "HKLM\OFFLINE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v Userinit'; desc='Verifier la valeur Userinit dans le registre Winlogon' }
            [pscustomobject]@{ label='SFC offline'; cmd='sfc /scannow /offbootdir=<LETTRE_WINDOWS>:\ /offwindir=<LETTRE_WINDOWS>:\Windows'; desc='Verifier les fichiers systeme Windows offline' }
        )
        'Pilotes / Services'    = @(
            [pscustomobject]@{ label='Exporter liste pilotes'; cmd='driverquery /FO csv > drivers-export.csv'; desc='Exporter la liste des pilotes installes' }
            [pscustomobject]@{ label='Lister services'; cmd='sc query type= all state= all'; desc='Lister tous les services et leur etat' }
        )
        'WHEA / Materiel'       = @(
            [pscustomobject]@{ label='Info memoire RAM'; cmd='wmic memorychip get capacity,manufacturer,speed /format:csv > memory-info.csv'; desc='Exporter les informations sur les barrettes RAM' }
            [pscustomobject]@{ label='Planifier test memoire'; cmd='mdsched.exe'; desc='Lancer le diagnosticateur de memoire Windows' }
            [pscustomobject]@{ label='Info materiel'; cmd='wmic computersystem get model,manufacturer,totalphysicalmemory /format:csv'; desc='Informations sur le materiel de la machine' }
        )
        'Alimentation / Boot'   = @(
            [pscustomobject]@{ label='Rapport energie'; cmd='powercfg /energy'; desc='Analyser la consommation et les problemes energie' }
            [pscustomobject]@{ label='SMART rapide'; cmd='wmic diskdrive get status,model,size /format:csv'; desc='Etat SMART des disques' }
        )
        'Intel RST/VMD'         = @(
            [pscustomobject]@{ label='Exporter liste pilotes'; cmd='driverquery /FO csv > drivers-export.csv'; desc='Identifier le pilote RST/VMD installe' }
            [pscustomobject]@{ label='Info stockage'; cmd='wmic diskdrive get model,status,size,interfacetype /format:csv'; desc='Identifier le type et etat des disques detectes' }
        )
    }
    $safeActBlocks = @()
    foreach ($famKey in $safeActFamilies.Keys) {
        $famActions = $safeActFamilies[$famKey]
        $famBtns = @()
        foreach ($fa in $famActions) {
            $faLabel = [System.Security.SecurityElement]::Escape([string]$fa.label)
            $faCmd   = [System.Security.SecurityElement]::Escape([string]$fa.cmd)
            $faDesc  = [System.Security.SecurityElement]::Escape([string]$fa.desc)
            $famBtns += '<div class="pat-action-row"><button type="button" class="sav-copy-btn" data-cmd="' + $faCmd + '" data-label="' + $faLabel + '" onclick="danewCopyCmd(this)">&#128203; ' + $faLabel + '</button><code class="sav-cmd-code">' + $faCmd + '</code><span class="sav-cmd-desc">' + $faDesc + '</span></div>'
        }
        $safeActBlocks += '<div class="sav-act-family"><div class="sav-act-family-title">' + [System.Security.SecurityElement]::Escape($famKey) + '</div>' + ($famBtns -join '') + '</div>'
    }
    $safeActDisclaimer = '<div style="margin-bottom:14px;display:flex;flex-direction:column;gap:8px;">' +
        '<p class="section-caption" style="margin:0;padding:10px 14px;background:rgba(180,83,9,0.08);border:1px solid rgba(180,83,9,0.25);border-radius:10px;"><strong>&#9888; Lettre Windows WinPE :</strong> En WinPE, la lettre de la partition Windows offline peut varier (D:, E:, F:...). Remplacez <code>&lt;LETTRE_WINDOWS&gt;</code> par la lettre detectee avant d utiliser une commande. Exemple : si Windows est sur D:, remplacez <code>&lt;LETTRE_WINDOWS&gt;</code> par <code>D</code>.</p>' +
        '<p class="section-caption" style="margin:0;"><strong>Securite :</strong> Ces boutons copient uniquement la commande dans le presse-papier. Aucune commande n est executee automatiquement. Toute reparation doit etre validee par le technicien.</p>' +
        '</div>'
    $safeActionsBody = $safeActDisclaimer + '<div class="sav-act-grid">' + ($safeActBlocks -join '') + '</div>'

    # ---- Metrics ----
    $metrics = @(
        (New-DanewMetricCardHtml -Label 'Severite' -Value (Get-DanewLocalizedStatusText $CrashAnalysis.severity_analysis.overall) -Tone $CrashAnalysis.severity_analysis.overall)
        (New-DanewMetricCardHtml -Label 'Confiance principale' -Value (Get-DanewLocalizedConfidenceText (Get-DanewCrashSafeProperty -Object $CrashAnalysis.root_cause_analysis.primary_cause -Name 'confidence' -DefaultValue 'Unknown')) -Tone (Get-DanewCrashSafeProperty -Object $CrashAnalysis.root_cause_analysis.primary_cause -Name 'confidence' -DefaultValue 'neutral'))
        (New-DanewMetricCardHtml -Label 'Patterns detectes' -Value $patternCount -Tone $(if ($patternCount -ge 3) { 'warn' } elseif ($patternCount -gt 0) { 'info' } else { 'neutral' }))
        (New-DanewMetricCardHtml -Label 'Evt critiques' -Value $critTotalCount -Tone $(if ($critTotalCount -ge 5) { 'danger' } elseif ($critTotalCount -gt 0) { 'warn' } else { 'neutral' }))
        (New-DanewMetricCardHtml -Label 'Causes suivies' -Value @($CrashAnalysis.root_cause_analysis.all_causes).Count -Tone 'info')
        (New-DanewMetricCardHtml -Label 'Recommandations' -Value @($CrashAnalysis.recommendations).Count -Tone 'ready')
    ) -join ''

    # ---- Meta ----
    $meta = New-DanewReportMetaListHtml -Items @(
        [pscustomobject]@{ label = 'Horodatage';          value = $CrashAnalysis.timestamp }
        [pscustomobject]@{ label = 'Impact';              value = (Get-DanewLocalizedImpactText $CrashAnalysis.impact) }
        [pscustomobject]@{ label = 'Chemin racine';       value = $CrashAnalysis.root_path }
        [pscustomobject]@{ label = 'Confiance detection'; value = (Get-DanewLocalizedConfidenceText $CrashAnalysis.detection_confidence) }
    )

    # ---- Section bodies ----
    $summaryBody = $explanation + $clientTextHtml + '<div class="split-grid">' + (New-DanewMetricCardHtml -Label 'Cause principale' -Value (Get-DanewLocalizedCauseText (Get-DanewCrashSafeProperty -Object $CrashAnalysis.root_cause_analysis.primary_cause -Name 'cause' -DefaultValue 'Unknown')) -Tone $CrashAnalysis.severity_analysis.overall) + (New-DanewMetricCardHtml -Label 'Impact' -Value (Get-DanewLocalizedImpactText $CrashAnalysis.impact) -Tone 'warn') + '</div>'
    $recommendationBody = '<ul class="report-list">' + ($recommendations -join '') + '</ul>'

    # ---- Additional CSS (OFFLINE-SAFE) ----
    $additionalCss = @'
<style>
/* SAV Enhanced — pattern cards, timeline, copy buttons */
.client-text-box{display:flex;align-items:flex-start;gap:10px;margin:12px 0;padding:12px 16px;background:rgba(15,118,110,0.08);border:1px solid rgba(15,118,110,0.22);border-radius:12px;font-size:14px;}
.client-text-icon{font-size:20px;flex-shrink:0;margin-top:1px;}
.pattern-card{margin-bottom:14px;padding:16px;border:1px solid var(--line);border-radius:16px;background:var(--panel);}
.pat-header{display:flex;align-items:center;justify-content:space-between;gap:10px;flex-wrap:wrap;margin-bottom:8px;}
.pat-name{font-weight:700;font-size:15px;}
.pat-summary{margin:0 0 10px 0;color:var(--muted);font-size:13px;}
.pat-evidence{display:flex;flex-direction:column;gap:4px;margin-bottom:10px;}
.pat-ev-item{display:grid;grid-template-columns:160px 200px 1fr;gap:6px;font-size:12px;padding:5px 8px;background:rgba(23,32,51,0.04);border-radius:8px;overflow:hidden;}
.pat-ev-ts{color:var(--muted);font-family:Consolas,"Cascadia Mono",monospace;}
.pat-ev-prov{color:var(--accent-strong);font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}
.pat-ev-msg{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}
.pat-actions-wrap{margin-top:8px;}
.pat-actions-wrap summary{cursor:pointer;font-size:13px;color:var(--muted);padding:4px 0;}
.pat-actions-wrap summary:hover{color:var(--accent);}
.pat-actions{display:flex;flex-direction:column;gap:8px;margin-top:8px;}
.pat-action-row{display:grid;grid-template-columns:auto 1fr;grid-template-rows:auto auto;gap:4px 10px;align-items:start;padding:8px;background:rgba(23,32,51,0.03);border-radius:10px;border:1px solid var(--line);}
.sav-copy-btn{grid-row:1;grid-column:1;padding:7px 12px;border-radius:10px;border:1px solid rgba(15,118,110,0.35);background:rgba(15,118,110,0.09);color:var(--accent-strong);cursor:pointer;font-size:12px;font-weight:600;white-space:nowrap;transition:background 120ms,transform 120ms;}
.sav-copy-btn:hover{background:rgba(15,118,110,0.18);transform:translateY(-1px);}
.sav-copy-btn:active{transform:translateY(0);}
.sav-copy-btn.copied{background:rgba(15,118,110,0.28);color:#0f766e;}
.sav-cmd-code{grid-row:1;grid-column:2;font-family:Consolas,"Cascadia Mono",monospace;font-size:12px;background:rgba(23,32,51,0.06);border-radius:6px;padding:5px 8px;overflow-x:auto;white-space:pre;}
.sav-cmd-desc{grid-row:2;grid-column:1/-1;font-size:11px;color:var(--muted);}
.sav-act-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:14px;}
.sav-act-family{padding:14px;border:1px solid var(--line);border-radius:14px;background:var(--panel);}
.sav-act-family-title{font-weight:700;font-size:14px;margin-bottom:10px;padding-bottom:6px;border-bottom:1px solid var(--line);}
@media(max-width:720px){.pat-ev-item{grid-template-columns:1fr;}.pat-action-row{grid-template-columns:1fr;}.sav-cmd-code{grid-row:2;grid-column:1;}.sav-cmd-desc{grid-row:3;}}
body.theme-dark .client-text-box{background:rgba(20,184,166,0.08);border-color:rgba(20,184,166,0.2);}
body.theme-dark .pattern-card{background:rgba(15,23,42,0.85);}
body.theme-dark .pat-ev-item{background:rgba(255,255,255,0.04);}
body.theme-dark .sav-copy-btn{background:rgba(20,184,166,0.12);border-color:rgba(20,184,166,0.3);color:#14b8a6;}
body.theme-dark .sav-copy-btn:hover{background:rgba(20,184,166,0.22);}
body.theme-dark .sav-cmd-code{background:rgba(255,255,255,0.05);}
body.theme-dark .sav-act-family{background:rgba(15,23,42,0.85);}
body.theme-dark .pat-action-row{background:rgba(255,255,255,0.03);}
</style>
'@

    # ---- Additional JS (OFFLINE-SAFE — copy only, no auto-exec) ----
    $additionalJs = @'
<script>
(function(){
function danewCopyCmd(btn){
    var cmd=btn.getAttribute('data-cmd');
    var origText=btn.textContent;
    function markCopied(){btn.textContent='✅ Copie!';btn.classList.add('copied');setTimeout(function(){btn.textContent=origText;btn.classList.remove('copied');},2200);}
    if(navigator.clipboard&&navigator.clipboard.writeText){
        navigator.clipboard.writeText(cmd).then(markCopied,function(){legacyCopy(cmd,markCopied);});
    } else { legacyCopy(cmd,markCopied); }
}
function legacyCopy(text,cb){
    var ta=document.createElement('textarea');ta.value=text;ta.style.position='fixed';ta.style.opacity='0';
    document.body.appendChild(ta);ta.focus();ta.select();
    try{document.execCommand('copy');}catch(e){}
    document.body.removeChild(ta);cb();
}
window.danewCopyCmd=danewCopyCmd;

// Family filter for event table
document.addEventListener('DOMContentLoaded',function(){
    var filterBtns=document.querySelectorAll('[data-family-filter]');
    filterBtns.forEach(function(btn){
        btn.addEventListener('click',function(){
            var fam=btn.getAttribute('data-family-filter');
            filterBtns.forEach(function(b){b.classList.remove('primary-button');});
            btn.classList.add('primary-button');
            var rows=document.querySelectorAll('#evtx-table tbody tr');
            rows.forEach(function(row){
                if(!fam||fam==='all'){row.hidden=false;return;}
                var rowFam=(row.getAttribute('data-family')||'').toLowerCase();
                row.hidden=rowFam.indexOf(fam.toLowerCase())===-1;
            });
        });
    });
});
})();
</script>
'@

    # ---- Toolbar filter buttons ----
    $familyFilterBtns = @('Tout','BugCheck / BSOD','Disk / Storage','NTFS corruption','Windows Update failure','Service startup failures','DriverFrameworks issues','Winlogon / login failure','Windows Update / KB servicing','WHEA hardware errors','Kernel-Power shutdown') | ForEach-Object {
        $fam = $_
        $attr = if ($fam -eq 'Tout') { 'all' } else { $fam }
        '<button type="button" data-family-filter="' + [System.Security.SecurityElement]::Escape($attr) + '">' + [System.Security.SecurityElement]::Escape($fam) + '</button>'
    }
    $toolbarFamilyHtml = '<span style="font-size:12px;color:var(--muted);margin-right:4px;">Famille:</span>' + ($familyFilterBtns -join '')

    # ---- Assemble sections ----
    $sections = @(
        (New-DanewReportSectionHtml -Title 'Resume executif' -Caption 'Cause racine la plus probable, criticite et message client. Aucune reparation ne doit etre lancee depuis cette phase.' -SearchText ('summary cause racine impact criticite ' + [string](Get-DanewCrashSafeProperty -Object $CrashAnalysis.root_cause_analysis.primary_cause -Name 'cause' -DefaultValue '')) -BodyHtml $summaryBody)
        (New-DanewReportSectionHtml -Title 'Frise chronologique critique' -Caption ('Top ' + [string]([Math]::Min(40, $critTotalCount)) + ' evenements critiques (criticite >= 3) tries par timestamp. ' + $critTotalCount + ' evenements critiques detectes au total.') -SearchText 'frise chronologie critique timestamp famille provider event' -BodyHtml ($critNotice + (New-DanewReportTableHtml -Headers @('Horodatage', 'Famille', 'Fournisseur', 'ID Evt', 'Score', 'Message') -Rows $critTimelineRows -EmptyMessage 'Aucun evenement de criticite >= 3 detecte dans les journaux.')))
        (New-DanewReportSectionHtml -Title 'Patterns de panne detectes' -Caption ([string]$patternCount + ' pattern(s) detecte(s). Chaque carte indique la sequence, les preuves et les actions SAV disponibles (copie seulement).') -SearchText 'patterns panne sequence preuves confidence cause impact' -BodyHtml $patternCardsHtml)
        (New-DanewReportSectionHtml -Title 'Causes principales et secondaires' -Caption 'Score et justification pour chaque hypothese de cause racine, triee par score decroissant.' -SearchText 'causes confidence score reason root cause analysis' -BodyHtml (New-DanewReportTableHtml -Headers @('Cause', 'Confiance', 'Score', 'Justification') -Rows $causeRows -EmptyMessage 'Aucune cause ne correspond.'))
        (New-DanewReportSectionHtml -Title 'Intelligence de chronologie' -Caption 'Motifs detectes dans la chronologie brute — complement de la section Patterns.' -SearchText 'timeline intelligence motifs confidence resume' -BodyHtml (New-DanewReportTableHtml -Headers @('Motif', 'Confiance', 'Resume') -Rows $timelineRows -EmptyMessage 'Aucun motif.') -Collapsed $true)
        (New-DanewReportSectionHtml -Title 'Tableau des evenements (top 50)' -Caption 'Tous les evenements classes — utilisez les filtres famille dans la barre d outils secondaire.' -SearchText 'event classification provider category message criticite' -BodyHtml (New-DanewReportTableHtml -Headers @('Horodatage', 'ID Evt', 'Fournisseur', 'Categorie', 'Score', 'Message') -Rows $eventRows -EmptyMessage 'Aucun evenement.') -Collapsed $true)
        $(if ($dismCbsSectionHtml) { $dismCbsSectionHtml })
        (New-DanewReportSectionHtml -Title 'Depannage SAV securise' -Caption 'Actions disponibles par famille de panne. Cliquer = copier la commande uniquement. Aucune execution automatique.' -SearchText 'depannage sav actions commandes copier chkdsk sfc dism driverquery' -BodyHtml $safeActionsBody)
        (New-DanewReportSectionHtml -Title 'Prochaines actions recommandees' -Caption 'Synthese des actions en lecture seule validees pour cette phase.' -SearchText ('recommendations next steps ' + (@($CrashAnalysis.recommendations) -join ' ')) -BodyHtml $recommendationBody)
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    $html = New-DanewInteractiveReportHtml `
        -Title 'Rapport de diagnostic SAV Danew' `
        -Subtitle 'Diagnostic hors ligne oriente crash: patterns, frise critique, hypotheses cause racine, depannage SAV securise.' `
        -Status ([string]$CrashAnalysis.severity_analysis.overall) `
        -Eyebrow 'Analyse SAV / crash' `
        -HeroMetricsHtml ('<div class="hero-metrics">' + $metrics + '</div>') `
        -MetaHtml $meta `
        -Sections $sections `
        -SearchPlaceholder 'Filtrer causes, patterns, events, fournisseurs ou recommandations' `
        -CurrentReportName 'sav-diagnostic' `
        -AdditionalStyleHtml $additionalCss `
        -AdditionalScriptHtml $additionalJs `
        -AdditionalToolbarHtml $toolbarFamilyHtml

    $html | Set-Content -Path $Path -Encoding UTF8
    Update-DanewInteractiveReportsIndex -ReportsPath (Split-Path -Parent $Path) | Out-Null
}

function Write-DanewSavDiagnosticFallbackReports {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ReportsPath,
        [Parameter(Mandatory = $true)]
        [object]$CrashAnalysis
    )

    if (-not (Test-Path -Path $ReportsPath)) {
        New-Item -Path $ReportsPath -ItemType Directory -Force | Out-Null
    }

    $primaryCause = Get-DanewCrashSafeProperty -Object $CrashAnalysis.root_cause_analysis -Name 'primary_cause' -DefaultValue $null
    $primaryCauseText = if ($primaryCause) { [string](Get-DanewCrashSafeProperty -Object $primaryCause -Name 'cause' -DefaultValue 'Unknown') } else { 'Unknown' }
    $primaryConfidence = if ($primaryCause) { [string](Get-DanewCrashSafeProperty -Object $primaryCause -Name 'confidence' -DefaultValue '') } else { '' }
    $primaryScore = if ($primaryCause) { [string](Get-DanewCrashSafeProperty -Object $primaryCause -Name 'score' -DefaultValue '') } else { '' }

    $txtLines = @(
        'Rapport de diagnostic SAV Danew',
        ('Generation: ' + (Get-Date).ToString('s')),
        ('Horodatage analyse: ' + [string]$CrashAnalysis.timestamp),
        ('Racine analysee: ' + [string]$CrashAnalysis.root_path),
        ('Severite: ' + [string]$CrashAnalysis.severity),
        ('Confiance detection: ' + [string]$CrashAnalysis.detection_confidence),
        ('Cause principale: ' + $primaryCauseText),
        ('Confiance cause principale: ' + $primaryConfidence),
        ('Score cause principale: ' + $primaryScore),
        ('Impact: ' + [string]$CrashAnalysis.impact),
        '',
        'Recommandations:'
    )
    foreach ($recommendation in @($CrashAnalysis.recommendations)) {
        $txtLines += ('- ' + [string]$recommendation)
    }

    $txtLines | Set-Content -Path (Join-Path $ReportsPath 'sav-diagnostic-report.txt') -Encoding UTF8

    $causeRows = @()
    foreach ($cause in @($CrashAnalysis.root_cause_analysis.all_causes)) {
        if ($null -eq $cause) {
            continue
        }
        $causeRows += [pscustomobject]@{
            cause = [string](Get-DanewCrashSafeProperty -Object $cause -Name 'cause' -DefaultValue '')
            confidence = [string](Get-DanewCrashSafeProperty -Object $cause -Name 'confidence' -DefaultValue '')
            score = [int](Get-DanewCrashSafeProperty -Object $cause -Name 'score' -DefaultValue 0)
            evidence_count = [int](Get-DanewCrashSafeProperty -Object $cause -Name 'evidence_count' -DefaultValue 0)
            reason = [string](Get-DanewCrashSafeProperty -Object $cause -Name 'reason' -DefaultValue '')
        }
    }

    $csvPath = Join-Path $ReportsPath 'sav-diagnostic-report.csv'
    if (@($causeRows).Count -gt 0) {
        $causeRows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    }
    else {
        'cause,confidence,score,evidence_count,reason' | Set-Content -Path $csvPath -Encoding UTF8
    }
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
        detected_patterns = @($timeline.intelligence | ForEach-Object {
            [pscustomobject]@{
                pattern    = [string](Get-DanewCrashSafeProperty -Object $_ -Name 'pattern'    -DefaultValue '')
                confidence = [string](Get-DanewCrashSafeProperty -Object $_ -Name 'confidence' -DefaultValue '')
                summary    = [string](Get-DanewCrashSafeProperty -Object $_ -Name 'summary'    -DefaultValue '')
                evidence_count = @(Get-DanewCrashSafeProperty -Object $_ -Name 'evidence' -DefaultValue @()).Count
            }
        })
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
    Write-DanewSavDiagnosticFallbackReports -ReportsPath ([string]$Config.reports_path) -CrashAnalysis $crash

    return $crash
}
