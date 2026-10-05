#!/usr/bin/env bash
# Runs the scripts against a throwaway repo with a local bare remote and a
# stub gh: both worktree tools, the claim, the push, the edit guard and the
# shell tripwire.
# Usage: bash scripts/selftest.sh
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"; fail=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t JJ_USER=t JJ_EMAIL=t@t

# t <expected exit> <name> <command...>
t() {
  want=$1 name=$2; shift 2
  "$@" >/dev/null 2>&1; got=$?
  if [ "$got" = "$want" ]; then echo "ok   $name"; else echo "FAIL $name (exit $got, want $want)"; fail=1; fi
}
run() { CLAUDE_PROJECT_DIR="$repo" bash "$here/scripts/issue.sh" "$@"; }
guard() { printf '{"tool_input":{"file_path":"%s"}}' "$1" | run guard; }
# wire <snap|trip> <id>: the Bash hooks, as Claude Code calls them
wire() { printf '{"tool_use_id":"%s"}' "$2" | run "$1"; }
# tripped <expected exit> <name> <shell snippet run in the main checkout>
tripped() { wire snap w; (cd "$repo" && eval "$3") >/dev/null 2>&1; t "$1" "$2" wire trip w; }

# The stub gh. GH_LABEL: the labels "issue view" reports. GH_PR: the
# "<number> <state> <head commit>" line "pr list" reports, or fail. Every
# call is logged to $GH_LOG.
mkdir "$tmp/bin"
cat > "$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$*" in
  *"issue view"*) echo "${GH_LABEL-in progress}" ;;
  *"pr list"*) [ "${GH_PR-}" != fail ] || exit 1; echo "${GH_PR-}" ;;
  *"auth status"*) [ "${GH_AUTH-}" != fail ] || exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/gh"; PATH="$tmp/bin:$PATH"; export GH_LOG="$tmp/gh.log"
# kept <what> <GH_PR>: sweep, faced with that PR, leaves worktree $p alone
kept() { GH_PR="$2" run sweep >/dev/null 2>&1; t 0 "$tool: sweep keeps $1" test -d ".worktrees/$p"; }

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
  GH_LABEL=other t 1 "$tool: claim fails when the label did not stick" run claim "$n"
  t 2 "$tool: guard still blocks after a failed claim" guard "$repo/.worktrees/$n/a.txt"
  t 0 "$tool: claim" run claim "$n"
  t 0 "$tool: guard allows the worktree after the claim" guard "$repo/.worktrees/$n/a.txt"
  echo x > ".worktrees/$n/a.txt"
  t 1 "$tool: push refuses uncommitted work without a message" run push "$n"
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
  run claim "$p" >/dev/null 2>&1; echo more > ".worktrees/$p/more.txt"
  was=$(git ls-remote origin "refs/heads/ext/pr-$p")
  t 0 "$tool: push to a continued branch" run push "$p" "fix($p): more"
  t 1 "$tool: that push moved the branch on the remote" test "$(git ls-remote origin "refs/heads/ext/pr-$p")" = "$was"
  t 0 "$tool: create refuses a branch that belongs to another issue" sh -c "CLAUDE_PROJECT_DIR='$repo' bash '$here/scripts/issue.sh' create 11 feat/$n-thing 2>&1 | grep -q 'belongs to issue $n'"
  t 1 "$tool: create refuses another branch for an existing worktree" run create "$n" "feat/$n-other"
  t 0 "$tool: create refuses the default branch" sh -c "CLAUDE_PROJECT_DIR='$repo' bash '$here/scripts/issue.sh' create 12 main 2>&1 | grep -q 'default branch'"
  # The end of the lifecycle, on the continued branch. While its PR is open
  # a claim leaves the tracker alone; sweep removes the worktree only once
  # the PR has merged and nothing in the worktree is missing from it.
  tip=$(git ls-remote origin "refs/heads/ext/pr-$p" | cut -f1)
  rm -f ".git/coddy/$p"; : > "$GH_LOG"
  GH_PR="7 OPEN $tip" t 0 "$tool: claim with an open PR" run claim "$p"
  t 1 "$tool: that claim left labels and assignees alone" grep -q "issue edit" "$GH_LOG"
  t 0 "$tool: that claim allows edits" guard "$repo/.worktrees/$p/a.txt"
  kept "an open PR" "7 OPEN $tip"
  kept "a PR closed without merging" "7 CLOSED $tip"
  kept "everything when gh fails" fail
  kept "commits that are not in the merged PR" "7 MERGED 0000"
  echo wip > ".worktrees/$p/wip.txt"
  kept "uncommitted changes" "7 MERGED $tip"
  rm ".worktrees/$p/wip.txt"
  GH_PR="7 MERGED $tip" CLAUDE_PROJECT_DIR="$repo/.worktrees/$p" bash "$here/scripts/issue.sh" sweep >/dev/null 2>&1
  t 0 "$tool: sweep keeps the worktree the session is in" test -d ".worktrees/$p"
  GH_PR="7 MERGED $tip" t 0 "$tool: sweep reports a merged, clean worktree as cleaned" sh -c "CLAUDE_PROJECT_DIR='$repo' bash '$here/scripts/issue.sh' sweep | grep -qx 'cleaned: $p'"
  t 1 "$tool: sweep removed that worktree" test -e ".worktrees/$p"
  t 1 "$tool: sweep removed its marker and branch record" test -e ".git/coddy/$p" -o -e ".git/coddy/$p.branch"
  t 1 "$tool: sweep removed its local branch" git show-ref -q "refs/heads/ext/pr-$p"
  t 0 "$tool: sweep left the other worktree alone" test -d ".worktrees/$n"
  t 0 "$tool: the whole flow left the main checkout alone" wire trip "leg$n"
}

printf 'tracker: github\ndefault_branch: main\n' > .claude/coddy.yml
t 2 "guard blocks the main checkout" guard "$repo/README.md"
t 0 "guard allows .claude/" guard "$repo/.claude/coddy.yml"
t 0 "guard ignores paths outside the project" guard "$tmp/elsewhere.txt"
t 2 "guard rejects .. paths" guard "$repo/.worktrees/../README.md"
t 1 "create rejects a bad issue id" run create "../x" feat/x
t 1 "claim needs a worktree first" run claim 99

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
t 0 "config.sh finds the config from inside a worktree" sh -c "CLAUDE_PROJECT_DIR='$repo/.worktrees/43' bash '$here/scripts/config.sh' | grep -q '^tracker:'"
# detect <line> [VAR=value...]: detect.sh prints exactly that line
detect() { line=$1; shift; env CLAUDE_PROJECT_DIR="$repo" "$@" "$BASH" "$here/scripts/detect.sh" 2>/dev/null | grep -qx "$line"; }
t 0 "detect.sh reports an installed jq" detect 'jq: installed'
t 0 "detect.sh reports a signed-in gh" detect 'gh_auth: ok'
t 0 "detect.sh reports a missing jq" detect 'jq: missing' PATH="$tmp/bin"
t 0 "detect.sh reports a gh that is not signed in" detect 'gh_auth: missing' GH_AUTH=fail

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
