#!/usr/bin/env bash
# The project root and its claimed issue worktrees, injected by /coddy:start
# and /coddy:ship. A directory under .worktrees/ counts only once issue.sh
# claim has recorded it, so worktrees coddy did not create are never listed.
# Each is printed as issue=branch, with the branch issue.sh create recorded.
root="${CLAUDE_PROJECT_DIR:-$PWD}"
case "$root" in */.worktrees/*) root="${root%%/.worktrees/*}" ;; esac
cd "$root" || exit 0
echo "root: $root"
echo "jj_repo: $([ -d .jj ] && echo yes || echo no)"
echo "worktrees: $(for d in .worktrees/*/; do n=$(basename "$d"); [ -e ".git/coddy/$n" ] || continue; b=$(cat ".git/coddy/$n.branch" 2>/dev/null); printf '%s ' "$n${b:+=$b}"; done)"
