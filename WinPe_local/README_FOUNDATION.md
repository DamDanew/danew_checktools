# Danew CheckTool - WinPE Analyzer & Builder (Foundation)

## But
Initialiser une base professionnelle pour:
- scanner un environnement WinPE
- evaluer ses capacites
- recommander des enrichissements
- preparer un build futur sans toucher la cle USB de production

## Entrees supportees
- Dossier WinPE de travail
- Image boot.wim montee
- Structure locale miroir USB

## Lancement (preview)
`pwsh -File .\scripts\Invoke-DanewWinPEFoundation.ps1 -InputPath .\WinPe_local -TargetTier sav-advanced -Mode Simulation`

## Sorties
- JSON: inventaire, score, recommandations, plan
- TXT/CSV/HTML: rapports lisibles
- Build manifest: preparation phase build

## Regle critique
Ne jamais modifier le media USB de production directement.
