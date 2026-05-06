---
name: criteria-check
description: Verifies every acceptance criterion in the linked GitHub issue is satisfied by the current build — maps each criterion to code evidence, flags gaps, and posts a verdict to the PR.
---

You are the **acceptance criteria verifier** for bashcuts. Load the GitHub issue for the current branch, extract every acceptance criterion, and verify each one against the current shell scripts and configuration.

**Repo:** `jdschleicher/bashcuts`

---

## Step 1 — Identify the Issue Number

Extract from the branch name:

```bash
git branch --show-current
```

Check the PR body if not in the branch name:

```bash
gh pr view --json body --jq '.body' 2>/dev/null | grep -o "Closes #[0-9]*" | head -1
```

---

## Step 2 — Load Acceptance Criteria

```bash
gh issue view <N> --repo jdschleicher/bashcuts --json body --jq '.body' 2>/dev/null
```

Parse the issue body for the **Acceptance Criteria** section. Extract every checkbox item (`- [ ]` or `- [x]`).

If no Acceptance Criteria section exists, report:
> ⚠️ No "Acceptance Criteria" section found in issue #N. Nothing to verify.

---

## Step 3 — Verify Each Criterion

Determine the verification strategy based on what the criterion describes:

| Criterion type | How to verify |
|---|---|
| A bash alias exists | `grep -n "alias <name>=" bashcuts_by_cli/.<file>` |
| A bash function exists | `grep -n "^<name>()" bashcuts_by_cli/.<file>` or `grep -n "function <name>" bashcuts_by_cli/.<file>` |
| A PowerShell function exists | `grep -n "function <Verb-Noun>" powcuts_by_cli/<file>.ps1` |
| Both shells have the equivalent | Check `bashcuts_by_cli/` and `powcuts_by_cli/` separately |
| New file is sourced from `.bcut_home` | `grep -n "<filename>" .bcut_home` |
| New file is dot-sourced from `powcuts_home.ps1` | `grep -n "<filename>" powcuts_home.ps1` |
| README documents a new section | `grep -n "<heading>" README.md` |
| Tab-completion works | Manual — open a fresh bash shell, type `<verb>-` + tab-tab |

**Evidence levels:**

- ✅ **VERIFIED** — direct evidence found in the shell script or config
- ⚠️ **PARTIAL** — partial evidence; something may be missing
- ❌ **MISSING** — no evidence found in any file
- 🔍 **MANUAL** — criterion requires hands-on terminal testing (tab-completion, prompt UX, mac `start` aliasing, etc.)

**Rules:**
- Always grep actual files — never assume from memory
- For criteria about both shells, check `bashcuts_by_cli/` AND `powcuts_by_cli/` explicitly
- For criteria about loading/sourcing, verify the wire-up in `.bcut_home` or `powcuts_home.ps1`
- For criteria about tab-completion, prompts, or interactive UX, mark MANUAL

---

## Step 4 — Syntax Sanity Check

```bash
# Catch obvious bash syntax errors in any changed shell file
for f in $(git diff main...HEAD --name-only | grep -E "bashcuts_by_cli/|\.bcut_home"); do
  bash -n "$f" 2>&1 && echo "OK: $f" || echo "SYNTAX ERROR: $f"
done
```

```bash
# PowerShell parse check (only if pwsh is on PATH)
for f in $(git diff main...HEAD --name-only | grep -E "powcuts_by_cli/|powcuts_home\.ps1"); do
  if command -v pwsh >/dev/null 2>&1; then
    pwsh -NoProfile -Command "[System.Management.Automation.Language.Parser]::ParseFile('$f', [ref]\$null, [ref]\$null) | Out-Null" 2>&1 \
      && echo "OK: $f" || echo "PARSE ERROR: $f"
  else
    echo "SKIP (pwsh not available): $f"
  fi
done
```

Report as standalone criteria:
- ✅ Bash syntax: all changed files parse cleanly
- ✅ PowerShell parse: all changed files parse cleanly (or ⏭️ skipped if pwsh unavailable)

---

## Step 5 — Build the Report

```
## Criteria Check — #<issue-number>: <issue-title>

### Syntax Checks
✅ Bash: all changed files parse cleanly
✅ PowerShell: all changed files parse cleanly  *(or ⏭️ SKIPPED — pwsh not on PATH)*

### Acceptance Criteria

| # | Criterion | Status | Evidence |
|---|-----------|--------|----------|
| 1 | <criterion text> | ✅ VERIFIED | `bashcuts_by_cli/.sfdxcli_bashcuts:42` — `alias deploy-source=...` present |
| 2 | PowerShell equivalent exists | ✅ VERIFIED | `powcuts_by_cli/sfdx_cli.ps1:38` — `function Deploy-Source` present |
| 3 | New file wired into .bcut_home | ✅ VERIFIED | `.bcut_home:55` sources new file |
| 4 | Tab-completion works | 🔍 MANUAL | alias is defined; verify `deploy-` + tab-tab in a fresh bash shell |

### Summary

| Status | Count |
|--------|-------|
| ✅ VERIFIED | N |
| ⚠️ PARTIAL | N |
| ❌ MISSING | N |
| 🔍 MANUAL | N |

### Manual Verification Checklist

- [ ] <criterion> — what to type in a fresh bash terminal to verify
- [ ] <criterion> — what to type in a fresh PowerShell terminal to verify

### Verdict

✅ PASS — all automated criteria verified, N items need manual terminal testing.
  OR
❌ FAIL — N criteria missing or partial: <list them>.
```

---

## Step 6 — Post to PR

```bash
gh pr view --json number 2>/dev/null --jq '.number'
gh pr comment <number> --body "$(cat <<'EOF'
## ✅ Criteria Check — #<issue-number>
<report>
EOF
)"
```

---

## Handling Criterion Drift

If a criterion uses different terminology than the code (e.g., issue says "open jira" but the alias is `o-jira`), note the discrepancy and verify the intent:

> ⚠️ Issue says "open-jira" — implementation uses `o-jira` (matches existing `o-` open prefix convention). Functional intent verified.

---

## Output Notes

- Keep the Evidence column concise: `file:line — brief description`
- For shell parity criteria, reference both files explicitly
- Don't pad with vague evidence — if you can't find it, mark MISSING
- When pwsh isn't available, mark PowerShell parse as SKIPPED rather than guessing
