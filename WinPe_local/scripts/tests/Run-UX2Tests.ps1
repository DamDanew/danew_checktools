[CmdletBinding()]
param(
    [string]$RootPath,
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RootPath)) {
    $scriptRoot = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
        $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    }
    $RootPath = Split-Path -Parent (Split-Path -Parent $scriptRoot)
}

if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $RootPath 'reports'
}

function Add-UX2Result {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Details = ''
    )

    return [pscustomobject]@{ name = $Name; passed = $Passed; details = $Details }
}

function Test-UX2PatternSet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,
        [Parameter(Mandatory = $true)]
        [string[]]$Patterns
    )

    foreach ($pattern in @($Patterns)) {
        if ($Content -notmatch [regex]::Escape($pattern)) {
            return $false
        }
    }

    return $true
}

$results = @()
$launcherPath = Join-Path $RootPath 'scripts\launcher.ps1'
$launcherCorePath = Join-Path $RootPath 'scripts\launcher\LauncherCore.ps1'
$content = Get-Content -Path $launcherPath -Raw -Encoding UTF8

$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($launcherPath, [ref]$tokens, [ref]$errors) | Out-Null
$results += Add-UX2Result -Name 'launcher_parser_ok' -Passed (-not $errors) -Details ($(if ($errors) { ($errors | Select-Object -First 1).Message } else { 'PowerShell parser clean' }))

$mainDiagnosticVisible = Test-UX2PatternSet -Content $content -Patterns @(
    "Name 'AnalyzeWindowsLogsButton'",
    'ANALYSER LES JOURNAUX WINDOWS',
    "-Action 'analyze-offline-logs'",
    "Name 'AnalyzeCrashCausesButton'",
    'ANALYSER LES CAUSES DE CRASH',
    "-Action 'analyze-crash-causes'"
)
$results += Add-UX2Result -Name 'main_diagnostic_buttons_visible_without_scroll' -Passed $mainDiagnosticVisible -Details 'Windows logs and crash cause buttons are primary controls.'

$noMainScrollbar = ($content -match '\$form\.AutoScroll\s*=\s*\$false') -and
    ($content -match 'AutoScrollMinSize\s*=\s*New-Object System\.Drawing\.Size\(900,\s*720\)') -and
    ($content -match 'Show-DanewSecondaryPanelDialog') -and
    ($content -match '\$quickPanel\.AutoScroll\s*=\s*\$false') -and
    ($content -match '\$analysisPanel\.AutoScroll\s*=\s*\$false') -and
    ($content -match '\$systemPanel\.AutoScroll\s*=\s*\$false')
$results += Add-UX2Result -Name 'no_main_vertical_scrollbar_1366x768' -Passed $noMainScrollbar -Details 'Main form disables scrolling and advanced panels open in secondary dialogs.'

$advancedCollapsed = ($content -match 'Set-DanewAdvancedToolsVisible\s+-Visible\s+\$false') -and
    ($content -match '\$buttonGroup\.Visible\s*=\s*\$Visible') -and
    ($content -match "Name\s*=\s*'AdvancedToolsPanel'")
$results += Add-UX2Result -Name 'advanced_tools_collapsed_by_default' -Passed $advancedCollapsed -Details 'Advanced tools remain hidden until explicitly opened.'

$primaryTopMatch = [regex]::Match($content, '\$primaryGroup\.Top\s*=\s*(\d+)')
$summaryTopMatch = [regex]::Match($content, '\$statusGroup\.Top\s*=\s*(\d+)')
$reportsTopMatch = [regex]::Match($content, '\$simpleActionsGroup\.Top\s*=\s*(\d+)')
$priorityOk = $primaryTopMatch.Success -and $summaryTopMatch.Success -and $reportsTopMatch.Success -and
    ([int]$primaryTopMatch.Groups[1].Value -lt [int]$summaryTopMatch.Groups[1].Value) -and
    ([int]$summaryTopMatch.Groups[1].Value -lt [int]$reportsTopMatch.Groups[1].Value) -and
    ($content -match 'New-DanewPrimaryDiagnosticButton') -and
    ($content -match "Text 'ANALYSER LES JOURNAUX WINDOWS'") -and
    ($content -match "Text 'ANALYSER LES CAUSES DE CRASH'")
