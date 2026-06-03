$reportsDir = 'H:\Danew_CheckTool\WinPe_local\reports'

$patch = @'
<style id="ui-patch-3-severity">
/* === SEVERITY ROW COLORS === */
tr.sev-critique td:first-child { border-left: 3px solid #b42318; }
tr.sev-erreur   td:first-child { border-left: 3px solid #dc2626; }
tr.sev-avert    td:first-child { border-left: 3px solid #b45309; }
tr.sev-critique { background: rgba(180,35,24,0.07) !important; }
tr.sev-erreur   { background: rgba(220,38,38,0.05) !important; }
tr.sev-avert    { background: rgba(180,83,9,0.06)  !important; }
tr.sev-critique:hover { background: rgba(180,35,24,0.13) !important; }
tr.sev-erreur:hover   { background: rgba(220,38,38,0.10) !important; }
tr.sev-avert:hover    { background: rgba(180,83,9,0.11)  !important; }
tr.sev-info:hover     { background: rgba(15,118,110,0.05) !important; }
.sev-badge { display:inline-flex; align-items:center; gap:4px; font-size:11px; font-weight:600; white-space:nowrap; padding:2px 7px; border-radius:6px; }
.sev-badge-critique { background:rgba(180,35,24,0.15); color:#b42318; }
.sev-badge-erreur   { background:rgba(220,38,38,0.12); color:#dc2626; }
.sev-badge-avert    { background:rgba(180,83,9,0.12);  color:#b45309; }
.sev-badge-info     { background:rgba(71,85,105,0.08); color:#475569; }
.sev-icon { font-size:12px; line-height:1; }
body.theme-dark tr.sev-critique { background:rgba(180,35,24,0.14) !important; }
body.theme-dark tr.sev-erreur   { background:rgba(220,38,38,0.10) !important; }
body.theme-dark tr.sev-avert    { background:rgba(180,83,9,0.12)  !important; }
body.theme-dark tr.sev-critique:hover { background:rgba(180,35,24,0.22) !important; }
body.theme-dark tr.sev-erreur:hover   { background:rgba(220,38,38,0.18) !important; }
body.theme-dark tr.sev-avert:hover    { background:rgba(180,83,9,0.19)  !important; }
body.theme-dark .sev-badge-critique { background:rgba(180,35,24,0.28); color:#f87171; }
body.theme-dark .sev-badge-erreur   { background:rgba(220,38,38,0.22); color:#fca5a5; }
body.theme-dark .sev-badge-avert    { background:rgba(180,83,9,0.22);  color:#fbbf24; }
body.theme-dark .sev-badge-info     { background:rgba(148,163,184,0.1); color:#94a3b8; }
.grav-haute  { color:#b42318; font-weight:700; }
.grav-moyenne { color:#b45309; font-weight:600; }
.grav-faible  { color:#15803d; }
</style>
<script id="ui-patch-3-severity-js">
(function(){
    var SEV = {
        'Critique':      { cls:'sev-critique', badge:'sev-badge-critique', icon:'&#x26D4;', label:'Critique' },
        'Erreur':        { cls:'sev-erreur',   badge:'sev-badge-erreur',   icon:'&#x274C;', label:'Erreur'   },
        'Avertissement': { cls:'sev-avert',    badge:'sev-badge-avert',    icon:'&#x26A0;', label:'Avert.'   },
        'Information':   { cls:'sev-info',     badge:'sev-badge-info',     icon:'&#x2139;', label:'Info'     }
    };
    document.querySelectorAll('table').forEach(function(table){
        var headers = Array.from(table.querySelectorAll('th'));
        var levelCol = -1;
        headers.forEach(function(th,i){ if(th.textContent.trim()==='Niveau') levelCol=i; });
        if(levelCol<0) return;
        table.querySelectorAll('tbody tr').forEach(function(row){
            var cells = row.querySelectorAll('td');
            if(cells.length<=levelCol) return;
            var cell = cells[levelCol];
            var raw = cell.textContent.trim();
            var def = SEV[raw];
            if(!def) return;
            row.classList.add(def.cls);
            if(!cell.querySelector('.sev-badge')){
                cell.innerHTML = '<span class="sev-badge '+def.badge+'"><span class="sev-icon">'+def.icon+'</span>'+def.label+'</span>';
            }
        });
    });
    document.querySelectorAll('table tbody tr').forEach(function(row){
        var cells = row.querySelectorAll('td');
        cells.forEach(function(td){
            var txt = td.textContent.trim().toLowerCase();
            if(txt==='haute'||txt==='elevee')   td.classList.add('grav-haute');
            else if(txt==='moyenne')             td.classList.add('grav-moyenne');
            else if(txt==='faible'||txt==='bas') td.classList.add('grav-faible');
        });
    });
})();
</script>
'@

$files = @('timeline-raw.html','sav-diagnostic-report.html','evtx-events.html','evtx-by-file.html')
$patched = 0

foreach ($f in $files) {
    $path = Join-Path $reportsDir $f
    if (-not (Test-Path $path)) { Write-Host "SKIP (missing): $f"; continue }
    $html = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    if ($html -match 'ui-patch-3-severity') { Write-Host "SKIP (done): $f"; continue }
    if ($html -match '</body>') {
        $html = $html -replace '</body>', ($patch + "`n</body>")
        [System.IO.File]::WriteAllText($path, $html, [System.Text.Encoding]::UTF8)
        $patched++
        Write-Host "PATCHED: $f"
    }
}
Write-Host "Total: $patched patched"
