---
name: next
description: Pick the next issue to work on
when_to_use: Use when the user asks what to work on next, what is open, or which issue or ticket to pick up.
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/config.sh"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/tree.sh"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" sweep)
---

# Next

## Config
!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/config.sh"`

## Cleaned up
!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" sweep`

## Worktrees
!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/tree.sh"`

`NOT_ONBOARDED` → stop and say: run `/coddy:onboard` first.
Lines under Cleaned up → say so first, in one sentence. `cleaned` is an issue whose PR merged and whose worktree was removed, so it is free again even if Worktrees still lists it; `kept` is a merged one whose worktree still holds work to push or discard, or that another running session still holds.

## Steps

1. Fetch open issues.
   - github: `gh issue list --state open --limit 50 --json number,title,labels,assignees,milestone,updatedAt`
   - jira: JQL `project = <project> AND statusCategory != Done ORDER BY priority DESC, updated DESC`
2. Set aside, never to recommend: every open issue from step 1 that Worktrees lists (claimed on this machine; `owners` says by whom), except one Cleaned up reports as `cleaned`; every one the tracker shows in progress (github: the `in progress` label; jira: a status in the In Progress category); and every one assigned to someone and not to me (github: assignees without my login from `gh api user --jq .login`, which is how an issue looks from a teammate's claim to the merge of their PR, since `ship` takes the label off; jira: an assignee that is not me), since `/coddy:start` refuses those. List them under an `In progress` heading as `id: title (owner)`: the tracker's assignee login(s), and for a claimed one also its `owners` entry as `this session` or `session <id> running|gone` (`<login>, this session`); no login → the `owners` entry alone.
3. `roadmap` set → read it and note the current milestone or phase.
4. Rank the rest: assigned to me first, then bugs that break production, then roadmap order, then priority and age.
5. Recommend one issue with a one-line reason, then at most four alternatives as `id: title`. End with: `/coddy:start <id>`.
