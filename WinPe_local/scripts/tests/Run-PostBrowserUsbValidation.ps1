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

function Add-PostBrowserResult {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Details = ''
    )

    return [pscustomobject]@{ name = $Name; passed = $Passed; details = $Details }
}

$results = @()

$disk = $null
try {
    $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
}
catch {
    $disk = $null
}

$results += Add-PostBrowserResult -Name 'disk_present' -Passed ($null -ne $disk) -Details ($(if ($disk) { 'disk=' + [string]$disk.Number + '; bus=' + [string]$disk.BusType } else { 'missing' }))

$files = @(
    'scripts\launcher.ps1',
    'scripts\launcher\LauncherCore.ps1',
    'scripts\DanewCheckTool.CLI.ps1',
    'scripts\SetHtmlAssociation.cmd',
    'scripts\OpenReportsIndex.cmd',
    'scripts\tests\Run-BrowserIntegrationTests.ps1',
    'scripts\tests\Run-PostBrowserUsbValidation.ps1'
)

foreach ($targetRoot in @('D:\', 'E:\')) {
    $targetName = $targetRoot.Substring(0, 1)
    $targetExists = Test-Path -Path $targetRoot
    $results += Add-PostBrowserResult -Name ('target_' + $targetName + '_present') -Passed $targetExists -Details ($(if ($targetExists) { 'present' } else { 'missing' }))

    if ($targetExists) {
        $browserDir = Join-Path $targetRoot 'tools\browser'
        $results += Add-PostBrowserResult -Name ('target_' + $targetName + '_browser_folder_exists') -Passed (Test-Path -Path $browserDir) -Details $browserDir

        foreach ($rel in @($files)) {
            $src = Join-Path $RootPath $rel
            $dst = Join-Path $targetRoot $rel
            $srcExists = Test-Path -Path $src
            $dstExists = Test-Path -Path $dst
            $name = ($targetName + '_' + ($rel -replace '[\\/:]', '_'))
            $results += Add-PostBrowserResult -Name ('exists_' + $name) -Passed ($srcExists -and $dstExists) -Details ('src=' + [string]$srcExists + '; dst=' + [string]$dstExists)
            if ($srcExists -and $dstExists) {
                $srcHash = (Get-FileHash -Algorithm SHA256 -Path $src).Hash
                $dstHash = (Get-FileHash -Algorithm SHA256 -Path $dst).Hash
                $results += Add-PostBrowserResult -Name ('hash_' + $name) -Passed ($srcHash -eq $dstHash) -Details ('src=' + $srcHash + '; dst=' + $dstHash)
            }
        }
    }
}

$localBrowserDir = Join-Path $RootPath 'tools\browser'
$providedBrowsers = @()
if (Test-Path -Path $localBrowserDir) {
    $providedBrowsers = @(Get-ChildItem -Path $localBrowserDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -in @('chrome.exe', 'chromium.exe', 'msedge.exe') })
}

if (@($providedBrowsers).Count -eq 0) {
    $results += Add-PostBrowserResult -Name 'manual_browser_binary_optional' -Passed $true -Details 'No portable browser binary provided; this is allowed.'
}
else {
    foreach ($browser in @($providedBrowsers)) {
        foreach ($targetRoot in @('D:\', 'E:\')) {
            $dst = Join-Path $targetRoot ('tools\browser\' + $browser.Name)
            $dstExists = Test-Path -Path $dst
            $hashOk = $false
            if ($dstExists) {
                $hashOk = ((Get-FileHash -Algorithm SHA256 -Path $browser.FullName).Hash -eq (Get-FileHash -Algorithm SHA256 -Path $dst).Hash)
            }
            $results += Add-PostBrowserResult -Name ('manual_browser_' + $targetRoot.Substring(0, 1) + '_' + $browser.Name) -Passed ($dstExists -and $hashOk) -Details $dst
        }
    }
}

if (-not (Test-Path -Path $OutputDirectory)) {
    New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
}

$summary = [pscustomobject]@{
    total = @($results).Count
    passed = @($results | Where-Object { $_.passed }).Count
    failed = @($results | Where-Object { -not $_.passed }).Count
}

$report = [pscustomobject]@{
    timestamp = (Get-Date).ToString('s')
    disk_number = $DiskNumber
    summary = $summary
    tests = $results
}

$jsonPath = Join-Path $OutputDirectory 'post-browser-usb-validation.json'
$txtPath = Join-Path $OutputDirectory 'post-browser-usb-validation.txt'
$report | ConvertTo-Json -Depth 30 | Set-Content -Path $jsonPath -Encoding UTF8

$lines = @(
    'Post Browser USB Validation',
    ('Disk: ' + [string]$DiskNumber),
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

Write-Host ('Post browser USB validation JSON: ' + $jsonPath)
Write-Host ('Post browser USB validation TXT: ' + $txtPath)

if ($summary.failed -gt 0) {
    exit 1
}
