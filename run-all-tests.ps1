$base = 'H:\Danew_CheckTool\WinPe_local\scripts\tests'
foreach ($t in @('Run-ReportFrenchTests','Run-UX2Tests','Run-Phase6ATests','Run-EvtxDismCorrelationTests')) {
    & "$base\$t.ps1" | Out-Null
    $rpt = "H:\Danew_CheckTool\WinPe_local\reports\$($t.ToLower())-report.txt"
    if (-not (Test-Path $rpt)) {
        # try alternate naming
        $rpt = Get-ChildItem 'H:\Danew_CheckTool\WinPe_local\reports' -Filter "*$($t.ToLower().Replace('run-',''))*report.txt" | Select-Object -First 1 -ExpandProperty FullName
    }
    if ($rpt -and (Test-Path $rpt)) {
        Get-Content $rpt | Select-Object -First 4
    } else {
        Write-Host "Report not found for $t"
    }
}
