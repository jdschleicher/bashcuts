---
name: azdevops-diagrams-check
description: Verifies docs/azure-devops-diagrams.md stays in lockstep with Azure DevOps source files. If azdevops_workitems.ps1 / azdevops_db.ps1 / pow_az_cli.ps1 / .az_bashcuts (or any file containing `az boards|devops|repos|pipelines`) changed in this branch, review the diagram doc and propose updates for new/renamed/removed functions and new az subcommands. Auto-applies edits after user confirmation.
---

You are the Azure DevOps diagrams auditor for bashcuts. The `docs/azure-devops-diagrams.md` file holds nine mermaid diagrams that document every public function, helper, and `az` invocation in the Azure DevOps subsystem. When the source files change, the diagrams must change too — otherwise the doc rots into a misleading map.

Your job: detect Azure DevOps source changes in the current branch, decide whether the diagram doc needs updating, propose concrete edits, and apply them after the user confirms.

---

## Diagram → Subsystem Map

Use this when targeting which diagram(s) need an edit:

| # | Section | Covers |
|---|---------|--------|
| 1 | High-level architecture | Public surface, cache files, `az` CLI groups, env vars |
| 2 | `Connect-AzDevOps` | 6-step orchestrator + each `Confirm-*` step |
| 3 | `Test-AzDevOpsAuth` | Silent diagnostic chain (CLI → env → smoke) |
| 4 | `Sync-AzDevOpsCache` | Dataset fan-out, `Invoke-AzDevOpsAzDataset`, the 5 dataset descriptors |
| 5 | Cache consumers | `Get-/Open-AzDevOps{Assigned,Mentions}` |
| 6 | `Show-AzDevOpsTree` | Hierarchy render, `Format-AzDevOpsTreeNode`, icons |
| 7 | `New-AzDevOpsUserStory` | Interactive create + parent-link flow |
| 8 | Register/Unregister sync schedule | Platform branch via `Get-AzDevOpsPlatform` |
| 9 | Function dependency map | Every public function ↔ every helper |

Diagram 9 is the **completeness** diagram — every public and private AzDO function should appear there. The other eight are subsystem-specific.

---

## Step 1 — Trigger Detection

Identify Azure DevOps files that changed in this branch (vs `main`) and in the working tree:

```bash
{
  git diff --name-only main...HEAD 2>/dev/null
  git diff --name-only HEAD 2>/dev/null
} | sort -u > /tmp/azdo-all-changed
```

**Name-based match** — files whose path identifies them as Azure DevOps:

```bash
grep -E "(azdevops|/\.az_bashcuts$|pow_az_cli\.ps1$)" /tmp/azdo-all-changed > /tmp/azdo-trigger-byname || true
```

**Content-based match** — any other changed file in `bashcuts_by_cli/` or `powcuts_by_cli/` that invokes `az boards|devops|repos|pipelines`:

```bash
> /tmp/azdo-trigger-bycontent
while read f; do
  case "$f" in
    bashcuts_by_cli/*|powcuts_by_cli/*)
      [ -f "$f" ] && grep -qE "\baz (boards|devops|repos|pipelines)\b" "$f" && echo "$f" >> /tmp/azdo-trigger-bycontent
      ;;
  esac
done < /tmp/azdo-all-changed
```

**Combined trigger set:**

```bash
sort -u /tmp/azdo-trigger-byname /tmp/azdo-trigger-bycontent > /tmp/azdo-trigger
cat /tmp/azdo-trigger
```

**Gate:** if `/tmp/azdo-trigger` is empty → emit `N/A — no Azure DevOps source changes` and exit. Skip the rest of the skill.

---

## Step 2 — Was the Diagram Doc Touched?

```bash
{
  git diff --name-only main...HEAD 2>/dev/null
  git diff --name-only HEAD 2>/dev/null
} | grep -q "^docs/azure-devops-diagrams\.md$" && echo "TOUCHED" || echo "UNTOUCHED"
```

- `UNTOUCHED` + non-empty trigger set → likely STALE; continue to Step 3 to find what's missing.
- `TOUCHED` → still continue to Step 3 to verify accuracy of what was edited.

---

## Step 3 — Build the Function Inventory

Extract every `Verb-AzDevOpsNoun` function name from source and from the diagram doc, then compare.

**From source** (every `function <Verb>-AzDevOps<Noun>` in `powcuts_by_cli/*.ps1`):

```bash
grep -hoE "^function [A-Za-z]+-AzDevOps[A-Za-z]+" powcuts_by_cli/*.ps1 \
  | awk '{print $2}' | sort -u > /tmp/azdo-source-fns
```

**From the diagram doc** (every `Verb-AzDevOpsNoun` mentioned anywhere):

```bash
grep -ohE "[A-Za-z]+-AzDevOps[A-Za-z]+" docs/azure-devops-diagrams.md \
  | sort -u > /tmp/azdo-diagram-fns
```

**Comparisons:**

```bash
echo "== In source, missing from diagrams =="
comm -23 /tmp/azdo-source-fns /tmp/azdo-diagram-fns

echo "== In diagrams, missing from source =="
comm -13 /tmp/azdo-source-fns /tmp/azdo-diagram-fns
```

The first set → diagrams need to grow. The second set → diagrams reference deleted/renamed functions and need correction.

---

## Step 4 — `az` Subcommand Drift

Every `az boards <subcommand>` mentioned in the diagrams should still exist as a real call site or wrapper in source:

