# Enforcement limits

This page holds the long lists of gaps in the shell tripwire.
You rarely need them. Read them when you want the exact edge of a check.
Back to [How hermy enforces its rules](enforcement.md#shell-tripwire).

## A check that fails is never read as a clean one

- A failing `git status`, `git worktree list`, `jj workspace list` or record is not read as an empty list.
  The command is reported as unchecked, naming the call that failed.
- A command that moves or removes the root's `.git` or `.jj/repo` is reported the same way,
  and so is every command after it while the `.git` stays away.
- While one keeps failing (a bad line in a staged nested repository's config, a corrupt index),
  every command runs unchecked and nothing it changes is named.
  Each check starts from the state just before the command. Once the call works again,
  whatever changed meanwhile (a main-checkout edit, a worktree outside `.worktrees/`, a `core.hooksPath` change)
  is part of that starting state and is never named.
- A main checkout too large to record in 20 seconds runs every command unchecked.
- `/hermy:start` refuses, and `hermy doctor` reports it, when the listing it checks the hermy path against fails.

## Settings files

The tripwire also compares `.claude/settings.json` and `.claude/settings.local.json`, git-ignored or not.
A change there can turn hermy's hooks off or change what runs outside the sandbox.
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

## What the tripwire leaves to other layers

The tripwire reads no command's text. It records the main checkout before a command and compares after it.

- A worktree outside `.worktrees/` and `.claude/worktrees/` is reported after it is made, not refused before.
  A background command's goes unreported.
- A push is not checked. The `pre-push` hook and branch protection hold a push to the default branch.
  Under jj, which runs no git hooks, and past `--no-verify` or `git send-pack`, branch protection holds it alone.
- A force push of a claimed issue's branch is allowed.
- Deleting a claimed issue's branch is not refused yet (#269).
