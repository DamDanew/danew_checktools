[CmdletBinding()]
param(
    [string]$RootPath = (Split-Path -Parent $PSScriptRoot),
    [string]$ConfigPath,
    [switch]$FallbackToCli,
    [switch]$ForceGuiInitFailure,
    [ValidateSet('Interactive', 'scan-winpe', 'capability-analysis', 'generate-report', 'open-reports-folder', 'export-diagnostic-package', 'prepare-startnet', 'start-diagnostic', 'analyze-offline-logs', 'analyze-crash-causes', 'create-usb-media', 'real-winpe-validation', 'exit')]
    [string]$CliFallbackCommand = 'Interactive'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
$offlineProgressBar = $null
$offlineOperationLabel = $null
$offlineTimingLabel = $null
$stepLabels = @{}
$recentActivityBox = $null
$simpleActionsGroup = $null
$advancedToggleButton = $null
$buttonGroup = $null
$script:ActionButtons = New-Object System.Collections.ArrayList
$script:IsActionRunning = $false
$script:AdvancedToolsVisible = $false

$script:StatusColorDefault = $null
$script:StatusColorPass = $null
$script:StatusColorWarning = $null
$script:StatusColorFail = $null

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
        $statusFields[$Name].Text = $Value
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
    $badgeText = if ([string]::IsNullOrWhiteSpace($normalized)) { 'IDLE' } else { $normalized }
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
    elseif ($normalized -eq 'FAIL' -or $normalized -eq 'ERROR') {
        $badgeBack = [System.Drawing.Color]::FromArgb(220, 38, 38)
        $badgeFore = [System.Drawing.Color]::White
    }
    elseif ($normalized -eq 'RUNNING') {
        $badgeBack = [System.Drawing.Color]::FromArgb(37, 99, 235)
        $badgeFore = [System.Drawing.Color]::White
    }

    if ($overallBadgeLabel) {
        $overallBadgeLabel.Text = $badgeText
        $overallBadgeLabel.BackColor = $badgeBack
        $overallBadgeLabel.ForeColor = $badgeFore
    }

    if ($summaryLabel -and -not [string]::IsNullOrWhiteSpace($Text)) {
        $summaryLabel.Text = $Text
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
        $advancedToggleButton.Text = if ($Visible) { 'Hide Advanced Tools' } else { 'Show Advanced Tools' }
    }
    if ($form) {
        $scrollHeight = if ($Visible) { 980 } else { 760 }
        $form.AutoScrollMinSize = New-Object System.Drawing.Size(900, $scrollHeight)
    }
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
    $button.Text = $Text
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
        $ToolTip.SetToolTip($button, $Hint)
    }

    if ($Action -eq 'exit') {
        $button.Add_Click({
            if ($script:IsActionRunning) { return }
            Invoke-DanewLauncherAction -Action 'exit' -RootPath $RootPath -Config $config | Out-Null
            $form.Close()
        })
    }
    else {
        $actionName = [string]$Action
        $button.Add_Click(({ Invoke-GuiAction -Action $actionName }).GetNewClosure())
    }

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
    Update-DanewRecentActivity

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
    Set-DanewSummaryVisual -Status 'RUNNING' -Text ('Running: ' + $Action)

    try {
        if ($Action -eq 'create-usb-media') {
            $usbDetails = 'This will prepare bootable USB media and may erase the selected target disk.' + [Environment]::NewLine + [Environment]::NewLine +
                'Current selected USB disk: ' + [string](Get-DanewLauncherSelectedUsbDisk -Config $config) + [Environment]::NewLine +
                'Continue only if the target disk is correct.'
            $confirmUsb = [System.Windows.Forms.MessageBox]::Show($usbDetails, 'Confirm USB Media Creation', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($confirmUsb -ne [System.Windows.Forms.DialogResult]::Yes) {
                Set-DanewSummaryVisual -Status 'IDLE' -Text 'USB media creation cancelled'
                return
            }
        }

        $suppressLog = $Action -in @('refresh-status', 'view-last-report')
        if ($Action -eq 'analyze-offline-logs') {
            if ($progressBox) {
                $progressBox.Text = ''
            }
            if ($summaryLabel) {
                $summaryLabel.Text = 'Summary: Offline logs running...'
            }
            Set-DanewSummaryVisual -Status 'RUNNING' -Text 'Offline logs running...'
            if ($offlineOperationLabel) {
                $offlineOperationLabel.Text = 'Current operation: initializing'
            }
            if ($offlineTimingLabel) {
                $offlineTimingLabel.Text = 'Elapsed: 00:00    ETA: --:--'
            }
            if ($offlineProgressBar) {
                $offlineProgressBar.Value = 0
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
            $message = if ($view.opened) { "Last report opened: $($view.path)" } else { "Last report: $($view.path)`n$($view.reason)" }
            [System.Windows.Forms.MessageBox]::Show($message, 'Danew Launcher') | Out-Null
        }
        elseif ($Action -eq 'refresh-status') {
            [void](Update-DanewStatusPanel)
            Set-DanewSummaryVisual -Status 'PASS' -Text 'Status refreshed'
        }
        elseif ($Action -eq 'analyze-offline-logs') {
            $offline = $res.output
            $summary = $offline.summary
            $failure = $offline.failure_report
            if ($offlineProgressBar) {
                $offlineProgressBar.Value = 100
            }
            if ($summaryLabel) {
                $summaryLabel.Text = 'Summary: Offline logs complete. Overall=' + [string]$offline.overall_status
            }
            Set-DanewSummaryVisual -Status ([string]$offline.overall_status) -Text ('Offline logs complete: ' + [string]$offline.overall_status)
            if ($offlineOperationLabel) {
                $offlineOperationLabel.Text = 'Current operation: complete'
            }
            if ($offlineTimingLabel) {
                $offlineTimingLabel.Text = 'Elapsed: complete    ETA: 00:00'
            }
            $message = 'Offline logs analysis complete.' + [Environment]::NewLine +
                'Overall: ' + [string]$offline.overall_status + [Environment]::NewLine +
                'Discovery case: ' + [string]$offline.discovery_case + [Environment]::NewLine +
                'Discovery summary: ' + [string]$offline.discovery_case_message + [Environment]::NewLine +
                'Primary disk status: ' + [string]$offline.primary_disk_status + [Environment]::NewLine +
                'Storage visibility case: ' + [string]$offline.storage_visibility_case + [Environment]::NewLine +
                'Confidence: ' + [string]$failure.confidence + [Environment]::NewLine +
                'Events: ' + [string]$summary.total_events + [Environment]::NewLine +
                'Missing required logs: ' + [string]$summary.missing_required_logs + [Environment]::NewLine +
                'Summary report: ' + [string]$offline.artifacts.evtx_summary

            if ($offline.preferred_windows_volume) {
                $message += [Environment]::NewLine + 'Preferred Windows volume: ' + [string]$offline.preferred_windows_volume.path
            }

            if ([string]$failure.status -eq 'generated') {
                $topCause = @($failure.probable_causes | Select-Object -First 1)
                if (@($topCause).Count -gt 0) {
                    $message += [Environment]::NewLine + 'Possible cause: ' + [string]$topCause[0].cause
                }
                $message += [Environment]::NewLine + 'SAV failure report: ' + [string]$offline.artifacts.offline_windows_failure_report_html
            }

            [System.Windows.Forms.MessageBox]::Show($message, 'Danew Launcher') | Out-Null

            if ([string]$failure.status -eq 'generated' -and -not [string]::IsNullOrWhiteSpace([string]$offline.artifacts.offline_windows_failure_report_html)) {
                $askOpen = [System.Windows.Forms.MessageBox]::Show('Open SAV failure report now?', 'Danew Launcher', [System.Windows.Forms.MessageBoxButtons]::YesNo)
                if ($askOpen -eq [System.Windows.Forms.DialogResult]::Yes) {
                    try {
                        Start-Process -FilePath [string]$offline.artifacts.offline_windows_failure_report_html | Out-Null
                    }
                    catch {
                    }
                }
            }
            [void](Update-DanewStatusPanel)
        }
        elseif ($Action -eq 'analyze-crash-causes') {
            $crash = $res.output
            $primary = $crash.root_cause_analysis.primary_cause
            $topEvidence = @($crash.evidence_correlation.correlations | Select-Object -First 1)
            $topEvidenceSummary = 'n/a'
            if (@($topEvidence).Count -gt 0) {
                $topEvidenceSummary = [string]$topEvidence[0].summary
            }
            $message = 'Crash cause analysis complete.' + [Environment]::NewLine +
                'Severity: ' + [string]$crash.severity + [Environment]::NewLine +
                'Primary cause: ' + [string]$primary.cause + [Environment]::NewLine +
                'Confidence: ' + [string]$primary.confidence + [Environment]::NewLine +
                'Top evidence: ' + $topEvidenceSummary + [Environment]::NewLine +
                'Report: ' + [string]$crash.report_paths.sav_diagnostic_report_html
            [System.Windows.Forms.MessageBox]::Show($message, 'Danew Launcher') | Out-Null
            if (-not [string]::IsNullOrWhiteSpace([string]$crash.report_paths.sav_diagnostic_report_html)) {
                try {
                    Start-Process -FilePath [string]$crash.report_paths.sav_diagnostic_report_html | Out-Null
                }
                catch {
                }
            }
            [void](Update-DanewStatusPanel)
        }
        elseif ($Action -eq 'create-usb-media') {
            Set-DanewSummaryVisual -Status 'PASS' -Text 'USB media report generated'
            [System.Windows.Forms.MessageBox]::Show('USB media action completed. Check the USB readiness status and report.', 'Danew Launcher') | Out-Null
            [void](Update-DanewStatusPanel)
        }
        elseif ($Action -ne 'exit') {
            Set-DanewSummaryVisual -Status 'PASS' -Text ('Completed: ' + [string]$res.action)
            [System.Windows.Forms.MessageBox]::Show("Action completed: $($res.action)", 'Danew Launcher') | Out-Null
            [void](Update-DanewStatusPanel)
        }
    }
    catch {
        Set-DanewSummaryVisual -Status 'FAIL' -Text ('Failed: ' + $Action)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Danew Launcher Error') | Out-Null
    }
    finally {
        $script:IsActionRunning = $false
        Set-DanewActionButtonsEnabled -Enabled $true
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
            $offlineOperationLabel.Text = 'Current operation: ' + $stepMatch.Groups[1].Value.Trim()
        }
    }

    if ($offlineTimingLabel) {
        $timingMatch = [regex]::Match($Line, '\|\s*Elapsed\s*([0-9:]+)\s*\|\s*ETA\s*([0-9:]+)')
        if ($timingMatch.Success) {
            $offlineTimingLabel.Text = 'Elapsed: ' + $timingMatch.Groups[1].Value + '    ETA: ' + $timingMatch.Groups[2].Value
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
        $summaryLabel.Text = 'Summary: Running...'
    }
    Set-DanewSummaryVisual -Status 'RUNNING' -Text 'Diagnostic running...'

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

        $summaryText = [string]$diag.summary.pass + ' OK, ' + [string]$diag.summary.warning + ' warning, ' + [string]$diag.summary.fail + ' fail'
        if ($summaryLabel) {
            $summaryLabel.Text = $summaryText
        }
        Set-DanewSummaryVisual -Status ([string]$diag.summary.overall_status) -Text $summaryText

        $dataReportRoot = Copy-DanewReportToDataVolume -HtmlPath ([string]$result.output.artifacts.report_html_path) -JsonPath ([string]$result.output.artifacts.report_json_path)
        Add-DiagnosticProgressLine -Line ('Final summary: ' + $summaryText)
        Add-DiagnosticProgressLine -Line ('JSON report: ' + [string]$result.output.artifacts.report_json_path)
        Add-DiagnosticProgressLine -Line ('HTML report: ' + [string]$result.output.artifacts.report_html_path)
        if (-not [string]::IsNullOrWhiteSpace($dataReportRoot)) {
            Add-DiagnosticProgressLine -Line ('Copied latest report to: ' + $dataReportRoot)
        }
        [System.Windows.Forms.MessageBox]::Show('Diagnostic completed. Overall: ' + [string]$diag.summary.overall_status, 'Danew Launcher') | Out-Null
        [void](Update-DanewStatusPanel)
    }
    catch {
        if ($summaryLabel) {
            $summaryLabel.Text = 'Summary: FAIL'
        }
        Set-DanewSummaryVisual -Status 'FAIL' -Text 'Diagnostic failed'
        Add-DiagnosticProgressLine -Line ('FAIL - Start diagnostic: ' + $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Danew Launcher Error') | Out-Null
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
$form.Text = 'Danew WinPE Check Tool - ' + $runtimeTitle
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(900, 780)
$form.TopMost = $true
$form.AutoScroll = $true
$form.AutoScrollMinSize = New-Object System.Drawing.Size(900, 760)
$form.MinimumSize = New-Object System.Drawing.Size(900, 760)
$form.BackColor = [System.Drawing.Color]::FromArgb(243, 246, 252)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$workingArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
if ($workingArea.Height -lt 900 -or $workingArea.Width -lt 940) {
    $targetWidth = [Math]::Max(820, [Math]::Min(900, $workingArea.Width - 24))
    $targetHeight = [Math]::Max(640, [Math]::Min(780, $workingArea.Height - 24))
    $form.ClientSize = New-Object System.Drawing.Size($targetWidth, $targetHeight)
}

$headerPanel = New-Object System.Windows.Forms.Panel
$headerPanel.Left = 14
$headerPanel.Top = 12
$headerPanel.Width = 872
$headerPanel.Height = 74
$headerPanel.Anchor = 'Top,Left,Right'
$headerPanel.BackColor = [System.Drawing.Color]::FromArgb(30, 64, 175)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Left = 16
$titleLabel.Top = 12
$titleLabel.Width = 680
$titleLabel.Height = 28
$titleLabel.ForeColor = [System.Drawing.Color]::White
$titleLabel.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
$titleLabel.Text = 'Danew Check Tool'

$subtitleLabel = New-Object System.Windows.Forms.Label
$subtitleLabel.Left = 16
$subtitleLabel.Top = 42
$subtitleLabel.Width = 820
$subtitleLabel.Height = 20
$subtitleLabel.ForeColor = [System.Drawing.Color]::FromArgb(219, 234, 254)
$subtitleLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$subtitleLabel.Text = 'Runtime: ' + $runtimeTitle + ' | Offline diagnostics, crash analysis, and USB preparation'

[void]$headerPanel.Controls.Add($titleLabel)
[void]$headerPanel.Controls.Add($subtitleLabel)

$statusGroup = New-Object System.Windows.Forms.GroupBox
$statusGroup.Text = 'Status'
$statusGroup.Left = 14
$statusGroup.Top = 96
$statusGroup.Width = 872
$statusGroup.Height = 154
$statusGroup.Anchor = 'Top,Left,Right'
$statusGroup.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$statusGroup.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)

$statusTable = New-Object System.Windows.Forms.TableLayoutPanel
$statusTable.Left = 12
$statusTable.Top = 22
$statusTable.Width = 846
$statusTable.Height = 120
$statusTable.ColumnCount = 4
$statusTable.RowCount = 4
$statusTable.AutoSize = $false
$statusTable.Dock = 'Fill'
$statusTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 132)))
$statusTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
$statusTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 142)))
$statusTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))

