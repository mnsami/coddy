#!/usr/bin/env bash
# The mutating half of coddy, and the guard that makes its rules binding.
#   issue.sh create <issue> <branch>   worktree at .worktrees/<issue> on <branch>
#   issue.sh claim  <issue> [--take]   lock the issue for this session, move it to In Progress
#   issue.sh push   <issue> [message]  commit what is uncommitted, then push
#   issue.sh sweep                     remove what issues with a merged PR left behind
#   issue.sh guard                     PreToolUse hook on Edit/Write (hooks/hooks.json)
#   issue.sh snap | trip               Pre/PostToolUse hooks on Bash
# An issue counts as In Progress once the lock .git/coddy/<issue>/ exists.
# Only claim makes it (mkdir, so of two sessions claiming at once one wins;
# a plain-file marker from before locks still counts until the next claim
# replaces it with a lock, tracker step and all); its owner
# file holds "<session> <pid>", plus "pending" until the tracker step went
# through, and another session's claim is refused unless --take is passed
# or the owner's pid no longer runs. guard rejects every edit that is not
# inside a claimed worktree (with "guard: warn" in the config it lets the
# edit through and says so).
# create records the issue's branch in .git/coddy/<issue>.branch, and push
# pushes that branch and no other.
# snap and trip fingerprint the main checkout around each shell command and
# reject the command's result when it left new changes there.
set -u

root="${CLAUDE_PROJECT_DIR:-$PWD}"
case "$root" in */.worktrees/*) root="${root%%/.worktrees/*}" ;; esac
conf="$root/.claude/coddy.yml"
code=1

# The process $1 runs. kill -0 needs no ps and sees this user's processes;
# /proc sees everyone's on Linux, where images without ps live; ps comes
# last, so a missing ps never reads as a dead owner. No pid counts as
# running, as claim reads it.
alive() { [ -z "$1" ] || kill -0 "$1" 2>/dev/null || [ -d "/proc/$1" ] || ps -p "$1" >/dev/null 2>&1; }
die() { echo "coddy: $*" >&2; exit "$code"; }
cfg() { sed -n "s/^$1:[[:space:]]*//p" "$conf" | sed "s/[[:space:]]*#.*$//; s/^[\"']//; s/[\"']$//" | head -1; }

