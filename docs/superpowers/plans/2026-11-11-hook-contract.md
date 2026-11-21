# Host-neutral hook contract Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `bin/hermy`'s hook verbs read a neutral input and print a neutral verdict; `scripts/issue.sh` maps Claude Code's payload and envelope to and from them, so Claude Code behaves exactly as today.

**Architecture:** The core calls two functions at its only payload boundaries: `hermy_in` (stdin → neutral JSON) where it reads the payload, and `hermy_out` (neutral line → host line) where it prints. With neither defined (a direct call, `selftest-core.sh`) it reads and prints neutral JSON as is. The Claude shim defines both before sourcing the core, so they run after the core's own `unpath`, under its `jqh`.

**Tech Stack:** bash 3.2+, jq (optional on the snap/trip path), sed.

**Spec:** `docs/superpowers/specs/2026-11-11-hook-contract-design.md`

## Global Constraints

- bash 3.2 (`/bin/bash` on macOS) parses and runs every script; no new dependency.
- `hooks/hooks.json`, every `allowed-tools` line and every verb stay as they are.
- Every Claude payload test in `scripts/selftest.sh` passes without edits to its payloads or its assertions on output.
- Neutral input keys: `paths` (array of strings), `command`, `cwd`, `call`, `session`. Neutral verdicts: block = exit 2 + stderr; allow = exit 0, no output; `{"hermy":"ask","text":…}`; `{"hermy":"note","text":…}`, one line, exit 0.
- After this change `bin/hermy` holds none of `tool_input`, `tool_use_id`, `session_id`, `hookSpecificOutput`, `permissionDecision`, `additionalContext`, `hookEventName`, comments included.
- `call` stays readable by `sed` without jq, so `snap` without jq and `trip` with it name the same snapshot.
- A shim mapping failure refuses (`guard`, `snap`) as a core failure does today, never passes.
- Commits: `type: summary`, author `git -c user.name='Mina Nabil Sami' -c user.email='mina.nsami@gmail.com'`, trailer `Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>`.
- Run after every task: `bash scripts/selftest.sh && bash scripts/selftest-core.sh`, and once before the PR both under `/bin/bash`.

## Review Focus

1. A payload jq cannot read (a lone surrogate `\ud800` in the command or path): `guard` and `snap` still exit 2 through the shim. Test in Task 1.
2. jq missing in the hook's `PATH`: `snap` lets a worktree/push command through saying jq is missing, and `trip` with jq finds `snap`'s snapshot. Test in Task 1 (shim level).
3. A note or ask text holding `"`, `\`, a newline or a control character comes out of the shim byte-identical to today's envelope. Test in Task 2.
4. An edit naming several paths where one is refused and another asks: refused; one asks and the rest pass: ask; an empty `paths`: refused. Test in Task 3.
5. Two sessions with no call id interleaving `snap`/`trip`: neither reports the other's snapshot lost. Test in Task 4.

---

### Task 1: Neutral input

**Files:**
- Modify: `bin/hermy` — guard's payload read (`:626-635`), snap/trip's read (`:1575-1581`, `:1745`, `:1804`), the comments naming Claude keys (`:626`, `:808`, `:1576-1579`)
- Modify: `scripts/issue.sh` — define `hermy_in` before sourcing the core
- Test: `scripts/selftest-core.sh` (payload helpers `:29`, `:32`, and every inline `tool_input`/`tool_use_id`/`session_id` payload, ~30 lines), `scripts/selftest.sh`

**Interfaces:**
- Produces: core helper `readin` — sets `in` to the neutral JSON: `hermy_in` when `declare -F hermy_in` finds it, else `cat`.
- Produces: shim function `hermy_in` (no args, payload on stdin, one neutral JSON line on stdout).
- Neutral reads in the core: guard `me=.session // ""`, `f=.paths[0] // empty` (Task 3 generalises), `cwd=.cwd // empty`; snap/trip `id` by `sed` on `"call"`, `ss` by `sed` on `"session"`, `cmd=.command // empty`, `cwd=.cwd // empty`.

