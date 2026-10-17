#!/usr/bin/env bash
# Claude Code adapter: hands Claude's environment to the core as its CODDY_*
# inputs, always, so an inherited CODDY_* value (a settings env, a hostile
# shell) is ignored, drops every GIT_* but the identity, ssh and credential-prompt ones (a
# GIT_DIR there would resolve the root in another repository, where no
# config is), and runs bin/coddy with the arguments as they are. Sourced,
# not exec'd, so the core names this shim in its messages, as the skills'
# allowed-tools do.
for v in "${!GIT_@}"; do case $v in GIT_AUTHOR_*|GIT_COMMITTER_*|GIT_SSH*|GIT_ASKPASS|GIT_TERMINAL_PROMPT) ;; *) unset "$v" ;; esac; done
CODDY_ROOT="${CLAUDE_PROJECT_DIR-}" CODDY_SESSION="${CLAUDE_CODE_SESSION_ID-}" CODDY_PID="${CLAUDE_PID-}" CODDY_AGENT_DIR=.claude
export CODDY_ROOT CODDY_SESSION CODDY_PID CODDY_AGENT_DIR
. "${0%/*}/../bin/coddy"
