[CmdletBinding()]
param(
    [string]$RootPath = (Split-Path -Parent $PSScriptRoot),
    [string]$BootWimPath,
    [int]$ImageIndex = 1,
    [string]$ProfileId,
    [string]$AdkWinPeOcRoot,
    [string]$MountPath,
    [switch]$SkipBackup,
    [switch]$DisableDismFallback
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'launcher\LauncherCore.ps1')
. (Join-Path $PSScriptRoot 'catalog\CatalogService.ps1')

function Get-DanewDefaultOcRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Architecture
    )

    $roots = @(
        'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment',
        'C:\Program Files\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment'
    )

    foreach ($base in $roots) {
        $candidate = Join-Path $base ($Architecture + '\WinPE_OCs')
        if (Test-Path -Path $candidate) {
            return $candidate
        }
    }

    throw "Unable to find WinPE optional component root for architecture '$Architecture'."
}

function Resolve-DanewArchitectureName {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Architecture
    )

    $raw = [string]$Architecture
    switch ($raw.ToLowerInvariant()) {
        '0' { return 'x86' }
        '5' { return 'arm' }
        '9' { return 'amd64' }
        '12' { return 'arm64' }
        'x64' { return 'amd64' }
        'amd64' { return 'amd64' }
        'x86' { return 'x86' }
        'arm64' { return 'arm64' }
        default { return $raw }
    }
}

if (-not $BootWimPath) {
    $config = Get-DanewLauncherConfig -RootPath $RootPath
    $BootWimPath = Join-Path $config.input_path 'sources\boot.wim'
    if (-not $ProfileId) {
        $ProfileId = $config.default_tier
    }
}

if (-not $ProfileId) {
    $ProfileId = 'sav-advanced'
}

if (-not (Test-Path -Path $BootWimPath)) {
    throw "boot.wim not found: $BootWimPath"
}

$catalog = Get-DanewCatalogContext -RootPath $RootPath
$imageInfo = Get-WindowsImage -ImagePath $BootWimPath -Index $ImageIndex
$architecture = Resolve-DanewArchitectureName -Architecture $imageInfo.Architecture
if ([string]::IsNullOrWhiteSpace($architecture)) {
    throw 'Unable to determine boot.wim architecture.'
}

if (-not $AdkWinPeOcRoot) {
    $AdkWinPeOcRoot = Get-DanewDefaultOcRoot -Architecture $architecture
}

if (-not (Test-Path -Path $AdkWinPeOcRoot)) {
    throw "ADK WinPE optional component root not found: $AdkWinPeOcRoot"
}

if (-not $MountPath) {
    $MountPath = Join-Path $RootPath 'temp\bootwim-servicing'
}

$requiredIds = @($catalog.WinPEPackagesCatalog.items | Where-Object { @($_.required_profiles) -contains $ProfileId } | ForEach-Object { [string]$_.id })
$orderedIds = @($catalog.PackageDependencyOrder.order | Where-Object { $requiredIds -contains $_ })

if (@($orderedIds).Count -eq 0) {
    throw "No WinPE packages defined for profile '$ProfileId'."
}

$packagePlan = @()
foreach ($pkgId in $orderedIds) {
    $entry = $catalog.WinPEPackagesCatalog.items | Where-Object { $_.id -eq $pkgId } | Select-Object -First 1
    if (-not $entry) {
        throw "Missing package catalog entry for '$pkgId'."
    }

    $cabPath = Join-Path $AdkWinPeOcRoot ($entry.name + '.cab')
    if (-not (Test-Path -Path $cabPath)) {
        throw "Required package CAB not found: $cabPath"
    }

    $packagePlan += [pscustomobject]@{
        id = $pkgId
        name = [string]$entry.name
        cab_path = $cabPath
    }
}

$backupPath = ''
if (-not $SkipBackup) {
    # Safety snapshot used for rollback if package servicing fails.
    $backupPath = $BootWimPath + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item -Path $BootWimPath -Destination $backupPath -Force
}

