function Export-DanewReports {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ReportObject,
        [Parameter(Mandatory = $true)]
        [string]$OutputDirectory,
        [Parameter(Mandatory = $true)]
        [string]$BaseName
    )

    if (-not (Test-Path -Path $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }

    $jsonPath = Join-Path $OutputDirectory "$BaseName.json"
    $txtPath = Join-Path $OutputDirectory "$BaseName.txt"
    $csvPath = Join-Path $OutputDirectory "$BaseName.recommendations.csv"
    $htmlPath = Join-Path $OutputDirectory "$BaseName.html"

    $ReportObject | ConvertTo-Json -Depth 20 | Set-Content -Path $jsonPath -Encoding UTF8

    $lines = @()
    $lines += "Scan ID: $($ReportObject.scan_id)"
    $lines += "Timestamp: $($ReportObject.timestamp)"
    $lines += "Input: $($ReportObject.input.path) [$($ReportObject.input.input_type)]"
    $lines += "Architecture: $($ReportObject.architecture)"
    $lines += "Global Score: $($ReportObject.score.global)/100"
    $lines += ""
    $lines += "Recommendations:"

    foreach ($r in $ReportObject.recommendations) {
        $lines += "- [$($r.priority)] $($r.feature) => $($r.recommendation)"
    }

    $lines | Set-Content -Path $txtPath -Encoding UTF8

    $ReportObject.recommendations | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

    $html = @"
<html>
<head><title>Danew WinPE Report</title></head>
<body>
<h1>Danew WinPE Report</h1>
<p><b>Scan ID:</b> $($ReportObject.scan_id)</p>
<p><b>Input:</b> $($ReportObject.input.path)</p>
<p><b>Architecture:</b> $($ReportObject.architecture)</p>
<p><b>Global Score:</b> $($ReportObject.score.global)/100</p>
<h2>Recommendations</h2>
<ul>
$((($ReportObject.recommendations | ForEach-Object { "<li>[$($_.priority)] $($_.feature): $($_.recommendation)</li>" }) -join "`n"))
</ul>
</body>
</html>
"@

    $html | Set-Content -Path $htmlPath -Encoding UTF8

    return [pscustomobject]@{
        json = $jsonPath
        txt = $txtPath
        csv = $csvPath
        html = $htmlPath
    }
}

function Export-DanewPhase3Artifacts {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputDirectory,
        [Parameter(Mandatory = $true)]
        [object]$EnrichmentPlan,
        [Parameter(Mandatory = $true)]
        [object]$ScoreDelta,
        [Parameter(Mandatory = $true)]
        [object]$RegistryAnalysis,
        [Parameter(Mandatory = $true)]
        [object]$DriverVendorAnalysis
    )

    if (-not (Test-Path -Path $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }

    $enrichmentJson = Join-Path $OutputDirectory 'enrichment-plan.json'
    $enrichmentHtml = Join-Path $OutputDirectory 'enrichment-plan.html'
    $scoreDeltaJson = Join-Path $OutputDirectory 'score-delta.json'
    $registryJson = Join-Path $OutputDirectory 'registry-analysis.json'
    $driverVendorJson = Join-Path $OutputDirectory 'driver-vendor-analysis.json'

    $EnrichmentPlan | ConvertTo-Json -Depth 20 | Set-Content -Path $enrichmentJson -Encoding UTF8
    $ScoreDelta | ConvertTo-Json -Depth 20 | Set-Content -Path $scoreDeltaJson -Encoding UTF8
    $RegistryAnalysis | ConvertTo-Json -Depth 20 | Set-Content -Path $registryJson -Encoding UTF8
    $DriverVendorAnalysis | ConvertTo-Json -Depth 20 | Set-Content -Path $driverVendorJson -Encoding UTF8

    $html = @"
<html>
<head><title>Danew Enrichment Plan</title></head>
<body>
<h1>Danew Enrichment Plan</h1>
<p><b>Plan ID:</b> $($EnrichmentPlan.plan_id)</p>
<p><b>Profile:</b> $($EnrichmentPlan.profile)</p>
<p><b>Estimated Size:</b> $($EnrichmentPlan.estimated_size_mb) MB</p>
<p><b>Estimated RAM:</b> $($EnrichmentPlan.estimated_ram_mb) MB</p>
<h2>Score Delta</h2>
<p>Global: $($ScoreDelta.before.global) -> $($ScoreDelta.after.global) (delta $($ScoreDelta.delta.global))</p>
<h2>Driver Actions</h2>
<ul>$((($EnrichmentPlan.driver_actions | ForEach-Object { "<li>$($_.action) [$($_.priority)]</li>" }) -join "`n"))</ul>
<h2>Tool Actions</h2>
<ul>$((($EnrichmentPlan.tool_actions | ForEach-Object { "<li>$($_.action) [$($_.priority)]</li>" }) -join "`n"))</ul>
<h2>Package Actions</h2>
<ul>$((($EnrichmentPlan.package_actions | ForEach-Object { "<li>$($_.action) [$($_.priority)]</li>" }) -join "`n"))</ul>
</body>
</html>
"@
    $html | Set-Content -Path $enrichmentHtml -Encoding UTF8

    return [pscustomobject]@{
        enrichment_plan_json = $enrichmentJson
        enrichment_plan_html = $enrichmentHtml
        score_delta_json = $scoreDeltaJson
        registry_analysis_json = $registryJson
        driver_vendor_analysis_json = $driverVendorJson
    }
}
