# start redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `/coddy:start <issue>` thinks the issue through with the user, then implements it on a difficulty-matched model, hardens it twice and loops code + security review until nothing blocking is left, resuming where it stopped.

**Architecture:** `start/SKILL.md` drives phases; each phase's sub-agent brief is a portable Markdown file next to it. Mechanics (phase, round, upheld disputes, summary) live in a new `issue.sh state` subcommand under the lock directory. Three config keys (`tiers`, `review_block`, `review_rounds`) join the three schema copies. `ship` reads the state into the PR body.

**Tech Stack:** bash (3.2-compatible), jj/git, Markdown skills, Claude Code plugin hooks, GitHub/Atlassian MCP.

**Spec:** `docs/specs/2026-10-15-start-redesign-design.md`

## Global Constraints

- Work only in `/Users/minasami/dev/private/coddy/.worktrees/88`. It is a jj workspace: commit with `jj commit -m`, never `git` inside it.
- Commit messages: `type: summary` (`feat`, `fix`, `chore`), ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Skill bodies are terse imperative checklists: `condition → action` guards, numbered steps, per-tracker sub-bullets. No explanatory prose.
- Frontmatter values contain no `: ` and no ` #`.
- Every `issue.sh` subcommand a skill runs is mirrored in its `allowed-tools` as `Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" <sub> *)`.
- No skill text names a vendor skill (`superpowers`, `code-review:`); installed skills are found by their description.
- `review_block` default `high`; `review_rounds` default `3`, range 1–5; reviewers always on the `high` tier; 2 hardening passes.
- Scripts stay bash 3.2-compatible (macOS `/bin/bash`): no `declare -A`, no `${var,,}`, no `mapfile`.
- After any change under `scripts/`: `bash scripts/selftest.sh` must end with no `FAIL` line and exit 0.

## Review Focus

1. A state value holding spaces, `=`, quotes or `$(…)` is stored and printed literally, never evaluated. (Task 2 test)
2. The lock's owner after `/clear` (new session id, same pid) can still write state; another running session can read but not write. (Task 2 tests)
3. An issue with a plain-file marker from before locks gets a clear "re-claim" refusal on a state write, not a silent loss. (Task 2 test)
4. A headless run whose installed review skill would stop to ask falls back to the brief instead of hanging. (Task 5 wording, Task 8 check)
5. `tiers` without an entry for the running agent makes `start` ask, never guess a model name. (Task 5 wording, Task 8 check)

---

### Task 1: Spike — does an in-process sub-agent's edit pass the guard?

The design rests on this. If it fails, stop and report to the user before any other task: the fallback (main agent implements) changes Task 5.

**Files:** none in the repo (scratch directory only).

- [ ] **Step 1: Build an onboarded scratch repo**

```bash
S=$(mktemp -d); P=/Users/minasami/dev/private/coddy/.worktrees/88
git init -q --bare "$S/origin.git" && git clone -q "$S/origin.git" "$S/repo" 2>/dev/null
cd "$S/repo" && git checkout -q -b main && echo hi > README.md && git add -A && git commit -q -m init && git push -q -u origin main
mkdir .claude && printf 'tracker: github\nrepo: nobody/nothing\nworktree: git\ndefault_branch: main\nbranch: "{type}/{issue}-{slug}"\ncommit: "{type}: {summary}"\nverify: "true"\n' > .claude/coddy.yml
echo "$S"
```

- [ ] **Step 2: Run the probe headless**

```bash
cd "$S/repo" && claude --plugin-dir "$P" --permission-mode acceptEdits --allowedTools "Bash Agent Write" -p "Run: bash \"$P/scripts/issue.sh\" create 1 feat/1-spike && bash \"$P/scripts/issue.sh\" claim 1. Then start one general-purpose sub-agent with the Agent tool. Its task: use the Write tool to create $S/repo/.worktrees/1/spike.txt containing hi, then use the Write tool to create $S/repo/outside.txt containing hi, and quote back verbatim any error either Write returns. Finally print INSIDE_OK or INSIDE_BLOCKED, then OUTSIDE_OK or OUTSIDE_BLOCKED, each followed by the quoted error if any."
```

- [ ] **Step 3: Read the result**

```bash
test -f "$S/repo/.worktrees/1/spike.txt" && echo inside-written; test -f "$S/repo/outside.txt" && echo outside-written; cat "$S/repo/.git/coddy/1/owner"
```

Expected: `inside-written`, no `outside-written` (the guard is live for the sub-agent), and the owner line still names the parent's session id. Outcome A (expected) → continue. Outcome B (inside blocked with "belongs to session") → stop, report the quoted error and ask the user whether to proceed with the main agent implementing. Outcome C (outside written) → stop: hooks do not fire for sub-agents, report.

- [ ] **Step 4: Record the result on the issue**

Post one comment on #88 (github `add_issue_comment`) with the three result lines and the `claude --version` output.

---

### Task 2: `issue.sh state`

**Files:**
- Modify: `scripts/issue.sh` (header comment lines 3-8; new `state)` case before `*)` at line 385; usage line 385)
- Test: `scripts/selftest.sh` (inside `leg()`, after the line `t 0 "$tool: guard allows a Claude Code worktree named for the claimed issue" …`; and in the sweep block after `t 1 "$tool: sweep removed its lock and branch record" …`)

