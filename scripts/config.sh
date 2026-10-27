#!/usr/bin/env bash
# Claude Code adapter for the config verb: the project's coddy config, or
# NOT_ONBOARDED. Every skill except onboard injects this and stops on it.
for v in "${!GIT_@}"; do case $v in GIT_AUTHOR_*|GIT_COMMITTER_*|GIT_SSH*|GIT_ASKPASS|GIT_TERMINAL_PROMPT) ;; *) unset "$v" ;; esac; done
real=$(case "${CLAUDE_PROJECT_DIR-}" in (/*) cd "$CLAUDE_PROJECT_DIR" 2>/dev/null && pwd -P ;; esac)
case "$(pwd -P)/" in "${real:-//}"/*) ;; *) CLAUDE_PROJECT_DIR=$PWD ;; esac
unset real
CODDY_ROOT="${CLAUDE_PROJECT_DIR-}" CODDY_SESSION="${CLAUDE_CODE_SESSION_ID-}" CODDY_PID="${CLAUDE_PID-}" CODDY_AGENT_DIR=.claude
export CODDY_ROOT CODDY_SESSION CODDY_PID CODDY_AGENT_DIR
. "${0%/*}/../bin/coddy" config
