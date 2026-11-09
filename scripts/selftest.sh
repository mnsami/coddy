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
quiet() { local o; o=$("$@" 2>&1) && [ -z "$o" ]; } # the command exits 0 and prints nothing
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
# cmdline: trip's last message holds a removal command to paste
cmdline() { grep -qE "git worktree remove '|jj workspace forget -- '" "$tmp/trip.err"; }

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
# A PATH with everything snap needs but jq (jj too, once the root holds a .jj).
mkdir "$tmp/nojq"; for x in bash sed awk cat grep git jj cmp sort comm tr cut cksum mkdir cp rm head sleep stat xargs wc readlink; do p=$(command -v "$x") && ln -s "$p" "$tmp/nojq/$x"; done
# A jq that fails whatever it is asked: on PATH first when a case asks.
mkdir "$tmp/badjq"; printf '#!/bin/sh\nexit 1\n' > "$tmp/badjq/jq"; chmod +x "$tmp/badjq/jq"
# kept <what>: sweep leaves worktree $p alone
kept() { run sweep >/dev/null 2>&1; t 0 "$tool: sweep keeps $1" test -d ".worktrees/$p"; }

git init -q --bare "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$repo" 2>/dev/null
cd "$repo" || exit 1
git checkout -q -b main; echo hi > README.md; git add -A; git commit -q -m init; git push -q -u origin main
mkdir .claude
echo note > notes.txt; : > empty.txt # untracked on purpose: jj must not make these look like changes

t 1 "no skill disables model invocation" grep -rq disable-model-invocation "$here/skills"
t 1 "no skill or agent names a vendor skill" grep -rqE 'superpowers|code-review:' "$here/skills" "$here/agents"
t 0 "policy.md exists" test -f "$here/skills/start/references/policy.md"
# Each agent's body, after its frontmatter, is a title and then the policy.md line.
opens() { awk 'NR == 1 { if ($0 != "---") exit; next } !b { if ($0 == "---") b = 1; next } NF { if (++n == 1 && !/^# /) exit; if (n == 2) { print; exit } }' "$1" | grep -qxF 'Read `policy.md` at the path you were given first; its rules apply here. No path given, or the file cannot be read → stop and return `no policy path`.'; }
for b in context simplest implement harden review security; do t 0 "agent $b opens with policy.md" opens "$here/agents/$b.md"; done
# The briefs live in agents/ alone: a copy left next to start's would drift from it.
for b in context simplest implement harden review security; do t 1 "skills/start holds no $b brief" test -e "$here/skills/start/$b.md"; done
sed '1,/^# /!{/^Read `policy.md`/d;}' "$here/agents/review.md" > "$tmp/review.md"
t 1 "an agent whose body does not open with it fails it" opens "$tmp/review.md"
# Each agent's frontmatter: its name, a description that keeps it inside
# coddy:start, model: inherit for a call that passes none, and its tools. A
# tools line is an allowlist and none inherits every tool, so the four that
# must change nothing carry one without Write, Edit, NotebookEdit or Agent;
# their Bash, which a build with no Grep or Glob tool needs to search, can
# still write, which start's mark catches in the worktree.
fm() { awk 'NR == 1 { if ($0 != "---") exit; next } $0 == "---" { exit } { print }' "$1"; }
key() { fm "$1" | sed -n "s/^$2: *//p"; }
named() { [ "$(key "$1" name)" = "$2" ] && key "$1" description | grep -qF coddy:start; }
hastools() { fm "$1" | grep -q '^tools:'; }
lists() { key "$1" tools | tr , '\n' | sed 's/^ *//; s/ *$//' | grep -qxE "($2)(\(.*\))?"; }
for b in context simplest implement harden review security; do
  t 0 "agent $b has its name and a description naming coddy:start" named "$here/agents/$b.md" "$b"
  t 0 "agent $b has model: inherit" test "$(key "$here/agents/$b.md" model)" = inherit
done
for b in context simplest review security; do
  t 0 "agent $b has a tools line" hastools "$here/agents/$b.md"
  t 1 "agent $b lists no Write, Edit, NotebookEdit or Agent" lists "$here/agents/$b.md" 'Write|Edit|NotebookEdit|Agent|Task'
done
# and exactly these, so no other tool (an MCP write, a list form the checks above cannot read) slips in
for bt in 'context:Read, Grep, Glob, Bash' 'simplest:Read, Grep, Glob, Bash, Skill' 'review:Read, Grep, Glob, Bash, Skill' 'security:Read, Grep, Glob, Bash, Skill'; do
  t 0 "agent ${bt%%:*} lists exactly ${bt#*:}" test "$(key "$here/agents/${bt%%:*}.md" tools)" = "${bt#*:}"
