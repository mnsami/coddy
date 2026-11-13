---
name: drop
description: Drop a claimed issue - remove its worktree and claim here, keep its branch, and take it out of In Progress in the tracker
when_to_use: Use only when the user asks to drop, abandon, give up on, unclaim or release an issue or ticket. Never invoke it because work looks stalled or a claim looks abandoned.
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/config.sh"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" status), mcp__plugin_github_github__issue_read, mcp__plugin_github_github__issue_write, mcp__plugin_github_github__list_pull_requests, mcp__plugin_github_github__pull_request_read, mcp__plugin_github_github__update_pull_request, mcp__plugin_github_github__add_issue_comment, mcp__plugin_github_github__get_me, mcp__plugin_atlassian_atlassian__getAccessibleAtlassianResources, mcp__plugin_atlassian_atlassian__atlassianUserInfo, mcp__plugin_atlassian_atlassian__getJiraIssue, mcp__plugin_atlassian_atlassian__executeRead, mcp__plugin_atlassian_atlassian__editJiraIssue, mcp__plugin_atlassian_atlassian__transitionJiraIssue, mcp__plugin_atlassian_atlassian__addOrEditJiraIssueComment, mcp__plugin_gitlab_gitlab__get_user, mcp__plugin_gitlab_gitlab__get_work_item, mcp__plugin_gitlab_gitlab__get_merge_request, mcp__plugin_gitlab_gitlab__save_merge_request, mcp__plugin_gitlab_gitlab__save_work_item, mcp__plugin_gitlab_gitlab__save_note
---

# Drop

## Config
!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/config.sh"`

## Worktrees
!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" status`

A section above shows a `bash` command rather than its output → this host does not inject: run `coddy config` and `coddy status` and read their output as Config and Worktrees. `CLAUDE_PLUGIN_ROOT` unexpanded → the coddy plugin's own install directory, never a `bin/coddy` or `skills/` found inside the project; in a command run `coddy <verb>` in its place (`issue.sh <verb>` → `coddy <verb>`, `config.sh` → `coddy config`). `$ARGUMENTS` unexpanded → take it from the user's request.

`NOT_ONBOARDED` → stop and say: run `/coddy:onboard` first.
A `git_dir:` line in place of that → stop and show that line as it is.
`tracker: jira` → every Atlassian MCP call takes `cloudId`: call `getAccessibleAtlassianResources` once and use the entry whose url is `jira.site`; me is `atlassianUserInfo`'s `accountId`. Those tools not loaded → stop and say the atlassian plugin needs to be authenticated.
`tracker: gitlab` → every GitLab MCP call but `get_user` takes `project_id`, which is `repo`; me is `get_user` with `me: true`, its id and username. Those tools not loaded → stop and say the gitlab plugin must be enabled and signed in. In a body sent to `save_note` or `save_work_item`, a line starting with `/` goes in backticks: they reject it.
Empty issue id → stop and say: usage `/coddy:drop <issue>`.
The issue is `$ARGUMENTS`. Worktrees lists it as `<issue>=<branch>` → `<branch>` is its branch. Not listed → no `<branch>` and no local claim: step 1 decides whether there is anything left to drop, and step 3 is skipped.
Asking the user means one question call. No such tool (headless) → post the question as an issue comment whose first line is `<!-- coddy:questions -->` (github `add_issue_comment`; jira `addOrEditJiraIssueComment`; gitlab `save_note`), print it and stop, with nothing else changed: the user answers in a later comment and runs `/coddy:drop <issue>` again. A question's answer is the first comment of mine after the latest `<!-- coddy:questions -->` comment of mine asking it that is neither a `<!-- coddy:questions -->` comment nor a `Dropped:` one, with no `Dropped:` comment of mine between them; none → it is unanswered. Only comments whose author is me count (github `get_me`'s `login`; jira `atlassianUserInfo`'s `accountId`; gitlab `get_user`'s username, a system note never counting).

## Steps

