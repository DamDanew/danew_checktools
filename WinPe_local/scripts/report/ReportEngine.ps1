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
    $lines += "ID analyse: $($ReportObject.scan_id)"
    $lines += "Horodatage: $($ReportObject.timestamp)"
    $lines += "Entree: $($ReportObject.input.path) [$($ReportObject.input.input_type)]"
    $lines += "Architecture: $($ReportObject.architecture)"
    $lines += "Score global: $($ReportObject.score.global)/100"
    $lines += ""
    $lines += "Recommandations :"

    foreach ($r in $ReportObject.recommendations) {
        $lines += "- [$($r.priority)] $($r.feature) => $($r.recommendation)"
    }

    $lines | Set-Content -Path $txtPath -Encoding UTF8

    $ReportObject.recommendations | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

    $recommendationItems = @($ReportObject.recommendations | ForEach-Object {
        '<li>[' + (ConvertTo-DanewReportHtmlText $_.priority) + '] ' + (ConvertTo-DanewReportHtmlText $_.feature) + ': ' + (ConvertTo-DanewReportHtmlText $_.recommendation) + '</li>'
    })
    $metrics = @(
        (New-DanewMetricCardHtml -Label 'Score global' -Value ($ReportObject.score.global.ToString() + '/100') -Tone 'info')
        (New-DanewMetricCardHtml -Label 'Recommandations' -Value @($ReportObject.recommendations).Count -Tone 'ready')
        (New-DanewMetricCardHtml -Label 'Architecture' -Value $ReportObject.architecture -Tone 'neutral')
    ) -join ''
    $meta = New-DanewReportMetaListHtml -Items @(
        [pscustomobject]@{ label = 'ID analyse'; value = $ReportObject.scan_id }
        [pscustomobject]@{ label = 'Horodatage'; value = $ReportObject.timestamp }
        [pscustomobject]@{ label = 'Entree'; value = $ReportObject.input.path }
    )
    $sections = @(
        (New-DanewReportSectionHtml -Title 'Recommandations' -Caption 'Ameliorations prioritaires extraites de l analyse en cours.' -SearchText ('recommendations ' + (@($ReportObject.recommendations | ForEach-Object { $_.priority, $_.feature, $_.recommendation }) -join ' ')) -BodyHtml ('<ul class="report-list">' + ($recommendationItems -join '') + '</ul>'))
    )
    $html = New-DanewInteractiveReportHtml -Title 'Rapport WinPE Danew' -Subtitle 'Export interactif du resume d analyse et des recommandations prioritaires.' -Status 'READY' -Eyebrow 'Rapport general' -HeroMetricsHtml ('<div class="hero-metrics">' + $metrics + '</div>') -MetaHtml $meta -Sections $sections -SearchPlaceholder 'Filtrer les recommandations par priorite, fonctionnalite ou texte'

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
<head><title>Plan d enrichissement Danew</title></head>
<body>
<h1>Plan d enrichissement Danew</h1>
<p><b>ID du plan :</b> $($EnrichmentPlan.plan_id)</p>
<p><b>Profil :</b> $($EnrichmentPlan.profile)</p>
<p><b>Taille estimee :</b> $($EnrichmentPlan.estimated_size_mb) MB</p>
<p><b>RAM estimee :</b> $($EnrichmentPlan.estimated_ram_mb) MB</p>
<h2>Delta de score</h2>
<p>Global : $($ScoreDelta.before.global) -> $($ScoreDelta.after.global) (delta $($ScoreDelta.delta.global))</p>
<h2>Actions pilotes</h2>
<ul>$((($EnrichmentPlan.driver_actions | ForEach-Object { "<li>$($_.action) [$($_.priority)]</li>" }) -join "`n"))</ul>
<h2>Actions outils</h2>
<ul>$((($EnrichmentPlan.tool_actions | ForEach-Object { "<li>$($_.action) [$($_.priority)]</li>" }) -join "`n"))</ul>
<h2>Actions packages</h2>
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
