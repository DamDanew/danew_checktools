# ============================================================
# UX PATCH GLOBAL — 8 améliorations UI/UX
# ============================================================

$reportsDir = 'H:\Danew_CheckTool\WinPe_local\reports'
$patched = @()

# ── CSS + JS patch universel ──────────────────────────────────
$universalPatch = @'
<style id="ui-patch-2">
/* === FIX 3: Compteur séparé visuellement === */
.toolbar-count {
    background: rgba(15,118,110,0.08) !important;
    border: 1px dashed rgba(15,118,110,0.35) !important;
    color: var(--accent) !important;
    font-weight: 600;
    font-size: 12px;
    border-radius: 20px !important;
    padding: 4px 12px !important;
    cursor: default !important;
    pointer-events: none;
}

/* === FIX 4: Toolbar wrap avec groupes === */
.toolbar { gap: 6px 8px !important; }
.toolbar-group-sep {
    width: 1px;
    height: 28px;
    background: var(--line);
    display: inline-block;
    vertical-align: middle;
    margin: 0 4px;
    flex-shrink: 0;
}

/* === FIX 1: Labels filtres === */
.filter-wrap {
    display: inline-flex;
    flex-direction: column;
    gap: 1px;
}
.filter-label {
    font-size: 9px;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--muted);
    padding-left: 4px;
    font-weight: 600;
}
.filter-wrap select {
    font-size: 12px !important;
    padding: 6px 10px !important;
}