**Interfaces:**
- Produces: `bash issue.sh state <issue>` prints the state file (`key=value` lines; nothing when empty), exit 0. `bash issue.sh state <issue> key=value… ` replaces each key's line; `key+=value` appends a line. Exit 1 with `coddy: …` on stderr when: the issue has no lock, the lock is a plain file, another session owns it, a key is not `[a-z_]+`, or an argument has no `=`. File: `.git/coddy/<issue>/state`.

- [ ] **Step 1: Write the failing tests**

In `scripts/selftest.sh`, inside `leg()`, after the line ending `guard "$repo/.claude/worktrees/$n/a.txt"`, insert:

```bash
  t 0 "$tool: state is empty before any write" test -z "$(run state "$n" 2>&1)"
  t 0 "$tool: state sets keys" run state "$n" phase=implement round=0
  t 0 "$tool: state prints them" says "^phase=implement$" run state "$n"
  run state "$n" phase=review >/dev/null 2>&1
  t 0 "$tool: a set replaces the key's line" test "$(run state "$n" | grep -c '^phase=')" = 1
  t 0 "$tool: and keeps the new value" says "^phase=review$" run state "$n"
  run state "$n" 'upheld+=a b' >/dev/null 2>&1; run state "$n" 'upheld+=c' >/dev/null 2>&1
  t 0 "$tool: += appends a line per value" test "$(run state "$n" | grep -c '^upheld=')" = 2
  run state "$n" 'summary=x=y "q" $(touch '"$tmp"'/pwned)' >/dev/null 2>&1
  t 0 "$tool: a value is stored literally" says '^summary=x=y "q" \$(touch' run state "$n"
  t 1 "$tool: and never evaluated" test -e "$tmp/pwned"
  t 1 "$tool: state refuses a key that is not lower case" run state "$n" Phase=x
  t 1 "$tool: state refuses an argument without =" run state "$n" phase
  t 1 "$tool: state refuses another running session's write" as sess-b 1 state "$n" phase=done
  t 0 "$tool: that refusal names the owner" says "belongs to session sess-a" as sess-b 1 state "$n" phase=done
  t 0 "$tool: another session may read it" says "^phase=review$" as sess-b 1 state "$n"
  t 0 "$tool: the owner's process under a new session id (/clear) may write" as sess-b $$ state "$n" round=1
  run claim "$n" >/dev/null 2>&1 # the lock back to this session id
  t 1 "$tool: state refuses an issue with no claim" run state 999 phase=x
```

In the sweep block, right before the line `t 0 "$tool: sweep reports a merged, clean worktree as cleaned" …`, insert:

```bash
  mkdir -p ".git/coddy/$p" && echo "phase=done" > ".git/coddy/$p/state"
```

and right after `t 1 "$tool: sweep removed its lock and branch record" …`, insert:

```bash
  t 1 "$tool: sweep removed its state" test -e ".git/coddy/$p/state"
```

Right after the line `t 0 "$tool: --take adopts a lock with no owner" run claim "$p" --take`:

```bash
  rm -rf ".git/coddy/$p"; : > ".git/coddy/$p"
  t 1 "$tool: state refuses a plain-file marker" run state "$p" phase=x
  t 0 "$tool: and says to re-claim" says "/coddy:start $p" run state "$p" phase=x
  rm -f ".git/coddy/$p"
```

(The existing next line `rm -rf ".git/coddy/$p"` stays harmless.)

- [ ] **Step 2: Run to verify they fail**

Run: `bash scripts/selftest.sh 2>&1 | grep -c '^FAIL'`
Expected: a non-zero count; the new `state` lines FAIL (usage error, exit 1 where 0 is wanted).

- [ ] **Step 3: Implement**

In `scripts/issue.sh`, add to the header comment after the `push` line:

```bash
#   issue.sh state  <issue> [key=value | key+=value ...]   print, or set, the issue's phase state for start and ship
```

Insert before the `*)` case:

```bash
  state)
    # start's phase state: key=value lines in the lock directory, so sweep
    # removes them with the lock. Anyone may read; only the lock's owner
    # writes, held as push is. Values are written, never evaluated.
    lock=".git/coddy/$issue" f=".git/coddy/$issue/state"
    [ -e "$lock" ] || die "issue $issue is not In Progress. Run /coddy:start $issue."
    [ $# -gt 2 ] || { cat "$f" 2>/dev/null; exit 0; }
    [ -d "$lock" ] || die "issue $issue's claim is from before locks. Run /coddy:start $issue to re-claim it."
    me="${CLAUDE_CODE_SESSION_ID-}"; owner "$issue"
    [ -z "$sid" ] || [ -z "$me" ] || mine || die "the worktree of issue $issue belongs to session $sid. Run /coddy:start $issue to take it over."
    shift 2
    for kv; do
      case "$kv" in *=*) ;; *) die "state takes key=value or key+=value, got '$kv'" ;; esac
      k="${kv%%=*}" v="${kv#*=}" add=""
      case "$k" in *+) add=1 k="${k%+}" ;; esac
      case "$k" in ''|*[!a-z_]*) die "state keys are lower case words, got '$k'" ;; esac
      case "$v" in *"
"*) die "state values are one line" ;; esac
      if [ -n "$add" ]; then
        printf '%s=%s\n' "$k" "$v" >> "$f" || die "could not write $f"
      else
        { grep -v "^$k=" "$f" 2>/dev/null; printf '%s=%s\n' "$k" "$v"; } > "$f.tmp" && mv "$f.tmp" "$f" || die "could not write $f"
      fi
    done ;;
```

