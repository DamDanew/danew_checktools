Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DanewLocalizedStatusText {
    param(
        [AllowNull()]
        [object]$Value
    )

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return ''
    }

    switch ($text.Trim().ToUpperInvariant()) {
        'PASS' { return 'OK' }
        'OK' { return 'OK' }
        'SUCCESS' { return 'SUCCES' }
        'WARNING' { return 'ALERTE' }
        'WARN' { return 'ALERTE' }
        'FAIL' { return 'ECHEC' }
        'ERROR' { return 'ERREUR' }
        'CRITICAL' { return 'CRITIQUE' }
        'INFO' { return 'INFO' }
        'IDLE' { return 'INACTIF' }
        'RUNNING' { return 'EN COURS' }
        'READY' { return 'EN ATTENTE' }
        'WAITING' { return 'EN ATTENTE' }
        'GENERATED' { return 'GENERE' }
        'NOT READY' { return 'NON PRET' }
        default { return $text }
    }
}

function Get-DanewLocalizedConfidenceText {
    param(
        [AllowNull()]
        [object]$Value
    )

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return ''
    }

    switch ($text.Trim().ToLowerInvariant()) {
        'high' { return 'Elevee' }
        'medium' { return 'Moyenne' }
        'low' { return 'Faible' }
        'unknown' { return 'Inconnue' }
        default { return $text }
    }
}

function Get-DanewLocalizedCauseText {
    param(
        [AllowNull()]
        [object]$Value
    )

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return ''
    }

    switch ($text) {
        'Intel RST/VMD issue' { return 'Probleme Intel RST/VMD' }
        'failing SSD' { return 'SSD en degradation' }
        'inaccessible NVMe controller' { return 'Controleur NVMe inaccessible' }
        'failed Windows Update' { return 'Echec de mise a jour Windows' }
        'corrupted NTFS filesystem' { return 'Systeme de fichiers NTFS corrompu' }
        'BitLocker lock state' { return 'Volume verrouille par BitLocker' }
        'thermal instability' { return 'Instabilite thermique' }
        'memory instability' { return 'Instabilite memoire' }
        'inaccessible SYSTEM hive' { return 'Ruche SYSTEM inaccessible' }
        'storage driver incompatibility' { return 'Incompatibilite de pilote de stockage' }
        'corrupted BCD' { return 'BCD corrompu' }
        'boot partition corruption' { return 'Partition de demarrage corrompue' }
        default { return $text }
    }
}

function Get-DanewLocalizedBooleanText {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($Value -is [bool]) {
        return $(if ($Value) { 'Oui' } else { 'Non' })
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return ''
    }

    switch ($text.Trim().ToLowerInvariant()) {
        'true' { return 'Oui' }
        'false' { return 'Non' }
        default { return $text }
    }
}

function Get-DanewLocalizedRecommendationText {
    param(
        [AllowNull()]
        [object]$Value
    )

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return ''
    }

    switch ($text) {
        'Verify BIOS storage mode and inject the matching Intel RST/VMD driver if required.' { return 'Verifier le mode de stockage du BIOS et injecter le pilote Intel RST/VMD correspondant si necessaire.' }
        'Run a non-destructive SSD health check and verify controller visibility.' { return 'Executer un controle non destructif de l etat du SSD et verifier la visibilite du controleur.' }
        'Verify NVMe visibility in firmware and storage driver support in WinPE.' { return 'Verifier la visibilite du NVMe dans le firmware et la prise en charge du pilote de stockage dans WinPE.' }
        'Review the last update window and compare it with the crash timeline.' { return 'Examiner la derniere fenetre de mise a jour et la comparer a la chronologie du crash.' }
        'Inspect the NTFS corruption pattern and preserve the disk state for offline analysis.' { return 'Examiner le schema de corruption NTFS et preserver l etat du disque pour l analyse hors ligne.' }
        'Confirm whether the target volume is intentionally locked and whether recovery metadata is available.' { return 'Confirmer si le volume cible est volontairement verrouille et si les informations de recuperation sont disponibles.' }
        'Check thermal history and cooling/power stability around the crash window.' { return 'Verifier l historique thermique et la stabilite du refroidissement et de l alimentation autour du crash.' }
        'Correlate the crash window with hardware memory diagnostics if available.' { return 'Croiser la fenetre du crash avec les diagnostics materiels memoire si disponibles.' }
        'Correlate the primary cause with the offline storage and registry evidence.' { return 'Croiser la cause principale avec les preuves de stockage et de registre hors ligne.' }
        'Review storage, driver, and timeline evidence for the strongest failure chain.' { return 'Examiner les preuves de stockage, de pilotes et de chronologie pour identifier la chaine de panne la plus probable.' }
        'Do not perform repairs from this phase; keep the analysis read-only.' { return 'Ne pas lancer de reparation a cette etape ; conserver une analyse en lecture seule.' }
        default { return $text }
    }
}