if [ "${1-}" = guard ]; then
  [ -f "$conf" ] || exit 0
  code=2 # exit 2 is what blocks the tool call
  # guard: warn lets the edit through and hands Claude the message as context
  # instead. No permissionDecision, so the usual permission flow still applies.
  # jq fails only when it is missing, and then the one message is that it is.
  if [ "$(cfg guard)" = warn ]; then
    die() {
      jq -cn --arg m "coddy warning, the edit was let through (guard: warn): $*" '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $m}}' 2>/dev/null ||
        echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"coddy warning: the edit guard needs jq, so this edit was not checked."}}'
      exit 0
    }
  fi
  command -v jq >/dev/null || die "the edit guard needs jq"
  f=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')
  # ponytail: string-prefix match, so a symlinked path into the project slips
  # through; resolve with realpath if that ever matters.
  case "$f" in */../*) die "refusing a path containing '..': $f" ;; esac
  case "$f" in
    "$root"/.worktrees/*|"$root"/.claude/worktrees/*) # the second is where Claude Code puts its own worktrees
      issue="${f#"$root"/.worktrees/}"; issue="${issue#"$root"/.claude/worktrees/}"; issue="${issue%%/*}"
      [ -e "$root/.git/coddy/$issue" ] || die "issue $issue is not In Progress yet. Run /coddy:start $issue." ;;
    "$root"/.claude/*) ;;
    "$root"/*) die "edits belong in an issue worktree, not the main checkout. Run /coddy:start <issue>, then edit under .worktrees/<issue>/." ;;
  esac
  exit 0
fi

# The main checkout's fingerprint: one line per dirty path with its content
# hash, one for the default branch when it holds commits its remote branch
# does not, and one for HEAD when it has left the default branch. A detached
# HEAD on the default branch's own history counts as on it: that is where jj
# leaves a synced checkout. Paths, not git status codes: jj colocation flips
# untracked files to intent-to-add on its own.
# ponytail: one git hash-object per dirty file, so a checkout with thousands
# of dirty files slows every shell command; batch with --stdin-paths then.
snap() {
  cd "$root" 2>/dev/null || return 0
  b=$(cfg default_branch); b="${b:-main}"
  git merge-base --is-ancestor "refs/heads/$b" "refs/remotes/origin/$b" 2>/dev/null ||
    { tip=$(git rev-parse -q --verify "refs/heads/$b" 2>/dev/null) && echo "commits on $b $tip"; }
  at=$(git symbolic-ref -q --short HEAD 2>/dev/null); h=$(git rev-parse HEAD 2>/dev/null)
  if [ -n "$at" ]; then
    [ "$at" = "$b" ] || echo "branch $at $h"
  elif ! git merge-base --is-ancestor HEAD "refs/remotes/origin/$b" 2>/dev/null; then
    echo "detached HEAD $h"
  fi
  git status --porcelain -uall -z 2>/dev/null | while IFS= read -r -d '' e; do
    p="${e:3}"
    case "$p" in .claude/*) continue ;; esac
    if [ -f "$p" ]; then printf '%s %s\n' "$p" "$(git hash-object -- "$p")"; else printf '%s gone\n' "$p"; fi
  done
}

if [ "${1-}" = snap ] || [ "${1-}" = trip ]; then
  id=$(jq -r '.tool_use_id // empty' 2>/dev/null)
  file="${TMPDIR:-/tmp}/coddy-snap-$(printf %s "$root" | cksum | cut -d' ' -f1)-${id:-shared}"
  if [ "$1" = snap ]; then
    [ -f "$conf" ] || exit 0
    snap | LC_ALL=C sort > "$file"; cp "$conf" "$file.conf"; exit 0
  fi
  # A snapshot means the project was onboarded when the command started, so
  # trip must not look at the config first: the command may have removed it.
  [ -f "$file" ] || exit 0
  code=2 msg=""
  # The config is the off switch for every hook here, so a shell command may
  # not change it: put it back. A config identical to the one committed at
  # HEAD came from git (a pull, a checkout) and stands.
  head=$(git -C "$root" rev-parse -q --verify HEAD:.claude/coddy.yml 2>/dev/null)
  if ! cmp -s "$conf" "$file.conf" && ! { [ -f "$conf" ] && [ -n "$head" ] && [ "$(git hash-object "$conf")" = "$head" ]; }; then
    mkdir -p "$root/.claude" && cp "$file.conf" "$conf"
    msg="that command changed .claude/coddy.yml, which switches the coddy guardrails, so it has been restored. Settings change through /coddy:config; leaving the workflow is for the user to do by hand. "
  fi
  # Only lines that are new count, so undoing a change never trips the wire.
  added=$(snap | LC_ALL=C sort | LC_ALL=C comm -13 "$file" - | sed 's/ [^ ]*$//' | tr '\n' ' ' | sed 's/ $//')
  rm -f "$file" "$file.conf"
  [ -n "$added" ] && msg="${msg}that command changed the main checkout: $added. Issue work belongs in .worktrees/<issue>/. Undo it."
  [ -z "$msg" ] && exit 0
  die "$msg"
fi

[ -f "$conf" ] || { [ "${1-}" = sweep ] && exit 0; die "NOT_ONBOARDED"; }
cd "$root" || die "cannot enter $root"
cmd="${1-}" issue="${2-}"
[ "$cmd" = sweep ] || case "$issue" in ''|*[!A-Za-z0-9_-]*) die "issue id must look like 42 or ABC-123, got '$issue'" ;; esac
wt=".worktrees/$issue" rec=".git/coddy/$issue.branch"
tool=$(cfg worktree); tool="${tool:-jj}"
base=$(cfg default_branch); base="${base:-main}"

# The worktree sits on branch $1: checked out (git), an ancestor of @ (jj).
on() {
  if [ "$tool" = jj ]; then
    [ -n "$(jj -R "$wt" log --no-graph -r "bookmarks(exact:\"$1\") & ::@" -T '"x"' 2>/dev/null)" ]
  else
    [ "$(git -C "$wt" branch --show-current)" = "$1" ]
  fi
}
record() { mkdir -p .git/coddy && echo "$branch" > "$rec" || die "could not record the branch"; }
has() { [ -n "$(jj log --no-graph -r "$1" -T '"x"' 2>/dev/null)" ]; } # a jj revset matches
# "<number> <state> <head commit>" of the PR for branch $1, an open one
# first; nothing when there is none or gh fails.
pr() { gh pr list --head "$1" --state all --json number,state,headRefOid --jq '(map(select(.state == "OPEN"))[0] // .[0] // empty) | "\(.number) \(.state) \(.headRefOid)"' 2>/dev/null; }

case "$cmd" in
  create)
    branch="${3-}"; [ -n "$branch" ] || die "usage: issue.sh create <issue> <branch>"
    [ "$branch" != "$base" ] || die "$base is the default branch, not an issue branch"
    other=$(grep -lxF -- "$branch" .git/coddy/*.branch 2>/dev/null | grep -vxF -- "$rec" | head -1)
    [ -z "$other" ] || die "branch $branch belongs to issue $(basename "$other" .branch)"
    if [ -d "$wt" ]; then
      if [ -s "$rec" ]; then
        [ "$(cat "$rec")" = "$branch" ] || die "$wt is on $(cat "$rec"), not $branch"
      else
        # A worktree from before the branch was recorded: record it now, but
        # only a branch the worktree really is on.
        on "$branch" || die "$wt is not on $branch"
        record
      fi
      echo "exists: $wt"; exit 0
    fi
    mkdir -p .worktrees
    git check-ignore -q .worktrees || echo '.worktrees/' >> .git/info/exclude
    # A branch that exists, here or only on the remote, is continued; any
    # other name starts a new branch from $base.
    if [ "$tool" = jj ]; then
      command -v jj >/dev/null || die "jj is not installed. Install it or set 'worktree: git' in .claude/coddy.yml."
      [ -d .jj ] || die "this repo is not jj-backed. Ask the user, then run: jj git init --colocate && echo '.jj/' >> .git/info/exclude"
      jj git fetch || die "fetch failed"
      mine="bookmarks(exact:\"$branch\")"
      if ! has "$mine" && has "remote_bookmarks(exact:\"$branch\", exact:\"origin\")"; then
        jj bookmark track "$branch@origin" || die "could not track $branch@origin"
      fi
      if has "$mine"; then
        jj workspace add --name "$issue" -r "\"$branch\"" "$wt" || die "could not create the jj workspace"
      else
        jj workspace add --name "$issue" -r "$base@origin" "$wt" || die "could not create the jj workspace"
        jj -R "$wt" bookmark create "$branch" -r @ || die "could not create branch $branch"
      fi
    else
      git fetch origin || die "fetch failed"
      if git show-ref -q "refs/heads/$branch" "refs/remotes/origin/$branch"; then
        git worktree add "$wt" "$branch" || die "could not create the git worktree"
      else
        git worktree add --no-track -b "$branch" "$wt" "origin/$base" || die "could not create the git worktree"
      fi
    fi
    record
    echo "created: $wt on $branch" ;;

  claim)
    [ -d "$wt" ] || die "create the worktree first: issue.sh create $issue <branch>"
    lock=".git/coddy/$issue" me="${CLAUDE_CODE_SESSION_ID-}" note="" own="" n="" state=""
    # A marker from before claims were locks is a plain file: nobody owns it;
    # the claim replaces it. rm -f never removes the lock another session
    # just made of it, so the mkdir race stays atomic.
    [ -f "$lock" ] && rm -f "$lock"
    mkdir -p .git/coddy || die "could not record the claim"
    if ! mkdir "$lock" 2>/dev/null; then
      for i in 1 2 3 4 5; do [ -s "$lock/owner" ] && break; sleep 0.1; done # the winner writes owner right after its mkdir
      own=$(cat "$lock/owner" 2>/dev/null) # "<session> <pid>", plus "pending" until the tracker step went through
      sid="${own%% *}" pid="${own#* }"; pid="${pid%% *}"
      if [ ! -s "$lock/owner" ]; then
        # A claim in flight, or one that died between its mkdir and its owner line.
        [ "${3-}" = --take ] || die "issue $issue is being claimed right now, or that claim died halfway: retry, or take it over with bash \"$0\" claim $issue --take"
      elif [ "$sid" = "$me" ] && [ "${own##* }" != pending ]; then
        # --resume keeps the session id and changes the pid: the lock follows it.
        [ "$own" = "$me ${CLAUDE_PID-}" ] || echo "$me ${CLAUDE_PID-}" > "$lock/owner"
        echo "in progress: $issue (already claimed by this session)"; exit 0
      elif [ "$sid" = "$me" ]; then own="" # mine, but it died before its tracker step: redo it as a fresh claim
      elif [ "${3-}" = --take ]; then note="taken over: $issue from session $sid (--take)"
      elif ! alive "$pid"; then note="taken over: $issue from session $sid (pid $pid is not running)"
      else die "issue $issue is claimed by session $sid (pid $pid, running). To take it over deliberately: bash \"$0\" claim $issue --take"
      fi
    fi
    # A claim that fails from here on leaves no lock behind; a takeover that
    # fails hands the lock back to its owner as it was. A kill runs no trap,
    # so the owner line says pending until the tracker step went through.
    trap 'if [ -n "$own" ]; then echo "$own" > "$lock/owner"; else rm -rf "$lock"; fi' EXIT
    echo "$me ${CLAUDE_PID-} pending" > "$lock/owner" || die "could not record the claim"
    # An open PR puts the issue past In Progress: the label stays off, but
    # the assignee is what the PR check reads, so it is still taken.
    branch=$(cat "$rec" 2>/dev/null)
    [ -z "$branch" ] || read -r n state _ <<<"$(pr "$branch")"
    if [ "$(cfg tracker)" != jira ]; then
      if [ "$state" = OPEN ]; then
        gh issue edit "$issue" --add-assignee @me >/dev/null || die "could not assign #$issue"
      else
        gh label create "in progress" >/dev/null 2>&1
        gh issue edit "$issue" --add-assignee @me --add-label "in progress" >/dev/null || die "could not move #$issue to In Progress"
        gh issue view "$issue" --json labels --jq '.labels[].name' | grep -qx "in progress" || die "#$issue does not carry the 'in progress' label"
      fi
    fi
    # ponytail: Jira is reachable only through MCP tools, so for jira this
    # records the transition the skill just made instead of verifying it.
    # Upgrade path: a PostToolUse hook on the Atlassian transition tool.
    echo "$me ${CLAUDE_PID-}" > "$lock/owner" || die "could not record the claim"
    trap - EXIT
    [ -z "$note" ] || echo "$note"
    if [ "$state" = OPEN ]; then echo "claimed: $issue (PR #$n is open, assigned without the label)"
    else echo "in progress: $issue"; fi ;;

  push)
    msg="${3-}"
    [ -d "$wt" ] || die "no worktree for $issue. Run /coddy:start $issue."
    [ -e ".git/coddy/$issue" ] || die "issue $issue is not In Progress. Run /coddy:start $issue."
    # The branch create recorded, never one read off the history: once $base
    # is merged in, the history holds the branches of merged issues too.
    branch=$(cat "$rec" 2>/dev/null)
    [ -n "$branch" ] || die "no branch recorded for $issue. Record it: issue.sh create $issue <branch>"
    [ "$branch" != "$base" ] && on "$branch" || die "$wt is not on issue branch $branch"
    if [ "$tool" = jj ]; then dirty=$(jj -R "$wt" diff --summary); else dirty=$(git -C "$wt" status --porcelain); fi
    if [ -n "$dirty" ]; then
      [ -n "$msg" ] || die "uncommitted changes in $wt: pass a commit message"
      if [ "$tool" = jj ]; then
        jj -R "$wt" commit -m "$msg" || die "commit failed"
      else
        git -C "$wt" add -A && git -C "$wt" commit -q -m "$msg" || die "commit failed"
      fi
    fi
    if [ "$tool" = jj ]; then
      jj -R "$wt" bookmark set "$branch" -r @- || die "nothing committed on $branch"
      jj -R "$wt" git push --bookmark "$branch" || die "push failed"
    else
      git -C "$wt" push -u origin HEAD || die "push failed"
    fi
    echo "pushed: $branch" ;;

  sweep)
    # Runs at skill load (next, start): quiet, never failing, and whatever it
    # cannot prove finished stays. Finished means the branch's PR is merged
    # and the worktree holds nothing beyond that PR's last commit.
    for rec in .git/coddy/*.branch; do
      issue=$(basename "$rec" .branch); wt=".worktrees/$issue"; branch=$(cat "$rec" 2>/dev/null)
      case "$issue" in ''|*[!A-Za-z0-9_-]*) continue ;; esac
      [ -n "$branch" ] && [ -e ".git/coddy/$issue" ] && [ -d "$wt" ] || continue
      # ponytail: compared as strings, so a session that reached its
      # worktree through a symlink is not recognised as being inside it.
      case "${CLAUDE_PROJECT_DIR-}/ $OLDPWD/" in *"$root/$wt/"*) continue ;; esac
      read -r n state oid <<<"$(pr "$branch")"
      [ "$state" = MERGED ] || continue
      if [ "$tool" = jj ]; then
        tip=$(jj -R "$wt" log --no-graph -r @- -T commit_id 2>/dev/null); dirty=$(jj -R "$wt" diff --summary 2>/dev/null)
      else
        tip=$(git -C "$wt" rev-parse HEAD 2>/dev/null); dirty=$(git -C "$wt" status --porcelain 2>/dev/null)
      fi
      [ -n "$tip" ] || continue
      if [ -n "$dirty" ] || [ "$tip" != "$oid" ]; then
        echo "kept: $issue (PR #$n merged, but $wt holds work that is not in it)"; continue
      fi
      if [ "$tool" = jj ]; then
        jj workspace forget "$issue" >/dev/null 2>&1 || continue
        rm -rf "$wt"; jj bookmark forget "$branch" >/dev/null 2>&1
      else
        git worktree remove "$wt" >/dev/null 2>&1 || continue
        git branch -D "$branch" >/dev/null 2>&1
      fi
      rm -rf ".git/coddy/$issue" "$rec"; echo "cleaned: $issue"
    done
    exit 0 ;;

  *) die "usage: issue.sh create <issue> <branch> | claim <issue> [--take] | push <issue> [message] | sweep | guard" ;;
esac
