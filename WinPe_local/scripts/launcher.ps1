[CmdletBinding()]
param(
    [string]$RootPath = (Split-Path -Parent $PSScriptRoot),
    [string]$ConfigPath,
    [switch]$FallbackToCli,
    [switch]$ForceGuiInitFailure,
    [ValidateSet('Interactive', 'scan-winpe', 'capability-analysis', 'generate-report', 'open-reports-folder', 'export-diagnostic-package', 'prepare-startnet', 'start-diagnostic', 'analyze-offline-logs', 'analyze-crash-causes', 'precheck-winpe', 'export-evtx-targeted', 'check-browser', 'create-usb-media', 'real-winpe-validation', 'refresh-status', 'show-status', 'view-last-report', 'exit')]
    [string]$CliFallbackCommand = 'Interactive'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
}
catch {
}

. (Join-Path $PSScriptRoot 'core\Logging.ps1')
. (Join-Path $PSScriptRoot 'catalog\CatalogService.ps1')
. (Join-Path $PSScriptRoot 'scan\ScanEngine.ps1')
. (Join-Path $PSScriptRoot 'profiles\ProfileEngine.ps1')
. (Join-Path $PSScriptRoot 'recommend\RecommendationEngine.ps1')
. (Join-Path $PSScriptRoot 'recommend\EnrichmentPlanner.ps1')
. (Join-Path $PSScriptRoot 'build\BuildPreparation.ps1')
. (Join-Path $PSScriptRoot 'report\ReportEngine.ps1')
. (Join-Path $PSScriptRoot 'security\SecurityService.ps1')
. (Join-Path $PSScriptRoot 'launcher\LauncherCore.ps1')

$config = Get-DanewLauncherConfig -RootPath $RootPath -ConfigPath $ConfigPath
$null = Invoke-DanewLauncherAction -Action 'prepare-startnet' -RootPath $RootPath -Config $config
Write-DanewLauncherActionLog -Config $config -Action 'gui-launcher' -Status 'start' -Message 'GUI launcher initialization started'

$cliPath = Join-Path $PSScriptRoot 'DanewCheckTool.CLI.ps1'

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
$openSavReportButton = $null
$toolTip = $null
$offlineProgressBar = $null
$offlineOperationLabel = $null
$offlineTimingLabel = $null
$stepLabels = @{}
$recentActivityBox = $null
$simpleActionsGroup = $null
$statusGroup = $null
$togglePanel = $null
$advancedToggleButton = $null
$technicalToggleButton = $null
$buttonGroup = $null
$technicalDetailsGroup = $null
$script:ActionButtons = New-Object System.Collections.ArrayList
$script:IsActionRunning = $false
$script:AdvancedToolsVisible = $false
$script:TechnicalDetailsVisible = $false
$script:SavSummaryDetailsVisible = $false
$script:SavSummaryDetailControls = @()

