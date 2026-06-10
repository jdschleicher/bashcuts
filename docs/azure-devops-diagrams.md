# Azure DevOps Functionality — Mermaid Diagrams

Visual reference for the Azure DevOps work-item shortcuts in `powcuts_by_cli/azdevops_*.ps1` (split across `azdevops_auth.ps1`, `azdevops_paths.ps1`, `azdevops_sync.ps1`, `azdevops_views.ps1`, `azdevops_find.ps1`, `azdevops_classification.ps1`, `azdevops_create_pickers.ps1`, `azdevops_create.ps1`, `azdevops_schema.ps1`, `azdevops_openers.ps1`, `azdevops_unplanned.ps1`). Each diagram covers one subsystem; the last diagram is a cross-cutting function-dependency map.

- [1. High-level architecture](#1-high-level-architecture)
- [2. `az-Connect-AzDevOps` — 8-step orchestrator](#2-az-connect-azdevops--8-step-orchestrator)
- [3. `az-Test-AzDevOpsAuth` — silent diagnostic chain](#3-az-test-azdevopsauth--silent-diagnostic-chain)
- [4. `az-Sync-AzDevOpsCache` — dataset fan-out](#4-az-sync-azdevopscache--dataset-fan-out)
- [5. Cache consumers (`az-Get-AzDevOpsAssigned/Mentions` and `az-Open-Assigned/Mention`)](#5-cache-consumers-az-get-azdevopsassignedmentions-and-az-open-assignedmention)
- [6. `az-Show-Tree` — Epic → Feature → requirement-tier render](#6-az-show-tree--epic--feature--requirement-tier-render)
- [7. `az-New-AzDevOpsUserStory` — interactive create flow](#7-az-new-azdevopsuserstory--interactive-create-flow)
- [8. `az-New-AzDevOpsFeature` — interactive Feature create + child-story hand-off](#8-az-new-azdevopsfeature--interactive-feature-create--child-story-hand-off)
- [9. `az-New-AzDevOpsFeatureStories` — batch child-story loop](#9-az-new-azdevopsfeaturestories--batch-child-story-loop)
- [10. `Start-AzDevOpsBackgroundSync` — silent on-open refresh](#10-start-azdevopsbackgroundsync--silent-on-open-refresh)
- [11. `az-Start-UnplannedWork` — firefighting session loop + debrief](#11-az-start-unplannedwork--firefighting-session-loop--debrief)
- [12. Function dependency map](#12-function-dependency-map)

---

## 1. High-level architecture

How the public surface, the local cache, and the `az` CLI relate. Read-only consumers never touch `az` directly — they only read cache files.

```mermaid
flowchart LR
    subgraph User["User session ($profile)"]
        Profile["powcuts_home.ps1<br/>dot-sources azdevops_*.ps1"]
        EnvVars["$env:AZ_USER_EMAIL<br/>$env:AZ_AREA<br/>$env:AZ_ITERATION<br/>$env:AZ_TEAM<br/>(org/project come from<br/>az devops configure --defaults)"]
    end

    subgraph Public["Public functions"]
        Connect["az-Connect-AzDevOps"]
        TestAuth["az-Test-AzDevOpsAuth"]
        Sync["az-Sync-AzDevOpsCache"]
        Status["az-Get-AzDevOpsCacheStatus"]
        BgSync["Start-AzDevOpsBackgroundSync<br/>(on-open, internal)"]
        GetA["az-Get-AzDevOpsAssigned"]
        OpenA["az-Open-Assigned"]
        GetM["az-Get-AzDevOpsMentions"]
        OpenM["az-Open-Mention"]
        Tree["az-Show-Tree"]
        Board["az-Show-Board"]
        Epics["az-Show-Epics"]
        Orphans["az-Show-Orphans"]
        ShowAreas["az-Show-Areas"]
        ShowIters["az-Show-Iterations"]
        GetAreas["az-Get-AzDevOpsAreas"]
        GetIters["az-Get-AzDevOpsIterations"]
        Find["az-Find-AzDevOpsWorkItem"]
        FindArea["az-Find-AzDevOpsArea"]
        FindIter["az-Find-AzDevOpsIteration"]
        FindProj["az-Find-AzDevOpsProject"]
        NewStory["az-New-AzDevOpsUserStory"]
        NewFeat["az-New-AzDevOpsFeature"]
        NewStoryBatch["az-New-AzDevOpsFeatureStories"]
        NewTask["az-New-Task"]
        ShowFeats["az-Show-Features"]
        Help["az-help"]
    end

    subgraph PathOpeners["Path inspectors (az-Open-*)"]
        OpensFolders["Folder openers:<br/>AppRoot, CacheDir, ConfigDir, SchemaDir"]
        OpensCache["Cache file openers:<br/>AssignedCache, MentionsCache, HierarchyCache,<br/>IterationsCache, AreasCache, LastSync, SyncLog"]
        OpensWiql["WIQL openers:<br/>EpicsWiql, FeaturesWiql, UserStoriesWiql"]
        OpensSchema["az-Open-Schema"]
    end

    subgraph Cache["$HOME/.bashcuts-az-devops-app/cache/"]
        AssignedJson["assigned.json"]
        MentionsJson["mentions.json"]
        HierJson["hierarchy.json"]
        IterJson["iterations.json"]
        AreasJson["areas.json"]
        LastSync["last-sync.json"]
        SyncLog["sync.log (rotates at ~1MB)"]
    end

    subgraph Config["$HOME/.bashcuts-az-devops-app/config/queries/"]
        EpicsWiql["epics.wiql"]
        FeatsWiql["features.wiql"]
        StoriesWiql["user-stories.wiql"]
    end

    subgraph Schema["$HOME/.bashcuts-az-devops-app/schema/"]
        SchemaJson["schema-&lt;org&gt;.json"]
    end

    subgraph AzCLI["Azure CLI"]
        AzBoards["az boards query / work-item create / work-item update / relation add"]
        AzExt["az extension (azure-devops)"]
        AzAcct["az account show / az login"]
    end

    Profile --> Public
    EnvVars -.read at runtime.-> Public

    Connect --> AzAcct
    Connect --> AzExt
    Connect --> AzBoards
    TestAuth --> AzBoards

    Sync --> AzBoards
    Sync --> AssignedJson
    Sync --> MentionsJson
    Sync --> HierJson
    Sync --> IterJson
    Sync --> AreasJson
    Sync --> LastSync
    Sync --> SyncLog

    GetA --> AssignedJson
    OpenA --> AssignedJson
    GetM --> MentionsJson
    GetM -.exclude assigned ids.-> AssignedJson
    OpenM --> MentionsJson
    Tree --> HierJson
    Board --> HierJson
    Epics --> HierJson
    Orphans --> HierJson
    Find --> HierJson
    ShowFeats --> HierJson
    Status --> LastSync

    ShowAreas --> AreasJson
    ShowAreas -.live fallback.-> AzBoards
    ShowIters --> IterJson
    ShowIters -.live fallback.-> AzBoards
    GetAreas --> AreasJson
    GetAreas -.live fallback.-> AzBoards
    GetIters --> IterJson
    GetIters -.live fallback.-> AzBoards
    FindArea --> AreasJson
    FindArea -.live fallback.-> AzBoards
    FindIter --> IterJson
    FindIter -.live fallback.-> AzBoards
    FindProj -.reads $global:AzDevOpsProjectMap.-> Public

    NewStory --> HierJson
    NewStory --> IterJson
    NewStory --> AreasJson
    NewStory --> AzBoards

    NewTask --> HierJson
    NewTask --> IterJson
    NewTask --> AreasJson
    NewTask --> AzBoards

    BgSync -.spawns hidden pwsh when stale.-> Sync

    OpensFolders -.opens dir.-> Cache
    OpensFolders -.opens dir.-> Config
    OpensFolders -.opens dir.-> Schema
    OpensCache -.opens file.-> AssignedJson
    OpensCache -.opens file.-> MentionsJson
    OpensCache -.opens file.-> HierJson
    OpensCache -.opens file.-> IterJson
    OpensCache -.opens file.-> AreasJson
    OpensCache -.opens file.-> LastSync
    OpensCache -.opens file.-> SyncLog
    OpensWiql -.opens file.-> EpicsWiql
    OpensWiql -.opens file.-> FeatsWiql
    OpensWiql -.opens file.-> StoriesWiql
    OpensSchema -.opens file.-> SchemaJson

    Sync --> EpicsWiql
    Sync --> FeatsWiql
    Sync --> StoriesWiql
```

---

## 2. `az-Connect-AzDevOps` — 8-step orchestrator

Thin orchestrator: a hard-coded array of step descriptors. Each step is a `Confirm-*` function that prints its own status and returns `{Ok, FailMessage}`. First failure short-circuits with `NOT READY`. Step 4 (`az-Confirm-AzDevOpsProjectMap`) is opt-in: it returns `Ok=$true` immediately when `$global:AzDevOpsProjectMap` is not defined, so single-project users skip it transparently. Step 7 (`az-Confirm-AzDevOpsQueryFiles`) seeds the three user-machine WIQL files under `~/.bashcuts-az-devops-app/config/queries/` (`epics.wiql`, `features.wiql`, `user-stories.wiql`) so subsequent `az-Sync-AzDevOpsCache` runs can build the hierarchy from customizable per-tier queries rather than an inline string.

```mermaid
flowchart TD
    Start([az-Connect-AzDevOps]) --> S1

    S1["Step 1 — az-Confirm-AzDevOpsCli<br/>uses Test-AzDevOpsCliPresent"]
    S2["Step 2 — az-Confirm-AzDevOpsExtension<br/>uses Test-AzDevOpsExtensionInstalled<br/>+ optional 'az extension add'"]
    S3["Step 3 — az-Confirm-AzDevOpsEnvVars<br/>reports $env:AZ_USER_EMAIL / $env:AZ_AREA<br/>(informational only — never blocks)"]
    S4["Step 4 — az-Confirm-AzDevOpsProjectMap<br/>opt-in $global:AzDevOpsProjectMap<br/>+ optional az-Use-AzDevOpsProject prompt"]
    S5["Step 5 — az-Confirm-AzDevOpsLogin<br/>uses Test-AzDevOpsLoggedIn<br/>+ optional 'az login'"]
    S6["Step 6 — az-Set-AzDevOpsDefaults<br/>'az devops configure --defaults'"]
    S7["Step 7 — az-Confirm-AzDevOpsQueryFiles<br/>seeds ~/.bashcuts-az-devops-app/config/queries/{epics,features,user-stories}.wiql<br/>via Initialize-AzDevOpsQueryFiles"]
    S8["Step 8 — az-Confirm-AzDevOpsSmokeQuery<br/>uses Invoke-AzDevOpsSmokeQuery"]

    Ready([READY])
    NotReady([NOT READY — blocked at step N])

    S1 -- Ok --> S2
    S2 -- Ok --> S3
    S3 -- Ok --> S4
    S4 -- Ok --> S5
    S5 -- Ok --> S6
    S6 -- Ok --> S7
    S7 -- Ok --> S8
    S8 -- Ok --> Ready

    S1 -- fail --> NotReady
    S2 -- fail --> NotReady
    S3 -- fail --> NotReady
    S4 -- fail --> NotReady
    S5 -- fail --> NotReady
    S6 -- fail --> NotReady
    S7 -- fail --> NotReady
    S8 -- fail --> NotReady

    classDef step fill:#1f3a5f,stroke:#4ea3ff,color:#fff
    class S1,S2,S3,S4,S5,S6,S7,S8 step
```

Helpers used by every step:

- `New-AzDevOpsStepResult` — builds the `{Ok, FailMessage}` PSCustomObject
- `Read-AzDevOpsYesNo` — default-yes Y/n prompt for remediation offers

---

## 3. `az-Test-AzDevOpsAuth` — silent diagnostic chain

Used by the read/sync callers (`az-Sync-AzDevOpsCache`, `az-Initialize-AzDevOpsSchema`, `az-Test-AzDevOpsSchema`) at the top of every command to bail early if the environment regressed via `Assert-AzDevOpsAuthOrAbort`. No I/O — pure boolean. The `az-New-AzDevOps*` creators deliberately opt out (`Test-AzDevOpsCreateGate` → `Assert-AzDevOpsAuthOrAbort -SkipLiveProbe`): they skip this live smoke query because their own `az boards work-item create` call is the authoritative auth check, so an upfront probe would be a redundant `az` round-trip.

```mermaid
flowchart TD
    Start([az-Test-AzDevOpsAuth]) --> A{Test-AzDevOpsCliPresent?}
    A -- no --> F([return $false])
    A -- yes --> C{Invoke-AzDevOpsSmokeQuery<br/>returns count?}
    C -- $null --> F
    C -- count --> T([return $true])

    classDef ok fill:#0d4f24,stroke:#2ecc71,color:#fff
    classDef bad fill:#5a1a1a,stroke:#e74c3c,color:#fff
    class T ok
    class F bad
```

Skipped on purpose: `Test-AzDevOpsExtensionInstalled` and `Test-AzDevOpsLoggedIn`. The smoke `az boards query` call already exercises both transitively, and a single failing query is faster + more authoritative than three individual probes. Env vars are no longer probed here either — `AZ_DEVOPS_ORG` / `AZ_PROJECT` were retired in favor of `az devops configure --defaults`, so the smoke query alone is sufficient.

---

## 4. `az-Sync-AzDevOpsCache` — dataset fan-out

Five datasets, one orchestrator. Each dataset descriptor declares its `Fetch` scriptblock, `Counter`, and target file path; `Invoke-AzDevOpsAzDataset` is the single sync helper that runs them all (per the CLAUDE.md extract-repeated-branches rule).

```mermaid
flowchart TD
    Entry([az-Sync-AzDevOpsCache]) --> Auth{az-Test-AzDevOpsAuth}
    Auth -- false --> AbortAuth([abort: 'Run az-Connect-AzDevOps'])
    Auth -- true --> Init["Initialize-AzDevOpsCacheDir<br/>(creates dir)"]
    Init --> Datasets["Get-AzDevOpsSyncDatasets<br/>builds 5 descriptors"]

    Datasets --> Loop{foreach dataset}

    subgraph Each["Invoke-AzDevOpsAzDataset (per descriptor)"]
        direction TB
        Fetch["& $Fetch<br/>→ Invoke-AzDevOpsBoardsQuery<br/>or Get-AzDevOpsClassificationList"]
        Stopwatch["measure elapsed"]
        Branch{ExitCode == 0?}
        Parse["ConvertFrom-Json<br/>+ Counter scriptblock"]
        WriteFile["Write-AzDevOpsCacheFile<br/>(atomic .tmp → rename)"]
        StatusOk["New-AzDevOpsDatasetStatus 'ok'"]
        StatusErr["New-AzDevOpsDatasetStatus 'error'<br/>+ Write-AzDevOpsSyncStderr"]

        Fetch --> Stopwatch --> Branch
        Branch -- yes --> Parse --> WriteFile --> StatusOk
        Branch -- no --> StatusErr
    end

    Loop --> Each --> Loop
    Loop -- done --> Summary["Write last-sync.json<br/>{Timestamp, Counts, Datasets}"]
    Summary --> Log["Write-AzDevOpsSyncLog 'sync complete'"]
    Log --> Banner["print Cache: <dir><br/>+ partial-failure banner if any"]

    subgraph Datasets5["Five datasets (descriptors)"]
        direction LR
        D1["assigned<br/>WIQL System.AssignedTo = @Me"]
        D2["mentions<br/>WIQL System.History Contains '@email'"]
        D3["hierarchy<br/>Invoke-AzDevOpsHierarchyQueries<br/>(reads ~/.bashcuts-az-devops-app/config/queries/{epics,features,user-stories}.wiql,<br/>substitutes {{AZ_AREA}}, fires one WIQL per tier,<br/>merges into Epic + Feature + Story flat + System.Parent)"]
        D4["iterations<br/>Get-AzDevOpsClassificationList -Kind Iteration<br/>→ az boards iteration project list --depth 5"]
        D5["areas<br/>Get-AzDevOpsClassificationList -Kind Area<br/>→ az boards area project list --depth 5"]
    end

    Datasets -.descriptors.-> Datasets5
```

Atomic write pattern (`Write-AzDevOpsCacheFile`): `Set-Content` to `<path>.tmp`, then `Move-Item -Force` over the real path — partial files never replace good cache.

---

## 5. Cache consumers (`az-Get-AzDevOpsAssigned/Mentions` and `az-Open-Assigned/Mention`)

The two parallel pairs share private helpers (extracted under "Shared scaffolding" per CLAUDE.md). They never call `az` — purely cache reads.

```mermaid
sequenceDiagram
    autonumber
    actor User
    participant GetA as az-Get-AzDevOpsAssigned
    participant ReadA as Read-AzDevOpsAssignedCache
    participant ReadJ as Read-AzDevOpsJsonCache
    participant Conv as ConvertFrom-AzDevOpsAssignedItem
    participant Banner as Write-AzDevOpsStaleBanner
    participant Filter as Select-AzDevOpsActiveItems
    participant Sort as Sort-AzDevOpsByDateDesc
    participant Title as Format-AzDevOpsTruncatedTitle
    participant Show as Show-AzDevOpsRows
    participant Cache as assigned.json

    User->>GetA: az-Get-AzDevOpsAssigned -State Active
    GetA->>ReadA: ReadAssigned()
    ReadA->>ReadJ: Read-AzDevOpsJsonCache(path, converter)
    ReadJ->>Cache: Get-Content -Raw
    Cache-->>ReadJ: JSON
    ReadJ->>Conv: per-row converter
    Conv-->>ReadJ: PSCustomObject[]
    ReadJ-->>ReadA: items
    ReadA-->>GetA: items

    GetA->>Banner: WARNING stale (if last-sync > 6h)
    GetA->>Filter: filter by -State or active default
    Filter-->>GetA: filtered[]
    GetA->>Sort: newest-first by AssignedAt (or MentionedAt)
    Sort-->>GetA: sorted[]
    GetA->>Title: title-column projection
    Title-->>GetA: rows
    GetA->>Show: -PassThru (Out-ConsoleGridView<br/>or Format-Table fallback)
    Show-->>User: selected rows / rendered table
```

Open-by-id flow re-uses the same cache + a different last-mile helper:

```mermaid
flowchart LR
    A([az-Open-Assigned 12345]) --> RC[Read-AzDevOpsAssignedCache]
    RC --> Find["Find-AzDevOpsCachedWorkItem<br/>(id lookup + miss-hint)"]
    Find -- miss --> Hint([print 'run az-Get-AzDevOpsAssigned' + LASTEXITCODE=1])
    Find -- hit --> Open["az-Open-WorkItemById<br/>(env-var guard + URL build)"]
    Open --> SP["Start-Process<br/>$env:AZ_DEVOPS_ORG/$env:AZ_PROJECT/_workitems/edit/12345"]
```

`az-Open-Mention` is structurally identical, just swaps `Read-AzDevOpsMentionsCache` and the `-Description 'mentions'` label.

---

## 6. `az-Show-Tree` — Epic → Feature → requirement-tier render

Pure cache read, no `az`. Each of the three hierarchy WIQLs (epics / features / user-stories) selects `[System.Parent]` per row, and `Invoke-AzDevOpsHierarchyQueries` merges them into a single flat array on disk, so a single pass into a `byParent` hashtable is enough — no follow-up queries.

The leaf-tier filter checks `Type -in $script:AzDevOpsRequirementTypes` — the four stock requirement-tier names across process templates (`User Story` on Agile, `Product Backlog Item` on Scrum, `Requirement` on CMMI, `Issue` on Basic) — so the same render code works on every template the user-stories WIQL fetches via `Microsoft.RequirementCategory`.

```mermaid
flowchart TD
    Start([az-Show-Tree]) --> Read[Read-AzDevOpsHierarchyCache]
    Read --> Banner[Write-AzDevOpsStaleBanner]
    Banner --> Index["build $byParent hashtable<br/>key = ParentId or 0"]
    Index --> Epics["filter Type='Epic', sort by Id"]
    Epics --> Grid{Test-AzDevOpsGridAvailable?}
    Grid -- yes --> Pfx["Get-AzDevOpsWorkItemUrlPrefix<br/>(once, not per row)"]
    Pfx --> RowsFn["Get-AzDevOpsTreeRows<br/>(Type/Id/Title/State/Depth/Path/Url)"]
    RowsFn --> Show["Show-AzDevOpsRows<br/>→ Out-ConsoleGridView"]
    Show --> Action[Invoke-AzDevOpsRowAction]
    Action --> Multi{"2+ rows selected?"}
    Multi -- yes --> OpenAll["Invoke-AzDevOpsOpenAllSelected<br/>Read-AzDevOpsYesNo [y/N]"]
    OpenAll -- yes --> OpenSel
    OpenAll -- "no (incl. Enter)" --> PerRow
    Multi -- no --> PerRow
    PerRow["per selected row<br/>(Get-AzDevOpsRowId)"] --> Choice{Read-AzDevOpsRowActionChoice}
    Choice -- open --> OpenSel["az-Open-WorkItemById"]
    Choice -- create --> Child["New-AzDevOpsChildForRow<br/>(Get-AzDevOpsChildTypeFor →<br/>az-New-AzDevOpsFeature / UserStory / az-New-Task)"]
    Choice -- skip --> NoOp([skip])
    Grid -- no --> ForEpic{foreach epic}
    ForEpic --> NodeE["Format-AzDevOpsTreeNode -Depth 0<br/>uses Get-AzDevOpsTreeIcon (Epic icon)<br/>+ Get-AzDevOpsTreeIndent"]
    NodeE --> Features["children where Type='Feature'"]
    Features --> NoFeat{any?}
    NoFeat -- no --> Empty["print '(no features)'"]
    NoFeat -- yes --> ForFeat{foreach feature}
    ForFeat --> NodeF["Format-AzDevOpsTreeNode -Depth 1<br/>(Feature icon)"]
    NodeF --> Stories["children where Type ∈ $script:AzDevOpsRequirementTypes<br/>(User Story / Product Backlog Item / Requirement / Issue)"]
    Stories --> ForStory{foreach story}
    ForStory --> NodeS["Format-AzDevOpsTreeNode -Depth 2<br/>(Story icon)"]
    NodeS --> ForStory
    ForStory --> ForFeat
    ForFeat --> ForEpic
```

Icon helper `Get-AzDevOpsTreeIcon` returns named codepoint locals (`$iconEpic`, `$iconFeature`, `$iconStory`) — never raw `[char]0x...` literals at the call site.

The grid branch's post-selection step (`Invoke-AzDevOpsRowAction`) is shared by `az-Show-Board`, `az-Show-Epics`, `az-Show-Features`, and `az-Show-Orphans` too; `az-Show-Features` passes `-DefaultType 'Feature'` and `az-Show-Epics` passes `-DefaultType 'Epic'` since their rows omit a Type column. When more than one row is selected it first offers a single bulk-open gate (`Invoke-AzDevOpsOpenAllSelected`, a `[y/N]` prompt defaulting to no via `Read-AzDevOpsYesNo -DefaultNo`); a yes opens every selected row and returns, while no (or a bare Enter) falls through to the per-row loop. For each selected work-item row it then offers open-in-browser or create-the-hierarchical-child (Epic→Feature, Feature→User Story, requirement-tier→Task). The shared `Get-AzDevOpsRowId` helper extracts each row's work-item id (or 0 when the row carries none) for both the bulk and per-row paths. `az-Show-Areas` / `az-Show-Iterations` use the parallel `Invoke-AzDevOpsClassificationAction`, which offers a Boards-hub open only (classification rows carry no work-item id).

---

## 7. `az-New-AzDevOpsUserStory` — interactive create flow

Interactive walk-through with all-optional parameters: every prompt is skipped if its parameter was supplied, so the function is also script-callable.

```mermaid
flowchart TD
    Start([az-New-AzDevOpsUserStory]) --> Auth{Test-AzDevOpsCreateGate<br/>auth memo or az-CLI-present<br/>no live smoke query}
    Auth -- false --> Abort1([abort: 'Run az-Connect-AzDevOps'])
    Auth -- true --> Email{$env:AZ_USER_EMAIL set?}
    Email -- no --> Abort2([abort])
    Email -- yes --> Hier[Read-AzDevOpsHierarchyCache]
    Hier -- null --> Abort3([abort: cache missing])
    Hier -- ok --> Title{Title param?}

    Title -- no --> ReadTitle["Read-Host 'title'"]
    Title -- yes --> Desc{Description param?}
    ReadTitle --> TitleEmpty{empty?}
    TitleEmpty -- yes --> Abort4([abort])
    TitleEmpty -- no --> Desc

    Desc -- no --> ReadDesc["Read-AzDevOpsUserStoryDescription<br/>(As-a / I-want / so-that prompts)"]
    Desc -- yes --> Prio{Priority 1-4?}
    ReadDesc --> Prio
    Prio -- no --> ReadPrio[Read-AzDevOpsPriority]
    Prio -- yes --> SP{StoryPoints >=0?}
    ReadPrio --> SP
    SP -- no --> ReadSP[Read-AzDevOpsStoryPoints]
    SP -- yes --> AC{AC param?}
    ReadSP --> AC
    AC -- no --> ReadAC[Read-AzDevOpsAcceptanceCriteria]
    AC -- yes --> Feat{FeatureId >=0?}
    ReadAC --> Feat
    Feat -- no --> PickFeat["Read-AzDevOpsFeaturePick<br/>(active Features from hierarchy.json)<br/>→ Read-AzDevOpsGridPick (Out-ConsoleGridView)<br/>or numbered menu fallback"]
    Feat -- yes --> Iter{Iteration param?}
    PickFeat --> Iter
    Iter -- no --> PickIter["Read-AzDevOpsKindPick -Kind 'Iteration'<br/>cache or Invoke-AzDevOpsClassificationLive<br/>→ Read-AzDevOpsGridPick (Out-ConsoleGridView)"]
    Iter -- yes --> Area{Area param?}
    PickIter --> Area
    Area -- no --> PickArea["Read-AzDevOpsKindPick -Kind 'Area'<br/>→ Read-AzDevOpsGridPick (Out-ConsoleGridView)"]
    Area -- yes --> Create
    PickArea --> Create

    Create["Invoke-AzDevOpsWorkItemCreate<br/>→ New-AzDevOpsWorkItem<br/>→ az boards work-item create"]
    Create --> CreateOk{Ok?}
    CreateOk -- no --> CreateFail([STEP FAILED])
    CreateOk -- yes --> Link{FeatureId > 0?}
    Link -- yes --> InvokeLink["Invoke-AzDevOpsParentLink<br/>→ Add-AzDevOpsWorkItemRelation<br/>→ az boards work-item relation add"]
    InvokeLink --> Open
    Link -- no --> Orphan["print '(no parent linked)'"]
    Orphan --> Open
    Open{NoOpen switch?}
    Open -- no --> SP2["Start-Process $newUrl"]
    Open -- yes --> Done
    SP2 --> Done([return $newId])
```

Auth gate: the create commands route through `Test-AzDevOpsCreateGate`, which calls `Assert-AzDevOpsAuthOrAbort -SkipLiveProbe`. Unlike `az-Sync-AzDevOpsCache` / the schema commands, the creators do **not** fire the live `az boards query` @Me smoke test up front — the `az boards work-item create` call that follows is itself the authoritative auth check, so a separate probe would be a redundant `az` round-trip. A valid in-session auth memo still short-circuits the gate; a stale memo only re-confirms the `az` CLI is on PATH (a local `Get-Command` lookup, no `az` process), and a genuinely-unauthed session surfaces the failure through the create's own `STEP FAILED` path.

Picker fallback: if `iterations.json` / `areas.json` aren't in the cache yet (user upgraded but hasn't synced), `Read-AzDevOpsKindPick` calls `Invoke-AzDevOpsClassificationLive` and prints a one-line "(run az-Sync-AzDevOpsCache to make this instant)" hint.

---

## 8. `az-New-AzDevOpsFeature` — interactive Feature create + child-story hand-off

Tier-one-up counterpart to `az-New-AzDevOpsUserStory`. Picks a parent Epic from the cached hierarchy, fills `title / description (Summary + Business Value) / priority / area / iteration`, creates the Feature, links to the Epic, then asks "Add child stories now?" — on yes hands off to `az-New-AzDevOpsFeatureStories -ParentId $newFeatureId` with the captured `area / iteration` pre-seeded. Story points are intentionally skipped (Features don't carry story points in default Agile / Scrum templates).

```mermaid
flowchart TD
    Start([az-New-AzDevOpsFeature]) --> Auth{Test-AzDevOpsCreateGate<br/>auth memo or az-CLI-present<br/>no live smoke query}
    Auth -- false --> Abort1([abort])
    Auth -- true --> Email{$env:AZ_USER_EMAIL set?}
    Email -- no --> Abort2([abort])
    Email -- yes --> Hier[Read-AzDevOpsHierarchyCache]
    Hier --> Title{Title param?}
    Title -- no --> ReadTitle["Read-Host 'title'"]
    Title -- yes --> Desc{Description param?}
    ReadTitle --> Desc
    Desc -- no --> ReadDesc["Read-AzDevOpsFeatureDescription<br/>(Summary + Business Value prompts)"]
    Desc -- yes --> Prio{Priority 1-4?}
    ReadDesc --> Prio
    Prio -- no --> ReadPrio[Read-AzDevOpsPriority]
    Prio -- yes --> Epic{ParentEpicId >= 0?}
    ReadPrio --> Epic
    Epic -- no --> PickEpic["Read-AzDevOpsEpicPick<br/>-> Read-AzDevOpsParentPick<br/>(active Epics from hierarchy.json)"]
    Epic -- yes --> Iter{Iteration param?}
    PickEpic --> Iter
    Iter -- no --> PickIter[Read-AzDevOpsKindPick -Kind 'Iteration']
    Iter -- yes --> Area{Area param?}
    PickIter --> Area
    Area -- no --> PickArea[Read-AzDevOpsKindPick -Kind 'Area']
    Area -- yes --> Create
    PickArea --> Create

    Create["Invoke-AzDevOpsWorkItemCreate -Type 'Feature'<br/>(StoryPoints field omitted)"]
    Create --> CreateOk{Ok?}
    CreateOk -- no --> CreateFail([STEP FAILED])
    CreateOk -- yes --> Link{ParentEpicId > 0?}
    Link -- yes --> InvokeLink["Invoke-AzDevOpsParentLink"]
    Link -- no --> Orphan["print '(orphan Feature)'"]
    InvokeLink --> Open
    Orphan --> Open
    Open{NoOpen switch?}
    Open -- no --> SP2["Start-Process $newUrl"]
    Open -- yes --> Handoff
    SP2 --> Handoff

    Handoff{NoChildStoriesPrompt?}
    Handoff -- yes --> Done
    Handoff -- no --> AskKids[Read-AzDevOpsYesNo 'Add child stories now?']
    AskKids -- no --> Done
    AskKids -- yes --> Loop["az-New-AzDevOpsFeatureStories -ParentId $newId<br/>-Iteration $Iteration -Area $Area"]
    Loop --> Done([return $newId])
```

DRY note: `Read-AzDevOpsEpicPick` and `Read-AzDevOpsFeaturePick` are 2-line wrappers over a shared `Read-AzDevOpsParentPick -ParentType 'Epic'|'Feature'` helper (per CLAUDE.md "extract repeated branches"). The single-shot story creator's parent picker did not regress — it still exists as `Read-AzDevOpsFeaturePick`.

---

## 9. `az-New-AzDevOpsFeatureStories` — batch child-story loop

Batch counterpart to `az-New-AzDevOpsUserStory`. Captures parent / area / iteration **once** at the top, then loops per-story prompts (title, AC, priority, story points) until the user submits an empty title or answers `n` to "Add another?". Mid-batch failures don't abort. Each child create runs through the same `Invoke-AzDevOpsWorkItemCreate` + `Invoke-AzDevOpsParentLink` pair the single-shot creator uses, so failure modes / schema enforcement stay identical.

```mermaid
flowchart TD
    Start([az-New-AzDevOpsFeatureStories -ParentId N]) --> Auth{Test-AzDevOpsCreateGate<br/>auth memo or az-CLI-present<br/>no live smoke query}
    Auth -- false --> Abort1([abort: 'Run az-Connect-AzDevOps'])
    Auth -- true --> Email{$env:AZ_USER_EMAIL set?}
    Email -- no --> Abort2([abort])
    Email -- yes --> Hier[Read-AzDevOpsHierarchyCache]
    Hier -- null --> Abort3([abort: cache missing])
    Hier -- ok --> Validate[Test-AzDevOpsParentIsFeature]
    Validate -- not-found / not-Feature --> Abort4([abort: clear message])
    Validate -- ok --> PickIter["Read-AzDevOpsKindPick -Kind 'Iteration'<br/>(skipped if -Iteration param)"]
    PickIter --> PickArea["Read-AzDevOpsKindPick -Kind 'Area'<br/>(skipped if -Area param)"]
    PickArea --> Loop

    Loop[Story loop iteration N] --> ReadTitle["Read-Host 'Story title (Enter to finish batch)'"]
    ReadTitle --> EmptyTitle{empty?}
    EmptyTitle -- yes --> Summary
    EmptyTitle -- no --> ReadAC[Read-AzDevOpsAcceptanceCriteria]
    ReadAC --> ReadPrio["Read-AzDevOpsPriority -Previous $previousPriority<br/>(Enter reuses last answer)"]
    ReadPrio --> ReadSP["Read-AzDevOpsStoryPoints -Previous $previousStoryPoints"]
    ReadSP --> Create["Invoke-AzDevOpsWorkItemCreate<br/>+ Invoke-AzDevOpsParentLink"]
    Create --> CreateOk{Ok?}
    CreateOk -- no --> FailCount["fail counter ++<br/>title -> failedTitles"]
    CreateOk -- yes --> CarryFwd["createdIds += newId<br/>previousPriority / previousStoryPoints = answers"]
    FailCount --> Continue
    CarryFwd --> Continue
    Continue[Read-AzDevOpsBatchContinue] --> Decide{stop / continue / change?}
    Decide -- stop --> Summary
    Decide -- continue --> Loop
    Decide -- change --> Repick["Read-AzDevOpsKindPick -Kind 'Iteration'<br/>Read-AzDevOpsKindPick -Kind 'Area'<br/>(carried forward into the next story)"]
    Repick --> Loop

    Summary["one-line summary:<br/>'Created N child stories under Feature #P: id1, id2, ...'<br/>(or 'Created N, Failed M' on partial failure)"]
    Summary --> Urls[one URL per created story]
    Urls --> Done([return [int[]] $createdIds])
```

Helpers introduced for this flow (named in CLAUDE.md's "extract repeated branches" + "name your magic strings" rules):

- `Get-AzDevOpsReuseHint` — formats the `(Enter to reuse '<value>')` suffix; reused by `Read-AzDevOpsPriority` + `Read-AzDevOpsStoryPoints`.
- `Read-AzDevOpsBatchContinue` — three-way `y/N/c` loop-control prompt.
- `Test-AzDevOpsParentIsFeature` — pre-loop validation against `hierarchy.json`.

---

## 10. `Start-AzDevOpsBackgroundSync` — silent on-open refresh

Runs on every shell open — invoked from `powcuts_home.ps1` after all `azdevops_*.ps1` files are dot-sourced, so `Get-AzDevOpsActiveProjectSlug` is defined and the staleness check targets the active project's cache. A cheap foreground gate decides whether to spawn a detached, hidden `pwsh` running `az-Sync-AzDevOpsCache`. The network auth check is intentionally left to the child (`az-Sync-AzDevOpsCache` → `Assert-AzDevOpsAuthOrAbort`) so the interactive prompt is never blocked by a smoke query. The child inherits `AZ_DEVOPS_AUTOSYNC_CHILD`, so its own profile load skips re-spawning — no cascade.

```mermaid
flowchart TD
    Open([shell open: azdevops_sync.ps1 dot-sourced]) --> Bg([Start-AzDevOpsBackgroundSync])
    Bg --> C1{AZ_DEVOPS_AUTOSYNC_CHILD set?}
    C1 -- yes --> Skip([return — no-op])
    C1 -- no --> C2{AZ_DEVOPS_NO_AUTOSYNC set?}
    C2 -- yes --> Skip
    C2 -- no --> C3{az present?}
    C3 -- no --> Skip
    C3 -- yes --> C4{cache stale or missing?}
    C4 -- no --> Skip
    C4 -- yes --> C5{autosync.lock active < 30 min?}
    C5 -- yes --> Skip
    C5 -- no --> Spawn["write autosync.lock<br/>set AZ_DEVOPS_AUTOSYNC_CHILD<br/>Start-Process pwsh -WindowStyle Hidden<br/>-Command az-Sync-AzDevOpsCache"]
    Spawn --> Child([detached child loads $profile,<br/>auth-gates, runs az-Sync-AzDevOpsCache,<br/>logs to sync.log])

    classDef shared fill:#3a2a5f,stroke:#a070ff,color:#fff
    class C1,C2,C3,C4,C5 shared
```

Private helpers:

- `Get-AzDevOpsAutoSyncChildVar` → `'AZ_DEVOPS_AUTOSYNC_CHILD'` (loop guard for the spawned child)
- `Get-AzDevOpsAutoSyncOptOutVar` → `'AZ_DEVOPS_NO_AUTOSYNC'` (user opt-out)
- `Get-AzDevOpsAutoSyncLockPath` → `<cache dir>/autosync.lock`
- `Get-AzDevOpsAutoSyncLockMaxAgeMinutes` → `30`
- `Test-AzDevOpsAutoSyncLockActive` → `$true` when the lock is younger than the TTL
- `Get-AzDevOpsPlatform` → `'Windows' | 'Posix' | 'Unknown'` (retained — still used by `azdevops_schema.ps1`)

---

## 11. `az-Start-UnplannedWork` — firefighting session loop + debrief

Free-for-all companion to the Pomodoro timer for work that can't be time-boxed. Each day rolls up under one **Unplanned Work — yyyy-MM-dd** User Story; every firefight is a child Task with its own debrief. PowerShell-only (the Windows balloon reminder + key-poll loop have no bash counterpart). `New-UnplannedWorkDebrief` is the end-of-day roll-up over a local per-day ledger.

The session starts the instant you've named the firefight: the daily story and child Task are **created at the end** (debrief time), not up front, so a burning fire isn't blocked on `az boards` round-trips. The daily-story id is cached per day (`unplanned-story-YYYY-MM-DD.json`) so the next firefight grabs it with no WIQL lookup and no risk of duplicate daily stories. If the create fails after the session, `Show-UnplannedCapturedItemsFallback` prints the captured items so the work isn't lost.

```mermaid
flowchart TD
    Start([az-Start-UnplannedWork]) --> Gate{Test-AzDevOpsCreateGate}
    Gate -- false --> Abort1([abort])
    Gate -- true --> AskTitle["prompt firefight title<br/>(Read-Host)"]
    AskTitle --> PlatCheck{Test-WpfIsWindows?}

    PlatCheck -- Windows --> WpfLoop["Show-WpfStopwatch<br/>(WPF circular overlay)<br/>Log Item / Create New Story / Stop"]
    PlatCheck -- macOS/Linux --> Loop[session loop — Read-UnplannedKeyPress poll]

    Loop -- Space --> LogItem["Read-Host item<br/>append {Time, Text}"]
    LogItem --> Loop
    Loop -- every ReminderMinutes --> Balloon["Show-UnplannedReminder<br/>(New-UnplannedBalloon NotifyIcon)"]
    Balloon --> Loop
    Loop -- Esc/Q --> Daily
    WpfLoop -- Stop/right-click --> Daily

    Daily["Get-UnplannedWorkDailyStory<br/>(deferred to stop)"] --> CacheCheck["Get-UnplannedCachedStoryId<br/>unplanned-story-YYYY-MM-DD.json"]
    CacheCheck -- hit --> HaveStory[daily story id]
    CacheCheck -- miss --> Find["Find-UnplannedWorkStoryId<br/>WIQL by title (+ AZ_AREA)<br/>→ Invoke-AzDevOpsBoardsQuery"]
    Find -- found --> SaveStory["Save-UnplannedCachedStoryId"]
    Find -- 0 --> NewStory["New-UnplannedWorkStory<br/>→ Invoke-AzDevOpsWorkItemCreate<br/>→ az boards work-item create (User Story)"]
    NewStory --> SaveStory
    SaveStory --> HaveStory

    HaveStory -- story id 0 --> Fallback["Show-UnplannedCapturedItemsFallback<br/>(print items, don't lose them)"]
    HaveStory -- ok --> Task["New-UnplannedWorkTask<br/>→ New-AzDevOpsWorkItem (Task)<br/>→ Invoke-AzDevOpsParentLink"]
    Task -- create failed --> Fallback
    Fallback --> Done
    Task -- ok --> Debrief[Invoke-UnplannedDebrief]

    Debrief --> FlushDesc["Format-UnplannedItemsDescription<br/>→ Set-AzDevOpsWorkItemField<br/>→ az boards work-item update (System.Description)"]
    FlushDesc --> AskFuture{future-feature opportunity?}
    AskFuture -- yes --> MaybeStory["(opt) az-New-AzDevOpsUserStory"]
    AskFuture -- no --> Tag
    MaybeStory --> Tag
    Tag["Select-AzDevOpsMention<br/>type-to-filter roster picker (Name+Email)<br/>→ Format-AzDevOpsMentionAnchor (data-vss-mention)"]
    Tag --> PostComment
    PostComment["Format-UnplannedDebriefComment<br/>(+ @-mention anchors)<br/>→ Add-AzDevOpsDiscussionComment<br/>→ az boards work-item update (--discussion)"]
    PostComment --> Ledger["Add-UnplannedLedgerEntry<br/>unplanned-YYYY-MM-DD.json"]
    Ledger --> Done([end])

    DebriefDay([New-UnplannedWorkDebrief]) --> ReadLedger["read day ledger<br/>Measure-Object -Property Minutes"]
    ReadLedger --> TagDay["Select-AzDevOpsMention<br/>(same shared roster picker)"]
    TagDay --> Rollup["Format-UnplannedDailyDebrief<br/>(+ @-mention anchors)<br/>→ Add-AzDevOpsDiscussionComment on daily story"]
    Rollup --> Done2([end])

    SyncTeam(["az-Sync-AzDevOpsTeam"]) --> ResolveTeam["Sync-AzDevOpsTeam<br/>Select-AzDevOpsTeamFromCli → Get-AzDevOpsTeamList<br/>→ Get-AzDevOpsTeamMemberList (az devops team list-member)<br/>→ ConvertFrom-AzDevOpsTeamMemberRow<br/>+ $env:AZ_TEAM supplement → Resolve-AzDevOpsTeamMember → Get-AzDevOpsIdentity"]
    ResolveTeam --> TeamCache["Save-AzDevOpsTeamCache<br/>team.json"]
    TeamCache --> Done3([end])

    classDef io fill:#5a3a1a,stroke:#ffaa55,color:#fff
    class CacheCheck,Find,NewStory,SaveStory,Task,FlushDesc,PostComment,Ledger,Rollup,ResolveTeam,TeamCache io
```

Capture lands in two places per firefight: the accumulated bullet items flush to the Task **description** once at stop, and a single **discussion comment** carries the time spent, debrief notes, and any future-feature opportunity. Before each comment posts, `Select-AzDevOpsMention` offers a type-to-filter picker over the cached team roster (`team.json`). That roster and picker are **shared** — they live in `azdevops_team.ps1` and the Pomodoro timer's debrief (`pow_timer.ps1`) tags through the same surface. `az-Sync-AzDevOpsTeam` builds the roster primarily from a **project team's members** (`az devops team list-member`, which returns name/email/identity-GUID in one call), optionally supplemented by `$env:AZ_TEAM` (';'/','-separated emails/names resolved individually via `Get-AzDevOpsIdentity`). Picked teammates are injected as real `data-vss-mention` anchors so they're notified. Tagging is optional — an empty pick (or an un-synced roster) posts the debrief unchanged. Pure-UI helpers (`Show-UnplannedStatus`, `Format-UnplannedElapsed`, `Read-UnplannedYesNo`) are session-internal and omitted from the dependency map below.

---

## 12. Function dependency map

Public functions on the left, private helpers on the right. Helpers under "Shared scaffolding" exist specifically because their bodies were duplicated across the parallel `Get-/Open-` pairs. The "Multi-project resolver layer" cluster collects the opt-in `$global:AzDevOpsProjectMap` switcher (`az-Use-/Show-/Get-AzDevOpsProject(s)`) plus every `Resolve-AzDevOpsType*` helper consumed by the `az-New-*` creators; when no map is defined, all resolvers return `$null`/`-1`/`@()` and the create paths fall through to today's prompt-driven flow.

```mermaid
graph LR
    classDef pub fill:#1f3a5f,stroke:#4ea3ff,color:#fff
    classDef priv fill:#3a3a3a,stroke:#888,color:#ddd
    classDef io fill:#5a3a1a,stroke:#ffaa55,color:#fff

    Connect(["az-Connect-AzDevOps"]):::pub
    TestAuth(["az-Test-AzDevOpsAuth"]):::pub
    Sync(["az-Sync-AzDevOpsCache"]):::pub
    Status(["az-Get-AzDevOpsCacheStatus"]):::pub
    BgSync["Start-AzDevOpsBackgroundSync"]:::priv
    GetA(["az-Get-AzDevOpsAssigned"]):::pub
    OpenA(["az-Open-Assigned"]):::pub
    GetM(["az-Get-AzDevOpsMentions"]):::pub
    OpenM(["az-Open-Mention"]):::pub
    Tree(["az-Show-Tree"]):::pub
    Board(["az-Show-Board"]):::pub
    Epics(["az-Show-Epics"]):::pub
    Orphans(["az-Show-Orphans"]):::pub
    ShowAreas(["az-Show-Areas"]):::pub
    ShowIters(["az-Show-Iterations"]):::pub
    GetAreas(["az-Get-AzDevOpsAreas"]):::pub
    GetIters(["az-Get-AzDevOpsIterations"]):::pub
    FindArea(["az-Find-AzDevOpsArea"]):::pub
    FindIter(["az-Find-AzDevOpsIteration"]):::pub
    NewS(["az-New-AzDevOpsUserStory"]):::pub
    NewF(["az-New-AzDevOpsFeature"]):::pub
    NewSB(["az-New-AzDevOpsFeatureStories"]):::pub
    NewTask(["az-New-Task"]):::pub
    Find(["az-Find-AzDevOpsWorkItem"]):::pub
    OpenHWiql(["az-Open-HierarchyWiqls"]):::pub
    ShowFeats(["az-Show-Features"]):::pub

    %% Multi-project switcher (azdevops_projects.ps1)
    UseProj(["az-Use-AzDevOpsProject"]):::pub
    ShowProj(["az-Show-Project"]):::pub
    GetProjs(["az-Get-AzDevOpsProjects"]):::pub
    FindProj(["az-Find-AzDevOpsProject"]):::pub

    %% Unplanned work sessions (azdevops_unplanned.ps1)
    StartUW(["az-Start-UnplannedWork"]):::pub
    NewUWDebrief(["New-UnplannedWorkDebrief"]):::pub
    GetDaily[Get-UnplannedWorkDailyStory]:::priv
    UWGetCachedStory[Get-UnplannedCachedStoryId]:::priv
    UWSaveCachedStory[Save-UnplannedCachedStoryId]:::priv
    UWStoryCachePath[Get-UnplannedStoryCachePath]:::priv
    FindUW[Find-UnplannedWorkStoryId]:::priv
    NewUWStory[New-UnplannedWorkStory]:::priv
    NewUWTask[New-UnplannedWorkTask]:::priv
    UWFallback[Show-UnplannedCapturedItemsFallback]:::priv
    InvUWDebrief[Invoke-UnplannedDebrief]:::priv
    UWBalloon[New-UnplannedBalloon]:::priv
    WpfStopwatch[Show-WpfStopwatch]:::priv
    UWLedger[Add-UnplannedLedgerEntry]:::priv
    UWLedgerPath[Get-UnplannedLedgerPath]:::priv

    %% Team tagging — shared by the unplanned debriefs and the timer (azdevops_team.ps1)
    SyncUWTeam(["az-Sync-AzDevOpsTeam"]):::pub
    UWRosterSync[Sync-AzDevOpsTeam]:::priv
    UWTeamPick[Select-AzDevOpsTeamFromCli]:::priv
    UWTeamList[Get-AzDevOpsTeamList]:::priv
    UWTeamMembers[Get-AzDevOpsTeamMemberList]:::priv
    UWMemberRow[ConvertFrom-AzDevOpsTeamMemberRow]:::priv
    UWMemberRec[New-AzDevOpsTeamMemberRecord]:::priv
    UWGetTeam[Get-AzDevOpsTeam]:::priv
    UWRoster[Get-AzDevOpsTeamEnvRoster]:::priv
    UWResolve[Resolve-AzDevOpsTeamMember]:::priv
    UWTeamSave[Save-AzDevOpsTeamCache]:::priv
    UWTeamRead[Read-AzDevOpsTeamCache]:::priv
    UWTeamPath[Get-AzDevOpsTeamCachePath]:::priv
    UWMentionPick[Select-AzDevOpsMention]:::priv
    UWMentionMenu[Select-AzDevOpsMentionFromMenu]:::priv
    UWAnchor[Format-AzDevOpsMentionAnchor]:::priv
    UWMentionLine[Format-AzDevOpsMentionLine]:::priv

    %% Shared JSON-array cache plumbing (azdevops_paths.ps1)
    UWCachePath[Get-AzDevOpsCacheFilePath]:::priv
    UWJsonRead[Read-AzDevOpsJsonArrayCache]:::priv
    UWJsonSave[Save-AzDevOpsJsonArrayCache]:::priv

    %% Step helpers
    C1[az-Confirm-AzDevOpsCli]:::priv
    C2[az-Confirm-AzDevOpsExtension]:::priv
    C3[az-Confirm-AzDevOpsEnvVars]:::priv
    CMap[az-Confirm-AzDevOpsProjectMap]:::priv
    C4[az-Confirm-AzDevOpsLogin]:::priv
    C5[az-Set-AzDevOpsDefaults]:::priv
    C6[az-Confirm-AzDevOpsSmokeQuery]:::priv
    C7[az-Confirm-AzDevOpsQueryFiles]:::priv
    StepRes[New-AzDevOpsStepResult]:::priv
    YN[Read-AzDevOpsYesNo]:::priv

    %% Diagnostic helpers
    TCli[Test-AzDevOpsCliPresent]:::priv
    TExt[Test-AzDevOpsExtensionInstalled]:::priv
    TLog[Test-AzDevOpsLoggedIn]:::priv
    TSmoke[Invoke-AzDevOpsSmokeQuery]:::priv

    %% Cache infra
    Paths[Get-AzDevOpsCachePaths]:::priv
    PathsForSlug[Get-AzDevOpsCachePathsForSlug]:::priv
    InitDir[Initialize-AzDevOpsCacheDir]:::priv
    WriteFile[Write-AzDevOpsCacheFile]:::priv
    LogFn[Write-AzDevOpsSyncLog]:::priv
    Age[Get-AzDevOpsCacheAge]:::priv

    %% Sync helpers
    DSets[Get-AzDevOpsSyncDatasets]:::priv
    InvokeDS[Invoke-AzDevOpsAzDataset]:::priv
    Stderr1[Get-AzDevOpsFirstStderrLine]:::priv
    DStatus[New-AzDevOpsDatasetStatus]:::priv
    StderrW[Write-AzDevOpsSyncStderr]:::priv
    Measure[Measure-AzDevOpsClassificationNodes]:::priv

    %% Query config (azdevops_paths.ps1)
    QPaths[Get-AzDevOpsConfigPaths]:::priv
    QInit[Initialize-AzDevOpsQueryFiles]:::priv
    QWiql[Get-AzDevOpsWiql]:::priv
    QDefaults[Get-AzDevOpsQueryDefaults]:::priv
    QNames[Get-AzDevOpsHierarchyQueryNames]:::priv
    InvHier[Invoke-AzDevOpsHierarchyQueries]:::priv
    MkDir[New-AzDevOpsDirectoryIfMissing]:::priv

    %% Data-plane wrappers (azdevops_db.ps1)
    AzJson[Invoke-AzDevOpsAzJson]:::priv
    Boards[Invoke-AzDevOpsBoardsQuery]:::priv
    ClassList[Get-AzDevOpsClassificationList]:::priv
    NewWI[New-AzDevOpsWorkItem]:::priv
    AddRel[Add-AzDevOpsWorkItemRelation]:::priv
    AddDisc[Add-AzDevOpsDiscussionComment]:::priv
    SetField[Set-AzDevOpsWorkItemField]:::priv
    AssertTok[Assert-AzDevOpsFieldTokens]:::priv
    WITypeDef[Get-AzDevOpsWorkItemTypeDefinition]:::priv
    Identity[Get-AzDevOpsIdentity]:::priv
    ConfDef[Get-AzDevOpsConfiguredDefaults]:::priv

    %% Query echo helpers (azdevops_db.ps1)
    CmdDisp[Format-AzDevOpsCommandDisplay]:::priv
    CmdHead[Get-AzDevOpsCommandHeadline]:::priv
    EchoLn[Write-AzDevOpsQueryEcho]:::priv
    ConvNative[ConvertTo-AzDevOpsNativeArgList]:::priv

    %% Cross-cutting console spinner (pow_common.ps1)
    Spinner[Invoke-WithSpinner]:::priv

    %% Platform + on-open background-sync helpers
    Plat[Get-AzDevOpsPlatform]:::priv
    AutoChild[Get-AzDevOpsAutoSyncChildVar]:::priv
    AutoOptOut[Get-AzDevOpsAutoSyncOptOutVar]:::priv
    AutoLockPath[Get-AzDevOpsAutoSyncLockPath]:::priv
    AutoLockTtl[Get-AzDevOpsAutoSyncLockMaxAgeMinutes]:::priv
    AutoLockActive[Test-AzDevOpsAutoSyncLockActive]:::priv

    %% Read helpers
    ReadJson[Read-AzDevOpsJsonCache]:::priv
    ConvA[ConvertFrom-AzDevOpsAssignedItem]:::priv
    ConvM[ConvertFrom-AzDevOpsMentionItem]:::priv
    ConvH[ConvertFrom-AzDevOpsHierarchyItem]:::priv
    ReadA[Read-AzDevOpsAssignedCache]:::priv
    ReadM[Read-AzDevOpsMentionsCache]:::priv
    ReadH[Read-AzDevOpsHierarchyCache]:::priv
    ReadHForProj[Read-AzDevOpsHierarchyCacheForProject]:::priv

    %% Shared scaffolding
    Closed[Get-AzDevOpsClosedStates]:::priv
    Stale[Write-AzDevOpsStaleBanner]:::priv
    SelAct[Select-AzDevOpsActiveItems]:::priv
    Sort[Sort-AzDevOpsByDateDesc]:::priv
    Trunc[Format-AzDevOpsTruncatedTitle]:::priv
    TitleCol[Get-AzDevOpsTitleColumn]:::priv
    Find[Find-AzDevOpsCachedWorkItem]:::priv
    OpenUrl[az-Open-WorkItemById]:::pub
    WiUrl[Get-AzDevOpsWorkItemUrl]:::priv
    WiPfx[Get-AzDevOpsWorkItemUrlPrefix]:::priv
    MentDN[Get-AzDevOpsMentionedByDisplayName]:::priv

    %% Tree helpers
    Indent[Get-AzDevOpsTreeIndent]:::priv
    Icon[Get-AzDevOpsTreeIcon]:::priv
    NodeFmt[Format-AzDevOpsTreeNode]:::priv
    TreeRows[Get-AzDevOpsTreeRows]:::priv

    %% Grid presentation helpers (Out-ConsoleGridView)
    GridAvail[Test-AzDevOpsGridAvailable]:::priv
    GridUnavail[Write-AzDevOpsGridUnavailable]:::priv
    ShowRows[Show-AzDevOpsRows]:::priv
    GridPick[Read-AzDevOpsGridPick]:::priv
    StatusRows[Get-AzDevOpsCacheStatusRows]:::priv
    ActionRow[New-AzDevOpsActionRow]:::priv

    %% Interactive post-selection row actions (azdevops_views.ps1 + azdevops_classification.ps1)
    RowAction[Invoke-AzDevOpsRowAction]:::priv
    OpenAllSel[Invoke-AzDevOpsOpenAllSelected]:::priv
    RowId[Get-AzDevOpsRowId]:::priv
    RowChoice[Read-AzDevOpsRowActionChoice]:::priv
    ChildType[Get-AzDevOpsChildTypeFor]:::priv
    ChildForRow[New-AzDevOpsChildForRow]:::priv
    RowType[Resolve-AzDevOpsRowType]:::priv
    ClsAction[Invoke-AzDevOpsClassificationAction]:::priv

    %% URL builders (shared base)
    UrlBase[Get-AzDevOpsUrlBase]:::priv
    BoardsUrl[Get-AzDevOpsBoardsUrl]:::priv

    %% Show-Features cache source + empty-state hint
    FeatSrc[Read-AzDevOpsFeaturesSource]:::priv
    NoFeatHint[Write-AzDevOpsNoFeaturesHint]:::priv

    %% az-New-Task picker
    PStory[Read-AzDevOpsStoryPick]:::priv

    %% NewStory helpers
    ReadCls[Read-AzDevOpsClassificationCache]:::priv
    InvCls[Invoke-AzDevOpsClassificationLive]:::priv
    ToWIPath[ConvertTo-AzDevOpsWorkItemPath]:::priv
    ToCPaths[ConvertTo-AzDevOpsClassificationPaths]:::priv
    GetCPaths[Get-AzDevOpsClassificationPaths]:::priv
    Pri[Read-AzDevOpsPriority]:::priv
    Pts[Read-AzDevOpsStoryPoints]:::priv
    AC[Read-AzDevOpsAcceptanceCriteria]:::priv
    USDesc[Read-AzDevOpsUserStoryDescription]:::priv
    FeatDesc[Read-AzDevOpsFeatureDescription]:::priv
    PFeat[Read-AzDevOpsFeaturePick]:::priv
    PEpic[Read-AzDevOpsEpicPick]:::priv
    PParent[Read-AzDevOpsParentPick]:::priv
    PCls[Read-AzDevOpsClassificationPick]:::priv
    PKind[Read-AzDevOpsKindPick]:::priv
    InvCreate[Invoke-AzDevOpsWorkItemCreate]:::priv
    InvLink[Invoke-AzDevOpsParentLink]:::priv

    %% Batch-creator helpers (az-New-AzDevOpsFeatureStories)
    ReuseHint[Get-AzDevOpsReuseHint]:::priv
    BatchCont[Read-AzDevOpsBatchContinue]:::priv
    ParentTest[Test-AzDevOpsParentIsFeature]:::priv

    %% Auth abort prologue
    AuthAbort[Assert-AzDevOpsAuthOrAbort]:::priv

    %% Shared creator scaffolding (consumed by all three az-New-AzDevOps* creators)
    CGate[Test-AzDevOpsCreateGate]:::priv
    ResIA[Resolve-AzDevOpsIterationArea]:::priv
    CrLink[Invoke-AzDevOpsCreateAndLink]:::priv
    AddHier[Add-AzDevOpsHierarchyCacheItem]:::priv

    %% Multi-project resolver layer (azdevops_projects.ps1)
    MapDef[Test-AzDevOpsProjectMapDefined]:::priv
    TypeKey[ConvertTo-AzDevOpsTypeKey]:::priv
    ActName[Get-AzDevOpsActiveProjectName]:::priv
    ActCfg[Get-AzDevOpsActiveProjectConfig]:::priv
    TypeCfg[Get-AzDevOpsTypeConfig]:::priv
    Slug[Get-AzDevOpsActiveProjectSlug]:::priv
    ToSlug[ConvertTo-AzDevOpsProjectSlug]:::priv
    SetEnv[Set-AzDevOpsActiveProjectEnv]:::priv
    RArea[Resolve-AzDevOpsTypeArea]:::priv
    RIter[Resolve-AzDevOpsTypeIteration]:::priv
    RTags[Resolve-AzDevOpsTypeTags]:::priv
    RReq[Resolve-AzDevOpsTypeRequiredFields]:::priv
    RPri[Resolve-AzDevOpsTypeDefaultPriority]:::priv
    RPts[Resolve-AzDevOpsTypeDefaultStoryPoints]:::priv
    RScope[Resolve-AzDevOpsTypeParentScope]:::priv

    %% Phase B creator wiring (azdevops_create.ps1 + azdevops_create_pickers.ps1)
    RPriP[Resolve-AzDevOpsTypePriorityOrPrompt]:::priv
    RPtsP[Resolve-AzDevOpsTypeStoryPointsOrPrompt]:::priv
    RTagsE[Resolve-AzDevOpsTypeTagsOrEmpty]:::priv
    ReadReq[Read-AzDevOpsRequiredFields]:::priv
    ScopePaths[Get-AzDevOpsParentScopeAreaPaths]:::priv
    AreaMatch[Test-AzDevOpsAreaPathMatch]:::priv

    %% Schema management (azdevops_schema.ps1)
    GetSchema(["az-Get-AzDevOpsSchema"]):::pub
    InitSchema(["az-Initialize-AzDevOpsSchema"]):::pub
    EditSchema(["az-Edit-AzDevOpsSchema"]):::pub
    TestSchema(["az-Test-AzDevOpsSchema"]):::pub
    SchemaSlug[Get-AzDevOpsSchemaOrgSlug]:::priv
    SchemaValidTypes[Get-AzDevOpsSchemaValidTypes]:::priv
    SchemaWITypes[Get-AzDevOpsSchemaWorkItemTypes]:::priv
    SchemaSysRefs[Get-AzDevOpsSchemaSystemRefs]:::priv
    SchemaForType[Get-AzDevOpsSchemaForType]:::priv
    SchemaStub[New-AzDevOpsSchemaStub]:::priv
    SchemaEditor[Resolve-AzDevOpsEditor]:::priv
    WITypeShow[Invoke-AzDevOpsWorkItemTypeShow]:::priv
    SchemaFieldEntry[ConvertTo-AzDevOpsSchemaFieldEntry]:::priv
    SchemaToRows[ConvertFrom-AzDevOpsSchemaToRows]:::priv
    SchemaRead[Read-AzDevOpsSchemaFile]:::priv
    SchemaWrite[Write-AzDevOpsSchemaFile]:::priv
    SchemaInitDir[Initialize-AzDevOpsSchemaDir]:::priv

    %% I/O sinks
    Az[(az CLI)]:::io
    FS[(cache files)]:::io

    Connect --> C1 --> TCli
    Connect --> C2 --> TExt
    Connect --> C3 --> TEnv
    Connect --> CMap
    Connect --> C4 --> TLog
    Connect --> C5
    Connect --> C7 --> QInit
    Connect --> C6 --> TSmoke
    C1 & C2 & C3 & CMap & C4 & C5 & C6 & C7 --> StepRes
    C2 & C4 --> YN
    CMap --> MapDef
    CMap --> ActName
    CMap --> ActCfg
    CMap --> UseProj

    TestAuth --> TCli
    TestAuth --> TEnv
    TestAuth --> TSmoke
    TSmoke --> Az

    AuthAbort --> TestAuth
    Sync --> AuthAbort
    Sync --> InitDir --> Paths
    InitDir --> MkDir
    Sync --> LogFn --> Paths
    Sync --> DSets
    Sync --> InvokeDS
    InvokeDS --> InvHier
    InvHier --> QNames --> QDefaults --> QPaths
    InvHier --> QWiql --> QInit
    InvHier --> Boards
    QInit --> QDefaults
    QInit --> QPaths
    QInit --> MkDir
    OpenHWiql --> QInit
    InvokeDS --> Boards
    InvokeDS --> ClassList
    Boards --> AzJson
    ClassList --> AzJson
    AddDisc --> AzJson
    SetField --> AzJson
    NewWI --> AssertTok
    SetField --> AssertTok
    WITypeDef --> AzJson
    Boards --> EchoLn
    AzJson --> CmdDisp
    AzJson --> CmdHead
    AzJson --> EchoLn
    AzJson --> ConvNative
    AzJson --> Spinner --> Az
    InvokeDS --> Stderr1
    InvokeDS --> DStatus
    InvokeDS --> StderrW --> LogFn
    InvokeDS --> WriteFile --> FS
    DSets --> Measure

    Status --> Age --> Paths
    Status --> StatusRows --> ShowRows
    BgSync --> AutoChild
    BgSync --> AutoOptOut
    BgSync --> TCli
    BgSync --> Age
    BgSync --> AutoLockPath --> Paths
    BgSync --> AutoLockActive --> AutoLockTtl
    BgSync --> InitDir
    BgSync -.spawns hidden pwsh.-> Sync

    ReadA --> ReadJson --> Paths
    ReadA --> ConvA
    ReadM --> ReadJson
    ReadM --> ConvM --> MentDN
    ReadH --> ReadJson
    ReadH --> ConvH

    GetA --> ReadA
    GetA --> Stale --> Age
    GetA --> SelAct --> Closed
    GetA --> Sort
    GetA --> TitleCol --> Trunc
    GetA --> ShowRows
    OpenA --> ReadA
    OpenA --> Find
    OpenA --> OpenUrl --> WiUrl --> WiPfx
    OpenUrl --> Az
    Find --> WiUrl

    GetM --> ReadM
    GetM --> ReadA
    GetM --> Stale
    GetM --> SelAct
    GetM --> Sort
    GetM --> TitleCol
    GetM --> ShowRows
    OpenM --> ReadM
    OpenM --> Find
    OpenM --> OpenUrl

    Tree --> ReadH
    Tree --> Stale
    Tree --> NodeFmt --> Indent
    NodeFmt --> Icon
    Tree --> TreeRows --> ShowRows
    TreeRows --> WiPfx
    ShowRows --> GridAvail
    GridPick --> GridAvail

    Board --> ReadH
    Board --> Stale
    Board --> SelAct
    Board --> TitleCol
    Board --> ShowRows

    Epics --> ReadH
    Epics --> Stale
    Epics --> SelAct
    Epics --> TitleCol
    Epics --> ShowRows

    Orphans --> ReadH
    Orphans --> Stale
    Orphans --> SelAct
    Orphans --> AreaMatch
    Orphans --> TitleCol
    Orphans --> ShowRows

    %% Post-selection row actions (shared by Tree / Board / Features / Orphans)
    Tree --> RowAction
    Board --> RowAction
    Epics --> RowAction
    ShowFeats --> RowAction
    Orphans --> RowAction
    RowAction --> Multi2{"2+ rows?"}
    Multi2 -- yes --> OpenAllSel
    OpenAllSel --> YN
    OpenAllSel --> RowId
    OpenAllSel --> OpenUrl
    RowAction --> RowId
    RowAction --> RowType
    RowAction --> ChildType
    RowAction --> RowChoice
    RowAction --> ChildForRow
    RowAction --> OpenUrl
    ChildForRow --> NewF
    ChildForRow --> NewS
    ChildForRow --> NewTask

    %% URL builders share one base
    WiPfx --> UrlBase
    BoardsUrl --> UrlBase
    UrlBase --> ConfDef

    %% Classification post-selection (Areas / Iterations: Boards-hub open only)
    ShowAreas --> ClsAction
    ShowIters --> ClsAction
    ClsAction --> BoardsUrl

    %% Classification tree views (cache-first, live fallback)
    ClsRows[ConvertFrom-AzDevOpsClassificationTree]:::priv
    ClsNode[Format-AzDevOpsClassificationNode]:::priv
    ShowCls[Show-AzDevOpsClassification]:::priv
    ReadRows[Read-AzDevOpsClassificationRows]:::priv
    DispRows[ConvertTo-AzDevOpsClassificationDisplayRows]:::priv
    FmtDate[Format-AzDevOpsClassificationDate]:::priv

    ShowAreas --> ShowCls
    ShowIters --> ShowCls
    ShowCls --> ReadRows
    ShowCls --> DispRows --> ShowRows
    ShowCls --> ClsNode --> Indent
    ReadRows --> ReadCls
    ReadRows -.cache miss.-> InvCls
    ReadRows --> Stale
    ReadRows --> ClsRows
    DispRows --> FmtDate

    %% Pipeable rows + interactive pickers for classification trees
    GetAreas --> ReadRows
    GetIters --> ReadRows
    FindArea --> GridAvail
    FindArea -.no grid.-> GridUnavail
    FindArea --> ReadRows
    FindArea --> PCls
    FindIter --> GridAvail
    FindIter -.no grid.-> GridUnavail
    FindIter --> ReadRows
    FindIter --> DispRows
    FindIter --> GridPick

    %% Interactive picker for projects (azdevops_projects.ps1)
    FindProj --> GridAvail
    FindProj -.no grid.-> GridUnavail
    FindProj --> GetProjs
    FindProj --> GridPick
    FindProj -.opt-in -Use.-> UseProj
    Find -.no grid.-> GridUnavail

    Find --> ReadH
    Find --> Stale
    Find --> Closed
    Find --> GridAvail
    Find --> ActionRow
    Find --> OpenUrl

    NewS --> CGate
    NewS --> ReadH
    NewS --> USDesc
    NewS --> Pri
    NewS --> Pts
    NewS --> AC
    NewS --> PFeat
    NewS --> ResIA
    NewS --> CrLink

    %% Classification-pick fan-out (consumed by ResIA via Read-AzDevOpsKindPick)
    PKind --> ReadCls
    PKind --> InvCls --> ClassList
    ReadCls --> Paths
    PKind --> GetCPaths --> ToCPaths --> ToWIPath
    PFeat --> PCls
    PFeat --> GridPick
    PCls --> GridPick

    NewF --> CGate
    NewF --> ReadH
    NewF --> Pri
    NewF --> FeatDesc
    NewF --> PEpic
    NewF --> ResIA
    NewF --> CrLink
    NewF --> YN
    NewF -.hand-off on yes.-> NewSB

    NewTask --> CGate
    NewTask --> ReadH
    NewTask --> RPriP
    NewTask --> PStory
    NewTask --> ResIA
    NewTask --> CrLink
    PStory --> PParent

    NewSB --> CGate
    NewSB --> ReadH
    NewSB --> ParentTest
    NewSB --> ResIA
    NewSB --> AC
    NewSB --> Pri
    NewSB --> Pts
    NewSB --> CrLink
    NewSB --> BatchCont

    %% Shared creator scaffolding fan-out to the data plane
    CGate --> TestAuth
    ResIA --> PKind
    CrLink --> InvCreate --> NewWI --> AzJson
    CrLink --> InvLink --> AddRel --> AzJson
    CrLink --> AddHier --> WriteFile

    %% Unplanned work sessions
    StartUW --> CGate
    StartUW --> GetDaily
    GetDaily --> UWGetCachedStory
    UWGetCachedStory --> UWStoryCachePath
    UWGetCachedStory --> UWJsonRead
    GetDaily --> FindUW --> Boards
    GetDaily --> NewUWStory --> InvCreate
    GetDaily --> UWSaveCachedStory
    UWSaveCachedStory --> UWStoryCachePath
    UWSaveCachedStory --> UWJsonSave
    UWStoryCachePath --> UWCachePath
    StartUW --> NewUWTask
    NewUWTask --> NewWI
    NewUWTask --> InvLink
    StartUW --> UWFallback
    StartUW --> UWBalloon
    StartUW --> WpfStopwatch
    StartUW --> InvUWDebrief
    InvUWDebrief --> SetField
    InvUWDebrief --> AddDisc
    InvUWDebrief --> NewS
    InvUWDebrief --> UWLedger
    NewUWDebrief --> AddDisc
    NewUWDebrief --> UWLedger

    %% Team tagging — shared by the unplanned debriefs and the timer (azdevops_team.ps1)
    SyncUWTeam --> CGate
    SyncUWTeam --> UWRosterSync
    UWRosterSync --> UWTeamPick
    UWTeamPick --> UWTeamList --> AzJson
    UWRosterSync --> UWTeamMembers --> AzJson
    UWTeamMembers --> UWMemberRow --> UWMemberRec
    UWRosterSync --> UWRoster
    UWRosterSync --> UWResolve --> Identity --> AzJson
    UWResolve --> UWMemberRec
    UWRosterSync --> UWTeamSave
    InvUWDebrief --> UWMentionPick
    NewUWDebrief --> UWMentionPick
    InvUWDebrief --> UWMentionLine
    NewUWDebrief --> UWMentionLine
    UWMentionPick --> UWGetTeam
    UWMentionPick --> UWMentionMenu
    UWGetTeam --> UWTeamRead
    UWMentionLine --> UWAnchor
    UWTeamSave --> UWTeamPath
    UWTeamSave --> UWJsonSave
    UWTeamRead --> UWTeamPath
    UWTeamRead --> UWJsonRead
    UWTeamPath --> UWCachePath
    UWLedger --> UWLedgerPath
    UWLedger --> UWJsonRead
    UWLedger --> UWJsonSave
    UWLedgerPath --> UWCachePath
    UWCachePath --> Paths

    %% Parent picker shared between Feature and Epic pickers
    PFeat --> PParent
    PEpic --> PParent
    PParent --> Closed
    PParent --> Trunc
    PParent --> GridAvail
    PParent --> GridPick

    %% Reusable-prompt hint
    Pri --> ReuseHint
    Pts --> ReuseHint

    %% Multi-project switcher fan-out (azdevops_projects.ps1)
    UseProj --> MapDef
    UseProj --> SetEnv
    UseProj --> Az
    ShowProj --> ActName
    ShowProj --> ActCfg
    GetProjs --> MapDef
    GetProjs --> ActName
    Paths --> Slug
    Paths --> PathsForSlug
    Slug --> ActName
    Slug --> ToSlug
    ActCfg --> MapDef
    ActCfg --> ActName
    TypeCfg --> ActCfg
    TypeCfg --> TypeKey

    %% Multi-project features view (azdevops_views.ps1)
    FeatNames[Get-AzDevOpsFeaturesProjectNames]:::priv

    ShowFeats --> Stale
    ShowFeats --> FeatNames
    FeatNames --> MapDef
    FeatNames --> ActName
    ShowFeats --> FeatSrc
    ShowFeats --> NoFeatHint
    ShowFeats --> SelAct
    ShowFeats --> TitleCol
    ShowFeats --> ShowRows
    FeatSrc --> ReadHForProj
    FeatSrc -.legacy fallback.-> ReadH
    NoFeatHint --> BoardsUrl
    ReadHForProj --> ToSlug
    ReadHForProj --> PathsForSlug
    ReadHForProj --> ReadJson
    ReadHForProj --> ConvH

    %% Resolver layer (shared lookup chain)
    RArea --> TypeCfg
    RArea --> ActCfg
    RIter --> TypeCfg
    RIter --> ActCfg
    RTags --> TypeCfg
    RTags --> ActCfg
    RReq --> TypeCfg
    RPri --> TypeCfg
    RPts --> TypeCfg
    RScope --> TypeCfg

    %% Phase B creator wiring
    ResIA --> RArea
    ResIA --> RIter
    RPriP --> RPri
    RPriP --> Pri
    RPtsP --> RPts
    RPtsP --> Pts
    RTagsE --> RTags
    ReadReq --> RReq

    NewS --> RPriP
    NewS --> RPtsP
    NewS --> RTagsE
    NewS --> ReadReq
    NewF --> RPriP
    NewF --> RTagsE
    NewF --> ReadReq
    NewSB --> RPriP
    NewSB --> RPtsP
    NewSB --> RTagsE
    NewSB --> ReadReq

    InvCreate -.System.Tags + ExtraFields.-> NewWI

    %% ParentScope.AreaPaths filter (Phase B)
    PFeat --> ScopePaths --> RScope
    PEpic --> ScopePaths
    PParent --> AreaMatch

    %% Path-inspector openers (azdevops_openers.ps1) — every public below is a
    %% thin wrapper that resolves a path via one of the Get-AzDevOps*Paths
    %% helpers and delegates to Open-AzDevOpsPathIfExists, which Test-Paths the
    %% target and calls Start-Process when it exists.
    OpenAppRoot(["az-Open-AppRoot"]):::pub
    OpenCacheDir(["az-Open-CacheDir"]):::pub
    OpenConfigDir(["o-az-devops-queries-config-dir"]):::pub
    OpenSchemaDir(["o-az-devops-schema-dir"]):::pub
    OpenAsg(["az-Open-AssignedCache"]):::pub
    OpenMen(["az-Open-MentionsCache"]):::pub
    OpenHier(["az-Open-HierarchyCache"]):::pub
    OpenIter(["az-Open-IterationsCache"]):::pub
    OpenAreas(["az-Open-AreasCache"]):::pub
    OpenLast(["az-Open-LastSync"]):::pub
    OpenLog(["az-Open-SyncLog"]):::pub
    OpenEpics(["az-Open-EpicsWiql"]):::pub
    OpenFeats(["az-Open-FeaturesWiql"]):::pub
    OpenStories(["az-Open-UserStoriesWiql"]):::pub
    OpenSchema(["az-Open-Schema"]):::pub

    %% Path-inspector helper + path-discovery helpers used by the openers above
    OpenPath[Open-AzDevOpsPathIfExists]:::priv
    AppRoot[Get-AzDevOpsAppRoot]:::priv
    SPaths[Get-AzDevOpsSchemaPaths]:::priv

    %% OS handler I/O sink for Start-Process
    OSHandler[(OS default handler)]:::io

    %% Each opener resolves its path through the matching Get-AzDevOps*Paths
    %% helper, then delegates to Open-AzDevOpsPathIfExists which calls
    %% Start-Process on the resolved path.
    OpenAppRoot --> AppRoot
    OpenCacheDir --> Paths
    OpenConfigDir --> QPaths
    OpenSchemaDir --> SPaths
    OpenAsg --> Paths
    OpenMen --> Paths
    OpenHier --> Paths
    OpenIter --> Paths
    OpenAreas --> Paths
    OpenLast --> Paths
    OpenLog --> Paths
    OpenEpics --> QPaths
    OpenFeats --> QPaths
    OpenStories --> QPaths
    OpenSchema --> SPaths

    OpenAppRoot & OpenCacheDir & OpenConfigDir & OpenSchemaDir --> OpenPath
    OpenAsg & OpenMen & OpenHier & OpenIter & OpenAreas & OpenLast & OpenLog --> OpenPath
    OpenEpics & OpenFeats & OpenStories & OpenSchema --> OpenPath
    OpenPath --> OSHandler

    %% Schema management wiring
    GetSchema --> SchemaRead
    GetSchema --> SPaths
    GetSchema --> SchemaToRows
    GetSchema --> ShowRows

    EditSchema --> SchemaInitDir
    EditSchema --> SchemaRead
    EditSchema --> SchemaStub
    EditSchema --> SchemaWrite
    EditSchema --> SchemaEditor

    InitSchema --> AuthAbort
    InitSchema --> SchemaInitDir
    InitSchema --> SchemaSysRefs
    InitSchema --> SchemaWITypes
    InitSchema --> WITypeShow
    InitSchema --> SchemaFieldEntry
    InitSchema --> SchemaWrite

    TestSchema --> AuthAbort
    TestSchema --> SPaths
    TestSchema --> SchemaRead
    TestSchema --> SchemaValidTypes
    TestSchema --> SchemaWITypes
    TestSchema --> WITypeShow

    WITypeShow --> WITypeDef
    SchemaRead --> SPaths
    SchemaWrite --> SPaths
    SchemaInitDir --> SPaths
    SchemaInitDir --> Plat
    SPaths --> SchemaSlug
    SchemaSlug --> AppRoot
    SchemaForType --> SchemaRead

    %% Help renderer (azdevops_help.ps1) — catalog-driven Out-ConsoleGridView
    %% drill-down. No az / cache interaction; pure presentation + Get-Command
    %% line-number resolution for GitHub permalinks.
    Help(["az-help"]):::pub
    HelpDetail[Show-AzDevOpsHelpDetail]:::priv
    HelpDump[Show-AzDevOpsHelpPlainDump]:::priv
    HelpUrl[Get-AzDevOpsHelpFunctionUrl]:::priv

    Help --> GridAvail
    Help -.no grid.-> HelpDump
    Help --> HelpDetail
    HelpDetail --> HelpUrl
```

---

## How to render

GitHub renders mermaid in markdown natively — view this file on GitHub (or any markdown previewer with mermaid support, including VS Code with the Mermaid extension) to see the diagrams. No build step required.
