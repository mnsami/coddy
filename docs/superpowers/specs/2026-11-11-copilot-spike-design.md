# Copilot CLI compatibility spike (#33, #30)

## Intent

Make coddy agent-agnostic, with GitHub Copilot CLI as the second host after Claude Code. Copilot must reach parity on all three trackers coddy supports today: GitHub, GitLab and Jira. Before building an adapter, find out what Copilot CLI actually does with coddy's plugin, hooks, skills, sub-agents and tracker MCP calls. The docs are incomplete or ambiguous on most of the points that decide the design.

The spike's product is evidence, not code: a compatibility matrix and a backlog rewritten from it. Nothing it builds is kept in coddy.

## Goals

- Answer every host question below on Copilot CLI with a logged observation, and on Claude Code as the baseline, using the same probe.
- Run coddy unchanged under Copilot through `onboard → next → start → ship` on each tracker, and record where and why it breaks.
- Turn the results into: an issue per gap (new or rewritten: #33, #278, #279, #239, #157, #164, #103), a revised ROADMAP line for #33, and the input for the adapter plan.

## Non-goals

- No adapter code, no change to `bin/coddy`, the shims, skills or hooks in this spike.
- No VS Code agent mode, no Copilot cloud agent (separate targets; the PR check already covers the cloud agent).
- No Codex, Cursor or Gemini runs. The probe is written so they can run it later.

## Anti-goals

- A matrix that says "works" without a log line behind it.
- Adapting coddy to Copilot by weakening a guardrail. A layer Copilot cannot enforce is recorded as such (advisory or enforced at commit, per #239), not hidden.
- Copilot-specific logic in `bin/coddy` (it stays host-neutral; #278).

## Constraints

- Copilot CLI 1.0.109 (local, `/opt/homebrew/bin/copilot`), headless via `copilot -p` and `--plugin-dir`; interactive runs only where headless cannot show the behaviour (`ask` prompts, sandbox).
- Claude Code baseline via `claude --plugin-dir . -p`.
- macOS, plus `/bin/bash` 3.2 where a script's behaviour is in question.
- Throwaway repositories live outside the coddy checkout (`~/dev/private/coddy-spike/`), each with a local bare remote for the git layers, and a real tracker project for the tracker legs.
- No secrets in logs that leave the machine: the probe logs variable names, and values only for the allowlist below.

## Approaches

- **A. Probe plugin first, then coddy unchanged (chosen).** A ~50-line plugin logs every hook payload and environment and carries a test skill and agent. It answers the host questions without coddy's guard in the way. Then coddy runs as-is per tracker. Picked because it separates "what the host does" from "what coddy does with it", and the probe runs again on any later host. That fits the agent-agnostic goal.
- B. coddy unchanged with a logging hook added to a copy. Faster to start, but the guard blocks calls before you can see why, so failures are hard to read.
- C. Hooks now, trackers later. Leaves the largest unknown (tracker MCP names and writes) for later, against the three-tracker requirement.

## Stage 1: the probe

A plugin `coddy-probe` in the throwaway area, with the same manifest shape as coddy (`.claude-plugin/plugin.json`).

- `hooks/hooks.json`: every event coddy uses, plus `Stop` and `UserPromptSubmit`, matcher `*`, in coddy's exec form (`/usr/bin/env … /bin/sh scripts/probe.sh <event>`), with `onFailure` and `timeout` set as coddy sets them.
- `scripts/probe.sh`: appends one JSON line per call to `$PROBE_LOG` (default `/tmp/coddy-probe/log.jsonl`): event, the raw payload, `PWD`, start and end times, pid, and the environment (names of every variable; values for `CLAUDE_*`, `COPILOT_*`, `CODDY_*`, `GIT_*`, `PATH`, `TMPDIR`, `HOME`). Its behaviour per event is read from a mode file next to the log (`pass`, `exit2`, `exit1`, `sleep <s>`, `context <text>`, `ask`, `deny`), so a scenario changes it without reinstalling.
- `skills/probe/SKILL.md`: coddy's frontmatter shape (`allowed-tools` with a `Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/facts.sh" …)` rule, `when_to_use`, `argument-hint`) and a body with a backtick-bang injection line, `${CLAUDE_PLUGIN_ROOT}`, `$ARGUMENTS` and a named argument; `scripts/facts.sh` prints the shell environment of the skill.
- `agents/probe.md`: `model: inherit`, a `tools:` list, a body that prints its environment through Bash.

### Host questions

| id | question | coddy depends on it in |
|---|---|---|
| H1 | `hooks/hooks.json` loads from a plugin dir and installed plugin; exec form (`command` + `args`) runs | every hook |
| H2 | event names and matchers fire; which tool names hooks see for edit, create, `apply_patch`, shell, view, sub-agent | guard / snap / trip matchers |
| H3 | payload keys: `tool_input.file_path` vs `path`, `notebook_path`, `command`, `cwd`, `session_id`, `tool_use_id`; `apply_patch`'s multi-file shape | guard path read, snap/trip pairing |
| H4 | hook env: `CLAUDE_PROJECT_DIR`, `CLAUDE_PLUGIN_ROOT`, `CLAUDE_PLUGIN_DATA`, any session id; hook `PWD` after a `cd` | shims' root and launcher |
| H5 | shell tool env: `CLAUDE_PROJECT_DIR`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_PID`, `PATH` holding the plugin's `bin/` | claim owner, Bash-tool verbs |
| H6 | exit 2, exit 1, crash, timeout: block or pass, per event; is `onFailure` read | guard/snap fail-closed |
| H7 | output: `hookSpecificOutput.additionalContext` reaches the model; `permissionDecision: ask` under `-p`, interactive, autopilot | warn mode, `.coddy.yml` ask |
| H8 | a failing shell command fires `PostToolUseFailure` | trip |
| H9 | parallel tool calls: overlapping Pre/Post hooks, ordering, a way to pair them | snapshot naming (#278) |
| H10 | `SessionStart` `source` values on start, resume, `/clear` | launcher link |
| H11 | sandbox on: hooks inside or outside it; writes to `.git/hooks`, `.git/config`, `TMPDIR` | git-hook install, snapshots |
| H12 | plugin cache and data dir layout for installed and `--plugin-dir` plugins | `issue.sh` launcher derivation |
| S1 | skill fires by `/coddy-probe:probe` and by plain language | every skill |
| S2 | backtick-bang injection runs and inlines stdout; `${CLAUDE_PLUGIN_ROOT}` expanded in body and `allowed-tools` | fact injection, fallback line |
| S3 | `$ARGUMENTS` and named arguments | `start <issue>`, `onto` |
| S4 | `allowed-tools` pre-approves the rule; others prompt | no-prompt skill runs |
| S5 | `agents/*.md` load as plugin agents (`coddy-probe:probe`); `model`, `tools`; per-spawn model override | start's six briefs, tiers |

### Tracker questions (each of GitHub, GitLab, Jira)

| id | question |
|---|---|
| T1 | how the server is configured for Copilot (built-in, plugin `.mcp.json`, user config) and how it authenticates |
| T2 | the tool names Copilot exposes, mapped to each `mcp__plugin_<x>_<x>__*` name coddy's skills use (27 distinct today) |
| T3 | read, assign, transition or label, comment, create PR/MR: each works, and whether writes need a toolset or flag (GitHub's built-in server is read-only by default) |
| T4 | whether a skill's `allowed-tools` can pre-approve those tools |

## Stage 2: coddy unchanged

Per tracker, in a throwaway repo with a scratch tracker project:

1. Install coddy with `copilot --plugin-dir <coddy checkout>` (and once through `copilot plugin marketplace add` for H12).
2. Run `onboard`, `next`, `start <issue>`, `ship` headless, then interactively where headless stops.
3. Run CLAUDE.md's headless checks against Copilot: edit outside a worktree refused, edit in an unclaimed worktree refused, `.coddy.yml` ask, tripwire on a main-checkout write, config lock restore, git-hook refusal on `default_branch`.
4. Run `coddy doctor` from Copilot's shell.

Each step is recorded as works / breaks / why, with the log line or transcript excerpt.

## Output

- The matrix, posted as a comment on #33 (and linked from #30), one row per question and step, Claude Code and Copilot side by side.
- New or rewritten issues for each gap, milestoned under M2 (host-neutral core: #278, #279, #157, #164, #103) or M4 (#33, #239).
- A ROADMAP line for #33 that is true.
- The adapter plan, written after the matrix, through the normal design → plan flow.

The probe plugin stays in the throwaway area. Keeping it (for Codex, Cursor, Gemini) is a separate request.

## Decided by the owner

- Approach A.
- All three trackers in scope.
- Goal: coddy agent-agnostic, Copilot CLI first.
- GitHub leg: private scratch repo `mnsami/coddy-spike`, writes allowed. GitLab and Jira: paper checks from docs and the MCP servers' published tool lists, unless the owner adds a project before stage 2.

## Observed so far

Full results: https://github.com/mnsami/coddy/issues/33#issuecomment-6794332979 (comment on #33).

- Copilot names an MCP tool `<user's server config name>-<tool>`, so coddy can't hard-code a prefix (#415).
- The built-in GitHub server shows write tools under `--enable-all-github-mcp-tools`, but runs as the Copilot login's account. Writes to a repo that account can't see return 404.

## Builder's calls

- Throwaway location, log format, mode-file mechanism, the env value allowlist.
- Claude Code baseline runs the same probe, so differences are attributable to the host.
- The spike does not decide #285 D5 (cold users before adapters) or D12 (strict mode before M4); it feeds them.
