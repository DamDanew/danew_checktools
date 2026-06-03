$reportsDir = 'H:\Danew_CheckTool\WinPe_local\reports'

# CSS + JS patch: chips → anchor links with smooth scroll
$patch = @'
<style id="ui-patch-4-chips">
/* Chips → liens cliquables */
.chip {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 6px 14px;
    border-radius: 999px;
    background: rgba(15,118,110,0.10);
    color: var(--accent, #0f766e);
    border: 1px solid rgba(15,118,110,0.30);
    font-size: 13px;
    font-weight: 500;
    cursor: pointer;
    text-decoration: none;
    transition: background 120ms ease, border-color 120ms ease, transform 80ms ease;
}
.chip:hover {
    background: rgba(15,118,110,0.20);
    border-color: rgba(15,118,110,0.55);
    transform: translateY(-1px);
}
.chip:active { transform: translateY(0); }
.chips { display: flex; flex-wrap: wrap; gap: 8px; margin: 10px 0; }

/* Section anchor highlight on scroll */
.section-anchor-target { scroll-margin-top: 60px; }
.section-heading-link {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    text-decoration: none;
    color: inherit;
}
.section-heading-link:hover .anchor-icon { opacity: 1; }
.anchor-icon {
    font-size: 14px;
    opacity: 0;
    color: var(--accent, #0f766e);
    transition: opacity 150ms ease;
}

/* Dark mode */
body.theme-dark .chip {
    background: rgba(20,184,166,0.10);
    color: #14b8a6;
    border-color: rgba(20,184,166,0.30);
}
body.theme-dark .chip:hover {
    background: rgba(20,184,166,0.20);
    border-color: rgba(20,184,166,0.55);
}
</style>
<script id="ui-patch-4-chips-js">
(function(){
    // Mapping chip label → heading text to find
    var chipMap = {
        'Top causes':                  'Top causes',
        'Top evenements':              'Top evenements',
        'Volume par fichier':          'Volume de logs par fichier EVTX',
        'Sections pliables par famille': 'Lecture par fichier et par famille'
    };

    // Add IDs to headings
    document.querySelectorAll('h2, h3').forEach(function(h) {
        var txt = h.textContent.trim();
        Object.keys(chipMap).forEach(function(chip) {
            if (chipMap[chip] === txt && !h.id) {
                var id = 'section-' + chip.toLowerCase()
                    .replace(/[^a-z0-9]+/g, '-')
                    .replace(/(^-|-$)/g, '');
                h.id = id;
                h.classList.add('section-anchor-target');
                // Add anchor icon
                h.innerHTML = '<a class="section-heading-link" href="#' + id + '">' +
                    h.innerHTML +
                    '<span class="anchor-icon">#</span></a>';
            }
        });
    });

    // Convert chip spans to anchor links
    document.querySelectorAll('.chips .chip, .chip').forEach(function(chip) {
        if (chip.tagName === 'A') return; // already a link
        var label = chip.textContent.trim();
        var targetText = chipMap[label];
        if (!targetText) return;

        // Find heading with this text
        var targetId = 'section-' + label.toLowerCase()
            .replace(/[^a-z0-9]+/g, '-')
            .replace(/(^-|-$)/g, '');

        var heading = document.getElementById(targetId);
        if (heading) {
            // Replace span with anchor
            var a = document.createElement('a');
            a.className = chip.className;
            a.href = '#' + targetId;
            a.textContent = label;
            a.title = 'Aller à : ' + targetText;
            // Smooth scroll
            a.addEventListener('click', function(e) {
                e.preventDefault();
                heading.scrollIntoView({ behavior: 'smooth', block: 'start' });
            });
            chip.parentNode.replaceChild(a, chip);
        } else {
            // No heading found — still style as button
            chip.style.cursor = 'pointer';
        }
    });
})();
</script>
'@

$files = @('evtx-by-file.html', 'evtx-events.html', 'sav-diagnostic-report.html', 'timeline-raw.html')
$patched = 0

foreach ($f in $files) {
    $path = Join-Path $reportsDir $f
    if (-not (Test-Path $path)) { Write-Host "SKIP (missing): $f"; continue }
    $html = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    if ($html -match 'ui-patch-4-chips') { Write-Host "SKIP (done): $f"; continue }
    if ($html -match '</body>') {
        $html = $html -replace '</body>', ($patch + "`n</body>")
        [System.IO.File]::WriteAllText($path, $html, [System.Text.Encoding]::UTF8)
        $patched++
        Write-Host "PATCHED: $f"
    }
}
Write-Host "Total: $patched patched"
