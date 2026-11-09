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
# a plain HEAD whose first 255 bytes, as git reads them, read as a ref or an
# object id up to a NUL, objects and refs), else the
# topmost one holding a .git at all and, with none git takes, the project a
# /.worktrees/ path names, since root resolution walks past a .git that is
# no repository, a link or a commondir, and a command can plant those. An
# entry is followed a component at a time (f, as bin/coddy's follow does), so
# its own spelling and every link on the way count, not only where it lands:
# a link in the project a command repointed outside it, or one outside that
# goes through one there. A link is read with /usr/bin/readlink,
# /bin/readlink or NixOS's /run/current-system/sw/bin/readlink, never one on
# PATH; with none, an entry with a link on the way is dropped. A HEAD is
# read the same way, with a head and a tr at those paths, so a huge one
# stalls no hook; with none, no .git is taken. The rest is kept in its physical spelling, and the first
# bash left runs, once a -c : of it has: one that cannot run is refused,
# exit 2, as no bash is, since /bin/sh's own exit for an exec that fails (1,
# 126, 127) blocks nothing; a bash that goes between the two still gets that
# exit. bin/coddy drops those at or under the root it resolves too (unpath,
# the same walk). Shell builtins alone until then, readlink, head and tr aside.
# POSIX sh, run without -p, which dash and BusyBox reject.
r=${CLAUDE_PROJECT_DIR:-$PWD} t='' w='' k='' h='[0-9a-fA-F]' g='' v=''
h=$h$h$h$h$h$h$h$h$h$h; h=$h$h$h$h
for y in /usr/bin/head /bin/head /run/current-system/sw/bin/head; do [ -n "$g" ] || [ ! -f "$y" ] || [ ! -x "$y" ] || g=$y; done
for y in /usr/bin/tr /bin/tr /run/current-system/sw/bin/tr; do [ -n "$v" ] || [ ! -f "$y" ] || [ ! -x "$y" ] || v=$y; done
case $r in /*) c=$r
  while [ -n "$c" ]; do
    if [ -e "$c/.git" ] || [ -L "$c/.git" ]; then
      t=$c l=''
      [ -n "$g" ] && [ -n "$v" ] && [ ! -L "$c/.git" ] && [ -f "$c/.git/HEAD" ] && [ ! -L "$c/.git/HEAD" ] && [ -x "$c/.git/objects" ] && [ -x "$c/.git/refs" ] && [ ! -e "$c/.git/commondir" ] && [ ! -L "$c/.git/commondir" ] && { l=$("$g" -c 255 < "$c/.git/HEAD" | LC_ALL=C "$v" '\000' '\n'); } 2>/dev/null
      # shellcheck disable=SC2254 # h is a pattern: 40 hex digits
      case $l in 'ref: refs/'*|'ref:refs/'*|$h*) k=1; break ;; esac
    fi
    c=${c%/*}
  done ;;
esac
[ -n "$k" ] || case $r in */.worktrees/*) w=${r%%/.worktrees/*} ;; esac
o() { x=$1; while [ -n "$x" ]; do { [ "$x" -ef "$r" ] || [ "$x" -ef "$t" ] || [ "$x" -ef "$w" ]; } && return 0; x=${x%/*}; done; return 1; }
q='' nl='
'
for y in /usr/bin/readlink /bin/readlink /run/current-system/sw/bin/readlink; do [ -n "$q" ] || [ ! -f "$y" ] || [ ! -x "$y" ] || q=$y; done
# f: absolute path $1 followed into d, physical; status 1 when it cannot be
# (past 40 links, a step that is no directory, a link unread), or when any
# directory on the way, or d, lies at or under the project (o).
f() {
  p=$1 d='' i=0
  while [ -n "$p" ]; do
    [ -d "${d:-/}" ] && ! o "$d" || return 1
    c=${p%%/*}; case $p in */*) p=${p#*/}; p=${p:-.} ;; *) p='' ;; esac
    case $c in ''|.) continue ;; ..) d=${d%/*}; continue ;; esac
    if [ -L "$d/$c" ]; then
      [ "$i" -lt 40 ] && [ -n "$q" ] || return 1
      i=$((i + 1))
      y=$("$q" -n "$d/$c" 2>/dev/null && printf x) || { y=$("$q" "$d/$c" 2>/dev/null && printf x) && case $y in *"$nl"x) y=${y%?x}x ;; *) false ;; esac; } || return 1
      y=${y%x}
      case $y in '') return 1 ;; /*) d='' ;; esac
      p=$y${p:+/$p}
    else d=$d/$c; fi
  done
  d=${d:-/}
  [ -d "$d" ] && ! o "$d"
}
s=$PATH: n='' b=''
while [ -n "$s" ]; do
  e=${s%%:*}; s=${s#*:}
  case $e in /*) f "$e" || continue ;; *) continue ;; esac
  case $d in *:*) continue ;; esac
  n=$n${n:+:}$d
  [ -n "$b" ] || [ ! -f "$d/bash" ] || [ ! -x "$d/bash" ] || b=$d/bash
done
[ -n "$b" ] || { printf '%s\n' "coddy: no bash on PATH outside the project at $r, so the coddy ${1-} hook cannot run, and the call is refused. An entry that is empty, relative or lies in the project is skipped, since a command in the project could plant a bash there." >&2; exit 2; }
PATH=$n
export PATH
"$b" -p -c : </dev/null >/dev/null 2>&1 || { printf '%s\n' "coddy: the bash at $b, the first on PATH outside the project, cannot run, so the coddy ${1-} hook cannot run, and the call is refused." >&2; exit 2; }
exec "$b" -p "${0%/*}/issue.sh" "$@"
