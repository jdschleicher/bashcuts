---
name: pr-flow
description: Full PR pipeline for bashcuts — syntax checks, commit, push, create PR, quad code review (bash + PowerShell + security + clean-code), criteria check, docs check, pr-body ToC. One command to ship.
---

You are the full PR pipeline orchestrator for bashcuts (bash + PowerShell shortcuts repo). Run every check in the correct order, gate on failures, and produce a fully reviewed, documented PR.

**Repo:** `jdschleicher/bashcuts`

## Overview

1. **Phase 1** — Pre-commit checks (bash syntax, PowerShell parse, shell parity, sourcing wire-up)
2. **Phase 2** — Commit, push, create PR
3. **Phase 3** — Triple code review (`/code-review` — bash + PowerShell + security in parallel)
4. **Phase 4** — Docs check (`/docs-check`)
5. **Phase 5** — Criteria check (`/criteria-check`)
6. **Phase 5b** — AzDO diagrams check (`/azdevops-diagrams-check`) — runs only when Azure DevOps source files changed
7. **Phase 6** — PR body ToC (`/pr-body`)

Each phase gates on the previous. If Phase 1 fails, stop.

---

## Phase 1 — Pre-Commit Checks

Run these checks inline with Bash tools. Do NOT invoke `/docs-check` or other skills here — execute each check directly.

**1a. Identify changed shell files:**
```bash
git diff --name-only main...HEAD 2>/dev/null
git diff --name-only HEAD 2>/dev/null
```

**1b. Bash syntax:**
```bash
for f in $(git diff --name-only main...HEAD 2>/dev/null; git diff --name-only HEAD 2>/dev/null) ; do
  case "$f" in
    bashcuts_by_cli/*|.bcut_home)
      bash -n "$f" 2>&1 && echo "OK: $f" || echo "SYNTAX ERROR: $f"
      ;;
  esac
done | sort -u
```
Pass: every changed bash file parses with no syntax errors.

**1c. PowerShell parse (only if pwsh is on PATH):**
```bash
if command -v pwsh >/dev/null 2>&1; then
  for f in $(git diff --name-only main...HEAD 2>/dev/null; git diff --name-only HEAD 2>/dev/null) ; do
    case "$f" in
      powcuts_by_cli/*|powcuts_home.ps1)
        pwsh -NoProfile -Command "[System.Management.Automation.Language.Parser]::ParseFile('$f', [ref]\$null, [ref]\$null) | Out-Null" 2>&1 \
          && echo "OK: $f" || echo "PARSE ERROR: $f"
        ;;
    esac
  done | sort -u
else
  echo "SKIPPED — pwsh not on PATH"
fi
```
Pass: every changed `.ps1` file parses, or pwsh unavailable (skipped, not failed).

**1d. Sourcing wire-up — new files must be loaded:**

For every brand-new file under `bashcuts_by_cli/`, verify a matching sourcing block exists in `.bcut_home`:
```bash
git diff --name-only --diff-filter=A main...HEAD 2>/dev/null | grep "^bashcuts_by_cli/" | while read f; do
  base=$(basename "$f")
  grep -q "$base" .bcut_home && echo "WIRED: $f" || echo "ORPHAN: $f (not sourced from .bcut_home)"
done
```

Same for PowerShell:
```bash
git diff --name-only --diff-filter=A main...HEAD 2>/dev/null | grep "^powcuts_by_cli/" | while read f; do
  base=$(basename "$f")
  grep -q "$base" powcuts_home.ps1 && echo "WIRED: $f" || echo "ORPHAN: $f (not dot-sourced from powcuts_home.ps1)"
done
```
Pass: zero ORPHAN entries.

**1e. Shell parity (warning, not blocker):**
```bash
git diff --name-only main...HEAD 2>/dev/null | grep -E "^bashcuts_by_cli/|^powcuts_by_cli/" || true
```
If only one shell's files changed, surface it as a warning — the user may have intentionally made a shell-specific change, but flag it so they can confirm.

**1f. Debug / leftover artifacts:**
```bash
git diff main...HEAD -- bashcuts_by_cli/ powcuts_by_cli/ .bcut_home powcuts_home.ps1 2>/dev/null \
  | grep -E "^\+" \
  | grep -iE "TODO|FIXME|XXX|console\.log|Write-Debug|set -x" || true
```
Pass: zero matches (or only intentional ones the user accepts).

**Gate:** If 1b, 1c, or 1d fails, stop. Tell the user what failed. Do not proceed to Phase 2.

---

## Phase 2 — Commit, Push, and PR

```bash
git status
git branch --show-current
```

**2a. Commit (if uncommitted changes):**
Stage changed files by name (not `git add .`). Ask the user for a commit message or draft one. Commit.

**2b. Push:**
```bash
git push -u origin $(git branch --show-current)
```

