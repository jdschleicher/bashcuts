# Azure DevOps Functionality — Mermaid Diagrams

Visual reference for the Azure DevOps work-item shortcuts in `powcuts_by_cli/azdevops_workitems.ps1`. Each diagram covers one subsystem; the last diagram is a cross-cutting function-dependency map.

- [1. High-level architecture](#1-high-level-architecture)
- [2. `az-Connect-AzDevOps` — 6-step orchestrator](#2-az-connect-azdevops--6-step-orchestrator)
- [3. `az-Test-AzDevOpsAuth` — silent diagnostic chain](#3-az-test-azdevopsauth--silent-diagnostic-chain)
- [4. `az-Sync-AzDevOpsCache` — dataset fan-out](#4-az-sync-azdevopscache--dataset-fan-out)
- [5. Cache consumers (`az-Get-/az-Open-AzDevOps{Assigned,Mentions}`)](#5-cache-consumers-az-get-az-open-azdevopsassignedmentions)
- [6. `az-Show-AzDevOpsTree` — Epic → Feature → Story render](#6-az-show-azdevopstree--epic--feature--story-render)
- [7. `az-New-AzDevOpsUserStory` — interactive create flow](#7-az-new-azdevopsuserstory--interactive-create-flow)
- [8. `az-Register-/az-Unregister-AzDevOpsSyncSchedule` — platform branch](#8-az-register-az-unregister-azdevopssyncschedule--platform-branch)
- [9. Function dependency map](#9-function-dependency-map)

---

## 1. High-level architecture

How the public surface, the local cache, and the `az` CLI relate. Read-only consumers never touch `az` directly — they only read cache files.

```mermaid
flowchart LR
    subgraph User["User session ($profile)"]
        Profile["powcuts_home.ps1<br/>dot-sources azdevops_workitems.ps1"]
        EnvVars["$env:AZ_DEVOPS_ORG<br/>$env:AZ_PROJECT<br/>$env:AZ_USER_EMAIL<br/>$env:AZ_AREA<br/>$env:AZ_ITERATION"]
    end

    subgraph Public["Public functions"]
        Connect["az-Connect-AzDevOps"]
        TestAuth["az-Test-AzDevOpsAuth"]
        Sync["az-Sync-AzDevOpsCache"]
        Status["az-Get-AzDevOpsCacheStatus"]
        Reg["az-Register-AzDevOpsSyncSchedule"]
        Unreg["az-Unregister-AzDevOpsSyncSchedule"]
        GetA["az-Get-AzDevOpsAssigned"]
        OpenA["az-Open-AzDevOpsAssigned"]
        GetM["az-Get-AzDevOpsMentions"]
        OpenM["az-Open-AzDevOpsMention"]
        Tree["az-Show-AzDevOpsTree"]
        NewStory["az-New-AzDevOpsUserStory"]
    end

    subgraph Cache["$HOME/.bashcuts-cache/azure-devops/"]
        AssignedJson["assigned.json"]
        MentionsJson["mentions.json"]
        HierJson["hierarchy.json"]
        IterJson["iterations.json"]
        AreasJson["areas.json"]
        LastSync["last-sync.json"]
        SyncLog["sync.log (rotates at ~1MB)"]
    end

    subgraph AzCLI["Azure CLI"]
        AzBoards["az boards query / work-item create / relation add"]
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
    Status --> LastSync

    NewStory --> HierJson
    NewStory --> IterJson
    NewStory --> AreasJson
    NewStory --> AzBoards

    Reg -.task scheduler / cron.-> Sync
    Unreg -.removes schedule.-> Reg
```

---

## 2. `az-Connect-AzDevOps` — 6-step orchestrator

Thin orchestrator: a hard-coded array of step descriptors. Each step is a `Confirm-*` function that prints its own status and returns `{Ok, FailMessage}`. First failure short-circuits with `NOT READY`.

```mermaid
flowchart TD
    Start([az-Connect-AzDevOps]) --> S1

    S1["Step 1 — az-Confirm-AzDevOpsCli<br/>uses Test-AzDevOpsCliPresent"]
    S2["Step 2 — az-Confirm-AzDevOpsExtension<br/>uses Test-AzDevOpsExtensionInstalled<br/>+ optional 'az extension add'"]
    S3["Step 3 — az-Confirm-AzDevOpsEnvVars<br/>uses Get-AzDevOpsMissingEnvVars"]
    S4["Step 4 — az-Confirm-AzDevOpsLogin<br/>uses Test-AzDevOpsLoggedIn<br/>+ optional 'az login'"]
    S5["Step 5 — az-Set-AzDevOpsDefaults<br/>'az devops configure --defaults'"]
    S6["Step 6 — az-Confirm-AzDevOpsSmokeQuery<br/>uses Invoke-AzDevOpsSmokeQuery"]

    Ready([READY])
    NotReady([NOT READY — blocked at step N])

    S1 -- Ok --> S2
    S2 -- Ok --> S3
    S3 -- Ok --> S4
    S4 -- Ok --> S5
    S5 -- Ok --> S6
    S6 -- Ok --> Ready

    S1 -- fail --> NotReady
    S2 -- fail --> NotReady
    S3 -- fail --> NotReady
    S4 -- fail --> NotReady
    S5 -- fail --> NotReady
    S6 -- fail --> NotReady

    classDef step fill:#1f3a5f,stroke:#4ea3ff,color:#fff
    class S1,S2,S3,S4,S5,S6 step
```

Helpers used by every step:

- `New-AzDevOpsStepResult` — builds the `{Ok, FailMessage}` PSCustomObject
- `Read-AzDevOpsYesNo` — default-yes Y/n prompt for remediation offers

---

## 3. `az-Test-AzDevOpsAuth` — silent diagnostic chain

Used by callers (`az-Sync-AzDevOpsCache`, `az-New-AzDevOpsUserStory`) at the top of every command to bail early if the environment regressed. No I/O — pure boolean.

```mermaid
flowchart TD
    Start([az-Test-AzDevOpsAuth]) --> A{Test-AzDevOpsCliPresent?}
    A -- no --> F([return $false])
    A -- yes --> B{Get-AzDevOpsMissingEnvVars<br/>count == 0?}
    B -- no --> F
    B -- yes --> C{Invoke-AzDevOpsSmokeQuery<br/>returns count?}
    C -- $null --> F
    C -- count --> T([return $true])

    classDef ok fill:#0d4f24,stroke:#2ecc71,color:#fff
    classDef bad fill:#5a1a1a,stroke:#e74c3c,color:#fff
    class T ok
    class F bad
```

Skipped on purpose: `Test-AzDevOpsExtensionInstalled` and `Test-AzDevOpsLoggedIn`. The smoke `az boards query` call already exercises both transitively, and a single failing query is faster + more authoritative than three individual probes.

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
        D3["hierarchy<br/>WIQL Epic/Feature/Story flat<br/>+ System.Parent"]
        D4["iterations<br/>Get-AzDevOpsClassificationList -Kind Iteration<br/>→ az boards iteration project list --depth 5"]
        D5["areas<br/>Get-AzDevOpsClassificationList -Kind Area<br/>→ az boards area project list --depth 5"]
    end

    Datasets -.descriptors.-> Datasets5
```

Atomic write pattern (`Write-AzDevOpsCacheFile`): `Set-Content` to `<path>.tmp`, then `Move-Item -Force` over the real path — partial files never replace good cache.

---

## 5. Cache consumers (`az-Get-/az-Open-AzDevOps{Assigned,Mentions}`)

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
    GetA->>Title: title-column projection
    Title-->>GetA: rows
    GetA->>Show: -PassThru (Out-ConsoleGridView<br/>or Format-Table fallback)
    Show-->>User: selected rows / rendered table
```

Open-by-id flow re-uses the same cache + a different last-mile helper:

```mermaid
flowchart LR
    A([az-Open-AzDevOpsAssigned 12345]) --> RC[Read-AzDevOpsAssignedCache]
    RC --> Find["Find-AzDevOpsCachedWorkItem<br/>(id lookup + miss-hint)"]
    Find -- miss --> Hint([print 'run az-Get-AzDevOpsAssigned' + LASTEXITCODE=1])
    Find -- hit --> Open["Open-AzDevOpsWorkItemUrl<br/>(env-var guard + URL build)"]
    Open --> SP["Start-Process<br/>$env:AZ_DEVOPS_ORG/$env:AZ_PROJECT/_workitems/edit/12345"]
```

`az-Open-AzDevOpsMention` is structurally identical, just swaps `Read-AzDevOpsMentionsCache` and the `-Description 'mentions'` label.

---

## 6. `az-Show-AzDevOpsTree` — Epic → Feature → Story render

Pure cache read, no `az`. The hierarchy WIQL pulled `[System.Parent]` per row, so a single pass into a `byParent` hashtable is enough — no follow-up queries.

```mermaid
flowchart TD
    Start([az-Show-AzDevOpsTree]) --> Read[Read-AzDevOpsHierarchyCache]
    Read --> Banner[Write-AzDevOpsStaleBanner]
    Banner --> Index["build $byParent hashtable<br/>key = ParentId or 0"]
    Index --> Epics["filter Type='Epic', sort by Id"]
    Epics --> Grid{Test-AzDevOpsGridAvailable?}
    Grid -- yes --> RowsFn["Get-AzDevOpsTreeRows<br/>(Type/Id/Title/State/Depth/Path)"]
    RowsFn --> Show["Show-AzDevOpsRows<br/>→ Out-ConsoleGridView"]
    Grid -- no --> ForEpic{foreach epic}
    ForEpic --> NodeE["Format-AzDevOpsTreeNode -Depth 0<br/>uses Get-AzDevOpsTreeIcon (Epic icon)<br/>+ Get-AzDevOpsTreeIndent"]
    NodeE --> Features["children where Type='Feature'"]
    Features --> NoFeat{any?}
    NoFeat -- no --> Empty["print '(no features)'"]
    NoFeat -- yes --> ForFeat{foreach feature}
    ForFeat --> NodeF["Format-AzDevOpsTreeNode -Depth 1<br/>(Feature icon)"]
    NodeF --> Stories["children where Type='User Story'"]
    Stories --> ForStory{foreach story}
    ForStory --> NodeS["Format-AzDevOpsTreeNode -Depth 2<br/>(Story icon)"]
    NodeS --> ForStory
    ForStory --> ForFeat
    ForFeat --> ForEpic
```

Icon helper `Get-AzDevOpsTreeIcon` returns named codepoint locals (`$iconEpic`, `$iconFeature`, `$iconStory`) — never raw `[char]0x...` literals at the call site.

---

## 7. `az-New-AzDevOpsUserStory` — interactive create flow

Interactive walk-through with all-optional parameters: every prompt is skipped if its parameter was supplied, so the function is also script-callable.

```mermaid
flowchart TD
    Start([az-New-AzDevOpsUserStory]) --> Auth{az-Test-AzDevOpsAuth}
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

    Desc -- no --> ReadDesc["Read-Host 'description'"]
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

Picker fallback: if `iterations.json` / `areas.json` aren't in the cache yet (user upgraded but hasn't synced), `Read-AzDevOpsKindPick` calls `Invoke-AzDevOpsClassificationLive` and prints a one-line "(run az-Sync-AzDevOpsCache to make this instant)" hint.

---

## 8. `az-Register-/az-Unregister-AzDevOpsSyncSchedule` — platform branch

Both functions delegate the OS check to `Get-AzDevOpsPlatform` so the branch lives in one place. The cron line itself is built by `Get-AzDevOpsCronLine` (also reused) so register and unregister stay symmetric.

```mermaid
flowchart TD
    Reg([az-Register-AzDevOpsSyncSchedule]) --> P1{Get-AzDevOpsPlatform}
    P1 -- Windows --> WReg["New-ScheduledTaskAction + Trigger<br/>Register-ScheduledTask -TaskName<br/>Get-AzDevOpsScheduledTaskName<br/>(every Get-AzDevOpsSyncIntervalHours)"]
    P1 -- Posix --> PReg["Get-AzDevOpsCronLine -PwshPath<br/>+ Get-AzDevOpsCrontabSplit<br/>append + crontab -"]
    P1 -- Unknown --> ErrR([Unsupported OS])

    Unreg([az-Unregister-AzDevOpsSyncSchedule]) --> P2{Get-AzDevOpsPlatform}
    P2 -- Windows --> WUn["Get-ScheduledTask?<br/>Unregister-ScheduledTask -Confirm:$false"]
    P2 -- Posix --> PUn["Get-AzDevOpsCrontabSplit<br/>(filter Get-AzDevOpsCronTag)<br/>crontab -"]
    P2 -- Unknown --> ErrU([Unsupported OS])

    classDef shared fill:#3a2a5f,stroke:#a070ff,color:#fff
    class P1,P2 shared
```

Shared private helpers (named in CLAUDE.md):

- `Get-AzDevOpsPlatform` → `'Windows' | 'Posix' | 'Unknown'`
- `Get-AzDevOpsScheduledTaskName` → `'BashcutsAzDevOpsSync'`
- `Get-AzDevOpsSyncIntervalHours` → `5`
- `Get-AzDevOpsCronTag` → `'# bashcuts-azdevops-sync'`
- `Get-AzDevOpsCronLine -PwshPath` → assembled cron line
- `Get-AzDevOpsCrontabSplit` → `{Other, HadBashcuts}` partition

---

## 9. Function dependency map

Public functions on the left, private helpers on the right. Helpers under "Shared scaffolding" exist specifically because their bodies were duplicated across the parallel `Get-/Open-` pairs and the parallel `Register-/Unregister-` pairs.

```mermaid
graph LR
    classDef pub fill:#1f3a5f,stroke:#4ea3ff,color:#fff
    classDef priv fill:#3a3a3a,stroke:#888,color:#ddd
    classDef io fill:#5a3a1a,stroke:#ffaa55,color:#fff

    Connect(["az-Connect-AzDevOps"]):::pub
    TestAuth(["az-Test-AzDevOpsAuth"]):::pub
    Sync(["az-Sync-AzDevOpsCache"]):::pub
    Status(["az-Get-AzDevOpsCacheStatus"]):::pub
    Reg(["az-Register-AzDevOpsSyncSchedule"]):::pub
    Unreg(["az-Unregister-AzDevOpsSyncSchedule"]):::pub
    GetA(["az-Get-AzDevOpsAssigned"]):::pub
    OpenA(["az-Open-AzDevOpsAssigned"]):::pub
    GetM(["az-Get-AzDevOpsMentions"]):::pub
    OpenM(["az-Open-AzDevOpsMention"]):::pub
    Tree(["az-Show-AzDevOpsTree"]):::pub
    NewS(["az-New-AzDevOpsUserStory"]):::pub

    %% Step helpers
    C1[az-Confirm-AzDevOpsCli]:::priv
    C2[az-Confirm-AzDevOpsExtension]:::priv
    C3[az-Confirm-AzDevOpsEnvVars]:::priv
    C4[az-Confirm-AzDevOpsLogin]:::priv
    C5[az-Set-AzDevOpsDefaults]:::priv
    C6[az-Confirm-AzDevOpsSmokeQuery]:::priv
    StepRes[New-AzDevOpsStepResult]:::priv
    YN[Read-AzDevOpsYesNo]:::priv

    %% Diagnostic helpers
    TCli[Test-AzDevOpsCliPresent]:::priv
    TExt[Test-AzDevOpsExtensionInstalled]:::priv
    TEnv[Get-AzDevOpsMissingEnvVars]:::priv
    TLog[Test-AzDevOpsLoggedIn]:::priv
    TSmoke[Invoke-AzDevOpsSmokeQuery]:::priv

    %% Cache infra
    Paths[Get-AzDevOpsCachePaths]:::priv
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

    %% Data-plane wrappers (azdevops_db.ps1)
    AzJson[Invoke-AzDevOpsAzJson]:::priv
    Boards[Invoke-AzDevOpsBoardsQuery]:::priv
    ClassList[Get-AzDevOpsClassificationList]:::priv
    NewWI[New-AzDevOpsWorkItem]:::priv
    AddRel[Add-AzDevOpsWorkItemRelation]:::priv

    %% Schedule helpers
    Plat[Get-AzDevOpsPlatform]:::priv
    TaskName[Get-AzDevOpsScheduledTaskName]:::priv
    Interval[Get-AzDevOpsSyncIntervalHours]:::priv
    CronTag[Get-AzDevOpsCronTag]:::priv
    CronLine[Get-AzDevOpsCronLine]:::priv
    CronSplit[Get-AzDevOpsCrontabSplit]:::priv

    %% Read helpers
    ReadJson[Read-AzDevOpsJsonCache]:::priv
    ConvA[ConvertFrom-AzDevOpsAssignedItem]:::priv
    ConvM[ConvertFrom-AzDevOpsMentionItem]:::priv
    ConvH[ConvertFrom-AzDevOpsHierarchyItem]:::priv
    ReadA[Read-AzDevOpsAssignedCache]:::priv
    ReadM[Read-AzDevOpsMentionsCache]:::priv
    ReadH[Read-AzDevOpsHierarchyCache]:::priv

    %% Shared scaffolding
    Closed[Get-AzDevOpsClosedStates]:::priv
    Stale[Write-AzDevOpsStaleBanner]:::priv
    SelAct[Select-AzDevOpsActiveItems]:::priv
    Trunc[Format-AzDevOpsTruncatedTitle]:::priv
    TitleCol[Get-AzDevOpsTitleColumn]:::priv
    Find[Find-AzDevOpsCachedWorkItem]:::priv
    OpenUrl[Open-AzDevOpsWorkItemUrl]:::priv
    MentDN[Get-AzDevOpsMentionedByDisplayName]:::priv

    %% Tree helpers
    Indent[Get-AzDevOpsTreeIndent]:::priv
    Icon[Get-AzDevOpsTreeIcon]:::priv
    NodeFmt[Format-AzDevOpsTreeNode]:::priv
    TreeRows[Get-AzDevOpsTreeRows]:::priv

    %% Grid presentation helpers (Out-ConsoleGridView)
    GridAvail[Test-AzDevOpsGridAvailable]:::priv
    ShowRows[Show-AzDevOpsRows]:::priv
    GridPick[Read-AzDevOpsGridPick]:::priv
    StatusRows[Get-AzDevOpsCacheStatusRows]:::priv

    %% NewStory helpers
    ReadCls[Read-AzDevOpsClassificationCache]:::priv
    InvCls[Invoke-AzDevOpsClassificationLive]:::priv
    ToWIPath[ConvertTo-AzDevOpsWorkItemPath]:::priv
    ToCPaths[ConvertTo-AzDevOpsClassificationPaths]:::priv
    GetCPaths[Get-AzDevOpsClassificationPaths]:::priv
    Pri[Read-AzDevOpsPriority]:::priv
    Pts[Read-AzDevOpsStoryPoints]:::priv
    AC[Read-AzDevOpsAcceptanceCriteria]:::priv
    PFeat[Read-AzDevOpsFeaturePick]:::priv
    PCls[Read-AzDevOpsClassificationPick]:::priv
    PKind[Read-AzDevOpsKindPick]:::priv
    InvCreate[Invoke-AzDevOpsWorkItemCreate]:::priv
    InvLink[Invoke-AzDevOpsParentLink]:::priv

    %% I/O sinks
    Az[(az CLI)]:::io
    FS[(cache files)]:::io

    Connect --> C1 --> TCli
    Connect --> C2 --> TExt
    Connect --> C3 --> TEnv
    Connect --> C4 --> TLog
    Connect --> C5
    Connect --> C6 --> TSmoke
    C1 & C2 & C3 & C4 & C5 & C6 --> StepRes
    C2 & C4 --> YN

    TestAuth --> TCli
    TestAuth --> TEnv
    TestAuth --> TSmoke
    TSmoke --> Az

    Sync --> TestAuth
    Sync --> InitDir --> Paths
    Sync --> LogFn --> Paths
    Sync --> DSets
    Sync --> InvokeDS
    InvokeDS --> Boards
    InvokeDS --> ClassList
    Boards --> AzJson
    ClassList --> AzJson
    AzJson --> Az
    InvokeDS --> Stderr1
    InvokeDS --> DStatus
    InvokeDS --> StderrW --> LogFn
    InvokeDS --> WriteFile --> FS
    DSets --> Measure

    Status --> Age --> Paths
    Status --> StatusRows --> ShowRows
    Reg --> Plat
    Reg --> TaskName
    Reg --> Interval
    Reg --> CronLine --> CronTag
    Reg --> CronSplit --> CronTag
    Unreg --> Plat
    Unreg --> TaskName
    Unreg --> CronSplit

    ReadA --> ReadJson --> Paths
    ReadA --> ConvA
    ReadM --> ReadJson
    ReadM --> ConvM --> MentDN
    ReadH --> ReadJson
    ReadH --> ConvH

    GetA --> ReadA
    GetA --> Stale --> Age
    GetA --> SelAct --> Closed
    GetA --> TitleCol --> Trunc
    GetA --> ShowRows
    OpenA --> ReadA
    OpenA --> Find
    OpenA --> OpenUrl --> Az

    GetM --> ReadM
    GetM --> ReadA
    GetM --> Stale
    GetM --> SelAct
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
    ShowRows --> GridAvail
    GridPick --> GridAvail

    NewS --> TestAuth
    NewS --> ReadH
    NewS --> Pri
    NewS --> Pts
    NewS --> AC
    NewS --> PFeat
    NewS --> PKind --> ReadCls
    PKind --> InvCls --> ClassList
    ReadCls --> Paths
    PKind --> GetCPaths --> ToCPaths --> ToWIPath
    PFeat --> PCls
    PFeat --> GridPick
    PCls --> GridPick
    NewS --> InvCreate --> NewWI --> AzJson
    NewS --> InvLink --> AddRel --> AzJson
```

---

## How to render

GitHub renders mermaid in markdown natively — view this file on GitHub (or any markdown previewer with mermaid support, including VS Code with the Mermaid extension) to see the diagrams. No build step required.
