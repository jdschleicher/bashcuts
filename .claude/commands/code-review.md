---
name: code-review
description: Triple code review — senior bash engineer, senior PowerShell engineer, and senior security engineer run in parallel against the current branch's changes.
---

## Triple Review — Three Reviewers in Parallel

This skill runs **three independent code reviews in parallel** using the Agent tool:

1. **Senior Bash Engineer** — invoke `/senior-bash-engineer`
2. **Senior PowerShell Engineer** — invoke `/senior-powershell-engineer`
3. **Senior Security Engineer** — invoke `/security-review` (built-in)

Launch all three as parallel agents. Each independently determines changed files, reads them, and produces its own report. After all complete, present the three reports sequentially — bash first, then PowerShell, then security.

**PR comments:** If a PR exists, each review posts its own comment to the PR — three separate comments, clearly labeled with `## 🐚`, `## 💠`, and `## 🛡️` headings.

---

## Pre-Review: Commit & Push Gate

Before reviewing, ensure everything is committed and pushed:

```bash
git status
git log --oneline -5
git branch --show-current
```

If there are uncommitted changes, ask the user whether to commit them before proceeding — the reviewers diff against `main`, so uncommitted work would be missed.

---

## Pre-Review: Determine Diff Scope

```bash
git diff main...HEAD --name-only 2>/dev/null
```

Categorize the changed files:

| Path pattern | Reviewer that owns it |
|---|---|
| `bashcuts_by_cli/*`, `.bcut_home` | Senior Bash Engineer |
| `powcuts_by_cli/*.ps1`, `powcuts_home.ps1` | Senior PowerShell Engineer |
| `vscode_snippets/*` | (no reviewer; flag for security only) |
| `README.md` | (no reviewer; flag for `/docs-check`) |

If only one shell's files changed, the other reviewer will return early with `APPROVE — no <shell> files in this diff`. That's expected and not a problem.

---

## Launch the Three Reviews in Parallel

Send a single message with three Agent tool calls. For each, pass enough context that the agent can run independently:

1. **Bash Engineer Agent** — task: "Run the `/senior-bash-engineer` review on the current branch's diff against `main`. Read the skill at `.claude/commands/senior-bash-engineer.md` and follow it. Post the result to the PR if one exists."

2. **PowerShell Engineer Agent** — task: "Run the `/senior-powershell-engineer` review on the current branch's diff against `main`. Read the skill at `.claude/commands/senior-powershell-engineer.md` and follow it. Post the result to the PR if one exists."

3. **Security Engineer Agent** — task: "Run the `/security-review` skill on the current branch's pending changes. Post the result to the PR if one exists."

Wait for all three to complete before continuing.

---

## Aggregate the Reports

Present the three reports sequentially in the user-facing summary:

```
## 🐚 Senior Bash Engineer
<report from agent 1>

---

## 💠 Senior PowerShell Engineer
<report from agent 2>

---

## 🛡️ Senior Security Engineer
<report from agent 3>
```

Then output a combined verdict:

```
## Combined Verdict

| Reviewer | Verdict |
|----------|---------|
| 🐚 Bash Engineer | ✅ APPROVE / ❌ REQUEST CHANGES (N issues) |
| 💠 PowerShell Engineer | ✅ APPROVE / ❌ REQUEST CHANGES (N issues) |
| 🛡️ Security Engineer | ✅ APPROVE / ❌ REQUEST CHANGES (N issues) |

### Overall
✅ APPROVE — all three reviewers passed
  OR
❌ REQUEST CHANGES — <list blocking findings, grouped by reviewer>
```

---

## Update PR Body ToC

After all three reviewers have posted their comments to the PR, run `/pr-body` to refresh the table of contents so reviewers can navigate to each report from the PR body.