$statusRows = @(
    @{ key = 'runtime_mode'; label = 'Runtime' },
    @{ key = 'last_action_status'; label = 'Last status' },
    @{ key = 'last_action'; label = 'Last action' },
    @{ key = 'selected_usb_disk'; label = 'USB disk' },
    @{ key = 'usb_media_ready'; label = 'USB media' },
    @{ key = 'offline_windows_detected'; label = 'Offline Windows' },
    @{ key = 'last_report_path'; label = 'Last report' }
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
        [void]$statusTable.Controls.Add($label, 0, 3)
        [void]$statusTable.Controls.Add($value, 1, 3)
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

[void]$statusGroup.Controls.Add($statusTable)

$primaryGroup = New-Object System.Windows.Forms.GroupBox
$primaryGroup.Text = 'Diagnostic Console'
$primaryGroup.Left = 14
$primaryGroup.Top = 262
$primaryGroup.Width = 872
$primaryGroup.Height = 340
$primaryGroup.Anchor = 'Top,Left,Right'
$primaryGroup.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$primaryGroup.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)

$startDiagnosticButton = New-Object System.Windows.Forms.Button
$startDiagnosticButton.Text = 'START DIAGNOSTIC'
$startDiagnosticButton.Left = 14
$startDiagnosticButton.Top = 26
$startDiagnosticButton.Width = 844
$startDiagnosticButton.Height = 48
$startDiagnosticButton.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
$startDiagnosticButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$startDiagnosticButton.FlatAppearance.BorderSize = 1
$startDiagnosticButton.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(30, 64, 175)
$startDiagnosticButton.BackColor = [System.Drawing.Color]::FromArgb(29, 78, 216)
$startDiagnosticButton.ForeColor = [System.Drawing.Color]::White
$startDiagnosticButton.Cursor = [System.Windows.Forms.Cursors]::Hand

