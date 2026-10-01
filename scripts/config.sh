#!/usr/bin/env bash
# Prints the project's coddy config, or NOT_ONBOARDED. Every skill except
# onboard injects this and stops on NOT_ONBOARDED.
root="${CLAUDE_PROJECT_DIR:-$PWD}"
case "$root" in */.worktrees/*) root="${root%%/.worktrees/*}" ;; esac
f="$root/.claude/coddy.yml"
if [ -f "$f" ]; then cat "$f"; else echo "NOT_ONBOARDED"; fi
