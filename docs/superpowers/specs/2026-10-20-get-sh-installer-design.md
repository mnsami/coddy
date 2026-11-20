# `get.sh` installer and a minimal `hermy doctor` (#140)

## Intent

hermy installs only as a Claude Code plugin. Codex, Cursor, Copilot CLI and Gemini CLI users, and anyone who wants the `hermy` command in a plain terminal, have no way in. `get.sh` is that second way: one `curl … | bash` that leaves a full checkout on disk and the command on `PATH`. Both audiences are expected (user): an agent without a plugin system needs the skills and briefs as Markdown, so the whole repository is installed, not `bin/hermy` alone.

## Goals

- `get.sh` at the repo root: `curl -fsSL https://raw.githubusercontent.com/mnsami/coddy/main/get.sh | bash`.
- Installs from `main`, always (user). No tags, no `--version`, no release check: the repo has no tags or releases, and the release process stays a `plugin.json` bump. (2026-11-18: tags exist from `v0.7.3`; per #285 D6, CI tags `v<version>` and creates a release for each bump merged to `main` (#282). 2026-11-20, #497: `get.sh` installs the latest release, the newest `v*` tag on `main`'s first-parent line (`git describe --first-parent --tags --abbrev=0 --match 'v[0-9]*' refs/remotes/origin/main`), detached, or `main` while there is none; `HERMY_REF=main` installs the tip by fast-forward, `HERMY_REF=<tag>` that tag, and `HERMY_REF` takes nothing else. Still no `--version` and no release check.)
- A minimal `hermy doctor` that reports which install it runs from (user); #34 extends the same verb later.
- README's Install section lists both ways.

## Non-goals

- Release tags, GitHub releases, checksums. (Tags and releases exist from `v0.7.3` and come from CI, #282, per #285 D6; `get.sh` installs the latest of them, `HERMY_REF=<tag>` pins a release, one `main` itself was at, and `HERMY_REF=main` the tip, from #497; checksums stay a non-goal.)
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
3. `~/.hermy` absent → `git clone -o origin -b main` `https://github.com/mnsami/coddy` into it (`-o origin`, so a user's `clone.defaultRemoteName` does not name the remote otherwise), then the target and its checkout, as in step 4's bullets. (Steps 3 and 4 as of #497, 2026-11-20.)
4. Present → it must be a git checkout whose `origin` is that repo, on branch `main` (`refs/heads/main`, so a tag named `main` does not stand in for it) or detached, with no change to a tracked file; otherwise stop and say which, touching nothing. Then `git fetch --prune origin refs/heads/main 'refs/tags/*:refs/tags/*'`: every tag, a tag deleted on the remote deleted here too (`--prune-tags` is ignored beside a refspec on the command line), and a tag moved on the remote stops the run, naming the local tag to delete.
   - The target: `HERMY_REF=main`, or a tag on `main`'s first-parent line, a state `main` itself was at (in `git rev-list --first-parent refs/remotes/origin/main`, the line `git describe --first-parent` reads, so a tag pushed on an unreviewed commit, or on one inside a branch merged with a merge commit, is refused), resolved as `refs/tags/<HERMY_REF>` alone (a commit id, a branch or a revision such as `v1~1` is refused by name); without `HERMY_REF`, the latest release (the `git describe` above), or `main` while there is none. That pick stops the run when it is a tag object whose embedded name differs from its ref, or when `refs/tags/<name>` resolves to a commit off `main`'s first-parent line, held to it as a pinned tag is (a file system that folds case may open another tag's ref by that name).
   - A tag is checked out detached. `main` moves by `git merge --ff-only refs/remotes/origin/main` on the branch, or from a detached `HEAD` by `git checkout -B main refs/remotes/origin/main`, once the local `main`, when there is one, holds no commit the remote's does not; one that does stops the run, saying so. Not a fast-forward, or an untracked file in the way → stop, show git's message, say so.
   - Every stop leaves the checkout and `HEAD` as they were; a first run clones before it can refuse its target (a `HERMY_REF` that is no tag or one `main` itself was never at, a latest release tag object named otherwise or whose ref resolves to a commit off `main`'s first-parent line), and links nothing. Text from the remote (git's output, a tag's name) reaches the terminal as line breaks and printable ASCII alone.
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
