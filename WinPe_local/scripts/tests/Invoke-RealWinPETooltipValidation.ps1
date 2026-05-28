[CmdletBinding()]
param(
    [string]$RootPath,
    [string]$OutputDirectory,
    [string]$LauncherPath,
    [switch]$SkipManualChecklist
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

function Get-DanewTooltipValidationEnvironment {
    param([string]$RootPath)

    $systemDrive = [string]$env:SystemDrive
    $runningFromX = (($systemDrive -eq 'X:') -or ((Get-Location).Path -match '^(?i)X:\\'))
    $winpeDetected = $runningFromX -or (Test-Path -Path 'X:\Windows\System32\startnet.cmd')

    $bootVolume = ''
    $dataVolume = ''
    try {
        if (Get-Command -Name Get-Volume -ErrorAction SilentlyContinue) {
            $volumes = @(Get-Volume -ErrorAction SilentlyContinue)
            $bootCandidate = @($volumes | Where-Object { [string]$_.FileSystemLabel -match '^(?i)BOOT$' } | Select-Object -First 1)
            $dataCandidate = @($volumes | Where-Object { [string]$_.FileSystemLabel -match '^(?i)(DATA|DANEW_DATA)$' } | Select-Object -First 1)
            if (@($bootCandidate).Count -gt 0 -and $bootCandidate[0].DriveLetter) {
                $bootVolume = [string]$bootCandidate[0].DriveLetter + ':'
            }
            if (@($dataCandidate).Count -gt 0 -and $dataCandidate[0].DriveLetter) {
                $dataVolume = [string]$dataCandidate[0].DriveLetter + ':'
            }
        }
    }
    catch {
    }

    if ([string]::IsNullOrWhiteSpace($bootVolume) -and (Test-Path -Path 'D:\scripts\launcher.ps1')) {
        $bootVolume = 'D:'
    }
    if ([string]::IsNullOrWhiteSpace($dataVolume) -and (Test-Path -Path 'E:\scripts\launcher.ps1')) {
        $dataVolume = 'E:'
    }

    [pscustomobject]@{
        environment = if ($winpeDetected) { 'WinPE' } else { 'Local' }
        winpe_detected = [bool]$winpeDetected
        running_from_x = [bool]$runningFromX
        root_path = $RootPath
        boot_volume = $bootVolume
        data_volume = $dataVolume
        system_drive = $systemDrive
    }
}

function Resolve-DanewTooltipLauncherPath {
    param(
        [string]$RootPath,
        [string]$LauncherPath
    )

    if (-not [string]::IsNullOrWhiteSpace($LauncherPath) -and (Test-Path -Path $LauncherPath)) {
        return (Resolve-Path $LauncherPath).Path
    }

    $candidates = @(
        (Join-Path $RootPath 'scripts\launcher.ps1'),
        'E:\scripts\launcher.ps1',
        'D:\scripts\launcher.ps1'
    )

    foreach ($candidate in @($candidates)) {
        if (Test-Path -Path $candidate) {
            return (Resolve-Path $candidate).Path
        }
    }

    return (Join-Path $RootPath 'scripts\launcher.ps1')
}

function Get-DanewTooltipChecklistText {
    return @(
        '1. Open the launcher.',
        '2. Hover over ANALYSER LES JOURNAUX WINDOWS.',
        '3. Confirm tooltip appears and mentions EVTX / reports / lecture seule.',
        '4. Hover over ANALYSER LES CAUSES DE CRASH.',
        '5. Confirm tooltip appears and mentions causes probables / confiance / gravite.',
        '6. Hover over EXPORT EVTX CIBLE.',
        '7. Confirm tooltip appears and mentions CSV / TXT / reports.',
        '8. Hover over VERIFIER WINPE.',
        '9. Confirm tooltip appears and mentions PowerShell / WinForms / EVTX.',
        '10. Confirm no mojibake appears in tooltips.'
    )
}

function Get-DanewTooltipScanResult {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LauncherText,
        [Parameter(Mandatory = $true)]
        [string[]]$ExpectedButtons,
        [Parameter(Mandatory = $true)]
        [object[]]$TooltipRules,
        [Parameter(Mandatory = $true)]
        [object[]]$ToggleRules
    )

    $buttonResults = @()
    foreach ($button in @($ExpectedButtons)) {
        $buttonResults += [pscustomobject]@{
            label = $button
            found = ($LauncherText -match [regex]::Escape($button))
        }
    }

    $tooltipResults = @()
    foreach ($rule in @($TooltipRules)) {
        $tooltipResults += [pscustomobject]@{
            label = [string]$rule.label
            found = (($LauncherText.Contains([string]$rule.label)) -and ($LauncherText.Contains([string]$rule.expected_text)))
            expected_text = [string]$rule.expected_text
        }
    }

    $toggleResults = @()
    foreach ($rule in @($ToggleRules)) {
        $toggleResults += [pscustomobject]@{
            label = [string]$rule.label
            found = $LauncherText.Contains([string]$rule.expected_text)
            expected_text = [string]$rule.expected_text
        }
    }

    $hintMatches = @([regex]::Matches($LauncherText, "-Hint\s+'(.+?)'\s+-Tone", [System.Text.RegularExpressions.RegexOptions]::Singleline) | ForEach-Object { $_.Groups[1].Value })
    $nonEmptyHints = @($hintMatches | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $nonAsciiHints = @($hintMatches | Where-Object { $_ -match '[^\x00-\x7F]' })
    $mojiPattern = ([string][char]0x00C3) + '|' + ([string][char]0x00C2) + '|' + (([string][char]0x00E2) + ([string][char]0x20AC))
    $mojibakeHits = @($hintMatches | Where-Object { $_ -match $mojiPattern }).Count

    $quality = [pscustomobject]@{
        tooltip_count = @($hintMatches).Count
        non_empty = @($nonEmptyHints).Count
        ascii_safe = (@($nonAsciiHints).Count -eq 0)
        mojibake_hits = $mojibakeHits
        read_only_mentions = @($hintMatches | Where-Object { $_ -match 'lecture seule' }).Count
        csv_txt_mentions = @($hintMatches | Where-Object { $_ -match 'CSV' -and $_ -match 'TXT' }).Count
        ps_winforms_evtx_mentions = @($hintMatches | Where-Object { $_ -match 'PowerShell' -and $_ -match 'WinForms' -and $_ -match 'EVTX' }).Count
    }

    [pscustomobject]@{
        buttons = $buttonResults
        tooltip_rules = $tooltipResults
        toggle_rules = $toggleResults
        tooltip_quality = $quality
        all_buttons_found = (@($buttonResults | Where-Object { -not $_.found }).Count -eq 0)
        all_tooltip_rules_found = (@($tooltipResults | Where-Object { -not $_.found }).Count -eq 0)
        all_toggle_rules_found = (@($toggleResults | Where-Object { -not $_.found }).Count -eq 0)
        all_tooltips_ascii_safe = $quality.ascii_safe
        mojibake_hits = [int]$quality.mojibake_hits
        tooltips_non_empty = ($quality.tooltip_count -gt 0 -and $quality.tooltip_count -eq $quality.non_empty)
    }
}

function Write-DanewTooltipChecklist {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $lines = @(
        'Danew SAV WinPE Tooltip Checklist',
        ''
    )
    $lines += (Get-DanewTooltipChecklistText)
    $lines | Set-Content -Path $Path -Encoding UTF8
}

$environment = Get-DanewTooltipValidationEnvironment -RootPath $RootPath
$launcherResolvedPath = Resolve-DanewTooltipLauncherPath -RootPath $RootPath -LauncherPath $LauncherPath
$launcherFound = Test-Path -Path $launcherResolvedPath
$launcherText = ''
if ($launcherFound) {
    $launcherText = Get-Content -Path $launcherResolvedPath -Raw -Encoding UTF8
}

$expectedButtons = @(
    'ANALYSER LES JOURNAUX WINDOWS',
    'ANALYSER LES CAUSES DE CRASH',
    'OUVRIR LE RAPPORT SAV',
    'OUVRIR LE RAPPORT CHRONOLOGIQUE',
    'EXPORTER LE DOSSIER SAV',
    'EXPORT EVTX CIBLE',
    'ACTIONS RECOMMANDEES',
    'AFFICHER LES OUTILS AVANCES',
    'AFFICHER LES DETAILS TECHNIQUES',
    'VERIFIER WINPE',
    'SCAN CAPACITES WINPE',
    'GENERER LE RAPPORT DE BASE',
    'OUVRIR LE DOSSIER DES RAPPORTS',
    'QUITTER'
)

$tooltipRules = @(
    [pscustomobject]@{ label = 'ANALYSER LES JOURNAUX WINDOWS'; expected_text = 'Lit les journaux Windows EVTX de l installation hors ligne detectee.' },
    [pscustomobject]@{ label = 'ANALYSER LES CAUSES DE CRASH'; expected_text = 'Analyse les evenements Windows deja lus pour identifier les causes probables de panne.' },
    [pscustomobject]@{ label = 'OUVRIR LE RAPPORT SAV'; expected_text = 'Ouvre le rapport SAV principal.' },
    [pscustomobject]@{ label = 'OUVRIR LE RAPPORT CHRONOLOGIQUE'; expected_text = 'Ouvre la chronologie interactive des evenements Windows.' },
    [pscustomobject]@{ label = 'EXPORTER LE DOSSIER SAV'; expected_text = 'Cree un package SAV avec les rapports, journaux et exports disponibles.' },
    [pscustomobject]@{ label = 'EXPORT EVTX CIBLE'; expected_text = 'Genere les exports EVTX physiques dans reports:' },
    [pscustomobject]@{ label = 'ACTIONS RECOMMANDEES'; expected_text = 'Affiche les actions SAV conseillees selon le diagnostic.' },
    [pscustomobject]@{ label = 'ACTUALISER LE RESUME'; expected_text = 'Recharge les derniers rapports disponibles et met a jour le resume SAV affiche dans l interface.' },
    [pscustomobject]@{ label = 'VERIFIER WINPE'; expected_text = 'Verifie que WinPE contient les composants necessaires: PowerShell, WinForms, EVTX' },
    [pscustomobject]@{ label = 'SCAN CAPACITES WINPE'; expected_text = 'Analyse les capacites de l environnement WinPE' },
    [pscustomobject]@{ label = 'GENERER LE RAPPORT DE BASE'; expected_text = 'Genere les rapports de base WinPE et environnement.' },
    [pscustomobject]@{ label = 'OUVRIR LE DOSSIER DES RAPPORTS'; expected_text = 'Ouvre le dossier reports contenant les rapports HTML, JSON, CSV et TXT generes.' },
    [pscustomobject]@{ label = 'QUITTER'; expected_text = 'Ferme l interface Danew SAV Diagnostic Tool.' }
)

$toggleRules = @(
    [pscustomobject]@{ label = 'AFFICHER LES OUTILS AVANCES'; expected_text = 'Affiche les outils techniques: scan WinPE, verification WinPE, rapports de base et outils USB.' },
    [pscustomobject]@{ label = 'AFFICHER LES DETAILS TECHNIQUES'; expected_text = 'Affiche les informations techniques du launcher, chemins, runtime, logs et etat interne.' }
)

$scanResult = [pscustomobject]@{
    launcher_path = $launcherResolvedPath
    launcher_found = [bool]$launcherFound
    expected_buttons_found = $null
    tooltip_static_validation = 'FAIL'
    ascii_safe = $false
    mojibake_hits = 0
    tooltip_quality = $null
    manual_visual_validation_required = $true
    manual_checklist_path = ''
    environment = $environment.environment
    root_path = $environment.root_path
    boot_volume = $environment.boot_volume
    data_volume = $environment.data_volume
    reports_path = $OutputDirectory
    static_status = 'FAIL'
    global_status = 'FAIL'
    gui_smoke = [pscustomobject]@{
        attempted = $false
        supported = $false
        result = 'not attempted'
    }
}

if (-not $launcherFound) {
    $scanResult.static_status = 'FAIL'
    $scanResult.global_status = 'FAIL'
}
else {
    $scan = Get-DanewTooltipScanResult -LauncherText $launcherText -ExpectedButtons $expectedButtons -TooltipRules $tooltipRules -ToggleRules $toggleRules
    $tooltipStaticPass = $scan.all_buttons_found -and $scan.all_tooltip_rules_found -and $scan.all_toggle_rules_found -and $scan.tooltips_non_empty -and $scan.all_tooltips_ascii_safe -and ($scan.mojibake_hits -eq 0)
    $scanResult.expected_buttons_found = $scan.buttons
    $scanResult.tooltip_static_validation = if ($tooltipStaticPass) { 'PASS' } else { 'FAIL' }
    $scanResult.ascii_safe = [bool]$scan.all_tooltips_ascii_safe
    $scanResult.mojibake_hits = [int]$scan.mojibake_hits
    $scanResult.tooltip_quality = $scan.tooltip_quality
    $scanResult.static_status = if ($tooltipStaticPass) { 'PASS' } else { 'FAIL' }

    if (-not $environment.winpe_detected) {
        $scanResult.global_status = if ($tooltipStaticPass) { 'LIMITED' } else { 'FAIL' }
    }
    else {
        $scanResult.global_status = if ($tooltipStaticPass) { 'PASS' } else { 'WARNING' }
    }
}

if (-not $SkipManualChecklist) {
    if (-not (Test-Path -Path $OutputDirectory)) {
        New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
    }
    $checklistPath = Join-Path $OutputDirectory 'real-winpe-tooltip-checklist.txt'
    Write-DanewTooltipChecklist -Path $checklistPath
    $scanResult.manual_checklist_path = $checklistPath
}

$scanResult.manual_visual_validation_required = $true
$scanResult.gui_smoke = [pscustomobject]@{
    attempted = $false
    supported = $environment.winpe_detected -and $scanResult.launcher_found
    result = 'manual validation required'
}

if (-not (Test-Path -Path $OutputDirectory)) {
    New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
}

$jsonPath = Join-Path $OutputDirectory 'real-winpe-tooltip-validation.json'
$txtPath = Join-Path $OutputDirectory 'real-winpe-tooltip-validation.txt'
$checklistPathFinal = if ($scanResult.manual_checklist_path) { $scanResult.manual_checklist_path } else { Join-Path $OutputDirectory 'real-winpe-tooltip-checklist.txt' }

$scanResult | ConvertTo-Json -Depth 30 | Set-Content -Path $jsonPath -Encoding UTF8

$txtLines = @(
    'Danew Real WinPE Tooltip Validation',
    ('Environment: ' + [string]$scanResult.environment),
    ('GlobalStatus: ' + [string]$scanResult.global_status),
    ('LauncherFound: ' + [string]$scanResult.launcher_found),
    ('TooltipStaticValidation: ' + [string]$scanResult.tooltip_static_validation),
    ('AsciiSafe: ' + [string]$scanResult.ascii_safe),
    ('MojibakeHits: ' + [string]$scanResult.mojibake_hits),
    ('ManualVisualValidationRequired: ' + [string]$scanResult.manual_visual_validation_required),
    ('ManualChecklist: ' + [string]$checklistPathFinal),
    ''
)
if ($scanResult.expected_buttons_found) {
    $txtLines += 'Buttons:'
    foreach ($button in @($scanResult.expected_buttons_found)) {
        $txtLines += ('- ' + [string]$button.label + ' = ' + [string]$button.found)
    }
}
$txtLines | Set-Content -Path $txtPath -Encoding UTF8

Write-Host ('Tooltip validation JSON: ' + $jsonPath)
Write-Host ('Tooltip validation TXT: ' + $txtPath)
Write-Host ('Tooltip checklist TXT: ' + $checklistPathFinal)

if ($scanResult.global_status -eq 'FAIL') {
    exit 1
}
