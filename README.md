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
`onboard/SKILL.md`. `coddy doctor` says which install a `coddy` runs from and, inside a project, what is missing or off (config, tools, git hooks, `.git/worktrees`, PR check, `AGENTS.md`), each with its fix; it exits 1 on any problem and changes nothing.
The plugin keeps its own copy and does not use `~/.coddy`.

coddy runs on macOS, Linux and WSL. Native Windows (Git Bash, MSYS2,
Cygwin) is not supported: under Claude Code the hooks cannot start there,
which from Claude Code 2.1.295 on refuses every edit and shell command, so
disable the plugin there (before 2.1.295 nothing is guarded). Where the
edit guard does run (the core called another way) it refuses every edit.
`/coddy:onboard` stops and `coddy doctor` exits 1.

You also need:

- bash 3.2 or later. The hooks start under `/bin/sh` and run the first
  `bash` on Claude Code's `PATH` (on macOS that may be `/bin/bash`, 3.2),
  and find their tools there, past every entry that is empty, relative or
  inside the project, by its spelling, through a link there or where it
  lands, where a command could plant a `bash`, `git` or `jq`
  that would run outside the sandbox. So tools that live only in the project
  (`.venv/bin`, devbox, nix-shell) do not count: with no `bash` left every
  edit and shell command is refused, and with no `git` left, or no `jj` where
  the project holds a `.jj`, every shell command. `coddy doctor` prints which
  `bash` they run.
