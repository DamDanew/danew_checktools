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
$offlineProgressBar = $null
$offlineOperationLabel = $null
$offlineTimingLabel = $null

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
    $button.Width = 250
    $button.Height = 34
    $button.Margin = New-Object System.Windows.Forms.Padding(6)
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderSize = 1
    $button.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand

    $baseBackColor = [System.Drawing.Color]::FromArgb(239, 246, 255)
    $baseBorderColor = [System.Drawing.Color]::FromArgb(191, 219, 254)
    $baseForeColor = [System.Drawing.Color]::FromArgb(30, 64, 175)
    $hoverBackColor = [System.Drawing.Color]::FromArgb(219, 234, 254)

    if ($Tone -eq 'primary') {
        $baseBackColor = [System.Drawing.Color]::FromArgb(29, 78, 216)
        $baseBorderColor = [System.Drawing.Color]::FromArgb(30, 64, 175)
        $baseForeColor = [System.Drawing.Color]::White
        $hoverBackColor = [System.Drawing.Color]::FromArgb(30, 64, 175)
    }
    elseif ($Tone -eq 'warn') {
        $baseBackColor = [System.Drawing.Color]::FromArgb(255, 251, 235)
        $baseBorderColor = [System.Drawing.Color]::FromArgb(251, 191, 36)
        $baseForeColor = [System.Drawing.Color]::FromArgb(146, 64, 14)
        $hoverBackColor = [System.Drawing.Color]::FromArgb(254, 243, 199)
    }
    elseif ($Tone -eq 'danger') {
        $baseBackColor = [System.Drawing.Color]::FromArgb(254, 242, 242)
        $baseBorderColor = [System.Drawing.Color]::FromArgb(252, 165, 165)
        $baseForeColor = [System.Drawing.Color]::FromArgb(153, 27, 27)
        $hoverBackColor = [System.Drawing.Color]::FromArgb(254, 226, 226)
    }

    $button.BackColor = $baseBackColor
    $button.ForeColor = $baseForeColor
    $button.FlatAppearance.BorderColor = $baseBorderColor

    $button.Add_MouseEnter({
        $sender = [System.Windows.Forms.Button]$this
        $sender.BackColor = $hoverBackColor
    })
    $button.Add_MouseLeave({
        $sender = [System.Windows.Forms.Button]$this
        $sender.BackColor = $baseBackColor
    })

    if (-not [string]::IsNullOrWhiteSpace($Hint)) {
        $ToolTip.SetToolTip($button, $Hint)
    }

    if ($Action -eq 'exit') {
        $button.Add_Click({
            Invoke-DanewLauncherAction -Action 'exit' -RootPath $RootPath -Config $config | Out-Null
            $form.Close()
        })
    }
    else {
        $actionName = [string]$Action
        $button.Add_Click(({ Invoke-GuiAction -Action $actionName }).GetNewClosure())
    }

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
    Set-DanewStatusText -Name 'logs_folder_path' -Value ([string]$snapshot.logs_folder_path)

    return $snapshot
}