$script:StatusColorDefault = $null
$script:StatusColorPass = $null
$script:StatusColorWarning = $null
$script:StatusColorFail = $null
$script:OfflineProgressStart = $null
$script:OfflineProgressUpdates = 0

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
    $symbols = @('|', '/', '-', '\\')
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
        }
    }

    [System.Windows.Forms.Application]::DoEvents()
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
            $lines = @('No recent activity')
        }
        $recentActivityBox.Text = ($lines -join [Environment]::NewLine)
    }
    catch {
        $recentActivityBox.Text = 'Recent activity unavailable'
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
    if ($Visible -and $technicalDetailsGroup) {
        Show-DanewSecondaryPanelDialog -Title 'DETAILS TECHNIQUES' -Panel $technicalDetailsGroup -Width 900 -Height 330
        $script:TechnicalDetailsVisible = $false
        $technicalDetailsGroup.Visible = $false
        if ($technicalToggleButton) {
            $technicalToggleButton.Text = Convert-DanewUiText -Text 'AFFICHER LES DETAILS TECHNIQUES'
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

    if ($statusGroup) {
        $statusGroup.Height = if ($Visible) { 276 } else { 108 }
    }

    if ($simpleActionsGroup) {
        $simpleActionsGroup.Top = if ($Visible) { 538 } else { 370 }
    }
    if ($togglePanel) {
        $togglePanel.Top = if ($Visible) { 662 } else { 494 }
    }
    if ($buttonGroup) {
        $buttonGroup.Top = if ($Visible) { 710 } else { 542 }
    }
    if ($technicalDetailsGroup) {
        $technicalDetailsGroup.Top = if ($Visible) { 710 } else { 542 }
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
    $dialog.ClientSize = New-Object System.Drawing.Size($Width, $Height)
    $dialog.MinimumSize = New-Object System.Drawing.Size($Width, $Height)
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
    $Panel.Width = $Width - 24
    $Panel.Height = $Height - 24
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
        [string[]]$Names
    )

    foreach ($root in @(Get-DanewReportSearchRoots)) {
        foreach ($name in @($Names)) {
            $path = Join-Path $root $name
            if (Test-Path -Path $path) {
                return $path
            }
        }
    }

    return ''
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

    Add-DanewBrowserCandidate -Path (Join-Path $RootPath 'tools\browser\chrome.exe')
    Add-DanewBrowserCandidate -Path (Join-Path $RootPath 'tools\browser\chromium.exe')
    Add-DanewBrowserCandidate -Path (Join-Path $RootPath 'tools\browser\msedge.exe')

    try {
        $dataVolumes = @(Get-Volume -FileSystemLabel 'DANEW_DATA' -ErrorAction SilentlyContinue)
        foreach ($volume in $dataVolumes) {
            if (-not [string]::IsNullOrWhiteSpace([string]$volume.DriveLetter)) {
                $root = [string]$volume.DriveLetter + ':\'
                Add-DanewBrowserCandidate -Path (Join-Path $root 'tools\browser\chrome.exe')
                Add-DanewBrowserCandidate -Path (Join-Path $root 'tools\browser\chromium.exe')
                Add-DanewBrowserCandidate -Path (Join-Path $root 'tools\browser\msedge.exe')
            }
        }
    }
    catch {
    }

    foreach ($drive in @('E', 'D', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'Y', 'Z')) {
        $root = $drive + ':\'
        Add-DanewBrowserCandidate -Path (Join-Path $root 'tools\browser\chrome.exe')
        Add-DanewBrowserCandidate -Path (Join-Path $root 'tools\browser\chromium.exe')
        Add-DanewBrowserCandidate -Path (Join-Path $root 'tools\browser\msedge.exe')
    }

    foreach ($candidate in @($candidates)) {
        if (Test-Path -Path $candidate) {
            return $candidate
        }
    }

    return ''
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

        if ((Test-Path -Path $full) -and (-not @($roots | Where-Object { $_ -ieq $full }))) {
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
        Add-DanewReportRoot -Path ($drive + ':\reports')
    }

    return @($roots)
}

function Open-DanewReportFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Title
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -Path $Path)) {
        [System.Windows.Forms.MessageBox]::Show('Le rapport n est pas encore disponible. Lancez d abord l analyse.', $Title, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return $false
    }

    $extension = [System.IO.Path]::GetExtension($Path)
    $browser = ''
    if ($extension -and $extension.ToLowerInvariant() -in @('.html', '.htm')) {
        $browser = Get-DanewPortableBrowserPath
    }

    if (-not [string]::IsNullOrWhiteSpace($browser)) {
        Start-Process -FilePath $browser -ArgumentList @($Path) | Out-Null
    }
    elseif ($extension -and $extension.ToLowerInvariant() -in @('.html', '.htm')) {
        [System.Windows.Forms.MessageBox]::Show(
            'Navigateur HTML non disponible. Consultez les rapports TXT/CSV dans le dossier reports.',
            $Title,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        return $false
    }
    else {
        Start-Process -FilePath $Path | Out-Null
    }
    return $true
}

function Open-DanewSpecificReport {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('sav', 'timeline', 'storage')]
        [string]$Kind
    )

    $path = ''
    $title = 'Rapport SAV Danew'
    switch ($Kind) {
        'sav' {
            $path = Get-DanewFirstExistingReportPath -Names @('sav-diagnostic-report.html', 'REPORTS_INDEX.html', 'reports-index.html', 'one-click-diagnostic-report.html', 'offline-windows-failure-report.html')
            $title = 'OUVRIR LE RAPPORT SAV'
        }
        'timeline' {
            $path = Get-DanewFirstExistingReportPath -Names @('timeline-raw.html', 'evtx-events.html', 'REPORTS_INDEX.html', 'timeline-raw.json')
            $title = 'Ouvrir le rapport chronologique'
        }
        'storage' {
            $path = Get-DanewFirstExistingReportPath -Names @('storage-diagnostics.html', 'REPORTS_INDEX.html', 'storage-diagnostics.json', 'storage-analysis.json', 'reports-index.html', 'storage-analysis.html', 'storage-visibility-diagnosis.json')
            $title = 'Ouvrir le rapport de stockage'
        }
    }

    return (Open-DanewReportFile -Path $path -Title $title)
}

