[CmdletBinding()]
param(
    [string]$RootPath = (Split-Path -Parent $PSScriptRoot),
    [string]$ConfigPath,
    [switch]$FallbackToCli,
    [switch]$ForceGuiInitFailure,
    [ValidateSet('Interactive', 'scan-winpe', 'capability-analysis', 'generate-report', 'open-reports-folder', 'export-diagnostic-package', 'prepare-startnet', 'start-diagnostic', 'create-usb-media', 'real-winpe-validation', 'exit')]
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

function New-DanewReadOnlyTextBox {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $box = New-Object System.Windows.Forms.TextBox
    $box.Name = $Name
    $box.ReadOnly = $true
    $box.BorderStyle = 'FixedSingle'
    $box.BackColor = [System.Drawing.SystemColors]::Window
    $box.Dock = 'Fill'
    $box.Margin = New-Object System.Windows.Forms.Padding(3, 2, 3, 2)
    $box
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
    }
}

function Update-DanewStatusPanel {
    try {
        $status = Invoke-DanewLauncherAction -Action 'refresh-status' -RootPath $RootPath -Config $config -RuntimeSystemDrive $env:SystemDrive -CurrentLocationPath (Get-Location).Path -SuppressActionLog
        $snapshot = $status.output
    }
    catch {
        $snapshot = [pscustomobject]@{
            root_path = $RootPath
            runtime_mode = 'Unknown'
            last_action = 'Unknown'
            last_action_status = 'Unknown'
            last_report_path = 'Unknown'
            selected_usb_disk = 'Unknown'
            offline_windows_detected = 'Unknown'
            logs_folder_path = $config.logs_path
            snapshot_path = if ($config.gui_status_snapshot_path) { $config.gui_status_snapshot_path } else { Join-Path $config.reports_path 'gui-status-snapshot.json' }
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
        $res = Invoke-DanewLauncherAction -Action $Action -RootPath $RootPath -Config $config -RuntimeSystemDrive $env:SystemDrive -CurrentLocationPath (Get-Location).Path -SuppressActionLog:$suppressLog

        if ($Action -eq 'view-last-report') {
            $view = $res.output
            $message = if ($view.opened) { "Last report opened: $($view.path)" } else { "Last report: $($view.path)`n$($view.reason)" }
            [System.Windows.Forms.MessageBox]::Show($message, 'Danew Launcher') | Out-Null
        }
        elseif ($Action -eq 'refresh-status') {
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
$form.Text = 'Danew WinPE Check Tool'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(700, 760)
$form.TopMost = $true
$form.AutoScroll = $true

$statusGroup = New-Object System.Windows.Forms.GroupBox
$statusGroup.Text = 'Status'
$statusGroup.Left = 14
$statusGroup.Top = 12
$statusGroup.Width = 660
$statusGroup.Height = 260
$statusGroup.Anchor = 'Top,Left,Right'

$statusTable = New-Object System.Windows.Forms.TableLayoutPanel
$statusTable.Left = 12
$statusTable.Top = 22
$statusTable.Width = 634
$statusTable.Height = 228
$statusTable.ColumnCount = 2
$statusTable.RowCount = 8
$statusTable.AutoSize = $false
$statusTable.Dock = 'Fill'
$statusTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 150)))
$statusTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))

$statusRows = @(
    @{ key = 'root_path'; label = 'Current RootPath' },
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
    $label.Text = $row.label
    $label.Dock = 'Fill'
    $label.TextAlign = 'MiddleLeft'
    $label.Margin = New-Object System.Windows.Forms.Padding(3, 4, 3, 4)

    $value = New-DanewReadOnlyTextBox -Name $row.key
    $statusFields[$row.key] = $value

    [void]$statusTable.Controls.Add($label)
    [void]$statusTable.Controls.Add($value)
}

$statusGroup.Controls.Add($statusTable)

