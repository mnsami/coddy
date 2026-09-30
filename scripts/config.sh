#!/usr/bin/env bash
# Prints the project's coddy config, or NOT_ONBOARDED. Every skill except
# onboard injects this and stops on NOT_ONBOARDED.
f="${CLAUDE_PROJECT_DIR:-$PWD}/.claude/coddy.yml"
if [ -f "$f" ]; then cat "$f"; else echo "NOT_ONBOARDED"; fi
