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

mkdir "$tmp/bin"
printf '#!/usr/bin/env bash\ncase "$*" in *"issue view"*) echo "${GH_LABEL-in progress}" ;; esac\n' > "$tmp/bin/gh"
chmod +x "$tmp/bin/gh"; PATH="$tmp/bin:$PATH"

git init -q --bare "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$repo" 2>/dev/null
cd "$repo" || exit 1
git checkout -q -b main; echo hi > README.md; git add -A; git commit -q -m init; git push -q -u origin main
mkdir .claude
echo note > notes.txt; : > empty.txt # untracked on purpose: jj must not make these look like changes

t 1 "no skill disables model invocation" grep -rq disable-model-invocation "$here/skills"
t 0 "guard allows everything before onboarding" guard "$repo/README.md"

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
if command -v jj >/dev/null; then
  printf 'tracker: github\nworktree: jj\ndefault_branch: main\n' > .claude/coddy.yml
  t 1 "jj: create refuses a repo that is not jj-backed" run create 41 feat/41-thing
  jj git init --colocate >/dev/null 2>&1; echo '.jj/' >> .git/info/exclude
  leg jj 42
else
  echo "skip jj leg (jj not installed)"
fi

tripped 0 "tripwire: quiet when nothing changed" 'true'
tripped 0 "tripwire: quiet for .claude/" 'echo x >> .claude/coddy.yml'
tripped 0 "tripwire: quiet for a worktree" 'echo y >> .worktrees/43/a.txt'
tripped 2 "tripwire: tracked file modified" 'echo x >> README.md'
tripped 2 "tripwire: dirty file modified again" 'echo y >> README.md'
tripped 0 "tripwire: quiet when the change is undone" 'git checkout README.md'
tripped 2 "tripwire: new file" 'echo x > stray.txt'
tripped 0 "tripwire: quiet when the new file is removed" 'rm stray.txt'
tripped 2 "tripwire: tracked file deleted" 'rm README.md'
git checkout -q README.md
tripped 2 "tripwire: local commit in the main checkout" 'git commit -q --allow-empty -m oops'

mkdir -p .worktrees/other
t 0 "tree.sh lists a claimed issue" sh -c "CLAUDE_PROJECT_DIR='$repo' bash '$here/scripts/tree.sh' | grep -q '^worktrees: .*43'"
t 1 "tree.sh skips an unclaimed directory" sh -c "CLAUDE_PROJECT_DIR='$repo' bash '$here/scripts/tree.sh' | grep -q other"
t 0 "config.sh finds the config from inside a worktree" sh -c "CLAUDE_PROJECT_DIR='$repo/.worktrees/43' bash '$here/scripts/config.sh' | grep -q '^tracker:'"

exit $fail
