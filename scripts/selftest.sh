#!/usr/bin/env bash
# Runs the scripts against a throwaway repo with a local bare remote: both
# worktree tools, the claim and its lock, the push, the sweep, the edit
# guard, the shell tripwire, the PR check's run block (against a stub gh,
# the one place gh remains: GitHub Actions) and tree.sh's owners line.
# Usage: bash scripts/selftest.sh
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"; fail=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t JJ_USER=t JJ_EMAIL=t@t
export CLAUDE_CODE_SESSION_ID=sess-a CLAUDE_PID=$$ # this run is one session; as() runs a command as another

# t <expected exit> <name> <command...>
t() {
  want=$1 name=$2; shift 2
  "$@" >/dev/null 2>&1; got=$?
  if [ "$got" = "$want" ]; then echo "ok   $name"; else echo "FAIL $name (exit $got, want $want)"; fail=1; fi
}
run() { CLAUDE_PROJECT_DIR="$repo" bash "$here/scripts/issue.sh" "$@"; }
as() { CLAUDE_CODE_SESSION_ID=$1 CLAUDE_PID=$2 run "${@:3}"; }
says() { "${@:2}" 2>&1 | grep -q "$1"; } # the command's output mentions $1
# guard <path> [session] [pid]: the edit hook, as Claude Code calls it; the
# payload names this run's session unless another is, and none when "" is;
# the hook runs in that session's process: this one, or 1 for another session
guard() { local s=${2-sess-a} p=1; [ "$s" != sess-a ] || p=$$; printf '{%s"tool_input":{"file_path":"%s"}}' "${s:+"\"session_id\":\"$s\","}" "$1" | CLAUDE_PID=${3-$p} run guard; }
# wire <snap|trip> <id>: the Bash hooks, as Claude Code calls them
wire() { printf '{"tool_use_id":"%s"}' "$2" | run "$1"; }
# tripped <expected exit> <name> <shell snippet run in the main checkout>
tripped() { wire snap w; (cd "$repo" && eval "$3") >/dev/null 2>&1; t "$1" "$2" wire trip w; }

# The stub gh, for the PR check's run block alone. GH_LINKED: the "<number>
# <state> <assignees>" lines "api graphql" reports, or fail. GH_ISSUE: the
# "<state> <assignees>" that "api repos/*/issues/<n>" reports after the
# number, or fail. Every call is logged to $GH_LOG.
mkdir "$tmp/bin"
cat > "$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$*" in
  *"api graphql"*) [ "${GH_LINKED-}" != fail ] || exit 1; echo "${GH_LINKED-}" ;;
  *"api repos/"*"/issues/"*) [ "${GH_ISSUE-}" != fail ] || exit 1; n="${*##*/issues/}"; echo "${n%% *} ${GH_ISSUE-OPEN 1}" ;;
esac
EOF
chmod +x "$tmp/bin/gh"; PATH="$tmp/bin:$PATH"; export GH_LOG="$tmp/gh.log"
# A ps that is not there, as in a container image without procps: on PATH first when a case asks.
mkdir "$tmp/nops"; printf '#!/bin/sh\nexit 127\n' > "$tmp/nops/ps"; chmod +x "$tmp/nops/ps"
# kept <what>: sweep leaves worktree $p alone
kept() { run sweep >/dev/null 2>&1; t 0 "$tool: sweep keeps $1" test -d ".worktrees/$p"; }

git init -q --bare "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$repo" 2>/dev/null
cd "$repo" || exit 1
git checkout -q -b main; echo hi > README.md; git add -A; git commit -q -m init; git push -q -u origin main
mkdir .claude
echo note > notes.txt; : > empty.txt # untracked on purpose: jj must not make these look like changes

t 1 "no skill disables model invocation" grep -rq disable-model-invocation "$here/skills"
t 0 "guard allows everything before onboarding" guard "$repo/README.md"
t 0 "sweep is a quiet no-op before onboarding" run sweep