done
for b in implement harden; do t 1 "agent $b has no tools line, so it inherits every tool" hastools "$here/agents/$b.md"; done
sed 's/^tools: .*/&, Edit/' "$here/agents/review.md" > "$tmp/review.md"
t 0 "the tools check finds an Edit added to an agent" lists "$tmp/review.md" 'Write|Edit|NotebookEdit|Agent|Task'
t 1 "policy.md never has a brief stage the whole tree" grep -q 'add -A' "$here/skills/start/references/policy.md"
literal() { grep -F 'Commit with the pattern' "$1" | grep -qF "root-file:" && grep -F 'Commit with the pattern' "$1" | grep -qF -- '--literal-pathspecs'; }
t 0 "policy.md tracks each new file by its literal path, never a directory" literal "$here/skills/start/references/policy.md"
shipasks() { grep -qF -- '-- <chosen paths>' "$1" && grep -qF 'No question tool (headless) → stop and print the list' "$1"; }
t 0 "ship: a push refused over untracked files asks which to include, or stops headless" shipasks "$here/skills/ship/SKILL.md"
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
# skill takes; start's never-list also names `agents/`, where its briefs live.
# A new skill goes in the table.
fallback() { line=$(grep -F '`CLAUDE_PLUGIN_ROOT` unexpanded' "$1") && for w in "coddy $2" 'never a `bin/coddy`' ${3-}; do case "$line" in *"$w"*) ;; *) return 1;; esac; done; }
for s in 'config status $ARGUMENTS' 'migrate status' 'next status' 'onboard detect' 'ship status $ARGUMENTS' 'start status $issue $onto $base `agents/`' 'triage status $ARGUMENTS'; do read -r n v a <<< "$s"; t 0 "skill $n carries the fallback for a host that does not inject" fallback "$here/skills/$n/SKILL.md" "$v" "$a"; done
grep -vF '`CLAUDE_PLUGIN_ROOT` unexpanded' "$here/skills/next/SKILL.md" > "$tmp/next.md"
t 1 "a skill that injects without the fallback fails it" fallback "$tmp/next.md" status
sed '/`CLAUDE_PLUGIN_ROOT` unexpanded/s/coddy status/coddy stat/' "$here/skills/next/SKILL.md" > "$tmp/next.md"
t 1 "one whose fallback drops the read-by-hand command fails it" fallback "$tmp/next.md" status
sed '/`CLAUDE_PLUGIN_ROOT` unexpanded/s|never a `bin/coddy`|never a copy|' "$here/skills/next/SKILL.md" > "$tmp/next.md"
t 1 "one whose fallback drops the never-a-bin/coddy clause fails it" fallback "$tmp/next.md" status
sed '/`CLAUDE_PLUGIN_ROOT` unexpanded/s| or `agents/`||' "$here/skills/start/SKILL.md" > "$tmp/start.md"
t 1 "start's fallback that takes an agents/ inside the project, where a brief could be planted, fails it" fallback "$tmp/start.md" status '$issue $onto $base `agents/`'
sed '/`CLAUDE_PLUGIN_ROOT` unexpanded/s/\$ARGUMENTS/$ARGS/' "$here/skills/triage/SKILL.md" > "$tmp/triage.md"
t 1 "one whose fallback drops its variable fails it" fallback "$tmp/triage.md" status '$ARGUMENTS'
# Every skill stops on a git_dir: line, which config, status and detect print in place of their output.
for f in "$here"/skills/*/SKILL.md; do t 0 "skill $(basename "$(dirname "$f")") stops on a git_dir: line" grep -q 'git_dir:` line.*stop and show that line as it is' "$f"; done
t 1 "no skill carries the injection syntax inside a line, which Claude Code would run" grep -qE '.!`' "$here"/skills/*/SKILL.md
t 0 "onboard names the AGENTS.md begin marker" grep -qF '<!-- coddy:begin -->' "$here/skills/onboard/SKILL.md"
t 0 "onboard names the AGENTS.md end marker" grep -qF '<!-- coddy:end -->' "$here/skills/onboard/SKILL.md"
# onboard is a resumable wizard: the agenda in order, answers saved under the
# agent dir, a stop on native Windows and on an existing config that names
# /coddy:config, and no install command for gh (the PR check runs it inside
# GitHub Actions alone), while each package manager detect can name gets one
# for jq.
t 0 "onboard names the seven wizard steps in order" grep -qF 'checks → tracker → branch → verify → tiers → AGENTS.md → review' "$here/skills/onboard/SKILL.md"
t 0 "onboard saves its answers under the agent dir" grep -qF '.claude/coddy/onboard-answers.json' "$here/skills/onboard/SKILL.md"
t 0 "onboard backs up what it replaces under the agent dir" grep -qF '.claude/coddy/backup/' "$here/skills/onboard/SKILL.md"
t 0 "onboard stops on an existing config and names /coddy:config" sh -c "grep -F 'config: present' '$here/skills/onboard/SKILL.md' | grep -qF '/coddy:config'"
t 0 "onboard stops on native Windows, writing nothing" grep -qF '`os: windows` → stop and write nothing' "$here/skills/onboard/SKILL.md"
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
t 0 "snap lets a push to the default branch through before onboarding" shell 'git push --force origin main'

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
  t 2 "$tool: and so is one in any case of worktrees/" guard "$repo/.claude/WorkTrees/$n/a.txt" sess-b
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
  t 0 "$tool: and one in any case of worktrees/" guard "$repo/.claude/WORKTREES/$n/a.txt"
  # The worktree's own pointer to the repository: git's .git file, jj's .jj/repo.
  for p in .git .jj/repo; do t 2 "$tool: guard blocks the claimed worktree's $p" saying 'a .git or .jj below the project root' guard "$repo/.worktrees/$n/$p"; done
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
  echo x > ".worktrees/$n/a.txt"; echo secret > ".worktrees/$n/.env"
  t 1 "$tool: push refuses uncommitted work without a message" run push "$n"
  t 1 "$tool: push refuses another session's worktree" as sess-b 1 push "$n" "feat($n): thing"
  t 0 "$tool: that refusal names the owner" says "belongs to session sess-a" as sess-b 1 push "$n" "feat($n): thing"
  # Nothing untracked is committed unless it is named after --.
  t 1 "$tool: push refuses untracked files" run push "$n" "feat($n): thing"
  t 0 "$tool: naming each on its own line, in single quotes" says "^'\.env'\$" run push "$n" "feat($n): thing"
  : > ".worktrees/$n/s.txt" # verify passes, so ship reaches the commit
  t 1 "$tool: so does ship" run ship "$n" "feat($n): thing"
  t 0 "$tool: naming each on its own line, in single quotes" says "^'\.env'\$" run ship "$n" "feat($n): thing"
  rm ".worktrees/$n/s.txt"
  t 1 "$tool: naming only some of them is refused too" run push "$n" "feat($n): thing" -- a.txt
  t 1 "$tool: a named path not in the worktree is refused" run push "$n" "feat($n): thing" -- a.txt .env nope.txt
  t 0 "$tool: naming it" says 'nope\.txt' run push "$n" "feat($n): thing" -- a.txt .env nope.txt
  t 2 "$tool: and nothing reached the remote" git ls-remote --exit-code origin "refs/heads/feat/$n-thing"
  rm ".worktrees/$n/.env"
  out=$(run push "$n" "feat($n): thing" -- a.txt 2>&1); r=$? # read whole: a grep -q that stops at the first line would cut the push short
  t 0 "$tool: push commits a named file and pushes" test "$r" = 0
  t 0 "$tool: and prints it" sh -c 'printf "%s\n" "$1" | grep -qx "committed: a\.txt"' _ "$out"
  t 0 "$tool: branch reached the remote" git ls-remote --exit-code origin "refs/heads/feat/$n-thing"
  if [ "$tool" = jj ]; then
    t 0 "jj: create turns auto-track off in the issue's workspace" test "$(jj -R ".worktrees/$n" config get snapshot.auto-track)" = 'none()'
    # A jj before 0.41, which has no --no-integrate-operation for push's untracked list.
    mkdir -p "$tmp/oldjj"; printf '#!/bin/sh\nfor a; do [ "$a" != --no-integrate-operation ] || exit 2; done\nexec %s "$@"\n' "$(command -v jj)" > "$tmp/oldjj/jj"; chmod +x "$tmp/oldjj/jj"
    PATH="$tmp/oldjj:$PATH" t 1 "jj: create refuses a jj before 0.41" run create "$n" "feat/$n-thing"
    PATH="$tmp/oldjj:$PATH" t 0 "jj: naming the version it needs" says 'jj 0\.41 or later' run create "$n" "feat/$n-thing"
    # The setting lives outside the project (jj's own config dir), so a re-run that finds it writes nothing.
    mkdir -p "$tmp/rojj"; printf '#!/bin/sh\ncase " $* " in *" config set "*) exit 3 ;; esac\nexec %s "$@"\n' "$(command -v jj)" > "$tmp/rojj/jj"; chmod +x "$tmp/rojj/jj"
    PATH="$tmp/rojj:$PATH" t 0 "jj: create on a workspace that already tracks no new file writes no config" run create "$n" "feat/$n-thing"
    # Claude Code's sandbox refuses that write, which jj keeps outside the project:
    # start names the sandbox and the user's one run from their own terminal.
    jj -R ".worktrees/$n" config unset --workspace snapshot.auto-track
    mkdir -p "$tmp/epjj"; printf '#!/bin/sh\ncase " $* " in *" config set "*) printf "Error: Failed to write config file\\nCaused by: Operation not permitted (os error 1)\\n" >&2; exit 1 ;; esac\nexec %s "$@"\n' "$(command -v jj)" > "$tmp/epjj/jj"; chmod +x "$tmp/epjj/jj"
    PATH="$tmp/epjj:$PATH" t 1 "jj: create that a sandbox keeps out of jj's config fails" run create "$n" "feat/$n-thing"
    PATH="$tmp/epjj:$PATH" t 0 "jj: naming the sandbox and the user's one run from their own terminal" says "sandbox.*from your own terminal, not through an agent: in .*, run start for issue $n on branch feat/$n-thing with the coddy at .*/coddy\. A rerun then writes nothing" run create "$n" "feat/$n-thing"
    run create "$n" "feat/$n-thing" >/dev/null 2>&1
    head -c 2097152 /dev/zero > ".worktrees/$n/big.bin"; was=$(git ls-remote origin "refs/heads/feat/$n-thing")
    t 0 "jj: a new file over snapshot.max-new-file-size is listed as untracked" says "^'big\.bin'\$" run push "$n" "feat($n): big"
    t 1 "jj: named, it is refused" run push "$n" "feat($n): big" -- big.bin
    t 0 "jj: naming it" says 'max-new-file-size.*big\.bin' sh -c "CLAUDE_PROJECT_DIR='$repo' bash '$here/scripts/issue.sh' push $n 'feat($n): big' -- big.bin 2>&1 | tr '\n' ' '"
    t 0 "jj: and nothing reached the remote" test "$(git ls-remote origin "refs/heads/feat/$n-thing")" = "$was"
    echo s > ".worktrees/$n/small.txt"
    t 1 "jj: named with a file it can track, it is refused" run push "$n" "feat($n): big" -- small.txt big.bin
    t 0 "jj: and that file is left untracked" says "^'small\.txt'\$" run push "$n" "feat($n): big" -- big.bin
    rm ".worktrees/$n/big.bin" ".worktrees/$n/small.txt"
  fi
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
  t 0 "$tool: push to a continued branch" as ${w% *} ${w#* } push "$p" "fix($p): more" -- more.txt # as the winner: push is the owner's too
  t 1 "$tool: that push moved the branch on the remote" test "$(git ls-remote origin "refs/heads/ext/pr-$p")" = "$was"
  mv ".worktrees/$p/more.txt" ".worktrees/$p/moved$p.txt" # per leg, as more.txt is
  out=$(as ${w% *} ${w#* } push "$p" "fix($p): moved" -- "moved$p.txt" 2>&1)
  t 0 "$tool: a rename's push prints both its paths" sh -c 'printf "%s\n" "$1" | grep -qx "committed: more\.txt" && printf "%s\n" "$1" | grep -qx "committed: moved$2\.txt"' _ "$out" "$p"
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
  t 0 "$tool: push of the stacked branch" run push "$q" "feat($q): stacked" -- s.txt
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
  t 1 "$tool: and kept no copy of a worktree with no ignored files" test -e ".git/coddy/swept/$p"
  t 1 "$tool: sweep removed its lock and branch record" test -e ".git/coddy/$p" -o -e ".git/coddy/$p.branch"
  t 1 "$tool: sweep removed its state" test -e ".git/coddy/$p/state"
  t 1 "$tool: sweep removed its local branch" git show-ref -q "refs/heads/ext/pr-$p"
  t 0 "$tool: sweep left the other worktree alone" test -d ".worktrees/$n"
  # The same worktree back, held by this session: swept as before.
  run create "$p" "ext/pr-$p" >/dev/null 2>&1 && mkdir ".git/coddy/$p" && echo "sess-a $$" > ".git/coddy/$p/owner"
  t 0 "$tool: sweep cleans a merged worktree this session holds" sh -c "CLAUDE_PROJECT_DIR='$repo' bash '$here/scripts/issue.sh' sweep | grep -qx 'cleaned: $p'"
  # Ignored files (a .env) are in no commit: the worktree moves whole under
  # .git/coddy/swept/<issue>, its .git and .jj dropped, unless a copy is there.
  run create "$p" "ext/pr-$p" >/dev/null 2>&1 && mkdir ".git/coddy/$p" && echo "sess-a $$" > ".git/coddy/$p/owner"
  echo .env >> .git/info/exclude; echo secret > ".worktrees/$p/.env"; mkdir -p ".git/coddy/swept/$p"
  kept "a merged worktree holding ignored files while an earlier copy is kept"
  t 0 "$tool: and names that copy" says "kept: $p (merged into main, but .git/coddy/swept/$p already holds an earlier copy)" run sweep
  t 0 "$tool: and leaves the copy as it was" test -z "$(ls -A ".git/coddy/swept/$p")"
  rmdir ".git/coddy/swept/$p"
  # Never through a link: the worktree stays, and nothing lands where it points.
  mv .git/coddy/swept "$tmp/swept$n"; mkdir "$tmp/out$n"; ln -s "$tmp/out$n" .git/coddy/swept
  kept "a merged worktree holding ignored files while .git/coddy/swept is a link"
  t 0 "$tool: and moves nothing through that link" test -z "$(ls -A "$tmp/out$n")"
  rm .git/coddy/swept; mv "$tmp/swept$n" .git/coddy/swept
  # A record that will not go (a locked git worktree, a jj forget that
  # fails) gets its directory back, whole: kept as it was.
  stub="$tmp/noforget$n"; mkdir -p "$stub"
  if [ "$tool" = git ]; then git worktree lock ".worktrees/$p"
  else printf '#!/bin/sh\ncase "$*" in *"workspace forget"*) exit 1 ;; esac\nexec '\''%s'\'' "$@"\n' "$(command -v jj)" > "$stub/jj"; chmod +x "$stub/jj"; fi
  PATH="$stub:$PATH" kept "a merged worktree holding ignored files whose record will not go"
  t 0 "$tool: and leaves it whole" test -e ".worktrees/$p/.$tool" -a -f ".worktrees/$p/.env"
  t 0 "$tool: and still a worktree" sh -c "if [ $tool = git ]; then git worktree list --porcelain | grep -q '/\.worktrees/$p\$'; else jj workspace list --ignore-working-copy | grep -q '^$p:'; fi"
  t 1 "$tool: and keeps no copy" test -e ".git/coddy/swept/$p"
  [ "$tool" = jj ] || git worktree unlock ".worktrees/$p"
  # Another worktree whose directory is away (moved by hand, on a drive not
  # mounted) keeps its admin data: only the swept one is forgotten.
  git worktree add -q --detach "$tmp/aside$n" >/dev/null 2>&1; mv "$tmp/aside$n" "$tmp/away$n"
  t 0 "$tool: sweep cleans a merged worktree holding ignored files, keeping them" sh -c "CLAUDE_PROJECT_DIR='$repo' bash '$here/scripts/issue.sh' sweep | grep -qx 'cleaned: $p (ignored files kept under .git/coddy/swept/$p)'"
  t 0 "$tool: the ignored file is in the swept copy" grep -qx secret ".git/coddy/swept/$p/.env"
  t 1 "$tool: which holds no .git" test -e ".git/coddy/swept/$p/.git"
  t 1 "$tool: and no .jj" test -e ".git/coddy/swept/$p/.jj"
  t 1 "$tool: the worktree is gone" test -e ".worktrees/$p"
  t 1 "$tool: git lists it no longer" sh -c "git worktree list --porcelain | grep -qx 'worktree .*/\.worktrees/$p'"
  [ "$tool" = git ] || t 1 "jj: jj lists it no longer" sh -c "jj workspace list --ignore-working-copy | grep -q '^$p:'"
  t 1 "$tool: its lock and branch record are gone" test -e ".git/coddy/$p" -o -e ".git/coddy/$p.branch"
  t 1 "$tool: and its local branch" git show-ref -q "refs/heads/ext/pr-$p"
  t 0 "$tool: and leaves git another worktree whose directory is away" sh -c "git worktree list --porcelain | grep -q '/aside$n\$'"
  mv "$tmp/away$n" "$tmp/aside$n"; git worktree remove --force "$tmp/aside$n" >/dev/null 2>&1
  # A record named swept is no issue: the directory its lock would be holds the copies.
  run create swept "ext/pr-$p" >/dev/null 2>&1; run sweep >/dev/null 2>&1
  t 0 "$tool: sweep never takes .git/coddy/swept for an issue's lock" grep -qx secret ".git/coddy/swept/$p/.env"
  if [ "$tool" = jj ]; then jj workspace forget swept >/dev/null 2>&1; rm -rf .worktrees/swept; jj bookmark forget "ext/pr-$p" >/dev/null 2>&1
  else git worktree remove --force .worktrees/swept >/dev/null 2>&1; git branch -qD "ext/pr-$p" >/dev/null 2>&1; fi
  rm -f .git/coddy/swept.branch .git/coddy/swept.base
  # Ignored files find cannot list (in a directory it may not read, a
  # database another user owns) count as some: the worktree moves whole.
  rm -rf ".git/coddy/swept/$p"
  run create "$p" "ext/pr-$p" >/dev/null 2>&1 && mkdir ".git/coddy/$p" && echo "sess-a $$" > ".git/coddy/$p/owner"
  echo locked/ >> .git/info/exclude; mkdir ".worktrees/$p/locked"; echo db > ".worktrees/$p/locked/db"; chmod 000 ".worktrees/$p/locked"
  t 0 "$tool: sweep moves a merged worktree whose ignored files cannot be listed" sh -c "CLAUDE_PROJECT_DIR='$repo' bash '$here/scripts/issue.sh' sweep | grep -qx 'cleaned: $p (ignored files kept under .git/coddy/swept/$p)'"
  chmod 755 ".git/coddy/swept/$p/locked" ".worktrees/$p/locked" 2>/dev/null
  t 0 "$tool: and keeps them" grep -qx db ".git/coddy/swept/$p/locked/db"
  # jj names paths it never writes to disk (one outside the sparse patterns, a
  # submodule's gitlink): the ignored files are the ones on disk it does not
  # name, however few. The gitlink goes from main again once merged.
  if [ "$tool" = jj ]; then
    for k in sparse submodule; do
      [ "$k" = sparse ] || (cd "$tmp/merge$p" && git fetch -q origin && git checkout -q -b "sub$p" "origin/ext/pr-$p" && git update-index --add --cacheinfo "160000,$(git rev-parse HEAD),sub" && git commit -q -m "sub $p" && git push -q origin "HEAD:ext/pr-$p" && git checkout -q main && git merge -q --no-ff -m "merge sub $p" "sub$p" && git rm -q --cached sub && git commit -q -m "drop sub $p" && git push -q origin main) >/dev/null 2>&1
      rm -rf ".git/coddy/swept/$p"
      run create "$p" "ext/pr-$p" >/dev/null 2>&1 && mkdir ".git/coddy/$p" && echo "sess-a $$" > ".git/coddy/$p/owner"
      [ "$k" = submodule ] || jj -R ".worktrees/$p" sparse set --clear --add nothing >/dev/null 2>&1
      echo secret > ".worktrees/$p/.env"
      t 0 "jj: sweep moves a merged $k workspace holding ignored files" sh -c "CLAUDE_PROJECT_DIR='$repo' bash '$here/scripts/issue.sh' sweep | grep -qx 'cleaned: $p (ignored files kept under .git/coddy/swept/$p)'"
      t 0 "jj: and keeps them in the $k workspace's copy" grep -qx secret ".git/coddy/swept/$p/.env"
    done
  fi
  # Submodules checked out in a git worktree keep their repositories in its
  # git dir, which git refuses to remove: the worktree stays, as before.
  if [ "$tool" = git ]; then
    rm -rf ".git/coddy/swept/$p"
    run create "$p" "ext/pr-$p" >/dev/null 2>&1 && mkdir ".git/coddy/$p" && echo "sess-a $$" > ".git/coddy/$p/owner"
    echo secret > ".worktrees/$p/.env"; gd=$(git -C ".worktrees/$p" rev-parse --absolute-git-dir); mkdir -p "$gd/modules/sub"
    kept "a merged worktree whose submodules' repositories live in its git dir"
    t 0 "git: and keeps those repositories" test -d "$gd/modules/sub"
    rm -rf "$gd/modules" ".worktrees/$p/.env"; run sweep >/dev/null 2>&1
  fi
  sed -i.bak '/^\.env$/d;/^locked\/$/d' .git/info/exclude && rm -f .git/info/exclude.bak
  # Squash and rebase merges leave no ancestor, so sweep finds the branch's
  # two commits in main by patch id. A branch deleted from the remote
  # without a merge is not finished.
  for k in 40:squash 50:rebase 60:gone; do
    s=$((n + ${k%%:*})) m=${k#*:}
    run create "$s" "feat/$s-$m" >/dev/null 2>&1; run claim "$s" >/dev/null 2>&1
    echo "$m" > ".worktrees/$s/$m.txt"; run push "$s" "feat($s): one" -- "$m.txt" >/dev/null 2>&1
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
t 0 "guard allows .claude/settings.json" guard "$repo/.claude/settings.json"
t 2 "guard blocks a Claude Code worktree under .claude/ without a claim" guard "$repo/.claude/worktrees/55/a.txt"
t 2 "guard blocks one in any case of worktrees/" guard "$repo/.claude/WORKTREES/55/a.txt"
t 0 "guard: and holds it to that issue's claim" says 'issue 55 is not In Progress' guard "$repo/.claude/WORKTREES/55/a.txt"
t 0 "guard ignores paths outside the project" guard "$tmp/elsewhere.txt"
# Claude Code hands the hooks the physical project dir; a path through a link to it is the project's.
ln -s "$repo" "$tmp/alias"
t 2 "guard blocks the main checkout through a link to the project" sh -c "printf '{\"session_id\":\"sess-a\",\"tool_input\":{\"file_path\":\"%s\"}}' '$tmp/alias/README.md' | CLAUDE_PROJECT_DIR='$(cd "$repo" && pwd -P)' bash '$here/scripts/issue.sh' guard"
t 2 "guard rejects .. paths" guard "$repo/.worktrees/../README.md"
t 2 "guard rejects .. paths hidden behind a newline" guard "$repo/.claude/x\\n/../../README.md"
mkdir -p .git/coddy/66 && echo "sess-f " > .git/coddy/66/owner # a claim run without CLAUDE_PID
t 0 "guard reads an owner without a pid as running, as claim does" says "(pid , running)" guard "$repo/.worktrees/66/a.txt" sess-b
rm -r .git/coddy/66
# hook <verb> <payload> <NAME=value...>: the first entry in hooks/hooks.json
# naming that verb, run as Claude Code runs exec form (no shell,
# ${CLAUDE_PLUGIN_ROOT} substituted), with the variables a .claude/settings.json
# env can put in its environment (a later CLAUDE_PROJECT_DIR wins)
hook() { local v=$1 p=$2; shift 2; eval "set -- \"\$@\" $(jq -r --arg v "$v" --arg r "$here" 'first(.hooks[][].hooks[] | select(.args | index($v))) | [.command] + .args | map(split("${CLAUDE_PLUGIN_ROOT}") | join($r)) | @sh' "$here/hooks/hooks.json")"; printf %s "$p" | env CLAUDE_PROJECT_DIR="$repo" "$@"; }
t 0 "hooks: every hook runs in exec form through env -u SHELLOPTS -u BASHOPTS -u FUNCNEST -u POSIXLY_CORRECT -u POSIX_PEDANTIC -u OSTYPE /bin/sh and the launcher" jq -e '[.hooks[][].hooks[]] | all(.command == "/usr/bin/env" and .args[:14] == ["-u", "SHELLOPTS", "-u", "BASHOPTS", "-u", "FUNCNEST", "-u", "POSIXLY_CORRECT", "-u", "POSIX_PEDANTIC", "-u", "OSTYPE", "/bin/sh", "${CLAUDE_PLUGIN_ROOT}/scripts/hook.sh"])' "$here/hooks/hooks.json"
t 0 "hooks: the launcher is executable" test -x "$here/scripts/hook.sh"
# The whole hooks/hooks.json table, in one equality: event, matcher, type, the
# verb and its args after the script path, onFailure and timeout. The launcher
# prefix is asserted above, so a change to it touches that line alone.
hookwant='[
 {"e":"SessionStart","m":"startup|resume","t":"command","a":["link","${CLAUDE_PLUGIN_DATA}"],"f":null,"o":null},
 {"e":"PreToolUse","m":"Edit|Write|NotebookEdit","t":"command","a":["guard"],"f":"block","o":10},
 {"e":"PreToolUse","m":"Bash","t":"command","a":["snap"],"f":"block","o":60},
 {"e":"PostToolUse","m":"Bash","t":"command","a":["trip"],"f":null,"o":null},
 {"e":"PostToolUseFailure","m":"Bash","t":"command","a":["trip"],"f":null,"o":null}]'
hooktable() { jq -e --argjson w "$hookwant" '[.hooks | to_entries[] | .key as $e | .value[] | .matcher as $m | .hooks[] | {e:$e,m:$m,t:.type,a:((.args | map(endswith("/scripts/hook.sh")) | index(true)) as $i | .args[$i+1:]),f:.onFailure,o:.timeout}] | sort_by(tojson) == ($w | sort_by(tojson))' "$1"; }
t 0 "hooks: the table is the five entries, with their matchers, verbs, onFailure and timeouts" hooktable "$here/hooks/hooks.json"
hmut() { jq "$1" "$here/hooks/hooks.json" > "$tmp/hooks.json"; hooktable "$tmp/hooks.json"; }
t 1 "hooks: a guard matcher shrunk to Edit fails the table" hmut '.hooks.PreToolUse[0].matcher = "Edit"'
t 1 "hooks: PostToolUseFailure's trip pointed at a nonexistent verb fails it" hmut '.hooks.PostToolUseFailure[0].hooks[0].args[-1] = "nope"'
t 1 "hooks: both trip entries pointed at one verb fail it" hmut '.hooks.PostToolUse[0].hooks[0].args[-1] = "guard" | .hooks.PostToolUseFailure[0].hooks[0].args[-1] = "guard"'
t 1 "hooks: PostToolUseFailure removed fails it" hmut 'del(.hooks.PostToolUseFailure)'
t 1 "hooks: an extra hook entry fails it" hmut '.hooks.PostToolUse += [.hooks.PostToolUse[0]]'
t 1 "hooks: an extra event fails it" hmut '.hooks.Stop = .hooks.PostToolUse'
# PostToolUseFailure is the entry a failing command fires, and hook() runs the
# first trip, PostToolUse's: run this one too, with its payload shape.
failtrip() { eval "set -- $(jq -r --arg r "$here" '.hooks.PostToolUseFailure[0].hooks[0] | [.command] + .args | map(split("${CLAUDE_PLUGIN_ROOT}") | join($r)) | @sh' "$here/hooks/hooks.json")"; printf '{"hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_use_id":"w","error":"Exit code 1"}' | env CLAUDE_PROJECT_DIR="$repo" "$@"; }
wire snap w; echo x > stray.txt; t 2 "hooks: the PostToolUseFailure entry trips on a stray file" failtrip; rm stray.txt
# Every skill's allowed-tools and body agree, both ways: each injected script
# and issue.sh verb a body calls has a rule that glob-matches it (a trailing :*
# read as " *", as Claude Code does), each rule is used by its own body, and
# each MCP tool a body names in backticks, of those any skill allows, is in its
# own allowed-tools. take and drop are prompt-gated: gated() below allows only
# a closed list of rule shapes, and a body may call them without a rule. MCP names drifting upstream is
# not checked here.
rules() { sed -n 's/^allowed-tools: //p' "$1" | tr ',' '\n' | sed 's/^ *//;s/ *$//'; }
# allowed-tools must be one plain line: a continuation line or a value opening
# with a quote, >, |, [, {, * or & is a form rules() does not read, so it fails;
# blank lines are skipped before the indentation test, as YAML folds them in.
atform() { awk -v q="'" '/^allowed-tools:/{f=1; v=substr($0,15); sub(/^ +/,"",v); if (v ~ ("^[" q "\">|[{*&]")) exit 1; next} f{if ($0 ~ /^[ \t]*$/) next; exit ($0 ~ /^[ \t]/)}' "$1"; }
mirror() {
  local f body at all r p c calls ok short bad=0
  all=$(for f in "$1"/*/SKILL.md; do rules "$f"; done | sed -n 's/^mcp__.*__//p' | sort -u)
  for f in "$1"/*/SKILL.md; do
    atform "$f" || { echo "$f: allowed-tools is not a plain line" >&2; bad=1; }
    body=$(awk '/^---$/{n++;next} n>=2' "$f"); at=$(rules "$f")
    while IFS= read -r c; do
      case $c in ''|*'issue.sh" take'|*'issue.sh" take '*|*'issue.sh" drop'|*'issue.sh" drop '*) continue ;; esac
      ok=1
      while IFS= read -r r; do
        # shellcheck disable=SC2053 # the rule is a glob, as Claude Code matches it
        case $r in Bash\(*\)) p=${r#Bash(}; p=${p%)}; case $p in *:\*) p="${p%:\*} *" ;; esac; [[ $c == $p ]] && ok=0 ;; esac
      done <<< "$at"
      [ $ok = 0 ] || { echo "$f: no rule for: $c" >&2; bad=1; }
    done <<< "$(printf '%s\n' "$body" | grep -o 'bash "${CLAUDE_PLUGIN_ROOT}/scripts/[a-z]*\.sh"[^`]*')"
    calls=$(printf '%s\n' "$body" | grep -o -e 'bash "${CLAUDE_PLUGIN_ROOT}/scripts/[a-z]*\.sh"[^`]*' -e '`[^`]*`' | tr -d '`')
    while IFS= read -r r; do
      ok=1
      case $r in
        mcp__*) printf '%s\n' "$body" | grep -qF -- "${r##*__}" && ok=0 ;;
        Bash\(*\)) p=${r#Bash(}; p=${p%)}; case $p in *:\*) p="${p%:\*} *" ;; esac
          while IFS= read -r c; do
            # shellcheck disable=SC2053 # the rule is a glob, as Claude Code matches it
            [[ $c == $p ]] && { ok=0; break; }
          done <<< "$calls" ;;
        *) printf '%s\n' "$body" | grep -qF -- "$r" && ok=0 ;;
      esac
      [ $ok = 0 ] || { echo "$f: unused rule: $r" >&2; bad=1; }
    done <<< "$at"
    while IFS= read -r short; do
      [ -n "$short" ] || continue
      ! printf '%s\n' "$body" | grep -qF "\`$short\`" || printf '%s\n' "$at" | grep -q "__$short\$" || { echo "$f: $short is not allowed" >&2; bad=1; }
    done <<< "$all"
  done
  return $bad
}
# take and drop are prompt-gated by an allowlist: every Bash rule must equal, character for character, one shape
# below. A new pre-approved form is added here on purpose; take and drop never.
SH='bash "${CLAUDE_PLUGIN_ROOT}/scripts'
shapes=("Bash($SH/config.sh\")" "Bash($SH/detect.sh\")" 'Bash(date +%Y%m%d-%H%M%S)')
for v in 'claim *' 'create *' 'diff *' 'exclude answers' 'exclude config' 'forget answers' 'log *' 'mark *' migrate 'push *' 'state *' status sweep 'verify *'; do shapes+=("Bash($SH/issue.sh\" $v)"); done
gated() {
  local f r s ok
  for f in "$1"/*/SKILL.md; do
    # a list-form allowed-tools has no single-line value: unread, so a failure
    [ -n "$(rules "$f")" ] || return 1
    atform "$f" || return 1
    while IFS= read -r r; do
      [ "$r" != Bash ] || return 1
      case $r in Bash\(*) ;; *) continue ;; esac
      ok=1
      for s in "${shapes[@]}"; do [ "$r" = "$s" ] && ok=0; done
      [ $ok = 0 ] || return 1
    done <<< "$(rules "$f")"
  done
  return 0
}
sk() { rm -rf "$tmp/sk"; cp -R "$here/skills" "$tmp/sk"; }
skadd() { sk; printf '%s\n' "$2" >> "$tmp/sk/$1/SKILL.md"; "${@:3}" "$tmp/sk"; }
skrule() { sk; sed "s|^allowed-tools: .*|&, $2|" "$here/skills/$1/SKILL.md" > "$tmp/sk/$1/SKILL.md"; "${@:3}" "$tmp/sk"; }
gatedlist() { sk; sed 's|^allowed-tools: .*|allowed-tools:\n  - Bash|' "$here/skills/next/SKILL.md" > "$tmp/sk/next/SKILL.md"; gated "$tmp/sk"; }
skcont() { sk; sed 's|^allowed-tools: .*|&\n  Bash(coddy take *)|' "$here/skills/next/SKILL.md" > "$tmp/sk/next/SKILL.md"; "$@" "$tmp/sk"; }
skblank() { sk; sed 's|^allowed-tools: .*|&\n\n  Bash(coddy take *)|' "$here/skills/next/SKILL.md" > "$tmp/sk/next/SKILL.md"; "$@" "$tmp/sk"; }
skquote() { sk; sed 's|^allowed-tools: \(.*\)|allowed-tools: "\1"|' "$here/skills/next/SKILL.md" > "$tmp/sk/next/SKILL.md"; "$@" "$tmp/sk"; }
R='bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh"'
t 0 "skills: every body and allowed-tools agree, both ways" mirror "$here/skills"
t 0 "skills: no rule pre-approves take or drop" gated "$here/skills"
t 1 "skills: an issue.sh verb called without its rule fails" skadd next "\`$R frobnicate\`" mirror
t 1 "skills: an injected script without its rule fails" skadd next "\`bash \"\${CLAUDE_PLUGIN_ROOT}/scripts/detect.sh\"\`" mirror
t 1 "skills: a rule no body uses fails" skrule next "Bash($R frobnicate *)" mirror
t 1 "skills: an MCP tool named in backticks without its entry fails" skadd next '`create_pull_request`' mirror
t 1 "skills: a claim rule with no operand, whose body calls always have one, fails" skrule start "Bash($R claim)" mirror
t 1 "skills: a rule cut short of any call fails" skrule start "Bash($R cre *)" mirror
t 0 "skills: a body calling take or drop without a rule passes" skadd next "\`$R take 7\` and \`$R drop 7 --force\`" mirror
t 1 "skills: a body calling takeover without a rule fails" skadd next "\`$R takeover 7\`" mirror
t 1 "skills: a body calling dropall without a rule fails" skadd next "\`$R dropall\`" mirror
t 1 "skills: a take rule fails" skrule next "Bash($R take *)" gated
t 1 "skills: a drop rule fails" skrule next "Bash($R drop 7 --force)" gated
t 1 "skills: a broad issue.sh rule fails" skrule next "Bash($R *)" gated
t 1 "skills: a rule on the core path fails" skrule next 'Bash(bash "${CLAUDE_PLUGIN_ROOT}/bin/coddy" status)' gated
t 1 "skills: an unquoted shim path rule fails" skrule next 'Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh status)' gated
t 1 "skills: a single-quoted shim path rule fails" skrule next "Bash(bash '\${CLAUDE_PLUGIN_ROOT}/scripts/issue.sh' status)" gated
t 1 "skills: a form outside the list fails" skrule next "Bash($R frobnicate *)" gated
t 1 "skills: a coddy rule fails" skrule next "Bash(coddy status)" gated
t 1 "skills: a bare Bash fails" skrule next "Bash" gated
t 1 "skills: Bash(*) fails" skrule next 'Bash(*)' gated
t 1 "skills: Bash(bash *) fails" skrule next 'Bash(bash *)' gated
t 1 "skills: Bash(bash:*) fails" skrule next 'Bash(bash:*)' gated
t 1 "skills: a plugin-root wildcard rule fails" skrule next 'Bash(bash "${CLAUDE_PLUGIN_ROOT}*)' gated
t 1 "skills: an allowed-tools in list form, unread, fails" gatedlist
t 1 "skills: a continuation line holding a take rule fails the gate" skcont gated
t 1 "skills: a continuation line fails the mirror" skcont mirror
t 1 "skills: a blank line before a continuation fails the gate" skblank gated
t 1 "skills: a blank line before a continuation fails the mirror" skblank mirror
t 1 "skills: a quoted allowed-tools value fails the gate" skquote gated
t 1 "skills: a quoted allowed-tools value fails the mirror" skquote mirror
# The other openers atform rejects: skopen <replacement of the value, \1 being it> <check>.
skopen() { sk; sed "s#^allowed-tools: \\(.*\\)#allowed-tools: $1#" "$here/skills/next/SKILL.md" > "$tmp/sk/next/SKILL.md"; shift; "$@" "$tmp/sk"; }
for op in "single-quoted:'\\1'" "> block scalar:>"$'\\\n'"  \\1" "| block scalar:|"$'\\\n'"  \\1" "flow sequence:[\\1]" "flow mapping:{\\1}" "alias:*\\1" "anchor:\\&\\1"; do
  for ck in gated mirror; do t 1 "skills: a ${op%%:*} allowed-tools value fails the $ck" skopen "${op#*:}" "$ck"; done
done
t 1 "skills: a take rule cut at a comma inside its parentheses fails" skrule next "Bash(x, coddy take *)" gated
# A hook blocks only on exit 2, so the shim makes every other exit of guard
# or snap a 2 with a message, a core it cannot read included, and a coddy
# crash blocks the call; trip keeps its own.
mkdir -p "$tmp/fk/scripts" "$tmp/fk/bin"; cp "$here/scripts/issue.sh" "$tmp/fk/scripts/"
fk() { printf '{}' | "$1" -p "$tmp/fk/scripts/issue.sh" "$2" 2>"$tmp/fk.err"; }
for sh in bash /bin/bash; do
  for c in 'exit 1' 'set -u; echo "$nope"' missing; do
    rm -f "$tmp/fk/bin/coddy"; [ "$c" = missing ] || echo "$c" > "$tmp/fk/bin/coddy"
    for v in guard snap; do
      t 2 "hooks: $v exits 2 on a core that ends $c, under $sh" fk "$sh" "$v"
      t 0 "hooks: and says so: $v, $c, under $sh" grep -q "coddy: the $v hook failed (exit [0-9]*), so the call is refused" "$tmp/fk.err"
      t 0 "hooks: and names what to do, in plain text: $v, $c, under $sh" grep -q "until the user updates or reinstalls the coddy plugin, or disables it\.$" "$tmp/fk.err"
    done
    t 1 "hooks: trip keeps its own exit on a core that ends $c, under $sh" sh -c 'fk() { printf "{}" | "$1" -p "$2" trip; }; fk "$1" "$2"; r=$?; [ "$r" = 0 ] || [ "$r" = 2 ]' - "$sh" "$tmp/fk/scripts/issue.sh"
  done
  for c in 0 2; do echo "exit $c" > "$tmp/fk/bin/coddy"; for v in guard snap; do t "$c" "hooks: $v keeps exit $c, under $sh" fk "$sh" "$v"; t 0 "hooks: and adds nothing: $v $c, under $sh" test ! -s "$tmp/fk.err"; done; done
done
rm -rf "$tmp/fk"
# Each under the bash on PATH and under /bin/bash (3.2 on macOS) first on PATH.
# GREP_OPTIONS and TMOUT are the core's to unset, not hooks.json's: they act
# only once it runs a grep (BSD grep honours it) or a read (bash 5 takes a
# fraction of a second, which times out reads from process substitutions).
# A BASH_ENV file and a function in the environment are bash -p's to skip.
mkdir "$tmp/sysbash"; ln -s /bin/bash "$tmp/sysbash/bash"; echo 'exit 0' > "$tmp/exit0"
for b in "" "$tmp/sysbash:"; do
  t 0 "hooks: guard${b:+ under /bin/bash} lets the agent dir through" hook guard "{\"session_id\":\"sess-a\",\"tool_input\":{\"file_path\":\"$repo/.claude/x\"}}" PATH="$b$PATH"
  # bash takes OSTYPE from the environment, so one an env sets would refuse every edit.
  t 0 "hooks: OSTYPE=msys${b:+ under /bin/bash} leaves guard as it was" hook guard "{\"session_id\":\"sess-a\",\"tool_input\":{\"file_path\":\"$repo/.claude/x\"}}" OSTYPE=msys PATH="$b$PATH"
  t 0 "hooks: snap${b:+ under /bin/bash} lets a command through" hook snap "$(payload true)" PATH="$b$PATH"
  # bash before 5.1 takes POSIX_PEDANTIC, as it does POSIXLY_CORRECT, for posix mode.
  t 0 "hooks: POSIX_PEDANTIC=1${b:+ under /bin/bash} leaves snap letting a command through" hook snap "$(payload true)" POSIX_PEDANTIC=1 PATH="$b$PATH"
  for e in SHELLOPTS=noexec BASHOPTS=failglob FUNCNEST=1 POSIXLY_CORRECT=1 POSIX_PEDANTIC=1 GREP_OPTIONS=-V TMOUT=0.000001 "BASH_ENV=$tmp/exit0" 'BASH_FUNC_jq%%=() { printf /tmp/elsewhere; }'; do
    w="$e${b:+ under /bin/bash}"
    t 2 "hooks: $w leaves guard on" hook guard "{\"session_id\":\"sess-a\",\"tool_input\":{\"file_path\":\"$repo/README.md\"}}" "$e" PATH="$b$PATH"
    t 2 "hooks: $w leaves snap on" hook snap "$(payload 'git worktree add ../x')" "$e" PATH="$b$PATH"
    # trip exits 2 under an imported jq with -p or without: the snapshot id
    # it reads changes, so it reports the snapshot lost.
    case $e in BASH_FUNC_*) continue ;; esac
    wire snap w; echo x > stray.txt; t 2 "hooks: $w leaves trip on" hook trip '{"tool_use_id":"w"}' "$e" PATH="$b$PATH"; rm stray.txt
  done
done
# The launcher (scripts/hook.sh) runs no bash, git, sed or jq a command in
# the project could plant first on PATH: behind a relative entry, an empty
# one (the hook's working directory, here the root) or an absolute one in the
# project, by its spelling or a link on the way (nl, a link in the project to
# a directory outside it, and via, one outside through nl), nor, for a
# session opened in a subdirectory, one in the root it resolves to. Each
# planted one leaves a mark, and none may.
cp .git/info/exclude "$tmp/exclude"; printf '/nm/\n/nl\n/bash\n/git\n/sed\n/jq\n/.gitconfig\n' >> .git/info/exclude
mkdir nm sub; for x in bash git sed jq; do printf '#!/bin/sh\necho %s >> "%s/planted"\nexit 0\n' "$x" "$tmp" > "nm/$x"; chmod +x "nm/$x"; cp "nm/$x" "$x"; done
mkdir "$tmp/lo"; cp nm/* "$tmp/lo/"; ln -s "$tmp/lo" nl; ln -s "$repo/nl" "$tmp/via"
agent="{\"session_id\":\"sess-a\",\"tool_input\":{\"file_path\":\"$repo/.claude/x\"}}" main="{\"session_id\":\"sess-a\",\"tool_input\":{\"file_path\":\"$repo/README.md\"}}"
# from <dir> <command...>: the command, run from that directory
from() { (cd "$1" && "${@:2}"); }
# past <what> <dir> <NAME=value...>: every hook, run from dir, lets through and
# refuses as it would with nothing planted, and runs nothing planted
past() {
  local w=$1 d=$2; shift 2; rm -f "$tmp/planted"
  t 0 "launcher: guard lets the agent dir through past $w" from "$d" hook guard "$agent" "$@"
  t 2 "launcher: guard blocks the main checkout past $w" from "$d" hook guard "$main" "$@"
  t 0 "launcher: snap lets a command through past $w" from "$d" hook snap "$(payload true "$repo/$d")" "$@"
  echo x > stray.txt; t 2 "launcher: trip still trips on a stray file past $w" from "$d" hook trip '{"tool_use_id":"sh"}' "$@"; rm stray.txt
  t 0 "launcher: link past $w" from "$d" hook link '' "$@"
  t 1 "launcher: and none of them ran a planted one past $w" test -e "$tmp/planted"
}
# An entry whose physical spelling holds a colon would split into a relative one (nm).
mkdir "$tmp/c:nm"; ln -s "$tmp/c:nm" "$tmp/cl"
for b in "" "$tmp/sysbash:"; do
  past "an entry spelled physically with a colon${b:+, under /bin/bash}" . "PATH=$tmp/cl:$b$PATH"
  past "a relative entry${b:+, under /bin/bash}" . "PATH=nm:$b$PATH"
  past "an empty entry${b:+, under /bin/bash}" . "PATH=:$b$PATH"
  past "an entry in the project${b:+, under /bin/bash}" . "PATH=$repo/nm:$b$PATH"
  past "an entry in the root, from a subdirectory${b:+, under /bin/bash}" sub "CLAUDE_PROJECT_DIR=$repo/sub" "PATH=$repo/nm:$b$PATH"
  past "an entry in the project that is a link out of it${b:+, under /bin/bash}" . "PATH=$repo/nl:$b$PATH"
  past "an entry outside through a link in the project${b:+, under /bin/bash}" . "PATH=$tmp/via:$b$PATH"
  past "an entry outside through a link in the root, from a subdirectory${b:+, under /bin/bash}" sub "CLAUDE_PROJECT_DIR=$repo/sub" "PATH=$tmp/via:$b$PATH"
done
# A .git in that subdirectory that git walks past (a HEAD that reads as
# neither a ref nor an object id), or a link, which root resolution refuses,
# stops the launcher no lower than the root's checkout; and a project
# outside git that a /.worktrees/ path names is the root's too.
mkdir -p sub/.git/objects sub/.git/refs; echo junk > sub/.git/HEAD
for b in "" "$tmp/sysbash:"; do
  past "an entry in the root, from a subdirectory whose .git is no repository${b:+, under /bin/bash}" sub "CLAUDE_PROJECT_DIR=$repo/sub" "PATH=$repo/nm:$b$PATH"
done
rm -r sub/.git; ln -s "$repo/.git" sub/.git; rm -f "$tmp/planted"
t 2 "launcher: snap refuses from a subdirectory whose .git is a link" from sub hook snap "$(payload true "$repo/sub")" "CLAUDE_PROJECT_DIR=$repo/sub" "PATH=$repo/nm:$PATH"
t 1 "launcher: and ran nothing planted past it" test -e "$tmp/planted"
rm sub/.git; mkdir -p "$tmp/jo/.worktrees/x"; cp -R nm "$tmp/jo/nm"; echo 'tracker: github' > "$tmp/jo/.coddy.yml"
from "$tmp/jo/.worktrees/x" hook guard "$agent" "CLAUDE_PROJECT_DIR=$tmp/jo/.worktrees/x" "PATH=$tmp/jo/nm:$PATH" >/dev/null 2>&1
t 1 "launcher: from a worktree of a project outside git, ran nothing planted in the project" test -e "$tmp/planted"
rm -r "$tmp/jo"
# It is POSIX sh, and runs under macOS's /bin/sh and under dash.
for sh in /bin/sh /bin/dash; do
  [ -x "$sh" ] || continue
  rm -f "$tmp/planted"
  t 0 "launcher: under $sh, guard lets the agent dir through" sh -c 'printf %s "$1" | CLAUDE_PROJECT_DIR="$2" PATH="nm:$PATH" "$3" "$4" guard' - "$agent" "$repo" "$sh" "$here/scripts/hook.sh"
  t 2 "launcher: under $sh, guard blocks the main checkout" sh -c 'printf %s "$1" | CLAUDE_PROJECT_DIR="$2" PATH="nm:$PATH" "$3" "$4" guard' - "$main" "$repo" "$sh" "$here/scripts/hook.sh"
  t 1 "launcher: under $sh, and ran nothing planted" test -e "$tmp/planted"
done
# A HEAD padded with 32 MB of spaces and no newline, which git still takes
# (it reads 255 bytes to take the repository and trims the rest), stalls no
# hook: the launcher reads 255 bytes of it, under either sh, and unpath 1024
# characters, under either bash.
hr=$(git symbolic-ref HEAD); cp .git/HEAD "$tmp/HEAD"; { printf 'ref: %s' "$hr"; head -c 32000000 /dev/zero | tr '\0' ' '; } > .git/HEAD
for sh in /bin/sh /bin/dash; do
  [ -x "$sh" ] || continue
  for b in "" "$tmp/sysbash:"; do
    for v in guard snap trip; do
      p=$agent; [ "$v" = guard ] || p=$(payload true)
      SECONDS=0; printf %s "$p" | CLAUDE_PROJECT_DIR="$repo" PATH="$b$PATH" "$sh" "$here/scripts/hook.sh" "$v" >/dev/null 2>&1; got=$?
      t 0 "launcher: under $sh${b:+ and /bin/bash}, $v reads a HEAD padded past 32 MB within seconds" test "$got:$((SECONDS <= 4))" = 0:1
    done
  done
done
cp "$tmp/HEAD" .git/HEAD
# With no bash left it refuses, in plain text.
mkdir "$tmp/nobash"
for p in "none:$tmp/nobash" "one in the project alone:$repo/nm" "a relative one alone:nm:$tmp/nobash"; do
  t 2 "launcher: refuses with no bash on PATH outside the project, ${p%%:*}" hook guard "$agent" PATH="${p#*:}"
  t 0 "launcher: and says so, ${p%%:*}" says 'no bash on PATH outside the project at' hook guard "$agent" PATH="${p#*:}"
done
# A bash it picks that cannot run (an interpreter that is gone, a file that is
# no program) is refused the same way, exit 2, never /bin/sh's own 1, 126 or 127.
mkdir "$tmp/badint" "$tmp/badbin"; printf '#!/nonexistent/sh\n' > "$tmp/badint/bash"; printf '\177ELF\001\001\001\000\000\000' > "$tmp/badbin/bash"; chmod +x "$tmp/badint/bash" "$tmp/badbin/bash"
for d in badint badbin; do
  t 2 "launcher: guard refuses when the bash it picks cannot run ($d)" hook guard "$agent" PATH="$tmp/$d:$PATH"
  t 2 "launcher: snap refuses when the bash it picks cannot run ($d)" hook snap "$(payload true)" PATH="$tmp/$d:$PATH"
  t 0 "launcher: and says so ($d)" says 'cannot run, so the coddy guard hook' hook guard "$agent" PATH="$tmp/$d:$PATH"
done
rm -r nm nl sub bash git sed jq "$tmp/lo" "$tmp/via" "$tmp/nobash" "$tmp/badint" "$tmp/badbin"
# git and jj read the user's config from HOME and XDG_CONFIG_HOME: one in the
# project, whose core.fsmonitor would leave a mark, makes snap refuse before
# its first git call, in either guard mode, naming the variable, and trip
# after putting the config back; guard is as it was, and a HOME outside
# changes nothing.
printf '#!/bin/sh\necho fsmonitor >> "%s/planted"\nexit 1\n' "$tmp" > "$tmp/fsm"; chmod +x "$tmp/fsm"
mkdir -p .claude/xdg/git "$tmp/away"; printf '[core]\n\tfsmonitor = %s\n' "$tmp/fsm" > .gitconfig; cp .gitconfig .claude/xdg/git/config; rm -f "$tmp/planted"
for v in block warn; do
  printf 'tracker: github\ndefault_branch: main\nguard: %s\n' "$v" > .claude/coddy.yml
  for h in "HOME=$repo" "XDG_CONFIG_HOME=$repo/.claude/xdg" "HOME=$repo/.claude/none"; do
    w="${h%%=*}=${h#*="$repo"}"; w=${w/=/=<root>}
    t 2 "home: $v, snap refuses $w" hook snap "$(payload true)" "$h"
    t 0 "home: $v, and names ${h%%=*}: $w" says "^coddy: ${h%%=*} ('$repo" hook snap "$(payload true)" "$h"
    t 0 "home: $v, guard lets the agent dir through under $w" hook guard "$agent" "$h"
  done
  w=2; [ "$v" = block ] || w=0
  t "$w" "home: $v, guard is as it was on the main checkout under HOME=<root>" hook guard "$main" HOME="$repo"
  t 0 "home: $v, a HOME outside the project changes nothing" hook snap "$(payload true)" HOME="$tmp/away"
done
# A .. after a link goes where git's open goes, not where the name says.
ln -s "$repo/.claude" "$tmp/hl"
t 2 "home: snap refuses a HOME that reaches the root through a link and .." hook snap "$(payload true)" HOME="$tmp/hl/.."
# git reads HOME=- as a directory named - where it runs, the root; cd as the last one.
mkdir ./-; cp .gitconfig ./-/
t 2 "home: snap refuses HOME=-, a directory in the root to git" hook snap "$(payload true)" HOME=-
t 2 "home: snap refuses XDG_CONFIG_HOME=- the same way" hook snap "$(payload true)" XDG_CONFIG_HOME=-
rm -r ./-
t 1 "home: and no fsmonitor ran" test -e "$tmp/planted"
printf 'tracker: github\ndefault_branch: main\n' > .claude/coddy.yml; cp .claude/coddy.yml "$tmp/conf.home"
hook snap "$(payload true)" >/dev/null; rm .claude/coddy.yml
t 2 "home: trip refuses HOME=<root>" hook trip '{"tool_use_id":"sh"}' HOME="$repo"
t 0 "home: after putting the config back" cmp -s .claude/coddy.yml "$tmp/conf.home"
t 1 "home: and no fsmonitor ran there either" test -e "$tmp/planted"
# Root resolution's git runs before that check, and git takes trace2.* (a
# file it appends to) from the user's config alone: none of the three hooks
# reads it from there.
printf '[trace2]\n\tnormalTarget = %s\n' "$tmp/t2" >> .gitconfig; cp .gitconfig .claude/xdg/git/config
for h in "HOME=$repo" "XDG_CONFIG_HOME=$repo/.claude/xdg"; do
  w="${h%%=*}=${h#*="$repo"}"; w=${w/=/=<root>}
  for v in guard snap trip; do
    case "$v" in guard) p=$agent ;; snap) p=$(payload true) ;; *) p='{"tool_use_id":"sh"}' ;; esac
    rm -f "$tmp/t2"; hook "$v" "$p" "$h" >/dev/null 2>&1
    t 1 "home: $v under $w writes no trace2 target that config names" test -e "$tmp/t2"
  done
done
rm -r .gitconfig .claude/xdg "$tmp/away" "$tmp/hl"; cp "$tmp/exclude" .git/info/exclude
# The fingerprint's git, and jj where the root holds a .jj, installed in the
# project alone (a .venv, devbox or nix-shell toolchain) is dropped from the
# hooks' PATH: snap refuses, in either guard mode, naming the tool, and trip
# the command that ran, after putting the config back, rather than compare
# two empty fingerprints.
mkdir "$tmp/nogit" "$tmp/gitonly" nm; ln -s "$(command -v git)" "$tmp/gitonly/git"; ln -s "$(command -v git)" nm/git
for x in bash sed awk cat grep cmp sort comm tr cut cksum mkdir cp rm head sleep stat xargs wc jq find readlink mktemp; do p=$(command -v "$x") && ln -s "$p" "$tmp/nogit/$x"; done
p=$(command -v jj) && ln -s "$p" nm/jj; printf '/nm/\n' >> .git/info/exclude
for v in block warn; do
  printf 'tracker: github\ndefault_branch: main\nguard: %s\n' "$v" > .claude/coddy.yml
  t 2 "tools: $v, snap refuses with git in the project alone" hook snap "$(payload true)" PATH="$repo/nm:$tmp/nogit"
  t 0 "tools: $v, and names it" says '^coddy: no git is on PATH outside the project' hook snap "$(payload true)" PATH="$repo/nm:$tmp/nogit"
  t 0 "tools: $v, snap needs no jj where the root holds no .jj" hook snap "$(payload true)" PATH="$repo/nm:$tmp/gitonly:$tmp/nogit"
  mkdir .jj
  t 2 "tools: $v, snap refuses with jj in the project alone where the root holds a .jj" hook snap "$(payload true)" PATH="$repo/nm:$tmp/gitonly:$tmp/nogit"
  t 0 "tools: $v, and names it" says '^coddy: no jj is on PATH outside the project' hook snap "$(payload true)" PATH="$repo/nm:$tmp/gitonly:$tmp/nogit"
  rmdir .jj
done
printf 'tracker: github\ndefault_branch: main\n' > .claude/coddy.yml; cp .claude/coddy.yml "$tmp/conf.tools"
hook snap "$(payload true)" >/dev/null; echo x > stray.txt
t 2 "tools: trip refuses a stray file with git in the project alone" hook trip '{"tool_use_id":"sh"}' PATH="$repo/nm:$tmp/nogit"
hook snap "$(payload true)" >/dev/null; rm .claude/coddy.yml
hook trip '{"tool_use_id":"sh"}' PATH="$repo/nm:$tmp/nogit" 2>"$tmp/tools.err"
t 0 "tools: trip puts the config back first" cmp -s .claude/coddy.yml "$tmp/conf.tools"
t 0 "tools: and names git" grep -q 'no git is on PATH outside the project' "$tmp/tools.err"
hook snap "$(payload true)" >/dev/null; mkdir .jj
hook trip '{"tool_use_id":"sh"}' PATH="$repo/nm:$tmp/gitonly:$tmp/nogit" 2>"$tmp/tools.err"; got=$?
t 0 "tools: trip refuses a command that left a .jj at the root with jj in the project alone" test "$got" = 2
t 0 "tools: and names jj" grep -q 'no jj is on PATH outside the project' "$tmp/tools.err"
rm -r .jj nm stray.txt "$tmp/nogit" "$tmp/gitonly"; cp "$tmp/exclude" .git/info/exclude
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
t 0 "warn: a push to the default branch is let through with the message" noted 'the default branch' 'git push origin main'
t 0 "warn: a force push is let through with the message" noted 'force-push' 'git push -f origin feat'
t 0 "warn: a branch delete is let through with the message" noted 'delete a remote branch' 'git push origin :feat'
# A jq that fails, or a payload naming no path, leaves the path unread:
# blocked, in warn mode too. raw <payload>: the edit hook with it as it is;
# saying <text> <command...>: the command's exit when its output holds the
# text, else 1, so no other refusal passes for this one
raw() { printf %s "$1" | run guard; }
saying() { local out r; out=$("${@:2}" 2>&1); r=$?; case "$out" in *"$1"*) return "$r" ;; esac; return 1; }
# A cygpath that turns any path into one the guard allows: the Windows
# refusal below never asks it, so it holds where Git Bash ships one.
mkdir "$tmp/cyg"; printf '#!/bin/sh\necho "%s/.claude/n.md"\n' "$repo" > "$tmp/cyg/cygpath"; chmod +x "$tmp/cyg/cygpath"
# A find that fails whatever it is asked: on PATH first when a case asks.
mkdir "$tmp/badfind"; printf '#!/bin/sh\nexit 1\n' > "$tmp/badfind/find"; chmod +x "$tmp/badfind/find"
for v in block warn; do
  printf 'tracker: github\ndefault_branch: main\nguard: %s\n' "$v" > .claude/coddy.yml
  PATH="$tmp/badjq:$PATH" t 2 "guard: $v blocks the main checkout with a jq that fails" saying 'could not read the hook payload with jq' guard "$repo/README.md"
  for p in '{}' '' 'null' '[]' '{"tool_input":"x"}' '{bad' '{"tool_input":{"file_path":null}}' "{\"tool_input\":{\"path\":\"$repo/x\"}}"; do
    t 2 "guard: $v blocks a payload naming no path: ${p:-empty}" saying 'the edit guard could not read' raw "$p"
  done
  # A path still read where the payload names one: a NotebookEdit's, and a
  # relative one against the payload's cwd. Allowed and silent, or refused.
  t 0 "guard: $v reads a NotebookEdit's notebook_path" test -z "$(raw "{\"tool_input\":{\"notebook_path\":\"$repo/.claude/n.ipynb\"}}" 2>&1 || echo refused)"
  # built outside the $( ), where bash 3.2 brace-expands {a,b} once its \" are read as quotes
  pl="{\"cwd\":\"$repo/.claude\",\"tool_input\":{\"file_path\":\"n.md\"}}"
  t 0 "guard: $v reads a relative path against the payload's cwd" test -z "$(raw "$pl" 2>&1 || echo refused)"
  # Native Windows paths, which nothing reads as Windows does (a drive
  # letter, a drive-relative C:x, a backslash, a UNC or device path written
  # with forward slashes), and a cwd that is not absolute, a non-string one
  # included: refused, in warn mode too.
  for p in '{"tool_input":{"file_path":"D:\\proj\\README.md"},"cwd":"D:\\proj"}' '{"tool_input":{"file_path":"README.md"},"cwd":"D:\\proj"}' '{"tool_input":{"file_path":"D:/proj/README.md"}}' '{"tool_input":{"file_path":"README.md"},"cwd":"D:/proj"}' '{"tool_input":{"file_path":"\\\\server\\share\\README.md"}}' "{\"tool_input\":{\"file_path\":\".claude\\\\n.md\"},\"cwd\":\"$repo\"}" \
    '{"tool_input":{"file_path":"//localhost/C$/proj/README.md"}}' '{"tool_input":{"file_path":"//./C:/proj/README.md"}}' '{"tool_input":{"file_path":"//?/C:/proj/README.md"}}' '{"tool_input":{"file_path":"README.md"},"cwd":"//./C:/proj"}' '{"tool_input":{"file_path":"C:README.md"}}'; do
    PATH="$tmp/cyg:$PATH" t 2 "guard: $v blocks a Windows path: $p" saying 'refuses a Windows path' raw "$p"
  done
  # Where bash itself runs on native Windows ($OSTYPE msys or cygwin), every
  # edit is refused, in warn mode too: a claimed worktree's own, which the
  # guard allows elsewhere, included.
  mkdir -p .git/coddy/88 && echo "sess-a $$" > .git/coddy/88/owner
  t 0 "guard: $v allows a claimed worktree outside native Windows" test -z "$(guard "$repo/.worktrees/88/a.txt" 2>&1 || echo refused)"
  for o in msys cygwin; do
    OSTYPE=$o t 2 "guard: $v blocks every edit under OSTYPE=$o" saying 'refuses every edit on native Windows' guard "$repo/.worktrees/88/a.txt"
  done
  # A repository's own files, a .git or .jj below the root in any case, as
  # given or reached through a link, and a hard link, whose write changes
  # every other name of the file: refused, in warn mode too, a claimed
  # worktree's and the agent dir's included. Beside each, paths that pass.
  mkdir -p .worktrees/88; echo x > .worktrees/88/one; ln -s one .worktrees/88/sl; ln README.md .worktrees/88/hl
  ln -s .. .claude/up; ln -s ../.git .claude/g
  for p in .claude/up/.git/config .claude/g/config .git/config .GIT/config .worktrees/88/.git .worktrees/88/.Git .jj/repo .worktrees/88/.jj/repo .worktrees/88/.JJ/repo; do
    t 2 "guard: $v blocks a repository's own file: $p" saying 'a .git or .jj below the project root' guard "$repo/$p"
  done
  t 2 "guard: $v blocks a hard link in a claimed worktree to a main-checkout file" saying 'is a hard link' guard "$repo/.worktrees/88/hl"
  PATH="$tmp/badfind:$PATH" t 2 "guard: $v blocks an existing file whose links a find that fails cannot count" saying 'could not count the links' guard "$repo/.worktrees/88/one"
  for p in .claude/settings.json .worktrees/88/one .worktrees/88/sl .worktrees/88/.gitignore .worktrees/88/.github/x .worktrees/88/.jjconfig.toml; do
    t 0 "guard: $v allows $p" test -z "$(guard "$repo/$p" 2>&1 || echo refused)"
  done
  # A .. after a missing directory, which the walk of the path as given
  # cannot follow while its collapsed spelling lands on an allowed file:
  # refused before the mode is read, in warn mode too.
  t 2 "guard: $v blocks a .. after a missing directory" saying 'could not follow' guard "$repo/.worktrees/88/newdir/../one"
  # Paths the kernel resolves and a walk a component at a time cannot:
  # macOS's /.vol/<dev>/<inode> (a directory's, held by where the edit
  # lands, or a file's, with no name to check) and Linux's /proc/self/root.
  # Refused, in warn mode too.
  # BSD stat by its path: a GNU stat first on PATH reads -f otherwise.
  mkdir -p src .worktrees/77; d=$(/usr/bin/stat -f %d src 2>/dev/null)
  if [ -d /.vol ] && [ "/.vol/$d/$(/usr/bin/stat -f %i src)" -ef src ]; then
    t 2 "guard: $v blocks a main-checkout file through /.vol" saying 'through /.vol' guard "/.vol/$d/$(/usr/bin/stat -f %i src)/m.c"
    t 2 "guard: $v blocks an unclaimed worktree's file through /.vol" saying 'through /.vol' guard "/.vol/$d/$(/usr/bin/stat -f %i .worktrees/77)/a.txt"
    for p in README.md .git/config; do t 2 "guard: $v blocks $p by its inode in /.vol" saying 'through /.vol' guard "/.vol/$d/$(/usr/bin/stat -f %i $p)"; done
  else echo "skip guard through /.vol: no /.vol here (macOS only)"; fi
  # macOS strips a leading /.nofollow/ or /.resolve/<flags>/ before it
  # resolves the rest, while the walk keeps it: refused like /.vol itself.
  for x in /.nofollow /.resolve/1; do
    if [ "$x/.vol/$d/$(/usr/bin/stat -f %i README.md 2>/dev/null)" -ef README.md ]; then
      for p in README.md .git/config; do t 2 "guard: $v blocks $p by its inode in $x/.vol" saying 'through /.vol' guard "$x/.vol/$d/$(/usr/bin/stat -f %i $p)"; done
    else echo "skip guard through $x/.vol: no $x here (macOS only)"; fi
  done
  # The walk never steps onto /dev/fd, compared by identity: a case-folding
  # disk reaches it as /DEV/fd too.
  if [ /DEV/fd -ef /dev/fd ]; then t 2 "guard: $v blocks /DEV/fd/1, /dev/fd spelled in another case" saying 'could not follow' guard /DEV/fd/1
  else echo "skip guard through /DEV/fd: /dev is not reached in another case here"; fi
  if [ "/proc/self/root$repo" -ef "$repo" ]; then
    t 2 "guard: $v blocks a main-checkout file through /proc/self/root" saying 'could not follow' guard "/proc/self/root$repo/README.md"
    # Magic links, whose text names another file than the kernel reaches: a
    # link to /proc/<pid>/fd/<n> holding a main-checkout file open under a
    # name since removed, and to /proc/<pid>/cwd in another mount namespace,
    # where the main checkout is bound at a path empty here. Refused, in
    # warn mode too: the walk never steps onto /proc.
    ln README.md .worktrees/88/dl; exec 7<.worktrees/88/dl; rm .worktrees/88/dl; ln -s "/proc/$$/fd/7" .worktrees/88/fd
    t 2 "guard: $v blocks a link to a main-checkout file held open in /proc/<pid>/fd under a removed name" saying 'could not follow' guard "$repo/.worktrees/88/fd"
    exec 7<&-
    if unshare -Urm true 2>/dev/null; then
      mkdir "$tmp/m"; unshare -Urm sh -c 'mount --bind "$1" "$2" && cd "$2" && exec sleep 60' sh "$repo" "$tmp/m" & k=$!
      for i in 1 2 3 4 5 6 7 8 9 10; do [ "$(readlink "/proc/$k/cwd")" != "$tmp/m" ] || break; sleep 0.2; done
      ln -s "/proc/$k/cwd" .worktrees/88/cw; ln -s "/proc/$k/cwd/.git" .worktrees/88/gg
      for p in cw/README.md cw/new.c gg/config; do t 2 "guard: $v blocks .worktrees/88/$p through /proc/<pid>/cwd in another mount namespace" saying 'could not follow' guard "$repo/.worktrees/88/$p"; done
      kill "$k"; wait "$k" 2>/dev/null; rmdir "$tmp/m"
      # And where the link's text names the same directory here, with mounts
      # below it in the other namespace alone: README.md and .git/config
      # bound over files, the main checkout over a directory, and README.md
      # over a file in the owner's own worktree, the second process's cwd.
      # Reached through the magic link, a relative chain to it, a dangling
      # link below the directory mount, and a .. the Write tool collapses
      # by name.
      mkdir -p "$tmp/n/d" "$tmp/y/z" .worktrees/88/sub; echo decoy > "$tmp/n/f"; echo decoy > "$tmp/n/c"; echo decoy > .worktrees/88/sub/x.c
      unshare -Urm sh -c 'mount --bind "$1/README.md" "$2/f" && mount --bind "$1/.git/config" "$2/c" && mount --bind "$1" "$2/d" && cd "$2" && exec sleep 60' sh "$repo" "$tmp/n" & k=$!
      unshare -Urm sh -c 'mount --bind "$1/README.md" "$2/sub/x.c" && cd "$2" && exec sleep 60' sh "$repo" "$repo/.worktrees/88" & w=$!
      for i in 1 2 3 4 5 6 7 8 9 10; do [ "$(readlink "/proc/$k/cwd")" != "$tmp/n" ] || [ "$(readlink "/proc/$w/cwd")" != "$repo/.worktrees/88" ] || break; sleep 0.2; done
      up=$(cd .worktrees/88 && pwd -P | sed 's#[^/][^/]*#..#g; s#^/##')
      ln -s "/proc/$k/cwd" .worktrees/88/cn; ln -s "/proc/$k/root" .worktrees/88/rt; ln -s "$up/proc/$k/cwd" .worktrees/88/rel
      ln -s "/proc/$k/cwd/d/new.c" .worktrees/88/dg; ln -s "/proc/$w/cwd" .worktrees/88/cs; ln -s "$tmp/y/z" .worktrees/88/x
      for p in cn/f cn/c "rt$tmp/n/f" rel/f dg cs/sub/x.c x/../cn/f; do t 2 "guard: $v blocks .worktrees/88/$p through /proc/<pid> into mounts in another namespace below a directory the same here" saying 'could not follow' guard "$repo/.worktrees/88/$p"; done
      kill "$k" "$w"; wait "$k" "$w" 2>/dev/null; rm -r "$tmp/n" "$tmp/y"
    else echo "skip guard through /proc/<pid>/cwd in another mount namespace: unshare -Urm is not allowed here"; fi
  else echo "skip guard through /proc/self/root: no /proc here (Linux only)"; fi
  rm -r .git/coddy/88 .worktrees .claude/up .claude/g src
  for p in '{"cwd":{"a":1},"tool_input":{"file_path":"x"}}' '{"cwd":["/x"],"tool_input":{"file_path":"x"}}' '{"cwd":"proj","tool_input":{"file_path":"x"}}'; do
    t 2 "guard: $v blocks a cwd that is not absolute: $p" saying 'refuses a cwd that is not an absolute path' raw "$p"
  done
done
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
git worktree remove --force .worktrees/44; git branch -qD feat/44-thing; rm -f .git/coddy/44.branch
# Claude Code keeps an install at <P>/plugins/cache/<marketplace>/<plugin>/<version>
# and its data at <P>/plugins/data/<plugin>-<marketplace>: link points the
# launcher there at the install's bin/coddy, given that dir alone, and create
# has the git hooks run it, whatever CODDY_EXEC the shell holds.
fake="$tmp/plugins/cache/mkt/coddy/9.9.9" data="$tmp/plugins/data/coddy-mkt"
mkdir -p "$fake/bin" "$fake/scripts" "$data" "$tmp/plugins/data/other"; cp "$here/bin/coddy" "$fake/bin/"; cp "$here/scripts/issue.sh" "$fake/scripts/"
frun() { CLAUDE_PROJECT_DIR="$repo" bash "$fake/scripts/issue.sh" "$@"; }
t 0 "link: from an install in no cache layout, nothing and exit 0" quiet run link "$data"
t 0 "link: and no launcher" test -z "$(ls -A "$data")"
t 0 "link: given another dir, nothing and exit 0" quiet frun link "$tmp/plugins/data/other"
t 0 "link: and no launcher there" test -z "$(ls -A "$tmp/plugins/data/other")"
t 0 "link: given its own data dir, nothing and exit 0" quiet frun link "$data"
t 0 "link: and the launcher points at the install's bin/coddy" test "$(readlink "$data/coddy")" = "$(cd "$fake/bin" && pwd -P)/coddy"
CODDY_EXEC=/elsewhere/coddy frun create 46 feat/46-thing >/dev/null 2>&1
t 0 "create: from that install, the hooks run the launcher, an inherited CODDY_EXEC ignored" grep -qxF "c='$(cd "$data" && pwd -P)/coddy'" .git/hooks/coddy/pre-commit
CODDY_EXEC="$data/coddy" run create 46 feat/46-thing >/dev/null 2>&1
t 0 "create: from an install in no cache layout, its own path, an inherited CODDY_EXEC ignored" grep -qxF "c='$here/bin/coddy'" .git/hooks/coddy/pre-commit
git worktree remove --force .worktrees/46; git branch -qD feat/46-thing; rm -f .git/coddy/46.branch; cp "$tmp/conf.yml" .claude/coddy.yml
if command -v jj >/dev/null; then
  printf 'tracker: github\nworktree: jj\ndefault_branch: main\n' > .claude/coddy.yml
  t 1 "jj: create refuses a repo that is not jj-backed" run create 41 feat/41-thing
  jj git init --colocate >/dev/null 2>&1; echo '.jj/' >> .git/info/exclude
  leg jj 42
  # A session's sandbox writes its own directory, which may be a jj workspace
  # outside the checkout: create refuses a coddy installed there.
  jj workspace add --name jw "$tmp/jw" >/dev/null 2>&1; mkdir "$tmp/jw/plug"; cp -R "$here/bin" "$here/scripts" "$tmp/jw/plug/"
  t 0 "jj: create refuses a coddy in a jj workspace outside the checkout" says 'is inside the project at .*, a worktree of it or where this start began' env CLAUDE_PROJECT_DIR="$repo" bash "$tmp/jw/plug/scripts/issue.sh" create 42 feat/42-thing
  jj workspace forget jw >/dev/null 2>&1; rm -rf "$tmp/jw"
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
printf '#!/bin/sh\ncase " $* " in *" hash-object "*) echo x >> "%s" ;; esac\nexec "%s" "$@"\n' "$tmp/hashes" "$real" > "$tmp/gitshim/git"; chmod +x "$tmp/gitshim/git"
for i in $(seq 1000); do echo "$i" > "many/$i.txt"; done
: > "$tmp/hashes"; PATH="$tmp/gitshim:$PATH" wire snap many
t 0 "tripwire: 1000 dirty files are hashed by one hash-object" test "$(wc -l < "$tmp/hashes" | tr -d ' ')" = 1
t 0 "tripwire: and each is in the snapshot" test "$(grep -c '^many/.* [0-9a-f]\{40\}$' "${TMPDIR:-/tmp}"/coddy-snap-*-many)" = 1000
wire trip many 2>/dev/null; rm -r many
# A dirty file over 1 MiB is not read: its line holds its size, ctime and
# inode, so a sparse 14 GiB one costs what a small one does, and one
# rewritten in place to the same size still trips.
dd if=/dev/null of=huge.bin bs=1048576 seek=14336 count=0 2>/dev/null
SECONDS=0; wire snap big
t 0 "tripwire: a sparse 14 GiB untracked file is fingerprinted within seconds" test "$SECONDS" -le 5
t 0 "tripwire: as its size, ctime and inode, unread" grep -q '^huge\.bin big:15032385536:[0-9.]*:[0-9]*$' "${TMPDIR:-/tmp}"/coddy-snap-*-big
SECONDS=0; wire trip big; got=$?
t 0 "tripwire: and trip, quiet while it stands, within seconds too" test "$got:$((SECONDS <= 5))" = 0:1
rm huge.bin; dd if=/dev/zero of=two.bin bs=1048576 count=2 2>/dev/null
tripped 0 "tripwire: quiet for a 2 MiB file left alone" 'true'
wire snap w; printf x | dd of=two.bin bs=1 seek=4096 conv=notrunc 2>/dev/null
wire trip w 2>"$tmp/trip.err"; got=$?
t 0 "tripwire: a 2 MiB file rewritten in place to the same size trips" test "$got" = 2
t 0 "tripwire: and the report names its path alone" grep -q 'main checkout: two\.bin\.' "$tmp/trip.err"
rm two.bin
# Exactly 1 MiB is hashed; a byte more is not read.
head -c 1048576 /dev/zero > mib.bin; head -c 1048577 /dev/zero > mib1.bin; wire snap big
t 0 "tripwire: a file of exactly 1 MiB is hashed" grep -q '^mib\.bin [0-9a-f]\{40\}$' "${TMPDIR:-/tmp}"/coddy-snap-*-big
t 0 "tripwire: one a byte over is not read" grep -q '^mib1\.bin big:1048577:' "${TMPDIR:-/tmp}"/coddy-snap-*-big
wire trip big 2>/dev/null; rm mib.bin mib1.bin
# A file named %Fc in the root, which GNU's stat reads after its -f as a
# path, does not pass it off as BSD's, which would read every big file.
head -c 1048577 /dev/zero > mib1.bin; : > %Fc; wire snap big
t 0 "tripwire: a file named %Fc in the root leaves a big file unread" grep -q '^mib1\.bin big:1048577:' "${TMPDIR:-/tmp}"/coddy-snap-*-big
wire trip big 2>/dev/null; rm mib1.bin %Fc
# Past 32 MiB hashed in all a file up to 1 MiB is recorded as a big one, so
# 8000 sparse 1 MiB untracked files cost what their paths do, not 8 GiB
# read, and one recorded so, rewritten in place to the same size, still trips.
mkdir sp; seq -f 'sp/f%04g' 0 7999 | xargs perl -e 'for (@ARGV) { open my $f, ">", $_ or die; truncate $f, 1048576 or die }'
wire snap big
t 1 "tripwire: 8000 sparse 1 MiB untracked files are fingerprinted within the budget" grep -qx unchecked "${TMPDIR:-/tmp}"/coddy-snap-*-big
got=$(grep -c '^sp/f[0-9]* [0-9a-f]\{40\}$' "${TMPDIR:-/tmp}"/coddy-snap-*-big)
t 0 "tripwire: no more than 32 MiB of them hashed" test "$got" -ge 1 -a "$got" -le 32
t 0 "tripwire: the rest by size, ctime and inode" grep -q '^sp/f7999 big:1048576:' "${TMPDIR:-/tmp}"/coddy-snap-*-big
wire trip big 2>/dev/null
wire snap w; printf x | dd of=sp/f7999 bs=1 seek=4096 conv=notrunc 2>/dev/null
wire trip w 2>"$tmp/trip.err"; got=$?
t 0 "tripwire: one of those rewritten in place to the same size trips" test "$got" = 2
t 0 "tripwire: and the report names its path alone" grep -q 'main checkout: sp/f7999\.' "$tmp/trip.err"
rm -r sp
# The fingerprint's budget is the core's alone: a CODDY_BUDGET a settings env
# hands the hook is dropped, so 0 runs no command unchecked.
CODDY_BUDGET=0 wire snap w >/dev/null
t 1 "tripwire: an inherited CODDY_BUDGET is ignored" grep -qx unchecked "${TMPDIR:-/tmp}/coddy-snap-$(printf %s "$repo" | cksum | cut -d' ' -f1)-w"
wire trip w 2>/dev/null
# A path holding a newline is left out of the stat, where its second line
# would read as another path's stat line and hide that path's change.
echo a > other.txt; echo b > "$(printf 'z\n9999999 1 1:other.txt')"
tripped 2 "tripwire: a newline in a path forges no other path's line" 'echo c > other.txt'
rm other.txt z?9999999*
# hash-object stops at the first path it cannot hash: one unreadable, one
# starting with a quote, which it reads as quoted, and one ending in a CR,
# which it strips, go by their stat instead, and so does each from the
# first it still fails on, so none hides a later file's change.
for e in a0 '"x' "$(printf 'a\r')"; do
  echo a > "$e"; echo b > z.txt; [ "$e" != a0 ] || chmod 000 a0
  wire snap w; echo c > z.txt; wire trip w 2>"$tmp/trip.err"; got=$?
  t 0 "tripwire: a change after an unhashable path trips: ${#e} bytes" test "$got" = 2
  t 0 "tripwire: and the report names the later file: ${#e} bytes" grep -q 'main checkout: z\.txt\.' "$tmp/trip.err"
  rm -f "$e" z.txt
done
mkdir "$tmp/hof"; printf '#!/bin/sh\ncase " $* " in *" hash-object "*) chmod 000 a0 ;; esac\nexec "%s" "$@"\n' "$(command -v git)" > "$tmp/hof/git"; chmod +x "$tmp/hof/git"
echo a > a0; echo b > z.txt
PATH="$tmp/hof:$PATH" wire snap w; chmod 644 a0; echo c > z.txt; PATH="$tmp/hof:$PATH" wire trip w 2>"$tmp/trip.err"; got=$?
t 0 "tripwire: a change after a path hash-object fails on trips" test "$got" = 2
t 0 "tripwire: and the report names the later file" grep -q 'main checkout: .*z\.txt\.' "$tmp/trip.err"
rm -rf a0 z.txt "$tmp/hof"
# trip records each path as snap did, so staging a file or one going away
# moves no other between hashed and big: past the 32 MiB.
mkdir r1; seq -f 'r1/b%02g' 0 32 | xargs perl -e 'for (@ARGV) { open my $f, ">", $_ or die; truncate $f, 1048576 or die }'
tripped 0 "tripwire: staging one of 33 1 MiB files moves none of the others" 'git add r1/b32'
git rm -q --cached r1/b32; perl -e 'open my $f, ">", "r1/a.bin" or die; truncate $f, 1048576 or die'
tripped 0 "tripwire: nor does one of them going away" 'rm r1/a.bin'
wire snap w; printf x >> r1/b31; wire trip w 2>"$tmp/trip.err"; got=$?
t 0 "tripwire: a change to the last of them still trips" test "$got" = 2
t 0 "tripwire: and the report names it" grep -q 'main checkout: r1/b31\.' "$tmp/trip.err"
rm -r r1
# A stat that gives no line for a dirty file leaves it unchecked: snap says
# the command runs unchecked and trip reports it.
mkdir "$tmp/nostat"; printf '#!/bin/sh\nexit 1\n' > "$tmp/nostat/stat"; chmod +x "$tmp/nostat/stat"
echo a > z.txt; out=$(PATH="$tmp/nostat:$PATH" wire snap w)
t 0 "tripwire: with no working stat, snap says the command runs unchecked" jq -e '.hookSpecificOutput.additionalContext | contains("since stat gave no size")' <<<"$out"
echo b > z.txt; PATH="$tmp/nostat:$PATH" wire trip w 2>"$tmp/trip.err"; got=$?
t 0 "tripwire: and trip reports it" test "$got" = 2
t 0 "tripwire: saying so" grep -q 'ran unchecked: .*since stat gave no size' "$tmp/trip.err"
rm -r z.txt "$tmp/nostat"
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
# An unquoted $( or backtick command word may expand to nothing, which bash
# drops: the word after it is read as the command too.
for c in '$(true) git worktree add ../x' 'env $(true) git worktree add ../x' '$(cd /tmp) git worktree add ../x' '`true` $(true) git worktree add ../x'; do
  t 2 "refused after a command word that may expand to nothing: $c" shell "$c"
done
t 0 "after one, a command word it cannot read passes with a message" noted 'could not tell where' '$(true) $g worktree add ../x'
# So may the unquoted substitutions a command name starts with: the name is
# read past them, and one it cannot read after them passes with a message.
for c in '$(true)git worktree add ../x' '$(true)$(true)git worktree add ../x' '`true`git worktree add ../x' '$(true)env git worktree add ../x'; do
  t 2 "refused, a command name after substitutions it starts with: $c" shell "$c"
done
t 0 "after them, a name it cannot read passes with a message" noted 'could not tell where' '$(true)${g}git worktree add ../x'
# A cd past one, or past the substitutions a name starts with, may be an
# argument of the command they print: the directory is unknown after it.
for c in '`echo true` cd .worktrees/43; git worktree add ../x' '`echo :`cd .worktrees/43; git worktree add ../x'; do
  t 0 "after a cd past a substitution, passes with a message: $c" noted 'could not tell where' "$c"
done
# case is read as any other word, its ( and ) as anywhere else, so the
# worktree add in or after each is read.
for c in 'echo "$(( 1 && case + in ))"; git worktree add ../x; echo ""' '[[ x && case == in ]]; (cd .worktrees/43); git worktree add ../x' \
  'echo "$(case esac in (esac) git worktree add ../x;; esac)"'; do
  t 2 "refused, around a case: $c" shell "$c"
done
# A backtick substitution ends at the first backtick no backslash escapes,
# whatever quotes it crosses; one in single quotes is text.
for c in 'git worktree add ../x `true "`' "git worktree add ../x \`true '\`"; do t 2 "refused, before a backtick holding an odd quote: $c" shell "$c"; done
t 0 "a backtick in single quotes is text" shell "echo '\`git worktree add ../x\`'"
# A substitution still open at the end of the text is read with the words
# around it.
for c in 'git worktree add ../x $(true' 'git worktree add ../x "$(true' 'git worktree add ../x $(echo $(true'; do t 2 "refused, before a substitution left open: $c" shell "$c"; done
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
t 0 "a path that spans lines passes with a message, no line of it read as a push's" noted 'could not tell where' $'git worktree add ".worktrees/77/a\n:to /../../../x"'
# A command that ends in a two-character redirection is read and let through
# at once. prompt <command...>: it ends within five seconds; one that does
# not is killed, with every process it started.
prompt() { ( set -m; "$@" >/dev/null 2>&1 & p=$!; for _ in $(seq 50); do kill -0 "$p" 2>/dev/null || exit 0; sleep 0.1; done; kill -9 -- -"$p"; exit 1 ); }
for c in 'echo x >>' 'cat <<' 'ls 2>&' 'ls &>'; do t 0 "a command ending in its redirection is read promptly: $c" prompt shell "$c" "$repo/.worktrees/43"; done
# Reading time is linear in the text. timed <command...>: its own exit,
# when it ends within five seconds; 124 when it is killed.
timed() { ( set -m; "$@" >/dev/null 2>&1 & p=$!; for _ in $(seq 50); do kill -0 "$p" 2>/dev/null || { wait "$p"; exit; }; sleep 0.1; done; kill -9 -- -"$p"; exit 124 ); }
big=$(awk 'BEGIN { for (i = 0; i < 8000; i++) printf "$(a) "; printf "; git worktree add ../x" }')
t 2 "a 40 KB command of substitutions is read in time, the worktree add after it refused" timed shell "$big"
big=$(awk 'BEGIN { for (i = 0; i < 1600; i++) print "bash <<E" i; for (i = 1599; i >= 0; i--) print "E" i; printf "git worktree add ../x" }')
t 2 "1600 heredocs fed to shells one inside another are read in time, the worktree add after them refused" timed shell "$big"
big=$(awk 'BEGIN { for (i = 0; i < 6000; i++) print "bash <<E"; printf "git worktree add ../x" }')
t 2 "6000 of them, one word for all, are read in time, the worktree add in the innermost refused" timed shell "$big"
nojq() { payload "$1" | PATH="$tmp/nojq" run snap; }
t 0 "without jq: a git worktree add passes" nojq 'git worktree add ../x'
t 0 "without jq: and says so" says 'jq is missing' nojq 'git worktree add ../x'
# A push to the default branch, a force push or a remote branch's delete is
# refused before it runs, read from the command's text as the worktree add
# is; the main checkout is on main, .worktrees/43 on feat/43-thing.
silent() { out=$(shell "$@") && [ -z "$out" ]; } # snap lets it through, saying nothing
w43="$repo/.worktrees/43"
for c in 'git push origin main' 'git push upstream main' 'git push origin +main' 'git push origin HEAD:main' 'git push origin feat:refs/heads/main' 'git push origin feat:heads/main' \
  'git push' 'git push origin' 'git push origin HEAD' 'git push origin @' 'git push --all origin' 'git push --mirror origin' 'git push --branches origin' \
  'git push origin :' 'git push --repo=origin upstream' 'git -C .worktrees/43 push origin main' 'A=1 env git push origin main' 'echo a && git push -q --verbose origin main'; do
  t 2 "push: refused, the default branch: $c" shell "$c"
done
for c in "cd '$repo' && git push origin main" "cd '$repo' && git push" "git -C '$repo' push origin HEAD"; do t 2 "push: refused from elsewhere: $c" shell "$c" "$tmp"; done
t 0 "push: that refusal names /coddy:ship" says '/coddy:ship' shell 'git push origin main'
for c in 'git push -f origin feat/43-thing' 'git push -uf origin feat/43-thing' 'git push --force origin feat/43-thing' 'git push --force-with-lease origin feat/43-thing' \
  'git push --force-with-lease=feat/43-thing:abc origin feat/43-thing' 'git push origin +feat/43-thing' 'git push origin --force' 'git push --force-w origin x'; do
  t 2 "push: refused on the issue's own branch, a force push: $c" shell "$c" "$w43"
done
t 0 "push: that refusal says it rewrites the remote's history" says 'force-push' shell 'git push -f origin feat/43-thing' "$w43"
for c in 'git push -d origin feat' 'git push origin --delete feat' 'git push --de origin feat' 'git push origin :feat' 'git push --prune origin'; do t 2 "push: refused, a branch delete: $c" shell "$c" "$w43"; done
t 0 "push: that refusal says it deletes a remote branch" says 'delete a remote branch' shell 'git push origin :feat' "$w43"
for c in 'jj git push -b main' 'jj git push --bookmark=main' 'jj git push -b exact:main' 'jj git push --named main=@' 'jj git push --named=main=@' \
  'jj git push -b=main' 'jj git push -bmain' 'jj git push --all' 'jj git push --tracked' 'jj git push --deleted' 'jj --no-pager git push --remote origin -b feat/x -b main'; do
  t 2 "push: refused, jj: $c" shell "$c"
done
for c in 'git push -u origin feat' 'git push origin main:feat' 'git push origin --tags' 'git push -o ci.skip origin feat' 'git push origin -o main feat' \
  'git push origin refs/tags/main' 'echo "git push --force origin main"' \
  "bash '$here/scripts/issue.sh' push 77" 'jj git push -c @' 'jj git push -b feat/x' 'jj git push --remote main -b feat/x' 'git pushx origin main'; do
  t 0 "push: passes, saying nothing: $c" silent "$c"
done
t 0 "push: in a heredoc body passes, saying nothing" silent $'cat <<EOF >/dev/null\ngit push --force origin main\nEOF'
for c in 'git push' 'git push origin HEAD' 'git push --repo=origin feat' 'git push --repo origin feat'; do t 0 "push: passes on the issue's branch, saying nothing: $c" silent "$c" "$w43"; done
t 0 "push: a bare push outside any repository passes, saying nothing" silent 'git push' "$tmp"
for c in 'git push origin "$b"' 'cd "$d" && git push' 'git push origin HEAD:`b`' 'jj git push' 'jj git push -r @' 'jj git push -b "glob:ma*"' 'jj git push -b substring:ma'; do
  t 0 "push: unresolved, passes with a message: $c" noted 'could not tell which branch' "$c"
done
for c in "git push origin 'refs/heads/*'" "git push origin 'refs/*:refs/*'" "git push origin '*:*'" 'GIT push origin main' 'JJ git push -b main'; do t 2 "push: refused, the default branch: $c" shell "$c"; done
t 0 "push: a pattern that cannot reach the default branch passes, saying nothing" silent "git push origin 'refs/heads/feat/*'"
t 0 "push: after a cd into no directory, which leaves the shell where it was, passes with a message" noted 'could not tell which branch' "cd '$w43/nope'; git push"
# HEAD is read as git reads it, from the repository git finds: a .git that is
# neither a gitdir: file nor a repository is walked past.
hd="$tmp/heads"; mkdir -p "$hd/.git/objects" "$hd/.git/refs" "$hd/empty/.git" "$hd/fifo" "$hd/file"
mkfifo "$hd/fifo/.git"; printf 'gitdir: %s\r\n' "$hd/.git" > "$hd/file/.git"
for h in 'ref:refs/heads/main\n' 'ref: \t refs/heads/main \t\r\n'; do
  printf "$h" > "$hd/.git/HEAD"
  for d in "" /empty /fifo /file; do t 2 "push: refused, HEAD $h read from ${d:-its checkout}" shell 'git push' "$hd$d"; done
done
printf 'ref: refs/heads/.invalid\n' > "$hd/.git/HEAD"
t 0 "push: a reftable repository's HEAD stub passes with a message" noted 'could not tell which branch' "cd '$hd' && git push"
rm "$hd/.git/HEAD"; ln -s refs/heads/main "$hd/.git/HEAD"
t 2 "push: refused, a HEAD that is a link to refs/heads/main" shell 'git push' "$hd/empty"
# A directory reached through a link to a name ending in a newline keeps it,
# so the sibling without it is never read: unresolved, never another's HEAD.
nw="$tmp/nlw"; for b in main feat; do r="$nw/r"; [ $b = feat ] || r="$r"$'\n'; mkdir -p "$r/objects" "$r/refs"; echo "ref: refs/heads/$b" > "$r/HEAD"; done; ln -s r$'\n' "$nw/l"
for c in "cd '$nw/l' && git push origin HEAD" "git --git-dir='$nw/l' push origin HEAD"; do t 0 "push: through a link to a repository named with a trailing newline, passes with a message: $c" noted 'could not tell which branch' "$c"; done
t 0 "without jq: a push passes" nojq 'git push origin main'
t 0 "without jq: and says so" says 'jq is missing' nojq 'git push origin main'
badjq() { payload "$1" | PATH="$tmp/badjq:$PATH" run snap; }
t 0 "with a jq that fails: a push passes" badjq 'git push origin main'
t 0 "with a jq that fails: and says so" says 'jq is missing or failed' badjq 'git push origin main'
# A jq that runs but cannot read the payload is no missing jq: the agent
# writes the payload, and a lone surrogate in any field (jq rejects one)
# would let every push through. Refused, and warned of in warn mode.
unread() { printf '{"tool_use_id":"sh","cwd":"%s","tool_input":{"command":"git push origin main","description":"x\\ud800"}}' "$repo" | run snap; }
unwarned() { out=$(unread) && printf %s "$out" | jq -e '.hookSpecificOutput | .hookEventName == "PreToolUse" and (.additionalContext | contains("could not read the hook payload with jq"))'; }
cp .claude/coddy.yml "$tmp/conf.yml"
printf 'tracker: github\ndefault_branch: main\n' > .claude/coddy.yml
t 2 "a payload jq cannot read: a push to the default branch is refused" saying 'could not read the hook payload with jq' unread
# jq loads ~/.jq into every program; the hooks run it with HOME=/dev/null,
# so a broken one leaves both hooks reading the payload as before.
mkdir "$tmp/badhome"; printf 'def x: ;\n' > "$tmp/badhome/.jq"
badhome() { payload "$1" | HOME="$tmp/badhome" run snap; }
t 2 "a broken ~/.jq: a push to the default branch is still refused" saying '/coddy:ship' badhome 'git push origin main'
HOME="$tmp/badhome" t 2 "a broken ~/.jq: guard still refuses the main checkout" saying 'not the main checkout' guard "$repo/README.md"
printf 'tracker: github\ndefault_branch: main\nguard: warn\n' > .claude/coddy.yml
t 0 "warn: a payload jq cannot read: a push is let through with the message" unwarned
cp "$tmp/conf.yml" .claude/coddy.yml
# A push that pushes nothing (help, a dry run) passes, force and all; tag
# names a tag.
for c in 'git push --help' 'git push -h' 'git --help push' 'git --version push origin main' 'git -v push origin main' 'git -C . --version push' \
  'git push --dry-run origin main' 'git push -n --force origin main' 'git push --dr -f --all' 'jj git push --dry-run -b main' 'git push origin tag main'; do
  t 0 "push: pushes nothing to the default branch, saying nothing: $c" silent "$c"
done
t 2 "push: refused, the default branch after a tag: git push origin tag v1 main" shell 'git push origin tag v1 main'
# A later --no- form undoes an option, as git reads them in order.
for c in 'git push --dry-run --no-dry-run origin feat:main' 'git push -n --no-dr origin main' 'git push --tags --no-tags origin' \
  'git send-pack --dry-run --no-dry-run ../origin.git feat:main'; do t 2 "push: refused, a dry run or --tags undone: $c" shell "$c"; done
for c in 'git push --force-with-lease --no-force origin feat/43-thing' 'git push -f --no-force-with-lease origin feat/43-thing'; do t 2 "push: refused, a force the other --no- form leaves: $c" shell "$c" "$w43"; done
t 0 "push: a lease --no-force-with-lease cancels passes, saying nothing" silent 'git push --force-with-lease --no-force-with-lease origin feat/43-thing' "$w43"
# A $( or backtick substitution is one word its text cannot fix, its own
# commands read too, and the words after it stay in the command.
t 2 "push: refused, the default branch after a substitution" shell 'git push "$(git remote)" main' "$w43"
t 0 "push: a branch after a substitution passes, saying nothing" silent 'git push "$(git remote)" feat'
for c in 'git -C "$(git rev-parse --show-toplevel)" push --force origin feat' 'x=`git push --force origin feat`'; do t 2 "push: refused, a force push: $c" shell "$c"; done
t 2 "push: refused, in a backtick" shell 'echo `git push origin main`'
for c in 'git push $ARGS' 'echo main | xargs git push origin'; do t 0 "push: unresolved, passes with a message: $c" noted 'could not tell which branch' "$c"; done
t 2 "push: refused, a force push after a command word that may expand to nothing" shell '$(true) git push --force origin main'
t 0 "push: after one, a command word it cannot read passes with a message" noted 'could not tell which branch' '$(true) $g push --force origin main'
t 2 "push: refused, a force push by a name after a substitution it starts with" shell '$(true)git push --force origin main'
t 2 "push: refused, after a case in a [[ in a substitution" shell 'echo "$([[ (case == in) ]])"; git push origin main; echo ""'
t 0 "push: after a cd past a substitution, passes with a message" noted 'could not tell which branch' '`echo true` cd .worktrees/43 && git push'
t 2 "push: refused, before a backtick holding an odd quote" shell 'git push origin main `true "`'
t 2 "push: refused, before a substitution left open" shell 'git push origin main $(true'
big=$(awk 'BEGIN { for (i = 0; i < 1600; i++) print "bash <<E" i; print "git push origin main"; for (i = 1599; i >= 0; i--) print "E" i }')
t 2 "push: refused in time, in the innermost of 1600 heredocs fed to shells" timed shell "$big"
# Wrappers, git options that take a value, a dashed builtin by path, a
# heredoc fed to a shell: the push in each is read.
for c in 'git --shallow-file x push origin main' 'timeout 120 git push origin main' 'nice git push origin main' 'nice -n 5 git push origin main' \
  'xargs git push origin main' 'env -u X git push origin main' 'exec -a NAME git push origin main' 'exec -cla NAME git push origin main' \
  '/usr/libexec/git-core/git-push origin main' '"$(git --exec-path)"/git-push origin main' \
  $'bash <<EOF\ngit push origin main\nEOF' $'sh <<\'EOF\'\ngit push origin main\nEOF' $'zsh -s <<EOF\ngit push origin main\nEOF' \
  $'dash <<-EOF\n\tgit push origin main\n\tEOF' $'ksh -e <<EOF\ngit push origin main\nEOF'; do
  t 2 "push: refused, the default branch: $c" shell "$c"
done
for c in 'git-lfs fetch --all' 'git-filter-repo --force --path src'; do t 0 "push: another dashed git tool passes, saying nothing: $c" silent "$c" "$w43"; done
for c in 'git-crypt unlock' 'git-cliff -o CHANGELOG.md && git push origin feat'; do t 0 "push: another dashed git tool passes, saying nothing: $c" silent "$c"; done
t 2 "push: refused, a force push behind timeout's options" shell 'timeout -s KILL 5m git push -f origin feat'
t 2 "push: refused, env -C into the main checkout" shell "env -C '$repo' git push" "$w43"
t 2 "push: refused, a heredoc fed to a shell after a cd" shell "$(printf "cd '%s' && bash <<EOF\ngit push\nEOF" "$repo")" "$w43"
t 0 "push: a cd in a heredoc fed to a shell stays there" silent "$(printf "bash <<EOF\ncd '%s'\nEOF\ngit push" "$repo")" "$w43"
t 0 "push: a heredoc fed to bash -c is text" silent $'bash -c true <<EOF\ngit push origin main\nEOF'
# The command's own -c config: help.autocorrect runs a typo, a bare push
# follows remote.<name>.push and push.default=matching.
t 2 "push: refused, a typo of push under help.autocorrect" shell 'git -c help.autocorrect=immediate psuh origin main'
t 0 "push: a typo without it passes, saying nothing" silent 'git psuh origin main'
for c in 'git -c remote.origin.push=HEAD:main push' 'git -c remote.origin.push=HEAD:main push origin' 'git -c push.default=matching push'; do t 2 "push: refused on the issue's branch, by its -c: $c" shell "$c" "$w43"; done
t 0 "push: another remote's push refspec does not count" silent 'git -c remote.up.push=HEAD:main push origin' "$w43"
# A git dir named by --git-dir or GIT_DIR is read for HEAD, not the
# command's directory; one that is no repository passes with a message.
for c in "git --git-dir='$repo/.git' push" "git --git-dir '$repo/.git' push" "GIT_DIR='$repo/.git' git push" "env GIT_DIR='$repo/.git' git push"; do t 2 "push: refused, HEAD read from the git dir named: $c" shell "$c" "$w43"; done
t 0 "push: a git dir that is no repository passes with a message" noted 'could not tell which branch' "git --git-dir='$tmp/nope' push"
# git's discovery: a bare repository with no .git above it, and a .git
# whose objects and refs come through its commondir.
bare="$tmp/bare"; mkdir -p "$bare/objects" "$bare/refs"; printf 'ref: refs/heads/main\n' > "$bare/HEAD"
t 2 "push: refused, HEAD read from a bare repository" shell "git -C '$bare' push origin HEAD" "$tmp"
# a HEAD git accepts with whitespace after ref: is read whole, not cut at 255 characters
for n in 237 240 246; do printf 'ref:%*srefs/heads/main\n' "$n" '' > "$bare/HEAD"; t 2 "push: refused, HEAD padded with $n blanks" shell "git -C '$bare' push origin HEAD" "$tmp"; t 2 "push: and by --git-dir, $n blanks" shell "git --git-dir='$bare' push origin HEAD" "$tmp"; done
printf 'ref: refs/heads/main\n' > "$bare/HEAD"
cm="$tmp/cm"; mkdir -p "$cm/.git/objects" "$cm/.git/refs" "$cm/sub/.git"; printf 'ref: refs/heads/feat\n' > "$cm/.git/HEAD"
printf 'ref: refs/heads/main\n' > "$cm/sub/.git/HEAD"; printf '../../.git\r\n' > "$cm/sub/.git/commondir"
t 0 "push: the enclosing repository's branch passes, saying nothing" silent 'git push origin HEAD' "$cm"
t 2 "push: refused, HEAD read from a .git whose commondir names the repository" shell 'cd sub && git push origin HEAD' "$cm"
mkfifo "$cm/sub/.git/fifo"; rm "$cm/sub/.git/commondir"; ln -s fifo "$cm/sub/.git/commondir"
t 0 "push: a commondir that is a FIFO is never read" prompt shell 'cd sub && git push origin HEAD' "$cm"
# git send-pack pushes, past the pre-push hook: matching with no refspec.
for c in 'git send-pack ../origin.git feat:main' 'git send-pack ../origin.git' 'git send-pack --all ../origin.git' 'git-send-pack ../origin.git feat:main'; do t 2 "push: refused, send-pack to the default branch: $c" shell "$c"; done
t 2 "push: refused, send-pack --force" shell 'git send-pack --force ../origin.git feat'
t 2 "push: refused, send-pack --mirror" shell 'git send-pack --mirror ../origin.git'
t 0 "push: send-pack of a branch passes, saying nothing" silent 'git send-pack ../origin.git feat'
t 0 "push: send-pack --stdin passes with a message" noted 'could not tell which branch' 'git send-pack --stdin ../origin.git feat'
# After the command: a worktree outside coddy's, made by any spelling, trips;
# one inside, or one that was there before, does not.
wo=$(cd "$tmp" && pwd -P)/out
tripped 0 "tripwire: a git worktree in .worktrees/<id>/ is quiet" 'git worktree add -q --detach .worktrees/88'
tripped 0 "tripwire: a git worktree in .claude/worktrees/ is quiet" 'git worktree add -q --detach .claude/worktrees/y'
wire snap w; (cd "$repo" && git worktree add -q --detach "$wo") >/dev/null 2>&1
wire trip w 2>"$tmp/trip.err"; got=$?
t 0 "tripwire: a git worktree outside trips" test "$got" = 2
t 0 "tripwire: and names it, made, with the tool that removes it" grep -qF "git worktree at '$wo', made (check what it holds before removing it with git worktree remove)" "$tmp/trip.err"
t 1 "tripwire: and gives no command line" cmdline
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
t 0 "tripwire: a path holding a remedy of its own is one quoted entry" grep -qF ": git worktree at '$sp', made (check what it holds before removing it with git worktree remove). Issue work" "$tmp/trip.err"
git worktree remove --force "$sp"
sq="$wo/it's"
wire snap w; git worktree add -q --detach "$sq" >/dev/null 2>&1
wire trip w 2>"$tmp/trip.err"; got=$?
t 0 "tripwire: a git worktree whose path holds a quote trips" test "$got" = 2
t 0 "tripwire: and is reported quoted" grep -qF "git worktree at '$wo/it'\\''s', made" "$tmp/trip.err"
t 1 "tripwire: and gives no command line" cmdline
git worktree remove --force "$sq"; rm -rf "$wo"
# A worktree made in .worktrees/<id>/ and moved out, or reached there through
# a link, is no longer coddy's: it trips, and only once.
tripped 2 "tripwire: a git worktree made in .worktrees/<id>/ and moved out trips" 'git worktree add -q -b evil .worktrees/87 && mv .worktrees/87 "$tmp/mv87"'
tripped 0 "tripwire: and is quiet on the next command" 'true'
tripped 2 "tripwire: one moved out with a link put back trips" 'git worktree add -q --detach .worktrees/86 && mv .worktrees/86 "$tmp/mv86" && ln -s "$tmp/mv86" .worktrees/86'
rm -rf "$tmp/mv87" "$tmp/mv86" .worktrees/86; git worktree prune; git branch -q -D evil
# trip runs git outside the sandbox: a git dir or common dir the command
# plants for a new worktree, or for a submodule of the main checkout, runs
# none of its programs.
printf '#!/bin/sh\necho x >> "%s/fsm"\nexit 1\n' "$tmp" > "$tmp/fsm.sh"; chmod +x "$tmp/fsm.sh"
git init -q "$tmp/evil"; git -C "$tmp/evil" config core.fsmonitor "$tmp/fsm.sh"
for c in 'echo "gitdir: $tmp/evil/.git" > "$wo/.git"' 'echo "$tmp/evil/.git" > "$(git -C "$wo" rev-parse --git-dir)/commondir"'; do
  rm -f "$tmp/fsm"; wire snap w; (git worktree add -q --detach "$wo" && eval "$c") >/dev/null 2>&1
  wire trip w 2>/dev/null; got=$?
  t 0 "tripwire: a new git worktree with a planted git dir trips: $c" test "$got" = 2
  t 1 "tripwire: and runs none of its programs" test -e "$tmp/fsm"
  rm -rf "$wo"; git worktree prune
done
rm -f "$tmp/fsm"; wire snap w; (git update-index --add --cacheinfo "160000,$(git rev-parse HEAD),sub" && mkdir sub && echo "gitdir: $tmp/evil/.git" > sub/.git) >/dev/null 2>&1
wire trip w 2>/dev/null; got=$?
t 0 "tripwire: a submodule of the main checkout off the commit recorded for it trips" test "$got" = 2
wire snap w; wire trip w 2>/dev/null
t 1 "tripwire: a planted submodule of the main checkout runs none of its programs" test -e "$tmp/fsm"
git rm -q --cached sub; rm -rf sub
# Nor does one whose commit leaves the one recorded for it, with a
# core.fsmonitor planted in its git dir under .git/modules/, which the
# sandbox does not protect.
mkdir -p .git/modules && git init -q --separate-git-dir .git/modules/sm sm && git -C sm commit -q --allow-empty -m a && git update-index --add --cacheinfo "160000,$(git -C sm rev-parse HEAD),sm"
rm -f "$tmp/fsm"; wire snap w; (git -C sm commit -q --allow-empty -m b && git config --file .git/modules/sm/config core.fsmonitor "$tmp/fsm.sh") >/dev/null 2>&1
wire trip w 2>/dev/null; wire snap w; wire trip w 2>/dev/null
t 1 "tripwire: a submodule moved off its commit runs its planted fsmonitor neither in snap nor in trip" test -e "$tmp/fsm"
rm -rf sm .git/modules; git update-index --force-remove sm
# A commondir in the main checkout's git dir, which git never writes there,
# points git at another repository's config, whether the root stays (a copy
# of .git in it) or moves (a repository elsewhere, holding a config of its
# own): the hooks run no git and refuse every edit and command, from the
# main checkout or a linked worktree, until it is removed by hand. A linked
# worktree's own commondir is by design: the hooks work from it.
git worktree add -q --detach .worktrees/82; cp -R .git .evilgit; git --git-dir=.evilgit config core.fsmonitor "$tmp/fsm.sh"
printf 'tracker: github\nworktree: git\n' > "$tmp/evil/.coddy.yml"
lw() { printf '{"tool_use_id":"%s"}' "$2" | CLAUDE_PROJECT_DIR="$repo/.worktrees/82" bash "$here/scripts/issue.sh" "$1"; }
lw snap w; t 0 "commondir: a linked worktree's own leaves the hooks working from it" lw trip w
for cd in ../.evilgit "$tmp/evil/.git"; do
  rm -f "$tmp/fsm"; wire snap w; echo "$cd" > .git/commondir
  wire trip w 2>"$tmp/trip.err"; got=$?
  t 0 "commondir: the command that plants one trips: $cd" test "$got" = 2
  t 0 "commondir: and the report names it" grep -qF "/.git/commondir, which git never writes in a main checkout" "$tmp/trip.err"
  t 2 "commondir: snap refuses every command after it: $cd" wire snap w
  t 2 "commondir: guard refuses every edit: $cd" guard "$repo/.claude/x"
  t 2 "commondir: from a linked worktree too: $cd" lw snap w
  t 1 "commondir: and git ran none of its programs: $cd" test -e "$tmp/fsm"
  mkdir -p .worktrees/85; echo garbage > .worktrees/85/.git; rm -f "$tmp/fsm"
  t 2 "commondir: snap refuses from a worktree whose .git is garbage: $cd" sh -c "printf '{\"tool_use_id\":\"w\"}' | CLAUDE_PROJECT_DIR='$repo/.worktrees/85' bash '$here/scripts/issue.sh' snap"
  t 1 "commondir: and that ran none of its programs: $cd" test -e "$tmp/fsm"
  rm -rf .worktrees/85
  rm .git/commondir
done
rm -rf .evilgit "$tmp/evil/.coddy.yml"; git worktree remove --force .worktrees/82
tripped 0 "commondir: removed, the hooks are back" 'true'
# git worktree list, which the fingerprint runs, reads gitdir, HEAD, locked
# and commondir in every admin dir under .git/worktrees/, a dot-named one
# included, and waits on a FIFO there for good: snap refuses every command,
# and trip the one that left it, at once, in either guard mode, trip after
# putting the config back. Anything else that is no plain file, links
# followed, is refused too; a plain file, through a link or not, or none,
# passes.
snapadm() { wire snap w 2>"$tmp/adm.err"; }
tripadm() { wire trip w 2>"$tmp/adm.err"; }
named() { grep -qF "$1' is not a plain file" "$tmp/adm.err"; }
cp .claude/coddy.yml "$tmp/conf.adm"; git worktree add -q --detach "$wo"; ad=$(git -C "$wo" rev-parse --absolute-git-dir)
for v in block warn; do
  { grep -v '^guard:' "$tmp/conf.adm"; echo "guard: $v"; } > .claude/coddy.yml; cp .claude/coddy.yml "$tmp/conf.mode"
  for f in gitdir HEAD locked commondir; do
    rm -f "$tmp/adm.save"; wire snap w
    rm .claude/coddy.yml; [ ! -e "$ad/$f" ] || mv "$ad/$f" "$tmp/adm.save"; mkfifo "$ad/$f"
    t 2 "worktree admin: trip refuses a FIFO at $f at once, guard: $v" timed tripadm
    t 0 "worktree admin: and names it: $f, guard: $v" named "worktrees/${ad##*/}/$f"
    t 0 "worktree admin: after putting the config back: $f, guard: $v" cmp -s .claude/coddy.yml "$tmp/conf.mode"
    t 2 "worktree admin: snap refuses every command after it at once: $f, guard: $v" timed snapadm
    t 0 "worktree admin: and names it to snap: $f, guard: $v" named "worktrees/${ad##*/}/$f"
    rm "$ad/$f"; [ ! -e "$tmp/adm.save" ] || mv "$tmp/adm.save" "$ad/$f"
  done
done
cp "$tmp/conf.adm" .claude/coddy.yml
mkdir .git/worktrees/.x; mkfifo .git/worktrees/.x/gitdir
t 2 "worktree admin: a FIFO in a dot-named admin dir is refused at once" timed snapadm
t 0 "worktree admin: and named" named "worktrees/.x/gitdir"
rm -r .git/worktrees/.x
# A session opened in a subdirectory whose .git is a garbage file: git finds
# no common dir from there, while git worktree list still runs at the root,
# so the root's own .git is checked.
subadm() { printf '{"tool_use_id":"w"}' | CLAUDE_PROJECT_DIR="$repo/adm.sub" bash "$here/scripts/issue.sh" "$1" 2>"$tmp/adm.err"; }
mkdir adm.sub; echo junk > adm.sub/.git; subadm snap; mkdir .git/worktrees/admx; mkfifo .git/worktrees/admx/gitdir
t 2 "worktree admin: trip from a subdirectory whose .git is garbage refuses a FIFO at once" timed subadm trip
t 0 "worktree admin: and names it" named "worktrees/admx/gitdir"
t 2 "worktree admin: and so does snap" timed subadm snap
t 0 "worktree admin: and names it to snap" named "worktrees/admx/gitdir"
rm -r .git/worktrees/admx adm.sub; mkfifo "$tmp/adm.fifo"; echo why > "$tmp/adm.why"
for c in "mkdir '$ad/locked'" "ln -s '$tmp/adm.fifo' '$ad/locked'" "ln -s '$tmp/adm.none' '$ad/locked'"; do
  eval "$c"; t 2 "worktree admin: snap refuses a locked that is no plain file: $c" timed snapadm
  t 0 "worktree admin: and names it: $c" named "worktrees/${ad##*/}/locked"; rm -rf "$ad/locked"
done
for c in "cp '$tmp/adm.why' '$ad/locked'" "ln -s '$tmp/adm.why' '$ad/locked'" true; do
  eval "$c"; tripped 0 "worktree admin: a plain locked, through a link or not, or none, passes: $c" 'true'; rm -f "$ad/locked"
done
# A HEAD link reaching nothing whose text starts with refs/, as git writes
# it under core.preferSymlinkRefs, is read as that ref and opened by no
# one: it passes. One that reaches a FIFO, no ref by its text, git opens
# and waits on: refused.
mv "$ad/HEAD" "$tmp/adm.head"; ln -s refs/heads/main "$ad/HEAD"
tripped 0 "worktree admin: a HEAD link to a ref, as core.preferSymlinkRefs writes it, passes" 'true'
rm "$ad/HEAD"; mkdir -p "$ad/refs"; mkfifo "$ad/adm.fifo"; ln -s refs/../adm.fifo "$ad/HEAD"
t 2 "worktree admin: a HEAD link whose text starts with refs/ and reaches a FIFO is refused at once" timed snapadm
t 0 "worktree admin: and named" named "worktrees/${ad##*/}/HEAD"
rm "$ad/HEAD" "$ad/adm.fifo"; mv "$tmp/adm.head" "$ad/HEAD"
# trip refusing an admin dir still reports the main checkout's own change,
# git worktree list left unrun, which it says.
for c in mkdir mkfifo; do
  wire snap w; echo evil >> README.md; "$c" "$ad/locked"
  t 2 "worktree admin: trip refuses a $c locked next to a dirty README.md at once" timed tripadm
  t 0 "worktree admin: and names it: $c" named "worktrees/${ad##*/}/locked"
  t 0 "worktree admin: and reports README.md: $c" grep -qF 'that command changed the main checkout: README.md.' "$tmp/adm.err"
  t 0 "worktree admin: and says the git worktrees went unlisted: $c" grep -qF 'The git worktrees could not be listed for that command' "$tmp/adm.err"
  rm -rf "$ad/locked"; git checkout -q README.md
done
# And a worktree the command made, which the next snap would record as
# there before: a git worktree by its admin dir, one snap did not record,
# no file in it read, and a jj workspace as ever. One from before the
# command is not named; one it moved is not either (a ceiling).
wn=${wo%/*}/admn
wire snap w; git worktree add -q --detach "$wn" >/dev/null 2>&1; an=$(cd "$(git -C "$wn" rev-parse --absolute-git-dir)" && pwd -P); ln -s "$tmp/adm.none" "$an/locked"
t 2 "worktree admin: trip refuses a dangling locked left by a command that made a git worktree" timed tripadm
t 0 "worktree admin: and names it" named "worktrees/admn/locked"
t 0 "worktree admin: and names that worktree's admin dir, made" grep -qF "git worktree whose admin dir is '$an', made (check what it holds before removing it with git worktree remove)" "$tmp/adm.err"
t 1 "worktree admin: and not the one from before the command" grep -qF "worktrees/${ad##*/}', made" "$tmp/adm.err"
rm "$an/locked"; git worktree remove --force "$wn"
if command -v jj >/dev/null; then
  wj=${wo%/*}/admj
  wire snap w; (jj workspace add --name admj "$wj" && ln -s "$tmp/adm.none" "$ad/locked") >/dev/null 2>&1
  t 2 "worktree admin: trip refuses a dangling locked left by a command that made a jj workspace" timed tripadm
  t 0 "worktree admin: and names it: jj" named "worktrees/${ad##*/}/locked"
  t 0 "worktree admin: and names that jj workspace, made" grep -qF "jj workspace 'admj' at '$wj', made (check what it holds before removing it with jj workspace forget)" "$tmp/adm.err"
  rm "$ad/locked"; jj workspace forget admj >/dev/null 2>&1; rm -rf "$wj"; git worktree prune
fi
# A session opened in a bare repository nested one level into the project
# roots at the project, where git worktree list runs: the root's own .git
# is checked, not the bare repository.
bareadm() { printf '{"tool_use_id":"w"}' | CLAUDE_PROJECT_DIR="$repo/adm.bare" bash "$here/scripts/issue.sh" "$1" 2>"$tmp/adm.err"; }
git init -q --bare adm.bare; bareadm snap; mkfifo "$ad/locked"
t 2 "worktree admin: trip from a bare repository nested in the project refuses a FIFO in the root's .git at once" timed bareadm trip
t 0 "worktree admin: and names it" named "worktrees/${ad##*/}/locked"
t 2 "worktree admin: and so does snap" timed bareadm snap
t 0 "worktree admin: and names it to snap" named "worktrees/${ad##*/}/locked"
rm "$ad/locked"; rm -rf adm.bare
rm -f "$tmp/adm.fifo" "$tmp/adm.why"; git worktree remove --force "$wo"
# The hooks find the checkout's git dir the way git does, without git: past a
# .git directory that is no repository (an empty one under .worktrees/<id>
# or a subdirectory, which git walks past to the commondir it would
# follow), refusing a .git that is a link, and putting the root back at the
# checkout when the root's .git is a gitdir: file naming one elsewhere.
hk() { printf '{"tool_use_id":"w","tool_input":{"file_path":"%s"}}' "${3-/x}" | CLAUDE_PROJECT_DIR="$1" bash "$here/scripts/issue.sh" "$2"; }
printf 'tracker: github\nworktree: git\n' > "$tmp/evil/.coddy.yml"; echo "$tmp/evil/.git" > .git/commondir
mkdir -p .worktrees/87/.git src/deep/.git; rm -f "$tmp/fsm"
t 2 "root: snap refuses from a worktree holding an empty .git dir" hk "$repo/.worktrees/87" snap
t 2 "root: and from a subdirectory holding one" hk "$repo/src/deep" snap
t 1 "root: and git ran none of its programs" test -e "$tmp/fsm"
rm -rf .worktrees/87 src .git/commondir "$tmp/evil/.coddy.yml"
rm -f "$tmp/fsm"; mkdir src; ln -s "$tmp/evil/.git" src/.git; printf 'tracker: github\nworktree: git\n' > src/.coddy.yml
t 2 "root: snap refuses a .git that is a link, in a subdirectory" hk "$repo/src" snap
t 2 "root: and guard" hk "$repo/src" guard "$repo/src/x"
t 1 "root: and git ran none of its programs" test -e "$tmp/fsm"
rm -rf src
# no config in the subdirectory: the root stays at git's, so the hooks still refuse
for lk in /nowhere "$tmp"; do
  rm -rf src; mkdir src; ln -s "$lk" src/.git
  t 2 "root: a .git link to $lk in a subdirectory with no config refuses guard" hk "$repo/src" guard "$repo/src/x"
  t 2 "root: and snap" hk "$repo/src" snap
done
rm -rf src; mkdir -p src/.git; echo /nowhere > src/.git/commondir
t 2 "root: a commondir to nowhere in a subdirectory with no config refuses guard" hk "$repo/src" guard "$repo/src/x"
t 2 "root: and snap" hk "$repo/src" snap
rm -rf src
mkdir -p src/.git; t 2 "root: a garbage .git dir in a subdirectory leaves the guard on" hk "$repo/src" guard "$repo/README.md"
rm -rf src; mkdir src; echo garbage > src/.git
t 2 "root: so does a garbage .git file, where git fails" hk "$repo/src" guard "$repo/README.md"
rm -rf src
# a HEAD git rejects (ref: then \v or \f) is no repository: a project holding one, below a repository, with a fatal .git between the start and it, runs no git in that repository
git init -q "$tmp/vA"; git -C "$tmp/vA" config core.fsmonitor "$tmp/fsm.sh"
for ws in $'\v' $'\f'; do
  rm -rf "$tmp/vA/P"; mkdir -p "$tmp/vA/P/src/deep" "$tmp/vA/P/.git/objects" "$tmp/vA/P/.git/refs"; printf 'ref:%srefs/heads/main\n' "$ws" > "$tmp/vA/P/.git/HEAD"; echo garbage > "$tmp/vA/P/src/.git"; printf 'tracker: github\nworktree: git\n' > "$tmp/vA/P/.coddy.yml"
  for h in snap trip; do rm -f "$tmp/fsm"; hk "$tmp/vA/P/src/deep" "$h" >/dev/null 2>&1; t 1 "root: a HEAD of ref: then $(printf %s "$ws" | od -An -c | tr -d ' ') is no repository, so $h runs no program of the one above" test -e "$tmp/fsm"; done
done
rm -rf "$tmp/vA"
# a .git git takes itself (a link to a real repository) is no root above it; where git fails, the walk's stop gets the same fallback
for lk in "$repo/.git" /etc/hosts; do
  rm -rf src; mkdir src; ln -s "$lk" src/.git
  t 2 "root: a .git link to $lk in a subdirectory with no config refuses guard" hk "$repo/src" guard "$repo/src/x"
  t 2 "root: and snap" hk "$repo/src" snap
done
rm -rf src; mkdir -p src/.git "$tmp/cd"; ln -s "$tmp/cd" src/.git/commondir
t 2 "root: a commondir link to a directory in a subdirectory with no config refuses guard" hk "$repo/src" guard "$repo/src/x"
t 2 "root: and snap" hk "$repo/src" snap
rm -rf src "$tmp/cd"
# a session in a linked git worktree, the checkout's .git swapped for a link
mkdir -p "$tmp/f6"; git init -q "$tmp/f6"; git -C "$tmp/f6" -c user.name=t -c user.email=t@t commit -q --allow-empty -m i
printf 'tracker: github\nworktree: git\n' > "$tmp/f6/.coddy.yml"; git -C "$tmp/f6" worktree add -q --detach .worktrees/5
mv "$tmp/f6/.git" "$tmp/f6/.gitx"; ln -s .gitx "$tmp/f6/.git"
t 2 "root: a session in a linked worktree, the checkout's .git a link, refuses guard" hk "$tmp/f6/.worktrees/5" guard "$tmp/f6/x"
t 2 "root: and snap" hk "$tmp/f6/.worktrees/5" snap
t 0 "root: and the message says the link is to be removed" sh -c "hk() { printf '{\"tool_input\":{\"file_path\":\"/x\"}}' | CLAUDE_PROJECT_DIR='$tmp/f6/.worktrees/5' bash '$here/scripts/issue.sh' guard 2>&1; }; hk | grep -qF '$tmp/f6/.git is a link'"
rm -rf "$tmp/f6"
mkdir -p "$tmp/f4"; git init -q "$tmp/f4"; printf 'tracker: github\nworktree: git\n' > "$tmp/f4/.coddy.yml"
mv "$tmp/f4/.git" "$tmp/f4git"; echo "gitdir: $tmp/f4git" > "$tmp/f4/.git"
t 2 "root: a root .git that is a gitdir: file elsewhere refuses snap" hk "$tmp/f4" snap
t 2 "root: and guard" hk "$tmp/f4" guard "$tmp/f4/x"
t 0 "root: and the message names the file and says to open the session in the main checkout" sh -c "hk() { printf '{\"tool_input\":{\"file_path\":\"/x\"}}' | CLAUDE_PROJECT_DIR='$tmp/f4' bash '$here/scripts/issue.sh' guard 2>&1; }; hk | grep -F '$tmp/f4/.git is a file naming a git dir elsewhere' | grep -qF 'open the session in the main checkout, or remove the file by hand'"
mkdir -p "$tmp/f5/.claude"; printf 'tracker: github\nworktree: git\n' > "$tmp/f5/.coddy.yml"
t 0 "root: a plain root with no .git passes guard with proj set in the environment" env proj=1 bash -c "printf '{\"tool_input\":{\"file_path\":\"$tmp/f5/.claude/x\"}}' | CLAUDE_PROJECT_DIR='$tmp/f5' bash '$here/scripts/issue.sh' guard"
t 0 "root: and snap" env proj=1 bash -c "printf '{\"tool_use_id\":\"w\"}' | CLAUDE_PROJECT_DIR='$tmp/f5' bash '$here/scripts/issue.sh' snap"
rm -rf "$tmp/f4" "$tmp/f4git" "$tmp/f5"
# groot in the environment moves nothing: git failing in a subdirectory with no config still gets the fallback
rm -rf src; mkdir src; ln -s /etc/hosts src/.git
t 2 "root: a groot in the environment leaves a .git link, where git fails, refusing guard" env groot="$repo/src" bash -c "printf '{\"tool_input\":{\"file_path\":\"$repo/src/x\"}}' | CLAUDE_PROJECT_DIR='$repo/src' bash '$here/scripts/issue.sh' guard"
t 2 "root: and snap" env groot="$repo/src" bash -c "printf '{\"tool_use_id\":\"w\"}' | CLAUDE_PROJECT_DIR='$repo/src' bash '$here/scripts/issue.sh' snap"
rm -rf src
# a session in an absorbed submodule of an onboarded project: git's root there is .git/modules/, which holds no config, so the hooks are inert as ever
mkdir -p "$tmp/f7/.claude"; git init -q "$tmp/f7"; git -C "$tmp/f7" -c user.name=t -c user.email=t@t commit -q --allow-empty -m i
printf 'tracker: github\nworktree: git\n' > "$tmp/f7/.coddy.yml"; git init -q "$tmp/f7sub"; git -C "$tmp/f7sub" -c user.name=t -c user.email=t@t commit -q --allow-empty -m i
git -C "$tmp/f7" -c protocol.file.allow=always submodule add -q "$tmp/f7sub" vendor/sub >/dev/null 2>&1
t 0 "root: a session in an absorbed submodule of an onboarded project passes guard" hk "$tmp/f7/vendor/sub" guard "$tmp/f7/README.md"
t 0 "root: and snap" hk "$tmp/f7/vendor/sub" snap
t 2 "root: while the project's own checkout still refuses guard" hk "$tmp/f7" guard "$tmp/f7/README.md"
rm -rf "$tmp/f7" "$tmp/f7sub"
# an onboarded submodule (its .git a gitdir: file naming a git dir elsewhere) stays refused, the message saying what to do
mkdir -p "$tmp/f9"; git init -q "$tmp/f9"; git -C "$tmp/f9" -c user.name=t -c user.email=t@t commit -q --allow-empty -m i
git init -q "$tmp/f9sub"; git -C "$tmp/f9sub" -c user.name=t -c user.email=t@t commit -q --allow-empty -m i
git -C "$tmp/f9" -c protocol.file.allow=always submodule add -q "$tmp/f9sub" vendor/sub >/dev/null 2>&1
printf 'tracker: github\nworktree: git\n' > "$tmp/f9/vendor/sub/.coddy.yml"
t 2 "root: a session in a submodule holding its own config refuses guard" hk "$tmp/f9/vendor/sub" guard "$tmp/f9/vendor/sub/x"
t 2 "root: and snap" hk "$tmp/f9/vendor/sub" snap
t 0 "root: and the message names its .git, a git dir elsewhere, a submodule and the main checkout" sh -c "hk() { printf '{\"tool_input\":{\"file_path\":\"/x\"}}' | CLAUDE_PROJECT_DIR='$tmp/f9/vendor/sub' bash '$here/scripts/issue.sh' guard 2>&1; }; hk | grep -F '$tmp/f9/vendor/sub/.git is a file naming a git dir elsewhere' | grep -F 'a submodule or a bare repository' | grep -qF 'open the session in the main checkout'"
rm -rf "$tmp/f9" "$tmp/f9sub"
# a git-less onboarded root (a jj project outside git) keeps its own root whatever .git sits above it, as it always did
mkdir -p "$tmp/g1/proj"; printf 'tracker: github\nworktree: jj\n' > "$tmp/g1/proj/.coddy.yml"
for lk in /nowhere /etc/hosts; do
  rm -rf "$tmp/g1/.git"; ln -s "$lk" "$tmp/g1/.git"
  t 0 "root: a git-less onboarded root under a .git link to $lk allows an agent-dir edit" hk "$tmp/g1/proj" guard "$tmp/g1/proj/.claude/x"
  t 0 "root: and from .worktrees/<id>" hk "$tmp/g1/proj/.worktrees/5" guard "$tmp/g1/proj/.claude/x"
done
rm -rf "$tmp/g1/.git"; mkdir -p "$tmp/g1/.git"; echo /nowhere > "$tmp/g1/.git/commondir"
t 0 "root: a git-less onboarded root under a commondir to nowhere allows an agent-dir edit" hk "$tmp/g1/proj" guard "$tmp/g1/proj/.claude/x"
t 0 "root: and from .worktrees/<id>" hk "$tmp/g1/proj/.worktrees/5" guard "$tmp/g1/proj/.claude/x"
# an uppercased detached HEAD is a repository to git: the walk stops at git's root, so a link or commondir above the project moves nothing
mkdir -p "$tmp/g3"; git init -q "$tmp/g3/proj"; git -C "$tmp/g3/proj" -c user.name=t -c user.email=t@t commit -q --allow-empty -m i
printf 'tracker: github\nworktree: git\n' > "$tmp/g3/proj/.coddy.yml"
git -C "$tmp/g3/proj" rev-parse HEAD | tr a-f A-F > "$tmp/g3/proj/.git/HEAD"
ln -s /nowhere "$tmp/g3/.git"
t 2 "root: an uppercase HEAD under a dangling .git link above still refuses guard on a main-checkout edit" hk "$tmp/g3/proj" guard "$tmp/g3/proj/x"
t 0 "root: and allows an agent-dir edit" hk "$tmp/g3/proj" guard "$tmp/g3/proj/.claude/x"
rm -f "$tmp/g3/.git"; mkdir "$tmp/g3/.git"; echo /nowhere > "$tmp/g3/.git/commondir"
t 2 "root: and under a commondir above, guard refuses a main-checkout edit" hk "$tmp/g3/proj" guard "$tmp/g3/proj/x"
t 0 "root: and the agent dir is allowed" hk "$tmp/g3/proj" guard "$tmp/g3/proj/.claude/x"
rm -rf "$tmp/g3"
rm -rf "$tmp/g1"
# a project with no config nested in an onboarded repository, its .git renamed, a session in .worktrees/<id> whose .git is a link: the config above is no config of the project's
mkdir -p "$tmp/g2/p/.worktrees/5/.gitdirx"; git init -q "$tmp/g2"; printf 'tracker: github\nworktree: git\n' > "$tmp/g2/.coddy.yml"
git init -q "$tmp/g2/p"; mv "$tmp/g2/p/.git" "$tmp/g2/p/.gitx"; rmdir "$tmp/g2/p/.worktrees/5/.gitdirx"; ln -s /etc/hosts "$tmp/g2/p/.worktrees/5/.git"
t 0 "root: a project with no config nested in an onboarded one stays inert from .worktrees/<id>, guard" hk "$tmp/g2/p/.worktrees/5" guard "$tmp/g2/p/x"
t 0 "root: and snap" hk "$tmp/g2/p/.worktrees/5" snap
rm -rf "$tmp/g2"
# the root's .git a link and the session's own directory holding the config: the message names the link
mkdir -p "$tmp/g3"; git init -q "$tmp/g3"; git -C "$tmp/g3" -c user.name=t -c user.email=t@t commit -q --allow-empty -m i
git -C "$tmp/g3" worktree add -q --detach .worktrees/5; printf 'tracker: github\nworktree: git\n' > "$tmp/g3/.worktrees/5/.coddy.yml"
mv "$tmp/g3/.git" "$tmp/g3/.gitx"; ln -s .gitx "$tmp/g3/.git"
t 2 "root: a root with no config whose .git is a link, a worktree holding one, refuses guard" hk "$tmp/g3/.worktrees/5" guard "$tmp/g3/x"
t 0 "root: and the message names the root's .git, the link" sh -c "hk() { printf '{\"tool_input\":{\"file_path\":\"/x\"}}' | CLAUDE_PROJECT_DIR='$tmp/g3/.worktrees/5' bash '$here/scripts/issue.sh' guard 2>&1; }; hk | grep -qF '$tmp/g3/.git is a link'"
rm -rf "$tmp/g3"
# a project nested in another repository, its .git renamed, a session in .worktrees/<id>: the walk stops at the project the path names, so the guard stays on as git failing there always left it
mkdir -p "$tmp/f8"; git init -q "$tmp/f8"; git -C "$tmp/f8" -c user.name=t -c user.email=t@t commit -q --allow-empty -m i
mkdir -p "$tmp/f8/p/.claude"; git init -q "$tmp/f8/p"; git -C "$tmp/f8/p" -c user.name=t -c user.email=t@t commit -q --allow-empty -m i
printf 'tracker: github\nworktree: git\n' > "$tmp/f8/p/.coddy.yml"; git -C "$tmp/f8/p" worktree add -q --detach .worktrees/5
mv "$tmp/f8/p/.git" "$tmp/f8/p/.gitx"
t 2 "root: a nested project, its .git renamed, refuses guard from .worktrees/<id>" hk "$tmp/f8/p/.worktrees/5" guard "$tmp/f8/p/x"
rm -f "$tmp/f8/p/.worktrees/5/.git"; ln -s /etc/hosts "$tmp/f8/p/.worktrees/5/.git"
t 2 "root: and snap, the worktree's own .git a link" hk "$tmp/f8/p/.worktrees/5" snap
rm -rf "$tmp/f8"
git worktree add -q --detach .worktrees/84
# A worktree git moved out of .worktrees/<id>/ was not made.
wire snap w; git worktree move .worktrees/84 "$wo" >/dev/null 2>&1
wire trip w 2>"$tmp/trip.err"; got=$?
t 0 "tripwire: a git worktree moved out of .worktrees/<id>/ by git trips" test "$got" = 2
t 0 "tripwire: and is reported moved, not made" grep -qF "git worktree at '$wo', moved, renamed or re-created (put it back with git worktree move, or check what it holds before removing it with git worktree remove)" "$tmp/trip.err"
t 1 "tripwire: with no command line" cmdline
git worktree move "$wo" .worktrees/84
# One moved by hand, its directory gone when snap runs, and repaired by the
# command, as git suggests: moved.
mv .worktrees/84 "$wo"
wire snap w; git worktree repair "$wo" >/dev/null 2>&1
wire trip w 2>"$tmp/trip.err"; got=$?
t 0 "tripwire: a git worktree moved by hand and repaired trips" test "$got" = 2
t 0 "tripwire: and is reported moved, not made" grep -qF "git worktree at '$wo', moved, renamed or re-created (put it back with git worktree move, or check what it holds before removing it with git worktree remove)" "$tmp/trip.err"
t 1 "tripwire: with no command line" cmdline
git worktree move "$wo" .worktrees/84
git worktree remove --force .worktrees/84
# A backslash prints as \134, so it never reads as the \ooo of a control byte.
bs="$wo/b\\001" cc="$wo/b"$'\001'
wire snap w; (git worktree add -q --detach "$bs" && git worktree add -q --detach "$cc") >/dev/null 2>&1
wire trip w 2>"$tmp/trip.err"
t 0 "tripwire: a backslash in a path prints as \\134" grep -qF "'$wo/b\\134001'" "$tmp/trip.err"
t 0 "tripwire: and a control byte as \\ooo, a line of its own" grep -qF "'$wo/b\\001'" "$tmp/trip.err"
git worktree remove --force "$bs"; git worktree remove --force "$cc"; rm -rf "$wo"
# A worktree's .git is read no further than a NUL or 1024 characters, so a
# huge one stalls no hook, and what snap records of it stays small.
sf="${TMPDIR:-/tmp}/coddy-snap-$(printf %s "$repo" | cksum | cut -d' ' -f1)-w"
git worktree add -q --detach .worktrees/83; cp .worktrees/83/.git "$tmp/g83"
{ printf 'gitdir: /a/b'; head -c 4000000 /dev/zero | tr '\0' x; } > .worktrees/83/.git
t 0 "tripwire: a 4 MB .git in a worktree stalls no snap" prompt wire snap w
t 0 "tripwire: and is recorded no further than 1024 characters" test "$(wc -c < "$sf.wt")" -lt 65536
t 0 "tripwire: nor trip" prompt wire trip w
cp "$tmp/g83" .worktrees/83/.git; git worktree remove --force .worktrees/83
# A dirty path holding line breaks is printed quoted, on one line: one built
# to read as a worktree's line is not reported as one, and does not hide the
# real one a later command makes at that path.
fake=$'x\n'"git worktree at '$wo' (git worktree remove)"$'\ny'
wire snap w; mkdir -p "${fake%/*}"; ln -s nowhere "$fake"
wire trip w 2>"$tmp/trip.err"; got=$?
t 0 "tripwire: a dirty path holding a worktree's line trips" test "$got" = 2
t 0 "tripwire: as a change to the main checkout" grep -qF "changed the main checkout: 'x\\012git worktree at" "$tmp/trip.err"
t 1 "tripwire: never as a worktree" grep -qF "'$wo', made" "$tmp/trip.err"
wire snap w; git worktree add -q --detach "$wo" >/dev/null 2>&1
wire trip w 2>"$tmp/trip.err"; got=$?
t 0 "tripwire: a real worktree made at that path afterwards trips" test "$got" = 2
t 0 "tripwire: and is named made" grep -qF "git worktree at '$wo', made (" "$tmp/trip.err"
git worktree remove --force "$wo"; rm -rf "${fake%%/*}" "$wo"
# A path that is the root, a newline and more is no root: it trips.
R=$(pwd -P); nl="$R"$'\n'x
wire snap w; git worktree add -q --detach "$nl" >/dev/null 2>&1
wire trip w 2>"$tmp/trip.err"; got=$?
t 0 "tripwire: a git worktree at the root, a newline and more trips" test "$got" = 2
t 1 "tripwire: and gives no command line" cmdline
git worktree remove --force "$nl"
# A git before 2.36 has no worktree list -z: a stub git refuses it and lists
# without it as such a git did, every path raw. The worktrees are read all
# the same, and an entry the listing splits is read as odd.
mkdir "$tmp/oldgit"; real=$(command -v git)
cat > "$tmp/oldgit/git" <<EOF
#!/bin/sh
case "\$*" in
  *"worktree list --porcelain -z") exit 129 ;;
  *"worktree list --porcelain") "$real" worktree list --porcelain -z | tr '\0' '\n'; exit ;;
