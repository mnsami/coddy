---
name: start
description: Start work on a tracked issue
arguments: [issue]
disable-model-invocation: true
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/config.sh")
---

# Start issue $issue

## Config
!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/config.sh"`

`NOT_ONBOARDED` → stop and say: run `/coddy:onboard` first.
Empty issue id → stop and say: usage `/coddy:start <issue>`.

## Steps

1. Fetch the issue with its comments.
   - github: `gh issue view $issue --comments`
   - jira: the Atlassian MCP tools (`getJiraIssue`, then its comments). If none are loaded, stop and say the atlassian plugin needs to be authenticated.
2. Restate in at most 10 lines: goal, acceptance criteria, out of scope. No acceptance criteria in the issue → ask one question to pin them down before continuing.
3. Claim it: github `gh issue edit $issue --add-assignee @me`; jira assign to me and transition to "In Progress" if that transition exists.
4. Branch from an up-to-date `default_branch` using the `branch` pattern. `type` is `bug`, `feat` or `chore` from the issue's labels or type; `slug` is at most four words from the title.
   - git: `git switch -c <branch> <default_branch>`
   - jj: `jj new <default_branch>` then `jj bookmark create <branch> -r @`
5. Investigate the code. When the change spans more than three files or touches a public contract (API, schema, CLI flags), post the plan as an issue comment before editing.
6. Implement. Commit messages follow the `commit` pattern. When done, say: run `/coddy:ship`.