leg() {
  tool=$1 n=$2
  printf 'tracker: github\nworktree: %s\ndefault_branch: main\n' "$tool" > .claude/coddy.yml
  wire snap "leg$n"
  t 0 "$tool: create worktree" run create "$n" "feat/$n-thing"
  t 0 "$tool: create is idempotent" run create "$n" "feat/$n-thing"
  t 2 "$tool: guard blocks the worktree before the claim" guard "$repo/.worktrees/$n/a.txt"
  t 1 "$tool: push refused before the claim" run push "$n" "feat($n): thing"
  t 0 "$tool: claim" run claim "$n"
  t 0 "$tool: the lock names this session and its pid" grep -qx "sess-a $$" ".git/coddy/$n/owner"
  t 0 "$tool: guard allows the owner's edit" guard "$repo/.worktrees/$n/a.txt"
  t 2 "$tool: guard blocks another session's edit in that worktree" guard "$repo/.worktrees/$n/a.txt" sess-b
  t 0 "$tool: that rejection names the issue and the owner" says "issue $n belongs to session sess-a (pid $$, running)" guard "$repo/.worktrees/$n/a.txt" sess-b
  t 2 "$tool: a Claude Code worktree is held to the same owner check" guard "$repo/.claude/worktrees/$n/a.txt" sess-b
  t 0 "$tool: a hook payload without session_id is not held to it" guard "$repo/.worktrees/$n/a.txt" ""
  t 0 "$tool: guard allows the owner's process under a new session id (/clear)" guard "$repo/.worktrees/$n/a.txt" sess-b $$
  t 0 "$tool: and moves the lock to that session id" grep -qx "sess-b $$" ".git/coddy/$n/owner"
  t 0 "$tool: and back on this session's edit" guard "$repo/.worktrees/$n/a.txt"
  t 0 "$tool: guard allows the owner's session from a new process (--resume)" guard "$repo/.worktrees/$n/a.txt" sess-a 1
  t 0 "$tool: and moves the lock to that process" grep -qx "sess-a 1" ".git/coddy/$n/owner"
  t 0 "$tool: and back on this session's edit" guard "$repo/.worktrees/$n/a.txt"
  t 0 "$tool: the lock names this session and its pid again" grep -qx "sess-a $$" ".git/coddy/$n/owner"
  t 1 "$tool: a running session's claim is refused" as sess-b 1 claim "$n"
  t 0 "$tool: that refusal names the owner" says "session sess-a" as sess-b 1 claim "$n"
  PATH="$tmp/nops:$PATH" t 1 "$tool: a running session's claim is refused with no ps on PATH" as sess-b 1 claim "$n"
  t 0 "$tool: a re-claim by the owner is a no-op" run claim "$n"
  t 0 "$tool: so is one by the owner's process under a new session id (/clear)" as sess-b $$ claim "$n"
  t 0 "$tool: and the lock followed it to that session id" grep -qx "sess-b $$" ".git/coddy/$n/owner"
  t 0 "$tool: and back to this one" run claim "$n"
  t 0 "$tool: so is one by the owner's session from a new process (--resume)" as sess-a 1 claim "$n"
  t 0 "$tool: and the lock followed it to that process" grep -qx "sess-a 1" ".git/coddy/$n/owner"
  t 0 "$tool: and back to this one" run claim "$n"
  t 0 "$tool: the lock names this session and its pid again" grep -qx "sess-a $$" ".git/coddy/$n/owner"
  t 0 "$tool: a --take by the owner is a no-op too" run claim "$n" --take
  t 0 "$tool: the lock still names this session" grep -qx "sess-a $$" ".git/coddy/$n/owner"
  t 0 "$tool: --take hands the claim to another session and says so" says "taken over: $n from session sess-a (--take)" as sess-b 1 claim "$n" --take
  t 0 "$tool: the lock now names that session" grep -qx "sess-b 1" ".git/coddy/$n/owner"
  t 2 "$tool: guard now blocks the previous owner" guard "$repo/.worktrees/$n/a.txt"
  t 0 "$tool: guard allows the taker" guard "$repo/.worktrees/$n/a.txt" sess-b
  dead=$(sh -c 'echo $$') # that shell has exited
  as sess-c "$dead" claim "$n" --take >/dev/null 2>&1
  t 0 "$tool: a lock whose owner is gone is taken over" says "not running" run claim "$n"
  t 0 "$tool: the lock names the taker" grep -qx "sess-a $$" ".git/coddy/$n/owner"
  t 0 "$tool: guard allows the worktree after the claim" guard "$repo/.worktrees/$n/a.txt"
  t 0 "$tool: guard allows a Claude Code worktree named for the claimed issue" guard "$repo/.claude/worktrees/$n/a.txt"
  echo x > ".worktrees/$n/a.txt"
  t 1 "$tool: push refuses uncommitted work without a message" run push "$n"
  t 1 "$tool: push refuses another session's worktree" as sess-b 1 push "$n" "feat($n): thing"
  t 0 "$tool: that refusal names the owner" says "belongs to session sess-a" as sess-b 1 push "$n" "feat($n): thing"
  t 0 "$tool: push commits and pushes" run push "$n" "feat($n): thing"
  t 0 "$tool: branch reached the remote" git ls-remote --exit-code origin "refs/heads/feat/$n-thing"
  rm -f ".git/coddy/$n.branch" # a worktree made before create recorded the branch
  t 1 "$tool: push refuses a worktree with no recorded branch" run push "$n"
  t 0 "$tool: that refusal names the command that records it" sh -c "CLAUDE_PROJECT_DIR='$repo' bash '$here/scripts/issue.sh' push $n 2>&1 | grep -q 'issue.sh create $n'"
  t 1 "$tool: create refuses to record a branch the worktree is not on" run create "$n" "feat/$n-other"
  t 0 "$tool: create records the branch of an existing worktree" run create "$n" "feat/$n-thing"
  t 0 "$tool: push works again once the branch is recorded" run push "$n"
  # Continue a branch that exists only on the remote, as for someone else's PR.
  p=$((n + 10))
  (git clone -q -b main "$tmp/origin.git" "$tmp/ext$p" && cd "$tmp/ext$p" && git checkout -q -b "ext/pr-$p" && echo "$p" > ext.txt && git add -A && git commit -q -m "pr $p" && git push -q origin "ext/pr-$p") >/dev/null 2>&1
  t 0 "$tool: create continues a branch that exists only on the remote" run create "$p" "ext/pr-$p"
  t 0 "$tool: that worktree starts at the branch's tip" test -f ".worktrees/$p/ext.txt"
  # Two sessions claim it at once: one wins the lock, the other is refused.
  # The other session's process is one of this test's own: $PPID may exit
  # under a launcher that backgrounds the test, and a dead pid is taken over.
  sleep 60 & live=$!
  as sess-x $$ claim "$p" >/dev/null 2>&1 & x=$!
  as sess-y "$live" claim "$p" >/dev/null 2>&1 & y=$!
  wait "$x"; xr=$?; wait "$y"; yr=$?
  t 0 "$tool: of two claims at once exactly one wins" test "$xr$yr" = 01 -o "$xr$yr" = 10
  [ "$xr" = 0 ] && w="sess-x $$" || w="sess-y $live"
  t 0 "$tool: the lock names the winner" grep -qx "$w" ".git/coddy/$p/owner"
  kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
  echo "more $p" > ".worktrees/$p/more.txt" # per leg: the other leg's is in main by now
  was=$(git ls-remote origin "refs/heads/ext/pr-$p")
  t 0 "$tool: push to a continued branch" as ${w% *} ${w#* } push "$p" "fix($p): more" # as the winner: push is the owner's too
  t 1 "$tool: that push moved the branch on the remote" test "$(git ls-remote origin "refs/heads/ext/pr-$p")" = "$was"
  t 0 "$tool: create refuses a branch that belongs to another issue" sh -c "CLAUDE_PROJECT_DIR='$repo' bash '$here/scripts/issue.sh' create 11 feat/$n-thing 2>&1 | grep -q 'belongs to issue $n'"
  t 1 "$tool: create refuses another branch for an existing worktree" run create "$n" "feat/$n-other"
  t 0 "$tool: create refuses the default branch" sh -c "CLAUDE_PROJECT_DIR='$repo' bash '$here/scripts/issue.sh' create 12 main 2>&1 | grep -q 'default branch'"
  # A worktree stacked on another issue's branch starts at that branch as it
  # stands here, records the base for ship, and its push moves only its own branch.
  q=$((n + 20))
  t 1 "$tool: create refuses to stack on an issue with no worktree" run create "$q" "feat/$q-stack" 98
  t 0 "$tool: that refusal says how to make one" says "/coddy:start 98" run create "$q" "feat/$q-stack" 98
  t 0 "$tool: create stacks a worktree on another issue's branch" says "onto feat/$n-thing" run create "$q" "feat/$q-stack" "$n"
  t 0 "$tool: that worktree starts at the base branch's tip" test -f ".worktrees/$q/a.txt"
  t 0 "$tool: and records the base" grep -qx "feat/$n-thing" ".git/coddy/$q.base"
  t 0 "$tool: a worktree started from the default branch records no base" test ! -e ".git/coddy/$n.base"
  t 0 "$tool: claim the stacked issue" run claim "$q"
  t 0 "$tool: tree.sh lists the base" sh -c "CLAUDE_PROJECT_DIR='$repo' bash '$here/scripts/tree.sh' | grep -q '^bases: .*$q=feat/$n-thing'"
  echo s > ".worktrees/$q/s.txt"; was=$(git ls-remote origin "refs/heads/feat/$n-thing")
  t 0 "$tool: push of the stacked branch" run push "$q" "feat($q): stacked"
  t 0 "$tool: the stacked branch reached the remote" git ls-remote --exit-code origin "refs/heads/feat/$q-stack"
  t 0 "$tool: and the base branch did not move" test "$(git ls-remote origin "refs/heads/feat/$n-thing")" = "$was"
  # The end of the lifecycle, on the continued branch: sweep removes the
  # worktree once its last commit is in main on the remote through a merge
  # commit and nothing is uncommitted.
  # A marker from before claims were locks is a plain file: it still counts,
  # and a claim on one replaces it with a lock.
  rm -rf ".git/coddy/$p"; ln -s nowhere ".git/coddy/$p"
  t 1 "$tool: a lock that cannot be written is a failed claim" run claim "$p"
  rm -rf ".git/coddy/$p"; : > ".git/coddy/$p"
  t 0 "$tool: an old marker still allows edits from any session" guard "$repo/.worktrees/$p/a.txt" sess-b
  t 0 "$tool: claim turns an old marker into a lock" run claim "$p"
  t 0 "$tool: that lock names this session" grep -qx "sess-a $$" ".git/coddy/$p/owner"
  : > ".git/coddy/$p/owner" # a kill between the owner file's open and its write, or a full disk
  t 1 "$tool: an empty owner line is a claim that died halfway" run claim "$p"
  t 0 "$tool: that refusal says so" says "died halfway" run claim "$p"
  t 0 "$tool: --take adopts a lock with an empty owner line" run claim "$p" --take
  # A lock with no owner line is a claim in flight, or one that died halfway.
  rm -rf ".git/coddy/$p"; mkdir ".git/coddy/$p"
  t 1 "$tool: a lock with no owner is refused" run claim "$p"
  t 2 "$tool: guard blocks a lock with no owner" guard "$repo/.worktrees/$p/a.txt"
  t 0 "$tool: that refusal says how to take it" says "take it over" run claim "$p"
  t 0 "$tool: --take adopts a lock with no owner" run claim "$p" --take
  rm -rf ".git/coddy/$p"
  t 0 "$tool: claim" run claim "$p"
  t 0 "$tool: that claim allows edits" guard "$repo/.worktrees/$p/a.txt"
  kept "a branch that is not merged"
  # Merged into main on the remote, as GitHub's merge button does it.
  (git clone -q -b main "$tmp/origin.git" "$tmp/merge$p" && cd "$tmp/merge$p" && git merge -q --no-ff -m "merge $p" "origin/ext/pr-$p" && git push -q origin main) >/dev/null 2>&1
  echo wip > ".worktrees/$p/wip.txt"
  kept "uncommitted changes"
  t 0 "$tool: and says so" says "holds uncommitted work" run sweep
  rm ".worktrees/$p/wip.txt"
  CLAUDE_PROJECT_DIR="$repo/.worktrees/$p" bash "$here/scripts/issue.sh" sweep >/dev/null 2>&1
  t 0 "$tool: sweep keeps the worktree the session is in" test -d ".worktrees/$p"
  echo "sess-b 1" > ".git/coddy/$p/owner" # claimed by another session whose process runs
  kept "a merged worktree another running session holds"
  t 0 "$tool: and names that session" says "kept: $p (merged into main, session sess-b still holds it)" run sweep
  echo "sess-b $(sh -c 'echo $$')" > ".git/coddy/$p/owner" # that process has exited
  t 0 "$tool: sweep reports a merged, clean worktree as cleaned" sh -c "CLAUDE_PROJECT_DIR='$repo' bash '$here/scripts/issue.sh' sweep | grep -qx 'cleaned: $p'"
  t 1 "$tool: sweep removed that worktree" test -e ".worktrees/$p"
  t 1 "$tool: sweep removed its lock and branch record" test -e ".git/coddy/$p" -o -e ".git/coddy/$p.branch"
  t 1 "$tool: sweep removed its local branch" git show-ref -q "refs/heads/ext/pr-$p"
  t 0 "$tool: sweep left the other worktree alone" test -d ".worktrees/$n"
  # The same worktree back, held by this session: swept as before.
  run create "$p" "ext/pr-$p" >/dev/null 2>&1 && mkdir ".git/coddy/$p" && echo "sess-a $$" > ".git/coddy/$p/owner"
  t 0 "$tool: sweep cleans a merged worktree this session holds" sh -c "CLAUDE_PROJECT_DIR='$repo' bash '$here/scripts/issue.sh' sweep | grep -qx 'cleaned: $p'"
  # A worktree just started from main sits on main's own first-parent line
  # with nothing of its own yet: not finished.
  r=$((n + 30)); run create "$r" "feat/$r-fresh" >/dev/null 2>&1; run claim "$r" >/dev/null 2>&1
  t 0 "$tool: sweep leaves a fresh worktree alone" sh -c "CLAUDE_PROJECT_DIR='$repo' bash '$here/scripts/issue.sh' sweep >/dev/null; test -d .worktrees/$r"
  t 0 "$tool: the whole flow left the main checkout alone" wire trip "leg$n"
}

printf 'tracker: github\ndefault_branch: main\n' > .claude/coddy.yml
t 2 "guard blocks the main checkout" guard "$repo/README.md"
t 0 "guard allows .claude/" guard "$repo/.claude/coddy.yml"
t 2 "guard blocks a Claude Code worktree under .claude/ without a claim" guard "$repo/.claude/worktrees/55/a.txt"
t 0 "guard ignores paths outside the project" guard "$tmp/elsewhere.txt"
t 2 "guard rejects .. paths" guard "$repo/.worktrees/../README.md"
t 2 "guard rejects .. paths hidden behind a newline" guard "$repo/.claude/x\\n/../../README.md"
mkdir -p .git/coddy/66 && echo "sess-f " > .git/coddy/66/owner # a claim run without CLAUDE_PID
t 0 "guard reads an owner without a pid as running, as claim does" says "(pid , running)" guard "$repo/.worktrees/66/a.txt" sess-b
rm -r .git/coddy/66
t 1 "create rejects a bad issue id" run create "../x" feat/x
t 1 "claim needs a worktree first" run claim 99

# guard: warn lets every edit through and hands Claude the message instead;
# the tripwire and the config lock are the same in both modes.
# warned <path> [session] [text]: guard exits 0 and prints that message, with
# the text (default: the command to run), as hook JSON
warned() { out=$(guard "$1" "${2-sess-a}") && printf %s "$out" | jq -e --arg s "${3-/coddy:start}" '.hookSpecificOutput | .hookEventName == "PreToolUse" and (.additionalContext | contains($s))'; }
printf 'tracker: github\ndefault_branch: main\nguard: warn\n' > .claude/coddy.yml
t 0 "warn: guard lets the main checkout through with the message" warned "$repo/README.md"
t 0 "warn: guard lets an unclaimed worktree through with the message" warned "$repo/.worktrees/77/a.txt"
mkdir -p .git/coddy/77 && echo "sess-z 1" > .git/coddy/77/owner # claimed by another session, in another process
t 0 "warn: guard lets another session's worktree through, naming the owner" warned "$repo/.worktrees/77/a.txt" sess-a "belongs to session sess-z"
rm -r .git/coddy/77
t 0 "warn: guard says nothing about .claude/" test -z "$(guard "$repo/.claude/coddy.yml")"
tripped 2 "warn: the tripwire still trips" 'echo x > stray.txt'; rm -f stray.txt
tripped 2 "warn: the config lock still holds" 'rm .claude/coddy.yml'
t 0 "warn: the config came back as it was" grep -qx 'guard: warn' .claude/coddy.yml
for v in block wran; do
  printf 'tracker: github\ndefault_branch: main\nguard: %s\n' "$v" > .claude/coddy.yml
  t 2 "guard: $v blocks the main checkout" guard "$repo/README.md"
done

leg git 43
git -C .worktrees/43 checkout -q -b feat/43-other
t 1 "git: push refuses a worktree that left its recorded branch" run push 43
git -C .worktrees/43 checkout -q feat/43-thing
if command -v jj >/dev/null; then
  printf 'tracker: github\nworktree: jj\ndefault_branch: main\n' > .claude/coddy.yml
  t 1 "jj: create refuses a repo that is not jj-backed" run create 41 feat/41-thing
  jj git init --colocate >/dev/null 2>&1; echo '.jj/' >> .git/info/exclude
  leg jj 42
else
  echo "skip jj leg (jj not installed)"
fi

tripped 0 "tripwire: quiet when nothing changed" 'true'
tripped 0 "tripwire: quiet for other files in .claude/" 'echo x >> .claude/notes.md'
tripped 0 "tripwire: quiet for a worktree" 'echo y >> .worktrees/43/a.txt'
tripped 2 "tripwire: tracked file modified" 'echo x >> README.md'
tripped 2 "tripwire: dirty file modified again" 'echo y >> README.md'
tripped 0 "tripwire: quiet when the change is undone" 'git checkout README.md'
tripped 2 "tripwire: new file" 'echo x > stray.txt'
tripped 0 "tripwire: quiet when the new file is removed" 'rm stray.txt'
tripped 2 "tripwire: tracked file deleted" 'rm README.md'
git checkout -q README.md
# HEAD leaving the default branch is a change too, even for a pushed commit
# with nothing dirty. A detached HEAD on the default branch's own history is
# where jj leaves a synced checkout, so that one is quiet.
wire snap w; git checkout -q -b side origin/feat/43-thing
wire trip w 2>"$tmp/trip.err"; got=$?
t 0 "tripwire: switch to a pushed branch" test "$got" = 2
t 0 "tripwire: that report names the branch" grep -q "branch side" "$tmp/trip.err"
tripped 0 "tripwire: quiet on the switch back" 'git checkout -q main'
tripped 0 "tripwire: quiet for a detached HEAD on the default branch" 'git checkout -q --detach origin/main'
tripped 2 "tripwire: detached HEAD on a pushed commit off the default branch" 'git checkout -q --detach origin/feat/43-thing'
git checkout -q main
tripped 2 "tripwire: local commit in the main checkout" 'git commit -q --allow-empty -m oops'
git checkout -q side
tripped 0 "tripwire: quiet on the switch back to a default branch with local commits" 'git checkout -q main'
git branch -q -D side
tripped 2 "tripwire: local commit that was pushed to another branch" 'git commit -q --allow-empty -m oops2 && git push -q origin HEAD:refs/heads/elsewhere'

# The config switches every hook off when it goes, so a shell command may not touch it.
cp .claude/coddy.yml "$tmp/conf.orig"
same() { cmp -s "$repo/.claude/coddy.yml" "$tmp/conf.orig"; }
tripped 2 "config: deleting it trips" 'rm .claude/coddy.yml'
t 0 "config: restored after deletion" same
t 2 "config: guard still on after the deletion" guard "$repo/README.md"
tripped 2 "config: rewriting it trips" 'echo "verify: true" >> .claude/coddy.yml'
t 0 "config: restored after the rewrite" same
tripped 2 "config: removing .claude/ trips" 'rm -rf .claude'
t 0 "config: restored after .claude/ was removed" same
# A shared (committed) config that changes through git is not a bypass.
# The legs merged branches into main on the remote: the local commits above go on
# top. git reset first: jj colocation left the untracked files as intent-to-add
# index entries, which a rebase refuses to start over.
git reset -q && git pull -q --rebase origin main
git add -f .claude/coddy.yml; git commit -q -m "share config"; git push -q origin HEAD:main
git clone -q -b main "$tmp/origin.git" "$tmp/mate" 2>/dev/null
(cd "$tmp/mate" && echo "roadmap: docs/ROADMAP.md" >> .claude/coddy.yml && git commit -q -am "roadmap" && git push -q origin HEAD:main)
tripped 0 "config: a pulled change to a shared config stands" 'git fetch -q origin && git merge -q --ff-only origin/main'
t 0 "config: the pulled change is kept" grep -q '^roadmap:' .claude/coddy.yml
tripped 2 "config: a shell edit to a shared config still trips" 'echo "verify: true" >> .claude/coddy.yml'
t 1 "config: the shell edit to a shared config is undone" grep -q '^verify: true' .claude/coddy.yml

mkdir -p .worktrees/other
t 0 "tree.sh lists a claimed issue with its branch" sh -c "CLAUDE_PROJECT_DIR='$repo' bash '$here/scripts/tree.sh' | grep -q '^worktrees: .*43=feat/43-thing'"
t 1 "tree.sh skips an unclaimed directory" sh -c "CLAUDE_PROJECT_DIR='$repo' bash '$here/scripts/tree.sh' | grep -q other"
# owns <issue=owner> [session] [pid]: tree.sh, run as that session, lists that owner
owns() { CLAUDE_CODE_SESSION_ID=${2-sess-a} CLAUDE_PID=${3-$$} CLAUDE_PROJECT_DIR="$repo" bash "$here/scripts/tree.sh" | grep -q "^owners: .*$1"; }
t 0 "tree.sh owners: this session's claim is me" owns "43=me"
t 0 "tree.sh owners: still me under a new session id (/clear)" owns "43=me" sess-b
t 0 "tree.sh owners: still me from a new process (--resume)" owns "43=me" sess-a 1
mkdir .git/coddy/other; echo "sess-d $(sh -c 'echo $$')" > .git/coddy/other/owner # that shell has exited
t 0 "tree.sh owners: another session whose process exited is gone" owns "other=sess-d (gone)"
echo "sess-e 1" > .git/coddy/other/owner
t 0 "tree.sh owners: another session whose process runs is running" owns "other=sess-e (running)"
echo "sess-e $$" > .git/coddy/other/owner
PATH="$tmp/nops:$PATH" t 0 "tree.sh owners: a running process is running with no ps on PATH" owns "other=sess-e (running)" sess-a 1
echo "sess-f " > .git/coddy/other/owner
t 0 "tree.sh owners: another session without a pid is running, as claim reads it" owns "other=sess-f (running)"
rm -r .git/coddy/other; : > .git/coddy/other
t 0 "tree.sh owners: a marker from before locks is unknown" owns "other=unknown"
rm .git/coddy/other
t 0 "config.sh finds the config from inside a worktree" sh -c "CLAUDE_PROJECT_DIR='$repo/.worktrees/43' bash '$here/scripts/config.sh' | grep -q '^tracker:'"
# detect <line> [VAR=value...]: detect.sh prints exactly that line
detect() { line=$1; shift; env CLAUDE_PROJECT_DIR="$repo" "$@" "$BASH" "$here/scripts/detect.sh" 2>/dev/null | grep -qx "$line"; }
t 0 "detect.sh reports an installed jq" detect 'jq: installed'
t 0 "detect.sh reports a missing jq" detect 'jq: missing' PATH="$tmp/bin"
t 0 "detect.sh reports no PR check" detect 'pr_check: none'
mkdir -p .github/workflows && : > .github/workflows/coddy.yml
t 0 "detect.sh reports the PR check once its workflow exists" detect 'pr_check: present'
rm -r .github

# The PR check's run block, as the workflow runs it (bash -e), with the stub
# gh and the template's own env names, each set to itself, so the gh log
# shows which names the run block read.
sed '1,/run: |/d; s/^          //' "$here/templates/coddy.yml" > "$tmp/check.sh"
# check <GH_LINKED> [VAR=value...]: every env name is its own value unless
# overridden, so BASE and DEFAULT differ: a stacked PR unless both are set.
check() { GH_LINKED="$1" env $(sed -n 's/^      \([A-Z_]*\): .*/\1=\1/p' "$here/templates/coddy.yml") "${@:2}" bash -e "$tmp/check.sh"; }
t 0 "pr check: an open, assigned linked issue passes" check "12 OPEN 1"
t 0 "pr check: the run block hands env's owner, repo and PR to gh" grep -q -- '-f owner=OWNER -f repo=REPO -F pr=PR' "$GH_LOG"
t 1 "pr check: no linked issue fails" check ""
t 1 "pr check: a failed lookup fails" check fail
t 1 "pr check: a closed linked issue fails" check "12 CLOSED 1"
t 1 "pr check: an unassigned linked issue fails" check "12 OPEN 0"
t 1 "pr check: one bad issue among two fails" check $'12 OPEN 1\n13 OPEN 0'
t 0 "pr check: two open, assigned issues pass" check $'12 OPEN 1\n13 OPEN 2'
t 0 "pr check: no linked issue names the fix" says '::error::no linked issue' check ""
t 0 "pr check: an unassigned issue names the issue and the fix" says '::error::#12 is not claimed.*/coddy:start 12' check "12 OPEN 0"
# A PR stacked on another branch: GitHub computes no closing references, so
# the description's keywords are read instead; on the default branch they are not.
t 0 "pr check: a stacked PR whose description closes an open, assigned issue passes" check "" BODY='Closes #12'
t 0 "pr check: that lookup read the issue" grep -q 'api repos/OWNER/REPO/issues/12' "$GH_LOG"
t 0 "pr check: the keyword is read in any case, with a colon, and among other words" check "" BODY=$'Fixed: #12 in the end\r'
t 1 "pr check: a word that merely ends in a keyword is not one" check "" BODY='prefixes #12'
t 1 "pr check: a stacked PR without a keyword fails" check "" BODY='see #12'
t 0 "pr check: and names the same fix" says '::error::no linked issue' check "" BODY='see #12'
t 1 "pr check: a default-branch PR is held to the computed references alone" check "" BASE=main DEFAULT=main BODY='Closes #12'
t 1 "pr check: a stacked keyword to a closed issue fails" check "" BODY='Closes #12' GH_ISSUE="CLOSED 1"
t 1 "pr check: a stacked keyword to an unassigned issue fails" check "" BODY='Closes #12' GH_ISSUE="OPEN 0"
t 1 "pr check: a stacked lookup that fails fails" check "" BODY='Closes #12' GH_ISSUE=fail
: > "$GH_LOG"
t 0 "pr check: two stacked keywords pass" check "" BODY=$'Closes #12\nResolves #13, closes #12'
t 0 "pr check: and each issue was read once" test "$(grep -c 'api repos/OWNER/REPO/issues/' "$GH_LOG")" = 2

# Merging main into an issue branch brings the bookmark of every merged PR
# into its history, and a newer one must not be taken for the issue's branch.
# Last, because it moves main on the remote.
if command -v jj >/dev/null; then
  { run create 44 feat/44-thing; run claim 44; echo y > .worktrees/44/a.txt; run push 44 "feat(44): thing"
    git clone -q -b main "$tmp/origin.git" "$tmp/merger"
    (cd "$tmp/merger" && git merge -q --no-ff -m "merge 44" origin/feat/44-thing && git push -q origin main)
    jj git fetch; jj -R .worktrees/42 new feat/42-thing main@origin; echo z > .worktrees/42/a.txt; } >/dev/null 2>&1
  was=$(git ls-remote origin refs/heads/feat/44-thing)
  t 0 "jj: push after merging main pushes the issue's branch" sh -c "CLAUDE_PROJECT_DIR='$repo' bash '$here/scripts/issue.sh' push 42 'chore(42): merge main' 2>/dev/null | grep -qx 'pushed: feat/42-thing'"
  t 0 "jj: that push left the merged branch alone" test "$(git ls-remote origin refs/heads/feat/44-thing)" = "$was"
fi

exit $fail
