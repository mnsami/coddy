#!/usr/bin/env bash
# Runs the scripts against a throwaway repo with a local bare remote: both
# worktree tools, the claim and its lock, the push, the sweep, the edit
# guard, the shell tripwire, the PR check's run block (against a stub gh,
# the one place gh remains: GitHub Actions) and issue.sh status's owners line.
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
holds() { read -r a b _ < "$2" && [ "$a $b" = "$1" ]; } # the owner line $2 names session and pid $1
# guard <path> [session] [pid]: the edit hook, as Claude Code calls it; the
# payload names this run's session unless another is, and none when "" is;
# the hook runs in that session's process: this one, or 1 for another session
guard() { local s=${2-sess-a} p=1; [ "$s" != sess-a ] || p=$$; printf '{%s"tool_input":{"file_path":"%s"}}' "${s:+"\"session_id\":\"$s\","}" "$1" | CLAUDE_PID=${3-$p} run guard; }
# wire <snap|trip> <id>: the Bash hooks, as Claude Code calls them
wire() { printf '{"tool_use_id":"%s"}' "$2" | run "$1"; }
# tripped <expected exit> <name> <shell snippet run in the main checkout>
tripped() { wire snap w; (cd "$repo" && eval "$3") >/dev/null 2>&1; t "$1" "$2" wire trip w; }
# shell <command> [dir]: snap before a Bash command run in dir (the main
# checkout unless named), as Claude Code calls it; noted <text> <command>:
# snap lets it through and hands Claude a message holding that text
payload() { jq -cn --arg c "$1" --arg d "${2-$repo}" '{tool_use_id: "sh", cwd: $d, tool_input: {command: $c}}'; }
shell() { payload "$@" | run snap; }
noted() { out=$(shell "$2") && printf %s "$out" | jq -e --arg s "$1" '.hookSpecificOutput | .hookEventName == "PreToolUse" and (.additionalContext | contains($s))'; }

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
# A PATH with everything snap needs but jq.
mkdir "$tmp/nojq"; for x in bash sed awk cat grep git cmp sort comm tr cut cksum mkdir cp rm head; do p=$(command -v "$x") && ln -s "$p" "$tmp/nojq/$x"; done
# kept <what>: sweep leaves worktree $p alone
kept() { run sweep >/dev/null 2>&1; t 0 "$tool: sweep keeps $1" test -d ".worktrees/$p"; }

git init -q --bare "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$repo" 2>/dev/null
cd "$repo" || exit 1
git checkout -q -b main; echo hi > README.md; git add -A; git commit -q -m init; git push -q -u origin main
mkdir .claude
echo note > notes.txt; : > empty.txt # untracked on purpose: jj must not make these look like changes

