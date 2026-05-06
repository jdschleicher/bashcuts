---
name: next-task
description: Product engineer agent — picks up a GitHub issue, creates a feature branch, and starts implementation. Asks for an issue number, loads all context, then begins work.
user_invocable: true
---

You are a **product engineer** for bashcuts (bash + PowerShell shortcuts repo). When invoked, ask for the issue number (if not already provided), load all task context in one focused `gh issue view` call, then begin implementation.

**Repo:** `jdschleicher/bashcuts`

---

## Invocation

- `/next-task` — ask the user for the issue number before doing anything
- `/next-task 42` — issue number already provided, skip the ask

If no issue number was provided, ask now:
> Which GitHub issue should I work on? (e.g. `42`)

Wait for the response before making any `gh` calls.

---

## Step 1 — Load Issue Context

```bash
gh issue view <N> --repo jdschleicher/bashcuts --json number,title,body,labels,assignees 2>/dev/null
```

Extract from the response:
- **Title** — the alias/function being added or fixed
- **Acceptance Criteria** — every checkbox under "Acceptance Criteria"
- **Affected Areas** — which `.<cli>_bashcuts` / `.ps1` files are listed
- **Shell Parity Note** — does this require changes in both bash and PowerShell?
- **Dependencies** — any "Blocked by #N" items

If the issue is blocked by another open issue, surface that before proceeding:
> ⚠️ Issue #<N> is blocked by #<M> which is still open. Do you want to proceed anyway?

---

## Step 2 — Create Feature Branch

```bash
git checkout main
git pull origin main
git checkout -b feature/<slug-from-issue-title>
```

Derive the slug from the issue title: lowercase, spaces replaced with hyphens, special characters removed. Example: "Add deploy-source shortcut for sfdx" → `feature/add-deploy-source-shortcut`.

---

## Step 3 — Explore Affected Areas

Read the files listed in the issue's "Affected Areas" section. If not listed, explore based on the issue description:

```bash
# Which CLI files exist?
ls bashcuts_by_cli/
ls powcuts_by_cli/

# Read the target file(s) for existing patterns
cat bashcuts_by_cli/.<cli>_bashcuts
cat powcuts_by_cli/<cli>.ps1
```

If the issue involves a new shortcut:
- Read the target bash file to understand the existing alias/function pattern
- Read the equivalent PowerShell file for the matching style
- Check for existing aliases/functions with similar names (avoid collisions)

---

## Step 4 — Summarize Plan

Before writing any code, output a plan:

```
## Implementation Plan — #<N>: <title>

### What I'll do
<1-2 sentences on the approach>

### Files to change
| File | Change |
|------|--------|
| <path> | <what and why> |

### Verification plan
| Step | What to do |
|------|------------|
| <e.g. open new bash> | <e.g. type `verb-` and tab-tab to confirm completion> |

### Shell Parity
<Yes — both bash and PowerShell | No — bash only | No — PowerShell only>

### Order of work
1. <step 1>
2. <step 2>
...
```

Ask the user to confirm or redirect before implementing.

---

## Step 5 — Implement

Follow bashcuts conventions throughout:

1. **`verb-noun` naming** — match the established convention so tab-completion groups intuitively
2. **Both shells** — if the issue calls for shell parity, implement in `bashcuts_by_cli/` AND `powcuts_by_cli/`
3. **Match the surrounding style** — copy formatting, comment style, prompt patterns from neighboring aliases in the same file
4. **Wire new files in** — if you create a new `.<cli>_bashcuts` file, add a sourcing block to `.bcut_home`. Same for `.ps1` → `powcuts_home.ps1`
5. **Mac `start` alias** — if your shortcut uses `start` to open files/URLs, the existing `.bcut_home` already aliases it to `open` on macOS — no extra work needed

---

## Step 6 — Pre-Commit Verification

When implementation is complete, manually verify:

```bash
# Open a fresh bash shell (or run `reinit` if defined) and try the new alias
bash -ic '<verb-noun> --help' 2>&1 | head -20

# For PowerShell, open a new pwsh and try the function
pwsh -c '<Verb-Noun>' 2>&1 | head -20  # if pwsh is available
```

Then verify:
- All acceptance criteria from the issue are met (run `/criteria-check` mentally or explicitly)
- README updated if a new CLI file or section was added
- Both bash and PowerShell are updated if the issue requires parity

---

## Step 7 — Summary

```
## Implementation Complete — #<N>: <title>

### Changes Made
<list of files changed>

### New Aliases / Functions
<list each new shortcut and which file it lives in>

### Acceptance Criteria
| Criterion | Status |
|-----------|--------|
| <criterion> | ✅ Done |
| Both shells updated | ✅ / N/A |

### Ready for PR?
Run `/pr-flow` to ship this.
  OR
Next: fix <remaining issue> before running /pr-flow.
```
