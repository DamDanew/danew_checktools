[CmdletBinding()]
param(
    [string]$RootPath = '',
    [string]$ConfigPath,
    [switch]$FallbackToCli,
    [switch]$ForceGuiInitFailure,
    [ValidateSet('Interactive', 'scan-winpe', 'capability-analysis', 'generate-report', 'open-reports-folder', 'export-diagnostic-package', 'prepare-startnet', 'start-diagnostic', 'analyze-offline-logs', 'analyze-offline-logs-fast', 'analyze-offline-logs-full', 'analyze-crash-causes', 'precheck-winpe', 'export-evtx-targeted', 'export-evtx-zip', 'check-browser', 'create-usb-media', 'real-winpe-validation', 'refresh-status', 'show-status', 'view-last-report', 'open-sav-report', 'open-reports-index', 'open-text-reports-list', 'generate-timeline-html', 'generate-html-reports', 'prepare-reports-for-tech', 'copy-sav-resume', 'exit')]
    [Alias('Action')]
    [string]$CliFallbackCommand = 'Interactive'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDirectory = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptDirectory)) {
    $scriptDirectory = Split-Path -Parent $PSCommandPath
}
if ([string]::IsNullOrWhiteSpace($scriptDirectory)) {
    $scriptDirectory = (Get-Location).Path
}
if ([string]::IsNullOrWhiteSpace($RootPath)) {
    $RootPath = Split-Path -Parent $scriptDirectory
}

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
}
catch {
}

. (Join-Path $scriptDirectory 'core\Logging.ps1')
. (Join-Path $scriptDirectory 'catalog\CatalogService.ps1')
. (Join-Path $scriptDirectory 'scan\ScanEngine.ps1')
. (Join-Path $scriptDirectory 'profiles\ProfileEngine.ps1')
. (Join-Path $scriptDirectory 'recommend\RecommendationEngine.ps1')
. (Join-Path $scriptDirectory 'recommend\EnrichmentPlanner.ps1')
. (Join-Path $scriptDirectory 'build\BuildPreparation.ps1')
. (Join-Path $scriptDirectory 'report\ReportEngine.ps1')
. (Join-Path $scriptDirectory 'security\SecurityService.ps1')
. (Join-Path $scriptDirectory 'launcher\LauncherCore.ps1')

# Detection WinPE centralisee — utilisee partout dans le launcher.
# Test-DanewIsWinPE est definie dans LauncherCore.ps1 (deja charge ci-dessus).
$script:IsWinPE = Test-DanewIsWinPE

$config = Get-DanewLauncherConfig -RootPath $RootPath -ConfigPath $ConfigPath
if ($CliFallbackCommand -notin @('open-sav-report', 'open-reports-index')) {
    $null = Invoke-DanewLauncherAction -Action 'prepare-startnet' -RootPath $RootPath -Config $config
}
[void](Write-DanewLauncherActionLog -Config $config -Action 'gui-launcher' -Status 'start' -Message 'GUI launcher initialization started')

$cliPath = Join-Path $scriptDirectory 'DanewCheckTool.CLI.ps1'

$form = $null
$statusFields = @{}
$progressBox = $null
$summaryLabel = $null
$overallBadgeLabel = $null
$windowsStatusValueLabel = $null
$storageStatusValueLabel = $null
$criticalEventsValueLabel = $null
$probableCauseValueLabel = $null
$confidenceValueLabel = $null
$severityValueLabel = $null
$recommendedActionValueLabel = $null
$runtimeChipLabel = $null
$windowsChipLabel = $null
$usbChipLabel = $null
$machineChipLabel = $null
$analysisCompletionLabel = $null
$openSavReportButton = $null
$openTimelineFastReportButton = $null
$openReportsButton = $null
$openTextReportsButton = $null
$exportEvtxZipButton = $null
$exportBtn1 = $null
$exportBtn2 = $null
$exportBtn3 = $null
$exportBtn4 = $null
$toolTip = $null
$offlineProgressBar = $null
$offlineSubProgressBar = $null
$offlineOperationLabel = $null
$offlineTimingLabel = $null
$fastCriticalCheckBox = $null
$fastErrorCheckBox = $null
$fastWarningCheckBox = $null
$fastEventLimitComboBox = $null
$stepLabels = @{}
$recentActivityBox = $null
$simpleActionsGroup = $null
$quickActionsGroup = $null
$statusGroup = $null
$togglePanel = $null
$advancedToggleButton = $null
$technicalToggleButton = $null
$buttonGroup = $null
$technicalDetailsGroup = $null
$technicalDetailsSplitContainer = $null
$script:ActionButtons = New-Object System.Collections.ArrayList
$script:IsActionRunning = $false
$script:AdvancedToolsVisible = $false
$script:TechnicalDetailsVisible = $false
$script:SavSummaryDetailsVisible = $false
$script:SavSummaryDetailControls = @()
$script:BaseFormClientWidth = 900
$script:BaseFormClientHeight = 720
$script:DockedTechnicalFormClientWidth = 1240
$script:TechnicalDockWidth = 330
$script:TechnicalTopPanelHeight = 196

$script:StatusColorDefault = $null
$script:StatusColorPass = $null
$script:StatusColorWarning = $null
$script:StatusColorFail = $null
$script:OfflineProgressStart = $null
$script:OfflineProgressUpdates = 0
$script:GuiSessionStartedAt = Get-Date
$script:ReportAvailabilityCutoff = $script:GuiSessionStartedAt.AddSeconds(-2)
$script:LastReportOpenError = ''
$script:BrowserOperationalCachePath = ''
$script:BrowserOperationalCacheResult = $false

function Get-DanewElapsedText {
    param(
        [datetime]$Since
    )

    if (-not $Since) {
        return '00:00'
    }

    $elapsed = (Get-Date) - $Since
    return ('{0:00}:{1:00}' -f [int]$elapsed.TotalMinutes, [int]$elapsed.Seconds)
}

function Get-DanewOfflineSpinnerSymbol {
    $symbols = @('[   ]', '[=  ]', '[== ]', '[===]', '[ ==]', '[  =]')
    if ($script:OfflineProgressUpdates -lt 0) {
        $script:OfflineProgressUpdates = 0
    }
    return $symbols[($script:OfflineProgressUpdates % $symbols.Count)]
}

function Convert-DanewUiText {
    param(
        [AllowNull()]
        [string]$Text
    )

    if ($null -eq $Text) {
        return ''
    }

    $value = [string]$Text
    if ([string]::IsNullOrEmpty($value)) {
        return $value
    }

    # UI labels are ASCII-safe in WinPE; keep function as a central text hook.
    $value = $value.TrimEnd()

    return $value
}

function Repair-DanewControlTreeText {
    param(
        [AllowNull()]
        [System.Windows.Forms.Control]$Control
    )

    if (-not $Control) {
        return
    }

    try {
        if ($Control.Text -is [string]) {
            $Control.Text = Convert-DanewUiText -Text ([string]$Control.Text)
        }
    }
    catch {
    }

    foreach ($child in @($Control.Controls)) {
        Repair-DanewControlTreeText -Control $child
    }
}

function New-DanewReadOnlyTextBox {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $box = New-Object System.Windows.Forms.TextBox
    $box.Name = $Name
    $box.ReadOnly = $true
    $box.BorderStyle = 'FixedSingle'
    $box.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)
    $box.ForeColor = [System.Drawing.Color]::FromArgb(31, 41, 55)
    $box.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $box.Dock = 'Fill'
    $box.Margin = New-Object System.Windows.Forms.Padding(3, 2, 3, 2)
    $box
}

function Set-DanewStatusFieldVisual {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    if (-not ($statusFields.ContainsKey($Name) -and $statusFields[$Name])) {
        return
    }

    $box = $statusFields[$Name]
    $box.ForeColor = $script:StatusColorDefault

    if ($Name -eq 'last_action_status') {
        $normalized = $Value.Trim().ToUpperInvariant()
        if ($normalized -eq 'PASS' -or $normalized -eq 'OK' -or $normalized -eq 'SUCCESS') {
            $box.ForeColor = $script:StatusColorPass
        }
        elseif ($normalized -eq 'WARNING' -or $normalized -eq 'WARN') {
            $box.ForeColor = $script:StatusColorWarning
        }
        elseif ($normalized -eq 'FAIL' -or $normalized -eq 'ERROR') {
            $box.ForeColor = $script:StatusColorFail
        }
    }
}

function Set-DanewStatusText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    if ($statusFields.ContainsKey($Name) -and $statusFields[$Name]) {
        $statusFields[$Name].Text = Convert-DanewUiText -Text $Value
        Set-DanewStatusFieldVisual -Name $Name -Value $Value
    }
}

function Set-DanewActionButtonsEnabled {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Enabled
    )

    foreach ($button in @($script:ActionButtons)) {
        if ($button) {
            $button.Enabled = $Enabled
            if ($button.Tag -and $button.Tag.PSObject.Properties['enabled_back_color']) {
                if ($Enabled) {
                    $button.BackColor = $button.Tag.enabled_back_color
                    $button.ForeColor = $button.Tag.enabled_fore_color
                    $button.FlatAppearance.BorderColor = $button.Tag.enabled_border_color
                    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
                }
                else {
                    $button.BackColor = $button.Tag.disabled_back_color
                    $button.ForeColor = $button.Tag.disabled_fore_color
                    $button.FlatAppearance.BorderColor = $button.Tag.disabled_border_color
                    $button.Cursor = [System.Windows.Forms.Cursors]::Default
                }
            }
        }
    }

    if (-not $script:IsActionRunning) {
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Set-DanewButtonAvailability {
    param(
        [AllowNull()]
        [System.Windows.Forms.Button]$Button,
        [Parameter(Mandatory = $true)]
        [bool]$Available,
        [AllowNull()]
        [System.Windows.Forms.ToolTip]$ToolTip,
        [string]$AvailableHint = '',
        [string]$UnavailableHint = 'Indisponible pour le moment. Lancez d abord une analyse ou genere un rapport.'
    )

    if (-not $Button) { return }

    if ($Button.Tag -and $Button.Tag.PSObject.Properties['base_text']) {
        $baseText = [string]$Button.Tag.base_text
        $Button.Text = Convert-DanewUiText -Text $baseText
    }

    $Button.Enabled = $Available
    if ($Button.Tag -and $Button.Tag.PSObject.Properties['enabled_back_color']) {
        if ($Available) {
            $Button.BackColor = $Button.Tag.enabled_back_color
            $Button.ForeColor = $Button.Tag.enabled_fore_color
            $Button.FlatAppearance.BorderColor = $Button.Tag.enabled_border_color
            $Button.Cursor = [System.Windows.Forms.Cursors]::Hand
        }
        else {
            $Button.BackColor = $Button.Tag.disabled_back_color
            $Button.ForeColor = $Button.Tag.disabled_fore_color
            $Button.FlatAppearance.BorderColor = $Button.Tag.disabled_border_color
            $Button.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    }

    if ($ToolTip) {
        $hint = if ($Available) { $AvailableHint } else { $UnavailableHint }
        if ([string]::IsNullOrWhiteSpace($hint) -and $Button.Tag -and $Button.Tag.PSObject.Properties['hint']) {
            $hint = [string]$Button.Tag.hint
        }
        if (-not [string]::IsNullOrWhiteSpace($hint)) {
            $ToolTip.SetToolTip($Button, (Convert-DanewUiText -Text $hint))
        }
    }
}

function Set-DanewSummaryVisual {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Status,
        [string]$Text = ''
    )

    $normalized = $Status.Trim().ToUpperInvariant()
    $badgeText = if ([string]::IsNullOrWhiteSpace($normalized)) { 'INACTIF' } else { (Get-DanewLocalizedStatusText $normalized) }
    $badgeBack = [System.Drawing.Color]::FromArgb(229, 231, 235)
    $badgeFore = [System.Drawing.Color]::FromArgb(31, 41, 55)

    if ($normalized -eq 'PASS' -or $normalized -eq 'OK' -or $normalized -eq 'SUCCESS') {
        $badgeBack = [System.Drawing.Color]::FromArgb(20, 184, 166)
        $badgeFore = [System.Drawing.Color]::White
    }
    elseif ($normalized -eq 'WARNING' -or $normalized -eq 'WARN') {
        $badgeBack = [System.Drawing.Color]::FromArgb(245, 158, 11)
        $badgeFore = [System.Drawing.Color]::FromArgb(17, 24, 39)
    }
    elseif ($normalized -eq 'FAIL' -or $normalized -eq 'ERROR' -or $normalized -eq 'CRITICAL') {
        $badgeBack = [System.Drawing.Color]::FromArgb(220, 38, 38)
        $badgeFore = [System.Drawing.Color]::White
    }
    elseif ($normalized -eq 'INFO' -or $normalized -eq 'IDLE') {
        $badgeBack = [System.Drawing.Color]::FromArgb(37, 99, 235)
        $badgeFore = [System.Drawing.Color]::White
    }
    elseif ($normalized -eq 'RUNNING') {
        $badgeBack = [System.Drawing.Color]::FromArgb(245, 158, 11)
        $badgeFore = [System.Drawing.Color]::FromArgb(17, 24, 39)
    }
    elseif ($normalized -eq 'READY' -or $normalized -eq 'WAITING') {
        $badgeText = 'En attente'
        $badgeBack = [System.Drawing.Color]::FromArgb(226, 232, 240)
        $badgeFore = [System.Drawing.Color]::FromArgb(30, 41, 59)
    }

    if ($overallBadgeLabel) {
        $overallBadgeLabel.Text = $badgeText
        $overallBadgeLabel.BackColor = $badgeBack
        $overallBadgeLabel.ForeColor = $badgeFore
    }

    if ($summaryLabel -and -not [string]::IsNullOrWhiteSpace($Text)) {
        $summaryLabel.Text = Convert-DanewUiText -Text $Text
    }
}

function Set-DanewAnalysisCompletionState {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('idle', 'running', 'done', 'error')]
        [string]$State,
        [string]$Text = ''
    )

    if (-not $analysisCompletionLabel) {
        return
    }

    switch ($State) {
        'idle' {
            $analysisCompletionLabel.Text = 'Analyse: en attente'
            $analysisCompletionLabel.ForeColor = [System.Drawing.Color]::FromArgb(219, 234, 254)
        }
        'running' {
            $analysisCompletionLabel.Text = 'Analyse: en cours...'
            $analysisCompletionLabel.ForeColor = [System.Drawing.Color]::FromArgb(191, 219, 254)
        }
        'done' {
            $analysisCompletionLabel.Text = if ([string]::IsNullOrWhiteSpace($Text)) { '[OK] Analyse terminee' } else { '[OK] ' + $Text }
            $analysisCompletionLabel.ForeColor = [System.Drawing.Color]::FromArgb(134, 239, 172)
        }
        'error' {
            $analysisCompletionLabel.Text = if ([string]::IsNullOrWhiteSpace($Text)) { '[X] Analyse en echec' } else { '[X] ' + $Text }
            $analysisCompletionLabel.ForeColor = [System.Drawing.Color]::FromArgb(254, 202, 202)
        }
    }
}

function Set-DanewStepState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [ValidateSet('pending', 'running', 'pass', 'warning', 'fail')]
        [string]$State
    )

    if (-not ($stepLabels.ContainsKey($Name) -and $stepLabels[$Name])) {
        return
    }

    $label = $stepLabels[$Name]
    $prefix = '[ ] '
    $back = [System.Drawing.Color]::FromArgb(241, 245, 249)
    $fore = [System.Drawing.Color]::FromArgb(71, 85, 105)

    switch ($State) {
        'running' { $prefix = '[...] '; $back = [System.Drawing.Color]::FromArgb(219, 234, 254); $fore = [System.Drawing.Color]::FromArgb(30, 64, 175) }
        'pass' { $prefix = '[OK] '; $back = [System.Drawing.Color]::FromArgb(204, 251, 241); $fore = [System.Drawing.Color]::FromArgb(15, 118, 110) }
        'warning' { $prefix = '[!] '; $back = [System.Drawing.Color]::FromArgb(254, 243, 199); $fore = [System.Drawing.Color]::FromArgb(146, 64, 14) }
        'fail' { $prefix = '[X] '; $back = [System.Drawing.Color]::FromArgb(254, 226, 226); $fore = [System.Drawing.Color]::FromArgb(153, 27, 27) }
    }

    $baseText = [string]$label.Tag
    $label.Text = $prefix + $baseText
    $label.BackColor = $back
    $label.ForeColor = $fore
}

function Reset-DanewStepStates {
    foreach ($name in @($stepLabels.Keys)) {
        Set-DanewStepState -Name ([string]$name) -State 'pending'
    }
}

function Update-DanewRecentActivity {
    if (-not $recentActivityBox) {
        return
    }

    function Set-DanewRecentActivityLines {
        param([string[]]$Lines)

        $recentActivityBox.Clear()
        foreach ($line in @($Lines)) {
            $upper = ([string]$line).ToUpperInvariant()
            if ($upper -match 'FAIL|ERROR') {
                $recentActivityBox.SelectionColor = [System.Drawing.Color]::FromArgb(180, 35, 24)
            }
            elseif ($upper -match 'WARN') {
                $recentActivityBox.SelectionColor = [System.Drawing.Color]::FromArgb(180, 83, 9)
            }
            elseif ($upper -match 'PASS|OK') {
                $recentActivityBox.SelectionColor = [System.Drawing.Color]::FromArgb(15, 118, 110)
            }
            else {
                $recentActivityBox.SelectionColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
            }
            $recentActivityBox.AppendText(([string]$line) + [Environment]::NewLine)
        }
        $recentActivityBox.SelectionColor = $recentActivityBox.ForeColor
    }

    try {
        $entries = @()
        if (Test-Path -Path $config.launcher_log_path) {
            $raw = Get-Content -Path $config.launcher_log_path -Raw -Encoding UTF8
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $entries = @($raw | ConvertFrom-Json -Depth 20)
            }
        }

        $lines = @(
            $entries |
                Select-Object -Last 5 |
                ForEach-Object {
                    $time = [string]$_.timestamp
                    if ($time.Length -ge 16) { $time = $time.Substring(11, 5) }
                    $time + '  ' + [string]$_.action + '  ' + [string]$_.status
                }
        )

        if (@($lines).Count -eq 0) {
            $lines = @('Aucune activite recente')
        }
        Set-DanewRecentActivityLines -Lines $lines
    }
    catch {
        Set-DanewRecentActivityLines -Lines @('Activite recente indisponible')
    }
}

function Get-DanewActionDisplayText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Action
    )

    switch ($Action) {
        'open-reports-index' { return 'Ouvrir les rapports Danew' }
        'open-text-reports-list' { return 'Ouvrir la liste des rapports texte' }
        'open-sav-report' { return 'Ouvrir le rapport SAV' }
        'open-timeline-report' { return 'Ouvrir la chronologie complete' }
        'open-timeline-fast-report' { return 'Ouvrir la vue rapide EVTX' }
        'open-storage-report' { return 'Ouvrir le rapport stockage' }
        'recommended-actions' { return 'Afficher les actions recommandees' }
        'analyze-offline-logs-fast' { return 'Analyse rapide des journaux Windows' }
        'analyze-offline-logs-full' { return 'Analyse complete des journaux Windows' }
        'analyze-crash-causes' { return 'Analyser les causes de crash' }
        'check-browser' { return 'Verifier navigateur HTML' }
        'create-usb-media' { return 'Preparer outil USB' }
        'refresh-status' { return 'Actualiser le statut' }
        'start-diagnostic' { return 'Diagnostic complet' }
        'generate-timeline-html'  { return 'Generer la chronologie HTML' }
        'generate-html-reports'   { return 'Generer tous les rapports HTML' }
        default { return $Action }
    }
}

function Get-DanewUsbMediaReadyDisplay {
    $bootValidationPath = Join-Path ([string]$config.reports_path) 'usb-boot-validation.json'
    if (-not (Test-Path -Path $bootValidationPath)) {
        return 'Unknown'
    }

    try {
        $bootValidation = Get-Content -Path $bootValidationPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20
        if ([string]$bootValidation.status -eq 'PASS') {
            return 'READY'
        }
        if ([string]$bootValidation.status -eq 'WARNING') {
            return 'WARNING'
        }
        return 'NOT READY'
    }
    catch {
        return 'Unknown'
    }
}

function Copy-DanewReportToDataVolume {
    param(
        [string]$HtmlPath,
        [string]$JsonPath
    )

    try {
        $dataVolume = @(Get-Volume -FileSystemLabel 'DANEW_DATA' -ErrorAction SilentlyContinue | Select-Object -First 1)
        if (@($dataVolume).Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$dataVolume[0].DriveLetter)) {
            return ''
        }

        $targetRoot = [string]$dataVolume[0].DriveLetter + ':\DANEW_REPORTS'
        if (-not (Test-Path -Path $targetRoot)) {
            New-Item -Path $targetRoot -ItemType Directory -Force | Out-Null
        }

        if (-not [string]::IsNullOrWhiteSpace($HtmlPath) -and (Test-Path -Path $HtmlPath)) {
            Copy-Item -Path $HtmlPath -Destination (Join-Path $targetRoot 'latest.html') -Force
        }
        if (-not [string]::IsNullOrWhiteSpace($JsonPath) -and (Test-Path -Path $JsonPath)) {
            Copy-Item -Path $JsonPath -Destination (Join-Path $targetRoot 'latest.json') -Force
        }

        return $targetRoot
    }
    catch {
        return ''
    }
}

function Set-DanewAdvancedToolsVisible {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Visible
    )

    $script:AdvancedToolsVisible = $Visible
    if ($buttonGroup) {
        $buttonGroup.Visible = $Visible
    }
    if ($advancedToggleButton) {
        if ($Visible) {
            $advancedToggleText = 'MASQUER LES OUTILS AVANCES'
        } else {
            $advancedToggleText = 'AFFICHER LES OUTILS AVANCES'
        }
        $advancedToggleButton.Text = Convert-DanewUiText -Text $advancedToggleText
    }
    if ($Visible -and $buttonGroup) {
        Show-DanewSecondaryPanelDialog -Title 'Outils avances' -Panel $buttonGroup -Width 900 -Height 330
        $script:AdvancedToolsVisible = $false
        $buttonGroup.Visible = $false
        if ($advancedToggleButton) {
            $advancedToggleButton.Text = Convert-DanewUiText -Text 'AFFICHER LES OUTILS AVANCES'
        }
    }
    if ($form) {
        $form.AutoScrollMinSize = New-Object System.Drawing.Size(900, 720)
    }
}

function Set-DanewTechnicalDetailsDockLayout {
    if (-not $technicalDetailsGroup -or -not $form) {
        return
    }

    $dockWidth = [int]$script:TechnicalDockWidth
    $rightMargin = 14
    $topMargin = 96
    $bottomMargin = 14
    $panelLeft = [Math]::Max(($script:BaseFormClientWidth + 10), ($form.ClientSize.Width - $dockWidth - $rightMargin))

    $technicalDetailsGroup.Left = $panelLeft
    $technicalDetailsGroup.Top = $topMargin
    $technicalDetailsGroup.Width = $dockWidth
    $technicalDetailsGroup.Height = [Math]::Max(560, ($form.ClientSize.Height - $topMargin - $bottomMargin))
    $technicalDetailsGroup.Anchor = 'Top,Bottom,Right'

    if ($statusTable) {
        $statusTable.Visible = $false
    }

    # progressBox fills the full height of the technical group (recentActivity panel removed).
    if ($progressBox) {
        $progressBox.Left = 12
        $progressBox.Top = 24
        $progressBox.Width = $dockWidth - 24
        $progressBox.Height = [Math]::Max(220, ($technicalDetailsGroup.Height - 36))
        $progressBox.Anchor = 'Top,Bottom,Left,Right'
    }
}

function Set-DanewReportsSectionLayout {
    # Deprecated — remplace par exportsPanel FlowLayoutPanel ; garde pour compatibilite form Resize.
    if (-not $simpleActionsGroup -or -not $exportsPanel) {
        return
    }
    $exportsPanel.Width = [Math]::Max(400, ([int]$simpleActionsGroup.ClientSize.Width - 20))
    return
    if (-not $simplePanel -or -not $openReportsButton) {
        return
    }

    $innerWidth = [Math]::Max(220, ([int]$simpleActionsGroup.ClientSize.Width - 20))
    $simplePanel.Left = 10
    $simplePanel.Top = 16
    $simplePanel.Width = $innerWidth
    $simplePanel.Height = 38
    $simplePanel.Anchor = 'Top,Left,Right'

    # Layout 2 buttons side-by-side: HTML (420px) + Fallback (180px) + 10px gap
    $htmlButtonWidth = [Math]::Min(420, [Math]::Max(200, ([int]($innerWidth * 0.65))))
    $fallbackButtonWidth = [Math]::Min(180, [Math]::Max(120, ([int]($innerWidth * 0.25))))
    $gapWidth = 10
    $totalButtonsWidth = $htmlButtonWidth + $fallbackButtonWidth + $gapWidth

    if ($totalButtonsWidth -le $innerWidth - 24) {
        # Both buttons fit side-by-side
        $startLeft = [Math]::Max(0, [int](($innerWidth - $totalButtonsWidth) / 2))

        $openReportsButton.Width = $htmlButtonWidth
        $openReportsButton.Left = $startLeft
        $openReportsButton.Top = 0

        if ($openTextReportsButton) {
            $openTextReportsButton.Width = $fallbackButtonWidth
            $openTextReportsButton.Left = $startLeft + $htmlButtonWidth + $gapWidth
            $openTextReportsButton.Top = 0
            if ($openTextReportsButton -notin $simplePanel.Controls) {
                [void]$simplePanel.Controls.Add($openTextReportsButton)
            }
        }
    } else {
        # Fallback: stack vertically
        $buttonWidth = [Math]::Min(400, [Math]::Max(220, ($innerWidth - 24)))
        $startLeft = [Math]::Max(0, [int](($innerWidth - $buttonWidth) / 2))

        $openReportsButton.Width = $buttonWidth
        $openReportsButton.Left = $startLeft
        $openReportsButton.Top = 0

        if ($openTextReportsButton) {
            $openTextReportsButton.Width = $buttonWidth
            $openTextReportsButton.Left = $startLeft
            $openTextReportsButton.Top = 50
            $simplePanel.Height = 110
            if ($openTextReportsButton -notin $simplePanel.Controls) {
                [void]$simplePanel.Controls.Add($openTextReportsButton)
            }
        }
    }
}

function Set-DanewTechnicalDetailsVisible {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Visible
    )

    $script:TechnicalDetailsVisible = $Visible
    if ($technicalDetailsGroup) {
        $technicalDetailsGroup.Visible = $Visible
    }
    if ($technicalToggleButton) {
        if ($Visible) {
            $technicalToggleText = 'MASQUER LES DETAILS TECHNIQUES'
        } else {
            $technicalToggleText = 'AFFICHER LES DETAILS TECHNIQUES'
        }
        $technicalToggleButton.Text = Convert-DanewUiText -Text $technicalToggleText
    }
    if ($form) {
        if ($Visible) {
            if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Normal -and $form.ClientSize.Width -lt $script:DockedTechnicalFormClientWidth) {
                $form.ClientSize = New-Object System.Drawing.Size($script:DockedTechnicalFormClientWidth, $script:BaseFormClientHeight)
            }
            Set-DanewTechnicalDetailsDockLayout
            if ($technicalDetailsGroup) {
                $technicalDetailsGroup.BringToFront()
            }
        }
        else {
            if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Normal -and $form.ClientSize.Width -ge $script:DockedTechnicalFormClientWidth) {
                $form.ClientSize = New-Object System.Drawing.Size($script:BaseFormClientWidth, $script:BaseFormClientHeight)
            }
        }
    }
    if ($form) {
        $form.AutoScrollMinSize = New-Object System.Drawing.Size(900, 720)
    }
}

function Set-DanewSavSummaryDetailsVisible {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Visible
    )

    $script:SavSummaryDetailsVisible = $Visible

    foreach ($control in @($script:SavSummaryDetailControls)) {
        if ($control) {
            $control.Visible = $Visible
        }
    }

    $clientHeight = if ($form) { [int]$form.ClientSize.Height } else { [int]$script:BaseFormClientHeight }
    function Get-DanewClampedTop {
        param(
            [int]$DesiredTop,
            [AllowNull()]
            [System.Windows.Forms.Control]$Control
        )
        if (-not $Control) {
            return $DesiredTop
        }
        $maxTop = [Math]::Max(0, ($clientHeight - [int]$Control.Height - 8))
        return [Math]::Min($DesiredTop, $maxTop)
    }

    if ($statusGroup) {
        $expandedHeight = [Math]::Min(276, [Math]::Max(108, ($clientHeight - 444)))
        $statusGroup.Height = if ($Visible) { $expandedHeight } else { 108 }
    }

    $statusBottom = if ($statusGroup) { [int]$statusGroup.Top + [int]$statusGroup.Height } else { 302 }
    $simpleDesiredTop = $statusBottom + 8
    $quickDesiredTop = $simpleDesiredTop + $(if ($simpleActionsGroup) { [int]$simpleActionsGroup.Height } else { 74 }) + 8
    $toggleDesiredTop = $quickDesiredTop + $(if ($quickActionsGroup) { [int]$quickActionsGroup.Height } else { 70 }) + 8
    $buttonDesiredTop = $toggleDesiredTop + $(if ($togglePanel) { [int]$togglePanel.Height } else { 40 }) + 8

    if ($simpleActionsGroup) {
        $simpleActionsGroup.Top = Get-DanewClampedTop -DesiredTop $simpleDesiredTop -Control $simpleActionsGroup
    }
    if ($quickActionsGroup) {
        $quickActionsGroup.Top = Get-DanewClampedTop -DesiredTop $quickDesiredTop -Control $quickActionsGroup
    }
    if ($togglePanel) {
        $togglePanel.Top = Get-DanewClampedTop -DesiredTop $toggleDesiredTop -Control $togglePanel
    }
    if ($buttonGroup) {
        $buttonGroup.Top = Get-DanewClampedTop -DesiredTop $buttonDesiredTop -Control $buttonGroup
    }
    if ($technicalDetailsGroup) {
        if ($script:TechnicalDetailsVisible) {
            Set-DanewTechnicalDetailsDockLayout
        }
        else {
            $technicalDetailsGroup.Top = 96
        }
    }
    if ($form) {
        $form.AutoScrollMinSize = if ($Visible) {
            New-Object System.Drawing.Size(900, 720)
        } else {
            New-Object System.Drawing.Size(900, 560)
        }
    }
}

