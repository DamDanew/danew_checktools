$files = @(
    @{ Name='CrashAnalysisEngine.ps1';         LocalSub='offline'; RemoteSub='offline' }
    @{ Name='OfflineLogsEngine.ps1';           LocalSub='offline'; RemoteSub='offline' }
    @{ Name='HtmlReportShell.ps1';             LocalSub='report';  RemoteSub='report'  }
    @{ Name='Run-EvtxDismCorrelationTests.ps1'; LocalSub='tests';   RemoteSub='tests'  }
)
$repoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$allOk = $true
foreach ($fd in $files) {
    $local = Join-Path (Join-Path $repoRoot "WinPe_local\scripts\$($fd.LocalSub)") $fd.Name
    if (-not (Test-Path $local)) { Write-Host "[----]  $($fd.Name): LOCAL MANQUANT"; $allOk = $false; continue }
    $lh = (Get-FileHash $local -Algorithm SHA256).Hash
    foreach ($drv in @('D:','E:')) {
        $remote = Join-Path "$drv\scripts\$($fd.RemoteSub)" $fd.Name
        if (Test-Path $remote) {
            $rh = (Get-FileHash $remote -Algorithm SHA256).Hash
            $ok = $lh -eq $rh
            if (-not $ok) { $allOk = $false }
            $tag = if ($ok) { 'OK  ' } else { 'DIFF' }
            Write-Host "[$tag]  $($fd.Name) -> $drv"
        } else {
            $allOk = $false
            Write-Host "[MISS]  $($fd.Name) -> ${drv}: fichier absent"
        }
    }
}
Write-Host ''
$msg = if ($allOk) { 'SYNC OK - cle a jour' } else { 'SYNC INCOMPLET - mise a jour necessaire' }
Write-Host "Resultat global: $msg"
