# Claude Code Assistant Instructions — bashcuts

## AI Context & Project Overview

You are assisting with **bashcuts**, a personal collection of **bash aliases / functions** and **PowerShell functions** that get sourced into the user's interactive shell (`.bashrc` / `$profile`). The point is to turn long, frequently-used CLI invocations (sfdx, gh, git, az, cci, jira, etc.) into tab-tab-completable `verb-noun` shortcuts.

There is **no compiler, no test runner, and no lint step**. Quality gates are: bash parses cleanly, PowerShell parses cleanly, files are wired into the entry points, and the user verifies behavior in a fresh terminal.

### Key Project Files

- `.bcut_home` — bash entry point; `source`-s every file under `bashcuts_by_cli/`. The user wires this into their `.bashrc` once
- `powcuts_home.ps1` — PowerShell entry point; dot-sources every file under `powcuts_by_cli/`. The user wires this into their `$profile` once
- `bashcuts_by_cli/.<cli>_bashcuts` — one file per CLI/tool, contains `alias` and function definitions
- `powcuts_by_cli/<cli>.ps1` — PowerShell counterparts; contains `function Verb-Noun { … }` definitions
- `vscode_snippets/*.code-snippets` — VS Code snippet JSON files synced via VS Code Settings Sync
- `README.md` — end-user setup and usage guide

## Primary Objectives

1. **Maintain bash + PowerShell parity** — when you add a shortcut for a CLI to one shell, add the equivalent to the other unless the user explicitly says shell-specific
2. **`verb-noun` naming** — every alias/function is `verb-noun` (lowercase in bash, PascalCase in PowerShell) so users can tab-tab to discover them by prefix
3. **Wire new files into the entry points** — a brand-new `bashcuts_by_cli/.foo_bashcuts` is dead weight unless `.bcut_home` sources it; same for `.ps1` ↔ `powcuts_home.ps1`
4. **Match the surrounding style** — read the file you're editing first; bashcuts content varies in formatting and prompt patterns, follow what's already there

## Quick Command Reference

```bash
# Verify a bash file parses (no syntax errors)
bash -n bashcuts_by_cli/.<file>

# Verify a PowerShell file parses (if pwsh is on PATH)
pwsh -NoProfile -Command "[System.Management.Automation.Language.Parser]::ParseFile('powcuts_by_cli/<file>.ps1', [ref]$null, [ref]$null) | Out-Null"

# Confirm a new bash file is sourced from .bcut_home
grep "<filename>" .bcut_home

# Confirm a new .ps1 is dot-sourced from powcuts_home.ps1
grep "<filename>" powcuts_home.ps1

# Reload bash shortcuts in the current shell (after editing)
reinit   # if defined in the user's environment, otherwise open a new shell

# Open the file containing aliases for a given CLI (uses the o- "open" prefix)
o-sfdx   o-git   o-gh   o-az   o-cci
```

## CRITICAL RULES — NO EXCEPTIONS

### After Every Code Change

1. **Bash parse** — `bash -n` every changed file under `bashcuts_by_cli/` and `.bcut_home`. Zero errors. A syntax error here breaks every user's shell on next source.
2. **PowerShell parse** — parse every changed file under `powcuts_by_cli/` and `powcuts_home.ps1` (skip if `pwsh` is unavailable). Zero errors.
3. **Sourcing wire-up** — for any newly-added shell file, confirm it's sourced from the matching entry point.
4. **Side-effect audit** — anything outside an `alias` or `function` body runs at source time, on every shell startup. Don't add `echo`s, network calls, or sleeps without a deliberate reason.
5. **Verification plan** — describe what to type in a fresh bash and/or PowerShell terminal to confirm the change works (the user will run this; you cannot).

### Naming Mandates

- **Bash:** `lowercase-verb-noun` (`deploy-source`, `open-jira`, `o-sfdx`). Prefer the prefix already used in the target file (`o-` for opens, `g-` if a file uses it).
- **PowerShell:** `Verb-Noun` PascalCase, with **approved verbs** (`Get-Verb`). Common acceptable verbs: `Get`, `Set`, `New`, `Open`, `Start`, `Stop`, `Invoke`, `Test`, `Show`, `Find`, `Add`, `Remove`, `Build`, `Deploy`, `Publish`, `Push`, `Pull`, `Sync`, `Connect`, `Watch`. Non-approved verbs trigger a warning every time the user dot-sources their profile.
- **Mirror across shells:** bash `deploy-source` ↔ PowerShell `Deploy-Source`. Same words.

### Code Style Mandates

