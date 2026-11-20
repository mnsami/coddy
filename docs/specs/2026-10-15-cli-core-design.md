# Agent-agnostic hermy CLI core (#27)

## Goal

Move hermy's mechanics into a `hermy` command with no Claude Code dependency, so later adapters (#31-#33) call the same core. Claude Code becomes the first adapter.

## Decisions

- `selftest.sh` is unchanged except the two pull-exemption assertions, which now expect a restore. It keeps calling `scripts/{issue,config,detect}.sh` with `CLAUDE_*` variables and `.claude/coddy.yml`, and passes.
- `scripts/*.sh` stay as Claude shims, so `hooks/hooks.json` and every skill's `allowed-tools` stay byte-identical.
- `.claude/coddy.yml` is a read fallback; projects move to `.hermy.yml` explicitly through `/hermy:config`, never from a hook.
- `.hermy.yml` gets no Claude Code sensitive-file prompt, so `guard` asks the user on every Edit or Write of it.
- `hermy start` and `hermy ship` cover the local halves only; tracker and PR calls stay MCP steps in the skills.

## Layout

- `bin/hermy`: the core. Today's `scripts/issue.sh` body plus `scripts/root.sh`, and the verbs `config` (today's `config.sh`) and `detect` (today's `detect.sh`). Executable. Claude Code puts a plugin's `bin/` on the Bash tool's `PATH`; other agents need a symlink or a `PATH` entry.
- `scripts/root.sh`: deleted.
- `scripts/issue.sh`, `scripts/config.sh`, `scripts/detect.sh`: Claude shims. Each sets, from Claude's environment alone, ignoring any inherited `HERMY_*` value (a settings `env`, a hostile shell),
  - `HERMY_ROOT` from `CLAUDE_PROJECT_DIR`
  - `HERMY_SESSION` from `CLAUDE_CODE_SESSION_ID`
  - `HERMY_PID` from `CLAUDE_PID`
  - `HERMY_AGENT_DIR=.claude`

  then sources `bin/hermy` (`issue.sh` passes its arguments through; `config.sh` and `detect.sh` call the `config` and `detect` verbs).

The core reads no `CLAUDE_*` variable. The only `.claude` string left in it is the legacy config path.

## Core inputs

| Variable | Meaning | Absent |
|---|---|---|
| `HERMY_ROOT` | Directory to start root resolution from | `$PWD` |
| `HERMY_SESSION` | Session id written to and compared with the lock's owner line | Caller not held to the owner, as today |
| `HERMY_PID` | Pid written to and compared with the owner line | As today without `CLAUDE_PID` |
| `HERMY_AGENT_DIR` | The agent's own directory, relative to the root | No agent-dir rules |

Root resolution is unchanged apart from its start point: `git rev-parse --git-common-dir`, keeping the caller's spelling, and stripping `/.worktrees/*` outside git.

## Verbs

| Verb | Does |
|---|---|
| `start <issue> <branch> [base]` | Today's `create`; `create` stays as an alias |
| `claim <issue> [--take]` | Unchanged; runs after the skill's tracker transition |
| `ship <issue>` | `verify` then `push`; `push` stays as an alias for push alone |
| `sweep`, `guard`, `status` | Unchanged |
| `snap`, `trip`, `state`, `verify`, `diff`, `log` | Unchanged |
| `config` | Today's `config.sh`: the config, or `NOT_ONBOARDED` |
| `detect` | Today's `detect.sh` |

The agent-dir rules in `guard` and `snap`, today written as `.claude/`:

- Paths under `$HERMY_AGENT_DIR/` are allowed, and skipped by `snap`.
- `$HERMY_AGENT_DIR/worktrees/<name>/` is held to `<name>`'s lock, as `.claude/worktrees/` is today.

## Config

- `conf` is `.hermy.yml` when it exists at the root, else `.claude/coddy.yml`.
- `guard` on `.hermy.yml` at the root prints `{"hermy": "ask", "text": "..."}`, which the shim turns into the host's ask, and exits 0, with `guard: warn` too. Without `jq` it exits 2 (fails closed, as today).
- Config lock:
  - `snap` records both paths, including whether each exists.
  - `trip` restores either one that a shell command deleted or changed.
  - `trip` deletes a `.hermy.yml` that the command created while only `.claude/coddy.yml` existed, so a new file cannot shadow the live config.
  - A changed config is put back from the snapshot, always, a pull or checkout that brought another one included: nothing a shell command run as the same user can write (a ref, an object, a git config) tells it from a forged one. The message names `/hermy:config`, which accepts it from `HEAD`. Nothing under `TMPDIR` is opened unless it is a plain file. The fingerprint leaves both config paths to the lock, since a restored file differs from a pulled `HEAD`.
- `/hermy:config` gains a migrate step when only the legacy file exists: write `.hermy.yml` with the Edit tool (the guard asks), then delete `.claude/coddy.yml`. A change to any other key offers the move first. It also accepts a config change that came from git: it shows `git diff HEAD -- <config>` and, on yes, writes `HEAD`'s content with the Write tool (the guard asks).
- `/hermy:onboard` writes `.hermy.yml`.
- `detect` reports `.hermy.yml` and the legacy file.
- The three schema copies keep the same keys.

## Tests

- `scripts/selftest.sh`: unchanged except the two pull-exemption assertions, which now expect a restore; passes through the shims.
- `scripts/selftest-core.sh` (new) calls `bin/hermy` with no `CLAUDE_*` set and covers:
  - root resolution from `HERMY_ROOT` and from `$PWD`;
  - a claim and push held to the owner through `HERMY_SESSION` and `HERMY_PID`;
  - `.hermy.yml` preferred over the legacy file, and the fallback;
  - the guard's ask on `.hermy.yml`, in both guard modes;
  - the shadowing restore, plus the delete and change restores on `.hermy.yml`, a pull of a shared config among them;
  - no agent-dir rules without `HERMY_AGENT_DIR`;
  - `start` and `ship` (including `ship` stopping on a failing verify) next to their aliases.
- `selftest.sh` does not call `selftest-core.sh`; it is unchanged except the two pull-exemption assertions, which now expect a restore. This repo's `verify` becomes `bash scripts/selftest.sh && bash scripts/selftest-core.sh && claude plugin validate .` through `/hermy:config`, and the Commands section of `CLAUDE.md` lists both tests.

## Docs

- `CLAUDE.md`: the core/adapter split, the `HERMY_*` inputs, the config path and its lock, the commands section.
- `README.md`: `.hermy.yml` and how to put `hermy` on `PATH`.
- `ROADMAP.md`: #27 under M2.

## Hook contract (#278)

The hook verbs (`guard`, `snap`, `trip`) read one neutral JSON object on stdin: `paths` (every path an edit writes), `command`, `cwd`, `call` (the per-call id pairing `snap` with `trip`) and `session`. They print at most one verdict line: block is exit 2 with the message on stderr; `{"hermy": "ask", "text": "..."}` and `{"hermy": "note", "text": "..."}` exit 0. A host's shim defines `hermy_in` (its payload to that object) and `hermy_out` (the verdict to its hook output) and sources the core; with neither, stdin is the object and the verdict goes out as it is. Design: `docs/superpowers/specs/2026-11-11-hook-contract-design.md`.

- `HERMY_ASK=0`: a shim whose host cannot ask sets it, and the guard's ask then blocks, saying the host cannot ask. `scripts/issue.sh` unsets an inherited one.
- The guard refuses an edit naming more than 64 paths, in both guard modes, before it guards any, and one whose paths are not all checked within 8 s, before the next path; each path's run gets the seconds left less one, `SECONDS` counting whole seconds (`HERMY_GUARD_BUDGET`, which lowers the 8 s; `scripts/issue.sh` unsets an inherited one).
- A plain-word `call` names the snapshot `call-<call>`; with none, it is `session-<session>`, else `pid-<HERMY_PID>`, each reduced to `[A-Za-z0-9_-]` and cut to 128 characters, else `shared`, each kind under a prefix of its own so no call id names a session's snapshot. The Claude shim hands over the top-level `session_id` while it is a plain word, else `session` as `sed` read it on both of its branches (its JSON spelling, control characters dropped), so `snap` without jq and `trip` with it name one snapshot.

| Host | Payload keys | Session id | Call id | Ask | Failure event | Hook registration |
|---|---|---|---|---|---|---|
| Claude Code | `tool_input.file_path`, `notebook_path`, `command`; `cwd` | `session_id` in the payload; `CLAUDE_CODE_SESSION_ID` and `CLAUDE_PID` in the shell's env | `tool_use_id` | `permissionDecision: ask`, its reason shown | `PostToolUse` and `PostToolUseFailure` | `hooks/hooks.json`, exec form |
| Copilot CLI | Claude's tool names (`Write`, `Edit`, `Bash`); `path` for `file_path`; `apply_patch` as an `Edit` whose `tool_input` is the patch string | `session_id` in the payload, none and no pid in the hook's env; `COPILOT_AGENT_SESSION_ID` in its shell tool, equality unverified (#414) | `tool_use_id` | shown without its reason; none headless, so its shim sets `HERMY_ASK=0` | `PostToolUse` alone, no `PostToolUseFailure` for a shell command | loads `hooks/hooks.json` but drops the exec form's args; a timeout fails open; hooks run inside its sandbox |
| Codex | paper only (#31): an `apply_patch` tool | per its docs, unverified | per its docs, unverified | unverified | unverified | `.codex-plugin/plugin.json`, unverified |

## Out of scope

- Hook output per agent: done by the hook contract above; each host's shim maps it (#31-#33).
- Session identity for agents without one (#34 reports it).
- AGENTS.md and portable skills (#28).
