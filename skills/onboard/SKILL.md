---
name: onboard
description: Bring the current project into the coddy workflow by writing .claude/coddy.yml
when_to_use: Use when the user asks to onboard a project or set coddy up in it for the first time. Changing a setting later is the config skill.
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect.sh")
---

# Onboard this project

## Detected
!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect.sh"`

`jq: missing` or `gh_auth: missing` → stop before asking anything and write nothing. Name each one that is missing with its fix, then say: run `/coddy:onboard` again.
- `jq: missing`: the edit guard blocks every edit without it. `brew install jq` or `apt install jq`.
- `gh_auth: missing`: `gh` is not installed (https://cli.github.com) or not signed in (`gh auth login`).

## Config schema: `.claude/coddy.yml`

```yaml
tracker: github              # github | jira
repo: owner/name             # github only
jira:                        # jira only
  site: https://acme.atlassian.net
  project: KEY
worktree: jj                 # jj | git; tool that creates each issue's worktree
default_branch: main
branch: "{type}/{issue}-{slug}"
commit: "{type}({issue}): {summary}"
verify: "make check"         # must exit 0 before /coddy:ship
roadmap: docs/ROADMAP.md     # optional; /coddy:next reads it
guard: block                 # optional; block (default) | warn. warn lets an edit outside a claimed worktree, or inside one another session claimed, through with a notice to Claude
```

## Steps

1. `config: present` → show it and ask whether to overwrite. "No" ends the skill.
2. Pre-fill from the detection block: `tracker`/`repo` from the remote, `branch`/`commit` from recent branches and commits when a pattern is visible, `verify` from make targets or package scripts, `roadmap` from the detected file.
3. Ask for the rest in ONE AskUserQuestion call: every key you could not infer, plus confirmation of the guessed patterns, plus the `worktree` tool with `jj` as the default first option and `git` as the other (`jj: missing` → say so in the `jj` option). A non-GitHub remote means asking for the tracker; `tracker: jira` means asking for site and project key. `guard` is not asked for: leave it out, `/coddy:config` sets it later. `default_branch_protected: false` → also ask whether to require a pull request for `default_branch`, so nothing reaches it without one, even from a shell. `tracker: github` and `pr_check: none` → also ask whether to add coddy's PR check workflow, which fails every pull request that does not close an open, assigned issue.
4. PR check accepted → `config: present` → the hooks are live and the tripwire would report the copy, so print `mkdir -p .github/workflows && cp "${CLAUDE_PLUGIN_ROOT}/templates/coddy.yml" .github/workflows/coddy.yml` for the user to run in their own terminal. `config: none` → run it yourself, before the config exists: the hooks go live with it. Say the file is uncommitted and to commit it; once the check is required, through a PR that closes an open, assigned issue, since the workflow runs from the PR's merge ref and checks that PR too.
5. Write `.claude/coddy.yml`.
6. `claude_dir_gitignored: no` → ask whether the config is personal (add `.claude/coddy.yml` to `.git/info/exclude`) or shared (leave it for commit).
7. Protection was accepted → `gh api -X PUT "repos/{owner}/{repo}/branches/<default_branch>/protection" -F required_status_checks=null -F enforce_admins=true -F "required_pull_request_reviews[required_approving_review_count]=0" -F restrictions=null`. `tracker: github` and (PR check accepted or `pr_check: present`) → `-F "required_status_checks[strict]=false" -f "required_status_checks[contexts][]=closes a claimed issue"` in place of `-F required_status_checks=null`. It fails (plan or permissions) → say so and carry on. `tracker: github`, PR check accepted or present, and the check was not made required here (protection `true`, declined, `unknown`, or the PUT failed) → say in one line that the workflow blocks a merge only once `closes a claimed issue` is a required check under that branch's protection, and to add it there by hand. `tracker: jira` and `pr_check: present` → say the workflow fails every Jira PR (no closing reference) and to remove it.
8. Print the final config and stop.

This skill changes nothing else: no code, no CI beyond `.github/workflows/coddy.yml`, no CLAUDE.md or planning docs.