- **alias vs function (bash)** — use `alias` only for fixed substitutions. The moment you need `$1`, `$2`, `$@`, `read`, conditionals, or anything multi-line, use a function. Aliases don't expand positional parameters the way callers expect.
- **No `Write-Host` for data (PowerShell)** — `Write-Host` cannot be captured or piped. Use it only for user-facing status messages. For values the caller might want to consume, use `Write-Output`, plain expressions, or `return`.
- **No in-script aliases (PowerShell)** — inside committed `.ps1` files prefer full cmdlet names (`Where-Object` over `?`, `ForEach-Object` over `%`, `Get-ChildItem` over `ls`/`gci`).
- **Quote variable expansions (bash)** — paths with spaces (`C:\Program Files`, `~/Library/Application Support`) break unquoted `$var`. The README explicitly warns about path-with-spaces; new code must respect that.
- **macOS `start`** — `.bcut_home` aliases `start` to `open` on Darwin. Code that uses `start` to open files/URLs is fine; **don't redefine `start` and don't pass platform-specific flags** (e.g. Windows `start /B`, mac `open -a "App"`) without an OS conditional.
- **No comments for self-evident code** — only comment where the logic is genuinely non-obvious.
- **Breathing room** — keep code visually scannable. Two blank lines between top-level function definitions in a `.ps1` or `.<cli>_bashcuts` file. One blank line between logical groups inside a function body (e.g. before a `foreach`, before a final `return`, between a setup block and the work that uses it). A wall of code without spacing makes review and edits harder; don't be stingy with vertical whitespace.
- **Extract repeated branches into private helpers** — if the same `if ($IsWindows -or ...)` / `elseif ($IsMacOS -or $IsLinux)` (or any other repeating decision) appears in two or more functions, lift it into a small private helper (e.g. `Get-AzDevOpsPlatform` returning `'Windows'`/`'Posix'`, or `Get-AzDevOpsCronLine` building the cron string). Same rule for bash: if two functions repeat the same `case "$OSTYPE"` block, extract it into `_bashcut_os` in `.bash_commons` or the file's local helper. Private helpers can use unapproved verbs since they aren't user-facing — readability of the public surface is what matters. Apply this proactively when implementing parallel `Register-/Unregister-` style pairs.
- **Never `return` a function call directly** — capture the call's result in a named local variable on its own line, then `return $thatVariable`. This applies to both PowerShell and bash. **Bad:** `return Get-Something -Param $x` / `return Read-AzDevOpsJsonCache -Path $p ...`. **Good:**
  ```powershell
  $result = Get-Something -Param $x
  return $result
  ```
  Reasons: a named local makes the value inspectable in a debugger / `Set-PSBreakpoint`, surfaces the type at the assignment site, gives a single explicit exit point, and makes refactoring (logging, transforming, validating before return) a one-line edit instead of restructuring the return statement. Applies to pipeline expressions too — assign `$rows = $raw | ForEach-Object { … }` then `return $rows`. Allowed exceptions: trivial value literals (`return $null`, `return $true`, `return ''`), and explicit `return` of an already-named variable.
- **Multi-line `if`/`elseif`/`else` blocks always — no inline shorthand** — every branch body lives on its own line with the body indented; never collapse a conditional to `if ($cond) { x } else { y }` on a single line. The `} else {` / `} elseif (...) {` joiners stay on the same line (existing project K&R style). Applies even when the conditional is the right-hand side of an assignment or a hashtable property value. **Bad:**
  ```powershell
  $key  = if ($null -ne $item.Parent) { $item.Parent } else { 0 }
  Id    = if ($f.'System.Id') { [int]$f.'System.Id' } else { [int]$Raw.id }
  ```
  **Good:**
  ```powershell
  $key = if ($null -ne $item.Parent) {
      $item.Parent
  } else {
      0
  }

  Id = if ($f.'System.Id') {
      [int]$f.'System.Id'
  } else {
      [int]$Raw.id
  }
  ```
  Reasons: each branch gets its own breakpoint line, adding a second statement to one branch is a one-line diff instead of restructuring, and the visual weight of the conditional matches its semantic weight. Same rule for bash — never compress `if condition; then x; else y; fi` to a single line; expand each branch to its own line.

## Project Structure

