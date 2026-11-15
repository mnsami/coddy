# Enforcement limits

This page holds the long lists of gaps in the shell tripwire.
You rarely need them. Read them when you want the exact edge of a check.
Back to [How coddy enforces its rules](enforcement.md#shell-tripwire).

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
- `/coddy:start` refuses, and `coddy doctor` reports it, when the listing it checks the coddy path against fails.

## Settings files

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

## What the text check reads

Before a command runs, the hook reads its text, following quotes, `cd`, `git -C`, options and compound commands.
It looks for a worktree add and for a push.

- It cannot work out a path or word that is `"$p"`, a backtick, a glob, a brace, `~` or a line break.
  The command passes with a notice.
- Spellings that dodge it:
  - a variable, `bash -c`, `eval`, a shell function (`p() { git "$@"; }`), a git alias, `sudo`;
    the check reads the command's name, not what a function or alias runs;
  - a `cd -`, or a `cd` in a pipeline;
  - a quoted word such as `work"tree"`;
  - a path through a symlink that it resolves by name.
- Push checks are also dodged by a here-string or a pipe into a shell, `env -S`, and a wrapper or wrapper option
  it does not know. Other `-c` keys are not read: `push.default=upstream`, `remote.<name>.mirror`,
  `branch.<name>.pushRemote`.
- The check afterwards still reports a worktree it missed, except from a background command.
- It does not check the issue's claim. The edit guard does.
- A call a working `jq` cannot read is refused. Under `guard: warn` it is a notice.

How the push check reads a push:

- It reads `HEAD` from the repository git would find, without running git.
  From the command's own `-c` settings it reads only `remote.<name>.push`, `push.default=matching`
  and `help.autocorrect`. It reads none of your git config.
- It reads `HEAD` as it stands before the command runs. A command that moves it first is read by where it was.
- A push with no refspec is read as the checked-out branch's, unless a `-c remote.<name>.push` or
  `push.default=matching` says otherwise.
- It refuses a push to a branch of the default branch's name in any repository.
- It sees no `jj git push` force, because jj has no force flag and always pushes with a lease.
- jj coverage is partial. A bare `jj git push`, or one with `-r` alone, passes with a notice,
  since only jj knows which bookmarks it moves. The git hooks never run under jj.
- A target it cannot work out passes with a notice.
  After that only the git hooks and branch protection stand in the way, and under jj only branch protection.
- Nothing stands behind it once the command has run. Branch protection and, for git, the git hooks do.
