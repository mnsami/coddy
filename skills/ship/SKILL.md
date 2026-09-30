---
name: ship
description: Verify, commit, push and open a PR for the current issue branch
disable-model-invocation: true
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/config.sh"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/tree.sh")
---

# Ship

## Config
!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/config.sh"`

## Working tree
!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/tree.sh"`

`NOT_ONBOARDED` → stop and say: run `/coddy:onboard` first.
Current branch equals `default_branch` → stop and say: not on an issue branch.

## Steps

1. Run `verify`. Non-zero exit → show the failing output and stop. Fixing belongs to the issue branch, not to this skill.
2. Derive the issue id from the branch name via the `branch` pattern.
3. Commit uncommitted work using the `commit` pattern. Ask for the summary only when the diff does not make it obvious.
4. Push and open the PR.
   - git: `git push -u origin HEAD` then `gh pr create --fill`, editing the body to: what changed, why, and `Closes #<issue>` (github) or the Jira key on its own line (jira).
   - jj: `jj git push --bookmark <branch>` then `gh pr create` the same way.
5. Post the PR URL as an issue comment. jira: also transition to "In Review" if that transition exists.
6. Print the PR URL and stop. No merging.