function Show-DanewSecondaryPanelDialog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,
        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.Control]$Panel,
        [int]$Width = 900,
        [int]$Height = 330
    )

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = Convert-DanewUiText -Text ('Outil de diagnostic SAV Danew - ' + $Title)
    $dialog.StartPosition = 'CenterParent'
    $screenW = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Width
    $screenH = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Height
    $dlgW = [Math]::Min($Width, [int]($screenW * 0.90))
    $dlgH = [Math]::Min($Height, [int]($screenH * 0.70))
    $dialog.ClientSize = New-Object System.Drawing.Size($dlgW, $dlgH)
    $dialog.MinimumSize = New-Object System.Drawing.Size([Math]::Min($Width, 640), [Math]::Min($Height, 300))
    $dialog.BackColor = [System.Drawing.Color]::FromArgb(243, 246, 252)
    $dialog.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $dialog.TopMost = $true

    $iconPath = Join-Path $RootPath 'Assets_danew\danew_brand_line_blue.ico'
    if (Test-Path -Path $iconPath) {
        try {
            $dialog.Icon = New-Object System.Drawing.Icon($iconPath)
        }
        catch {
        }
    }

    if ($Panel.Parent) {
        $Panel.Parent.Controls.Remove($Panel)
    }

    $Panel.Left = 12
    $Panel.Top = 12
    $Panel.Width = $dlgW - 24
    $Panel.Height = $dlgH - 24
    $Panel.Anchor = 'Top,Bottom,Left,Right'
    $Panel.Visible = $true

    [void]$dialog.Controls.Add($Panel)
    try {
        [void]$dialog.ShowDialog($form)
    }
    finally {
        [void]$dialog.Controls.Remove($Panel)
        $Panel.Visible = $false
        $dialog.Dispose()
    }
}

function Get-DanewObjectValue {
    param(
        [AllowNull()]
        [object]$Object,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [AllowNull()]
        [object]$Default = ''
    )

    if ($null -eq $Object) {
        return $Default
    }

    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) {
        return $prop.Value
    }

    return $Default
}

function Get-DanewReportJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $path = Join-Path ([string]$config.reports_path) $Name
    if (-not (Test-Path -Path $path)) {
        return $null
    }

    try {
        return (Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 50)
    }
    catch {
        return $null
    }
}

function Get-DanewFirstExistingReportPath {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Names,
        [AllowNull()]
        [object]$MinLastWriteTime = $null
    )

    $resolvedMinTime = $null
    if ($null -ne $MinLastWriteTime) {
        $rawMinTime = [string]$MinLastWriteTime
        if (-not [string]::IsNullOrWhiteSpace($rawMinTime)) {
            try {
                $resolvedMinTime = [datetime]$MinLastWriteTime
            }
            catch {
                $resolvedMinTime = $null
            }
        }
    }

    foreach ($root in @(Get-DanewReportSearchRoots)) {
        foreach ($name in @($Names)) {
            $path = Join-Path $root $name
            if (Test-Path -Path $path -ErrorAction SilentlyContinue) {
                if ($null -ne $resolvedMinTime) {
                    try {
                        $item = Get-Item -Path $path -ErrorAction Stop
                        if ($item.LastWriteTime -lt $resolvedMinTime) {
                            continue
                        }
                    }
                    catch {
                        continue
                    }
                }
                return $path
            }
        }
    }

    return ''
}

function Get-DanewAvailableReportPath {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Names,
        [AllowNull()]
        [object]$MinLastWriteTime = $null
    )

    $resolvedMinTime = $null
    if ($null -ne $MinLastWriteTime) {
        $rawMinTime = [string]$MinLastWriteTime
        if (-not [string]::IsNullOrWhiteSpace($rawMinTime)) {
            try {
                $resolvedMinTime = [datetime]$MinLastWriteTime
            }
            catch {
                $resolvedMinTime = $null
            }
        }
    }

    if ($null -ne $resolvedMinTime) {
        $path = Get-DanewFirstExistingReportPath -Names $Names -MinLastWriteTime $resolvedMinTime
    }
    else {
        $path = Get-DanewFirstExistingReportPath -Names $Names
    }
    if (-not [string]::IsNullOrWhiteSpace($path)) {
        return $path
    }

    return (Get-DanewFirstExistingReportPath -Names $Names)
}

function Test-DanewDriveLetterAvailable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DriveLetter
    )

    if ([string]::IsNullOrWhiteSpace($DriveLetter)) {
        return $false
    }

    try {
        $drive = Get-PSDrive -Name $DriveLetter -PSProvider FileSystem -ErrorAction SilentlyContinue
        return ($null -ne $drive)
    }
    catch {
        return $false
    }
}

function Get-DanewPortableBrowserPath {
    $candidates = New-Object System.Collections.ArrayList

    function Add-DanewBrowserCandidate {
        param([string]$Path)
        if ([string]::IsNullOrWhiteSpace($Path)) {
            return
        }

        if (-not @($candidates | Where-Object { $_ -ieq $Path })) {
            [void]$candidates.Add($Path)
        }
    }

    foreach ($exeName in @('chromium.exe', 'chrome.exe', 'msedge.exe', 'FirefoxPortable.exe', 'firefox.exe')) {
        Add-DanewBrowserCandidate -Path (Join-Path $RootPath ('tools\browser\' + $exeName))
    }

    try {
        $dataVolumes = @(Get-Volume -FileSystemLabel 'DANEW_DATA' -ErrorAction SilentlyContinue)
        foreach ($volume in $dataVolumes) {
            if (-not [string]::IsNullOrWhiteSpace([string]$volume.DriveLetter)) {
                $root = [string]$volume.DriveLetter + ':\'
                foreach ($exeName in @('chromium.exe', 'chrome.exe', 'msedge.exe', 'FirefoxPortable.exe', 'firefox.exe')) {
                    Add-DanewBrowserCandidate -Path (Join-Path $root ('tools\browser\' + $exeName))
                }
            }
        }
    }
    catch {
    }

    foreach ($drive in @('E', 'D', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'Y', 'Z')) {
        if (-not (Test-DanewDriveLetterAvailable -DriveLetter $drive)) {
            continue
        }

        $root = $drive + ':\'
        foreach ($exeName in @('chromium.exe', 'chrome.exe', 'msedge.exe', 'FirefoxPortable.exe', 'firefox.exe')) {
            Add-DanewBrowserCandidate -Path (Join-Path $root ('tools\browser\' + $exeName))
        }
    }

    foreach ($candidate in @($candidates)) {
        if (Test-Path -Path $candidate -ErrorAction SilentlyContinue) {
            return $candidate
        }
    }

    return ''
}

function Get-DanewPortableBrowserCandidates {
    $paths = New-Object System.Collections.ArrayList

    function Add-DanewPortableBrowserCandidate {
        param([string]$Path)
        if ([string]::IsNullOrWhiteSpace($Path)) {
            return
        }
        if ((Test-Path -Path $Path -ErrorAction SilentlyContinue) -and (-not @($paths | Where-Object { $_ -ieq $Path }))) {
            [void]$paths.Add($Path)
        }
    }

    $first = Get-DanewPortableBrowserPath
    Add-DanewPortableBrowserCandidate -Path $first

    $roots = New-Object System.Collections.ArrayList
    [void]$roots.Add($RootPath)
    try {
        $dataVolumes = @(Get-Volume -FileSystemLabel 'DANEW_DATA' -ErrorAction SilentlyContinue)
        foreach ($volume in $dataVolumes) {
            if (-not [string]::IsNullOrWhiteSpace([string]$volume.DriveLetter)) {
                [void]$roots.Add([string]$volume.DriveLetter + ':\')
            }
        }
    }
    catch {
    }
    foreach ($drive in @('E', 'D', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'Y', 'Z')) {
        if (Test-DanewDriveLetterAvailable -DriveLetter $drive) {
            [void]$roots.Add($drive + ':\')
        }
    }

    foreach ($root in @($roots)) {
        foreach ($exeName in @('chromium.exe', 'chrome.exe', 'msedge.exe', 'FirefoxPortable.exe', 'firefox.exe')) {
            Add-DanewPortableBrowserCandidate -Path (Join-Path ([string]$root) ('tools\browser\' + $exeName))
        }
    }

    return @($paths)
}

function Get-DanewBrowserUserDataDirectory {
    try {
        $base = [string]$config.reports_path
        if ([string]::IsNullOrWhiteSpace($base)) {
            $base = Join-Path $RootPath 'reports'
        }
        $dir = Join-Path $base 'browser-profile'
        if (-not (Test-Path -Path $dir -ErrorAction SilentlyContinue)) {
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
        }
        return $dir
    }
    catch {
        return ''
    }
}

function Get-DanewBrowserLaunchArguments {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BrowserPath,
        [Parameter(Mandatory = $true)]
        [string]$TargetPath
    )

    $exe = [System.IO.Path]::GetFileName($BrowserPath).ToLowerInvariant()
    if ($exe -like 'firefox*') {
        return @('-new-window', $TargetPath)
    }

    $profileDir = Get-DanewBrowserUserDataDirectory
    $args = @(
        '--no-first-run',
        '--no-default-browser-check',
        '--disable-background-networking',
        '--disable-component-update',
        '--disable-crash-reporter',
        '--disable-breakpad',
        '--disable-crashpad',
        '--disable-features=Crashpad',
        '--disable-gpu',
        '--allow-file-access-from-files'
    )
    if (-not [string]::IsNullOrWhiteSpace($profileDir)) {
        $args += ('--user-data-dir=' + $profileDir)
    }
    $args += $TargetPath
    return @($args)
}

function Start-DanewPortableBrowser {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BrowserPath,
        [Parameter(Mandatory = $true)]
        [string]$TargetPath
    )

    $workingDir = Split-Path -Parent $BrowserPath
    $args = @(Get-DanewBrowserLaunchArguments -BrowserPath $BrowserPath -TargetPath $TargetPath)
    Write-DanewReportOpeningTrace -Status 'browser-start-before' -Path $TargetPath -BrowserPath $BrowserPath -Arguments $args -Message ('working_dir=' + $workingDir)
    try {
        $proc = Start-Process -FilePath $BrowserPath -ArgumentList $args -WorkingDirectory $workingDir -PassThru -ErrorAction Stop
        Write-DanewReportOpeningTrace -Status 'browser-start-after' -Path $TargetPath -BrowserPath $BrowserPath -Arguments $args -Message 'Start-Process returned a process handle.' -Process $proc
    }
    catch {
        Write-DanewReportOpeningTrace -Status 'browser-start-error' -Path $TargetPath -BrowserPath $BrowserPath -Arguments $args -Message $_.Exception.Message
        throw
    }
    if (-not $proc) {
        Write-DanewReportOpeningTrace -Status 'browser-start-no-handle' -Path $TargetPath -BrowserPath $BrowserPath -Arguments $args -Message 'Start-Process returned no process handle.'
        throw 'Navigateur lance sans handle de processus.'
    }
    $exe = [System.IO.Path]::GetFileName($BrowserPath).ToLowerInvariant()
    if ($exe -like 'firefox*') {
        Write-DanewReportOpeningTrace -Status 'browser-start-firefox-delegated' -Path $TargetPath -BrowserPath $BrowserPath -Arguments $args -Message 'Firefox launch delegated; exit check skipped.' -Process $proc
        return $true
    }

    $elapsedMs = 0
    while ($elapsedMs -lt 8000) {
        Start-Sleep -Milliseconds 500
        $elapsedMs += 500
        if ($proc -and -not $proc.HasExited -and $elapsedMs -ge 2000) {
            Write-DanewReportOpeningTrace -Status 'browser-start-alive' -Path $TargetPath -BrowserPath $BrowserPath -Arguments $args -Message ('alive_after_ms=' + [string]$elapsedMs) -Process $proc
            return $true
        }
        if ($proc -and $proc.HasExited) {
            break
        }
    }

    if ($proc -and $proc.HasExited -and $proc.ExitCode -eq 0) {
        Write-DanewReportOpeningTrace -Status 'browser-start-exit-zero' -Path $TargetPath -BrowserPath $BrowserPath -Arguments $args -Message ('exited_after_ms=' + [string]$elapsedMs) -Process $proc
        return $true
    }

    if ($proc -and $proc.HasExited) {
        Write-DanewReportOpeningTrace -Status 'browser-start-exit-nonzero' -Path $TargetPath -BrowserPath $BrowserPath -Arguments $args -Message ('exited_after_ms=' + [string]$elapsedMs) -Process $proc
        throw ('Navigateur ferme immediatement avec code ' + [string]$proc.ExitCode)
    }
    Write-DanewReportOpeningTrace -Status 'browser-start-timeout-alive' -Path $TargetPath -BrowserPath $BrowserPath -Arguments $args -Message ('alive_after_ms=' + [string]$elapsedMs) -Process $proc
    return $true
}

function Test-DanewPortableBrowserOperational {
    param(
        [AllowEmptyString()]
        [string]$BrowserPath
    )

    if ([string]::IsNullOrWhiteSpace($BrowserPath)) {
        return $false
    }

    if ($script:BrowserOperationalCachePath -ieq $BrowserPath) {
        return [bool]$script:BrowserOperationalCacheResult
    }

    $ok = $false
    try {
        if (-not (Test-Path -Path $BrowserPath -ErrorAction SilentlyContinue)) {
            $ok = $false
        }
        else {
            $workingDir = Split-Path -Parent $BrowserPath
            if ([string]::IsNullOrWhiteSpace($workingDir) -or -not (Test-Path -Path $workingDir -ErrorAction SilentlyContinue)) {
                $ok = $false
            }
            else {
                $args = @(Get-DanewBrowserLaunchArguments -BrowserPath $BrowserPath -TargetPath 'about:blank')
                $proc = Start-Process -FilePath $BrowserPath -ArgumentList $args -WorkingDirectory $workingDir -PassThru -WindowStyle Hidden -ErrorAction Stop
                if ($proc) {
                    $elapsedMs = 0
                    while ($elapsedMs -lt 8000) {
                        Start-Sleep -Milliseconds 500
                        $elapsedMs += 500
                        if ($proc.HasExited) {
                            $ok = ($proc.ExitCode -eq 0)
                            break
                        }
                        if ($elapsedMs -ge 2000) {
                            $ok = $true
                            break
                        }
                    }

                    if (-not $proc.HasExited) {
                        try {
                            $proc.Kill()
                        }
                        catch {
                        }
                    }
                }
            }
        }
    }
    catch {
        $ok = $false
    }

    $script:BrowserOperationalCachePath = $BrowserPath
    $script:BrowserOperationalCacheResult = $ok
    return $ok
}

function Convert-DanewPathToFileUri {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        return ([System.Uri]::new($Path)).AbsoluteUri
    }
    catch {
        return $Path
    }
}

function Write-DanewReportOpeningTrace {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Status,
        [string]$Title = '',
        [string]$Path = '',
        [string]$BrowserPath = '',
        [string[]]$Arguments = @(),
        [string]$Message = '',
        [AllowNull()]
        [object]$Process = $null
    )

    try {
        $traceRoot = [string]$config.reports_path
        if ([string]::IsNullOrWhiteSpace($traceRoot)) {
            $traceRoot = Join-Path $RootPath 'reports'
        }
        if (-not (Test-Path -Path $traceRoot -ErrorAction SilentlyContinue)) {
            New-Item -Path $traceRoot -ItemType Directory -Force | Out-Null
        }

        $tracePath = Join-Path $traceRoot 'report-opening.log'
        $parts = @(
            (Get-Date).ToString('s'),
            ('status=' + $Status),
            ('title=' + $Title),
            ('path=' + $Path),
            ('browser=' + $BrowserPath),
            ('args=' + ($Arguments -join ' ')),
            ('message=' + $Message)
        )
        if ($Process) {
            try {
                $parts += ('pid=' + [string]$Process.Id)
                $parts += ('has_exited=' + [string]$Process.HasExited)
                if ($Process.HasExited) {
                    $parts += ('exit_code=' + [string]$Process.ExitCode)
                }
            }
            catch {
                $parts += ('process_error=' + $_.Exception.Message)
            }
        }
        Add-Content -Path $tracePath -Value ($parts -join ' | ') -Encoding UTF8
    }
    catch {
    }

    try {
        $data = [ordered]@{
            path = $Path
            browser_path = $BrowserPath
            arguments = ($Arguments -join ' ')
        }

        if ($Process) {
            try {
                $data.process_id = [int]$Process.Id
                $data.has_exited = [bool]$Process.HasExited
                if ($Process.HasExited) {
                    $data.exit_code = [int]$Process.ExitCode
                }
            }
            catch {
                $data.process_error = $_.Exception.Message
            }
        }

        [void](Write-DanewLauncherActionLog -Config $config -Action 'open-report' -Status $Status -Message $Message -Data ([pscustomobject]$data))
    }
    catch {
    }
}

function Test-DanewLikelyWinPE {
    try {
        $systemRoot = [string]$env:SystemRoot
        if ($systemRoot -like 'X:\*') {
            return $true
        }
    }
    catch {
    }
    return $false
}

function Show-DanewHtmlFallbackNotice {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,
        [Parameter(Mandatory = $true)]
        [string]$Reason
    )

    [System.Windows.Forms.MessageBox]::Show(
        ('Le rapport HTML ne peut pas etre ouvert dans cet environnement.' + [Environment]::NewLine + [Environment]::NewLine +
            'Raison : ' + $Reason + [Environment]::NewLine +
            'Ouverture du fallback texte (TXT/CSV/JSON).'),
        $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
}

function Show-DanewFallbackReportText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,
        [Parameter(Mandatory = $true)]
        [string]$Content,
        [AllowEmptyString()]
        [string]$FilePath = ''
    )

    [System.Windows.Forms.Application]::EnableVisualStyles()

    $viewer = New-Object System.Windows.Forms.Form
    $viewer.Text = $Title
    $viewer.StartPosition = 'CenterParent'
    $viewer.ClientSize = New-Object System.Drawing.Size(900, 620)
    $viewer.MinimumSize = New-Object System.Drawing.Size(720, 480)
    $viewer.TopMost = $true
    $viewer.BringToFront()
    $viewer.BackColor = [System.Drawing.Color]::White
    $viewer.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $textBox = New-Object System.Windows.Forms.TextBox
    if (-not $textBox) {
        [System.Windows.Forms.MessageBox]::Show(
            'TextBox creation failed. WinPE fallback unavailable.',
            'Fallback Error',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
        return
    }

    $textBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $textBox.Multiline = $true
    $textBox.ReadOnly = $true
    $textBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
    $textBox.WordWrap = $false
    $textBox.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $textBox.BackColor = [System.Drawing.Color]::FromArgb(248, 250, 252)
    $textBox.ForeColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
    $textBox.Font = New-Object System.Drawing.Font('Consolas', 10)
    $textBox.Text = $Content

    $copyButton = New-Object System.Windows.Forms.Button
    $copyButton.Text = 'Copier tout'
    $copyButton.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $copyButton.Height = 32
    $copyButton.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $copyButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $copyButton.BackColor = [System.Drawing.Color]::FromArgb(15, 118, 110)
    $copyButton.ForeColor = [System.Drawing.Color]::White
    $copyButton.Add_Click({ [System.Windows.Forms.Clipboard]::SetText($textBox.Text) })
    [void]$viewer.Controls.Add($copyButton)
    [void]$viewer.Controls.Add($textBox)

    $reportDir = ''
    try {
        if ($config -and $config.PSObject.Properties['reports_path']) {
            $reportDir = [string]$config.reports_path
        }
    }
    catch {
        $reportDir = ''
    }
    if ([string]::IsNullOrWhiteSpace($reportDir)) {
        $reportDir = Join-Path $RootPath 'reports'
    }

    try {
        # Force window visibility in WinPE before modal show.
        $viewer.TopMost = $true
        $viewer.BringToFront()
        [System.Windows.Forms.Application]::DoEvents()

        $dialogResult = [System.Windows.Forms.DialogResult]::None
        if ($form) {
            $dialogResult = $viewer.ShowDialog($form)
        }
        else {
            $dialogResult = $viewer.ShowDialog()
        }

        if ($dialogResult -eq [System.Windows.Forms.DialogResult]::None) {
            $diagnostic = 'Text viewer ShowDialog() returned None. Trying notepad fallback.'
            Write-DanewReportOpeningTrace -Status 'fallback-textbox-dialogresult-none' -Title $Title -Path $FilePath -Message $diagnostic
            # Try notepad.exe as last resort (always available in WinPE X:\Windows\System32)
            $notepadOpened = $false
            foreach ($notepadPath in @("$env:SystemRoot\System32\notepad.exe", 'X:\Windows\System32\notepad.exe', 'C:\Windows\System32\notepad.exe')) {
                if (Test-Path -Path $notepadPath -ErrorAction SilentlyContinue) {
                    $targetFile = $FilePath
                    if ([string]::IsNullOrWhiteSpace($targetFile) -or -not (Test-Path $targetFile)) {
                        # Write content to temp file
                        $targetFile = Join-Path $env:TEMP ('danew-report-' + [System.IO.Path]::GetRandomFileName() + '.txt')
                        try { [System.IO.File]::WriteAllText($targetFile, $Content, [System.Text.Encoding]::UTF8) } catch {}
                    }
                    if (Test-Path -Path $targetFile -ErrorAction SilentlyContinue) {
                        try {
                            Start-Process -FilePath $notepadPath -ArgumentList @($targetFile) -ErrorAction Stop | Out-Null
                            Write-DanewReportOpeningTrace -Status 'fallback-notepad-ok' -Title $Title -Path $targetFile -BrowserPath $notepadPath -Message 'Notepad opened as WinPE text viewer fallback.'
                            $notepadOpened = $true
                            break
                        } catch {}
                    }
                }
            }
            if (-not $notepadOpened) {
                # Last resort: MessageBox with truncated preview
                $preview = if ($Content.Length -gt 1800) { $Content.Substring(0, 1800) + "`n... (tronque)" } else { $Content }
                [System.Windows.Forms.MessageBox]::Show($preview, $Title, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            }
        }
    }
    catch {
        Write-DanewReportOpeningTrace -Status 'fallback-textbox-error' -Title $Title -Path '' -Message $_.Exception.Message
        [System.Windows.Forms.MessageBox]::Show(
            ('Text viewer display error: ' + $_.Exception.Message),
            'Fallback Display Error',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
    finally {
        $viewer.Dispose()
    }
}

function Open-DanewFallbackReport {
    param(
        [AllowEmptyString()]
        [string]$ReportBaseName,
        [object]$Config = $null
    )

    $effectiveConfig = $Config
    if ($null -eq $effectiveConfig) {
        $effectiveConfig = $config
    }

    $reportsPath = ''
    try {
        $reportsPath = [string]$effectiveConfig.reports_path
    }
    catch {
        $reportsPath = ''
    }
    if ([string]::IsNullOrWhiteSpace($reportsPath)) {
        $reportsPath = Join-Path $RootPath 'reports'
    }

    $baseName = [string]$ReportBaseName
    if ([string]::IsNullOrWhiteSpace($baseName)) {
        $baseName = 'rapport'
    }
    Write-DanewReportOpeningTrace -Status 'fallback-enter' -Title ('Rapport - ' + $baseName) -Path $reportsPath -Message 'Open-DanewFallbackReport entered.'

    # REPORTS_INDEX fallback : construire une liste lisible des rapports disponibles
    $isIndex = $baseName -match '(?i)REPORTS_INDEX|reports-index'
    if ($isIndex) {
        $indexLines = New-Object System.Collections.ArrayList
        [void]$indexLines.Add('=== RAPPORTS DANEW DISPONIBLES ===')
        [void]$indexLines.Add('Dossier: ' + $reportsPath)
        [void]$indexLines.Add('')
        $reportDefs = @(
            @{ Name='Diagnostic SAV'; Html='sav-diagnostic-report.html'; Txt='sav-diagnostic-report.txt' },
            @{ Name='Chronologie';    Html='timeline-raw.html';          Txt='timeline-raw.txt' },
            @{ Name='Evenements EVTX';Html='evtx-events.html';           Txt='evtx-events.txt' },
            @{ Name='EVTX par fichier';Html='evtx-by-file.html';         Txt='evtx-by-file.txt' }
        )
        $i = 1
        foreach ($rep in $reportDefs) {
            $htmlExists = Test-Path (Join-Path $reportsPath $rep.Html) -ErrorAction SilentlyContinue
            $txtExists  = Test-Path (Join-Path $reportsPath $rep.Txt) -ErrorAction SilentlyContinue
            $htmlMark = if ($htmlExists) { '[HTML OK]' } else { '[HTML manquant]' }
            $txtMark  = if ($txtExists)  { '[TXT OK]' }  else { '[TXT manquant]' }
            [void]$indexLines.Add("$i. $($rep.Name)  $htmlMark  $txtMark")
            [void]$indexLines.Add("   HTML: $($rep.Html)")
            [void]$indexLines.Add("   TXT:  $($rep.Txt)")
            [void]$indexLines.Add('')
            $i++
        }
        [void]$indexLines.Add('Utilisez le bouton [RAPPORT TXT (Fallback)] pour acceder aux fichiers TXT.')
        $indexContent = $indexLines -join [Environment]::NewLine
        Write-DanewReportOpeningTrace -Status 'fallback-index-list' -Title ('Rapport - ' + $baseName) -Path $reportsPath -Message 'Showing dynamic reports index list.'

        # Essai notepad systeme en premier (plus fiable que les controles riches en WinPE)
        $indexTxtPath = Join-Path $reportsPath ($baseName + '.txt')
        $openedInNotepad = $false
        foreach ($notepadPath in @("$env:SystemRoot\System32\notepad.exe", 'X:\Windows\System32\notepad.exe', 'C:\Windows\System32\notepad.exe')) {
            if (Test-Path -Path $notepadPath -ErrorAction SilentlyContinue) {
                $targetTxt = if (Test-Path $indexTxtPath) { $indexTxtPath } else {
                    $tmp = Join-Path $env:TEMP 'danew-index.txt'
                    try { [System.IO.File]::WriteAllText($tmp, $indexContent, [System.Text.Encoding]::UTF8) } catch {}
                    $tmp
                }
                if (Test-Path $targetTxt -ErrorAction SilentlyContinue) {
                    try {
                        Start-Process -FilePath $notepadPath -ArgumentList @($targetTxt) -ErrorAction Stop | Out-Null
                        Write-DanewReportOpeningTrace -Status 'fallback-index-notepad-ok' -Title ('Rapport - ' + $baseName) -Path $targetTxt -BrowserPath $notepadPath -Message 'Notepad opened for index fallback.'
                        $openedInNotepad = $true
                        break
                    } catch {}
                }
            }
        }
        if (-not $openedInNotepad) {
            Show-DanewFallbackReportText -Title 'Index des rapports' -Content $indexContent -FilePath $indexTxtPath
        }
        return $true
    }

    foreach ($extension in @('.txt', '.csv')) {
        $candidate = ''
        try {
            $candidate = Join-Path $reportsPath ($baseName + $extension)
            if (Test-Path -Path $candidate -ErrorAction SilentlyContinue) {
                Write-DanewReportOpeningTrace -Status 'fallback-file-found' -Title ('Rapport - ' + $baseName) -Path $candidate -Message 'TXT/CSV fallback found.'

                # Essai Notepad++ portable
                try {
                    $npp = Join-Path $RootPath 'tools\notepad++\notepad++.exe'
                    if (Test-Path -Path $npp -ErrorAction SilentlyContinue) {
                        Write-DanewReportOpeningTrace -Status 'fallback-notepadpp-try' -Title ('Rapport - ' + $baseName) -Path $candidate -BrowserPath $npp -Message 'Trying Notepad++ portable fallback.'
                        Start-Process -FilePath $npp -ArgumentList @($candidate) -ErrorAction Stop | Out-Null
                        Write-DanewReportOpeningTrace -Status 'fallback-notepadpp-ok' -Title ('Rapport - ' + $baseName) -Path $candidate -BrowserPath $npp -Message 'Notepad++ portable returned success.'
                        return $true
                    }
                }
                catch {
                    Write-DanewReportOpeningTrace -Status 'fallback-notepadpp-error' -Title ('Rapport - ' + $baseName) -Path $candidate -Message $_.Exception.Message
                }

                # Essai notepad systeme avant viewer integre (plus robuste en WinPE)
                $notepadLaunched = $false
                foreach ($notepadPath in @("$env:SystemRoot\System32\notepad.exe", 'X:\Windows\System32\notepad.exe', 'C:\Windows\System32\notepad.exe')) {
                    if (Test-Path -Path $notepadPath -ErrorAction SilentlyContinue) {
                        try {
                            Start-Process -FilePath $notepadPath -ArgumentList @($candidate) -ErrorAction Stop | Out-Null
                            Write-DanewReportOpeningTrace -Status 'fallback-notepad-system-ok' -Title ('Rapport - ' + $baseName) -Path $candidate -BrowserPath $notepadPath -Message 'System notepad opened TXT fallback.'
                            $notepadLaunched = $true
                            break
                        } catch {}
                    }
                }
                if ($notepadLaunched) { return $true }

                # Derniere option : viewer texte WinForms
                $content = Get-Content -Path $candidate -Raw -Encoding UTF8 -ErrorAction Stop
                Write-DanewReportOpeningTrace -Status 'fallback-textbox-file' -Title ('Rapport - ' + $baseName) -Path $candidate -Message 'Showing TXT/CSV fallback in native text viewer.'
                Show-DanewFallbackReportText -Title ('Rapport - ' + $baseName) -Content $content -FilePath $candidate
                return $true
            }
        }
        catch {
            Write-DanewReportOpeningTrace -Status 'fallback-file-error' -Title ('Rapport - ' + $baseName) -Path $candidate -Message $_.Exception.Message
        }
    }

    $snapshotPath = ''
    try {
        $snapshotPath = Join-Path $reportsPath 'gui-status-snapshot.json'
        if (Test-Path -Path $snapshotPath -ErrorAction SilentlyContinue) {
            $snapshot = Get-Content -Path $snapshotPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $lines = New-Object System.Collections.ArrayList
            foreach ($property in @($snapshot.PSObject.Properties)) {
                $value = $property.Value
                if ($null -eq $value) {
                    $valueText = ''
                }
                elseif ($value -is [System.Array]) {
                    $valueText = (@($value) -join ', ')
                }
                elseif ($value -is [System.Management.Automation.PSCustomObject]) {
                    $valueText = ($value | ConvertTo-Json -Depth 8 -Compress)
                }
                else {
                    $valueText = [string]$value
                }
                [void]$lines.Add(([string]$property.Name + ': ' + $valueText))
            }
            Write-DanewReportOpeningTrace -Status 'fallback-textbox-snapshot' -Title ('Rapport - ' + $baseName) -Path $snapshotPath -Message 'Showing gui-status-snapshot.json fallback in native text viewer.'
            Show-DanewFallbackReportText -Title ('Rapport - ' + $baseName) -Content (@($lines) -join [Environment]::NewLine)
            return $true
        }
    }
    catch {
        Write-DanewReportOpeningTrace -Status 'fallback-snapshot-error' -Title ('Rapport - ' + $baseName) -Path $snapshotPath -Message $_.Exception.Message
    }

    $message = 'Navigateur HTML non disponible et aucun fallback TXT/CSV lisible trouve.' + [Environment]::NewLine +
        'Rapport demande: ' + $baseName + [Environment]::NewLine +
        'Dossier rapports: ' + $reportsPath + [Environment]::NewLine +
        'Consultez les fichiers TXT, CSV ou JSON dans le dossier reports.'
    Write-DanewReportOpeningTrace -Status 'fallback-none' -Title ('Rapport - ' + $baseName) -Path $reportsPath -Message $message
    [System.Windows.Forms.MessageBox]::Show(
        $message,
        'Rapport indisponible',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    ) | Out-Null
    return $false
}

function Get-DanewReportSearchRoots {
    $roots = New-Object System.Collections.ArrayList

    function Add-DanewReportRoot {
        param([string]$Path)
        if ([string]::IsNullOrWhiteSpace($Path)) {
            return
        }

        try {
            $full = [System.IO.Path]::GetFullPath($Path)
        }
        catch {
            $full = $Path
        }

        if ((Test-Path -Path $full -ErrorAction SilentlyContinue) -and (-not @($roots | Where-Object { $_ -ieq $full }))) {
            [void]$roots.Add($full)
        }
    }

    Add-DanewReportRoot -Path ([string]$config.reports_path)

    try {
        $dataVolumes = @(Get-Volume -FileSystemLabel 'DANEW_DATA' -ErrorAction SilentlyContinue)
        foreach ($volume in $dataVolumes) {
            if (-not [string]::IsNullOrWhiteSpace([string]$volume.DriveLetter)) {
                Add-DanewReportRoot -Path ([string]$volume.DriveLetter + ':\reports')
            }
        }
    }
    catch {
    }

    foreach ($drive in @('E', 'D', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'Y', 'Z')) {
        if (-not (Test-DanewDriveLetterAvailable -DriveLetter $drive)) {
            continue
        }

        Add-DanewReportRoot -Path ($drive + ':\reports')
    }

    return @($roots)
}

function Get-DanewTextReportCandidates {
    $results = New-Object System.Collections.ArrayList
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $extensions = @('*.txt', '*.csv', '*.json')

    foreach ($root in @(Get-DanewReportSearchRoots)) {
        foreach ($pattern in $extensions) {
            foreach ($file in @(Get-ChildItem -Path $root -Filter $pattern -File -ErrorAction SilentlyContinue)) {
                if ($seen.Add($file.FullName)) {
                    [void]$results.Add([pscustomobject]@{
                        display = ($file.Name + '   [' + $file.LastWriteTime.ToString('yyyy-MM-dd HH:mm') + ']')
                        path = $file.FullName
                        name = $file.Name
                        updated = $file.LastWriteTime
                    })
                }
            }
        }
    }

    return @($results | Sort-Object -Property @{ Expression = 'updated'; Descending = $true }, @{ Expression = 'name'; Descending = $false })
}

function Open-DanewTextReportCandidate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -Path $Path -PathType Leaf -ErrorAction SilentlyContinue)) {
        [System.Windows.Forms.MessageBox]::Show('Rapport texte introuvable.', 'Rapports TXT', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return $false
    }

    $extension = [System.IO.Path]::GetExtension($Path)
    if ($extension -and $extension.ToLowerInvariant() -in @('.csv', '.json')) {
        return (Show-DanewNativeReportViewer -Path $Path -Title ('Rapport - ' + [System.IO.Path]::GetFileName($Path)))
    }

    try {
        $content = Get-Content -Path $Path -Raw -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        try {
            $content = Get-Content -Path $Path -Raw -ErrorAction Stop
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(('Impossible de lire le rapport:' + [Environment]::NewLine + $Path + [Environment]::NewLine + $_.Exception.Message), 'Rapports TXT', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return $false
        }
    }

    Show-DanewFallbackReportText -Title ('Rapport texte - ' + [System.IO.Path]::GetFileName($Path)) -Content $content
    return $true
}

function ConvertTo-DanewReportCellText {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return ''
    }
    if ($Value -is [System.Array]) {
        $parts = New-Object System.Collections.ArrayList
        foreach ($item in @($Value)) {
            [void]$parts.Add((ConvertTo-DanewReportCellText -Value $item))
        }
        return (@($parts) -join '; ')
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        try {
            return ($Value | ConvertTo-Json -Depth 8 -Compress)
        }
        catch {
            return [string]$Value
        }
    }
    return [string]$Value
}

function ConvertTo-DanewReportDataTable {
    param(
        [AllowNull()]
        [object[]]$Rows
    )

    $table = New-Object System.Data.DataTable
    $columns = New-Object System.Collections.ArrayList
    foreach ($row in @($Rows)) {
        if ($null -eq $row) {
            continue
        }
        if ($row -is [System.Management.Automation.PSCustomObject]) {
            foreach ($property in @($row.PSObject.Properties)) {
                if (-not @($columns | Where-Object { $_ -ieq $property.Name })) {
                    [void]$columns.Add([string]$property.Name)
                }
            }
        }
        else {
            if (-not @($columns | Where-Object { $_ -ieq 'Valeur' })) {
                [void]$columns.Add('Valeur')
            }
        }
    }

    if (@($columns).Count -eq 0) {
        [void]$columns.Add('Information')
    }

    foreach ($columnName in @($columns)) {
        [void]$table.Columns.Add([string]$columnName, [string])
    }
    [void]$table.Columns.Add('_search', [string])

    foreach ($row in @($Rows)) {
        $dataRow = $table.NewRow()
        $searchParts = New-Object System.Collections.ArrayList
        foreach ($columnName in @($columns)) {
            $value = ''
            if ($row -is [System.Management.Automation.PSCustomObject]) {
                $property = $row.PSObject.Properties[[string]$columnName]
                if ($null -ne $property) {
                    $value = ConvertTo-DanewReportCellText -Value $property.Value
                }
            }
            else {
                $value = ConvertTo-DanewReportCellText -Value $row
            }
            $dataRow[[string]$columnName] = $value
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                [void]$searchParts.Add($value)
            }
        }
        $dataRow['_search'] = (@($searchParts) -join ' ')
        [void]$table.Rows.Add($dataRow)
    }

    if ($table.Rows.Count -eq 0) {
        $dataRow = $table.NewRow()
        $dataRow[[string]$columns[0]] = 'Aucune ligne a afficher.'
        $dataRow['_search'] = 'Aucune ligne a afficher.'
        [void]$table.Rows.Add($dataRow)
    }

    return $table
}

function Get-DanewJsonReportRows {
    param(
        [Parameter(Mandatory = $true)]
        [object]$JsonObject
    )

    if ($JsonObject -is [System.Array]) {
        return @($JsonObject)
    }

    foreach ($propertyName in @('events', 'reports', 'causes', 'items', 'records', 'rows', 'files')) {
        $property = $JsonObject.PSObject.Properties[$propertyName]
        if ($null -ne $property) {
            $value = $property.Value
            if ($value -is [System.Array]) {
                return @($value)
            }
        }
    }

    $rows = New-Object System.Collections.ArrayList
    foreach ($property in @($JsonObject.PSObject.Properties)) {
        [void]$rows.Add([pscustomobject]@{
            champ = [string]$property.Name
            valeur = ConvertTo-DanewReportCellText -Value $property.Value
        })
    }
    return @($rows)
}

function Show-DanewReportGrid {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,
        [Parameter(Mandatory = $true)]
        [object[]]$Rows,
        [AllowEmptyString()]
        [string]$SourcePath = ''
    )

    [System.Windows.Forms.Application]::EnableVisualStyles()

    $viewer = New-Object System.Windows.Forms.Form
    $viewer.Text = $Title
    $viewer.StartPosition = 'CenterParent'
    $viewer.ClientSize = New-Object System.Drawing.Size(1040, 640)
    $viewer.MinimumSize = New-Object System.Drawing.Size(780, 480)
    $viewer.BackColor = [System.Drawing.Color]::FromArgb(243, 246, 252)
    $viewer.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $viewer.TopMost = $true

    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = [System.Windows.Forms.DockStyle]::Top
    $header.Height = 76
    $header.BackColor = [System.Drawing.Color]::White

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Left = 14
    $titleLabel.Top = 10
    $titleLabel.Width = 720
    $titleLabel.Height = 24
    $titleLabel.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
    $titleLabel.Text = $Title

    $hintLabel = New-Object System.Windows.Forms.Label
    $hintLabel.Left = 14
    $hintLabel.Top = 38
    $hintLabel.Width = 720
    $hintLabel.Height = 18
    $hintLabel.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
    $hintLabel.Text = 'Recherche locale. Colonnes triables, redimensionnables et deplacables.'

    $searchBox = New-Object System.Windows.Forms.TextBox
    $searchBox.Left = 740
    $searchBox.Top = 14
    $searchBox.Width = 280
    $searchBox.Height = 28
    $searchBox.Anchor = 'Top,Right'

    $countLabel = New-Object System.Windows.Forms.Label
    $countLabel.Left = 740
    $countLabel.Top = 46
    $countLabel.Width = 280
    $countLabel.Height = 18
    $countLabel.Anchor = 'Top,Right'
    $countLabel.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock = [System.Windows.Forms.DockStyle]::Fill
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToOrderColumns = $true
    $grid.AllowUserToResizeColumns = $true
    $grid.AllowUserToResizeRows = $false
    $grid.ReadOnly = $true
    $grid.MultiSelect = $false
    $grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $grid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::None
    $grid.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
    $grid.RowHeadersVisible = $false
    $grid.BackgroundColor = [System.Drawing.Color]::White
    $grid.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $grid.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $grid.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $grid.DefaultCellStyle.WrapMode = [System.Windows.Forms.DataGridViewTriState]::False

    $footer = New-Object System.Windows.Forms.Panel
    $footer.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $footer.Height = 42
    $footer.BackColor = [System.Drawing.Color]::White

    $pathLabel = New-Object System.Windows.Forms.Label
    $pathLabel.Left = 14
    $pathLabel.Top = 12
    $pathLabel.Width = 620
    $pathLabel.Height = 18
    $pathLabel.Anchor = 'Left,Right,Bottom'
    $pathLabel.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
    $pathLabel.Text = $SourcePath

    $copyButton = New-Object System.Windows.Forms.Button
    $copyButton.Text = 'Copier ligne'
    $copyButton.Width = 120
    $copyButton.Height = 30
    $copyButton.Left = 770
    $copyButton.Top = 6
    $copyButton.Anchor = 'Right,Bottom'
    $copyButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $copyButton.BackColor = [System.Drawing.Color]::FromArgb(15, 118, 110)
    $copyButton.ForeColor = [System.Drawing.Color]::White

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = 'Fermer'
    $closeButton.Width = 120
    $closeButton.Height = 30
    $closeButton.Left = 900
    $closeButton.Top = 6
    $closeButton.Anchor = 'Right,Bottom'
    $closeButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat

    $table = ConvertTo-DanewReportDataTable -Rows @($Rows)
    $view = New-Object System.Data.DataView -ArgumentList $table
    $grid.DataSource = $view
    if ($grid.Columns['_search']) {
        $grid.Columns['_search'].Visible = $false
    }
    foreach ($column in @($grid.Columns)) {
        $column.Width = [Math]::Max(90, [Math]::Min(280, ($column.HeaderText.Length * 9 + 36)))
        $column.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::Automatic
    }

    $updateCount = {
        $countLabel.Text = ([string]$view.Count + ' ligne(s) visible(s) / ' + [string]$table.Rows.Count)
    }
    & $updateCount

    $searchBox.Add_TextChanged({
        $term = [string]$searchBox.Text
        if ([string]::IsNullOrWhiteSpace($term)) {
            $view.RowFilter = ''
        }
        else {
            try {
                $escaped = $term.Replace("'", "''").Replace('[', '[[]').Replace(']', '[]]').Replace('%', '[%]').Replace('*', '[*]')
                $view.RowFilter = "[_search] LIKE '%$escaped%'"
            }
            catch {
                $view.RowFilter = ''
            }
        }
        & $updateCount
    })

    $copyButton.Add_Click({
        if ($grid.CurrentRow -and -not $grid.CurrentRow.IsNewRow) {
            $parts = New-Object System.Collections.ArrayList
            foreach ($cell in @($grid.CurrentRow.Cells)) {
                if ($cell.OwningColumn -and $cell.OwningColumn.Visible) {
                    [void]$parts.Add(([string]$cell.OwningColumn.HeaderText + '=' + [string]$cell.Value))
                }
            }
            [System.Windows.Forms.Clipboard]::SetText((@($parts) -join [Environment]::NewLine))
        }
    })
    $closeButton.Add_Click({ $viewer.Close() })

    [void]$header.Controls.Add($titleLabel)
    [void]$header.Controls.Add($hintLabel)
    [void]$header.Controls.Add($searchBox)
    [void]$header.Controls.Add($countLabel)
    [void]$footer.Controls.Add($pathLabel)
    [void]$footer.Controls.Add($copyButton)
    [void]$footer.Controls.Add($closeButton)
    [void]$viewer.Controls.Add($grid)
    [void]$viewer.Controls.Add($footer)
    [void]$viewer.Controls.Add($header)

    if ($form) {
        [void]$viewer.ShowDialog($form)
    }
    else {
        [void]$viewer.ShowDialog()
    }
    $viewer.Dispose()
    return $true
}

function Show-DanewNativeReportViewer {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Title
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -Path $Path -PathType Leaf -ErrorAction SilentlyContinue)) {
        return $false
    }

    $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    try {
        if ($extension -eq '.csv') {
            $rows = @(Import-Csv -Path $Path -Delimiter ';' -Encoding UTF8 -ErrorAction Stop)
            if (@($rows).Count -eq 0 -or (@($rows[0].PSObject.Properties).Count -le 1)) {
                $rows = @(Import-Csv -Path $Path -Delimiter ',' -Encoding UTF8 -ErrorAction Stop)
            }
            Write-DanewReportOpeningTrace -Status 'native-viewer-csv' -Title $Title -Path $Path -Message 'Opening CSV in DataGridView.'
            return (Show-DanewReportGrid -Title $Title -Rows @($rows) -SourcePath $Path)
        }
        if ($extension -eq '.json') {
            $json = Get-Content -Path $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $rows = @(Get-DanewJsonReportRows -JsonObject $json)
            Write-DanewReportOpeningTrace -Status 'native-viewer-json' -Title $Title -Path $Path -Message 'Opening JSON in DataGridView.'
            return (Show-DanewReportGrid -Title $Title -Rows @($rows) -SourcePath $Path)
        }
        $content = Get-Content -Path $Path -Raw -Encoding UTF8 -ErrorAction Stop
        Write-DanewReportOpeningTrace -Status 'native-viewer-text' -Title $Title -Path $Path -Message 'Opening text in native viewer.'
        Show-DanewFallbackReportText -Title $Title -Content $content -FilePath $Path
        return $true
    }
    catch {
        Write-DanewReportOpeningTrace -Status 'native-viewer-error' -Title $Title -Path $Path -Message $_.Exception.Message
        return $false
    }
}

function Get-DanewNativeCompanionReportPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $directory = Split-Path -Parent $Path
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $lowerBase = $baseName.ToLowerInvariant()
    $preferredNames = @()

    if ($lowerBase -in @('reports_index', 'reports-index')) {
        $preferredNames = @('REPORTS_INDEX.csv', 'REPORTS_INDEX.txt', 'reports-index.txt', 'reports-index.csv')
    }
    elseif ($lowerBase -in @('timeline-raw', 'evtx-events', 'evtx-by-file')) {
        $preferredNames = @("$baseName.csv", "$baseName.txt", "$baseName.json")
    }
    elseif ($lowerBase -eq 'sav-diagnostic-report') {
        $preferredNames = @('sav-diagnostic-report.txt', 'sav-diagnostic-report.json', 'sav-diagnostic-report.csv')
    }
    else {
        $preferredNames = @("$baseName.txt", "$baseName.csv", "$baseName.json")
    }

    foreach ($name in $preferredNames) {
        $candidate = Join-Path $directory ([string]$name)
        if (Test-Path -Path $candidate -PathType Leaf -ErrorAction SilentlyContinue) {
            return $candidate
        }
    }

    return ''
}

function Show-DanewWebBrowserReport {
    # OFFLINE-SAFE: uses built-in MSHTML (IE11 engine) - no Chromium, no install required, works in WinPE
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Title
    )

    if (-not (Test-Path -Path $Path -PathType Leaf -ErrorAction SilentlyContinue)) { return $false }

    try {
        [System.Windows.Forms.Application]::EnableVisualStyles()

        $form = New-Object System.Windows.Forms.Form
        $form.Text = $Title
        $form.StartPosition = 'CenterParent'
        $form.ClientSize = New-Object System.Drawing.Size(1040, 680)
        $form.MinimumSize = New-Object System.Drawing.Size(780, 500)
        $form.BackColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
        $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
        $form.TopMost = $true

        $toolbar = New-Object System.Windows.Forms.Panel
        $toolbar.Dock = [System.Windows.Forms.DockStyle]::Top
        $toolbar.Height = 38
        $toolbar.BackColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
        $toolbar.Padding = New-Object System.Windows.Forms.Padding(8, 4, 8, 4)

        $titleLbl = New-Object System.Windows.Forms.Label
        $titleLbl.Text = $Title
        $titleLbl.ForeColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
        $titleLbl.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
        $titleLbl.Left = 10
        $titleLbl.Top = 10
        $titleLbl.Width = 700
        $titleLbl.Height = 20

        $backBtn = New-Object System.Windows.Forms.Button
        $backBtn.Text = '< Retour'
        $backBtn.Width = 90
        $backBtn.Height = 26
        $backBtn.Top = 6
        $backBtn.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
        $backBtn.Left = $form.ClientSize.Width - 200
        $backBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $backBtn.BackColor = [System.Drawing.Color]::FromArgb(51, 65, 85)
        $backBtn.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
        $backBtn.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
        $backBtn.Enabled = $false
        $backBtn.add_Click({
            if ($wb.CanGoBack) { $wb.GoBack() }
        })

        $closeBtn = New-Object System.Windows.Forms.Button
        $closeBtn.Text = 'Fermer'
        $closeBtn.Width = 90
        $closeBtn.Height = 26
        $closeBtn.Top = 6
        $closeBtn.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
        $closeBtn.Left = $form.ClientSize.Width - 100
        $closeBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $closeBtn.BackColor = [System.Drawing.Color]::FromArgb(51, 65, 85)
        $closeBtn.ForeColor = [System.Drawing.Color]::White
        $closeBtn.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
        $closeBtn.add_Click({ $form.Close() })

        $noticeLbl = New-Object System.Windows.Forms.Label
        $noticeLbl.Text = 'Affichage via moteur IE11 integre (WinPE). Rendu sans navigateur externe.'
        $noticeLbl.ForeColor = [System.Drawing.Color]::FromArgb(100, 116, 139)
        $noticeLbl.Font = New-Object System.Drawing.Font('Segoe UI', 8)
        $noticeLbl.Dock = [System.Windows.Forms.DockStyle]::Bottom
        $noticeLbl.Height = 18
        $noticeLbl.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        $noticeLbl.Padding = New-Object System.Windows.Forms.Padding(10, 0, 0, 0)
        $noticeLbl.BackColor = [System.Drawing.Color]::FromArgb(15, 23, 42)

        $wb = New-Object System.Windows.Forms.WebBrowser
        $wb.Dock = [System.Windows.Forms.DockStyle]::Fill
        $wb.ScrollBarsEnabled = $true
        $wb.IsWebBrowserContextMenuEnabled = $false
        $wb.WebBrowserShortcutsEnabled = $false
        $wb.ScriptErrorsSuppressed = $true
        $wb.Navigate('file:///' + $Path.Replace('\', '/'))

        $wb.add_Navigated({
            $backBtn.Enabled = $wb.CanGoBack
            $backBtn.ForeColor = if ($wb.CanGoBack) {
                [System.Drawing.Color]::White
            } else {
                [System.Drawing.Color]::FromArgb(71, 85, 105)
            }
            # Mise a jour du titre avec le rapport courant
            $currentFile = [System.IO.Path]::GetFileNameWithoutExtension($wb.Url.LocalPath)
            if (-not [string]::IsNullOrWhiteSpace($currentFile)) {
                $titleLbl.Text = $currentFile + ' - ' + $Title
            }
        })

        $toolbar.Controls.Add($titleLbl)
        $toolbar.Controls.Add($backBtn)
        $toolbar.Controls.Add($closeBtn)
        $form.Controls.Add($wb)
        $form.Controls.Add($toolbar)
        $form.Controls.Add($noticeLbl)
        $form.KeyPreview = $true
        $form.add_KeyDown({
            param($s, $e)
            if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $form.Close() }
        })

        Write-DanewReportOpeningTrace -Status 'webbrowser-winforms-open' -Title $Title -Path $Path -Message 'Opening HTML in WinForms WebBrowser (MSHTML/IE11).'
        $form.ShowDialog() | Out-Null
        return $true
    }
    catch {
        Write-DanewReportOpeningTrace -Status 'webbrowser-winforms-error' -Title $Title -Path $Path -Message $_.Exception.Message
        return $false
    }
}

function Open-DanewNativeReportFromHtml {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Title
    )

    $companion = Get-DanewNativeCompanionReportPath -Path $Path
    if (-not [string]::IsNullOrWhiteSpace($companion)) {
        Write-DanewReportOpeningTrace -Status 'native-viewer-companion' -Title $Title -Path $companion -Message ('HTML redirected to native report companion: ' + $Path)
        return (Show-DanewNativeReportViewer -Path $companion -Title $Title)
    }

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    Write-DanewReportOpeningTrace -Status 'native-viewer-no-companion' -Title $Title -Path $Path -Message 'No native companion found; using fallback report flow.'
    return (Open-DanewFallbackReport -ReportBaseName $baseName -Config $config)
}

