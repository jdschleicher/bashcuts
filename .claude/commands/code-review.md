---
name: code-review
description: Septet code review — senior bash, PowerShell, security, clean-code, front-end, Azure resources, and Entra ID engineers run in parallel against the current branch's changes.
---

## Septet Review — Seven Reviewers in Parallel

This skill runs **seven independent code reviews in parallel** using the Agent tool:

1. **Senior Bash Engineer** — invoke `/senior-bash-engineer`
2. **Senior PowerShell Engineer** — invoke `/senior-powershell-engineer`
3. **Senior Security Engineer** — invoke `/security-review` (built-in)
4. **Senior Clean-Code Engineer** — invoke `/senior-clean-code-engineer` (duplication, function shape, abstraction debt; enforces CLAUDE.md's extract-repeated-branches + breathing-room rules)
5. **Senior Front-End Engineer** — invoke `/senior-frontend-engineer` (semantic HTML + accessibility, CSS token/specificity/unit hygiene, data-driven rendering, untrusted-data escaping; owns the `daily-viewer/` web surface)
6. **Senior Azure Resources Engineer** — invoke `/senior-azure-resources-engineer` (ARM / RBAC correctness, `az` flag + output-shape audit, subscription fan-out cost, Windows `az.cmd` argument safety, read-only guarantee)
7. **Senior Entra ID Engineer** — invoke `/senior-entra-identity-engineer` (identity provider / authentication services: token + secret exposure, sign-in type coverage, Microsoft Graph correctness, app registration vs service principal semantics, credential metadata)

Launch all seven as parallel agents. Each independently determines changed files, reads them, and produces its own report. After all complete, present the seven reports sequentially — bash, PowerShell, security, clean-code, front-end, Azure resources, then Entra ID.

A reviewer whose scope gate finds nothing in the diff returns its `APPROVE — no … in this diff` verdict immediately; the orchestrator may post that verdict directly instead of spawning an agent for it.

**PR comments:** If a PR exists, each review posts its own comment to the PR — seven separate comments, clearly labeled with `## 🐚`, `## 💠`, `## 🛡️`, `## 🧼`, `## 🎨`, `## ☁️`, and `## 🔐` headings.

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
| `powcuts_by_cli/azresources_*.ps1`, `azure-viewer/*`, `.az_bashcuts`, any `az role\|resource\|identity\|account\|graph` call | Senior Azure Resources Engineer |
| `azdevops_auth.ps1`, `azresources_*.ps1`, any `az ad`, `az rest` → Graph, `az login`, token / PAT / credential handling | Senior Entra ID Engineer |
| `vscode_snippets/*` | (no reviewer; flag for security only) |
| `README.md` | (no reviewer; flag for `/docs-check`) |

Each reviewer returns early with `APPROVE — no <kind> files in this diff` when its files aren't touched (e.g. the front-end engineer on a pure-PowerShell diff, or the bash engineer when only `daily-viewer/` changed). The clean-code and security engineers review broadly. That's expected and not a problem.

---

## Launch the Seven Reviews in Parallel

Send a single message with seven Agent tool calls (minus any whose scope gate is empty — see above). For each, pass enough context that the agent can run independently:

1. **Bash Engineer Agent** — task: "Run the `/senior-bash-engineer` review on the current branch's diff against `main`. Read the skill at `.claude/commands/senior-bash-engineer.md` and follow it. Post the result to the PR if one exists."

2. **PowerShell Engineer Agent** — task: "Run the `/senior-powershell-engineer` review on the current branch's diff against `main`. Read the skill at `.claude/commands/senior-powershell-engineer.md` and follow it. Post the result to the PR if one exists."

3. **Security Engineer Agent** — task: "Run the `/security-review` skill on the current branch's pending changes. Post the result to the PR if one exists."

4. **Clean-Code Engineer Agent** — task: "Run the `/senior-clean-code-engineer` review on the current branch's diff against `main`. Read the skill at `.claude/commands/senior-clean-code-engineer.md` and follow it. Focus on duplicated branches across functions, oversized functions, parallel function pairs sharing scaffolding, magic numbers, and the named CLAUDE.md extract-repeated-branches + breathing-room rules. Post the result to the PR if one exists."

5. **Front-End Engineer Agent** — task: "Run the `/senior-frontend-engineer` review on the current branch's diff against `main`. Read the skill at `.claude/commands/senior-frontend-engineer.md` and follow it. Focus on the `daily-viewer/` web surface: untrusted-data escaping (XSS via innerHTML), semantic HTML + accessibility, CSS token/specificity/unit hygiene, data-driven rendering vs hardcoded markup, CSP-hostile patterns, and secrets never reaching the browser. Post the result to the PR if one exists."

6. **Azure Resources Engineer Agent** — task: "Run the `/senior-azure-resources-engineer` review on the current branch's diff against `main`. Read the skill at `.claude/commands/senior-azure-resources-engineer.md` and follow it. Post the result to the PR if one exists."

7. **Entra ID Engineer Agent** — task: "Run the `/senior-entra-identity-engineer` review on the current branch's diff against `main`. Read the skill at `.claude/commands/senior-entra-identity-engineer.md` and follow it. Post the result to the PR if one exists."

Wait for all seven to complete before continuing.

---

## Aggregate the Reports

Present the seven reports sequentially in the user-facing summary:

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

---

## ☁️ Senior Azure Resources Engineer
<report from agent 6>

---

## 🔐 Senior Entra ID Engineer
<report from agent 7>
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
| ☁️ Azure Resources Engineer | ✅ APPROVE / ❌ REQUEST CHANGES (N issues) |
| 🔐 Entra ID Engineer | ✅ APPROVE / ❌ REQUEST CHANGES (N issues) |

### Overall
✅ APPROVE — all seven reviewers passed
  OR
❌ REQUEST CHANGES — <list blocking findings, grouped by reviewer>
```

---

## Update PR Body ToC

After all seven reviewers have posted their comments to the PR, run `/pr-body` to refresh the table of contents so reviewers can navigate to each report from the PR body.
