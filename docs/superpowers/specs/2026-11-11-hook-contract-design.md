# Host-neutral hook contract (#278)

Status: draft, 2026-11-11. Decision on #30: own contract (below).

## Intent

`bin/hermy`'s hook verbs (`guard`, `snap`, `trip`) read Claude Code's
PreToolUse/PostToolUse JSON and print Claude Code's `hookSpecificOutput`
envelope. So the core is agent-agnostic everywhere but at the hooks, and the
Copilot adapter (#33), the Codex adapter (#31) and any later one would each
have to bend the core. This change puts the host format in the shim alone:
the core reads one neutral input and prints one neutral verdict; each host's
shim maps its payload in and the verdict out.

Why now: the Copilot spike (#33, comment 6794332979) showed the host deltas
are small and known, and every guardrail is off under Copilot until a shim
can feed the core.

## Decision on #30

hermy defines its own contract and adopts no third-party hook layer:

- The deltas are small: Copilot sends Claude's tool names (`Write`, `Edit`,
  `Bash`, `Agent`, `Read`) and a per-call `tool_use_id`; it differs in the
  `tool_input` keys (`path` for `file_path`), an `apply_patch` arriving as an
  `Edit` whose `tool_input` is the patch string, no session or pid variable,
  no `PostToolUseFailure` for a shell command, and the hook's working
  directory (the plugin dir).
- The guard is fail-closed security code hardened against PATH planting, env
  injection, FIFOs and timeouts. A layer in front of it would decide first,
  outside that hardening, and fail-open there turns every guardrail off.
- hermy has no dependencies and a bash 3.2 floor; the candidate layers bring
  a runtime or an install step.

Cost if wrong: the shims are redone on top of a layer; the neutral input and
verdict stay.

## Goals

- `bin/hermy` holds no host's payload key or envelope: no `tool_input`,
  `tool_use_id`, `session_id`, `hookSpecificOutput`, `permissionDecision`,
  `additionalContext`, `hookEventName`. `selftest-core.sh` fails on any.
- `scripts/issue.sh` (Claude Code's shim) maps Claude's payload to the neutral
  input and the neutral verdict back, so Claude Code behaves exactly as today:
  every existing payload test in both self-tests passes unchanged.
- An edit names a list of paths, every one guarded, so a shim can hand over
  every file of one `apply_patch` string.
- Two sessions with no call id do not share a snapshot.

## Non-goals

- The Copilot shim and its hook registration (#33). Copilot drops the exec
  form's `args`, and the single-string form runs through a shell that a
  settings `env` reaches (`SHELLOPTS=noexec`), which the exec form exists to
  avoid. Choosing Copilot's registration is #33's security decision, not
  this change's.
- Parsing `apply_patch` (each host's shim does, in #33 and #31). This change
  only makes the core take several paths.
- Codex and Cursor shims.
- A `failed` flag: `trip` does not read whether the command failed, and
  Claude Code fires exactly one of `PostToolUse` and `PostToolUseFailure`
  per command, Copilot `PostToolUse` alone, so `trip` already runs once.

## Anti-goals

- Any weakening of a guardrail on Claude Code: a payload the guard refuses
  today is refused after, by the same message's meaning, in both modes.
- A new failure mode open: the shim's mapping failing must refuse (`guard`,
  `snap`) as a core failure does today, never pass.
- jq becoming a requirement of `snap`: `onboard` installs jq inside a shell
  command, so `snap` runs without it and `trip` with it, and both must name
  the snapshot the same way.

## The contract

### Input: the shim hands the core one JSON object on stdin

| key | type | meaning |
|---|---|---|
| `paths` | array of strings | edit: every path the call writes, as the host gives it (relative or absolute) |
| `command` | string | command: the shell command's text |
| `cwd` | string | the session's working directory (the host's, not the hook's own) |
| `call` | string | the host's per-call id, pairing `snap` with `trip` |
| `session` | string | the host's session id |

Absent and empty mean the same. The event is the verb (`guard`, `snap`,
`trip`), as now. `HERMY_SESSION`/`HERMY_PID` remain the Bash-tool side's
inputs (`claim`, `push`, `status`); `session` is the hook side's.

Reading stays as today: `call` and `session` by `sed` (plain words, so no jq
is needed and both sides name the snapshot alike), the rest by jq. A shim
without a working jq still hands over `call` and `session`, as plain words it
read with `sed`, so `snap` behaves as it does today without jq. With jq it
hands over the top-level `session_id` while that is a plain word, which `sed`
reads alike, so a `session_id` key inside `tool_input` never names the
guard's owner; any other it hands over as `sed` read it, in its JSON
spelling with control characters dropped, never jq's decoding of it, so a
session holding a JSON escape names one snapshot on both sides.

An edit naming several paths runs the guard once per path. It is refused
with more than 64 paths, before any runs, and once 8 s have passed since the
hook started, before the next path, in both modes; each path's run gets the
seconds left less one (`HERMY_GUARD_BUDGET`, which lowers the 8 s and which
the Claude shim unsets when inherited), since `SECONDS` counts whole
wall-clock seconds and each side may read up to one short, so the whole ends
about 9 s in, inside the guard's 10 s timeout. A path's run takes a tenth to a fifth of a second, so a patch
of more than some forty paths is refused under the 64 cap and must be split.

### Verdict: the core prints at most one neutral line on stdout

- block: exit 2, the message on stderr (unchanged; both hosts honour it).
- allow: exit 0, nothing printed.
- ask: exit 0, `{"hermy":"ask","text":"…"}`.
- note: exit 0, `{"hermy":"note","text":"…"}`.

`text` is a JSON string the core escapes as today. The shim maps ask to the
host's ask envelope and note to the host's context envelope, by jq when it
runs and, since the core prints one fixed shape, by plain text substitution
without it (`snap`'s note path runs without jq today).

Copilot headless turns an ask into a deny by itself (spike H7), and
interactive Copilot shows the ask without its text. A shim whose host cannot
ask sets `HERMY_ASK=0`: the guard's ask then blocks, exit 2, its message
ending `This host cannot ask, so hermy refuses it.`, for an edit naming
several paths too, whether or not the shim exports it. The Claude shim unsets an
inherited `HERMY_ASK`, since Claude Code can ask.

### Session under Copilot

Copilot's hook payload carries `session_id` (spike H3), so its shim fills
`session` from it. The lock's owner line is written on the Bash-tool side
from `HERMY_SESSION`; whether Copilot's shell variable
`COPILOT_AGENT_SESSION_ID` equals the payload's `session_id` is unverified
(#414). This change does not depend on it: the contract only names where the
session goes. #33 verifies the match before its shim sets `HERMY_SESSION`,
and until then a lock is held to its owner on Claude Code alone, as the
no-session rows of the Lock states table already describe.

### Call id fallback

A host with no call id (none so far; Claude and Copilot both send one) gets
`session-<session>`, else `pid-<HERMY_PID>`, reduced to `[A-Za-z0-9_-]`,
instead of the root-wide `shared` name; with neither, `shared` as today. A
call id names `call-<id>`, so no call id can name a session's snapshot.

## Approaches considered

1. **Neutral JSON on stdin, shim maps with jq (chosen).** The core keeps its
   jq/sed reading, with renamed keys; the jq-less path keeps working because
   `call` and `session` stay `sed`-readable plain words.
2. **Environment variables** (`HERMY_PATHS`, `HERMY_COMMAND`…). No JSON in the
   core at all, but a path or command can hold any byte but NUL, and a
   newline-separated list cannot carry a path with a line break, which the
   guard must still refuse correctly.
3. **Keep Claude's keys as the contract.** Least change, but the core stays
   Claude-shaped and every other shim emulates Claude.

## Constraints

- bash 3.2 (`/bin/bash` on macOS CI), no new dependency.
- Hooks stay exec form in `hooks/hooks.json`; the table `selftest.sh` asserts
  does not change.
- `allowed-tools` lines and verbs do not change.
- Every behaviour the CLAUDE.md guardrail description states for a payload
  holds after, read through the shim.

## Docs

- `docs/specs/2026-10-15-cli-core-design.md`: a per-host delta table for
  Claude Code, Copilot CLI (spike matrix) and Codex (paper).
- README:78 area and ROADMAP:59 stop claiming the hooks are host-neutral
  before this lands; ROADMAP:62's Cursor premise is fixed.
- CLAUDE.md: the core/adapter paragraph names the contract.

## Process (owner's ask)

Each task's diff is reviewed by hermy's own briefs, `agents/review.md` and
`agents/security.md`, run as generic sub-agents on the brief file with
`skills/start/references/policy.md`'s path, the worktree, the diff and this
design's goals as the acceptance criteria: the fallback hermy itself uses on
a host without its agents. Both self-tests run on every change, and a
headless Claude Code guard check runs before the PR.

## Left to the builder

- How the shim reads the payload (one jq call building the neutral object).
- Message wording, as long as each refusal keeps its meaning.
- Self-test structure for the two-session interleave.