function Show-DanewTextReportsListDialog {
    $items = @(Get-DanewTextReportCandidates)
    if (@($items).Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Aucun rapport TXT, CSV ou JSON disponible dans le dossier reports.', 'Rapports TXT', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return $false
    }

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = Convert-DanewUiText -Text 'Outil de diagnostic SAV Danew - Rapports TXT'
    $dialog.StartPosition = 'CenterParent'
    $dialog.ClientSize = New-Object System.Drawing.Size(860, 520)
    $dialog.MinimumSize = New-Object System.Drawing.Size(720, 420)
    $dialog.BackColor = [System.Drawing.Color]::FromArgb(243, 246, 252)
    $dialog.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $dialog.TopMost = $true

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Left = 14
    $titleLabel.Top = 12
    $titleLabel.Width = 820
    $titleLabel.Height = 22
    $titleLabel.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
    $titleLabel.Text = 'Rapports TXT / CSV / JSON disponibles'

    $hintLabel = New-Object System.Windows.Forms.Label
    $hintLabel.Left = 14
    $hintLabel.Top = 36
    $hintLabel.Width = 820
    $hintLabel.Height = 18
    $hintLabel.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
    $hintLabel.Text = 'Double-cliquez une entree ou utilisez OUVRIR pour afficher le rapport dans la visionneuse texte.'

    $listBox = New-Object System.Windows.Forms.ListBox
    $listBox.Left = 14
    $listBox.Top = 62
    $listBox.Width = 820
    $listBox.Height = 394
    $listBox.Anchor = 'Top,Bottom,Left,Right'
    $listBox.Font = New-Object System.Drawing.Font('Consolas', 9)
    $listBox.DisplayMember = 'display'
    foreach ($item in $items) {
        [void]$listBox.Items.Add($item)
    }
    if ($listBox.Items.Count -gt 0) {
        $listBox.SelectedIndex = 0
    }

    $openButton = New-Object System.Windows.Forms.Button
    $openButton.Left = 518
    $openButton.Top = 468
    $openButton.Width = 150
    $openButton.Height = 34
    $openButton.Anchor = 'Bottom,Right'
    $openButton.Text = 'OUVRIR'
    $openButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $openButton.FlatAppearance.BorderSize = 1
    $openButton.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(15, 118, 110)
    $openButton.BackColor = [System.Drawing.Color]::FromArgb(15, 118, 110)
    $openButton.ForeColor = [System.Drawing.Color]::White

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Left = 684
    $closeButton.Top = 468
    $closeButton.Width = 150
    $closeButton.Height = 34
    $closeButton.Anchor = 'Bottom,Right'
    $closeButton.Text = 'FERMER'
    $closeButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat

    $openHandler = {
        if (-not $listBox.SelectedItem) {
            return
        }
        $selected = $listBox.SelectedItem
        [void](Open-DanewTextReportCandidate -Path ([string]$selected.path))
    }

    $openButton.Add_Click($openHandler)
    $listBox.Add_DoubleClick($openHandler)
    $closeButton.Add_Click({ $dialog.Close() })

    [void]$dialog.Controls.Add($titleLabel)
    [void]$dialog.Controls.Add($hintLabel)
    [void]$dialog.Controls.Add($listBox)
    [void]$dialog.Controls.Add($openButton)
    [void]$dialog.Controls.Add($closeButton)
    [void]$dialog.ShowDialog($form)
    return $true
}

function Open-DanewReportFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Title
    )

    $script:LastReportOpenError = ''
    Write-DanewReportOpeningTrace -Status 'open-report-call' -Title $Title -Path $Path -Message 'Open-DanewReportFile entered.'

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -Path $Path -ErrorAction SilentlyContinue)) {
        $script:LastReportOpenError = 'Rapport introuvable: ' + [string]$Path
        Write-DanewReportOpeningTrace -Status 'open-report-missing' -Title $Title -Path $Path -Message $script:LastReportOpenError
        [System.Windows.Forms.MessageBox]::Show('Le rapport n est pas encore disponible. Lancez d abord l analyse.', $Title, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return $false
    }

    $extension = [System.IO.Path]::GetExtension($Path)
    $isHtmlReport = ($extension -and $extension.ToLowerInvariant() -in @('.html', '.htm'))
    $reportBaseName = [System.IO.Path]::GetFileNameWithoutExtension($Path)

    if ($isHtmlReport) {
        # 1. WebBrowser WinForms (MSHTML/IE11) - natif WinPE, rendu HTML complet avec patterns/frise/CSS
        Write-DanewReportOpeningTrace -Status 'open-report-webbrowser-first' -Title $Title -Path $Path -Message 'Trying WebBrowser WinForms (MSHTML) first - richest HTML rendering, no external dependency.'
        if (Show-DanewWebBrowserReport -Path $Path -Title $Title) {
            return $true
        }
        # 2. Viewer natif CSV/TXT - fallback si MSHTML indisponible ou erreur
        Write-DanewReportOpeningTrace -Status 'open-report-webbrowser-failed' -Title $Title -Path $Path -Message 'WebBrowser failed; trying native CSV/TXT companion viewer.'
        if (Open-DanewNativeReportFromHtml -Path $Path -Title $Title) {
            return $true
        }
        Write-DanewReportOpeningTrace -Status 'open-report-native-failed' -Title $Title -Path $Path -Message 'Native companion failed; falling back to legacy Chromium/Notepad flow.'
    }

    $browser = ''
    if ($isHtmlReport) {
        $browser = Get-DanewPortableBrowserPath
    }
    Write-DanewReportOpeningTrace -Status 'open-report-resolved' -Title $Title -Path $Path -BrowserPath $browser -Message ('is_html=' + [string]$isHtmlReport)

    function Try-DanewOpenTarget {
        param(
            [Parameter(Mandatory = $true)]
            [string]$TargetPath,
            [string]$BrowserPath = ''
        )

        if (-not [string]::IsNullOrWhiteSpace($BrowserPath)) {
            try {
                Write-DanewReportOpeningTrace -Status 'open-report-portable-browser-try' -Title $Title -Path $TargetPath -BrowserPath $BrowserPath -Message 'Trying portable browser.'
                [void](Start-DanewPortableBrowser -BrowserPath $BrowserPath -TargetPath $TargetPath)
                Write-DanewReportOpeningTrace -Status 'open-report-portable-browser-ok' -Title $Title -Path $TargetPath -BrowserPath $BrowserPath -Message 'Portable browser returned success.'
                return $true
            }
            catch {
                $script:LastReportOpenError = 'Echec ouverture via navigateur portable: ' + $_.Exception.Message
                Write-DanewReportOpeningTrace -Status 'open-report-portable-browser-error' -Title $Title -Path $TargetPath -BrowserPath $BrowserPath -Message $script:LastReportOpenError
            }
        }

        try {
            Write-DanewReportOpeningTrace -Status 'open-report-direct-start-try' -Title $Title -Path $TargetPath -Message 'Trying Start-Process direct.'
            Start-Process -FilePath $TargetPath | Out-Null
            Write-DanewReportOpeningTrace -Status 'open-report-direct-start-ok' -Title $Title -Path $TargetPath -Message 'Start-Process direct returned success.'
            return $true
        }
        catch {
            $script:LastReportOpenError = 'Echec Start-Process direct: ' + $_.Exception.Message
            Write-DanewReportOpeningTrace -Status 'open-report-direct-start-error' -Title $Title -Path $TargetPath -Message $script:LastReportOpenError
        }

        try {
            Write-DanewReportOpeningTrace -Status 'open-report-invoke-item-try' -Title $Title -Path $TargetPath -Message 'Trying Invoke-Item.'
            Invoke-Item -Path $TargetPath -ErrorAction Stop
            Write-DanewReportOpeningTrace -Status 'open-report-invoke-item-ok' -Title $Title -Path $TargetPath -Message 'Invoke-Item returned success.'
            return $true
        }
        catch {
            $script:LastReportOpenError = 'Echec Invoke-Item: ' + $_.Exception.Message
            Write-DanewReportOpeningTrace -Status 'open-report-invoke-item-error' -Title $Title -Path $TargetPath -Message $script:LastReportOpenError
        }

        try {
            $startArgs = '/c start "" "' + $TargetPath + '"'
            Write-DanewReportOpeningTrace -Status 'open-report-cmd-start-try' -Title $Title -Path $TargetPath -Arguments @($startArgs) -Message 'Trying cmd /c start.'
            Start-Process -FilePath 'cmd.exe' -ArgumentList $startArgs | Out-Null
            Write-DanewReportOpeningTrace -Status 'open-report-cmd-start-ok' -Title $Title -Path $TargetPath -Arguments @($startArgs) -Message 'cmd /c start returned success.'
            return $true
        }
        catch {
            $script:LastReportOpenError = 'Echec cmd/start: ' + $_.Exception.Message
            Write-DanewReportOpeningTrace -Status 'open-report-cmd-start-error' -Title $Title -Path $TargetPath -Arguments @($startArgs) -Message $script:LastReportOpenError
        }

        return $false
    }

    if ($isHtmlReport -and -not [string]::IsNullOrWhiteSpace($browser)) {
        $targetUri = Convert-DanewPathToFileUri -Path $Path
        $browserErrors = @()
        foreach ($candidateBrowser in @(Get-DanewPortableBrowserCandidates)) {
            try {
                Write-DanewReportOpeningTrace -Status 'open-report-candidate-try' -Title $Title -Path $targetUri -BrowserPath $candidateBrowser -Message ('source_path=' + $Path)
                [void](Start-DanewPortableBrowser -BrowserPath $candidateBrowser -TargetPath $targetUri)
                Write-DanewReportOpeningTrace -Status 'open-report-candidate-ok' -Title $Title -Path $targetUri -BrowserPath $candidateBrowser -Message ('source_path=' + $Path)
                return $true
            }
            catch {
                $browserErrors += ([string]$candidateBrowser + ' => ' + $_.Exception.Message)
                Write-DanewReportOpeningTrace -Status 'open-report-candidate-error' -Title $Title -Path $targetUri -BrowserPath $candidateBrowser -Message $_.Exception.Message
            }
        }
        $script:LastReportOpenError = 'Echec navigateurs portables: ' + ($browserErrors -join ' ; ')
        Write-DanewReportOpeningTrace -Status 'open-report-all-browsers-failed' -Title $Title -Path $Path -BrowserPath $browser -Message $script:LastReportOpenError
    }

    if ($isHtmlReport -and [string]::IsNullOrWhiteSpace($browser)) {
        $script:LastReportOpenError = 'Navigateur HTML non disponible. Aucun navigateur portable detecte dans tools\\browser.'
        Write-DanewReportOpeningTrace -Status 'open-report-fallback-no-browser' -Title $Title -Path $Path -Message $script:LastReportOpenError
        Show-DanewHtmlFallbackNotice -Title $Title -Reason $script:LastReportOpenError
        return (Open-DanewFallbackReport -ReportBaseName $reportBaseName -Config $config)
    }

    if ($isHtmlReport -and -not [string]::IsNullOrWhiteSpace($browser) -and -not [string]::IsNullOrWhiteSpace($script:LastReportOpenError)) {
        Write-DanewReportOpeningTrace -Status 'open-report-fallback-browser-failed' -Title $Title -Path $Path -BrowserPath $browser -Message $script:LastReportOpenError
        Show-DanewHtmlFallbackNotice -Title $Title -Reason $script:LastReportOpenError
        return (Open-DanewFallbackReport -ReportBaseName $reportBaseName -Config $config)
    }

    try {
        Write-DanewReportOpeningTrace -Status 'open-report-file-start-try' -Title $Title -Path $Path -Message 'Trying Start-Process on report file.'
        Start-Process -FilePath $Path | Out-Null
        Write-DanewReportOpeningTrace -Status 'open-report-file-start-ok' -Title $Title -Path $Path -Message 'Start-Process on report file returned success.'
        return $true
    }
    catch {
        $script:LastReportOpenError = 'Echec ouverture fichier: ' + $_.Exception.Message
        Write-DanewReportOpeningTrace -Status 'open-report-file-start-error' -Title $Title -Path $Path -Message $script:LastReportOpenError
    }

    if (Try-DanewOpenTarget -TargetPath $Path -BrowserPath '') {
        return $true
    }

    if ($isHtmlReport) {
        Write-DanewReportOpeningTrace -Status 'open-report-fallback-final' -Title $Title -Path $Path -Message $script:LastReportOpenError
        if (Test-DanewLikelyWinPE) {
            Show-DanewHtmlFallbackNotice -Title $Title -Reason $script:LastReportOpenError
        }
        return (Open-DanewFallbackReport -ReportBaseName $reportBaseName -Config $config)
    }

    Write-DanewReportOpeningTrace -Status 'open-report-failed' -Title $Title -Path $Path -BrowserPath $browser -Message $script:LastReportOpenError

    $message = 'Impossible d ouvrir ce rapport automatiquement.' + [Environment]::NewLine +
        'Chemin: ' + $Path + [Environment]::NewLine +
        'Raison: ' + $script:LastReportOpenError + [Environment]::NewLine +
        'Astuce: ouvrez le dossier reports et choisissez un rapport TXT/CSV/JSON si HTML indisponible.'
    [System.Windows.Forms.MessageBox]::Show(
        $message,
        $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    ) | Out-Null
    return $false
}

