# How coddy enforces its rules

This page says what each layer stops, what it lets through and where it falls short.
The [README](../README.md) has the short version.

Each layer has the same rows. A row is left out when it does not apply.

- **Stops:** what the layer refuses or reports.
- **Lets through:** what it leaves alone on purpose.
- **Asks you first:** what needs your yes.
- **Always refuses:** what it refuses in both `guard` modes.
- **Doesn't catch:** its gaps.
- **When it blocks you:** how to get unblocked.
- **Needs:** what must be installed or set.

## What holds against what

- The hooks stop the common slips, such as editing in the main checkout or pushing to the default branch.
- The hooks also report many shell writes after they happen.
- They are not a sandbox. An agent that is set on getting round them can.
- Two layers hold against that: branch protection and the required PR check. You set both by hand.
- Claims are cooperative. A shell command that writes to `.git/coddy` defeats
  "only the claiming session may edit or push".
- `start`'s sub-agents run in the parent's session. Their edits count as the session's own.
- The tracker check is a step in `/coddy:start`. It reads the issue and refuses one assigned to someone else.
  `claim` never reads the tracker. It records what the skill did.
- The review the PR shows is what `/coddy:start` reports. Any command in the owning session can set it.

## When hooks fail or are off

### A hook fails

- The edit guard and the shell check block a call by exiting 2.
- coddy turns any other exit of theirs into a 2. A coddy crash refuses every edit and shell command,
  under `guard: warn` too, until you update, reinstall or disable the plugin.
- From Claude Code 2.1.295 they also block on a timeout or when they cannot start.
  Before 2.1.295 that call goes through.
- Timeouts: 10 seconds for the edit guard, 60 for the shell check.
- The shell check gives its fingerprint of the main checkout 20 seconds.
  Past that the command runs, and Claude is told before and after it that it went unchecked.
- The other hooks never block on a failure.

### Three ways out

- Run the command from your own terminal.
- Disable the plugin: `claude plugin disable coddy@coddy`.
- Start a session with every hook off: `claude --settings '{"disableAllHooks": true}'`.

### Hooks off

- Claude Code runs no plugin hook when `disableAllHooks` is set, in any settings file or by `--settings`.
- It runs none under managed settings that set `allowManagedHooksOnly`.
  An admin who wants managed hooks alone keeps coddy's by force-enabling `coddy@coddy` in the managed `enabledPlugins`.
- With the hooks off, the edit guard, the tripwire and the config lock are off.
  Only the git hooks, branch protection and the PR check hold.
- Each shell hook leaves a mark for its session. `/coddy:start` looks for it before it creates or claims the worktree.
  With none, it prints `hooks: off` and the causes, and asks you before it claims the issue.
- That check reads the session's own mark. A session with its hooks off is caught only when it runs `/coddy:start`
  itself, and a shell command can make the mark. It is a check, not a guardrail.

## Platform

### bash and `PATH`

- The hooks start under `/bin/sh`. They run the first `bash` on Claude Code's `PATH`. bash 3.2 or later works.
  On macOS that can be `/bin/bash`.
- They look for `bash`, `git`, `jq` and `jj` on that `PATH`.
  They skip every entry that is empty, relative, or inside the project, through a link or not.
  A command could plant a tool there, and the hooks run outside the sandbox.
- So a toolchain that lives only in the project (`.venv/bin`, devbox, nix-shell) does not count.
- With no `bash` left, every call is refused.
- With no `git` left, every shell command is refused.
  So is every shell command with no `jj`, where the project holds a `.jj`.
- With no `jq`, every edit is refused.
- `coddy doctor` prints the `bash` the hooks run.
- These still reach the hooks: `LD_PRELOAD`, `LD_AUDIT`, `TMPDIR`, `JJ_CONFIG`
  and an absolute `PATH` entry outside the project.
  So does a function exported into your own environment that is named like a builtin (`cd`, `pwd`, `printf`),
  on macOS, where `/bin/sh` is bash.

### Native Windows

- Git Bash, MSYS2 and Cygwin are not supported. Use WSL.
- The hooks cannot start there. From Claude Code 2.1.295, that refuses every edit and shell command.
  Disable the plugin there. Before 2.1.295 nothing is guarded.
- The hooks also need Claude Code 2.1.139 or later and `/usr/bin/env`.
- Where the edit guard does run (the core called another way), it refuses every edit.
- `/coddy:onboard` stops. `coddy doctor` exits 1.