function Get-DanewLocalizedImpactText {
    param(
        [AllowNull()]
        [object]$Value
    )

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return ''
    }

    switch ($text) {
        'Windows may be unable to boot or may be crashing soon after boot.' { return 'Windows peut ne pas demarrer ou planter peu apres le demarrage.' }
        'Windows volumes may be inaccessible until the lock state is resolved outside this phase.' { return 'Les volumes Windows peuvent rester inaccessibles tant que le verrouillage n est pas traite hors de cette phase.' }
        default { return $text }
    }
}

function ConvertTo-DanewReportHtmlText {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return ''
    }

    return [System.Security.SecurityElement]::Escape([string]$Value)
}

function ConvertTo-DanewReportToken {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return 'neutral'
    }

    $token = ([string]$Value).ToLowerInvariant()
    switch ($token) {
        { $_ -in @('pass', 'ok', 'ready', 'generated', 'high', 'info') } { return 'good' }
        { $_ -in @('warning', 'warn', 'medium') } { return 'warn' }
        { $_ -in @('fail', 'failed', 'critical', 'danger', 'error', 'low', 'not ready') } { return 'danger' }
        default { return 'neutral' }
    }
}

function New-DanewReportBadgeHtml {
    param(
        [string]$Text,
        [string]$Tone = 'neutral'
    )

    $safeText = ConvertTo-DanewReportHtmlText (Get-DanewLocalizedStatusText $Text)
    $safeTone = ConvertTo-DanewReportHtmlText (ConvertTo-DanewReportToken $Tone)
    return '<span class="report-badge report-badge-' + $safeTone + '">' + $safeText + '</span>'
}

function New-DanewMetricCardHtml {
    param(
        [string]$Label,
        [AllowNull()]
        [object]$Value,
        [string]$Tone = 'neutral'
    )

    return @"
<div class="metric-card" data-tone="$(ConvertTo-DanewReportHtmlText (ConvertTo-DanewReportToken $Tone))">
<div class="metric-label">$(ConvertTo-DanewReportHtmlText $Label)</div>
<div class="metric-value">$(ConvertTo-DanewReportHtmlText $Value)</div>
</div>
"@
}

function New-DanewReportMetaListHtml {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Items
    )

    $rows = @()
    foreach ($item in @($Items)) {
        if ($null -eq $item) {
            continue
        }

        $label = ConvertTo-DanewReportHtmlText $item.label
        $value = ConvertTo-DanewReportHtmlText $item.value
        if ([string]::IsNullOrWhiteSpace($label) -and [string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        $rows += '<div class="meta-item"><span class="meta-label">' + $label + '</span><span class="meta-value">' + $value + '</span></div>'
    }

    if (@($rows).Count -eq 0) {
        return ''
    }

    return '<div class="meta-grid">' + ($rows -join '') + '</div>'
}

function New-DanewReportSectionHtml {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,
        [Parameter(Mandatory = $true)]
        [string]$BodyHtml,
        [string]$SearchText = '',
        [string]$Caption = '',
        [bool]$Collapsed = $false
    )

    $sectionId = 'section-' + ([guid]::NewGuid().ToString('N'))
    $safeTitle = ConvertTo-DanewReportHtmlText $Title
    $safeSearch = ConvertTo-DanewReportHtmlText $SearchText
    $safeCaption = ConvertTo-DanewReportHtmlText $Caption
    $expanded = if ($Collapsed) { 'false' } else { 'true' }
    $hidden = if ($Collapsed) { ' hidden' } else { '' }
    $captionHtml = if ([string]::IsNullOrWhiteSpace($safeCaption)) { '' } else { '<p class="section-caption">' + $safeCaption + '</p>' }

    return @"
<section class="report-card" data-section-card data-search="$safeSearch">
<div class="section-head">
<div>
<h2>$safeTitle</h2>
$captionHtml
</div>
<button type="button" class="ghost-button" data-section-toggle aria-expanded="$expanded" aria-controls="$sectionId">Basculer</button>
</div>
<div id="$sectionId" class="section-body"$hidden>
$BodyHtml
</div>
</section>
"@
}

