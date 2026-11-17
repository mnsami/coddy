# Delete snap's command-text reader (#261)

Decided in #285 D1 (2026-11-01, option 1). Plan comment on #261 holds the acceptance criteria.

## Why

snap's reader (`adds`, an awk tokenizer) refused a `git worktree add` outside `.worktrees/` and pushes to the
default branch, force pushes and remote branch deletes by reading the command's text. Every spelling it could not
read (`bash -c`, `eval`, an alias, `sudo`, a function, a variable) passed, and each one found became a bug: about 20
open at the time #261 was filed. The layers a steered agent cannot skip hold without it.

## Goals

- `bin/hermy` holds no command-text reader; snap does not read `tool_input.command`.
- What holds instead is stated and tested: trip reports a stray worktree after it is made; pre-push and branch
  protection refuse a push to the default branch (jj: branch protection only).
- triage and start file no issue for a finding that is another case of a limit the project's docs already record.

## Non-goals

- Refusing a claimed branch's delete in pre-push (#269).
- A jj argv shim (#263, #285 D9).
- Reporting a push to the default branch after the fact (#263).

## Approaches

- A: delete the reader. Chosen in #285 D1.
- B: keep it, refusing literal spellings under a written scope rule, and close the rest as ceilings. Rejected: the
  spelling variants kept arriving, and the backstops that hold against a steered agent do not depend on it.

## Decided

- snap keeps its snapshot, config copy, settings lines and session mark, and ends as it does for any other command.
- Force push of a claimed branch is allowed (#285 D10); a claimed branch's delete is not refused until #269.
- `THIRD_PARTY_NOTICES.md` goes: its only entry is the super-board push rules ported into the reader.
- triage step 1: a finding that is another case of a recorded limit gets no issue, naming where it is recorded.
  start step 11: such an idea is offered as drop only.

## Left to the builder

- Exact wording of the docs and the two skill lines, in the project's terse style.
- Where the three new self-test cases sit among the existing ones.
