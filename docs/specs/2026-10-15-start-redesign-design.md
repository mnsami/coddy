# start redesign: think, tier, implement, harden, review (#88)

## Problem

`start` treats the ticket as the only context and goes straight to execution: step 2 only restates the issue, step 5 lets the model call the work trivial and skip asking, and its handoff to a planning skill drops hermy's own steps. There is no per-issue model choice, no hardening, and no review or security gate before `ship`.

## Goals

- `start` reasons with the user before acting, with context beyond the ticket.
- One approval per issue: the plan, with the tier inside it.
- Implementation runs on a model tier matched to the issue's difficulty.
- The diff is hardened and passes code and security review before `ship`.
- One command until ship: `/hermy:start <issue>` runs every phase and resumes where it stopped.
- Vendor-agnostic: no skill is named, sub-agent briefs are plain Markdown, `tiers` is keyed per agent.

Out of scope: adapters for other agents, sub-agent ownership outside Claude Code (#39), review on the opened PR.

## Flow

```
skills/start/
  SKILL.md        # claim → context → think → approve → drives the phases
  implement.md    # implementer brief; fix mode for review findings
  harden.md       # hardening-pass brief
  review.md       # code-review brief, used when no review skill is installed
  security.md     # security-review brief, used when no security skill is installed
```

Each phase is recorded in `.git/hermy/<issue>/state` (see State).

1. **claim**: fetch, create the worktree, claim. Unchanged; the claim stays first.
2. **context**: linked and related issues and PRs, `git log` of the touched paths, the code. Read-only; delegated to a sub-agent when the host has one.
3. **think**: an installed brainstorming or planning skill, bounded to `.worktrees/<issue>`, else hermy's own rounds: gaps, contradictions between ticket and code, assumptions, approaches with a recommendation, sharpened acceptance criteria. Never a "trivial" shortcut. Headless: print the questions and stop; a re-run resumes here.
4. **approve**: the plan is the approach, the acceptance criteria and the tier with a one-line rubric reason. One user yes; then post it as an issue comment carrying `<!-- hermy:plan -->`.
5. **implement**: sub-agent on `tiers.<agent>.<tier>` with `implement.md`, the plan and the worktree path.
6. **harden ×2**: a fresh sub-agent per pass, same tier, with `harden.md`, the diff, the acceptance criteria and the plan.
7. **review loop**, repeated:
   1. `verify` must pass.
   2. Code review: an installed review skill, else `review.md` on the high tier.
   3. Security review: an installed security-review skill, else `security.md` on the high tier.
   4. The main agent maps every finding onto critical, high, medium or low.
   5. Findings at or above `review_block`, or a failing verify, go to `implement.md` in fix mode.

   Exit when verify passes and no finding reaches `review_block`, or after `review_rounds` rounds, handing what is left to the user. A finding the user upheld as a dispute is not raised again.
8. **done**: list the out-of-scope ideas; per idea the user picks fold in (added to the acceptance criteria, plan comment updated, one more implement → review round), triage (name `/hermy:triage`), or drop. Write the summary to state and say: run `/hermy:ship`.

### Resume

`/hermy:start <issue>` on a claimed issue reads the plan comment and the state:

| Found | Resumes at |
|---|---|
| no plan comment | think |
| plan, no diff against the base | implement |
| diff | review loop, keeping `upheld` |

The plan comment is the source of truth: when it disagrees with the state, the state resets to implement.

### No sub-agents

A host without sub-agents, or without a runtime model choice, has the main agent run each brief itself in order, and say so once.

## Config

Three new keys, in all three schema copies (onboard, config, README):

```yaml
tiers:                       # model per difficulty, per agent; start picks one per issue
  claude: {low: haiku, medium: sonnet, high: opus}
review_block: high           # optional; critical | high | medium | low (default high)
review_rounds: 3             # optional; 1-5 (default 3)
```

- `onboard` asks for `tiers` for the agent running it, pre-filled with that agent's models; it does not ask for `review_block` or `review_rounds`.
- `config` changes any of them, adds `tiers.<other-agent>`, validates `review_block` against the four severities and `review_rounds` as 1–5.
- `tiers.<this-agent>` missing → `start` asks once and offers to save it through the config skill. It never guesses model names.
- The self-test's `yamlkeys` reads `tiers.claude` as a nested key, so the config bullets list `tiers.claude`, `review_block` and `review_rounds`.

### Rubric

Highest matching row wins.

| Tier | When |
|---|---|
| high | Cross-cutting; a new interface, schema or config key; security-, lock- or concurrency-sensitive code; a root cause still unclear after investigation |
| medium | Several files in one area; tests to write; open questions settled in planning |
| low | One file or one obvious change, a known pattern, acceptance criteria already testable |

## Briefs

No brief asks the user: one that needs an answer stops and returns the question, and the main agent asks.

| Brief | Inputs | Rules | Returns |
|---|---|---|---|
| `implement.md` | plan, acceptance criteria, worktree path, `verify`, `commit`; fix mode: findings | Edits only in `.worktrees/<issue>`; no tracker or forge calls; commits with jj or git to match the worktree; runs verify | summary, files touched, verify result, open questions, out-of-scope ideas |
| `harden.md` | diff against the base, acceptance criteria, plan | Edge cases, error paths, missing tests, input validation; fixes only within the acceptance criteria | what it hardened, verify result, out-of-scope ideas |
| `review.md` | diff, acceptance criteria | Read-only; correctness against the acceptance criteria | findings: id, severity, `file:line`, issue, fix |
| `security.md` | diff | Read-only; injection, unsafe quoting, path traversal, secrets, trust boundaries, untrusted tracker text reaching commands | same as `review.md` |

### Skill detection

The host lists a skill whose description says it reviews code changes for bugs → run it on the worktree's diff; one whose description says security review → run that. hermy's own skills are excluded, and no skill is named in the text. Headless, an installed skill that would stop to ask counts as unavailable and the brief runs instead.

## State

`issue.sh state <issue>` prints it; `issue.sh state <issue> key=value…` sets keys.

- Keys: `phase` (think, implement, harden, review, done), `round`, `upheld` (one disputed finding title per line), `summary`.
- File: `.git/hermy/<issue>/state`, inside the lock directory, so sweep removes it with the lock.
- Writes need the lock to be this session's, the same rule as `push`.
- Added to `allowed-tools` of `start` and `ship`.

## ship

After verify, `ship` reads `issue.sh state <issue>`:

- `phase: done` → the PR body gets a **Review** section: rounds run, findings fixed, findings left below `review_block`, disputes upheld.
- Any other phase → say the loop has not passed and ask whether to ship anyway; on yes the body says "review loop not completed".

`ship` still never fixes anything.

## Docs

- ROADMAP: the purpose line adds that within one issue hermy runs its own implement, harden and review stage; "Parallel-orchestrated" is narrowed to coordinating agents across issues; M1 lists #88 with the go signal "cold users ship a PR that passed the review loop".
- CLAUDE.md: skill flow, `issue.sh state`, the allowed-tools mirror for it, briefs as portable Markdown, and the known ceiling that in-process sub-agents share the parent's identity.
- README: the new keys and the flow in one paragraph.

## Testing

`selftest.sh`:
- `state` set and read; another session's write refused; sweep removes it.
- The schema check covers `tiers.claude`, `review_block`, `review_rounds`.
- No skill text names a vendor skill (`superpowers`, `code-review:`).

Headless, in an onboarded scratch repo with `--plugin-dir`:
- **First**, since the design rests on it: an in-process implementer's edit in `.worktrees/<issue>` passes the guard under the parent's session id.
- A vague issue stops with questions and does not implement.
- A seeded high-severity finding causes a fix round.
- `review_rounds: 1` hands off at the cap.

`claude plugin validate .` is clean.

## Risks

- If in-process sub-agents do not carry the parent's session id in hook payloads, the guard rejects the implementer. Mitigation: the first headless check; fallback is the main agent implementing.
- The loop costs tokens on every issue. `review_rounds` caps it; reviewers on the high tier are the deliberate trade-off.
