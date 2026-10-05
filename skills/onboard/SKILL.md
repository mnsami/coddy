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
```

## Steps

1. `config: present` → show it and ask whether to overwrite. "No" ends the skill.
2. Pre-fill from the detection block: `tracker`/`repo` from the remote, `branch`/`commit` from recent branches and commits when a pattern is visible, `verify` from make targets or package scripts, `roadmap` from the detected file.
3. Ask for the rest in ONE AskUserQuestion call: every key you could not infer, plus confirmation of the guessed patterns, plus the `worktree` tool with `jj` as the default first option and `git` as the other (`jj: missing` → say so in the `jj` option). A non-GitHub remote means asking for the tracker; `tracker: jira` means asking for site and project key. `default_branch_protected: false` → also ask whether to require a pull request for `default_branch`, so nothing reaches it without one, even from a shell.
4. Write `.claude/coddy.yml`.
5. `claude_dir_gitignored: no` → ask whether the config is personal (add `.claude/coddy.yml` to `.git/info/exclude`) or shared (leave it for commit).
6. Protection was accepted → `gh api -X PUT "repos/{owner}/{repo}/branches/<default_branch>/protection" -F required_status_checks=null -F enforce_admins=true -F "required_pull_request_reviews[required_approving_review_count]=0" -F restrictions=null`. It fails (plan or permissions) → say so and carry on.
7. Print the final config and stop.

This skill changes nothing else: no code, CI, CLAUDE.md, or planning docs.
