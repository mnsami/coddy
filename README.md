<p align="center">
  <img src="assets/coddy.svg" alt="Hermit, the coddy mascot: a hermit crab in its shell" width="160">
</p>

# coddy

[![CI](https://github.com/mnsami/coddy/actions/workflows/ci.yml/badge.svg)
](https://github.com/mnsami/coddy/actions/workflows/ci.yml)

coddy is an issue-driven workflow for Claude Code. Every change Claude makes is tied to a claimed issue,
lives in its own worktree and lands through a pull request. The tracker holds the state. The plugin holds the habits.

- Hooks stop the common slips, and report many shell writes after they happen.
- They are not a sandbox. Against an agent set on getting round them, the hard stops are
  [branch protection and the required PR check](#how-it-enforces), which you set by hand.
- The flow: `/coddy:onboard` → `/coddy:next` → `/coddy:start <issue>` → `/coddy:ship`.

```text
> add a Develop section to the README

⏺ Update(README.md)
  ⎿  PreToolUse:Edit hook error: [bash "…/coddy/scripts/issue.sh" guard]:
     coddy: edits belong in an issue worktree, not the main checkout.
     Run /coddy:start <issue>, then edit under .worktrees/<issue>/.

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

The first edit is rejected. It goes through once `/coddy:start` has claimed the issue. A hook enforces that.

## Install

```bash
claude plugin marketplace add mnsami/coddy   # or a local path to this repo
claude plugin install coddy@coddy
```

For another agent (Codex, Cursor, Copilot CLI, Gemini CLI or Antigravity CLI) or your own terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/mnsami/coddy/main/get.sh | bash
```

- It clones `main` into `~/.coddy` (a rerun fast-forwards it) and links `coddy` into `~/.local/bin`.
  Your agent reads the skills from `~/.coddy/skills/`, starting with `onboard/SKILL.md`. The plugin does not use it.
- `coddy doctor` says which install a `coddy` runs from. In a project it lists what is missing or off, with fixes.
  It exits 1 on any problem and changes nothing.

coddy runs on macOS, Linux and WSL, in the Claude Code CLI. claude.ai and Cowork do not install a plugin with a
top-level `bin/`. Native Windows is not supported: [disable the plugin there](docs/enforcement.md#native-windows).

You need:

- bash 3.2 or later, and `git`. The hooks find them [on `PATH`, outside the project](docs/enforcement.md#bash-and-path).
- `jq`. The edit guard refuses every edit without a working one.
- `jj` ([Jujutsu](https://jj-vcs.github.io)), only for `worktree: jj`. The default, `worktree: git`, needs nothing more.
  `/coddy:onboard` installs a missing `jq` or `jj` through a shell command you allow.
  Declining `jq` stops it. `jj` has no apt-get package, so there it names the install page.
- For GitHub, GitLab or Jira: that tracker's plugin, enabled and signed in. Trackers are reached through
  its MCP tools, so none needs a CLI. The GitHub PR check runs `gh` and the GitLab job `curl`, inside their CI.
- GitLab: as shipped, the plugin reaches gitlab.com only. A self-managed instance needs an MCP server
  configured for that instance, whose tools the skills' `allowed-tools` do not pre-approve, so its calls prompt.
  The config names no host.

## Quick start

Run these inside your project. Each skill also starts from plain language ("start issue 42", "ship it").

1. `/coddy:onboard`: a seven-step wizard that writes `.coddy.yml`. Run it once per project.
   It assumes one remote, `origin`, which you need write access to, and write or triage access to the tracker's
   repository. Forks are not supported yet (#280). It saves your answers, so a run that stops resumes.
   On your yes it writes the PR check workflow, a block in `AGENTS.md` and `.coddy.yml`.
2. `/coddy:next`: recommends an issue to work on.
3. `/coddy:start <issue>`: claims the issue, gives it a worktree, then plans, implements and reviews it with you.
4. `/coddy:ship`: runs `verify`, pushes and opens the PR. Merge it, and the next skill you run cleans up.

## Skills

- `/coddy:config [key=value ...]` shows `.coddy.yml` or changes the keys you name.
  `/coddy:migrate` brings it up to the current `version`, and moves `.claude/coddy.yml` to `.coddy.yml`.
- `/coddy:next`: recommends the next issue, skipping ones in progress, assigned to others or claimed here.
- `/coddy:start <issue> [onto <base-issue>]`: claims the issue, moves it to In Progress and makes `.worktrees/<issue>`.
  After one plan approval it implements, hardens twice and reviews. Run it again to resume.
  `onto` starts from another issue's branch.
- `/coddy:ship [issue]`: runs `verify`, commits, pushes and opens the PR. Under `onto` the PR targets that branch.
- `/coddy:drop <issue>`: gives a claimed issue up and keeps its branch.
- `/coddy:refresh`: after a merge, brings the other claimed worktrees up to date with the default branch.
- `/coddy:triage`: turns findings into issues, skipping ones already open.

In Progress is the `in progress` label on GitHub and GitLab, and the workflow status on Jira.
It ends when `/coddy:ship` has the PR open: the label comes off, and Jira moves to In Review.
After a merge, the next `/coddy:next` or `/coddy:start` removes the issue's worktree, claim and local branch.
[What each of these keeps, skips or moves](docs/enforcement.md#sweep-drop-and-refresh).

## Confidential issues

A confidential GitLab issue, or a Jira ticket with a security level, is hidden. Its branch, commits and PR are not.
So `/coddy:start` first proposes a cover, written without the issue's words: the branch name, one commit subject
(used for every commit and as the PR title), one line of description and a list of what goes public.
Nothing is created until you approve it, and `/coddy:ship` stops on such an issue that has none.
A GitLab internal note or a Jira comment restricted to a group or role is never quoted in public text.
The plan and questions `/coddy:start` posts on that issue are internal too.
Its ceilings:

- The diff itself is public once pushed: the cover hides the issue's words, not the change.
- Ideas `/coddy:triage` files from that work are not covered: it files them as issues that are not confidential.

## How it enforces

[docs/enforcement.md](docs/enforcement.md) has one section per layer: what it stops, lets through and misses.

- **Edit guard.** Rejects Claude's file edits outside `.worktrees/<issue>/`, and inside it before the issue is claimed.
  A claim belongs to one session, but a shell command can still write to the lock.
  The assigned-to-someone-else check is a step of `/coddy:start`. The lock never reads the tracker.
- **Shell tripwire.** Compares the main checkout before and after each shell command and reports what changed.
  Its text check refuses a new worktree or a push to the default branch.
  A `bash -c`, `eval`, a git alias or `sudo` hides a command from that check.
  It reads a `jj git push` before it runs, and jj runs no git hooks, so jj coverage is partial.
- **Config lock.** Undoes a shell command that removes or rewrites `.coddy.yml`, the switch for all of this.
- **Git hooks.** `/coddy:start` installs a `pre-commit` and a `pre-push` that refuse the default branch
  and any branch no claimed issue owns. `--no-verify` skips them.
- **Branch protection.** You set it. A hard stop for a command that edits, commits and pushes in one go.
- **PR check.** A GitHub Action, or a GitLab job, that fails a PR unless it closes an open, assigned issue.
  You require it. It holds for a cloud agent, or for a branch coddy did not name.

If the hooks keep refusing, there are [three ways out](docs/enforcement.md#three-ways-out): your own terminal,
`claude plugin disable coddy@coddy`, or `claude --settings '{"disableAllHooks": true}'`.

## Config

`.coddy.yml` at the project root, written by `/coddy:onboard` and changed by `/coddy:config`:

```yaml
version: 2                   # schema version; set by /coddy:onboard and /coddy:migrate
tracker: github              # github | jira | gitlab
repo: owner/name             # github: owner/name; gitlab: the full project path, group/subgroup/project
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

- `worktree` is `git` (`git worktree add`, the default) or `jj` (`jj workspace add`, colocating the repo on first use).
  Below version 2, an absent key means `jj`. `/coddy:config` refuses to switch it while an issue worktree exists.
- `guard: warn` turns the edit guard's rejections into [notices](docs/enforcement.md#guard-warn).
  `/coddy:onboard` leaves the key out. Set it with `/coddy:config guard=warn`.
- A config at `.claude/coddy.yml`, or one without `version`, is still read. `/coddy:migrate` updates it.
  Every other skill refuses to run without the file.
- To leave the workflow, [follow these steps](docs/enforcement.md#leaving-the-workflow) from your own terminal.

## Related projects

coddy guards one issue at a time. It is not a board or a factory.
- [super-board](https://github.com/EricTechPro/super-board) drains a GitHub Projects board unattended.
  A lane can call `/coddy:start` and `/coddy:ship`.
- [Vibe Kanban](https://www.vibekanban.com/) and [CCPM](https://github.com/automazeio/ccpm) launch several agents.
  coddy launches none. It keeps what runs in parallel off another issue's worktree.

## Contributing

- Collaborators: pick an open [issue](https://github.com/mnsami/coddy/issues) and work it through coddy itself.
  Outside contributors open a PR by hand with `Closes #<n>`.
- Commits are `type: summary` (`feat`, `fix`, `chore`). The PR must close its issue (`Closes #<n>`).
  Before opening it, the first three commands under [Develop](#develop) pass.
- A release is a version bump of `.claude-plugin/plugin.json` through a PR of its own, never a direct commit to `main`.
- PRs merge with a merge commit, never squash or rebase. Stacked PRs need their base's commits intact.
- Brand assets are listed in [`assets/README.md`](assets/README.md).

## Develop

```bash
bash scripts/selftest.sh                 # the Claude Code shims end to end, in a throwaway repo
bash scripts/selftest-core.sh            # bin/coddy on its own inputs, with no CLAUDE_* set
claude plugin validate .                 # manifest and skill frontmatter
claude --plugin-dir . -p "/coddy:next"   # run one skill headless against the working copy
```

A headless run needs `--allowedTools` for the edit tools and `Agent`, and `Skill(coddy:<name>)` for a plain trigger.
