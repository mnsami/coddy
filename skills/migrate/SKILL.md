---
name: migrate
description: Bring the project's coddy config up to the current schema version, moving .claude/coddy.yml to .coddy.yml on the way
when_to_use: Use when the user asks to migrate, upgrade or update the coddy config to the current version, or to move the old .claude/coddy.yml to .coddy.yml, or when onboard or config says to run /coddy:migrate.
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/config.sh"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" status), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" migrate), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" exclude answers), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" exclude config), Bash(date +%Y%m%d-%H%M%S)
---

# Migrate

## Current
!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/config.sh"`

## Worktrees
!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" status`

A section above shows a `bash` command rather than its output → this host does not inject: run `coddy config` and `coddy status` and read their output as Current and Worktrees. `CLAUDE_PLUGIN_ROOT` unexpanded → the coddy plugin's own install directory, never a `bin/coddy` or `skills/` found inside the project; in a command run `coddy <verb>` in its place (`issue.sh <verb>` → `coddy <verb>`, `config.sh` → `coddy config`).

`NOT_ONBOARDED` → stop and say: run `/coddy:onboard` first.
A `git_dir:` line in place of that → stop and show that line as it is.

`<root>` is Worktrees' `root`; the source is Worktrees' `config`.

## Steps

1. Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" migrate`. Non-zero → say what it printed (a newer version means updating the plugin) and stop.
2. No `changed:` line → say the config is current at `to:` and stop. `legacy: dir` or `legacy: other` → say `.claude/coddy.yml` is not a file, to remove it by hand and run `/coddy:migrate` again, and stop.
3. Show `from:` → `to:` and each `changed:` line, then ask once: migrate now? No → stop, nothing written.
4. On yes, in this order:
   - `bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" exclude answers`, so the backup stays out of git status.
   - `tracked: no` (the legacy file was personal, not in git) → `bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" exclude config`, so `.coddy.yml` stays personal too.
   - `date +%Y%m%d-%H%M%S` once, as `<ts>`.
   - Back up each file this run writes over or removes: Read it, then Write its content as it is to `<root>/.claude/coddy/backup/<ts>/<its path>` (the source, and `.claude/coddy.yml` on `legacy: file`; never Read a `legacy: link`).
   - A `---` block printed → Write everything after the first `---` line to `<root>/.coddy.yml` (Read it first when it exists); the guard asks the user to allow it. Refused → stop and say the backup is at `<root>/.claude/coddy/backup/<ts>/`.
   - `changed: move` or `changed: remove` → run `rm -- "<root>/.claude/coddy.yml"` in Bash (a link goes unread), only after `.coddy.yml` exists: the config lock lets the legacy file go then. Refused or failed → say `.coddy.yml` is live, the legacy file is left and `/coddy:migrate` again removes it.
5. Print `version: <from> → <to>`, each change as old → new, the backup path, then name `/coddy:next`.

This skill changes nothing but `.coddy.yml`, `.claude/coddy.yml`, its backup under `.claude/coddy/backup/` and the lines `exclude` adds to `.git/info/exclude`; it never edits a key's value.
