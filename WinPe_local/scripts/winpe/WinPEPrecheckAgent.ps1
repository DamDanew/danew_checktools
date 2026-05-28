Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-DanewWinPEPrecheckCheck {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,
        [Parameter(Mandatory = $true)]
        [string]$Label,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Available', 'Limited', 'Missing')]
        [string]$Status,
        [Parameter(Mandatory = $true)]
        [string]$Details,
        [bool]$Critical = $false,
        [object]$FixAvailable = $false,
        [bool]$FixApplied = $false,
        [string]$FixResult = '',
        [object]$Data = $null
    )

    return [pscustomobject]@{
        id = $Id
        label = $Label
        status = $Status
        critical = $Critical
        details = $Details
        fix_available = [bool]$FixAvailable
        fix_applied = $FixApplied
        fix_result = $FixResult
        data = $Data
    }
}

function Test-DanewWritableDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        if (-not (Test-Path -Path $Path)) {
            New-Item -Path $Path -ItemType Directory -Force | Out-Null
        }

        $probe = Join-Path $Path ('write-probe-' + [guid]::NewGuid().ToString() + '.tmp')
        'ok' | Set-Content -Path $probe -Encoding ASCII
        Remove-Item -Path $probe -Force -ErrorAction SilentlyContinue
        return $true
    }
    catch {
        return $false
    }
}

function Get-DanewWinPEPrecheckOverallStatus {
    param([object[]]$Checks)

    $allChecks = @($Checks)
    $criticalMissing = @($allChecks | Where-Object { $_.critical -and $_.status -eq 'Missing' }).Count
    $criticalLimited = @($allChecks | Where-Object { $_.critical -and $_.status -eq 'Limited' }).Count
    $anyMissing = @($allChecks | Where-Object { $_.status -eq 'Missing' }).Count

    if ($criticalMissing -gt 0) {
        return 'FAIL'
    }
    if ($criticalLimited -gt 0 -or $anyMissing -gt 0) {
        return 'WARNING'
    }
    return 'PASS'
}

function Update-DanewWinPEPrecheckHistory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HistoryPath,
        [Parameter(Mandatory = $true)]
        [object]$RunSummary
    )

    function Get-DanewFlattenedHistoryRuns {
        param([AllowNull()][object]$InputObject)

        if ($null -eq $InputObject) {
            return @()
        }

        if ($InputObject -is [System.Array]) {
            $items = @()
            foreach ($entry in @($InputObject)) {
                $items += @(Get-DanewFlattenedHistoryRuns -InputObject $entry)
            }
            return @($items)
        }

        if ($InputObject.PSObject.Properties['runs']) {
            return @(Get-DanewFlattenedHistoryRuns -InputObject $InputObject.runs)
        }

        return @($InputObject)
    }

    $historyItems = @()
    if (Test-Path -Path $HistoryPath) {
        try {
            $parsed = Get-Content -Path $HistoryPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $historyItems = @(Get-DanewFlattenedHistoryRuns -InputObject $parsed)
        }
        catch {
            $historyItems = @()
        }
    }

    $historyItems += $RunSummary
    $historyJsonItems = @($historyItems | ForEach-Object { $_ | ConvertTo-Json -Depth 30 -Compress })
    ('{"runs":[' + ($historyJsonItems -join ',') + ']}') | Set-Content -Path $HistoryPath -Encoding UTF8
}

