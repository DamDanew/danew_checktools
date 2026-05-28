Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

    $safeText = ConvertTo-DanewReportHtmlText $Text
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
<button type="button" class="ghost-button" data-section-toggle aria-expanded="$expanded" aria-controls="$sectionId">Toggle</button>
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
        [Parameter(Mandatory = $true)]
        [string[]]$Rows,
        [int[]]$SortableColumns = @(),
        [string]$EmptyMessage = 'No rows to display.'
    )

    $headerCells = @()
    for ($i = 0; $i -lt @($Headers).Count; $i++) {
        $label = ConvertTo-DanewReportHtmlText $Headers[$i]
        $isSortable = (@($SortableColumns).Count -eq 0) -or ($i -in $SortableColumns)
        if ($isSortable) {
            $headerCells += '<th data-sortable="true" data-sort-index="' + [string]$i + '" data-sort-direction="none"><button type="button" class="sort-header-button" data-sort-trigger="' + [string]$i + '"><span>' + $label + '</span><span class="sort-indicator" aria-hidden="true">+/-</span></button></th>'
        }
        else {
            $headerCells += '<th>' + $label + '</th>'
        }
    }
    $headerHtml = $headerCells -join ''
    $rowsHtml = $Rows -join "`n"

    return @"
<div class="table-wrap">
<table>
<thead><tr>$headerHtml</tr></thead>
<tbody>
$rowsHtml
</tbody>
</table>
<div class="empty-state" data-empty-state hidden>$(ConvertTo-DanewReportHtmlText $EmptyMessage)</div>
</div>
"@
}

function New-DanewInteractiveReportHtml {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,
        [string]$Subtitle = '',
        [string]$Status = '',
        [string]$Eyebrow = 'Offline HTML5 report',
        [string]$HeroMetricsHtml = '',
        [string]$MetaHtml = '',
        [Parameter(Mandatory = $true)]
        [string[]]$Sections,
        [string]$SearchPlaceholder = 'Search in this report',
        [string]$FooterNote = 'Offline report generated without external dependencies.'
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
<html lang="en">
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
    position: sticky;
    top: 12px;
    z-index: 20;
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
    overflow: auto;
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
    min-width: 720px;
}
th, td {
    padding: 10px 12px;
    border-bottom: 1px solid var(--line);
    text-align: left;
    vertical-align: top;
    font-size: 13px;
}
th {
    position: sticky;
    top: 0;
    background: #eef5f4;
    z-index: 1;
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
</head>
<body>
<div class="report-shell" data-report-shell="danew">
<noscript>
<div class="noscript-card"><strong>Interactive features disabled.</strong> This report remains fully readable without JavaScript.</div>
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
<button type="button" class="primary-button" data-action="expand-all">Expand all</button>
<button type="button" data-action="collapse-all">Collapse all</button>
<button type="button" data-action="print">Print</button>
</div>
$HeroMetricsHtml
$MetaHtml
</header>
<main class="report-content">
$sectionHtml
</main>
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
}());
</script>
</body>
</html>
"@
}

function Get-DanewInteractiveReportCatalog {
    return @{
        'sav-diagnostic-report.html' = [pscustomobject]@{ title = 'SAV / Crash Diagnostic'; subtitle = 'Root cause synthesis, timeline intelligence, and recommended read-only next steps.'; rank = 10 }
        'one-click-diagnostic-report.html' = [pscustomobject]@{ title = 'One-Click Diagnostic'; subtitle = 'Execution summary of launcher-driven checks and their outcomes.'; rank = 20 }
        'timeline-raw.html' = [pscustomobject]@{ title = 'Offline Timeline'; subtitle = 'Raw event timeline with searchable provider, level, and message details.'; rank = 30 }
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
        $subtitle = if ($null -ne $entry) { [string]$entry.subtitle } else { 'Generated HTML artifact.' }
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
        (New-DanewMetricCardHtml -Label 'Reports detected' -Value @($items).Count -Tone 'info')
        (New-DanewMetricCardHtml -Label 'Interactive shell' -Value 'offline ready' -Tone 'good')
        (New-DanewMetricCardHtml -Label 'Updated' -Value (Get-Date).ToString('s') -Tone 'neutral')
    ) -join ''

    $rows = @()
    foreach ($item in $items) {
        $searchText = ConvertTo-DanewReportHtmlText ($item.title + ' ' + $item.subtitle + ' ' + $item.name + ' ' + $item.json_name)
        $jsonLink = if ([string]::IsNullOrWhiteSpace($item.json_name)) { '<span class="inline-code">n/a</span>' } else { '<a href="' + (ConvertTo-DanewReportHtmlText $item.json_name) + '">' + (ConvertTo-DanewReportHtmlText $item.json_name) + '</a>' }
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
        $rows += '<tr data-search-row="no reports"><td colspan="4">No HTML reports have been generated yet.</td></tr>'
    }

    $meta = New-DanewReportMetaListHtml -Items @(
        [pscustomobject]@{ label = 'Reports directory'; value = $ReportsPath }
        [pscustomobject]@{ label = 'Primary index'; value = 'REPORTS_INDEX.html' }
        [pscustomobject]@{ label = 'Shortcut copy'; value = 'reports-index.html' }
    )

    $sections = @(
        (New-DanewReportSectionHtml -Title 'Available Reports' -Caption 'Open the HTML report directly or inspect the matching JSON artifact when available.' -SearchText 'reports index html json available reports' -BodyHtml (New-DanewReportTableHtml -Headers @('Report', 'HTML', 'JSON', 'Last Updated') -Rows $rows -EmptyMessage 'No matching reports for the current filter.'))
    )

    $html = New-DanewInteractiveReportHtml -Title 'Danew Reports Index' -Subtitle 'Offline launch point for generated HTML and JSON diagnostic artifacts.' -Status 'READY' -Eyebrow 'Report hub' -HeroMetricsHtml ('<div class="hero-metrics">' + $metrics + '</div>') -MetaHtml $meta -Sections $sections -SearchPlaceholder 'Filter reports by title, file name, or companion JSON artifact'

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