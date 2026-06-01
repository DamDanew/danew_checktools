[CmdletBinding()]
param(
    [string]$RootPath = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [string]$ChromiumSourceFolder,
    [switch]$SyncToUsb,
    [string]$UsbDriveLetter = 'E'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DanewLatestPlaywrightChromiumFolder {
    $base = Join-Path $env:LOCALAPPDATA 'ms-playwright'
    if (-not (Test-Path -Path $base)) {
        return ''
    }

    $candidates = @(Get-ChildItem -Path $base -Directory -Filter 'chromium-*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    foreach ($dir in $candidates) {
        $folder = Join-Path $dir.FullName 'chrome-win64'
        if (Test-Path -Path (Join-Path $folder 'chrome.exe')) {
            return $folder
        }
    }

    return ''
}

if ([string]::IsNullOrWhiteSpace($ChromiumSourceFolder)) {
    $ChromiumSourceFolder = Get-DanewLatestPlaywrightChromiumFolder
}

if ([string]::IsNullOrWhiteSpace($ChromiumSourceFolder) -or -not (Test-Path -Path (Join-Path $ChromiumSourceFolder 'chrome.exe'))) {
    throw 'Chromium source introuvable. Installez Playwright Chromium ou fournissez -ChromiumSourceFolder.'
}

$browserToolsPath = Join-Path $RootPath 'tools\browser'
if (-not (Test-Path -Path $browserToolsPath)) {
    New-Item -Path $browserToolsPath -ItemType Directory -Force | Out-Null
}

robocopy $ChromiumSourceFolder $browserToolsPath /E /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
Copy-Item -Path (Join-Path $browserToolsPath 'chrome.exe') -Destination (Join-Path $browserToolsPath 'chromium.exe') -Force

$usbPath = ''
if ($SyncToUsb) {
    $usbPath = $UsbDriveLetter + ':\tools\browser'
    if (-not (Test-Path -Path $usbPath)) {
        New-Item -Path $usbPath -ItemType Directory -Force | Out-Null
    }
    robocopy $browserToolsPath $usbPath /E /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
}

$result = [pscustomobject]@{
    timestamp = (Get-Date).ToString('s')
    source_folder = $ChromiumSourceFolder
    tools_browser_path = $browserToolsPath
    chrome_exists = (Test-Path -Path (Join-Path $browserToolsPath 'chrome.exe'))
    chromium_exists = (Test-Path -Path (Join-Path $browserToolsPath 'chromium.exe'))
    chrome_version = (Get-Item -Path (Join-Path $browserToolsPath 'chrome.exe')).VersionInfo.ProductVersion
    synced_to_usb = [bool]$SyncToUsb
    usb_browser_path = $usbPath
}

$result | ConvertTo-Json -Depth 10