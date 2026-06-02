[CmdletBinding()]
param(
    [string]$RootPath,
    [string]$OutputDirectory,
    [int]$DiskNumber = 4
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RootPath)) {
    $scriptRoot = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
        $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    }
    $RootPath = Split-Path -Parent (Split-Path -Parent $scriptRoot)
}

if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $RootPath 'reports'
}

function Add-PostUX2BResult {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Details = ''
    )

    return [pscustomobject]@{ name = $Name; passed = $Passed; details = $Details }
}

$results = @()

$bootScriptPath = 'D:\scripts\launcher.ps1'
$dataScriptPath = 'E:\scripts\launcher.ps1'
$localScriptPath = Join-Path $RootPath 'scripts\launcher.ps1'

$dataVol = @(Get-Volume -FileSystemLabel 'DANEW_DATA' -ErrorAction SilentlyContinue | Select-Object -First 1)
$bootVol = @(Get-Volume -FileSystemLabel 'DANEW_BOOT' -ErrorAction SilentlyContinue | Select-Object -First 1)

$results += Add-PostUX2BResult -Name 'danew_data_detection' -Passed (@($dataVol).Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$dataVol[0].DriveLetter)) -Details ($(if (@($dataVol).Count -gt 0) { 'DANEW_DATA=' + [string]$dataVol[0].DriveLetter + ':' } else { 'DANEW_DATA volume not detected' }))

$results += Add-PostUX2BResult -Name 'danew_boot_detection' -Passed (@($bootVol).Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$bootVol[0].DriveLetter)) -Details ($(if (@($bootVol).Count -gt 0) { 'DANEW_BOOT=' + [string]$bootVol[0].DriveLetter + ':' } else { 'DANEW_BOOT volume not detected' }))

$results += Add-PostUX2BResult -Name 'launcher_present_boot_data' -Passed ((Test-Path $bootScriptPath) -and (Test-Path $dataScriptPath)) -Details ('D=' + [string](Test-Path $bootScriptPath) + '; E=' + [string](Test-Path $dataScriptPath))

$hashLocal = if (Test-Path $localScriptPath) { (Get-FileHash -Algorithm SHA256 -Path $localScriptPath).Hash } else { '' }
$hashBoot = if (Test-Path $bootScriptPath) { (Get-FileHash -Algorithm SHA256 -Path $bootScriptPath).Hash } else { '' }
$hashData = if (Test-Path $dataScriptPath) { (Get-FileHash -Algorithm SHA256 -Path $dataScriptPath).Hash } else { '' }

$results += Add-PostUX2BResult -Name 'launcher_synced_to_boot_data' -Passed (($hashLocal -ne '') -and ($hashLocal -eq $hashBoot) -and ($hashLocal -eq $hashData)) -Details ('local=' + $hashLocal + '; D=' + $hashBoot + '; E=' + $hashData)

$bootFallbackOk = $false
$dataFallbackOk = $false
if (Test-Path $bootScriptPath) {
    $bootContent = Get-Content -Path $bootScriptPath -Raw -Encoding UTF8
    $bootFallbackOk = $bootContent -match "REPORTS_INDEX\.html', 'reports-index\.html', 'sav-diagnostic-report\.html', 'one-click-diagnostic-report\.html', 'offline-windows-failure-report\.html'"
}
if (Test-Path $dataScriptPath) {
    $dataContent = Get-Content -Path $dataScriptPath -Raw -Encoding UTF8
    $dataFallbackOk = $dataContent -match "REPORTS_INDEX\.html', 'reports-index\.html', 'sav-diagnostic-report\.html', 'one-click-diagnostic-report\.html', 'offline-windows-failure-report\.html'"
}

$results += Add-PostUX2BResult -Name 'fallback_order_present_on_boot_data' -Passed ($bootFallbackOk -and $dataFallbackOk) -Details ('D=' + [string]$bootFallbackOk + '; E=' + [string]$dataFallbackOk)

$reportRoot = 'E:\reports'
$results += Add-PostUX2BResult -Name 'usb_report_root_exists' -Passed (Test-Path $reportRoot) -Details $reportRoot

$openD = 'D:\scripts\OpenReportsIndex.cmd'
$openE = 'E:\scripts\OpenReportsIndex.cmd'
$openDExit = 999
$openEExit = 999

if (Test-Path $openD) {
    cmd /c $openD | Out-Null
    $openDExit = $LASTEXITCODE
}
if (Test-Path $openE) {
    cmd /c $openE | Out-Null
    $openEExit = $LASTEXITCODE
}

$results += Add-PostUX2BResult -Name 'open_reports_from_D_scripts' -Passed ((Test-Path $openD) -and ($openDExit -eq 0)) -Details ('path=' + $openD + '; exit=' + [string]$openDExit)
$results += Add-PostUX2BResult -Name 'open_reports_from_E_scripts' -Passed ((Test-Path $openE) -and ($openEExit -eq 0)) -Details ('path=' + $openE + '; exit=' + [string]$openEExit)

$diskDetected = @(Get-Disk -Number $DiskNumber -ErrorAction SilentlyContinue | Select-Object -First 1)
$results += Add-PostUX2BResult -Name 'target_disk_detected' -Passed (@($diskDetected).Count -gt 0) -Details ($(if (@($diskDetected).Count -gt 0) { 'Disk=' + [string]$DiskNumber + '; FriendlyName=' + [string]$diskDetected[0].FriendlyName } else { 'Disk not found: ' + [string]$DiskNumber }))

$summary = [pscustomobject]@{
    total = @($results).Count
    passed = @($results | Where-Object { $_.passed }).Count
    failed = @($results | Where-Object { -not $_.passed }).Count
}

$report = [pscustomobject]@{
    timestamp = (Get-Date).ToString('s')
    summary = $summary
    tests = $results
}

if (-not (Test-Path -Path $OutputDirectory)) {
    New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
}

$jsonPath = Join-Path $OutputDirectory 'post-ux2b-usb-validation.json'
$txtPath = Join-Path $OutputDirectory 'post-ux2b-usb-validation.txt'

$report | ConvertTo-Json -Depth 20 | Set-Content -Path $jsonPath -Encoding UTF8

$lines = @(
    'Post UX-2B USB Validation',
    ('Total: ' + [string]$summary.total),
    ('Passed: ' + [string]$summary.passed),
    ('Failed: ' + [string]$summary.failed),
    ''
)
foreach ($result in @($results)) {
    $status = if ($result.passed) { 'PASS' } else { 'FAIL' }
    $lines += '[' + $status + '] ' + [string]$result.name + ' - ' + [string]$result.details
}
$lines | Set-Content -Path $txtPath -Encoding UTF8

Write-Host ('Post UX-2B USB validation JSON: ' + $jsonPath)
Write-Host ('Post UX-2B USB validation TXT: ' + $txtPath)

if ($summary.failed -gt 0) {
    exit 1
}