Change the usage line to:

```bash
  *) die "usage: issue.sh create <issue> <branch> [base-issue] | claim <issue> [--take] | push <issue> [message] | state <issue> [key=value ...] | sweep | status | guard" ;;
```

- [ ] **Step 4: Run to verify they pass**

Run: `bash scripts/selftest.sh; echo "exit $?"`
Expected: no `FAIL` line; `exit 0`. Also on macOS bash 3.2: `/bin/bash scripts/selftest.sh | grep -c '^FAIL'` prints `0`.

- [ ] **Step 5: Commit**

```bash
jj commit -m "feat: issue.sh state records start's phase, round, disputes and summary (#88)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Config keys `tiers`, `review_block`, `review_rounds`

**Files:**
- Modify: `skills/onboard/SKILL.md` (yaml schema block; step 3)
- Modify: `skills/config/SKILL.md` (`## Keys`; step 1; step 2)
- Modify: `README.md` (yaml block under `## Config`)
- Test: existing `schema` check in `scripts/selftest.sh:69`

**Interfaces:**
- Produces: config keys read by Task 5 (`tiers.<agent>.{low,medium,high}`, `review_block`, `review_rounds`).

- [ ] **Step 1: Make the schema check fail first**

In `skills/onboard/SKILL.md`, in the yaml block, after the `guard:` line, add:

```yaml
tiers:                       # model per difficulty, per agent; start picks one per issue
  claude: {low: haiku, medium: sonnet, high: opus}
review_block: high           # optional; critical | high | medium | low (default high); findings at or above it trigger another fix round
review_rounds: 3             # optional; 1-5 (default 3); review rounds before start hands the rest to the user
```

Run: `bash scripts/selftest.sh | grep schema`
Expected: `FAIL schema: onboard, config and README list the same keys`.

- [ ] **Step 2: Add the keys to the other two copies**

`README.md`, in the yaml block under `## Config`, after the `guard:` line:

```yaml
tiers:                       # model per difficulty, per agent; start picks one per issue
  claude: {low: haiku, medium: sonnet, high: opus}
review_block: high           # optional; critical | high | medium | low (default high)
review_rounds: 3             # optional; 1-5 (default 3)
```

`skills/config/SKILL.md`, under `## Keys`, after the `guard` bullet:

```markdown
- `tiers.claude`: the model per difficulty for one agent, as `{low: <model>, medium: <model>, high: <model>}`, in names that agent accepts. Other agents get their own line (`tiers.codex`, `tiers.gemini`, …); add one when a teammate uses another agent.
- `review_block`: `critical`, `high`, `medium` or `low`. Optional; absent means `high`. Findings at or above it make start run another fix round.
- `review_rounds`: a whole number from 1 to 5. Optional; absent means `3`.
```

In its step 1, change the multi-select list `(\`default_branch\`, \`branch\` and \`commit\` patterns, \`verify\`, \`roadmap\`)` to `(\`default_branch\`, \`branch\` and \`commit\` patterns, \`verify\`, \`roadmap\`, \`tiers\`, \`review_block\`, \`review_rounds\`)`.

- [ ] **Step 3: onboard asks for the running agent's tiers**

In `skills/onboard/SKILL.md` step 3, after the sentence ending `\`git\` as the other (\`jj: missing\` → say so in the \`jj\` option).`, add:

```markdown
Also `tiers` for the agent running this skill only, keyed by its lower-case name (`claude`, `codex`, `gemini`, `cursor`, `copilot`): one option with its own cheap, default and strongest models as low, medium and high (Claude Code: `haiku`, `sonnet`, `opus`), marked recommended. `review_block` and `review_rounds` are not asked for: leave them out, their defaults apply.
```

- [ ] **Step 4: Run the schema check**

Run: `bash scripts/selftest.sh; echo "exit $?"`
Expected: `ok   schema: onboard, config and README list the same keys`, no `FAIL`, `exit 0`.

- [ ] **Step 5: Commit**

```bash
jj commit -m "feat: tiers, review_block and review_rounds config keys (#88)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Sub-agent briefs

**Files:**
- Create: `skills/start/implement.md`, `skills/start/harden.md`, `skills/start/review.md`, `skills/start/security.md`

**Interfaces:**
- Produces: briefs Task 5 passes to sub-agents. Return formats: implement/harden → sections `Summary`, `Files`, `Verify`, `Open questions`, `Out-of-scope ideas` (harden: `Hardened` in place of `Summary`; fix mode adds `Findings`); review/security → one line per finding `<id> | <severity> | <file:line> | <what goes wrong> | <fix>` or `no findings`.

- [ ] **Step 1: Write `skills/start/implement.md`**

```markdown
# Implement

