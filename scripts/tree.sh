#!/usr/bin/env bash
# Current branch and uncommitted changes, injected by /coddy:ship.
cd "${CLAUDE_PROJECT_DIR:-$PWD}" || exit 0
echo "branch: $(git branch --show-current 2>/dev/null || echo none)"
echo "uncommitted:"
git status --short 2>/dev/null | head -30
