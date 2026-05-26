function New-DanewBuildPreparationPlan {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Recommendations,
        [Parameter(Mandatory = $true)]
        [string]$ProfileId,
        [Parameter(Mandatory = $true)]
        [string]$Architecture,
        [ValidateSet('Simulation','PlanOnly')]
        [string]$Mode = 'Simulation'
    )

    $totalSize = ($Recommendations | Measure-Object -Property size_impact_mb -Sum).Sum
    $totalRam = ($Recommendations | Measure-Object -Property ram_impact_mb -Sum).Sum

    if (-not $totalSize) { $totalSize = 0 }
    if (-not $totalRam) { $totalRam = 0 }

    return [pscustomobject]@{
        mode = $Mode
        profile = $ProfileId
        architecture = $Architecture
        additions_count = @($Recommendations).Count
        estimated_size_increase_mb = [math]::Round($totalSize, 2)
        estimated_ram_increase_mb = [math]::Round($totalRam, 2)
        summary = "[SIMULATION] +$([math]::Round($totalSize,2)) MB ; +$($Recommendations.Count) items ; +$([math]::Round($totalRam,2)) MB RAM"
    }
}

function Add-DanewBuildHistoryEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [Parameter(Mandatory = $true)]
        [object]$BuildPlan,
        [Parameter(Mandatory = $true)]
        [object]$Recommendations
    )

    $historyPath = Join-Path $RootPath 'builds\build-history.json'

    $entry = [pscustomobject]@{
        build_id = ([guid]::NewGuid().ToString())
        timestamp = (Get-Date).ToString('s')
        profile = $BuildPlan.profile
        architecture = $BuildPlan.architecture
        items = @($Recommendations | ForEach-Object { $_.missing } | ForEach-Object { $_ } | Select-Object -Unique)
        estimated_size_mb = $BuildPlan.estimated_size_increase_mb
        output_sha256 = ''
        notes = $BuildPlan.summary
    }

    $history = @()
    if (Test-Path $historyPath) {
        $history = Get-Content -Path $historyPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }

    $newHistory = @($history) + @($entry)
    $newHistory | ConvertTo-Json -Depth 20 | Set-Content -Path $historyPath -Encoding UTF8

    return $entry
}