### `bin/coddy` and the `CODDY_*` variables

- Every mechanic lives in one command, `bin/coddy`. It does not need Claude Code.
- Claude Code puts the plugin's `bin/` on the Bash tool's `PATH` while the plugin is enabled.
- claude.ai and Cowork do not install a plugin that has a top-level `bin/`, through organisation settings either.
  So coddy needs the Claude Code CLI.
- It reads these variables. Claude Code's hooks and skills set them from its own environment.
  - `CODDY_ROOT`: where to look for the project. The working directory without it.
  - `CODDY_SESSION` and `CODDY_PID`: the session and process a claim is held to.
  - `CODDY_AGENT_DIR`: the agent's own directory, such as `.claude`, free to edit.
- `get.sh` links `coddy` into `~/.local/bin` and prints the `PATH` line to add when that is not on your `PATH`.

## Edit guard

A `PreToolUse` hook on Edit, Write and NotebookEdit.

- **Stops:** an edit outside `.worktrees/<issue>/`.
  Inside, an edit before `/coddy:start` has claimed the issue, or when another session holds the claim.
- **Lets through:** `.claude/`, except Claude Code's own worktrees under `.claude/worktrees/`.
  Those are held to the lock too.
- **Asks you first:** any edit of `.coddy.yml`, by whatever path it reaches the file.
  A symlink or hard link from a worktree counts.
  In headless `-p` under `--permission-mode bypassPermissions` the ask is still not bypassed:
  the edit is denied and the file stays as it was.
  That was checked in `-p` alone, where an ask nobody answers is a deny.
  What an interactive bypass session shows is not known.
- **Always refuses:**
  - a file inside a `.git` or `.jj` below the project root;
  - a hard-linked file other than `.coddy.yml`, pnpm's store links in `node_modules` included;
  - a path it cannot read or follow: over 4096 bytes, through `/proc` or macOS's `/.vol`, or one that is
    Windows-style (a drive letter, a backslash, a leading `//`);
  - every edit, where bash itself runs on native Windows;
  - every edit, when the config was removed while a claim lock is still there (see Config lock).
- **Doesn't catch:**
  - Shell commands. The tripwire reports those after they run.
  - An edit through a FUSE or network mount of the project, or a bind mount of a directory in it.
  - A command that swaps the target for a link between the check and the write.
  - A project whose path holds a backslash cannot be edited through these tools on macOS or Linux.
- **When it blocks you:** see "When hooks fail or are off".
- **Needs:** `jq`. Without a working one, or for a payload with no path it can read, every edit is refused.

### Claims

- A claim belongs to the session that made it. Only that session may edit or push the worktree.
- Another session that starts the same issue is refused and told how to take it over.
  `/coddy:start` takes it over only when you say so.
- A session that is no longer running is taken over on its own.
- `/coddy:start` refuses an issue the tracker shows assigned to someone else, or in progress and not to you.
  That is a step of the skill, not of the guard.
- A claim is a lock under `.git/coddy`. It holds against Claude's edit tools and against `coddy push`.
  It does not hold against a shell command that rewrites the lock.
- The tripwire does not see shell writes inside any worktree, claimed or not.
  So only the edit guard and `push` are held to the owner.

### `guard: warn`

- The rejection becomes a notice. The edit goes through, and Claude is told it landed outside a claimed worktree,
  or in one another session claimed, and which command to run.
- The ask on `.coddy.yml` stays an ask.
- Everything in **Always refuses** stays refused, and so does a coddy crash.
- Of the other layers, only the tripwire's worktree and push checks read the key. They become notices too.
- Set it with `/coddy:config guard=warn`. `/coddy:onboard` leaves the key out.

## Shell tripwire

A shell command's writes cannot be told from its text.
So one hook takes a fingerprint of the main checkout before each shell command and another compares after it.
Claude is told to undo whatever the command left there. Only additions count, so an undo is quiet.

The fingerprint holds:

- every changed path, with a hash of its content;
- the default branch, when it has commits its remote branch lacks, and `HEAD`, when it has left the default branch;
- the git worktrees and jj workspaces;
- `core.hooksPath`, once the git hooks are installed;
- the two Claude Code settings files.

