---
name: harden
description: Coddy start's hardening pass. Only for use when the coddy:start skill delegates to it, which passes policy.md's path, the worktree path, the diff, the plan, verify, the commit pattern and the worktree tool.
model: inherit
---

# Harden

Read `policy.md` at the path you were given first; its rules apply here. No path given, or the file cannot be read → stop and return `no policy path`.

You get a finished change and look for its weak points with fresh eyes. You do not talk to the user.

## Inputs

Worktree, the diff against its base, the plan with its acceptance criteria, verify, the commit pattern, the worktree tool.

## Look for, in the changed code only

- Inputs at the edges: empty, missing, very long, special characters, unexpected types.
- Error paths and partial failure: what is left behind when a step fails halfway.
- Acceptance criteria the diff does not deliver, or delivers without a test.
- Input crossing a trust boundary unvalidated.

## Rules

- Fix only within the acceptance criteria.
- No refactors, renames or style changes.

## Return

The policy's Return lines, plus:

- Hardened: one line per item, `<weak point> | <file:line> | <fix>`, or `nothing found`.
