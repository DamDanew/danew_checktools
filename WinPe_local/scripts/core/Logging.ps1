function Write-DanewLog {
    param(
        [ValidateSet('INFO','WARN','ERROR','DEBUG')]
        [string]$Level = 'INFO',
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [string]$LogFile
    )

    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$ts][$Level] $Message"
    Write-Host $line

    if ($LogFile) {
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    }
}
