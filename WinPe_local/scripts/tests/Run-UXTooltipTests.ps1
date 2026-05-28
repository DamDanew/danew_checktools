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

function Add-UXTooltipResult {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Details = ''
    )

    return [pscustomobject]@{ name = $Name; passed = $Passed; details = $Details }
}

$results = @()
$launcherPath = Join-Path $RootPath 'scripts\launcher.ps1'
$launcher = Get-Content -Path $launcherPath -Raw -Encoding UTF8

$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($launcherPath, [ref]$tokens, [ref]$errors) | Out-Null
$results += Add-UXTooltipResult -Name 'launcher_parser_ok' -Passed (-not $errors) -Details ($(if ($errors) { ($errors | Select-Object -First 1).Message } else { 'PowerShell parser clean' }))

$tooltipConfigOk = ($launcher -match '\$toolTip\.InitialDelay\s*=\s*400') -and ($launcher -match '\$toolTip\.AutoPopDelay\s*=\s*12000') -and ($launcher -match '\$toolTip\.ReshowDelay\s*=\s*100') -and ($launcher -match '\$toolTip\.ShowAlways\s*=\s*\$true')
$results += Add-UXTooltipResult -Name 'tooltip_object_configured' -Passed $tooltipConfigOk -Details 'Shared ToolTip object configured with expected delays.'

$requiredButtonHints = @(
    @{ text = 'ANALYSER LES JOURNAUX WINDOWS'; hint = 'Lit les journaux Windows EVTX de l installation hors ligne detectee.' },
    @{ text = 'ANALYSER LES CAUSES DE CRASH'; hint = 'Analyse les evenements Windows deja lus pour identifier les causes probables de panne.' },
    @{ text = 'OUVRIR LE RAPPORT SAV'; hint = 'Ouvre le rapport SAV principal.' },
    @{ text = 'OUVRIR LE RAPPORT CHRONOLOGIQUE'; hint = 'Ouvre la chronologie interactive des evenements Windows.' },
    @{ text = 'EXPORTER LE DOSSIER SAV'; hint = 'Cree un package SAV avec les rapports, journaux et exports disponibles.' },
    @{ text = 'EXPORT EVTX CIBLE'; hint = 'Genere les exports EVTX physiques dans reports' },
    @{ text = 'ACTIONS RECOMMANDEES'; hint = 'Affiche les actions SAV conseillees selon le diagnostic.' },
    @{ text = 'ACTUALISER LE RESUME'; hint = 'Recharge les derniers rapports disponibles et met a jour le resume SAV affiche dans l interface.' },
    @{ text = 'VERIFIER WINPE'; hint = 'Verifie que WinPE contient les composants necessaires: PowerShell, WinForms, EVTX' },
    @{ text = 'SCAN CAPACITES WINPE'; hint = 'Analyse les capacites de l environnement WinPE' },
    @{ text = 'GENERER LE RAPPORT DE BASE'; hint = 'Genere les rapports de base WinPE et environnement.' },
    @{ text = 'OUVRIR LE DOSSIER DES RAPPORTS'; hint = 'Ouvre le dossier reports contenant les rapports HTML, JSON, CSV et TXT generes.' },
    @{ text = 'QUITTER'; hint = 'Ferme l interface Danew SAV Diagnostic Tool.' }
)

$missingHints = @()
foreach ($item in @($requiredButtonHints)) {
    $hasText = $launcher.Contains("-Text '" + [string]$item.text + "'")
    $hasHint = $launcher.Contains([string]$item.hint)
    if (-not ($hasText -and $hasHint)) {
        $missingHints += [string]$item.text
    }
}
$results += Add-UXTooltipResult -Name 'required_button_tooltips_present' -Passed (@($missingHints).Count -eq 0) -Details ($(if (@($missingHints).Count -eq 0) { 'All required button tooltips found.' } else { 'Missing tooltip bindings for: ' + ($missingHints -join ', ') }))

