# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Claude Code plugin (`coddy`) that is also its own single-plugin marketplace. There is no build step and no dependencies: the deliverable is six prompt files (`skills/*/SKILL.md`), the bash scripts they call, and one hook.

## Commands

```bash
bash scripts/selftest.sh                    # scripts end to end: both worktree tools, claim, push, guard, tripwire
claude plugin validate .                    # manifest + skill frontmatter
claude --plugin-dir . -p "/coddy:next"      # run one skill headless against the working copy
```

`selftest.sh` builds a throwaway repo with a local bare remote and a stub `gh`; it skips the jj leg when `jj` is missing. Run it after any change under `scripts/`. It cannot prove the hooks or skills are wired; check those headless inside an onboarded scratch repo:

- `claude --plugin-dir . -p "start issue 42"` - plain-language trigger. In `-p` the Skill call is denied unless `Skill(coddy:start)` is allowed in settings or via `--allowedTools`.
- `--permission-mode acceptEdits` for edit-guard checks, `--allowedTools Bash` for tripwire checks. Without them the permission layer refuses before any hook runs.
- A scratch repo whose remote is a local bare repo makes `claim` fail (no GitHub host): the quick way to see `start` stop without editing.

Skills act on the project in `$CLAUDE_PROJECT_DIR`, so to exercise one, run `claude --plugin-dir /path/to/coddy` from inside a target project that has (or, for `onboard`, lacks) `.claude/coddy.yml`.

Release = commit straight to `main` (the marketplace installs from it), then bump `version` in `.claude-plugin/plugin.json` as its own commit (`chore: bump to X.Y.Z`). `marketplace.json` carries no version. An installed copy only changes after a bump: `claude plugin marketplace update coddy && claude plugin update coddy@coddy`.

## Architecture

**Prompts hold judgment, scripts hold mechanics.** A skill decides what to do (which issue, branch name, commit message, PR body); anything that is a fixed command sequence lives in a script so it is tested once and pre-approved.

**Fact injection.** Each skill opens with `` !`bash "${CLAUDE_PLUGIN_ROOT}/scripts/<x>.sh"` `` blocks. These run at skill load and their stdout is inlined into the prompt, so the model starts with config and repo state rather than discovering them with tool calls. The injected scripts (`config.sh`, `detect.sh`, `tree.sh`) are read-only, print `key: value` lines, and must not fail loudly (`|| exit 0`, `2>/dev/null`, fallback values) since their output is the prompt.

**`scripts/issue.sh` is the only script that mutates.** `create` makes the worktree, `claim` moves the issue to In Progress, `push` commits and pushes; `guard`, `snap` and `trip` are the hooks. It reads `worktree` and `default_branch` from the config itself, so the jj/git split lives there and nowhere in the prompts.

**The guardrails are enforced by `hooks/hooks.json`, not by wording.** Three layers, all inert until the project is onboarded:

- *Edit guard.* `PreToolUse` on Edit/Write/NotebookEdit runs `issue.sh guard`, which rejects (exit 2) any path that is not under `.claude/` or inside `.worktrees/<issue>/` for an issue whose marker `.git/coddy/<issue>` exists. Only `claim` writes that marker, and only after the tracker change succeeded, so "In Progress before any code is edited" and "one issue, one worktree" hold even when no skill fired.
- *Shell tripwire.* A shell command's writes cannot be predicted from its text, so `PreToolUse` on Bash runs `issue.sh snap` and `PostToolUse` plus `PostToolUseFailure` run `issue.sh trip`. They fingerprint the main checkout (every dirty path with its content hash, plus `HEAD` when no remote branch contains it) and exit 2 when the command left new lines in that fingerprint. Only additions count, so an undo is quiet. The fingerprint uses paths rather than git status codes because jj colocation turns untracked files into intent-to-add entries by itself.
- *Config lock.* `.claude/coddy.yml` is the off switch for all of the above, so `snap` keeps a copy and `trip` puts it back when a shell command deleted or changed it. A config identical to the one committed at `HEAD` is left alone (a pull of a shared config). Legitimate changes go through the Edit tool (`/coddy:config`), where Claude Code's own sensitive-file prompt asks the user. `trip` keys off the snapshot, never off the config, or a deleted config would silence it.
- *Branch protection.* `onboard` offers to require a pull request on `default_branch`. It is the only layer that holds when a command edits, commits and pushes in one go.

