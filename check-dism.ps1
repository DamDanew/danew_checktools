Write-Host '=== DISM dans les rapports HTML ==='

# Check HTML reports for DISM
$htmlFiles = @(
    'E:\reports\timeline-raw.html',
    'E:\reports\evtx-events.html',
    'E:\reports\evtx-by-file.html',
    'E:\reports\sav-diagnostic-report.html'
)

foreach ($f in $htmlFiles) {
    if (-not (Test-Path $f)) { Write-Host "MISSING: $f"; continue }
    $html = [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8)
    $count = ([regex]::Matches($html, 'DISM', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)).Count
    Write-Host "  $(Split-Path $f -Leaf): $count occurrences DISM"
}

Write-Host ''
Write-Host '=== DISM dans les JSON ==='

# Check JSON data
$jsonFiles = @(
    'E:\reports\timeline-raw.json',
    'E:\reports\evtx-events.json',
    'E:\reports\evtx-summary.json'
)

foreach ($f in $jsonFiles) {
    if (-not (Test-Path $f)) { Write-Host "MISSING: $f"; continue }
    $content = [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8)
    $count = ([regex]::Matches($content, 'DISM', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)).Count
    Write-Host "  $(Split-Path $f -Leaf): $count occurrences DISM"
}

Write-Host ''
Write-Host '=== DISM events dans timeline-raw.json (detail) ==='

$jsonPath = 'E:\reports\timeline-raw.json'
if (Test-Path $jsonPath) {
    $data = Get-Content $jsonPath -Raw | ConvertFrom-Json
    $events = if ($data.events) { $data.events } elseif ($data.PSObject.Properties['items']) { $data.items } else { @() }
    Write-Host "Total events: $($events.Count)"

    $dismEvents = $events | Where-Object {
        ($_.source -match 'DISM') -or
        ($_.provider -match 'DISM') -or
        ($_.journal -match 'DISM') -or
        ($_.message -match 'DISM')
    }
    Write-Host "DISM events: $($dismEvents.Count)"

    if ($dismEvents.Count -gt 0) {
        $dismEvents | Select-Object -First 5 | ForEach-Object {
            $src = if ($_.source) { $_.source } elseif ($_.provider) { $_.provider } else { 'n/a' }
            $msg = if ($_.message) { $_.message.ToString().Substring(0, [Math]::Min(100, $_.message.ToString().Length)) } else { '' }
            Write-Host "  [$($_.level)] $src | ID:$($_.id) | $msg"
        }
    }

    # Also check what providers/sources exist
    Write-Host ''
    Write-Host '=== Sources uniques (top 20) ==='
    $events | Group-Object { if ($_.source) { $_.source } else { $_.provider } } |
        Sort-Object Count -Descending |
        Select-Object -First 20 |
        ForEach-Object { Write-Host "  $($_.Count)x  $($_.Name)" }
}
