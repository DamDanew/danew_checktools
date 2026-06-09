$src = 'H:\Danew_CheckTool\WinPe_local'
$files = @(
    'RAPPORTS_TECHPC.bat',
    'scripts\launcher.ps1',
    'scripts\DanewCheckTool.CLI.ps1',
    'scripts\launcher\LauncherCore.ps1',
    'scripts\Run-TechPcReportViewerTests.ps1',
    'scripts\Run-WinPECollectorModeTests.ps1',
    'scripts\report\HtmlReportShell.ps1',
    'reports\timeline-raw.html',
    'reports\sav-diagnostic-report.html',
    'reports\evtx-events.html',
    'reports\evtx-by-file.html',
    'reports\REPORTS_INDEX.html',
    'reports\reports-index.html'
)
$dsts = @('D:','E:')
$ok = 0; $skip = 0

foreach ($f in $files) {
    $srcPath = Join-Path $src $f
    if (-not (Test-Path $srcPath)) { Write-Host "MISSING: $f"; continue }
    $srcHash = (Get-FileHash $srcPath -Algorithm SHA256).Hash
    foreach ($d in $dsts) {
        # Preserve directory structure: scripts\launcher.ps1 -> D:\scripts\launcher.ps1
        $dstPath = Join-Path $d $f
        $dstDir  = Split-Path $dstPath -Parent
        if (-not (Test-Path $dstDir -ErrorAction SilentlyContinue)) {
            New-Item -Path $dstDir -ItemType Directory -Force | Out-Null
        }
        Copy-Item $srcPath $dstPath -Force
        $match = (Get-FileHash $dstPath -Algorithm SHA256).Hash -eq $srcHash
        $icon = if ($match) { 'OK' } else { 'MISMATCH' }
        Write-Host "$icon  $f -> ${d}\"
        $ok++
    }
}
Write-Host ""
Write-Host "DONE: $ok files synced, $skip skipped"