- [x] **Step 1: Convert `selftest-core.sh` payloads to neutral input**

Every payload the core reads directly becomes neutral, e.g. `guard()` at `:29`:
`printf '{"session":"%s","paths":["%s"]}' "$s" "$1"`, `wire()` at `:32`: `printf '{"call":"%s"}' "$2"`, `{"tool_use_id":"w"}` → `{"call":"w"}`, `cwd`/`tool_input.command` → `cwd`/`command`. Assertions on output stay for Task 2. Line `:678`'s test name says "a call id that is not a plain word".

- [x] **Step 2: Run `bash scripts/selftest-core.sh`; expect failures on the converted guard/snap tests (core still reads Claude keys).**

- [x] **Step 3: Add the shim-level tests to `selftest.sh`** (Review Focus 1, 2), where its existing `payload`/`nojq` helpers live (`:1298`, `:1360`):
  - `t 2 "shim: guard refuses a path jq cannot read"` — Claude payload with `"file_path":"\ud800"` through `shim guard`.
  - `t 2 "shim: snap refuses a command jq cannot read"` — `"command":"git push \ud800"` through `shim snap`.
  - `t 0 "shim: snap without jq and trip with it name the same snapshot"` — `PATH="$tmp/nojq"` `shim snap` with `tool_use_id` `w`, then `shim trip` with jq: exit 0, no "lost".

- [x] **Step 4: Implement `readin` in `bin/hermy` and the neutral reads above; implement `hermy_in` in `scripts/issue.sh`.**

`hermy_in`: read stdin once into `r`; `id` = `sed` extraction of `tool_use_id` from `r` exactly as the core does today (`:1581`). The core calls `hermy_in` after its own definitions and `unpath`, so `hermy_in` uses the core's `jqh`. With a working `jqh`:
`jqh -c --arg c "$id" '{paths: [.tool_input.file_path // .tool_input.notebook_path // empty], command: (.tool_input.command // ""), cwd: (.cwd // ""), call: $c, session: (.session_id // "")}'`.
When jq is missing or fails: `printf '{"raw":%s,"call":"%s","session":"%s"}\n' "$r" "$id" "$ss"` with `ss` the `sed` extraction of `session_id`. The raw payload inside keeps the object unreadable to the core's jq exactly when it was before (so refusals hold) and keeps the core's `case "$in"` prefilter (`:1794`) matching the command's words.

- [x] **Step 5: Run both self-tests; expect PASS.**

- [ ] **Step 6: Review** — run `agents/review.md` and `agents/security.md` as generic sub-agents (inputs below), fix what they uphold, rerun the self-tests.

- [x] **Step 7: Commit** `feat: hook verbs read a host-neutral input (#278)`

### Task 2: Neutral verdict

**Files:**
- Modify: `bin/hermy` — `note()` `:521`, guard's `ask()` `:734`, snap's `ctx()` `:1684`
- Modify: `scripts/issue.sh` — define `hermy_out`
- Test: `scripts/selftest-core.sh` (assertions at `:31`, `:452`, `:472`, `:521`, `:585`, `:1256` and any other `.hookSpecificOutput` read), `scripts/selftest.sh`

**Interfaces:**
- Produces: core helper `out <line>` — `hermy_out "$1"` when defined, else `printf '%s\n' "$1"`.
- `note` → `out "$(jqh -cn --arg m … '{hermy: "note", text: $m}')"`; `ask` → `{hermy: "ask", text: $m}`; `ctx` → `out "$(printf '{"hermy":"note","text":"%s"}' "$*")"`.
- Produces: shim `hermy_out <line>`: a line starting `{"hermy":"note","text":` → `{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":<text>}}`; `{"hermy":"ask","text":` → `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":<text>}}`; anything else printed as is. Pure parameter expansion, no jq, no subprocess: `<text>` is the already-escaped JSON string between the fixed prefix and the final `}`.