Known ceilings: the tripwire reports after the fact and does not see background commands or shell writes inside an unclaimed worktree; for Jira the marker records the MCP transition rather than verifying it (a script cannot reach Jira).

**`allowed-tools` must mirror the commands exactly.** Every injected command, and every `issue.sh` subcommand a skill runs, is repeated in that skill's `allowed-tools` frontmatter as `Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/<x>.sh" …)`. Adding, renaming, or re-quoting one without updating that line brings back permission prompts on every skill run.

**Onboarding gate.** `.claude/coddy.yml` in the target project is the plugin's config. `scripts/config.sh` prints it, or the sentinel `NOT_ONBOARDED`; every skill except `onboard` injects it and stops on the sentinel, and the guard does nothing without it. `onboard` instead injects `scripts/detect.sh` (remote, whether `jj` is installed, default branch and whether it is protected, make/npm targets, roadmap, recent commits and branches) to pre-fill the config and ask only for what it could not infer.

**Config schema has three copies.** The annotated schema in `skills/onboard/SKILL.md` is authoritative; `skills/config/SKILL.md` lists the same keys with their validation rules, and `README.md` shows an example. Adding a key means updating all three, `detect.sh` if it can be inferred, and every skill or script that should read it. `onboard` creates the file; `config` changes single keys afterwards and refuses to switch `worktree` while an issue worktree exists.

**Tracker variants stay in the prompts.** Tracker is `github` (`gh` CLI) or `jira` (Atlassian MCP plugin tools, not a CLI, so a script cannot reach it). A step that touches the tracker spells out both variants inline.

**Issue work lives in `.worktrees/<issue>`.** The directory name is the issue id, which is how `ship` and the guard find the issue. `scripts/tree.sh` lists only the directories that have a claim marker, so a worktree coddy did not create is never offered to `ship` and stays uneditable. Every script resolves the real project root when the session was opened inside a worktree, and `tree.sh` prints it as `root` for the prompts. `worktree` is `jj` (the default, also when the key is absent) or `git`. A jj workspace has `.jj/` and no `.git/`, so `gh` always runs from the project root with `--head`.

**`start` order is local first, tracker second.** The worktree is created before the issue is claimed, so a failed fetch or a missing `jj` never leaves an issue In Progress with no branch; `claim` refuses to run without the worktree.

**Skills must stay model-invocable.** None may set `disable-model-invocation` (the self-test asserts it); each carries a `when_to_use` line of trigger phrases so it fires from plain language as well as `/coddy:<name>`. `ship` is the exception in tone: its `when_to_use` restricts it to explicit asks. Keep frontmatter values free of `: ` and ` #` (unquoted YAML scalars).

Skill flow is `onboard` → `next` → `start <issue>` → `ship`, with `triage` feeding new issues back into the tracker. Each skill ends by naming the next command rather than chaining into it, and each states what it must not do (`ship` never merges or fixes failures; `onboard` writes nothing but the config and, when accepted, the branch protection).

## Conventions

- A hook blocks only on exit 2; any other non-zero exit is a non-blocking error. Hook paths in `issue.sh` set `code=2` before `die`.
- A Bash command that exits non-zero fires `PostToolUseFailure`, not `PostToolUse`, so `trip` is registered on both.
- `${CLAUDE_PLUGIN_ROOT}` is expanded in skill bodies and in `allowed-tools`, so skills call scripts by that path.
- Scripts are committed executable (`chmod +x`).
- Skill bodies are terse imperative checklists: `condition → action` guards up top, numbered steps, per-tracker variants as sub-bullets. Match that style rather than writing explanatory prose.
- Commits: `type: summary` (`feat`, `fix`, `chore`).
