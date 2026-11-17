# Migration to hermy: records, old hooks, legacy stop (#464)

## Intent

#476 renamed the plugin. Projects onboarded before it still hold `.coddy.yml` (or `.claude/coddy.yml`), claims under `.git/coddy`, hooks under `.git/hooks/coddy` with `coddy.previousHooksPath`, and backups under `.claude/coddy/`. #476 already keeps them guarded: the guard and config lock read the legacy config, `start` adopts `.git/hooks/coddy`, `migrate` moves the config. This change finishes the move so nothing from before the rename is left, and stops every skill until it is done.

The only installs are the author's own machines and repositories, so nothing here serves an install nobody can reach.

## Goals

- `migrate` lists, and a new verb does, the move of `.git/coddy/*` to `.git/hermy/*` (owner lines kept) and `.claude/coddy/` to `.claude/hermy/`.
- `start` removes `.git/hooks/coddy` and `coddy.previousHooksPath` once its hooks live in `.git/hooks/hermy`.
- A project whose live config is a legacy path: every skill but `migrate` (and `onboard`, which already names it) stops with one line naming `/hermy:migrate`.
- `selftest-core.sh` takes a project shaped as before the rename through `migrate`, the new verb and `start`, and asserts it ends where a fresh hermy onboarding does.
- CLAUDE.md "Onboarding gate" documents the legacy paths, the stop, and the `coddy:` marker acceptance.

## Non-goals

- `get.sh` moving the old home or leaving a shim: no machine has one.
- A last release under the old name: each machine switches the plugin by hand (commands go in the PR description).
- Moving `.github/workflows/coddy.yml`: it is tracked on `default_branch`, so a rename in the main checkout cannot be committed there. `migrate` names it to rename in the next PR; `doctor` already accepts it while identical to the old template.
- A schema `version` bump: the schema did not change, and a legacy path already reads as behind (`migrate` prints `changed:`).

## Approaches

- A (chosen): a new mutating verb in `bin/hermy`, `migrate records`, called by the migrate skill; `migrate` stays read-only and lists the moves as `changed:` lines. Edge cases live in one tested place, the call is pre-approved, and the self-test can run it.
- B: the skill runs `mv` per path. Rejected: edge cases in prose, a permission prompt on every `.git/` and `.claude/` write, and the self-test cannot run a skill.
- C: no move; every reader of `.git/hermy` falls back to `.git/coddy`. Rejected: seven readers touched and a fallback that never goes away.

## Design

- `migrate` (read-only) adds `changed: move .git/coddy -> .git/hermy` when `.git/coddy` holds an entry, `changed: move .claude/coddy -> .claude/hermy` when `$HERMY_AGENT_DIR/coddy` exists, and `rename: .github/workflows/coddy.yml` while that file exists and `hermy.yml` does not.
- `migrate records` merges `.git/coddy` into `.git/hermy` and `$HERMY_AGENT_DIR/coddy` into `$HERMY_AGENT_DIR/hermy`: each entry moved when its name is free at the target, a directory present at both merged one level down the same way, anything else left and printed as `kept:`; the source removed once empty. Refuses a link at any of the four paths before moving anything. Prints `moved:` and `kept:` lines.
- Migrate skill order: `exclude answers` (so `.claude/hermy` stays out of git status), then `migrate records`, then the existing backup, Write and `rm` steps; a `rename:` line is reported at the end.
- `start`: once `core.hooksPath` is its own, removes each file in `.git/hooks/coddy` carrying `# Written by coddy start: ` and the directory when empty, and unsets `coddy.previousHooksPath` once `hermy.previousHooksPath` is set; both only when present, so a rerun writes nothing; a failed write goes through `nowrite` like the other writes there.
- `config` prints one `MIGRATE: <path>` line in place of the config when the live config is not `.hermy.yml`; every skill that stops on `NOT_ONBOARDED`, `migrate` aside, stops on it naming `/hermy:migrate`.
- The rename grep's allowed spellings gain `.claude/coddy/` and `AGENT_DIR/coddy`.

## Left to the builder

- Exact output wording, the fixture's shape and how the comparison with a fresh onboarding normalises the root path.
