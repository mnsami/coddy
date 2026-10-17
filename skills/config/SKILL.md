---
name: config
description: Show or change the project's coddy settings in .coddy.yml
when_to_use: Use when the user asks to view, edit, change or update coddy settings for an onboarded project, such as the tracker, worktree tool, default branch, branch or commit pattern, verify command, roadmap or edit guard mode, or to accept a config change that came from git (a pull or checkout).
argument-hint: "[key=value ...]"
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/config.sh"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" status)
---

# Config

## Current
!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/config.sh"`

## Worktrees
!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" status`

`NOT_ONBOARDED` → stop and say: run `/coddy:onboard` first.

## Keys

- `tracker`: `github` or `jira`.
- `repo`: `owner/name`. Required with `tracker: github`.
- `jira.site`, `jira.project`: the Atlassian site URL and the project key. Required with `tracker: jira`.
- `worktree`: `jj` or `git`.
- `default_branch`: a branch that exists on `origin`.
- `branch`, `commit`: patterns. `branch` must contain `{issue}`.
- `verify`: a shell command that exits 0 when the work can ship.
- `roadmap`: path to an existing file. Optional, so it can be removed.
- `guard`: `block` or `warn`. Optional, so it can be removed; absent means `block`. `warn` only when the user asked for it in so many words, never to get a rejected edit through.
- `tiers.claude`: the model per difficulty for one agent, as `{low: <model>, medium: <model>, high: <model>}`, in names that agent accepts. All three levels are required. Other agents get their own line (`tiers.codex`, `tiers.gemini`, …); add one when a teammate uses another agent.
- `review_block`: `critical`, `high`, `medium` or `low`. Optional; absent means `high`. Findings at or above it make start run another fix round.
- `review_rounds`: a whole number from 1 to 5. Optional; absent means `3`.

## Steps

1. Worktrees says `config: .claude/coddy.yml` → the config is at its old path: offer the move to `.coddy.yml` first, before any other change. Yes → write `.coddy.yml` under `root` with the Write tool, the file's content as it is (the guard asks the user to allow it), then run `rm .claude/coddy.yml` in Bash: the config lock lets the legacy file go once `.coddy.yml` exists. No → leave it where it is.
2. The user asks to accept a config change that came from git (a pull or checkout; the config lock's message sends them here after putting the file back) → run `git -C <root> ls-tree --name-only HEAD .coddy.yml .claude/coddy.yml` and `git -C <root> diff HEAD -- .coddy.yml .claude/coddy.yml` in Bash.
   - `HEAD` holds neither path → nothing came from git: say so, and that leaving the workflow is `rm <config>` by hand. Stop.
   - `HEAD` holds `.coddy.yml` and it differs or is missing in the working tree (the lock removes one pulled next to a live `.claude/coddy.yml`) → show the diff and ask; yes → Read `.coddy.yml` if it exists, then Write `HEAD`'s content (`git -C <root> show HEAD:.coddy.yml`) to it under `root` (the guard asks the user to allow it); `config` was `.claude/coddy.yml` → that is the move, so run `rm .claude/coddy.yml` in Bash as step 1 does. Say so and stop.
   - Only `.claude/coddy.yml` differs → show the diff and ask; yes → Read the file, then Write `HEAD`'s content (`git -C <root> show HEAD:.claude/coddy.yml`) over it, say so and stop.
   - No diff → say the file already matches `HEAD` and stop. No to either ask → stop and leave it.
3. The requested change is `$ARGUMENTS` (`key=value` pairs or plain words), else what the user asked for in this conversation. Nothing requested → show the current config, then ask in ONE AskUserQuestion call, each current value first and marked `(current)`: `worktree` (jj, git), `tracker` (github, jira), `guard` (block, warn), and a multi-select of the free-text settings to change (`default_branch`, `branch` and `commit` patterns, `verify`, `roadmap`, `tiers`, `review_block`, `review_rounds`). Then ask for the new value of each setting picked there. Everything left as it is → say nothing changed and stop.
4. Check every change against Keys. Unknown key or invalid value → say which and stop. A new `tracker` without its companion keys → ask for them in one question.
5. `worktree` changes while Worktrees lists an issue → stop and say: ship or remove those worktrees first, an issue cannot switch tools midway.
6. Edit the config (`config` under Worktrees, or `.coddy.yml` once step 1 wrote it) under `root`: change only the requested keys and keep every other line, comments included.
7. Print each changed key as old → new and stop.

This skill changes nothing but that file.