function New-DanewReportTableHtml {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Headers,
        [AllowEmptyCollection()]
        [string[]]$Rows = @(),
        [int[]]$SortableColumns = @(),
        [string]$EmptyMessage = 'Aucune ligne a afficher.'
    )

    $headerCells = @()
    for ($i = 0; $i -lt @($Headers).Count; $i++) {
        $label = ConvertTo-DanewReportHtmlText $Headers[$i]
        $isSortable = (@($SortableColumns).Count -eq 0) -or ($i -in $SortableColumns)
        if ($isSortable) {
            $headerCells += '<th data-column-index="' + [string]$i + '" data-sortable="true" data-sort-index="' + [string]$i + '" data-sort-direction="none" draggable="true"><button type="button" class="sort-header-button" data-sort-trigger="' + [string]$i + '"><span>' + $label + '</span><span class="sort-indicator" aria-hidden="true">+/-</span></button><span class="column-resize-handle" data-column-resize title="Redimensionner la colonne"></span></th>'
        }
        else {
            $headerCells += '<th data-column-index="' + [string]$i + '" draggable="true">' + $label + '<span class="column-resize-handle" data-column-resize title="Redimensionner la colonne"></span></th>'
        }
    }
    $headerHtml = $headerCells -join ''
    $rowItems = @($Rows)
    $rowsHtml = $rowItems -join "`n"
    $emptyStateHidden = if ($rowItems.Count -eq 0) { '' } else { ' hidden' }

    return @"
<div class="table-wrap">
<table data-enhanced-table="true">
<thead><tr>$headerHtml</tr></thead>
<tbody>
$rowsHtml
</tbody>
</table>
<div class="empty-state" data-empty-state$emptyStateHidden>$(ConvertTo-DanewReportHtmlText $EmptyMessage)</div>
</div>
"@
}