function Open-DanewSpecificReport {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('reports-index', 'sav', 'timeline', 'timeline-fast-by-file', 'storage')]
        [string]$Kind
    )

    $path = ''
    $cutoff = $script:ReportAvailabilityCutoff
    $title = 'Rapport SAV Danew'
    switch ($Kind) {
        'reports-index' {
            $path = Get-DanewAvailableReportPath -Names @('REPORTS_INDEX.html', 'reports-index.html') -MinLastWriteTime $cutoff
            $title = 'RAPPORTS DANEW'
        }
        'sav' {
            $path = Get-DanewAvailableReportPath -Names @('sav-diagnostic-report.html', 'REPORTS_INDEX.html', 'reports-index.html', 'sav-diagnostic-report.json', 'one-click-diagnostic-report.html', 'offline-windows-failure-report.html') -MinLastWriteTime $cutoff
            $path = Ensure-DanewReportHtml -Path $path
            $title = 'OUVRIR LE RAPPORT SAV'
        }
        'timeline' {
            $path = Get-DanewAvailableReportPath -Names @('timeline-raw.html', 'REPORTS_INDEX.html', 'reports-index.html', 'timeline-raw.json') -MinLastWriteTime $cutoff
            $path = Ensure-DanewReportHtml -Path $path
            $title = 'Lire les logs Windows (classes)'
        }
        'timeline-fast-by-file' {
            $path = Get-DanewAvailableReportPath -Names @('evtx-by-file.html', 'timeline-raw.html', 'evtx-events.html', 'REPORTS_INDEX.html', 'timeline-raw.json') -MinLastWriteTime $cutoff
            $path = Ensure-DanewReportHtml -Path $path
            $title = 'Lire les logs Windows (rapide par fichier EVTX)'
        }
        'storage' {
            $path = Get-DanewAvailableReportPath -Names @('storage-analysis.html', 'storage-diagnostics.html', 'REPORTS_INDEX.html', 'reports-index.html', 'storage-analysis.json', 'storage-visibility-diagnosis.json', 'storage-diagnostics.json') -MinLastWriteTime $cutoff
            $title = 'Ouvrir le rapport de stockage'
        }
    }

    Write-DanewReportOpeningTrace -Status 'specific-report-resolved' -Title $title -Path $path -Message ('kind=' + $Kind)
    return (Open-DanewReportFile -Path $path -Title $title)
}

# ---------------------------------------------------------------------------
# Ensure-DanewReportHtml — dispatcher generique pour la generation HTML
# on-demand de tous les rapports differables (timeline-raw, evtx-events,
# evtx-by-file). Remplace l'ancienne Ensure-DanewFullTimelineReport.
#
# $Path : chemin retourne par Get-DanewAvailableReportPath — peut etre
#         un .html (absent ou stub) ou un .json (mode differe pur).
# Retourne toujours un chemin .html (genere ou pas).
# ---------------------------------------------------------------------------
function Ensure-DanewReportHtml {
    param(
        [AllowEmptyString()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }

    $leaf      = Split-Path -Leaf $Path
    $dir       = Split-Path -Parent $Path
    $lowerLeaf = $leaf.ToLowerInvariant()

    # ---- Identifier le type de rapport a partir du nom de fichier ----
    $reportType = switch -Exact ($lowerLeaf) {
        'timeline-raw.json'           { 'timeline';     break }
        'timeline-raw.html'           { 'timeline';     break }
        'evtx-events.html'            { 'evtx-events';  break }
        'evtx-by-file.html'           { 'evtx-by-file'; break }
        'sav-diagnostic-report.json'  { 'sav';          break }
        'sav-diagnostic-report.html'  { 'sav';          break }
        default                       { 'unknown';      break }
    }

    if ($reportType -eq 'unknown') { return $Path }

    # ---- Chemin HTML cible ----
    $htmlDest = switch ($lowerLeaf) {
        'timeline-raw.json'          { Join-Path $dir 'timeline-raw.html' }
        'sav-diagnostic-report.json' { Join-Path $dir 'sav-diagnostic-report.html' }
        default                      { $Path }
    }

    # ---- Nom du JSON source selon le type ----
    $sourceJsonName = switch ($reportType) {
        'sav'     { 'sav-diagnostic-report.json' }
        default   { 'timeline-raw.json' }
    }

    # ---- Detecter si une (re)generation est necessaire ----
    $needsGeneration = $false
    if ($lowerLeaf -in @('timeline-raw.json', 'sav-diagnostic-report.json')) {
        # Cas differe pur : le JSON seul etait disponible, HTML absent
        $needsGeneration = $true
    }
    elseif (-not (Test-Path -Path $htmlDest)) {
        # HTML absent — generer si le JSON source est present
        $needsGeneration = (Test-Path -Path (Join-Path $dir $sourceJsonName))
    }
    elseif ($reportType -eq 'timeline') {
        # HTML present : verifier si c'est un stub mode-rapide a upgrader
        try {
            $stub = Get-Content -Path $htmlDest -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($stub -match 'Mode rapide optimise') { $needsGeneration = $true }
        }
        catch {}
    }

    if (-not $needsGeneration) { return $htmlDest }

    # ---- Charger les donnees communes (timeline JSON + summary) ----
    $loadTimelineData = {
        $tl = Get-DanewReportJson -Name 'timeline-raw.json'
        if ($null -eq $tl) { return $null }
        $sm = Get-DanewReportJson -Name 'evtx-summary.json'
        if ($null -eq $sm) {
            $sm = [pscustomobject]@{
                total_events          = @($tl.events).Count
                missing_required_logs = 0
                parse_issue_count     = @($tl.issues).Count
            }
        }
        return [pscustomobject]@{ Timeline = $tl; Summary = $sm }
    }

    # ---- Generation selon le type ----
    switch ($reportType) {

        'timeline' {
            $data = & $loadTimelineData
            if ($null -eq $data) { return $htmlDest }
            try {
                Add-DiagnosticProgressLine -Line '[HTML] Generation timeline-raw.html on-demand depuis timeline-raw.json...'
                Write-DanewTimelineHtml -Path $htmlDest -Events @($data.Timeline.events) -Summary $data.Summary
                # evtx-events.html est toujours une copie de timeline-raw.html
                $evtxEventsPath = Join-Path (Split-Path -Parent $htmlDest) 'evtx-events.html'
                try { Copy-Item -Path $htmlDest -Destination $evtxEventsPath -Force -ErrorAction SilentlyContinue } catch {}
                Add-DiagnosticProgressLine -Line ('[HTML] timeline-raw.html + evtx-events.html generees (' + [math]::Round((Get-Item $htmlDest -ErrorAction SilentlyContinue).Length/1KB, 0) + ' KB)')
            }
            catch {
                Add-DiagnosticProgressLine -Line ('[HTML] Echec generation timeline-raw.html: ' + $_.Exception.Message)
            }
        }

        'evtx-events' {
            # evtx-events.html = copie de timeline-raw.html ; on s'assure d'abord que la timeline est generee
            $timelinePath = Join-Path $dir 'timeline-raw.html'
            $resolvedTimeline = Ensure-DanewReportHtml -Path $timelinePath
            if ((Test-Path $resolvedTimeline) -and ($resolvedTimeline -ne $htmlDest)) {
                try {
                    Copy-Item -Path $resolvedTimeline -Destination $htmlDest -Force -ErrorAction SilentlyContinue
                    Add-DiagnosticProgressLine -Line '[HTML] evtx-events.html synchronisee depuis timeline-raw.html'
                }
                catch {}
            }
        }

        'evtx-by-file' {
            $data = & $loadTimelineData
            if ($null -eq $data) { return $htmlDest }
            try {
                Add-DiagnosticProgressLine -Line '[HTML] Generation evtx-by-file.html on-demand depuis timeline-raw.json...'
                Write-DanewEvtxByFileHtml -Path $htmlDest -Events @($data.Timeline.events) -Summary $data.Summary
                Add-DiagnosticProgressLine -Line ('[HTML] evtx-by-file.html generee (' + [math]::Round((Get-Item $htmlDest -ErrorAction SilentlyContinue).Length/1KB, 0) + ' KB)')
            }
            catch {
                Add-DiagnosticProgressLine -Line ('[HTML] Echec generation evtx-by-file.html: ' + $_.Exception.Message)
            }
        }

        'sav' {
            # Charger sav-diagnostic-report.json et appeler le generateur HTML SAV.
            $savJsonPath = Join-Path $dir 'sav-diagnostic-report.json'
            if (-not (Test-Path -Path $savJsonPath)) {
                Add-DiagnosticProgressLine -Line '[HTML] sav-diagnostic-report.json absent — generation HTML SAV impossible.'
                return $htmlDest
            }
            try {
                Add-DiagnosticProgressLine -Line '[HTML] Generation sav-diagnostic-report.html on-demand depuis sav-diagnostic-report.json...'
                $reportsPathForSav = Split-Path -Parent $htmlDest
                [void](Write-DanewSavDiagnosticReportHtmlFromJson -ReportsPath $reportsPathForSav)
                Add-DiagnosticProgressLine -Line ('[HTML] sav-diagnostic-report.html generee (' + [math]::Round((Get-Item $htmlDest -ErrorAction SilentlyContinue).Length/1KB, 0) + ' KB)')
            }
            catch {
                Add-DiagnosticProgressLine -Line ('[HTML] Echec generation sav-diagnostic-report.html: ' + $_.Exception.Message)
            }
        }
    }

    return $htmlDest
}

# Alias de compatibilite — conserve pour les appels eventuellement deja
# presents dans des scripts tiers ; delègue au nouveau dispatcher.
function Ensure-DanewFullTimelineReport {
    param([AllowEmptyString()][string]$Path)
    return Ensure-DanewReportHtml -Path $Path
}

function Update-DanewReportAvailability {
    $cutoff = $script:ReportAvailabilityCutoff
    $browserPath = Get-DanewPortableBrowserPath
    $browserOperational = Test-DanewPortableBrowserOperational -BrowserPath $browserPath
    $savNames = @('sav-diagnostic-report.html', 'REPORTS_INDEX.html', 'reports-index.html', 'one-click-diagnostic-report.html', 'offline-windows-failure-report.html')
    $timelineNames = @('timeline-raw.html', 'evtx-events.html', 'timeline-raw.json', 'evtx-events.csv')
    $timelineFastNames = @('evtx-by-file.html', 'timeline-raw.html', 'evtx-events.html', 'timeline-raw.json', 'evtx-events.csv')
    $recommendedNames = @('sav-diagnostic-report.json', 'root-cause-analysis.json', 'severity-analysis.json', 'offline-windows-analysis.json', 'timeline-raw.json', 'one-click-diagnostic-report.json')
    $evtxExportNames = @('evtx-events.csv', 'evtx-events.json', 'timeline-raw.json', 'evtx-sav-summary.txt')
    $anyReportNames = @(
        'sav-diagnostic-report.html',
        'evtx-by-file.html',
        'timeline-raw.html',
        'evtx-events.html',
        'REPORTS_INDEX.html',
        'reports-index.html',
        'one-click-diagnostic-report.html',
        'offline-windows-failure-report.html',
        'evtx-events.csv',
        'timeline-raw.json'
    )

    $savPath = Get-DanewAvailableReportPath -Names $savNames -MinLastWriteTime $cutoff
    $timelinePath = Get-DanewAvailableReportPath -Names $timelineNames -MinLastWriteTime $cutoff
    $timelineFastPath = Get-DanewAvailableReportPath -Names $timelineFastNames -MinLastWriteTime $cutoff
    $recommendedPath = Get-DanewAvailableReportPath -Names $recommendedNames -MinLastWriteTime $cutoff
    $evtxExportPath = Get-DanewAvailableReportPath -Names $evtxExportNames -MinLastWriteTime $cutoff
    $anyReportPath = Get-DanewAvailableReportPath -Names $anyReportNames -MinLastWriteTime $cutoff
    $reportsIndexPath = Get-DanewAvailableReportPath -Names @('REPORTS_INDEX.html', 'reports-index.html') -MinLastWriteTime $cutoff

    $hasTimeline = -not [string]::IsNullOrWhiteSpace($timelinePath)
    $hasTimelineFast = -not [string]::IsNullOrWhiteSpace($timelineFastPath)
    $hasSav = -not [string]::IsNullOrWhiteSpace($savPath)
    $hasRecommended = -not [string]::IsNullOrWhiteSpace($recommendedPath)
    $hasEvtx = -not [string]::IsNullOrWhiteSpace($evtxExportPath)
    $hasAnyReport = -not [string]::IsNullOrWhiteSpace($anyReportPath)
    $hasReportsIndex = -not [string]::IsNullOrWhiteSpace($reportsIndexPath)
    $hasTextReports = @((Get-DanewTextReportCandidates)).Count -gt 0

    $availabilityChecks = @(
        $hasTimeline,
        $hasTimelineFast,
        $hasSav,
        $hasRecommended,
        $hasEvtx,
        $hasEvtx,
        $hasAnyReport
    )
    $availableCount = @($availabilityChecks | Where-Object { $_ }).Count
    $pendingCount = @($availabilityChecks | Where-Object { -not $_ }).Count
    if ($quickActionsGroup) {
        $suffix = ' - ' + [string]$availableCount + ' disponibles, ' + [string]$pendingCount + ' a generer'
        # En WinPE, le navigateur est absent par conception — ne pas afficher de warning.
        if ((-not $browserOperational) -and (-not $script:IsWinPE)) {
            $suffix += ' - navigateur HTML indisponible'
        }
        $quickActionsGroup.Text = Convert-DanewUiText -Text ('Actions rapides' + $suffix)
    }

    # En WinPE : boutons HTML caches — les rapports s'ouvrent sur PC technicien.
    # Les blocs ci-dessous ne s'executent qu'hors WinPE.
    if ((-not $script:IsWinPE) -and $openTimelineReportButton) {
        $timelineLabel = '1. LOGS COMPLETS'
        if ($openTimelineReportButton.Tag -and $openTimelineReportButton.Tag.PSObject.Properties['base_text']) {
            $openTimelineReportButton.Tag.base_text = $timelineLabel
        }
        $openTimelineReportButton.Text = Convert-DanewUiText -Text $timelineLabel
        $timelineUnavailableHint = if (-not $browserOperational) { 'Rapport present mais navigateur non operationnel. Verifiez Chromium portable.' } else { 'Rapport complet indisponible. Lancez ANALYSE COMPLETE.' }
        Set-DanewButtonAvailability -Button $openTimelineReportButton -Available $hasTimeline -ToolTip $toolTip -AvailableHint 'Ouvre la vue complete des journaux Windows recuperes.' -UnavailableHint $timelineUnavailableHint
    }

    if ((-not $script:IsWinPE) -and $openTimelineFastReportButton) {
        $timelineFastLabel = '2. LOGS RAPIDES'
        if ($openTimelineFastReportButton.Tag -and $openTimelineFastReportButton.Tag.PSObject.Properties['base_text']) {
            $openTimelineFastReportButton.Tag.base_text = $timelineFastLabel
        }
        $openTimelineFastReportButton.Text = Convert-DanewUiText -Text $timelineFastLabel
        $timelineFastUnavailableHint = if (-not $browserOperational) { 'Rapport present mais navigateur non operationnel. Verifiez Chromium portable.' } else { 'Rapport rapide indisponible. Lancez ANALYSE RAPIDE ou ANALYSE COMPLETE.' }
        Set-DanewButtonAvailability -Button $openTimelineFastReportButton -Available $hasTimelineFast -ToolTip $toolTip -AvailableHint 'Ouvre la vue rapide des evenements critiques, erreurs et avertissements.' -UnavailableHint $timelineFastUnavailableHint
    }

    if ((-not $script:IsWinPE) -and $openSavReportButton) {
        $savLabel = '3. RAPPORT SAV'
        if ($openSavReportButton.Tag -and $openSavReportButton.Tag.PSObject.Properties['base_text']) {
            $openSavReportButton.Tag.base_text = $savLabel
        }
        $openSavReportButton.Text = Convert-DanewUiText -Text $savLabel
        $savUnavailableHint = if (-not $browserOperational) { 'Rapport present mais navigateur non operationnel. Verifiez Chromium portable.' } else { 'Rapport SAV indisponible. Lancez ANALYSER CAUSES DE CRASH.' }
        Set-DanewButtonAvailability -Button $openSavReportButton -Available $hasSav -ToolTip $toolTip -AvailableHint 'Ouvre le rapport SAV principal.' -UnavailableHint $savUnavailableHint
    }

    if ($openReportsButton) {
        Set-DanewButtonAvailability -Button $openReportsButton -Available $hasReportsIndex -ToolTip $toolTip -AvailableHint 'Ouvre le hub REPORTS_INDEX avec navigation croisee entre tous les rapports.' -UnavailableHint 'Hub de rapports indisponible pour cette session. Lancez une analyse pour generer REPORTS_INDEX.html.'
    }

    if ($openTextReportsButton) {
        Set-DanewButtonAvailability -Button $openTextReportsButton -Available $hasTextReports -ToolTip $toolTip -AvailableHint 'Affiche la liste des rapports TXT, CSV et JSON disponibles.' -UnavailableHint 'Aucun rapport texte disponible pour cette session. Lancez une analyse ou un export.'
    }

    if ($recommendedActionsButton) {
        $recommendedLabel = '4. ACTIONS SAV'
        if ($recommendedActionsButton.Tag -and $recommendedActionsButton.Tag.PSObject.Properties['base_text']) {
            $recommendedActionsButton.Tag.base_text = $recommendedLabel
        }
        $recommendedActionsButton.Text = Convert-DanewUiText -Text $recommendedLabel
        Set-DanewButtonAvailability -Button $recommendedActionsButton -Available $hasRecommended -ToolTip $toolTip -AvailableHint 'Affiche les actions SAV conseillees selon le diagnostic.' -UnavailableHint 'Actions recommandees indisponibles pour cette session. Lancez d abord une analyse des journaux.'
    }

    if ($exportEvtxTargetedButton) {
        $evtxLabel = '5. EXPORT EVTX'
        if ($exportEvtxTargetedButton.Tag -and $exportEvtxTargetedButton.Tag.PSObject.Properties['base_text']) {
            $exportEvtxTargetedButton.Tag.base_text = $evtxLabel
        }
        $exportEvtxTargetedButton.Text = Convert-DanewUiText -Text $evtxLabel
        Set-DanewButtonAvailability -Button $exportEvtxTargetedButton -Available $hasEvtx -ToolTip $toolTip -AvailableHint 'Genere les exports EVTX physiques dans reports.' -UnavailableHint 'Export EVTX indisponible pour cette session. Lancez d abord ANALYSE RAPIDE ou ANALYSE COMPLETE.'
    }

    if ($exportEvtxZipButton) {
        $evtxZipLabel = '6. ZIP EVTX'
        if ($exportEvtxZipButton.Tag -and $exportEvtxZipButton.Tag.PSObject.Properties['base_text']) {
            $exportEvtxZipButton.Tag.base_text = $evtxZipLabel
        }
        $exportEvtxZipButton.Text = Convert-DanewUiText -Text $evtxZipLabel
        Set-DanewButtonAvailability -Button $exportEvtxZipButton -Available $hasEvtx -ToolTip $toolTip -AvailableHint 'Cree un ZIP des fichiers EVTX lisibles avec les artefacts utiles.' -UnavailableHint 'Export ZIP EVTX indisponible pour cette session. Lancez d abord ANALYSE RAPIDE ou ANALYSE COMPLETE.'
    }

    if ($exportSavPackageButton) {
        $savPackageLabel = '7. DOSSIER SAV'
        if ($exportSavPackageButton.Tag -and $exportSavPackageButton.Tag.PSObject.Properties['base_text']) {
            $exportSavPackageButton.Tag.base_text = $savPackageLabel
        }
        $exportSavPackageButton.Text = Convert-DanewUiText -Text $savPackageLabel
        Set-DanewButtonAvailability -Button $exportSavPackageButton -Available $hasAnyReport -ToolTip $toolTip -AvailableHint 'Cree un package SAV avec les rapports disponibles.' -UnavailableHint 'Package SAV indisponible pour cette session. Generez au moins un rapport avant export.'
    }

    # Boutons contextuels Rapports / Exports — WinPE ou PC technicien
    if ($script:IsWinPE) {
        # Btn1 : PREPARER RAPPORTS PC TECH — disponible quand analyse faite (JSON present)
        if ($exportBtn1) {
            $hasJsonForTech = (Test-Path (Join-Path ([string]$config.reports_path) 'timeline-raw.json')) -or (Test-Path (Join-Path ([string]$config.reports_path) 'sav-diagnostic-report.json'))
            Set-DanewButtonAvailability -Button $exportBtn1 -Available $hasJsonForTech -ToolTip $toolTip -AvailableHint 'Consolide JSON/CSV/TXT pour transfert PC technicien.' -UnavailableHint 'Lancer une analyse d abord pour generer les artefacts JSON/CSV/TXT.'
        }
        # Btn2 : EXPORT ZIP SAV (export-diagnostic-package) — disponible si au moins un rapport present
        if ($exportBtn2) {
            Set-DanewButtonAvailability -Button $exportBtn2 -Available $hasAnyReport -ToolTip $toolTip -AvailableHint 'Cree un ZIP SAV complet : JSON/CSV/TXT/logs et artefacts EVTX.' -UnavailableHint 'Aucun artefact a zipper. Lancez une analyse WinPE d abord.'
        }
        # Btn3 : EXPORT EVTX CIBLE — disponible quand EVTX analyses
        if ($exportBtn3) {
            Set-DanewButtonAvailability -Button $exportBtn3 -Available $hasEvtx -ToolTip $toolTip -AvailableHint 'Genere les exports EVTX physiques dans reports.' -UnavailableHint 'Lancez d abord ANALYSE RAPIDE ou ANALYSE COMPLETE.'
        }
        # Btn4 : COPIER RESUME SAV — disponible quand evtx-sav-summary.txt present
        if ($exportBtn4) {
            $savSummaryPath = Join-Path ([string]$config.reports_path) 'evtx-sav-summary.txt'
            $hasSavSummary = Test-Path $savSummaryPath
            Set-DanewButtonAvailability -Button $exportBtn4 -Available $hasSavSummary -ToolTip $toolTip -AvailableHint 'Copie evtx-sav-summary.txt dans le presse-papiers.' -UnavailableHint 'evtx-sav-summary.txt absent. Lancez EXPORT EVTX CIBLE d abord.'
        }
    }
    else {
        # Btn1 : GENERER RAPPORTS HTML — toujours disponible sur PC technicien si JSON present
        if ($exportBtn1) {
            $hasJsonSource = (Test-Path (Join-Path ([string]$config.reports_path) 'timeline-raw.json')) -or (Test-Path (Join-Path ([string]$config.reports_path) 'sav-diagnostic-report.json'))
            Set-DanewButtonAvailability -Button $exportBtn1 -Available $hasJsonSource -ToolTip $toolTip -AvailableHint 'Genere les rapports HTML depuis les JSON collectes en WinPE.' -UnavailableHint 'Aucun JSON source detecte. Branchez la cle USB avec les artefacts WinPE.'
        }
        # Btn2 : OUVRIR RAPPORTS — disponible quand REPORTS_INDEX present
        if ($exportBtn2) {
            Set-DanewButtonAvailability -Button $exportBtn2 -Available $hasReportsIndex -ToolTip $toolTip -AvailableHint 'Ouvre le hub REPORTS_INDEX avec navigation croisee.' -UnavailableHint 'REPORTS_INDEX.html absent. Lancez GENERER RAPPORTS HTML.'
        }
        # Btn3 : OUVRIR DOSSIER — toujours disponible si le dossier reports existe
        if ($exportBtn3) {
            $reportsFolderExists = Test-Path ([string]$config.reports_path)
            Set-DanewButtonAvailability -Button $exportBtn3 -Available $reportsFolderExists -ToolTip $toolTip -AvailableHint 'Ouvre le dossier reports dans l explorateur.' -UnavailableHint 'Dossier reports introuvable.'
        }
        # Btn4 : ACTUALISER — toujours disponible
        if ($exportBtn4) {
            $exportBtn4.Enabled = $true
            if ($toolTip) { [void]$toolTip.SetToolTip($exportBtn4, 'Actualise la disponibilite des rapports et l etat du systeme.') }
        }
    }
}

function Set-DanewValueLabel {
    param(
        [AllowNull()]
        [object]$Label,
        [string]$Text,
        [string]$Tone = 'info'
    )

    if (-not $Label) {
        return
    }

    $Label.Text = Convert-DanewUiText -Text $Text
    $Label.ForeColor = [System.Drawing.Color]::FromArgb(31, 41, 55)

    switch ($Tone.ToUpperInvariant()) {
        'OK' { $Label.ForeColor = [System.Drawing.Color]::FromArgb(15, 118, 110) }
        'PASS' { $Label.ForeColor = [System.Drawing.Color]::FromArgb(15, 118, 110) }
        'WARNING' { $Label.ForeColor = [System.Drawing.Color]::FromArgb(180, 83, 9) }
        'CRITICAL' { $Label.ForeColor = [System.Drawing.Color]::FromArgb(190, 18, 60) }
        'FAIL' { $Label.ForeColor = [System.Drawing.Color]::FromArgb(190, 18, 60) }
        'HIGH' { $Label.ForeColor = [System.Drawing.Color]::FromArgb(15, 118, 110) }
    }
}

function Get-DanewSavSummary {
    $summary = [ordered]@{
        overall = 'READY'
        probable_cause = 'Run analysis to identify the probable cause.'
        confidence = 'UNKNOWN'
        severity = 'INFO'
        windows_status = 'Unknown'
        storage_status = 'Unknown'
        critical_events = '0'
        recommended_action = 'Analyser ce PC pour construire le diagnostic SAV.'
    }

    $sav = Get-DanewReportJson -Name 'sav-diagnostic-report.json'
    $rootCause = Get-DanewReportJson -Name 'root-cause-analysis.json'
    $severity = Get-DanewReportJson -Name 'severity-analysis.json'
    $offline = Get-DanewReportJson -Name 'offline-windows-analysis.json'
    $timeline = Get-DanewReportJson -Name 'timeline-raw.json'
    $oneClick = Get-DanewReportJson -Name 'one-click-diagnostic-report.json'

    if ($sav) {
        $savRoot = Get-DanewObjectValue -Object $sav -Name 'root_cause_analysis' -Default $null
        $savPrimary = Get-DanewObjectValue -Object $savRoot -Name 'primary_cause' -Default $null
        $cause = Get-DanewObjectValue -Object $savPrimary -Name 'cause' -Default ''
        if (-not [string]::IsNullOrWhiteSpace([string]$cause)) {
            $summary.probable_cause = [string]$cause
        }

        $confidence = Get-DanewObjectValue -Object $savPrimary -Name 'confidence' -Default ''
        if (-not [string]::IsNullOrWhiteSpace([string]$confidence)) {
            $summary.confidence = ([string]$confidence).ToUpperInvariant()
        }

        $savSeverity = Get-DanewObjectValue -Object (Get-DanewObjectValue -Object $sav -Name 'severity_analysis' -Default $null) -Name 'overall' -Default ''
        if (-not [string]::IsNullOrWhiteSpace([string]$savSeverity)) {
            $summary.severity = ([string]$savSeverity).ToUpperInvariant()
            $summary.overall = $summary.severity
        }
    }

    if ($rootCause -and $summary.probable_cause -eq 'Run analysis to identify the probable cause.') {
        $primary = Get-DanewObjectValue -Object $rootCause -Name 'primary_cause' -Default $null
        $cause = Get-DanewObjectValue -Object $primary -Name 'cause' -Default ''
        if (-not [string]::IsNullOrWhiteSpace([string]$cause)) {
            $summary.probable_cause = [string]$cause
        }
        $confidence = Get-DanewObjectValue -Object $primary -Name 'confidence' -Default ''
        if (-not [string]::IsNullOrWhiteSpace([string]$confidence)) {
            $summary.confidence = ([string]$confidence).ToUpperInvariant()
        }
    }

    if ($severity) {
        $overall = Get-DanewObjectValue -Object $severity -Name 'overall' -Default ''
        if (-not [string]::IsNullOrWhiteSpace([string]$overall)) {
            $summary.severity = ([string]$overall).ToUpperInvariant()
            $summary.overall = $summary.severity
        }
    }

    if ($offline) {
        $preferredWindows = Get-DanewObjectValue -Object $offline -Name 'preferred_windows_volume' -Default $null
        $preferredPath = Get-DanewObjectValue -Object $preferredWindows -Name 'path' -Default ''
        if (-not [string]::IsNullOrWhiteSpace([string]$preferredPath)) {
            $summary.windows_status = 'Detected: ' + [string]$preferredPath
        }
        else {
            $discovery = Get-DanewObjectValue -Object $offline -Name 'discovery_case_message' -Default ''
            if (-not [string]::IsNullOrWhiteSpace([string]$discovery)) {
                $summary.windows_status = [string]$discovery
            }
        }

        $diskStatus = Get-DanewObjectValue -Object $offline -Name 'primary_disk_status' -Default ''
        if (-not [string]::IsNullOrWhiteSpace([string]$diskStatus)) {
            $summary.storage_status = [string]$diskStatus
        }
    }

    if ($timeline) {
        $events = Get-DanewObjectValue -Object $timeline -Name 'events' -Default @()
        $criticalCount = @($events | Where-Object {
                $level = [string](Get-DanewObjectValue -Object $_ -Name 'level' -Default '')
                $provider = [string](Get-DanewObjectValue -Object $_ -Name 'provider' -Default '')
                $message = [string](Get-DanewObjectValue -Object $_ -Name 'message' -Default '')
                ($level -match 'critical|error') -or ($provider -match 'BugCheck|Kernel-Power|Disk|Ntfs|WHEA') -or ($message -match 'bugcheck|inaccessible|boot device|critical')
            }).Count
        $summary.critical_events = [string]$criticalCount
    }

    if ($oneClick -and $summary.overall -eq 'INFO') {
        $diag = Get-DanewObjectValue -Object $oneClick -Name 'diagnostic' -Default $null
        $diagSummary = Get-DanewObjectValue -Object $diag -Name 'summary' -Default $null
        $overall = Get-DanewObjectValue -Object $diagSummary -Name 'overall_status' -Default ''
        if (-not [string]::IsNullOrWhiteSpace([string]$overall)) {
            $summary.overall = ([string]$overall).ToUpperInvariant()
            $summary.severity = $summary.overall
        }
    }

    switch ($summary.severity) {
        'CRITICAL' { $summary.recommended_action = 'Ouvrir le rapport SAV, confirmer l acces au stockage, puis exporter le package SAV.' }
        'FAIL' { $summary.recommended_action = 'Ouvrir le rapport SAV et exporter le package SAV pour escalade.' }
        'WARNING' { $summary.recommended_action = 'Examiner les alertes, la chronologie et le rapport de stockage avant de cloturer le dossier.' }
        'PASS' { $summary.recommended_action = 'Aucun blocage detecte. Exporter le package si une tracabilite est requise.' }
        default { }
    }

    return [pscustomobject]$summary
}

function Update-DanewSavSummaryCard {
    $summary = Get-DanewSavSummary
    $statusText = if ([string]$summary.overall -eq 'READY') { 'Statut : En attente d analyse' } else { 'Statut : ' + (Get-DanewLocalizedStatusText ([string]$summary.overall)) }
    Set-DanewSummaryVisual -Status ([string]$summary.overall) -Text $statusText
    $criticalTone = 'OK'
    $criticalCount = 0
    if ([int]::TryParse([string]$summary.critical_events, [ref]$criticalCount) -and $criticalCount -gt 0) {
        $criticalTone = 'CRITICAL'
    }
    Set-DanewValueLabel -Label $probableCauseValueLabel -Text ([string]$summary.probable_cause)
    Set-DanewValueLabel -Label $confidenceValueLabel -Text (Get-DanewLocalizedConfidenceText ([string]$summary.confidence)) -Tone ([string]$summary.confidence)
    Set-DanewValueLabel -Label $severityValueLabel -Text (Get-DanewLocalizedStatusText ([string]$summary.severity)) -Tone ([string]$summary.severity)
    Set-DanewValueLabel -Label $windowsStatusValueLabel -Text ([string]$summary.windows_status)
    $storageDisplay = Normalize-DanewStorageStatusDisplay -RawValue ([string]$summary.storage_status)
    Set-DanewValueLabel -Label $storageStatusValueLabel -Text $storageDisplay -Tone ([string]$summary.severity)
    Set-DanewValueLabel -Label $criticalEventsValueLabel -Text ([string]$summary.critical_events) -Tone $criticalTone
    Set-DanewValueLabel -Label $recommendedActionValueLabel -Text ([string]$summary.recommended_action)
    if ($toolTip -and $recommendedActionValueLabel) {
        $toolTip.SetToolTip($recommendedActionValueLabel, $recommendedActionValueLabel.Text)
    }
    return $summary
}

function Show-DanewRecommendedActions {
    $summary = Update-DanewSavSummaryCard
    $message = 'Actions recommandees' + [Environment]::NewLine + [Environment]::NewLine +
        'Cause probable : ' + (Get-DanewLocalizedCauseText ([string]$summary.probable_cause)) + [Environment]::NewLine +
        'Severite : ' + (Get-DanewLocalizedStatusText ([string]$summary.severity)) + [Environment]::NewLine +
        'Confiance : ' + (Get-DanewLocalizedConfidenceText ([string]$summary.confidence)) + [Environment]::NewLine + [Environment]::NewLine +
        [string]$summary.recommended_action + [Environment]::NewLine + [Environment]::NewLine +
        'Utiliser "OUVRIR LE RAPPORT SAV" pour le detail et "EXPORTER LE DOSSIER SAV" pour l escalade.'

    [System.Windows.Forms.MessageBox]::Show($message, 'Actions recommandees', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
}

function New-DanewActionButton {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,
        [Parameter(Mandatory = $true)]
        [string]$Action,
        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.ToolTip]$ToolTip,
        [string]$Hint = '',
        [ValidateSet('neutral', 'primary', 'warn', 'danger')]
        [string]$Tone = 'neutral'
    )

    $button = New-Object System.Windows.Forms.Button
    $button.Text = Convert-DanewUiText -Text $Text
    $button.Width = 198
    $button.Height = 34
    $button.Margin = New-Object System.Windows.Forms.Padding(5, 3, 5, 3)
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderSize = 2
    $button.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
    $button.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $button.UseMnemonic = $false
    $button.AutoEllipsis = $true
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand

    $baseBackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)
    $baseBorderColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
    $baseForeColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
    $hoverBackColor = [System.Drawing.Color]::FromArgb(241, 245, 249)

    if ($Tone -eq 'primary') {
        $baseBackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
        $baseBorderColor = [System.Drawing.Color]::FromArgb(29, 78, 216)
        $baseForeColor = [System.Drawing.Color]::White
        $hoverBackColor = [System.Drawing.Color]::FromArgb(29, 78, 216)
    }
    elseif ($Tone -eq 'warn') {
        $baseBackColor = [System.Drawing.Color]::FromArgb(245, 158, 11)
        $baseBorderColor = [System.Drawing.Color]::FromArgb(180, 83, 9)
        $baseForeColor = [System.Drawing.Color]::FromArgb(17, 24, 39)
        $hoverBackColor = [System.Drawing.Color]::FromArgb(217, 119, 6)
    }
    elseif ($Tone -eq 'danger') {
        $baseBackColor = [System.Drawing.Color]::FromArgb(220, 38, 38)
        $baseBorderColor = [System.Drawing.Color]::FromArgb(153, 27, 27)
        $baseForeColor = [System.Drawing.Color]::White
        $hoverBackColor = [System.Drawing.Color]::FromArgb(185, 28, 28)
    }

    $button.BackColor = $baseBackColor
    $button.ForeColor = $baseForeColor
    $button.FlatAppearance.BorderColor = $baseBorderColor
    $button.Tag = [pscustomobject]@{
        base_text = [string]$Text
        enabled_back_color = $baseBackColor
        enabled_fore_color = $baseForeColor
        enabled_border_color = $baseBorderColor
        hover_back_color = $hoverBackColor
        disabled_back_color = [System.Drawing.Color]::FromArgb(241, 245, 249)
        disabled_fore_color = [System.Drawing.Color]::FromArgb(100, 116, 139)
        disabled_border_color = [System.Drawing.Color]::FromArgb(203, 213, 225)
        hint = [string]$Hint
    }

    $hoverBackColorForHandler = $hoverBackColor
    $baseBackColorForHandler = $baseBackColor

    $button.Add_MouseEnter(({
        $sender = [System.Windows.Forms.Button]$this
        if ($sender.Enabled) {
            $sender.BackColor = $hoverBackColorForHandler
        }
    }).GetNewClosure())
    $button.Add_MouseLeave(({
        $sender = [System.Windows.Forms.Button]$this
        if ($sender.Enabled) {
            $sender.BackColor = $baseBackColorForHandler
        }
    }).GetNewClosure())

    if (-not [string]::IsNullOrWhiteSpace($Hint)) {
        $ToolTip.SetToolTip($button, (Convert-DanewUiText -Text $Hint))
    }

    if ($Action -eq 'exit') {
        $button.Add_Click({
            if ($script:IsActionRunning) { return }
            Invoke-DanewLauncherAction -Action 'exit' -RootPath $RootPath -Config $config | Out-Null
            $form.Close()
        })
    }
    elseif ($Action -eq 'start-diagnostic') {
        $button.Add_Click({ Invoke-StartDiagnostic })
    }
    else {
        $actionName = [string]$Action
        $button.Add_Click(({
            if ($actionName -in @('open-reports-index', 'open-sav-report', 'open-timeline-report', 'open-timeline-fast-report', 'open-storage-report')) {
                try {
                    [void](Write-DanewLauncherActionLog -Config $config -Action $actionName -Status 'click' -Message 'Report button clicked before Invoke-GuiAction.')
                    Write-DanewReportOpeningTrace -Status 'click' -Title $actionName -Message 'Report button clicked before Invoke-GuiAction.'
                }
                catch {
                }
            }
            Invoke-GuiAction -Action $actionName
        }).GetNewClosure())
    }

    [void]$script:ActionButtons.Add($button)
    return $button
}

