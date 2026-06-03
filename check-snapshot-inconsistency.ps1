# Compare gui-status-snapshot vs offline-windows-analysis

Write-Host "=== gui-status-snapshot.json ==="
$snap = 'E:\reports\gui-status-snapshot.json'
if (Test-Path $snap) {
    $s = Get-Content $snap -Raw | ConvertFrom-Json
    Write-Host "  offline_windows_detected : $($s.offline_windows_detected)"
    Write-Host "  windows_path             : $($s.windows_path)"
    Write-Host "  windows_version          : $($s.windows_version)"
    Write-Host "  windows_product          : $($s.windows_product)"
    Write-Host "  analysis_phase           : $($s.analysis_phase)"
    Write-Host "  last_updated             : $($s.last_updated)"
    Write-Host "  status                   : $($s.status)"
    Write-Host "  (LastWriteTime: $((Get-Item $snap).LastWriteTime))"
} else { Write-Host "  NOT FOUND" }

Write-Host ""
Write-Host "=== offline-windows-analysis.json ==="
$analysis = 'E:\reports\offline-windows-analysis.json'
if (Test-Path $analysis) {
    $a = Get-Content $analysis -Raw | ConvertFrom-Json
    $a.PSObject.Properties | Select-Object Name, Value | Format-Table -AutoSize
    Write-Host "  (LastWriteTime: $((Get-Item $analysis).LastWriteTime))"
} else { Write-Host "  NOT FOUND" }

Write-Host ""
Write-Host "=== Timestamps comparison ==="
$files = @(
    'E:\reports\gui-status-snapshot.json',
    'E:\reports\offline-windows-analysis.json',
    'E:\reports\sav-diagnostic-report.json',
    'E:\reports\timeline-raw.json'
)
foreach ($f in $files) {
    if (Test-Path $f) {
        $fi = Get-Item $f
        Write-Host "  $($fi.Name.PadRight(40)) $(($fi.LastWriteTime).ToString('yyyy-MM-dd HH:mm:ss'))"
    }
}

Write-Host ""
Write-Host "=== Recherche offline_windows_detected dans le code ==="
$hits = Get-ChildItem 'H:\Danew_CheckTool\WinPe_local\scripts' -Filter '*.ps1' -Recurse |
    Select-String 'offline_windows_detected' -List |
    Select-Object Path, LineNumber, Line
foreach ($h in $hits) {
    Write-Host "  $($h.Path | Split-Path -Leaf) L$($h.LineNumber): $($h.Line.Trim())"
}
