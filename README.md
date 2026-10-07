# coddy

Issue-driven development workflow for Claude Code. The tracker holds the
state; the plugin holds the habits.

| Skill | What it does |
|---|---|
| `/coddy:onboard` | Detects the project, asks for what it can't infer, writes `.claude/coddy.yml` |
| `/coddy:config [key=value ...]` | Shows `.claude/coddy.yml`, or changes the keys you name |
| `/coddy:start <issue>` | Fetches the issue, restates acceptance criteria, claims it, moves it to In Progress, gives it its own worktree (`.worktrees/<issue>`) on a new branch, or on the existing one when you name a PR or branch or the issue already has an open PR |
| `/coddy:ship [issue]` | Runs `verify` in the issue's worktree, commits, pushes, opens the PR, links it back to the issue |
| `/coddy:triage` | Turns findings into issues, skipping ones already open |
| `/coddy:next` | Recommends the next issue from the tracker and the roadmap |

Each skill also triggers from plain language ("start issue 42", "what's
next?", "ship it"); the slash command is optional.

Trackers: GitHub Issues (`gh`) and Jira (Atlassian MCP plugin). In Progress
is the `in progress` label on GitHub and the workflow status on Jira. It ends
when `/coddy:ship` has the PR open: the label comes off on GitHub, and Jira
moves to In Review.

Once a PR has merged, the next `/coddy:next` or `/coddy:start` removes that
issue's worktree, claim and local branch. A worktree that still holds work
that is not in the PR is kept and reported.

## Guardrails

In an onboarded project a hook rejects every file edit Claude attempts
outside `.worktrees/<issue>/`, and inside it until `/coddy:start` has moved
that issue to In Progress. So each issue is worked on its own branch, in its
own worktree, with the tracker already updated. `.claude/` stays editable.
The hook needs `jq`. A claim belongs to the session that made it: another
session starting the same issue is refused and told how to take it over
(`claim <issue> --take`, which `/coddy:start` runs only when you say so); a
session that is no longer running is taken over on its own.

Shell commands cannot be checked in advance, so a second hook compares the
main checkout before and after each one and tells Claude to undo any change
it left there. `/coddy:onboard` also offers to require a pull request on the
default branch, which is the backstop for a command that commits and pushes
in one go.

## Install

```bash
claude plugin marketplace add mnsami/coddy   # or a local path to this repo
claude plugin install coddy@coddy
```

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
goes through, and Claude is told it landed outside a claimed worktree and
which command to run. The shell hook and the config lock are the same in
both modes. `/coddy:onboard` leaves the key out; set it with
`/coddy:config guard=warn`.

Delete the file yourself to leave the workflow; a shell command from Claude
that removes or rewrites it is undone, and `/coddy:config` asks you first. Every other skill refuses to run
without it.

## Develop

```bash
bash scripts/selftest.sh
claude plugin validate .
claude --plugin-dir . -p "/coddy:next"
```