if (Test-Path -Path $MountPath) {
    if ((Get-ChildItem -Path $MountPath -Force -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0) {
        $mounted = @(Get-WindowsImage -Mounted | Where-Object { $_.Path -eq $MountPath })
        if (@($mounted).Count -gt 0) {
            Dismount-WindowsImage -Path $MountPath -Discard | Out-Null
        }
        Remove-Item -Path $MountPath -Recurse -Force
    }
}
New-Item -Path $MountPath -ItemType Directory -Force | Out-Null

$packageApplyMethod = 'Add-WindowsPackage'
$fallbackUsed = $false
$primaryApplyError = ''
$snapshotRestored = $false

function Invoke-DanewDismAddPackage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImagePath,
        [Parameter(Mandatory = $true)]
        [string]$PackagePath
    )

    $arguments = @(
        '/English',
        ('/Image:{0}' -f $ImagePath),
        '/Add-Package',
        ('/PackagePath:{0}' -f $PackagePath)
    )

    $output = & dism.exe @arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $details = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        throw ('dism.exe Add-Package failed (exit=' + [string]$exitCode + ') for ' + $PackagePath + [Environment]::NewLine + $details)
    }
}

try {
    Mount-WindowsImage -ImagePath $BootWimPath -Index $ImageIndex -Path $MountPath | Out-Null

    try {
        foreach ($pkg in $packagePlan) {
            Add-WindowsPackage -Path $MountPath -PackagePath $pkg.cab_path | Out-Null
        }
    }
    catch {
        $primaryApplyError = [string]$_.Exception.Message
        if ($DisableDismFallback) {
            throw
        }

        $fallbackUsed = $true
        $packageApplyMethod = 'dism.exe'
        Write-Warning ('Add-WindowsPackage failed: ' + $primaryApplyError + ' ; retrying via dism.exe fallback.')

        $mountedRetry = @(Get-WindowsImage -Mounted | Where-Object { $_.Path -eq $MountPath })
        if (@($mountedRetry).Count -gt 0) {
            Dismount-WindowsImage -Path $MountPath -Discard | Out-Null
        }

        Mount-WindowsImage -ImagePath $BootWimPath -Index $ImageIndex -Path $MountPath | Out-Null
        foreach ($pkg in $packagePlan) {
            Invoke-DanewDismAddPackage -ImagePath $MountPath -PackagePath $pkg.cab_path
        }
    }

    $installed = @(Get-WindowsPackage -Path $MountPath | Where-Object { $_.PackageName -match 'WinPE-(WMI|Scripting|NetFx|PowerShell|MDAC|StorageWMI)' -and $_.PackageState -match 'Installed' } | Select-Object -ExpandProperty PackageName)
    Dismount-WindowsImage -Path $MountPath -Save | Out-Null

    [pscustomobject]@{
        boot_wim_path = $BootWimPath
        backup_path = $backupPath
        image_index = $ImageIndex
        architecture = $architecture
        profile = $ProfileId
        oc_root = $AdkWinPeOcRoot
        packages_applied = $packagePlan
        installed_packages = $installed
        package_apply_method = $packageApplyMethod
        fallback_used = $fallbackUsed
        primary_apply_error = $primaryApplyError
        snapshot_path = $backupPath
        snapshot_restored = $snapshotRestored
        status = 'PASS'
    } | ConvertTo-Json -Depth 20 | Set-Content -Path (Join-Path $RootPath 'reports\boot-wim-repair-report.json') -Encoding UTF8

    Write-Host "boot.wim repaired: $BootWimPath"
    if ($backupPath) {
        Write-Host "Backup: $backupPath"
    }
    Write-Host "Report: $(Join-Path $RootPath 'reports\boot-wim-repair-report.json')"
}
catch {
    $mounted = @(Get-WindowsImage -Mounted | Where-Object { $_.Path -eq $MountPath })
    if (@($mounted).Count -gt 0) {
        Dismount-WindowsImage -Path $MountPath -Discard | Out-Null
    }

    if ($backupPath -and (Test-Path -Path $backupPath)) {
        Copy-Item -Path $backupPath -Destination $BootWimPath -Force
        $snapshotRestored = $true
    }

    [pscustomobject]@{
        boot_wim_path = $BootWimPath
        backup_path = $backupPath
        image_index = $ImageIndex
        architecture = $architecture
        profile = $ProfileId
        oc_root = $AdkWinPeOcRoot
        packages_applied = $packagePlan
        package_apply_method = $packageApplyMethod
        fallback_used = $fallbackUsed
        primary_apply_error = $primaryApplyError
        snapshot_path = $backupPath
        snapshot_restored = $snapshotRestored
        status = 'FAIL'
        failure_reason = [string]$_.Exception.Message
    } | ConvertTo-Json -Depth 20 | Set-Content -Path (Join-Path $RootPath 'reports\boot-wim-repair-report.json') -Encoding UTF8

    throw
}