- [x] **Step 1: Change `selftest-core.sh` output assertions to the neutral shape**, e.g. `:31`: `jq -e '.hermy == "ask" and (.text | contains(".hermy.yml"))'`; `:452`: `jq -e '.hermy == "note" and (.text | contains("so this command runs unchecked"))'`.

- [x] **Step 2: Add to `selftest.sh`** (Review Focus 3): `t 0 "shim: a note with a quote, backslash and newline maps byte-identically"` — under `guard: warn`, an edit outside the worktree whose path holds `"`, `\` and a newline; assert `jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and (.hookSpecificOutput.additionalContext | contains("<that path>"))'` and that the output is one line. And the gate in `selftest-core.sh` next to `:48`:
`t 1 "the core names no host payload key or envelope" grep -qE 'tool_input|tool_use_id|session_id|hookSpecificOutput|permissionDecision|additionalContext|hookEventName' "$here/bin/hermy"`.

- [x] **Step 3: Run both self-tests; expect the new assertions to FAIL.**

- [x] **Step 4: Implement `out`, the three emitters and `hermy_out`; reword remaining comments so the gate passes.**

- [x] **Step 5: Run both self-tests; expect PASS.**

- [ ] **Step 6: Review** (as Task 1).

- [x] **Step 7: Commit** `feat: hook verbs print a host-neutral verdict (#278)`

### Task 3: An edit names several paths

**Files:**
- Modify: `bin/hermy` — guard, right after the payload read (`:630-636`)
- Test: `scripts/selftest-core.sh`

