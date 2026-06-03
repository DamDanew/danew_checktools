# Check DISM log
try {
    $log = Get-WinEvent -ListLog 'Microsoft-Windows-DISM/Operational' -ErrorAction Stop
    Write-Host 'DISM log: FOUND'
    Write-Host '  Records:' $log.RecordCount
    Write-Host '  Enabled:' $log.IsEnabled
    Get-WinEvent -LogName 'Microsoft-Windows-DISM/Operational' -MaxEvents 5 -ErrorAction Stop |
        ForEach-Object {
            $msg = if ($_.Message) { $_.Message.Substring(0, [Math]::Min(80, $_.Message.Length)) } else { '' }
            Write-Host "  [$($_.LevelDisplayName)] ID:$($_.Id) | $msg"
        }
} catch {
    Write-Host 'DISM log: NOT FOUND or EMPTY -' $_.Exception.Message
}

Write-Host ''

# Check evtx-discovery for scanned logs
$discovery = 'E:\reports\evtx-discovery.json'
if (Test-Path $discovery) {
    $raw = Get-Content $discovery -Raw
    $dismFound = [regex]::Matches($raw, '"[^"]*[Dd][Ii][Ss][Mm][^"]*"')
    Write-Host "DISM references in evtx-discovery.json: $($dismFound.Count)"
    foreach ($m in $dismFound) { Write-Host " " $m.Value }

    $data = $raw | ConvertFrom-Json
    $keys = $data | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name
    Write-Host "Total journals scanned: $($keys.Count)"
    $keys | Sort-Object | ForEach-Object { Write-Host "  $_" }
} else {
    Write-Host 'evtx-discovery.json: NOT FOUND'
}
