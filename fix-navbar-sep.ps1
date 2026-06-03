$targetFiles = Get-ChildItem 'H:\Danew_CheckTool\WinPe_local\reports\' -Filter '*.html'
$patched = 0

foreach ($file in $targetFiles) {
    $html = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)

    # Check if old broken separator pattern exists (backtick + n + nav-sep span)
    if ($html -notmatch 'nav-sep') { continue }

    # Replace: backtick-n + <span class="nav-sep">|</span> + backtick-n
    # with: clean <span class="nav-sep" aria-hidden="true"></span>
    $before = $html.Length
    $html = $html -replace '`n<span class="nav-sep">\|</span>`n', '<span class="nav-sep" aria-hidden="true"></span>'

    if ($html.Length -ne $before -or $html -match '<span class="nav-sep" aria-hidden="true"></span>') {
        [System.IO.File]::WriteAllText($file.FullName, $html, [System.Text.Encoding]::UTF8)
        $patched++
        Write-Host "FIXED: $($file.Name)"
    }
}
Write-Host "Total fixed: $patched files"
