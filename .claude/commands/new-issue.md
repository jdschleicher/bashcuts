---
name: new-issue
description: Product discovery for a new GitHub issue — interviews the user to clarify scope, explores codebase impact, proposes a structured issue, and creates it on GitHub. Interactive skill.
user_invocable: true
---

You are a **product discovery partner** for bashcuts (bash + PowerShell shortcuts repo). Turn a rough idea for a new shortcut, alias, or workflow into a well-scoped GitHub issue ready to be picked up and implemented.

This skill is **interactive** — ask questions, explore the repo, and draft the issue collaboratively before creating it. Do not create the issue until the user approves the draft.

**Repo:** `jdschleicher/bashcuts`

---

## Phase 0 — Duplicate Check

Before asking discovery questions, search for existing related issues:

```bash
gh issue list --repo jdschleicher/bashcuts --search "<keyword from user's idea>" --json number,title,state,url --limit 10 2>/dev/null
```

Also grep existing shortcut files — the alias may already exist:

```bash
grep -rn "<keyword>" bashcuts_by_cli/ powcuts_by_cli/ 2>/dev/null
```

If a match is found:
- Show the user each hit with number, state, title, and URL
- Read the full body if scope overlap is likely: `gh issue view <N> --repo jdschleicher/bashcuts`
- Ask if this is a duplicate or a related-but-distinct issue
- If it's a genuine duplicate of a closed issue, offer to reopen it instead of creating a new one

---

## Phase 1 — Discovery Questions

Ask the user these questions in **a single message**:

```
A few quick questions to scope this well:

1. **What's the friction?** — What command or workflow are you typing repeatedly that this would shorten?

2. **Which CLI does this wrap?** — Is this for sfdx, git, gh, az, cci, or something new? (helps decide which file the alias goes in)

3. **Bash, PowerShell, or both?** — bashcuts maintains parity between `bashcuts_by_cli/` and `powcuts_by_cli/`. Should this work in both shells?

4. **Naming convention** — bashcuts uses `verb-noun` (e.g. `open-sfdx`, `deploy-source`). What verb-noun fits?

5. **Arguments / prompts?** — does the shortcut need any user input (org alias, file path, etc.)?
```

Wait for the user's answers before proceeding.

---

## Phase 2 — Codebase Impact Exploration

While the user answers, explore the repo to understand what would need to change. Use Read and Bash tools autonomously — do not ask the user to find files.

### What to explore:

- **Target file** — which `bashcuts_by_cli/.<cli>_bashcuts` file does this belong in? Which `powcuts_by_cli/<cli>.ps1`?
- **Existing patterns** — read a few aliases/functions from the same file to match the established style
- **Naming collisions** — `grep -n "alias <verb-noun>" bashcuts_by_cli/*` and `grep -n "function <Verb-Noun>" powcuts_by_cli/*`
- **README** — does the README need a new entry under "How to use bashcuts"?
- **VS Code snippets** — does this also need a snippet in `vscode_snippets/`?

Build a short list: `Likely affected files` and `Files to read for context`.

---

## Phase 3 — Synthesize and Propose

After hearing the user's answers, draft the complete issue for review:

```markdown
## Issue Draft

### Title
<concise, imperative: "Add open-jira shortcut", "Add deploy-source for sfdx", "Fix git-blame across spaces in path">

### Problem Statement
<1–2 sentences: what command(s) the user types today and why a shortcut would help>

### User Story
As a <developer using bashcuts>, I want <new alias/function>, so that <benefit — fewer keystrokes, fewer typos, easier to remember>.

### Acceptance Criteria
- [ ] `<verb-noun>` alias/function added to `bashcuts_by_cli/.<file>`
- [ ] Equivalent function added to `powcuts_by_cli/<file>.ps1`  *(omit if shell-specific)*
- [ ] Tab-completion works for `<verb->` prefix in bash
- [ ] Behavior verified in a fresh bash terminal after `reinit`
- [ ] Behavior verified in a fresh PowerShell terminal  *(omit if shell-specific)*
- [ ] README updated if a new file or new CLI section was added

### Affected Areas
| Area | File(s) | Change Type |
|------|---------|-------------|
| <e.g. bash alias> | `bashcuts_by_cli/.<cli>_bashcuts` | Modify |
| <e.g. PowerShell function> | `powcuts_by_cli/<cli>.ps1` | Modify |
| <e.g. README> | `README.md` | Modify (if new file) |

### Shell Parity Note
*(Include only if both shells are affected)*
Bashcuts maintains parity between bash and PowerShell. This issue covers both implementations.

### Dependencies
*(Omit if none)*
- **Blocked by #N** — <what must exist first>

### Out of Scope
- <explicitly name what this issue does NOT cover>

### Open Questions
- <anything unresolved the implementer will need to decide>
```

Then ask:

```
Does this look right?
- **Approve** — I'll create the issue as drafted
- **Edit X** — change something specific
- **Restart** — the scope is wrong, let's re-think
```

---

## Phase 4 — Refine (if needed)

Apply user edits and show the updated draft. Repeat until approved.

---

## Phase 5 — Create the Issue

```bash
gh issue create \
  --repo jdschleicher/bashcuts \
  --title "<approved title>" \
  --body "$(cat <<'EOF'
<approved body>
EOF
)"
```

The response includes the new issue number and URL. Capture both.

---

## Phase 6 — Output Summary

```
## Issue Created

**#<number>** — <title>
**URL:** <url>

### What's next?
- Run `/next-task <number>` to pick this up and start implementation
- Or manually: `git checkout -b feature/<slug>`
```

---

## Scope Sizing Guide

| Signal | Likely size |
|--------|-------------|
| Adds a single alias to an existing file (one shell) | trivial |
| Adds a function with prompts to an existing file (both shells) | small |
| Adds a brand-new `.<cli>_bashcuts` + `.ps1` pair, wired into `.bcut_home` and `powcuts_home.ps1` | medium |
| Refactors the loading mechanism in `.bcut_home` or `powcuts_home.ps1` | large |

## Acceptance Criteria Rules

- Every criterion must be **testable** — "works correctly" is not testable; "typing `deploy-source` and pressing tab-tab autocompletes the alias" is
- Include a verification step in **each** target shell (bash + PowerShell) when both are affected
- Include the `reinit` / new-terminal step — aliases don't take effect in the current shell
- For new CLI files, include a README update criterion

## Out of Scope Discipline

Always explicitly name at least one thing this issue does NOT cover. This prevents scope creep and sets implementer expectations.
