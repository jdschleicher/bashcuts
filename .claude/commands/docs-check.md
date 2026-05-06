---
name: docs-check
description: Audits README.md against the actual shortcut files in bashcuts_by_cli/ and powcuts_by_cli/ — verifies setup instructions are still accurate and any documented CLI sections still exist. Update stale sections automatically.
---

You are the documentation auditor for bashcuts. Verify that `README.md` accurately reflects the current state of the repo's shortcut files and setup instructions, and fix staleness automatically where possible.

---

## Check 1 — Shell Setup Snippets Reference Real Files

The README contains bash and PowerShell setup snippets that reference `.bcut_home` and `powcuts_home.ps1`. Verify both files exist:

```bash
ls -la .bcut_home powcuts_home.ps1 2>&1
```

**Pass:** both files present.
**Fail:** README points users to a file that no longer exists.

---

## Check 2 — All `bashcuts_by_cli/` Files Are Sourced from `.bcut_home`

Every shortcut file in `bashcuts_by_cli/` should be sourced from `.bcut_home` (otherwise users won't get it after setup):

```bash
ls bashcuts_by_cli/
echo "---"
grep -oE "bashcuts_by_cli/\.[a-z_]+" .bcut_home | sort -u
```

Compare the two lists. Flag:
- Files in `bashcuts_by_cli/` not sourced from `.bcut_home` (orphaned shortcut file)
- Sourcing blocks in `.bcut_home` pointing to files that don't exist (dead reference)

---

## Check 3 — All `powcuts_by_cli/` Files Are Dot-Sourced from `powcuts_home.ps1`

Same check for PowerShell:

```bash
ls powcuts_by_cli/
echo "---"
grep -oE "powcuts_by_cli/[a-z_]+\.ps1|powcuts_by_cli\\\\[a-z_]+\.ps1" powcuts_home.ps1 | sort -u
```

Flag any orphaned `.ps1` files or dead references.

---

## Check 4 — Bash / PowerShell Parity

For every `.<cli>_bashcuts` file, there should typically be a matching `<cli>.ps1` (and vice versa). Spot mismatches:

```bash
# Normalize names: .ghcli_bashcuts → ghcli, gh_cli.ps1 → gh_cli, etc.
echo "Bash CLIs:"
ls bashcuts_by_cli/ | sed -E 's/^\.//; s/_bashcuts$//' | sort -u

echo "PowerShell CLIs:"
ls powcuts_by_cli/ | sed -E 's/\.ps1$//' | sort -u
```

Flag CLI names that exist in only one of the two directories. Some intentional asymmetries exist (e.g. `.bash_commons` vs `pow_common.ps1`), so use judgment — not every mismatch is a bug.

---

## Check 5 — README CLI Sections vs Actual Files

Scan the README for CLI/tool mentions in the prerequisites and setup sections:

```bash
grep -nE "sfdx|gh CLI|GitHub CLI|CumulusCI|jq|cci|az |Azure" README.md
```

Cross-reference with the shortcut files that exist. Flag:
- Tools listed in the README prerequisites that no longer have a shortcut file (stale prereq)
- New shortcut files (e.g. a brand-new CLI wrapper) not mentioned anywhere in the README

---

## Check 6 — Setup Snippet Currency

The README setup snippets in the **System Setup** section show inline bash and PowerShell loaders. Verify they still match what `.bcut_home` and `powcuts_home.ps1` actually do at the top:

```bash
head -15 .bcut_home
echo "---"
head -15 powcuts_home.ps1
```

Flag if the README snippet syntax has drifted from the real entry-point file (e.g. variable names changed, file moved).

---

## Auto-Fix Offer

For each staleness finding, offer to fix it:

1. **Orphaned shortcut file** — add a sourcing block to `.bcut_home` or `powcuts_home.ps1`
2. **Dead reference** — remove the sourcing block from the entry-point file
3. **README missing a new CLI** — add a bullet to the prerequisites list and a brief mention under "How to use bashcuts"
4. **README snippet drift** — update the README code block to match the real entry-point

Always show the proposed change and ask for confirmation before writing.

---

## Output Format

```
## Docs Check Report

### Check 1 — Setup Files Exist
PASS — `.bcut_home` and `powcuts_home.ps1` both present
  OR
FAIL — `<file>` referenced by README is missing

### Check 2 — Bash Sourcing Coverage
PASS — all N files in bashcuts_by_cli/ are sourced from .bcut_home
  OR
STALE — orphaned: <list>; dead refs: <list>

### Check 3 — PowerShell Sourcing Coverage
PASS — all N files in powcuts_by_cli/ are dot-sourced from powcuts_home.ps1
  OR
STALE — orphaned: <list>; dead refs: <list>

### Check 4 — Shell Parity
PASS — bash and PowerShell CLI sets match
  OR
NOTE — bash-only: <list>; pwsh-only: <list>  (intentional? confirm)

### Check 5 — README CLI Mentions
PASS — README prerequisites match the shortcut files in the repo
  OR
STALE — README mentions <tool> but no shortcut file; <file> exists but README doesn't mention <tool>

### Check 6 — Setup Snippet Currency
PASS — README snippets match the real entry-point files
  OR
STALE — README shows `<old syntax>`; real file uses `<new syntax>`

---

## Verdict

CURRENT — all documentation is accurate.
  OR
STALE — update the documents flagged above (offers to auto-fix each).
```
