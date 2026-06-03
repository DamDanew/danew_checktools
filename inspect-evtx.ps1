$f = 'H:\Danew_CheckTool\WinPe_local\reports\evtx-by-file.html'
$html = [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8)

# All elements with id= attributes
$idMatches = [regex]::Matches($html, 'id="([^"]+)"')
Write-Host '=== ALL IDs ==='
foreach ($m in $idMatches) { Write-Host '  id=' $m.Groups[1].Value }

# All h2/h3
$hmatches = [regex]::Matches($html, '<(h[23])[^>]*>([^<]+)</')
Write-Host ''
Write-Host '=== HEADINGS ==='
foreach ($m in $hmatches) { Write-Host ' ' $m.Groups[1].Value ':' $m.Groups[2].Value }

# Chips
$chipIdx = $html.IndexOf('class="chips"')
Write-Host ''
Write-Host '=== CHIPS ==='
if ($chipIdx -ge 0) { Write-Host $html.Substring($chipIdx, [Math]::Min(400, $html.Length-$chipIdx)) }
