# coddy refresh (#36)

## Why

After a PR merges, every other open issue branch is behind `default_branch`. Bringing each up to date and re-running `verify` is manual, and a conflict costs the most. The M1 run (#380-#385) did this by hand after every merge.

## Goals

- One command, `/coddy:refresh`, brings every eligible issue worktree up to date with `origin/<default_branch>` and runs `verify` in each.
- A clean update with a passing verify needs nothing from the user.
- A conflict, or a verify that fails after a clean update, is reported per issue and flagged. `start <n>` picks the flag up: the implementer resolves against the issue's acceptance criteria, then `verify`, then one review round.

## Non-goals

- Pushing. `ship` stays the only landing path (#251). The skill names `/coddy:ship <n>` for an updated issue whose PR is already open.
- Updating a branch stacked on a base that is still open.
- Running in `sweep`: `verify` takes minutes, and `sweep` runs at every `next` and `start` load.

## Anti-goals

- The mechanical step never resolves a conflict and never leaves a worktree mid-rebase or mid-merge.
- Never touches a worktree another running session holds, or one with uncommitted work.
- No force push, and no change to the rule that a force push is the user's to make.

## Approaches

- **Trigger, chosen: all at once.** One skill, one verb call per issue, and one output line per issue. A clean sibling costs about 20 tokens, against 12-15k for each `/coddy:start <n>`, which would also start an unwanted review round on resume. A per-issue rebase inside `start` was rejected on cost.
- **Pushed git branches, chosen: A, merge.** Under `worktree: git`, `origin/<default_branch>` is merged into the branch, so nothing is rewritten and `ship`'s normal push works. jj workspaces rebase, since `jj git push` already moves a rewritten bookmark with a lease. B, rebase plus `--force-with-lease` in `push`, was rejected because it reverses the force-push rule. C, rebase when unpushed and merge when pushed, was rejected for having two paths to test.

## Design

**bin/coddy: `refresh <issue>`.** Prints one line and exits 0. It refuses, with exit 1, a missing lock or worktree and a `git_dir:` case, as the other verbs do.
- `skipped: <n> (<reason>)` covers:
  - another running session's lock (the `sweep` test: a gone owner, no owner line, or this session is eligible);
  - uncommitted work (`wtstate`'s `dirty`);
  - a stacked base that still resolves (`stacked` sets `from`).
- `current: <n>` when the worktree already contains `origin/<base>` (after `git fetch -q origin <base>`).
- **Update:**
  - git: `git -C <wt> merge --no-edit origin/<base>`. On a conflict, `git merge --abort`.
  - jj: `jj -R <wt> rebase -b @ -d '<base>@origin'`. If that leaves a conflicted commit in the branch, it is undone so that only this workspace's commits move back.
  - A stacked branch whose base has merged no longer resolves `from`, so it is updated like any other. A squash-merged base shows up as a conflict, which is the intended report.
- **On a conflict:** `conflict: <n> (<files>)`, with the files quoted as `q` prints them, and `needs_rebase=<origin/<base> sha>` written to the issue's state file by the core itself, since `state`'s owner check would refuse a gone owner's lock.
- **After a clean update:** `verify` runs in the worktree, with its output to `/dev/null`. A pass prints `refreshed: <n>`. A fail prints `failed: <n>` and writes the same `needs_rebase` flag.
- A stacked issue that was updated onto `default_branch` has its `.base` record removed.

**skills/refresh/SKILL.md** (new, model-invocable, `when_to_use`: refresh, update or rebase the open issues or siblings after a merge). It injects config, sweep and status with their fallback line, and runs `issue.sh refresh <n>` once per issue listed under Worktrees, one Bash call each. It shows the lines as printed, then names `/coddy:start <n>` for each `conflict:` and `failed:`, and `/coddy:ship <n>` for each `refreshed:` that has an open PR. It never edits code.

**Skills touched:**
- `start` step 4 resume: `needs_rebase` in `state` comes before every other resume rule. The implementer runs in fix mode on the plan's tier with the step 8 inputs, and the finding is "bring the branch up to date with `origin/<default_branch>` (git: merge; jj: rebase) and resolve conflicts against the acceptance criteria". Then `state needs_rebase=` is cleared, and one round of step 10 runs.
- `next` and `start`: a `cleaned:` line while other worktrees are listed adds "run `/coddy:refresh`".
- `onboard`: the AGENTS.md block's skill list gains `refresh`.

**Tests (selftest.sh, git and jj legs):**
- `current` on an up-to-date worktree;
- `refreshed` after an unrelated commit on the remote base, with a merge commit under git and a rebased branch under jj;
- `conflict` restores the worktree to its exact pre-call tip and writes `needs_rebase`;
- `failed` when verify fails;
- `skipped` for a dirty worktree, a running session's lock, and an open stacked base.
- The allowed-tools shape `refresh *` joins the closed list, and the mirror and model-invocable checks pass.

**Docs:** README's skill table and lifecycle, CLAUDE.md's verb list, skill flow and the eight-skills count.

## Left to the builder

- How the jj undo on a conflict is done without `jj op restore`, which would reset the other workspaces too. For example, record the branch's change ids before the rebase and rebase them back, or check for a conflict first with `git merge-tree --write-tree` from the colocated root.
- Which files a `conflict:` line names under jj.