$startDiagnosticButton.Add_MouseEnter({
    $sender = [System.Windows.Forms.Button]$this
    $sender.BackColor = [System.Drawing.Color]::FromArgb(30, 64, 175)
})

$startDiagnosticButton.Add_MouseLeave({
    $sender = [System.Windows.Forms.Button]$this
    $sender.BackColor = [System.Drawing.Color]::FromArgb(29, 78, 216)
})

$summaryLabel = New-Object System.Windows.Forms.Label
$summaryLabel.Left = 14
$summaryLabel.Top = 136
$summaryLabel.Width = 704
$summaryLabel.Height = 24
$summaryLabel.Text = 'Summary: Idle'
$summaryLabel.ForeColor = [System.Drawing.Color]::FromArgb(30, 64, 175)
$summaryLabel.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)

$overallBadgeLabel = New-Object System.Windows.Forms.Label
$overallBadgeLabel.Left = 730
$overallBadgeLabel.Top = 134
$overallBadgeLabel.Width = 128
$overallBadgeLabel.Height = 28
$overallBadgeLabel.Text = 'IDLE'
$overallBadgeLabel.TextAlign = 'MiddleCenter'
$overallBadgeLabel.BackColor = [System.Drawing.Color]::FromArgb(229, 231, 235)
$overallBadgeLabel.ForeColor = [System.Drawing.Color]::FromArgb(31, 41, 55)
$overallBadgeLabel.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)