function Update-DanewReportAvailability {
    $button = $openSavReportButton
    if (-not $button) {
        return
    }

    $path = Get-DanewFirstExistingReportPath -Names @('sav-diagnostic-report.html', 'REPORTS_INDEX.html', 'reports-index.html', 'one-click-diagnostic-report.html', 'offline-windows-failure-report.html')
    if ([string]::IsNullOrWhiteSpace($path)) {
        $button.Enabled = $false
        $button.Text = Convert-DanewUiText -Text 'Ouvrir le rapport SAV (indisponible)'
        return
    }

    $button.Enabled = $true
    $button.Text = Convert-DanewUiText -Text 'OUVRIR LE RAPPORT SAV'
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
    $button.Width = 236
    $button.Height = 40
    $button.Margin = New-Object System.Windows.Forms.Padding(5, 4, 5, 4)
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderSize = 2
    $button.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand

    $baseBackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)
    $baseBorderColor = [System.Drawing.Color]::FromArgb(59, 130, 246)
    $baseForeColor = [System.Drawing.Color]::FromArgb(30, 64, 175)
    $hoverBackColor = [System.Drawing.Color]::FromArgb(219, 234, 254)

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
        $button.Add_Click(({ Invoke-GuiAction -Action $actionName }).GetNewClosure())
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
        return
    }

    $script:IsActionRunning = $true
    Set-DanewActionButtonsEnabled -Enabled $false
    Set-DanewSummaryVisual -Status 'RUNNING' -Text 'Preparation de l action...'

    try {
        if ($Action -eq 'open-sav-report') {
            [void](Open-DanewSpecificReport -Kind 'sav')
            Set-DanewSummaryVisual -Status 'PASS' -Text 'Rapport SAV ouvert'
            return
        }
        elseif ($Action -eq 'open-timeline-report') {
            [void](Open-DanewSpecificReport -Kind 'timeline')
            Set-DanewSummaryVisual -Status 'PASS' -Text 'Rapport chronologique ouvert'
            return
        }
        elseif ($Action -eq 'open-storage-report') {
            [void](Open-DanewSpecificReport -Kind 'storage')
            Set-DanewSummaryVisual -Status 'PASS' -Text 'Rapport de stockage ouvert'
            return
        }
        elseif ($Action -eq 'recommended-actions') {
            Show-DanewRecommendedActions
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
        if ($Action -eq 'analyze-offline-logs') {
            $script:OfflineProgressStart = Get-Date
            $script:OfflineProgressUpdates = 0
            Set-DanewSavSummaryDetailsVisible -Visible $false
            if ($progressBox) {
                $progressBox.Text = ''
            }
            if ($summaryLabel) {
                $summaryLabel.Text = 'Analyse des journaux Windows hors ligne...'
            }
            Set-DanewSummaryVisual -Status 'RUNNING' -Text 'Analyse hors ligne en cours...'
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

            $offlineProgress = {
                param([string]$Message)
                Update-OfflineProgressFromLine -Line $Message
            }

            $res = Invoke-DanewLauncherAction -Action $Action -RootPath $RootPath -Config $config -RuntimeSystemDrive $env:SystemDrive -CurrentLocationPath (Get-Location).Path -ProgressCallback $offlineProgress -SuppressActionLog:$suppressLog
        }
        else {
            $res = Invoke-DanewLauncherAction -Action $Action -RootPath $RootPath -Config $config -RuntimeSystemDrive $env:SystemDrive -CurrentLocationPath (Get-Location).Path -SuppressActionLog:$suppressLog
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
        elseif ($Action -eq 'analyze-offline-logs') {
            $offline = $res.output
            $summary = $offline.summary
            $failure = $offline.failure_report
            if ($offlineProgressBar) {
                $offlineProgressBar.Style = 'Continuous'
                $offlineProgressBar.MarqueeAnimationSpeed = 0
                $offlineProgressBar.Value = 100
            }
            if ($summaryLabel) {
                $summaryLabel.Text = 'Analyse des journaux Windows hors ligne terminee. Global=' + (Get-DanewLocalizedStatusText ([string]$offline.overall_status))
            }
            Set-DanewSummaryVisual -Status ([string]$offline.overall_status) -Text ('Analyse hors ligne terminee : ' + (Get-DanewLocalizedStatusText ([string]$offline.overall_status)))
            if ($offlineOperationLabel) {
                $offlineOperationLabel.Text = 'Operation en cours : terminee'
            }
            if ($offlineTimingLabel) {
                $offlineTimingLabel.Text = 'Ecoule : termine    ETA : 00:00'
            }
            Add-DiagnosticProgressLine -Line 'Analyse des journaux hors ligne terminee. Consulter le resume SAV pour le detail.'
            Add-DiagnosticProgressLine -Line ('Temps total ecoule : ' + (Get-DanewElapsedText -Since $script:OfflineProgressStart))

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
    }
    catch {
        Set-DanewSummaryVisual -Status 'FAIL' -Text ('Failed: ' + $Action)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Danew SAV Diagnostic Tool Error') | Out-Null
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

    Add-DiagnosticProgressLine -Line $Line

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
            if ($summaryLabel) {
                $summaryLabel.Text = 'Summary: Offline logs running - ' + [string]$value + '%'
            }
            Set-DanewSummaryVisual -Status 'RUNNING' -Text ('Offline logs running: ' + [string]$value + '%')
        }
    }

    if ($offlineOperationLabel) {
        $stepMatch = [regex]::Match($Line, 'Step\s+\d+/\d+\s+-\s+([^|]+)')
        if ($stepMatch.Success) {
            $script:OfflineProgressUpdates++
            $spinner = Get-DanewOfflineSpinnerSymbol
            $offlineOperationLabel.Text = 'Current operation: ' + $stepMatch.Groups[1].Value.Trim() + '  [' + $spinner + ']'
        }
        elseif ($Line -match '^\[(\d+)%\]') {
            $script:OfflineProgressUpdates++
            $spinner = Get-DanewOfflineSpinnerSymbol
            $offlineOperationLabel.Text = 'Current operation: processing evidence  [' + $spinner + ']'
        }
    }

    if ($offlineTimingLabel) {
        $timingMatch = [regex]::Match($Line, '\|\s*Elapsed\s*([0-9:]+)\s*\|\s*ETA\s*([0-9:]+)')
        if ($timingMatch.Success) {
            $offlineTimingLabel.Text = 'Elapsed: ' + $timingMatch.Groups[1].Value + '    ETA: ' + $timingMatch.Groups[2].Value
        }
        else {
            $offlineTimingLabel.Text = 'Elapsed: ' + (Get-DanewElapsedText -Since $script:OfflineProgressStart) + '    ETA: updating...'
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
    if ($summaryLabel) {
        $summaryLabel.Text = 'Diagnosis in progress...'
    }
    Set-DanewSummaryVisual -Status 'RUNNING' -Text 'Analyzing this PC...'
    if ($offlineOperationLabel) {
        $offlineOperationLabel.Text = 'Current operation: collecting diagnostic evidence'
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

    Write-DanewLauncherActionLog -Config $config -Action 'gui-launcher' -Status 'ok' -Message 'GUI assemblies loaded'
}
catch {
    Write-DanewLauncherActionLog -Config $config -Action 'gui-launcher' -Status 'error' -Message $_.Exception.Message
    if ($FallbackToCli) {
        Write-DanewLauncherActionLog -Config $config -Action 'cli-fallback' -Status 'start' -Message 'GUI failed, switching to CLI'
        & $cliPath -RootPath $RootPath -ConfigPath $ConfigPath -Command $CliFallbackCommand
        Write-DanewLauncherActionLog -Config $config -Action 'cli-fallback' -Status 'ok' -Message 'CLI fallback exited'
        exit 0
    }
    throw
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
$form.AutoScroll = $false
$form.AutoScrollMinSize = New-Object System.Drawing.Size(900, 720)
$form.MinimumSize = New-Object System.Drawing.Size(900, 700)
$form.BackColor = [System.Drawing.Color]::FromArgb(243, 246, 252)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

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
$subtitleLabel.Text = 'OEM offline crash, boot, and storage diagnosis assistant'

[void]$headerPanel.Controls.Add($logoBox)
[void]$headerPanel.Controls.Add($titleLabel)
[void]$headerPanel.Controls.Add($subtitleLabel)

$statusGroup = New-Object System.Windows.Forms.GroupBox
$statusGroup.Text = 'SAV Summary'
$statusGroup.Left = 14
$statusGroup.Top = 250
$statusGroup.Width = 872
$statusGroup.Height = 276
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
$statusTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 132)))
$statusTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
$statusTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 142)))
$statusTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))

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
$resultTitleLabel.Top = 24
$resultTitleLabel.Width = 380
$resultTitleLabel.Height = 28
$resultTitleLabel.Text = 'Resume du diagnostic'
$resultTitleLabel.ForeColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
$resultTitleLabel.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)

