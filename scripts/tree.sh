#!/usr/bin/env bash
# The project root and its claimed issue worktrees, injected by /coddy:start,
# /coddy:ship, /coddy:config and /coddy:next. A directory under .worktrees/
# counts only once issue.sh claim has recorded it, so worktrees coddy did not
# create are never listed. Each is printed as issue=branch, with the branch
# issue.sh create recorded, and again under owners as issue=<owner>: me when
# the lock is this session's (the same session id, or the same Claude Code
# process, since /clear changes the id and not the pid: issue.sh's mine()),
# another session's id with (running) or (gone) by its pid, read the way
# issue.sh's alive() reads it (kill -0, /proc, then ps; no pid counts as
# running), or unknown for a marker from before locks or an owner line that
# names no session.
root="${CLAUDE_PROJECT_DIR:-$PWD}"
case "$root" in */.worktrees/*) root="${root%%/.worktrees/*}" ;; esac
cd "$root" || exit 0
echo "root: $root"
echo "jj_repo: $([ -d .jj ] && echo yes || echo no)"
echo "worktrees: $(for d in .worktrees/*/; do n=$(basename "$d"); [ -e ".git/coddy/$n" ] || continue; b=$(cat ".git/coddy/$n.branch" 2>/dev/null); printf '%s ' "$n${b:+=$b}"; done)"
echo "owners: $(for d in .worktrees/*/; do n=$(basename "$d"); [ -e ".git/coddy/$n" ] || continue
  own=$(cat ".git/coddy/$n/owner" 2>/dev/null); sid="${own%% *}" pid="${own#* }"; pid="${pid%% *}"
  if [ -z "$sid" ]; then o=unknown
  elif [ "$sid" = "${CLAUDE_CODE_SESSION_ID-}" ] || { [ -n "$pid" ] && [ "$pid" = "${CLAUDE_PID-}" ]; }; then o=me
  elif [ -z "$pid" ] || kill -0 "$pid" 2>/dev/null || [ -d "/proc/$pid" ] || ps -p "$pid" >/dev/null 2>&1; then o="$sid (running)"; else o="$sid (gone)"; fi
  printf '%s ' "$n=$o"; done)"