```
.
├── .bcut_home                          # Bash entry point — sources every file under bashcuts_by_cli/
├── powcuts_home.ps1                    # PowerShell entry point — dot-sources every file under powcuts_by_cli/
├── README.md                           # End-user setup + usage guide
├── bashcuts_by_cli/                    # Bash shortcut files, one per CLI/tool
│   ├── .bash_commons                   # Shared helpers used by other files
│   ├── .sfdxcli_bashcuts                # Salesforce sfdx
│   ├── .gitcli_bashcuts                # git
│   ├── .ghcli_bashcuts                 # GitHub CLI (gh)
│   ├── .ccicli_bashcuts                # CumulusCI (cci)
│   ├── .az_bashcuts                    # Azure CLI
│   ├── .open_bashcuts                  # "o-" open shortcuts (open files / URLs)
│   ├── .robot_bashcuts                 # Robot Framework helpers
│   └── .support_bashcuts               # Misc support
├── powcuts_by_cli/                     # PowerShell counterparts
│   ├── pow_common.ps1                  # Shared helpers
│   ├── pow_open.ps1                    # "Open-" shortcuts
│   ├── sfdx_cli.ps1
│   ├── git_common.ps1
│   ├── pow_az_cli.ps1
│   ├── pester.ps1                      # Pester test helpers
│   └── jira_automations.ps1
└── vscode_snippets/                    # VS Code snippets synced via VS Code Settings Sync
    ├── Apex.code-snippets
    ├── azure-cli.code-snippets
    ├── lwc.code-snippets
    └── powershell.code-snippets
```

Note the asymmetric naming: bash files use a `.<cli>_bashcuts` dotfile pattern, PowerShell uses `<cli>.ps1`. Some bash files have no dedicated PowerShell counterpart and vice-versa (e.g. `.bash_commons` ↔ `pow_common.ps1`, `.support_bashcuts` has no pwsh equivalent). That's intentional — only enforce parity when the issue calls for it or when adding a new CLI wrapper.

## Architecture Patterns

### Shell Load Flow

```
User opens a terminal
  → ~/.bashrc sources $PATH_TO_BASHCUTS/bashcuts/.bcut_home
    → .bcut_home runs an `if [ -f … ]; then source …` block per file under bashcuts_by_cli/
      → each .<cli>_bashcuts defines aliases + functions in the user's interactive shell

User opens a PowerShell terminal
  → $profile dot-sources $path_to_bashcuts\powcuts_home.ps1
    → powcuts_home.ps1 dot-sources each .ps1 under powcuts_by_cli/
      → each <cli>.ps1 defines functions in the user's session
```

### Key Design Decisions

- **Sourced into the interactive shell, not run as a script.** Top-level code runs on every shell startup. Anything that isn't an `alias`/`function` definition is a side effect. The existing entry points already do `echo "bashrc loaded"` and `Write-Host "powershell starting"` — that's the established pattern, but new unconditional output is noise.
- **Path-with-spaces is unsupported by design.** The README tells users to clone bashcuts into a path without spaces. `.bcut_home` uses unquoted `$PATH_TO_BASHCUTS/bashcuts/...` because of this. When adding new code, still quote your own variables — but don't try to "fix" the entry-point path handling unless the user asks.
- **`reinit` reloads in the current shell** — modifying a file requires re-sourcing or opening a new shell. The README points users at this. Tell users which one they need to do after a change.
- **`o-` is the open prefix** — `o-sfdx`, `o-git`, etc. open the underlying shortcut file in the editor (commonly VS Code) so the user can browse/edit shortcuts without leaving the terminal. Honor that prefix when adding open shortcuts.

### Tab-Completion Convention

Tab-tab on `verb-` shows every alias/function with that verb. This is why naming must be `verb-noun` — it's the discovery mechanism. Examples: `o-` → opens, `deploy-` → deployments, `get-` → gets. A new shortcut should slot into an existing verb prefix when it makes sense; only invent a new verb when none of the existing ones fit.

## Implementation Checklist

When implementing a new feature or fixing a bug:

- [ ] Read the target file(s) before making changes — match the existing style
- [ ] If adding a CLI wrapper, implement in **both** `bashcuts_by_cli/` (bash) and `powcuts_by_cli/` (PowerShell) — unless the issue says shell-specific
- [ ] If you create a new file under `bashcuts_by_cli/`, add a sourcing block to `.bcut_home`
- [ ] If you create a new file under `powcuts_by_cli/`, add a dot-sourcing block to `powcuts_home.ps1`
- [ ] `bash -n` every changed bash file — zero syntax errors
- [ ] Parse every changed `.ps1` (or note pwsh unavailable)
- [ ] Update README if you added a new CLI section, new prerequisite tool, or changed the setup snippets
- [ ] Provide a verification plan: what to type in a fresh bash terminal and/or PowerShell terminal to confirm the new shortcut works

