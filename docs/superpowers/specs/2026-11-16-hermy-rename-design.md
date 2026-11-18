# Rename to hermy (#463)

## Why

The old name collides with Coddy Agent (same niche, same CLI name, same `~/.<name>` home) and with Coddy, Inc. (asserted trademark), and searches never surface this project. With no users and no announcement yet, the rename is cheap now. The product is hermy; the mascot stays Hermit.

## Goals

- Every name, path, variable, marker, asset and doc says hermy: plugin and marketplace `hermy`, `bin/hermy`, `HERMY_*` inputs, `.hermy.yml`, `.git/hermy/`, `.git/hooks/hermy/`, `hermy.previousHooksPath`, `# Written by hermy start: `, `<!-- hermy:* -->` markers, `templates/hermy.yml` written to `.github/workflows/hermy.yml`, `get.sh` on `HERMY_HOME`/`HERMY_BIN`/`HERMY_REPO_URL`, `assets/hermy*`.
- A project onboarded before the rename keeps its guardrails after upgrading, until #464's migrate moves it.
- `selftest.sh` fails on any old-name occurrence outside a fixed list of legacy spellings.

## Non-goals

- The repository slug: `mnsami/coddy` stays in `get.sh`'s default URL, `plugin.json` homepage and repository, the README install line and the `AGENTS.md` block's link until #465 renames the repository (GitHub redirects old to new only, so `mnsami/hermy` would 404 until then).
- #464: migrate moving `.git/coddy`, the agent dir's answers and backups and the workflow file; the old `.git/hooks/coddy` directory and `coddy.previousHooksPath` key removed; `get.sh` moving the home; skills stopping on a legacy-only project; the final release under the old name.
- The 0.8.0 version bump (its own PR).
- Plugin evals, a `hermy:lint` marker and PR-body section markers: none exists today, so there is nothing to rename.
- Keeping later commands refused until a higher config `trip` could not remove is gone: it needs a new mechanism, a record `trip` leaves for `snap`.

## Anti-goals

- A project onboarded under the old name left unguarded, or with every commit refused, after the upgrade.
- External names rewritten: `mnsami/coddy`, the `coddy-spike` directory and its `coddy-probe` plugin.

## Approaches

- A (chosen): a scripted rename over the tree with a reviewed exclusion list, then the legacy reads written by hand, then the self-test grep.
- B: the rename alone in #463 and every legacy read in #464. Rejected: with the header renamed, `start` in a project onboarded earlier records `.git/hooks/coddy` as a foreign previous hooks path and `githook` runs that hook, which looks for claims under `.git/coddy`, finds none and refuses every commit.

## Decided

- Config precedence: `.hermy.yml`, then `.coddy.yml`, then `.claude/coddy.yml`; the first present is live. `status` and `detect` print which. The config lock snapshots all three, puts back the live one, lets a lower one go while a higher one is live, and removes a higher one a command made next to a live lower one; when that removal fails, `trip` says so and names that file as now the live config. The guard asks on the live config and on any config path above it; a path below the live one is asked about only once the config is removed, as before the rename, and otherwise goes through the `.git`, hard-link and lock checks like any other path. `exclude config` excludes `.hermy.yml`. Onboard stops when any of the three exists.
- `migrate` moves the live legacy config (either path) to `.hermy.yml`; the version step and the other moves are #464's.
- Git hooks: `start`, `githook` and `doctor` treat the old header, a `core.hooksPath` naming `.git/hooks/coddy` and `coddy.previousHooksPath` as their own previous install: never recorded as the previous hooks path, never run as a previous hook; `coddy.previousHooksPath` is read when `hermy.previousHooksPath` is absent; `start` writes the hooks under `.git/hooks/hermy/` with the new header and records `hermy.previousHooksPath`. Before moving `core.hooksPath` off `.git/hooks/coddy`, `start` holds that directory to its own directory's rule: a symlink there, or a file not carrying the old header, makes it write nothing and stop, naming the file and the previous directory it belongs in.
- `left` also sees `.git/hooks/coddy` and a claim under `.git/coddy`, so a project onboarded earlier whose config is removed is refused, not inert. A claim under `.git/coddy` is otherwise not read: its edits are refused until #464 moves it, which fails closed.
- Markers: written as `hermy:`; every reader (the skills, `doctor`'s `agents_md`, onboard's in-place block replace) also accepts `<!-- coddy:plan -->`, `<!-- coddy:questions -->` and the `<!-- coddy:begin -->`/`<!-- coddy:end -->` pair, for one major version.
- `doctor`'s `pr_check` accepts `.github/workflows/coddy.yml` while `hermy.yml` is absent and the old file is byte-identical to the old template, held as its hash.
- The GitLab template's token variable becomes `HERMY_TOKEN`.
- Docs: every file under `docs/` renamed, dated records included, external names kept.
- The grep: over the tracked files alone (`git ls-files` in a checkout with a `.git`, `jj file list` in a jj workspace), so no untracked or ignored file and no other worktree under `.worktrees/` is read, case-insensitive, each line with the allowed legacy spellings removed must hold no old name; no path holds it. Allowed: `coddy@coddy`, `coddy:*`, `.coddy.yml`, `.claude/coddy.yml`, `.claude/coddy/`, `AGENT_DIR/coddy`, `.git/coddy`, `.git/hooks/coddy`, `coddy.previousHooksPath`, `Written by coddy start`, `coddy:plan`, `coddy:questions`, `coddy:begin`, `coddy:end`, `workflows/coddy.yml`, `mnsami/coddy`, `coddy-spike`, `coddy-probe`, `formerly coddy`, `Coddy Agent`, `Coddy, Inc.`.

## Left to the builder

- The order of the scripted passes and the exact exclusion list, as long as the grep passes and no legacy read is lost.
- How the selftests build a project onboarded earlier for the legacy reads above.
