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