$primaryGroup = New-Object System.Windows.Forms.GroupBox
$primaryGroup.Text = 'Diagnostic Mode'
$primaryGroup.Left = 14
$primaryGroup.Top = 286
$primaryGroup.Width = 660
$primaryGroup.Height = 250
$primaryGroup.Anchor = 'Top,Left,Right'

$startDiagnosticButton = New-Object System.Windows.Forms.Button
$startDiagnosticButton.Text = 'START DIAGNOSTIC'
$startDiagnosticButton.Left = 14
$startDiagnosticButton.Top = 26
$startDiagnosticButton.Width = 620
$startDiagnosticButton.Height = 48
$startDiagnosticButton.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)

$summaryLabel = New-Object System.Windows.Forms.Label
$summaryLabel.Left = 14
$summaryLabel.Top = 82
$summaryLabel.Width = 620
$summaryLabel.Height = 24
$summaryLabel.Text = 'Summary: Idle'

$progressBox = New-Object System.Windows.Forms.TextBox
$progressBox.Left = 14
$progressBox.Top = 112
$progressBox.Width = 620
$progressBox.Height = 122
$progressBox.Multiline = $true
$progressBox.ScrollBars = 'Vertical'
$progressBox.ReadOnly = $true
$progressBox.BorderStyle = 'FixedSingle'
$progressBox.BackColor = [System.Drawing.SystemColors]::Window

$startDiagnosticButton.Add_Click({ Invoke-StartDiagnostic })

$primaryGroup.Controls.Add($startDiagnosticButton)
$primaryGroup.Controls.Add($summaryLabel)
$primaryGroup.Controls.Add($progressBox)

$buttonGroup = New-Object System.Windows.Forms.GroupBox
$buttonGroup.Text = 'Advanced Tools'
$buttonGroup.Left = 14
$buttonGroup.Top = 548
$buttonGroup.Width = 660
$buttonGroup.Height = 170
$buttonGroup.Anchor = 'Top,Left,Right'

$buttonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$buttonPanel.Dock = 'Fill'
$buttonPanel.WrapContents = $true
$buttonPanel.FlowDirection = 'LeftToRight'
$buttonPanel.Padding = New-Object System.Windows.Forms.Padding(10)

$form.Controls.Add($statusGroup)
$form.Controls.Add($primaryGroup)
$form.Controls.Add($buttonGroup)
$buttonGroup.Controls.Add($buttonPanel)

$buttonDefinitions = @(
    @{ label = 'Refresh Status'; action = 'refresh-status' },
    @{ label = 'View Last Report'; action = 'view-last-report' },
    @{ label = 'Scan WinPE'; action = 'scan-winpe' },
    @{ label = 'Run Capability Analysis'; action = 'capability-analysis' },
    @{ label = 'Generate Report'; action = 'generate-report' },
    @{ label = 'Open Reports Folder'; action = 'open-reports-folder' },
    @{ label = 'Export Diagnostic Package'; action = 'export-diagnostic-package' },
    @{ label = 'Create Bootable USB'; action = 'create-usb-media' },
    @{ label = 'Exit'; action = 'exit' }
)

foreach ($a in $buttonDefinitions) {
    $button = New-Object System.Windows.Forms.Button
    $button.Text = [string]$a.label
    $button.Width = 200
    $button.Height = 34
    $button.Margin = New-Object System.Windows.Forms.Padding(6)

    if ($a.action -eq 'exit') {
        $button.Add_Click({
            Invoke-DanewLauncherAction -Action 'exit' -RootPath $RootPath -Config $config | Out-Null
            $form.Close()
        })
    }
    else {
        $actionName = [string]$a.action
        $button.Add_Click(({ Invoke-GuiAction -Action $actionName }).GetNewClosure())
    }

    [void]$buttonPanel.Controls.Add($button)
}

[void](Update-DanewStatusPanel)
[void]$form.ShowDialog()