You implement one issue in its own worktree. You do not talk to the user: a question only they can answer goes under Open questions, and you stop.

## Inputs

- Worktree: an absolute path. Work only there.
- Plan: the approach and the acceptance criteria.
- Verify: the command that exits 0 when the work can ship.
- Commit: the message pattern. Worktree tool: `jj` or `git`.
- Fix mode: a list of findings (`id | severity | file:line | what goes wrong | fix`) instead of a fresh start.

## Rules

- Edit only under the worktree: never the main checkout, never another worktree.
- No tracker or forge calls, no push.
- Stay inside the acceptance criteria. Anything else you notice goes under Out-of-scope ideas, unfixed.
- Fix mode: fix each finding, or say why it is wrong; change nothing else.
- Write the test first wherever the project already tests the code you touch.
- Run verify inside the worktree before you finish and fix what it reports.
- Commit with the pattern. `jj`: `jj commit -m "<message>"` (a jj workspace has no `.git`; never run `git` there). `git`: `git add -A && git commit -m "<message>"`.

## Return

- Summary: what changed, in at most 5 lines.
- Files: one per line.
- Verify: `pass` or `fail`, with the last 20 lines of output on fail.
- Open questions: or `none`.
- Out-of-scope ideas: one per line, or `none`.
- Findings (fix mode only): `<id>: fixed` or `<id>: disputed, <reason>`.
```

- [ ] **Step 2: Write `skills/start/harden.md`**

```markdown
# Harden

You get a finished change and look for its weak points with fresh eyes. You do not talk to the user.

## Inputs

Worktree, the diff against its base, the plan with its acceptance criteria, verify, the commit pattern, the worktree tool.

## Look for, in the changed code only

- Inputs at the edges: empty, missing, very long, special characters, unexpected types.
- Error paths and partial failure: what is left behind when a step fails halfway.
- Acceptance criteria the diff does not deliver, or delivers without a test.
- Input crossing a trust boundary unvalidated.

## Rules

- The same editing, verify and commit rules as `implement.md` in this directory.
- Fix only within the acceptance criteria; anything else goes under Out-of-scope ideas.
- Each fix comes with a test wherever the project tests that code.
- No refactors, renames or style changes.

## Return

- Hardened: one line per item, `<weak point> | <file:line> | <fix>`, or `nothing found`.
- Verify: `pass` or `fail`, with the last 20 lines of output on fail.
- Out-of-scope ideas: one per line, or `none`.
```

- [ ] **Step 3: Write `skills/start/review.md`**

```markdown
# Review

Read-only: you do not edit, commit or talk to the user. You review one change against its acceptance criteria.

## Inputs

The diff, the acceptance criteria, the worktree path (read any file there for context).

## Check

- Each acceptance criterion is delivered and tested.
- Correctness: logic, wrong conditions, off-by-one, unhandled errors, races, resource leaks.
- Callers of changed code: read them; a change that breaks one is a finding.

Not style, naming or preference, unless it hides a bug. Every finding points at a line and says what goes wrong for which input.

## Severity

- critical: data loss, a security hole, or the change does not work at all.
- high: an acceptance criterion not met, or a bug a normal user hits.
- medium: a bug on an edge case.
- low: minor.

## Return

One line per finding: `<id> | <severity> | <file:line> | <what goes wrong> | <fix>`. None → `no findings`.
```

- [ ] **Step 4: Write `skills/start/security.md`**

```markdown
# Security review

Read-only: you do not edit, commit or talk to the user. You review one change for security flaws.

## Inputs

The diff, the worktree path (read any file there for context).

## Check, in the changed code and what it calls

- Injection: shell, SQL, template, path, or prompt, from any input.
- Shell quoting: unquoted expansions, `eval`, word splitting on user data.
- Path traversal and symlinks: paths built from input escaping their directory.
- Secrets: keys, tokens or passwords in code, logs, errors or commits.
- Missing authentication or authorization on a new entry point.
- Unsafe deserialization, SSRF, and trust placed in data from outside.
- Untrusted tracker or user text (issue bodies, comments, PR descriptions) reaching a shell, a file path or an agent prompt as instructions.

## Severity

As in `review.md` in this directory: critical, high, medium, low.

## Return