$overallBadgeLabel = New-Object System.Windows.Forms.Label
$overallBadgeLabel.Left = 720
$overallBadgeLabel.Top = 24
$overallBadgeLabel.Width = 110
$overallBadgeLabel.Height = 26
$overallBadgeLabel.Text = 'En attente'
$overallBadgeLabel.TextAlign = 'MiddleCenter'
$overallBadgeLabel.BackColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
$overallBadgeLabel.ForeColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
$overallBadgeLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)

$summaryLabel = New-Object System.Windows.Forms.Label
$summaryLabel.Left = 16
$summaryLabel.Top = 56
$summaryLabel.Width = 832
$summaryLabel.Height = 24
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

    $registry = Get-DanewObjectValue -Object $offline -Name 'registry_metadata' -Default $null
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
    elseif (-not [string]::IsNullOrWhiteSpace($currentBuild)) {
        $parts += ('build ' + $currentBuild)
    }

    return ('Windows : ' + ($parts -join ' '))
}

function Update-DanewSummaryChips {
    param(
        [AllowNull()]
        [object]$Snapshot
    )

    if (-not $runtimeChipLabel -and -not $windowsChipLabel -and -not $usbChipLabel) {
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

    if ($runtimeChipLabel) { $runtimeChipLabel.Text = $runtimeText }
    if ($windowsChipLabel) { $windowsChipLabel.Text = $windowsText }
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

$probableCauseCaptionLabel = New-DanewSummaryFieldLabel -Caption 'Cause probable' -Left 16 -Top 102 -Width 400
[void]$statusGroup.Controls.Add($probableCauseCaptionLabel)
$probableCauseValueLabel = New-DanewSummaryValueLabel -Text 'Lancer l analyse pour identifier la cause probable.' -Left 16 -Top 120 -Width 530 -Height 38
[void]$statusGroup.Controls.Add($probableCauseValueLabel)

$confidenceCaptionLabel = New-DanewSummaryFieldLabel -Caption 'Confiance' -Left 566 -Top 102 -Width 130
[void]$statusGroup.Controls.Add($confidenceCaptionLabel)
$confidenceValueLabel = New-DanewSummaryValueLabel -Text 'INCONNUE' -Left 566 -Top 120 -Width 130 -Height 38
[void]$statusGroup.Controls.Add($confidenceValueLabel)

$severityCaptionLabel = New-DanewSummaryFieldLabel -Caption 'Severite' -Left 712 -Top 102 -Width 136
[void]$statusGroup.Controls.Add($severityCaptionLabel)
$severityValueLabel = New-DanewSummaryValueLabel -Text 'INFO' -Left 712 -Top 120 -Width 136 -Height 38
[void]$statusGroup.Controls.Add($severityValueLabel)

$windowsStatusCaptionLabel = New-DanewSummaryFieldLabel -Caption 'Detection Windows' -Left 16 -Top 166 -Width 260
[void]$statusGroup.Controls.Add($windowsStatusCaptionLabel)
$windowsStatusValueLabel = New-DanewSummaryValueLabel -Text 'Inconnu' -Left 16 -Top 184 -Width 260 -Height 34
[void]$statusGroup.Controls.Add($windowsStatusValueLabel)

$storageStatusCaptionLabel = New-DanewSummaryFieldLabel -Caption 'Visibilite du stockage' -Left 292 -Top 166 -Width 260
[void]$statusGroup.Controls.Add($storageStatusCaptionLabel)
$storageStatusValueLabel = New-DanewSummaryValueLabel -Text 'Inconnu' -Left 292 -Top 184 -Width 260 -Height 34
[void]$statusGroup.Controls.Add($storageStatusValueLabel)

$criticalEventsCaptionLabel = New-DanewSummaryFieldLabel -Caption 'Evenements critiques' -Left 568 -Top 166 -Width 260
[void]$statusGroup.Controls.Add($criticalEventsCaptionLabel)
$criticalEventsValueLabel = New-DanewSummaryValueLabel -Text '0' -Left 568 -Top 184 -Width 260 -Height 34
[void]$statusGroup.Controls.Add($criticalEventsValueLabel)

$recommendedActionValueLabel = $null
$recommendedActionCaptionLabel = New-DanewSummaryFieldLabel -Caption 'Prochaine action recommandee' -Left 16 -Top 222 -Width 832
[void]$statusGroup.Controls.Add($recommendedActionCaptionLabel)
$recommendedActionValueLabel = New-DanewSummaryValueLabel -Text 'Analyser d abord les journaux Windows.' -Left 16 -Top 240 -Width 832 -Height 36
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

$runtimeChipLabel = New-DanewChipLabel -Text ('Execution : ' + $runtimeTitle) -Left 16 -Top 80 -Width 176
$windowsChipLabel = New-DanewChipLabel -Text 'Windows : Inconnu' -Left 208 -Top 80 -Width 260
$usbChipLabel = New-DanewChipLabel -Text 'USB : Inconnu' -Left 484 -Top 80 -Width 176
[void]$statusGroup.Controls.Add($runtimeChipLabel)
[void]$statusGroup.Controls.Add($windowsChipLabel)
[void]$statusGroup.Controls.Add($usbChipLabel)

$savSummaryLabel = $summaryLabel
$savOverallBadgeLabel = $overallBadgeLabel

$primaryGroup = New-Object System.Windows.Forms.GroupBox
$primaryGroup.Text = 'Actions principales de diagnostic'
$primaryGroup.Left = 14
$primaryGroup.Top = 96
$primaryGroup.Width = 872
$primaryGroup.Height = 150
$primaryGroup.Anchor = 'Top,Left,Right'
$primaryGroup.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$primaryGroup.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)

$offlineOperationLabel = New-Object System.Windows.Forms.Label
$offlineOperationLabel.Left = 22
$offlineOperationLabel.Top = 104
$offlineOperationLabel.Width = 844
$offlineOperationLabel.Height = 20
$offlineOperationLabel.Text = 'Pret. Commencer par les journaux Windows, puis l analyse des causes de crash.'
$offlineOperationLabel.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
$offlineOperationLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$offlineProgressBar = New-Object System.Windows.Forms.ProgressBar
$offlineProgressBar.Left = 22
$offlineProgressBar.Top = 126
$offlineProgressBar.Width = 828
$offlineProgressBar.Height = 18
$offlineProgressBar.Minimum = 0
$offlineProgressBar.Maximum = 100
$offlineProgressBar.Value = 0
$offlineProgressBar.Style = 'Continuous'

$offlineTimingLabel = New-Object System.Windows.Forms.Label
$offlineTimingLabel.Left = 14
$offlineTimingLabel.Top = 146
$offlineTimingLabel.Width = 844
$offlineTimingLabel.Height = 20
$offlineTimingLabel.Text = 'Ecoule : 00:00    ETA : --:--'
$offlineTimingLabel.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
$offlineTimingLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9)

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

