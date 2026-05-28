 $reportShellPath = Join-Path $PSScriptRoot 'HtmlReportShell.ps1'
 if (Test-Path -Path $reportShellPath) {
     . $reportShellPath
 }

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

    $recommendationItems = @($ReportObject.recommendations | ForEach-Object {
        '<li>[' + (ConvertTo-DanewReportHtmlText $_.priority) + '] ' + (ConvertTo-DanewReportHtmlText $_.feature) + ': ' + (ConvertTo-DanewReportHtmlText $_.recommendation) + '</li>'
    })
    $metrics = @(
        (New-DanewMetricCardHtml -Label 'Global score' -Value ($ReportObject.score.global.ToString() + '/100') -Tone 'info')
        (New-DanewMetricCardHtml -Label 'Recommendations' -Value @($ReportObject.recommendations).Count -Tone 'ready')
        (New-DanewMetricCardHtml -Label 'Architecture' -Value $ReportObject.architecture -Tone 'neutral')
    ) -join ''
    $meta = New-DanewReportMetaListHtml -Items @(
        [pscustomobject]@{ label = 'Scan ID'; value = $ReportObject.scan_id }
        [pscustomobject]@{ label = 'Timestamp'; value = $ReportObject.timestamp }
        [pscustomobject]@{ label = 'Input'; value = $ReportObject.input.path }
    )
    $sections = @(
        (New-DanewReportSectionHtml -Title 'Recommendations' -Caption 'Prioritized improvements extracted from the current scan.' -SearchText ('recommendations ' + (@($ReportObject.recommendations | ForEach-Object { $_.priority, $_.feature, $_.recommendation }) -join ' ')) -BodyHtml ('<ul class="report-list">' + ($recommendationItems -join '') + '</ul>'))
    )
    $html = New-DanewInteractiveReportHtml -Title 'Danew WinPE Report' -Subtitle 'Interactive export for scan summary and prioritized recommendations.' -Status 'READY' -Eyebrow 'General report' -HeroMetricsHtml ('<div class="hero-metrics">' + $metrics + '</div>') -MetaHtml $meta -Sections $sections -SearchPlaceholder 'Filter recommendations by priority, feature, or recommendation text'

    $html | Set-Content -Path $htmlPath -Encoding UTF8
    Update-DanewInteractiveReportsIndex -ReportsPath $OutputDirectory | Out-Null

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
