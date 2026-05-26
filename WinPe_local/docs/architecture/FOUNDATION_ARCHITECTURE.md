# Danew CheckTool - Foundation Module (Phase 1)

## Vision
Ce module fournit une base OEM robuste pour scanner et qualifier un environnement WinPE sans modifier le media de production.

Principe immuable: WORK DIRECTORY -> BUILD -> FINAL USB EXPORT.

## Objectifs fonctionnels couverts
1. Scan WinPE (dossier, image montee, structure USB locale)
2. Detection outils, runtimes, drivers, packages optionnels WinPE
3. Validation architecture (x64/x86/ARM64) et compatibilite binaire
4. Scoring de capacites
5. Recommandations classees (Critical/Recommended/Optional/Expert)
6. Preparation de build (simulation, estimation taille/RAM, dependances)
7. Preparation cache offline, securite et historique de build

## Architecture logique
```mermaid
flowchart LR
    A[Input Resolver\nDirectory | Mounted WIM | USB Mirror] --> B[Scan Engine]
    B --> C[Detection Engine]
    C --> D[Capability Scoring]
    C --> E[Dependency Resolver]
    E --> F[Improvement Engine]
    D --> F
    F --> G[Profile Matcher]
    G --> H[Build Preparation Planner]
    H --> I[Report Engine]
    H --> J[Cache Planner]

    K[Catalogs + Manifests] --> C
    K --> E
    K --> G

    L[Security Verifier\nSHA256+Signature+Vendor] --> J
    M[Build History Store] --> I
```

## Couches techniques
- CORE: orchestration, modeles, logs, erreurs
- SCAN: inventaire fichiers, binaries, registres offline, packages
- CATALOG: metadata-driven catalogs/manifests, dependency maps
- PROFILES: exigences par niveau (Minimal, SAV Advanced, OEM Expert)
- RECOMMEND: matching profil, scoring, recommandations
- BUILD: simulation, plan d enrichissement, pre-build manifest
- CACHE: depot local versionne, index, offline mode
- SECURITY: hash/signature/vendor verification
- REPORT: export JSON/HTML/TXT/CSV

## Contrats de donnees
- Tool Catalog Entry
- Feature Catalog Entry
- Dependency Graph
- Profile Definition
- Scan Snapshot
- Capability Scorecard
- Recommendation Set
- Build Plan
- Build History Entry

## Principes de qualite OEM
- Pas de hardcode des outils: pilotage par catalogues
- Tolerance aux composants absents
- Analyse offline first
- Idempotence en simulation
- Journalisation structurée
- Versionnage manifests/profils/schemas

## Compatibilite cible
- Runtime: PowerShell 7+
- Interop Windows: DISM, reg load, signtool/Get-AuthenticodeSignature
- Extension future .NET 8 (API/GUI/agent runtime)

## Risques et limitations (Phase 1)
- Detection signature peut varier selon source binaire
- Inventaire WinSxS volumineux (necessite cache/index incremental)
- Analyse driver deep (INF dependency chain) peut etre couteuse
- Estimation RAM reste heuristique sans benchmark runtime

## Mitigations
- Index cache par hash chemin+taille+lastwrite
- Niveaux de profondeur de scan (fast/standard/deep)
- Timeouts et fallbacks sur zones lourdes
- Baseline empirique progressive pour RAM/size predictor

## Scalabilite future
- Ajout modules crash analyzer/BSOD/forensic sans casser le core
- Moteur de regles externe (YAML/JSON) pour recommandations
- Plug-ins outils OEM par fournisseur
- Telemetrie locale optionnelle (hors internet)