$offlineOperationLabel = New-Object System.Windows.Forms.Label
$offlineOperationLabel.Left = 14
$offlineOperationLabel.Top = 162
$offlineOperationLabel.Width = 844
$offlineOperationLabel.Height = 20
$offlineOperationLabel.Text = 'Current operation: idle'
$offlineOperationLabel.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
$offlineOperationLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$offlineProgressBar = New-Object System.Windows.Forms.ProgressBar
$offlineProgressBar.Left = 14
$offlineProgressBar.Top = 186
$offlineProgressBar.Width = 844
$offlineProgressBar.Height = 18
$offlineProgressBar.Minimum = 0
$offlineProgressBar.Maximum = 100
$offlineProgressBar.Value = 0
$offlineProgressBar.Style = 'Continuous'

$offlineTimingLabel = New-Object System.Windows.Forms.Label
$offlineTimingLabel.Left = 14
$offlineTimingLabel.Top = 208
$offlineTimingLabel.Width = 844
$offlineTimingLabel.Height = 20
$offlineTimingLabel.Text = 'Elapsed: 00:00    ETA: --:--'
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

$startDiagnosticButton.Add_Click({ Invoke-StartDiagnostic })
[void]$script:ActionButtons.Add($startDiagnosticButton)

$stepPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$stepPanel.Left = 14
$stepPanel.Top = 80
$stepPanel.Width = 844
$stepPanel.Height = 48
$stepPanel.FlowDirection = 'LeftToRight'
$stepPanel.WrapContents = $true
$stepPanel.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)

