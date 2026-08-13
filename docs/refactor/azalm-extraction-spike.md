# Azure ALM + Timer Extraction — Spike Assessment

> **Status:** Spike / assessment only. **No code moves in this document.**
> Tracks [#254](https://github.com/jdschleicher/bashcuts/issues/254).

## Executive summary

The Azure DevOps work-item surface, the Pomodoro timer, and the daily-viewer app
are **~19,000 lines across 20 PowerShell files** plus the `daily-viewer/`
front-end — the large majority of `powcuts_by_cli/`. They form a self-contained
Azure ALM productivity suite.

**Recommendation: GO — as a phased extraction into a standalone PowerShell repo.**

The reason the lift is tractable despite the line count: **every cross-module
edge is already a `Get-Command`-guarded soft dependency.** The suite was built to
tolerate its own absence, so the seams that must be cut are already seams, not
welds. There are exactly three of them, and two are already optional-by-design:

| Edge | Where | Already soft? |
|---|---|---|
| AzDevOps → Outlook day-section registry | `azdevops_views.ps1:2131` guards on `Get-Command Register-OutlookDaySection` | ✅ yes |
| Daily-viewer → Outlook agenda | `daily_viewer.ps1:336` guards on `Get-Command ol-Get-OutlookAgenda` | ✅ yes |
| Timer ↔ AzDevOps (bidirectional) | `pow_timer.ps1` ↔ `azdevops_unplanned.ps1` / `azdevops_team.ps1` | n/a — **co-moves**, becomes internal |

Net: the timer and AzDevOps move **together** (their coupling is bidirectional
and heavy, so it becomes internal to the new repo — not a cut), and the only
true cuts are the two already-guarded Outlook edges, which the new module
re-satisfies by registering into the same public contract when both are
installed.

**Rough total effort: M–L** (a few focused sessions), dominated by wiring and
docs, not by untangling logic.

---

## 1. Confirmed inventory (move vs. stay)

### Moves to the new module

| Bucket | Files | ~LOC |
|---|---|---:|
| Azure DevOps core | 17 × `powcuts_by_cli/azdevops_*.ps1` | ~13,744 |
| Timer (Pomodoro) | `powcuts_by_cli/pow_timer.ps1` | 1,959 |
| Daily-viewer backend | `powcuts_by_cli/daily_viewer.ps1` | 3,362 |
| Daily-viewer front-end | `daily-viewer/` (`index.html`, `app.js`, `styles.css`, `favicon.svg`, `wpf/`) | whole dir |
| Azure-specific `pow_common` helper | `ConvertTo-AzDevOpsHtmlLineBreak` | ~20 |
| Docs | `docs/azure-devops-diagrams.md`, `docs/refactor/azdevops-split-plan.md`, this file | — |
| Snippets | `vscode_snippets/azure-cli.code-snippets` | — |
| **PowerShell subtotal** | **20 files** | **~19,065** |

The 17 `azdevops_*.ps1` files: `auth` (538), `classification` (639), `create`
(1,329), `create_pickers` (972), `db` (521), `draft` (1,413), `find` (562),
`help` (737), `openers` (195), `paths` (837), `projects` (666), `schema` (579),
`sync` (524), `team` (507), `unplanned` (1,333), `views` (2,136), `workitems`
(256).

### Stays in bashcuts

| File(s) | Why |
|---|---|
| `bashcuts_by_cli/.az_bashcuts` (~268) | **Decision:** bash stays. Thin `az boards` query wrappers, **zero** timer coupling. |
| `powcuts_by_cli/outlook_agenda.ps1` (587) | Generic Outlook calendar. **Zero** azdevops references. Owns the day-section registry the new module plugs into. |
| Generic `pow_common.ps1` helpers | See §4 — most are used by other bashcuts surfaces too. |
| `git_common.ps1`, `sfdx_cli.ps1`, `jira_automations.ps1`, `pester.ps1`, `pow_open.ps1` (minus one line) | Unrelated to the Azure ALM suite. |

---

## 2. Coupling map (the actual lift)

### CP-1 — Timer ↔ AzDevOps (bidirectional) → **co-move, becomes internal**

`pow_timer.ps1` reaches into the AzDevOps surface:

| Call | Count | Target file (new repo) |
|---|---:|---|
| `az-Open-WorkItemById` | 4 | `azdevops_views.ps1` |
| `az-Sync-AzDevOpsCache` | 2 | `azdevops_sync.ps1` |
| `az-Sync-AzDevOpsTeam` | 1 | `azdevops_team.ps1` |
| `az-New-AzDevOpsUserStory` | 2 | `azdevops_create.ps1` |
| `Add-AzDevOpsDiscussionComment` | 3 | `azdevops_db.ps1` |
| `Get-AzDevOpsTeam` | 2 | `azdevops_team.ps1` |
| `Read-AzDevOpsAssignedCache` | 1 | `azdevops_views.ps1` |

And AzDevOps reaches back into the timer: `azdevops_unplanned.ps1` (6 mentions)
and `azdevops_team.ps1` build on the Pomodoro session model, and the timer's own
public entry `az-Start-TimerSession` / `az-Register-TimerIntegration` are the
integration points.

**Proposed seam:** none. Because the dependency is dense and bidirectional, the
timer moves with AzDevOps. After the move all of the above are same-repo calls —
this coupling **stops being a cross-repo concern.**

### CP-2 — AzDevOps → Outlook day-section registry → **re-satisfy the contract**

`outlook_agenda.ps1` (stays) defines the extension point:

```
powcuts_by_cli/outlook_agenda.ps1:61   $script:OutlookDaySections = @()
powcuts_by_cli/outlook_agenda.ps1:503  function Register-OutlookDaySection { ... }
powcuts_by_cli/outlook_agenda.ps1:531  function Invoke-OutlookDaySections { ... }
```

`azdevops_views.ps1` (moves) registers into it — **already guarded**:

```
powcuts_by_cli/azdevops_views.ps1:2131  if (Get-Command Register-OutlookDaySection -ErrorAction SilentlyContinue) {
powcuts_by_cli/azdevops_views.ps1:2132      Register-OutlookDaySection ...
```

**Proposed seam:** keep exactly this. The new module registers its work-item
section **only if** `Register-OutlookDaySection` exists. Result:
- bashcuts alone → Outlook day view works, no work-item section (already true).
- new module alone → work-item views work, no Outlook injection (already true).
- both installed → the section appears (already true).

This is already a clean, documented-by-behavior extension point. §5 writes the
contract down explicitly so the two repos can't drift.

### CP-3 — Daily-viewer → Outlook agenda → **re-satisfy the contract**

`daily_viewer.ps1` (moves) live-calls the Outlook agenda for its Calendar tile —
**already guarded**:

```
powcuts_by_cli/daily_viewer.ps1:336  if (-not (Get-Command ol-Get-OutlookAgenda -ErrorAction SilentlyContinue)) { ... soft-fail ... }
powcuts_by_cli/daily_viewer.ps1:340  $events = ol-Get-OutlookAgenda -Days $Days
```

**Proposed seam:** keep the guard. The daily-viewer Calendar tile renders from
`ol-Get-OutlookAgenda` when bashcuts' Outlook module is present, and soft-fails
to an empty/placeholder tile when it isn't. This makes bashcuts an **optional
enhancer** of the new module, not a hard prerequisite — same pattern as CP-2, in
the opposite direction.

### CP-4 — `pow_open.ps1` opener

```
powcuts_by_cli/pow_open.ps1:36  function o-pow-azdevops { Start-Process ".../azdevops_auth.ps1" }
```

**Proposed cut:** remove `o-pow-azdevops` from bashcuts; the new repo provides
its own opener (the AzDevOps suite already ships `az-Open-AzDevOps*` openers in
`azdevops_openers.ps1`, so this is redundant even today).

### CP-5 — `powcuts_home.ps1` entry point

19 dot-source blocks reference moving files (17 `azdevops_*` + `pow_timer` +
`daily_viewer`), lines 45–186 of a 207-line file.

**Proposed cut:** delete those 19 blocks. The new repo gets its own
`powcuts_home.ps1`-style entry point (§6). Leave the 4 survivors (`sfdx_cli`,
`pow_common`, `pow_open`, `git_common`, plus `outlook_agenda`, `jira`,
`pester`).

### CP-6 — README

Sections to lift into the new repo's README, with a one-line pointer left behind:

| Section | README line |
|---|---:|
| Configuring the Azure CLI (`az`) | 161 |
| Azure DevOps work-item shortcuts | 280 |
| Daily viewer (local dashboard) | 789 |
| Timer sessions | 850 |
| Unplanned work sessions | 949 |

The `az` prerequisite bullet (line 24) becomes "only needed by the separate
Azure ALM module — see <link>."

### CP-7 — `.claude/` tooling

Files referencing `daily-viewer`/azdevops/timer:
`azdevops-diagrams-check.md` (moves wholesale), and the review/PR commands
`code-review.md`, `pr-flow.md`, `pr-diagram.md`, `senior-powershell-engineer.md`,
`senior-frontend-engineer.md`, `senior-clean-code-engineer.md` (trim the
azdevops/daily-viewer clauses here; re-home a copy in the new repo).

**Proposed cut:** move `azdevops-diagrams-check` + `docs/azure-devops-diagrams.md`
to the new repo. In bashcuts, drop the `daily-viewer/` ownership clause from
`senior-frontend-engineer` and the azdevops mentions from the others.

### CP-8 — Cache location

State lives at `~/.bashcuts-az-devops-app/` — already a **separate, namespaced
directory**, untouched by the rest of bashcuts.

**Proposed cut:** **no data migration.** The new module points at the same path
(or a rebranded one — see open questions). Users keep their cache across the
move either way.

---

## 3. Coupling summary — what actually gets cut

| # | Edge | Type | Action | Risk |
|---|---|---|---|---|
| CP-1 | Timer ↔ AzDevOps | dense, bidirectional | co-move (internalizes) | none |
| CP-2 | AzDevOps → Outlook registry | soft, guarded | keep contract | low |
| CP-3 | Daily-viewer → Outlook agenda | soft, guarded | keep contract | low |
| CP-4 | `o-pow-azdevops` | trivial | delete (redundant) | none |
| CP-5 | `powcuts_home.ps1` blocks | mechanical | delete 19 blocks | none |
| CP-6 | README sections | docs | lift + pointer | none |
| CP-7 | `.claude/` commands | tooling | move 1, trim 6 | low |
| CP-8 | cache dir | none | no migration | none |

**Only CP-2 and CP-3 are genuine runtime seams, and both already exist as
`Get-Command` guards.** Everything else is mechanical or documentation.

---

## 4. `pow_common.ps1` helper classification

Measured by real call sites in the moving files (`azdevops_*.ps1`, `pow_timer.ps1`,
`daily_viewer.ps1`):

### Azure-specific → **move to new module**

| Helper | Callers |
|---|---:|
| `ConvertTo-AzDevOpsHtmlLineBreak` | 2 |

Per the issue decision, this moves. It is the only `*AzDevOps*`-named helper in
`pow_common.ps1`.

### Generic but consumed by the moving code → **copy-vs-shared-base decision**

The daily-viewer WPF prototype and the timer's WPF countdown/debrief pull a
family of generic WPF + spinner + grid helpers:

| Helper | Callers in moving code |
|---|---:|
| `Test-WpfIsWindows` | 3 |
| `Test-ConsoleGridAvailable` | 2 |
| `Set-WpfArcPoint` | 2 |
| `New-WpfCircleResources` | 2 |
| `New-WpfBrushSet` | 2 |
| `Invoke-WithSpinner` | 2 |
| `New-WpfSpinnerControl` | 1 |
| `New-WpfProgressWindow` | 1 |

These are **also used elsewhere in bashcuts**, so they can't simply move.
`Invoke-WithSpinner` additionally calls `Start-/Stop-CommonConsoleSpinner`
internally, so copying it pulls those two along.

**Recommendation: copy the closure of the eight helpers above (plus the two
spinner internals) into the new repo's own `common.ps1`.** Rationale: it is ~150
lines of stable, rarely-touched plumbing; a shared submodule adds install
friction (two clones, version skew) that outweighs the small duplication. Revisit
a shared base only if these helpers start changing often. Track the duplication
with a one-line comment in both copies so a future edit knows to mirror.

### Stays put (not called by moving code)

`reinit`, `new-list`, `robot-debug`, `last-command`, `decode-base`,
`encode-base`, `kill-by-port`, `pow`, `Test-CommonSpinnerEnabled`,
`New-WpfProgressController`.

---

## 5. Outlook day-section registry — extension-point contract

This is the one interface that must be written down so bashcuts (producer) and
the new module (consumer) can evolve independently. It already exists in code;
this formalizes it.

**Owner:** bashcuts, `powcuts_by_cli/outlook_agenda.ps1`.

**Public surface (bashcuts guarantees stability):**

```powershell
# Register a section to be rendered inside ol-Show-OutlookDay.
Register-OutlookDaySection `
    -Name   <string>        # unique key; re-registering the same Name replaces it
    -Order  <int>           # sort key; lower renders earlier
    -Script <scriptblock>   # returns the rendered rows for the day

# Called by ol-Show-OutlookDay to render all registered sections in Order, then Name.
Invoke-OutlookDaySections
```

**Consumer contract (the new Azure ALM module):**
- On load, guard registration: `if (Get-Command Register-OutlookDaySection -ErrorAction SilentlyContinue) { Register-OutlookDaySection ... }`.
- Never assume the registry exists — absence just means Outlook isn't installed.
- The section's scriptblock must be **cache-only and read-only** (no `az`
  round-trip), matching today's behavior — it reads the assigned cache and
  returns rows.

**Reverse contract (daily-viewer consuming Outlook):**
- The daily-viewer Calendar tile calls `ol-Get-OutlookAgenda` **only** behind a
  `Get-Command` guard and soft-fails to an empty tile when absent.

**Compatibility matrix:**

| bashcuts (Outlook) | Azure ALM module | Result |
|:---:|:---:|---|
| ✅ | ✅ | Full: work-item section in Outlook day view; Calendar tile in daily-viewer |
| ✅ | ❌ | Outlook day view, no work-item section; no daily-viewer |
| ❌ | ✅ | Work-item views + daily-viewer with empty Calendar tile |
| ❌ | ❌ | Neither |

Because the contract is `Get-Command`-guarded in both directions, **load order
across the two repos does not matter** and neither repo hard-requires the other.

---

## 6. Proposed new-repo layout

Name TBD (see open questions) — call it `azalm-powcuts` for now.

```
azalm-powcuts/
├── azalm_home.ps1                 # entry point; dot-sources every powcuts_by_cli/*.ps1 (mirror of powcuts_home.ps1)
├── README.md                      # lifted Azure DevOps + Timer + Daily-viewer + unplanned sections
├── CLAUDE.md                      # the AzDevOps/timer/front-end rules, lifted from bashcuts' CLAUDE.md
├── powcuts_by_cli/
│   ├── common.ps1                 # copied closure of the shared WPF/spinner/grid helpers + ConvertTo-AzDevOpsHtmlLineBreak
│   ├── azdevops_*.ps1             # all 17, unchanged
│   ├── pow_timer.ps1              # unchanged
│   └── daily_viewer.ps1           # unchanged (keeps the ol-Get-OutlookAgenda guard)
├── daily-viewer/                  # index.html, app.js, styles.css, favicon.svg, wpf/
├── docs/
│   ├── azure-devops-diagrams.md
│   └── refactor/azdevops-split-plan.md
├── vscode_snippets/azure-cli.code-snippets
└── .claude/
    ├── commands/azdevops-diagrams-check.md
    └── commands/ (trimmed copies of the review commands as needed)
```

**Install / wire-up (user-facing):** identical model to bashcuts — clone into a
path without spaces, then add one dot-source line to `$profile`:

```powershell
. "$path_to_azalm\azalm-powcuts\azalm_home.ps1"
```

Load order relative to bashcuts is irrelevant (§5). If the user wants the Outlook
work-item section, they keep bashcuts loaded too; otherwise the module stands
alone.

**Packaging decision (open):** plain dot-source clone (matches bashcuts, zero
ceremony) vs. a real module manifest (`.psd1`) publishable to the PowerShell
Gallery. Recommendation: **start as a dot-source clone** to keep parity with
bashcuts and avoid a build step; graduate to a manifest later if Gallery
distribution becomes a goal. Naming stays `verb-noun` / `Verb-Noun` exactly as
today — **no renames**, so muscle memory, tab-completion, and every diagram-doc
reference keep working.

---

## 7. Phased migration plan + effort

Follows the `azdevops-split-plan.md` discipline: **pure move, no renames, no
behavior change.**

| Phase | Work | Effort | Notes |
|---|---|:---:|---|
| **P0** | Create the new repo, scaffold `azalm_home.ps1`, `README`, `CLAUDE.md`, `.claude/` | **S** | Empty shell; nothing moved yet |
| **P1** | Copy the 20 `.ps1` files + `daily-viewer/` + `common.ps1` closure into the new repo; wire `azalm_home.ps1`; parse-check | **M** | Mechanical; the bulk of the LOC but the least thinking |
| **P2** | Write down the §5 registry contract in both repos; confirm all 3 cross-edges (CP-1/2/3) resolve under the guards | **S** | The only genuinely technical phase |
| **P3** | In bashcuts: delete 19 `powcuts_home.ps1` blocks, `o-pow-azdevops`, and the moved files; lift README sections with a pointer; trim `.claude/` commands; move `docs/azure-devops-diagrams.md` + `azdevops-diagrams-check` | **M** | Careful deletion + docs; the diagram-check skill must land in the new repo working |
| **P4** | Verify in fresh terminals (both repos loaded, each alone); update `azdevops-split-plan.md` reference; decide cache-dir rebrand | **S** | Verification + cleanup |

**Total: M–L.** No phase is L on its own; the size comes from breadth, not depth.
P1 and P3 are the two biggest, and both are mechanical.

### Suggested follow-up epic child issues

1. **Scaffold `azalm-powcuts` repo + entry point** (P0) — S
2. **Move Azure DevOps + timer + daily-viewer files into the new repo** (P1) — M
3. **Formalize the Outlook day-section extension-point contract in both repos** (P2) — S
4. **Remove Azure ALM surface from bashcuts + leave README pointer** (P3) — M
5. **Move `azdevops-diagrams-check` + diagram doc; trim review commands** (P3) — S
6. **Cross-terminal verification + cache-dir decision** (P4) — S

---

## 8. Risks

| Risk | Severity | Mitigation |
|---|:---:|---|
| User muscle memory / tab-completion breaks | Low | No renames — every `az-*` / `Verb-Noun` name is identical after the move |
| `azdevops-diagrams-check` skill breaks (paths change) | Medium | Skill + diagram doc move together in P3-5; re-point its frontmatter globs at the new repo |
| Shared-helper drift (copied `pow_common` closure) | Low | ~150 lines of stable plumbing; mirror-comment in both copies; revisit shared base only if churn appears |
| Dual-repo maintenance overhead | Medium | Accepted cost of the split; the suite is self-contained enough that cross-repo changes will be rare |
| Load-order dependency between repos | **None** | Both cross-edges are `Get-Command`-guarded; order is irrelevant (§5) |
| Cache loss on move | **None** | `~/.bashcuts-az-devops-app/` is untouched; no migration |

---

## 9. Open questions (resolve in the epic, not blocking)

1. **Repo name + packaging** — dot-source clone (recommended) vs. `.psd1`
   module manifest / PowerShell Gallery. Name suggestion: `azalm-powcuts`.
2. **Shared helpers** — copy the closure (recommended) vs. extract a shared base
   module both repos consume.
3. **Cache path rebrand** — keep `~/.bashcuts-az-devops-app/` (zero migration) or
   rename to e.g. `~/.azalm-app/` (needs a one-time move + back-compat read).
4. **`.az_bashcuts` (bash)** — stays for now per decision; revisit whether a bash
   counterpart belongs in the new repo if that repo ever grows a bash surface.

---

## Verification plan for this spike

This document is docs-only. To confirm its factual claims:

```bash
# Inventory + LOC
wc -l powcuts_by_cli/azdevops_*.ps1 powcuts_by_cli/pow_timer.ps1 powcuts_by_cli/daily_viewer.ps1

# CP-2 / CP-3 guards exist
grep -n "Get-Command Register-OutlookDaySection" powcuts_by_cli/azdevops_views.ps1
grep -n "Get-Command ol-Get-OutlookAgenda"        powcuts_by_cli/daily_viewer.ps1

# Registry owner
grep -nE "OutlookDaySections|function Register-OutlookDaySection|function Invoke-OutlookDaySections" powcuts_by_cli/outlook_agenda.ps1

# Entry-point blocks to remove
grep -nE "Get-Content .*(azdevops_|pow_timer|daily_viewer)" powcuts_home.ps1

# outlook_agenda has zero azdevops references (stays)
grep -ciE "azdevops|az boards" powcuts_by_cli/outlook_agenda.ps1   # -> 0
```
