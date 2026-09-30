---
name: triage
description: Turn review findings into tracker issues
disable-model-invocation: true
---

# Triage

## Config
!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/config.sh"`

`NOT_ONBOARDED` → stop and say: run `/coddy:onboard` first.

## Source
Findings come from this conversation, or from `$ARGUMENTS` when given (a file path or pasted text).

## Steps

1. List the findings, one issue per finding. Merge duplicates.
2. Fetch open issues: github `gh issue list --state open --limit 100`; jira JQL `project = <project> AND statusCategory != Done`. A finding already covered by an open issue is skipped and cited.
3. Show a table: title, label, covered-by. Ask once to confirm.
4. Create each issue with this body:
   - **Problem**: what is wrong, with evidence (`file:line`, command output).
   - **Fix**: checklist of concrete steps.
   - **Acceptance**: checklist of observable checks.
   Labels: `bug` or `enhancement` (github); issue type Bug or Task (jira).
5. Print the created links.
