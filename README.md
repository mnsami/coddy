<p align="center">
  <img src="assets/hermy.svg" alt="Hermit, the hermy mascot: a hermit crab in its shell" width="160">
</p>

# hermy

Formerly coddy; not affiliated with Coddy Agent (coddy.dev) or Coddy, Inc. (coddy.tech).

[![CI](https://github.com/mnsami/hermy/actions/workflows/ci.yml/badge.svg)
](https://github.com/mnsami/hermy/actions/workflows/ci.yml) [![release][rb]][r]

[r]: https://github.com/mnsami/hermy/commits/main/.claude-plugin/plugin.json
[rb]: https://img.shields.io/github/package-json/v/mnsami/hermy?filename=.claude-plugin%2Fplugin.json&label=release
hermy is an issue-driven workflow for Claude Code. Every change Claude makes is tied to a claimed issue,
lives in its own worktree and lands through a pull request. The tracker holds the state. The plugin holds the habits.

- Hooks stop the common slips, and report many shell writes after they happen.
- They are not a sandbox. On GitHub and GitLab, two layers you set by hand ([branch protection and the required PR
  check](#how-it-enforces)) send every change to the default branch through a PR that closes an open, assigned issue,
  if [their settings](#how-it-enforces) are right. Jira has branch protection alone.
- Install: `claude plugin marketplace add mnsami/hermy`, then `claude plugin install hermy@hermy` ([more](#install)).
- The flow: `/hermy:onboard` → `/hermy:next` → `/hermy:start <issue>` → `/hermy:ship`.

```text
> add a Develop section to the README

⏺ Update(README.md)
  ⎿  PreToolUse:Edit hook error: [bash "…/hermy/scripts/issue.sh" guard]:
     hermy: edits belong in an issue worktree, not the main checkout.
     Run /hermy:start <issue>, then edit under .worktrees/<issue>/.

> /hermy:start 42

⏺ #42 is In Progress in .worktrees/42. Run /hermy:ship when done.
```

The edit in the main checkout is rejected. After `/hermy:start`, the same edit under `.worktrees/42/` goes through.

## Install

```bash
claude plugin marketplace add mnsami/hermy   # or a local path to this repo
claude plugin install hermy@hermy
```

For another agent (Codex, Cursor, Copilot CLI, Gemini CLI or Antigravity CLI) or your own terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/mnsami/hermy/main/get.sh | bash
```

- It clones the latest release (the newest `v*` tag on `main`) into `~/.hermy` and links `hermy` into `~/.local/bin`.
  A rerun moves it to the latest release, and stops on local changes to tracked files. `HERMY_REF=main` follows
  the tip of `main` instead, `HERMY_REF=<tag>` pins a release. Your agent reads `~/.hermy/skills/`, starting with `onboard/SKILL.md`.
  The plugin keeps its own copy.
- `hermy doctor` says which install runs. In a project it lists what is missing or off. It changes nothing.

hermy runs on macOS, Linux and WSL. As a plugin it needs the Claude Code CLI: claude.ai and Cowork do not
install a plugin with a top-level `bin/`. [Native Windows](docs/enforcement.md#native-windows) is not supported.

You need:
- bash 3.2 or later, and `git`. The hooks find them [on `PATH`, outside the project](docs/enforcement.md#bash-and-path).
- `jq`. The edit guard refuses every edit without a working one.
- `jj` ([Jujutsu](https://jj-vcs.github.io)), only for `worktree: jj`. The default, `worktree: git`, needs nothing more.
  `/hermy:onboard` installs a missing `jq` or `jj` through a shell command you allow. Declining `jq` stops it.
  `jj` has no apt-get package, so there it names the install page.
- For GitHub, GitLab or Jira: the GitHub, GitLab or Atlassian plugin, enabled and signed in.
  Its MCP tools reach the tracker, so none needs a CLI. The GitHub token must read and write issues and PRs.
  The PR check runs `gh` (GitHub) or `curl` (GitLab) inside CI.
- GitLab: as shipped, the plugin reaches gitlab.com only. A self-managed instance needs an MCP server
  configured for that instance, whose tools the skills' `allowed-tools` do not pre-approve, so its calls prompt.
  The config names no host.

## Quick start

Run these inside your project. Each skill also starts from plain language ("start issue 42", "ship it").
1. `/hermy:onboard`: a wizard that writes `.hermy.yml`. Run it once per project.
2. `/hermy:next`: recommends an issue to work on.
3. `/hermy:start <issue>`: claims the issue, gives it a worktree, then plans, implements and reviews it with you.
4. `/hermy:ship`: runs `verify`, pushes and opens the PR. Merge it. The next `/hermy:next` or `/hermy:start` cleans up.

```mermaid
flowchart TB
  A["/hermy:onboard<br/>writes .hermy.yml"] --> B["/hermy:next<br/>picks an issue"]
  B --> S
  subgraph S["/hermy:start 42, in .worktrees/42"]
    direction LR
    s1["claim it"] --> s2["plan:<br/>you approve"]
    s2 --> s3["implement,<br/>harden twice"] --> s4["code and<br/>security review"]
  end
  S --> D["/hermy:ship<br/>verify, push"]
  D --> E["PR that<br/>closes issue 42"]
  E --> F(["you merge"])
  F --> G[("main")]
  g1{{"edit guard · tripwire · config lock"}} -. "Claude Code hooks:<br/>stop the common slips" .-> S
  g2{{"git hooks"}} -. "refuse main and<br/>unclaimed branches" .-> D
  g3{{"PR check (you require it)"}} -. "must close an open,<br/>assigned issue" .-> E
  g4{{"branch protection (you set it)"}} -. "main only<br/>through a PR" .-> F
```

## Skills

| Skill | What it does |
|---|---|
| `/hermy:onboard` | Wizard that writes `.hermy.yml`, the PR check and an `AGENTS.md` block. Run once. |
| `/hermy:next` | Recommends the next issue, skipping ones in progress, assigned to others or claimed here. |
| `/hermy:start <issue>` | Claims it (In Progress), makes `.worktrees/<issue>`, plans with you, implements, reviews. |
| `/hermy:ship [issue]` | Runs `verify`, commits, pushes and opens the issue's PR. |
| `/hermy:drop <issue>` | Gives a claimed issue up and keeps its branch. |
| `/hermy:refresh` | After a merge, updates the other claimed worktrees from the default branch. |
| `/hermy:triage` | Turns findings into issues, skipping ones already open. |
| `/hermy:config [key=value]` | Shows `.hermy.yml` or changes the keys you name. |
| `/hermy:migrate` | Brings the config to the current `version`, moving `.coddy.yml` or `.claude/coddy.yml` to `.hermy.yml`. |

- `/hermy:onboard` is a seven-step wizard that saves your answers, so a run that stops resumes. It assumes one
  remote, `origin`, that you can write to, and write or triage access to the tracker's repository.
  Forks are not supported yet (#280). On GitLab it opens a merge request for the check. Jira gets none.
- `/hermy:start` reviews until nothing at `review_block` or above is left or `review_rounds` rounds have run,
  then hands the rest to you. Rerun it to resume. `onto <base-issue>` starts from that issue's branch.
- `/hermy:ship` commits tracked changes and only the untracked files you name. Any other untracked file stops it.
  Under `onto` the PR targets the base issue's branch.

In Progress is the `in progress` label (Jira: the workflow status). Opening the PR ends it (Jira: In Review).
After a merge, the next `/hermy:next` or `/hermy:start` removes the issue's worktree, claim and local branch
([what each keeps, skips or moves](docs/enforcement.md#sweep-drop-and-refresh)).

## Confidential issues

A confidential GitLab issue, or a Jira ticket with a security level, is hidden. Its branch, commits and PR are not.
So `/hermy:start` first proposes a cover, written without the issue's words: the branch name, one commit subject
(used for every commit and as the PR title), one line of description and a list of what goes public.
Nothing is created until you approve it, and `/hermy:ship` stops on such an issue that has none.
A GitLab internal note or a Jira comment restricted to a group or role is never quoted in public text.
The plan and questions `/hermy:start` posts on that issue are internal too. Ceilings:
- The diff itself is public once pushed: the cover hides the issue's words, not the change.
- Ideas `/hermy:triage` files from that work are not covered: it files them as issues that are not confidential.
- Commits already on a branch from before the cover keep their messages, which are public once pushed.

## How it enforces

[docs/enforcement.md](docs/enforcement.md) has one section per layer: what it stops, lets through and misses.
The edit guard, tripwire and config lock run as Claude Code hooks only, until another host's shim lands: the core
they run is host-neutral, and each host needs a shim mapping its hook payload in and the verdict out.
Another agent running the skills from `~/.hermy` gets only the git hooks, branch protection and the PR check.
- **Edit guard.** Rejects Claude's file edits in the project outside `.worktrees/<issue>/`, and inside it before
  the issue is claimed. `.claude/` stays editable, settings files too
  ([only Claude Code's prompt holds them](docs/enforcement-limits.md#settings-files)), except `.claude/worktrees/`.
  Files outside the project pass. A claim is a lock under `.git/hermy`, and a shell command can rewrite it.
  The assignee check is a `/hermy:start` step. `claim` never reads the tracker.
- **Shell tripwire.** Compares the main checkout before and after each shell command and reports what changed.
  A new worktree outside `.worktrees/` and `.claude/worktrees/` is reported after it is made.
  It does not read the command, so it refuses no push.
- **Config lock.** Undoes a shell command that removes or rewrites `.hermy.yml`, the switch for all of this.
- **Git hooks.** `/hermy:start` installs a `pre-commit` and a `pre-push` that refuse the default branch
  and any branch no claimed issue owns. `--no-verify` skips them, and jj runs none.
  A force push of a claimed branch passes. Its delete is not refused yet (#269).
- **Branch protection.** You set it. It holds when a command edits, commits and pushes in one go.
  With the `pre-push` hook it holds a push to the default branch. Under jj it holds it alone.
- **PR check.** A GitHub Action, or a GitLab job, that fails a PR unless it closes an open, assigned issue.
  You require it. It holds for a cloud agent, or a branch hermy did not name. Jira has none.

Branch protection and the PR check hold only with these ([details](docs/enforcement.md#what-the-hard-layers-need)):
- No token the agent can use may change repository settings. GitHub: no Administration write. GitLab: below Maintainer.
- A required approving review, with stale approvals dismissed on a new push. onboard asks for neither.
- A required code-owner review on every CI file, since a PR can edit the check's own workflow: `.github/workflows/`
  (GitLab: `.gitlab/`, `.gitlab-ci.yml` and every file it includes). GitLab needs Premium for it.
- A plan that offers them: a private GitHub repository needs Pro, Team or Enterprise. Without one, only hooks hold.

If the hooks keep refusing, see the [three ways out](docs/enforcement.md#three-ways-out).

## Config

`.hermy.yml` at the project root, written by `/hermy:onboard` and changed by `/hermy:config`:

```yaml
version: 2                   # schema version; set by /hermy:onboard and /hermy:migrate
tracker: github              # github | jira | gitlab
repo: owner/name             # github: owner/name; gitlab: the full project path, group/subgroup/project
# jira:                      # jira only, in place of repo
#   site: https://acme.atlassian.net
#   project: KEY
worktree: git                # git (default) | jj
default_branch: main
branch: "{type}/{issue}-{slug}"
commit: "{type}({issue}): {summary}"
verify: "make check"         # must exit 0 before /hermy:ship opens the PR
setup: "npm ci"              # optional; run once in each new issue worktree
roadmap: docs/ROADMAP.md     # optional; /hermy:next reads it
guard: block                 # optional; block (default) | warn
tiers:                       # model per difficulty, per agent; start picks one per issue
  claude: {low: haiku, medium: sonnet, high: opus}
review_block: high           # optional; critical | high | medium | low (default high)
review_rounds: 3             # optional; 1-5 (default 3)
```

- `worktree` is `git` (`git worktree add`, the default) or `jj` (`jj workspace add`, colocating the repo on first use).
  Below version 2, an absent key means `jj`. `/hermy:config` refuses to switch it while an issue worktree exists.
- `setup` runs once in each new issue worktree, with `HERMY_ISSUE` and `HERMY_PORT_OFFSET` (`(issue % 100) * 10`) set.
  Before it, the git-ignored files that the root's `.worktreeinclude` (gitignore syntax) names are copied in.
  A failing `setup` stops `start` and keeps the worktree.
- `guard: warn` turns the edit guard's rejections into [notices](docs/enforcement.md#guard-warn).
  Set it with `/hermy:config guard=warn`.
- A config without `version` is read as version 0. One at `.coddy.yml`, then `.claude/coddy.yml`, from before
  the rename, is read while `.hermy.yml` is absent. `/hermy:migrate` updates any of them.
  Every skill but `/hermy:onboard` refuses to run without one.
- To leave the workflow, [follow these steps](docs/enforcement.md#leaving-the-workflow) from your own terminal.

## Related projects

- [super-board](https://github.com/EricTechPro/super-board) drains a Projects board; a lane can run `/hermy:start`.
- [Vibe Kanban](https://www.vibekanban.com/) and [CCPM](https://github.com/automazeio/ccpm) launch several agents.
  hermy launches none. It keeps Claude's Edit and Write tools and `/hermy:ship`'s push off another session's claimed
  worktree. Shell commands are not held.
- [chock](https://github.com/open-coder-ai/chock) blocks dangerous commands. hermy covers the workflow.

## Contributing

- Collaborators: pick an open [issue](https://github.com/mnsami/hermy/issues) and work it through hermy itself.
  The config is personal: run `/hermy:onboard` in your clone first. Others open a PR by hand with `Closes #<n>`.
- Commits are `type: summary` (`feat`, `fix`, `chore`). The PR must close its issue (`Closes #<n>`).
  The first three commands under [Develop](#develop) pass before you open it.
- A release is a version bump of `.claude-plugin/plugin.json`, in a PR of its own; once it merges, CI tags it
  `v<version>` and creates its GitHub release. An installed copy changes only after a bump. PRs merge with a merge
  commit, never squash or rebase, so stacked PRs keep their base's commits.

## Develop

```bash
bash scripts/selftest.sh                 # the Claude Code shims end to end, in a throwaway repo
bash scripts/selftest-core.sh            # bin/hermy on its own inputs, with no CLAUDE_* set
claude plugin validate .                 # manifest and skill frontmatter
claude --plugin-dir . -p "/hermy:next"   # run one skill headless against the working copy
```

A headless run needs `--allowedTools` for the edit tools and `Agent`, and `Skill(hermy:<name>)` for a plain trigger.
