---
name: next
description: Pick the next issue to work on
disable-model-invocation: true
---

# Next

## Config
!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/config.sh"`

`NOT_ONBOARDED` → stop and say: run `/coddy:onboard` first.

## Steps

1. Fetch open issues.
   - github: `gh issue list --state open --limit 50 --json number,title,labels,assignees,milestone,updatedAt`
   - jira: JQL `project = <project> AND statusCategory != Done ORDER BY priority DESC, updated DESC`
2. `roadmap` set → read it and note the current milestone or phase.
3. Rank: assigned to me first, then bugs that break production, then roadmap order, then priority and age.
4. Recommend one issue with a one-line reason, then at most four alternatives as `id: title`. End with: `/coddy:start <id>`.