foreach ($step in @(
        @{ key = 'scan'; label = 'Scan' },
        @{ key = 'snapshot'; label = 'Status' },
        @{ key = 'usb'; label = 'USB' },
        @{ key = 'offline'; label = 'Offline' },
        @{ key = 'logs'; label = 'Logs' },
        @{ key = 'report'; label = 'Report' },
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

[void]$primaryGroup.Controls.Add($startDiagnosticButton)
[void]$primaryGroup.Controls.Add($stepPanel)
[void]$primaryGroup.Controls.Add($summaryLabel)
[void]$primaryGroup.Controls.Add($overallBadgeLabel)
[void]$primaryGroup.Controls.Add($offlineOperationLabel)
[void]$primaryGroup.Controls.Add($offlineProgressBar)
[void]$primaryGroup.Controls.Add($offlineTimingLabel)
[void]$primaryGroup.Controls.Add($progressBox)

$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.AutoPopDelay = 12000
$toolTip.InitialDelay = 250
$toolTip.ReshowDelay = 150
$toolTip.ShowAlways = $true

$simpleActionsGroup = New-Object System.Windows.Forms.GroupBox
$simpleActionsGroup.Text = 'Simple Actions'
$simpleActionsGroup.Left = 14
$simpleActionsGroup.Top = 614
$simpleActionsGroup.Width = 872
$simpleActionsGroup.Height = 148
$simpleActionsGroup.Anchor = 'Top,Left,Right'
$simpleActionsGroup.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)
$simpleActionsGroup.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)

