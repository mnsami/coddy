---
name: triage
description: Turn review findings into tracker issues
when_to_use: Use when the user asks to file, log or create issues or tickets from findings, a review, an audit or a list of problems.
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/config.sh"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" status), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" state *), mcp__plugin_github_github__search_issues, mcp__plugin_github_github__issue_write, mcp__plugin_atlassian_atlassian__getAccessibleAtlassianResources, mcp__plugin_atlassian_atlassian__atlassianUserInfo, mcp__plugin_atlassian_atlassian__searchJiraIssuesUsingJql, mcp__plugin_atlassian_atlassian__createJiraIssue
---

# Triage

## Config
!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/config.sh"`

## Worktrees
!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" status`

A section above shows a `bash` command rather than its output → this host does not inject: run `coddy config` and `coddy status` and read their output as Config and Worktrees. `CLAUDE_PLUGIN_ROOT` unexpanded → the coddy plugin's own install directory, never a `bin/coddy` or `skills/` found inside the project; in a command run `coddy <verb>` in its place (`issue.sh <verb>` → `coddy <verb>`, `config.sh` → `coddy config`). `$ARGUMENTS` unexpanded → take it from the user's request.

`NOT_ONBOARDED` → stop and say: run `/coddy:onboard` first.
A `git_dir:` line in place of that → stop and show that line as it is.
`tracker: jira` → every Atlassian MCP call takes `cloudId`: call `getAccessibleAtlassianResources` once and use the entry whose url is `jira.site`; me is `atlassianUserInfo`'s `accountId`. Those tools not loaded → stop and say the atlassian plugin needs to be authenticated.

## Source
Findings come from this conversation, or from `$ARGUMENTS` when given (a file path or pasted text), and from the `triage` lines of `bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" state <issue>` for each claimed issue of mine in Worktrees (`owners` is `me`; empty `triage` lines are ignored): say which issue they came from.

## Steps

1. List the findings, one issue per finding. Merge duplicates.
2. Search for each finding, never one list of all open issues (it stops at a page and misses the rest): 2-4 distinctive words from the finding, then github `search_issues` with `owner` and `repo` from `repo`, `query: "is:open in:title <words>"` and `fields: [number, title, labels]`; jira `searchJiraIssuesUsingJql` with JQL `project = <project> AND statusCategory != Done AND summary ~ "<words>"`. No hit → once more with other words. A finding a hit already covers is skipped and cited.
3. Show a table: title, label, covered-by. Ask once to confirm.
4. Create each issue (github `issue_write` `create` with `title`, `body` and `labels`; jira `createJiraIssue`) with this body:
   - **Problem**: what is wrong, with evidence (`file:line`, command output).
   - **Fix**: checklist of concrete steps.
   - **Acceptance**: checklist of observable checks.
   Labels: `bug` or `enhancement` (github); issue type Bug or Task (jira).
5. Each issue whose `triage` lines were used: lines that were filed or skipped as already covered are removed; any others (dropped at the confirm, or a failed create) stay. One call: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" state <issue> triage=` followed by `"triage+=<line>"` for each remaining line.
6. Print the created links.