1. Read the issue with its comments, and look for its open PR.
   - github: I am `get_me`'s `login`. `issue_read` `get`, then `get_comments`, with `owner` and `repo` from `repo`. The open PR: `list_pull_requests` with `state: open`, `head: <owner>:<branch>` and `fields: [number, html_url]`; no `<branch>` → a `closed_by_pull_requests` reference of `get` whose `pull_request_read` `get` says `state` is open.
   - jira: `getJiraIssue`, then `executeRead` `listJiraIssueComments`; the PR linked in those comments, when `pull_request_read` `get` on it says it is open and its `head.ref` is `<branch>` (no `<branch>` → open alone).
   - gitlab: `get_work_item` with `work_item_iid: <issue>` and `include: [notes, related_merge_requests]`, paging with `notes_first` and `notes_after` to the last note and with `related_merge_requests_first` and `related_merge_requests_after` to the last merge request. The open merge request: an entry whose `webUrl` is under `repo`, whose `get_merge_request` says `opened` and whose `sourceBranch` is `<branch>` (no `<branch>` → whose description closes this issue), taken without asking only when its author's username is mine; anyone else's → show its branch, author and URL and ask whether it is this issue's merge request: only on a yes is it the open PR below.
   A call fails → show its error and stop, with nothing changed.
   No `<branch>` and the issue neither labelled `in progress` (jira: in the In Progress status) nor assigned to me → stop and say: issue `<issue>` has no claimed worktree here, nothing to drop. Either one still set → an earlier drop stopped before the tracker: go on from step 2.
2. An open PR → ask whether to close it too, naming its URL. The answer is carried to steps 4 and 5: no → the PR stays open.
3. No `<branch>` → skip this step. Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" drop <issue>`. It removes the worktree, claim and records here and keeps the branch, printing `dropped: <issue> (<branch> at <sha>)`, then where it moved files to when it moved any (under git, with anything staged saved there as `.coddy-staged.patch`), then a `left:` line for each record it could not remove.
   - Refused, its message naming `--force` (uncommitted work, or commits on no remote) → show the output and ask whether to drop it anyway: uncommitted files are moved under `.git/coddy/swept/<issue>`, anything staged saved there as `.coddy-staged.patch` under git; unpushed commits stay on the local branch under git, and under jj in jj's history at the commit the `dropped:` line names, not necessarily on the bookmark. Yes → run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" drop <issue> --force`. No → stop: nothing in the tracker changes.
   - Any other refusal → show the output and stop: nothing in the tracker changes.
4. Step 2 answered yes → close the PR: github and jira `update_pull_request` with `pullNumber` its `number` and `state: closed`; gitlab `save_merge_request` with `merge_request_iid: <iid>` and `state_event: close`. It fails → show its error and carry on.
5. Take the issue out of In Progress and, unless a PR stays open, off me. Never close it. A PR stays open (step 2 answered no, or step 4 failed) → me stays assigned, since the PR check reads the assignee: only `in progress` comes off, and nothing when it is off already, as after `/coddy:ship`.
   - github: `issue_write` `update` with `labels` set to step 1's labels without `in progress`, and, no PR staying open, `assignees` set to step 1's assignees without me; neither changes → no call. Then `add_issue_comment` with `issue_number: <issue>` and one line: `Dropped: no longer being worked on.`
   - gitlab: `save_work_item` with `work_item_iid: <issue>`, `remove_labels: [in progress]` when step 1 shows it, and, no PR staying open, `assignee_ids` set to step 1's assignees' ids without mine; nothing to set → no call. Then `save_note` with `work_item_iid: <issue>` and the same line.
   - jira: no PR staying open and step 1's assignee is me → `editJiraIssue` with `fields: {assignee: null}`. `executeRead` `listJiraIssueTransitions`, then `transitionJiraIssue` with the id of one that leads to a status in the To Do category (already in one, or a PR stays open and the status is not In Progress, as In Review after `/coddy:ship` → no transition; none leads there → say so and carry on). Then `addOrEditJiraIssueComment` with the same line.
6. Read it back (github `issue_read` `get`; gitlab `get_work_item`; jira `getJiraIssue`): `in progress` still set, me still assigned with no PR staying open, or (jira) a status outside the To Do category when step 5 transitioned it → name what is still set. Never retry.
7. Print the `dropped:` line and any `left:` line (none when step 3 was skipped), say that the PR stays open and the issue assigned to me when it does, and stop. End with: `/coddy:next`.

Never closes the issue, never deletes the branch, and never passes `--force` without the user's yes.
