# Config version key and `/coddy:migrate` (#139)

## Intent

Nothing records which schema a config was written against, so every layout change (the #27 move from `.claude/coddy.yml` to `.coddy.yml`, the M1.5 keys to come) is a special case scattered through `onboard` and `config`. A `version` key plus one ordered migration path turns each future change into one more step.

## Goals

- `version` (`2` today) is a schema key in all three copies (onboard yaml, config `## Keys` bullet, README yaml); `onboard` writes it.
- A config without `version` is v0 (the pre-#27 layout, wherever the file lives).
- `/coddy:migrate` brings a config from its version up to the current one, backup first, and prints what changed.
- `selftest-core.sh` migrates a v0 fixture and diffs it against the expected current version.

## Non-goals

- The M1.5 keys (`max_lines`, `migrations`, `labels`, `notifications`).
- Nagging from `next`, `start`, `ship`, `triage`: they keep working on an old config.
- Downgrades.

## Anti-goals

- `bin/coddy` writing the config. Any shell write to it is undone by `trip`; the file is written with the Write tool so the guard's `ask` applies.
- A second place that knows how to move the legacy file. `config` loses its move offer.

## Decided

**Ownership.** Migration is its own skill, `/coddy:migrate` (not `update`, which reads as `claude plugin update`). `onboard` keeps refusing over an existing config and names `/coddy:migrate` when the config is behind (no `version`, or `legacy_config: present`), `/coddy:config` otherwise. `config` hands its legacy-move offer (current step 1) to `migrate`: when the config is behind it warns (run `/coddy:migrate`) and still applies the requested change (user's call); it refuses any change to `version`. Behind means no `version`, a `version` below the current one, or a `.claude/coddy.yml` present.

**Mechanics in the core.** `bin/coddy migrate` is a read-only verb (after the NOT_ONBOARDED gate, no issue id), called by the skill through the `issue.sh` shim and listed in its `allowed-tools`. It reads the live config (`confpath()`), takes `version` (absent → 0), and applies each step in order up to the current version. Output: header lines `from: <n>`, `to: <n>`, one `changed: <what>` per change, then `---`, then the migrated file. Every line and comment of the original is kept. Already current → `from: 2`, `to: 2`, no `---` block. A version above the current one → non-zero exit naming the plugin update.

**v0 → v1.** Insert `version: 1` as the first line. Target path is `.coddy.yml`; when the source was `.claude/coddy.yml`, a `changed: move .claude/coddy.yml -> .coddy.yml` line. A leftover `.claude/coddy.yml` next to a live `.coddy.yml` gets `changed: remove .claude/coddy.yml` at any version, so a v1 config with a leftover prints that line and no `---` block, and the skill only runs the `rm` (my call).

**Skill steps.** Run `migrate` → nothing to do: say so, stop. Otherwise show the changed lines and ask once. On yes: `issue.sh exclude answers` (so `.claude/coddy/` is excluded on projects onboarded before #138), `issue.sh exclude config` when the legacy file was not tracked by git, so a personal config stays personal (my call), `date +%Y%m%d-%H%M%S`, Write the backup of the source file to `.claude/coddy/backup/<ts>/<source path>`, Write `.coddy.yml` (guard asks), `rm .claude/coddy.yml` when the source was legacy or one was left behind (the config lock lets it go once `.coddy.yml` is live), print old → new.

**Skill rules.** Injects `config.sh` and `issue.sh status` like `config`, stops on `NOT_ONBOARDED`, and carries the same non-injecting-host fallback line the self-test asserts on every skill. `rm .claude/coddy.yml` stays out of `allowed-tools`, as in `config` today. Model-invocable, `when_to_use` with trigger phrases ("migrate / upgrade the coddy config"), frontmatter free of `: ` and ` #`, terse checklist style, states what it must not do (touches nothing but the config, its backup and the `.git/info/exclude` lines).

**Test.** `selftest-core.sh`: a v0 legacy fixture with comments → `coddy migrate` output after `---` equals an expected current file; a current config → no `---` block; a current `.coddy.yml` with a leftover legacy file → `changed: remove` and no `---` block; `version: 99` → non-zero.

## Left to the builder

- Exact wording of messages and `when_to_use`.
- How the step table is laid out inside `bin/coddy` (a function per step is fine).
- README and CLAUDE.md updates (skill count, the new verb, the move now living in `migrate`).