function Invoke-GuiAction {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Action
    )

    try {
        $suppressLog = $Action -in @('refresh-status', 'view-last-report')
        if ($Action -eq 'analyze-offline-logs') {
            if ($progressBox) {
                $progressBox.Text = ''
            }
            if ($summaryLabel) {
                $summaryLabel.Text = 'Summary: Offline logs running...'
            }
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
        elseif ($Action -ne 'exit') {
            [System.Windows.Forms.MessageBox]::Show("Action completed: $($res.action)", 'Danew Launcher') | Out-Null
            [void](Update-DanewStatusPanel)
        }
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Danew Launcher Error') | Out-Null
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

function Invoke-StartDiagnostic {
    if ($progressBox) {
        $progressBox.Text = ''
    }
    if ($summaryLabel) {
        $summaryLabel.Text = 'Summary: Running...'
    }

    $progress = {
        param([string]$Message)
        Add-DiagnosticProgressLine -Line $Message
    }

    try {
        $result = Invoke-DanewLauncherAction -Action 'start-diagnostic' -RootPath $RootPath -Config $config -RuntimeSystemDrive $env:SystemDrive -CurrentLocationPath (Get-Location).Path -ProgressCallback $progress
        $diag = $result.output.diagnostic
        $summaryText = 'Summary: Overall=' + [string]$diag.summary.overall_status + ' PASS=' + [string]$diag.summary.pass + ' WARNING=' + [string]$diag.summary.warning + ' FAIL=' + [string]$diag.summary.fail
        if ($summaryLabel) {
            $summaryLabel.Text = $summaryText
        }

        Add-DiagnosticProgressLine -Line ('Final summary: ' + $summaryText)
        Add-DiagnosticProgressLine -Line ('JSON report: ' + [string]$result.output.artifacts.report_json_path)
        Add-DiagnosticProgressLine -Line ('HTML report: ' + [string]$result.output.artifacts.report_html_path)
        [System.Windows.Forms.MessageBox]::Show('Diagnostic completed. Overall: ' + [string]$diag.summary.overall_status, 'Danew Launcher') | Out-Null
        [void](Update-DanewStatusPanel)
    }
    catch {
        if ($summaryLabel) {
            $summaryLabel.Text = 'Summary: FAIL'
        }
        Add-DiagnosticProgressLine -Line ('FAIL - Start diagnostic: ' + $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Danew Launcher Error') | Out-Null
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
$form.ClientSize = New-Object System.Drawing.Size(900, 860)
$form.TopMost = $true
$form.AutoScroll = $false
$form.MinimumSize = New-Object System.Drawing.Size(900, 860)
$form.BackColor = [System.Drawing.Color]::FromArgb(243, 246, 252)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

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
$statusGroup.Text = 'Status Snapshot'
$statusGroup.Left = 14
$statusGroup.Top = 96
$statusGroup.Width = 872
$statusGroup.Height = 286
$statusGroup.Anchor = 'Top,Left,Right'
$statusGroup.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)

$statusTable = New-Object System.Windows.Forms.TableLayoutPanel
$statusTable.Left = 12
$statusTable.Top = 22
$statusTable.Width = 846
$statusTable.Height = 252
$statusTable.ColumnCount = 2
$statusTable.RowCount = 8
$statusTable.AutoSize = $false
$statusTable.Dock = 'Fill'
$statusTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 190)))
$statusTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))

$statusRows = @(
    @{ key = 'root_path'; label = 'Current root path' },
    @{ key = 'runtime_mode'; label = 'Runtime mode' },
    @{ key = 'last_action'; label = 'Last action' },
    @{ key = 'last_action_status'; label = 'Last action status' },
    @{ key = 'last_report_path'; label = 'Last report path' },
    @{ key = 'selected_usb_disk'; label = 'Selected USB disk' },
    @{ key = 'offline_windows_detected'; label = 'Offline Windows detected' },
    @{ key = 'logs_folder_path'; label = 'Logs folder path' }
)

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

    [void]$statusTable.Controls.Add($label)
    [void]$statusTable.Controls.Add($value)
}

[void]$statusGroup.Controls.Add($statusTable)

$primaryGroup = New-Object System.Windows.Forms.GroupBox
$primaryGroup.Text = 'Diagnostic Console'
$primaryGroup.Left = 14
$primaryGroup.Top = 392
$primaryGroup.Width = 872
$primaryGroup.Height = 260
$primaryGroup.Anchor = 'Top,Left,Right'
$primaryGroup.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)

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
$summaryLabel.Top = 82
$summaryLabel.Width = 844
$summaryLabel.Height = 24
$summaryLabel.Text = 'Summary: Idle'
$summaryLabel.ForeColor = [System.Drawing.Color]::FromArgb(30, 64, 175)
$summaryLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