$simplePanel = New-Object System.Windows.Forms.FlowLayoutPanel
$simplePanel.Left = 10
$simplePanel.Top = 22
$simplePanel.Width = 844
$simplePanel.Height = 50
$simplePanel.FlowDirection = 'LeftToRight'
$simplePanel.WrapContents = $false
$simplePanel.Padding = New-Object System.Windows.Forms.Padding(0)

[void]$simplePanel.Controls.Add((New-DanewActionButton -Text 'Open Last Report' -Action 'view-last-report' -ToolTip $toolTip -Hint 'Open the most recent HTML or JSON report.' -Tone 'primary'))
[void]$simplePanel.Controls.Add((New-DanewActionButton -Text 'Export Package' -Action 'export-diagnostic-package' -ToolTip $toolTip -Hint 'Bundle reports and artifacts for transfer.' -Tone 'neutral'))

$advancedToggleButton = New-Object System.Windows.Forms.Button
$advancedToggleButton.Text = 'Show Advanced Tools'
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
[void]$script:ActionButtons.Add($advancedToggleButton)
[void]$simplePanel.Controls.Add($advancedToggleButton)

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
[void]$simpleActionsGroup.Controls.Add($recentActivityBox)

$buttonGroup = New-Object System.Windows.Forms.GroupBox
$buttonGroup.Text = 'Advanced Tools'
$buttonGroup.Left = 14
$buttonGroup.Top = 774
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
$quickGroup.Text = 'Quick Actions'
$quickGroup.Dock = 'Fill'
$quickGroup.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$quickGroup.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)

$analysisGroup = New-Object System.Windows.Forms.GroupBox
$analysisGroup.Text = 'Analysis'
$analysisGroup.Dock = 'Fill'
$analysisGroup.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$analysisGroup.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)

$systemGroup = New-Object System.Windows.Forms.GroupBox
$systemGroup.Text = 'System'
$systemGroup.Dock = 'Fill'
$systemGroup.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$systemGroup.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)

$quickPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$quickPanel.Dock = 'Fill'
$quickPanel.FlowDirection = 'TopDown'
$quickPanel.WrapContents = $false
$quickPanel.AutoScroll = $true
$quickPanel.Padding = New-Object System.Windows.Forms.Padding(8, 10, 8, 8)

$analysisPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$analysisPanel.Dock = 'Fill'
$analysisPanel.FlowDirection = 'TopDown'
$analysisPanel.WrapContents = $false
$analysisPanel.AutoScroll = $true
$analysisPanel.Padding = New-Object System.Windows.Forms.Padding(8, 10, 8, 8)

$systemPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$systemPanel.Dock = 'Fill'
$systemPanel.FlowDirection = 'TopDown'
$systemPanel.WrapContents = $false
$systemPanel.AutoScroll = $true
$systemPanel.Padding = New-Object System.Windows.Forms.Padding(8, 10, 8, 8)

[void]$quickPanel.Controls.Add((New-DanewActionButton -Text 'Refresh Status' -Action 'refresh-status' -ToolTip $toolTip -Hint 'Reload the status snapshot and latest state from launcher.' -Tone 'neutral'))
[void]$quickPanel.Controls.Add((New-DanewActionButton -Text 'View Last Report' -Action 'view-last-report' -ToolTip $toolTip -Hint 'Open the most recently generated report.' -Tone 'neutral'))
[void]$quickPanel.Controls.Add((New-DanewActionButton -Text 'Open Reports Folder' -Action 'open-reports-folder' -ToolTip $toolTip -Hint 'Open the reports directory in File Explorer.' -Tone 'neutral'))

[void]$analysisPanel.Controls.Add((New-DanewActionButton -Text 'Scan WinPE' -Action 'scan-winpe' -ToolTip $toolTip -Hint 'Scan WinPE runtime details and environment state.' -Tone 'neutral'))
[void]$analysisPanel.Controls.Add((New-DanewActionButton -Text 'Run Capability Analysis' -Action 'capability-analysis' -ToolTip $toolTip -Hint 'Assess capabilities and produce a machine profile.' -Tone 'neutral'))
[void]$analysisPanel.Controls.Add((New-DanewActionButton -Text 'Generate Report' -Action 'generate-report' -ToolTip $toolTip -Hint 'Generate JSON and HTML diagnostic reports.' -Tone 'neutral'))
[void]$analysisPanel.Controls.Add((New-DanewActionButton -Text 'Analyze Offline Windows Logs' -Action 'analyze-offline-logs' -ToolTip $toolTip -Hint 'Run offline logs analysis with live progress and ETA.' -Tone 'primary'))
[void]$analysisPanel.Controls.Add((New-DanewActionButton -Text 'Analyze Crash Causes' -Action 'analyze-crash-causes' -ToolTip $toolTip -Hint 'Correlate evidence and identify probable crash causes.' -Tone 'warn'))

[void]$systemPanel.Controls.Add((New-DanewActionButton -Text 'Export Diagnostic Package' -Action 'export-diagnostic-package' -ToolTip $toolTip -Hint 'Bundle reports and artifacts for transfer.' -Tone 'neutral'))
[void]$systemPanel.Controls.Add((New-DanewActionButton -Text 'Create Bootable USB' -Action 'create-usb-media' -ToolTip $toolTip -Hint 'Prepare or refresh a bootable USB with Danew media.' -Tone 'warn'))
[void]$systemPanel.Controls.Add((New-DanewActionButton -Text 'Exit' -Action 'exit' -ToolTip $toolTip -Hint 'Close the launcher interface.' -Tone 'danger'))

[void]$quickGroup.Controls.Add($quickPanel)
[void]$analysisGroup.Controls.Add($analysisPanel)
[void]$systemGroup.Controls.Add($systemPanel)

[void]$toolsLayout.Controls.Add($quickGroup, 0, 0)
[void]$toolsLayout.Controls.Add($analysisGroup, 1, 0)
[void]$toolsLayout.Controls.Add($systemGroup, 2, 0)

[void]$buttonGroup.Controls.Add($toolsLayout)

[void]$form.Controls.Add($headerPanel)
[void]$form.Controls.Add($statusGroup)
[void]$form.Controls.Add($primaryGroup)
[void]$form.Controls.Add($simpleActionsGroup)
[void]$form.Controls.Add($buttonGroup)

Set-DanewAdvancedToolsVisible -Visible $false
[void](Update-DanewStatusPanel)
[void]$form.ShowDialog()
