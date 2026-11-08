#!/bin/sh
# The Claude Code hooks' launcher: hooks/hooks.json runs it under /bin/sh,
# through env -u, and it runs issue.sh under a bash -p (no BASH_ENV, no
# function from the environment). The hooks run outside Claude Code's
# sandbox, so a bash, git, sed or jq a command in the project planted on
# PATH would run unsandboxed: every entry that is empty or relative (the
# hook's working directory, which follows the Bash tool's cd), gone, or
# lies, physically, at or under the project dir or the nearest directory
# above it holding a .git directory (the checkout of a session opened in a
# subdirectory or worktree) is dropped, the rest kept in their physical
# spelling, and the first bash left runs; bin/coddy drops those at or under
# the root it resolves too. Shell builtins alone until then. POSIX sh, run
# without -p, which dash and BusyBox reject.
r=${CLAUDE_PROJECT_DIR:-$PWD} t=
case $r in /*) t=$r; while [ -n "$t" ] && [ ! -d "$t/.git" ]; do t=${t%/*}; done ;; esac
o() { x=$1; while [ -n "$x" ]; do { [ "$x" -ef "$r" ] || [ "$x" -ef "$t" ]; } && return 0; x=${x%/*}; done; return 1; }
s=$PATH: n='' b=''
while [ -n "$s" ]; do
  e=${s%%:*}; s=${s#*:}
  case $e in /*) d=$(cd -P "$e" 2>/dev/null && pwd -P) && ! o "$d" || continue ;; *) continue ;; esac
  n=$n${n:+:}$d
  [ -n "$b" ] || [ ! -f "$d/bash" ] || [ ! -x "$d/bash" ] || b=$d/bash
done
[ -n "$b" ] || { printf '%s\n' "coddy: no bash on PATH outside the project at $r, so the coddy ${1-} hook cannot run, and the call is refused. An entry that is empty, relative or lies in the project is skipped, since a command in the project could plant a bash there." >&2; exit 2; }
PATH=$n
export PATH
exec "$b" -p "${0%/*}/issue.sh" "$@"
