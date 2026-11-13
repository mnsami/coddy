# coddy drop (#252)

## Why

A claim ends only when its PR merges (`sweep`). An abandoned issue keeps its lock, `.branch`/`.base` records and worktree forever, `status` shows it `(gone)`, and the tracker keeps the assignee and `in progress`, so every teammate's `next` sets it aside. #38 (`max_in_progress`) would count these for good.

## Goals

- `coddy drop <issue> [--force]` ends a claim locally: the worktree goes, then the lock and the `.branch`/`.base` records. The local branch stays.
- `/coddy:drop <issue>` also ends the claim in the tracker: no `in progress`, no assignee, and a one-line comment. If you say yes, it closes an open PR.
- `sweep` prints `kept: <n> (not merged)` for an unmerged claim whose owner is gone, and `next` offers `/coddy:drop <n>` for it.

## Non-goals

- Closing the issue.
- A lock with no worktree (#253 owns that; `drop` refuses as `push` does).
- #133's `swept.tsv` record (written once #133 lands).

## Anti-goals

- `drop` must never delete uncommitted or ignored files, `--force` included.
- The skill never passes `--force` without the user's yes. Bypass and auto modes skip the permission prompt, so that prompt can't be the only confirmation.

## Approaches

- **A, chosen: one shared removal function.** Sweep's inline removal code is moved into one top-level function. `sweep` and `drop` call it.
- B, a drop mode of `sweep`, was rejected because it mixes sweep's quiet, never-fail behaviour with drop's refusals.
- C, a separate copy, was rejected because it keeps two copies of the code that deletes data.

## Design

**bin/coddy**
- `landed`, `ignored` and `lines` move out of the `sweep` case to top level. The removal code becomes one function:
  - **Move to swept/:** when the worktree holds ignored files, or is dirty under `--force`, it moves whole to `.git/coddy/swept/<n>`, as #254 does today. If `swept/<n>` already exists, the worktree stays and the function reports it.
  - **Otherwise:** `git worktree remove` / `jj workspace forget`.
  - **Last:** the lock and the `.branch`/`.base` records are removed.
  - **Branch:** the function never touches the branch. `sweep` deletes it after the function returns (as today: `git branch -D` / `jj bookmark forget`); `drop` keeps it.
- `drop <issue> [--force]` refuses with exit 1 in these cases:
  - no worktree, or no lock;
  - the lock belongs to another session that is still running (the sweep form: a gone owner, no owner line and a caller with no session are all allowed);
  - **without `--force` only:** the worktree is dirty (git `status --porcelain`; jj `diff --summary` plus untracked files), or it has commits not on `origin/<branch>`. When the remote has no `origin/<branch>`, those are the commits since the base.
  - It then prints `dropped: <n> (<branch> at <sha>)`, adding the swept note when files were moved.
- `sweep`: a claim that hasn't landed, whose owner line names a session that is gone and not this one, prints `kept: <n> (not merged)` instead of skipping silently.
- `drop` joins the usage line, and `selftest-core.sh` adds it to the git-dir refusal list.

**skills/drop/SKILL.md** (new, model-invocable, `when_to_use` for explicit asks only: abandon, drop, give up, unclaim). It carries the injected config and status blocks and their fallback line, like the other skills.
1. Read the issue, and look for an open PR on its recorded branch.
   - GitHub: `closed_by_pull_requests`, or `list_pull_requests` with `head`.
   - Jira: the PR linked in the comments.
   - GitLab: `related_merge_requests`.
2. If a PR is open, ask whether to close it. A yes is carried to step 4.
3. Run `issue.sh drop <n>`. No allowed-tools rule covers it, so it stays prompt-gated. On a refusal the skill shows the output; for a dirty or unpushed refusal it asks whether to re-run with `--force`. A no stops the skill with nothing changed in the tracker.
4. Close the PR if the user said yes in step 2.
   - GitHub and Jira: `update_pull_request` `state: closed`.
   - GitLab: `save_merge_request` `state_event: close`.
5. Update the tracker.
   - GitHub: `issue_write` `update` with the labels minus `in progress` and the assignees minus me, then a one-line `add_issue_comment`.
   - GitLab: `save_work_item` with `remove_labels: [in progress]` and the assignees minus me, then a `save_note`.
   - Jira: a To Do-category transition and unassign, then a comment.
   - Each tracker is read back afterwards. Anything still set is reported, never retried.
6. End by naming `/coddy:next`.

**Skills touched:**
- `next`: the cleanup rule covers `kept: <n> (not merged)`, shown with `/coddy:drop <n>` only when `<n>` matches the tracker id pattern (digits or a Jira key), else the line as printed.
- `start`: its cleanup sentence names the new kind of `kept:` line.
- `onboard`: the AGENTS.md block's skill list gains `drop`.

**Tests**
- `selftest.sh` covers:
  - drop cleans and keeps the branch;
  - the ignored `.env` lands under `swept/`;
  - `--force` on a dirty worktree moves it to `swept/`;
  - refusals for a dirty worktree, unpushed commits and another running session's lock;
  - sweep's `kept: (not merged)` line.
- Both git and jj legs run where the suite already has them. `drop` stays on the prompt-gated list, and the mirror and model-invocable checks pass.

**Docs:** README's lifecycle line and skill table, CLAUDE.md's lock table (a `drop` column) and its skill flow.

## Left to the builder

- How the unpushed-commit test reads a stacked base (`stacked`'s `from`).
- Whether `issue_write` with an empty `assignees` list clears the assignees through the MCP. The read-back in skill step 5 catches it if not.
