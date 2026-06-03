Get-Content 'H:\Danew_CheckTool\WinPe_local\reports\report-fr-tests-report.txt' | Select-Object -First 4
Get-Content 'H:\Danew_CheckTool\WinPe_local\reports\ux2-tests-report.txt' | Select-Object -First 4
Get-Content 'H:\Danew_CheckTool\WinPe_local\reports\phase6a-tests-report.txt' | Select-Object -First 4

$dismTest = 'H:\Danew_CheckTool\WinPe_local\reports\evtx-dism-correlation-tests-report.txt'
if (Test-Path $dismTest) {
    Write-Host '--- EvtxDismCorrelation ---'
    Get-Content $dismTest | Select-Object -First 20
} else {
    Write-Host '--- EvtxDismCorrelation: report file absent ---'
}

Write-Host '--- Hash D/E ---'
$fileDefs = @(
    @{ Name='OfflineLogsEngine.ps1'; Sub='offline' }
    @{ Name='CrashAnalysisEngine.ps1'; Sub='offline' }
    @{ Name='HtmlReportShell.ps1'; Sub='report' }
)
foreach ($fd in $fileDefs) {
    $local = Get-ChildItem "H:\Danew_CheckTool\WinPe_local\scripts\$($fd.Sub)" -Filter $fd.Name -ErrorAction SilentlyContinue | Select-Object -First 1
    $dFile = Get-ChildItem "D:\scripts\$($fd.Sub)" -Filter $fd.Name -ErrorAction SilentlyContinue | Select-Object -First 1
    $eFile = Get-ChildItem "E:\scripts\$($fd.Sub)" -Filter $fd.Name -ErrorAction SilentlyContinue | Select-Object -First 1

    $lh = if ($local) { (Get-FileHash $local.FullName -Algorithm SHA256).Hash } else { 'MISSING' }
    $dh = if ($dFile) { (Get-FileHash $dFile.FullName -Algorithm SHA256).Hash } else { 'MISSING' }
    $eh = if ($eFile) { (Get-FileHash $eFile.FullName -Algorithm SHA256).Hash } else { 'MISSING' }
    Write-Host "$($fd.Name): D_match=$($lh -eq $dh) E_match=$($lh -eq $eh)"
}
