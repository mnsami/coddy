# Releasing

Release = a version bump PR of its own, never a direct commit to `main`. Tags exist from `v0.7.3`: for each `plugin.json` version bump merged to `main`, CI (`.github/workflows/release.yml`, #282, per #285 D6) creates tag `v<version>` on the merge commit and a GitHub release listing the `feat:` and `fix:` subjects since the previous tag. `get.sh` installs the latest release, the newest `v*` tag on `main`'s first-parent line (#497), and `HERMY_REF=main` the tip.

1. List the installed GitHub and Atlassian plugin tools in a session; compare them with `grep -oh 'mcp__[A-Za-z0-9_]*' skills/*/SKILL.md | sort -u`. A name that differs → stop and fix the skills first.
2. The release branch `chore/<issue>-release-X-Y-Z` comes from `/hermy:start <issue>`. Rebase it on the remote's `main`, which the local `main` may lag: `git fetch origin && git rebase origin/main`, or `jj git fetch && jj rebase -d main@origin` in a jj worktree.
3. Bump `version` in `.claude-plugin/plugin.json` as its own commit: `chore: bump to X.Y.Z`. Keep `version` on its own line (`bin/hermy` and `scripts/selftest-core.sh` read it by sed).
4. Verify, from the worktree: `bash scripts/selftest.sh && bash scripts/selftest-core.sh && claude plugin validate .`. Only the CLAUDE.md warning is expected.
5. Smoke run under `/bin/bash` 3.2 (stock macOS bash). The hooks and shims call `bash` through `PATH`, so put it first: `PATH=/bin:$PATH claude --plugin-dir <worktree>`, and confirm with `bash --version` in the session's shell.
   - Fresh scratch project: `/hermy:onboard` → `/hermy:start <issue>` → an edit → `/hermy:ship`.
   - Project onboarded by 0.6.0 (`.claude/coddy.yml`, no `version` key): it still works, and `/hermy:migrate` moves it to `.hermy.yml`.
6. Open the PR. Any step above fails → fix it on the branch, rebase again, and repeat from step 4; nothing is released until the PR merges.
7. After it merges: the `release` workflow's run creates tag `vX.Y.Z` and its GitHub release. Check both (`gh release view vX.Y.Z`; a failed run is rerun from the Actions page, and so is a cancelled one: GitHub keeps one waiting run in the workflow's concurrency group, so a third bump merged close behind cancels the second's), then `claude plugin marketplace update hermy && claude plugin update hermy@hermy`. From the tag on, `get.sh` installs the newest tag on `main`, `vX.Y.Z` unless a later release's tag is already there, and a rerun moves a `get.sh` install to it; until it is there, they stay on the release before.
