param(
    [string]$TargetVersion = "7.6.2.0",
    [switch]$ConfigureVsCodeUser,
    [switch]$ConfigureVsCodeWorkspace,
    [string]$WorkspacePath = (Get-Location).Path,
    [switch]$IncludePreviewCleanup,
    [switch]$RemoveGenericPowerShellProfile,
    [switch]$DryRun,
    [switch]$Quiet,
    [string]$LogPath
)

$ErrorActionPreference = "Stop"

$script:CommandExecutedCount = 0
$script:CommandSimulatedCount = 0
$script:SettingsWrittenCount = 0
$script:SettingsSimulatedCount = 0

if (-not $LogPath) {
    $logDir = Join-Path $PSScriptRoot "logs"
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $LogPath = Join-Path $logDir "powershell-install-clean-$stamp.log"
}

$logParent = Split-Path -Parent $LogPath
if ($logParent -and -not (Test-Path $logParent)) {
    New-Item -ItemType Directory -Path $logParent -Force | Out-Null
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )

    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
    Add-Content -Path $LogPath -Value $line -Encoding UTF8

    if (-not $Quiet) {
        switch ($Level) {
            'WARN' { Write-Host $line -ForegroundColor Yellow }
            'ERROR' { Write-Host $line -ForegroundColor Red }
            default { Write-Host $line }
        }
    }
}

function Invoke-LoggedCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$ReadOnly
    )

    if ($DryRun -and -not $ReadOnly) {
        $script:CommandSimulatedCount++
        Write-Log -Level WARN -Message "DRYRUN: skip command => $Command $($Arguments -join ' ')"
        return @{ Output = @(); ExitCode = 0; Skipped = $true }
    }

    $script:CommandExecutedCount++
    Write-Log "Run: $Command $($Arguments -join ' ')"
    $output = & $Command @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($output) {
        foreach ($line in $output) {
            $text = $line.ToString()
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                Write-Log -Message $text
            }
        }
    }
    Write-Log "ExitCode: $exitCode"
    return @{ Output = $output; ExitCode = $exitCode }
}

function Write-Step {
    param([string]$Message)
    Write-Log -Message "=== $Message ==="
}

function Get-StablePowerShellVersions {
    $res = Invoke-LoggedCommand -Command "winget" -Arguments @("list", "--id", "Microsoft.PowerShell", "--exact", "--accept-source-agreements") -ReadOnly
    $raw = $res.Output | Out-String
    $versions = @()
    foreach ($line in ($raw -split "`r?`n")) {
        if ($line -match 'Microsoft\.PowerShell\s+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)') {
            $versions += $matches[1]
        }
    }
    return ($versions | Select-Object -Unique)
}

function Get-PreviewPowerShellVersions {
    $res = Invoke-LoggedCommand -Command "winget" -Arguments @("list", "--id", "Microsoft.PowerShell.Preview", "--exact", "--accept-source-agreements") -ReadOnly
    $raw = $res.Output | Out-String
    $versions = @()
    foreach ($line in ($raw -split "`r?`n")) {
        if ($line -match 'Microsoft\.PowerShell\.Preview\s+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)') {
            $versions += $matches[1]
        }
    }
    return ($versions | Select-Object -Unique)
}

function ConvertTo-Hashtable {
    param([object]$Value)
    if ($null -eq $Value) { return @{} }
    if ($Value -is [hashtable]) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in $Value.Keys) { $h[$k] = $Value[$k] }
        return $h
    }
    return @{}
}

function Update-VsCodeSettings {
    param(
        [Parameter(Mandatory = $true)][string]$SettingsPath,
        [Parameter(Mandatory = $true)][string]$PwshPath,
        [Parameter(Mandatory = $true)][string]$ProfileName,
        [bool]$RemoveGenericProfile = $false
    )

    $dir = Split-Path -Parent $SettingsPath
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    if (Test-Path $SettingsPath) {
        $content = Get-Content -Path $SettingsPath -Raw
        if ([string]::IsNullOrWhiteSpace($content)) {
            $settings = @{}
        }
        else {
            $settings = ConvertFrom-Json -InputObject $content -AsHashtable
        }
    }
    else {
        $settings = @{}
    }

    $settings = ConvertTo-Hashtable $settings
    $profiles = ConvertTo-Hashtable $settings['terminal.integrated.profiles.windows']

    foreach ($key in @($profiles.Keys)) {
        if ($key -ne $ProfileName -and $key -match '^PowerShell\s+[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$') {
            $profiles.Remove($key) | Out-Null
        }
    }

    if ($RemoveGenericProfile -and $profiles.ContainsKey('PowerShell')) {
        $profiles.Remove('PowerShell') | Out-Null
    }

    $profiles[$ProfileName] = @{
        path = $PwshPath
        args = @('-NoLogo')
    }

    $settings['terminal.integrated.profiles.windows'] = $profiles
    $settings['terminal.integrated.defaultProfile.windows'] = $ProfileName

    if ($DryRun) {
        $script:SettingsSimulatedCount++
        Write-Log -Level WARN -Message "DRYRUN: skip writing settings => $SettingsPath"
        return
    }

    $script:SettingsWrittenCount++
    $json = $settings | ConvertTo-Json -Depth 30
    Set-Content -Path $SettingsPath -Value $json -Encoding UTF8
}

