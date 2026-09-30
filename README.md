# coddy

Issue-driven development workflow for Claude Code. The tracker holds the
state; the plugin holds the habits.

| Skill | What it does |
|---|---|
| `/coddy:onboard` | Detects the project, asks for what it can't infer, writes `.claude/coddy.yml` |
| `/coddy:start <issue>` | Fetches the issue, restates acceptance criteria, claims it, creates the branch |
| `/coddy:ship` | Runs `verify`, commits, pushes, opens the PR, links it back to the issue |
| `/coddy:triage` | Turns findings into issues, skipping ones already open |
| `/coddy:next` | Recommends the next issue from the tracker and the roadmap |

Trackers: GitHub Issues (`gh`) and Jira (Atlassian MCP plugin).

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
vcs: git
default_branch: main
branch: "{type}/{issue}-{slug}"
commit: "{type}({issue}): {summary}"
verify: "make check"
roadmap: docs/ROADMAP.md
```

Delete the file to leave the workflow. Every other skill refuses to run
without it.

## Develop

```bash
claude plugin validate .
claude --plugin-dir . -p "/coddy:next"
```