$toggleTooltipsOk = ($launcher -match 'SetToolTip\(\$advancedToggleButton,\s*''Affiche les outils techniques') -and ($launcher -match 'SetToolTip\(\$technicalToggleButton,\s*''Affiche les informations techniques')
$results += Add-UXTooltipResult -Name 'toggle_button_tooltips_present' -Passed $toggleTooltipsOk -Details 'Advanced and technical toggle buttons have explicit tooltips.'

$hintMatches = [regex]::Matches($launcher, "-Hint\s+'(.+?)'\s+-Tone", [System.Text.RegularExpressions.RegexOptions]::Singleline)
$allHints = @($hintMatches | ForEach-Object { $_.Groups[1].Value })
$nonEmptyHints = @($allHints | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$results += Add-UXTooltipResult -Name 'tooltip_text_non_empty' -Passed (@($allHints).Count -eq @($nonEmptyHints).Count -and @($allHints).Count -gt 0) -Details ('total=' + [string]@($allHints).Count + '; non_empty=' + [string]@($nonEmptyHints).Count)

$nonAsciiHints = @($allHints | Where-Object { $_ -match '[^\x00-\x7F]' })
$results += Add-UXTooltipResult -Name 'tooltip_text_ascii_safe' -Passed (@($nonAsciiHints).Count -eq 0) -Details ($(if (@($nonAsciiHints).Count -eq 0) { 'All tooltip texts are ASCII-safe.' } else { 'non_ascii_count=' + [string]@($nonAsciiHints).Count }))

$mojiPattern = ([string][char]0x00C3) + '|' + ([string][char]0x00C2) + '|' + (([string][char]0x00E2) + ([string][char]0x20AC))
$mojiInHints = @($allHints | Where-Object { $_ -match $mojiPattern })
$results += Add-UXTooltipResult -Name 'tooltip_no_mojibake_markers' -Passed (@($mojiInHints).Count -eq 0) -Details ($(if (@($mojiInHints).Count -eq 0) { 'No mojibake markers in tooltips.' } else { 'mojibake_count=' + [string]@($mojiInHints).Count }))

$readOnlyHintOk = ($launcher -match "ANALYSER LES JOURNAUX WINDOWS'.*Action en lecture seule") -and ($launcher -match "ANALYSER LES CAUSES DE CRASH'.*Action en lecture seule")
$results += Add-UXTooltipResult -Name 'read_only_mentions_present' -Passed $readOnlyHintOk -Details 'Read-only wording present where applicable.'

$evtxHintOk = $launcher -match "(?s)EXPORT EVTX CIBLE'.*CSV/TXT"
$results += Add-UXTooltipResult -Name 'evtx_tooltip_mentions_csv_txt' -Passed $evtxHintOk -Details 'EVTX targeted export tooltip mentions CSV/TXT outputs.'

$precheckHintOk = $launcher -match "VERIFIER WINPE'.*PowerShell.*WinForms.*EVTX"
$results += Add-UXTooltipResult -Name 'precheck_tooltip_mentions_ps_winforms_evtx' -Passed $precheckHintOk -Details 'WinPE precheck tooltip mentions PowerShell/WinForms/EVTX.'

$encodingScript = Join-Path $RootPath 'scripts\tests\Run-UXEncodingTests.ps1'
$encodingExit = 1
if (Test-Path -Path $encodingScript) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $encodingScript -RootPath $RootPath -OutputDirectory $OutputDirectory | Out-Null
    $encodingExit = $LASTEXITCODE
}
$results += Add-UXTooltipResult -Name 'ux_encoding_regression_pass' -Passed ($encodingExit -eq 0) -Details ('exit=' + [string]$encodingExit)

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

$jsonPath = Join-Path $OutputDirectory 'ux-tooltip-tests-report.json'
$txtPath = Join-Path $OutputDirectory 'ux-tooltip-tests-report.txt'

$report | ConvertTo-Json -Depth 20 | Set-Content -Path $jsonPath -Encoding UTF8

$lines = @(
    'UX Tooltip Tests',
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

Write-Host ('UX tooltip test report JSON: ' + $jsonPath)
Write-Host ('UX tooltip test report TXT: ' + $txtPath)

if ($summary.failed -gt 0) {
    exit 1
}
