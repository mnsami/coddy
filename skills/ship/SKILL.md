---
name: ship
description: Verify, commit, push and open a PR for an issue's worktree
when_to_use: Use only when the user asks to ship, open a PR, push for review or submit the current issue. Never invoke it unprompted because the work looks finished.
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/config.sh"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/tree.sh"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" push *), mcp__plugin_github_github__list_pull_requests, mcp__plugin_github_github__create_pull_request, mcp__plugin_github_github__add_issue_comment, mcp__plugin_github_github__issue_read, mcp__plugin_github_github__issue_write
---

# Ship

## Config
!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/config.sh"`

## Worktrees
!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/tree.sh"`

`NOT_ONBOARDED` → stop and say: run `/coddy:onboard` first.
Worktrees lists each as `issue=branch`, `bases` the branch a stacked worktree was started from, and `owners` whose claim each is. Pick the issue: `$ARGUMENTS` when given, else the issue started in this conversation, else the only worktree whose `owners` entry is `me` or `unknown`. Several and unclear → ask which. None listed → stop and say: nothing to ship, run `/coddy:start <issue>` first. The pick's `owners` entry names another session → stop and say whose it is: ship it from that session, or `/coddy:start <issue>` to take it over (`push` refuses it anyway).

## Steps

Paths below are relative to `root`.

1. Run `verify` inside `.worktrees/<issue>`. Non-zero exit → show the failing output and stop. Fixing belongs to the issue branch, not to this skill.
2. Commit and push: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" push <issue> "<message>"`. The message follows the `commit` pattern and is used only when there is uncommitted work; ask for the summary only when the diff does not make it obvious. It prints `pushed: <branch>`. A failure → show the output and stop.
3. `list_pull_requests` with `state: open`, `head: <owner>:<branch>` and `fields: [number, html_url]` (`owner` and `repo` from `repo`; jira: from the remote) lists a PR → it is already open: keep that URL and skip step 4. Otherwise `create_pull_request` with `head: <branch>`, `base: <base>`, a title and a body of what changed, why, and `Closes #<issue>` (github) or the Jira key on its own line (jira). `<base>` is the branch `bases` lists for the issue, else `<default_branch>`; say which. A listed base → `list_pull_requests` with `head: <owner>:<base>` is the PR it is stacked on: name it in the body as `Stacked on #<n>`. `create_pull_request` rejects a listed base because it is gone from the remote → its PR has merged: open against `<default_branch>` instead and say so.
4. Post the PR URL as an issue comment: github `add_issue_comment` with `issue_number: <issue>`; jira the ticket comment tool.
5. Take the issue out of In Progress, now that its PR is open.
   - github: `issue_read` `get_labels` lists `in progress` → `issue_write` `update` with `labels` set to the rest. Not listed → carry on.
   - jira: transition to "In Review" if that transition exists.
6. Print the PR URL and stop. No merging.