Write-Log "Flags: DryRun=$DryRun Quiet=$Quiet ConfigureVsCodeUser=$ConfigureVsCodeUser ConfigureVsCodeWorkspace=$ConfigureVsCodeWorkspace RemoveGenericPowerShellProfile=$RemoveGenericPowerShellProfile"

Write-Step "Installation PowerShell $TargetVersion"
$installRes = Invoke-LoggedCommand -Command "winget" -Arguments @("install", "--id", "Microsoft.PowerShell", "--version", $TargetVersion, "--exact", "--force", "--accept-package-agreements", "--accept-source-agreements")
if ($installRes.ExitCode -ne 0) {
    throw "Echec installation PowerShell $TargetVersion (code $($installRes.ExitCode))."
}

Write-Step "Nettoyage versions stables non cible"
$stableVersions = Get-StablePowerShellVersions
if (-not $stableVersions -or $stableVersions.Count -eq 0) {
    Write-Log "Aucune version stable detectee par winget."
}
else {
    Write-Log "Versions stables detectees: $($stableVersions -join ', ')"
    $toRemove = $stableVersions | Where-Object { $_ -ne $TargetVersion }
    foreach ($v in $toRemove) {
        Write-Log "Suppression de Microsoft.PowerShell $v"
        try {
            $removeRes = Invoke-LoggedCommand -Command "winget" -Arguments @("uninstall", "--id", "Microsoft.PowerShell", "--version", $v, "--exact", "--accept-source-agreements")
            if ($removeRes.ExitCode -ne 0) {
                Write-Log -Level WARN -Message "Echec suppression $v (code $($removeRes.ExitCode))."
            }
        }
        catch {
            Write-Log -Level WARN -Message "Exception suppression ${v}: $($_.Exception.Message)"
        }
    }
}

if ($IncludePreviewCleanup) {
    Write-Step "Nettoyage versions preview"
    $previewVersions = Get-PreviewPowerShellVersions
    foreach ($v in $previewVersions) {
        Write-Log "Suppression de Microsoft.PowerShell.Preview $v"
        try {
            $removePreviewRes = Invoke-LoggedCommand -Command "winget" -Arguments @("uninstall", "--id", "Microsoft.PowerShell.Preview", "--version", $v, "--exact", "--accept-source-agreements")
            if ($removePreviewRes.ExitCode -ne 0) {
                Write-Log -Level WARN -Message "Echec suppression preview $v (code $($removePreviewRes.ExitCode))."
            }
        }
        catch {
            Write-Log -Level WARN -Message "Exception suppression preview ${v}: $($_.Exception.Message)"
        }
    }
}

$pwshWindowsApps = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'
if (-not (Test-Path $pwshWindowsApps)) {
    throw "pwsh.exe non trouve dans WindowsApps: $pwshWindowsApps"
}

$profileName = "PowerShell $TargetVersion"

if ($ConfigureVsCodeUser) {
    Write-Step "Configuration VS Code utilisateur"
    $userSettingsCandidates = @(
        (Join-Path $env:APPDATA 'Code - Insiders\User\settings.json'),
        (Join-Path $env:APPDATA 'Code\User\settings.json')
    )

    foreach ($settingsPath in $userSettingsCandidates) {
        if (Test-Path (Split-Path -Parent $settingsPath)) {
            Update-VsCodeSettings -SettingsPath $settingsPath -PwshPath $pwshWindowsApps -ProfileName $profileName -RemoveGenericProfile:$RemoveGenericPowerShellProfile
            Write-Log "Settings utilisateur mis a jour: $settingsPath"
        }
    }
}

if ($ConfigureVsCodeWorkspace) {
    Write-Step "Configuration VS Code workspace"
    $workspaceSettings = Join-Path $WorkspacePath '.vscode\settings.json'
    Update-VsCodeSettings -SettingsPath $workspaceSettings -PwshPath $pwshWindowsApps -ProfileName $profileName -RemoveGenericProfile:$RemoveGenericPowerShellProfile
    Write-Log "Settings workspace mis a jour: $workspaceSettings"
}

Write-Step "Verification finale"
$runtimeVersion = & $pwshWindowsApps -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
Write-Log "Version runtime WindowsApps: $runtimeVersion"
Write-Log "winget list Microsoft.PowerShell:"
$null = Invoke-LoggedCommand -Command "winget" -Arguments @("list", "--id", "Microsoft.PowerShell", "--exact", "--accept-source-agreements") -ReadOnly

Write-Log "Termine."
Write-Log "Summary: commands_executed=$($script:CommandExecutedCount) commands_simulated=$($script:CommandSimulatedCount) settings_written=$($script:SettingsWrittenCount) settings_simulated=$($script:SettingsSimulatedCount)"
if (-not $Quiet) {
    Write-Host "`nTermine. Log: $LogPath" -ForegroundColor Green
}