$analyzeWindowsLogsButton = New-DanewPrimaryDiagnosticButton -Name 'AnalyzeWindowsLogsButton' -Text 'ANALYSER LES JOURNAUX WINDOWS' -Action 'analyze-offline-logs' -ToolTip $toolTip -Hint 'Lit les journaux Windows EVTX de l installation hors ligne detectee. Genere timeline-raw.html, evtx-events.html et les exports CSV/TXT dans reports. Action en lecture seule.' -Tone 'blue'
$analyzeWindowsLogsButton.Left = 22
$analyzeWindowsLogsButton.Top = 28

$analyzeCrashCausesButton = New-DanewPrimaryDiagnosticButton -Name 'AnalyzeCrashCausesButton' -Text 'ANALYSER LES CAUSES DE CRASH' -Action 'analyze-crash-causes' -ToolTip $toolTip -Hint 'Analyse les evenements Windows deja lus pour identifier les causes probables de panne. Genere le rapport SAV principal avec confiance, gravite et preuves. Action en lecture seule.' -Tone 'orange'
$analyzeCrashCausesButton.Left = 442
$analyzeCrashCausesButton.Top = 28

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

[void]$primaryGroup.Controls.Add($analyzeWindowsLogsButton)
[void]$primaryGroup.Controls.Add($analyzeCrashCausesButton)
[void]$primaryGroup.Controls.Add($offlineOperationLabel)
[void]$primaryGroup.Controls.Add($offlineProgressBar)
[void]$primaryGroup.Controls.Add($offlineTimingLabel)
$summaryLabel = $savSummaryLabel
$overallBadgeLabel = $savOverallBadgeLabel

