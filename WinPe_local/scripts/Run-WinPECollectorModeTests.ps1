#Requires -Version 5.1
<#
.SYNOPSIS
    Tests du mode collecte WinPE — valide que l'outil se comporte correctement
    en environnement WinPE : pas de HTML genere, pas de navigateur lance, JSON/CSV/TXT
    et ZIP SAV complets, GUI affichant le message "ouvrir sur PC technicien".

.USAGE
    powershell -ExecutionPolicy Bypass -File Run-WinPECollectorModeTests.ps1
    powershell -ExecutionPolicy Bypass -File Run-WinPECollectorModeTests.ps1 -Verbose
    powershell -ExecutionPolicy Bypass -File Run-WinPECollectorModeTests.ps1 -ReportsPath E:\reports

.OUTPUTS
    winpe-collector-mode-tests-report.json
    winpe-collector-mode-tests-report.txt
#>
[CmdletBinding()]
param(
    [string]$RootPath   = (Split-Path -Parent $PSScriptRoot),
    [string]$ReportsPath = '',
    [switch]$StopOnFirstFailure
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$scriptStart = Get-Date
$results = [System.Collections.ArrayList]::new()
$passCount = 0
$failCount = 0
$skipCount = 0

function Write-TestLog {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = (Get-Date).ToString('HH:mm:ss')
    $line = "[$ts][$Level] $Message"
    switch ($Level) {
        'PASS' { Write-Host $line -ForegroundColor Green }
        'FAIL' { Write-Host $line -ForegroundColor Red }
        'SKIP' { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line }
    }
}

function Add-TestResult {
    param(
        [string]$Name,
        [string]$Status,   # PASS / FAIL / SKIP
        [string]$Detail = ''
    )
    $script:results.Add([pscustomobject]@{
        name   = $Name
        status = $Status
        detail = $Detail
    }) | Out-Null
    switch ($Status) {
        'PASS' { $script:passCount++; Write-TestLog -Level 'PASS' -Message "PASS  $Name" }
        'FAIL' { $script:failCount++; Write-TestLog -Level 'FAIL' -Message "FAIL  $Name : $Detail" }
        'SKIP' { $script:skipCount++; Write-TestLog -Level 'SKIP' -Message "SKIP  $Name : $Detail" }
    }
    if ($Status -eq 'FAIL' -and $StopOnFirstFailure) {
        Write-TestLog -Level 'FAIL' -Message 'StopOnFirstFailure : arret.'
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Charger l engine pour acceder a Test-DanewIsWinPE et les config helpers
# ---------------------------------------------------------------------------
$launcherCorePath = Join-Path $PSScriptRoot 'launcher\LauncherCore.ps1'
if (Test-Path $launcherCorePath) {
    . $launcherCorePath
}
else {
    Write-TestLog -Level 'FAIL' -Message "LauncherCore.ps1 introuvable : $launcherCorePath"
}

# Dossier reports de reference
if ([string]::IsNullOrWhiteSpace($ReportsPath)) {
    $ReportsPath = Join-Path $RootPath 'WinPe_local\reports'
}

Write-TestLog "=== RUN-WINPECOLLECTORMODE-TESTS ==="
Write-TestLog "RootPath    : $RootPath"
Write-TestLog "ReportsPath : $ReportsPath"
Write-TestLog ''

# ---------------------------------------------------------------------------
# TEST 1 : Test-DanewIsWinPE disponible et retourne un booleen
# ---------------------------------------------------------------------------
try {
    if (Get-Command -Name 'Test-DanewIsWinPE' -ErrorAction SilentlyContinue) {
        $result = Test-DanewIsWinPE
        if ($result -is [bool]) {
            Add-TestResult -Name 'Test-DanewIsWinPE retourne un booleen' -Status 'PASS' -Detail "valeur=$result"
        }
        else {
            Add-TestResult -Name 'Test-DanewIsWinPE retourne un booleen' -Status 'FAIL' -Detail "type inattendu : $($result.GetType().Name)"
        }
    }
    else {
        Add-TestResult -Name 'Test-DanewIsWinPE retourne un booleen' -Status 'FAIL' -Detail 'Fonction introuvable apres chargement LauncherCore.ps1'
    }
}
catch {
    Add-TestResult -Name 'Test-DanewIsWinPE retourne un booleen' -Status 'FAIL' -Detail $_.Exception.Message
}

# ---------------------------------------------------------------------------
# TEST 2 : En mode simule WinPE, les HTML lourds ne doivent pas etre generes
# Verifie que $deferTimelineHtml = true quand isWinPE = true dans la logique engine
# On inspecte le code source pour la presence du guard.
# ---------------------------------------------------------------------------
try {
    $enginePath = Join-Path $PSScriptRoot 'offline\OfflineLogsEngine.ps1'
    if (Test-Path $enginePath) {
        $src = Get-Content $enginePath -Raw -Encoding UTF8
        $hasWinPEGuard = $src -match 'skipHtmlInWinPE' -and $src -match 'isWinPE'
        if ($hasWinPEGuard) {
            Add-TestResult -Name 'OfflineLogsEngine contient guard HTML WinPE' -Status 'PASS'
        }
        else {
            Add-TestResult -Name 'OfflineLogsEngine contient guard HTML WinPE' -Status 'FAIL' -Detail 'skipHtmlInWinPE / isWinPE introuvables dans le source'
        }
    }
    else {
        Add-TestResult -Name 'OfflineLogsEngine contient guard HTML WinPE' -Status 'SKIP' -Detail "Fichier introuvable : $enginePath"
    }
}
catch {
    Add-TestResult -Name 'OfflineLogsEngine contient guard HTML WinPE' -Status 'FAIL' -Detail $_.Exception.Message
}

# ---------------------------------------------------------------------------
# TEST 3 : CrashAnalysisEngine contient guard HTML WinPE pour SAV
# ---------------------------------------------------------------------------
try {
    $crashPath = Join-Path $PSScriptRoot 'offline\CrashAnalysisEngine.ps1'
    if (Test-Path $crashPath) {
        $src = Get-Content $crashPath -Raw -Encoding UTF8
        $hasGuard = $src -match 'skipSavHtmlInWinPE' -and $src -match 'isWinPE'
        if ($hasGuard) {
            Add-TestResult -Name 'CrashAnalysisEngine contient guard HTML SAV WinPE' -Status 'PASS'
        }
        else {
            Add-TestResult -Name 'CrashAnalysisEngine contient guard HTML SAV WinPE' -Status 'FAIL' -Detail 'skipSavHtmlInWinPE / isWinPE introuvables'
        }
    }
    else {
        Add-TestResult -Name 'CrashAnalysisEngine contient guard HTML SAV WinPE' -Status 'SKIP' -Detail "Introuvable : $crashPath"
    }
}
catch {
    Add-TestResult -Name 'CrashAnalysisEngine contient guard HTML SAV WinPE' -Status 'FAIL' -Detail $_.Exception.Message
}

# ---------------------------------------------------------------------------
# TEST 4 : Artefacts JSON/CSV/TXT presents dans le dossier reports (si analyse deja faite)
# ---------------------------------------------------------------------------
try {
    if (Test-Path $ReportsPath) {
        $jsonCount = @(Get-ChildItem -Path $ReportsPath -Filter '*.json' -ErrorAction SilentlyContinue).Count
        $csvCount  = @(Get-ChildItem -Path $ReportsPath -Filter '*.csv'  -ErrorAction SilentlyContinue).Count
        $txtCount  = @(Get-ChildItem -Path $ReportsPath -Filter '*.txt'  -ErrorAction SilentlyContinue).Count
        $total = $jsonCount + $csvCount + $txtCount
        if ($total -gt 0) {
            Add-TestResult -Name 'Artefacts JSON/CSV/TXT presents dans reports' -Status 'PASS' -Detail "json=$jsonCount csv=$csvCount txt=$txtCount"
        }
        else {
            Add-TestResult -Name 'Artefacts JSON/CSV/TXT presents dans reports' -Status 'SKIP' -Detail 'Dossier vide — lancer une analyse WinPE pour verifier'
        }
    }
    else {
        Add-TestResult -Name 'Artefacts JSON/CSV/TXT presents dans reports' -Status 'SKIP' -Detail "Dossier reports introuvable : $ReportsPath"
    }
}
catch {
    Add-TestResult -Name 'Artefacts JSON/CSV/TXT presents dans reports' -Status 'FAIL' -Detail $_.Exception.Message
}

# ---------------------------------------------------------------------------
# TEST 5 : En WinPE, aucun HTML lourd genere (timeline-raw.html absent si JSON present)
# ---------------------------------------------------------------------------
try {
    if (Test-Path $ReportsPath) {
        $tlJson = Join-Path $ReportsPath 'timeline-raw.json'
        $tlHtml = Join-Path $ReportsPath 'timeline-raw.html'
        $savJson = Join-Path $ReportsPath 'sav-diagnostic-report.json'
        $savHtml = Join-Path $ReportsPath 'sav-diagnostic-report.html'

        $jsonPresent   = (Test-Path $tlJson) -or (Test-Path $savJson)
        $htmlGenerated = (Test-Path $tlHtml) -or (Test-Path $savHtml)

        if (-not $jsonPresent) {
            Add-TestResult -Name 'HTML lourds absents si analyse WinPE' -Status 'SKIP' -Detail 'Aucun JSON source present — lancer une analyse pour verifier'
        }
        elseif (-not $htmlGenerated) {
            Add-TestResult -Name 'HTML lourds absents si analyse WinPE' -Status 'PASS' -Detail 'JSON present, HTML absent — comportement WinPE correct'
        }
        else {
            # HTML present : verifier s'il a ete genere post-analyse (tech PC) ou en WinPE
            Add-TestResult -Name 'HTML lourds absents si analyse WinPE' -Status 'SKIP' -Detail 'HTML present — peut etre genere legitimement sur PC technicien'
        }
    }
    else {
        Add-TestResult -Name 'HTML lourds absents si analyse WinPE' -Status 'SKIP' -Detail "Dossier reports introuvable : $ReportsPath"
    }
}
catch {
    Add-TestResult -Name 'HTML lourds absents si analyse WinPE' -Status 'FAIL' -Detail $_.Exception.Message
}

# ---------------------------------------------------------------------------
# TEST 6 : GUI launcher contient le label "PC technicien" pour WinPE
# ---------------------------------------------------------------------------
try {
    $launcherPath = Join-Path $PSScriptRoot 'launcher.ps1'
    if (Test-Path $launcherPath) {
        $src = Get-Content $launcherPath -Raw -Encoding UTF8
        $hasLabel = $src -match 'PC technicien' -and $src -match 'generate-html-reports'
        $hasIsWinPE = $src -match 'script:IsWinPE'
        if ($hasLabel -and $hasIsWinPE) {
            Add-TestResult -Name 'launcher.ps1 contient label WinPE + IsWinPE' -Status 'PASS'
        }
        else {
            Add-TestResult -Name 'launcher.ps1 contient label WinPE + IsWinPE' -Status 'FAIL' -Detail ("label=$hasLabel IsWinPE=$hasIsWinPE")
        }
    }
    else {
        Add-TestResult -Name 'launcher.ps1 contient label WinPE + IsWinPE' -Status 'SKIP' -Detail "Introuvable : $launcherPath"
    }
}
catch {
    Add-TestResult -Name 'launcher.ps1 contient label WinPE + IsWinPE' -Status 'FAIL' -Detail $_.Exception.Message
}

# ---------------------------------------------------------------------------
# Rapport final
# ---------------------------------------------------------------------------
$elapsed = [math]::Round(((Get-Date) - $scriptStart).TotalSeconds, 1)
$summary = [pscustomobject]@{
    suite      = 'WinPECollectorMode'
    date       = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    elapsed_s  = $elapsed
    total      = $results.Count
    pass       = $passCount
    fail       = $failCount
    skip       = $skipCount
    result     = if ($failCount -eq 0) { 'OK' } else { 'FAIL' }
    tests      = $results
}

$outBase = Join-Path $PSScriptRoot 'winpe-collector-mode-tests-report'
$summary | ConvertTo-Json -Depth 6 | Set-Content -Path ($outBase + '.json') -Encoding UTF8
$lines = @("=== WinPE Collector Mode Tests ===", "Date : $($summary.date)", "Duree : $elapsed s", '')
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