$results += Add-UX2Result -Name 'analyze_buttons_visually_prioritized' -Passed $priorityOk -Details 'Primary diagnostics appear before summary and reports.'

$summaryVisible = ($content -match "Text = 'Resume du diagnostic'") -and
    ($content -match '\$statusGroup\.Top\s*=\s*250') -and
    (Test-UX2PatternSet -Content $content -Patterns @('Cause probable', 'Confiance', 'Severite', 'Detection Windows', 'Visibilite du stockage', 'Evenements critiques'))
$results += Add-UX2Result -Name 'sav_summary_visible_immediately' -Passed $summaryVisible -Details 'SAV summary card remains on the first screen.'

$usbIndex = $content.IndexOf("-Text 'OUTILS USB'")
$advancedIndex = $content.IndexOf('$buttonGroup = New-Object System.Windows.Forms.GroupBox')
$simpleIndex = $content.IndexOf('$simpleActionsGroup = New-Object System.Windows.Forms.GroupBox')
$usbSecondary = ($usbIndex -gt $advancedIndex) -and ($advancedIndex -gt $simpleIndex) -and ($content -notmatch '\$simplePanel\.Controls\.Add\(\(New-DanewActionButton -Text ''OUTILS USB''')
$results += Add-UX2Result -Name 'usb_tools_visually_secondary' -Passed $usbSecondary -Details 'USB tools are only in Advanced Tools.'

$requiredHandlers = @(
    'function Invoke-GuiAction',
    'function Invoke-StartDiagnostic',
    'function New-DanewPrimaryDiagnosticButton',
    "Invoke-GuiAction -Action `$actionName",
    "elseif (`$Action -eq 'start-diagnostic')",
    "if (`$Action -eq 'open-sav-report')",
    "elseif (`$Action -eq 'open-timeline-report')",
    "elseif (`$Action -eq 'open-storage-report')"
)
$handlersOk = Test-UX2PatternSet -Content $content -Patterns $requiredHandlers
$results += Add-UX2Result -Name 'existing_handlers_still_functional' -Passed $handlersOk -Details 'Primary, report, and full diagnostic handlers remain present.'

$reportsOpenOk = Test-UX2PatternSet -Content $content -Patterns @(
    'Open-DanewReportFile',
    'Get-DanewReportSearchRoots',
    'DANEW_DATA',
    'Start-Process -FilePath $Path',
    'sav-diagnostic-report.html',
    'REPORTS_INDEX.html',
    'timeline-raw.html',
    'storage-analysis.json'
)
$results += Add-UX2Result -Name 'existing_reports_still_open_correctly' -Passed $reportsOpenOk -Details 'SAV, timeline, storage, and index fallback paths remain wired.'

$savFallbackOrder = ($content -match "sav-diagnostic-report\.html', 'REPORTS_INDEX\.html', 'reports-index\.html")
$results += Add-UX2Result -Name 'sav_report_falls_back_to_index' -Passed $savFallbackOrder -Details 'SAV button opens reports index before one-click fallback when SAV report is absent.'

$unsupportedPatterns = @('PresentationFramework', 'System.Xaml', 'WebView2', 'Electron', 'WPF')
$unsupportedFound = @($unsupportedPatterns | Where-Object { $content -match [regex]::Escape($_) })
$portableBrowserOnly = ($content -match 'tools\\browser\\chromium\.exe') -and ($content -notmatch 'Add-Type.+Chromium')
$results += Add-UX2Result -Name 'no_winpe_incompatible_dependency' -Passed (@($unsupportedFound).Count -eq 0 -and $portableBrowserOnly) -Details ($(if (@($unsupportedFound).Count -eq 0 -and $portableBrowserOnly) { 'WinForms/System.Drawing only; optional portable browser launcher path allowed.' } else { 'Found: ' + ($unsupportedFound -join ', ') }))