One line per finding: `<id> | <severity> | <file:line> | <what goes wrong> | <fix>`. None → `no findings`.
```

- [ ] **Step 5: Check and commit**

Run: `claude plugin validate . ; grep -rnE 'superpowers|code-review:' skills/start/*.md; echo "grep exit $?"`
Expected: validate passes (its one CLAUDE.md warning is expected); `grep exit 1`.

```bash
jj commit -m "feat: implement, harden, review and security briefs for start (#88)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Rewrite `skills/start/SKILL.md`

**Files:**
- Modify: `skills/start/SKILL.md` (whole file)
- Test: `scripts/selftest.sh` (one line after `t 1 "no skill disables model invocation" …`)

**Interfaces:**
- Consumes: `issue.sh state` (Task 2), config keys (Task 3), briefs (Task 4).
- Produces: plan comment whose first line is `<!-- coddy:plan -->`; state keys `phase` (think, implement, harden, review, done), `round`, `upheld`, `summary` that Task 6 reads.

- [ ] **Step 1: Write the failing test**

After `t 1 "no skill disables model invocation" grep -rq disable-model-invocation "$here/skills"` add:

```bash
t 1 "no skill names a vendor skill" grep -rqE 'superpowers|code-review:' "$here/skills"
```

Run: `bash scripts/selftest.sh | grep vendor`
Expected: `FAIL no skill names a vendor skill` (today's step 5 names `superpowers:brainstorming`).

- [ ] **Step 2: Replace `skills/start/SKILL.md` with**

````markdown
---
name: start
description: Start or continue work on a tracked issue - claim it, think it through with the user, then implement, harden and review it until it is ready to ship
when_to_use: Use whenever the user asks to start, pick up, work on, fix or implement a GitHub issue or Jira ticket (issue 42, ABC-123, an issue URL), or to continue an existing pull request or branch (resolve its conflicts, address review comments, rebase it), before touching any code for it. Pass the bare issue number or Jira key as the argument, followed by onto and another issue to stack the new branch on that issue's branch (issue 22 onto 21). For a pull request, pass the issue it closes, or the PR number when it closes none.
arguments: [issue, onto, base]
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/config.sh"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" status), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" create *), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" claim *), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" state *), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" sweep), mcp__plugin_github_github__issue_read, mcp__plugin_github_github__issue_write, mcp__plugin_github_github__pull_request_read, mcp__plugin_github_github__list_pull_requests, mcp__plugin_github_github__get_me, mcp__plugin_github_github__add_issue_comment, mcp__plugin_atlassian_atlassian__getAccessibleAtlassianResources, mcp__plugin_atlassian_atlassian__atlassianUserInfo, mcp__plugin_atlassian_atlassian__getJiraIssue, mcp__plugin_atlassian_atlassian__executeRead, mcp__plugin_atlassian_atlassian__editJiraIssue, mcp__plugin_atlassian_atlassian__transitionJiraIssue, mcp__plugin_atlassian_atlassian__addOrEditJiraIssueComment
---

# Start issue $issue

## Config
!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/config.sh"`

## Cleaned up
!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" sweep`

## Worktrees
!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" status`

`NOT_ONBOARDED` → stop and say: run `/coddy:onboard` first.
`tracker: jira` → every Atlassian MCP call takes `cloudId`: call `getAccessibleAtlassianResources` once and use the entry whose url is `jira.site`; me is `atlassianUserInfo`'s `accountId`. Those tools not loaded → stop and say the atlassian plugin needs to be authenticated.
Lines under Cleaned up → say so first, in one sentence. `cleaned` is an issue whose PR merged and whose worktree was removed, so it has no worktree even if Worktrees still lists it; `kept` is a merged one whose worktree still holds work to push or discard, or that another running session still holds.
Empty issue id, or `$onto` given without a base issue after it → stop and say: usage `/coddy:start <issue> [onto <base-issue>]`.
`$base` is set and Worktrees does not list `$base=<branch>` → stop and say: run `/coddy:start $base` first, a branch can only be stacked on a claimed issue's.
`tracker: jira` and `$issue` is not a ticket key → stop and ask which ticket the work belongs to.

## Non-negotiable

- The issue is In Progress in the tracker before any code is edited, or its PR is already open.
- One issue, one branch, one worktree. Every edit and commit for this issue happens in `.worktrees/$issue` on its own branch: never in the main checkout, never on `default_branch`, never on another issue's branch.
- No code is edited before the user approves the plan (step 7). The ticket is one input, not the whole truth.

Hooks enforce the first two: every Edit and Write outside a worktree whose issue step 4 has claimed is rejected, so is one inside a worktree another session claimed (the remedy is `/coddy:start <issue>`, which asks before taking it over), and any shell command that leaves a change in the main checkout is flagged. A rejection means a step was skipped: go back and do it, and undo what was flagged. Never route around it.

Paths below are relative to `root`. State is `bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" state $issue`: with no more arguments it prints `phase`, `round`, `upheld` and `summary` lines; `key=value` sets one, `upheld+=<title>` adds one. The briefs `implement.md`, `harden.md`, `review.md` and `security.md` sit next to this file. Asking the user means one question call per round; no such tool (headless) → print the questions and stop: `/coddy:start $issue` again resumes.

## Steps

1. Fetch the issue with its comments.
   - github: `issue_read` `get`, then `get_comments`, with `owner` and `repo` from `repo`. `get` also returns the assignees, labels and `closed_by_pull_requests` that steps 3 and 4 read.
   - jira: `getJiraIssue`, then `executeRead` `listJiraIssueComments`.
2. Restate in at most 10 lines: goal, acceptance criteria, out of scope.
3. Create the worktree: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" create $issue <branch>`, or with `$base` set `bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" create $issue <branch> $base`. It continues `<branch>` when that branch exists, locally or on the remote, and starts it from `default_branch` otherwise, or from issue `$base`'s branch, which it records so that `ship` opens the PR against it. An existing worktree for `$issue` is reused when it is on `<branch>`. `<branch>` is the first of these that applies:
   - The user named a branch → that branch. The user named a PR → `pull_request_read` `get` (`owner` and `repo` from `repo`, or from the PR's URL under jira): its branch is `head.ref`. Its `head.repo.full_name` is another repository → stop and say a PR from a fork cannot be continued.
   - The issue has an open PR → its `head.ref`.
     - github: a `closed_by_pull_requests` reference from step 1 whose `pull_request_read` `get` says `state` is open.
     - jira: the PR linked in the ticket's comments, when `pull_request_read` `get` on it says it is open.
   - Worktrees lists `$issue=<branch>` → that branch.
   - None of these → the `branch` pattern: `type` is `bug`, `feat` or `chore` from the issue's labels or type; `slug` is at most four words from the title.

   `create` fails → show the output and stop. Never pass another issue id or branch to get past it. `jj_repo: no` while `worktree` is `jj`, or absent in a config below version 2, → first ask, then `jj git init --colocate; echo '.jj/' >> .git/info/exclude`.
4. Move it to In Progress. A failure here → stop and report; do not continue. An issue whose branch has an open PR is past In Progress: its labels and status stay as they are; github still assigns you, since the PR check reads the assignee.
   - github: I am `get_me`'s `login`. Step 1 shows the issue assigned to someone else and not to me, or labelled `in progress` with nobody assigned → stop and ask the user whether to take it over; only on a yes continue, with me as the only assignee, and say who lost it. Then `issue_write` `update`: `assignees` is the current list plus me (on a takeover, me alone); no open PR for `<branch>` (step 3, else `list_pull_requests` with `state: open` and `head: <owner>:<branch>`) → `labels` is the current list plus `in progress` as well; an open PR → leave `labels` out. No open PR → then `issue_read` `get_labels`: `in progress` missing → stop and say the label must exist in the repository first (create it under the repository's labels, then run `/coddy:start $issue` again). Then `bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" claim $issue` records it.
   - jira: read the ticket (`getJiraIssue`): assigned to someone else, or In Progress and not to me → stop and say who has it; take it over only when the user says so: assign to me (`editJiraIssue`), then the steps below with `claim $issue --take` in place of `claim $issue`. No open PR → assign to me (`editJiraIssue`, `fields: {assignee: {accountId: <me>}}`), then `executeRead` `listJiraIssueTransitions` and `transitionJiraIssue` with the id of the one that leads to the In Progress status (already there → no transition; none leads there → stop and list the available ones), then `getJiraIssue` again: status not In Progress or assignee not me → stop and report, no claim. Then, open PR or not, `bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" claim $issue` to record it.

   Either tracker: `claim` is refused because another session holds the claim and is running, or a claim is in flight → stop and ask the user whether to take it over; only on a yes run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" claim $issue --take`. `claim` reports a takeover → say so in one line, naming the session it was taken from, and continue.

   Resume: the latest comment from step 1 whose first line is `<!-- coddy:plan -->` is the agreed plan. None → step 5. One, and the worktree has no diff against its base (step 9) → step 8 with that plan. One and a diff → step 10 with that plan, keeping `upheld`. Say in one line where it resumes.
5. Gather context beyond the ticket, read-only, and with sub-agents available hand this to a read-only one that returns at most 40 lines: issues and PRs the issue or its comments reference (github `issue_read` `get`, `pull_request_read` `get`; jira `getJiraIssue`), the last 15 commits on the paths involved (`git -C <root> log --oneline -15 origin/<default_branch> -- <paths>`), and the code itself in `.worktrees/$issue`.
6. Think it through with the user. `state $issue phase=think`.
   - A skill whose description says it brainstorms or plans work is available (not one of coddy's) → run it for this step. It writes nothing outside `.worktrees/$issue`; when it moves on to writing a plan document or implementing, stop it there and continue at step 7 with what it agreed.
   - Otherwise ask, in rounds, until nothing is open: gaps in the ticket, contradictions between the ticket and the code or context, the assumptions you would otherwise make silently, two or three approaches with a recommendation, and acceptance criteria sharpened into observable checks. A one-line change still gets one round that confirms your reading of the ticket.
7. Plan and approval. Rate the tier, the highest row that matches:
   - high: cross-cutting; a new interface, schema or config key; security-, lock- or concurrency-sensitive code; a root cause still unclear.
   - medium: several files in one area; tests to write; open questions settled in step 6.
   - low: one file or one obvious change, a known pattern, acceptance criteria already testable.

   The model is `tiers.<agent>.<tier>`, `<agent>` being this agent's lower-case name (`claude`, `codex`, `gemini`, `cursor`, `copilot`). No `tiers.<agent>` → ask once for its low, medium and high models and say `/coddy:config` saves them; never guess a model name. Show the plan: the approach, the acceptance criteria as a checklist, and `Tier: <tier> (<model>): <one-line reason>`. No yes → back to step 6. On a yes, post it as an issue comment whose first line is `<!-- coddy:plan -->` (github `add_issue_comment`; jira `addOrEditJiraIssueComment`), then `state $issue phase=implement round=0`.
8. Implement. Run `implement.md` as a sub-agent on the tier's model with: the absolute worktree path, the plan, `verify`, the `commit` pattern and the `worktree` tool. No sub-agents, or no choice of model → follow the brief yourself and say so once. Its open questions → ask the user, then run it again with the answers. Keep its out-of-scope ideas.
9. Harden. `state $issue phase=harden`. Twice, each time a fresh sub-agent on the same model with `harden.md`, the diff, the plan, `verify`, `commit` and `worktree`. The diff is against the issue's base (`bases` entry, else `default_branch`): git `git -C .worktrees/$issue diff origin/<default_branch>...HEAD` (a `bases` entry: `<base>...HEAD`); jj `jj -R .worktrees/$issue diff -r '<default_branch>@origin..@'` (a `bases` entry: `'"<base>"..@'`). Keep its out-of-scope ideas.
10. Review loop. `state $issue phase=review`. Each round, `round` one higher:
    1. Run `verify` in `.worktrees/$issue`. Non-zero → a blocking finding with the last 20 lines of output.
    2. Code review: a skill whose description says it reviews code changes for bugs is available (not one of coddy's) → run it on the diff. None, or it would stop to ask with no question tool → a sub-agent on `tiers.<agent>.high` with `review.md`, the diff and the acceptance criteria.
    3. Security review: a skill whose description says it reviews for security is available (not one of coddy's) → run it on the diff. None, or it would stop to ask with no question tool → a sub-agent on `tiers.<agent>.high` with `security.md` and the diff.
    4. Put every finding on critical, high, medium or low. Leave out those whose title is an `upheld` line.
    5. Blocking: a failing verify, and every finding at or above `review_block` (absent: `high`). None → step 11. A finding you judge wrong → ask the user; upheld → `state $issue "upheld+=<title>"`. The rest → `implement.md` in fix mode with those findings, then `state $issue round=<round>`.
    6. `round` reached `review_rounds` (absent: `3`) with blocking findings left → list them and ask: another round, fix by hand and run `/coddy:start $issue` again, or go on to step 11 as is.
11. Done. List the out-of-scope ideas from steps 8 to 10 and ask, for each: fold in, triage, or drop. Folded in → add them to the acceptance criteria, post the updated plan as a new `<!-- coddy:plan -->` comment, run `implement.md` in fix mode with them, then one more round of step 10. Triage → list them and say: run `/coddy:triage`. Then `state $issue phase=done "summary=<rounds> rounds; fixed: <titles>; left below <review_block>: <titles>; upheld: <titles>"` and say: run `/coddy:ship`.
````

- [ ] **Step 3: Run the checks**

Run: `bash scripts/selftest.sh; echo "exit $?"; claude plugin validate .`
Expected: `ok   no skill names a vendor skill`, no `FAIL`, `exit 0`; validate passes.

- [ ] **Step 4: Commit**

```bash
jj commit -m "feat: start thinks with the user, tiers by difficulty, implements, hardens and loops review (#88)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: `ship` puts the review in the PR

**Files:**
- Modify: `skills/ship/SKILL.md` (frontmatter `allowed-tools`; step 1; step 3)

**Interfaces:**
- Consumes: `issue.sh state <issue>` lines `phase=…`, `summary=…` (Tasks 2, 5).

- [ ] **Step 1: Mirror `state` in allowed-tools**

In the frontmatter, after `Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" push *),` add ` Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" state *),`.

- [ ] **Step 2: Read the state after verify**

Replace step 1 with:

```markdown
1. Run `verify` inside `.worktrees/<issue>`. Non-zero exit → show the failing output and stop. Fixing belongs to the issue branch, not to this skill. Then `bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" state <issue>`: `phase=done` → its `summary` goes into the PR body (step 3). Any other phase, or none → say start's review loop has not passed and ask whether to ship anyway; no, or no question tool → stop and say: run `/coddy:start <issue>`. Yes → the PR body says `Review loop not completed.`
```

- [ ] **Step 3: Add the Review section to the body**

In step 3, change `a body of what changed, why, and` to `a body of what changed, why, a **Review** section (the `summary` from step 1, or \`Review loop not completed.\`), and`.

- [ ] **Step 4: Check and commit**

Run: `claude plugin validate . && bash scripts/selftest.sh | grep -c '^FAIL'`
Expected: validate passes; `0`.

```bash
jj commit -m "feat: ship carries start's review summary into the PR body (#88)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Docs — ROADMAP, CLAUDE.md, README

**Files:**
- Modify: `ROADMAP.md:3`, `ROADMAP.md` "Parallel-orchestrated" bullet, M1 section
- Modify: `CLAUDE.md` ("What this is", `issue.sh` paragraph, "Skill flow" line, Known ceilings)
- Modify: `README.md:68-76` (lifecycle line and `start` table row)

- [ ] **Step 1: ROADMAP**

Line 3 becomes:

```markdown
coddy's purpose stays the same: **every change an agent makes is tied to a claimed issue, lives in its own worktree, and lands through a pull request, enforced by tooling rather than by prompts.** Within one issue, coddy also runs its own stage from the agreed plan to a reviewed diff: an implementer on a model matched to the issue's difficulty, two hardening passes, and a code and security review loop.
```

The Parallel-orchestrated bullet becomes:

```markdown
- **Parallel-orchestrated**: launching and coordinating agents across issues. Out of scope; that stays with other tools, with coddy guarding underneath. Sub-agents inside one issue's stage are coddy's own (#88).
```

In M1, after `- #13 Add a warn mode for the edit guard` add `- #88 Redesign start: think with the user, tier by difficulty, implement, harden, review and security loop`, and to the M1 go signals line append `; cold users ship a PR that passed start's review loop`.

- [ ] **Step 2: CLAUDE.md**

- "What this is": `the deliverable is six prompt files (\`skills/*/SKILL.md\`)` → `the deliverable is six prompt files (\`skills/*/SKILL.md\`), the four sub-agent briefs next to \`start\`'s (\`skills/start/{implement,harden,review,security}.md\`)`.
- `issue.sh` paragraph: after `` `push` commits and pushes, `` add `` `state` records `start`'s phase, review round, upheld disputes and summary in the lock directory for the owner alone (anyone reads it, `ship` too), ``.
- Replace the "Skill flow" line with: `Skill flow is \`onboard\` → \`next\` → \`start <issue>\` → \`ship\`, with \`triage\` feeding new issues back into the tracker. \`start\` runs from the claim to a reviewed diff in one command: context, thinking with the user, one plan approval with the tier inside it, then implementer, two hardening passes and the code and security review loop, as sub-agents on the briefs next to it (the main agent follows them itself without sub-agents); re-running it resumes from the \`<!-- coddy:plan -->\` comment and \`issue.sh state\`. Each skill ends by naming the next command rather than chaining into it, and each states what it must not do (\`ship\` never merges or fixes failures; \`onboard\` writes nothing but the config and, when accepted, the PR check workflow).`
- Known ceilings: append `; start's sub-agents run in the parent's process and session, so the lock and the guard cannot tell them apart from the parent: a sub-agent's edit counts as the session's own`.
- "Config schema has three copies": after `` `guard` is the one key `onboard` never asks for `` add ``, with `review_block` and `review_rounds`; `tiers` it asks for the running agent only``.