```bash
grep -ohE "az boards [a-z-]+( [a-z-]+)?" docs/azure-devops-diagrams.md \
  | sort -u > /tmp/azdo-diagram-subcmds

grep -hoE "\baz boards [a-z-]+( [a-z-]+)?" powcuts_by_cli/*.ps1 bashcuts_by_cli/.az_bashcuts 2>/dev/null \
  | sort -u > /tmp/azdo-source-subcmds

# Also include subcommands invoked indirectly through Invoke-AzDevOpsAzJson with an arg list starting at 'boards'
grep -hoE "Invoke-AzDevOpsAzJson +-ArgList +@\([^)]+\)" powcuts_by_cli/*.ps1 \
  | grep -oE "'boards', *'[a-z-]+'(, *'[a-z-]+')?" \
  | sed -E "s/'boards', *'([a-z-]+)'(, *'([a-z-]+)')?/az boards \1 \3/" \
  | sed 's/  */ /g; s/ $//' \
  | sort -u >> /tmp/azdo-source-subcmds

sort -u /tmp/azdo-source-subcmds -o /tmp/azdo-source-subcmds

echo "== Subcommands in diagrams, not in source =="
comm -23 /tmp/azdo-diagram-subcmds /tmp/azdo-source-subcmds

echo "== Subcommands in source, not in diagrams =="
comm -13 /tmp/azdo-diagram-subcmds /tmp/azdo-source-subcmds
```

---

## Step 5 — Classify Findings

For each gap from Steps 3 and 4, decide which diagrams to edit using the **Diagram → Subsystem Map** above:

| Finding type | Targets |
|---|---|
| New public function (`Get-`, `Open-`, `Show-`, `New-`, `Connect-`, `Sync-`, `Register-`, `Unregister-`) | The relevant subsystem diagram (#2-#8) **and** Diagram 9 |
| New private helper (`Invoke-`, `Read-`, `Write-`, `ConvertFrom-`, `ConvertTo-`, `Format-`, `Test-`, `Get-` if internal) | Diagram 9 only, unless it's central to a subsystem flow |
| Renamed function | Every diagram that referenced the old name |
| Removed function | Every diagram that referenced it (delete the node + adjust edges) |
| New `az boards <subcmd>` | Diagram 1 (architecture) + the subsystem diagram of the calling function |
| Removed `az boards <subcmd>` | Same diagrams, remove the node/edge |
| Wrapper-layer addition (e.g. new function in `azdevops_db.ps1`) | Diagram 9 — add under a "Data-plane wrappers" cluster; if missing, propose creating the cluster |

---

## Step 6 — Propose Concrete Edits

For each finding, draft the **exact** mermaid line(s) to add/change/remove, and quote the surrounding context so the user can see the placement. Format:

```
### Finding 1: New function `Add-AzDevOpsWorkItemRelation` (in azdevops_db.ps1)

Targets: Diagram 9 (function dependency map), Diagram 7 (New-AzDevOpsUserStory flow)

Proposed edit — Diagram 9, under "Sync helpers" / new "Data-plane wrappers" cluster:
    AddRel[Add-AzDevOpsWorkItemRelation]:::priv
    InvLink --> AddRel --> Az

Proposed edit — Diagram 7, replace:
    InvokeLink["Invoke-AzDevOpsParentLink<br/>az boards work-item relation add"]
With:
    InvokeLink["Invoke-AzDevOpsParentLink<br/>→ Add-AzDevOpsWorkItemRelation<br/>→ az boards work-item relation add"]

Apply? [Y/n]
```

Show all findings up front, then apply in batch on a single confirmation, OR apply individually — user's choice.

---

## Step 7 — Apply Edits

Use the `Edit` tool to apply each accepted change to `docs/azure-devops-diagrams.md`. Re-run Steps 3 and 4 after writing to confirm the gaps closed. Report any remaining drift.

---

## Output Format

```
## AzDO Diagrams Check Report

### Trigger
TRIGGERED — changed Azure DevOps files:
  • <file 1>
  • <file 2>
  ...
  OR
N/A — no Azure DevOps source changes (skill exits)

### Diagram Doc Touched in This Branch
TOUCHED — docs/azure-devops-diagrams.md included in the diff
  OR
UNTOUCHED — diagram doc not edited despite source changes

### Function Inventory
Source has N AzDevOps functions; diagrams reference M.
  • In source, missing from diagrams: <list>
  • In diagrams, missing from source: <list>

### az Subcommand Coverage
  • In diagrams, not in source: <list>
  • In source, not in diagrams: <list>

### Proposed Edits
1. <Finding> — target Diagram <N> — <one-line description>
2. ...

(each with diff snippet, applied on user confirmation)

---

## Verdict
CURRENT — diagrams already in sync with source
  OR
STALE — N proposed edits offered (auto-fix on confirm)
  OR
DRIFT — accuracy issues found in already-edited diagram (manual review needed)
```

---

## Notes for the auditor

- The diagram doc uses GitHub-flavoured mermaid; HTML line breaks are `<br/>` (not `\n`). Match the existing convention.
- Class definitions (`classDef pub fill:#1f3a5f,...`) live inside each diagram — when adding a new node, also assign the right class (`:::pub`, `:::priv`, `:::io`).
- The dependency map (Diagram 9) is the only one that's expected to be **complete**. Subsystem diagrams (#2-#8) are intentionally focused — don't dump every helper into them. Use the subsystem map above to decide.
- Don't propose cosmetic rewrites (rephrasing labels, reformatting) — only propose edits that close a real source-vs-doc gap.
- If the source change is a **pure refactor** (a new wrapper interposed between an existing caller and an existing `az` invocation, like the `Invoke-AzDevOpsAzJson` → wrapper layer added in issue #23), the diagrams should reflect the new intermediate node — propose adding it to Diagram 9 and updating the relevant call-chain in the affected subsystem diagram.
