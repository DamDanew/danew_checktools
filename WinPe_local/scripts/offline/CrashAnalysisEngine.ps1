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
        # Exclure les faux positifs "update" : edgeupdate, googleupdate, MozillaUpdate, etc. (services tiers non liés à Windows Update)
        $isFalseUpdatePositive = $provider -match 'edgeupdate|googleupdate|MozillaUpdate|ChromeUpdate|SoftwareUpdate|AdobeUpdate|JavaUpdate|UpdateService' -or
                                 ($text -match '\bupdate\b' -and $provider -notmatch 'Windows|Microsoft|WU|WUAUCLT|WindowsUpdate' -and $channel -match 'Application')
        if (-not $isFalseUpdatePositive -and ($provider -match 'WindowsUpdateClient|wuauclt|wusa|WindowsUpdate' -or ($text -match 'windows update|wuauclt|KB\d{6,}|cumulative update|quality update') )) { [void]$categories.Add('Windows Update failure'); $criticality += 3 }
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

function Get-DanewPatternSummaryFr {
    param([string]$PatternName, [string]$EnglishSummary)
    # Traduit les summaries générés en anglais par le moteur de patterns
    $map = @{
        'Repeated Kernel-Power loops'                = "Plusieurs arrêts anormaux du noyau ont été détectés en séquence — signe d'instabilité alimentation ou matérielle."
        'Repeated BugCheck loops'                    = "Plusieurs écrans bleus (BSOD) ont été détectés — cause probable : pilote, mémoire ou matériel défaillant."
        'Update -> reboot -> crash chain'            = "Une mise à jour Windows a déclenché une chaîne d'erreurs menant à un crash ou un redémarrage forcé."
        'NTFS corruption before login'               = "Une corruption du système de fichiers NTFS a été détectée avant la session utilisateur — intégrité du disque compromise."
        'Kernel-Power reboot triggering bugchecks'   = "Des redémarrages forcés par le noyau ont provoqué des erreurs système en cascade."
        'Driver failure causing repeated restarts'   = "Un pilote défaillant provoque des redémarrages répétés — remplacement ou rollback recommandé."
        'Repeated service failures'                  = "Des services système échouent de façon répétée au démarrage — corruption possible ou dépendance manquante."
        'WHEA hardware error indicating instability' = "Des erreurs matérielles bas niveau (WHEA) ont été détectées — CPU, RAM ou carte mère à vérifier."
        'Intel RST/VMD issue causing storage failure'= "Un problème avec le pilote Intel RST/VMD empêche l'accès au stockage — mise à jour ou désactivation nécessaire."
        'DISM/CBS servicing before crash'            = "Une opération de maintenance DISM/CBS était en cours avant le crash — intégrité de l'image Windows à vérifier."
        'CBS/DISM servicing before login failure'    = "Une opération CBS/DISM incomplète a provoqué un échec de connexion — réparation de l'image recommandée."
        'CBS/DISM corruption marker'                 = "Des marqueurs de corruption ont été détectés dans les journaux CBS/DISM — exécuter DISM CheckHealth."
        'Winlogon failure loop'                      = "Le processus de connexion Windows échoue en boucle — profil utilisateur ou service d'authentification compromis."
        'Storage errors before system halt'          = "Des erreurs de stockage précèdent chaque arrêt système — disque dur ou contrôleur à remplacer."
        'BitLocker blocking boot'                    = "BitLocker bloque le démarrage — la clé de récupération est requise pour déverrouiller le lecteur."
    }
    # Cherche par nom de pattern exact, sinon retourne l'anglais si court ou un message générique
    if ($map.ContainsKey($PatternName)) { return $map[$PatternName] }
    # Tentative de correspondance partielle
    foreach ($key in $map.Keys) {
        if ($PatternName -like "*$key*" -or $key -like "*$PatternName*") { return $map[$key] }
    }
    # Fallback : retourner le résumé anglais s'il est disponible
    if ($EnglishSummary) { return $EnglishSummary }
    return "Pattern de panne détecté — consulter les preuves ci-dessous."
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

function Get-DanewWindowsUpdatePackages {
    <#
    .SYNOPSIS Extrait et classe les paquets Windows Update depuis les records classifiés.
    Retourne une liste structurée: KB, type, statut, date, package, code erreur.
    #>
    param([object]$CrashAnalysis)

    $wuProviders = 'WindowsUpdateClient|Microsoft-Windows-WindowsUpdateClient|wuauserv|wusa|CBS|Servicing|UpdateOrchestrator|SetupDiagnostics'
    $wuCategories = @('Windows Update failure', 'Windows Update / KB servicing')

    $packages = [System.Collections.Generic.List[object]]::new()
    $seen = @{}

    foreach ($rec in @($CrashAnalysis.classification.records)) {
        $prov  = [string](Get-DanewCrashSafeProperty -Object $rec -Name 'provider'  -DefaultValue '')
        $msg   = [string](Get-DanewCrashSafeProperty -Object $rec -Name 'message'   -DefaultValue '')
        $eid   = [int](Get-DanewCrashSafeProperty    -Object $rec -Name 'event_id'  -DefaultValue 0)
        $ts    = [string](Get-DanewCrashSafeProperty  -Object $rec -Name 'timestamp' -DefaultValue '')
        $lvl   = [string](Get-DanewCrashSafeProperty  -Object $rec -Name 'level_fr'  -DefaultValue '')
        $chan   = [string](Get-DanewCrashSafeProperty  -Object $rec -Name 'channel'   -DefaultValue '')
        $cats  = @(Get-DanewCrashSafeProperty          -Object $rec -Name 'categories' -DefaultValue @())
        $crit  = [int](Get-DanewCrashSafeProperty      -Object $rec -Name 'criticality' -DefaultValue 0)

        $isWU = ($prov -match $wuProviders) -or ($cats | Where-Object { $wuCategories -contains $_ })
        $hasKB = $msg -match 'KB\d{6,}'
        if (-not $isWU -and -not $hasKB) { continue }

        # --- Extraire les KB ---
        $kbMatches = [regex]::Matches($msg, 'KB(\d{6,})')
        $kbList = @($kbMatches | ForEach-Object { 'KB' + $_.Groups[1].Value } | Select-Object -Unique)
        if ($kbList.Count -eq 0) { $kbList = @('(aucun KB)') }

        foreach ($kb in $kbList) {
            # --- Statut ---
            $status = 'Inconnu'
            $statusIcon = '⚙️'
            $statusTone = 'neutral'
            if ($eid -eq 19 -or $msg -match 'successful|install.*complet|install.*success|success.*install') {
                $status = 'INSTALLÉ'; $statusIcon = '✅'; $statusTone = 'success'
            } elseif ($eid -eq 20 -or $msg -match 'failed|failure|échec|erreur|error|0x8[0-9a-fA-F]{7}') {
                $status = 'ÉCHEC'; $statusIcon = '❌'; $statusTone = 'danger'
            } elseif ($msg -match 'restart|reboot|pending') {
                $status = 'EN ATTENTE REDÉMARRAGE'; $statusIcon = '🔄'; $statusTone = 'warn'
            } elseif ($msg -match 'download|télécharg') {
                $status = 'TÉLÉCHARGEMENT'; $statusIcon = '⬇️'; $statusTone = 'info'
            } elseif ($lvl -eq 'Erreur') {
                $status = 'ÉCHEC'; $statusIcon = '❌'; $statusTone = 'danger'
            } elseif ($lvl -eq 'Information' -and ($isWU)) {
                $status = 'INSTALLÉ'; $statusIcon = '✅'; $statusTone = 'success'
            }

            # --- Type de paquet ---
            $msgLow = $msg.ToLowerInvariant()
            $pkgType = 'Mise à jour'
            $pkgLabel = 'UPDATE'
            $pkgColor = '#1d4ed8'
            if ($msgLow -match 'driver|pilote|hdaudio|pci|usb|nvidia|amd|intel|realtek|broadcom|mediatek') {
                $pkgType = 'Pilote'; $pkgLabel = 'DRIVER'; $pkgColor = '#0891b2'
            } elseif ($msgLow -match 'firmware|bios|uefi|microcode') {
                $pkgType = 'BIOS / Firmware'; $pkgLabel = 'BIOS'; $pkgColor = '#7c3aed'
            } elseif ($msgLow -match 'feature update|mise à niveau|upgrade') {
                $pkgType = 'Mise à niveau (Feature)'; $pkgLabel = 'FEATURE'; $pkgColor = '#0f766e'
            } elseif ($msgLow -match 'security|sécurité|defender|antivirus|malicious') {
                $pkgType = 'Sécurité'; $pkgLabel = 'SECURITY'; $pkgColor = '#b45309'
            } elseif ($msgLow -match 'cumulative|cumulatif') {
                $pkgType = 'Cumulatif'; $pkgLabel = 'CUMUL'; $pkgColor = '#1d4ed8'
            } elseif ($msgLow -match 'servic|cbs|dism') {
                $pkgType = 'Maintenance CBS/DISM'; $pkgLabel = 'CBS'; $pkgColor = '#6d28d9'
            }

            # --- Nom du paquet (extraire de la parenthèse ou chemin) ---
            $pkgName = ''
            if ($msg -match 'for\s+update\s+(.+?)(?:\s+\(|$)') { $pkgName = $Matches[1].Trim() }
            elseif ($msg -match 'package\s+([^\s,]+)') { $pkgName = $Matches[1].Trim() }
            elseif ($msg -match 'Initiating changes for package\s+([^\s,]+)') { $pkgName = $Matches[1].Trim() }

            # --- Code erreur ---
            $errCode = ''
            if ($msg -match '(0x[0-9a-fA-F]{7,8})') { $errCode = $Matches[1] }

            # --- Déduplication KB+statut ---
            $key = $kb + '_' + $status + '_' + $ts.Substring(0, [Math]::Min(10, $ts.Length))
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true

            $packages.Add([pscustomobject]@{
                kb         = $kb
                timestamp  = $ts
                type       = $pkgType
                label      = $pkgLabel
                color      = $pkgColor
                status     = $status
                statusIcon = $statusIcon
                statusTone = $statusTone
                pkgName    = $pkgName
                errCode    = $errCode
                provider   = $prov
                message    = $msg
                eventId    = $eid
                criticality= $crit
            })
        }
    }

    return @($packages | Sort-Object timestamp)
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
    # On charge score >= 2 dans le DOM — le filtre min/max est géré côté JS
    # Score 0 = non classifié (trop nombreux), score 1 = inexistant, score 2+ = pertinent
    $critAllRecords = @($CrashAnalysis.classification.records | Where-Object {
        [int](Get-DanewCrashSafeProperty -Object $_ -Name 'criticality' -DefaultValue 0) -ge 2
    } | Sort-Object { [string](Get-DanewCrashSafeProperty -Object $_ -Name 'timestamp' -DefaultValue '') })
    $critTotalCount = @($critAllRecords).Count

    # Mapping famille -> couleur de la ligne verticale
    $familyColorMap = @{
        'BugCheck / BSOD'          = '#b42318'
        'Disk / Storage'           = '#c2410c'
        'NTFS corruption'          = '#c2410c'
        'Boot / BCD'               = '#b45309'
        'Kernel-Power shutdown'    = '#9a3412'
        'Windows Update failure'   = '#1d4ed8'
        'Windows Update / KB servicing' = '#1d4ed8'
        'DISM / Servicing'         = '#6d28d9'
        'WHEA hardware errors'     = '#7c3aed'
        'DriverFrameworks issues'  = '#0369a1'
        'Service startup failures' = '#0891b2'
        'Winlogon / login failure' = '#0f766e'
        'Memory instability'       = '#7c2d12'
        'BitLocker related issues' = '#374151'
    }

    $critFriseCards = @()
    foreach ($rec in @($critAllRecords | Select-Object -First 40)) {
        $cats     = @(Get-DanewCrashSafeProperty -Object $rec -Name 'categories'  -DefaultValue @())
        $crit     = [int](Get-DanewCrashSafeProperty -Object $rec -Name 'criticality' -DefaultValue 0)
        $ts       = [string](Get-DanewCrashSafeProperty -Object $rec -Name 'timestamp'  -DefaultValue '')
        $eid      = [string](Get-DanewCrashSafeProperty -Object $rec -Name 'event_id'   -DefaultValue '')
        $prov     = [string](Get-DanewCrashSafeProperty -Object $rec -Name 'provider'   -DefaultValue '')
        $msg      = [string](Get-DanewCrashSafeProperty -Object $rec -Name 'message'    -DefaultValue '')
        $levelFr  = [string](Get-DanewCrashSafeProperty -Object $rec -Name 'level_fr'   -DefaultValue '')
        $channel  = [string](Get-DanewCrashSafeProperty -Object $rec -Name 'channel'    -DefaultValue '')
        $catsJoin = $cats -join ' · '
        $msgS     = if ($msg.Length -gt 120) { $msg.Substring(0, 120) + '…' } else { $msg }

        # Couleur selon la famille
        $color = '#64748b'
        foreach ($cat in $cats) { if ($familyColorMap.ContainsKey($cat)) { $color = $familyColorMap[$cat]; break } }

        # Criticité lisible
        $critTone  = if ($crit -ge 5) { 'danger' } elseif ($crit -ge 4) { 'warn' } else { 'neutral' }
        $critText  = switch ($crit) { 5 { 'CRITIQUE' } 4 { 'ÉLEVÉ' } 3 { 'MOYEN' } default { "Score $crit" } }
        $critIcon  = if ($crit -ge 5) { '&#9940;' } elseif ($crit -ge 4) { '&#9888;' } else { '&#9679;' }

        # Niveau (Erreur/Avert./Info)
        # N'afficher le niveau que si c'est une Erreur ou Avertissement (pas Information)
        $showLevel = $levelFr -eq 'Erreur' -or $levelFr -eq 'Avertissement'
        $levelIcon = switch ($levelFr) { 'Erreur' { '&#10060;' } 'Avertissement' { '&#9888;' } default { '' } }
        $levelColor = switch ($levelFr) { 'Erreur' { '#dc2626' } 'Avertissement' { '#d97706' } default { '#6b7280' } }

        # --- Détection Windows Update : KB, type, statut ---
        $wuKb = ''; $wuStatus = ''; $wuStatusIcon = ''; $wuStatusTone = ''; $wuLabel = ''; $wuLabelColor = ''
        $msgLow = $msg.ToLowerInvariant()
        $isWuEvent = ($prov -match 'WindowsUpdateClient|wuauserv|wusa|CBS|Servicing|UpdateOrchestrator') -or
                     ($cats -contains 'Windows Update failure') -or ($cats -contains 'Windows Update / KB servicing') -or
                     ($msg -match 'KB\d{6,}')
        if ($isWuEvent) {
            $kbMatch = [regex]::Match($msg, 'KB(\d{6,})')
            if ($kbMatch.Success) { $wuKb = 'KB' + $kbMatch.Groups[1].Value }
            # Statut
            $eidInt = [int]$eid
            if ($eidInt -eq 19 -or $msgLow -match 'successful|install.*complet|success.*install') {
                $wuStatus = 'Installé'; $wuStatusIcon = '✅'; $wuStatusTone = 'success'
            } elseif ($eidInt -eq 20 -or $msgLow -match 'failed|failure|echec|0x8[0-9a-f]{7}' -or $levelFr -eq 'Erreur') {
                $wuStatus = 'Échec'; $wuStatusIcon = '❌'; $wuStatusTone = 'danger'
            } elseif ($msgLow -match 'restart|reboot|pending|attente') {
                $wuStatus = 'En attente'; $wuStatusIcon = '🔄'; $wuStatusTone = 'warn'
            } else {
                $wuStatus = 'Autre'; $wuStatusIcon = 'ℹ️'; $wuStatusTone = 'info'
            }
            # Type de paquet
            if ($msgLow -match 'driver|pilote|hdaudio|nvidia|amd|intel.*driver') { $wuLabel = 'DRIVER'; $wuLabelColor = '#0891b2' }
            elseif ($msgLow -match 'firmware|bios|uefi|microcode') { $wuLabel = 'BIOS'; $wuLabelColor = '#7c3aed' }
            elseif ($msgLow -match 'security|sécurité|defender') { $wuLabel = 'SECURITY'; $wuLabelColor = '#b45309' }
            elseif ($msgLow -match 'feature update|mise à niveau|upgrade') { $wuLabel = 'FEATURE'; $wuLabelColor = '#0f766e' }
            elseif ($msgLow -match 'cumulative|cumulatif') { $wuLabel = 'CUMUL'; $wuLabelColor = '#1d4ed8' }
            elseif ($msgLow -match 'cbs|dism|servic') { $wuLabel = 'CBS'; $wuLabelColor = '#6d28d9' }
            else { $wuLabel = 'UPDATE'; $wuLabelColor = '#1d4ed8' }
        }

        # Échapper pour HTML et pour attributs data-*
        $tsEsc    = [System.Security.SecurityElement]::Escape($ts)
        $provEsc  = [System.Security.SecurityElement]::Escape($prov)
        $eidEsc   = [System.Security.SecurityElement]::Escape($eid)
        $catEsc   = [System.Security.SecurityElement]::Escape($catsJoin)
        $msgEsc   = [System.Security.SecurityElement]::Escape($msg)
        $msgSEsc  = [System.Security.SecurityElement]::Escape($msgS)
        $colorEsc = [System.Security.SecurityElement]::Escape($color)
        $lvlEsc   = [System.Security.SecurityElement]::Escape($levelFr)
        $chanEsc  = [System.Security.SecurityElement]::Escape($channel)
        $critTxtEsc = [System.Security.SecurityElement]::Escape($critText)
        $critNumEsc = [System.Security.SecurityElement]::Escape([string]$crit)
        $wuStatusEsc = [System.Security.SecurityElement]::Escape($wuStatus)
        $wuKbEsc     = [System.Security.SecurityElement]::Escape($wuKb)
        $wuLabelColorEsc = [System.Security.SecurityElement]::Escape($wuLabelColor)
        $wuLabelEsc  = [System.Security.SecurityElement]::Escape($wuLabel)

        # Badge WU optionnel dans le header
        $wuBadgeHtml = if ($isWuEvent) {
            $kbChip = if ($wuKb) { '<span class="frise-wu-kb">' + $wuKbEsc + '</span>' } else { '' }
            $typeBadge = '<span class="frise-wu-label" style="background:' + $wuLabelColorEsc + ';">' + $wuLabelEsc + '</span>'
            $statusBadge = '<span class="frise-wu-status frise-wu-' + $wuStatusTone + '">' + $wuStatusIcon + ' ' + $wuStatusEsc + '</span>'
            $kbChip + $typeBadge + $statusBadge
        } else { '' }

        $critFriseCards += @"
<div class="frise-card frise-card-$critTone" style="border-left-color:$colorEsc" role="button" tabindex="0"
  data-ts="$tsEsc" data-prov="$provEsc" data-evid="$eidEsc" data-msg="$msgEsc"
  data-cat="$catEsc" data-level="$lvlEsc" data-crit="$critNumEsc" data-chan="$chanEsc"
  data-wu-status="$wuStatusEsc" data-wu-kb="$wuKbEsc"
  onclick="showFriseDetail(this)" onkeydown="if(event.key==='Enter'||event.key===' ')showFriseDetail(this)">
  <div class="frise-dot" style="background:$colorEsc;border-color:$colorEsc">$critIcon</div>
  <div class="frise-body">
    <div class="frise-header">
      <span class="frise-ts">$tsEsc</span>
      <span class="frise-badge frise-badge-$critTone">$critTxtEsc</span>
      $(if ($showLevel) { '<span class="frise-level" style="color:' + $levelColor + '">' + $levelIcon + ' ' + $lvlEsc + '</span>' } else { '' })
      <span class="frise-evtid">ID $eidEsc</span>
    </div>
    $(if ($isWuEvent) { '<div class="frise-wu-bar">' + $wuBadgeHtml + '</div>' } else { '' })
    <div class="frise-family" style="color:$colorEsc">$catEsc</div>
    <div class="frise-provider">$provEsc</div>
    <div class="frise-msg">$msgSEsc</div>
    <div class="frise-click-hint">&#128269; Cliquer pour voir les détails complets</div>
  </div>
</div>
"@
    }

    $friseLegend = @'
<div class="frise-legend">
  <span class="frise-legend-title">Légende :</span>
  <span class="frise-legend-item" style="background:rgba(75,85,99,0.15);color:#374151;">&#9632; Contexte (score 2)</span>
  <span class="frise-legend-item frise-legend-neutral">&#9679; MOYEN (score 3)</span>
  <span class="frise-legend-item frise-legend-warn">&#9650; ÉLEVÉ (score 4)</span>
  <span class="frise-legend-item frise-legend-danger">&#9940; CRITIQUE (score 5)</span>
  <span class="frise-legend-item" style="background:rgba(220,38,38,0.1);color:#dc2626;">&#10060; Erreur</span>
  <span class="frise-legend-item" style="background:rgba(217,119,6,0.1);color:#d97706;">&#9888;&#65039; Avert.</span>
  <span class="frise-legend-click">&#128269; Cliquer sur une carte = panneau détails</span>
</div>
'@
    # ---- Frise horizontale : dots JSON (via ConvertTo-Json pour échappement correct) ----
    $friseDotsObjects = [System.Collections.Generic.List[object]]::new()
    foreach ($rec in @($critAllRecords | Select-Object -First 40)) {
        $ts   = [string](Get-DanewCrashSafeProperty -Object $rec -Name 'timestamp'  -DefaultValue '')
        $eid  = [string](Get-DanewCrashSafeProperty -Object $rec -Name 'event_id'   -DefaultValue '')
        $prov = [string](Get-DanewCrashSafeProperty -Object $rec -Name 'provider'   -DefaultValue '')
        $msg  = [string](Get-DanewCrashSafeProperty -Object $rec -Name 'message'    -DefaultValue '')
        $crit = [int](Get-DanewCrashSafeProperty -Object $rec -Name 'criticality'   -DefaultValue 0)
        $cats = @(Get-DanewCrashSafeProperty -Object $rec -Name 'categories' -DefaultValue @())
        $cat  = if ($cats.Count -gt 0) { $cats[0] } else { '' }
        $lvl  = [string](Get-DanewCrashSafeProperty -Object $rec -Name 'level_fr'   -DefaultValue '')
        $chan = [string](Get-DanewCrashSafeProperty -Object $rec -Name 'channel'     -DefaultValue '')
        $color = '#64748b'
        foreach ($c in $cats) { if ($familyColorMap.ContainsKey($c)) { $color = $familyColorMap[$c]; break } }
        $msgTrunc = if ($msg.Length -gt 600) { $msg.Substring(0, 600) } else { $msg }

        # WU detection pour le JSON dots
        $msgLowD = $msg.ToLowerInvariant()
        $isWuD = ($prov -match 'WindowsUpdateClient|wuauserv|wusa|CBS|Servicing|UpdateOrchestrator') -or
                 ($cats -contains 'Windows Update failure') -or ($cats -contains 'Windows Update / KB servicing') -or
                 ($msg -match 'KB\d{6,}')
        $wuKbD = ''; $wuStatusD = ''; $wuStatusToneD = ''; $wuLabelD = ''; $wuLabelColorD = ''; $wuDotColorD = ''
        if ($isWuD) {
            $km = [regex]::Match($msg, 'KB(\d{6,})')
            if ($km.Success) { $wuKbD = 'KB' + $km.Groups[1].Value }
            $eidDInt = [int]$eid
            if ($eidDInt -eq 19 -or $msgLowD -match 'successful|install.*complet|success.*install') {
                $wuStatusD = 'Installé'; $wuStatusToneD = 'success'; $wuDotColorD = '#059669'
            } elseif ($eidDInt -eq 20 -or $msgLowD -match 'failed|failure|echec|0x8[0-9a-f]{7}' -or $lvl -eq 'Erreur') {
                $wuStatusD = 'Échec'; $wuStatusToneD = 'danger'; $wuDotColorD = '#dc2626'
            } elseif ($msgLowD -match 'restart|reboot|pending|attente') {
                $wuStatusD = 'En attente'; $wuStatusToneD = 'warn'; $wuDotColorD = '#d97706'
            } else {
                $wuStatusD = 'Autre'; $wuStatusToneD = 'info'; $wuDotColorD = '#0891b2'
            }
            if ($msgLowD -match 'driver|pilote') { $wuLabelD = 'DRIVER'; $wuLabelColorD = '#0891b2' }
            elseif ($msgLowD -match 'firmware|bios|uefi') { $wuLabelD = 'BIOS'; $wuLabelColorD = '#7c3aed' }
            elseif ($msgLowD -match 'security|sécurité') { $wuLabelD = 'SEC'; $wuLabelColorD = '#b45309' }
            elseif ($msgLowD -match 'feature update|upgrade') { $wuLabelD = 'FEAT'; $wuLabelColorD = '#0f766e' }
            elseif ($msgLowD -match 'cumulative|cumulatif') { $wuLabelD = 'CUM'; $wuLabelColorD = '#1d4ed8' }
            elseif ($msgLowD -match 'cbs|dism|servic') { $wuLabelD = 'CBS'; $wuLabelColorD = '#6d28d9' }
            else { $wuLabelD = 'WU'; $wuLabelColorD = '#1d4ed8' }
        }

        $friseDotsObjects.Add([pscustomobject]@{
            ts = $ts; eid = $eid; prov = $prov; msg = $msgTrunc
            crit = $crit; cat = $cat; color = $color; level = $lvl; chan = $chan
            wuKb = $wuKbD; wuStatus = $wuStatusD; wuTone = $wuStatusToneD
            wuDotColor = $wuDotColorD; wuLabel = $wuLabelD; wuLabelColor = $wuLabelColorD
            isWu = $isWuD
        })
    }
    $friseDotsJsonArr = $friseDotsObjects | ConvertTo-Json -Compress -Depth 2

    $friseHorizontalHtml = @"
<div class="frise-h-wrap" id="friseHWrap" hidden>
  <div class="frise-h-toolbar">
    <span class="frise-h-info" id="friseHInfo"></span>
    <span class="frise-h-hint">&#x1F50D; Cliquer sur un point = panneau détails</span>
    <button type="button" class="frise-h-fullscreen-btn" id="friseHFullscreenBtn" onclick="toggleFriseFullscreen()" title="Plein écran">&#x26F6; Plein écran</button>
  </div>
  <div class="frise-h-scroll" id="friseHScroll">
    <div class="frise-h-stage" id="friseHStage">
      <div class="frise-h-axis" id="friseHAxis"></div>
      <div class="frise-h-track">
        <div class="frise-h-line-bar"></div>
        <div class="frise-h-dots" id="friseHDots"></div>
      </div>
    </div>
  </div>
  <script id="friseHData" type="application/json">$friseDotsJsonArr</script>
  <script id="friseHMeta" type="application/json">$([pscustomobject]@{
    primaryCause  = [string](Get-DanewCrashSafeProperty -Object $CrashAnalysis.root_cause_analysis.primary_cause -Name 'cause' -DefaultValue '')
    primaryCauseFr= Get-DanewSavClientText -PrimaryCause $CrashAnalysis.root_cause_analysis.primary_cause
    confidence    = [string](Get-DanewCrashSafeProperty -Object $CrashAnalysis.root_cause_analysis.primary_cause -Name 'confidence' -DefaultValue '')
    severity      = [string]$CrashAnalysis.severity_analysis.overall
    rootPath      = [string]$CrashAnalysis.root_path
    scanDate      = [string]$CrashAnalysis.timestamp
  } | ConvertTo-Json -Compress)</script>
</div>
"@

    $friseToggleBar = @'
<div class="frise-view-toggle">
  <button type="button" class="frise-view-btn active" id="btnFriseList" onclick="switchFriseView('list')">&#9776; Vue liste</button>
  <button type="button" class="frise-view-btn" id="btnFriseH" onclick="switchFriseView('horizontal')">&#9135; Vue frise horizontale</button>
  <div class="frise-wu-filter" id="friseWuFilter">
    <label class="frise-filter-label">Windows Update</label>
    <button type="button" class="frise-wu-btn frise-wu-btn-all active" onclick="setFriseWuFilter('all')" title="Tous les événements">Tout</button>
    <button type="button" class="frise-wu-btn frise-wu-btn-success" onclick="setFriseWuFilter('wu')" title="Seulement les événements Windows Update">&#127975; WU seuls</button>
    <button type="button" class="frise-wu-btn frise-wu-btn-success" onclick="setFriseWuFilter('Installé')" title="Mises à jour installées avec succès">&#9989; Installés</button>
    <button type="button" class="frise-wu-btn frise-wu-btn-danger" onclick="setFriseWuFilter('Échec')" title="Mises à jour en échec">&#10060; Échecs</button>
    <button type="button" class="frise-wu-btn frise-wu-btn-warn" onclick="setFriseWuFilter('En attente')" title="Mises à jour en attente redémarrage">&#128260; En attente</button>
    <button type="button" class="frise-wu-btn frise-wu-btn-info" onclick="setFriseWuFilter('Autre')" title="Autres événements WU">&#8505;&#65039; Autres</button>
  </div>
  <div class="frise-score-filter" id="friseScoreFilter">
    <label class="frise-filter-label">Score min</label>
    <div class="frise-score-btns" id="friseMinBtns">
      <button type="button" class="frise-score-btn" data-min="2" onclick="setFriseScoreMin(2)" title="Afficher contexte + tout (Services, Thermal...)">&#9632; 2</button>
      <button type="button" class="frise-score-btn" data-min="3" onclick="setFriseScoreMin(3)" title="Afficher MOYEN + ÉLEVÉ + CRITIQUE">&#9679; 3</button>
      <button type="button" class="frise-score-btn active" data-min="4" onclick="setFriseScoreMin(4)" title="Afficher ÉLEVÉ + CRITIQUE">&#9650; 4</button>
      <button type="button" class="frise-score-btn" data-min="5" onclick="setFriseScoreMin(5)" title="Afficher CRITIQUE uniquement">&#9940; 5</button>
    </div>
    <label class="frise-filter-label">Score max</label>
    <div class="frise-score-btns" id="friseMaxBtns">
      <button type="button" class="frise-score-btn" data-max="2" onclick="setFriseScoreMax(2)" title="Afficher contexte seulement (score 2)">&#9632; 2</button>
      <button type="button" class="frise-score-btn" data-max="3" onclick="setFriseScoreMax(3)" title="Afficher jusqu'à MOYEN">&#9679; 3</button>
      <button type="button" class="frise-score-btn" data-max="4" onclick="setFriseScoreMax(4)" title="Afficher jusqu'à ÉLEVÉ">&#9650; 4</button>
      <button type="button" class="frise-score-btn active" data-max="5" onclick="setFriseScoreMax(5)" title="Afficher tout">&#9940; 5</button>
    </div>
    <span class="frise-filter-count" id="friseFilterCount"></span>
  </div>
</div>
'@

    $critFriseHtml = if (@($critFriseCards).Count -gt 0) {
        $friseLegend + $friseToggleBar + $friseHorizontalHtml + '<div class="frise-timeline" id="friseVList">' + ($critFriseCards -join '') + '</div>'
    } else {
        '<p class="section-caption">Aucun evenement de criticite &gt;= 3 detecte dans les journaux.</p>'
    }
    $critNotice = if ($critTotalCount -gt 40) { '<p class="section-caption" style="margin-bottom:12px;">&#9432; Affichage limite aux 40 premiers evenements critiques sur ' + $critTotalCount + ' detectes au total.</p>' } else { '' }

    # ---- Pattern cards with safe actions ----
    $allPatterns  = @($CrashAnalysis.timeline_intelligence.intelligence)
    $patternCount = @($allPatterns).Count
    $patternCardsHtml = '<p class="section-caption">Aucun pattern de panne detecte dans les journaux disponibles.</p>'
    if ($patternCount -gt 0) {
        $cards = @()
        foreach ($pat in $allPatterns) {
            $patName = [string](Get-DanewCrashSafeProperty -Object $pat -Name 'pattern'    -DefaultValue 'Pattern inconnu')
            $patConf = [string](Get-DanewCrashSafeProperty -Object $pat -Name 'confidence' -DefaultValue 'Low')
            $patSummRaw = [string](Get-DanewCrashSafeProperty -Object $pat -Name 'summary' -DefaultValue '')
            $patSumm = Get-DanewPatternSummaryFr -PatternName $patName -EnglishSummary $patSummRaw
            $patEv   = @(Get-DanewCrashSafeProperty -Object $pat -Name 'evidence' -DefaultValue @())
            $confTone = switch ($patConf) { 'High' { 'danger' } 'Medium' { 'warn' } default { 'neutral' } }

            $evItems = @()
            $evIdx = 0
            foreach ($ev in @($patEv | Select-Object -First 3)) {
                $evTs   = [string](Get-DanewCrashSafeProperty -Object $ev -Name 'timestamp' -DefaultValue '')
                $evProv = [string](Get-DanewCrashSafeProperty -Object $ev -Name 'provider'  -DefaultValue '')
                $evMsg  = [string](Get-DanewCrashSafeProperty -Object $ev -Name 'message'   -DefaultValue '')
                $evId   = [string](Get-DanewCrashSafeProperty -Object $ev -Name 'event_id'  -DefaultValue '')
                $evMsgS = if ($evMsg.Length -gt 100) { $evMsg.Substring(0, 100) + '...' } else { $evMsg }
                $evTsEsc = [System.Security.SecurityElement]::Escape($evTs)
                $evProvEsc = [System.Security.SecurityElement]::Escape($evProv)
                $evMsgEsc = [System.Security.SecurityElement]::Escape($evMsg)
                $evMsgSEsc = [System.Security.SecurityElement]::Escape($evMsgS)
                $evIdEsc = [System.Security.SecurityElement]::Escape($evId)
                $evItems += '<div class="pat-ev-item" data-pat-idx="' + $evIdx + '" data-ts="' + $evTsEsc + '" data-prov="' + $evProvEsc + '" data-msg="' + $evMsgEsc + '" data-evid="' + $evIdEsc + '" onclick="showPatternDetail(this)" style="cursor:pointer;"><span class="pat-ev-ts">' + $evTsEsc + '</span><span class="pat-ev-prov">' + $evProvEsc + '</span><span class="pat-ev-msg">' + $evMsgSEsc + '</span></div>'
                $evIdx++
            }

            $patActions = Get-DanewSavPatternActions -PatternName $patName
            $actHtml = ''
            foreach ($action in $patActions) {
                $aLabel = [System.Security.SecurityElement]::Escape([string]$action.label)
                $aCmd   = [System.Security.SecurityElement]::Escape([string]$action.cmd)
                $aDesc  = [System.Security.SecurityElement]::Escape([string]$action.desc)
                $actHtml += '<div class="pat-action-row"><button type="button" class="sav-copy-btn" data-cmd="' + $aCmd + '" data-label="' + $aLabel + '" onclick="danewCopyCmd(this)">&#128203; ' + $aLabel + '</button><code class="sav-cmd-code">' + $aCmd + '</code><span class="sav-cmd-desc">' + $aDesc + '</span></div>'
            }
            $actWrap = if ($actHtml) { '<details class="pat-actions-wrap" open><summary>&#128295; Actions SAV disponibles <span class="pat-actions-badge">copie seule</span></summary><div class="pat-actions">' + $actHtml + '</div></details>' } else { '' }

            $cards += '<div class="pattern-card"><div class="pat-header"><span class="pat-name">' + [System.Security.SecurityElement]::Escape($patName) + '</span><span class="report-badge report-badge-' + $confTone + '">' + [System.Security.SecurityElement]::Escape($patConf) + '</span></div><p class="pat-summary">' + [System.Security.SecurityElement]::Escape($patSumm) + '</p><div class="pat-evidence">' + ($evItems -join '') + '</div>' + $actWrap + '</div>'
        }

        # Create patterns section with legend, cards, detail panel, and summary table
        $patLegend = @"
<div class="pat-legend">
  <p><strong>Comment utiliser cette section :</strong></p>
  <ul>
    <li><span class="legend-badge legend-badge-danger">HIGH</span> = Confiance élevée — cause probable</li>
    <li><span class="legend-badge legend-badge-warn">MEDIUM</span> = Confiance moyenne — cause possible</li>
    <li><span class="legend-badge legend-badge-neutral">LOW</span> = Confiance faible — à vérifier</li>
    <li>Cliquez sur une ligne d'évidence pour voir les détails complets → panneau de droite</li>
    <li>Copiez les commandes SAV (boutons) pour dépannage manuel en WinPE</li>
    <li>Chaque ligne affiche les 3 premiers événements du pattern ; le tableau en bas résume tous</li>
  </ul>
</div>
"@

        # Build evidence table data from all patterns
        $allEvidenceData = @()
        foreach ($pat in $allPatterns) {
            $pn = [string](Get-DanewCrashSafeProperty -Object $pat -Name 'pattern' -DefaultValue 'Pattern inconnu')
            $pc = [string](Get-DanewCrashSafeProperty -Object $pat -Name 'confidence' -DefaultValue 'Low')
            $pev = @(Get-DanewCrashSafeProperty -Object $pat -Name 'evidence' -DefaultValue @())
            foreach ($e in $pev) {
                $ets = [string](Get-DanewCrashSafeProperty -Object $e -Name 'timestamp' -DefaultValue '')
                $epv = [string](Get-DanewCrashSafeProperty -Object $e -Name 'provider' -DefaultValue '')
                $emg = [string](Get-DanewCrashSafeProperty -Object $e -Name 'message' -DefaultValue '')
                $allEvidenceData += @{pattern=$pn; confidence=$pc; timestamp=$ets; provider=$epv; message=$emg}
            }
        }

        $evidenceTableHtml = ''
        if (@($allEvidenceData).Count -gt 0) {
            $tableRows = @()
            foreach ($ed in $allEvidenceData) {
                $pnEsc = [System.Security.SecurityElement]::Escape([string]$ed.pattern)
                $etsEsc = [System.Security.SecurityElement]::Escape([string]$ed.timestamp)
                $epvEsc = [System.Security.SecurityElement]::Escape([string]$ed.provider)
                $emgEsc = [System.Security.SecurityElement]::Escape([string]$ed.message)
                $confTone = switch ([string]$ed.confidence) { 'High' { 'danger' } 'Medium' { 'warn' } default { 'neutral' } }
                $tableRows += '<tr data-pattern="' + $pnEsc + '" data-conf="' + [string]$ed.confidence + '" data-ts="' + $etsEsc + '" data-prov="' + $epvEsc + '" data-msg="' + $emgEsc + '" data-evid="" onclick="showPatternDetail(this)" style="cursor:pointer;"><td><strong>' + $pnEsc + '</strong></td><td><span class="report-badge report-badge-' + $confTone + '">' + [System.Security.SecurityElement]::Escape([string]$ed.confidence) + '</span></td><td>' + $etsEsc + '</td><td>' + $epvEsc + '</td><td>' + $emgEsc + '</td></tr>'
            }
            $evidenceTableHtml = @"
<div class="pat-table-wrap">
  <h4>Tableau récapitulatif - Tous les événements</h4>
  <table class="pat-evidence-table" id="patEvidenceTable">
    <thead>
      <tr>
        <th data-sort-trigger="pattern">Pattern</th>
        <th data-sort-trigger="confidence">Confiance</th>
        <th data-sort-trigger="timestamp">Date/Heure</th>
        <th data-sort-trigger="provider">Source</th>
        <th data-sort-trigger="message">Détails</th>
      </tr>
    </thead>
    <tbody>
      $($tableRows -join '')
    </tbody>
  </table>
</div>
"@
        }

        # Fixed overlay panel — same pattern as OfflineLogsEngine evtx-detail-panel
        $fixedDetailPanel = @'
<aside class="pat-detail-panel" id="patDetailPanel" hidden>
  <div class="pat-detail-head">
    <h3 id="patDetailTitle">Détail événement</h3>
    <button type="button" class="ghost-button" id="patDetailClose" title="Fermer">&#10005; Fermer</button>
  </div>
  <div class="pat-detail-body" id="patDetailBody"></div>
  <div class="pat-detail-footer" id="patDetailFooter">
    <button type="button" class="pat-detail-copy-btn" id="patCopyBtnGlobal">&#128203; Copier tout</button>
    <button type="button" class="pat-detail-ai-btn" id="patAiBtnGlobal">&#129302; Analyse IA complète</button>
  </div>
</aside>
'@
        $patternCardsHtml = $patLegend + '<div class="pat-cards-list">' + ($cards -join '') + '</div>' + $evidenceTableHtml + $fixedDetailPanel
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

    # ---- Windows Update Package History section ----
    $wuPackages = @(Get-DanewWindowsUpdatePackages -CrashAnalysis $CrashAnalysis)
    $wuSectionHtml = ''
    if ($wuPackages.Count -gt 0) {
        $wuSuccess = @($wuPackages | Where-Object { $_.statusTone -eq 'success' }).Count
        $wuFailed  = @($wuPackages | Where-Object { $_.statusTone -eq 'danger'  }).Count
        $wuPending = @($wuPackages | Where-Object { $_.statusTone -eq 'warn'    }).Count
        $wuOther   = $wuPackages.Count - $wuSuccess - $wuFailed - $wuPending

        # Summary cards
        $wuSummary = '<div class="wu-summary">' +
            '<div class="wu-stat wu-stat-success"><span class="wu-stat-icon">&#9989;</span><span class="wu-stat-val">' + $wuSuccess + '</span><span class="wu-stat-lbl">Installés</span></div>' +
            '<div class="wu-stat wu-stat-danger"><span class="wu-stat-icon">&#10060;</span><span class="wu-stat-val">' + $wuFailed + '</span><span class="wu-stat-lbl">Échecs</span></div>' +
            '<div class="wu-stat wu-stat-warn"><span class="wu-stat-icon">&#128260;</span><span class="wu-stat-val">' + $wuPending + '</span><span class="wu-stat-lbl">En attente</span></div>' +
            '<div class="wu-stat wu-stat-neutral"><span class="wu-stat-icon">&#8505;</span><span class="wu-stat-val">' + $wuOther + '</span><span class="wu-stat-lbl">Autres</span></div>' +
            '</div>'

        # Table rows
        $wuRows = @()
        foreach ($pkg in $wuPackages) {
            $kbEsc    = [System.Security.SecurityElement]::Escape($pkg.kb)
            $tsEsc    = [System.Security.SecurityElement]::Escape($pkg.timestamp)
            $typeEsc  = [System.Security.SecurityElement]::Escape($pkg.type)
            $stEsc    = [System.Security.SecurityElement]::Escape($pkg.status)
            $stIcon   = $pkg.statusIcon
            $nameEsc  = [System.Security.SecurityElement]::Escape($pkg.pkgName)
            $errEsc   = [System.Security.SecurityElement]::Escape($pkg.errCode)
            $colorEsc = [System.Security.SecurityElement]::Escape($pkg.color)
            $msgEsc   = [System.Security.SecurityElement]::Escape($pkg.message)
            $toneEsc  = [System.Security.SecurityElement]::Escape($pkg.statusTone)
            $labelEsc = [System.Security.SecurityElement]::Escape($pkg.label)
            $tone = $pkg.statusTone
            $rowBg = switch ($tone) { 'success' { 'rgba(16,185,129,0.06)' } 'danger' { 'rgba(239,68,68,0.07)' } 'warn' { 'rgba(245,158,11,0.07)' } default { '' } }

            $searchText = ConvertTo-DanewReportHtmlText (($pkg.kb, $pkg.type, $pkg.timestamp, $pkg.status, $pkg.pkgName, $pkg.errCode) -join ' ')
            $wuRows += "<tr data-search-row=`"$searchText`" data-status=`"$toneEsc`" data-ts=`"$tsEsc`" data-prov=`"$([System.Security.SecurityElement]::Escape($pkg.provider))`" data-msg=`"$msgEsc`" data-evid=`"$([string]$pkg.eventId)`" data-crit=`"$([string]$pkg.criticality)`" data-cat=`"$typeEsc`" data-level=`"`" data-chan=`"`" style=`"background:$rowBg;cursor:pointer;`" onclick=`"showPatternDetail(this)`"><td><span class='wu-kb-chip'>$kbEsc</span></td><td><span class='wu-type-badge' style='background:$colorEsc;'>$labelEsc</span></td><td>$typeEsc</td><td>$tsEsc</td><td>$stIcon <span class='wu-status-$toneEsc'>$stEsc</span></td><td>$nameEsc</td><td class='wu-err-code'>$errEsc</td></tr>"
        }

        $wuSectionHtml = New-DanewReportSectionHtml `
            -Title 'Historique Windows Update' `
            -Caption ([string]$wuPackages.Count + ' paquet(s) detectes. Cliquer une ligne = panneau details complet.') `
            -SearchText 'windows update KB driver bios security feature cumulative installed failed' `
            -BodyHtml ($wuSummary + (New-DanewReportTableHtml -Headers @('KB', 'Type', 'Catégorie', 'Date/Heure', 'Statut', 'Nom paquet', 'Code erreur') -Rows $wuRows -EmptyMessage 'Aucun paquet Windows Update détecté.')) `
            -Collapsed $false
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
        [pscustomobject]@{ label = 'Horodatage';          value = $(try { [datetime]::Parse($CrashAnalysis.timestamp).ToString("dd/MM/yyyy 'à' HH'h'mm") } catch { $CrashAnalysis.timestamp }) }
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
/* Windows Update History */
.wu-summary{display:flex;gap:12px;flex-wrap:wrap;margin-bottom:16px;}
.wu-stat{display:flex;flex-direction:column;align-items:center;justify-content:center;gap:4px;padding:14px 20px;border-radius:14px;border:1px solid var(--line);background:var(--panel);min-width:90px;text-align:center;}
.wu-stat-icon{font-size:22px;}
.wu-stat-val{font-size:28px;font-weight:800;line-height:1;}
.wu-stat-lbl{font-size:11px;text-transform:uppercase;letter-spacing:0.07em;color:var(--muted);}
.wu-stat-success{border-color:rgba(16,185,129,0.3);background:rgba(16,185,129,0.06);}
.wu-stat-success .wu-stat-val{color:#065f46;}
.wu-stat-danger{border-color:rgba(239,68,68,0.3);background:rgba(239,68,68,0.06);}
.wu-stat-danger .wu-stat-val{color:#991b1b;}
.wu-stat-warn{border-color:rgba(245,158,11,0.3);background:rgba(245,158,11,0.06);}
.wu-stat-warn .wu-stat-val{color:#78350f;}
.wu-stat-neutral{border-color:var(--line);background:rgba(23,32,51,0.04);}
.wu-stat-neutral .wu-stat-val{color:var(--muted);}
.wu-kb-chip{display:inline-block;padding:3px 8px;border-radius:6px;font-family:Consolas,"Cascadia Mono",monospace;font-size:12px;font-weight:700;background:#dbeafe;color:#1e40af;white-space:nowrap;}
.wu-type-badge{display:inline-block;padding:3px 8px;border-radius:6px;font-size:10px;font-weight:700;color:#fff;letter-spacing:0.04em;text-transform:uppercase;}
.wu-status-success{color:#065f46;font-weight:700;}
.wu-status-danger{color:#991b1b;font-weight:700;}
.wu-status-warn{color:#78350f;font-weight:700;}
.wu-err-code{font-family:Consolas,"Cascadia Mono",monospace;font-size:11px;color:var(--muted);}
body.theme-dark .wu-kb-chip{background:rgba(30,64,175,0.25);color:#93c5fd;}
body.theme-dark .wu-stat-success{background:rgba(16,185,129,0.08);}
body.theme-dark .wu-stat-success .wu-stat-val{color:#6ee7b7;}
body.theme-dark .wu-stat-danger{background:rgba(239,68,68,0.08);}
body.theme-dark .wu-stat-danger .wu-stat-val{color:#fca5a5;}
body.theme-dark .wu-stat-warn{background:rgba(245,158,11,0.08);}
body.theme-dark .wu-stat-warn .wu-stat-val{color:#fbbf24;}
.client-text-box{display:flex;align-items:flex-start;gap:10px;margin:12px 0;padding:12px 16px;background:rgba(15,118,110,0.08);border:1px solid rgba(15,118,110,0.22);border-radius:12px;font-size:14px;}
.client-text-icon{font-size:20px;flex-shrink:0;margin-top:1px;}
.pattern-card{margin-bottom:14px;padding:16px;border:1px solid var(--line);border-radius:16px;background:var(--panel);}
.pat-header{display:flex;align-items:center;justify-content:space-between;gap:10px;flex-wrap:wrap;margin-bottom:8px;}
.pat-name{font-weight:700;font-size:15px;}
.pat-summary{margin:0 0 10px 0;color:var(--muted);font-size:13px;}
.pat-evidence{display:flex;flex-direction:column;gap:4px;margin-bottom:10px;}
.pat-ev-item{display:grid;grid-template-columns:130px 140px 1fr;grid-auto-rows:auto;gap:6px;font-size:12px;padding:5px 8px;background:rgba(23,32,51,0.04);border-radius:8px;align-items:start;}
.pat-ev-ts{color:var(--muted);font-family:Consolas,"Cascadia Mono",monospace;}
.pat-ev-prov{color:var(--accent-strong);font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}
.pat-ev-msg{overflow:hidden;word-break:break-word;white-space:pre-wrap;line-height:1.35;max-height:6.75em;padding-top:2px;}
.pat-actions-wrap{margin-top:10px;border:1px solid rgba(15,118,110,0.2);border-radius:10px;overflow:hidden;}
.pat-actions-wrap summary{cursor:pointer;font-size:13px;font-weight:600;color:var(--accent-strong);padding:8px 12px;background:rgba(15,118,110,0.06);display:flex;align-items:center;gap:8px;list-style:none;}
.pat-actions-wrap summary::-webkit-details-marker{display:none;}
.pat-actions-wrap summary::before{content:'▸';transition:transform 180ms;font-size:11px;color:var(--accent);}
.pat-actions-wrap[open] summary::before{content:'▾';}
.pat-actions-wrap summary:hover{background:rgba(15,118,110,0.1);}
.pat-actions-badge{display:inline-block;padding:2px 7px;border-radius:5px;font-size:10px;font-weight:700;background:rgba(15,118,110,0.15);color:var(--accent-strong);margin-left:auto;text-transform:uppercase;letter-spacing:0.04em;}
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
.pat-legend{padding:14px;background:rgba(15,118,110,0.06);border:1px solid rgba(15,118,110,0.15);border-radius:12px;margin-bottom:16px;}
.pat-legend p{margin:0 0 10px 0;font-size:13px;font-weight:600;}
.pat-legend ul{margin:0;padding-left:20px;font-size:12px;line-height:1.6;}
.pat-legend li{margin-bottom:6px;}
.legend-badge{display:inline-block;padding:3px 8px;border-radius:5px;font-size:11px;font-weight:600;margin-right:6px;}
.legend-badge-danger{background:#fee2e2;color:#7f1d1d;}
.legend-badge-warn{background:#fef3c7;color:#78350f;}
.legend-badge-neutral{background:#e5e7eb;color:#374151;}
body.theme-dark .pat-legend{background:rgba(20,184,166,0.06);border-color:rgba(20,184,166,0.15);}
body.theme-dark .legend-badge-danger{background:rgba(220,38,38,0.2);color:#fca5a5;}
body.theme-dark .legend-badge-warn{background:rgba(217,119,6,0.2);color:#fbbf24;}
body.theme-dark .legend-badge-neutral{background:rgba(107,114,128,0.2);color:#d1d5db;}
.pat-cards-list{display:flex;flex-direction:column;gap:14px;margin-bottom:20px;}
.pat-detail-panel{position:fixed;top:76px;right:16px;width:400px;max-height:calc(100vh - 96px);display:flex;flex-direction:column;z-index:1200;border:1px solid var(--line);border-radius:18px;background:#ffffff;box-shadow:0 8px 40px rgba(0,0,0,0.18);pointer-events:none;overflow:hidden;}
.pat-detail-panel[hidden]{display:none!important;}
.pat-detail-panel>*{pointer-events:auto;}
.pat-detail-panel{animation:patSlideIn 0.22s ease;}
.pat-detail-head{padding:14px 16px 12px;border-bottom:1px solid var(--line);flex-shrink:0;}
.pat-detail-body{flex:1;overflow-y:auto;padding:12px 16px;display:flex;flex-direction:column;gap:10px;}
.pat-detail-footer{flex-shrink:0;display:flex;gap:8px;padding:12px 16px;border-top:1px solid var(--line);background:rgba(248,250,252,0.95);}
@keyframes patSlideIn{from{opacity:0;transform:translateX(30px);}to{opacity:1;transform:translateX(0);}}
.pat-detail-head{display:flex;align-items:center;gap:8px;}
.pat-detail-head h3{margin:0;font-size:15px;flex:1;}
.pat-detail-field{padding-bottom:10px;border-bottom:1px solid var(--line);}
.pat-detail-field:last-child{border-bottom:none;padding-bottom:0;}
.pat-detail-label{font-size:11px;text-transform:uppercase;letter-spacing:0.07em;color:var(--muted);font-weight:600;display:block;margin-bottom:4px;}
.pat-detail-value{font-family:Consolas,"Cascadia Mono",monospace;white-space:pre-wrap;word-break:break-word;background:#f8fafc;border:1px solid var(--line);padding:8px 10px;border-radius:8px;font-size:12px;line-height:1.45;max-height:220px;overflow-y:auto;}
.pat-detail-ctx-chips{display:flex;flex-wrap:wrap;gap:6px;margin-top:4px;}
.pat-detail-chip{display:inline-block;padding:3px 8px;border-radius:6px;font-size:11px;font-weight:700;}
.pat-detail-chip-kb{background:#dbeafe;color:#1e40af;font-family:Consolas,monospace;}
.pat-detail-chip-danger{background:#fee2e2;color:#7f1d1d;}
.pat-detail-chip-warn{background:#fef3c7;color:#78350f;}
.pat-detail-chip-neutral{background:#e5e7eb;color:#374151;}
.pat-detail-ctx-box{background:rgba(23,32,51,0.04);border-radius:8px;padding:10px 12px;font-size:12px;line-height:1.5;}
.pat-detail-nearby{display:flex;flex-direction:column;gap:5px;margin-top:4px;}
.pat-detail-nearby-row{display:grid;grid-template-columns:64px 70px 1fr 1fr;gap:5px;align-items:center;font-size:11px;padding:4px 6px;background:rgba(23,32,51,0.03);border-radius:6px;}
.pat-detail-nearby-time{font-family:Consolas,monospace;color:var(--muted);}
.pat-detail-nearby-prov{font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}
.pat-detail-nearby-cat{color:var(--muted);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}
body.theme-dark .pat-detail-ctx-box{background:rgba(255,255,255,0.04);}
body.theme-dark .pat-detail-chip-kb{background:rgba(30,64,175,0.2);color:#93c5fd;}
body.theme-dark .pat-detail-chip-danger{background:rgba(220,38,38,0.2);color:#fca5a5;}
body.theme-dark .pat-detail-chip-warn{background:rgba(217,119,6,0.2);color:#fbbf24;}
body.theme-dark .pat-detail-nearby-row{background:rgba(255,255,255,0.03);}
.pat-detail-btn-row{display:flex;gap:8px;margin-top:8px;flex-wrap:wrap;}
.pat-detail-copy-btn{display:inline-flex;align-items:center;gap:4px;padding:6px 12px;background:rgba(15,118,110,0.1);border:1px solid rgba(15,118,110,0.25);border-radius:8px;cursor:pointer;font-size:12px;font-weight:600;color:var(--accent-strong);transition:background 120ms,transform 80ms;}
.pat-detail-copy-btn:hover{background:rgba(15,118,110,0.22);transform:translateY(-1px);}
.pat-detail-copy-btn:active{transform:translateY(0);}
.pat-detail-ai-btn{display:inline-flex;align-items:center;gap:4px;padding:6px 12px;background:rgba(99,60,180,0.1);border:1px solid rgba(99,60,180,0.28);border-radius:8px;cursor:pointer;font-size:12px;font-weight:600;color:#5b21b6;transition:background 120ms,transform 80ms;}
.pat-detail-ai-btn:hover{background:rgba(99,60,180,0.2);transform:translateY(-1px);}
.pat-detail-ai-btn:active{transform:translateY(0);}
.pat-detail-ai-btn.copied{background:rgba(99,60,180,0.25);color:#4c1d95;}
body.theme-dark .pat-detail-ai-btn{color:#c4b5fd;background:rgba(139,92,246,0.12);border-color:rgba(139,92,246,0.3);}
body.theme-dark .pat-detail-ai-btn:hover{background:rgba(139,92,246,0.22);}
.pat-ev-item:hover{background:rgba(15,118,110,0.07)!important;outline:2px solid rgba(15,118,110,0.25);border-radius:8px;}
.pat-ev-item.selected{background:rgba(15,118,110,0.13)!important;outline:2px solid var(--accent);border-radius:8px;}
.pat-table-wrap{margin-top:20px;}
.pat-table-wrap h4{margin:0 0 12px 0;font-size:14px;font-weight:700;}
.pat-evidence-table{width:100%;border-collapse:collapse;font-size:12px;}
.pat-evidence-table thead{background:rgba(23,32,51,0.06);}
.pat-evidence-table th{padding:10px;text-align:left;font-weight:700;cursor:pointer;user-select:none;border-bottom:2px solid var(--line);}
.pat-evidence-table th[data-sort-trigger]{position:relative;padding-right:22px;}
.pat-evidence-table th[data-sort-trigger]::after{content:' \2195';position:absolute;right:4px;opacity:0.4;font-size:10px;}
.pat-evidence-table th[data-sort-trigger].sort-asc::after{content:' \2191';opacity:1;}
.pat-evidence-table th[data-sort-trigger].sort-desc::after{content:' \2193';opacity:1;}
.pat-evidence-table td{padding:10px;border-bottom:1px solid var(--line);}
.pat-evidence-table tbody tr{cursor:pointer;}
.pat-evidence-table tbody tr:hover{background:rgba(15,118,110,0.05);}
.pat-evidence-table tbody tr.selected{background:rgba(15,118,110,0.12);}
body.theme-dark .pat-detail-panel{background:rgba(15,23,42,0.97);border-color:rgba(255,255,255,0.12);}
body.theme-dark .pat-detail-footer{background:rgba(15,23,42,0.95);border-color:rgba(255,255,255,0.08);}
body.theme-dark .pat-detail-value{background:rgba(255,255,255,0.05);border-color:rgba(255,255,255,0.1);}
body.theme-dark .pat-ev-item:hover{background:rgba(20,184,166,0.1)!important;}
body.theme-dark .pat-ev-item.selected{background:rgba(20,184,166,0.15)!important;}
body.theme-dark .pat-evidence-table thead{background:rgba(255,255,255,0.05);}
body.theme-dark .pat-evidence-table tbody tr:hover{background:rgba(20,184,166,0.06);}
@media(max-width:720px){
  .pat-ev-item{grid-template-columns:1fr;}
  .pat-ev-msg{max-height:10em;}
  .pat-action-row{grid-template-columns:1fr;}
  .sav-cmd-code{grid-row:2;grid-column:1;}
  .sav-cmd-desc{grid-row:3;}
  .pat-evidence-table{font-size:11px;}
  .pat-evidence-table th,.pat-evidence-table td{padding:6px 4px;}
}
body.theme-dark .client-text-box{background:rgba(20,184,166,0.08);border-color:rgba(20,184,166,0.2);}
body.theme-dark .pattern-card{background:rgba(15,23,42,0.85);}
body.theme-dark .pat-ev-item{background:rgba(255,255,255,0.04);}
body.theme-dark .sav-copy-btn{background:rgba(20,184,166,0.12);border-color:rgba(20,184,166,0.3);color:#14b8a6;}
body.theme-dark .sav-copy-btn:hover{background:rgba(20,184,166,0.22);}
body.theme-dark .sav-cmd-code{background:rgba(255,255,255,0.05);}
body.theme-dark .sav-act-family{background:rgba(15,23,42,0.85);}
body.theme-dark .pat-action-row{background:rgba(255,255,255,0.03);}
/* Frise chronologique critique — timeline visuelle avec cartes */
/* ===================== FRISE TOGGLE ===================== */
.frise-view-toggle{display:flex;flex-wrap:wrap;align-items:center;gap:8px;margin-bottom:14px;}
.frise-view-btn{padding:8px 16px;border-radius:10px;border:1px solid var(--line);background:var(--panel);cursor:pointer;font-size:13px;font-weight:600;color:var(--muted);transition:all 150ms;}
.frise-view-btn.active{background:var(--accent);border-color:var(--accent);color:#fff;}
.frise-view-btn:hover:not(.active){border-color:var(--accent);color:var(--accent);}
/* WU filter */
.frise-wu-filter{display:flex;align-items:center;gap:5px;flex-wrap:wrap;}
.frise-wu-btn{padding:4px 9px;border-radius:7px;border:1px solid var(--line);background:var(--panel-strong);cursor:pointer;font-size:11px;font-weight:600;color:var(--muted);transition:all 120ms;white-space:nowrap;}
.frise-wu-btn:hover{opacity:0.85;}
.frise-wu-btn.active{color:#fff;}
.frise-wu-btn-all.active{background:#475569;border-color:#475569;}
.frise-wu-btn-success.active{background:#059669;border-color:#059669;}
.frise-wu-btn-danger.active{background:#dc2626;border-color:#dc2626;}
.frise-wu-btn-warn.active{background:#d97706;border-color:#d97706;}
.frise-wu-btn-info.active{background:#0891b2;border-color:#0891b2;}
/* WU bar inside frise card */
.frise-wu-bar{display:flex;align-items:center;gap:6px;flex-wrap:wrap;margin-bottom:5px;margin-top:2px;}
.frise-wu-kb{display:inline-block;padding:2px 6px;border-radius:5px;font-family:Consolas,monospace;font-size:10px;font-weight:700;background:#dbeafe;color:#1e40af;}
.frise-wu-label{display:inline-block;padding:2px 6px;border-radius:5px;font-size:9px;font-weight:700;color:#fff;text-transform:uppercase;letter-spacing:0.04em;}
.frise-wu-status{font-size:11px;font-weight:700;}
.frise-wu-success{color:#065f46;}
.frise-wu-danger{color:#991b1b;}
.frise-wu-warn{color:#92400e;}
.frise-wu-info{color:#0e7490;}
body.theme-dark .frise-wu-kb{background:rgba(30,64,175,0.25);color:#93c5fd;}
body.theme-dark .frise-wu-success{color:#6ee7b7;}
body.theme-dark .frise-wu-danger{color:#fca5a5;}
body.theme-dark .frise-wu-warn{color:#fbbf24;}
/* Score filter */
.frise-score-filter{display:flex;align-items:center;gap:6px;margin-left:auto;padding:4px 10px;background:rgba(23,32,51,0.04);border:1px solid var(--line);border-radius:12px;flex-wrap:wrap;}
.frise-filter-label{font-size:11px;font-weight:600;color:var(--muted);white-space:nowrap;}
.frise-score-btns{display:flex;gap:3px;}
.frise-score-btn{padding:4px 9px;border-radius:7px;border:1px solid var(--line);background:var(--panel-strong);cursor:pointer;font-size:11px;font-weight:700;color:var(--muted);transition:all 120ms;white-space:nowrap;}
.frise-score-btn:hover{border-color:var(--accent);color:var(--accent);}
.frise-score-btn.active{background:var(--accent);border-color:var(--accent);color:#fff;}
.frise-score-btn[data-min="2"].active,.frise-score-btn[data-max="2"].active{background:#4b5563;border-color:#4b5563;}
.frise-score-btn[data-min="3"].active,.frise-score-btn[data-max="3"].active{background:#6b7280;border-color:#6b7280;}
.frise-score-btn[data-min="4"].active,.frise-score-btn[data-max="4"].active{background:#d97706;border-color:#d97706;}
.frise-score-btn[data-min="5"].active,.frise-score-btn[data-max="5"].active{background:#b42318;border-color:#b42318;}
.frise-filter-count{font-size:11px;color:var(--muted);padding-left:4px;border-left:1px solid var(--line);white-space:nowrap;}
body.theme-dark .frise-score-filter{background:rgba(255,255,255,0.04);}
body.theme-dark .frise-score-btn{background:rgba(255,255,255,0.05);}
body.theme-dark .frise-score-btn.active{color:#fff;}

/* ===================== FRISE HORIZONTALE ===================== */
.frise-h-wrap{margin-bottom:12px;}
.frise-h-toolbar{display:flex;align-items:center;gap:10px;margin-bottom:10px;font-size:12px;flex-wrap:wrap;}
.frise-h-info{color:var(--muted);flex:1;}
.frise-h-hint{color:var(--accent);font-style:italic;opacity:0.8;}
.frise-h-fullscreen-btn{padding:6px 12px;border-radius:9px;border:1px solid var(--line);background:var(--panel-strong);cursor:pointer;font-size:12px;font-weight:600;color:var(--text);transition:all 150ms;white-space:nowrap;}
.frise-h-fullscreen-btn:hover{border-color:var(--accent);color:var(--accent);background:rgba(15,118,110,0.07);}
/* Plein écran */
.frise-h-wrap.frise-fullscreen{position:fixed;inset:0;z-index:2000;background:var(--panel-strong,#fff);display:flex;flex-direction:column;justify-content:center;padding:14px 32px 20px;overflow:hidden;}
.frise-h-wrap.frise-fullscreen .frise-h-toolbar{flex-shrink:0;margin-bottom:16px;}
.frise-h-wrap.frise-fullscreen .frise-h-scroll{overflow-x:auto;overflow-y:visible;flex-shrink:0;}
.frise-h-wrap.frise-fullscreen .frise-h-stage{min-width:100%;}
.frise-h-wrap.frise-fullscreen .frise-h-track{height:220px;}
.frise-h-wrap.frise-fullscreen .frise-h-axis span{line-height:1.3;}
.frise-h-wrap.frise-fullscreen .frise-h-fullscreen-btn{background:rgba(220,38,38,0.08);border-color:rgba(220,38,38,0.3);color:#dc2626;}
.frise-h-wrap.frise-fullscreen .frise-h-fullscreen-btn:hover{background:rgba(220,38,38,0.16);}
body.frise-fullscreen-active{overflow:hidden;}
body.theme-dark .frise-h-wrap.frise-fullscreen{background:rgb(10,15,30);}
body.theme-dark .frise-h-wrap.frise-fullscreen{background:rgb(10,15,30);}
.frise-h-scroll{overflow-x:auto;overflow-y:visible;padding-bottom:8px;cursor:grab;}
.frise-h-scroll:active{cursor:grabbing;}
.frise-h-stage{min-width:900px;position:relative;padding:0 40px;}
.frise-h-axis{display:flex;justify-content:space-between;font-size:10px;color:var(--muted);font-family:Consolas,monospace;margin-bottom:6px;}
.frise-h-track{position:relative;height:140px;}
.frise-h-line-bar{position:absolute;top:50%;left:0;right:0;height:3px;background:linear-gradient(90deg,#b42318,#c2410c 25%,#1d4ed8 50%,#0f766e 80%,#374151);border-radius:2px;opacity:0.22;transform:translateY(-50%);}
.frise-h-dots{position:absolute;top:0;left:0;right:0;bottom:0;}
.frise-h-dot-wrap{position:absolute;transform:translateX(-50%);display:flex;flex-direction:column;align-items:center;cursor:pointer;}
.frise-h-dot-wrap:hover .frise-h-dot{transform:scale(1.35);box-shadow:0 4px 14px rgba(0,0,0,0.25);}
.frise-h-dot-wrap.selected .frise-h-dot{box-shadow:0 0 0 3px rgba(15,118,110,0.4);}
.frise-h-dot{border-radius:50%;border:2px solid white;box-shadow:0 2px 6px rgba(0,0,0,0.2);transition:transform 150ms,box-shadow 150ms;cursor:pointer;}
.frise-h-label-top{position:absolute;bottom:calc(50% + 14px);text-align:center;font-size:10px;font-weight:600;max-width:100px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;color:var(--text);background:var(--panel);border:1px solid var(--line);border-radius:5px;padding:2px 5px;pointer-events:none;}
.frise-h-label-bottom{position:absolute;top:calc(50% + 14px);text-align:center;font-size:10px;font-weight:600;max-width:100px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;color:var(--text);background:var(--panel);border:1px solid var(--line);border-radius:5px;padding:2px 5px;pointer-events:none;}
.frise-h-time{position:absolute;font-size:9px;color:var(--muted);font-family:Consolas,monospace;white-space:nowrap;pointer-events:none;}
.frise-h-time-top{bottom:calc(50% - 12px);}
.frise-h-time-bottom{top:calc(50% + 2px);}
.frise-h-connector{position:absolute;width:1px;background:var(--line);pointer-events:none;}
body.theme-dark .frise-h-label-top,body.theme-dark .frise-h-label-bottom{background:rgba(15,23,42,0.9);border-color:rgba(255,255,255,0.12);}
body.theme-dark .frise-h-dot{border-color:rgba(15,23,42,0.8);}

/* ===================== FRISE CHRONOLOGIQUE ===================== */
.frise-legend{display:flex;flex-wrap:wrap;gap:10px;margin-bottom:16px;padding:12px 14px;background:rgba(23,32,51,0.04);border-radius:10px;font-size:12px;align-items:center;}
.frise-legend-title{font-weight:700;margin-right:4px;color:var(--muted);}
.frise-legend-item{display:inline-flex;align-items:center;gap:5px;padding:3px 8px;border-radius:6px;font-size:11px;font-weight:600;}
.frise-legend-danger{background:#fee2e2;color:#7f1d1d;}
.frise-legend-warn{background:#fef3c7;color:#78350f;}
.frise-legend-neutral{background:#e5e7eb;color:#374151;}
.frise-legend-click{font-size:11px;color:var(--muted);margin-left:auto;font-style:italic;}
.frise-timeline{position:relative;padding:4px 0 4px 0;}
.frise-timeline::before{content:'';position:absolute;left:14px;top:0;bottom:0;width:3px;background:linear-gradient(180deg,#b42318 0%,#c2410c 20%,#1d4ed8 50%,#0f766e 80%,#374151 100%);border-radius:2px;opacity:0.25;}
.frise-card{display:flex;gap:0;margin-bottom:12px;position:relative;margin-left:44px;border:1px solid var(--line);border-radius:12px;background:var(--panel);border-left:4px solid #64748b;cursor:pointer;transition:box-shadow 180ms,transform 120ms,border-left-width 120ms;outline:none;}
.frise-card[hidden]{display:none!important;}
.frise-card:hover{box-shadow:0 6px 20px rgba(0,0,0,0.13);transform:translateX(2px);border-left-width:6px;}
.frise-card:focus-visible{box-shadow:0 0 0 3px rgba(15,118,110,0.35);}
.frise-card.selected{box-shadow:0 6px 22px rgba(0,0,0,0.16);border-left-width:6px;outline:2px solid rgba(15,118,110,0.4);}
.frise-card-danger.selected{outline-color:rgba(180,35,24,0.4);}
.frise-card-warn.selected{outline-color:rgba(180,83,9,0.4);}
.frise-dot{display:flex;align-items:center;justify-content:center;width:30px;height:30px;min-width:30px;border-radius:50%;background:white;border:3px solid currentColor;font-size:14px;position:absolute;left:-52px;top:50%;transform:translateY(-50%);z-index:10;box-shadow:0 2px 6px rgba(0,0,0,0.15);}
.frise-body{flex:1;min-width:0;padding:11px 14px;}
.frise-header{display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-bottom:6px;}
.frise-ts{font-family:Consolas,"Cascadia Mono",monospace;font-size:12px;font-weight:700;color:var(--text);background:rgba(23,32,51,0.06);padding:2px 7px;border-radius:5px;}
.frise-badge{display:inline-block;padding:3px 9px;border-radius:6px;font-size:11px;font-weight:700;letter-spacing:0.03em;}
.frise-badge-danger{background:#fee2e2;color:#7f1d1d;}
.frise-badge-warn{background:#fef3c7;color:#78350f;}
.frise-badge-neutral{background:#e5e7eb;color:#374151;}
.frise-level{font-size:11px;font-weight:600;}
.frise-evtid{font-size:11px;color:var(--muted);font-family:Consolas,"Cascadia Mono",monospace;margin-left:auto;}
.frise-family{font-size:12px;font-weight:700;margin-bottom:3px;}
.frise-provider{font-size:11px;color:var(--muted);margin-bottom:5px;}
.frise-msg{font-size:12px;color:var(--text);line-height:1.45;word-break:break-word;overflow:hidden;display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical;}
.frise-click-hint{font-size:11px;color:var(--accent);margin-top:7px;opacity:0.7;transition:opacity 150ms;}
.frise-card:hover .frise-click-hint{opacity:1;font-weight:600;}
body.theme-dark .frise-legend{background:rgba(255,255,255,0.04);}
body.theme-dark .frise-legend-danger{background:rgba(220,38,38,0.2);color:#fca5a5;}
body.theme-dark .frise-legend-warn{background:rgba(217,119,6,0.2);color:#fbbf24;}
body.theme-dark .frise-legend-neutral{background:rgba(107,114,128,0.2);color:#d1d5db;}
body.theme-dark .frise-card{background:rgba(15,23,42,0.75);border-color:rgba(255,255,255,0.08);}
body.theme-dark .frise-dot{background:rgba(15,23,42,0.95);}
body.theme-dark .frise-ts{background:rgba(255,255,255,0.06);}
body.theme-dark .frise-badge-danger{background:rgba(220,38,38,0.22);color:#fca5a5;}
body.theme-dark .frise-badge-warn{background:rgba(217,119,6,0.22);color:#fbbf24;}
body.theme-dark .frise-badge-neutral{background:rgba(107,114,128,0.18);color:#d1d5db;}
@media(max-width:720px){
  .frise-card{margin-left:28px;border-left-width:3px;}
  .frise-dot{width:22px;height:22px;font-size:12px;left:-36px;border-width:2px;}
  .frise-timeline::before{left:8px;width:2px;}
  .frise-ts{font-size:11px;}
  .frise-msg{font-size:11px;-webkit-line-clamp:2;}
}
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

// ==================== FRISE FILTRE SCORE ====================
var _friseMinScore=4, _friseMaxScore=5, _friseWuFilter='all';
function applyFriseScoreFilter(){
    var cards=document.querySelectorAll('.frise-card');
    var visible=0;
    cards.forEach(function(c){
        var s=parseInt(c.getAttribute('data-crit')||'0',10);
        var wuStatus=c.getAttribute('data-wu-status')||'';
        var isWuCard=!!wuStatus;
        var scoreOk=(s>=_friseMinScore&&s<=_friseMaxScore);
        var wuOk=true;
        if(_friseWuFilter==='wu') wuOk=isWuCard;
        else if(_friseWuFilter!=='all') wuOk=(wuStatus===_friseWuFilter);
        var show=scoreOk&&wuOk;
        c.hidden=!show;
        if(show) visible++;
    });
    var dots=document.querySelectorAll('.frise-h-dot-wrap');
    var visibleDots=0;
    dots.forEach(function(d){
        var s=parseInt(d.getAttribute('data-crit')||'0',10);
        var wuStatus=d.getAttribute('data-wu-status')||'';
        var isWuDot=!!wuStatus;
        var scoreOk=(s>=_friseMinScore&&s<=_friseMaxScore);
        var wuOk=true;
        if(_friseWuFilter==='wu') wuOk=isWuDot;
        else if(_friseWuFilter!=='all') wuOk=(wuStatus===_friseWuFilter);
        var show=scoreOk&&wuOk;
        d.style.display=show?'':'none';
        if(show) visibleDots++;
    });
    var countEl=document.getElementById('friseFilterCount');
    if(countEl) countEl.textContent=visible+' / '+cards.length+' événements';
}
function setFriseWuFilter(filter){
    _friseWuFilter=filter;
    document.querySelectorAll('.frise-wu-btn').forEach(function(b){b.classList.remove('active');});
    var map={'all':'frise-wu-btn-all','wu':'frise-wu-btn-success','Installé':'frise-wu-btn-success','Échec':'frise-wu-btn-danger','En attente':'frise-wu-btn-warn','Autre':'frise-wu-btn-info'};
    var cls=map[filter]||'frise-wu-btn-all';
    document.querySelectorAll('.'+cls+'[onclick*="'+filter.replace(/é/g,'\\u00e9')+'"]').forEach(function(b){b.classList.add('active');});
    // Fallback: match by onclick attr
    document.querySelectorAll('.frise-wu-btn').forEach(function(b){
        var oa=b.getAttribute('onclick')||'';
        if(oa.indexOf("'"+filter+"'")>=0||oa.indexOf('"'+filter+'"')>=0) b.classList.add('active');
    });
    applyFriseScoreFilter();
}
window.setFriseWuFilter=setFriseWuFilter;
function setFriseScoreMin(v){
    _friseMinScore=v;
    if(_friseMaxScore<v) { _friseMaxScore=v; updateScoreBtnActive('max',v); }
    updateScoreBtnActive('min',v);
    applyFriseScoreFilter();
}
function setFriseScoreMax(v){
    _friseMaxScore=v;
    if(_friseMinScore>v) { _friseMinScore=v; updateScoreBtnActive('min',v); }
    updateScoreBtnActive('max',v);
    applyFriseScoreFilter();
}
function updateScoreBtnActive(type,v){
    var attr=type==='min'?'data-min':'data-max';
    var id=type==='min'?'friseMinBtns':'friseMaxBtns';
    var container=document.getElementById(id);
    if(!container) return;
    container.querySelectorAll('.frise-score-btn').forEach(function(b){
        b.classList.toggle('active',parseInt(b.getAttribute(attr)||'0',10)===v);
    });
}
window.setFriseScoreMin=setFriseScoreMin;
window.setFriseScoreMax=setFriseScoreMax;

// ==================== FRISE PLEIN ÉCRAN ====================
var _friseFullscreen=false;
function _applyPanelFullscreenStyle(active){
    var panel=document.getElementById('patDetailPanel');
    if(!panel) return;
    if(active){
        panel.style.zIndex='2100';
        panel.style.top='60px';
        panel.style.right='20px';
        panel.style.maxHeight='calc(100vh - 80px)';
    } else {
        panel.style.zIndex='';
        panel.style.top='';
        panel.style.right='';
        panel.style.maxHeight='';
    }
}
function toggleFriseFullscreen(){
    var wrap=document.getElementById('friseHWrap');
    var btn=document.getElementById('friseHFullscreenBtn');
    if(!wrap) return;
    _friseFullscreen=!_friseFullscreen;
    if(_friseFullscreen){
        wrap.classList.add('frise-fullscreen');
        document.body.classList.add('frise-fullscreen-active');
        if(btn){ btn.innerHTML='&#x2715; Fermer plein écran'; btn.title='Quitter le plein écran (Échap)'; }
        _applyPanelFullscreenStyle(true);
        setTimeout(function(){ _friseHBuilt=false; buildFriseH(); },50);
    } else {
        wrap.classList.remove('frise-fullscreen');
        document.body.classList.remove('frise-fullscreen-active');
        if(btn){ btn.innerHTML='&#x26F6; Plein écran'; btn.title='Plein écran'; }
        _applyPanelFullscreenStyle(false);
        setTimeout(function(){ _friseHBuilt=false; buildFriseH(); },50);
    }
}
window.toggleFriseFullscreen=toggleFriseFullscreen;
// Échap pour quitter le plein écran
document.addEventListener('keydown',function(e){
    if(e.key==='Escape'&&_friseFullscreen) toggleFriseFullscreen();
});

// ==================== FRISE HORIZONTALE ====================
function switchFriseView(mode){
    var listEl=document.getElementById('friseVList');
    var hEl=document.getElementById('friseHWrap');
    var btnL=document.getElementById('btnFriseList');
    var btnH=document.getElementById('btnFriseH');
    if(mode==='horizontal'){
        if(listEl) listEl.hidden=true;
        if(hEl){ hEl.hidden=false; buildFriseH(); }
        if(btnL) btnL.classList.remove('active');
        if(btnH) btnH.classList.add('active');
    } else {
        if(listEl) listEl.hidden=false;
        if(hEl) hEl.hidden=true;
        if(btnL) btnL.classList.add('active');
        if(btnH) btnH.classList.remove('active');
    }
}
window.switchFriseView=switchFriseView;

var _friseHBuilt=false;
function buildFriseH(){
    if(_friseHBuilt) return;
    _friseHBuilt=true;
    var dataEl=document.getElementById('friseHData');
    if(!dataEl) return;
    var events;
    try{ events=JSON.parse(dataEl.textContent); }catch(e){ return; }
    if(!events||!events.length) return;
    // Stocké globalement pour enrichissement panneau
    window._friseEvents=events;

    // Parse timestamps — format MM/DD/YYYY HH:MM:SS
    function parseTs(s){
        if(!s) return null;
        var m=s.match(/(\d+)\/(\d+)\/(\d+)\s+(\d+):(\d+):(\d+)/);
        if(!m) return null;
        return new Date(+m[3],+m[1]-1,+m[2],+m[4],+m[5],+m[6]);
    }
    function fmtTime(d){ return ('0'+d.getHours()).slice(-2)+':'+('0'+d.getMinutes()).slice(-2); }
    function fmtDate(d){ return ('0'+d.getDate()).slice(-2)+'/'+('0'+(d.getMonth()+1)).slice(-2)+'/'+d.getFullYear(); }

    var parsed=events.map(function(e,i){ return {d:parseTs(e.ts),ev:e,i:i}; }).filter(function(x){return x.d;});
    if(!parsed.length) return;
    parsed.sort(function(a,b){return a.d-b.d;});

    var tMin=parsed[0].d.getTime();
    var tMax=parsed[parsed.length-1].d.getTime();
    var tRange=tMax-tMin||1;

    // Stage width: at least 900px, max 3000px, ~80px per event min spacing
    var stageW=Math.max(900,Math.min(4000,parsed.length*90));
    var stage=document.getElementById('friseHStage');
    if(stage) stage.style.minWidth=stageW+'px';

    // Build axis labels (time ticks)
    var axisEl=document.getElementById('friseHAxis');
    if(axisEl){
        var tickCount=Math.min(10,parsed.length);
        var ticksHtml='';
        for(var ti=0;ti<=tickCount;ti++){
            var tTick=new Date(tMin+(tRange/tickCount)*ti);
            ticksHtml+='<span>'+fmtDate(tTick)+'<br>'+fmtTime(tTick)+'</span>';
        }
        axisEl.innerHTML=ticksHtml;
    }

    // Build dots — read actual track height from DOM
    var dotsEl=document.getElementById('friseHDots');
    if(!dotsEl) return;
    var html='';
    var trackEl=document.querySelector('.frise-h-track');
    var trackH=trackEl?trackEl.offsetHeight:140;
    if(trackH<80) trackH=140; // fallback si pas encore rendu
    var midY=Math.round(trackH/2);
    // Minimum horizontal spacing to avoid overlap (as % of stage width)
    var minGapPct=1.5;
    var positions=[];
    parsed.forEach(function(item,idx){
        var rawPct=((item.d.getTime()-tMin)/tRange)*100;
        // Clamp with padding
        var pct=Math.max(1,Math.min(99,rawPct));
        // Enforce minimum gap
        if(idx>0){
            var prev=positions[idx-1];
            if(pct-prev<minGapPct) pct=prev+minGapPct;
        }
        positions.push(pct);
        item.pct=pct;
    });

    // Compact layout constants (relative to midY)
    var GAP=6; // px between dot edge and connector/label
    parsed.forEach(function(item,idx){
        var ev=item.ev;
        var pct=item.pct;
        var isTop=(idx%2===0); // alternate above/below
        var sz=ev.crit>=5?18:ev.crit>=4?13:10; // dot diameter
        var halfSz=Math.round(sz/2);
        var labelCat=(ev.cat||'').length>18?(ev.cat||'').substring(0,17)+'…':ev.cat||'';
        var timeStr=fmtTime(item.d);
        var critText=ev.crit>=5?'CRITIQUE':ev.crit>=4?'ÉLEVÉ':'MOYEN';

        var safeProv=(ev.prov||'').replace(/"/g,'&quot;');
        var safeMsg=(ev.msg||'').replace(/"/g,'&quot;');
        var safeTs=(ev.ts||'').replace(/"/g,'&quot;');
        var safeEid=(ev.eid||'').replace(/"/g,'&quot;');
        var safeCat=(ev.cat||'').replace(/"/g,'&quot;');
        var safeLvl=(ev.level||'').replace(/"/g,'&quot;');
        var safeChan=(ev.chan||'').replace(/"/g,'&quot;');

        // Absolute Y positions (all relative to track top)
        var dotTop=midY-halfSz;
        var dotBottom=midY+halfSz;

        // Label and time placement
        var labelH=20, timeH=16;
        var connLen=GAP+4;
        var labelTop, timeTop, connTop, connHeight;
        if(isTop){
            // above: time → label → connector → dot
            labelTop=dotTop-GAP-connLen-labelH;
            timeTop=labelTop-timeH-2;
            connTop=dotTop-GAP-connLen;
            connHeight=connLen;
        } else {
            // below: dot → connector → label → time
            connTop=dotBottom+GAP;
            connHeight=connLen;
            labelTop=connTop+connHeight;
            timeTop=labelTop+labelH+2;
        }

        // Couleur du dot : WU status > criticité famille
        var dotColor = ev.color;
        var dotBorder = 'white';
        var isWuDot = !!(ev.isWu || ev.wuStatus);
        if(isWuDot && ev.wuDotColor){ dotColor=ev.wuDotColor; }
        // Label affiché au-dessus/dessous : WU prioritaire sur famille
        var dispLabel = isWuDot ? ((ev.wuKb?ev.wuKb+' ':'')+ev.wuLabel) : labelCat;
        var dispLabelBg = isWuDot ? (ev.wuLabelColor||'#1d4ed8') : 'var(--panel)';
        var dispLabelColor = isWuDot ? '#fff' : 'var(--text)';
        var dispLabelBorder = isWuDot ? 'none' : '1px solid var(--line)';
        // Badge statut WU sur le dot
        var wuStatusMark = isWuDot ? (ev.wuTone==='success'?'✅':ev.wuTone==='danger'?'❌':ev.wuTone==='warn'?'🔄':'ℹ️') : '';

        html+='<div class="frise-h-dot-wrap" style="position:absolute;left:'+pct+'%;top:0;height:100%;" '+
              'data-ts="'+safeTs+'" data-prov="'+safeProv+'" data-msg="'+safeMsg+'" '+
              'data-evid="'+safeEid+'" data-cat="'+safeCat+'" data-level="'+safeLvl+'" '+
              'data-crit="'+ev.crit+'" data-chan="'+safeChan+'" '+
              'data-wu-status="'+(ev.wuStatus||'')+'" data-wu-kb="'+(ev.wuKb||'')+'" '+
              'onclick="showFriseDetail(this)" title="'+safeTs+' — '+safeProv+(isWuDot?' [WU:'+ev.wuStatus+']':'')+' ['+critText+']">'+
              // Dot principal
              '<div class="frise-h-dot" style="width:'+sz+'px;height:'+sz+'px;background:'+dotColor+';border-color:'+dotBorder+';position:absolute;top:'+dotTop+'px;left:50%;transform:translateX(-50%);'+(isWuDot?'box-shadow:0 0 0 2px rgba(0,0,0,0.15),0 0 8px 2px '+dotColor+'44;':'')+'">'+(isWuDot&&sz>=14?'<span style="font-size:'+(sz<=14?'8':'10')+'px;line-height:1;display:block;text-align:center;margin-top:'+(sz<=14?'1':'2')+'px;">WU</span>':'')+
              '</div>'+
              // Connector
              '<div style="position:absolute;left:50%;top:'+connTop+'px;width:1px;height:'+connHeight+'px;background:rgba(100,116,139,0.4);transform:translateX(-50%);pointer-events:none;"></div>'+
              // Label (KB+type pour WU, famille sinon)
              '<div style="position:absolute;left:50%;top:'+labelTop+'px;transform:translateX(-50%);font-size:10px;font-weight:700;white-space:nowrap;color:'+dispLabelColor+';background:'+dispLabelBg+';border:'+dispLabelBorder+';border-radius:4px;padding:1px 5px;pointer-events:none;max-width:130px;overflow:hidden;text-overflow:ellipsis;">'+dispLabel+'</div>'+
              // Statut WU icon ou heure
              '<div style="position:absolute;left:50%;top:'+timeTop+'px;transform:translateX(-50%);font-size:'+(isWuDot?'12':'9')+'px;color:var(--muted);white-space:nowrap;pointer-events:none;">'+(isWuDot&&wuStatusMark ? wuStatusMark : timeStr)+'</div>'+
              '</div>';
    });
    dotsEl.innerHTML=html;

    // Info bar
    var infoEl=document.getElementById('friseHInfo');
    if(infoEl){
        var d0=parsed[0].d,d1=parsed[parsed.length-1].d;
        infoEl.textContent=parsed.length+' événements · '+fmtDate(d0)+' '+fmtTime(d0)+' → '+fmtDate(d1)+' '+fmtTime(d1);
    }

    // Drag-to-scroll on the frise
    var scroll=document.getElementById('friseHScroll');
    if(scroll){
        var isDragging=false,startX=0,scrollLeft=0;
        scroll.addEventListener('mousedown',function(e){isDragging=true;startX=e.pageX-scroll.offsetLeft;scrollLeft=scroll.scrollLeft;});
        scroll.addEventListener('mouseleave',function(){isDragging=false;});
        scroll.addEventListener('mouseup',function(){isDragging=false;});
        scroll.addEventListener('mousemove',function(e){if(!isDragging) return;e.preventDefault();var x=e.pageX-scroll.offsetLeft;scroll.scrollLeft=scrollLeft-(x-startX);});
    }
}

// ==================== FRISE CARD CLICK ====================
// Frise card click → même panneau fixe
function showFriseDetail(elem){
    _initPatPanel();
    if(!_patPanel||!_patBody) return;
    var ts=elem.getAttribute('data-ts')||'';
    var prov=elem.getAttribute('data-prov')||'';
    var msg=elem.getAttribute('data-msg')||'';
    var eid=elem.getAttribute('data-evid')||'';
    var cat=elem.getAttribute('data-cat')||'';
    var level=elem.getAttribute('data-level')||'';
    var crit=elem.getAttribute('data-crit')||'';
    var chan=elem.getAttribute('data-chan')||'';
    _patLastMsg=msg;
    var critText=crit==='5'?'CRITIQUE':crit==='4'?'ÉLEVÉ':crit==='3'?'MOYEN':'Score '+crit;
    var critClass=crit==='5'?'frise-badge-danger':crit==='4'?'frise-badge-warn':'frise-badge-neutral';
    var head=_patPanel.querySelector('h3');
    if(head) head.innerHTML='<span class="frise-badge '+critClass+'" style="font-size:12px;margin-right:8px;">'+escHtml(critText)+'</span>'+escHtml(prov||'Événement critique');
    var html='';
    if(ts) html+='<div class="pat-detail-field"><span class="pat-detail-label">Horodatage</span><div class="pat-detail-value">'+escHtml(ts)+'</div></div>';
    if(eid) html+='<div class="pat-detail-field"><span class="pat-detail-label">ID Événement</span><div class="pat-detail-value">'+escHtml(eid)+'</div></div>';
    if(cat) html+='<div class="pat-detail-field"><span class="pat-detail-label">Famille / Catégorie</span><div class="pat-detail-value">'+escHtml(cat)+'</div></div>';
    if(level) html+='<div class="pat-detail-field"><span class="pat-detail-label">Niveau</span><div class="pat-detail-value">'+escHtml(level)+'</div></div>';
    if(prov) html+='<div class="pat-detail-field"><span class="pat-detail-label">Fournisseur / Source</span><div class="pat-detail-value">'+escHtml(prov)+'</div></div>';
    if(chan) html+='<div class="pat-detail-field"><span class="pat-detail-label">Canal</span><div class="pat-detail-value">'+escHtml(chan)+'</div></div>';
    html+='<div class="pat-detail-field"><span class="pat-detail-label">Message complet</span><div class="pat-detail-value" style="max-height:200px;overflow-y:auto;">'+escHtml(msg)+'</div></div>';

    // --- Enrichissement contextuel ---
    // 1. KB mentionnés dans le message
    var kbMatches=msg.match(/KB\d{6,}/g)||[];
    var kbUniq=[]; kbMatches.forEach(function(k){if(kbUniq.indexOf(k)<0)kbUniq.push(k);});
    if(kbUniq.length>0){
        html+='<div class="pat-detail-field"><span class="pat-detail-label">&#128273; Mises à jour KB mentionnées</span><div class="pat-detail-ctx-chips">'+kbUniq.map(function(k){return '<span class="pat-detail-chip pat-detail-chip-kb">'+escHtml(k)+'</span>';}).join('')+'</div></div>';
    }

    // 2. Événements proches (±5 min dans la frise)
    if(window._friseEvents&&ts){
        function parseDetailTs(s){var m=s.match(/(\d+)\/(\d+)\/(\d+)\s+(\d+):(\d+)/);if(!m)return null;return new Date(+m[3],+m[1]-1,+m[2],+m[4],+m[5]).getTime();}
        var tRef=parseDetailTs(ts);
        if(tRef){
            var WIN=5*60*1000; // ±5 min
            var nearby=window._friseEvents.filter(function(e){
                var t2=parseDetailTs(e.ts||'');
                return t2&&Math.abs(t2-tRef)<=WIN&&(e.prov!==prov||e.ts!==ts);
            });
            if(nearby.length>0){
                var nearHtml=nearby.slice(0,5).map(function(e){
                    var critLabel=e.crit>=5?'CRITIQUE':e.crit>=4?'ÉLEVÉ':'MOYEN';
                    var critCls=e.crit>=5?'danger':e.crit>=4?'warn':'neutral';
                    var timeShort=(e.ts||'').replace(/\d{4} /,'').replace(':00$','');
                    return '<div class="pat-detail-nearby-row">'+
                        '<span class="pat-detail-chip pat-detail-chip-'+critCls+'">'+critLabel+'</span>'+
                        '<span class="pat-detail-nearby-time">'+escHtml(timeShort)+'</span>'+
                        '<span class="pat-detail-nearby-prov">'+escHtml((e.prov||'').length>28?(e.prov||'').substring(0,27)+'…':e.prov||'')+'</span>'+
                        '<span class="pat-detail-nearby-cat">'+escHtml((e.cat||'').length>22?(e.cat||'').substring(0,21)+'…':e.cat||'')+'</span>'+
                        '</div>';
                }).join('');
                html+='<div class="pat-detail-field"><span class="pat-detail-label">&#8987; Événements contemporains (±5 min)</span><div class="pat-detail-nearby">'+nearHtml+'</div></div>';
            }
        }
    }

    // 3. Cause racine système
    var metaEl=document.getElementById('friseHMeta');
    if(metaEl){
        try{
            var meta=JSON.parse(metaEl.textContent||'{}');
            if(meta.primaryCause){
                var matches=(cat&&meta.primaryCause.toLowerCase().indexOf(cat.toLowerCase().split('/')[0].trim())>=0)||false;
                html+='<div class="pat-detail-field"><span class="pat-detail-label">&#128269; Diagnostic système global</span>'+
                    '<div class="pat-detail-ctx-box">'+
                    '<div><strong>Cause principale :</strong> '+escHtml(meta.primaryCause)+'</div>'+
                    '<div style="margin-top:4px;font-size:11px;color:var(--muted);">'+escHtml(meta.primaryCauseFr||'')+'</div>'+
                    (matches?'<div class="pat-detail-chip pat-detail-chip-warn" style="margin-top:6px;">&#9888; Cette famille est liée à la cause principale</div>':'')+
                    '</div>'+
                    '</div>';
            }
        }catch(e){}
    }

    // Collect nearby text for fullText (built before innerHTML)
    var nearbyLines=[];
    if(window._friseEvents&&ts){
        function parseDTs(s){var m=s.match(/(\d+)\/(\d+)\/(\d+)\s+(\d+):(\d+)/);if(!m)return null;return new Date(+m[3],+m[1]-1,+m[2],+m[4],+m[5]).getTime();}
        var tRef2=parseDTs(ts);
        if(tRef2){
            var WIN2=5*60*1000;
            window._friseEvents.filter(function(e){var t2=parseDTs(e.ts||'');return t2&&Math.abs(t2-tRef2)<=WIN2&&(e.prov!==prov||e.ts!==ts);})
            .slice(0,5).forEach(function(e){
                var cl=e.crit>=5?'CRITIQUE':e.crit>=4?'ÉLEVÉ':'MOYEN';
                var timeShort=(e.ts||'').replace(/\d{4} /,'').replace(':00$','');
                nearbyLines.push(cl+' '+timeShort+' · '+(e.prov||'')+' · '+(e.cat||''));
            });
        }
    }
    var metaObj=null;
    try{ var metaEl2=document.getElementById('friseHMeta'); if(metaEl2) metaObj=JSON.parse(metaEl2.textContent||'{}'); }catch(e){}
    var fullText=buildFullEventText({ts:ts,eid:eid,cat:cat,level:level,prov:prov,chan:chan,crit:critText,msg:msg,nearby:nearbyLines,meta:metaObj});

    _patBody.innerHTML=html;
    wireDetailFooter(fullText);
    document.querySelectorAll('.frise-card.selected,.pat-ev-item.selected,.pat-evidence-table tbody tr.selected').forEach(function(e){e.classList.remove('selected');});
    elem.classList.add('selected');
    if(_patPanel.hidden){
        _patPanel.hidden=false;
        _patPanel.style.animation='none';
        void _patPanel.offsetWidth;
        _patPanel.style.animation='';
    }
}
window.showFriseDetail=showFriseDetail;

// ==================== TEXTE COMPLET PANNEAU ====================
function buildFullEventText(fields){
    // fields: {ts,eid,cat,level,prov,chan,crit,msg,nearby,meta}
    var lines=[];
    lines.push('=== ÉVÉNEMENT WINDOWS ===');
    if(fields.ts)    lines.push('Date/Heure    : '+fields.ts);
    if(fields.eid)   lines.push('ID Événement  : '+fields.eid);
    if(fields.cat)   lines.push('Famille       : '+fields.cat);
    if(fields.level) lines.push('Niveau        : '+fields.level);
    if(fields.prov)  lines.push('Fournisseur   : '+fields.prov);
    if(fields.chan)  lines.push('Canal         : '+fields.chan);
    if(fields.crit)  lines.push('Criticité     : '+fields.crit);
    lines.push('');
    lines.push('Message complet :');
    lines.push(fields.msg||'(aucun message)');
    if(fields.nearby&&fields.nearby.length){
        lines.push('');
        lines.push('=== ÉVÉNEMENTS CONTEMPORAINS (±5 min) ===');
        fields.nearby.forEach(function(n){ lines.push('• '+n); });
    }
    if(fields.meta&&fields.meta.primaryCause){
        lines.push('');
        lines.push('=== DIAGNOSTIC SYSTÈME ===');
        lines.push('Cause principale  : '+fields.meta.primaryCause);
        if(fields.meta.confidence) lines.push('Confiance         : '+fields.meta.confidence);
        if(fields.meta.severity)   lines.push('Sévérité globale  : '+fields.meta.severity);
        if(fields.meta.primaryCauseFr) lines.push('Message client    : '+fields.meta.primaryCauseFr);
    }
    lines.push('');
    lines.push('=========================');
    return lines.join('\n');
}
function buildAiPrompt(fullText){
    return 'Tu es un expert en diagnostic Windows. Analyse cet événement Windows et donne une réponse structurée en français :\n\n'+
           '1. Ce que signifie cet événement\n'+
           '2. La cause probable (en lien avec le contexte système si fourni)\n'+
           '3. L\'impact potentiel sur le système\n'+
           '4. Les actions correctives recommandées (commandes WinPE si applicable)\n'+
           '5. KB ou correctifs Microsoft associés si connus\n\n'+
           fullText;
}
function wireDetailFooter(fullText){
    var cpBtn=document.getElementById('patCopyBtnGlobal');
    var aiBtn=document.getElementById('patAiBtnGlobal');
    // Clone pour supprimer les anciens listeners
    if(cpBtn){ var cp2=cpBtn.cloneNode(true); cpBtn.parentNode.replaceChild(cp2,cpBtn); cp2.addEventListener('click',function(){copyPatMsg(fullText,cp2);}); }
    if(aiBtn){ var ai2=aiBtn.cloneNode(true); aiBtn.parentNode.replaceChild(ai2,aiBtn); ai2.addEventListener('click',function(){copyPatMsg(buildAiPrompt(fullText),ai2);}); }
}
window.buildFullEventText=buildFullEventText;
window.wireDetailFooter=wireDetailFooter;

// Pattern detail panel — position:fixed overlay identical to evtx-detail-panel
var _patPanel=null,_patBody=null,_patLastMsg='';
function _initPatPanel(){
    if(_patPanel) return;
    _patPanel=document.getElementById('patDetailPanel');
    _patBody=document.getElementById('patDetailBody');
    var closeBtn=document.getElementById('patDetailClose');
    if(closeBtn) closeBtn.addEventListener('click',function(){ if(_patPanel){_patPanel.hidden=true;} document.querySelectorAll('.pat-ev-item.selected,.pat-evidence-table tbody tr.selected').forEach(function(e){e.classList.remove('selected');});});
}
function showPatternDetail(elem){
    _initPatPanel();
    if(!_patPanel||!_patBody) return;
    var ts=elem.getAttribute('data-ts')||'';
    var prov=elem.getAttribute('data-prov')||'';
    var msg=elem.getAttribute('data-msg')||'';
    var eid=elem.getAttribute('data-evid')||'';
    _patLastMsg=msg;
    var head=_patPanel.querySelector('h3');
    if(head) head.textContent=prov||'Détail événement';
    var html='';
    if(ts) html+='<div class="pat-detail-field"><span class="pat-detail-label">Horodatage</span><div class="pat-detail-value">'+escHtml(ts)+'</div></div>';
    if(eid) html+='<div class="pat-detail-field"><span class="pat-detail-label">ID Événement</span><div class="pat-detail-value">'+escHtml(eid)+'</div></div>';
    if(prov) html+='<div class="pat-detail-field"><span class="pat-detail-label">Fournisseur / Source</span><div class="pat-detail-value">'+escHtml(prov)+'</div></div>';
    html+='<div class="pat-detail-field"><span class="pat-detail-label">Message complet</span><div class="pat-detail-value" style="max-height:320px;overflow-y:auto;">'+escHtml(msg)+'</div></div>';
    var fullTextPat=buildFullEventText({ts:ts,eid:eid,prov:prov,msg:msg,nearby:[],meta:null});
    _patBody.innerHTML=html;
    wireDetailFooter(fullTextPat);
    document.querySelectorAll('.pat-ev-item.selected,.pat-evidence-table tbody tr.selected').forEach(function(e){e.classList.remove('selected');});
    elem.classList.add('selected');
    if(_patPanel.hidden){
        _patPanel.hidden=false;
        // Force re-trigger animation
        _patPanel.style.animation='none';
        void _patPanel.offsetWidth;
        _patPanel.style.animation='';
    }
}
function copyPatMsg(text,btn){
    var orig=btn?btn.textContent:'';
    function mark(){if(btn){btn.textContent='✅ Copie!';setTimeout(function(){btn.textContent=orig;},2200);}}
    if(navigator.clipboard&&navigator.clipboard.writeText){
        navigator.clipboard.writeText(text).then(mark,function(){legacyCopyPat(text,mark);});
    } else { legacyCopyPat(text,mark); }
}
function legacyCopyPat(text,cb){
    var ta=document.createElement('textarea');ta.value=text;ta.style.position='fixed';ta.style.opacity='0';
    document.body.appendChild(ta);ta.focus();ta.select();
    try{document.execCommand('copy');}catch(e){}
    document.body.removeChild(ta);if(cb)cb();
}
function escHtml(text){
    return String(text).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}
window.showPatternDetail=showPatternDetail;

// Table sorting for pattern evidence table
function initPatternTableSort(){
    var table=document.getElementById('patEvidenceTable');
    if(!table) return;
    var headers=table.querySelectorAll('th[data-sort-trigger]');
    headers.forEach(function(th){
        th.addEventListener('click',function(){
            var col=th.getAttribute('data-sort-trigger');
            var isAsc=th.classList.contains('sort-asc');
            headers.forEach(function(h){h.classList.remove('sort-asc','sort-desc');});
            th.classList.add(isAsc?'sort-desc':'sort-asc');
            var tbody=table.querySelector('tbody');
            var rows=Array.from(tbody.querySelectorAll('tr'));
            rows.sort(function(a,b){
                var aVal=a.getAttribute('data-'+col)||'';
                var bVal=b.getAttribute('data-'+col)||'';
                var cmp=aVal.localeCompare(bVal);
                return isAsc?-cmp:cmp;
            });
            rows.forEach(function(row){tbody.appendChild(row);});
        });
    });
}

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
    // Init pattern table sort
    initPatternTableSort();
    // Appliquer le filtre score par défaut (min=4, max=5) au chargement
    applyFriseScoreFilter();

    // Fix 5 — Barre de progression de lecture latérale
    var progBar=document.createElement('div');
    progBar.id='read-progress-bar';
    progBar.style.cssText='position:fixed;left:0;top:0;width:3px;height:0%;background:var(--accent,#0f766e);z-index:9999;border-radius:0 2px 2px 0;transition:height 80ms linear;pointer-events:none;';
    document.body.appendChild(progBar);
    function updateProgress(){
        var sc=window.scrollY||document.documentElement.scrollTop;
        var h=document.documentElement.scrollHeight-document.documentElement.clientHeight;
        var pct=h>0?Math.min(100,Math.round(sc/h*100)):0;
        progBar.style.height=pct+'%';
    }
    window.addEventListener('scroll',updateProgress,{passive:true});
    updateProgress();

    // Fix 7 — Décaler le contenu quand le panneau détail est ouvert
    function syncPanelMargin(){
        var panel=document.getElementById('patDetailPanel');
        var shell=document.querySelector('.report-shell');
        if(!shell) return;
        if(panel&&!panel.hidden){
            var pw=panel.offsetWidth||400;
            shell.style.paddingRight=(pw+20)+'px';
            shell.style.transition='padding-right 220ms ease';
        } else {
            shell.style.paddingRight='';
        }
    }
    // Observe le panneau pour détecter show/hide
    var detObs=new MutationObserver(syncPanelMargin);
    var detPanel=document.getElementById('patDetailPanel');
    if(detPanel) detObs.observe(detPanel,{attributes:true,attributeFilter:['hidden']});
    document.getElementById('patDetailClose')?.addEventListener('click',function(){setTimeout(syncPanelMargin,10);});
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
        (New-DanewReportSectionHtml -Title 'Frise chronologique critique' -Caption ('Top ' + [string]([Math]::Min(40, $critTotalCount)) + ' evenements significatifs (criticite >= 4 : ELEVE ou CRITIQUE) tries par timestamp. ' + $critTotalCount + ' evenements detectes au total.') -SearchText 'frise chronologie critique timestamp famille provider event' -BodyHtml ($critNotice + $critFriseHtml))
        (New-DanewReportSectionHtml -Title 'Patterns de panne detectes' -Caption ([string]$patternCount + ' pattern(s) detecte(s). Chaque carte indique la sequence, les preuves et les actions SAV disponibles (copie seulement).') -SearchText 'patterns panne sequence preuves confidence cause impact' -BodyHtml $patternCardsHtml)
        (New-DanewReportSectionHtml -Title 'Causes principales et secondaires' -Caption 'Score et justification pour chaque hypothese de cause racine, triee par score decroissant.' -SearchText 'causes confidence score reason root cause analysis' -BodyHtml (New-DanewReportTableHtml -Headers @('Cause', 'Confiance', 'Score', 'Justification') -Rows $causeRows -EmptyMessage 'Aucune cause ne correspond.'))
        (New-DanewReportSectionHtml -Title 'Intelligence de chronologie' -Caption 'Motifs detectes dans la chronologie brute — complement de la section Patterns.' -SearchText 'timeline intelligence motifs confidence resume' -BodyHtml (New-DanewReportTableHtml -Headers @('Motif', 'Confiance', 'Resume') -Rows $timelineRows -EmptyMessage 'Aucun motif.') -Collapsed $true)
        (New-DanewReportSectionHtml -Title 'Tableau des evenements (top 50)' -Caption 'Tous les evenements classes — utilisez les filtres famille dans la barre d outils secondaire.' -SearchText 'event classification provider category message criticite' -BodyHtml (New-DanewReportTableHtml -Headers @('Horodatage', 'ID Evt', 'Fournisseur', 'Categorie', 'Score', 'Message') -Rows $eventRows -EmptyMessage 'Aucun evenement.') -Collapsed $true)
        $(if ($wuSectionHtml) { $wuSectionHtml })
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