- [ ] **Step 3: README**

Line 68 becomes `The lifecycle is \`next → start (think, implement, harden, review) → ship → merge\`.` The `/coddy:start` table row's description becomes:

```markdown
Fetches the issue, claims it, moves it to In Progress and gives it its own worktree in `.worktrees/<issue>`. Then reads beyond the ticket, thinks the work through with you, and asks for one approval of the plan with its difficulty tier. On a yes it implements on that tier's model, hardens the result twice, and loops code and security review until nothing at `review_block` or above is left (at most `review_rounds` rounds). Run it again to resume. Name a PR or branch, or let the issue's open PR be found: that branch instead. `onto` starts from another issue's branch instead of the default branch
```

- [ ] **Step 4: Check and commit**

Run: `bash scripts/selftest.sh | grep -c '^FAIL'; claude plugin validate .`
Expected: `0`; validate passes.

```bash
jj commit -m "chore: ROADMAP, CLAUDE.md and README for the start redesign (#88)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Headless acceptance checks

Needs a GitHub repository the GitHub MCP plugin can read and write, where test issues may be created and closed. **Ask the user which one before this task** (`mnsami/coddy` itself would get test issues).

**Files:** none in the repo; a scratch clone of that repository.

- [ ] **Step 1: Prepare** — clone it to `$S/sandbox`, write `.claude/coddy.yml` (`tracker: github`, its `repo`, `worktree: git`, `default_branch: main`, `verify: "true"`, `tiers` with `claude: {low: haiku, medium: sonnet, high: opus}`), create the `in progress` label there, and create issue A "Make it better" with an empty body.

- [ ] **Step 2: A vague issue stops with questions**

```bash
cd "$S/sandbox" && claude --plugin-dir "$P" --allowedTools "Skill(coddy:start) Bash mcp__plugin_github_github__issue_read mcp__plugin_github_github__issue_write mcp__plugin_github_github__get_me mcp__plugin_github_github__add_issue_comment mcp__plugin_github_github__list_pull_requests" -p "/coddy:start <A>"
```

Expected: output lists questions; `git -C .worktrees/<A> status --porcelain` is empty; no `<!-- coddy:plan -->` comment on A.

- [ ] **Step 3: Missing tier asks, never guesses** — remove `tiers` from the config, create issue B with clear acceptance criteria ("Add a `hello.sh` that prints hello; acceptance: `bash hello.sh` prints `hello`"), post a `<!-- coddy:plan -->` comment yourself, run step 2's command with `<B>`. Expected: output asks for the models; no `hello.sh` is written. Put `tiers` back.

- [ ] **Step 4: A seeded finding causes a fix round, and the cap hands off** — in issue B's worktree, have the plan comment demand `hello.sh` also handle an empty `$1` safely; set `review_rounds: 1`; run interactively `claude --plugin-dir "$P"` then `/coddy:start <B>`. Expected: one review round runs, `issue.sh state <B>` shows `round=1`, and either the loop exits with no blocking finding or it lists what is left and asks the three-way question.

- [ ] **Step 5: ship carries the summary** — after step 4 reaches `phase=done`, run `/coddy:ship`. Expected: the PR body has a **Review** section with the summary. Close the PR and both issues afterwards.

- [ ] **Step 6: Report** — post the results of steps 2–5 as one comment on #88 (github `add_issue_comment`), each with pass or fail and the evidence line.
