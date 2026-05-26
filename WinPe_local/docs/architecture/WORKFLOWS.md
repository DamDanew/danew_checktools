# Workflows Foundation

## 1) Workflow d analyse
```mermaid
sequenceDiagram
    participant U as User/CLI
    participant O as Orchestrator
    participant S as Scan Engine
    participant D as Detection Engine
    participant R as Recommendation Engine
    participant P as Profile Engine
    participant Rep as Report Engine

    U->>O: Invoke Scan (inputPath, profile, mode)
    O->>S: Build file inventory
    S-->>O: Snapshot (files, binaries, drivers, runtimes)
    O->>D: Resolve features from catalogs
    D-->>O: Feature map + compatibility map
    O->>P: Match profile requirements
    P-->>O: Coverage + gap list
    O->>R: Generate recommendations + priorities
    R-->>O: Improvement plan + size/RAM estimate
    O->>Rep: Export JSON/HTML/TXT/CSV
    Rep-->>U: Reports + prebuild plan
```

## 2) Workflow cache offline
```mermaid
flowchart TD
    A[Catalog Item] --> B{Version already in local cache?}
    B -->|Yes| C[Reuse local package]
    B -->|No| D[Download to downloads]
    D --> E[Verify SHA256]
    E --> F[Verify signature/vendor]
    F --> G[Promote to cache\ntools/<name>/<version>]
    G --> H[Update cache index]
```

## 3) Workflow build preparation (no USB write)
```mermaid
flowchart LR
    A[Scan Result] --> B[Gap Analysis]
    B --> C[Dependency Resolution]
    C --> D[Simulation Plan]
    D --> E[Size + RAM estimation]
    E --> F[Build Manifest Generation]
    F --> G[Ready for build stage]
```

## 4) Workflow historique de build
1. Generate build plan id
2. Persist profile, selected tools, selected drivers, architecture
3. Persist package hashes and source metadata
4. Persist expected output size and timestamp
5. Persist final image hash after build phase (future)