## Common Tasks

### Adding a New CLI Shortcut to an Existing File

1. Identify the target file (`bashcuts_by_cli/.<cli>_bashcuts` and `powcuts_by_cli/<cli>.ps1`)
2. Choose a `verb-noun` name; check for collisions: `grep "alias <verb-noun>=" bashcuts_by_cli/*` and `grep "function <Verb-Noun>" powcuts_by_cli/*`
3. Add the alias/function in both files, matching the established style of neighboring entries
4. `bash -n` and `pwsh` parse the changed files
5. Provide the user a verification plan — open a new bash terminal, tab-tab on the verb prefix, run the shortcut

### Adding a Wrapper for a Brand-New CLI

1. Create `bashcuts_by_cli/.<newcli>_bashcuts` and `powcuts_by_cli/<newcli>.ps1`
2. Add a sourcing block to `.bcut_home` (mirror the existing `if [ -f … ]; then source …; else echo "missing …"; fi` pattern)
3. Add a dot-sourcing block to `powcuts_home.ps1` (mirror the existing `Get-Content`/`if`/`. <path>` pattern)
4. Add the new CLI to the README's prerequisites bullet list
5. Add a brief mention under "How to use bashcuts" so `o-<newcli>` discovery makes sense

### Fixing a Bug in an Existing Shortcut

1. Reproduce the failure path mentally (or ask the user for the exact command they typed and the error)
2. Read the function/alias and any helpers it calls (`.bash_commons` for bash, `pow_common.ps1` for PowerShell)
3. Apply the minimum fix — bashcuts grows by accretion; resist refactoring neighboring shortcuts
4. Provide a verification plan that exercises the fixed path

### Adding or Updating a VS Code Snippet

1. Edit the relevant `vscode_snippets/<lang>.code-snippets` JSON file
2. Validate the JSON parses (`python -c "import json,sys; json.load(open(sys.argv[1]))" vscode_snippets/<file>.code-snippets`)
3. Tell the user that their editor will pick the change up via Settings Sync — no shell `reinit` needed

## Slash Commands (`.claude/commands/`)

This repo defines its own Claude Code slash commands:

| Command | What it does |
|---|---|
| `/new-issue` | Interactive product discovery → drafts and creates a GitHub issue |
| `/next-task <N>` | Picks up an issue, creates a feature branch, plans the work |
| `/project-sync` | Aligns issue ↔ PR ↔ branch on GitHub |
| `/criteria-check` | Verifies issue acceptance criteria against the code |
| `/docs-check` | Audits README + sourcing wire-up |
| `/code-review` | Runs `senior-bash-engineer` + `senior-powershell-engineer` + `/security-review` + `senior-clean-code-engineer` in parallel |
| `/senior-bash-engineer` | Solo bash review (called by `/code-review`) |
| `/senior-powershell-engineer` | Solo PowerShell review (called by `/code-review`) |
| `/senior-clean-code-engineer` | Solo clean-code review — duplication, function shape, abstraction debt; enforces CLAUDE.md's extract-repeated-branches + breathing-room rules (called by `/code-review`) |
| `/pr-body` | Builds / refreshes the PR body table of contents |
| `/pr-flow` | Full pipeline: parse-checks → commit → push → PR → code-review → docs-check → criteria-check → pr-body |

Use them. `/pr-flow` is the standard "ship it" command.

## Remember

- **Both shells** — new CLI wrappers go in `bashcuts_by_cli/` AND `powcuts_by_cli/` unless the issue is shell-specific
- **Wire it up** — a new file in `bashcuts_by_cli/` must be sourced from `.bcut_home`; a new `.ps1` must be dot-sourced from `powcuts_home.ps1`
- **`verb-noun`** — every alias/function name; bash lowercase, PowerShell PascalCase with an approved verb
- **Side effects on source** — anything outside `alias`/`function` runs on every shell startup; don't add noise
- **Mac `start`** — already aliased to `open` on Darwin in `.bcut_home`; don't redefine
- **Path-with-spaces** — clone path is unsupported per README; quote your own variables but don't try to "fix" the entry points
- **No tests / no compiler** — your gates are `bash -n`, `pwsh` parse, sourcing wire-up, and a verification plan the user can run
- **Breathing room + DRY** — two blank lines between top-level functions, one blank line between logical groups within a function; if the same `if`/`case` branch appears in two or more functions, extract a private helper

---

_This document is optimized for Claude Code. Refer to `README.md` for end-user setup and usage._