- **Stops:**
  - A change a command left in the main checkout, reported after it ran.
  - A new git worktree or jj workspace outside `.worktrees/<issue>/` and `.claude/worktrees/`, reported after it ran.
    The report gives its path, says whether the command made it or moved, renamed or re-created it,
    and says which tool removes it or puts it back.
    The tool is `git worktree remove` or `jj workspace forget`, once you have checked what the directory holds,
    and `git worktree move` or `jj workspace rename`.
    The report gives no command to paste, since a command can arrange for one to remove something it did not make.
    Every path and name in it is in single quotes, with backslashes and control characters escaped,
    so none can pass for a second entry.
    A worktree moved out of `.worktrees/<issue>/` (by `mv` or `git worktree move`), or reached there through a link,
    counts as outside. The command that moves or deletes it is reported once.
  - A `git worktree add` or `jj workspace add` that would put a worktree anywhere else, refused before it runs.
    It names `/coddy:start <issue>`.
  - A `git push`, `git send-pack` or `jj git push` to the default branch, refused before it runs.
    It names `/coddy:ship`.
  - A change to `core.hooksPath`, reported once. A hook manager's install does it.
    husky's `prepare` script does it on every `npm install` or `npm ci`, in a worktree too.
- **Lets through:**
  - Every force push and every remote branch delete. Those are yours to make.
  - A dry run, `--help`, and `jj git push -c`.
  - A command with a word it cannot work out. It passes with a notice, and the check after it still looks.
  - A command that goes over the 20-second budget. It runs, and Claude is told it went unchecked.
- **Asks you first:** a change to a settings file.
  Claude is told to have you check it. coddy does not put the file back.
  See "Settings files" below.
- **Always refuses:** every shell command, in either guard mode, when:
  - `HOME` or `XDG_CONFIG_HOME` lies at or under the project, since git and jj read `core.fsmonitor` from there;
  - no `git` is left on the hooks' `PATH`, or no `jj` where the project holds a `.jj`;
  - the config is over 64 KiB (see Config lock);
  - `.git/worktrees` holds more entries than coddy can check in 10 seconds.
    Remove the ones no worktree uses. `git worktree prune` drops those whose worktree is gone.
    The same refusal comes when a file there that git would wait on forever is not a plain file.
  - the config was removed while a claim lock is still there.
- **Doesn't catch:**
  - A background command's changes.
  - A shell write inside any worktree under `.worktrees/`, claimed or not, or another session's.
  - A file over 1 MiB, or one past the first 32 MiB hashed, is compared by its size, inode and change time.
    A same-size rewrite in place that keeps those is not seen.
  - A change inside a submodule's work tree.
    A submodule is seen once, when it leaves the commit recorded for it, and not again while it stays off it.
  - A commit on the default branch, if the command also writes `refs/remotes/origin/<default_branch>`.
    Branch protection catches it at the push.
  - A clean filter. The fingerprint runs none on a changed file, but `git status`, which finds them, still runs
    the clean filter of a driver you set up in your git config, on a modified tracked file whose `.gitattributes`
    names it.
  - A hook a command plants inside the project does not run: the fingerprint's git calls write no index and run no hook.
  - A jj workspace whose path jj cannot give (made before jj 0.38, or, before jj 0.46, its directory gone).
  - A git worktree moved, renamed or re-created by a command that also left a git admin file that is not a plain file.
  - A worktree check or push check that was dodged. See below.
- **Needs:** `git`, and `jj` where the project holds a `.jj` and has jj 0.38 or later.
  Without `jq`, the worktree and push checks pass with a notice.

### A check that fails is never read as a clean one

- A failing `git status`, `git worktree list`, `jj workspace list` or fingerprint is not read as an empty list.
  The command is reported as unchecked, naming the call that failed.
- A command that moves or removes the root's `.git` or `.jj/repo` is reported the same way,
  and so is every command after it while the `.git` stays away.
- Every command runs unchecked while one keeps failing (a bad line in a staged nested repository's config,
  a corrupt index). Nothing it changes is named.
- Each command's check starts from a fingerprint taken just before it.
  Once the call works again, whatever changed meanwhile (an edit in the main checkout, a worktree made
  outside `.worktrees/`, a `core.hooksPath` change) is part of that fingerprint and is never named.
- A main checkout too large to fingerprint in 20 seconds runs every command unchecked.
- `/coddy:start` refuses, and `coddy doctor` reports it, when the listing it checks the coddy path against fails.

### Settings files

The tripwire also compares `.claude/settings.json` and `.claude/settings.local.json`, git-ignored or not.
A change there can turn coddy's hooks off or change what runs outside the sandbox.
A delete counts. A change only to a `permissions.allow` list of strings does not,
because Claude Code writes that itself when you allow a command for good.

