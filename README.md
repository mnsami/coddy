<p align="center">
  <img src="assets/coddy.svg" alt="Hermit, the coddy mascot: a hermit crab in its shell" width="160">
</p>

# coddy

[![CI](https://github.com/mnsami/coddy/actions/workflows/ci.yml/badge.svg)](https://github.com/mnsami/coddy/actions/workflows/ci.yml)

Issue-driven development workflow for Claude Code: every change Claude makes
is tied to a claimed issue, lives in its own worktree, and lands through a
pull request. The tracker holds the state; the plugin holds the habits.

<!-- Static transcript; a recording (asciinema, vhs) can replace it. -->
```text
> add a Develop section to the README

⏺ Update(README.md)
  ⎿  PreToolUse:Edit hook error: [bash "…/coddy/scripts/issue.sh" guard]:
     coddy: edits belong in an issue worktree, not the main checkout. Run /coddy:start <issue>, then edit under .worktrees/<issue>/.

> /coddy:start 42

⏺ #42 "Add a Develop section to the README": one section listing the three dev commands.
⏺ Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" create 42 chore/42-readme-develop)
  ⎿  created: .worktrees/42 on chore/42-readme-develop
⏺ Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh" claim 42)
  ⎿  claimed: 42
⏺ #42 is In Progress in .worktrees/42. Run /coddy:ship when done.

> now add it

⏺ Update(.worktrees/42/README.md)
  ⎿  Updated .worktrees/42/README.md with 7 additions
```

The first edit is rejected. It goes through once `/coddy:start` has claimed
the issue and given it a worktree. A hook enforces that, not the prompt.

## Install

In Claude Code, as a plugin:

```bash
claude plugin marketplace add mnsami/coddy   # or a local path to this repo
claude plugin install coddy@coddy
```

For another agent (Codex, Cursor, Copilot CLI, Gemini CLI) or your own
terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/mnsami/coddy/main/get.sh | bash
```

It clones `main` into `~/.coddy` (a rerun fast-forwards it, and stops on
local changes to tracked files), links `coddy` into `~/.local/bin` and
prints the line to add when that is not on your `PATH`. Your agent reads
the skills as Markdown from `~/.coddy/skills/`, starting with
`onboard/SKILL.md`. `coddy doctor` says which install a `coddy` runs from.
The plugin keeps its own copy and does not use `~/.coddy`.

You also need:

- `jq`. The edit guard needs it and blocks every edit without it.
- Optionally `jj` ([Jujutsu](https://jj-vcs.github.io)), for `worktree: jj`;
  `worktree: git`, the default, needs nothing more. `/coddy:onboard`
  installs either one that is missing (Homebrew, apt-get, dnf or winget)
  through a shell command you allow; `jj` has no apt-get package, so there
  it names the install page and recommends `worktree: git`.
- For GitHub Issues: the GitHub plugin, enabled and signed in with a token
  that can read and write the repository's issues and pull requests.
- For Jira: the Atlassian plugin.

Trackers are reached through those plugins' MCP tools. Neither needs a CLI.
The PR check workflow alone runs `gh`, inside GitHub Actions, where it is
built in.

The mechanics live in one command, `bin/coddy`, with no Claude Code
dependency: Claude Code puts the plugin's `bin/` on the Bash tool's `PATH`
while the plugin is enabled. claude.ai and Cowork do not install a plugin
that has a top-level `bin/`, through organisation settings either, so coddy
needs the Claude Code CLI. `get.sh` links `coddy` into `~/.local/bin`
and prints the `PATH` line to add when that directory is not on `PATH`.
It reads `CODDY_ROOT` (where to look for the project; the working directory
without it), `CODDY_SESSION` and `CODDY_PID` (the session and process a
claim is held to) and `CODDY_AGENT_DIR` (the agent's own directory, such as
`.claude`, free to edit); Claude Code's hooks and skills set those from its
own environment.

## Onboard a project

Run `/coddy:onboard` inside the project. It is a wizard of seven steps,
`checks → tracker → branch → verify → tiers → AGENTS.md → review`, with an
agenda before each and at most one question per step. It detects what it
can and asks for the rest; a missing `jq` or `jj` is installed through a
shell command you allow (declining `jq` stops it, declining `jj` picks
`worktree: git`). Your answers are saved under `.claude/coddy/`, so a run
that stops resumes where it was. At review it shows the config and, on your
yes, writes the PR check workflow and the coddy block into `AGENTS.md` (so
an agent without the plugin reads the rules), backing up any file it
replaces under `.claude/coddy/backup/`, and then `.coddy.yml` (see
[Config](#config)). It tells you what to set by hand so the default branch
requires a pull request. A project that already has a config is sent to
`/coddy:migrate` when it is behind the current version, `/coddy:config`
otherwise.

## Skills

The lifecycle is `next → start (think, implement, harden, review) → ship → merge`.
The next `next` or `start` sweeps up what the merge left behind.

| Skill | What it does |
|---|---|
| `/coddy:onboard` | A seven-step wizard: detects the project, installs `jq` and `jj` when you allow it, asks for what it can't infer (answers saved, so a re-run resumes), then writes the PR check workflow, the coddy block into `AGENTS.md` (backing up what it replaces) and `.coddy.yml` |
| `/coddy:config [key=value ...]` | Shows `.coddy.yml`, or changes the keys you name |
| `/coddy:migrate` | Brings the config up to the current `version`, moving one an earlier version wrote to `.claude/coddy.yml` to `.coddy.yml`, after backing it up under `.claude/coddy/backup/` |
| `/coddy:next` | Recommends the next issue from the tracker and the roadmap, setting aside issues in progress, assigned to someone else, or claimed on this machine |
| `/coddy:start <issue> [onto <base-issue>]` | Fetches the issue, claims it, moves it to In Progress and gives it its own worktree in `.worktrees/<issue>`. Then reads beyond the ticket, thinks the work through with you, and asks for one approval of the plan with its difficulty tier. On a yes it implements on that tier's model, hardens the result twice, and loops code and security review until nothing at `review_block` or above is left (at most `review_rounds` rounds). Run it again to resume. Name a PR or branch, or let the issue's open PR be found: that branch instead. `onto` starts from another issue's branch instead of the default branch |
| `/coddy:ship [issue]` | Runs `verify` in the issue's worktree, commits, pushes, opens the PR and links it back to the issue. Started `onto` another issue: the PR targets that issue's branch, so it shows only its own diff |
| `/coddy:triage` | Turns findings into issues, skipping ones already open |

Each skill also triggers from plain language ("start issue 42", "what's
next?", "ship it"); the slash command is optional.

In Progress is the `in progress` label on GitHub and the workflow status on
Jira. It ends when `/coddy:ship` has the PR open: the label comes off, and
Jira moves to In Review.

Once a PR has merged, the next `/coddy:next` or `/coddy:start` removes that
issue's worktree, claim and local branch. A worktree that still holds work
not in the PR, or that another running session holds, is kept and reported.
Merge, squash and rebase merges are all seen; one whose conflicts were
resolved on the way in is not, so remove that worktree by hand.

## How it enforces

Six layers. The first three are Claude Code hooks, live in every onboarded
project; the fourth is a pair of git hooks that `/coddy:start` installs.

**Edit guard.** A hook rejects every file edit Claude attempts outside
`.worktrees/<issue>/`. Inside, it rejects edits until `/coddy:start` has
claimed that issue. `.claude/` stays editable, except Claude Code's own
worktrees under it. An edit of `.coddy.yml` asks you first. The hook needs
`jq`, and blocks every edit without it.

A claim belongs to the session that made it. Only that session may edit or
push the worktree. Another session starting the same issue is refused and
told how to take it over; `/coddy:start` does so only when you say so. A
claim is also refused on an issue the tracker shows assigned to someone
else, or in progress and not to you. A session that is no longer running is
taken over on its own.

`guard: warn` turns the rejection into a notice. The edit goes through, and
Claude is told it landed outside a claimed worktree, or in one another
session claimed, and which command to run. The other layers do not read the
key.

**Shell tripwire.** Shell commands cannot be checked in advance. So a second
hook compares the main checkout before and after each one, and tells Claude
to undo any change it left there.

**Config lock.** `.coddy.yml` is the off switch for all of this. A shell
command from Claude that removes or rewrites it is undone, and so is one
that creates it next to a config still at `.claude/coddy.yml`, which it
would shadow; `/coddy:config` asks you first, by whatever path the edit
reaches the file, a symlink from a worktree included. A change that came
through git, a pull of a shared config or a checkout, is undone too, since
nothing on disk tells it from one a command forged: the message sends Claude
to `/coddy:config`, which shows you the diff against `HEAD` and writes it
only when you say so.

**Git hooks.** `/coddy:start` points git's `core.hooksPath` at
`.git/coddy/hooks/`. Its `pre-commit` and `pre-push` refuse a commit on the
default branch, or a push to it, and on any branch no claimed issue owns,
whichever session claimed it. They refuse people too. A commit on a detached
`HEAD`, a tag, and deleting a branch other than the default one go through.
Once the check passes, the hook `core.hooksPath` named before runs, or the
one in `.git/hooks/`. Every other hook that directory holds, a `commit-msg`
say, gets a pass-through to it, so pointing `core.hooksPath` elsewhere turns
none of them off. A hook that cannot find coddy refuses and says how to get
past it: `/coddy:start <issue>`, which rewrites them, `--no-verify`, or the
command that puts the old `core.hooksPath` back. Their ceilings:

- `git commit --no-verify` and `git push --no-verify` skip them, and
  `git -c core.hooksPath=` runs without them.
- jj runs no git hooks.
- A tool that sets `core.hooksPath` itself, such as a hook manager's
  install, turns them off until the next `/coddy:start`.
- A tool that installs into git's hooks directory (lefthook,
  `git lfs install`, simple-git-hooks) writes into `.git/coddy/hooks/` once
  `/coddy:start` has run, and can replace coddy's own. `/coddy:start` then
  stops on any file there it did not write, and names the old hooks
  directory to move it to; it never deletes or overwrites one.
- The hooks run coddy by the path `/coddy:start` ran it from, the plugin's
  versioned directory. Claude Code deletes an old version's directory 14
  days after an update, and from then a terminal without `coddy` on `PATH`
  has every commit and push refused until the next `/coddy:start`.
- The pass-throughs are written when `/coddy:start` runs: a hook added to
  the old directory after that runs from the next `/coddy:start`.
- `core.hooksPath` is an absolute path, so moving or renaming the checkout
  turns every hook off, the old ones included, until the next `/coddy:start`.
- `/coddy:start` stops when a `core.hooksPath` set where it overrides
  `.git/config` (the worktree's own config, an include, an `includeIf` on
  the issue's branch, `GIT_CONFIG_*`) would keep them off, at the root or in
  the issue's worktree; `git config --show-origin core.hooksPath` there
  finds it.
- Claude Code's sandbox blocks writes to `.git/config` by default, so the
  first `/coddy:start` in a repository stops there. Set
  `sandbox.filesystem.allowGitConfig: true`, or run that `start` once
  outside the sandbox: later runs do not write `core.hooksPath`.
- A merge, cherry-pick or revert runs no `pre-commit`; the push catches it.

**Branch protection.** The backstop for a command that edits, commits and
pushes to the default branch in one go. Nothing in coddy can set it.
`/coddy:onboard` asks whether the branch already requires a pull request and
tells you what to set by hand.

**PR check.** A GitHub Action, `templates/coddy.yml`, fails a pull request
unless it closes an open, assigned issue (`Closes #<n>` in the description).
Open and assigned is what holds from `/coddy:start` to the merge.
The `in progress` label comes off when the PR opens, and the check runs
again on every push. It is keyed on the closing reference, not the branch
name. So it is the one layer that holds for a cloud agent, or for any
branch coddy did not name. `/coddy:onboard` writes it to
`.github/workflows/coddy.yml` on a GitHub tracker, backing up a differing
copy under `.claude/coddy/backup/`; commit it yourself. Its ceilings:

- GitHub Issues only. A Jira project gets the local guardrails alone:
  `/coddy:onboard` does not write the check, and a copied one fails every
  Jira PR, which carries no closing reference.
- GitHub computes the references only on a PR against the default branch.
  On a PR stacked on another branch, the check reads the closing keywords
  in the description itself. A link made only in the sidebar is not seen.
- It blocks a merge only once `closes a claimed issue` is a required check
  on the default branch, which you add by hand.

## Config

`.coddy.yml` at the project root, written by `/coddy:onboard` and changed
by `/coddy:config`:

```yaml
version: 2                   # schema version; set by /coddy:onboard and /coddy:migrate
tracker: github              # github | jira
repo: owner/name             # github only
# jira:                      # jira only, in place of repo
#   site: https://acme.atlassian.net
#   project: KEY
worktree: git                # git (default) | jj
default_branch: main
branch: "{type}/{issue}-{slug}"
commit: "{type}({issue}): {summary}"
verify: "make check"         # must exit 0 before /coddy:ship opens the PR
roadmap: docs/ROADMAP.md     # optional; /coddy:next reads it
guard: block                 # optional; block (default) | warn
tiers:                       # model per difficulty, per agent; start picks one per issue
  claude: {low: haiku, medium: sonnet, high: opus}
review_block: high           # optional; critical | high | medium | low (default high)
review_rounds: 3             # optional; 1-5 (default 3)
```

- `worktree` picks what creates each issue's worktree: `git` (`git worktree
  add`, the default, also when the key is absent at version 2) or `jj` (`jj
  workspace add`, colocating the repo on first use). Below version 2 an
  absent key means `jj`, and `/coddy:migrate` writes it in.
  `/coddy:config` refuses to switch it while an issue worktree exists.
- `guard: warn` is described under the edit guard above. `/coddy:onboard`
  leaves the key out; set it with `/coddy:config guard=warn`.
- `.claude/coddy.yml`, where earlier versions kept the config, is still read
  while `.coddy.yml` is absent; `/coddy:migrate` moves it. A config without
  `version` is version 0; `/coddy:migrate` brings it up to date.
- Delete the file yourself to leave the workflow (`.git/coddy`, where claims
  keep their records, can go with it). Every other skill
  refuses to run without the file.

## Related projects

coddy is the guard that holds while a person or an agent works on one issue.
It is not a board, a planner or a factory, and it pairs with tools that are:

- [super-board](https://github.com/EricTechPro/super-board) drains a GitHub
  Projects board unattended: cards run through build, QA and review lanes and
  merge when green. coddy keeps a person in the merge and holds an interactive
  session to its claimed worktree, which a factory's lanes do not police; the
  two can run on the same repository, a lane calling `/coddy:start` and
  `/coddy:ship` under the hood.
- [Vibe Kanban](https://www.vibekanban.com/) and
  [CCPM](https://github.com/automazeio/ccpm) launch and coordinate several
  agents at once. coddy does not launch anything; it makes whatever runs in
  parallel unable to step on another issue's worktree.
- Cross-agent guardrail tools such as [chock](https://github.com/open-coder-ai/chock)
  block dangerous commands and files across agents. coddy's rules are about
  the workflow (claim, worktree, PR), not about which commands are dangerous.

## Contributing

- Pick an open [issue](https://github.com/mnsami/coddy/issues) and work it
  through coddy itself: `/coddy:start <issue>`, then `/coddy:ship`. The
  config is personal, so run `/coddy:onboard` in your clone first; `verify`
  is the three commands under [Develop](#develop).
- Commits are `type: summary` (`feat`, `fix`, `chore`).
- The PR must close its issue (`Closes #<n>`).
- Before opening it, `bash scripts/selftest.sh`, `bash scripts/selftest-core.sh`
  and `claude plugin validate .` pass; `/coddy:ship` runs them as `verify`.
- Releases are a version bump of `.claude-plugin/plugin.json` through a PR of
  its own, never a direct commit to `main`. The marketplace installs from
  `main`, and an installed copy changes only after a bump.
- Brand assets and their uses are listed in [`assets/README.md`](assets/README.md).

## Develop

```bash
bash scripts/selftest.sh                 # the Claude Code shims end to end, in a throwaway repo
bash scripts/selftest-core.sh            # bin/coddy on its own inputs, with no CLAUDE_* set
claude plugin validate .                 # manifest and skill frontmatter
claude --plugin-dir . -p "/coddy:next"   # run one skill headless against the working copy
```

A headless run needs `--allowedTools` only for what a skill's `allowed-tools` does not mirror: the edit tools and `Agent`, plus `Skill(coddy:<name>)` for a plain-language trigger in `-p`.