function New-DanewPrimaryDiagnosticButton {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$Text,
        [Parameter(Mandatory = $true)]
        [string]$Action,
        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.ToolTip]$ToolTip,
        [string]$Hint = '',
        [ValidateSet('blue', 'orange')]
        [string]$Tone = 'blue'
    )

    $button = New-Object System.Windows.Forms.Button
    $button.Name = $Name
    $button.Text = Convert-DanewUiText -Text $Text
    $button.Width = 408
    $button.Height = 64
    $button.Margin = New-Object System.Windows.Forms.Padding(8, 6, 8, 6)
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderSize = 2
    $button.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand

    $baseBackColor = [System.Drawing.Color]::FromArgb(29, 78, 216)
    $hoverBackColor = [System.Drawing.Color]::FromArgb(30, 64, 175)
    $borderColor = [System.Drawing.Color]::FromArgb(30, 64, 175)
    $foreColor = [System.Drawing.Color]::White

    if ($Tone -eq 'orange') {
        $baseBackColor = [System.Drawing.Color]::FromArgb(245, 158, 11)
        $hoverBackColor = [System.Drawing.Color]::FromArgb(217, 119, 6)
        $borderColor = [System.Drawing.Color]::FromArgb(180, 83, 9)
        $foreColor = [System.Drawing.Color]::FromArgb(17, 24, 39)
    }

    $button.BackColor = $baseBackColor
    $button.ForeColor = $foreColor
    $button.FlatAppearance.BorderColor = $borderColor

    $hoverBackColorForHandler = $hoverBackColor
    $baseBackColorForHandler = $baseBackColor

    $button.Add_MouseEnter(({
        $sender = [System.Windows.Forms.Button]$this
        $sender.BackColor = $hoverBackColorForHandler
    }).GetNewClosure())
    $button.Add_MouseLeave(({
        $sender = [System.Windows.Forms.Button]$this
        $sender.BackColor = $baseBackColorForHandler
    }).GetNewClosure())

    if (-not [string]::IsNullOrWhiteSpace($Hint)) {
        $ToolTip.SetToolTip($button, (Convert-DanewUiText -Text $Hint))
    }

    $actionName = [string]$Action
    $button.Add_Click(({ Invoke-GuiAction -Action $actionName }).GetNewClosure())

    [void]$script:ActionButtons.Add($button)
    return $button
}

function Get-DanewFastAnalysisOptions {
    $levels = New-Object System.Collections.ArrayList
    if ($fastCriticalCheckBox -and $fastCriticalCheckBox.Checked) { [void]$levels.Add(1) }
    if ($fastErrorCheckBox -and $fastErrorCheckBox.Checked) { [void]$levels.Add(2) }
    if ($fastWarningCheckBox -and $fastWarningCheckBox.Checked) { [void]$levels.Add(3) }

    if (@($levels).Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Selectionnez au moins un niveau pour l analyse rapide : Critique, Erreur ou Avertissement.', 'Analyse rapide', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return $null
    }

    $maxEvents = 500
    if ($fastEventLimitComboBox -and $fastEventLimitComboBox.SelectedItem) {
        $choice = [string]$fastEventLimitComboBox.SelectedItem
        if ($choice -match '100') {
            $maxEvents = 100
        }
        elseif ($choice -match '(?i)tout|all') {
            $maxEvents = 0
        }
    }

    return [pscustomobject]@{
        levels = @($levels)
        max_events_per_log = $maxEvents
    }
}

function Update-DanewStatusPanel {
    try {
        $status = Invoke-DanewLauncherAction -Action 'refresh-status' -RootPath $RootPath -Config $config -RuntimeSystemDrive $env:SystemDrive -CurrentLocationPath (Get-Location).Path -SuppressActionLog
        $snapshot = $status.output
    }
    catch {
        $logsPath = 'Unknown'
        if ($config.PSObject.Properties['logs_path']) {
            $logsPath = [string]$config.logs_path
        }
        $snapshotPath = 'Unknown'
        if ($config.PSObject.Properties['gui_status_snapshot_path'] -and -not [string]::IsNullOrWhiteSpace([string]$config.gui_status_snapshot_path)) {
            $snapshotPath = [string]$config.gui_status_snapshot_path
        }
        elseif ($config.PSObject.Properties['reports_path']) {
            $snapshotPath = Join-Path ([string]$config.reports_path) 'gui-status-snapshot.json'
        }
        $snapshot = [pscustomobject]@{
            root_path = $RootPath
            runtime_mode = 'Unknown'
            last_action = 'Unknown'
            last_action_status = 'Unknown'
            last_report_path = 'Unknown'
            selected_usb_disk = 'Unknown'
            offline_windows_detected = 'Unknown'
            logs_folder_path = $logsPath
            browser_html_status = 'Unknown'
            browser_html_path = ''
            snapshot_path = $snapshotPath
        }
    }

    Set-DanewStatusText -Name 'root_path' -Value ([string]$snapshot.root_path)
    Set-DanewStatusText -Name 'runtime_mode' -Value ([string]$snapshot.runtime_mode)
    Set-DanewStatusText -Name 'last_action' -Value ([string]$snapshot.last_action)
    Set-DanewStatusText -Name 'last_action_status' -Value ([string]$snapshot.last_action_status)
    Set-DanewStatusText -Name 'last_report_path' -Value ([string]$snapshot.last_report_path)
    Set-DanewStatusText -Name 'selected_usb_disk' -Value ([string]$snapshot.selected_usb_disk)
    Set-DanewStatusText -Name 'offline_windows_detected' -Value ([string]$snapshot.offline_windows_detected)
    Set-DanewStatusText -Name 'usb_media_ready' -Value (Get-DanewUsbMediaReadyDisplay)
    Set-DanewStatusText -Name 'logs_folder_path' -Value ([string]$snapshot.logs_folder_path)
    Set-DanewStatusText -Name 'browser_html_status' -Value ([string]$snapshot.browser_html_status)
    Set-DanewStatusText -Name 'browser_html_path' -Value ([string]$snapshot.browser_html_path)
    Update-DanewRecentActivity
    Update-DanewSummaryChips -Snapshot $snapshot

    return $snapshot
}

