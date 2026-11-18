# Migrate with the plugin from before the rename still loaded (#470)

## Why

With `coddy@coddy` and `hermy@hermy` both installed, `/hermy:migrate` runs `migrate records`, which moves the claims from `.git/coddy` into `.git/hermy`, and then the old plugin's edit guard refuses the `.hermy.yml` write, since it holds every root path but its own config to a worktree (checked against the installed 0.7.3 guard). The project is left half moved: the config still `.coddy.yml`, the old session's claims gone from where it reads them. Separately, policy.md's skill rule excludes hermy's own skills by name but not the old plugin's, so a brief can route to a `coddy:*` skill.

## Goals

- `/hermy:migrate` stops before any write while a `coddy:*` skill is listed for the session, and names `claude plugin uninstall coddy@coddy` and a new session.
- policy.md's skill rule excludes `coddy:*` skills by name, as it does hermy's own.

## Non-goals

- `claim` reading `.git/coddy/<n>`: every skill but `onboard` and `migrate` stops on `MIGRATE:` while the old config is live, and `migrate records` moves the lock with its owner line, which `claim` then holds to as any other (#481). A `claim` run by hand is not held to the owner anyway.
- A final release under the old name: dropped in #464's plan.

## Approaches

- A: a guard line in the migrate skill keyed on the session's listed skills. Chosen: no code, the same "listed for this session" test policy.md already routes skills by, and the old plugin's skills are always `coddy:*`.
- B: the shim reads Claude Code's installed-plugins file and injects a fact. Rejected: a Claude path reader, a fixture and an `allowed-tools` rule for a window only the author's own machines pass through.

## Design

- skills/migrate/SKILL.md: a guard with the others up top.
- policy.md line 40: "never one of hermy's own or a `coddy:*` one".
- The old-name check's allowed spellings (`oldok` in scripts/selftest.sh and the rename design doc's list) gain `coddy@coddy` and `coddy:*`.
- CLAUDE.md "Onboarding gate": one clause on the stop.
