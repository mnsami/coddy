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
for v in "${!GIT_@}"; do case $v in GIT_AUTHOR_*|GIT_COMMITTER_*|GIT_SSH*|GIT_ASKPASS|GIT_TERMINAL_PROMPT) ;; *) unset "$v" ;; esac; done
case "${1-}" in guard|snap|trip) ;; *)
  real=$(case "${CLAUDE_PROJECT_DIR-}" in (/*) cd "$CLAUDE_PROJECT_DIR" 2>/dev/null && pwd -P ;; esac)
  case "$(pwd -P)/" in "${real:-//}"/*) ;; *) CLAUDE_PROJECT_DIR=$PWD ;; esac
  unset real ;;
esac
CODDY_ROOT="${CLAUDE_PROJECT_DIR-}" CODDY_SESSION="${CLAUDE_CODE_SESSION_ID-}" CODDY_PID="${CLAUDE_PID-}" CODDY_AGENT_DIR=.claude
export CODDY_ROOT CODDY_SESSION CODDY_PID CODDY_AGENT_DIR
. "${0%/*}/../bin/coddy"