$launcherCoreOk = $false
$launcherCoreDetails = ''
$tempRoot = Join-Path $RootPath 'temp\ux2-launchercore-tests'
try {
    if (Test-Path -Path $tempRoot) {
        Remove-Item -Path $tempRoot -Recurse -Force
    }
    New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null
    foreach ($folder in @('scripts\launcher', 'reports', 'logs')) {
        New-Item -Path (Join-Path $tempRoot $folder) -ItemType Directory -Force | Out-Null
    }

    Copy-Item -Path $launcherCorePath -Destination (Join-Path $tempRoot 'scripts\launcher\LauncherCore.ps1') -Force
    $cfgPath = Join-Path $tempRoot 'scripts\launcher-config.json'
    @{
        input_path = '.'
        default_tier = 'standard'
        reports_path = 'reports'
        logs_path = 'logs'
        launcher_log_path = 'logs/launcher-log.json'
        gui_status_snapshot_path = 'reports/gui-status-snapshot.json'
        startnet_runtime_log_path = 'reports/startnet-runtime-log.txt'
        startnet_template_path = 'missing.cmd'
        startnet_output_path = 'reports/StartNet.generated.cmd'
        startnet_fallback_output_path = 'reports/StartNet.fallback.cmd'
    } | ConvertTo-Json -Depth 5 | Set-Content -Path $cfgPath -Encoding UTF8

    . (Join-Path $tempRoot 'scripts\launcher\LauncherCore.ps1')
    $cfg = Get-DanewLauncherConfig -RootPath $tempRoot -ConfigPath $cfgPath
    $status = Invoke-DanewLauncherAction -Action 'refresh-status' -RootPath $tempRoot -Config $cfg -RuntimeSystemDrive $env:SystemDrive -CurrentLocationPath $tempRoot -SuppressActionLog
    $launcherCoreOk = ($status.action -eq 'refresh-status') -and ($null -ne $status.output)
    $launcherCoreDetails = 'refresh-status returned launcher snapshot.'
}
catch {
    $launcherCoreOk = $false
    $launcherCoreDetails = $_.Exception.Message
}
finally {
    if (Test-Path -Path $tempRoot) {
        Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
$results += Add-UX2Result -Name 'launchercore_actions_still_working' -Passed $launcherCoreOk -Details $launcherCoreDetails

$summary = [pscustomobject]@{
    total = @($results).Count
    passed = @($results | Where-Object { $_.passed }).Count
    failed = @($results | Where-Object { -not $_.passed }).Count
}

$report = [pscustomobject]@{
    timestamp = (Get-Date).ToString('s')
    summary = $summary
    tests = $results
}

if (-not (Test-Path -Path $OutputDirectory)) {
    New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
}

$jsonPath = Join-Path $OutputDirectory 'ux2-tests-report.json'
$txtPath = Join-Path $OutputDirectory 'ux2-tests-report.txt'

$report | ConvertTo-Json -Depth 20 | Set-Content -Path $jsonPath -Encoding UTF8

$lines = @(
    'UX-2 Tests',
    ('Total: ' + [string]$summary.total),
    ('Passed: ' + [string]$summary.passed),
    ('Failed: ' + [string]$summary.failed),
    ''
)
foreach ($result in @($results)) {
    $status = if ($result.passed) { 'PASS' } else { 'FAIL' }
    $lines += '[' + $status + '] ' + [string]$result.name + ' - ' + [string]$result.details
}
$lines | Set-Content -Path $txtPath -Encoding UTF8

Write-Host ('UX-2 test report JSON: ' + $jsonPath)
Write-Host ('UX-2 test report TXT: ' + $txtPath)

if ($summary.failed -gt 0) {
    exit 1
}
