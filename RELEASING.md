# Releasing

Release = a version bump PR of its own, never a direct commit to `main`. Tags and GitHub releases are out of scope (#282).

1. List the installed GitHub and Atlassian plugin tools in a session; compare them with `grep -oh 'mcp__[A-Za-z0-9_]*' skills/*/SKILL.md | sort -u`. A name that differs → stop and fix the skills first.
2. Rebase the release branch `chore/<issue>-release-X-Y-Z` on `main`.
3. Bump `version` in `.claude-plugin/plugin.json` as its own commit: `chore: bump to X.Y.Z`. Keep `version` on its own line (`bin/coddy` and `scripts/selftest-core.sh` read it by sed).
4. Verify, from the worktree: `bash scripts/selftest.sh && bash scripts/selftest-core.sh && claude plugin validate .`. Only the CLAUDE.md warning is expected.
5. Smoke run: `/bin/bash` 3.2 (stock macOS bash), `claude --plugin-dir <worktree>`.
   - Fresh scratch project: `/coddy:onboard` → `/coddy:start <issue>` → an edit → `/coddy:ship`.
   - Project onboarded by 0.6.0 (`.claude/coddy.yml`, no `version` key): it still works, and `/coddy:migrate` moves it to `.coddy.yml`.
6. Open the PR.
7. After it merges: `claude plugin marketplace update coddy && claude plugin update coddy@coddy`.