- `jq`. The edit guard needs it and blocks every edit without a working one.
- Optionally `jj` ([Jujutsu](https://jj-vcs.github.io)), for `worktree: jj`;
  `worktree: git`, the default, needs nothing more. `/coddy:onboard`
  installs either one that is missing (Homebrew, apt-get, dnf or winget)
  through a shell command you allow; `jj` has no apt-get package, so there
  it names the install page. Onboard recommends `worktree: git` either way.
- For GitHub Issues: the GitHub plugin, enabled and signed in with a token
  that can read and write the repository's issues and pull requests.
- For GitLab: the GitLab plugin, enabled and signed in. As shipped it
  reaches gitlab.com only. A self-managed instance needs an MCP server
  configured for that instance, whose tools the skills' `allowed-tools`
  do not pre-approve, so its calls prompt. The config names no host.
- For Jira: the Atlassian plugin.

Trackers are reached through those plugins' MCP tools. None needs a CLI.
The PR check workflow alone runs `gh`, inside GitHub Actions, where it is
built in; the GitLab job alone calls the API, with `curl`, inside its
pipeline.

A confidential GitLab issue, or a Jira ticket with a security level, is
hidden, while its branch, commits and pull request are not. So
`/coddy:start` first proposes a cover written without the issue's words:
the branch, one commit subject used for every commit and as the PR title,
and one line of description, with a list of what goes public once shipped.
Nothing is created until you approve it, and `/coddy:ship` stops on such an
issue that has none. A GitLab note marked internal, or a Jira comment
restricted to a group or role, is never quoted in public text, and the plan
and questions `/coddy:start` posts on that issue are internal too. Its
ceilings:

- The diff itself is public once pushed: the cover hides the issue's words,
  not the change.
- Ideas `/coddy:triage` files from that work are not covered: it files them
  as issues that are not confidential.

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
shell command you allow (declining `jq` stops it). The branch step
recommends `worktree: git` first, with `jj` offered after it. coddy assumes
a single remote, `origin`, and write or triage access to the tracker's
repository; forks are not supported yet (#280). Your answers are saved
under `.claude/coddy/`, so a run that stops resumes where it was. At review
it shows the config and, on your yes, writes the PR check workflow and the
coddy block into `AGENTS.md` (so an agent without the plugin reads the
rules), backing up any file it replaces under `.claude/coddy/backup/`, and
then `.coddy.yml` (see [Config](#config)). It tells you what to set by hand so the default branch
requires a pull request. A project that already has a config is sent to
`/coddy:migrate` when it is behind the current version, `/coddy:config`
otherwise.

## Skills

The lifecycle is `next → start (think, implement, harden, review) → ship → merge`,
or `drop` to give an issue up. The next `next` or `start` sweeps up what the
merge left behind.

| Skill | What it does |
|---|---|
| `/coddy:onboard` | A seven-step wizard: detects the project, installs `jq` and `jj` when you allow it, asks for what it can't infer (answers saved, so a re-run resumes), then writes the PR check workflow (on GitLab, opens a merge request that adds the check), the coddy block into `AGENTS.md` (backing up what it replaces) and `.coddy.yml` |
| `/coddy:config [key=value ...]` | Shows `.coddy.yml`, or changes the keys you name |
| `/coddy:migrate` | Brings the config up to the current `version`, moving one an earlier version wrote to `.claude/coddy.yml` to `.coddy.yml`, after backing it up under `.claude/coddy/backup/` |
| `/coddy:next` | Recommends the next issue from the tracker and the roadmap, setting aside issues in progress, assigned to someone else, or claimed on this machine |
| `/coddy:start <issue> [onto <base-issue>]` | Fetches the issue, claims it, moves it to In Progress and gives it its own worktree in `.worktrees/<issue>`. Then reads beyond the ticket, thinks the work through with you, and asks for one approval of the plan with its difficulty tier. On a yes it implements on that tier's model, hardens the result twice, and loops code and security review until nothing at `review_block` or above is left. After `review_rounds` rounds it stops and hands what is left to you: cut the rule those findings sit on, fix by hand, or go on as is. Run it again to resume. Name a PR or branch, or let the issue's open PR be found: that branch instead. `onto` starts from another issue's branch instead of the default branch |
| `/coddy:ship [issue]` | Runs `verify` in the issue's worktree, commits its tracked changes and only the untracked files you name (any other untracked file stops it), pushes, opens the PR and links it back to the issue. Started `onto` another issue: the PR targets that issue's branch, so it shows only its own diff |
| `/coddy:drop <issue>` | Gives a claimed issue up: removes its worktree and claim here, keeping its branch and moving any ignored or uncommitted files whole under `.git/coddy/swept/<issue>/`, then takes it out of In Progress in the tracker, and off you only when no PR stays open, closing its open PR if you say so. Uncommitted work or commits on no remote need your yes first |
| `/coddy:triage` | Turns findings into issues, skipping ones already open |

Each skill also triggers from plain language ("start issue 42", "what's
next?", "ship it"); the slash command is optional.

In Progress is the `in progress` label on GitHub and GitLab, and the
workflow status on Jira. It ends when `/coddy:ship` has the PR open: the
label comes off, and Jira moves to In Review.

Once a PR has merged, the next `/coddy:next` or `/coddy:start` removes that
issue's worktree, claim and local branch. A worktree that still holds work
not in the PR, or that another running session holds, is kept and reported.
One that holds ignored files (a `.env`, a local database) is moved whole to
`.git/coddy/swept/<issue>/` instead, and stays there until you delete it;
while an earlier copy is there, the worktree is kept and reported.
Merge, squash and rebase merges are all seen; one whose conflicts were
resolved on the way in is not, so remove that worktree by hand.
A claim that has not merged and whose session has ended is reported as
`kept: <issue> (not merged)`, and `/coddy:next` offers `/coddy:drop <issue>`
for it.

## How it enforces

Six layers. The first three are Claude Code hooks, live in every onboarded
project; the fourth is a pair of git hooks that `/coddy:start` installs.

The edit guard and the check before each shell command block a call by
exiting 2, and coddy turns any other exit of theirs into a 2. With Claude
Code 2.1.295 or later they also block when they time out (10 seconds for
the edit guard, 60 for the shell check) or cannot start; an older Claude
Code lets that call through. So a coddy crash or a hook that hangs refuses
every edit and every shell command, under `guard: warn` too, until the
plugin is updated, reinstalled or disabled. The shell check gives its
fingerprint of the main checkout 20 seconds: past that the command runs,
and Claude is told before and after it that it went unchecked.

When the hooks keep refusing, there are three ways out: run the command
from your own terminal, disable the plugin
(`claude plugin disable coddy@coddy`), or start a session with every hook
off (`claude --settings '{"disableAllHooks": true}'`). On native Windows,
or a host without `/usr/bin/env` or `/bin/sh`, the hooks cannot start, which
from Claude Code 2.1.295 refuses every edit and shell command, so disable
the plugin there.

Claude Code runs no plugin hook in a session with `disableAllHooks` set,
in any settings file or by `--settings`, or under managed settings that set
`allowManagedHooksOnly`. An admin who wants managed hooks alone keeps
coddy's by force-enabling `coddy@coddy` in the managed `enabledPlugins`.
With the hooks off, the edit guard, the tripwire and the config lock are
off too, and only the git hooks, branch protection and the PR check hold.
Each shell hook leaves a mark for its session, so when none came right
before `/coddy:start` creates or claims the worktree, it prints
`hooks: off` with these causes and asks you before claiming the issue.

**Edit guard.** A hook rejects every file edit Claude attempts outside
`.worktrees/<issue>/`. Inside, it rejects edits until `/coddy:start` has
claimed that issue. `.claude/` stays editable, except Claude Code's own
worktrees under it. An edit of `.coddy.yml` asks you first, and in
headless `-p` under `--permission-mode bypassPermissions` that ask still
holds: the edit is denied and the file stays as it was. That was checked
in `-p` alone, where an ask nobody answers is a deny; what an interactive
bypass session shows is not known. An edit inside
a `.git` or `.jj` in the project, or of a hard-linked file other than
`.coddy.yml` (pnpm's store links in `node_modules` included), is always
refused. The hook needs `jq`, and blocks every edit without a working one,
or whose path it cannot read.

A claim belongs to the session that made it. Only that session may edit or
push the worktree. Another session starting the same issue is refused and
told how to take it over; `/coddy:start` does so only when you say so. A
claim is also refused on an issue the tracker shows assigned to someone
else, or in progress and not to you. A session that is no longer running is
taken over on its own.

`guard: warn` turns the rejection into a notice. The edit goes through, and
Claude is told it landed outside a claimed worktree, or in one another
session claimed, and which command to run. A coddy crash is no rejection:
it still refuses the edit, as above. Of the other layers, only the
tripwire's worktree and push checks before a command read the key.

**Shell tripwire.** Shell commands cannot be checked in advance. So a second
hook compares the main checkout before and after each one, and tells Claude
to undo any change it left there. A file over 1 MiB, or one whose hashing
would take the total read past 32 MiB, in `git status` order, is compared
by its size, inode and change time rather than read, and after the command
a path is compared the way it was before, so one rewritten in place to the
same size within the change time's resolution is not seen. Changes
inside a submodule's work tree in the main checkout are not seen, and a
submodule is seen once, when it leaves the commit recorded for it, not
again while it stays off it. It hashes a changed file as it is, running no
clean filter, but `git status`, which it runs to find them, still runs the
clean filter of a driver set up in your git config on a modified tracked
file whose `.gitattributes` names that driver. Its git calls write no index
and run no git hook, so a hook a command plants in a hooks directory inside
the project (husky's `.husky/_`, a `.githooks`) does not run.
It also lists every git worktree and jj workspace outside
`.worktrees/<issue>/` and `.claude/worktrees/`, and reports a new one,
however the command made it: its path, whether the command made it or moved,
renamed or re-created it, which tool puts it back, `git worktree move` for a
git worktree the command did not make, `jj workspace rename` for a jj
workspace only renamed, and which removes it, `git worktree remove` or `jj
workspace forget`, once you have checked what the directory holds.
The report gives no command to paste. Every path and name in it is in single
quotes, with backslashes and control characters escaped, so none can pass
for a second entry. A worktree moved out of `.worktrees/<issue>/` (by `mv`
or `git worktree move`) or reached there through a link counts as outside:
the command that moves or deletes a worktree there trips once. When
`.git/worktrees` holds more entries than coddy can check in 10 seconds,
every shell command is refused until you remove the ones no worktree uses
(`git worktree prune` drops those whose worktree is gone).
A `git status` or `git worktree list` anywhere but a plain jj root (one
holding `.jj/repo` and no `.git`, under `worktree: jj`), or, in
a jj repository with a jj on `PATH` that does not report a version before
0.38, a `jj workspace list`, that fails,
before the command or after it, is
never read as an empty listing, and neither is a fingerprint that fails on
its own: the command is reported as unchecked, naming the call that failed.
So is a command that moves or removes the root's `.git` or `.jj/repo`,
and every command after it while the `.git` stays away.
While one keeps failing (a bad line in a staged nested repository's config,
a corrupt index), every command runs unchecked and nothing it changes is
named. Each command's check starts from a fingerprint taken just before it,
so once the call works again, whatever changed meanwhile (an edit in the
main checkout, a worktree made outside `.worktrees/`, a `core.hooksPath`
change) is part of that fingerprint and is never named either. `/coddy:start` refuses, and `coddy doctor` reports it, when
the listing it checks the coddy path against fails.

It also compares `.claude/settings.json` and `.claude/settings.local.json`,
git-ignored or not, where a change can turn coddy's hooks off or change what
runs outside the sandbox, and reports a change a command made there, a
delete included, other than to a `permissions.allow` list of strings, which
Claude Code writes itself when you allow a command for good. It does not put
the file back: Claude is told to have you check it. Its ceilings:

- An Edit or Write of a settings file is held only by Claude Code's own
  prompt for its protected paths, which `bypassPermissions` and auto mode
  skip.
- A shell write of a `permissions.allow` list of strings is not seen, an
  `Edit` allow rule there included.
- `~/.claude/settings.json`, managed settings and a worktree's own
  `.claude/settings*.json` are not compared, nor a subdirectory's, which
  a session opened in that subdirectory loads.
- A settings file over 1 MiB is compared by its size, ctime and inode
  alone, so every change to it is reported, `permissions.allow` included,
  and a same-size rewrite that keeps its inode and ctime is not.
- `hooks: off` reads the session's own mark alone, so a session with its
  hooks off is caught only when it runs `/coddy:start` itself, and a shell
  command can make that mark: it is a check, not a guardrail.

Before a command runs, the hook reads its text for a `git worktree add` or
`jj workspace add` that would put a worktree anywhere else, and refuses it,
naming `/coddy:start <issue>`; `guard: warn` turns that into a notice. The
reading follows quotes, `cd`, `git -C`, options and compound commands, but a
path it cannot work out (`"$p"`, a backtick, a glob) or a missing or failing
`jq` lets the command through with a notice, and the check afterwards still
catches the worktree, except from a command run in the background. A payload
a working `jq` cannot read is refused (a notice under `guard: warn`).

The same reading refuses a `git push`, `git send-pack` or `jj git push` to
the default branch, naming `/coddy:ship`, and leaves every force push and
remote branch delete to you. It reads `HEAD` from the repository git would
find, without running git, and the command's own `-c` settings; a dry run
or `--help` goes through. A target it cannot work out passes with a notice;
after that only the git hooks and branch protection stand in the way.

**Config lock.** `.coddy.yml` is the off switch for all of this. A shell
command from Claude that removes or rewrites it is undone, and so is one
that creates it next to a config still at `.claude/coddy.yml`, which it
would shadow; `/coddy:config` asks you first, by whatever path the edit
reaches the file, a symlink from a worktree included. A change that came
through git, a pull of a shared config or a checkout, is undone too, since
nothing on disk tells it from one a command forged: the message sends Claude
to `/coddy:config`, which shows you the diff against `HEAD` and writes it
only when you say so. A config over 64 KiB is more than coddy keeps a copy
of, so every shell command is refused until `/coddy:config` brings it under
that.

No config at either path, while a claim lock under `.git/coddy` or the
`.git/hooks/coddy` directory is still there, means the config was removed,
not never written. Then every edit, shell command, commit and push is
refused, in either guard mode, except writing the config back: a Write of
`.coddy.yml` (or `.claude/coddy.yml`) asks you first. The message names
what is missing, what was left, and the two ways out in words. A project
with neither leftover, one never onboarded or one you left by hand, stays
inert. Its ceilings:

- A background command's changes are not compared, and the config is only
  compared around each command, so a rewrite between two calls (a
  `guard: warn` added, a weaker `.claude/coddy.yml` left after `.coddy.yml`
  is removed) goes unseen.
- With the sandbox off, one command can remove the config and every
  leftover, which leaves nothing to tell it from a project never onboarded.

**Git hooks.** `/coddy:start` points git's `core.hooksPath` at
`.git/hooks/coddy/`. Its `pre-commit` and `pre-push` refuse a commit on the
default branch, or a push to it, and on any branch no claimed issue owns,
whichever session claimed it. They refuse people too. A commit on a detached
`HEAD`, a tag, and deleting a branch other than the default one go through.
Once the check passes, the hook `core.hooksPath` named before runs, or the
one in `.git/hooks/`. Every other hook that directory holds, a `commit-msg`
say, gets a pass-through to it, so pointing `core.hooksPath` elsewhere turns
none of them off. The hooks run coddy through a launcher, a link in the
plugin's data directory that each Claude Code session points at the current
install, so an update leaves them as they are; never a `coddy` on `PATH`.
They run it under a `bash` from `PATH`, and it finds its tools there, past
every entry that is relative or inside the repository, as the Claude Code
hooks do; the old hook gets `PATH` as it was. `/coddy:start` refuses to write hooks that would run a
coddy inside the project or a worktree of it, which a sandboxed command
could rewrite. A hook whose coddy is gone
refuses and says, in words, what puts it back, that `--no-verify` skips it
and how to turn the hooks off. Their ceilings:

- `git commit --no-verify` and `git push --no-verify` skip them, and
  `git -c core.hooksPath=` runs without them.
- jj runs no git hooks. The tripwire's push check reads a `jj git push`
  before it runs.
- A tool that sets `core.hooksPath` itself, such as a hook manager's
  install, turns them off until the next `/coddy:start`. husky's `prepare`
  script does it on every `npm install` or `npm ci`, in a worktree too. The
  tripwire reports it once, and `coddy doctor`'s `hooks` line shows it.
- A tool that installs into git's hooks directory (lefthook,
  `git lfs install`, simple-git-hooks) writes into `.git/hooks/coddy/` once
  `/coddy:start` has run, and can replace coddy's own. `/coddy:start` then
  stops on any file there it did not write, and names the old hooks
  directory to move it to; it never deletes or overwrites one.
- An install the launcher does not cover (`claude --plugin-dir`, a coddy
  from `get.sh`) has the hooks run coddy by the path `/coddy:start` ran it
  from.
- The pass-throughs are written when `/coddy:start` runs: a hook added to
  the old directory after that runs from the next `/coddy:start`.
- `core.hooksPath` is an absolute path, so moving or renaming the checkout
  turns every hook off, the old ones included, until the next `/coddy:start`.
- `/coddy:start` stops when a `core.hooksPath` set where it overrides
  `.git/config` (the worktree's own config, an include, an `includeIf` on
  the issue's branch, `GIT_CONFIG_*`) would keep them off, at the root or in
  the issue's worktree; `git config --show-origin core.hooksPath` there
  finds it.
- git runs hooks outside Claude Code's sandbox, so the sandbox keeps writes
  out of `.git/hooks` and `.git/config`, where the hooks and the old
  `core.hooksPath` live. The first `/coddy:start` in a repository stops
  there: run it once from your own terminal, as its message says. Later runs
  change nothing there and pass inside the sandbox, unless the old hooks
  directory has gained a hook since: then the next one stops the same way,
  until it is run once from your own terminal. So does the first one after
  upgrading from a coddy whose hooks ran its versioned directory.
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

- GitHub and GitLab only. A Jira project gets the local guardrails alone:
  `/coddy:onboard` does not write the check, and a copied one fails every
  Jira PR, which carries no closing reference.
- GitHub computes the references only on a PR against the default branch.
  On a PR stacked on another branch, the check reads the closing keywords
  in the description itself. A link made only in the sidebar is not seen.
- It blocks a merge only once `closes a claimed issue` is a required check
  on the default branch, which you add by hand.

On GitLab the same check is a job, `templates/coddy.gitlab-ci.yml`, also
named `closes a claimed issue`. `/coddy:onboard` opens a merge request that
adds it as `.gitlab/coddy.yml`, included from `.gitlab-ci.yml`, and never
commits to the default branch. Its ceilings:

- It runs in the `test` stage. A project whose `stages:` omits `test` must
  add it, or set a stage for the job in `.gitlab-ci.yml`.
- It reads the merge request's description and each issue it closes through
  the API, with the job token, so nothing needs setting up. The references
  come from the description alone, by GitLab's default closing pattern, the
  same way whatever the target branch: a closing keyword only in a commit
  message, or a link made in the Work items widget, is not seen.
- Only a job that reports it cannot read (a 401, 403 or 404 fails the job
  and names the variable) needs the CI variable `CODDY_TOKEN`: a token
  tied to this project alone, never a personal one, with `read_api`,
  masked and not protected, since a protected variable does not reach a
  merge request pipeline from an unprotected branch.
  Any branch's pipeline can read it.
- Editing a merge request's description starts no pipeline, so re-run the
  job after fixing one.
- The merge request that adds it is checked by it too: give it `Closes #<n>`
  for an open, assigned issue, or merge it before Pipelines must succeed is
  on.
- It blocks a merge only once Pipelines must succeed is on, with the default
  branch protected, which you set by hand.

## Config

`.coddy.yml` at the project root, written by `/coddy:onboard` and changed
by `/coddy:config`:

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
- To leave the workflow, from your own terminal delete the file, the claim
  locks under `.git/coddy` and the `.git/hooks/coddy` directory, and set
  `core.hooksPath` back to the `coddy.previousHooksPath` that `.git/config`
  records, or, when that is empty or missing, unset `core.hooksPath`, never
  set it to an empty value. While a claim lock or the hooks directory is
  left, a missing config reads as removed and the hooks refuse everything.
  Every other skill refuses to run without the file.

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
- PRs merge with a merge commit, never squash or rebase merge: stacked PRs
  need their base's commits intact.
- coddy assumes one remote, `origin`, and write or triage access to the
  tracker's repository; forks are not supported yet (#280). Outside
  contributors open a PR by hand with `Closes #<n>`; the coddy flow is for
  collaborators.
- Brand assets and their uses are listed in [`assets/README.md`](assets/README.md).

## Develop

```bash
bash scripts/selftest.sh                 # the Claude Code shims end to end, in a throwaway repo
bash scripts/selftest-core.sh            # bin/coddy on its own inputs, with no CLAUDE_* set
claude plugin validate .                 # manifest and skill frontmatter
claude --plugin-dir . -p "/coddy:next"   # run one skill headless against the working copy
```

A headless run needs `--allowedTools` only for what a skill's `allowed-tools` does not mirror: the edit tools and `Agent`, plus `Skill(coddy:<name>)` for a plain-language trigger in `-p`.
