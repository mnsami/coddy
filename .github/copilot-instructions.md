# Copilot instructions for hermy

hermy is a Claude Code plugin (and its own single-plugin marketplace). There is no build step and no dependencies. The deliverables are prompt files and shell scripts:

- `skills/*/SKILL.md`: nine skills (`onboard`, `next`, `start`, `ship`, `triage`, `config`, `migrate`, `drop`, `refresh`)
- `agents/{context,simplest,implement,harden,review,security}.md`: the sub-agent briefs `start` delegates to
- `skills/start/references/policy.md`: shared brief rules, read first by every brief
- `bin/hermy`: the core, holding every mechanic
- `scripts/*.sh`: Claude Code shims around the core
- `hooks/hooks.json`: the guardrails
- `templates/`: the PR-check CI templates for GitHub and GitLab
- `get.sh`: the installer for other agents and terminals

`CLAUDE.md` is the detailed design reference (lock states, hook behaviour, known ceilings). Read the relevant section before changing `bin/hermy`, `scripts/` or `hooks/`.

## Commands

```bash
bash scripts/selftest.sh        # shims end to end: worktrees, claim, push, guard, tripwire, PR check, static wiring
bash scripts/selftest-core.sh   # bin/hermy on HERMY_* inputs alone (no CLAUDE_* set), get.sh, doctor
claude plugin validate .        # manifest and skill frontmatter; the CLAUDE.md-not-loaded warning is expected
shellcheck -S warning bin/hermy scripts/*.sh get.sh   # lint, as CI runs it (pinned shellcheck 0.11.0)
claude --plugin-dir . -p "/hermy:next"   # run one skill headless against the working copy
```

- `verify` in `.hermy.yml` is the two self-tests plus `claude plugin validate .`.
- Run both self-tests after any change under `bin/` or `scripts/`. There is no way to run a single test case, so run the whole script.
- CI runs both under `/bin/bash` 3.2 on macOS, so keep scripts bash-3.2 compatible.
- `selftest.sh` skips the jj leg when `jj` is missing.
- Skills act on the project in `$CLAUDE_PROJECT_DIR`. To exercise one, run `claude --plugin-dir /path/to/hermy` from inside a target project that has (or, for `onboard`, lacks) `.hermy.yml`.
- A release is a version bump of `.claude-plugin/plugin.json` through its own PR, never a direct commit to `main`. CI then tags it. Steps are in `RELEASING.md`. `marketplace.json` carries no version.

## Architecture

- **Prompts hold judgment, scripts hold mechanics.** A skill decides what to do. Any fixed command sequence lives in `bin/hermy` so it is tested once and pre-approved.
- **Core and adapter.** `bin/hermy` is the only script that mutates. It reads no `CLAUDE_*` variable, only `HERMY_*` inputs. `scripts/issue.sh`, `config.sh` and `detect.sh` are shims that map Claude Code's environment onto those inputs and source the core. Anything Claude-specific belongs in a shim, not in `bin/hermy`.
  - The hook verbs (`guard`, `snap`, `trip`) read one host-neutral JSON object (`paths`, `command`, `cwd`, `call`, `session`) and print at most one verdict line, `{"hermy":"ask"|"note","text":...}`. A block is exit 2 with the message on stderr.
  - A host's shim defines `hermy_in` (payload to that object) and `hermy_out` (verdict to the host's hook output) before sourcing the core; Claude Code's are in `scripts/issue.sh`. No host payload key is in `bin/hermy`, and `selftest-core.sh` asserts it.
  - A shim whose host cannot ask sets `HERMY_ASK=0`, which turns the guard's ask into a block. `issue.sh` unsets an inherited one.
- **Fact injection.** Each skill opens with injected `` !`bash "${CLAUDE_PLUGIN_ROOT}/scripts/<x>.sh"` `` blocks whose stdout becomes prompt text.
  - Injected scripts must be read-only, print `key: value` lines and never fail loudly (`|| exit 0`, `2>/dev/null`).
  - The exception is `issue.sh sweep`, which cleans up merged branches.
  - Each skill carries one fallback line for hosts that don't inject. The self-test asserts it, and it must not contain the injection syntax inside a line.
- **Hooks run through `scripts/hook.sh`,** a POSIX `sh` launcher (not bash) invoked via `/usr/bin/env -u …`, which strips project-local `PATH` entries and runs `issue.sh` under `bash -p`. The shims ignore any inherited `HERMY_*` value.
- **Guardrails are enforced by `hooks/hooks.json`, not wording.** The layers are the edit guard, the shell tripwire (`snap`/`trip`), the config lock, the git hooks, branch protection and the PR check. All are inert until the project is onboarded. `guard` and `snap` fail closed.
- **Shared brief rules go in `skills/start/references/policy.md`,** not into an individual brief. Each brief is a plugin agent `hermy:<name>` with `model: inherit` and a fixed tool list that the self-test checks.
- **Config schema has three copies.** They are the annotated schema in `skills/onboard/SKILL.md` (authoritative), the key list in `skills/config/SKILL.md` and the example in `README.md`. The self-test fails unless all three name the same keys. A new key also means updating `detect.sh` if it can be inferred, and every skill or script that reads it. Schema changes are a new step function in `bin/hermy` plus a bumped `version` in all three copies.
- **Tracker variants (`github`, `jira`, `gitlab`) live in the prompts.** They are MCP tools, so no script reaches the tracker. Each step that touches the tracker spells out every variant inline.
- **Issue work lives in `.worktrees/<issue>`.** The directory name is the issue id, and `.git/hermy/<issue>/` is its claim lock. `start` creates the worktree locally before claiming on the tracker, so a failure never leaves an issue In Progress without a branch.
- **Skill flow:** `onboard` → `next` → `start <issue>` → `ship`. `triage`, `config`, `migrate`, `drop` and `refresh` sit alongside. Each skill ends by naming the next command and states what it must not do.

## Conventions

- **`allowed-tools` must mirror commands exactly.**
  - Every injected command and every `issue.sh` verb a skill runs must appear in that skill's `allowed-tools` as `Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/<x>.sh" …)`.
  - Each rule must be an exact match for one shape in the closed list in `scripts/selftest.sh`. Adding, renaming or re-quoting a command without updating both breaks the self-test or brings back permission prompts.
  - `take` and `drop` are prompt-gated and have no rules.
- `hooks/hooks.json` is asserted as one table in `selftest.sh`. Changing, adding or dropping an entry means updating the assertion.
- Skills must stay model-invocable. Never set `disable-model-invocation`. Each needs a `when_to_use` line of trigger phrases. Only `ship` and `drop` restrict theirs to explicit asks.
- Keep frontmatter values free of `: ` and ` #`, since they are unquoted YAML scalars.
- Skill bodies are terse imperative checklists: `condition → action` guards first, then numbered steps, with per-tracker variants as sub-bullets. Match that style.
- Hooks block only on exit 2. Hook paths in `bin/hermy` set `code=2` before `die`. A hook that only wants to tell the agent something prints a `note` verdict and exits 0; Claude Code's shim maps it to `additionalContext`, without `permissionDecision`.
- `trip` is registered on both `PostToolUse` and `PostToolUseFailure`, because a failing Bash command fires only the latter.
- Scripts are committed executable (`chmod +x`).
- The pre-rename name is not allowed anywhere in the tree except the legacy spellings listed in `oldok` in `selftest.sh`.
- Commits use `type: summary` (`feat`, `fix`, `chore`).