- It does not see an Edit or Write of a settings file. Only Claude Code's own prompt for its protected paths holds it,
  and `bypassPermissions` and auto mode skip that prompt.
- It does not see a shell write of a `permissions.allow` list of strings, an `Edit` allow rule there included.
- It does not compare `~/.claude/settings.json`, managed settings, a worktree's own `.claude/settings*.json`,
  or a subdirectory's, which a session opened in that subdirectory loads.
- A settings file over 1 MiB is compared by its size, ctime and inode alone.
  Every change to it is reported, `permissions.allow` included.
  A same-size rewrite that keeps its inode and ctime is not.

### What the text check reads

Before a command runs, the hook reads its text, following quotes, `cd`, `git -C`, options and compound commands.
It looks for a worktree add and for a push.

- It cannot work out a path or word that is `"$p"`, a backtick, a glob, a brace, `~` or a line break.
  The command passes with a notice.
- Spellings that dodge it:
  - a variable, `bash -c`, `eval`, a git alias, `sudo`;
  - a `cd -`, or a `cd` in a pipeline;
  - a quoted word such as `work"tree"`;
  - a path through a symlink that it resolves by name.
- Push checks are also dodged by a here-string or a pipe into a shell, `env -S`, and a wrapper or wrapper option
  it does not know.
- The check afterwards still reports a worktree it missed, except from a background command.
- It does not check the issue's claim. The edit guard does.
- A payload a working `jq` cannot read is refused. Under `guard: warn` it is a notice.

How the push check reads a push:

- It reads `HEAD` from the repository git would find, without running git, and the command's own `-c` settings.
  It reads none of your git config.
- It reads `HEAD` as it stands before the command runs. A command that moves it first is read by where it was.
- A push with no refspec is read as the checked-out branch's, unless the command's `-c` settings say otherwise.
- It refuses a push to a branch of the default branch's name in any repository.
- It sees no `jj git push` force, because jj has no force flag and always pushes with a lease.
- jj coverage is partial. A bare `jj git push`, or one with `-r` alone, passes with a notice,
  since only jj knows which bookmarks it moves. The git hooks never run under jj.
- A target it cannot work out passes with a notice.
  After that only the git hooks and branch protection stand in the way, and under jj only branch protection.
- Nothing stands behind it once the command has run. Branch protection and, for git, the git hooks do.
- Both checks hold only when the lock and the caller name a session.
  A push from a script run by hand is not held to it.

## Config lock

`.coddy.yml` is the off switch for every layer above, so the tripwire guards it.

- **Stops:** a shell command that removes or rewrites `.coddy.yml`. It is put back.
  So is one that creates `.coddy.yml` next to a config still at `.claude/coddy.yml`, which it would shadow.
  A change that came through git is undone too, a pull of a shared config or a checkout.
  Nothing on disk tells it from one a command forged.
  The message sends Claude to `/coddy:config`, which shows you the diff against `HEAD` and writes it only on your yes.
- **Lets through:**
  - A project with no config and nothing a started issue leaves behind. It is inert.
  - A command that writes the config when none existed (a pull of a shared `.coddy.yml` into a fresh clone).
  - A change to `.claude/coddy.yml` once `.coddy.yml` is live. It is ignored then.
    `/coddy:migrate` ends its move that way.
- **Asks you first:** `/coddy:config`, `/coddy:migrate` and `/coddy:onboard` write the file with the Write tool.
  The edit guard asks you, whatever path the write reaches the file by.
- **Always refuses:** every edit, shell command, commit and push, in either guard mode,
  when no config exists at either path while a claim lock under `.git/coddy`, or the `.git/hooks/coddy` directory,
  is still there. That means the config was removed, not never written.
  The one exception is a Write of the config, which asks you first.
  The message names what is missing, what was left, and the two ways out.
  Also every shell command while `.coddy.yml` is over 64 KiB, which is more than coddy keeps a copy of.
  `/coddy:config` brings it under.
- **Doesn't catch:**
  - A background command's changes. The config is compared around each command alone,
    so a rewrite between two calls goes unseen (a `guard: warn` added, a weaker `.claude/coddy.yml` left
    after `.coddy.yml` is removed).
  - With the sandbox off, one command can remove the config and every leftover.
    Nothing then tells it from a project never onboarded.
  - The snapshot the lock compares against is under `TMPDIR`. A shell command run as you can rewrite it.
- **Needs:** nothing beyond the tripwire's.

## Git hooks