$offlineOperationLabel = New-Object System.Windows.Forms.Label
$offlineOperationLabel.Left = 14
$offlineOperationLabel.Top = 104
$offlineOperationLabel.Width = 844
$offlineOperationLabel.Height = 20
$offlineOperationLabel.Text = 'Current operation: idle'
$offlineOperationLabel.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
$offlineOperationLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$offlineProgressBar = New-Object System.Windows.Forms.ProgressBar
$offlineProgressBar.Left = 14
$offlineProgressBar.Top = 130
$offlineProgressBar.Width = 844
$offlineProgressBar.Height = 18
$offlineProgressBar.Minimum = 0
$offlineProgressBar.Maximum = 100
$offlineProgressBar.Value = 0
$offlineProgressBar.Style = 'Continuous'

$offlineTimingLabel = New-Object System.Windows.Forms.Label
$offlineTimingLabel.Left = 14
$offlineTimingLabel.Top = 152
$offlineTimingLabel.Width = 844
$offlineTimingLabel.Height = 20
$offlineTimingLabel.Text = 'Elapsed: 00:00    ETA: --:--'
$offlineTimingLabel.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
$offlineTimingLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$progressBox = New-Object System.Windows.Forms.TextBox
$progressBox.Left = 14
$progressBox.Top = 176
$progressBox.Width = 844
$progressBox.Height = 72
$progressBox.Multiline = $true
$progressBox.ScrollBars = 'Vertical'
$progressBox.ReadOnly = $true
$progressBox.BorderStyle = 'FixedSingle'
$progressBox.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)
$progressBox.ForeColor = [System.Drawing.Color]::FromArgb(31, 41, 55)
$progressBox.Font = New-Object System.Drawing.Font('Consolas', 9)

$startDiagnosticButton.Add_Click({ Invoke-StartDiagnostic })

[void]$primaryGroup.Controls.Add($startDiagnosticButton)
[void]$primaryGroup.Controls.Add($summaryLabel)
[void]$primaryGroup.Controls.Add($offlineOperationLabel)
[void]$primaryGroup.Controls.Add($offlineProgressBar)
[void]$primaryGroup.Controls.Add($offlineTimingLabel)
[void]$primaryGroup.Controls.Add($progressBox)

$buttonGroup = New-Object System.Windows.Forms.GroupBox
$buttonGroup.Text = 'Advanced Tools'
$buttonGroup.Left = 14
$buttonGroup.Top = 660
$buttonGroup.Width = 872
$buttonGroup.Height = 186
$buttonGroup.Anchor = 'Top,Left,Right'

$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.AutoPopDelay = 12000
$toolTip.InitialDelay = 250
$toolTip.ReshowDelay = 150
$toolTip.ShowAlways = $true

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

$analysisGroup = New-Object System.Windows.Forms.GroupBox
$analysisGroup.Text = 'Analysis'
$analysisGroup.Dock = 'Fill'
$analysisGroup.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

$systemGroup = New-Object System.Windows.Forms.GroupBox
$systemGroup.Text = 'System'
$systemGroup.Dock = 'Fill'
$systemGroup.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

$quickPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$quickPanel.Dock = 'Fill'
$quickPanel.FlowDirection = 'TopDown'
$quickPanel.WrapContents = $false
$quickPanel.Padding = New-Object System.Windows.Forms.Padding(8, 10, 8, 8)

$analysisPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$analysisPanel.Dock = 'Fill'
$analysisPanel.FlowDirection = 'TopDown'
$analysisPanel.WrapContents = $false
$analysisPanel.Padding = New-Object System.Windows.Forms.Padding(8, 10, 8, 8)

$systemPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$systemPanel.Dock = 'Fill'
$systemPanel.FlowDirection = 'TopDown'
$systemPanel.WrapContents = $false
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
[void]$form.Controls.Add($buttonGroup)

[void](Update-DanewStatusPanel)
[void]$form.ShowDialog()
