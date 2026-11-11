# Copilot CLI Compatibility Spike Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

Status: executed 2026-11-11; results in the #33 comment (https://github.com/mnsami/coddy/issues/33#issuecomment-6794332979).

**Goal:** A compatibility matrix, backed by log lines, of what Copilot CLI does with coddy's plugin, hooks, skills, agents and tracker calls, and a backlog rewritten from it.

**Architecture:** A throwaway probe plugin logs every hook payload and environment and carries a test skill and agent. It runs on Copilot CLI (and on Claude Code as a baseline). Then coddy, unchanged, runs end to end under Copilot against a scratch GitHub repo. Nothing built here is committed to coddy except this plan, the design, and the backlog/ROADMAP edits in the last task.

**Tech Stack:** POSIX sh, bash, jq, git, Copilot CLI 1.0.109, Claude Code (if installable), Docker MCP gateway (`github-official`, a Docker MCP gateway profile).

**Spec:** `docs/superpowers/specs/2026-11-11-copilot-spike-design.md`

## Global Constraints

- No change to `bin/coddy`, `scripts/`, `skills/`, `agents/` or `hooks/` in coddy during the spike.
- Throwaway area: `~/dev/private/coddy-spike/` (`probe/`, `scratch/` + `scratch.git/`, `repo/`, `results/`). Never inside the coddy checkout.
- GitHub writes only to `mnsami/coddy-spike`. GitLab and Jira legs are paper checks.
- Probe logs variable values only for `CLAUDE_*`, `COPILOT_*`, `CODDY_*`, `GIT_*`, `PATH`, `TMPDIR`, `HOME`; names only for the rest.
- Every matrix cell cites a log line, a transcript excerpt or a doc URL (paper checks). No "works" without one.
- Copilot headless: `copilot --plugin-dir <dir> -p "<prompt>" --allow-all-tools --log-dir ~/dev/private/coddy-spike/results/logs/<run>`; interactive only for H7 `ask`, H10 `/clear` and H11 sandbox.

## Review Focus

- Probe hook on a payload with no `tool_input` (SessionStart, Stop) must still log and exit per mode, or the matrix records a false "event did not fire". Pinned in Task 1.
- Mode file absent or empty must mean `pass`, not block every call. Pinned in Task 1.
- Parallel calls writing the log at once must not interleave lines. Pinned in Task 1.
- A run that never loaded the plugin looks like "hook not fired" on every row; each run must assert a `SessionStart` or `PreToolUse` line before its rows count. Pinned in Task 3.
- Secrets in env dumps (`GITHUB_TOKEN`, OAuth): values outside the allowlist never reach the log. Pinned in Task 1.

---

### Task 1: Probe hook logger

**Files:**
- Create: `~/dev/private/coddy-spike/probe/.claude-plugin/plugin.json` (`{"name":"coddy-probe","version":"0.0.1","description":"throwaway"}`)
- Create: `~/dev/private/coddy-spike/probe/hooks/hooks.json`
- Create: `~/dev/private/coddy-spike/probe/scripts/probe.sh` (executable)
- Test: `~/dev/private/coddy-spike/probe/scripts/probe-test.sh`

