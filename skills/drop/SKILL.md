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
`tracker: gitlab` → every GitLab MCP call but `get_user` takes `project_id`, which is `repo`; me is `get_user` with `me: true`, its id and username. Those tools not loaded → stop and say the gitlab plugin must be enabled and signed in.
Empty issue id → stop and say: usage `/coddy:drop <issue>`.
The issue is `$ARGUMENTS`. Worktrees does not list it as `<issue>=<branch>` → stop and say: issue `<issue>` has no claimed worktree here, nothing to drop.
Asking the user means one question call. No such tool (headless) → post the question as an issue comment whose first line is `<!-- coddy:questions -->` (github `add_issue_comment`; jira `addOrEditJiraIssueComment`; gitlab `save_note`), print it and stop, with nothing else changed: the user answers in a later comment and runs `/coddy:drop <issue>` again. A question's answer is the first comment of mine after the latest `<!-- coddy:questions -->` comment of mine asking it that is neither a `<!-- coddy:questions -->` comment nor a `Dropped:` one, with no `Dropped:` comment of mine between them; none → it is unanswered. Only comments whose author is me count (github `get_me`'s `login`; jira `atlassianUserInfo`'s `accountId`; gitlab `get_user`'s username, a system note never counting).

## Steps

1. Read the issue with its comments, and look for an open PR on `<branch>`, the branch Worktrees lists for it.
   - github: `issue_read` `get`, then `get_comments`, with `owner` and `repo` from `repo`; `list_pull_requests` with `state: open`, `head: <owner>:<branch>` and `fields: [number, html_url]`.
   - jira: `getJiraIssue`, then `executeRead` `listJiraIssueComments`; the PR linked in those comments, when `pull_request_read` `get` on it says it is open and its `head.ref` is `<branch>`.
   - gitlab: `get_work_item` with `work_item_iid: <issue>` and `include: [notes, related_merge_requests]`, paging with `notes_first` and `notes_after` to the last note and with `related_merge_requests_first` and `related_merge_requests_after` to the last merge request; an entry whose `get_merge_request` says `opened` and whose `sourceBranch` is `<branch>`.
   A call fails → show its error and stop, with nothing changed.
2. An open PR → ask whether to close it too, naming its URL. The answer is carried to step 4.
3. Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" drop <issue>`. It removes the worktree, claim and records here and keeps the branch, printing `dropped: <issue> (<branch> at <sha>)`.
   - Refused, its message naming `--force` (uncommitted work, or commits on no remote) → show the output and ask whether to drop it anyway: uncommitted files are moved under `.git/coddy/swept/<issue>`, unpushed commits stay on the local branch. Yes → run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" drop <issue> --force`. No → stop: nothing in the tracker changes.
   - Any other refusal → show the output and stop: nothing in the tracker changes.
4. Step 2 answered yes → close the PR: github and jira `update_pull_request` with `pullNumber` its `number` and `state: closed`; gitlab `save_merge_request` with `merge_request_iid: <iid>` and `state_event: close`. It fails → show its error and carry on.
5. Take the issue out of In Progress and off me. Never close it.
   - github: I am `get_me`'s `login`. `issue_write` `update` with `labels` set to step 1's labels without `in progress`, and `assignees` set to step 1's assignees without me; neither changes → no call. Then `add_issue_comment` with `issue_number: <issue>` and one line: `Dropped: no longer being worked on.`
   - gitlab: `save_work_item` with `work_item_iid: <issue>`, `remove_labels: [in progress]` and `assignee_ids` set to step 1's assignees' ids without mine; neither changes → no call. Then `save_note` with `work_item_iid: <issue>` and the same line.
   - jira: step 1's assignee is me → `editJiraIssue` with `fields: {assignee: null}`; `executeRead` `listJiraIssueTransitions`, then `transitionJiraIssue` with the id of one that leads to a status in the To Do category (already in one → no transition; none leads there → say so and carry on). Then `addOrEditJiraIssueComment` with the same line.
6. Read it back (github `issue_read` `get`; gitlab `get_work_item`; jira `getJiraIssue`): `in progress` still set, me still assigned, or (jira) a status outside the To Do category → name what is still set. Never retry.
7. Print the `dropped:` line and stop. End with: `/coddy:next`.

Never closes the issue, never deletes the branch, and never passes `--force` without the user's yes.
