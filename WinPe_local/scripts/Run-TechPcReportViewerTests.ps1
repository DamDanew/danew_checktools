#Requires -Version 5.1
<#
.SYNOPSIS
    Tests du mode viewer PC technicien — valide que generate-html-reports detecte
    les artefacts JSON/CSV/TXT depuis la cle USB et genere correctement les HTML,
    REPORTS_INDEX.html, et que le navigateur s'ouvre si disponible.

.USAGE
    powershell -ExecutionPolicy Bypass -File Run-TechPcReportViewerTests.ps1
    powershell -ExecutionPolicy Bypass -File Run-TechPcReportViewerTests.ps1 -ReportsPath E:\reports
    powershell -ExecutionPolicy Bypass -File Run-TechPcReportViewerTests.ps1 -Verbose

.OUTPUTS
    tech-pc-report-viewer-tests-report.json
    tech-pc-report-viewer-tests-report.txt
#>
[CmdletBinding()]
param(
    [string]$RootPath    = (Split-Path -Parent $PSScriptRoot),
    [string]$ReportsPath = '',
    [switch]$StopOnFirstFailure
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$scriptStart = Get-Date
$results     = [System.Collections.ArrayList]::new()
$passCount   = 0
$failCount   = 0
$skipCount   = 0

function Write-TestLog {
    param([string]$Message, [string]$Level = 'INFO')
    $ts   = (Get-Date).ToString('HH:mm:ss')
    $line = "[$ts][$Level] $Message"
    switch ($Level) {
        'PASS' { Write-Host $line -ForegroundColor Green }
        'FAIL' { Write-Host $line -ForegroundColor Red }
        'SKIP' { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line }
    }
}

function Add-TestResult {
    param([string]$Name, [string]$Status, [string]$Detail = '')
    $script:results.Add([pscustomobject]@{ name = $Name; status = $Status; detail = $Detail }) | Out-Null
    switch ($Status) {
        'PASS' { $script:passCount++; Write-TestLog -Level 'PASS' -Message "PASS  $Name" }
        'FAIL' { $script:failCount++; Write-TestLog -Level 'FAIL' -Message "FAIL  $Name : $Detail" }
        'SKIP' { $script:skipCount++; Write-TestLog -Level 'SKIP' -Message "SKIP  $Name : $Detail" }
    }
    if ($Status -eq 'FAIL' -and $StopOnFirstFailure) { exit 1 }
}

# Charger les engines
$launcherCorePath = Join-Path $PSScriptRoot 'launcher\LauncherCore.ps1'
if (Test-Path $launcherCorePath) { . $launcherCorePath }

$reportShellPath = Join-Path $PSScriptRoot 'report\HtmlReportShell.ps1'
if (Test-Path $reportShellPath) { . $reportShellPath }

$offlineEnginePath = Join-Path $PSScriptRoot 'offline\OfflineLogsEngine.ps1'
if (Test-Path $offlineEnginePath) { . $offlineEnginePath }

$crashEnginePath = Join-Path $PSScriptRoot 'offline\CrashAnalysisEngine.ps1'
if (Test-Path $crashEnginePath) { . $crashEnginePath }

if ([string]::IsNullOrWhiteSpace($ReportsPath)) {
    $ReportsPath = Join-Path $RootPath 'WinPe_local\reports'
}

Write-TestLog "=== RUN-TECHPC-REPORTVIEWER-TESTS ==="
Write-TestLog "RootPath    : $RootPath"
Write-TestLog "ReportsPath : $ReportsPath"
Write-TestLog ''

# ---------------------------------------------------------------------------
# TEST 1 : Artefacts JSON/CSV/TXT detectes dans reports
# ---------------------------------------------------------------------------
try {
    if (Test-Path $ReportsPath) {
        $jsonFiles = @(Get-ChildItem -Path $ReportsPath -Filter '*.json' -ErrorAction SilentlyContinue)
        $csvFiles  = @(Get-ChildItem -Path $ReportsPath -Filter '*.csv'  -ErrorAction SilentlyContinue)
        $txtFiles  = @(Get-ChildItem -Path $ReportsPath -Filter '*.txt'  -ErrorAction SilentlyContinue)
        $total = $jsonFiles.Count + $csvFiles.Count + $txtFiles.Count
        if ($total -gt 0) {
            Add-TestResult -Name 'Artefacts JSON/CSV/TXT detectes' -Status 'PASS' -Detail "json=$($jsonFiles.Count) csv=$($csvFiles.Count) txt=$($txtFiles.Count)"
        }
        else {
            Add-TestResult -Name 'Artefacts JSON/CSV/TXT detectes' -Status 'SKIP' -Detail 'Dossier vide — brancher la cle USB avec une analyse WinPE'
        }
    }
    else {
        Add-TestResult -Name 'Artefacts JSON/CSV/TXT detectes' -Status 'SKIP' -Detail "ReportsPath introuvable : $ReportsPath"
    }
}
catch {
    Add-TestResult -Name 'Artefacts JSON/CSV/TXT detectes' -Status 'FAIL' -Detail $_.Exception.Message
}

# ---------------------------------------------------------------------------
# TEST 2 : timeline-raw.html genere depuis timeline-raw.json (si JSON present)
# ---------------------------------------------------------------------------
try {
    $tlJson = Join-Path $ReportsPath 'timeline-raw.json'
    $tlHtml = Join-Path $ReportsPath 'timeline-raw.html'
    if (-not (Test-Path $tlJson)) {
        Add-TestResult -Name 'timeline-raw.html genere depuis JSON' -Status 'SKIP' -Detail 'timeline-raw.json absent'
    }
    else {
        # Supprimer HTML si present pour forcer la generation
        $backupPath = $tlHtml + '.bak'
        $hadHtml = Test-Path $tlHtml
        if ($hadHtml) { Move-Item -Path $tlHtml -Destination $backupPath -Force }
        try {
            if (-not (Get-Command -Name 'Ensure-DanewReportHtml' -ErrorAction SilentlyContinue)) {
                # Fallback : appel direct Write-DanewTimelineHtml si disponible
                $tlData = Get-Content -Path $tlJson -Raw -Encoding UTF8 | ConvertFrom-Json
                if (Get-Command -Name 'Write-DanewTimelineHtml' -ErrorAction SilentlyContinue) {
                    $sm = [pscustomobject]@{ total_events = @($tlData.events).Count; missing_required_logs = 0; parse_issue_count = 0 }
                    Write-DanewTimelineHtml -Path $tlHtml -Events @($tlData.events) -Summary $sm
                }
                else {
                    Add-TestResult -Name 'timeline-raw.html genere depuis JSON' -Status 'SKIP' -Detail 'Ensure-DanewReportHtml et Write-DanewTimelineHtml non charges (launcher.ps1 requis)'
                    throw 'skip'
                }
            }
            else {
                [void](Ensure-DanewReportHtml -Path $tlHtml)
            }
            if (Test-Path $tlHtml) {
                $sizeKB = [math]::Round((Get-Item $tlHtml).Length / 1KB, 0)
                Add-TestResult -Name 'timeline-raw.html genere depuis JSON' -Status 'PASS' -Detail "$sizeKB KB"
            }
            else {
                Add-TestResult -Name 'timeline-raw.html genere depuis JSON' -Status 'FAIL' -Detail 'Generation terminee sans erreur mais HTML absent'
            }
        }
        finally {
            # Restaurer backup si existait et que la generation a echoue (sauf si skip)
            if ($hadHtml -and (Test-Path $backupPath) -and -not (Test-Path $tlHtml)) {
                Move-Item -Path $backupPath -Destination $tlHtml -Force
            }
            elseif (Test-Path $backupPath) {
                Remove-Item -Path $backupPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
catch {
    Add-TestResult -Name 'timeline-raw.html genere depuis JSON' -Status 'FAIL' -Detail $_.Exception.Message
}

# ---------------------------------------------------------------------------
# TEST 3 : REPORTS_INDEX.html genere
# ---------------------------------------------------------------------------
try {
    if (Test-Path $ReportsPath) {
        $indexHtml = Join-Path $ReportsPath 'REPORTS_INDEX.html'
        [void](Update-DanewInteractiveReportsIndex -ReportsPath $ReportsPath)
        if (Test-Path $indexHtml) {
            $sizeKB = [math]::Round((Get-Item $indexHtml).Length / 1KB, 0)
            Add-TestResult -Name 'REPORTS_INDEX.html genere' -Status 'PASS' -Detail "$sizeKB KB"
        }
        else {
            Add-TestResult -Name 'REPORTS_INDEX.html genere' -Status 'FAIL' -Detail 'REPORTS_INDEX.html absent apres Update-DanewInteractiveReportsIndex'
        }
    }
    else {
        Add-TestResult -Name 'REPORTS_INDEX.html genere' -Status 'SKIP' -Detail "ReportsPath introuvable : $ReportsPath"
    }
}
catch {
    Add-TestResult -Name 'REPORTS_INDEX.html genere' -Status 'FAIL' -Detail $_.Exception.Message
}

# ---------------------------------------------------------------------------
# TEST 4 : sav-diagnostic-report.html genere depuis sav-diagnostic-report.json
# ---------------------------------------------------------------------------
try {
    $savJson = Join-Path $ReportsPath 'sav-diagnostic-report.json'
    $savHtml = Join-Path $ReportsPath 'sav-diagnostic-report.html'
    if (-not (Test-Path $savJson)) {
        Add-TestResult -Name 'sav-diagnostic-report.html genere depuis JSON' -Status 'SKIP' -Detail 'sav-diagnostic-report.json absent'
    }
    else {
        $backupPath = $savHtml + '.bak'
        $hadHtml = Test-Path $savHtml
        if ($hadHtml) { Move-Item -Path $savHtml -Destination $backupPath -Force }
        try {
            $ok = Write-DanewSavDiagnosticReportHtmlFromJson -ReportsPath $ReportsPath
            if ((Test-Path $savHtml)) {
                $sizeKB = [math]::Round((Get-Item $savHtml).Length / 1KB, 0)
                Add-TestResult -Name 'sav-diagnostic-report.html genere depuis JSON' -Status 'PASS' -Detail "$sizeKB KB"
            }
            else {
                Add-TestResult -Name 'sav-diagnostic-report.html genere depuis JSON' -Status 'FAIL' -Detail 'HTML absent apres appel Write-DanewSavDiagnosticReportHtmlFromJson'
            }
        }
        finally {
            if ($hadHtml -and (Test-Path $backupPath) -and -not (Test-Path $savHtml)) {
                Move-Item -Path $backupPath -Destination $savHtml -Force
            }
            elseif (Test-Path $backupPath) {
                Remove-Item -Path $backupPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
catch {
    Add-TestResult -Name 'sav-diagnostic-report.html genere depuis JSON' -Status 'FAIL' -Detail $_.Exception.Message
}

# ---------------------------------------------------------------------------
# TEST 5 : Navigateur portable detecte (si disponible) — pas bloquant
# ---------------------------------------------------------------------------
try {
    if (Get-Command -Name 'Get-DanewPortableBrowserPath' -ErrorAction SilentlyContinue) {
        $browserPath = Get-DanewPortableBrowserPath
        if (-not [string]::IsNullOrWhiteSpace($browserPath) -and (Test-Path $browserPath)) {
            Add-TestResult -Name 'Navigateur portable disponible' -Status 'PASS' -Detail $browserPath
        }
        else {
            Add-TestResult -Name 'Navigateur portable disponible' -Status 'SKIP' -Detail 'Absent — fallback TXT/CSV utilise. Non bloquant sur PC technicien.'
        }
    }
    else {
        Add-TestResult -Name 'Navigateur portable disponible' -Status 'SKIP' -Detail 'Get-DanewPortableBrowserPath non charge'
    }
}
catch {
    Add-TestResult -Name 'Navigateur portable disponible' -Status 'FAIL' -Detail $_.Exception.Message
}

# ---------------------------------------------------------------------------
# TEST 6 : generate-html-reports dans le ValidateSet de launcher.ps1
# ---------------------------------------------------------------------------
try {
    $launcherPath = Join-Path $PSScriptRoot 'launcher.ps1'
    if (Test-Path $launcherPath) {
        $src = Get-Content $launcherPath -Raw -Encoding UTF8
        if ($src -match "generate-html-reports") {
            Add-TestResult -Name 'generate-html-reports dans ValidateSet launcher' -Status 'PASS'
        }
        else {
            Add-TestResult -Name 'generate-html-reports dans ValidateSet launcher' -Status 'FAIL' -Detail 'Action generate-html-reports introuvable dans launcher.ps1'
        }
    }
    else {
        Add-TestResult -Name 'generate-html-reports dans ValidateSet launcher' -Status 'SKIP' -Detail "Introuvable : $launcherPath"
    }
}
catch {
    Add-TestResult -Name 'generate-html-reports dans ValidateSet launcher' -Status 'FAIL' -Detail $_.Exception.Message
}

# ---------------------------------------------------------------------------
# Rapport final
# ---------------------------------------------------------------------------
$elapsed = [math]::Round(((Get-Date) - $scriptStart).TotalSeconds, 1)
$summary = [pscustomobject]@{
    suite     = 'TechPcReportViewer'
    date      = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    elapsed_s = $elapsed
    total     = $results.Count
    pass      = $passCount
    fail      = $failCount
    skip      = $skipCount
    result    = if ($failCount -eq 0) { 'OK' } else { 'FAIL' }
    tests     = $results
}

$outBase = Join-Path $PSScriptRoot 'tech-pc-report-viewer-tests-report'
$summary | ConvertTo-Json -Depth 6 | Set-Content -Path ($outBase + '.json') -Encoding UTF8
$lines = @("=== Tech PC Report Viewer Tests ===", "Date : $($summary.date)", "Duree : $elapsed s", '')
foreach ($t in $results) {
    $lines += '[' + $t.status.PadRight(4) + '] ' + $t.name + $(if ($t.detail) { ' - ' + $t.detail } else { '' })
}
$lines += ''
$lines += "TOTAL : $($results.Count)  PASS : $passCount  FAIL : $failCount  SKIP : $skipCount"
$lines += "RESULTAT : $($summary.result)"
$lines | Set-Content -Path ($outBase + '.txt') -Encoding UTF8

Write-TestLog ''
Write-TestLog "=== RESULTAT FINAL : $($summary.result) - PASS=$passCount FAIL=$failCount SKIP=$skipCount ==="
Write-TestLog "Rapport : $outBase.json / .txt"

if ($failCount -gt 0) { exit 1 } else { exit 0 }