`/coddy:start` points git's `core.hooksPath` at `.git/hooks/coddy/`.
It writes a `pre-commit` and a `pre-push` there.

- **Stops:** a commit on the default branch, or a push to it.
  A commit or push on any branch no claimed issue owns, whichever session claimed it.
  They refuse people too.
- **Lets through:**
  - A commit on a detached `HEAD`, a tag, and deleting a branch other than the default one.
  - The hook `core.hooksPath` named before, or the one in `.git/hooks/`. It runs once the check passes.
  - Every other hook that old directory holds, a `commit-msg` say. It gets a pass-through,
    so pointing `core.hooksPath` elsewhere turns none of them off.
- **Doesn't catch:**
  - `git commit --no-verify` and `git push --no-verify` skip them, and `git -c core.hooksPath=` runs without them.
  - Under jj. jj runs no git hooks.
  - A merge, cherry-pick or revert runs no `pre-commit`. The push catches it.
  - A tool that sets `core.hooksPath` itself turns them off until the next `/coddy:start`.
    husky's `prepare` script does it on every `npm install` or `npm ci`, in a worktree too.
    The tripwire reports it once, and `coddy doctor`'s `hooks` line shows it.
  - A tool that installs into git's hooks directory (lefthook, `git lfs install`, simple-git-hooks)
    writes into `.git/hooks/coddy/` and can replace coddy's own.
    `/coddy:start` then stops on any file there it did not write and names the old hooks directory to move it to.
    It never deletes or overwrites one.
  - `core.hooksPath` is an absolute path. Moving or renaming the checkout turns every hook off, the old ones included,
    until the next `/coddy:start`.
  - A hook added to the old directory after `/coddy:start` ran runs from the next `/coddy:start`.
  - An install the launcher does not cover (`claude --plugin-dir`, a coddy from `get.sh`)
    has the hooks run coddy by the path `/coddy:start` ran it from.
  - `/resume` inside a process that still runs an install an update replaced points the launcher back to it
    until the next session starts.
- **When it blocks you:**
  - The hooks run coddy through a launcher, a link in the plugin's data directory.
    Each Claude Code session points it at the current install, so an update leaves the hooks as they are.
    They never run a `coddy` on `PATH`.
  - A hook whose coddy is gone refuses and says in words what puts it back.
    It also says that `--no-verify` skips the hook, and how to turn the hooks off.
  - `/coddy:start` stops when a `core.hooksPath` set where it overrides `.git/config` would keep them off.
    That is the worktree's own config, an include, an `includeIf` on the issue's branch or `GIT_CONFIG_*`,
    at the root or in the issue's worktree.
    `git config --show-origin core.hooksPath` there finds it.
  - `/coddy:start` refuses to write hooks that would run a coddy inside the project or a worktree of it,
    which a sandboxed command could rewrite.
  - git runs hooks outside Claude Code's sandbox, so the sandbox keeps writes out of `.git/hooks` and `.git/config`.
    The first `/coddy:start` in a repository stops there. Run it once from your own terminal, as its message says.
    Later runs change nothing there and pass inside the sandbox.
    If the old hooks directory has gained a hook since, the next one stops the same way.
    So does the first one after upgrading from a coddy whose hooks ran its versioned directory.
    Under jj, the first `/coddy:start` of each issue stops the same way, since jj keeps the workspace's
    `snapshot.auto-track` setting outside the project.
- **Needs:** a `bash`, `git` and `sed` on the hooks' `PATH`, found past every entry that is relative
  or inside the repository. The old hook gets `PATH` as git gave it.

## Branch protection

The only layer that holds when a command edits, commits and pushes to the default branch in one go.

- **Stops:** a push to the default branch that skips a pull request, once you have set it.
- **Doesn't catch:** anything, until you set it. coddy cannot set it: no MCP tool reads or writes protection.
- **Needs:** you, by hand.
  - GitHub: require a pull request on the default branch. `/coddy:onboard` asks and tells you what to set.
  - GitLab: protect the default branch, and turn on Pipelines must succeed. `/coddy:onboard` names both.

## PR check

A job named `closes a claimed issue`. It fails a pull request unless it closes an open, assigned issue.
Open and assigned is what holds from `/coddy:start` to the merge.
The `in progress` label comes off when the PR opens, and the check runs again on every push.
It goes by the closing reference, not the branch name.
So it is the one layer that holds for a cloud agent, or for any branch coddy did not name.