$simpleActionsGroup = New-Object System.Windows.Forms.GroupBox
$simpleActionsGroup.Text = 'Rapports et actions'
$simpleActionsGroup.Left = 14
$simpleActionsGroup.Top = 538
$simpleActionsGroup.Width = 872
$simpleActionsGroup.Height = 112
$simpleActionsGroup.Anchor = 'Top,Left,Right'
$simpleActionsGroup.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)
$simpleActionsGroup.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)

$simplePanel = New-Object System.Windows.Forms.FlowLayoutPanel
$simplePanel.Left = 10
$simplePanel.Top = 22
$simplePanel.Width = 844
$simplePanel.Height = 84
$simplePanel.FlowDirection = 'LeftToRight'
$simplePanel.WrapContents = $true
$simplePanel.Padding = New-Object System.Windows.Forms.Padding(0)

$openSavReportButton = New-DanewActionButton -Text 'OUVRIR LE RAPPORT SAV' -Action 'open-sav-report' -ToolTip $toolTip -Hint 'Ouvre le rapport SAV principal. A utiliser apres analyse des journaux ou analyse des causes de crash. Si absent, ouvre l index des rapports.' -Tone 'primary'
[void]$simplePanel.Controls.Add($openSavReportButton)
[void]$simplePanel.Controls.Add((New-DanewActionButton -Text 'OUVRIR LE RAPPORT CHRONOLOGIQUE' -Action 'open-timeline-report' -ToolTip $toolTip -Hint 'Ouvre la chronologie interactive des evenements Windows. Permet de filtrer, trier et rechercher les erreurs, critiques et avertissements.' -Tone 'neutral'))
[void]$simplePanel.Controls.Add((New-DanewActionButton -Text 'EXPORTER LE DOSSIER SAV' -Action 'export-diagnostic-package' -ToolTip $toolTip -Hint 'Cree un package SAV avec les rapports, journaux et exports disponibles. Utile pour archivage, envoi SAV ou analyse hors ligne.' -Tone 'neutral'))
[void]$simplePanel.Controls.Add((New-DanewActionButton -Text 'EXPORT EVTX CIBLE' -Action 'export-evtx-targeted' -ToolTip $toolTip -Hint 'Genere les exports EVTX physiques dans reports: evenements filtres, evenements critiques, fenetre crash et resume SAV TXT. Ne depend pas du navigateur HTML.' -Tone 'neutral'))
[void]$simplePanel.Controls.Add((New-DanewActionButton -Text 'ACTIONS RECOMMANDEES' -Action 'recommended-actions' -ToolTip $toolTip -Hint 'Affiche les actions SAV conseillees selon le diagnostic. Les actions sont informatives et non destructives.' -Tone 'neutral'))

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