t 1 "no skill disables model invocation" grep -rq disable-model-invocation "$here/skills"
t 1 "no skill names a vendor skill" grep -rqE 'superpowers|code-review:' "$here/skills"
t 0 "policy.md exists" test -f "$here/skills/start/references/policy.md"
opens() { sed -n 3p "$1" | grep -qxF 'Read `policy.md` at the path you were given first; its rules apply here. No path given, or the file cannot be read → stop and return `no policy path`.'; }
for b in implement harden review security; do t 0 "brief $b opens with policy.md" opens "$here/skills/start/$b.md"; done
# The config schema has three copies. yamlkeys reads the yaml block under a
# "## Config" heading (README comments out its jira lines, so a leading "# "
# is dropped), naming a nested key parent.child and leaving out a bare
# parent; bulletkeys reads the backticked names before the colon of each
# bullet under "## Keys".
yamlkeys() { awk '/^## Config/{f=1} f&&/^```yaml/{y=1;next} y&&/^```/{exit} y{sub(/^# ?/,""); if (!match($0,/^ *[a-z_]+:/)) next; k=substr($0,1,RLENGTH-1); rest=substr($0,RLENGTH+1)
  if (k ~ /^ /) { gsub(/ /,"",k); print top "." k } else { top=k; if (rest !~ /^[ \t]*(#.*)?$/) print k } }' "$1" | sort; }
bulletkeys() { awk '/^## Keys/{f=1;next} f&&/^## /{exit} f&&/^- `/{ h=substr($0,1,index($0,"`:")); n=split(h,a,"`"); for (i=2;i<=n;i+=2) print a[i] }' "$1" | sort; }
schema() { [ "$(yamlkeys "$1")" = "$(bulletkeys "$2")" ] && [ "$(yamlkeys "$1")" = "$(yamlkeys "$3")" ]; }
t 0 "schema: onboard, config and README list the same keys" schema "$here/skills/onboard/SKILL.md" "$here/skills/config/SKILL.md" "$here/README.md"
awk '{print} /^roadmap: /{print "extra: x"}' "$here/skills/onboard/SKILL.md" > "$tmp/onboard.md"
t 1 "schema: a key added to one copy only fails it" schema "$tmp/onboard.md" "$here/skills/config/SKILL.md" "$here/README.md"
# A skill that injects a script's output says what to do on a host that does
# not inject or expand. fallback <skill> <verb> [vars]: its fallback line names
# coddy <verb> for reading the sections by hand, `CLAUDE_PLUGIN_ROOT`
# unexpanded as never a `bin/coddy` inside the project, and each variable the
# skill takes. A new skill goes in the table.
fallback() { line=$(grep -F '`CLAUDE_PLUGIN_ROOT` unexpanded' "$1") && for w in "coddy $2" 'never a `bin/coddy`' ${3-}; do case "$line" in *"$w"*) ;; *) return 1;; esac; done; }
for s in 'config status $ARGUMENTS' 'migrate status' 'next status' 'onboard detect' 'ship status $ARGUMENTS' 'start status $issue $onto $base' 'triage status $ARGUMENTS'; do read -r n v a <<< "$s"; t 0 "skill $n carries the fallback for a host that does not inject" fallback "$here/skills/$n/SKILL.md" "$v" "$a"; done
grep -vF '`CLAUDE_PLUGIN_ROOT` unexpanded' "$here/skills/next/SKILL.md" > "$tmp/next.md"
t 1 "a skill that injects without the fallback fails it" fallback "$tmp/next.md" status
sed '/`CLAUDE_PLUGIN_ROOT` unexpanded/s/coddy status/coddy stat/' "$here/skills/next/SKILL.md" > "$tmp/next.md"
t 1 "one whose fallback drops the read-by-hand command fails it" fallback "$tmp/next.md" status
sed '/`CLAUDE_PLUGIN_ROOT` unexpanded/s|never a `bin/coddy`|never a copy|' "$here/skills/next/SKILL.md" > "$tmp/next.md"
t 1 "one whose fallback drops the never-a-bin/coddy clause fails it" fallback "$tmp/next.md" status
sed '/`CLAUDE_PLUGIN_ROOT` unexpanded/s/\$ARGUMENTS/$ARGS/' "$here/skills/triage/SKILL.md" > "$tmp/triage.md"
t 1 "one whose fallback drops its variable fails it" fallback "$tmp/triage.md" status '$ARGUMENTS'
t 1 "no skill carries the injection syntax inside a line, which Claude Code would run" grep -qE '.!`' "$here"/skills/*/SKILL.md
t 0 "onboard names the AGENTS.md begin marker" grep -qF '<!-- coddy:begin -->' "$here/skills/onboard/SKILL.md"
t 0 "onboard names the AGENTS.md end marker" grep -qF '<!-- coddy:end -->' "$here/skills/onboard/SKILL.md"
# onboard is a resumable wizard: the agenda in order, answers saved under the
# agent dir, a stop on an existing config that names /coddy:config, and no
# install command for gh (the PR check runs it inside GitHub Actions alone),
# while each package manager detect can name gets one for jq.
t 0 "onboard names the seven wizard steps in order" grep -qF 'checks → tracker → branch → verify → tiers → AGENTS.md → review' "$here/skills/onboard/SKILL.md"
t 0 "onboard saves its answers under the agent dir" grep -qF '.claude/coddy/onboard-answers.json' "$here/skills/onboard/SKILL.md"
t 0 "onboard backs up what it replaces under the agent dir" grep -qF '.claude/coddy/backup/' "$here/skills/onboard/SKILL.md"
t 0 "onboard stops on an existing config and names /coddy:config" sh -c "grep -F 'config: present' '$here/skills/onboard/SKILL.md' | grep -qF '/coddy:config'"
t 1 "onboard carries no install command for gh" grep -qiE 'install (-y )?(gh|github\.cli)( |$|`)' "$here/skills/onboard/SKILL.md"
# No hook is live during onboard, so its pre-approved shell is the core's
# verbs alone: a wildcard in a rule is where rm's flags and operands go, and
# a redirect or rm on .git/ or .claude/ prompts as a sensitive write anyway.
t 1 "onboard's allowed-tools holds no wildcard, redirect or rm" sh -c "sed -n 's/^allowed-tools: //p' '$here/skills/onboard/SKILL.md' | grep -qE '\\*|>>|(^| |\\()rm '"
for v in 'exclude answers' 'exclude config' 'forget answers'; do t 0 "onboard pre-approves issue.sh $v" grep -qF "Bash(bash \"\${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh\" $v)" "$here/skills/onboard/SKILL.md"; done
for p in brew apt-get dnf winget; do t 0 "onboard names a jq install command for $p" grep -qE "$p"' install (-y )?(jq|jqlang\.jq)( |$|`)' "$here/skills/onboard/SKILL.md"; done
t 0 "guard allows everything before onboarding" guard "$repo/README.md"
t 0 "sweep is a quiet no-op before onboarding" run sweep
t 0 "snap lets a git worktree add outside through before onboarding" shell 'git worktree add ../x'

leg() {
  tool=$1 n=$2
  printf 'tracker: github\nworktree: %s\ndefault_branch: main\nverify: test -f s.txt || exit 3\n' "$tool" > .claude/coddy.yml
  wire snap "leg$n"
  t 0 "$tool: create worktree" run create "$n" "feat/$n-thing"
  t 0 "$tool: create is idempotent" run create "$n" "feat/$n-thing"
  t 2 "$tool: guard blocks the worktree before the claim" guard "$repo/.worktrees/$n/a.txt"
  t 1 "$tool: push refused before the claim" run push "$n" "feat($n): thing"
  t 0 "$tool: claim" run claim "$n"
  t 0 "$tool: the lock names this session and its pid" holds "sess-a $$" ".git/coddy/$n/owner"
  t 0 "$tool: guard allows the owner's edit" guard "$repo/.worktrees/$n/a.txt"
  t 2 "$tool: guard blocks another session's edit in that worktree" guard "$repo/.worktrees/$n/a.txt" sess-b
  t 0 "$tool: that rejection names the issue and the owner" says "issue $n belongs to session sess-a (pid $$, running)" guard "$repo/.worktrees/$n/a.txt" sess-b
  t 2 "$tool: a Claude Code worktree is held to the same owner check" guard "$repo/.claude/worktrees/$n/a.txt" sess-b
  t 0 "$tool: a hook payload without session_id is not held to it" guard "$repo/.worktrees/$n/a.txt" ""
  t 0 "$tool: guard allows the owner's process under a new session id (/clear)" guard "$repo/.worktrees/$n/a.txt" sess-b $$
  t 0 "$tool: and moves the lock to that session id" holds "sess-b $$" ".git/coddy/$n/owner"
  t 0 "$tool: and back on this session's edit" guard "$repo/.worktrees/$n/a.txt"
  t 0 "$tool: guard allows the owner's session from a new process (--resume)" guard "$repo/.worktrees/$n/a.txt" sess-a 1
  t 0 "$tool: and moves the lock to that process" holds "sess-a 1" ".git/coddy/$n/owner"
  t 0 "$tool: and back on this session's edit" guard "$repo/.worktrees/$n/a.txt"
  t 0 "$tool: the lock names this session and its pid again" holds "sess-a $$" ".git/coddy/$n/owner"
  t 1 "$tool: a running session's claim is refused" as sess-b 1 claim "$n"
  t 0 "$tool: that refusal names the owner" says "session sess-a" as sess-b 1 claim "$n"
  PATH="$tmp/nops:$PATH" t 1 "$tool: a running session's claim is refused with no ps on PATH" as sess-b 1 claim "$n"
  t 0 "$tool: a re-claim by the owner is a no-op" run claim "$n"
  t 0 "$tool: so is one by the owner's process under a new session id (/clear)" as sess-b $$ claim "$n"
  t 0 "$tool: and the lock followed it to that session id" holds "sess-b $$" ".git/coddy/$n/owner"
  t 0 "$tool: and back to this one" run claim "$n"
  t 0 "$tool: so is one by the owner's session from a new process (--resume)" as sess-a 1 claim "$n"
  t 0 "$tool: and the lock followed it to that process" holds "sess-a 1" ".git/coddy/$n/owner"
  t 0 "$tool: and back to this one" run claim "$n"
  t 0 "$tool: the lock names this session and its pid again" holds "sess-a $$" ".git/coddy/$n/owner"
  t 0 "$tool: a --take by the owner is a no-op too" run claim "$n" --take
  t 0 "$tool: the lock still names this session" holds "sess-a $$" ".git/coddy/$n/owner"
  t 0 "$tool: --take hands the claim to another session and says so" says "taken over: $n from session sess-a (--take)" as sess-b 1 claim "$n" --take
  t 0 "$tool: the lock now names that session" holds "sess-b 1" ".git/coddy/$n/owner"
  t 2 "$tool: guard now blocks the previous owner" guard "$repo/.worktrees/$n/a.txt"
  t 0 "$tool: guard allows the taker" guard "$repo/.worktrees/$n/a.txt" sess-b
  dead=$(sh -c 'echo $$') # that shell has exited
  as sess-c "$dead" claim "$n" --take >/dev/null 2>&1
  t 0 "$tool: a lock whose owner is gone is taken over" says "not running" run claim "$n"
  t 0 "$tool: the lock names the taker" holds "sess-a $$" ".git/coddy/$n/owner"
  t 0 "$tool: guard allows the worktree after the claim" guard "$repo/.worktrees/$n/a.txt"
  t 0 "$tool: guard allows a Claude Code worktree named for the claimed issue" guard "$repo/.claude/worktrees/$n/a.txt"
  t 0 "$tool: state is empty before any write" test -z "$(run state "$n" 2>&1)"
  t 0 "$tool: state sets keys" run state "$n" phase=implement round=0
  t 0 "$tool: state prints them" says "^phase=implement$" run state "$n"
  run state "$n" phase=review >/dev/null 2>&1
  t 0 "$tool: a set replaces the key's line" test "$(run state "$n" | grep -c '^phase=')" = 1
  t 0 "$tool: and keeps the new value" says "^phase=review$" run state "$n"
  run state "$n" 'upheld+=a b' >/dev/null 2>&1; run state "$n" 'upheld+=c' >/dev/null 2>&1
  t 0 "$tool: += appends a line per value" test "$(run state "$n" | grep -c '^upheld=')" = 2
  run state "$n" 'summary=x=y "q" $(touch '"$tmp"'/pwned)' >/dev/null 2>&1
  t 0 "$tool: a value is stored literally" says '^summary=x=y "q" \$(touch' run state "$n"
  t 1 "$tool: and never evaluated" test -e "$tmp/pwned"
  t 1 "$tool: state refuses a key that is not lower case" run state "$n" Phase=x
  t 1 "$tool: state refuses an argument without =" run state "$n" phase
  run state "$n" phase=keep >/dev/null 2>&1; t 1 "$tool: a bad key refuses the whole write" run state "$n" phase=gone Bad=x; t 0 "$tool: and writes none of it" says "^phase=keep$" run state "$n"; run state "$n" phase=review >/dev/null 2>&1
  t 1 "$tool: state refuses another running session's write" as sess-b 1 state "$n" phase=done
  t 0 "$tool: that refusal names the owner" says "belongs to session sess-a" as sess-b 1 state "$n" phase=done
  t 0 "$tool: another session may read it" says "^phase=review$" as sess-b 1 state "$n"
  t 0 "$tool: the owner's process under a new session id (/clear) may write" as sess-b $$ state "$n" round=1
  run claim "$n" >/dev/null 2>&1 # the lock back to this session id
  t 1 "$tool: state refuses an issue with no claim" run state 999 phase=x
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
  t 0 "$tool: the lock names the winner" holds "$w" ".git/coddy/$p/owner"
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
  t 0 "$tool: issue.sh status lists the base" sh -c "CLAUDE_PROJECT_DIR='$repo' bash '$here/scripts/issue.sh' status | grep -q '^bases: .*$q=feat/$n-thing'"
  echo s > ".worktrees/$q/s.txt"; was=$(git ls-remote origin "refs/heads/feat/$n-thing")
  t 0 "$tool: push of the stacked branch" run push "$q" "feat($q): stacked"
  t 0 "$tool: the stacked branch reached the remote" git ls-remote --exit-code origin "refs/heads/feat/$q-stack"
  t 0 "$tool: and the base branch did not move" test "$(git ls-remote origin "refs/heads/feat/$n-thing")" = "$was"
  # verify runs the config's command in the worktree and passes its exit code
  # through; diff is the worktree's change against its base.
  t 0 "$tool: verify passes when the command passes" run verify "$q"
  t 3 "$tool: verify passes its command's exit code through" run verify "$n"
  t 1 "$tool: verify refuses an issue with no worktree" run verify 97
  t 0 "$tool: that refusal says how to make one" says "/coddy:start 97" run verify 97
  t 0 "$tool: diff shows the issue's changed file" says "a.txt" run diff "$n"
  t 0 "$tool: the stacked diff shows its own change" says "s.txt" run diff "$q"
  t 1 "$tool: and not its base's" says "a.txt" run diff "$q"
  t 1 "$tool: diff refuses an issue with no worktree" run diff 97
  mv ".git/coddy/$q.base" "$tmp/q.base"; echo feat/gone > ".git/coddy/$q.base"
  t 0 "$tool: diff falls back to the default branch when the base no longer resolves" run diff "$q"
  t 0 "$tool: and so does log" run log "$q" README.md
  mv "$tmp/q.base" ".git/coddy/$q.base"
  t 0 "$tool: log shows the commits on a path" says init run log "$n" README.md
  t 0 "$tool: log treats a path starting with - as a path" test -z "$(run log "$n" --stat 2>&1)"
  t 1 "$tool: log refuses an issue with no worktree" run log 97 a.txt
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
  t 0 "$tool: that lock names this session" holds "sess-a $$" ".git/coddy/$p/owner"
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
  rm -rf ".git/coddy/$p"; : > ".git/coddy/$p"
  t 1 "$tool: state refuses a plain-file marker" run state "$p" phase=x
  t 0 "$tool: and says to re-claim" says "/coddy:start $p" run state "$p" phase=x
  rm -f ".git/coddy/$p"
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
  (cd ".worktrees/$p" && CLAUDE_PROJECT_DIR="$repo/.worktrees/$p" bash "$here/scripts/issue.sh" sweep) >/dev/null 2>&1
  t 0 "$tool: sweep keeps the worktree the session is in" test -d ".worktrees/$p"
  echo "sess-b 1" > ".git/coddy/$p/owner" # claimed by another session whose process runs
  kept "a merged worktree another running session holds"
  t 0 "$tool: and names that session" says "kept: $p (merged into main, session sess-b still holds it)" run sweep
  echo "sess-b $(sh -c 'echo $$')" > ".git/coddy/$p/owner" # that process has exited
  mkdir -p ".git/coddy/$p" && echo "phase=done" > ".git/coddy/$p/state"
  t 0 "$tool: sweep reports a merged, clean worktree as cleaned" sh -c "CLAUDE_PROJECT_DIR='$repo' bash '$here/scripts/issue.sh' sweep | grep -qx 'cleaned: $p'"
  t 1 "$tool: sweep removed that worktree" test -e ".worktrees/$p"
  t 1 "$tool: sweep removed its lock and branch record" test -e ".git/coddy/$p" -o -e ".git/coddy/$p.branch"
  t 1 "$tool: sweep removed its state" test -e ".git/coddy/$p/state"
  t 1 "$tool: sweep removed its local branch" git show-ref -q "refs/heads/ext/pr-$p"
  t 0 "$tool: sweep left the other worktree alone" test -d ".worktrees/$n"
  # The same worktree back, held by this session: swept as before.
  run create "$p" "ext/pr-$p" >/dev/null 2>&1 && mkdir ".git/coddy/$p" && echo "sess-a $$" > ".git/coddy/$p/owner"
  t 0 "$tool: sweep cleans a merged worktree this session holds" sh -c "CLAUDE_PROJECT_DIR='$repo' bash '$here/scripts/issue.sh' sweep | grep -qx 'cleaned: $p'"
  # Squash and rebase merges leave no ancestor, so sweep finds the branch's
  # two commits in main by patch id. A branch deleted from the remote
  # without a merge is not finished.
  for k in 40:squash 50:rebase 60:gone; do
    s=$((n + ${k%%:*})) m=${k#*:}
    run create "$s" "feat/$s-$m" >/dev/null 2>&1; run claim "$s" >/dev/null 2>&1
    echo "$m" > ".worktrees/$s/$m.txt"; run push "$s" "feat($s): one" >/dev/null 2>&1
    echo "$s" >> ".worktrees/$s/$m.txt"; run push "$s" "feat($s): two" >/dev/null 2>&1
    (git clone -q -b main "$tmp/origin.git" "$tmp/$m$s" && cd "$tmp/$m$s" && git commit -q --allow-empty -m "main moves on" && case $m in
      squash) git merge -q --squash "origin/feat/$s-$m" && git commit -q -m "feat($s): squashed" && git push -q origin main ;;
      rebase) git rebase -q main "origin/feat/$s-$m" && git push -q origin HEAD:main ;;
      gone) git push -q origin --delete "feat/$s-$m" ;;
    esac) >/dev/null 2>&1
    if [ "$m" = gone ]; then
      run sweep >/dev/null 2>&1; t 0 "$tool: sweep keeps an unmerged worktree whose remote branch was deleted" test -d ".worktrees/$s"
    else
      t 0 "$tool: sweep cleans a $m-merged worktree" sh -c "CLAUDE_PROJECT_DIR='$repo' bash '$here/scripts/issue.sh' sweep | grep -qx 'cleaned: $s'"
    fi
  done
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
t 0 "warn: a git worktree add outside .worktrees/ is let through with the message" noted '/coddy:start <issue>' 'git worktree add ../x'
for v in block wran; do
  printf 'tracker: github\ndefault_branch: main\nguard: %s\n' "$v" > .claude/coddy.yml
  t 2 "guard: $v blocks the main checkout" guard "$repo/README.md"
done

leg git 43
git -C .worktrees/43 checkout -q -b feat/43-other
t 1 "git: push refuses a worktree that left its recorded branch" run push 43
git -C .worktrees/43 checkout -q feat/43-thing
cp .claude/coddy.yml "$tmp/conf.yml"; printf 'version: 2\ntracker: github\ndefault_branch: main\n' > .claude/coddy.yml
t 0 "no worktree key at version 2: create makes a worktree" run create 44 feat/44-thing
t 0 "no worktree key at version 2: and it is git's, not jj's" sh -c 'test -e .worktrees/44/.git && ! test -e .worktrees/44/.jj'
git worktree remove --force .worktrees/44; git branch -qD feat/44-thing; rm -f .git/coddy/44.branch; cp "$tmp/conf.yml" .claude/coddy.yml
if command -v jj >/dev/null; then
  printf 'tracker: github\nworktree: jj\ndefault_branch: main\n' > .claude/coddy.yml
  t 1 "jj: create refuses a repo that is not jj-backed" run create 41 feat/41-thing
  jj git init --colocate >/dev/null 2>&1; echo '.jj/' >> .git/info/exclude
  leg jj 42
  printf 'tracker: github\ndefault_branch: main\n' > .claude/coddy.yml
  t 0 "no worktree key, no version: create makes a worktree" run create 45 feat/45-thing
  t 0 "no worktree key, no version: and it is jj's, until migrated" test -d .worktrees/45/.jj
  jj workspace forget 45 >/dev/null 2>&1; rm -rf .worktrees/45; jj bookmark delete feat/45-thing >/dev/null 2>&1; rm -f .git/coddy/45.branch
  printf 'tracker: github\nworktree: jj\ndefault_branch: main\n' > .claude/coddy.yml
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
wire snap mv; git mv README.md MOVED.md
wire trip mv 2>"$tmp/trip.err"; got=$?
t 0 "tripwire: a staged rename trips" test "$got" = 2
t 0 "tripwire: and names both of its paths whole" grep -q 'main checkout: MOVED.md README.md\.' "$tmp/trip.err"
git mv MOVED.md README.md
# A thousand dirty files cost one hash-object, not one each: a git on PATH
# that logs every hash-object it runs.
mkdir -p "$tmp/gitshim" "$repo/many"; real=$(command -v git)
printf '#!/bin/sh\n[ "$1" = hash-object ] && echo x >> "%s"\nexec "%s" "$@"\n' "$tmp/hashes" "$real" > "$tmp/gitshim/git"; chmod +x "$tmp/gitshim/git"
for i in $(seq 1000); do echo "$i" > "many/$i.txt"; done
: > "$tmp/hashes"; PATH="$tmp/gitshim:$PATH" wire snap many
t 0 "tripwire: 1000 dirty files are hashed by one hash-object" test "$(wc -l < "$tmp/hashes" | tr -d ' ')" = 1
t 0 "tripwire: and each is in the snapshot" test "$(grep -c '^many/.* [0-9a-f]\{40\}$' "${TMPDIR:-/tmp}"/coddy-snap-*-many)" = 1000
wire trip many 2>/dev/null; rm -r many
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
tripped 2 "tripwire: local commit in the main checkout, past the git hooks" 'git commit -q --no-verify --allow-empty -m oops'
git checkout -q side
tripped 0 "tripwire: quiet on the switch back to a default branch with local commits" 'git checkout -q main'
git branch -q -D side
tripped 2 "tripwire: local commit that was pushed to another branch" 'git commit -q --no-verify --allow-empty -m oops2 && git push -q --no-verify origin HEAD:refs/heads/elsewhere'

# A git worktree add or jj workspace add that would make a worktree outside
# .worktrees/<id>/ and .claude/worktrees/<name>/ is refused before it runs,
# read from the command's text, however it is written.
for g in 'git worktree add' 'jj workspace add'; do
  t 2 "$g: outside the project is refused" shell "$g ../x"
  t 0 "$g: that refusal names /coddy:start" says '/coddy:start <issue>' shell "$g ../x"
  t 2 "$g: in the main checkout is refused" shell "$g x"
  t 0 "$g: inside .worktrees/<id>/ passes" shell "$g .worktrees/77"
  t 0 "$g: inside .claude/worktrees/<name>/ passes" shell "$g .claude/worktrees/x"
  t 2 "$g: resolved against the command's directory" shell "$g x" "$tmp"
  t 0 "$g: from a subdirectory, into .worktrees/, passes" shell "$g ../.worktrees/77" "$repo/.claude"
  t 2 "$g: after a cd is refused" shell "cd .worktrees && $g ../../x"
  t 0 "$g: after a cd into .worktrees/ passes" shell "cd .worktrees && $g 77"
  t 2 "$g: in any segment of a compound command is refused" shell "echo a | grep a; true && $g /tmp/x"
  t 2 "$g: behind env prefixes is refused" shell "A=1 env B=2 command $g ../x"
  t 0 "$g: quoted as text passes" shell "echo '$g ../x'"
  t 0 "$g: in a heredoc body passes" shell $'cat <<EOF >/dev/null\n'"$g"$' ../x\nEOF'
done
t 2 "git worktree add: an option's value is not the path" shell 'git worktree add -b .worktrees/77 ../x'
t 0 "git worktree add: the path after the option's value is read" shell 'git worktree add -fb ../x .worktrees/77 main 2>/dev/null'
t 2 "git worktree add: after -- is refused" shell 'git worktree add --lock --reason "r s" -- ../x'
t 2 "git -C: the path resolves against its directory" shell 'git -c a=b -C .worktrees worktree add ../../x'
t 0 "git -C: into .claude/worktrees/ passes" shell 'git -C .claude worktree add worktrees/x'
t 2 "jj -R, --name and -r: refused outside" shell 'jj -R . workspace add --name x -r @ ../x'
t 0 "jj --name and -r: inside passes" shell 'jj workspace add --name x -r@- .worktrees/77'
t 0 "a cd in a subshell ends at its parenthesis" shell '(cd /tmp && true); git worktree add .worktrees/77'
t 2 "git --attr-source: its value is not the subcommand" shell 'git --attr-source HEAD worktree add ../x'
t 2 "a git worktree add in a quoted \$( is refused" shell 'echo "a $(git worktree add ../x) b"'
# A commit message from a heredoc in a quoted $( is text, odd quotes and all.
t 0 "a heredoc in a quoted \$( is not read as commands" shell "git commit -m \"\$(cat <<'EOF'
an odd \"quote
git worktree add ../x
EOF
)\""
t 0 "after a popd the directory is unknown: passes with a message" noted 'could not tell where' 'pushd /tmp && popd && git worktree add .worktrees/77'
t 0 "coddy's own start passes" shell "bash '$here/scripts/issue.sh' create 77 feat/77-worktree"
# A path the text cannot fix, or no jq, passes and says so.
for c in 'p=../x; git worktree add "$p"' 'git worktree add `echo ../x`' 'git worktree add ../x*' 'cd "$d" && jj workspace add x'; do
  t 0 "unresolved, passes with a message: $c" noted 'could not tell where' "$c"
done
# A command that ends in a two-character redirection is read and let through
# at once. prompt <command...>: it ends within five seconds; one that does
# not is killed, with every process it started.
prompt() { ( set -m; "$@" >/dev/null 2>&1 & p=$!; for _ in $(seq 50); do kill -0 "$p" 2>/dev/null || exit 0; sleep 0.1; done; kill -9 -- -"$p"; exit 1 ); }
for c in 'echo x >>' 'cat <<' 'ls 2>&' 'ls &>'; do t 0 "a command ending in its redirection is read promptly: $c" prompt shell "$c" "$repo/.worktrees/43"; done
nojq() { payload "$1" | PATH="$tmp/nojq" run snap; }
t 0 "without jq: a git worktree add passes" nojq 'git worktree add ../x'
t 0 "without jq: and says so" says 'jq is missing' nojq 'git worktree add ../x'
# After the command: a worktree outside coddy's, made by any spelling, trips;
# one inside, or one that was there before, does not.
wo=$(cd "$tmp" && pwd -P)/out
tripped 0 "tripwire: a git worktree in .worktrees/<id>/ is quiet" 'git worktree add -q --detach .worktrees/88'
tripped 0 "tripwire: a git worktree in .claude/worktrees/ is quiet" 'git worktree add -q --detach .claude/worktrees/y'
wire snap w; (cd "$repo" && git worktree add -q --detach "$wo") >/dev/null 2>&1
wire trip w 2>"$tmp/trip.err"; got=$?
t 0 "tripwire: a git worktree outside trips" test "$got" = 2
t 0 "tripwire: and names it with how to remove it" grep -qF "'$wo' (remove it: git worktree remove '$wo')" "$tmp/trip.err"
tripped 0 "tripwire: a worktree outside from before the command is quiet" 'true'
# A copy of its admin dir makes git list it twice: still not the command's.
wire snap w; cp -R "$(git -C "$wo" rev-parse --absolute-git-dir)" .git/worktrees/aacopy
t 0 "tripwire: a copied admin dir makes git list a worktree twice" test "$(git worktree list --porcelain | grep -cxF "worktree $wo")" = 2
t 0 "tripwire: and that worktree, from before the command, is quiet" wire trip w
rm -rf .git/worktrees/aacopy
t 0 "dodged: a git worktree add from a variable passes snap" noted 'could not tell where' 'p=../dodge; git worktree add -q --detach "$p"'
(cd "$repo" && p=../dodge; git worktree add -q --detach "$p") >/dev/null 2>&1
t 2 "dodged: and trips once it has run" wire trip sh
git worktree remove --force "$wo"; git worktree remove --force "$tmp/dodge"; git worktree remove --force .worktrees/88; git worktree remove --force .claude/worktrees/y
# A path built to read as a second entry with its own remedy is printed as
# one, quoted.
sp="$wo/z (remove it: rm -rf $tmp/none); $wo/w"
wire snap w; git worktree add -q --detach "$sp" >/dev/null 2>&1
wire trip w 2>"$tmp/trip.err"
t 0 "tripwire: a path holding a remedy of its own is one quoted entry" grep -qF ": '$sp' (remove it: git worktree remove '$sp'). Issue work" "$tmp/trip.err"
git worktree remove --force "$sp"
sq="$wo/it's"
wire snap w; git worktree add -q --detach "$sq" >/dev/null 2>&1
wire trip w 2>"$tmp/trip.err"; got=$?
t 0 "tripwire: a git worktree whose path holds a quote trips" test "$got" = 2
t 0 "tripwire: and is reported quoted" grep -qF "git worktree at '$wo/it'\\''s' (coddy gives no command" "$tmp/trip.err"
t 1 "tripwire: and names no command for it" grep -q 'remove it' "$tmp/trip.err"
git worktree remove --force "$sq"; rm -rf "$wo"
# A worktree made in .worktrees/<id>/ and moved out, or reached there through
# a link, is no longer coddy's: it trips, and only once.
tripped 2 "tripwire: a git worktree made in .worktrees/<id>/ and moved out trips" 'git worktree add -q -b evil .worktrees/87 && mv .worktrees/87 "$tmp/mv87"'
tripped 0 "tripwire: and is quiet on the next command" 'true'
tripped 2 "tripwire: one moved out with a link put back trips" 'git worktree add -q --detach .worktrees/86 && mv .worktrees/86 "$tmp/mv86" && ln -s "$tmp/mv86" .worktrees/86'
rm -rf "$tmp/mv87" "$tmp/mv86" .worktrees/86; git worktree prune; git branch -q -D evil
# A remedy acts only on the worktree the command made. rem runs the git one
# the message names, if any.
rem() { (cd "$repo" && eval "$(sed -n "s/.*(remove it: \(git worktree remove '[^']*'\)).*/\1/p" "$tmp/trip.err")") >/dev/null 2>&1; }
# A worktree at .worktrees itself, .worktrees/<id>/ moved aside and back into
# it and excluded, so its removal would pass: no command, and <id> survives.
git worktree add -q --detach .worktrees/84; echo wip > .worktrees/84/wip.txt; cp .git/info/exclude "$tmp/exclude"
wire snap w; (mv .worktrees "$tmp/wa" && git worktree add -q --detach .worktrees && mv "$tmp/wa/84" .worktrees/84 && echo 84 >> .git/info/exclude) >/dev/null 2>&1
wire trip w 2>"$tmp/trip.err"; got=$?; rem
t 0 "tripwire: a git worktree at .worktrees itself trips" test "$got" = 2
t 1 "tripwire: and names no command for it" grep -q 'remove it' "$tmp/trip.err"
t 0 "tripwire: and .worktrees/<id>/ in it survives" test -f .worktrees/84/wip.txt
mv .worktrees/84 "$tmp/wa/84"; git worktree remove --force .worktrees; mv "$tmp/wa" .worktrees; cp "$tmp/exclude" .git/info/exclude
# A worktree git moved out of .worktrees/<id>/ was not made: no command.
wire snap w; git worktree move .worktrees/84 "$wo" >/dev/null 2>&1
wire trip w 2>"$tmp/trip.err"; got=$?
t 0 "tripwire: a git worktree moved out of .worktrees/<id>/ by git trips" test "$got" = 2
t 0 "tripwire: and is reported moved, not made" grep -qF "git worktree at '$wo' (moved or renamed, not made" "$tmp/trip.err"
t 1 "tripwire: with no command to remove it" grep -q 'remove it' "$tmp/trip.err"
git worktree move "$wo" .worktrees/84
# A worktree outside swapped for a link to .worktrees/<id>/, whose .git now
# names the new one's admin dir: no command, and <id> survives.
cp .worktrees/84/.git "$tmp/gitfile"
wire snap w; (git worktree add -q --detach "$wo" && a=$(cat "$wo/.git") && rm -rf "$wo" && ln -s "$repo/.worktrees/84" "$wo" && echo "$a" > .worktrees/84/.git) >/dev/null 2>&1
wire trip w 2>"$tmp/trip.err"; got=$?; rem
t 0 "tripwire: a worktree outside swapped for a link to .worktrees/<id>/ trips" test "$got" = 2
t 1 "tripwire: and names no command for it" grep -q 'remove it' "$tmp/trip.err"
t 0 "tripwire: and .worktrees/<id>/ behind the link survives" test -f .worktrees/84/wip.txt
cp "$tmp/gitfile" .worktrees/84/.git; rm "$wo"; git worktree prune; git worktree remove --force .worktrees/84
# A backslash prints as \134, so it never reads as the \ooo of a control byte.
bs="$wo/b\\001" cc="$wo/b"$'\001'
wire snap w; (git worktree add -q --detach "$bs" && git worktree add -q --detach "$cc") >/dev/null 2>&1
wire trip w 2>"$tmp/trip.err"
t 0 "tripwire: a backslash in a path prints as \\134" grep -qF "'$wo/b\\134001'" "$tmp/trip.err"
t 0 "tripwire: and a control byte as \\ooo, a line of its own" grep -qF "'$wo/b\\001'" "$tmp/trip.err"
git worktree remove --force "$bs"; git worktree remove --force "$cc"; rm -rf "$wo"
# A path that is the root, a newline and more is no root: it trips, and with
# no command to remove it.
R=$(pwd -P); nl="$R"$'\n'x
wire snap w; git worktree add -q --detach "$nl" >/dev/null 2>&1
wire trip w 2>"$tmp/trip.err"; got=$?
t 0 "tripwire: a git worktree at the root, a newline and more trips" test "$got" = 2
t 1 "tripwire: and names no command for it" grep -q 'remove it' "$tmp/trip.err"
git worktree remove --force "$nl"
# A git before 2.36 has no worktree list -z: a stub git refuses it and lists
# without it as such a git did, every path raw. The worktrees are read all
# the same, and an entry the listing splits is read as odd.
mkdir "$tmp/oldgit"; real=$(command -v git)
cat > "$tmp/oldgit/git" <<EOF
#!/bin/sh
case "\$*" in
  "worktree list --porcelain -z") exit 129 ;;
  "worktree list --porcelain") "$real" worktree list --porcelain -z | tr '\0' '\n'; exit ;;
