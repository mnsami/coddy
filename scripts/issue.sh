#!/usr/bin/env bash
# The mutating half of coddy, and the guard that makes its rules binding.
#   issue.sh create <issue> <branch>   worktree at .worktrees/<issue> on <branch>
#   issue.sh claim  <issue>            move the issue to In Progress, record it
#   issue.sh push   <issue> [message]  commit what is uncommitted, then push
#   issue.sh guard                     PreToolUse hook on Edit/Write (hooks/hooks.json)
#   issue.sh snap | trip               Pre/PostToolUse hooks on Bash
# An issue counts as In Progress once .git/coddy/<issue> exists; only claim
# writes it, and guard rejects every edit that is not inside a claimed worktree.
# snap and trip fingerprint the main checkout around each shell command and
# reject the command's result when it left new changes there.
set -u

root="${CLAUDE_PROJECT_DIR:-$PWD}"
case "$root" in */.worktrees/*) root="${root%%/.worktrees/*}" ;; esac
conf="$root/.claude/coddy.yml"
code=1

die() { echo "coddy: $*" >&2; exit "$code"; }
cfg() { sed -n "s/^$1:[[:space:]]*//p" "$conf" | sed "s/[[:space:]]*#.*$//; s/^[\"']//; s/[\"']$//" | head -1; }

if [ "${1-}" = guard ]; then
  [ -f "$conf" ] || exit 0
  code=2 # exit 2 is what blocks the tool call
  command -v jq >/dev/null || die "the edit guard needs jq"
  f=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')
  # ponytail: string-prefix match, so a symlinked path into the project slips
  # through; resolve with realpath if that ever matters.
  case "$f" in */../*) die "refusing a path containing '..': $f" ;; esac
  case "$f" in
    "$root"/.worktrees/*)
      issue="${f#"$root"/.worktrees/}"; issue="${issue%%/*}"
      [ -e "$root/.git/coddy/$issue" ] || die "issue $issue is not In Progress yet. Run /coddy:start $issue." ;;
    "$root"/.claude/*) ;;
    "$root"/*) die "edits belong in an issue worktree, not the main checkout. Run /coddy:start <issue>, then edit under .worktrees/<issue>/." ;;
  esac
  exit 0
fi

# One line per dirty path in the main checkout with its content hash, plus
# HEAD when it is a commit no remote branch contains. Paths, not git status
# codes: jj colocation flips untracked files to intent-to-add on its own.
# ponytail: one git hash-object per dirty file, so a checkout with thousands
# of dirty files slows every shell command; batch with --stdin-paths then.
snap() {
  cd "$root" 2>/dev/null || return 0
  [ -n "$(git branch -r --contains HEAD 2>/dev/null)" ] || git rev-parse HEAD 2>/dev/null | sed 's/^/HEAD /'
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

[ -f "$conf" ] || die "NOT_ONBOARDED"
cd "$root" || die "cannot enter $root"
cmd="${1-}" issue="${2-}"
case "$issue" in ''|*[!A-Za-z0-9_-]*) die "issue id must look like 42 or ABC-123, got '$issue'" ;; esac
wt=".worktrees/$issue"
tool=$(cfg worktree); tool="${tool:-jj}"
base=$(cfg default_branch); base="${base:-main}"

case "$cmd" in
  create)
    branch="${3-}"; [ -n "$branch" ] || die "usage: issue.sh create <issue> <branch>"
    [ -d "$wt" ] && { echo "exists: $wt"; exit 0; }
    mkdir -p .worktrees
    git check-ignore -q .worktrees || echo '.worktrees/' >> .git/info/exclude
    if [ "$tool" = jj ]; then
      command -v jj >/dev/null || die "jj is not installed. Install it or set 'worktree: git' in .claude/coddy.yml."
      [ -d .jj ] || die "this repo is not jj-backed. Ask the user, then run: jj git init --colocate && echo '.jj/' >> .git/info/exclude"
      [ -z "$(jj bookmark list "$branch" 2>/dev/null)" ] || die "branch $branch already exists"
      jj git fetch || die "fetch failed"
      jj workspace add --name "$issue" -r "$base@origin" "$wt" || die "could not create the jj workspace"
      jj -R "$wt" bookmark create "$branch" -r @ || die "could not create branch $branch"
    else
      git fetch origin || die "fetch failed"
      git worktree add --no-track -b "$branch" "$wt" "origin/$base" || die "could not create the git worktree"
    fi
    echo "created: $wt on $branch" ;;

  claim)
    [ -d "$wt" ] || die "create the worktree first: issue.sh create $issue <branch>"
    if [ "$(cfg tracker)" != jira ]; then
      gh label create "in progress" >/dev/null 2>&1
      gh issue edit "$issue" --add-assignee @me --add-label "in progress" >/dev/null || die "could not move #$issue to In Progress"
      gh issue view "$issue" --json labels --jq '.labels[].name' | grep -qx "in progress" || die "#$issue does not carry the 'in progress' label"
    fi
    # ponytail: Jira is reachable only through MCP tools, so for jira this
    # records the transition the skill just made instead of verifying it.
    # Upgrade path: a PostToolUse hook on the Atlassian transition tool.
    mkdir -p .git/coddy && : > ".git/coddy/$issue" || die "could not record the claim"
    echo "in progress: $issue" ;;

  push)
    msg="${3-}"
    [ -d "$wt" ] || die "no worktree for $issue. Run /coddy:start $issue."
    [ -e ".git/coddy/$issue" ] || die "issue $issue is not In Progress. Run /coddy:start $issue."
    if [ "$tool" = jj ]; then
      branch=$(jj -R "$wt" log --no-graph -r 'heads(::@ & bookmarks())' -T 'local_bookmarks.map(|b| b.name()).join("\n") ++ "\n"' | head -1)
      dirty=$(jj -R "$wt" diff --summary)
    else
      branch=$(git -C "$wt" branch --show-current)
      dirty=$(git -C "$wt" status --porcelain)
    fi
    [ -n "$branch" ] && [ "$branch" != "$base" ] || die "$wt is not on an issue branch"
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

  *) die "usage: issue.sh create <issue> <branch> | claim <issue> | push <issue> [message] | guard" ;;
esac