$recentActivityBox = New-Object System.Windows.Forms.TextBox
$recentActivityBox.Left = 14
$recentActivityBox.Top = 78
$recentActivityBox.Width = 844
$recentActivityBox.Height = 54
$recentActivityBox.Multiline = $true
$recentActivityBox.ScrollBars = 'Vertical'
$recentActivityBox.ReadOnly = $true
$recentActivityBox.BorderStyle = 'FixedSingle'
$recentActivityBox.BackColor = [System.Drawing.Color]::FromArgb(248, 250, 252)
$recentActivityBox.ForeColor = [System.Drawing.Color]::FromArgb(51, 65, 85)
$recentActivityBox.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$recentActivityBox.Text = 'Recent activity: idle'

[void]$simpleActionsGroup.Controls.Add($simplePanel)

$togglePanel = New-Object System.Windows.Forms.FlowLayoutPanel
$togglePanel.Name = 'CollapsedControlsPanel'
$togglePanel.Left = 14
$togglePanel.Top = 662
$togglePanel.Width = 872
$togglePanel.Height = 44
$togglePanel.Anchor = 'Top,Left,Right'
$togglePanel.FlowDirection = 'LeftToRight'
$togglePanel.WrapContents = $false
$togglePanel.BackColor = [System.Drawing.Color]::FromArgb(243, 246, 252)
[void]$togglePanel.Controls.Add($advancedToggleButton)
[void]$togglePanel.Controls.Add($technicalToggleButton)

$buttonGroup = New-Object System.Windows.Forms.GroupBox
$buttonGroup.Text = 'OUTILS AVANCES'
$buttonGroup.Name = 'AdvancedToolsPanel'
$buttonGroup.Left = 14
$buttonGroup.Top = 710
$buttonGroup.Width = 872
$buttonGroup.Height = 186
$buttonGroup.Anchor = 'Top,Left,Right'
$buttonGroup.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)

$toolsLayout = New-Object System.Windows.Forms.TableLayoutPanel
$toolsLayout.Dock = 'Fill'
$toolsLayout.ColumnCount = 3
$toolsLayout.RowCount = 1
$toolsLayout.Padding = New-Object System.Windows.Forms.Padding(8)
$toolsLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33.333)))
$toolsLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33.333)))
$toolsLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33.333)))

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
[void]$quickPanel.Controls.Add((New-DanewActionButton -Text 'OUVRIR LE RAPPORT STOCKAGE' -Action 'open-storage-report' -ToolTip $toolTip -Hint 'Open storage visibility and diagnostics evidence.' -Tone 'neutral'))
[void]$quickPanel.Controls.Add((New-DanewActionButton -Text 'OUVRIR LE DOSSIER DES RAPPORTS' -Action 'open-reports-folder' -ToolTip $toolTip -Hint 'Ouvre le dossier reports contenant les rapports HTML, JSON, CSV et TXT generes.' -Tone 'neutral'))