function Invoke-GuiAction {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Action
    )

    if ($script:IsActionRunning) {
        if ($Action -in @('open-reports-index', 'open-text-reports-list', 'open-sav-report', 'open-timeline-report', 'open-timeline-fast-report', 'open-storage-report')) {
            Write-DanewReportOpeningTrace -Status 'gui-action-ignored-running' -Title $Action -Message 'Action ignored because another action is running.'
        }
        return
    }

    $actionDisplay = Get-DanewActionDisplayText -Action $Action
    $isAnalysisAction = $Action -in @('analyze-offline-logs', 'analyze-offline-logs-fast', 'analyze-offline-logs-full', 'analyze-crash-causes')

    $script:IsActionRunning = $true
    Set-DanewActionButtonsEnabled -Enabled $false
    Set-DanewSummaryVisual -Status 'RUNNING' -Text ('Preparation : ' + $actionDisplay)
    if ($isAnalysisAction) {
        Set-DanewAnalysisCompletionState -State 'running'
    }
    if ($offlineOperationLabel) {
        $offlineOperationLabel.Text = 'Operation en cours : ' + $actionDisplay
    }
    Add-DiagnosticProgressLine -Line ('[UI] Demarrage action : ' + $actionDisplay)
    if ($Action -in @('open-reports-index', 'open-text-reports-list', 'open-sav-report', 'open-timeline-report', 'open-timeline-fast-report', 'open-storage-report')) {
        Write-DanewReportOpeningTrace -Status 'gui-action-start' -Title $Action -Message ('Invoke-GuiAction started: ' + $actionDisplay)
    }

    try {
        if ($Action -eq 'open-reports-index') {
            $opened = Open-DanewSpecificReport -Kind 'reports-index'
            if ($opened) {
                Set-DanewSummaryVisual -Status 'PASS' -Text 'Hub des rapports ouvert'
            }
            else {
                Set-DanewSummaryVisual -Status 'WARNING' -Text 'Ouverture hub des rapports echec'
            }
            return
        }
        if ($Action -eq 'open-text-reports-list') {
            $opened = Show-DanewTextReportsListDialog
            if ($opened) {
                Set-DanewSummaryVisual -Status 'PASS' -Text 'Liste des rapports texte ouverte'
            }
            else {
                Set-DanewSummaryVisual -Status 'WARNING' -Text 'Aucun rapport texte disponible'
            }
            return
        }
        if ($Action -eq 'open-sav-report') {
            # Detecter en avance si sav-diagnostic-report.html doit etre genere on-demand.
            $reportsPath   = [string]$config.reports_path
            $savHtmlPath   = Join-Path $reportsPath 'sav-diagnostic-report.html'
            $savJsonPath   = Join-Path $reportsPath 'sav-diagnostic-report.json'
            $needsSavGen   = (-not (Test-Path $savHtmlPath)) -and (Test-Path $savJsonPath)
            if ($needsSavGen) {
                Set-DanewSummaryVisual -Status 'RUNNING' -Text 'Generation HTML rapport SAV en cours...'
                Add-DiagnosticProgressLine -Line '[HTML] sav-diagnostic-report.html absent — generation on-demand depuis sav-diagnostic-report.json...'
                [System.Windows.Forms.Application]::DoEvents()
            }
            $opened = Open-DanewSpecificReport -Kind 'sav'
            if ($opened) {
                Set-DanewSummaryVisual -Status 'PASS' -Text 'Rapport SAV ouvert'
            }
            else {
                Set-DanewSummaryVisual -Status 'WARNING' -Text 'Ouverture rapport SAV echec'
            }
            return
        }
        elseif ($Action -eq 'open-timeline-report') {
            # Detect upfront if HTML needs on-demand generation (deferred mode).
            # If so, show a specific status + flush UI before the blocking call.
            $reportsPath      = [string]$config.reports_path
            $timelineHtmlPath = Join-Path $reportsPath 'timeline-raw.html'
            $timelineJsonPath = Join-Path $reportsPath 'timeline-raw.json'
            $needsGeneration  = (-not (Test-Path $timelineHtmlPath)) -and (Test-Path $timelineJsonPath)
            if ($needsGeneration) {
                Set-DanewSummaryVisual -Status 'RUNNING' -Text 'Generation HTML timeline en cours...'
                Add-DiagnosticProgressLine -Line '[TIMELINE] HTML absent — generation on-demand depuis timeline-raw.json...'
            }
            $opened = Open-DanewSpecificReport -Kind 'timeline'
            if ($opened) {
                Set-DanewSummaryVisual -Status 'PASS' -Text 'Logs Windows classes ouverts'
            }
            else {
                Set-DanewSummaryVisual -Status 'WARNING' -Text 'Ouverture logs classes echec'
            }
            return
        }
        elseif ($Action -eq 'open-timeline-fast-report') {
            # Detecter en avance si evtx-by-file.html doit etre genere on-demand.
            $reportsPath       = [string]$config.reports_path
            $byFileHtmlPath    = Join-Path $reportsPath 'evtx-by-file.html'
            $timelineJsonPath  = Join-Path $reportsPath 'timeline-raw.json'
            $needsByFileGen    = (-not (Test-Path $byFileHtmlPath)) -and (Test-Path $timelineJsonPath)
            if ($needsByFileGen) {
                Set-DanewSummaryVisual -Status 'RUNNING' -Text 'Generation HTML evtx-by-file en cours...'
                Add-DiagnosticProgressLine -Line '[HTML] evtx-by-file.html absent — generation on-demand depuis timeline-raw.json...'
                [System.Windows.Forms.Application]::DoEvents()
            }
            $opened = Open-DanewSpecificReport -Kind 'timeline-fast-by-file'
            if ($opened) {
                Set-DanewSummaryVisual -Status 'PASS' -Text 'Logs Windows rapides par fichier ouverts'
            }
            else {
                Set-DanewSummaryVisual -Status 'WARNING' -Text 'Ouverture logs rapides echec'
            }
            return
        }
        elseif ($Action -eq 'open-storage-report') {
            $opened = Open-DanewSpecificReport -Kind 'storage'
            if ($opened) {
                Set-DanewSummaryVisual -Status 'PASS' -Text 'Rapport de stockage ouvert'
            }
            else {
                Set-DanewSummaryVisual -Status 'WARNING' -Text 'Ouverture rapport stockage echec'
            }
            return
        }
        elseif ($Action -eq 'recommended-actions') {
            Show-DanewRecommendedActions
            return
        }
        elseif ($Action -eq 'generate-timeline-html') {
            $reportsPath = [string]$config.reports_path
            $jsonPath    = Join-Path $reportsPath 'timeline-raw.json'
            $htmlPath    = Join-Path $reportsPath 'timeline-raw.html'
            if (-not (Test-Path $jsonPath)) {
                Set-DanewSummaryVisual -Status 'WARNING' -Text 'timeline-raw.json absent — lancez d abord une analyse EVTX'
                return
            }
            Set-DanewSummaryVisual -Status 'RUNNING' -Text 'Generation de timeline-raw.html...'
            Add-DiagnosticProgressLine -Line '[TIMELINE] Demarrage generation HTML on-demand...'
            try {
                $tl = Get-DanewReportJson -Name 'timeline-raw.json'
                $sm = Get-DanewReportJson -Name 'evtx-summary.json'
                if ($null -eq $sm) { $sm = [pscustomobject]@{ total_events = @($tl.events).Count; missing_required_logs = 0; parse_issue_count = @($tl.issues).Count } }
                Write-DanewTimelineHtml -Path $htmlPath -Events @($tl.events) -Summary $sm
                [void](Update-DanewReportAvailability)
                Set-DanewSummaryVisual -Status 'PASS' -Text ('timeline-raw.html generee — ' + [math]::Round((Get-Item $htmlPath).Length/1KB, 0) + ' KB')
            }
            catch {
                Set-DanewSummaryVisual -Status 'FAIL' -Text ('Echec generation HTML: ' + $_.Exception.Message)
            }
            return
        }

        if ($Action -eq 'generate-html-reports') {
            # Commande PC technicien : generer tous les rapports HTML depuis les artefacts JSON/CSV.
            # Utilisable aussi en mode GUI ou CLI.
            if ($script:IsWinPE) {
                Set-DanewSummaryVisual -Status 'WARNING' -Text 'generate-html-reports non disponible en WinPE — retirer la cle USB et lancer sur PC technicien.'
                return
            }
            $reportsPath = [string]$config.reports_path
            if (-not (Test-Path $reportsPath)) {
                Set-DanewSummaryVisual -Status 'WARNING' -Text 'Dossier reports introuvable — verifiez le chemin de configuration.'
                return
            }

            Set-DanewSummaryVisual -Status 'RUNNING' -Text 'Generation des rapports HTML en cours...'
            Add-DiagnosticProgressLine -Line '[HTML] Demarrage generate-html-reports depuis artefacts JSON...'
            [System.Windows.Forms.Application]::DoEvents()

            $generatedCount = 0
            $errorCount = 0

            # 1. sav-diagnostic-report.html
            $savHtml  = Join-Path $reportsPath 'sav-diagnostic-report.html'
            $savJson  = Join-Path $reportsPath 'sav-diagnostic-report.json'
            if ((-not (Test-Path $savHtml)) -and (Test-Path $savJson)) {
                try {
                    Add-DiagnosticProgressLine -Line '[HTML] Generation sav-diagnostic-report.html...'
                    [void](Write-DanewSavDiagnosticReportHtmlFromJson -ReportsPath $reportsPath)
                    $generatedCount++
                }
                catch { $errorCount++; Add-DiagnosticProgressLine -Line ('[HTML] Echec SAV: ' + $_.Exception.Message) }
            }

            # 2. timeline-raw.html + evtx-events.html (meme source)
            $tlHtml = Join-Path $reportsPath 'timeline-raw.html'
            $tlJson = Join-Path $reportsPath 'timeline-raw.json'
            if ((-not (Test-Path $tlHtml)) -and (Test-Path $tlJson)) {
                try {
                    Add-DiagnosticProgressLine -Line '[HTML] Generation timeline-raw.html + evtx-events.html...'
                    [void](Ensure-DanewReportHtml -Path $tlHtml)
                    $generatedCount++
                }
                catch { $errorCount++; Add-DiagnosticProgressLine -Line ('[HTML] Echec timeline: ' + $_.Exception.Message) }
            }

            # 3. evtx-by-file.html
            $byFileHtml = Join-Path $reportsPath 'evtx-by-file.html'
            if ((-not (Test-Path $byFileHtml)) -and (Test-Path $tlJson)) {
                try {
                    Add-DiagnosticProgressLine -Line '[HTML] Generation evtx-by-file.html...'
                    [void](Ensure-DanewReportHtml -Path $byFileHtml)
                    $generatedCount++
                }
                catch { $errorCount++; Add-DiagnosticProgressLine -Line ('[HTML] Echec evtx-by-file: ' + $_.Exception.Message) }
            }

            # 4. REPORTS_INDEX.html
            try {
                Add-DiagnosticProgressLine -Line '[HTML] Mise a jour REPORTS_INDEX.html...'
                [void](Update-DanewInteractiveReportsIndex -ReportsPath $reportsPath)
                $generatedCount++
            }
            catch { $errorCount++; Add-DiagnosticProgressLine -Line ('[HTML] Echec index: ' + $_.Exception.Message) }

            # 5. Rafraichir disponibilite + ouvrir rapport principal si navigateur OK
            [void](Update-DanewReportAvailability)
            $statusText = 'generate-html-reports : ' + $generatedCount + ' generes'
            if ($errorCount -gt 0) { $statusText += ', ' + $errorCount + ' erreur(s)' }
            Set-DanewSummaryVisual -Status (if ($errorCount -eq 0) { 'PASS' } else { 'WARNING' }) -Text $statusText
            Add-DiagnosticProgressLine -Line ('[HTML] Termine — ' + $statusText)

            # Ouvrir REPORTS_INDEX.html si navigateur disponible
            $indexHtml = Join-Path $reportsPath 'REPORTS_INDEX.html'
            if (Test-Path $indexHtml) {
                try { [void](Open-DanewSpecificReport -Kind 'reports-index') } catch {}
            }
            return
        }

        if ($Action -eq 'prepare-reports-for-tech') {
            # WinPE : verifier artefacts essentiels pour le PC technicien.
            # Ne genere AUCUN HTML — ceux-ci sont produits sur PC technicien via generate-html-reports.
            $reportsPath = [string]$config.reports_path
            if (-not (Test-Path $reportsPath)) {
                Set-DanewSummaryVisual -Status 'WARNING' -Text 'Dossier reports introuvable.'
                return
            }
            Set-DanewSummaryVisual -Status 'RUNNING' -Text 'Verification des artefacts essentiels...'
            [System.Windows.Forms.Application]::DoEvents()

            # Artefacts essentiels : presence = OK, absence = manquant
            $checks = [ordered]@{
                'evtx-summary.json'    = Test-Path (Join-Path $reportsPath 'evtx-summary.json')
                'evtx-events.json'     = (Test-Path (Join-Path $reportsPath 'evtx-events.json')) -or (Test-Path (Join-Path $reportsPath 'timeline-raw.json'))
                'evtx-sav-summary.txt' = Test-Path (Join-Path $reportsPath 'evtx-sav-summary.txt')
                'CSV EVTX'             = ((Test-Path (Join-Path $reportsPath 'evtx-events.csv')) -or (Test-Path (Join-Path $reportsPath 'evtx-filtered-events.csv')) -or (Test-Path (Join-Path $reportsPath 'evtx-critical-events.csv')))
                'REPORTS_README.txt'   = Test-Path (Join-Path $reportsPath 'REPORTS_README.txt')
            }

            $missing = @($checks.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object { $_.Key })
            $presentCount = ($checks.Values | Where-Object { $_ }).Count
            $totalChecks = $checks.Count

            if ($missing.Count -eq 0) {
                $msg = 'PRET — ' + $presentCount + '/' + $totalChecks + ' artefacts OK. Branchez la cle sur PC technicien et lancez generate-html-reports.'
                Set-DanewSummaryVisual -Status 'PASS' -Text $msg
                Add-DiagnosticProgressLine -Line ('[PREP] ' + $msg)
            }
            else {
                $missingStr = ($missing -join ', ')
                $msg = 'INCOMPLET — ' + $presentCount + '/' + $totalChecks + ' OK. Manquants : ' + $missingStr
                Set-DanewSummaryVisual -Status 'WARNING' -Text $msg
                Add-DiagnosticProgressLine -Line ('[PREP] ' + $msg)
                Add-DiagnosticProgressLine -Line '[PREP] Lancez ANALYSE RAPIDE ou ANALYSE COMPLETE pour generer les artefacts manquants.'
            }
            [void](Update-DanewReportAvailability)
            return
        }

        if ($Action -eq 'copy-sav-resume') {
            # Copie le contenu de evtx-sav-summary.txt dans le presse-papiers.
            # Fallback si presse-papiers indisponible (WinPE sans clipboard service).
            $reportsPath = [string]$config.reports_path
            $savSummaryPath = Join-Path $reportsPath 'evtx-sav-summary.txt'
            if (-not (Test-Path $savSummaryPath)) {
                Set-DanewSummaryVisual -Status 'WARNING' -Text 'evtx-sav-summary.txt absent. Lancez EXPORT EVTX d abord.'
                Add-DiagnosticProgressLine -Line '[COPY] evtx-sav-summary.txt absent — lancez export EVTX cible.'
                return
            }
            try {
                $content = Get-Content -Path $savSummaryPath -Raw -Encoding UTF8 -ErrorAction Stop
                try {
                    [System.Windows.Forms.Clipboard]::SetText($content)
                    Set-DanewSummaryVisual -Status 'PASS' -Text 'Resume SAV copie dans le presse-papiers.'
                    Add-DiagnosticProgressLine -Line '[COPY] evtx-sav-summary.txt copie dans le presse-papiers.'
                }
                catch {
                    # Presse-papiers indisponible (WinPE typique) — afficher le chemin
                    $fallbackMsg = 'Presse-papiers indisponible. Resume disponible dans : ' + $savSummaryPath
                    Set-DanewSummaryVisual -Status 'WARNING' -Text $fallbackMsg
                    Add-DiagnosticProgressLine -Line ('[COPY] Fallback : ' + $fallbackMsg)
                    # Essai via PowerShell clip.exe si disponible
                    try {
                        $content | & clip.exe 2>$null
                        Add-DiagnosticProgressLine -Line '[COPY] clip.exe fallback utilise.'
                    }
                    catch {}
                }
            }
            catch {
                Set-DanewSummaryVisual -Status 'WARNING' -Text ('Lecture evtx-sav-summary.txt impossible : ' + $_.Exception.Message)
                Add-DiagnosticProgressLine -Line ('[COPY] Echec lecture : ' + $_.Exception.Message)
            }
            return
        }

        if ($Action -eq 'create-usb-media') {
            $usbDetails = 'Cette operation prepare l outil USB SAV et peut effacer le disque cible selectionne.' + [Environment]::NewLine + [Environment]::NewLine +
                'Disque USB actuellement selectionne : ' + [string](Get-DanewLauncherSelectedUsbDisk -Config $config) + [Environment]::NewLine +
                'Continuer uniquement si le disque cible est correct.'
            $confirmUsb = [System.Windows.Forms.MessageBox]::Show($usbDetails, 'Confirmer la preparation de l outil USB', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($confirmUsb -ne [System.Windows.Forms.DialogResult]::Yes) {
                Set-DanewSummaryVisual -Status 'IDLE' -Text 'Preparation de l outil USB annulee'
                return
            }
        }

        $suppressLog = $Action -in @('refresh-status', 'view-last-report')
        $isOfflineLogsAction = $Action -in @('analyze-offline-logs', 'analyze-offline-logs-fast', 'analyze-offline-logs-full')
        $isCrashCauseAction = $Action -eq 'analyze-crash-causes'
        $isOfflineProgressAction = $isOfflineLogsAction -or $isCrashCauseAction
        $actionConfig = $config
        if ($Action -eq 'analyze-offline-logs-fast') {
            $fastOptions = Get-DanewFastAnalysisOptions
            if ($null -eq $fastOptions) {
                return
            }

            $actionConfig = Copy-DanewLauncherConfigWithOverrides -Config $config -Overrides @{
                offline_fast_mode = $true
                offline_event_level_filter = @($fastOptions.levels)
                offline_max_events_per_log = [int]$fastOptions.max_events_per_log
                offline_analysis_mode = 'fast-custom'
            }
        }

        if ($isOfflineProgressAction) {
            $script:OfflineProgressStart = Get-Date
            $script:OfflineProgressUpdates = 0
            Set-DanewSavSummaryDetailsVisible -Visible $false
            if ($progressBox) {
                $progressBox.Text = ''
            }
            if ($summaryLabel) {
                if ($Action -eq 'analyze-offline-logs-fast') {
                    $summaryLabel.Text = 'Analyse rapide des journaux Windows hors ligne...'
                }
                elseif ($Action -eq 'analyze-offline-logs-full') {
                    $summaryLabel.Text = 'Analyse complete des journaux Windows hors ligne...'
                }
                elseif ($Action -eq 'analyze-crash-causes') {
                    $summaryLabel.Text = 'Analyse des causes de crash en cours...'
                }
                else {
                    $summaryLabel.Text = 'Analyse des journaux Windows hors ligne...'
                }
            }
            if ($Action -eq 'analyze-crash-causes') {
                Set-DanewSummaryVisual -Status 'RUNNING' -Text 'Analyse causes de crash en cours...'
            }
            else {
                Set-DanewSummaryVisual -Status 'RUNNING' -Text 'Analyse hors ligne en cours...'
            }
            if ($offlineOperationLabel) {
                $offlineOperationLabel.Text = 'Operation en cours : initialisation de l analyse de journaux hors ligne'
            }
            if ($offlineTimingLabel) {
                $offlineTimingLabel.Text = 'Ecoule : 00:00    ETA : --:--'
            }
            if ($offlineProgressBar) {
                $offlineProgressBar.Value = 0
                $offlineProgressBar.Style = 'Marquee'
                $offlineProgressBar.MarqueeAnimationSpeed = 25
            }
            if ($offlineSubProgressBar) {
                $offlineSubProgressBar.Value = 0
                $offlineSubProgressBar.Style = 'Continuous'
                $offlineSubProgressBar.MarqueeAnimationSpeed = 0
            }

            $offlineProgress = {
                param([string]$Message)
                Update-OfflineProgressFromLine -Line $Message
            }

            if ($Action -eq 'analyze-crash-causes') {
                Add-DiagnosticProgressLine -Line '[0%] Step 0/2 - Initialisation de l analyse causes de crash'
            }

            $res = Invoke-DanewLauncherAction -Action $Action -RootPath $RootPath -Config $actionConfig -RuntimeSystemDrive $env:SystemDrive -CurrentLocationPath (Get-Location).Path -ProgressCallback $offlineProgress -SuppressActionLog:$suppressLog
        }
        else {
            $res = Invoke-DanewLauncherAction -Action $Action -RootPath $RootPath -Config $actionConfig -RuntimeSystemDrive $env:SystemDrive -CurrentLocationPath (Get-Location).Path -SuppressActionLog:$suppressLog
        }

        if ($Action -eq 'view-last-report') {
            $view = $res.output
            $message = if ($view.opened) { "Dernier rapport ouvert : $($view.path)" } else { "Dernier rapport : $($view.path)`n$($view.reason)" }
            [System.Windows.Forms.MessageBox]::Show($message, 'Outil de diagnostic SAV Danew') | Out-Null
        }
        elseif ($Action -eq 'refresh-status') {
            [void](Update-DanewStatusPanel)
            [void](Update-DanewSavSummaryCard)
            Set-DanewSummaryVisual -Status 'PASS' -Text 'Statut actualise'
        }
        elseif ($isOfflineLogsAction) {
            $offline = $res.output
            $summary = $offline.summary
            $failure = $offline.failure_report
            if ($offlineProgressBar) {
                $offlineProgressBar.Style = 'Continuous'
                $offlineProgressBar.MarqueeAnimationSpeed = 0
                $offlineProgressBar.Value = 100
            }
            if ($offlineSubProgressBar) {
                $offlineSubProgressBar.Style = 'Continuous'
                $offlineSubProgressBar.MarqueeAnimationSpeed = 0
                $offlineSubProgressBar.Value = 100
            }
            if ($summaryLabel) {
                $analysisLabel = 'Analyse des journaux Windows hors ligne'
                if ($Action -eq 'analyze-offline-logs-fast') { $analysisLabel = 'Analyse rapide des journaux Windows' }
                elseif ($Action -eq 'analyze-offline-logs-full') { $analysisLabel = 'Analyse complete des journaux Windows' }
                $summaryLabel.Text = $analysisLabel + ' terminee. Global=' + (Get-DanewLocalizedStatusText ([string]$offline.overall_status))
            }
            Set-DanewSummaryVisual -Status ([string]$offline.overall_status) -Text ('Analyse hors ligne terminee : ' + (Get-DanewLocalizedStatusText ([string]$offline.overall_status)))
            Set-DanewAnalysisCompletionState -State 'done' -Text 'Analyse hors ligne terminee'
            if ($offlineOperationLabel) {
                $offlineOperationLabel.Text = 'Operation en cours : terminee'
            }
            if ($offlineTimingLabel) {
                $offlineTimingLabel.Text = 'Ecoule : termine    ETA : 00:00'
            }
            Add-DiagnosticProgressLine -Line 'Analyse des journaux hors ligne terminee. Consulter le resume SAV pour le detail.'
            Add-DiagnosticProgressLine -Line ('Temps total ecoule : ' + (Get-DanewElapsedText -Since $script:OfflineProgressStart))

            $offlineDoneMessage = $analysisLabel + ' terminee.' + [Environment]::NewLine +
                'Global : ' + (Get-DanewLocalizedStatusText ([string]$offline.overall_status)) + [Environment]::NewLine +
                'Evenements parses : ' + [string]$summary.total_events
            [System.Windows.Forms.MessageBox]::Show($offlineDoneMessage, 'Outil de diagnostic SAV Danew', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null

            if ([string]$failure.status -eq 'generated' -and -not [string]::IsNullOrWhiteSpace([string]$offline.artifacts.offline_windows_failure_report_html)) {
                $askOpen = [System.Windows.Forms.MessageBox]::Show('Ouvrir maintenant le rapport d echec SAV ?', 'Outil de diagnostic SAV Danew', [System.Windows.Forms.MessageBoxButtons]::YesNo)
                if ($askOpen -eq [System.Windows.Forms.DialogResult]::Yes) {
                    try {
                        [void](Open-DanewReportFile -Path ([string]$offline.artifacts.offline_windows_failure_report_html) -Title 'Rapport des journaux Windows')
                    }
                    catch {
                    }
                }
            }
            [void](Update-DanewStatusPanel)
            [void](Update-DanewSavSummaryCard)
            Set-DanewSavSummaryDetailsVisible -Visible $true
        }
        elseif ($Action -eq 'analyze-crash-causes') {
            $crash = $res.output
            $primary = $crash.root_cause_analysis.primary_cause
            $topEvidence = @($crash.evidence_correlation.correlations | Select-Object -First 1)
            $topEvidenceSummary = 'n/a'
            if (@($topEvidence).Count -gt 0) {
                $topEvidenceSummary = [string]$topEvidence[0].summary
            }

            if ($offlineProgressBar) {
                $offlineProgressBar.Style = 'Continuous'
                $offlineProgressBar.MarqueeAnimationSpeed = 0
                $offlineProgressBar.Value = 100
            }
            if ($offlineSubProgressBar) {
                $offlineSubProgressBar.Style = 'Continuous'
                $offlineSubProgressBar.MarqueeAnimationSpeed = 0
                $offlineSubProgressBar.Value = 100
            }
            if ($offlineOperationLabel) {
                $offlineOperationLabel.Text = 'Operation en cours : analyse des causes de crash terminee'
            }
            if ($offlineTimingLabel) {
                $offlineTimingLabel.Text = 'Ecoule : termine    ETA : 00:00'
            }
            if ($summaryLabel) {
                $summaryLabel.Text = 'Analyse des causes de crash terminee. Severite=' + (Get-DanewLocalizedStatusText ([string]$crash.severity))
            }
            Set-DanewSummaryVisual -Status ([string]$crash.severity) -Text ('Analyse causes de crash terminee : ' + (Get-DanewLocalizedStatusText ([string]$crash.severity)))
            Set-DanewAnalysisCompletionState -State 'done' -Text 'Analyse causes terminee'
            Add-DiagnosticProgressLine -Line '[100%] Step 2/2 - Analyse des causes de crash terminee'

            $message = 'Analyse des causes de crash terminee.' + [Environment]::NewLine +
                'Severite : ' + (Get-DanewLocalizedStatusText ([string]$crash.severity)) + [Environment]::NewLine +
                'Cause principale : ' + (Get-DanewLocalizedCauseText ([string]$primary.cause)) + [Environment]::NewLine +
                'Confiance : ' + (Get-DanewLocalizedConfidenceText ([string]$primary.confidence)) + [Environment]::NewLine +
                'Preuve principale : ' + $topEvidenceSummary + [Environment]::NewLine +
                'Rapport : ' + [string]$crash.report_paths.sav_diagnostic_report_html
            [System.Windows.Forms.MessageBox]::Show($message, 'Outil de diagnostic SAV Danew') | Out-Null
            if (-not [string]::IsNullOrWhiteSpace([string]$crash.report_paths.sav_diagnostic_report_html)) {
                try {
                    [void](Open-DanewReportFile -Path ([string]$crash.report_paths.sav_diagnostic_report_html) -Title 'Rapport SAV Danew')
                }
                catch {
                }
            }
            [void](Update-DanewStatusPanel)
            [void](Update-DanewSavSummaryCard)
        }
        elseif ($Action -eq 'check-browser') {
            $browser = $res.output.detection
            Set-DanewSummaryVisual -Status ([string]$browser.status) -Text ('Navigateur HTML : ' + (Get-DanewLocalizedStatusText ([string]$browser.status)))
            [System.Windows.Forms.MessageBox]::Show(([string]$browser.message + [Environment]::NewLine + [Environment]::NewLine + 'Chemin : ' + [string]$browser.browser_path), 'Verification navigateur HTML') | Out-Null
            [void](Update-DanewStatusPanel)
            [void](Update-DanewSavSummaryCard)
        }
        elseif ($Action -eq 'create-usb-media') {
            Set-DanewSummaryVisual -Status 'PASS' -Text 'Rapport outil USB genere'
            [System.Windows.Forms.MessageBox]::Show('Action outil USB terminee. Verifier la disponibilite dans les details avances si necessaire.', 'Outil de diagnostic SAV Danew') | Out-Null
            [void](Update-DanewStatusPanel)
            [void](Update-DanewSavSummaryCard)
        }
        elseif ($Action -ne 'exit') {
            Set-DanewSummaryVisual -Status 'PASS' -Text ('Termine : ' + [string]$res.action)
            [System.Windows.Forms.MessageBox]::Show("Action terminee : $($res.action)", 'Outil de diagnostic SAV Danew') | Out-Null
            [void](Update-DanewStatusPanel)
            [void](Update-DanewSavSummaryCard)
        }
        Add-DiagnosticProgressLine -Line ('[UI] Action terminee : ' + $actionDisplay)
    }
    catch {
        Set-DanewSummaryVisual -Status 'FAIL' -Text ('Echec : ' + $actionDisplay)
        if ($isAnalysisAction) {
            Set-DanewAnalysisCompletionState -State 'error' -Text 'Analyse en echec'
        }
        Add-DiagnosticProgressLine -Line ('[UI] ECHEC action : ' + $actionDisplay + ' | ' + $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Erreur outil de diagnostic SAV Danew') | Out-Null
    }
    finally {
        $script:IsActionRunning = $false
        Set-DanewActionButtonsEnabled -Enabled $true
        Update-DanewReportAvailability
    }
}

function Add-DiagnosticProgressLine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Line
    )

    if (-not $progressBox) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($progressBox.Text)) {
        $progressBox.Text = $Line
    }
    else {
        $progressBox.Text += [Environment]::NewLine + $Line
    }
    $progressBox.SelectionStart = $progressBox.Text.Length
    $progressBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Update-OfflineProgressFromLine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Line
    )

    $heartbeatMatch = [regex]::Match($Line, '^\[heartbeat\]\s+([^|]+)\|\s+(.+)$')
    if ($heartbeatMatch.Success) {
        $script:OfflineProgressUpdates++
        $spinner = Get-DanewOfflineSpinnerSymbol
        $heartbeatName = $heartbeatMatch.Groups[1].Value.Trim()
        $fields = @{}
        foreach ($fieldMatch in [regex]::Matches($heartbeatMatch.Groups[2].Value, '([a-zA-Z_]+)=([^|]+)')) {
            $fields[$fieldMatch.Groups[1].Value.Trim()] = $fieldMatch.Groups[2].Value.Trim()
        }

        $doneText = if ($fields.ContainsKey('done')) { [string]$fields['done'] } else { '?/?' }
        $activeText = if ($fields.ContainsKey('active')) { [string]$fields['active'] } else { '?' }
        $pendingText = if ($fields.ContainsKey('pending')) { [string]$fields['pending'] } else { '?' }
        $eventsText = if ($fields.ContainsKey('events')) { [string]$fields['events'] } else { '?' }
        $elapsedText = if ($fields.ContainsKey('elapsed')) { [string]$fields['elapsed'] } else { (Get-DanewElapsedText -Since $script:OfflineProgressStart) }
        $fileText = if ($fields.ContainsKey('file')) { [string]$fields['file'] } else { 'EVTX' }

        if ($offlineOperationLabel) {
            $offlineOperationLabel.Text = 'Operation en cours : lecture ' + $heartbeatName + ' ' + $doneText + ' - actifs ' + $activeText + ', attente ' + $pendingText + '  [' + $spinner + ']'
        }
        if ($summaryLabel) {
            $summaryLabel.Text = 'Lecture EVTX en cours : ' + $eventsText + ' evenements lus'
        }
        if ($offlineTimingLabel) {
            $offlineTimingLabel.Text = 'Heartbeat: ' + $fileText + '    Ecoule: ' + $elapsedText + '    ETA: actualisation...'
        }
        if ($offlineSubProgressBar) {
            $offlineSubProgressBar.Style = 'Continuous'
            $offlineSubProgressBar.MarqueeAnimationSpeed = 0
            $pulse = 8 + (($script:OfflineProgressUpdates * 13) % 84)
            if ($pulse -gt 95) { $pulse = 95 }
            $offlineSubProgressBar.Value = $pulse
        }
        Set-DanewSummaryVisual -Status 'RUNNING' -Text ('Lecture EVTX active: ' + $eventsText + ' evenements')
        [System.Windows.Forms.Application]::DoEvents()
        return
    }

    Add-DiagnosticProgressLine -Line $Line

    $subtaskMatch = [regex]::Match($Line, '^\[subtask\]\s+([^|]+)\|\s+([^|]+)(?:\|\s*(.+))?$')
    if ($subtaskMatch.Success) {
        $stage = $subtaskMatch.Groups[1].Value.Trim()
        $name = $subtaskMatch.Groups[2].Value.Trim()
        $details = ''
        if ($subtaskMatch.Groups.Count -ge 4) {
            $details = $subtaskMatch.Groups[3].Value.Trim()
        }

        if ($offlineOperationLabel) {
            $script:OfflineProgressUpdates++
            $spinner = Get-DanewOfflineSpinnerSymbol
            $offlineOperationLabel.Text = 'Operation en cours : [' + $stage + '] ' + $name + '  [' + $spinner + ']'
        }

        if ($summaryLabel) {
            if ([string]::IsNullOrWhiteSpace($details)) {
                $summaryLabel.Text = 'Resume : ' + $name
            }
            else {
                $summaryLabel.Text = 'Resume : ' + $name + ' (' + $details + ')'
            }
        }

        if ($offlineTimingLabel) {
            $offlineTimingLabel.Text = 'Sous-etape: ' + $stage + '    Ecoule: ' + (Get-DanewElapsedText -Since $script:OfflineProgressStart) + '    ETA: actualisation...'
        }

        if ($offlineSubProgressBar) {
            if ($stage -match '^(?i:start)$') {
                $offlineSubProgressBar.Style = 'Marquee'
                $offlineSubProgressBar.MarqueeAnimationSpeed = 35
            }
            elseif ($stage -match '^(?i:done)$') {
                $offlineSubProgressBar.Style = 'Continuous'
                $offlineSubProgressBar.MarqueeAnimationSpeed = 0
                $offlineSubProgressBar.Value = 100
            }
            else {
                $offlineSubProgressBar.Style = 'Continuous'
                $offlineSubProgressBar.MarqueeAnimationSpeed = 0
                $pulse = 10 + (($script:OfflineProgressUpdates * 17) % 80)
                if ($pulse -gt 95) { $pulse = 95 }
                $offlineSubProgressBar.Value = $pulse
            }
        }

        [System.Windows.Forms.Application]::DoEvents()
        return
    }

    if ($offlineProgressBar) {
        $match = [regex]::Match($Line, '^\[(\d+)%\]')
        if ($match.Success) {
            $value = [int]$match.Groups[1].Value
            if ($value -lt 0) { $value = 0 }
            if ($value -gt 100) { $value = 100 }
            if ([string]$offlineProgressBar.Style -ne 'Continuous') {
                $offlineProgressBar.Style = 'Continuous'
                $offlineProgressBar.MarqueeAnimationSpeed = 0
            }
            $offlineProgressBar.Value = $value
            if ($offlineSubProgressBar -and [string]$offlineSubProgressBar.Style -ne 'Marquee') {
                $subValue = $value
                if ($subValue -lt 5 -and $value -gt 0) { $subValue = 5 }
                if ($subValue -gt 95 -and $value -lt 100) { $subValue = 95 }
                $offlineSubProgressBar.Value = $subValue
            }
            if ($summaryLabel) {
                $summaryLabel.Text = 'Resume : Analyse hors ligne en cours - ' + [string]$value + '%'
            }
            Set-DanewSummaryVisual -Status 'RUNNING' -Text ('Analyse hors ligne en cours : ' + [string]$value + '%')
        }
    }

    if ($offlineOperationLabel) {
        $stepMatch = [regex]::Match($Line, 'Step\s+\d+/\d+\s+-\s+([^|]+)')
        if ($stepMatch.Success) {
            $script:OfflineProgressUpdates++
            $spinner = Get-DanewOfflineSpinnerSymbol
            $offlineOperationLabel.Text = 'Operation en cours : ' + $stepMatch.Groups[1].Value.Trim() + '  [' + $spinner + ']'
        }
        elseif ($Line -match '^\[(\d+)%\]') {
            $script:OfflineProgressUpdates++
            $spinner = Get-DanewOfflineSpinnerSymbol
            $offlineOperationLabel.Text = 'Operation en cours : traitement des preuves  [' + $spinner + ']'
        }
    }

    if ($offlineTimingLabel) {
        $timingMatch = [regex]::Match($Line, '\|\s*Elapsed\s*([0-9:]+)\s*\|\s*ETA\s*([0-9:]+)')
        if ($timingMatch.Success) {
            $offlineTimingLabel.Text = 'Progression: globale + sous-etape    Ecoule: ' + $timingMatch.Groups[1].Value + '    ETA: ' + $timingMatch.Groups[2].Value
        }
        else {
            $offlineTimingLabel.Text = 'Progression: globale + sous-etape    Ecoule: ' + (Get-DanewElapsedText -Since $script:OfflineProgressStart) + '    ETA: actualisation...'
        }
    }
}

function Update-DiagnosticProgressFromLine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Line
    )

    Add-DiagnosticProgressLine -Line $Line

    $runningMatch = [regex]::Match($Line, 'Running step\s+(\d+)/7')
    $doneMatch = [regex]::Match($Line, '^(PASS|WARNING|FAIL)\s+(\d+)/7')

    if ($runningMatch.Success) {
        switch ([int]$runningMatch.Groups[1].Value) {
            1 { Set-DanewStepState -Name 'scan' -State 'running' }
            2 { Set-DanewStepState -Name 'snapshot' -State 'running' }
            3 { Set-DanewStepState -Name 'usb' -State 'running' }
            4 { Set-DanewStepState -Name 'offline' -State 'running' }
            5 { Set-DanewStepState -Name 'logs' -State 'running' }
            6 { Set-DanewStepState -Name 'report' -State 'running' }
            7 { Set-DanewStepState -Name 'export' -State 'running' }
        }
    }
    elseif ($doneMatch.Success) {
        $state = ([string]$doneMatch.Groups[1].Value).ToLowerInvariant()
        switch ([int]$doneMatch.Groups[2].Value) {
            1 { Set-DanewStepState -Name 'scan' -State $state }
            2 { Set-DanewStepState -Name 'snapshot' -State $state }
            3 { Set-DanewStepState -Name 'usb' -State $state }
            4 { Set-DanewStepState -Name 'offline' -State $state }
            5 { Set-DanewStepState -Name 'logs' -State $state }
            6 { Set-DanewStepState -Name 'report' -State $state }
            7 { Set-DanewStepState -Name 'export' -State $state }
        }
    }
}

function Invoke-StartDiagnostic {
    if ($script:IsActionRunning) {
        return
    }

    $script:IsActionRunning = $true
    Set-DanewActionButtonsEnabled -Enabled $false

    if ($progressBox) {
        $progressBox.Text = ''
    }
    Reset-DanewStepStates
    Set-DanewStepState -Name 'scan' -State 'running'
    Set-DanewAnalysisCompletionState -State 'running'
    if ($summaryLabel) {
        $summaryLabel.Text = 'Diagnosis in progress...'
    }
    Set-DanewSummaryVisual -Status 'RUNNING' -Text 'Analyzing this PC...'
    if ($offlineOperationLabel) {
        $offlineOperationLabel.Text = 'Operation en cours : collecte des preuves de diagnostic'
    }

    $progress = {
        param([string]$Message)
        Update-DiagnosticProgressFromLine -Line $Message
    }

    try {
        $result = Invoke-DanewLauncherAction -Action 'start-diagnostic' -RootPath $RootPath -Config $config -RuntimeSystemDrive $env:SystemDrive -CurrentLocationPath (Get-Location).Path -ProgressCallback $progress
        $diag = $result.output.diagnostic
        foreach ($step in @($diag.steps)) {
            $state = 'pending'
            if ([string]$step.status -eq 'PASS') { $state = 'pass' }
            elseif ([string]$step.status -eq 'WARNING') { $state = 'warning' }
            elseif ([string]$step.status -eq 'FAIL') { $state = 'fail' }

            switch ([int]$step.order) {
                1 { Set-DanewStepState -Name 'scan' -State $state }
                2 { Set-DanewStepState -Name 'snapshot' -State $state }
                3 { Set-DanewStepState -Name 'usb' -State $state }
                4 { Set-DanewStepState -Name 'offline' -State $state }
                5 { Set-DanewStepState -Name 'logs' -State $state }
                6 { Set-DanewStepState -Name 'report' -State $state }
                7 { Set-DanewStepState -Name 'export' -State $state }
            }
        }

        $summaryText = [string]$diag.summary.pass + ' OK, ' + [string]$diag.summary.warning + ' alerte, ' + [string]$diag.summary.fail + ' echec'
        if ($summaryLabel) {
            $summaryLabel.Text = 'Diagnostic termine : ' + $summaryText
        }
        Set-DanewSummaryVisual -Status ([string]$diag.summary.overall_status) -Text $summaryText
        [void](Update-DanewSavSummaryCard)
        Set-DanewSavSummaryDetailsVisible -Visible $true
        Set-DanewAnalysisCompletionState -State 'done' -Text 'Diagnostic termine'

        $dataReportRoot = Copy-DanewReportToDataVolume -HtmlPath ([string]$result.output.artifacts.report_html_path) -JsonPath ([string]$result.output.artifacts.report_json_path)
        Add-DiagnosticProgressLine -Line ('Resume final : ' + $summaryText)
        Add-DiagnosticProgressLine -Line ('Rapport JSON : ' + [string]$result.output.artifacts.report_json_path)
        Add-DiagnosticProgressLine -Line ('Rapport HTML : ' + [string]$result.output.artifacts.report_html_path)
        if (-not [string]::IsNullOrWhiteSpace($dataReportRoot)) {
            Add-DiagnosticProgressLine -Line ('Dernier rapport copie vers : ' + $dataReportRoot)
        }
        [System.Windows.Forms.MessageBox]::Show('Diagnostic termine. Global : ' + (Get-DanewLocalizedStatusText ([string]$diag.summary.overall_status)), 'Outil de diagnostic SAV Danew') | Out-Null
        [void](Update-DanewStatusPanel)
        [void](Update-DanewSavSummaryCard)
        Set-DanewSavSummaryDetailsVisible -Visible $true
    }
    catch {
        if ($summaryLabel) {
            $summaryLabel.Text = 'Diagnostic en echec'
        }
        Set-DanewSummaryVisual -Status 'FAIL' -Text 'Diagnostic en echec'
        Set-DanewAnalysisCompletionState -State 'error' -Text 'Diagnostic en echec'
        Add-DiagnosticProgressLine -Line ('ECHEC - Analyse PC : ' + $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Erreur outil diagnostic SAV Danew') | Out-Null
    }
    finally {
        $script:IsActionRunning = $false
        Set-DanewActionButtonsEnabled -Enabled $true
    }
}

try {
    if ($ForceGuiInitFailure) {
        throw 'Forced GUI init failure for validation.'
    }

    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop

    $script:StatusColorDefault = [System.Drawing.Color]::FromArgb(31, 41, 55)
    $script:StatusColorPass = [System.Drawing.Color]::FromArgb(15, 118, 110)
    $script:StatusColorWarning = [System.Drawing.Color]::FromArgb(180, 83, 9)
    $script:StatusColorFail = [System.Drawing.Color]::FromArgb(190, 18, 60)

    [void](Write-DanewLauncherActionLog -Config $config -Action 'gui-launcher' -Status 'ok' -Message 'GUI assemblies loaded')
}
catch {
    [void](Write-DanewLauncherActionLog -Config $config -Action 'gui-launcher' -Status 'error' -Message $_.Exception.Message)
    if ($FallbackToCli) {
        [void](Write-DanewLauncherActionLog -Config $config -Action 'cli-fallback' -Status 'start' -Message 'GUI failed, switching to CLI')
        & $cliPath -RootPath $RootPath -ConfigPath $ConfigPath -Command $CliFallbackCommand
        [void](Write-DanewLauncherActionLog -Config $config -Action 'cli-fallback' -Status 'ok' -Message 'CLI fallback exited')
        exit 0
    }
    throw
}

if ($CliFallbackCommand -in @('open-sav-report', 'open-reports-index')) {
    $cliKind = if ($CliFallbackCommand -eq 'open-reports-index') { 'reports-index' } else { 'sav' }
    Write-DanewReportOpeningTrace -Status ('cli-direct-' + $CliFallbackCommand) -Title $CliFallbackCommand -Message ('launcher.ps1 direct ' + $CliFallbackCommand + ' command entered.')
    $openedFromCli = Open-DanewSpecificReport -Kind $cliKind
    Write-DanewReportOpeningTrace -Status ('cli-direct-' + $CliFallbackCommand + '-result') -Title $CliFallbackCommand -Message ('opened=' + [string]$openedFromCli)
    if ($openedFromCli) {
        exit 0
    }
    exit 1
}

$form = New-Object System.Windows.Forms.Form
$runtimeTitle = 'WinPE'
if ($config.PSObject.Properties['runtime_mode']) {
    $modeVal = [string]$config.runtime_mode
    if (-not [string]::IsNullOrWhiteSpace($modeVal)) {
        $runtimeTitle = $modeVal
    }
}
$form.Text = 'Outil de diagnostic SAV Danew'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(900, 720)
$form.TopMost = $true
$form.AutoScroll = $true
$form.AutoScrollMinSize = New-Object System.Drawing.Size(900, 720)
$form.MinimumSize = New-Object System.Drawing.Size(800, 560)
$form.BackColor = [System.Drawing.Color]::FromArgb(243, 246, 252)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

$iconPath = Join-Path $RootPath 'Assets_danew\danew_brand_line_blue.ico'
if (Test-Path -Path $iconPath) {
    try {
        $form.Icon = New-Object System.Drawing.Icon($iconPath)
    }
    catch {
    }
}

$workingArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
if ($workingArea.Height -lt 900 -or $workingArea.Width -lt 940) {
    $targetWidth = [Math]::Max(820, [Math]::Min(900, $workingArea.Width - 24))
    $targetHeight = [Math]::Max(640, [Math]::Min(720, $workingArea.Height - 24))
    $form.ClientSize = New-Object System.Drawing.Size($targetWidth, $targetHeight)
}

$form.Add_Resize({
    Set-DanewReportsSectionLayout
    if ($script:TechnicalDetailsVisible) {
        Set-DanewTechnicalDetailsDockLayout
    }
})

$headerPanel = New-Object System.Windows.Forms.Panel
$headerPanel.Left = 14
$headerPanel.Top = 12
$headerPanel.Width = 872
$headerPanel.Height = 74
$headerPanel.Anchor = 'Top,Left,Right'
$headerPanel.BackColor = [System.Drawing.Color]::FromArgb(30, 64, 175)

$logoBox = New-Object System.Windows.Forms.PictureBox
$logoBox.Left = 14
$logoBox.Top = 14
$logoBox.Width = 50
$logoBox.Height = 50
$logoBox.SizeMode = 'Zoom'
$logoPath = Join-Path $RootPath 'Assets_danew\danew_line_black.png'
if (Test-Path -Path $logoPath) {
    try {
        $logoBox.Image = [System.Drawing.Image]::FromFile($logoPath)
        $logoBox.BackColor = [System.Drawing.Color]::White
    }
    catch {
        $logoBox.Visible = $false
    }
}
else {
    $logoBox.Visible = $false
}

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Left = 72
$titleLabel.Top = 12
$titleLabel.Width = 624
$titleLabel.Height = 28
$titleLabel.ForeColor = [System.Drawing.Color]::White
$titleLabel.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
$titleLabel.Text = 'Outil de diagnostic SAV Danew'

$subtitleLabel = New-Object System.Windows.Forms.Label
$subtitleLabel.Left = 72
$subtitleLabel.Top = 42
$subtitleLabel.Width = 820
$subtitleLabel.Height = 20
$subtitleLabel.ForeColor = [System.Drawing.Color]::FromArgb(219, 234, 254)
$subtitleLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$subtitleLabel.Text = 'Assistant de diagnostic hors ligne: crash, demarrage et stockage'

# Badge mode dans le header — WINPE COLLECTE ou PC TECHNICIEN (en haut a droite)
$modeBadgeLabel = New-Object System.Windows.Forms.Label
$modeBadgeLabel.Width  = 200
$modeBadgeLabel.Height = 22
$modeBadgeLabel.Top    = 14
$modeBadgeLabel.Left   = [int]$headerPanel.Width - 212
$modeBadgeLabel.Anchor = 'Top,Right'
$modeBadgeLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$modeBadgeLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
if ($script:IsWinPE) {
    $modeBadgeLabel.Text      = 'MODE : WINPE COLLECTE'
    $modeBadgeLabel.BackColor = [System.Drawing.Color]::FromArgb(220, 38, 38)
    $modeBadgeLabel.ForeColor = [System.Drawing.Color]::White
}
else {
    $modeBadgeLabel.Text      = 'MODE : PC TECHNICIEN'
    $modeBadgeLabel.BackColor = [System.Drawing.Color]::FromArgb(5, 150, 105)
    $modeBadgeLabel.ForeColor = [System.Drawing.Color]::White
}
[void]$headerPanel.Controls.Add($modeBadgeLabel)

$analysisCompletionLabel = New-Object System.Windows.Forms.Label
$analysisCompletionLabel.Left = 72
$analysisCompletionLabel.Top = 58
$analysisCompletionLabel.Width = 290
$analysisCompletionLabel.Height = 14
$analysisCompletionLabel.ForeColor = [System.Drawing.Color]::FromArgb(219, 234, 254)
$analysisCompletionLabel.Font = New-Object System.Drawing.Font('Segoe UI', 8.5, [System.Drawing.FontStyle]::Bold)
$analysisCompletionLabel.Text = 'Analyse: en attente'

[void]$headerPanel.Controls.Add($logoBox)
[void]$headerPanel.Controls.Add($titleLabel)
[void]$headerPanel.Controls.Add($subtitleLabel)
[void]$headerPanel.Controls.Add($analysisCompletionLabel)

$statusGroup = New-Object System.Windows.Forms.GroupBox
$statusGroup.Text = 'Resume SAV'
$statusGroup.Left = 14
$statusGroup.Top = 302
$statusGroup.Width = 872
$statusGroup.Height = 244
$statusGroup.Anchor = 'Top,Left,Right'
$statusGroup.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$statusGroup.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)

