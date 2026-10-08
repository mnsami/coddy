# coddy

Issue-driven development workflow for Claude Code. The tracker holds the
state; the plugin holds the habits.

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
  ⎿  in progress: 42
⏺ #42 is In Progress in .worktrees/42. Run /coddy:ship when done.

> now add it

⏺ Update(.worktrees/42/README.md)
  ⎿  Updated .worktrees/42/README.md with 7 additions
```

The first edit is rejected and the same edit goes through once `/coddy:start`
has claimed the issue and given it a worktree: a hook enforces it, not the
prompt.

| Skill | What it does |
|---|---|
| `/coddy:onboard` | Detects the project, asks for what it can't infer, writes `.claude/coddy.yml` |
| `/coddy:config [key=value ...]` | Shows `.claude/coddy.yml`, or changes the keys you name |
| `/coddy:start <issue> [onto <base-issue>]` | Fetches the issue, restates acceptance criteria, claims it, moves it to In Progress, gives it its own worktree (`.worktrees/<issue>`) on a new branch, or on the existing one when you name a PR or branch or the issue already has an open PR. `onto` starts the branch from another issue's branch instead of the default branch |
| `/coddy:ship [issue]` | Runs `verify` in the issue's worktree, commits, pushes, opens the PR (against the base issue's branch when started `onto` one, so it shows only its own diff), links it back to the issue |
| `/coddy:triage` | Turns findings into issues, skipping ones already open |
| `/coddy:next` | Recommends the next issue from the tracker and the roadmap, setting aside issues in progress, assigned to someone else, or claimed on this machine |

Each skill also triggers from plain language ("start issue 42", "what's
next?", "ship it"); the slash command is optional.

Trackers: GitHub Issues (GitHub MCP plugin) and Jira (Atlassian MCP plugin). In Progress
is the `in progress` label on GitHub and the workflow status on Jira. It ends
when `/coddy:ship` has the PR open: the label comes off on GitHub, and Jira
moves to In Review.

Once a PR has merged, the next `/coddy:next` or `/coddy:start` removes that
issue's worktree, claim and local branch. A worktree that still holds work
that is not in the PR, or that another running session still holds, is kept
and reported.

## Guardrails

In an onboarded project a hook rejects every file edit Claude attempts
outside `.worktrees/<issue>/`, and inside it until `/coddy:start` has moved
that issue to In Progress. So each issue is worked on its own branch, in its
own worktree, with the tracker already updated. `.claude/` stays editable.
The hook needs `jq`. A claim belongs to the session that made it: only it
may edit or push the worktree, another session starting the same issue
is refused and told how to take it over (`claim <issue> --take`, which
`/coddy:start` runs only when you say so), and so is a claim on an issue the
tracker shows assigned to someone else, or in progress and not to you; a
session that is no longer running is taken over on its own.

Shell commands cannot be checked in advance, so a second hook compares the
main checkout before and after each one and tells Claude to undo any change
it left there. `/coddy:onboard` also offers to require a pull request on the
default branch, which is the backstop for a command that commits and pushes
in one go.

## PR check

A GitHub Action, `templates/coddy.yml`, fails a pull request unless it
closes an issue (`Closes #<n>` in the description) that is open and has an
assignee. Open and assigned is what holds from `/coddy:start` to the merge;
the `in progress` label comes off as soon as the PR opens, and the check
runs again on every push. It is keyed on the closing reference, not the
branch name, so it is the one layer that holds for a cloud agent, or for
any branch coddy did not name. GitHub Issues only: a Jira PR carries no
closing reference and would fail it. GitHub computes the references only
on a PR against the repository's default branch; on a PR stacked on
another branch the check reads the closing keywords in the description
itself, so there the keyword is what counts and a link made only in the
sidebar is not seen. `/coddy:onboard`
offers to copy it to `.github/workflows/coddy.yml`, or copy the file
yourself; it blocks a merge only once `closes a claimed issue` is a required
check under the default branch's protection rule, which you add by hand.

## Install

```bash
claude plugin marketplace add mnsami/coddy   # or a local path to this repo
claude plugin install coddy@coddy
```

The `github` tracker is reached through the GitHub plugin's MCP tools, so
enable that plugin with a token that can read and write the repository's
issues and pull requests; the `jira` tracker through the Atlassian plugin.
Neither needs a CLI. The PR check workflow alone runs `gh`, inside GitHub
Actions, where it is built in.

## Onboard a project

Run `/coddy:onboard` inside the project. It writes `.claude/coddy.yml`:

```yaml
tracker: github
repo: owner/name
worktree: jj                 # jj (default) | git
default_branch: main
branch: "{type}/{issue}-{slug}"
commit: "{type}({issue}): {summary}"
verify: "make check"
roadmap: docs/ROADMAP.md
guard: block                 # block (default) | warn
```

`worktree` picks what creates each issue's worktree: `jj` (`jj workspace
add`, colocating the repo on first use) or `git` (`git worktree add`).

`guard: warn` turns the edit hook from a rejection into a notice: the edit
goes through, and Claude is told it landed outside a claimed worktree, or
in one another session claimed, and which command to run. The shell hook
and the config lock are the same in both modes. `/coddy:onboard` leaves
the key out; set it with `/coddy:config guard=warn`.

Delete the file yourself to leave the workflow; a shell command from Claude
that removes or rewrites it is undone, and `/coddy:config` asks you first. Every other skill refuses to run
without it.

## Develop

```bash
bash scripts/selftest.sh
claude plugin validate .
claude --plugin-dir . -p "/coddy:next"
```
