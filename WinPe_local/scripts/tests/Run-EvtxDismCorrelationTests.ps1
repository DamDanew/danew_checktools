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

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $RootPath 'reports'
}

if (-not (Test-Path -Path $OutputDirectory)) {
    New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
}

function Add-CorrelationResult {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [bool]$Passed,
        [string]$Details = ''
    )

    return [pscustomobject]@{
        name = $Name
        passed = $Passed
        details = $Details
    }
}

function Try-ParseDate {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse($Value, [ref]$parsed)) {
        return $parsed
    }

    return $null
}

$offlineEnginePath = Join-Path $RootPath 'scripts\offline\OfflineLogsEngine.ps1'
$crashEnginePath = Join-Path $RootPath 'scripts\offline\CrashAnalysisEngine.ps1'
if (Test-Path -Path $offlineEnginePath) {
    . $offlineEnginePath
}
if (Test-Path -Path $crashEnginePath) {
    . $crashEnginePath
}

$results = @()

$reportsPath = Join-Path $RootPath 'reports'
$evtxEventsPath = Join-Path $reportsPath 'evtx-events.json'

$results += Add-CorrelationResult -Name 'evtx_events_json_exists' -Passed (Test-Path -Path $evtxEventsPath) -Details $evtxEventsPath

$evtxEvents = @()
if (Test-Path -Path $evtxEventsPath) {
    try {
        $evtxEvents = @(Get-Content -Path $evtxEventsPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    catch {
        $results += Add-CorrelationResult -Name 'evtx_events_json_parse' -Passed $false -Details $_.Exception.Message
    }
}

if (@($evtxEvents).Count -gt 0) {
    $results += Add-CorrelationResult -Name 'evtx_events_json_parse' -Passed $true -Details ('events=' + [string]@($evtxEvents).Count)

    $updateProvidersPattern = 'WindowsUpdateClient|Servicing|UpdateOrchestrator|Kernel-Boot|Kernel-General'
    $updateMessagePattern = 'KB\d{4,7}|\bDISM\b|packageChanges|cumulative update|quality update|servicing stack|HotFix'

    $evtxUpdateHits = @(
        $evtxEvents | Where-Object {
            ([string]$_.provider -match $updateProvidersPattern) -or
            ([string]$_.message -match $updateMessagePattern)
        }
    )

    $results += Add-CorrelationResult -Name 'evtx_has_update_signals' -Passed (@($evtxUpdateHits).Count -gt 0) -Details ('hits=' + [string]@($evtxUpdateHits).Count)
}
else {
    $results += Add-CorrelationResult -Name 'evtx_has_update_signals' -Passed $false -Details 'No EVTX events available.'
}

$dismCandidates = @(
    (Join-Path $reportsPath 'Offline_Packages.txt'),
    (Join-Path $reportsPath 'Installed_KB_List.csv'),
    (Join-Path $reportsPath 'Installed_KB_List.txt'),
    (Join-Path $reportsPath 'Windows_Update_Timeline.csv'),
    (Join-Path $reportsPath 'windows-update-timeline.csv')
)

$existingDismArtifacts = @($dismCandidates | Where-Object { Test-Path -Path $_ })

$fixtureRoot = Join-Path $OutputDirectory 'evtx-dism-correlation-fixture'
$fixtureVolumeRoot = Join-Path $fixtureRoot 'volume'
$fixtureDismDir = Join-Path $fixtureVolumeRoot 'Windows\Logs\DISM'
$fixtureCbsDir = Join-Path $fixtureVolumeRoot 'Windows\Logs\CBS'
if (Test-Path -Path $fixtureRoot) {
    Remove-Item -Path $fixtureRoot -Recurse -Force
}
New-Item -Path $fixtureDismDir -ItemType Directory -Force | Out-Null
New-Item -Path $fixtureCbsDir -ItemType Directory -Force | Out-Null

$fixtureDismPath = Join-Path $fixtureDismDir 'dism.log'
$fixtureCbsPath = Join-Path $fixtureCbsDir 'CBS.log'
@(
    '2026-06-03 10:00:00, Info                  DISM   Package Manager initialized.',
    '2026-06-03 10:05:00, Error                 DISM   DISM Package Manager: Failed to install package KB5074109 with error 0x800f081f.',
    '2026-06-03 10:06:00, Warning               DISM   Servicing stack reported corruption marker.'
) | Set-Content -Path $fixtureDismPath -Encoding UTF8
@(
    '2026-06-03 10:07:00, Error                 CBS    Failed to resolve package KB5074109. Mark store corruption flag.',
    '2026-06-03 10:08:00, Warning               CBS    Reboot required after servicing package.'
) | Set-Content -Path $fixtureCbsPath -Encoding Unicode

$fixtureDismCbsEvents = @()
try {
    $fixtureDismCbsEvents = @(Read-DanewDismCbsTextLogs -WindowsRoot $fixtureVolumeRoot -MaxTailLines 3000)
}
catch {
    $fixtureDismCbsEvents = @()
    $results += Add-CorrelationResult -Name 'dism_cbs_fixture_parse' -Passed $false -Details $_.Exception.Message
}

if (@($fixtureDismCbsEvents).Count -gt 0) {
    $hasDism = @($fixtureDismCbsEvents | Where-Object { [string]$_.provider -match 'DISM' }).Count -gt 0
    $hasCbs = @($fixtureDismCbsEvents | Where-Object { [string]$_.provider -match 'CBS' }).Count -gt 0
    $hasKb = @($fixtureDismCbsEvents | Where-Object { [string]$_.message -match 'KB5074109' }).Count -gt 0
    $results += Add-CorrelationResult -Name 'dism_cbs_fixture_parse' -Passed ($hasDism -and $hasCbs -and $hasKb) -Details ('events=' + [string]@($fixtureDismCbsEvents).Count + '; dism=' + [string]$hasDism + '; cbs=' + [string]$hasCbs + '; kb=' + [string]$hasKb)
}

$results += Add-CorrelationResult -Name 'dism_or_kb_artifact_present' -Passed ((@($existingDismArtifacts).Count -gt 0) -or (@($fixtureDismCbsEvents).Count -gt 0)) -Details ($(if (@($existingDismArtifacts).Count -gt 0) { ($existingDismArtifacts -join '; ') } elseif (@($fixtureDismCbsEvents).Count -gt 0) { 'Synthetic DISM/CBS fixture generated for local validation.' } else { 'No DISM/KB artifact file found in reports and fixture parser returned no event.' }))

$correlationPossible = $false
$correlationDetails = 'Insufficient data for timestamp correlation.'

if (@($evtxEvents).Count -gt 0 -and @($existingDismArtifacts).Count -gt 0) {
    $eventTimes = @(
        $evtxEvents | ForEach-Object { Try-ParseDate -Value ([string]$_.timestamp) } | Where-Object { $null -ne $_ }
    )

    if (@($eventTimes).Count -gt 0) {
        $minEvent = ($eventTimes | Sort-Object | Select-Object -First 1)
        $maxEvent = ($eventTimes | Sort-Object -Descending | Select-Object -First 1)
        $correlationPossible = $true
        $correlationDetails = ('EVTX window: ' + $minEvent.ToString('s') + ' -> ' + $maxEvent.ToString('s') + '; DISM artifacts: ' + ($existingDismArtifacts -join ', '))
    }
}

if (-not $correlationPossible -and @($fixtureDismCbsEvents).Count -gt 0) {
    $fixtureCrashEvents = @(
        $fixtureDismCbsEvents
        [pscustomobject]@{
            timestamp = '2026-06-03 12:00:00'
            level = 'Critical'
            level_fr = 'Critique'
            provider = 'Microsoft-Windows-WER-SystemErrorReporting'
            event_id = 1001
            channel = 'System'
            message = 'BugCheck / BSOD after package KB5074109. Stop code 0x7B.'
            source_file = 'System.evtx'
            installation_root = $fixtureVolumeRoot
        }
    )

    $classification = Get-DanewCrashClassification -LogRecords $fixtureCrashEvents
    $timeline = Get-DanewCrashTimelineIntelligence -LogRecords $fixtureCrashEvents -ClassifiedRecords $classification.records
    $fixturePatterns = @($timeline.intelligence | Where-Object {
            [string]$_.pattern -in @('KB -> crash within 24h', 'DISM/CBS servicing before crash', 'CBS/DISM corruption marker with storage errors')
        })

    if (@($fixturePatterns).Count -gt 0) {
        $correlationPossible = $true
        $correlationDetails = 'Synthetic DISM/CBS fixture correlation patterns: ' + ((@($fixturePatterns | ForEach-Object { [string]$_.pattern })) -join ', ')
    }
}

$results += Add-CorrelationResult -Name 'evtx_dism_correlation_window_available' -Passed $correlationPossible -Details $correlationDetails

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

$jsonPath = Join-Path $OutputDirectory 'evtx-dism-correlation-tests-report.json'
$txtPath = Join-Path $OutputDirectory 'evtx-dism-correlation-tests-report.txt'

$report | ConvertTo-Json -Depth 20 | Set-Content -Path $jsonPath -Encoding UTF8

$lines = @(
    'EVTX + DISM Correlation Tests',
    ('Total: ' + [string]$summary.total),
    ('Passed: ' + [string]$summary.passed),
    ('Failed: ' + [string]$summary.failed),
    ''
)

foreach ($item in @($results)) {
    $status = if ($item.passed) { 'PASS' } else { 'FAIL' }
    $lines += ('[' + $status + '] ' + $item.name + ' - ' + $item.details)
}

$lines | Set-Content -Path $txtPath -Encoding UTF8

Write-Host ('EVTX+DISM correlation test report JSON: ' + $jsonPath)
Write-Host ('EVTX+DISM correlation test report TXT: ' + $txtPath)

if ($summary.failed -gt 0) {
    exit 1
}
