# README redesign (#451)

## Why

`README.md` is 554 lines and 5,584 words. Half of it is enforcement detail. A reader cannot quickly find what
coddy is, how to install it or how to run it. The owner wants every page this change writes to be easy to read
and to make its point in the plainest way.

## Goals

- First screen: what coddy is, how to install it, how to run `onboard → next → start → ship`.
- README about 190 lines, no line over 120 characters.
- Enforcement detail on its own page, `docs/enforcement.md`, written for a reader, not a maintainer.
- Every claim true to the code. The README half of #259 is done here: the pitch says the hooks stop the common
  slips and report shell writes afterwards, and that branch protection and the required PR check are the hard
  stops; claims are cooperative; tracker checks are `start` steps; jj push coverage is partial; the shell dodge
  list (`bash -c`, `eval`, an alias, a function, `sudo`, `cd -`) sits beside the tripwire.

## Non-goals

- CLAUDE.md, ROADMAP.md (the ROADMAP half of #259 stays there), skills, scripts' behaviour.
  Three CLAUDE.md fixes were folded in after review: the tripwire dodge list names a shell function,
  "both hold only when the lock and the caller name a session" now names the edit guard and `push`,
  and the PR check's own-workflow ceiling is added.
- New features or new claims.

## Anti-goals

- Shorter by dropping a ceiling. Every ceiling in today's README appears in README, `docs/enforcement.md` or `docs/enforcement-limits.md`.
- A new page as dense as the old one.

## Approaches

- A. Tidy today's text into lists. Safest for accuracy, still dense.
- B. One fixed shape per layer: Stops, Lets through, Asks you first, Always refuses, Doesn't catch, When it
  blocks you, Needs (only the rows that apply). Internals stay in CLAUDE.md behind one link. **Chosen**: the
  owner asked for the plainest reading, and a fixed shape makes a missing ceiling easy to spot.
- C. Scenario-led ("Claude edits outside a worktree → …"). Readable, but ceilings scatter.

## Structure (approved)

README.md:

1. Title, badge, honest 3-line pitch.
2. Transcript (as is).
3. Install: plugin and `get.sh` blocks, `coddy doctor`, "You need" one line each (GitLab gitlab.com-only line
   stays), "macOS, Linux, WSL; not native Windows" with a link.
4. Quick start: onboard → next → start → ship → merge, one line each.
5. Skills: one short row per skill; In Progress and sweep-after-merge in about 4 lines.
6. Confidential issues: about 9 lines with both pinned ceilings.
7. How it enforces: one line per layer, the hard stops, what you set by hand, the three ways out, link.
8. Config: `## Config` heading and yaml unchanged, short bullets; leaving the workflow points to the new page.
9. Related projects, Contributing, Develop: trimmed.

docs/enforcement.md:

1. What holds against what: hooks stop slips; hard stops are branch protection and the required PR check.
2. When hooks fail or are off, and the three ways out.
3. Platform: bash and `PATH`, native Windows, `bin/coddy` and the `CODDY_*` variables.
4. One section per layer in shape B: Edit guard (with claims and `guard: warn`), Shell tripwire (the everyday rows,
   with a pointer to `docs/enforcement-limits.md`), Config lock, Git hooks, Branch protection, PR check (GitHub and
   the GitLab job with `CODDY_TOKEN`).
5. Leaving the workflow.

docs/enforcement-limits.md: the long tripwire lists (a check that fails, settings files, what the text check
reads and the dodge list), linked from `docs/enforcement.md`.

## Writing rules

- One idea per sentence; short sentences; "you" for the reader.
- A term is explained the first time it appears, or not used.
- Lists over paragraphs; bold labels only for the shape-B rows.
- No line over 120 characters in either file.

## Constraints

- `scripts/selftest.sh` keeps passing. README keeps `## Config`, its yaml keys, "reaches gitlab.com only",
  "do not pre-approve, so its calls prompt", "The diff itself is public once pushed" and
  "Ideas `/coddy:triage` files from that work are not covered", and never says "on any instance",
  `closes_issues` or `related_issues`.
- The three `CODDY_TOKEN` phrases ("Only a job that reports it cannot read", "tied to this project alone, never
  a personal one", "any branch's pipeline can read it") move to `docs/enforcement.md`; `scripts/selftest.sh`
  checks that file for them instead of README (two lines).
- Anchors `#config` and `#develop` keep working.

## Left to the builder

- Exact wording, section order inside each shape-B block, and which today's sentences merge.