esac
exec "$real" "\$@"
EOF
chmod +x "$tmp/oldgit/git"; old() { PATH="$tmp/oldgit:$PATH" wire "$@"; }
old snap w; git worktree add -q --detach "$wo" >/dev/null 2>&1
old trip w 2>"$tmp/trip.err"; got=$?
t 0 "git before 2.36: a git worktree outside trips" test "$got" = 2
t 0 "git before 2.36: and names it, made" grep -qF "git worktree at '$wo', made (check what it holds before removing it with git worktree remove)" "$tmp/trip.err"
t 1 "git before 2.36: with no command line" cmdline
git worktree remove --force "$wo"
old snap w; git worktree add -q --detach .worktrees/88 >/dev/null 2>&1
t 0 "git before 2.36: a git worktree in .worktrees/<id>/ is quiet" old trip w
git worktree remove --force .worktrees/88
old snap w; git worktree add -q --detach "$nl" >/dev/null 2>&1
old trip w 2>"$tmp/trip.err"; got=$?
t 0 "git before 2.36: a worktree at the root, a newline and more trips" test "$got" = 2
t 1 "git before 2.36: and gives no command line" cmdline
git worktree remove --force "$nl"
if [ -d .jj ]; then
  # A user's ui.color = "always" colours no path or name.
  printf '[ui]\ncolor = "always"\n' > "$tmp/jj.toml"; export JJ_CONFIG="$tmp/jj.toml"
  tripped 0 "tripwire: a jj workspace in .worktrees/<id>/ is quiet" 'jj workspace add --name 89 .worktrees/89'
  tripped 2 "tripwire: a jj workspace moved out of .worktrees/<id>/ and linked back trips" 'jj workspace add --name 85 .worktrees/85 && mv .worktrees/85 "$tmp/mv85" && ln -s "$tmp/mv85" .worktrees/85'
  jj workspace forget 85 >/dev/null 2>&1; rm -rf "$tmp/mv85" .worktrees/85
  wire snap w; (cd "$repo" && jj workspace add --name 'o t' "$wo") >/dev/null 2>&1
  wire trip w 2>"$tmp/trip.err"; got=$?
  t 0 "tripwire: a jj workspace outside trips" test "$got" = 2
  t 0 "tripwire: and names it, made, with the tool that removes it" grep -qF "jj workspace 'o t' at '$wo', made (check what it holds before removing it with jj workspace forget)" "$tmp/trip.err"
  t 1 "tripwire: and gives no command line" cmdline
  jj workspace forget 'o t' >/dev/null 2>&1
  # A jj workspace outside, renamed, was not made.
  wp=${wo%/*}/o2; jj workspace add --name o2 "$wp" >/dev/null 2>&1
  wire snap w; (cd "$wp" && jj workspace rename o3) >/dev/null 2>&1
  wire trip w 2>"$tmp/trip.err"; got=$?
  t 0 "tripwire: a jj workspace outside, renamed, trips" test "$got" = 2
  t 0 "tripwire: and is reported renamed, not made" grep -qF "jj workspace 'o3' at '$wp', moved, renamed or re-created (put it back with jj workspace rename, or check what it holds before removing it with jj workspace forget)" "$tmp/trip.err"
  t 1 "tripwire: with no command line" cmdline
  # One whose directory is gone when snap runs, which jj before 0.46 lists
  # with no path, put back by the command: not made.
  mv "$wp" "$tmp/o3"
  wire snap w; mv "$tmp/o3" "$wp"
  wire trip w 2>"$tmp/trip.err"
  t 1 "tripwire: a jj workspace put back where it was is not reported made" grep -qF "'$wp', made" "$tmp/trip.err"
  jj workspace forget o3 >/dev/null 2>&1; rm -rf "$wp"
  # One forgotten and added again elsewhere under its old name: no rename
  # puts that back.
  wp=${wo%/*}/o4; jj workspace add --name 79 .worktrees/79 >/dev/null 2>&1
  wire snap w; (jj workspace forget 79 && rm -rf .worktrees/79 && jj workspace add --name 79 "$wp") >/dev/null 2>&1
  wire trip w 2>"$tmp/trip.err"; got=$?
  t 0 "tripwire: a jj workspace re-created outside under its old name trips" test "$got" = 2
  t 0 "tripwire: and names no rename to put it back" grep -qF "jj workspace '79' at '$wp', moved, renamed or re-created (check what it holds before removing it with jj workspace forget)" "$tmp/trip.err"
  jj workspace forget 79 >/dev/null 2>&1; rm -rf "$wp"
  # A name or path holding a newline, a tab, a DEL or a C1 character is
  # reported escaped, so it reads as no other entry.
  odd=$'77\n/some/dir\tdefault\x7f\xc2\x85'
  wire snap w; (cd .worktrees/89 && jj workspace rename "$odd") >/dev/null 2>&1
  wire trip w 2>"$tmp/trip.err"; got=$?
  t 0 "tripwire: a jj workspace renamed to hold a newline and a tab trips" test "$got" = 2
  t 0 "tripwire: and is reported escaped and renamed" grep -qE "jj workspace '77\\\\134n/some/dir\\\\134tdefault\\\\177\\\\302\\\\205' at '[^']*', moved, renamed or re-created" "$tmp/trip.err"
  t 1 "tripwire: and gives no command line" cmdline
  nl="$R"$'\n'"$R/.worktrees/zz"; mkdir -p "${nl%/*}"
  wire snap w; jj workspace add --name zz "$nl" >/dev/null 2>&1
  wire trip w 2>"$tmp/trip.err"; got=$?
  t 0 "tripwire: a jj workspace at the root, a newline and a coddy path trips" test "$got" = 2
  t 1 "tripwire: and gives no command line" cmdline
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
# A pid is the owner's only while it is the process that started then: the
# fourth field, in UTC, is compared; the third is the local start 0.6.0
# wrote and compares, as its started prints it in C.
lstart=$(LC_ALL=C ps -o lstart= -p $$ | awk '{$1=$1; gsub(/ /,"_")} 1')
started=$(TZ=UTC0 LC_ALL=C ps -o lstart= -p $$ | awk '{$1=$1; gsub(/ /,"_"); print $0 "_UTC"}')
echo "sess-e $$ $lstart $started" > .git/coddy/other/owner
t 0 "issue.sh status owners: a running pid with the recorded start time is running" owns "other=sess-e (running)" sess-z 1
echo "sess-e $$ $lstart Thu_Jan_1_00:00:00_1970_UTC" > .git/coddy/other/owner
t 0 "issue.sh status owners: a running pid with another start time is gone" owns "other=sess-e (gone)"
t 1 "issue.sh status owners: and it is not me by that pid" owns "other=me" sess-z
PATH="$tmp/nops:$PATH" t 0 "issue.sh status owners: a start time ps cannot read counts as a match" owns "other=sess-e (running)" sess-z 1
echo "sess-e $$ Thu_Jan_1_00:00:00_1970" > .git/coddy/other/owner # 0.6.0's line: three fields, the third local
t 0 "issue.sh status owners: a line 0.6.0 wrote counts by its running pid alone" owns "other=sess-e (running)" sess-z 1
echo "sess-e $$ Thu_Jan_1_00:00:00_1970_UTC" > .git/coddy/other/owner
t 0 "issue.sh status owners: and so does a three-field line in UTC" owns "other=sess-e (running)" sess-z 1
t 0 "claim records the claiming process's start, local as 0.6.0 compares it, then UTC" grep -qx "sess-a $$ $lstart $started" .git/coddy/43/owner
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
IFS=$'\n' read -rd '' -a envs < <(sed -n 's/^      \([A-Z_]*\): .*/\1=\1/p' "$here/templates/coddy.yml")
check() { GH_LINKED="$1" env "${envs[@]}" "${@:2}" bash -e "$tmp/check.sh"; }
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
  { run create 44 feat/44-thing; run claim 44; echo y > .worktrees/44/a.txt; run push 44 "feat(44): thing" -- a.txt
    git clone -q -b main "$tmp/origin.git" "$tmp/merger"
    (cd "$tmp/merger" && git merge -q --no-ff -m "merge 44" origin/feat/44-thing && git push -q origin main)
    jj git fetch; jj -R .worktrees/42 new feat/42-thing main@origin; echo z > .worktrees/42/a.txt; } >/dev/null 2>&1
  was=$(git ls-remote origin refs/heads/feat/44-thing)
  t 0 "jj: push after merging main pushes the issue's branch" sh -c "CLAUDE_PROJECT_DIR='$repo' bash '$here/scripts/issue.sh' push 42 'chore(42): merge main' 2>/dev/null | grep -qx 'pushed: feat/42-thing'"
  t 0 "jj: that push left the merged branch alone" test "$(git ls-remote origin refs/heads/feat/44-thing)" = "$was"
fi

exit $fail
