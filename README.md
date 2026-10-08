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

## Onboard a project

Run `/coddy:onboard` inside the project. It detects what it can, asks for
the rest, and writes `.claude/coddy.yml` (see [Config](#config)). It also
offers to copy the PR check workflow into the project, and tells you what to
set by hand so the default branch requires a pull request.

## Skills

The lifecycle is `next → start → edit in .worktrees/<issue> → ship → merge`.
The next `next` or `start` sweeps up what the merge left behind.

| Skill | What it does |
|---|---|
| `/coddy:onboard` | Detects the project, asks for what it can't infer, writes `.claude/coddy.yml` |
| `/coddy:config [key=value ...]` | Shows `.claude/coddy.yml`, or changes the keys you name |
| `/coddy:next` | Recommends the next issue from the tracker and the roadmap, setting aside issues in progress, assigned to someone else, or claimed on this machine |
| `/coddy:start <issue> [onto <base-issue>]` | Fetches the issue, restates its acceptance criteria, claims it, moves it to In Progress and gives it its own worktree in `.worktrees/<issue>` on a new branch. Name a PR or branch, or let the issue's open PR be found: that branch instead. `onto` starts from another issue's branch instead of the default branch |
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
A squash or rebase merge is not seen; remove that worktree by hand.

## How it enforces

Five layers. The first three are hooks, live in every onboarded project.

**Edit guard.** A hook rejects every file edit Claude attempts outside
`.worktrees/<issue>/`. Inside, it rejects edits until `/coddy:start` has
claimed that issue. `.claude/` stays editable, except Claude Code's own
worktrees under it. The hook needs `jq`.

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

**Config lock.** `.claude/coddy.yml` is the off switch for all of this. A
shell command from Claude that removes or rewrites it is undone, and
`/coddy:config` asks you first. A change that arrives through git, such as a
pull of a shared config, stands.

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

- GitHub Issues only. A Jira PR carries no closing reference and fails it.
- GitHub computes the references only on a PR against the default branch.
  On a PR stacked on another branch, the check reads the closing keywords
  in the description itself. A link made only in the sidebar is not seen.
- It blocks a merge only once `closes a claimed issue` is a required check
  on the default branch, which you add by hand.

## Config

`.claude/coddy.yml`, written by `/coddy:onboard` and changed by
`/coddy:config`:

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
```

- `worktree` picks what creates each issue's worktree: `jj` (`jj workspace
  add`, colocating the repo on first use) or `git` (`git worktree add`).
  `/coddy:config` refuses to switch it while an issue worktree exists.
- `guard: warn` is described under the edit guard above. `/coddy:onboard`
  leaves the key out; set it with `/coddy:config guard=warn`.
- Delete the file yourself to leave the workflow. Every other skill refuses
  to run without it.

## Contributing

- Pick an open [issue](https://github.com/mnsami/coddy/issues) and work it
  through coddy itself: `/coddy:start <issue>`, then `/coddy:ship`. The
  config is personal, so run `/coddy:onboard` in your clone first; `verify`
  is the two commands under [Develop](#develop).
- Commits are `type: summary` (`feat`, `fix`, `chore`).
- The PR must close its issue (`Closes #<n>`).
- Before opening it, `bash scripts/selftest.sh` and `claude plugin validate .`
  pass; `/coddy:ship` runs them as `verify`.
- Releases are a version bump of `.claude-plugin/plugin.json` through a PR of
  its own, never a direct commit to `main`. The marketplace installs from
  `main`, and an installed copy changes only after a bump.
- Brand assets and their uses are listed in [`assets/README.md`](assets/README.md).

## Develop

```bash
bash scripts/selftest.sh                 # the scripts end to end, in a throwaway repo
claude plugin validate .                 # manifest and skill frontmatter
claude --plugin-dir . -p "/coddy:next"   # run one skill headless against the working copy
```
