# TODO demain - Logs offline et UX

Date de preparation: 2026-05-28

## Synchro multi-agent (systematique)

Regle de fonctionnement (a appliquer a chaque reprise):
- Agent A = CODEX ; Agent B = VSCODE.
- Avant de commencer, chaque agent annonce ses taches prises dans AGENT_COMMUNICATION.md.
- Une tache = un seul proprietaire actif.
- Si une tache est deja prise, ne pas modifier les memes fichiers.
- Fichiers verrouilles = edition uniquement par l agent qui claim.
- En fin de bloc, l agent note: fichiers modifies, tests lances, resultat.

Format court a utiliser:
- PRIS PAR MOI: [liste des taches]
- LIBRE AUTRE AGENT: [liste des taches]
- FICHIERS VERROUILLES: [liste]

Regle de fin de tache (obligatoire):
- Sortie obligatoire: FAIT / PENDING / FILES LIBERES / TESTS / PROMPT AUTRE AGENT.
- A la fin de chaque tache, ajouter un bloc `PROMPT AUTRE AGENT` token optimise.

Template token optimise:
```
PROMPT AUTRE AGENT:
ROLE: Agent [A|B]
ETAT: [ok|warning|blocked] [resume 1 ligne]
PRIS: [tache1;tache2]
VERROUILLES: [fichier1;fichier2]
INTERDIT: [liste courte]
ACTION: [prochaine action unique]
SORTIE: FAIT/PENDING/FILES LIBERES/TESTS
```

Template 1 ligne (handoff express):
```
Handoff: ROLE=[A|B] | ETAT=[ok|warning|blocked] | PRIS=... | VERROUILLES=... | ACTION=... | SORTIE=FAIT/PENDING/FILES LIBERES/TESTS
```

## Repartition actuelle (sans empietement)

### PRIS PAR MOI (Codex Agent A)

- [x] Optimisation moteur: verifier et ajuster les parametres `offline_fast_mode`, `offline_max_events_per_log`, `offline_parallel_evtx`, `offline_evtx_parallel_jobs`.
- [x] Optimisation moteur: verifier la reutilisation du cache provider+event_id dans tous les parcours de rendu.
- [x] Tests: executer `Run-Phase6ATests.ps1` et `Run-UX2Tests.ps1` apres ajustements moteur.

Fichiers verrouilles pour cette partie:
- `scripts/offline/OfflineLogsEngine.ps1`
- `scripts/launcher-config.json` (si ajustement des valeurs par defaut)
- `scripts/tests/Run-Phase6ATests.ps1` (seulement si adaptation test strictement necessaire)

### LIBRE AUTRE AGENT

- [ ] Compatibilite WinPE: verifier en boot reel la correction PowerShell (`The term 'if' is not recognized`).
- [ ] Compatibilite WinPE: valider ouverture des rapports sans popup lecteur manquant (`F:`).
- [x] Deploiement USB: resynchroniser `launcher.ps1` et `OfflineLogsEngine.ps1` vers `D:` et `E:`.
- [x] Deploiement USB: verifier les hash SHA256 source/destination.
- [ ] Git final: commit versione/commente puis push apres validations.

Fichiers verrouilles pour autre agent:
- `scripts/launcher.ps1`
- `scripts/offline/OfflineLogsEngine.ps1` sur `D:` et `E:` uniquement (sync/deploiement)
- `reports/*` (artefacts de validation)

## Objectif principal
Ajouter une lecture plus rapide des logs EVTX, en conservant la vue detaillee existante.

## Modes cibles

- [x] Mode 1: Rapide - Erreurs uniquement.
- [x] Mode 2: Complet - Tous les evenements.

## Taches prioritaires

- [x] Ajouter un 2e bouton dans "Rapports et actions" pour une lecture rapide par fichier EVTX.
- [x] Conserver le bouton actuel "LIRE LES LOGS WINDOWS (CLASSES)" pour la vue complete detaillee.
- [x] Generer un nouveau rapport HTML "par fichier" (regroupement par source EVTX).
- [x] Ajouter un mode "erreurs par type" (focus Critique/Erreur) dans la vue rapide.
- [x] Ajouter des sections pliables/depliables par famille (Disque/NTFS, Boot, Pilotes, WHEA, Services, Update, BitLocker, Autres).
- [x] Ajouter un resume court en tete: top causes, top evenements, volume de logs par fichier.

## Optimisation moteur (a finaliser)

- [x] Verifier les parametres de profil rapide dans la config:
  - offline_fast_mode
  - offline_max_events_per_log
  - offline_parallel_evtx
  - offline_evtx_parallel_jobs
- [x] Ajuster les valeurs par defaut selon le hardware WinPE reel (equilibre vitesse/qualite).
- [x] Verifier que le cache de connaissance provider+event_id est bien reutilise dans tous les parcours de rendu.

## Compatibilite WinPE

- [ ] Verifier en boot reel que le correctif de compatibilite PowerShell du launcher supprime l erreur "The term 'if' is not recognized".
- [ ] Valider l ouverture des rapports sans popup d erreur de lecteur manquant (F:).

## Tests a executer

- [x] Lancer Run-Phase6ATests.ps1 (attendu: 9/9 PASS).
- [x] Lancer Run-UX2Tests.ps1 (attendu: 13/13 PASS).
- [x] Ajouter un test cible pour le nouveau bouton "lecture rapide par fichier".
- [x] Ajouter un test de generation du nouveau rapport HTML par fichier.

## Deploiement USB

- [x] Resynchroniser launcher.ps1 vers D: et E:.
- [x] Resynchroniser OfflineLogsEngine.ps1 vers D: et E:.
- [x] Verifier hash SHA256 source/destination sur tous les chemins runtime.

## Git

- [ ] Commit "versione et commente" des changements de demain.
- [ ] Push sur origin/main apres validation tests + hash USB.

## Optimisation progressive (nouveau lot)

- [x] Phase 1: en mode rapide, remplacer `timeline-raw.html` lourd par une page legere de synthese/redirection vers `evtx-by-file.html` et `timeline-raw.json`.
- [ ] Phase 2: generer le HTML complet seulement sur demande explicite (analyse complete ou action ouvrir rapport detaille).
- [ ] Phase 3: produire un resume SAV immediat avant les artefacts lourds.
- [ ] Phase 4: ajouter un cache incremental EVTX base sur chemin/taille/date de modification.
- [ ] Phase 5: ne lancer exports cibles/ZIP que sur action explicite, jamais par defaut au premier diagnostic.

## Notes

- Le rapport logs detaille existe deja (tableau + details + filtres + export).
- La demande de demain est d ajouter une 2e voie de lecture plus rapide, sans retirer la vue detaillee.