/* === FIX 7: Sections colorées par type === */
.section-sav     { border-left: 4px solid #b42318 !important; }
.section-warn    { border-left: 4px solid #b45309 !important; }
.section-table   { border-left: 4px solid #1d4ed8 !important; }
.section-loop    { border-left: 4px solid #7c3aed !important; }
.section-head h2 { display: flex; align-items: center; gap: 8px; }
.section-icon { font-size: 16px; }

/* === FIX 7: Badges de sévérité section === */
.section-badge {
    display: inline-flex;
    align-items: center;
    padding: 2px 8px;
    border-radius: 999px;
    font-size: 10px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    vertical-align: middle;
}
.section-badge-danger { background: rgba(180,35,24,0.12); color: #b42318; }
.section-badge-warn   { background: rgba(180,83,9,0.12);  color: #b45309; }
.section-badge-info   { background: rgba(29,78,216,0.1);  color: #1d4ed8; }
.section-badge-loop   { background: rgba(124,58,237,0.1); color: #7c3aed; }

/* === FIX 5: Boutons Vue Technicien / Client === */
.view-mode-label {
    font-size: 9px;
    display: block;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--muted);
    margin-bottom: 2px;
}

/* === FIX 6: Badge statut === */
.report-badge-ok-enriched {
    font-size: 11px !important;
    padding: 5px 12px !important;
}

/* === FIX 8: REPORTS_INDEX ordre === */
.report-seq-badge {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 22px;
    height: 22px;
    border-radius: 50%;
    background: var(--accent);
    color: #fff;
    font-size: 11px;
    font-weight: 700;
    flex-shrink: 0;
    margin-right: 6px;
}
.report-start-hint {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 10px 14px;
    background: rgba(15,118,110,0.08);
    border: 1px solid rgba(15,118,110,0.25);
    border-radius: 12px;
    font-size: 13px;
    color: var(--accent-strong);
    margin-bottom: 14px;
    font-weight: 500;
}

/* DARK mode overrides */
body.theme-dark .filter-label { color: #64748b; }
body.theme-dark .section-badge-danger { background: rgba(180,35,24,0.2); }
body.theme-dark .section-badge-warn   { background: rgba(180,83,9,0.2); }
body.theme-dark .section-badge-info   { background: rgba(29,78,216,0.18); }
body.theme-dark .section-badge-loop   { background: rgba(124,58,237,0.18); }
body.theme-dark .toolbar-count { color: #14b8a6 !important; background: rgba(20,184,166,0.08) !important; border-color: rgba(20,184,166,0.3) !important; }
body.theme-dark .report-start-hint { background: rgba(20,184,166,0.08); border-color: rgba(20,184,166,0.25); color: #14b8a6; }
</style>
<script id="ui-patch-2-js">
(function(){
  // FIX 1: Labels filtres selects
  var filterDefs = [
    { sel: '[data-filter-level]',    label: 'Niveau' },
    { sel: '[data-filter-family]',   label: 'Famille' },
    { sel: '[data-filter-provider]', label: 'Fournisseur' },
    { sel: '[data-filter-event-id]', label: 'ID evt' }
  ];
  filterDefs.forEach(function(fd) {
    var el = document.querySelector(fd.sel);
    if (!el || el.closest('.filter-wrap')) return;
    var wrap = document.createElement('div');
    wrap.className = 'filter-wrap';
    var lbl = document.createElement('span');
    lbl.className = 'filter-label';
    lbl.textContent = fd.label;
    el.parentNode.insertBefore(wrap, el);
    wrap.appendChild(lbl);
    wrap.appendChild(el);
  });

  // FIX 2: Ouvrir Resume SAV par defaut
  var toggleBtns = Array.from(document.querySelectorAll('[data-section-toggle]'));
  toggleBtns.forEach(function(btn) {
    var heading = btn.closest('[data-section-card]');
    if (!heading) return;
    var h2 = heading.querySelector('h2');
    if (h2 && h2.textContent.match(/Resume SAV/i)) {
      if (btn.getAttribute('aria-expanded') !== 'true') {
        btn.click();
      }
    }
  });

  // FIX 3: Compteur — retirer cursor pointer si present
  var counts = document.querySelectorAll('.toolbar-count');
  counts.forEach(function(c) { c.style.cursor = 'default'; });

  // FIX 5: Boutons Technicien / Client — ajouter hint
  var allBtns = Array.from(document.querySelectorAll('button'));
  allBtns.forEach(function(btn) {
    var txt = btn.textContent.trim();
    if (txt === 'Technicien' && !btn.querySelector('.view-mode-label')) {
      btn.innerHTML = '<span class="view-mode-label">Vue</span>Technicien';
      btn.title = 'Affiche les colonnes pertinentes pour le diagnostic SAV';
    }
    if (txt === 'Client' && !btn.querySelector('.view-mode-label')) {
      btn.innerHTML = '<span class="view-mode-label">Vue</span>Client';
      btn.title = 'Affiche un resume simplifie pour le client';
    }
  });

  // FIX 6: Badge "OK" → descriptif
  var badges = document.querySelectorAll('.report-badge');
  badges.forEach(function(b) {
    if (b.textContent.trim() === 'OK') {
      b.textContent = 'Analyse complete';
      b.classList.add('report-badge-ok-enriched');
    }
    if (b.textContent.trim() === 'EN ATTENTE') {
      b.textContent = 'En attente d\'analyse';
    }
    if (b.textContent.trim() === 'CRITIQUE') {
      b.textContent = 'Critique — action requise';
    }
  });

  // FIX 7: Couleurs sections par type
  var sectionMap = [
    { pattern: /Resume SAV/i,       cls: 'section-sav',   badge: 'PRIORITAIRE', badgeCls: 'section-badge-danger', icon: '🔴' },
    { pattern: /importants/i,        cls: 'section-warn',  badge: 'IMPORTANT',   badgeCls: 'section-badge-warn',   icon: '🟡' },
    { pattern: /Tableau interactif/i,cls: 'section-table', badge: 'DONNÉES',     badgeCls: 'section-badge-info',   icon: '📊' },
    { pattern: /Boucles/i,           cls: 'section-loop',  badge: 'BOUCLES',     badgeCls: 'section-badge-loop',   icon: '🔁' }
  ];
  document.querySelectorAll('[data-section-card]').forEach(function(card) {
    var h2 = card.querySelector('h2');
    if (!h2) return;
    sectionMap.forEach(function(sm) {
      if (sm.pattern.test(h2.textContent)) {
        card.classList.add(sm.cls);
        if (!card.querySelector('.section-badge')) {
          var badge = document.createElement('span');
          badge.className = 'section-badge ' + sm.badgeCls;
          badge.textContent = sm.badge;
          h2.appendChild(badge);
        }
      }
    });
  });

  // FIX 8: REPORTS_INDEX — ordre recommande
  var tbody = document.querySelector('[data-enhanced-table="true"] tbody');
  if (tbody) {
    // Add "Par ou commencer" hint before table
    var tableWrap = tbody.closest('.table-wrap');
    if (tableWrap && !document.querySelector('.report-start-hint')) {
      var hint = document.createElement('div');
      hint.className = 'report-start-hint';
      hint.innerHTML = '<span>▶</span> <strong>Par ou commencer ?</strong> Lisez les rapports dans l\'ordre : 1 → Diagnostic SAV &nbsp;·&nbsp; 2 → Chronologie &nbsp;·&nbsp; 3 → Evenements EVTX &nbsp;·&nbsp; 4 → EVTX par fichier';
      tableWrap.parentNode.insertBefore(hint, tableWrap);
    }
    // Add sequence numbers to rows
    var rows = Array.from(tbody.querySelectorAll('tr'));
    rows.forEach(function(row, i) {
      var firstCell = row.querySelector('td strong');
      if (firstCell && !row.querySelector('.report-seq-badge')) {
        var badge = document.createElement('span');
        badge.className = 'report-seq-badge';
        badge.textContent = (i + 1).toString();
        firstCell.insertBefore(badge, firstCell.firstChild);
      }
    });
  }

})();
</script>
'@

# ── Fichiers à patcher ────────────────────────────────────────
$filesToPatch = @(
    'timeline-raw.html',
    'sav-diagnostic-report.html',
    'evtx-events.html',
    'evtx-by-file.html',
    'REPORTS_INDEX.html',
    'reports-index.html'
)

foreach ($fname in $filesToPatch) {
    $path = Join-Path $reportsDir $fname
    if (-not (Test-Path $path)) { Write-Host "SKIP (missing): $fname"; continue }

    $html = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)

    # Skip if already patched with ui-patch-2
    if ($html -match 'ui-patch-2') { Write-Host "SKIP (already patched): $fname"; continue }

    # Inject before </body>
    if ($html -match '</body>') {
        $html = $html -replace '</body>', ($universalPatch + "`n</body>")
        [System.IO.File]::WriteAllText($path, $html, [System.Text.Encoding]::UTF8)
        $patched += $fname
        Write-Host "PATCHED: $fname"
    } else {
        Write-Host "SKIP (no </body>): $fname"
    }
}

Write-Host ""
Write-Host "Total patched: $($patched.Count) files"
Write-Host "Files: $($patched -join ', ')"