function Invoke-DanewWinPEPrecheckAgent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [Parameter(Mandatory = $true)]
        [object]$Config,
        [switch]$ApplyFixes
    )

    if (-not (Test-Path -Path $Config.reports_path)) {
        New-Item -Path $Config.reports_path -ItemType Directory -Force | Out-Null
    }

    $checks = @()
    $fixActions = New-Object System.Collections.ArrayList

    $requiredFolders = @(
        [pscustomobject]@{ label = 'reports'; path = $Config.reports_path },
        [pscustomobject]@{ label = 'scripts'; path = (Join-Path $RootPath 'scripts') },
        [pscustomobject]@{ label = 'tools'; path = (Join-Path $RootPath 'tools') }
    )

    $psCmd = Get-Command -Name powershell.exe -ErrorAction SilentlyContinue
    $pwshCmd = Get-Command -Name pwsh.exe -ErrorAction SilentlyContinue
    $psVersion = $PSVersionTable.PSVersion
    $psStatus = 'Missing'
    $psDetails = 'Aucun moteur PowerShell compatible detecte.'
    if ($psCmd -or $pwshCmd) {
        if ($psVersion -and [int]$psVersion.Major -ge 5) {
            $psStatus = 'Available'
            $psDetails = 'PowerShell detecte avec version compatible: ' + [string]$psVersion
        }
        else {
            $psStatus = 'Limited'
            $psDetails = 'PowerShell detecte mais version limitee: ' + [string]$psVersion
        }
    }

    $checks += New-DanewWinPEPrecheckCheck -Id 'powershell' -Label 'PowerShell compatible' -Status $psStatus -Details $psDetails -Critical $true -Data [pscustomobject]@{ powershell = [bool]$psCmd; pwsh = [bool]$pwshCmd; version = [string]$psVersion }

    $winFormsStatus = 'Missing'
    $winFormsDetails = 'WinForms indisponible.'
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $winFormsStatus = 'Available'
        $winFormsDetails = 'WinForms et System.Drawing disponibles.'
    }
    catch {
        $winFormsStatus = 'Missing'
        $winFormsDetails = 'WinForms indisponible: ' + $_.Exception.Message
    }
    $checks += New-DanewWinPEPrecheckCheck -Id 'winforms' -Label '.NET / WinForms GUI' -Status $winFormsStatus -Details $winFormsDetails -Critical $true

    $evtxStatus = 'Missing'
    $evtxDetails = 'Get-WinEvent indisponible.'
    $evtxCmd = Get-Command -Name Get-WinEvent -ErrorAction SilentlyContinue
    if ($evtxCmd) {
        $evtxStatus = 'Available'
        $evtxDetails = 'Lecture EVTX disponible via Get-WinEvent.'
    }
    $checks += New-DanewWinPEPrecheckCheck -Id 'evtx_reader' -Label 'Lecture EVTX' -Status $evtxStatus -Details $evtxDetails -Critical $true -Data [pscustomobject]@{ command = if ($evtxCmd) { $evtxCmd.Source } else { '' } }

    $foldersData = @()
    $folderMissing = 0
    $folderLimited = 0
    foreach ($folder in @($requiredFolders)) {
        $exists = Test-Path -Path $folder.path
        $writable = $false
        if ($exists) {
            $writable = Test-DanewWritableDirectory -Path $folder.path
        }

        $state = 'Available'
        if (-not $exists) {
            $state = 'Missing'
            $folderMissing++
        }
        elseif (-not $writable) {
            $state = 'Limited'
            $folderLimited++
        }

        $fixApplied = $false
        $fixResult = ''
        if ($ApplyFixes -and $state -eq 'Missing') {
            try {
                New-Item -Path $folder.path -ItemType Directory -Force | Out-Null
                $fixApplied = $true
                $fixResult = 'Dossier cree automatiquement.'
                $state = if (Test-DanewWritableDirectory -Path $folder.path) { 'Available' } else { 'Limited' }
                [void]$fixActions.Add([pscustomobject]@{ action = 'create-folder'; target = $folder.path; result = 'ok' })
            }
            catch {
                $fixApplied = $true
                $fixResult = 'Echec creation dossier: ' + $_.Exception.Message
                [void]$fixActions.Add([pscustomobject]@{ action = 'create-folder'; target = $folder.path; result = 'error'; details = $_.Exception.Message })
            }
        }

        $foldersData += [pscustomobject]@{ folder = $folder.label; path = $folder.path; status = $state; exists = (Test-Path -Path $folder.path) }

        if ($fixApplied -and $state -eq 'Available') {
            $folderMissing = [math]::Max(0, $folderMissing - 1)
        }
    }

    $foldersStatus = 'Available'
    if (@($foldersData | Where-Object { $_.status -eq 'Missing' }).Count -gt 0) {
        $foldersStatus = 'Missing'
    }
    elseif (@($foldersData | Where-Object { $_.status -eq 'Limited' }).Count -gt 0) {
        $foldersStatus = 'Limited'
    }

    $foldersDetails = 'Disponibilite dossiers reports/scripts/tools OK.'
    if ($foldersStatus -eq 'Missing') { $foldersDetails = 'Un ou plusieurs dossiers requis sont absents.' }
    elseif ($foldersStatus -eq 'Limited') { $foldersDetails = 'Un ou plusieurs dossiers requis sont en acces limite.' }

    $folderFixNote = ''
    if ($ApplyFixes) {
        $folderFixNote = 'Creation auto tentee pour dossiers manquants.'
    }
    $checks += New-DanewWinPEPrecheckCheck -Id 'required_folders' -Label 'Dossiers requis accessibles' -Status $foldersStatus -Details $foldersDetails -Critical $true -FixAvailable $true -FixApplied ([bool]$ApplyFixes) -FixResult $folderFixNote -Data $foldersData

    $timelineHtmlPath = Join-Path $Config.reports_path 'timeline-raw.html'
    $evtxHtmlPath = Join-Path $Config.reports_path 'evtx-events.html'
    $htmlStatus = 'Limited'
    $htmlDetails = 'Rapports EVTX HTML non generes dans reports.'
    $htmlData = [pscustomobject]@{ timeline_raw_html = $timelineHtmlPath; evtx_events_html = $evtxHtmlPath; markers = @() }
    if ((Test-Path -Path $timelineHtmlPath) -or (Test-Path -Path $evtxHtmlPath)) {
        $candidate = if (Test-Path -Path $timelineHtmlPath) { $timelineHtmlPath } else { $evtxHtmlPath }
        try {
            $htmlContent = Get-Content -Path $candidate -Raw -Encoding UTF8
            $markers = @(
                [pscustomobject]@{ id = 'search'; ok = ($htmlContent -match 'data-report-search') },
                [pscustomobject]@{ id = 'filters'; ok = ($htmlContent -match 'data-filter-level') },
                [pscustomobject]@{ id = 'detail'; ok = ($htmlContent -match 'data-evtx-detail') },
                [pscustomobject]@{ id = 'modes'; ok = ($htmlContent -match 'Mode Technicien' -and $htmlContent -match 'Mode Client') }
            )
            $okCount = @($markers | Where-Object { $_.ok }).Count
            if ($okCount -eq @($markers).Count) {
                $htmlStatus = 'Available'
                $htmlDetails = 'HTML interactif EVTX detecte avec marqueurs principaux.'
            }
            else {
                $htmlStatus = 'Limited'
                $htmlDetails = 'HTML present mais marqueurs interactifs incomplets.'
            }
            $htmlData = [pscustomobject]@{ timeline_raw_html = $timelineHtmlPath; evtx_events_html = $evtxHtmlPath; markers = $markers }
        }
        catch {
            $htmlStatus = 'Limited'
            $htmlDetails = 'HTML EVTX present mais lecture impossible: ' + $_.Exception.Message
        }
    }
    $checks += New-DanewWinPEPrecheckCheck -Id 'interactive_html' -Label 'Rapport HTML/JS interactif' -Status $htmlStatus -Details $htmlDetails -Critical $false -Data $htmlData

    $exportStatus = 'Available'
    $exportDetails = 'Ecriture CSV/JSON/TXT via PowerShell fonctionnelle.'
    $probeDir = Join-Path $Config.reports_path 'precheck-probe'
    $probeCsv = Join-Path $probeDir 'probe.csv'
    $probeJson = Join-Path $probeDir 'probe.json'
    $probeTxt = Join-Path $probeDir 'probe.txt'
    try {
        if (-not (Test-Path -Path $probeDir)) {
            New-Item -Path $probeDir -ItemType Directory -Force | Out-Null
        }
        @([pscustomobject]@{ col = 'ok' }) | Export-Csv -Path $probeCsv -NoTypeInformation -Encoding UTF8
        [pscustomobject]@{ check = 'ok' } | ConvertTo-Json | Set-Content -Path $probeJson -Encoding UTF8
        'ok' | Set-Content -Path $probeTxt -Encoding UTF8
    }
    catch {
        $exportStatus = 'Missing'
        $exportDetails = 'Ecriture export CSV/JSON/TXT en echec: ' + $_.Exception.Message
    }
    finally {
        if (Test-Path -Path $probeDir) {
            Remove-Item -Path $probeDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    $checks += New-DanewWinPEPrecheckCheck -Id 'powershell_exports' -Label 'Exports CSV/JSON/TXT' -Status $exportStatus -Details $exportDetails -Critical $true

    $windowsCandidates = @()
    try {
        $windowsCandidates = @(
            Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
                ForEach-Object { $_.Root } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                ForEach-Object {
                    $winPath = Join-Path $_ 'Windows'
                    [pscustomobject]@{
                        root = $_
                        windows = Test-Path -Path $winPath
                        eventlogs = Test-Path -Path (Join-Path $winPath 'System32\winevt\Logs')
                    }
                }
        )
    }
    catch {
        $windowsCandidates = @()
    }

    $windowsFound = @($windowsCandidates | Where-Object { $_.windows }).Count
    $windowsStatus = if ($windowsFound -gt 0) { 'Available' } else { 'Limited' }
    $windowsDetails = if ($windowsFound -gt 0) { 'Installation(s) Windows detectee(s): ' + [string]$windowsFound } else { 'Aucune installation Windows detectee dans cet environnement.' }
    $checks += New-DanewWinPEPrecheckCheck -Id 'windows_volume_detection' -Label 'Detection volume Windows / partitions internes' -Status $windowsStatus -Details $windowsDetails -Critical $true -Data $windowsCandidates

    $cfgChecks = @()
    $cfgMissing = 0
    foreach ($key in @('input_path', 'reports_path', 'logs_path', 'launcher_log_path', 'startnet_output_path')) {
        $prop = $Config.PSObject.Properties[$key]
        $value = if ($prop) { [string]$prop.Value } else { '' }
        $ok = -not [string]::IsNullOrWhiteSpace($value)
        if (-not $ok) { $cfgMissing++ }
        $cfgChecks += [pscustomobject]@{ key = $key; value = $value; ok = $ok }
    }

    $cfgStatus = if ($cfgMissing -eq 0) { 'Available' } else { 'Missing' }
    $cfgDetails = if ($cfgMissing -eq 0) { 'Configuration launcher coherente.' } else { 'Configuration launcher incomplete: ' + [string]$cfgMissing + ' champ(s) manquant(s).' }

    $cfgFixApplied = $false
    $cfgFixAvailable = $false
    $cfgFixResult = ''
    if ($ApplyFixes -and $cfgMissing -gt 0) {
        $cfgFixApplied = $true
        $cfgFixAvailable = $true
        $cfgFixResult = 'Correction automatique non destructive non appliquee (champs de config manquants necessitent validation manuelle).'
        [void]$fixActions.Add([pscustomobject]@{ action = 'config-review'; target = $Config.config_path; result = 'manual-required' })
    }

    if ($cfgMissing -gt 0 -and -not $cfgFixAvailable) {
        $cfgFixAvailable = $true
    }

    $checks += New-DanewWinPEPrecheckCheck -Id 'launcher_config' -Label 'Variables et configuration launcher' -Status $cfgStatus -Details $cfgDetails -Critical $true -FixAvailable ([bool]$cfgFixAvailable) -FixApplied ([bool]$cfgFixApplied) -FixResult $cfgFixResult -Data $cfgChecks

    $overall = Get-DanewWinPEPrecheckOverallStatus -Checks $checks

    $limitedCount = @($checks | Where-Object { $_.status -eq 'Limited' }).Count
    $missingCount = @($checks | Where-Object { $_.status -eq 'Missing' }).Count
    $availableCount = @($checks | Where-Object { $_.status -eq 'Available' }).Count

    $recommendations = @()
    if ($missingCount -gt 0) {
        $recommendations += 'Des composants critiques sont manquants: corriger avant utilisation SAV en production.'
    }
    if (@($checks | Where-Object { $_.id -eq 'evtx_reader' -and $_.status -ne 'Available' }).Count -gt 0) {
        $recommendations += 'Ajouter le support lecture EVTX dans l image WinPE (cmdlets/journaux).'
    }
    if (@($checks | Where-Object { $_.id -eq 'winforms' -and $_.status -ne 'Available' }).Count -gt 0) {
        $recommendations += 'Verifier packages GUI/WinForms dans l image WinPE.'
    }
    if (@($checks | Where-Object { $_.id -eq 'windows_volume_detection' -and $_.status -ne 'Available' }).Count -gt 0) {
        $recommendations += 'Verifier visibilite des disques internes (pilotes stockage/NVMe/RST/VMD).'
    }

    $jsonPath = Join-Path $Config.reports_path 'winpe-precheck-report.json'
    $txtPath = Join-Path $Config.reports_path 'winpe-precheck-report.txt'
    $historyPath = Join-Path $Config.reports_path 'WinPE_precheck_history.json'

    $report = [pscustomobject]@{
        timestamp = (Get-Date).ToString('s')
        root_path = $RootPath
        reports_path = $Config.reports_path
        apply_fixes = [bool]$ApplyFixes
        overall_status = $overall
        summary = [pscustomobject]@{
            available = $availableCount
            limited = $limitedCount
            missing = $missingCount
            total = @($checks).Count
        }
        checks = $checks
        recommendations_fr = $recommendations
        fix_actions = @($fixActions)
        artifacts = [pscustomobject]@{
            json = $jsonPath
            txt = $txtPath
            history = $historyPath
        }
    }

    $report | ConvertTo-Json -Depth 50 | Set-Content -Path $jsonPath -Encoding UTF8

    $lines = @(
        'Agent de pre-check WinPE Danew',
        ('Horodatage: ' + [string]$report.timestamp),
        ('Statut global: ' + [string]$report.overall_status),
        ('Available: ' + [string]$availableCount),
        ('Limited: ' + [string]$limitedCount),
        ('Missing: ' + [string]$missingCount),
        ''
    )
    foreach ($check in @($checks)) {
        $line = '[' + [string]$check.status + '] ' + [string]$check.label + ' - ' + [string]$check.details
        if ($check.fix_applied -and -not [string]::IsNullOrWhiteSpace([string]$check.fix_result)) {
            $line += ' | Correction: ' + [string]$check.fix_result
        }
        $lines += $line
    }
    if (@($recommendations).Count -gt 0) {
        $lines += ''
        $lines += 'Actions recommandees :'
        foreach ($item in @($recommendations)) {
            $lines += ('- ' + [string]$item)
        }
    }
    $lines | Set-Content -Path $txtPath -Encoding UTF8

    Update-DanewWinPEPrecheckHistory -HistoryPath $historyPath -RunSummary ([pscustomobject]@{
            timestamp = $report.timestamp
            overall_status = $report.overall_status
            available = $availableCount
            limited = $limitedCount
            missing = $missingCount
            apply_fixes = [bool]$ApplyFixes
            json_report = $jsonPath
            txt_report = $txtPath
        })

    return $report
}