**2c. Create PR (if none exists):**
```bash
gh pr view --repo jdschleicher/bashcuts --json number,url 2>/dev/null
```
If no PR:
1. Extract issue number from branch name if present
2. Look up issue title: `gh issue view <N> --repo jdschleicher/bashcuts --json title`
3. Create PR:
   ```bash
   gh pr create \
     --repo jdschleicher/bashcuts \
     --title "<title>" \
     --body "$(cat <<'EOF'
   ## Summary
   <brief description>

   ## Issue
   Closes #<N>

   ## Changes
   <list changed shortcut files / new aliases or functions>

   ## Test Plan
   - [ ] Open a fresh bash terminal — `<verb>-` + tab-tab autocompletes the new alias/function
   - [ ] Run the new alias/function and confirm expected behavior
   - [ ] Open a fresh PowerShell terminal — `<Verb-Noun>` runs without parse errors  *(if PowerShell parity)*
   EOF
   )"
   ```

If a PR already exists, note its number and URL and continue.

---

## Phase 3 — Quad Code Review

Invoke `/code-review`. This launches four reviewers in parallel:
- 🐚 Senior Bash Engineer
- 💠 Senior PowerShell Engineer
- 🛡️ Senior Security Engineer (`/security-review`)
- 🧼 Senior Clean-Code Engineer (`/senior-clean-code-engineer`) — duplication, function shape, abstraction debt; enforces CLAUDE.md's extract-repeated-branches + breathing-room rules

Each posts its own comment to the PR. Wait for all four to complete.

**Gate:** If any reviewer returns `REQUEST CHANGES` on a CRITICAL finding, surface it to the user and ask whether to proceed or fix first. HIGH/MEDIUM findings are non-blocking but should be summarized. Clean-code HIGH findings (named CLAUDE.md violations like duplicated branches across 2+ functions) are blocking — fix before merging.

---

## Phase 4 — Docs Check

Invoke `/docs-check` as an Agent. Wait for completion.

**Gate:** If `STALE` findings exist (e.g. orphaned shortcut file, dead sourcing reference), surface them and ask whether to proceed or fix first. Cosmetic README drift is non-blocking; orphaned files in `bashcuts_by_cli/` or `powcuts_by_cli/` are blocking (users won't get the new shortcut).

---

## Phase 5 — Criteria Check

Invoke `/criteria-check`. Wait for completion.

If no Acceptance Criteria section exists in the linked issue, note it and continue.

---

## Phase 5b — Azure DevOps Diagrams Check

Invoke `/azdevops-diagrams-check`. The skill self-gates: if no Azure DevOps source files changed in this branch (none of `powcuts_by_cli/azdevops_*.ps1`, `powcuts_by_cli/pow_az_cli.ps1`, `bashcuts_by_cli/.az_bashcuts`, or any other file containing `az boards|devops|repos|pipelines`), it exits with `N/A` and Phase 5b is a no-op.

When triggered, the skill compares `docs/azure-devops-diagrams.md` against the current source — function inventory, `az` subcommand coverage — and proposes concrete mermaid edits for each gap. Edits apply on user confirmation.

**Gate:** STALE without applied fixes is **blocking** (the diagram doc misleads readers if it lags the code). DRIFT-only findings (already-edited diagrams that still don't fully match source) are non-blocking but must be summarized so the user can decide.

---

## Phase 6 — PR Body ToC

Invoke `/pr-body` to aggregate all skill report verdicts and update the PR body navigation hub.

---

## Final Summary

```
## PR Flow Complete — PR #<number>

### Phase Results
| Phase | Result |
|-------|--------|
| Bash Syntax | ✅ PASS |
| PowerShell Parse | ✅ PASS / ⏭️ SKIPPED |
| Sourcing Wire-up | ✅ WIRED |
| Shell Parity | ✅ MATCHED / ⚠️ bash-only / ⚠️ pwsh-only |
| Debug Artifacts | ✅ CLEAN |
| 🐚 Bash Engineer Review | ✅ APPROVE / ❌ REQUEST CHANGES |
| 💠 PowerShell Engineer Review | ✅ APPROVE / ❌ REQUEST CHANGES |
| 🛡️ Security Audit | ✅ PASS / ❌ FAIL |
| 🧼 Clean-Code Engineer Review | ✅ APPROVE / ❌ REQUEST CHANGES |
| Docs Check | ✅ CURRENT / ⚠️ <stale items> |
| Criteria Check | ✅ PASS / ⏭️ no AC section |
| AzDO Diagrams Check | ✅ CURRENT / ⏭️ N/A / ⚠️ <stale sections> |
| PR Body | ✅ Updated |

### PR
**#<number>** — <title>
**URL:** <url>

### Verdict
✅ READY TO MERGE
  OR
⚠️ NEEDS ATTENTION — <list blocking issues>
```
