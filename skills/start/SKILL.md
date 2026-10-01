---
name: start
description: Start work on a tracked issue by moving it to In Progress and creating its own branch in its own worktree
when_to_use: Use whenever the user asks to start, pick up, work on, fix or implement a GitHub issue or Jira ticket (issue 42, ABC-123, an issue URL), before touching any code for it. Pass the bare issue number or Jira key as the argument.
arguments: [issue]
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/config.sh"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/tree.sh"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" create *), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" claim *)
---

# Start issue $issue

## Config
!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/config.sh"`

## Worktrees
!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/tree.sh"`

`NOT_ONBOARDED` → stop and say: run `/coddy:onboard` first.
Empty issue id → stop and say: usage `/coddy:start <issue>`.

## Non-negotiable

- The issue is In Progress in the tracker before any code is edited.
- One issue, one branch, one worktree. Every edit and commit for this issue happens in `.worktrees/$issue` on its own branch: never in the main checkout, never on `default_branch`, never on another issue's branch.

Hooks enforce both: every Edit and Write outside a worktree whose issue step 4 has claimed is rejected, and any shell command that leaves a change in the main checkout is flagged. A rejection means a step was skipped: go back and do it, and undo what was flagged. Never route around it.

Paths below are relative to `root`.

## Steps

1. Fetch the issue with its comments.
   - github: `gh issue view $issue --comments`
   - jira: the Atlassian MCP tools (`getJiraIssue`, then its comments). If none are loaded, stop and say the atlassian plugin needs to be authenticated.
2. Restate in at most 10 lines: goal, acceptance criteria, out of scope. No acceptance criteria in the issue → ask one question to pin them down before continuing.
3. Create the worktree: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" create $issue <branch>`. `<branch>` follows the `branch` pattern: `type` is `bug`, `feat` or `chore` from the issue's labels or type; `slug` is at most four words from the title. An existing worktree for `$issue` is reused. `jj_repo: no` while `worktree` is `jj` or absent → first ask, then `jj git init --colocate; echo '.jj/' >> .git/info/exclude`.
4. Move it to In Progress. A failure here → stop and report; do not continue.
   - github: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" claim $issue` assigns you, adds the `in progress` label and verifies it.
   - jira: assign to me, then `getTransitionsForJiraIssue` and `transitionJiraIssue` into the In Progress status (already there → no transition; no such transition → stop and list the available ones). Only then `bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" claim $issue` to record it.
5. Investigate the code in the worktree. When the change spans more than three files or touches a public contract (API, schema, CLI flags), post the plan as an issue comment before editing.
6. Implement in `.worktrees/$issue` only. Commit messages follow the `commit` pattern. A jj worktree has no `.git`: commit with `jj commit -m`, never `git`. When done, say: run `/coddy:ship`.
