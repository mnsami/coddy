#!/usr/bin/env bash
# Claude Code adapter: hands Claude's environment to the core as its CODDY_*
# inputs, always, so an inherited CODDY_* value (a settings env, a hostile
# shell) is ignored, drops every GIT_* but the identity, ssh and credential-prompt ones (a
# GIT_DIR there would resolve the root in another repository, where no
# config is), and runs bin/coddy with the arguments as they are. Sourced,
# not exec'd, so the core names this shim in its messages, as the skills'
# allowed-tools do.
# For a Bash-tool verb, CLAUDE_PROJECT_DIR is taken only when it is absolute
# and the working directory is it or under it: a settings env overrides it in
# the Bash tool's environment and cannot set PWD. Compared by real path, since
# a session opened through a symlink has PWD in the link's spelling and the
# project dir in the real one. The hooks (guard, snap, trip) take it as it is:
# they get the real one, and their working directory follows the Bash tool's
# cd, so held to it a cd out of the project would drop the root.
# The launcher the git hooks run lives in the plugin's data dir, found by
# Claude Code's layout: an install at <P>/plugins/cache/<marketplace>/<plugin>/<version>
# keeps it at <P>/plugins/data/<id>, <id> being <plugin>@<marketplace> with
# every character but A-Za-z0-9_- made a -. Any other install (--plugin-dir)
# has none, so it never repoints the launcher an installed coddy keeps. link,
# the SessionStart hook, which needs no project and whose output is the
# model's context, points it at this install's bin/coddy, given that dir
# alone; start has the hooks run it once it is there. An inherited CODDY_EXEC
# is ignored, as every CODDY_* is.
# guard and snap run with onFailure: block (hooks/hooks.json), so any exit
# but 0 or 2 blocks the call with no reason given: here it becomes a 2 with
# a message, a core that cannot be read included, which names what to do in
# plain text: on any Claude Code it blocks every such call until coddy is
# fixed or turned off. trip and link keep theirs.
# shellcheck disable=SC2154 # c is the trap's own
case "${1-}" in guard|snap) trap 'c=$?; [ "$c" = 0 ] || [ "$c" = 2 ] || { echo "coddy: the '"$1"' hook failed (exit $c), so the call is refused. The failure lies in coddy, not in the call (its error, if any, is above), and every such call is refused until the user updates or reinstalls the coddy plugin, or disables it." >&2; exit 2; }' EXIT ;; esac
for v in "${!GIT_@}"; do case $v in GIT_AUTHOR_*|GIT_COMMITTER_*|GIT_SSH*|GIT_ASKPASS|GIT_TERMINAL_PROMPT) ;; *) unset "$v" ;; esac; done
unset CODDY_EXEC
case "${1-}" in link|start|create)
  d=$(cd -P "${0%/*}/.." 2>/dev/null && pwd -P); d=${d%/*}; id=${d##*/}; d=${d%/*}; id="$id@${d##*/}"; d=${d%/*}
  case "$d" in */plugins/cache) d="${d%/cache}/data/${id//[!A-Za-z0-9_-]/-}" ;; *) d="" ;; esac
  if [ "$1" = link ]; then { [ -n "$d" ] && [ -d "$d" ] && [ "$d" -ef "${2-}" ]; } || exit 0
  elif [ -n "$d" ] && [ -x "$d/coddy" ]; then export CODDY_EXEC="$d/coddy"; fi
  unset d id ;;
esac
case "${1-}" in guard|snap|trip|link) ;; *)
  real=$(case "${CLAUDE_PROJECT_DIR-}" in (/*) cd "$CLAUDE_PROJECT_DIR" 2>/dev/null && pwd -P ;; esac)
  case "$(pwd -P)/" in "${real:-//}"/*) ;; *) CLAUDE_PROJECT_DIR=$PWD ;; esac
  unset real ;;
esac
CODDY_ROOT="${CLAUDE_PROJECT_DIR-}" CODDY_SESSION="${CLAUDE_CODE_SESSION_ID-}" CODDY_PID="${CLAUDE_PID-}" CODDY_AGENT_DIR=.claude
export CODDY_ROOT CODDY_SESSION CODDY_PID CODDY_AGENT_DIR
. "${0%/*}/../bin/coddy"
