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

```bash
claude plugin marketplace add mnsami/coddy   # or a local path to this repo
claude plugin install coddy@coddy
```

You also need:

- `jq`. The edit guard needs it and blocks every edit without it.
- `jj` ([Jujutsu](https://jj-vcs.github.io)), unless you pick `worktree: git`
  at onboarding.
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
needs the Claude Code CLI. To run it from your own terminal or another
agent, put that directory on your `PATH` or symlink `bin/coddy` into one.
It reads `CODDY_ROOT` (where to look for the project; the working directory
without it), `CODDY_SESSION` and `CODDY_PID` (the session and process a
claim is held to) and `CODDY_AGENT_DIR` (the agent's own directory, such as
`.claude`, free to edit); Claude Code's hooks and skills set those from its
own environment.

## Onboard a project

Run `/coddy:onboard` inside the project. It detects what it can, asks for
the rest, and writes `.coddy.yml` (see [Config](#config)). It also
offers to copy the PR check workflow into the project, and tells you what to
set by hand so the default branch requires a pull request.

## Skills

The lifecycle is `next → start (think, implement, harden, review) → ship → merge`.
The next `next` or `start` sweeps up what the merge left behind.

| Skill | What it does |
|---|---|
| `/coddy:onboard` | Detects the project, asks for what it can't infer, writes `.coddy.yml` |
| `/coddy:config [key=value ...]` | Shows `.coddy.yml`, or changes the keys you name; offers to move a config an earlier version wrote to `.claude/coddy.yml` |
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

Five layers. The first three are hooks, live in every onboarded project.

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
branch coddy did not name. `/coddy:onboard` offers to copy it to
`.github/workflows/coddy.yml`, or copy the file yourself. Its ceilings:

- GitHub Issues only. A Jira project gets the local guardrails alone:
  `/coddy:onboard` does not offer the check, and a copied one fails every
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
tracker: github              # github | jira
repo: owner/name             # github only
# jira:                      # jira only, in place of repo
#   site: https://acme.atlassian.net
#   project: KEY
worktree: jj                 # jj (default) | git
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

- `worktree` picks what creates each issue's worktree: `jj` (`jj workspace
  add`, colocating the repo on first use) or `git` (`git worktree add`).
  `/coddy:config` refuses to switch it while an issue worktree exists.
- `guard: warn` is described under the edit guard above. `/coddy:onboard`
  leaves the key out; set it with `/coddy:config guard=warn`.
- `.claude/coddy.yml`, where earlier versions kept the config, is still read
  while `.coddy.yml` is absent; `/coddy:config` offers to move it.
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
