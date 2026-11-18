# `get.sh` installer and a minimal `hermy doctor` (#140)

## Intent

hermy installs only as a Claude Code plugin. Codex, Cursor, Copilot CLI and Gemini CLI users, and anyone who wants the `hermy` command in a plain terminal, have no way in. `get.sh` is that second way: one `curl … | bash` that leaves a full checkout on disk and the command on `PATH`. Both audiences are expected (user): an agent without a plugin system needs the skills and briefs as Markdown, so the whole repository is installed, not `bin/hermy` alone.

## Goals

- `get.sh` at the repo root: `curl -fsSL https://raw.githubusercontent.com/mnsami/coddy/main/get.sh | bash`.
- Installs from `main`, always (user). No tags, no `--version`, no release check: the repo has no tags or releases, and the release process stays a `plugin.json` bump. (2026-11-18: tags exist from `v0.7.3`; per #285 D6, CI tags `v<version>` and creates a release for each bump merged to `main` (#282). `get.sh` still installs from `main` here; following the newest tag is #497.)
- A minimal `hermy doctor` that reports which install it runs from (user); #34 extends the same verb later.
- README's Install section lists both ways.

## Non-goals

- Release tags, GitHub releases, version pinning, checksums. (Tags and releases exist from `v0.7.3` and come from CI, #282, per #285 D6; `get.sh` following them is #497.)
- Per-agent packaging (#31, #32, #33, #150) and #34's prerequisite and enforcement checks.
- Installing `jq`, `jj` or anything else; editing shell rc files.

## Anti-goals

- Overwriting local work in `~/.hermy`.
- Running as root.
- `bin/hermy` naming a Claude Code path to tell installs apart (CLAUDE.md: the core names no Claude Code path but the legacy config).

## Decided

**`get.sh` behaviour.**
1. Refuse when `id -u` is 0.
2. Needs `git` and `bash`; missing `git` → say so and stop.
3. `~/.hermy` absent → `git clone` `https://github.com/mnsami/coddy` (branch `main`) into it.
4. Present → it must be a git checkout whose `origin` is that repo, on `main`, with no change to a tracked file; otherwise stop and say which, touching nothing. Then `git fetch` and `git merge --ff-only origin/main`; not a fast-forward, or the merge stops on an untracked file in the way → stop, show git's message, say so.
   - "That repo" compares normalised URLs: `git@github.com:` read as `https://github.com/`, a trailing `/` and `.git` dropped, so the https and ssh forms of `mnsami/coddy`, with or without `.git`, all match (my call).
   - Untracked files do not block (my call): editor backups and an agent's scratch output in `~/.hermy` would otherwise stop every update.
5. Link `~/.hermy/bin/hermy` as `hermy` in `~/.local/bin` (created when absent). An existing `hermy` there that is not a link to that file → stop and say so. `~/.local/bin` not on `PATH` → print the line to add, edit nothing.
6. Print the installed commit (short sha) and whether anything changed (a rerun on the same commit says it is up to date).
7. Print the next step per agent: Claude Code → the two `claude plugin` lines, noting the plugin does not use `~/.hermy`; any other agent → run `/hermy:onboard`'s equivalent by having the agent read `~/.hermy/skills/onboard/SKILL.md`, and `hermy` is on `PATH` (exact wording left to the builder).

**Test hooks (my call).** `get.sh` reads `HERMY_REPO_URL` (default the GitHub URL), `HERMY_HOME` (default `~/.hermy`) and `HERMY_BIN` (default `~/.local/bin`), so the self-test runs it against the local bare remote in a temp `HOME` without the network.

**`hermy doctor`.** A top-level verb in `bin/hermy` that needs no config and no issue (placed before the NOT_ONBOARDED gate). It resolves its own real path (`BASH_SOURCE[0]`, following links, so the shims that source it and a `PATH` link both resolve to the real file) and prints:
- `install: <dir>`: the real directory above `bin/hermy`.
- `via: get.sh` when that directory is `${HERMY_HOME:-$HOME/.hermy}`, otherwise `via: other` (a plugin cache or a checkout; told apart by `install:` alone, my call, so the core names no Claude Code path).
- `version: <x.y.z>` from `.claude-plugin/plugin.json` there, or `unknown`.
- `commit: <short sha>` when that directory is a git checkout, else `none`.
Exit 0. Usage header and the `usage` line list it.

**Tests (my call).** `selftest-core.sh` (no `CLAUDE_*`):
- `get.sh` as root is refused (simulated by an override of `id`, or skipped when unfakeable: builder's choice).
- First run into an empty `HERMY_HOME` clones, links into `HERMY_BIN`, prints the commit; a second run says up to date; a new commit on the remote → fast-forwards; an edited tracked file or another branch → refuses and leaves the checkout as it was; an untracked file → updates; an origin spelled with `.git` or a trailing `/` → accepted, another repo → refused; a foreign `hermy` in `HERMY_BIN` → refuses.
- `hermy doctor` through the link → `via: get.sh` with the installed commit; from the repo's own `bin/hermy` → `via: other`.

**Docs.** README Install: the plugin way first, then `get.sh` for other agents and the terminal, replacing the "put that directory on your `PATH`" sentence. CLAUDE.md: the new verb in the `bin/hermy` paragraph, `get.sh` in "What this is".

## Left to the builder

- Exact messages and the per-agent next-step wording.
- Whether `get.sh` is `set -euo pipefail` with small functions or a flat script.
