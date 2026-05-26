function Get-DanewCachePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [Parameter(Mandatory = $true)]
        [string]$ToolName,
        [Parameter(Mandatory = $true)]
        [string]$Version
    )

    return (Join-Path $RootPath ("tools\$ToolName\$Version"))
}

function Initialize-DanewCacheIndex {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath
    )

    $indexPath = Join-Path $RootPath 'cache\index.json'

    if (-not (Test-Path $indexPath)) {
        @{
            version = '1.0.0'
            updated_at = (Get-Date).ToString('s')
            items = @()
        } | ConvertTo-Json -Depth 20 | Set-Content -Path $indexPath -Encoding UTF8
    }

    return $indexPath
}