$statusTable = New-Object System.Windows.Forms.TableLayoutPanel
$statusTable.Left = 12
$statusTable.Top = 22
$statusTable.Width = 846
$statusTable.Height = 120
$statusTable.ColumnCount = 4
$statusTable.RowCount = 5
$statusTable.AutoSize = $false
$statusTable.Dock = 'Fill'
[void]$statusTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 132)))
[void]$statusTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
[void]$statusTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 142)))
[void]$statusTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))

$statusRows = @(
    @{ key = 'runtime_mode'; label = 'Execution' },
    @{ key = 'last_action_status'; label = 'Dernier statut' },
    @{ key = 'last_action'; label = 'Derniere action' },
    @{ key = 'selected_usb_disk'; label = 'Disque USB' },
    @{ key = 'usb_media_ready'; label = 'Media USB' },
    @{ key = 'offline_windows_detected'; label = 'Windows hors ligne' },
    @{ key = 'browser_html_status'; label = 'Browser HTML' },
    @{ key = 'browser_html_path'; label = 'Chemin navigateur' },
    @{ key = 'last_report_path'; label = 'Dernier rapport' }
)

$statusPairIndex = 0
foreach ($row in $statusRows) {
    $label = New-Object System.Windows.Forms.Label
    $label.Text = [string]$row.label + ' :'
    $label.Dock = 'Fill'
    $label.TextAlign = 'MiddleLeft'
    $label.Margin = New-Object System.Windows.Forms.Padding(3, 4, 3, 4)
    $label.ForeColor = [System.Drawing.Color]::FromArgb(55, 65, 81)
    $label.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

    $value = New-DanewReadOnlyTextBox -Name $row.key
    $statusFields[$row.key] = $value

    if ([string]$row.key -eq 'last_report_path') {
        [void]$statusTable.Controls.Add($label, 0, 4)
        [void]$statusTable.Controls.Add($value, 1, 4)
        $statusTable.SetColumnSpan($value, 3)
    }
    else {
        $statusRowIndex = [int][Math]::Floor($statusPairIndex / 2)
        $statusColumnIndex = if (($statusPairIndex % 2) -eq 0) { 0 } else { 2 }
        [void]$statusTable.Controls.Add($label, $statusColumnIndex, $statusRowIndex)
        [void]$statusTable.Controls.Add($value, ($statusColumnIndex + 1), $statusRowIndex)
        $statusPairIndex++
    }
}

$resultTitleLabel = New-Object System.Windows.Forms.Label
$resultTitleLabel.Left = 16
$resultTitleLabel.Top = 20
$resultTitleLabel.Width = 380
$resultTitleLabel.Height = 26
$resultTitleLabel.Text = 'Resume du diagnostic'
$resultTitleLabel.ForeColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
$resultTitleLabel.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)

$overallBadgeLabel = New-Object System.Windows.Forms.Label
$overallBadgeLabel.Left = 720
$overallBadgeLabel.Top = 20
$overallBadgeLabel.Width = 110
$overallBadgeLabel.Height = 24
$overallBadgeLabel.Text = 'En attente'
$overallBadgeLabel.TextAlign = 'MiddleCenter'
$overallBadgeLabel.BackColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
$overallBadgeLabel.ForeColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
$overallBadgeLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)

$summaryLabel = New-Object System.Windows.Forms.Label
$summaryLabel.Left = 16
$summaryLabel.Top = 50
$summaryLabel.Width = 832
$summaryLabel.Height = 22
$summaryLabel.Text = 'Statut : En attente d analyse'
$summaryLabel.ForeColor = [System.Drawing.Color]::FromArgb(30, 64, 175)
$summaryLabel.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)

function New-DanewSummaryFieldLabel {
    param(
        [string]$Caption,
        [int]$Left,
        [int]$Top,
        [int]$Width = 188
    )

    $label = New-Object System.Windows.Forms.Label
    $label.Left = $Left
    $label.Top = $Top
    $label.Width = $Width
    $label.Height = 18
    $label.Text = $Caption
    $label.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
    $label.Font = New-Object System.Drawing.Font('Segoe UI', 8.5, [System.Drawing.FontStyle]::Bold)
    return $label
}

function New-DanewSummaryValueLabel {
    param(
        [string]$Text,
        [int]$Left,
        [int]$Top,
        [int]$Width = 188,
        [int]$Height = 30
    )

    $label = New-Object System.Windows.Forms.Label
    $label.Left = $Left
    $label.Top = $Top
    $label.Width = $Width
    $label.Height = $Height
    $label.Text = $Text
    $label.ForeColor = [System.Drawing.Color]::FromArgb(31, 41, 55)
    $label.BackColor = [System.Drawing.Color]::FromArgb(248, 250, 252)
    $label.BorderStyle = 'FixedSingle'
    $label.TextAlign = 'MiddleLeft'
    $label.Padding = New-Object System.Windows.Forms.Padding(8, 0, 8, 0)
    $label.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
    return $label
}

function New-DanewChipLabel {
    param(
        [string]$Text,
        [int]$Left,
        [int]$Top,
        [int]$Width = 176
    )

    $label = New-Object System.Windows.Forms.Label
    $label.Left = $Left
    $label.Top = $Top
    $label.Width = $Width
    $label.Height = 20
    $label.Text = $Text
    $label.TextAlign = 'MiddleCenter'
    $label.BackColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
    $label.ForeColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
    $label.BorderStyle = 'FixedSingle'
    $label.Font = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Bold)
    return $label
}

function Get-DanewWindowsReleaseFromBuild {
    param(
        [AllowNull()]
        [object]$Build
    )

    $buildText = [string]$Build
    if ([string]::IsNullOrWhiteSpace($buildText)) {
        return ''
    }

    $buildNumber = 0
    if (-not [int]::TryParse(($buildText -replace '[^\d].*$', ''), [ref]$buildNumber)) {
        return ''
    }

    if ($buildNumber -ge 26200) { return '25H2' }
    if ($buildNumber -ge 26100) { return '24H2' }
    if ($buildNumber -ge 22631) { return '23H2' }
    if ($buildNumber -ge 22621) { return '22H2' }
    if ($buildNumber -ge 22000) { return '21H2' }
    if ($buildNumber -ge 19045) { return '22H2' }
    if ($buildNumber -ge 19044) { return '21H2' }
    if ($buildNumber -ge 19043) { return '21H1' }
    if ($buildNumber -ge 19042) { return '20H2' }
    if ($buildNumber -ge 19041) { return '2004' }

    return ''
}

function Get-DanewWindowsDisplayFromOfflineReport {
    $offline = Get-DanewReportJson -Name 'offline-windows-analysis.json'
    if (-not $offline) {
        return 'Windows : Inconnu'
    }

    # registry_metadata est un array - prendre le premier element valide
    $regRaw = Get-DanewObjectValue -Object $offline -Name 'registry_metadata' -Default $null
    $registry = if ($regRaw -is [array]) { $regRaw | Where-Object { $_.status -eq 'PASS' } | Select-Object -First 1 } else { $regRaw }
    $productName = [string](Get-DanewObjectValue -Object $registry -Name 'product_name' -Default '')
    $displayVersion = [string](Get-DanewObjectValue -Object $registry -Name 'display_version' -Default '')
    $releaseId = [string](Get-DanewObjectValue -Object $registry -Name 'release_id' -Default '')
    $currentBuild = [string](Get-DanewObjectValue -Object $registry -Name 'current_build' -Default '')

    if ([string]::IsNullOrWhiteSpace($displayVersion)) {
        $displayVersion = Get-DanewWindowsReleaseFromBuild -Build $currentBuild
    }
    if ([string]::IsNullOrWhiteSpace($displayVersion) -and -not [string]::IsNullOrWhiteSpace($releaseId)) {
        $displayVersion = $releaseId
    }

    $windowsName = ''
    if ($productName -match '(?i)Windows\s+11') {
        $windowsName = 'Windows 11'
    }
    elseif ($productName -match '(?i)Windows\s+10') {
        $windowsName = 'Windows 10'
    }
    elseif (-not [string]::IsNullOrWhiteSpace($productName)) {
        $windowsName = $productName
    }
    elseif (-not [string]::IsNullOrWhiteSpace($currentBuild)) {
        $buildNumber = 0
        if ([int]::TryParse(($currentBuild -replace '[^\d].*$', ''), [ref]$buildNumber) -and $buildNumber -ge 22000) {
            $windowsName = 'Windows 11'
        } else {
            $windowsName = 'Windows'
        }
    }

    if ([string]::IsNullOrWhiteSpace($windowsName)) {
        $preferredWindows = Get-DanewObjectValue -Object $offline -Name 'preferred_windows_volume' -Default $null
        $preferredPath = [string](Get-DanewObjectValue -Object $preferredWindows -Name 'path' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($preferredPath)) {
            return 'Windows : Detecte'
        }
        return 'Windows : Inconnu'
    }

    $parts = @($windowsName)
    if (-not [string]::IsNullOrWhiteSpace($displayVersion)) {
        $parts += $displayVersion
    }
    if (-not [string]::IsNullOrWhiteSpace($currentBuild)) {
        $parts += ('Build ' + $currentBuild)
    }

    return ('Windows : ' + ($parts -join ' '))
}

function Update-DanewSummaryChips {
    param(
        [AllowNull()]
        [object]$Snapshot
    )

    if (-not $runtimeChipLabel -and -not $windowsChipLabel -and -not $usbChipLabel -and -not $machineChipLabel) {
        return
    }

    $runtimeText = 'Execution : ' + $runtimeTitle
    if ($Snapshot -and $Snapshot.PSObject.Properties['runtime_mode']) {
        $modeVal = [string]$Snapshot.runtime_mode
        if (-not [string]::IsNullOrWhiteSpace($modeVal)) {
            $runtimeText = 'Execution : ' + $modeVal
        }
    }

    $windowsText = Get-DanewWindowsDisplayFromOfflineReport
    if ($Snapshot -and $Snapshot.PSObject.Properties['offline_windows_detected']) {
        $raw = [string]$Snapshot.offline_windows_detected
        if ($windowsText -eq 'Windows : Inconnu') {
            if ($raw -match '(?i)not\s+detected|no\s+windows|missing') {
                $windowsText = 'Windows : Non detecte'
            }
            elseif ($raw -match '(?i)detected|found|windows') {
                $windowsText = 'Windows : Detecte'
            }
        }
    }

    $usbText = 'USB : Inconnu'
    if ($Snapshot -and $Snapshot.PSObject.Properties['selected_usb_disk']) {
        $disk = [string]$Snapshot.selected_usb_disk
        if (-not [string]::IsNullOrWhiteSpace($disk) -and $disk -ne 'Unknown') {
            if ($disk -match '(?i)disk') {
                $usbText = 'USB : ' + $disk
            }
            else {
                $usbText = 'USB : Disque ' + $disk
            }
        }
    }

    # Machine name depuis offline-windows-analysis.json
    $machineText = 'Machine : Inconnu'
    $offlineData = Get-DanewReportJson -Name 'offline-windows-analysis.json'
    if ($offlineData) {
        $regRaw = Get-DanewObjectValue -Object $offlineData -Name 'registry_metadata' -Default $null
        $regEntry = if ($regRaw -is [array]) { $regRaw | Where-Object { $_.status -eq 'PASS' } | Select-Object -First 1 } else { $regRaw }
        $computerName = [string](Get-DanewObjectValue -Object $regEntry -Name 'computer_name' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($computerName)) {
            $machineText = 'Machine : ' + $computerName
        }
    }

    if ($runtimeChipLabel) { $runtimeChipLabel.Text = $runtimeText }
    if ($windowsChipLabel) { $windowsChipLabel.Text = $windowsText }
    if ($machineChipLabel) { $machineChipLabel.Text = $machineText }
    if ($usbChipLabel) { $usbChipLabel.Text = $usbText }
}

function Normalize-DanewStorageStatusDisplay {
    param(
        [string]$RawValue
    )

    if ([string]::IsNullOrWhiteSpace($RawValue)) {
        return 'Inconnu'
    }

    $clean = $RawValue
    $clean = $clean -replace '\s*/\s*case\s*[A-Z]', ''
    $clean = $clean.Trim()

    if ($clean -match '(?i)^internal-visible') { return 'Disque interne visible' }
    if ($clean -match '(?i)^internal-hidden') { return 'Disque interne non visible' }
    if ($clean -match '(?i)^external-visible') { return 'Disque externe visible' }
    if ($clean -match '(?i)^external-hidden') { return 'Disque externe non visible' }
    if ($clean -match '(?i)^no-disks') { return 'Aucun disque detecte' }
    if ($clean -match '(?i)^unknown') { return 'Inconnu' }

    return $clean
}

[void]$statusGroup.Controls.Add($resultTitleLabel)
[void]$statusGroup.Controls.Add($overallBadgeLabel)
[void]$statusGroup.Controls.Add($summaryLabel)

$probableCauseCaptionLabel = New-DanewSummaryFieldLabel -Caption 'Cause probable' -Left 16 -Top 100 -Width 400
[void]$statusGroup.Controls.Add($probableCauseCaptionLabel)
$probableCauseValueLabel = New-DanewSummaryValueLabel -Text 'Lancer l analyse pour identifier la cause probable.' -Left 16 -Top 116 -Width 530 -Height 28
[void]$statusGroup.Controls.Add($probableCauseValueLabel)

$confidenceCaptionLabel = New-DanewSummaryFieldLabel -Caption 'Confiance' -Left 566 -Top 100 -Width 130
[void]$statusGroup.Controls.Add($confidenceCaptionLabel)
$confidenceValueLabel = New-DanewSummaryValueLabel -Text 'INCONNUE' -Left 566 -Top 116 -Width 130 -Height 28
[void]$statusGroup.Controls.Add($confidenceValueLabel)

$severityCaptionLabel = New-DanewSummaryFieldLabel -Caption 'Severite' -Left 712 -Top 100 -Width 136
[void]$statusGroup.Controls.Add($severityCaptionLabel)
$severityValueLabel = New-DanewSummaryValueLabel -Text 'INFO' -Left 712 -Top 116 -Width 136 -Height 28
[void]$statusGroup.Controls.Add($severityValueLabel)

$windowsStatusCaptionLabel = New-DanewSummaryFieldLabel -Caption 'Detection Windows' -Left 16 -Top 148 -Width 260
[void]$statusGroup.Controls.Add($windowsStatusCaptionLabel)
$windowsStatusValueLabel = New-DanewSummaryValueLabel -Text 'Inconnu' -Left 16 -Top 164 -Width 260 -Height 26
[void]$statusGroup.Controls.Add($windowsStatusValueLabel)

$storageStatusCaptionLabel = New-DanewSummaryFieldLabel -Caption 'Visibilite du stockage' -Left 292 -Top 148 -Width 260
[void]$statusGroup.Controls.Add($storageStatusCaptionLabel)
$storageStatusValueLabel = New-DanewSummaryValueLabel -Text 'Inconnu' -Left 292 -Top 164 -Width 260 -Height 26
[void]$statusGroup.Controls.Add($storageStatusValueLabel)

$criticalEventsCaptionLabel = New-DanewSummaryFieldLabel -Caption 'Evenements critiques' -Left 568 -Top 148 -Width 260
[void]$statusGroup.Controls.Add($criticalEventsCaptionLabel)
$criticalEventsValueLabel = New-DanewSummaryValueLabel -Text '0' -Left 568 -Top 164 -Width 260 -Height 26
[void]$statusGroup.Controls.Add($criticalEventsValueLabel)

$recommendedActionValueLabel = $null
$recommendedActionCaptionLabel = New-DanewSummaryFieldLabel -Caption 'Prochaine action recommandee' -Left 16 -Top 194 -Width 832
[void]$statusGroup.Controls.Add($recommendedActionCaptionLabel)
$recommendedActionValueLabel = New-DanewSummaryValueLabel -Text 'Analyser d abord les journaux Windows.' -Left 16 -Top 210 -Width 832 -Height 28
$recommendedActionValueLabel.AutoSize = $false
$recommendedActionValueLabel.TextAlign = 'TopLeft'
$recommendedActionValueLabel.AutoEllipsis = $false
[void]$statusGroup.Controls.Add($recommendedActionValueLabel)

$script:SavSummaryDetailControls = @(
    $probableCauseCaptionLabel,
    $probableCauseValueLabel,
    $confidenceCaptionLabel,
    $confidenceValueLabel,
    $severityCaptionLabel,
    $severityValueLabel,
    $windowsStatusCaptionLabel,
    $windowsStatusValueLabel,
    $storageStatusCaptionLabel,
    $storageStatusValueLabel,
    $criticalEventsCaptionLabel,
    $criticalEventsValueLabel,
    $recommendedActionCaptionLabel,
    $recommendedActionValueLabel
)

$runtimeChipLabel = New-DanewChipLabel -Text ('Execution : ' + $runtimeTitle) -Left 16 -Top 76 -Width 152
$windowsChipLabel = New-DanewChipLabel -Text 'Windows : Inconnu' -Left 176 -Top 76 -Width 238
$machineChipLabel = New-DanewChipLabel -Text 'Machine : Inconnu' -Left 422 -Top 76 -Width 170
$usbChipLabel = New-DanewChipLabel -Text 'USB : Inconnu' -Left 600 -Top 76 -Width 150
[void]$statusGroup.Controls.Add($runtimeChipLabel)
[void]$statusGroup.Controls.Add($windowsChipLabel)
[void]$statusGroup.Controls.Add($machineChipLabel)
[void]$statusGroup.Controls.Add($usbChipLabel)

$savSummaryLabel = $summaryLabel
$savOverallBadgeLabel = $overallBadgeLabel

$primaryGroup = New-Object System.Windows.Forms.GroupBox
$primaryGroup.Text = 'Actions principales de diagnostic (1 -> 3)'
$primaryGroup.Left = 14
$primaryGroup.Top = 96
$primaryGroup.Width = 872
$primaryGroup.Height = 168
$primaryGroup.Anchor = 'Top,Left,Right'
$primaryGroup.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$primaryGroup.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)

$offlineOperationLabel = New-Object System.Windows.Forms.Label
$offlineOperationLabel.Left = 22
$offlineOperationLabel.Top = 124
$offlineOperationLabel.Width = 844
$offlineOperationLabel.Height = 18
$offlineOperationLabel.Text = 'Pret. Commencer par les journaux Windows, puis l analyse des causes de crash.'
$offlineOperationLabel.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
$offlineOperationLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$offlineProgressBar = New-Object System.Windows.Forms.ProgressBar
$offlineProgressBar.Left = 22
$offlineProgressBar.Top = 144
$offlineProgressBar.Width = 828
$offlineProgressBar.Height = 18
$offlineProgressBar.Minimum = 0
$offlineProgressBar.Maximum = 100
$offlineProgressBar.Value = 0
$offlineProgressBar.Style = 'Continuous'

$offlineSubProgressBar = New-Object System.Windows.Forms.ProgressBar
$offlineSubProgressBar.Left = 22
$offlineSubProgressBar.Top = 164
$offlineSubProgressBar.Width = 828
$offlineSubProgressBar.Height = 10
$offlineSubProgressBar.Minimum = 0
$offlineSubProgressBar.Maximum = 100
$offlineSubProgressBar.Value = 0
$offlineSubProgressBar.Style = 'Continuous'

# offlineTimingLabel : compact sur une seule ligne sous les barres de progression.
$offlineTimingLabel = New-Object System.Windows.Forms.Label
$offlineTimingLabel.Left = 22
$offlineTimingLabel.Top = 176
$offlineTimingLabel.Width = 844
$offlineTimingLabel.Height = 16
$offlineTimingLabel.Text = 'Ecoule : 00:00    ETA : --:--'
$offlineTimingLabel.ForeColor = [System.Drawing.Color]::FromArgb(100, 116, 139)
$offlineTimingLabel.Font = New-Object System.Drawing.Font('Segoe UI', 8)

$progressBox = New-Object System.Windows.Forms.TextBox
$progressBox.Left = 14
$progressBox.Top = 234
$progressBox.Width = 844
$progressBox.Height = 92
$progressBox.Multiline = $true
$progressBox.ScrollBars = 'Vertical'
$progressBox.ReadOnly = $true
$progressBox.BorderStyle = 'FixedSingle'
$progressBox.BackColor = [System.Drawing.Color]::FromArgb(248, 250, 252)
$progressBox.ForeColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
$progressBox.Font = New-Object System.Drawing.Font('Consolas', 9)

$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.AutoPopDelay = 12000
$toolTip.InitialDelay = 400
$toolTip.ReshowDelay = 100
$toolTip.ShowAlways = $true

if ($recommendedActionValueLabel) {
    $toolTip.SetToolTip($recommendedActionValueLabel, $recommendedActionValueLabel.Text)
}

$analyzeWindowsLogsFastButton = New-DanewPrimaryDiagnosticButton -Name 'AnalyzeWindowsLogsFastButton' -Text 'ANALYSE FILTRE RAPIDE' -Action 'analyze-offline-logs-fast' -ToolTip $toolTip -Hint 'Analyse rapide des journaux Windows selon les cases cochees et le volume choisi. Filtre Critique, Erreur et/ou Avertissement. Action en lecture seule.' -Tone 'blue'
$analyzeWindowsLogsFastButton.Width = 220
$analyzeWindowsLogsFastButton.Height = 34
$analyzeWindowsLogsFastButton.Font = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Bold)
$analyzeWindowsLogsFastButton.Left = 22
$analyzeWindowsLogsFastButton.Top = 86

$analyzeWindowsLogsFullButton = New-DanewPrimaryDiagnosticButton -Name 'AnalyzeWindowsLogsFullButton' -Text "ANALYSE COMPLETE`r`nTOUS LES LOGS" -Action 'analyze-offline-logs-full' -ToolTip $toolTip -Hint 'Analyse complete des journaux Windows recuperes pour inspection detaillee. Plus longue que l analyse rapide. Action en lecture seule.' -Tone 'blue'
$analyzeWindowsLogsFullButton.Width = 410
$analyzeWindowsLogsFullButton.Height = 56
$analyzeWindowsLogsFullButton.Font = New-Object System.Drawing.Font('Segoe UI', 11.5, [System.Drawing.FontStyle]::Bold)
$analyzeWindowsLogsFullButton.Left = 22
$analyzeWindowsLogsFullButton.Top = 24

$analyzeCrashCausesButton = New-DanewPrimaryDiagnosticButton -Name 'AnalyzeCrashCausesButton' -Text "ANALYSER CAUSES`r`nDE CRASH" -Action 'analyze-crash-causes' -ToolTip $toolTip -Hint 'Analyse les evenements Windows deja lus pour identifier les causes probables de panne. Genere le rapport SAV principal avec confiance, gravite et preuves. Action en lecture seule.' -Tone 'orange'
$analyzeCrashCausesButton.Width = 410
$analyzeCrashCausesButton.Height = 56
$analyzeCrashCausesButton.Font = New-Object System.Drawing.Font('Segoe UI', 11.5, [System.Drawing.FontStyle]::Bold)
$analyzeCrashCausesButton.Left = 448
$analyzeCrashCausesButton.Top = 24

$fastOptionsPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$fastOptionsPanel.Name = 'FastAnalysisOptionsPanel'
$fastOptionsPanel.Left = 254
$fastOptionsPanel.Top = 88
$fastOptionsPanel.Width = 596
$fastOptionsPanel.Height = 30
$fastOptionsPanel.FlowDirection = 'LeftToRight'
$fastOptionsPanel.WrapContents = $false
$fastOptionsPanel.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)

$fastOptionsLabel = New-Object System.Windows.Forms.Label
$fastOptionsLabel.Text = 'Filtres :'
$fastOptionsLabel.Width = 62
$fastOptionsLabel.Height = 24
$fastOptionsLabel.Margin = New-Object System.Windows.Forms.Padding(0, 4, 6, 0)
$fastOptionsLabel.TextAlign = 'MiddleLeft'
$fastOptionsLabel.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
$fastOptionsLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
[void]$fastOptionsPanel.Controls.Add($fastOptionsLabel)

$fastCriticalCheckBox = New-Object System.Windows.Forms.CheckBox
$fastCriticalCheckBox.Text = 'Critique'
$fastCriticalCheckBox.Width = 82
$fastCriticalCheckBox.Height = 24
$fastCriticalCheckBox.Checked = $true
$fastCriticalCheckBox.Margin = New-Object System.Windows.Forms.Padding(0, 4, 8, 0)
$fastCriticalCheckBox.Font = New-Object System.Drawing.Font('Segoe UI', 9)
[void]$toolTip.SetToolTip($fastCriticalCheckBox, 'Inclut les evenements critiques Windows.')
[void]$fastOptionsPanel.Controls.Add($fastCriticalCheckBox)

$fastErrorCheckBox = New-Object System.Windows.Forms.CheckBox
$fastErrorCheckBox.Text = 'Erreur'
$fastErrorCheckBox.Width = 72
$fastErrorCheckBox.Height = 24
$fastErrorCheckBox.Checked = $true
$fastErrorCheckBox.Margin = New-Object System.Windows.Forms.Padding(0, 4, 8, 0)
$fastErrorCheckBox.Font = New-Object System.Drawing.Font('Segoe UI', 9)
[void]$toolTip.SetToolTip($fastErrorCheckBox, 'Inclut les erreurs Windows.')
[void]$fastOptionsPanel.Controls.Add($fastErrorCheckBox)

