#!/usr/bin/env bash
# Claude Code adapter: hands Claude's environment to the core as its HERMY_*
# inputs, always, so an inherited HERMY_* value (a settings env, a hostile
# shell) is ignored, drops every GIT_* but the identity, ssh and credential-prompt ones (a
# GIT_DIR there would resolve the root in another repository, where no
# config is), and runs bin/hermy with the arguments as they are. Sourced,
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
# has none, so it never repoints the launcher an installed hermy keeps. link,
# the SessionStart hook, which needs no project and whose output is the
# model's context, points it at this install's bin/hermy, given that dir
# alone; start has the hooks run it once it is there. An inherited HERMY_EXEC,
# HERMY_BUDGET or HERMY_GUARD_BUDGET (the fingerprint's and the guard's
# seconds, the self-test's to lower) or HERMY_ASK (Claude Code can ask) is
# ignored, as every HERMY_* is.
# A hook blocks only on exit 2, so any other exit of guard or snap, a core
# that cannot be read included, becomes a 2 here with a message naming what
# to do in plain text: a hermy crash blocks every such call until hermy is
# fixed or turned off. A timeout, or a hook that cannot start, blocks them
# through hooks.json's onFailure on Claude Code 2.1.295 or later, and lets
# the call through before it. trip and link keep theirs.
# shellcheck disable=SC2154 # c is the trap's own
case "${1-}" in guard|snap) trap 'c=$?; [ "$c" = 0 ] || [ "$c" = 2 ] || { echo "hermy: the '"$1"' hook failed (exit $c), so the call is refused. The failure lies in hermy, not in the call (its error, if any, is above), and every such call is refused until the user updates or reinstalls the hermy plugin, or disables it." >&2; exit 2; }' EXIT ;; esac
for v in "${!GIT_@}"; do case $v in GIT_AUTHOR_*|GIT_COMMITTER_*|GIT_SSH*|GIT_ASKPASS|GIT_TERMINAL_PROMPT) ;; *) unset "$v" ;; esac; done
unset HERMY_EXEC HERMY_BUDGET HERMY_GUARD_BUDGET HERMY_ASK
case "${1-}" in link|start|create)
  d=$(cd -P "${0%/*}/.." 2>/dev/null && pwd -P); d=${d%/*}; id=${d##*/}; d=${d%/*}; id="$id@${d##*/}"; d=${d%/*}
  case "$d" in */plugins/cache) d="${d%/cache}/data/${id//[!A-Za-z0-9_-]/-}" ;; *) d="" ;; esac
  if [ "$1" = link ]; then { [ -n "$d" ] && [ -d "$d" ] && [ "$d" -ef "${2-}" ]; } || exit 0
  elif [ -n "$d" ] && [ -x "$d/hermy" ]; then export HERMY_EXEC="$d/hermy"; fi
  unset d id ;;
esac
case "${1-}" in guard|snap|trip|link) ;; *)
  real=$(case "${CLAUDE_PROJECT_DIR-}" in (/*) cd "$CLAUDE_PROJECT_DIR" 2>/dev/null && pwd -P ;; esac)
  case "$(pwd -P)/" in "${real:-//}"/*) ;; *) CLAUDE_PROJECT_DIR=$PWD ;; esac
  unset real ;;
esac
# HERMY_HOOKS: Claude Code runs hermy's shell hooks, so start and claim print
# hooks: off, with the causes, when snap left no mark for this session
# before them.
HERMY_HOOKS=1
HERMY_ROOT="${CLAUDE_PROJECT_DIR-}" HERMY_SESSION="${CLAUDE_CODE_SESSION_ID-}" HERMY_PID="${CLAUDE_PID-}" HERMY_AGENT_DIR=.claude
export HERMY_ROOT HERMY_SESSION HERMY_PID HERMY_AGENT_DIR HERMY_HOOKS
# Claude Code's hook payload as the core's neutral input. The call id and
# session are read with sed, as the core did, so snap without jq and trip with
# it name the same snapshot. With jq the session is the payload's top-level
# session_id while that is a plain word ([A-Za-z0-9_-], as Claude Code's
# are), which sed reads alike, so a session_id key inside tool_input, the
# last one sed finds, never names the guard's owner; any other is passed as
# sed read it on both branches: its JSON spelling (a \u escape kept, not
# decoded), control characters dropped, which jq would print as \u escapes
# on one side alone.
# paths holds file_path and notebook_path both, when both are there, so the
# guard holds the edit to each; a non-null one that is no string fails jq.
# When jq is missing or fails, the raw payload rides along after a word that
# is no JSON, so the core's jq fails on it and refuses.
hermy_in() {
  local r id ss
  r=$(cat)
  id=$(sed -n 's/.*"tool_use_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$r" 2>/dev/null | head -n1)
  ss=$(sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$r" 2>/dev/null | head -n1)
  ss=${ss//[[:cntrl:]]/}
  if command -v jq >/dev/null && o=$(jqh -cn --arg c "$id" --arg s "$ss" '[inputs] | if length == 1 then .[0] | {paths: [.tool_input | objects | (.file_path, .notebook_path) | select(. != null) | if type == "string" then . else error("a path that is not a string") end], command: (.tool_input.command // ""), cwd: (.cwd // ""), call: $c, session: (.session_id | if type == "string" then (if [explode[] | select((. < 48 or . > 57) and (. < 65 or . > 90) and (. < 97 or . > 122) and . != 45 and . != 95)] == [] then . else $s end) else $s end)} else error("not one value") end' <<<"$r" 2>/dev/null); then
    printf '%s\n' "$o"
  else
    printf 'hermy-unreadable %s "call":"%s","session":"%s"\n' "$r" "$id" "$ss"
  fi
}
# The core's verdict line as Claude Code's hook JSON, by parameter expansion
# alone: the text is already a JSON string, so it moves over byte for byte.
# A line that is neither verdict refuses the call (exit 2), so an ask is
# never let through without its permissionDecision.
hermy_out() {
  local l=$1 n='{"hermy":"note","text":' a='{"hermy":"ask","text":'
  if [[ $l == "$n"*'}' ]]; then
    l=${l#"$n"}
    printf '%s\n' "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"additionalContext\":${l%\}}}}"
  elif [[ $l == "$a"*'}' ]]; then
    l=${l#"$a"}
    printf '%s\n' "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"ask\",\"permissionDecisionReason\":${l%\}}}}"
  else
    echo "hermy: the hook's verdict could not be read, so the call is refused. The failure lies in hermy, not in the call, and every such call is refused until the user updates or reinstalls the hermy plugin, or disables it." >&2
    exit 2
  fi
}
. "${0%/*}/../bin/hermy"
