# Roadmap

coddy's purpose stays the same: **every change an agent makes is tied to a claimed issue, lives in its own worktree, and lands through a pull request, enforced by tooling rather than by prompts.**

What this roadmap changes is reach and concurrency. coddy aims to support **Claude Code, Codex, Cursor and Copilot CLI** first-class, and to stay correct when several terminals, a lead session with subagents or agent teams, or several teammates work the same repository.

Each phase below is a [GitHub milestone](https://github.com/mnsami/coddy/milestones). Issue numbers are listed per milestone; the milestone pages are the live source.

## Enforcement model

| Layer | Role | Works with any agent? |
| --- | --- | --- |
| Agent hook adapters | Default. Block early, with instructions; `coddy doctor` reports each agent's protection level | Per agent |
| Git hooks + branch protection | The floor: nothing is committed or pushed to the default branch outside the workflow | Yes (not under jj, which doesn't run git hooks) |
| PR check (GitHub Action) | Always on. Fails a PR that isn't linked to a claimed, in-progress issue. Keyed on the issue link, not the branch name, so cloud agents' own branches pass | Yes, including cloud agents |
| Strict mode | Opt-in. Each agent's sandbox can only write to its issue's worktree | Yes |

## Parallel work, in three levels

- **Parallel-safe** (M1): sessions and agents can't corrupt each other's work.
- **Parallel-convenient** (M5): running several at once is pleasant, not just safe.
- **Parallel-orchestrated**: launching and coordinating agents. Out of scope; that stays with other tools, with coddy guarding underneath.

## Milestones

### M0 · Fix what's live
Bugs in the current release.
- #11 Onboarding succeeds without jq, then the guard blocks every edit (done)
- #12 Release the changes merged since 0.2.0 (done)
- #20 Guard lets edits under .claude/ through, including Claude Code's own worktrees

### M1 · Test window: parallel-safe on Claude Code
Make parallel sessions safe on Claude Code, add the PR check, lower adoption friction, then test with real users. **Go/no-go gate for M2 onwards.**
- #21 Make claims exclusive: an atomic lock owned by the claiming session
- #22 Guard allows edits only in worktrees owned by the calling session
- #23 next recommends issues another session already claimed
- #24 Claim fails when someone else already owns the issue in the tracker
- #25 PR check: fail PRs that aren't linked to a claimed, in-progress issue
- #26 Run the test window: dogfooding and 5 cold onboarding sessions
- #13 Add a warn mode for the edit guard
- #17 Add repo description, topics and a demo of the guard

Go signals: still in use at the end of 4 weeks of dogfooding; at least 3 of 5 cold users finish onboarding and ship a PR; at least 2 people outside the project file issues or PRs.

### M2 · Agent-agnostic core
Extract a `coddy` CLI core with no Claude Code dependencies; Claude Code becomes the first adapter.
- #27 Extract an agent-agnostic coddy CLI core
- #28 Write an AGENTS.md section at onboarding and keep skills portable
- #16 Post the restated acceptance criteria back to the issue

### M3 · The floor
Enforcement every agent gets.
- #29 Install git hooks that refuse commits outside a claimed issue branch
- #14 Make git the default worktree tool, keep jj opt-in

### M4 · Agent adapters
- #30 Spike: build agent adapters on an existing cross-agent hook layer
- #31 Codex adapter
- #32 Cursor adapter
- #33 Copilot CLI adapter
- #34 coddy doctor: prerequisites and per-agent enforcement level
- #15 Create issue worktrees through Claude Code's WorktreeCreate/WorktreeRemove hooks

### M5 · Parallel-convenient
- #35 next --parallel N: pick issues that can safely run side by side
- #36 Refresh sibling worktrees after a PR merges
- #37 Worktree setup: a setup command, .worktreeinclude and port offsets
- #38 max_in_progress: limit how many issues can be in flight
- #39 Ownership for subagents and agent teams

### M6 · Strict mode
- #40 Strict mode: confine each agent to its issue's worktree with a sandbox

## Risks

- **Maintenance.** Four agents' hook APIs are still changing. M4 starts with a spike on building on an existing cross-agent hook layer instead of maintaining four adapters here.
- **Adoption is untested.** That's what M1's test window is for; M2 onwards waits for its result.
- **Platform absorption.** GitHub already enforces the remote half for its own cloud agent. coddy's value rests on the local, cross-vendor layer and on tracker semantics (exclusive claims, Jira, lifecycle cleanup).
