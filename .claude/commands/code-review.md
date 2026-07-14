---
name: code-review
description: Quint code review — senior bash engineer, senior PowerShell engineer, senior security engineer, senior clean-code engineer, and senior front-end engineer run in parallel against the current branch's changes.
---

## Quint Review — Five Reviewers in Parallel

This skill runs **five independent code reviews in parallel** using the Agent tool:

1. **Senior Bash Engineer** — invoke `/senior-bash-engineer`
2. **Senior PowerShell Engineer** — invoke `/senior-powershell-engineer`
3. **Senior Security Engineer** — invoke `/security-review` (built-in)
4. **Senior Clean-Code Engineer** — invoke `/senior-clean-code-engineer` (duplication, function shape, abstraction debt; enforces CLAUDE.md's extract-repeated-branches + breathing-room rules)
5. **Senior Front-End Engineer** — invoke `/senior-frontend-engineer` (semantic HTML + accessibility, CSS token/specificity/unit hygiene, data-driven rendering, untrusted-data escaping; owns the `daily-viewer/` web surface)

Launch all five as parallel agents. Each independently determines changed files, reads them, and produces its own report. After all complete, present the five reports sequentially — bash, PowerShell, security, clean-code, then front-end.

**PR comments:** If a PR exists, each review posts its own comment to the PR — five separate comments, clearly labeled with `## 🐚`, `## 💠`, `## 🛡️`, `## 🧼`, and `## 🎨` headings.

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

| Path pattern | Reviewer(s) that own it |
|---|---|
| `bashcuts_by_cli/*`, `.bcut_home` | Senior Bash Engineer + Senior Clean-Code Engineer |
| `powcuts_by_cli/*.ps1`, `powcuts_home.ps1` | Senior PowerShell Engineer + Senior Clean-Code Engineer |
| `daily-viewer/*`, `*.html`, `*.css`, `*.js` | Senior Front-End Engineer (+ Senior PowerShell Engineer for the backend `.ps1`) |
| `vscode_snippets/*` | (no reviewer; flag for security only) |
| `README.md` | (no reviewer; flag for `/docs-check`) |

Each reviewer returns early with `APPROVE — no <kind> files in this diff` when its files aren't touched (e.g. the front-end engineer on a pure-PowerShell diff, or the bash engineer when only `daily-viewer/` changed). The clean-code and security engineers review broadly. That's expected and not a problem.

---

## Launch the Four Reviews in Parallel

Send a single message with four Agent tool calls. For each, pass enough context that the agent can run independently:

1. **Bash Engineer Agent** — task: "Run the `/senior-bash-engineer` review on the current branch's diff against `main`. Read the skill at `.claude/commands/senior-bash-engineer.md` and follow it. Post the result to the PR if one exists."

2. **PowerShell Engineer Agent** — task: "Run the `/senior-powershell-engineer` review on the current branch's diff against `main`. Read the skill at `.claude/commands/senior-powershell-engineer.md` and follow it. Post the result to the PR if one exists."

3. **Security Engineer Agent** — task: "Run the `/security-review` skill on the current branch's pending changes. Post the result to the PR if one exists."

4. **Clean-Code Engineer Agent** — task: "Run the `/senior-clean-code-engineer` review on the current branch's diff against `main`. Read the skill at `.claude/commands/senior-clean-code-engineer.md` and follow it. Focus on duplicated branches across functions, oversized functions, parallel function pairs sharing scaffolding, magic numbers, and the named CLAUDE.md extract-repeated-branches + breathing-room rules. Post the result to the PR if one exists."

5. **Front-End Engineer Agent** — task: "Run the `/senior-frontend-engineer` review on the current branch's diff against `main`. Read the skill at `.claude/commands/senior-frontend-engineer.md` and follow it. Focus on the `daily-viewer/` web surface: untrusted-data escaping (XSS via innerHTML), semantic HTML + accessibility, CSS token/specificity/unit hygiene, data-driven rendering vs hardcoded markup, CSP-hostile patterns, and secrets never reaching the browser. Post the result to the PR if one exists."

Wait for all five to complete before continuing.

---

## Aggregate the Reports

Present the five reports sequentially in the user-facing summary:

```
## 🐚 Senior Bash Engineer
<report from agent 1>

---

## 💠 Senior PowerShell Engineer
<report from agent 2>

---

## 🛡️ Senior Security Engineer
<report from agent 3>

---

## 🧼 Senior Clean-Code Engineer
<report from agent 4>

---

## 🎨 Senior Front-End Engineer
<report from agent 5>
```

Then output a combined verdict:

```
## Combined Verdict

| Reviewer | Verdict |
|----------|---------|
| 🐚 Bash Engineer | ✅ APPROVE / ❌ REQUEST CHANGES (N issues) |
| 💠 PowerShell Engineer | ✅ APPROVE / ❌ REQUEST CHANGES (N issues) |
| 🛡️ Security Engineer | ✅ APPROVE / ❌ REQUEST CHANGES (N issues) |
| 🧼 Clean-Code Engineer | ✅ APPROVE / ❌ REQUEST CHANGES (N issues) |
| 🎨 Front-End Engineer | ✅ APPROVE / ❌ REQUEST CHANGES (N issues) |

### Overall
✅ APPROVE — all five reviewers passed
  OR
❌ REQUEST CHANGES — <list blocking findings, grouped by reviewer>
```

---

## Update PR Body ToC

After all five reviewers have posted their comments to the PR, run `/pr-body` to refresh the table of contents so reviewers can navigate to each report from the PR body.