$fastWarningCheckBox = New-Object System.Windows.Forms.CheckBox
$fastWarningCheckBox.Text = 'Avert.'
$fastWarningCheckBox.Width = 70
$fastWarningCheckBox.Height = 24
$fastWarningCheckBox.Checked = $true
$fastWarningCheckBox.Margin = New-Object System.Windows.Forms.Padding(0, 4, 18, 0)
$fastWarningCheckBox.Font = New-Object System.Drawing.Font('Segoe UI', 9)
[void]$toolTip.SetToolTip($fastWarningCheckBox, 'Inclut les avertissements Windows.')
[void]$fastOptionsPanel.Controls.Add($fastWarningCheckBox)

$fastLimitLabel = New-Object System.Windows.Forms.Label
$fastLimitLabel.Text = 'Evenements/log :'
$fastLimitLabel.Width = 116
$fastLimitLabel.Height = 24
$fastLimitLabel.Margin = New-Object System.Windows.Forms.Padding(0, 4, 6, 0)
$fastLimitLabel.TextAlign = 'MiddleRight'
$fastLimitLabel.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
$fastLimitLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
[void]$fastOptionsPanel.Controls.Add($fastLimitLabel)

$fastEventLimitComboBox = New-Object System.Windows.Forms.ComboBox
$fastEventLimitComboBox.Name = 'FastEventLimitComboBox'
$fastEventLimitComboBox.Width = 94
$fastEventLimitComboBox.Height = 24
$fastEventLimitComboBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$fastEventLimitComboBox.Items.Add('100')
[void]$fastEventLimitComboBox.Items.Add('500')
[void]$fastEventLimitComboBox.Items.Add('Tout')
$fastEventLimitComboBox.SelectedItem = '500'
$fastEventLimitComboBox.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 0)
$fastEventLimitComboBox.Font = New-Object System.Drawing.Font('Segoe UI', 9)
[void]$toolTip.SetToolTip($fastEventLimitComboBox, 'Choisit le nombre maximum d evenements lus par journal en analyse rapide. Tout lit tous les evenements correspondant aux niveaux coches.')
[void]$fastOptionsPanel.Controls.Add($fastEventLimitComboBox)

$stepPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$stepPanel.Left = 14
$stepPanel.Top = 150
$stepPanel.Width = 844
$stepPanel.Height = 48
$stepPanel.FlowDirection = 'LeftToRight'
$stepPanel.WrapContents = $true
$stepPanel.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)

foreach ($step in @(
        @{ key = 'scan'; label = 'Scan' },
        @{ key = 'snapshot'; label = 'Statut' },
        @{ key = 'usb'; label = 'USB' },
        @{ key = 'offline'; label = 'Hors ligne' },
        @{ key = 'logs'; label = 'Journaux' },
        @{ key = 'report'; label = 'Rapport' },
        @{ key = 'export'; label = 'Export' }
    )) {
    $stepLabel = New-Object System.Windows.Forms.Label
    $stepLabel.Text = '[ ] ' + [string]$step.label
    $stepLabel.Tag = [string]$step.label
    $stepLabel.Width = 112
    $stepLabel.Height = 20
    $stepLabel.Margin = New-Object System.Windows.Forms.Padding(3, 2, 3, 2)
    $stepLabel.TextAlign = 'MiddleCenter'
    $stepLabel.BackColor = [System.Drawing.Color]::FromArgb(241, 245, 249)
    $stepLabel.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
    $stepLabel.Font = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Bold)
    $stepLabels[[string]$step.key] = $stepLabel
    [void]$stepPanel.Controls.Add($stepLabel)
}

[void]$primaryGroup.Controls.Add($analyzeWindowsLogsFastButton)
[void]$primaryGroup.Controls.Add($analyzeWindowsLogsFullButton)
[void]$primaryGroup.Controls.Add($analyzeCrashCausesButton)
[void]$primaryGroup.Controls.Add($fastOptionsPanel)
[void]$primaryGroup.Controls.Add($offlineOperationLabel)
[void]$primaryGroup.Controls.Add($offlineProgressBar)
[void]$primaryGroup.Controls.Add($offlineSubProgressBar)
[void]$primaryGroup.Controls.Add($offlineTimingLabel)
$summaryLabel = $savSummaryLabel
$overallBadgeLabel = $savOverallBadgeLabel

$simpleActionsGroup = New-Object System.Windows.Forms.GroupBox
$simpleActionsGroup.Text = 'Rapports / Exports'
$simpleActionsGroup.Left = 14
$simpleActionsGroup.Top = 586
$simpleActionsGroup.Width = 872
$simpleActionsGroup.Height = 74
$simpleActionsGroup.Anchor = 'Top,Left,Right'
$simpleActionsGroup.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)
$simpleActionsGroup.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)

$exportsPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$exportsPanel.Left = 10
$exportsPanel.Top = 18
$exportsPanel.Width = 844
$exportsPanel.Height = 48
$exportsPanel.Anchor = 'Top,Left,Right'
$exportsPanel.FlowDirection = 'LeftToRight'
$exportsPanel.WrapContents = $false
$exportsPanel.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)
$exportsPanel.Padding = New-Object System.Windows.Forms.Padding(0, 2, 0, 2)

# 4 boutons contextuels — WinPE : collecte/export ; PC tech : HTML/navigation
if ($script:IsWinPE) {
    $exportBtn1 = New-DanewActionButton -Text 'PREPARER PC TECH' -Action 'prepare-reports-for-tech' -ToolTip $toolTip -Hint 'Verifie les artefacts essentiels (JSON/CSV/TXT) pour le PC technicien. Affiche pret ou incomplet avec liste des fichiers manquants.' -Tone 'primary'
    $exportBtn2 = New-DanewActionButton -Text 'EXPORT ZIP SAV' -Action 'export-diagnostic-package' -ToolTip $toolTip -Hint 'Cree un ZIP SAV complet : JSON, CSV, TXT, logs et artefacts EVTX. Pret pour transfert ou archivage SAV.' -Tone 'neutral'
    $exportBtn3 = New-DanewActionButton -Text 'EXPORT EVTX' -Action 'export-evtx-targeted' -ToolTip $toolTip -Hint 'Genere les exports EVTX physiques : evenements filtres, critiques, fenetre crash et resume SAV TXT.' -Tone 'neutral'
    $exportBtn4 = New-DanewActionButton -Text 'COPIER RESUME' -Action 'copy-sav-resume' -ToolTip $toolTip -Hint 'Copie le contenu de evtx-sav-summary.txt dans le presse-papiers. Si indisponible, affiche le chemin du fichier.' -Tone 'neutral'
}
else {
    $exportBtn1 = New-DanewActionButton -Text 'GENERER RAPPORTS HTML' -Action 'generate-html-reports' -ToolTip $toolTip -Hint 'Genere les rapports HTML depuis les JSON collectes en WinPE : timeline, SAV, REPORTS_INDEX.' -Tone 'primary'
    $exportBtn2 = New-DanewActionButton -Text 'OUVRIR RAPPORTS' -Action 'open-reports-index' -ToolTip $toolTip -Hint 'Ouvre le hub REPORTS_INDEX avec navigation croisee entre tous les rapports HTML.' -Tone 'neutral'
    $exportBtn3 = New-DanewActionButton -Text 'OUVRIR DOSSIER' -Action 'open-reports-folder' -ToolTip $toolTip -Hint 'Ouvre le dossier reports dans l explorateur de fichiers.' -Tone 'neutral'
    $exportBtn4 = New-DanewActionButton -Text 'ACTUALISER' -Action 'refresh-status' -ToolTip $toolTip -Hint 'Actualise la disponibilite des rapports et l etat du systeme.' -Tone 'neutral'
}
[void]$exportsPanel.Controls.Add($exportBtn1)
[void]$exportsPanel.Controls.Add($exportBtn2)
[void]$exportsPanel.Controls.Add($exportBtn3)
[void]$exportsPanel.Controls.Add($exportBtn4)

# Conserver simplePanel + openReportsButton pour compatibilite (hors WinPE uniquement)
$simplePanel = New-Object System.Windows.Forms.Panel
$simplePanel.Left = 0
$simplePanel.Top = 0
$simplePanel.Width = 0
$simplePanel.Height = 0
$simplePanel.Visible = $false

$openReportsButton = New-Object System.Windows.Forms.Button
$openReportsButton.Name = 'openReportsButton'
$openReportsButton.Text = Convert-DanewUiText -Text "OUVRIR RAPPORTS`n(HTML)"
$openReportsButton.AutoSize = $false
$openReportsButton.Width = 420
$openReportsButton.Height = 40
$openReportsButton.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$openReportsButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$openReportsButton.FlatAppearance.BorderSize = 2
$openReportsButton.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(15, 118, 110)
$openReportsButton.BackColor = [System.Drawing.Color]::FromArgb(15, 118, 110)
$openReportsButton.ForeColor = [System.Drawing.Color]::White
$openReportsButton.Margin = New-Object System.Windows.Forms.Padding(5, 3, 5, 3)
$openReportsButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$openReportsButton.Tag = [pscustomobject]@{
    base_text = 'OUVRIR RAPPORTS'
    enabled_back_color = [System.Drawing.Color]::FromArgb(15, 118, 110)
    enabled_fore_color = [System.Drawing.Color]::White
    enabled_border_color = [System.Drawing.Color]::FromArgb(15, 118, 110)
    hover_back_color = [System.Drawing.Color]::FromArgb(13, 148, 136)
    disabled_back_color = [System.Drawing.Color]::FromArgb(241, 245, 249)
    disabled_fore_color = [System.Drawing.Color]::FromArgb(100, 116, 139)
    disabled_border_color = [System.Drawing.Color]::FromArgb(203, 213, 225)
    hint = 'Ouvre REPORTS_INDEX.html comme point d entree unique pour tous les rapports HTML.'
}
$openReportsButton.Add_MouseEnter({
    $sender = [System.Windows.Forms.Button]$this
    if ($sender.Enabled) {
        $sender.BackColor = [System.Drawing.Color]::FromArgb(13, 148, 136)
    }
})
$openReportsButton.Add_MouseLeave({
    $sender = [System.Windows.Forms.Button]$this
    if ($sender.Enabled) {
        $sender.BackColor = [System.Drawing.Color]::FromArgb(15, 118, 110)
    }
})
$openReportsButton.Add_Click({
    $originalText = $openReportsButton.Text
    $spinnerFrames = @('[===  ]', '[=== ]', '[ ===]', '[  ==]', '[   =]', '[    ]')
    $spinnerIndex = 0

    # Show spinner
    $spinnerTimer = New-Object System.Windows.Forms.Timer
    $spinnerTimer.Interval = 150
    $spinnerTimer.Add_Tick({
        $openReportsButton.Text = "$($spinnerFrames[$spinnerIndex % $spinnerFrames.Count]) Chargement..."
        $spinnerIndex++
    })
    $spinnerTimer.Start()

    # Execute action in background
    [System.Windows.Forms.Application]::DoEvents()
    try {
        Invoke-GuiAction -Action 'open-reports-index'
    } finally {
        $spinnerTimer.Stop()
        $spinnerTimer.Dispose()
        $openReportsButton.Text = $originalText
    }
})
[void]$toolTip.SetToolTip($openReportsButton, 'Ouvre le hub REPORTS_INDEX.html avec navigation croisee offline-safe.')
[void]$script:ActionButtons.Add($openReportsButton)

$openTextReportsButton = New-Object System.Windows.Forms.Button
$openTextReportsButton.Name = 'openTextReportsButton'
$openTextReportsButton.Text = Convert-DanewUiText -Text "RAPPORT TXT`n(Fallback)"
$openTextReportsButton.AutoSize = $false
$openTextReportsButton.Width = 260
$openTextReportsButton.Height = 40
$openTextReportsButton.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$openTextReportsButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$openTextReportsButton.FlatAppearance.BorderSize = 2
$openTextReportsButton.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
$openTextReportsButton.BackColor = [System.Drawing.Color]::White
$openTextReportsButton.ForeColor = [System.Drawing.Color]::FromArgb(31, 41, 55)
$openTextReportsButton.Margin = New-Object System.Windows.Forms.Padding(5, 3, 5, 3)
$openTextReportsButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$openTextReportsButton.Tag = [pscustomobject]@{
    base_text = 'RAPPORT TXT (LISTE)'
    enabled_back_color = [System.Drawing.Color]::White
    enabled_fore_color = [System.Drawing.Color]::FromArgb(31, 41, 55)
    enabled_border_color = [System.Drawing.Color]::FromArgb(71, 85, 105)
    hover_back_color = [System.Drawing.Color]::FromArgb(241, 245, 249)
    disabled_back_color = [System.Drawing.Color]::FromArgb(241, 245, 249)
    disabled_fore_color = [System.Drawing.Color]::FromArgb(100, 116, 139)
    disabled_border_color = [System.Drawing.Color]::FromArgb(203, 213, 225)
    hint = 'Affiche la liste des rapports texte lisibles: TXT, CSV et JSON.'
}
$openTextReportsButton.Add_MouseEnter({
    $sender = [System.Windows.Forms.Button]$this
    if ($sender.Enabled) {
        $sender.BackColor = [System.Drawing.Color]::FromArgb(241, 245, 249)
    }
})
$openTextReportsButton.Add_MouseLeave({
    $sender = [System.Windows.Forms.Button]$this
    if ($sender.Enabled) {
        $sender.BackColor = [System.Drawing.Color]::White
    }
})
$openTextReportsButton.Add_Click({
    Invoke-GuiAction -Action 'open-text-reports-list'
})
[void]$toolTip.SetToolTip($openTextReportsButton, 'Affiche la liste des rapports TXT, CSV et JSON disponibles dans reports.')
[void]$script:ActionButtons.Add($openTextReportsButton)

$openTimelineReportButton = New-DanewActionButton -Text '1. COMPLET TOUS LES LOGS' -Action 'open-timeline-report' -ToolTip $toolTip -Hint 'Ouvre la vue complete des journaux Windows recuperes. Permet de filtrer, trier et rechercher tous les evenements EVTX.' -Tone 'primary'
$openTimelineFastReportButton = New-DanewActionButton -Text '2. RAPIDE CRIT/ERR/AVERT.' -Action 'open-timeline-fast-report' -ToolTip $toolTip -Hint 'Ouvre la vue rapide des journaux Windows limitee aux evenements critiques, erreurs et avertissements, regroupes par fichier EVTX.' -Tone 'primary'
$openSavReportButton = New-DanewActionButton -Text '3. OUVRIR LE RAPPORT SAV' -Action 'open-sav-report' -ToolTip $toolTip -Hint 'Ouvre le rapport SAV principal. A utiliser apres analyse des journaux ou analyse des causes de crash. Si absent, ouvre l index des rapports.' -Tone 'primary'
if ($script:IsWinPE) {
    # WinPE : les rapports HTML s'ouvrent sur le PC technicien — cacher definitivement
    # les boutons HTML et les exclure des ActionButtons.
    $openTimelineReportButton.Visible = $false
    $openTimelineFastReportButton.Visible = $false
    $openSavReportButton.Visible = $false

    # Label informatif dans simplePanel a la place des boutons HTML
    $winpeTechPcLabel = New-Object System.Windows.Forms.Label
    $winpeTechPcLabel.Text = Convert-DanewUiText -Text 'Rapports HTML disponibles sur PC technicien. Branchez la cle USB et lancez : generate-html-reports'
    $winpeTechPcLabel.AutoSize = $false
    $winpeTechPcLabel.Width = 800
    $winpeTechPcLabel.Height = 36
    $winpeTechPcLabel.Left = 0
    $winpeTechPcLabel.Top = 0
    $winpeTechPcLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Italic)
    $winpeTechPcLabel.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
    $winpeTechPcLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
}
else {
    # PC normal : caches initialement, rendus visibles par Update-DanewReportAvailability
    $openTimelineReportButton.Visible = $false
    $openTimelineFastReportButton.Visible = $false
    $openSavReportButton.Visible = $false
}

$quickActionsGroup = New-Object System.Windows.Forms.GroupBox
$quickActionsGroup.Text = 'Actions rapides'
$quickActionsGroup.Left = 14
$quickActionsGroup.Top = 670
$quickActionsGroup.Width = 872
$quickActionsGroup.Height = 70
$quickActionsGroup.Anchor = 'Top,Left,Right'
$quickActionsGroup.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)
$quickActionsGroup.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)

$quickActionsPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$quickActionsPanel.Left = 10
$quickActionsPanel.Top = 20
$quickActionsPanel.Width = 844
$quickActionsPanel.Height = 46
$quickActionsPanel.FlowDirection = 'LeftToRight'
$quickActionsPanel.WrapContents = $false
$quickActionsPanel.Padding = New-Object System.Windows.Forms.Padding(0, 2, 0, 0)

$recommendedActionsButton = New-DanewActionButton -Text '4. ACTIONS RECOMMANDEES' -Action 'recommended-actions' -ToolTip $toolTip -Hint 'Affiche les actions SAV conseillees selon le diagnostic. Les actions sont informatives et non destructives.' -Tone 'neutral'
[void]$quickActionsPanel.Controls.Add($recommendedActionsButton)
$openTextReportsQuickButton = New-DanewActionButton -Text 'TXT/CSV LISTE' -Action 'open-text-reports-list' -ToolTip $toolTip -Hint 'Affiche la liste des rapports TXT, CSV et JSON disponibles.' -Tone 'neutral'
[void]$quickActionsPanel.Controls.Add($openTextReportsQuickButton)
$exportEvtxTargetedButton = $null
$exportEvtxZipButton = $null
$exportSavPackageButton = $null

$advancedToggleButton = New-Object System.Windows.Forms.Button
$advancedToggleButton.Text = 'AFFICHER LES OUTILS AVANCES'
$advancedToggleButton.Width = 236
$advancedToggleButton.Height = 40
$advancedToggleButton.Margin = New-Object System.Windows.Forms.Padding(5, 4, 5, 4)
$advancedToggleButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$advancedToggleButton.FlatAppearance.BorderSize = 2
$advancedToggleButton.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
$advancedToggleButton.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)
$advancedToggleButton.ForeColor = [System.Drawing.Color]::FromArgb(31, 41, 55)
$advancedToggleButton.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
$advancedToggleButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$advancedToggleButton.Add_Click({
    Set-DanewAdvancedToolsVisible -Visible (-not $script:AdvancedToolsVisible)
})
[void]$toolTip.SetToolTip($advancedToggleButton, 'Affiche les outils techniques: scan WinPE, verification WinPE, rapports de base et outils USB. Reserve aux techniciens avances.')
[void]$script:ActionButtons.Add($advancedToggleButton)

$technicalToggleButton = New-Object System.Windows.Forms.Button
$technicalToggleButton.Name = 'ShowTechnicalDetailsButton'
$technicalToggleButton.Text = 'AFFICHER LES DETAILS TECHNIQUES'
$technicalToggleButton.Width = 236
$technicalToggleButton.Height = 40
$technicalToggleButton.Margin = New-Object System.Windows.Forms.Padding(5, 4, 5, 4)
$technicalToggleButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$technicalToggleButton.FlatAppearance.BorderSize = 2
$technicalToggleButton.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
$technicalToggleButton.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)
$technicalToggleButton.ForeColor = [System.Drawing.Color]::FromArgb(31, 41, 55)
$technicalToggleButton.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
$technicalToggleButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$technicalToggleButton.Add_Click({
    Set-DanewTechnicalDetailsVisible -Visible (-not $script:TechnicalDetailsVisible)
})
[void]$toolTip.SetToolTip($technicalToggleButton, 'Affiche les informations techniques du launcher, chemins, runtime, logs et etat interne. Utile pour debug ou support niveau 2.')
[void]$script:ActionButtons.Add($technicalToggleButton)

$recentActivityBox = New-Object System.Windows.Forms.RichTextBox
$recentActivityBox.Left = 14
$recentActivityBox.Top = 78
$recentActivityBox.Width = 844
$recentActivityBox.Height = 54
$recentActivityBox.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::Vertical
$recentActivityBox.ReadOnly = $true
$recentActivityBox.BorderStyle = 'FixedSingle'
$recentActivityBox.BackColor = [System.Drawing.Color]::FromArgb(248, 250, 252)
$recentActivityBox.ForeColor = [System.Drawing.Color]::FromArgb(51, 65, 85)
$recentActivityBox.Font = New-Object System.Drawing.Font('Consolas', 8.5)

# Pre-fill with initial status
$initStatus = @"
[INIT] Gui-launcher demarre
[INIT] Theme: light
[INIT] Rapports: HTML + TXT/CSV + JSON
[INIT] Navigateur portable: detection en cours...
[READY] Interface prete pour l'analyse
"@
$recentActivityBox.Text = $initStatus.Trim()

# Set initial status colors
$recentActivityBox.SelectionStart = 0
$recentActivityBox.SelectionLength = $recentActivityBox.Text.Length
$recentActivityBox.SelectionColor = [System.Drawing.Color]::FromArgb(15, 118, 110)  # READY = teal
$recentActivityBox.SelectionStart = $recentActivityBox.Text.Length
$recentActivityBox.SelectionLength = 0

[void]$simpleActionsGroup.Controls.Add($exportsPanel)
[void]$quickActionsGroup.Controls.Add($quickActionsPanel)

$togglePanel = New-Object System.Windows.Forms.FlowLayoutPanel
$togglePanel.Name = 'CollapsedControlsPanel'
$togglePanel.Left = 14
$togglePanel.Top = 782
$togglePanel.Width = 872
$togglePanel.Height = 44
$togglePanel.Anchor = 'Top,Left,Right'
$togglePanel.FlowDirection = 'LeftToRight'
$togglePanel.WrapContents = $false
$togglePanel.BackColor = [System.Drawing.Color]::FromArgb(243, 246, 252)
[void]$togglePanel.Controls.Add($advancedToggleButton)
[void]$togglePanel.Controls.Add($technicalToggleButton)

$buttonGroup = New-Object System.Windows.Forms.GroupBox
$buttonGroup.Text = 'OUTILS AVANCES (NIVEAU 2)'
$buttonGroup.Name = 'AdvancedToolsPanel'
$buttonGroup.Left = 14
$buttonGroup.Top = 830
$buttonGroup.Width = 872
$buttonGroup.Height = 186
$buttonGroup.Anchor = 'Top,Left,Right'
$buttonGroup.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)

$toolsLayout = New-Object System.Windows.Forms.TableLayoutPanel
$toolsLayout.Dock = 'Fill'
$toolsLayout.ColumnCount = 3
$toolsLayout.RowCount = 1
$toolsLayout.Padding = New-Object System.Windows.Forms.Padding(8)
[void]$toolsLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33.333)))
[void]$toolsLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33.333)))
[void]$toolsLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33.333)))

$quickGroup = New-Object System.Windows.Forms.GroupBox
$quickGroup.Text = 'RAPPORTS'
$quickGroup.Dock = 'Fill'
$quickGroup.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$quickGroup.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)

$analysisGroup = New-Object System.Windows.Forms.GroupBox
$analysisGroup.Text = 'DIAGNOSTIC AVANCE'
$analysisGroup.Dock = 'Fill'
$analysisGroup.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$analysisGroup.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)

$systemGroup = New-Object System.Windows.Forms.GroupBox
$systemGroup.Text = 'OUTILS'
$systemGroup.Dock = 'Fill'
$systemGroup.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$systemGroup.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)

$quickPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$quickPanel.Dock = 'Fill'
$quickPanel.FlowDirection = 'TopDown'
$quickPanel.WrapContents = $false
$quickPanel.AutoScroll = $false
$quickPanel.Padding = New-Object System.Windows.Forms.Padding(8, 10, 8, 8)

$analysisPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$analysisPanel.Dock = 'Fill'
$analysisPanel.FlowDirection = 'TopDown'
$analysisPanel.WrapContents = $false
$analysisPanel.AutoScroll = $false
$analysisPanel.Padding = New-Object System.Windows.Forms.Padding(8, 10, 8, 8)

$systemPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$systemPanel.Dock = 'Fill'
$systemPanel.FlowDirection = 'TopDown'
$systemPanel.WrapContents = $false
$systemPanel.AutoScroll = $false
$systemPanel.Padding = New-Object System.Windows.Forms.Padding(8, 10, 8, 8)

[void]$quickPanel.Controls.Add((New-DanewActionButton -Text 'ACTUALISER LE RESUME' -Action 'refresh-status' -ToolTip $toolTip -Hint 'Recharge les derniers rapports disponibles et met a jour le resume SAV affiche dans l interface.' -Tone 'neutral'))
[void]$quickPanel.Controls.Add((New-DanewActionButton -Text 'OUVRIR LE RAPPORT STOCKAGE' -Action 'open-storage-report' -ToolTip $toolTip -Hint 'Ouvre les preuves de visibilite de stockage et le diagnostic associe.' -Tone 'neutral'))
[void]$quickPanel.Controls.Add((New-DanewActionButton -Text 'OUVRIR LE DOSSIER DES RAPPORTS' -Action 'open-reports-folder' -ToolTip $toolTip -Hint 'Ouvre le dossier reports contenant les rapports HTML, JSON, CSV et TXT generes.' -Tone 'neutral'))

[void]$analysisPanel.Controls.Add((New-DanewActionButton -Text 'SCAN CAPACITES WINPE' -Action 'capability-analysis' -ToolTip $toolTip -Hint 'Analyse les capacites de l environnement WinPE: outils presents, drivers, packages et dependances. Utile pour valider une cle de diagnostic.' -Tone 'neutral'))
[void]$analysisPanel.Controls.Add((New-DanewActionButton -Text 'DIAGNOSTIC COMPLET' -Action 'start-diagnostic' -ToolTip $toolTip -Hint 'Execute la sequence complete en un clic du diagnostic SAV.' -Tone 'neutral'))
[void]$analysisPanel.Controls.Add((New-DanewActionButton -Text 'ANALYSE COMPLETE LOGS' -Action 'analyze-offline-logs-full' -ToolTip $toolTip -Hint 'Lit les journaux Windows EVTX de l installation hors ligne detectee en mode complet. Genere timeline-raw.html, evtx-events.html et les exports CSV/TXT dans reports. Action en lecture seule.' -Tone 'neutral'))
[void]$analysisPanel.Controls.Add((New-DanewActionButton -Text 'VERIFIER WINPE' -Action 'precheck-winpe' -ToolTip $toolTip -Hint 'Verifie que WinPE contient les composants necessaires: PowerShell, WinForms, EVTX, scripts, reports et exports. Genere winpe-precheck.json et winpe-precheck.txt.' -Tone 'neutral'))
[void]$analysisPanel.Controls.Add((New-DanewActionButton -Text 'VERIFIER NAVIGATEUR HTML' -Action 'check-browser' -ToolTip $toolTip -Hint 'Verifie si un navigateur portable est disponible dans tools\\browser pour ouvrir les rapports HTML. Genere browser-detection.json et browser-detection.txt.' -Tone 'neutral'))

[void]$systemPanel.Controls.Add((New-DanewActionButton -Text 'OUTILS USB' -Action 'create-usb-media' -ToolTip $toolTip -Hint 'Prepare ou met a jour l outil USB SAV.' -Tone 'warn'))
[void]$systemPanel.Controls.Add((New-DanewActionButton -Text 'GENERER LE RAPPORT DE BASE' -Action 'generate-report' -ToolTip $toolTip -Hint 'Genere les rapports de base WinPE et environnement. Ne remplace pas l analyse des journaux Windows.' -Tone 'neutral'))
[void]$systemPanel.Controls.Add((New-DanewActionButton -Text 'QUITTER' -Action 'exit' -ToolTip $toolTip -Hint 'Ferme l interface Danew SAV Diagnostic Tool.' -Tone 'danger'))

[void]$quickGroup.Controls.Add($quickPanel)
[void]$analysisGroup.Controls.Add($analysisPanel)
[void]$systemGroup.Controls.Add($systemPanel)

[void]$toolsLayout.Controls.Add($quickGroup, 0, 0)
[void]$toolsLayout.Controls.Add($analysisGroup, 1, 0)
[void]$toolsLayout.Controls.Add($systemGroup, 2, 0)

[void]$buttonGroup.Controls.Add($toolsLayout)

$technicalDetailsGroup = New-Object System.Windows.Forms.GroupBox
$technicalDetailsGroup.Text = 'ACTIVITE TECHNIQUE'
$technicalDetailsGroup.Name = 'TechnicalDetailsPanel'
$technicalDetailsGroup.Left = 910
$technicalDetailsGroup.Top = 96
$technicalDetailsGroup.Width = $script:TechnicalDockWidth
$technicalDetailsGroup.Height = 610
$technicalDetailsGroup.Anchor = 'Top,Bottom,Right'
$technicalDetailsGroup.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)
$technicalDetailsGroup.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

$technicalDetailsSplitContainer = New-Object System.Windows.Forms.SplitContainer
$technicalDetailsSplitContainer.Left = 12
$technicalDetailsSplitContainer.Top = 24
$technicalDetailsSplitContainer.Width = $script:TechnicalDockWidth - 24
$technicalDetailsSplitContainer.Height = 574
$technicalDetailsSplitContainer.Anchor = 'Top,Bottom,Left,Right'
$technicalDetailsSplitContainer.Orientation = [System.Windows.Forms.Orientation]::Horizontal
$technicalDetailsSplitContainer.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$technicalDetailsSplitContainer.BackColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
$technicalDetailsSplitContainer.SplitterWidth = 8
$technicalDetailsSplitContainer.Panel1MinSize = 120
$technicalDetailsSplitContainer.Panel2MinSize = 140
$technicalDetailsSplitContainer.FixedPanel = [System.Windows.Forms.FixedPanel]::None
$technicalDetailsSplitContainer.IsSplitterFixed = $false
$technicalDetailsSplitContainer.SplitterDistance = $script:TechnicalTopPanelHeight
$technicalDetailsSplitContainer.Panel1.Padding = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
$technicalDetailsSplitContainer.Panel2.Padding = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
$technicalDetailsSplitContainer.Add_SplitterMoved({
    $script:TechnicalTopPanelHeight = [int]$technicalDetailsSplitContainer.SplitterDistance
})

$statusTable.Visible = $false

# progressBox fills the entire technical group — recentActivityBox panel removed.
$progressBox.Left = 12
$progressBox.Top = 24
$progressBox.Anchor = 'Top,Bottom,Left,Right'
$progressBox.Dock = 'None'

[void]$technicalDetailsGroup.Controls.Add($statusTable)
[void]$technicalDetailsGroup.Controls.Add($progressBox)

[void]$form.Controls.Add($headerPanel)
[void]$form.Controls.Add($statusGroup)
[void]$form.Controls.Add($primaryGroup)
[void]$form.Controls.Add($simpleActionsGroup)
[void]$form.Controls.Add($quickActionsGroup)
[void]$form.Controls.Add($togglePanel)
[void]$form.Controls.Add($buttonGroup)
[void]$form.Controls.Add($technicalDetailsGroup)

# Safety net: normalize all visible UI captions to avoid mojibake in WinPE hosts.
Repair-DanewControlTreeText -Control $form

Set-DanewAdvancedToolsVisible -Visible $false
Set-DanewTechnicalDetailsVisible -Visible $true
[void](Update-DanewStatusPanel)
[void](Update-DanewSavSummaryCard)
Set-DanewSavSummaryDetailsVisible -Visible $false
[void](Update-DanewReportAvailability)
[void]$form.ShowDialog()
