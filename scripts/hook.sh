#!/bin/sh
# The Claude Code hooks' launcher: hooks/hooks.json runs it under /bin/sh,
# through env -u, and it runs issue.sh under a bash -p (no BASH_ENV, no
# function from the environment). The hooks run outside Claude Code's
# sandbox, so a bash, git, sed or jq a command in the project planted on
# PATH would run unsandboxed: every entry that is empty or relative (the
# hook's working directory, which follows the Bash tool's cd), gone, spelled
# physically with a colon (which would split it into a relative one), or
# lies, physically, at or under the project dir or the checkout of a session
# opened in a subdirectory or worktree: the nearest directory above whose
# .git git takes for a main checkout's (a real directory with no commondir,
# a plain HEAD reading as a ref or an object id, objects and refs), else the
# topmost one holding a .git at all and, with none git takes, the project a
# /.worktrees/ path names, since root resolution walks past a .git that is
# no repository, a link or a commondir, and a command can plant those. The rest
# is kept in its physical spelling, and the first bash left runs, once a -c :
# of it has: one that cannot run is refused, exit 2, as no bash is, since
# /bin/sh's own exit for an exec that fails (1, 126, 127) blocks nothing;
# a bash that goes between the two still gets that exit. bin/coddy
# drops those at or under the root it resolves too (unpath, the same walk).
# Shell builtins alone until then. POSIX sh, run without -p, which dash and
# BusyBox reject.
r=${CLAUDE_PROJECT_DIR:-$PWD} t='' w='' k='' h='[0-9a-fA-F]'
h=$h$h$h$h$h$h$h$h$h$h; h=$h$h$h$h
case $r in /*) c=$r
  while [ -n "$c" ]; do
    if [ -e "$c/.git" ] || [ -L "$c/.git" ]; then
      t=$c l=''
      [ ! -L "$c/.git" ] && [ -f "$c/.git/HEAD" ] && [ ! -L "$c/.git/HEAD" ] && [ -x "$c/.git/objects" ] && [ -x "$c/.git/refs" ] && [ ! -e "$c/.git/commondir" ] && [ ! -L "$c/.git/commondir" ] && { IFS= read -r l || :; } 2>/dev/null < "$c/.git/HEAD"
      # shellcheck disable=SC2254 # h is a pattern: 40 hex digits
      case $l in 'ref: refs/'*|'ref:refs/'*|$h*) k=1; break ;; esac
    fi
    c=${c%/*}
  done ;;
esac
[ -n "$k" ] || case $r in */.worktrees/*) w=${r%%/.worktrees/*} ;; esac
o() { x=$1; while [ -n "$x" ]; do { [ "$x" -ef "$r" ] || [ "$x" -ef "$t" ] || [ "$x" -ef "$w" ]; } && return 0; x=${x%/*}; done; return 1; }
s=$PATH: n='' b=''
while [ -n "$s" ]; do
  e=${s%%:*}; s=${s#*:}
  case $e in /*) d=$(cd -P "$e" 2>/dev/null && pwd -P) && ! o "$d" || continue ;; *) continue ;; esac
  case $d in *:*) continue ;; esac
  n=$n${n:+:}$d
  [ -n "$b" ] || [ ! -f "$d/bash" ] || [ ! -x "$d/bash" ] || b=$d/bash
done
[ -n "$b" ] || { printf '%s\n' "coddy: no bash on PATH outside the project at $r, so the coddy ${1-} hook cannot run, and the call is refused. An entry that is empty, relative or lies in the project is skipped, since a command in the project could plant a bash there." >&2; exit 2; }
PATH=$n
export PATH
"$b" -p -c : </dev/null >/dev/null 2>&1 || { printf '%s\n' "coddy: the bash at $b, the first on PATH outside the project, cannot run, so the coddy ${1-} hook cannot run, and the call is refused." >&2; exit 2; }
exec "$b" -p "${0%/*}/issue.sh" "$@"