- **Stops:** a PR that closes no issue, or an issue that is closed or has no assignee.
- **Doesn't catch:**
  - A PR on a project that never requires the check. It blocks a merge only once
    `closes a claimed issue` is a required check on the default branch (GitHub), or Pipelines must succeed is on
    with the default branch protected (GitLab). You set both by hand.
  - GitHub or GitLab only. A Jira project gets the local guardrails alone.
    `/coddy:onboard` does not write the check, and a copied one fails every Jira PR, which carries no closing reference.
- **Needs:** the workflow file, committed by you.

### On GitHub

- `templates/coddy.yml` goes to `.github/workflows/coddy.yml`. `/coddy:onboard` writes it and backs up a differing copy
  under `.claude/coddy/backup/`. You commit it.
- GitHub computes the closing references only for a PR against the default branch.
  On a PR stacked on another branch, the check reads the closing keywords in the description itself.
  A link made only in the sidebar is not seen.

### On GitLab

- `templates/coddy.gitlab-ci.yml` is a job with the same name.
  `/coddy:onboard` opens a merge request that adds it as `.gitlab/coddy.yml`, included from `.gitlab-ci.yml`.
  It never commits to the default branch.
- It runs in the `test` stage. A project whose `stages:` omits `test` must add it,
  or set a stage for the job in `.gitlab-ci.yml`.
- It reads the merge request's description and each issue it closes through the API, with the job token.
  Nothing needs setting up.
- The references come from the description alone, by GitLab's default closing pattern, the same way
  whatever the target branch.
  A closing keyword only in a commit message, or a link made in the Work items widget, is not seen.
- Only a job that reports it cannot read (a 401, 403 or 404 fails the job and names the variable)
  needs the CI variable `CODDY_TOKEN`.
  Use a token tied to this project alone, never a personal one, with `read_api`, masked and not protected.
  A protected variable does not reach a merge request pipeline from an unprotected branch.
  Any branch's pipeline can read it.
- Editing a merge request's description starts no pipeline. Re-run the job after fixing one.
- The merge request that adds the job is checked by it too.
  Give it `Closes #<n>` for an open, assigned issue, or merge it before Pipelines must succeed is on.

## Leaving the workflow

From your own terminal:

1. Delete `.coddy.yml`.
2. Delete the claim locks under `.git/coddy`.
3. Delete the `.git/hooks/coddy` directory.
4. Set `core.hooksPath` back to the `coddy.previousHooksPath` that `.git/config` records.
   When that is empty or missing, unset `core.hooksPath`. Never set it to an empty value.

While a claim lock or the hooks directory is left, a missing config reads as removed.
Then the hooks refuse everything, and every skill but `/coddy:onboard` refuses to run.

## Sweep, drop and refresh

These skills end or update a claim. They keep your work unless you say otherwise.

### Sweep

After a PR merges, the next `/coddy:next` or `/coddy:start` removes the issue's worktree, claim and local branch.

- It keeps and reports a worktree that holds work not in the PR, or that another running session holds.
- A worktree with ignored files (a `.env`, a local database) is moved whole to `.git/coddy/swept/<issue>/`.
  It stays there until you delete it. While an earlier copy is there, the worktree is kept and reported.
- It sees merge, squash and rebase merges. One whose conflicts were resolved on the way in is not seen.
  Remove that worktree by hand.
- An unmerged claim whose session has ended shows as `kept: <issue> (not merged)`.
  `/coddy:next` then offers `/coddy:drop <issue>`.

### Drop

- `/coddy:drop <issue>` removes the worktree and claim here and keeps the branch.
- Ignored or uncommitted files move whole to `.git/coddy/swept/<issue>/`. Nothing is deleted.
- It needs your yes first for uncommitted work or commits on no remote.
- It takes the issue out of In Progress in the tracker, and off you only when no PR stays open.
  It closes an open PR only if you say so.

### Refresh

- `/coddy:refresh` brings every claimed worktree up to date with the default branch and runs `verify` in each.
  Git makes a merge commit. jj rebases.
- It never pushes.
- A conflict leaves the worktree as it was. A conflict, or a `verify` that fails once the worktree is updated,
  flags the issue. `/coddy:start <issue>` then updates the branch before anything else.
- It skips:
  - another running session's worktree, and uncommitted work;
  - a branch stacked on an open issue;
  - under git, a detached `HEAD` or a branch other than the issue's;
  - under jj, a branch other commits build on;
  - a config with no `verify`, or a block-scalar one.
