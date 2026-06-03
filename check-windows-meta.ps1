# Lire toutes les métadonnées Windows dispo dans offline-windows-analysis.json
$analysisPath = 'E:\reports\offline-windows-analysis.json'
$data = Get-Content $analysisPath -Raw | ConvertFrom-Json

Write-Host "=== METADONNEES WINDOWS DISPONIBLES ==="
Write-Host ""

# registry_metadata
Write-Host "--- registry_metadata ---"
foreach ($reg in $data.registry_metadata) {
    Write-Host "  installation_root : $($reg.installation_root)"
    Write-Host "  status            : $($reg.status)"
    Write-Host "  product_name      : $($reg.product_name)"
    Write-Host "  display_version   : $($reg.display_version)"
    Write-Host "  current_build     : $($reg.current_build)"
    Write-Host "  ubr               : $($reg.ubr)"
    Write-Host "  edition_id        : $($reg.edition_id)"
    Write-Host "  install_date      : $($reg.install_date)"
    Write-Host "  registered_owner  : $($reg.registered_owner)"
    Write-Host "  computer_name     : $($reg.computer_name)"
    Write-Host "  last_update       : $($reg.last_update)"
    Write-Host "  ---"
}

Write-Host ""
Write-Host "--- valid_installations ---"
foreach ($inst in $data.valid_installations) {
    Write-Host "  path              : $($inst.path)"
    Write-Host "  windows_root      : $($inst.windows_root)"
    Write-Host "  product_name      : $($inst.product_name)"
    Write-Host "  display_version   : $($inst.display_version)"
    Write-Host "  current_build     : $($inst.current_build)"
    Write-Host "  computer_name     : $($inst.computer_name)"
    Write-Host "  install_date      : $($inst.install_date)"
    Write-Host "  ---"
}

Write-Host ""
Write-Host "--- TOP-LEVEL fields ---"
Write-Host "  discovery_case     : $($data.discovery_case)"
Write-Host "  detection_confidence: $($data.detection_confidence)"
Write-Host "  evidence_score     : $($data.evidence_score)"
Write-Host "  timestamp          : $($data.timestamp)"