function New-DanewInteractiveReportHtml {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,
        [string]$Subtitle = '',
        [string]$Status = '',
        [string]$Eyebrow = 'Rapport HTML5 hors ligne',
        [string]$HeroMetricsHtml = '',
        [string]$MetaHtml = '',
        [Parameter(Mandatory = $true)]
        [string[]]$Sections,
        [string]$SearchPlaceholder = 'Rechercher dans ce rapport',
        [string]$FooterNote = 'Rapport hors ligne genere sans dependance externe.',
        [string]$AdditionalToolbarHtml = '',
        [string]$AdditionalContentHtml = '',
        [string]$AdditionalStyleHtml = '',
        [string]$AdditionalScriptHtml = ''
    )

    $safeTitle = ConvertTo-DanewReportHtmlText $Title
    $safeSubtitle = ConvertTo-DanewReportHtmlText $Subtitle
    $safeEyebrow = ConvertTo-DanewReportHtmlText $Eyebrow
    $safeSearchPlaceholder = ConvertTo-DanewReportHtmlText $SearchPlaceholder
    $safeFooterNote = ConvertTo-DanewReportHtmlText $FooterNote
    $statusHtml = ''
    if (-not [string]::IsNullOrWhiteSpace($Status)) {
        $statusHtml = New-DanewReportBadgeHtml -Text $Status -Tone $Status
    }

    $sectionHtml = $Sections -join "`n"

    return @"
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$safeTitle</title>
<style>
:root {
    --bg-top: #f7f3e8;
    --bg-bottom: #dce9ee;
    --panel: rgba(255,255,255,0.88);
    --panel-strong: #ffffff;
    --text: #172033;
    --muted: #596579;
    --line: rgba(23,32,51,0.12);
    --accent: #0f766e;
    --accent-strong: #115e59;
    --warn: #b45309;
    --danger: #b42318;
    --shadow: 0 18px 40px rgba(23,32,51,0.10);
}
* { box-sizing: border-box; }
html { scroll-behavior: smooth; }
body {
    margin: 0;
    font-family: Bahnschrift, "Segoe UI Variable Text", "Segoe UI", sans-serif;
    color: var(--text);
    background:
        radial-gradient(circle at top left, rgba(15,118,110,0.18), transparent 32%),
        radial-gradient(circle at top right, rgba(180,83,9,0.12), transparent 24%),
        linear-gradient(180deg, var(--bg-top), var(--bg-bottom));
}
.report-shell {
    width: min(1320px, calc(100% - 32px));
    margin: 24px auto 40px auto;
}
.hero {
    margin-bottom: 18px;
    padding: 22px;
    border: 1px solid var(--line);
    border-radius: 24px;
    background: rgba(255,255,255,0.82);
    backdrop-filter: blur(16px);
    box-shadow: var(--shadow);
}
.hero-top {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 16px;
}
.eyebrow {
    text-transform: uppercase;
    letter-spacing: 0.12em;
    font-size: 11px;
    color: var(--muted);
    margin-bottom: 10px;
}
h1 {
    margin: 0;
    font-size: clamp(28px, 5vw, 44px);
    line-height: 1.02;
}
.subtitle {
    margin: 10px 0 0 0;
    color: var(--muted);
    font-size: 15px;
    max-width: 780px;
}
.toolbar {
    margin-top: 18px;
    display: flex;
    flex-wrap: wrap;
    gap: 10px;
}
.toolbar input {
    flex: 1 1 320px;
    min-width: 220px;
    padding: 12px 14px;
    border-radius: 14px;
    border: 1px solid var(--line);
    background: var(--panel-strong);
    color: var(--text);
}
.toolbar button {
    padding: 12px 14px;
    border-radius: 14px;
    border: 1px solid var(--line);
    background: var(--panel-strong);
    cursor: pointer;
    color: var(--text);
}
.toolbar button.primary-button {
    background: var(--accent);
    border-color: var(--accent);
    color: #ffffff;
}
.hero-metrics {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(160px, 1fr));
    gap: 12px;
    margin-top: 18px;
}
.metric-card,
.report-card {
    border: 1px solid var(--line);
    border-radius: 20px;
    background: var(--panel);
    box-shadow: var(--shadow);
}
.metric-card {
    padding: 14px 16px;
}
.metric-card[data-tone="good"] { border-color: rgba(15,118,110,0.32); }
.metric-card[data-tone="warn"] { border-color: rgba(180,83,9,0.32); }
.metric-card[data-tone="danger"] { border-color: rgba(180,35,24,0.32); }
.metric-label {
    color: var(--muted);
    font-size: 12px;
    text-transform: uppercase;
    letter-spacing: 0.08em;
}
.metric-value {
    margin-top: 8px;
    font-size: 28px;
    font-weight: 700;
}
.meta-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
    gap: 10px;
    margin-top: 16px;
}
.meta-item {
    padding: 12px 14px;
    border-radius: 16px;
    border: 1px solid var(--line);
    background: rgba(255,255,255,0.55);
}
.meta-label {
    display: block;
    color: var(--muted);
    font-size: 12px;
    text-transform: uppercase;
    letter-spacing: 0.08em;
}
.meta-value {
    display: block;
    margin-top: 6px;
    font-weight: 600;
}
.report-content {
    display: grid;
    gap: 14px;
}
.report-card {
    padding: 18px 20px;
    min-width: 0;
}
.section-head {
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    gap: 12px;
}
.section-head h2 {
    margin: 0;
    font-size: 20px;
}
.section-caption {
    margin: 8px 0 0 0;
    color: var(--muted);
    font-size: 14px;
}
.ghost-button {
    white-space: nowrap;
    padding: 8px 12px;
    border-radius: 999px;
    border: 1px solid var(--line);
    background: rgba(255,255,255,0.75);
    cursor: pointer;
}
.section-body { margin-top: 16px; }
.section-body[hidden] { display: none; }
.report-badge {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 7px 12px;
    border-radius: 999px;
    font-size: 12px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.08em;
}
.report-badge-good { background: rgba(15,118,110,0.14); color: var(--accent-strong); }
.report-badge-warn { background: rgba(180,83,9,0.14); color: var(--warn); }
.report-badge-danger { background: rgba(180,35,24,0.14); color: var(--danger); }
.report-badge-neutral { background: rgba(89,101,121,0.12); color: var(--text); }
.table-wrap {
    overflow-x: auto;
    overflow-y: visible;
    border: 1px solid var(--line);
    border-radius: 16px;
    background: #ffffff;
}
.sort-header-button {
    width: 100%;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    border: 0;
    background: transparent;
    padding: 0;
    margin: 0;
    font: inherit;
    color: inherit;
    cursor: pointer;
}
.sort-indicator {
    font-size: 12px;
    opacity: 0.65;
}
th[data-sort-direction="asc"] .sort-indicator { opacity: 1; color: var(--accent-strong); }
th[data-sort-direction="asc"] .sort-indicator::before { content: '^'; }
th[data-sort-direction="asc"] .sort-indicator { font-size: 0; }
th[data-sort-direction="desc"] .sort-indicator { opacity: 1; color: var(--accent-strong); }
th[data-sort-direction="desc"] .sort-indicator::before { content: 'v'; }
th[data-sort-direction="desc"] .sort-indicator { font-size: 0; }
table {
    width: 100%;
    border-collapse: collapse;
    min-width: 0;
    table-layout: fixed;
}
th, td {
    padding: 10px 12px;
    border-bottom: 1px solid var(--line);
    text-align: left;
    vertical-align: top;
    font-size: 13px;
    overflow-wrap: anywhere;
    word-break: break-word;
    min-width: 0;
}
th {
    position: sticky;
    top: 0;
    background: #eef5f4;
    z-index: 1;
    user-select: none;
}
th[draggable="true"] { cursor: grab; }
th.column-dragging { opacity: 0.55; cursor: grabbing; }
th.column-drop-target { box-shadow: inset 3px 0 0 var(--accent); }
.column-resize-handle {
    position: absolute;
    top: 0;
    right: 0;
    width: 8px;
    height: 100%;
    cursor: col-resize;
    opacity: 0;
    border-right: 2px solid rgba(15,118,110,0.35);
}
th:hover .column-resize-handle,
.column-resize-handle:hover {
    opacity: 1;
}
body.column-resizing {
    cursor: col-resize;
    user-select: none;
}
tbody tr:nth-child(even) { background: rgba(15,118,110,0.03); }
tbody tr[hidden] { display: none; }
ul.report-list {
    margin: 0;
    padding-left: 20px;
    display: grid;
    gap: 8px;
}
.split-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
    gap: 14px;
}
.inline-code {
    font-family: Consolas, "Cascadia Mono", monospace;
    font-size: 12px;
}
.empty-state {
    padding: 14px;
    color: var(--muted);
}
.footer-note {
    margin-top: 14px;
    color: var(--muted);
    font-size: 12px;
}
noscript .noscript-card {
    display: block;
    margin-bottom: 14px;
    padding: 14px 16px;
    border-radius: 16px;
    border: 1px solid var(--line);
    background: rgba(255,255,255,0.95);
}
@media print {
    body { background: #ffffff; }
    .hero { position: static; backdrop-filter: none; box-shadow: none; }
    .toolbar, .ghost-button { display: none !important; }
    .report-shell { width: 100%; margin: 0; }
    .report-card, .metric-card, .hero { box-shadow: none; border-color: #d6d6d6; }
}
@media (max-width: 720px) {
    .report-shell { width: min(100% - 16px, 1320px); margin: 12px auto 24px auto; }
    .hero, .report-card { padding: 16px; border-radius: 18px; }
    .hero-top { flex-direction: column; }
    .toolbar { flex-direction: column; }
}
</style>
$AdditionalStyleHtml
</head>
<body>
<div class="report-shell" data-report-shell="danew">
<noscript>
<div class="noscript-card"><strong>Fonctions interactives desactivees.</strong> Ce rapport reste entierement lisible sans JavaScript.</div>
</noscript>
<header class="hero">
<div class="hero-top">
<div>
<div class="eyebrow">$safeEyebrow</div>
<h1>$safeTitle</h1>
<p class="subtitle">$safeSubtitle</p>
</div>
<div>$statusHtml</div>
</div>
<div class="toolbar report-toolbar">
<input type="search" placeholder="$safeSearchPlaceholder" data-report-search>
$AdditionalToolbarHtml
<button type="button" class="primary-button" data-action="expand-all">Developper tout</button>
<button type="button" data-action="collapse-all">Reduire tout</button>
<button type="button" data-action="print">Imprimer</button>
</div>
$HeroMetricsHtml
$MetaHtml
</header>
<main class="report-content">
$sectionHtml
</main>
$AdditionalContentHtml
<div class="footer-note">$safeFooterNote</div>
</div>
<script>
(function () {
    function normalize(value) {
        return (value || '').toString().toLowerCase();
    }

    function setExpanded(button, expanded) {
        var targetId = button.getAttribute('aria-controls');
        var target = document.getElementById(targetId);
        if (!target) {
            return;
        }

        button.setAttribute('aria-expanded', expanded ? 'true' : 'false');
        target.hidden = !expanded;
    }

    function parseSortableValue(value) {
        var text = (value || '').toString().trim();
        var numeric = text.replace(/\s+/g, '').replace(',', '.');
        if (/^-?\d+(\.\d+)?$/.test(numeric)) {
            return { type: 'number', value: parseFloat(numeric) };
        }
        return { type: 'text', value: text.toLowerCase() };
    }

    function compareRowsByColumn(rowA, rowB, columnIndex, direction) {
        var cellA = rowA.children[columnIndex];
        var cellB = rowB.children[columnIndex];
        var valueA = parseSortableValue(cellA ? cellA.textContent : '');
        var valueB = parseSortableValue(cellB ? cellB.textContent : '');
        var result = 0;

        if (valueA.type === 'number' && valueB.type === 'number') {
            result = valueA.value - valueB.value;
        } else {
            if (valueA.value < valueB.value) {
                result = -1;
            } else if (valueA.value > valueB.value) {
                result = 1;
            }
        }

        return direction === 'asc' ? result : (-1 * result);
    }

    function initSortableTables() {
        var tables = Array.prototype.slice.call(document.querySelectorAll('.table-wrap table'));
        tables.forEach(function (table) {
            var tbody = table.querySelector('tbody');
            if (!tbody) {
                return;
            }

            var headers = Array.prototype.slice.call(table.querySelectorAll('thead th[data-sortable="true"]'));
            headers.forEach(function (header) {
                var trigger = header.querySelector('[data-sort-trigger]');
                if (!trigger) {
                    return;
                }

                trigger.addEventListener('click', function () {
                    var colIndex = parseInt(header.getAttribute('data-sort-index') || '0', 10);
                    var current = header.getAttribute('data-sort-direction') || 'none';
                    var next = current === 'asc' ? 'desc' : 'asc';

                    headers.forEach(function (other) {
                        other.setAttribute('data-sort-direction', 'none');
                    });
                    header.setAttribute('data-sort-direction', next);

                    var rows = Array.prototype.slice.call(tbody.querySelectorAll('tr'));
                    rows.sort(function (a, b) {
                        return compareRowsByColumn(a, b, colIndex, next);
                    });

                    rows.forEach(function (row) {
                        tbody.appendChild(row);
                    });
                });
            });
        });
    }

    function setColumnWidth(table, columnIndex, width) {
        var safeWidth = Math.max(64, Math.round(width));
        var rows = Array.prototype.slice.call(table.querySelectorAll('tr'));
        rows.forEach(function (row) {
            var cell = row.children[columnIndex];
            if (cell) {
                cell.style.width = safeWidth + 'px';
                cell.style.minWidth = safeWidth + 'px';
            }
        });

        var totalWidth = 0;
        var headers = Array.prototype.slice.call(table.querySelectorAll('thead th'));
        headers.forEach(function (header) {
            var headerWidth = parseInt(header.style.width || header.offsetWidth || 0, 10);
            totalWidth += Math.max(64, headerWidth || 64);
        });
        if (totalWidth > 0) {
            // ne pas forcer la largeur globale : le tableau reste dans sa carte
        }
    }

    function moveColumn(table, fromIndex, toIndex) {
        if (fromIndex === toIndex || fromIndex < 0 || toIndex < 0) {
            return;
        }

        var rows = Array.prototype.slice.call(table.querySelectorAll('tr'));
        rows.forEach(function (row) {
            var cells = row.children;
            if (fromIndex >= cells.length || toIndex >= cells.length) {
                return;
            }

            var movingCell = cells[fromIndex];
            var targetCell = cells[toIndex];
            if (fromIndex < toIndex) {
                row.insertBefore(movingCell, targetCell.nextSibling);
            }
            else {
                row.insertBefore(movingCell, targetCell);
            }
        });

        var headers = Array.prototype.slice.call(table.querySelectorAll('thead th'));
        headers.forEach(function (header, index) {
            header.setAttribute('data-column-index', String(index));
            if (header.getAttribute('data-sortable') === 'true') {
                header.setAttribute('data-sort-index', String(index));
                var trigger = header.querySelector('[data-sort-trigger]');
                if (trigger) {
                    trigger.setAttribute('data-sort-trigger', String(index));
                }
            }
        });
    }

    function initInteractiveColumns() {
        var tables = Array.prototype.slice.call(document.querySelectorAll('.table-wrap table'));
        tables.forEach(function (table) {
            var headers = Array.prototype.slice.call(table.querySelectorAll('thead th'));
            if (headers.length === 0) {
                return;
            }

            headers.forEach(function (header, index) {
                header.setAttribute('draggable', 'true');
                header.setAttribute('data-column-index', String(index));

                var handle = header.querySelector('[data-column-resize]');
                if (!handle) {
                    handle = document.createElement('span');
                    handle.className = 'column-resize-handle';
                    handle.setAttribute('data-column-resize', 'true');
                    handle.setAttribute('title', 'Redimensionner la colonne');
                    header.appendChild(handle);
                }
                if (handle) {
                    handle.addEventListener('mousedown', function (event) {
                        event.preventDefault();
                        event.stopPropagation();
                        var startX = event.clientX;
                        var startWidth = header.offsetWidth;
                        var columnIndex = Array.prototype.indexOf.call(header.parentNode.children, header);
                        document.body.classList.add('column-resizing');

                        function onMove(moveEvent) {
                            setColumnWidth(table, columnIndex, startWidth + (moveEvent.clientX - startX));
                        }

                        function onUp() {
                            document.removeEventListener('mousemove', onMove);
                            document.removeEventListener('mouseup', onUp);
                            document.body.classList.remove('column-resizing');
                        }

                        document.addEventListener('mousemove', onMove);
                        document.addEventListener('mouseup', onUp);
                    });
                }

                header.addEventListener('dragstart', function (event) {
                    if (event.target && event.target.getAttribute && event.target.getAttribute('data-column-resize') !== null) {
                        event.preventDefault();
                        return;
                    }
                    var columnIndex = Array.prototype.indexOf.call(header.parentNode.children, header);
                    header.classList.add('column-dragging');
                    event.dataTransfer.effectAllowed = 'move';
                    event.dataTransfer.setData('text/plain', String(columnIndex));
                });

                header.addEventListener('dragend', function () {
                    header.classList.remove('column-dragging');
                    headers.forEach(function (item) {
                        item.classList.remove('column-drop-target');
                    });
                });

                header.addEventListener('dragover', function (event) {
                    event.preventDefault();
                    header.classList.add('column-drop-target');
                    event.dataTransfer.dropEffect = 'move';
                });

                header.addEventListener('dragleave', function () {
                    header.classList.remove('column-drop-target');
                });

                header.addEventListener('drop', function (event) {
                    event.preventDefault();
                    header.classList.remove('column-drop-target');
                    var fromIndex = parseInt(event.dataTransfer.getData('text/plain') || '-1', 10);
                    var toIndex = Array.prototype.indexOf.call(header.parentNode.children, header);
                    moveColumn(table, fromIndex, toIndex);
                });
            });
        });
    }

    var search = document.querySelector('[data-report-search]');
    var sections = Array.prototype.slice.call(document.querySelectorAll('[data-section-card]'));

    sections.forEach(function (section) {
        var button = section.querySelector('[data-section-toggle]');
        if (button) {
            button.addEventListener('click', function () {
                setExpanded(button, button.getAttribute('aria-expanded') !== 'true');
            });
        }
    });

    var expandAll = document.querySelector('[data-action="expand-all"]');
    if (expandAll) {
        expandAll.addEventListener('click', function () {
            sections.forEach(function (section) {
                var button = section.querySelector('[data-section-toggle]');
                if (button) {
                    setExpanded(button, true);
                }
            });
        });
    }

    var collapseAll = document.querySelector('[data-action="collapse-all"]');
    if (collapseAll) {
        collapseAll.addEventListener('click', function () {
            sections.forEach(function (section) {
                var button = section.querySelector('[data-section-toggle]');
                if (button) {
                    setExpanded(button, false);
                }
            });
        });
    }

    var printButton = document.querySelector('[data-action="print"]');
    if (printButton) {
        printButton.addEventListener('click', function () {
            window.print();
        });
    }

    function applySearch() {
        var term = search ? normalize(search.value) : '';
        sections.forEach(function (section) {
            var baseMatch = term === '' || normalize(section.getAttribute('data-search')).indexOf(term) !== -1;
            var rows = Array.prototype.slice.call(section.querySelectorAll('[data-search-row]'));
            var visibleRows = 0;
            rows.forEach(function (row) {
                var match = term === '' || normalize(row.getAttribute('data-search-row')).indexOf(term) !== -1;
                row.hidden = !match;
                if (match) {
                    visibleRows += 1;
                }
            });

            var emptyState = section.querySelector('[data-empty-state]');
            if (emptyState) {
                emptyState.hidden = term === '' || visibleRows > 0;
            }

            section.hidden = !(baseMatch || visibleRows > 0);
        });
    }

    if (search) {
        search.addEventListener('input', applySearch);
        applySearch();
    }

    initSortableTables();
    initInteractiveColumns();
}());
</script>
$AdditionalScriptHtml
</body>
</html>
"@
}

function Get-DanewInteractiveReportCatalog {
    return @{
        'sav-diagnostic-report.html' = [pscustomobject]@{ title = 'Diagnostic SAV / crash'; subtitle = 'Synthese des causes racines, chronologie et prochaines actions en lecture seule.'; rank = 10 }
        'one-click-diagnostic-report.html' = [pscustomobject]@{ title = 'Diagnostic en un clic'; subtitle = 'Resume d execution des controles lances depuis le launcher et de leurs resultats.'; rank = 20 }
        'timeline-raw.html' = [pscustomobject]@{ title = 'Chronologie hors ligne'; subtitle = 'Chronologie brute des evenements avec recherche par fournisseur, niveau et message.'; rank = 30 }
    }
}

function Update-DanewInteractiveReportsIndex {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ReportsPath
    )

    if (-not (Test-Path -Path $ReportsPath)) {
        return $null
    }

    $catalog = Get-DanewInteractiveReportCatalog
    $htmlFiles = @(Get-ChildItem -Path $ReportsPath -Filter '*.html' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin @('REPORTS_INDEX.html', 'reports-index.html') })
    $items = @()
    foreach ($file in $htmlFiles) {
        $entry = $catalog[$file.Name]
        $title = if ($null -ne $entry) { [string]$entry.title } else { [System.IO.Path]::GetFileNameWithoutExtension($file.Name) }
        $subtitle = if ($null -ne $entry) { [string]$entry.subtitle } else { 'Artefact HTML genere.' }
        $rank = if ($null -ne $entry) { [int]$entry.rank } else { 1000 }
        $jsonCandidate = Join-Path $ReportsPath ($file.BaseName + '.json')

        $items += [pscustomobject]@{
            name = $file.Name
            title = $title
            subtitle = $subtitle
            rank = $rank
            modified = $file.LastWriteTime.ToString('s')
            html_name = $file.Name
            json_name = if (Test-Path -Path $jsonCandidate) { [System.IO.Path]::GetFileName($jsonCandidate) } else { '' }
        }
    }

    $items = @($items | Sort-Object rank, name)

    $metrics = @(
        (New-DanewMetricCardHtml -Label 'Rapports detectes' -Value @($items).Count -Tone 'info')
        (New-DanewMetricCardHtml -Label 'Interface interactive' -Value 'prete hors ligne' -Tone 'good')
        (New-DanewMetricCardHtml -Label 'Mise a jour' -Value (Get-Date).ToString('s') -Tone 'neutral')
    ) -join ''

    $rows = @()
    foreach ($item in $items) {
        $searchText = ConvertTo-DanewReportHtmlText ($item.title + ' ' + $item.subtitle + ' ' + $item.name + ' ' + $item.json_name)
        $jsonLink = if ([string]::IsNullOrWhiteSpace($item.json_name)) { '<span class="inline-code">n/d</span>' } else { '<a href="' + (ConvertTo-DanewReportHtmlText $item.json_name) + '">' + (ConvertTo-DanewReportHtmlText $item.json_name) + '</a>' }
        $rows += @"
<tr data-search-row="$searchText">
<td><strong><a href="$(ConvertTo-DanewReportHtmlText $item.html_name)">$(ConvertTo-DanewReportHtmlText $item.title)</a></strong><div class="section-caption">$(ConvertTo-DanewReportHtmlText $item.subtitle)</div></td>
<td><span class="inline-code">$(ConvertTo-DanewReportHtmlText $item.html_name)</span></td>
<td>$jsonLink</td>
<td>$(ConvertTo-DanewReportHtmlText $item.modified)</td>
</tr>
"@
    }

    if (@($rows).Count -eq 0) {
        $rows += '<tr data-search-row="no reports"><td colspan="4">Aucun rapport HTML n a encore ete genere.</td></tr>'
    }

    $meta = New-DanewReportMetaListHtml -Items @(
        [pscustomobject]@{ label = 'Dossier des rapports'; value = $ReportsPath }
        [pscustomobject]@{ label = 'Index principal'; value = 'REPORTS_INDEX.html' }
        [pscustomobject]@{ label = 'Copie de raccourci'; value = 'reports-index.html' }
    )

    $sections = @(
        (New-DanewReportSectionHtml -Title 'Rapports disponibles' -Caption 'Ouvrir directement le rapport HTML ou consulter l artefact JSON associe lorsqu il est disponible.' -SearchText 'reports index html json available reports' -BodyHtml (New-DanewReportTableHtml -Headers @('Rapport', 'HTML', 'JSON', 'Derniere mise a jour') -Rows $rows -EmptyMessage 'Aucun rapport ne correspond au filtre courant.'))
    )

    $html = New-DanewInteractiveReportHtml -Title 'Index des rapports Danew' -Subtitle 'Point d entree hors ligne pour les artefacts diagnostiques HTML et JSON generes.' -Status 'READY' -Eyebrow 'Centre de rapports' -HeroMetricsHtml ('<div class="hero-metrics">' + $metrics + '</div>') -MetaHtml $meta -Sections $sections -SearchPlaceholder 'Filtrer les rapports par titre, nom de fichier ou artefact JSON associe'

    $primaryPath = Join-Path $ReportsPath 'REPORTS_INDEX.html'
    $aliasPath = Join-Path $ReportsPath 'reports-index.html'
    $html | Set-Content -Path $primaryPath -Encoding UTF8
    $html | Set-Content -Path $aliasPath -Encoding UTF8

    return [pscustomobject]@{
        primary = $primaryPath
        alias = $aliasPath
        count = @($items).Count
    }
}
