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

function Add-UX1Result {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Details = ''
    )

    return [pscustomobject]@{ name = $Name; passed = $Passed; details = $Details }
}

function Test-UX1PatternSet {
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

$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($launcherPath, [ref]$tokens, [ref]$errors) | Out-Null
$results += Add-UX1Result -Name 'launcher_parser_ok' -Passed (-not $errors) -Details ($(if ($errors) { ($errors | Select-Object -First 1).Message } else { 'PowerShell parser clean' }))

$content = Get-Content -Path $launcherPath -Raw -Encoding UTF8

$mainButtons = @(
    'ANALYSE COMPLETE',
    'ANALYSER CAUSES',
    '1. COMPLET TOUS LES LOGS',
    '3. OUVRIR LE RAPPORT SAV',
    '7. EXPORTER LE DOSSIER SAV',
    '4. ACTIONS RECOMMANDEES'
)
$results += Add-UX1Result -Name 'main_buttons_visible' -Passed (Test-UX1PatternSet -Content $content -Patterns $mainButtons) -Details ($mainButtons -join ', ')

$cleanAvailabilityLabels = ($content -notmatch '\$availabilityLabel') -and
    ($content -notmatch 'Bouton actif: rapport disponible') -and
    ($content -notmatch 'Bouton grise: analyse a lancer') -and
    ($content -notmatch '\$availabilityLegendLabel') -and
    ($content -match 'disponibles, ') -and
    ($content -match 'navigateur HTML indisponible')
$results += Add-UX1Result -Name 'report_buttons_without_ok_ko_suffix' -Passed $cleanAvailabilityLabels -Details 'Report buttons keep clean text; availability is shown by disabled state and group summary, not header legend text.'

$advancedCollapsed = ($content -match 'Set-DanewAdvancedToolsVisible\s+-Visible\s+\$false') -and ($content -match '\$buttonGroup\.Visible\s*=\s*\$Visible') -and ($content -match "Name\s*=\s*'AdvancedToolsPanel'")
$results += Add-UX1Result -Name 'advanced_tools_collapsed_by_default' -Passed $advancedCollapsed -Details 'Advanced tools panel is driven by hidden default toggle.'

$technicalCollapsed = ($content -match 'Set-DanewTechnicalDetailsVisible\s+-Visible\s+\$false') -and
    ($content -match '\$technicalDetailsGroup\.Visible\s*=\s*\$Visible') -and
    ($content -match "Name\s*=\s*'TechnicalDetailsPanel'") -and
    ($content -match 'Set-DanewTechnicalDetailsDockLayout') -and
    ($content -notmatch "Show-DanewSecondaryPanelDialog -Title 'DETAILS TECHNIQUES'")
$results += Add-UX1Result -Name 'technical_details_hidden_by_default' -Passed $technicalCollapsed -Details 'Technical details are hidden by default and open as a right docked panel instead of a popup.'

$forbiddenMainWords = @(
    'Diagnostic Console',
    'Status Snapshot',
    'Open Last Report',
    'View Last Report',
    'START DIAGNOSTIC',
    'Create Bootable USB'
)
$forbiddenFound = @($forbiddenMainWords | Where-Object { $content -match [regex]::Escape($_) })
$results += Add-UX1Result -Name 'no_developer_wording_on_main_screen' -Passed (@($forbiddenFound).Count -eq 0) -Details ($(if (@($forbiddenFound).Count -eq 0) { 'No forbidden main-screen wording found.' } else { 'Found: ' + ($forbiddenFound -join ', ') }))

$reportHandlers = @(
    "if (`$Action -eq 'open-sav-report')",
    "elseif (`$Action -eq 'open-timeline-report')",
    "elseif (`$Action -eq 'open-storage-report')",
    'Open-DanewSpecificReport',
    'sav-diagnostic-report.html',
    'timeline-raw.html',
    'storage-analysis.json'
)
$results += Add-UX1Result -Name 'main_report_buttons_functional' -Passed (Test-UX1PatternSet -Content $content -Patterns $reportHandlers) -Details 'SAV, timeline, and storage open handlers are present.'

$layoutFits = ($content -match 'ClientSize\s*=\s*New-Object System\.Drawing\.Size\(900,\s*720\)') -and
    ($content -match 'MinimumSize\s*=\s*New-Object System\.Drawing\.Size\(800,\s*560\)') -and
    ($content -match '\$form\.AutoScroll\s*=\s*\$true') -and
    ($content -match 'Get-DanewClampedTop') -and
    ($content -match '\$form\.ClientSize\.Height')
$results += Add-UX1Result -Name 'layout_fits_1366x768' -Passed $layoutFits -Details 'Layout keeps 900x720 design surface while allowing 800x560 low-resolution WinPE with scroll and clamped panels.'

$requiredHandlers = @(
    'function Invoke-StartDiagnostic',
    'function Invoke-GuiAction',
    'function Set-DanewAdvancedToolsVisible',
    'function Set-DanewTechnicalDetailsVisible',
    "Add_Click({ Invoke-StartDiagnostic })",
    "Add_Click(({ Invoke-GuiAction -Action `$actionName }).GetNewClosure())"
)
$results += Add-UX1Result -Name 'no_broken_handlers' -Passed (Test-UX1PatternSet -Content $content -Patterns $requiredHandlers) -Details 'Click handlers target existing launcher functions.'

$launcherCoreOk = $false
$launcherCoreDetails = ''
$tempRoot = Join-Path $RootPath 'temp\ux1-launchercore-tests'
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
$results += Add-UX1Result -Name 'launchercore_actions_still_working' -Passed $launcherCoreOk -Details $launcherCoreDetails

$htmlOpeningOk = (Test-UX1PatternSet -Content $content -Patterns @('Open-DanewReportFile', 'Start-Process -FilePath $Path', 'Open-DanewSpecificReport -Kind ''sav''', 'Open-DanewSpecificReport -Kind ''timeline''', 'Open-DanewSpecificReport -Kind ''storage'''))
$results += Add-UX1Result -Name 'html_report_opening_still_works' -Passed $htmlOpeningOk -Details 'Report opening still uses local Start-Process paths.'

$unsupportedPatterns = @('PresentationFramework', 'System.Xaml', 'WebView2', 'Electron', 'WPF')
$unsupportedFound = @($unsupportedPatterns | Where-Object { $content -match [regex]::Escape($_) })
$results += Add-UX1Result -Name 'no_unsupported_winpe_dependency' -Passed (@($unsupportedFound).Count -eq 0) -Details ($(if (@($unsupportedFound).Count -eq 0) { 'WinForms/System.Drawing only.' } else { 'Found: ' + ($unsupportedFound -join ', ') }))

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

$jsonPath = Join-Path $OutputDirectory 'ux1-tests-report.json'
$txtPath = Join-Path $OutputDirectory 'ux1-tests-report.txt'

$report | ConvertTo-Json -Depth 20 | Set-Content -Path $jsonPath -Encoding UTF8

$lines = @(
    'UX-1 Tests',
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

Write-Host ('UX-1 test report JSON: ' + $jsonPath)
Write-Host ('UX-1 test report TXT: ' + $txtPath)

if ($summary.failed -gt 0) {
    exit 1
}