[void]$analysisPanel.Controls.Add((New-DanewActionButton -Text 'SCAN CAPACITES WINPE' -Action 'capability-analysis' -ToolTip $toolTip -Hint 'Analyse les capacites de l environnement WinPE: outils presents, drivers, packages et dependances. Utile pour valider une cle de diagnostic.' -Tone 'neutral'))
[void]$analysisPanel.Controls.Add((New-DanewActionButton -Text 'DIAGNOSTIC COMPLET' -Action 'start-diagnostic' -ToolTip $toolTip -Hint 'Run the complete one-click diagnostic sequence.' -Tone 'neutral'))
[void]$analysisPanel.Controls.Add((New-DanewActionButton -Text 'ANALYSER LES JOURNAUX WINDOWS' -Action 'analyze-offline-logs' -ToolTip $toolTip -Hint 'Lit les journaux Windows EVTX de l installation hors ligne detectee. Genere timeline-raw.html, evtx-events.html et les exports CSV/TXT dans reports. Action en lecture seule.' -Tone 'neutral'))
[void]$analysisPanel.Controls.Add((New-DanewActionButton -Text 'VERIFIER WINPE' -Action 'precheck-winpe' -ToolTip $toolTip -Hint 'Verifie que WinPE contient les composants necessaires: PowerShell, WinForms, EVTX, scripts, reports et exports. Genere winpe-precheck.json et winpe-precheck.txt.' -Tone 'neutral'))
[void]$analysisPanel.Controls.Add((New-DanewActionButton -Text 'VERIFIER NAVIGATEUR HTML' -Action 'check-browser' -ToolTip $toolTip -Hint 'Verifie si un navigateur portable est disponible dans tools\\browser pour ouvrir les rapports HTML. Genere browser-detection.json et browser-detection.txt.' -Tone 'neutral'))

[void]$systemPanel.Controls.Add((New-DanewActionButton -Text 'OUTILS USB' -Action 'create-usb-media' -ToolTip $toolTip -Hint 'Prepare or refresh the SAV USB tool.' -Tone 'warn'))
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
$technicalDetailsGroup.Text = 'DETAILS TECHNIQUES'
$technicalDetailsGroup.Name = 'TechnicalDetailsPanel'
$technicalDetailsGroup.Left = 14
$technicalDetailsGroup.Top = 710
$technicalDetailsGroup.Width = 872
$technicalDetailsGroup.Height = 190
$technicalDetailsGroup.Anchor = 'Top,Left,Right'
$technicalDetailsGroup.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)
$technicalDetailsGroup.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

$statusTable.Dock = 'None'
$statusTable.Left = 10
$statusTable.Top = 22
$statusTable.Width = 520
$statusTable.Height = 150

$progressBox.Left = 544
$progressBox.Top = 22
$progressBox.Width = 314
$progressBox.Height = 86

$recentActivityBox.Left = 544
$recentActivityBox.Top = 116
$recentActivityBox.Width = 314
$recentActivityBox.Height = 56

[void]$technicalDetailsGroup.Controls.Add($statusTable)
[void]$technicalDetailsGroup.Controls.Add($progressBox)
[void]$technicalDetailsGroup.Controls.Add($recentActivityBox)

[void]$form.Controls.Add($headerPanel)
[void]$form.Controls.Add($statusGroup)
[void]$form.Controls.Add($primaryGroup)
[void]$form.Controls.Add($simpleActionsGroup)
[void]$form.Controls.Add($togglePanel)
[void]$form.Controls.Add($buttonGroup)
[void]$form.Controls.Add($technicalDetailsGroup)

# Safety net: normalize all visible UI captions to avoid mojibake in WinPE hosts.
Repair-DanewControlTreeText -Control $form

Set-DanewAdvancedToolsVisible -Visible $false
Set-DanewTechnicalDetailsVisible -Visible $false
[void](Update-DanewStatusPanel)
[void](Update-DanewSavSummaryCard)
Set-DanewSavSummaryDetailsVisible -Visible $false
Update-DanewReportAvailability
[void]$form.ShowDialog()