**Interfaces:**
- Produces: `probe.sh <event>`: reads the payload on stdin, appends one JSON line `{"t0","t1","event","pid","pwd","payload","env":{name:value|null}}` to `${PROBE_LOG:-/tmp/coddy-probe/log.jsonl}`, then acts per `$(dirname "$PROBE_LOG")/mode.<event>`, else `mode`, else `pass`. Modes (first word): `pass` (exit 0), `exit2`, `exit1`, `sleep <s>`, `touch <path>`, `context <text>` (prints `{"hookSpecificOutput":{"hookEventName":"<event>","additionalContext":"<text>"}}`), `ask`/`deny` (prints `hookSpecificOutput.permissionDecision` + reason), `ask-flat`/`deny-flat` (prints top-level `permissionDecision` + `permissionDecisionReason`, Copilot's documented shape).
- `hooks.json`: events `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `Stop`, matcher `*` where matchers apply; each entry copies coddy's exec form from `coddy/hooks/hooks.json` with `scripts/probe.sh <event>`; `PreToolUse` carries `"onFailure":"block","timeout":10`.

- [ ] **Step 1: Write `probe-test.sh`** asserting, with a temp `PROBE_LOG`:
  - `echo '{"session_id":"s","tool_name":"Bash","tool_input":{"command":"ls"}}' | GITHUB_TOKEN=sekret probe.sh PreToolUse` exits 0; log has 1 line; `jq -e '.event=="PreToolUse" and .payload.tool_input.command=="ls"'`; `grep -c sekret log` is 0.
  - `echo '{}' | probe.sh Stop` exits 0 and logs a line.
  - `echo not-json | probe.sh Stop` exits 0 and logs `.payload` as a string.
  - `echo exit2 > mode.PreToolUse`: PreToolUse exits 2; Stop exits 0.
  - `echo 'context hi' > mode`: Stop's stdout passes `jq -e '.hookSpecificOutput.additionalContext=="hi"'`.
  - 20 background calls then `wait`: 20 more lines, each passes `jq -e .`.
- [ ] **Step 2: Run** `sh probe-test.sh` → FAIL (no probe.sh).
- [ ] **Step 3: Implement `probe.sh`** in POSIX sh; build the line with one `jq -c` call (`--argjson` payload, `--arg` fallback when stdin is not JSON) and append it with one `printf` (atomic under PIPE_BUF for normal payloads).
- [ ] **Step 4: Run** `sh probe-test.sh` and `/bin/bash probe-test.sh` → all PASS.
- [ ] **Step 5:** `git init ~/dev/private/coddy-spike` and commit (`chore: probe hook logger`); never pushed.

### Task 2: Probe skill and agent

**Files:**
- Create: `probe/skills/probe/SKILL.md`, `probe/scripts/facts.sh` (executable), `probe/agents/probe.md`, `probe/bin/probe-bin` (executable, prints `probe-bin on PATH`)

**Interfaces:**
- Consumes: plugin layout from Task 1.
- Produces: `facts.sh` prints `key: value` lines: `plugin_root`, `project_dir` (`$CLAUDE_PROJECT_DIR`), `session` (`$CLAUDE_CODE_SESSION_ID`), `pid` (`$CLAUDE_PID`), `copilot_vars` (names of `COPILOT_*`), `pwd`, `path_has_bin` (`yes` if `probe/bin` is on `PATH`).
- `SKILL.md` frontmatter: `name: probe`, `description: coddy probe skill`, `when_to_use: run the coddy probe`, `argument-hint: <issue>`, `allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/facts.sh")`. Body: a line opening with the backtick-bang injection of `bash "${CLAUDE_PLUGIN_ROOT}/scripts/facts.sh"`; `ROOT=${CLAUDE_PLUGIN_ROOT}`; `ARGS=$ARGUMENTS`; then: reply with the injected section verbatim and both lines as seen, run `probe-bin` and `bash "${CLAUDE_PLUGIN_ROOT}/scripts/facts.sh"` and quote both outputs, then spawn agent `coddy-probe:probe` with model `haiku` and quote its reply.
- `agents/probe.md`: frontmatter `name: probe`, `description: coddy probe agent (coddy-probe:probe)`, `model: inherit`, `tools: Bash, Read`; body: run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/facts.sh"`, return its output and the model name if known.

- [ ] **Step 1: Verify** `CLAUDE_PROJECT_DIR=/x bash probe/scripts/facts.sh` prints `project_dir: /x` and all seven keys.
- [ ] **Step 2: Commit** (`chore: probe skill and agent`).

### Task 3: Host matrix (H1–H12, S1–S5)

**Files:**
- Create: `scratch/` (git repo, one commit, `origin` = local bare `scratch.git`), `results/run.sh`, `results/matrix.md`

**Interfaces:**
- Produces: `run.sh <host> <id> "<prompt>" [mode-line]`: host `copilot` or `claude`; writes the mode file, sets `PROBE_LOG=results/logs/<host>-<id>/log.jsonl`, runs the host headless in `scratch/` with `--plugin-dir probe`, saves the transcript as `transcript.txt` beside the log, exits 1 unless the log holds a `SessionStart` or `PreToolUse` line.
- `matrix.md`: one table, rows H1–H12, S1–S5, columns `id | question | claude | copilot | evidence`.

- [ ] **Step 1: Baseline host.** Ask the owner to approve `npm i -g @anthropic-ai/claude-code` and log in; if declined, the claude column cites CLAUDE.md / Claude Code docs and the table header says so.
- [ ] **Step 2: Runs**, each on both hosts with the same prompt:
  - `h1`: "Create a.txt containing x, then edit it to y, then run ls, then read a.txt." → H1–H3 (tool names, `tool_input` keys), H4 (hook env), H8 negative.
  - `h3patch`: "Use apply_patch to create b.txt and c.txt in one patch." → H3 multi-file shape.
  - `h6-exit2`, `h6-exit1`, `h6-sleep` (`sleep 15` > timeout 10) with the h1 prompt on `mode.PreToolUse` → H6: did a.txt change?
  - `h7-ctx` (`context PROBE-CTX`, prompt "run ls and quote any hook context you received"), `h7-ask`, `h7-askflat`, `h7-denyflat` headless; `ask` again interactive and with `--autopilot` → H7.
  - `h8`: "run the command false" → `PostToolUseFailure` line present.
  - `h9`: "In parallel, run `sleep 3; echo a` and `sleep 3; echo b`" → overlapping `t0`/`t1` on the two `PreToolUse` lines; any per-call id in the payload.
  - `h10`: `source` on a new run, `copilot --continue`, and `/clear` interactive.
  - `h11`: interactive with `copilot sandbox` on, `mode.PreToolUse` = `touch $PWD/.git/hooks/probe-x`, then `touch $TMPDIR/probe-x` → did each file appear; hook `pwd`/env.
  - `h12`: `copilot plugin install ~/dev/private/coddy-spike/probe` then the h1 prompt without `--plugin-dir` → `CLAUDE_PLUGIN_ROOT`/`CLAUDE_PLUGIN_DATA` paths; uninstall after.
  - `s1`: "/coddy-probe:probe 42"; `s1nl`: "run the coddy probe for issue 42" → S1–S5; H5 from `facts.sh` output.
- [ ] **Step 3: Fill `matrix.md`**, every cell with evidence `logs/<host>-<id>/log.jsonl:<line>` or a transcript quote.
- [ ] **Step 4: Commit** (`chore: host matrix`).

### Task 4: Tracker matrix (T1–T4)

**Files:**
- Modify: `results/matrix.md` (rows T1–T4 × GitHub, GitLab, Jira)
- Create: `results/tool-map.md`: each name from `grep -rhoE 'mcp__[A-Za-z_]+' ~/dev/private/coddy/skills | sort -u` (27 today) → its Copilot name or `none`.

- [ ] **Step 1: GitHub, live**, in `repo/` (clone of `mnsami/coddy-spike`), Copilot headless with `--allow-all-tools`: create label `in progress`; create issue "spike: probe"; read it; assign `mnsami`; set label; comment; push branch `spike-1` with one commit and open a PR "Closes #<n>". Record per action the tool name used and which server served it (built-in `github-mcp-server` or `docker-*`).
- [ ] **Step 2: Built-in only**: repeat Step 1's write actions with `--enable-all-github-mcp-tools` and the Docker server removed from that run (`--disable-mcp-server docker` if present, else a temp `COPILOT_HOME`/config without it) → can Copilot's own server write?
- [ ] **Step 3: T4**: add `allowed-tools` entries `docker-issue_write` and `mcp__plugin_github_github__issue_write` to the probe skill, run "/coddy-probe:probe comment on issue <n>" without `--allow-all-tools` → which (if any) skips the prompt.
- [ ] **Step 4: GitLab and Jira, paper**: from GitLab's MCP server docs and Atlassian's Rovo MCP server docs: the `~/.copilot/mcp-config.json` entry, auth, and tool names; fill `tool-map.md`; each cell `paper` + URL.
- [ ] **Step 5: Commit** (`chore: tracker matrix`).

### Task 5: coddy unchanged under Copilot (stage 2)

**Files:**
- Create: `results/stage2.md` (table `step | result | why | evidence`)

**Interfaces:**
- Consumes: `repo/` from Task 4; coddy checkout at `~/dev/private/coddy` as `--plugin-dir`.

- [ ] **Step 1: Onboard**: in `repo/`, `copilot --plugin-dir ~/dev/private/coddy`, interactive `/coddy:onboard`; record injection, questions, files written (`.coddy.yml`, PR check workflow, `AGENTS.md` block).
- [ ] **Step 2: Flow**: file issues "spike: add hello.txt" and "spike: add bye.txt"; run `/coddy:next`, `/coddy:start <n>` (to plan approval and through review), `/coddy:ship`; record each step.
- [ ] **Step 3: Guardrails**, each a headless prompt with `--allow-all-tools` in `repo/`: edit `README.md` in the main checkout (expect refusal); edit a file in an unclaimed `.worktrees/99/` (refusal); edit `.coddy.yml` (ask); `echo x >> README.md` via shell (trip report); `rm .coddy.yml` via shell (restored); `git commit --allow-empty -m x` on `main` (git-hook refusal); two parallel shell calls (snap/trip pairing).
- [ ] **Step 4:** `coddy doctor` from Copilot's shell; quote output.
- [ ] **Step 5: Commit** (`chore: stage 2 results`).

### Task 6: Backlog and ROADMAP from the matrix

**Files:**
- Modify (coddy, branch `chore/copilot-spike`): `ROADMAP.md` (#33's M4 line); `docs/superpowers/specs/2026-11-11-copilot-spike-design.md` ("Observed so far" gets a link to the #33 comment)
- Add: this plan and the design doc

- [ ] **Step 1:** Post `matrix.md`, `tool-map.md` and `stage2.md` as one comment on #33; link it from #30 and #278.
- [ ] **Step 2:** Draft, per `breaks` cell, a rewrite of the owning issue's acceptance criteria (#33, #278, #279, #239, #157, #164, #103) or a new issue (M2: core/contract; M4: Copilot adapter), each citing its row. Show the list to the owner; file only what they approve.
- [ ] **Step 3:** Replace #33's ROADMAP line with one sentence the matrix supports.
- [ ] **Step 4:** Commit (`chore: copilot spike design, plan and roadmap line`), push the branch, open a PR referencing #33.
- [ ] **Step 5:** Ask the owner whether to delete `mnsami/coddy-spike` and `~/dev/private/coddy-spike/`, or keep the probe for Codex/Cursor/Gemini (a separate request).