esac
exec "$real" "\$@"
EOF
chmod +x "$tmp/oldgit/git"; old() { PATH="$tmp/oldgit:$PATH" wire "$@"; }
old snap w; git worktree add -q --detach "$wo" >/dev/null 2>&1
old trip w 2>"$tmp/trip.err"; got=$?
t 0 "git before 2.36: a git worktree outside trips" test "$got" = 2
t 0 "git before 2.36: and names it" grep -qF "git worktree at '$wo' (coddy gives no command" "$tmp/trip.err"
t 1 "git before 2.36: with no command, since a raw path can forge entries" grep -q 'git worktree remove' "$tmp/trip.err"
git worktree remove --force "$wo"
old snap w; git worktree add -q --detach .worktrees/88 >/dev/null 2>&1
t 0 "git before 2.36: a git worktree in .worktrees/<id>/ is quiet" old trip w
git worktree remove --force .worktrees/88
old snap w; git worktree add -q --detach "$nl" >/dev/null 2>&1
old trip w 2>"$tmp/trip.err"; got=$?
t 0 "git before 2.36: a worktree at the root, a newline and more trips" test "$got" = 2
t 1 "git before 2.36: and names no command for it" grep -q 'remove it' "$tmp/trip.err"
git worktree remove --force "$nl"
if [ -d .jj ]; then
  # A user's ui.color = "always" colours no path, and a name jj shows quoted
  # is named as forget takes it, so the command in the message removes it.
  printf '[ui]\ncolor = "always"\n' > "$tmp/jj.toml"; export JJ_CONFIG="$tmp/jj.toml"
  tripped 0 "tripwire: a jj workspace in .worktrees/<id>/ is quiet" 'jj workspace add --name 89 .worktrees/89'
  tripped 2 "tripwire: a jj workspace moved out of .worktrees/<id>/ and linked back trips" 'jj workspace add --name 85 .worktrees/85 && mv .worktrees/85 "$tmp/mv85" && ln -s "$tmp/mv85" .worktrees/85'
  jj workspace forget 85 >/dev/null 2>&1; rm -rf "$tmp/mv85" .worktrees/85
  wire snap w; (cd "$repo" && jj workspace add --name 'o t' "$wo") >/dev/null 2>&1
  wire trip w 2>"$tmp/trip.err"; got=$?
  t 0 "tripwire: a jj workspace outside trips" test "$got" = 2
  t 0 "tripwire: and names it with how to remove it" grep -qF "'$wo' (remove it: jj workspace forget -- 'o t', then check that directory and delete it by hand)" "$tmp/trip.err"
  t 1 "tripwire: and deletes no directory itself" grep -q 'rm ' "$tmp/trip.err"
  (cd "$repo" && eval "$(sed -n 's/.*(remove it: \(jj workspace forget .*\), then check.*/\1/p' "$tmp/trip.err")") >/dev/null 2>&1
  t 1 "tripwire: and that command removes it" grep -qx 'o t' <(jj workspace list --ignore-working-copy --color=never -T 'stringify(name) ++ "\n"')
  # A jj workspace outside, renamed, was not made: no command.
  wp=${wo%/*}/o2; jj workspace add --name o2 "$wp" >/dev/null 2>&1
  wire snap w; (cd "$wp" && jj workspace rename o3) >/dev/null 2>&1
  wire trip w 2>"$tmp/trip.err"; got=$?
  t 0 "tripwire: a jj workspace outside, renamed, trips" test "$got" = 2
  t 0 "tripwire: and is reported renamed, not made" grep -qF "jj workspace 'o3' at '$wp' (moved or renamed, not made" "$tmp/trip.err"
  t 1 "tripwire: with no command for it" grep -q 'forget' "$tmp/trip.err"
  jj workspace forget o3 >/dev/null 2>&1; rm -rf "$wp"
  # A name or path holding a newline, a tab, a DEL or a C1 character is
  # reported escaped, with no command: one built to read as other entries
  # would aim it elsewhere.
  odd=$'77\n/some/dir\tdefault\x7f\xc2\x85'
  wire snap w; (cd .worktrees/89 && jj workspace rename "$odd") >/dev/null 2>&1
  wire trip w 2>"$tmp/trip.err"; got=$?
  t 0 "tripwire: a jj workspace renamed to hold a newline and a tab trips" test "$got" = 2
  t 0 "tripwire: and is reported escaped" grep -qF '"77\134n/some/dir\134tdefault\177\302\205"' "$tmp/trip.err"
  t 1 "tripwire: and names no command for it" grep -qE 'remove it|forget|rm ' "$tmp/trip.err"
  nl="$R"$'\n'"$R/.worktrees/zz"; mkdir -p "${nl%/*}"
  wire snap w; jj workspace add --name zz "$nl" >/dev/null 2>&1
  wire trip w 2>"$tmp/trip.err"; got=$?
  t 0 "tripwire: a jj workspace at the root, a newline and a coddy path trips" test "$got" = 2
  t 1 "tripwire: and names no command for it" grep -q 'remove it' "$tmp/trip.err"
  jj workspace forget "$odd" zz >/dev/null 2>&1; rm -rf "$wo" .worktrees/89 "$R"$'\n'; unset JJ_CONFIG
fi
# A project under a directory whose name holds a quote: coddy's own start
# there is quiet, since only what follows the root is held to the odd test.
qr="$tmp/q\"x/repo"; mkdir "${qr%/*}"; git clone -q -b main "$tmp/origin.git" "$qr" 2>/dev/null
mkdir "$qr/.claude"; printf 'tracker: github\nworktree: git\ndefault_branch: main\n' > "$qr/.claude/coddy.yml"
rp=$repo repo=$qr
tripped 0 "tripwire: git start under a directory named with a quote is quiet" 'run create 90 feat/90-q'
if command -v jj >/dev/null; then
  (cd "$qr" && jj git init --colocate && echo '.jj/' >> .git/info/exclude) >/dev/null 2>&1
  printf 'tracker: github\nworktree: jj\ndefault_branch: main\n' > "$qr/.claude/coddy.yml"
  tripped 0 "tripwire: jj start under a directory named with a quote is quiet" 'run create 91 feat/91-q'
fi
repo=$rp

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
# A shared (committed) config that changes through git is restored too: the user accepts it with /coddy:config.
# The legs merged branches into main on the remote: the local commits above go on
# top. git reset first: jj colocation left the untracked files as intent-to-add
# index entries, which a rebase refuses to start over.
git reset -q && git pull -q --rebase origin main
git add -f .claude/coddy.yml; git commit -q --no-verify -m "share config"; git push -q --no-verify origin HEAD:main # past the git hooks start installed
git clone -q -b main "$tmp/origin.git" "$tmp/mate" 2>/dev/null
(cd "$tmp/mate" && echo "roadmap: docs/ROADMAP.md" >> .claude/coddy.yml && git commit -q -am "roadmap" && git push -q origin HEAD:main)
tripped 2 "config: a pulled change to a shared config is restored" 'git fetch -q origin && git merge -q --ff-only origin/main'
t 1 "config: the pulled change waits for /coddy:config" grep -q '^roadmap:' .claude/coddy.yml
tripped 2 "config: a shell edit to a shared config still trips" 'echo "verify: true" >> .claude/coddy.yml'
t 1 "config: the shell edit to a shared config is undone" grep -q '^verify: true' .claude/coddy.yml

mkdir -p .worktrees/other
t 0 "issue.sh status lists a claimed issue with its branch" sh -c "CLAUDE_PROJECT_DIR='$repo' bash '$here/scripts/issue.sh' status | grep -q '^worktrees: .*43=feat/43-thing'"
t 1 "issue.sh status skips an unclaimed directory" sh -c "CLAUDE_PROJECT_DIR='$repo' bash '$here/scripts/issue.sh' status | grep -q other"
# owns <issue=owner> [session] [pid]: issue.sh status, run as that session, lists that owner
owns() { CLAUDE_CODE_SESSION_ID=${2-sess-a} CLAUDE_PID=${3-$$} CLAUDE_PROJECT_DIR="$repo" bash "$here/scripts/issue.sh" status | grep -q "^owners: .*$1"; }
t 0 "issue.sh status owners: this session's claim is me" owns "43=me"
t 0 "issue.sh status owners: still me under a new session id (/clear)" owns "43=me" sess-b
t 0 "issue.sh status owners: still me from a new process (--resume)" owns "43=me" sess-a 1
mkdir .git/coddy/other; echo "sess-d $(sh -c 'echo $$')" > .git/coddy/other/owner # that shell has exited
t 0 "issue.sh status owners: another session whose process exited is gone" owns "other=sess-d (gone)"
echo "sess-e 1" > .git/coddy/other/owner
t 0 "issue.sh status owners: another session whose process runs is running" owns "other=sess-e (running)"
echo "sess-e $$" > .git/coddy/other/owner
PATH="$tmp/nops:$PATH" t 0 "issue.sh status owners: a running process is running with no ps on PATH" owns "other=sess-e (running)" sess-a 1
echo "sess-f " > .git/coddy/other/owner
t 0 "issue.sh status owners: another session without a pid is running, as claim reads it" owns "other=sess-f (running)"
# A pid is the owner's only while it is the process that started then.
started=$(ps -o lstart= -p $$ | awk '{$1=$1; gsub(/ /,"_")} 1')
echo "sess-e $$ $started" > .git/coddy/other/owner
t 0 "issue.sh status owners: a running pid with the recorded start time is running" owns "other=sess-e (running)" sess-z 1
echo "sess-e $$ Thu_Jan_1_00:00:00_1970" > .git/coddy/other/owner
t 0 "issue.sh status owners: a running pid with another start time is gone" owns "other=sess-e (gone)"
t 1 "issue.sh status owners: and it is not me by that pid" owns "other=me" sess-z
PATH="$tmp/nops:$PATH" t 0 "issue.sh status owners: a start time ps cannot read counts as a match" owns "other=sess-e (running)" sess-z 1
t 0 "claim records the claiming process's start time" grep -qx "sess-a $$ $started" .git/coddy/43/owner
rm -r .git/coddy/other; : > .git/coddy/other
t 0 "issue.sh status owners: a marker from before locks is unknown" owns "other=unknown"
rm .git/coddy/other
t 0 "config.sh finds the config from inside a worktree" sh -c "cd '$repo/.worktrees/43' && CLAUDE_PROJECT_DIR='$repo/.worktrees/43' bash '$here/scripts/config.sh' | grep -q '^tracker:'"
# rooted <dir>: a session opened in that directory gets the project root from
# every script: issue.sh status prints it, config.sh and detect.sh find the config,
# and the guard holds the main checkout's README to it
rooted() (
  cd "$1" && export CLAUDE_PROJECT_DIR=$1
  bash "$here/scripts/issue.sh" status | grep -qx "root: $repo" || exit 1
  bash "$here/scripts/config.sh" | grep -q '^tracker:' || exit 1
  bash "$here/scripts/detect.sh" | grep -qx 'config: present' || exit 1
  bash "$here/scripts/detect.sh" | grep -qx "root: $repo" || exit 1
  printf '{"tool_input":{"file_path":"%s"}}' "$repo/README.md" | bash "$here/scripts/issue.sh" guard
  [ $? = 2 ]
)
mkdir -p sub/dir; git worktree add -q .claude/worktrees/x 2>/dev/null
for d in "" /sub/dir /.worktrees/43 /.claude/worktrees/x; do t 0 "root: resolved from ${d:-the repo root}" rooted "$repo$d"; done
[ ! -d .worktrees/42 ] || t 0 "root: resolved from a jj workspace" rooted "$repo/.worktrees/42"
git worktree remove --force .claude/worktrees/x; rm -r sub
# A .claude/settings.json env overrides CLAUDE_PROJECT_DIR in the Bash tool's
# environment (the hooks get the real one), so a cloned repository could move
# the root: every shim takes it, for a Bash-tool verb, only while the working
# directory is it or under it, compared by real path, and PWD cannot be set from there.
# from <dir> <CLAUDE_PROJECT_DIR> <root>: run there, every shim resolves that root
from() { (cd "$1" && export CLAUDE_PROJECT_DIR=$2 && bash "$here/scripts/issue.sh" status | grep -qx "root: $3" && bash "$here/scripts/detect.sh" | grep -qx "root: $3" && { [ "$3" != "$repo" ] || bash "$here/scripts/config.sh" | grep -q '^tracker:'; } && { [ "$3" = "$repo" ] || bash "$here/scripts/config.sh" | grep -qx NOT_ONBOARDED; }); }
mkdir "$tmp/other" "$tmp/repo2"; ln -s "$repo" "$tmp/link"
t 0 "shim: a CLAUDE_PROJECT_DIR that does not hold the working directory is ignored" from "$repo" "$tmp/other" "$repo"
t 0 "shim: so is one that holds it by spelling alone" from "$tmp/repo2" "$repo" "$tmp/repo2"
t 0 "shim: so is a relative one" from "$repo" .. "$repo"
t 0 "shim: one above the working directory is honoured" from "$repo" "$tmp" "$tmp"
t 0 "shim: one naming the working directory by its real path is honoured" from "$tmp/link" "$repo" "$repo"
rm -r "$tmp/other" "$tmp/repo2" "$tmp/link"
# The hooks get the real CLAUDE_PROJECT_DIR while their working directory
# follows the Bash tool's cd, so guard, snap and trip take it as it is: held
# to the working directory, a cd out of the project would drop the root, and
# every guardrail with it.
# away <command...>: run from outside the project, as a hook runs after that cd
away() { (cd "$tmp" && "$@"); }
# asks <path>: guard exits 0 and asks the user, as hook JSON
asks() { out=$(guard "$1") && printf %s "$out" | jq -e '.hookSpecificOutput | .hookEventName == "PreToolUse" and .permissionDecision == "ask"'; }
t 2 "hook: guard after a cd out of the project blocks the main checkout" away guard "$repo/README.md"
t 0 "hook: and asks on .coddy.yml" away asks "$repo/.coddy.yml"
away wire snap w; echo x > stray.txt; t 2 "hook: trip after a cd out of the project reports a stray write" away wire trip w; rm stray.txt
away wire snap w; rm .claude/coddy.yml; t 2 "hook: trip after a cd out of the project restores a deleted config" away wire trip w
t 0 "hook: and the config came back" same
wire snap w; t 0 "hook: a cd out of the project is not a change" away wire trip w
# detect <line> [VAR=value...]: detect.sh prints exactly that line
detect() { line=$1; shift; env CLAUDE_PROJECT_DIR="$repo" "$@" "$BASH" "$here/scripts/detect.sh" 2>/dev/null | grep -qx "$line"; }
detect_remote() {
  local expected=$1 url=$2 output
  git remote set-url origin "$url" || return 1
  output=$(env CLAUDE_PROJECT_DIR="$repo" "$BASH" "$here/scripts/detect.sh" 2>/dev/null) || return 1
  printf '%s\n' "$output" | grep -Fxq "remote: $expected" &&
    ! printf '%s\n' "$output" | grep -Fq 'coddy-test-secret'
}
t 0 "detect.sh reports an installed jq" detect 'jq: installed'
t 0 "detect.sh reports a missing jq" detect 'jq: missing' PATH="$tmp/bin"
t 0 "detect.sh reports no PR check" detect 'pr_check: none'
mkdir -p .github/workflows && : > .github/workflows/coddy.yml
t 0 "detect.sh reports the PR check once its workflow exists" detect 'pr_check: present'
rm -r .github
t 0 "detect.sh strips credentials from an HTTPS remote" detect_remote 'https://host/x.git' 'https://u:coddy-test-secret@host/x.git'
t 0 "detect.sh preserves an ordinary HTTPS remote" detect_remote 'https://host/x.git' 'https://host/x.git'
t 0 "detect.sh preserves an SCP-style SSH remote" detect_remote 'git@example.com:owner/repo.git' 'git@example.com:owner/repo.git'
git remote set-url origin "$tmp/origin.git"

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