**Interfaces:**
- Consumes: `readin`, `out` (Tasks 1–2).
- With `.paths | length` > 1, guard runs itself once per path: `jqh -c --argjson i "$i" '.paths = [.paths[$i]]' <<<"$in" | "$BASH" -p "$src" guard` (`$src` the core's absolute path, computed as `:2010` does, moved above the guard block), each child's stdout and stderr captured. The child has no `hermy_in`/`hermy_out` (not exported), so it reads and prints neutral. Result, in order: the first child exiting 2 → its stderr, exit 2; any other non-zero → exit 1 (the shim's trap makes it 2); else the first `ask` line through `out`; else every `note` text joined by a space into one `note`; else exit 0. `paths` empty → today's "could not read a path" refusal.

- [x] **Step 1: Write the tests** (Review Focus 4; the issue's patch acceptance at contract level):
  - `t 2 "guard: two paths, one outside any worktree, is refused"` — `{"session":"sess-a","paths":["$repo/.worktrees/1/a.txt","$repo/README.md"]}`.
  - `t 0 "guard: two paths, one the config, asks"` — `[".worktrees/1/a.txt", "$repo/.hermy.yml"]` (claimed by sess-a); assert `.hermy == "ask"`.
  - `t 2 "guard: a refused path beats an ask"` — `["$repo/.hermy.yml","$repo/README.md"]`.
  - `t 2 "guard: an empty paths list is refused"` — `{"session":"sess-a","paths":[]}`.
  - `t 0 "guard: two paths in the claimed worktree pass"`.

- [x] **Step 2: Run `bash scripts/selftest-core.sh`; expect the first three to FAIL (only `paths[0]` is read).**

- [x] **Step 3: Implement the per-path run above.**

- [x] **Step 4: Run both self-tests; expect PASS, and the multi-path tests under `/bin/bash`.**

- [ ] **Step 5: Review** (as Task 1).

- [x] **Step 6: Commit** `feat: the edit guard holds every path an edit names (#278)`

### Task 4: Call id fallback per session

**Files:**
- Modify: `bin/hermy` `:1705` (and read `ss` before it, from `:1745`)
- Test: `scripts/selftest-core.sh` near `:678`

**Interfaces:**
- A plain-word `id` becomes `call-<id>`; one that is empty or not a plain word becomes `session-<w>`, else `pid-<w>`, `w` the first of `session`, `HERMY_PID` that is a non-empty `[A-Za-z0-9_-]` word cut to 128 characters; with neither, `shared`. Each kind has its own prefix, so no call id names a session's snapshot.

- [x] **Step 1: Write the test** (Review Focus 5): `t 0 "snapshot: two sessions without a call id keep their own"` — onboarded repo; `{"session":"a"}` snap, `{"session":"b"}` snap, `{"session":"b"}` trip, `{"session":"a"}` trip: the last exits 0 and stderr has no "lost". Update `:678`'s check to `${snapfile%-w}-shared` only when the payload names no session (keep it so).

- [x] **Step 2: Run; expect FAIL (the second snap overwrote `shared`, so a's trip finds b's removed or reports it).**

- [x] **Step 3: Implement.**

- [x] **Step 4: Run both self-tests; expect PASS.**

- [ ] **Step 5: Review** (as Task 1).

- [x] **Step 6: Commit** `fix: snapshots without a call id are kept per session (#278)`

### Task 5: Docs and a live check

Notes from the build:
- #261 removed snap's reader of the command text, so the core reads `command` nowhere today; the key stays in the contract for the next reader.
- Added on the way, each with its tests in `selftest-core.sh` (the shim one in `selftest.sh`): the guard refuses an edit naming more than 64 paths, before any child runs (`feat: the edit guard caps the paths one edit names`), and one not checked within 8 s, before the next child; `HERMY_ASK=0`, for a host that cannot ask, turns the guard's ask into a block that says so, and `issue.sh` unsets an inherited one (`feat: an ask blocks where the host cannot ask`); self-test-only Codex- and Copilot-shaped shims hand one `apply_patch` string's files to the guard (`test: apply_patch payloads through host-shaped shims`).
- Task 4's fallback is `session-<session>`, else `pid-<HERMY_PID>`, else `shared`, a plain-word call id being `call-<id>`, one helper (`shared`) naming the file for both `snap` and `trip`.

**Files:**
- Modify: `docs/specs/2026-10-15-cli-core-design.md` — a per-host delta table: rows Claude Code, Copilot CLI (from the spike's `results/matrix.md`: tool names, `path` vs `file_path`, `apply_patch` as `Edit` with a string `tool_input`, `session_id` in payload / none in env, no `PostToolUseFailure` for shell, ask shown without its reason, timeout fails open, hooks inside its sandbox), Codex (paper, from #31); columns: payload keys, session id, call id, ask, failure event, hook registration.
- Modify: `README.md` (~`:78`), `ROADMAP.md:59` (say hooks run on Claude Code only until a host's shim lands), `ROADMAP.md:62` (Cursor: its pre-edit hook blocking is unconfirmed, not absent; reword to match #32).
- Modify: `CLAUDE.md` core/adapter paragraph and `.github/copilot-instructions.md` architecture bullet: the hook verbs read `paths`, `command`, `cwd`, `call`, `session` and print `{"hermy":"ask"|"note","text"}`; a shim defines `hermy_in`/`hermy_out`.

- [x] **Step 1: Write the docs.**
- [x] **Step 2: `claude plugin validate .`; expect the one CLAUDE.md warning only.**
- [x] **Step 3: Headless Claude Code check** in an onboarded scratch repo with a claimed issue: `claude --plugin-dir ~/dev/private/hermy --permission-mode acceptEdits -p "write hi to README.md"` is refused naming `/hermy:start`; `-p "write guard: warn to .hermy.yml"` is asked (denied headless); under `guard: warn` the run quotes the hook's warning back.
- [x] **Step 4: Both self-tests under `/bin/bash`.**
- [ ] **Step 5: Final whole-branch review** with both briefs, then commit `docs: describe the host-neutral hook contract (#278)` and open the PR closing #278.

## Review inputs (every Review step)

Run each of `agents/review.md` and `agents/security.md` as a generic sub-agent whose prompt names: the brief's path; the policy at `skills/start/references/policy.md`; the worktree `~/dev/private/hermy`; the diff `git diff <task base>..HEAD`; the acceptance criteria = the spec's Goals and Anti-goals plus this task's tests. Fix what is upheld; record a dispute in the task's commit message.
