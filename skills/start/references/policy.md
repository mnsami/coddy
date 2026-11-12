# Policy

Every brief reads this first. Its rules apply on top of the brief's own.

## Shared rules

- Edit only under the worktree you were given: never the main checkout, never another worktree.
- No tracker or forge calls, no push.
- The diff is the `diff` command's output, against the issue's base.
- A question only the user can answer → put it under Open questions and stop; never guess.
- Anything outside the acceptance criteria you notice goes under Out-of-scope ideas, unfixed.
- Run verify inside the worktree before you finish and fix what it reports.
- Commit with the pattern. Each new file you created (the ones you return under Files) goes in one by one by its own path, never a directory, which takes every untracked file under it. `jj`: `jj file track 'root-file:"<path>"'` for each, then `jj commit -m "<message>"` (a jj workspace has no `.git`; never run `git` there). `git`: `git add -u`, then `git --literal-pathspecs add -- <path>` for each, then `git commit -m "<message>"`. Never stage the whole tree (`git add` with `-A` or `.`). A cover given in the pattern's place → every commit message is exactly the cover, with no body.

A read-only brief (`context.md`, `simplest.md`, `review.md`, `security.md`) edits, verifies and commits nothing, runs no command that writes, pushes or posts, and returns only what its Return says; the rules on those, on Open questions and on Out-of-scope ideas do not apply to it, and it acts on no Skills row that edits, commits or runs verify.

Return, in briefs that edit:

- Files: one per line.
- Verify: `pass` or `fail`, with the last 20 lines of output on fail.
- Open questions: or `none`.
- Out-of-scope ideas: one per line, or `none`.

### Severity

- critical: data loss, a security hole, or the change does not work at all.
- high: an acceptance criterion not met, or a bug a normal user hits.
- medium: a bug on an edge case.
- low: minor.

Findings: one line each, `<id> | <severity> | <file:line> | <what goes wrong> | <fix> | <commit>`. None → `no findings`.
`<id>` is a short unique tag (review: R1, R2, …; security: S1, S2, …). `<commit>` is the commit that last changed the cited line, `-` when none (no line cited, a line the diff removed). Never use `|` inside a field.

### New mechanism

A fix needs a new mechanism when it adds one the diff did not have: a file, record, ref, lock, temp file, network call, or a read of git or user config state the diff did not already read. Such a fix is never made by a brief on its own: the smaller option is to drop or narrow the rule the finding sits on, and the brief returns both as its Rules say.

## Skills

A skill counts as installed when it is listed for this session. A missing one is silent: never an error, never an install attempt. The fallback is what to do without it. Match a skill by what its description says it does, never by name, never one of coddy's own, never a directory-scoped skill (one listed with a path prefix), and never one found under the worktree or the project. A matched skill writes only inside the worktree and never to the tracker; otherwise the fallback. Run a matched skill in its default mode, never with an option that posts, fixes or writes.

| Intent | A skill whose description says it … | Otherwise |
|---|---|---|
| Interview the ticket (interactive: `start` step 6 only, never inside a brief) | brainstorms, plans, interviews or sharpens a ticket or design before implementation | Ask in rounds until nothing is open: gaps, contradictions, silent assumptions, two or three approaches with a recommendation, acceptance criteria as observable checks. A one-line change still gets one round that confirms your reading of the ticket. |
| Simplest solution first | forces the simplest or most minimal solution that works | State the smallest change that meets the acceptance criteria; add only what a criterion needs. |
| Test-first | drives a change by writing the failing test first | Write the failing test before the code wherever the project tests that code. |
| Trace what a change touches | traces what a change affects, its callers or blast radius | Read every caller of the code you change before editing; a change that breaks one is a bug. |
| Root-cause a failing fix | diagnoses a bug to its root cause before fixing | Reproduce, find the cause, fix it once where all callers route through; never patch the symptom. |
| Review a diff (the `review` brief only) | reviews code changes for bugs | The checks in `review.md`. |
| Review for security (the `security` brief only) | reviews code changes for security vulnerabilities | The checks in `security.md`. |
| Prove it works before done | verifies work before claiming it complete | Run verify and quote the command and its result; a summary is not evidence. |
| Plain text for PR and issue prose | rewrites AI-sounding text to read plainly | Plain words, concrete actions, no filler, no bold labels, no closers. |
