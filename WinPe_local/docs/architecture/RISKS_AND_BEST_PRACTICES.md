# Risks, Limitations, and Best Practices

## Risks
- Catalogue stale: recommandations obsoletes
- Binaries renamed by OEM: detection partielle
- Drivers custom INF: categorisation inexacte
- WinSxS size explosion: scans lents

## Best practices
- Versionner tous les manifests
- Utiliser checksums et signatures systematiquement
- Maintenir un cache immutable par version
- Executer des scans regulierement sur images de reference
- Comparer les scores entre builds pour detecter regressions
- Conserver historique de build et rapports pour audit SAV/OEM

## Optimisations recommandees
- Incremental scanning via cache index
- Parallelisation des checks non-bloquants
- Classification par confidence level
- Rule engine exterieur au code (JSON/YAML)
