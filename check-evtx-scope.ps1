# What EVTX logs were actually scanned
$tj = 'E:\reports\timeline-raw.json'
if (Test-Path $tj) {
    $raw = Get-Content $tj -Raw

    # Find EVTX file paths
    $fileMatches = [regex]::Matches($raw, 'C:\\\\Windows\\\\[^"]+\.evtx')
    $files = $fileMatches | ForEach-Object { $_.Value -replace '\\\\', '\' } | Sort-Object -Unique
    Write-Host "EVTX files scanned ($($files.Count) unique):"
    foreach ($f in $files) { Write-Host "  $f" }

    # Check for DISM in file paths
    $dismFiles = $files | Where-Object { $_ -match 'DISM|dism' }
    Write-Host ''
    if ($dismFiles) {
        Write-Host "DISM EVTX files: $($dismFiles.Count)"
        foreach ($f in $dismFiles) { Write-Host "  $f" }
    } else {
        Write-Host "DISM EVTX files: NONE — journal DISM non collecte"
    }
} else {
    Write-Host "timeline-raw.json not found at $tj"
}

Write-Host ''
# Check if DISM logs exist on system
Write-Host "=== Journaux DISM existants sur le systeme ==="
$dismLogs = @(
    'Microsoft-Windows-DISM/Operational',
    'Microsoft-Windows-Deployment-Services-Diagnostics/Operational',
    'Setup'
)
foreach ($log in $dismLogs) {
    try {
        $l = Get-WinEvent -ListLog $log -ErrorAction Stop
        Write-Host "  FOUND: $log — $($l.RecordCount) events"
    } catch {
        Write-Host "  ABSENT: $log"
    }
}

Write-Host ''
# Check C:\Windows\Logs\DISM
$dismLogPath = 'C:\Windows\Logs\DISM'
if (Test-Path $dismLogPath) {
    Write-Host "=== Dossier C:\Windows\Logs\DISM ==="
    Get-ChildItem $dismLogPath | Select-Object Name, LastWriteTime, Length | Format-Table -AutoSize
} else {
    Write-Host "C:\Windows\Logs\DISM: non trouve"
}
