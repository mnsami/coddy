---
name: start
description: Start or continue work on a tracked issue by moving it to In Progress and giving it its own worktree, on a new branch or on the branch of an existing PR
when_to_use: Use whenever the user asks to start, pick up, work on, fix or implement a GitHub issue or Jira ticket (issue 42, ABC-123, an issue URL), or to continue an existing pull request or branch (resolve its conflicts, address review comments, rebase it), before touching any code for it. Pass the bare issue number or Jira key as the argument. For a pull request, pass the issue it closes, or the PR number when it closes none.
arguments: [issue]
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/config.sh"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/tree.sh"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" create *), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" claim *), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" sweep)
---

# Start issue $issue

## Config
!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/config.sh"`

## Cleaned up
!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" sweep`

## Worktrees
!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/tree.sh"`

`NOT_ONBOARDED` → stop and say: run `/coddy:onboard` first.
Lines under Cleaned up → say so first, in one sentence. `cleaned` is an issue whose PR merged and whose worktree was removed, so it has no worktree even if Worktrees still lists it; `kept` is a merged one whose worktree still holds work to push or discard.
Empty issue id → stop and say: usage `/coddy:start <issue>`.
`tracker: jira` and `$issue` is not a ticket key → stop and ask which ticket the work belongs to.

## Non-negotiable

- The issue is In Progress in the tracker before any code is edited, or its PR is already open.
- One issue, one branch, one worktree. Every edit and commit for this issue happens in `.worktrees/$issue` on its own branch: never in the main checkout, never on `default_branch`, never on another issue's branch.

Hooks enforce both: every Edit and Write outside a worktree whose issue step 4 has claimed is rejected, and any shell command that leaves a change in the main checkout is flagged. A rejection means a step was skipped: go back and do it, and undo what was flagged. Never route around it.

Paths below are relative to `root`.

## Steps

1. Fetch the issue with its comments.
   - github: `gh issue view $issue --comments`
   - jira: the Atlassian MCP tools (`getJiraIssue`, then its comments). If none are loaded, stop and say the atlassian plugin needs to be authenticated.
2. Restate in at most 10 lines: goal, acceptance criteria, out of scope. No acceptance criteria in the issue → ask one question to pin them down before continuing.
3. Create the worktree: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" create $issue <branch>`. It continues `<branch>` when that branch exists, locally or on the remote, and starts it from `default_branch` otherwise. An existing worktree for `$issue` is reused when it is on `<branch>`. `<branch>` is the first of these that applies:
   - The user named a branch → that branch. The user named a PR → its `headRefName` from `gh pr view <pr> --json headRefName,isCrossRepository`. `isCrossRepository` is true → stop and say a PR from a fork cannot be continued.
   - The issue has an open PR → its `headRefName`.
     - github: `gh pr list --state open --json headRefName,closingIssuesReferences --jq '.[] | select(any(.closingIssuesReferences[]; .number == $issue)) | .headRefName'`
     - jira: the PR linked in the ticket's comments, when `gh pr view <url> --json headRefName,state` says it is open.
   - Worktrees lists `$issue=<branch>` → that branch.
   - None of these → the `branch` pattern: `type` is `bug`, `feat` or `chore` from the issue's labels or type; `slug` is at most four words from the title.

   `create` fails → show the output and stop. Never pass another issue id or branch to get past it. `jj_repo: no` while `worktree` is `jj` or absent → first ask, then `jj git init --colocate; echo '.jj/' >> .git/info/exclude`.
4. Move it to In Progress. A failure here → stop and report; do not continue. An issue whose branch has an open PR is past In Progress: its labels and status stay as they are; github still assigns you, since the PR check reads the assignee.
   - github: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" claim $issue` assigns you, adds the `in progress` label and verifies it, or only assigns you when the PR is open.
   - jira: no open PR → assign to me, then `getTransitionsForJiraIssue` and `transitionJiraIssue` into the In Progress status (already there → no transition; no such transition → stop and list the available ones). Then, open PR or not, `bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" claim $issue` to record it.

   Either tracker: `claim` is refused because another session holds the claim and is running, or a claim is in flight → stop and ask the user whether to take it over; only on a yes run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" claim $issue --take`. `claim` reports a takeover from a session that is no longer running → say so in one line and continue.
5. Investigate the code in the worktree. When the change spans more than three files or touches a public contract (API, schema, CLI flags), post the plan as an issue comment before editing.
6. Implement in `.worktrees/$issue` only. Commit messages follow the `commit` pattern. A jj worktree has no `.git`: commit with `jj commit -m`, never `git`. When done, say: run `/coddy:ship`.
