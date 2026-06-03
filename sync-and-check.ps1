$files = @(
    @{ Name='CrashAnalysisEngine.ps1'; Sub='offline' }
    @{ Name='OfflineLogsEngine.ps1';   Sub='offline' }
)
foreach ($fd in $files) {
    $src = "H:\Danew_CheckTool\WinPe_local\scripts\$($fd.Sub)\$($fd.Name)"
    foreach ($drive in @('D:','E:')) {
        $dst = "$drive\scripts\$($fd.Sub)\$($fd.Name)"
        $dstDir = Split-Path $dst
        if (Test-Path $dstDir) {
            Copy-Item $src $dst -Force
            $sh = (Get-FileHash $src -Algorithm SHA256).Hash
            $dh = (Get-FileHash $dst -Algorithm SHA256).Hash
            Write-Host "SYNC $($fd.Name) -> $drive match=$($sh -eq $dh)"
        } else {
            Write-Host "SKIP $($fd.Name) -> ${drive}: dir missing"
        }
    }
}

$lc = Get-Content 'H:\Danew_CheckTool\WinPe_local\scripts\launcher.ps1' -Raw
Write-Host "launcher has DanewSavClient: $($lc -match 'Get-DanewSavClientText')"

$ce = Get-Content 'H:\Danew_CheckTool\WinPe_local\scripts\offline\CrashAnalysisEngine.ps1' -Raw
Write-Host "danewCopyCmd JS: $($ce -match 'danewCopyCmd')"
$noAutoExec = -not ($ce -match 'Invoke-Expression')
Write-Host "No auto-exec (Invoke-Expression): $noAutoExec"
Write-Host "Client text fn: $($ce -match 'function Get-DanewSavClientText')"
Write-Host "Pattern actions fn: $($ce -match 'function Get-DanewSavPatternActions')"
Write-Host "detected_patterns field: $($ce -match 'detected_patterns')"
Write-Host "Critical timeline: $($ce -match 'critAllRecords')"
Write-Host "Pattern cards: $($ce -match 'patternCardsHtml')"
Write-Host "Safe actions section: $($ce -match 'Depannage SAV securise')"
$pCount = ([regex]::Matches($ce, 'pattern\s+=\s+.NTFS corruption before login|Kernel-Power reboot triggering|Driver failure causing repeated|Repeated service failures|WHEA hardware error indicating|Intel RST/VMD issue causing|DISM/CBS servicing before crash|CBS/DISM servicing before login|CBS/DISM corruption marker')).Count
Write-Host "Supplementary patterns defined: $pCount / 9 expected"
