#!/usr/bin/env bash
# Runs bin/coddy as any agent would: no CLAUDE_* variable set, its inputs
# from CODDY_ROOT, CODDY_SESSION, CODDY_PID and CODDY_AGENT_DIR, the config
# at .coddy.yml with .claude/coddy.yml as the fallback. The Claude Code shims
# under scripts/ and the full lifecycle are selftest.sh's.
# Usage: bash scripts/selftest-core.sh
set -u
unset $(compgen -v CLAUDE_) CODDY_AGENT_DIR 2>/dev/null
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"; fail=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export CODDY_ROOT="$repo" CODDY_SESSION=sess-a CODDY_PID=$$

# t <expected exit> <name> <command...>
t() {
  want=$1 name=$2; shift 2
  "$@" >/dev/null 2>&1; got=$?
  if [ "$got" = "$want" ]; then echo "ok   $name"; else echo "FAIL $name (exit $got, want $want)"; fail=1; fi
}
run() { "$here/bin/coddy" "$@"; } # by its exec bit, as PATH would run it
as() { CODDY_SESSION=$1 CODDY_PID=$2 run "${@:3}"; }
says() { "${@:2}" 2>&1 | grep -q "$1"; }
holds() { read -r a b _ < "$2" && [ "$a $b" = "$1" ]; }
# guard <path> [session]: the edit hook's payload; another session runs in another process
guard() { local s=${2-sess-a} p=1; [ "$s" != sess-a ] || p=$$; printf '{"session_id":"%s","tool_input":{"file_path":"%s"}}' "$s" "$1" | CODDY_PID=$p run guard; }
# asks <path>: guard exits 0 and asks the user, as hook JSON
asks() { out=$(guard "$1") && printf %s "$out" | jq -e '.hookSpecificOutput | .hookEventName == "PreToolUse" and .permissionDecision == "ask" and (.permissionDecisionReason | contains(".coddy.yml"))'; }
wire() { printf '{"tool_use_id":"%s"}' "$2" | run "$1"; }
tripped() { wire snap w; (cd "$repo" && eval "$3") >/dev/null 2>&1; t "$1" "$2" wire trip w; }
# report <name> <shell snippet>: as tripped, with trip's exit in $r and its report in $out
report() { wire snap w; (cd "$repo" && eval "$2") >/dev/null 2>&1; out=$(wire trip w 2>&1); r=$?; t 0 "$1" test "$r" = 2; }
snapfile="${TMPDIR:-/tmp}/coddy-snap-$(printf %s "$repo" | cksum | cut -d' ' -f1)-w"
# rooted <dir> [VAR=value...]: status run from that directory prints the project root
rooted() { d=$1; shift; (cd "$d" && env "$@" "$here/bin/coddy" status | grep -qx "root: $repo"); }
# A PATH with everything the guard needs but jq.
mkdir "$tmp/nojq"; for x in bash sh sed awk cat grep git cmp ps sort comm tr cut cksum mkdir cp rm head; do p=$(command -v "$x") && ln -s "$p" "$tmp/nojq/$x"; done

git init -q --bare "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$repo" 2>/dev/null
cd "$repo" || exit 1
git checkout -q -b main; echo hi > README.md; git add -A; git commit -q -m init; git push -q -u origin main
mkdir .claude sub

t 1 "the core reads no CLAUDE_ variable" grep -q CLAUDE_ "$here/bin/coddy"
t 0 "root: from CODDY_ROOT" rooted /
t 0 "root: from the working directory without CODDY_ROOT" rooted "$repo" -u CODDY_ROOT
t 0 "root: from a subdirectory without CODDY_ROOT" rooted "$repo/sub" -u CODDY_ROOT
t 0 "config: NOT_ONBOARDED before onboarding" says '^NOT_ONBOARDED$' run config
t 0 "status: no config before onboarding" says '^config: none$' run status
t 0 "detect: no config" says '^config: none$' run detect
t 0 "detect: no legacy config" says '^legacy_config: none$' run detect
t 0 "guard allows everything before onboarding" guard "$repo/README.md"
t 0 "guard asks nothing for .coddy.yml before onboarding" test -z "$(guard "$repo/.coddy.yml")"
t 2 "trip without a snapshot trips before onboarding too: snap writes one before every command" wire trip none
tripped 0 "before onboarding: a shell write to the main checkout is quiet" 'echo x > stray.txt'; rm stray.txt
t 1 "before onboarding: snap made nothing under .git" test -e .git/coddy

tripped 0 "onboarding: the command that writes the config is let through" 'printf "tracker: github\nworktree: git\ndefault_branch: main\nverify: test -f ok.txt\n" > .claude/coddy.yml'
t 0 "onboarding: and the config stands" test -f .claude/coddy.yml
t 0 "config: the legacy file is read when it is the only one" says '^worktree: git$' run config
t 0 "status names the legacy file" says '^config: .claude/coddy.yml$' run status
t 0 "detect: config present with the legacy file alone" says '^config: present$' run detect
t 0 "detect: and reports it as legacy" says '^legacy_config: present$' run detect
printf 'tracker: github\nworktree: git\ndefault_branch: main\nverify: test -f ok.txt\nroadmap: R.md\n' > .coddy.yml
t 0 "config: .coddy.yml is read before the legacy file" says '^roadmap: R.md$' run config
t 0 "status names .coddy.yml" says '^config: .coddy.yml$' run status
rm .claude/coddy.yml
t 0 "config: .coddy.yml alone" says '^roadmap: R.md$' run config
t 0 "detect: no legacy config next to .coddy.yml" says '^legacy_config: none$' run detect
t 0 "detect: .coddy.yml is not ignored" says '^config_ignored: no$' run detect
echo .coddy.yml >> .git/info/exclude
t 0 "detect: .coddy.yml is ignored once excluded" says '^config_ignored: yes$' run detect

# Editing .coddy.yml is for the user to allow, in both guard modes; without
# jq the guard cannot tell which path is edited and fails closed.
t 0 "guard asks on .coddy.yml" asks "$repo/.coddy.yml"
for p in "$repo/./.coddy.yml" "$repo//.coddy.yml" "$repo/sub/../.coddy.yml" "$repo/.CODDY.YML" .coddy.yml; do t 0 "guard asks on .coddy.yml spelled $p" asks "$p"; done
t 2 "guard blocks the main checkout" guard "$repo/README.md"
PATH="$tmp/nojq" t 2 "guard without jq fails closed" guard "$repo/.coddy.yml"
echo 'guard: warn' >> .coddy.yml
t 0 "warn: guard still asks on .coddy.yml" asks "$repo/.coddy.yml"
t 0 "warn: and spelled through .." asks "$repo/sub/../.coddy.yml"
t 0 "warn: guard lets the main checkout through" guard "$repo/README.md"
PATH="$tmp/nojq" t 2 "warn: guard without jq fails closed" guard "$repo/.coddy.yml"
sed -i.bak '/^guard:/d' .coddy.yml && rm .coddy.yml.bak
wire snap flow

# The config lock holds both paths: .coddy.yml is restored, and one created
# while .claude/coddy.yml was the live config is removed, so it cannot shadow it.
cp .coddy.yml "$tmp/conf.orig"
same() { cmp -s "$repo/$1" "$tmp/conf.orig"; }
tripped 2 "config: deleting .coddy.yml trips" 'rm .coddy.yml'
t 0 "config: restored after the deletion" same .coddy.yml
tripped 2 "config: rewriting .coddy.yml trips" 'echo "verify: true" >> .coddy.yml'
t 0 "config: restored after the rewrite" same .coddy.yml
t 0 "config: that report names the file" says 'changed .coddy.yml' sh -c "cd '$repo' && printf '{\"tool_use_id\":\"w\"}' | '$here/bin/coddy' snap && echo x >> .coddy.yml && printf '{\"tool_use_id\":\"w\"}' | '$here/bin/coddy' trip"
tripped 2 "config: a link in its place trips, the same content behind it" 'cp .coddy.yml "$tmp/else" && ln -sf "$tmp/else" .coddy.yml'
t 1 "config: and the link is gone" test -L .coddy.yml
t 0 "config: a file with its content back" same .coddy.yml
tripped 2 "config: a directory in its place trips" 'rm .coddy.yml && mkdir .coddy.yml'
t 0 "config: and the file is back" same .coddy.yml
# A config the user keeps as a link is not a change; retargeting the link,
# or writing the file behind it, is, and what comes back is a plain file.
mv .coddy.yml "$tmp/linked"; ln -s "$tmp/linked" .coddy.yml
tripped 0 "config: a config that was a link already is left alone" 'true'
t 0 "config: and is still that link" test -L .coddy.yml
tripped 2 "config: retargeting the link trips, the same content behind it" 'ln -sf "$tmp/else" .coddy.yml'
t 1 "config: and the link is gone" test -L .coddy.yml
t 0 "config: a plain file with its content back" same .coddy.yml
ln -sf "$tmp/linked" .coddy.yml
tripped 2 "config: writing the file behind the link trips" 'echo "verify: true" >> "$tmp/linked"'
t 1 "config: and the link is gone" test -L .coddy.yml
t 0 "config: a plain file with its content back" same .coddy.yml
# A restore the file system refuses is reported as such, with its copy kept.
if [ "$(id -u)" != 0 ]; then
  copy="$snapfile..coddy.yml"
  wire snap w; rm .coddy.yml; chmod a-w .; out=$(wire trip w 2>&1); r=$?; chmod u+w .
  t 0 "config: a restore the directory refuses still trips" test "$r" = 2
  t 0 "config: and says the file could not be put back" grep -q 'could not be put back' <<<"$out"
  t 0 "config: keeping its copy" cmp -s "$copy" "$tmp/conf.orig"
  cp "$tmp/conf.orig" .coddy.yml; rm -f "$copy"
fi
mv .coddy.yml .claude/coddy.yml
tripped 2 "config: a .coddy.yml created next to the live legacy file trips" 'cp .claude/coddy.yml .coddy.yml'
t 1 "config: and is removed" test -e .coddy.yml
t 0 "config: the legacy file stands" same .claude/coddy.yml
ln -s ../.coddy.yml .claude/cfg
CODDY_AGENT_DIR=.claude t 0 "guard asks on a dangling link to .coddy.yml from the agent dir while the legacy file is live" asks "$repo/.claude/cfg"
rm .claude/cfg
ln -s ../.coddy.yml .claude/c10; for i in 9 8 7 6 5 4 3 2 1; do ln -s "c$((i+1))" ".claude/c$i"; done
CODDY_AGENT_DIR=.claude t 0 "guard asks through a dangling chain of ten links" asks "$repo/.claude/c1"
rm .claude/c[0-9]*
tripped 2 "config: deleting the legacy file trips" 'rm .claude/coddy.yml'
t 0 "config: the legacy file is restored" same .claude/coddy.yml
# Once .coddy.yml is live the legacy file is ignored, so the lock lets it go.
# .claude is the agent dir here, as from the shims, so the tripwire skips it too.
cp .claude/coddy.yml .coddy.yml
CODDY_AGENT_DIR=.claude tripped 0 "config: changing the legacy file next to a live .coddy.yml is quiet" 'echo "verify: true" >> .claude/coddy.yml'
t 0 "config: and the change stands" grep -q '^verify: true$' .claude/coddy.yml
CODDY_AGENT_DIR=.claude tripped 0 "config: deleting the legacy file next to a live .coddy.yml is quiet" 'rm .claude/coddy.yml'
t 1 "config: and it is not restored" test -e .claude/coddy.yml
# A file git cannot read in its place is a change like any other.
report "config: an unreadable file in its place trips" 'echo "guard: warn" > .coddy.yml && chmod 000 .coddy.yml'
t 0 "config: and is restored" same .coddy.yml
# No change from git stands on its own: a commit made here, a checkout of
# the committed copy over a changed one, or a pull of a shared config is
# put back, since nothing a shell command cannot write tells it from a
# forged one, and the report sends the user to /coddy:config, which reads
# the accepted copy from HEAD. The restored file then differs from HEAD,
# which the fingerprint does not report as the command's change.
git add -f .coddy.yml && git commit -q -m conf && git push -q origin main
tripped 2 "config: a change committed here in the same command trips" 'echo "guard: warn" >> .coddy.yml && git commit -qam warn'
t 0 "config: and is restored" same .coddy.yml
git reset -q --hard origin/main
echo 'roadmap: X.md' >> .coddy.yml
tripped 2 "config: a checkout of the committed copy over a changed one trips" 'git checkout -- .coddy.yml'
t 0 "config: and the changed one is put back" grep -q '^roadmap: X.md$' .coddy.yml
git checkout -q -- .coddy.yml
git clone -q -b main "$tmp/origin.git" "$tmp/mate" 2>/dev/null
(cd "$tmp/mate" && echo 'roadmap: Y.md' >> .coddy.yml && git commit -q -am up && git push -q origin HEAD:main)
report "config: a pull of a changed shared config trips" 'git fetch -q origin && git merge -q --ff-only origin/main'
t 0 "config: and is put back" same .coddy.yml
t 0 "config: and the report says /coddy:config accepts it" grep -q 'accept it with /coddy:config' <<<"$out"
t 1 "config: and does not call the restored file the command's change" grep -q 'changed the main checkout' <<<"$out"
t 0 "config: and HEAD holds the pulled copy for /coddy:config to read" sh -c "git show HEAD:.coddy.yml | grep -q '^roadmap: Y.md$'"
tripped 0 "config: the restored file is quiet afterwards" 'true'
git reset -q --hard HEAD~1 # back to before the pull, so the config matches HEAD and the flow snapshot again
# TMPDIR is the command's to write too, so trip opens nothing there that is
# not a plain file: a FIFO planted at the snapshot's link record would hang it.
# bounded <expected exit> <name>: trip in the background, failed and killed after 5s
bounded() { wire trip w >/dev/null 2>&1 & tp=$!; i=0; while kill -0 $tp 2>/dev/null && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
  if kill -0 $tp 2>/dev/null; then kill $tp 2>/dev/null; pkill -f "$snapfile" 2>/dev/null; wait $tp 2>/dev/null; r=124; else wait $tp; r=$?; fi; t 0 "$2" test "$r" = "$1"; }
wire snap w; echo "guard: warn" >> .coddy.yml; mkfifo "$snapfile..coddy.yml.link"
bounded 2 "config: a FIFO planted at the link record does not hang trip"
t 0 "config: and the change is restored" same .coddy.yml
t 1 "config: and the snapshot is cleaned up, the FIFO with it" test -e "$snapfile..coddy.yml.link"
# The snapshot is what trip checks a command against, so a command that
# removes it, or its copy of the config, is rejected; a project that left the
# workflow by hand, its config gone and .git/coddy kept, is quiet.
report "snapshot: a command that removes it trips" 'rm -f "$snapfile"'
t 0 "snapshot: and the report names it" grep -q "$snapfile" <<<"$out"
tripped 2 "snapshot: so does one that removes it with the config, .git/coddy left behind" 'rm -f "$snapfile" .coddy.yml'
git checkout -q -- .coddy.yml
tripped 2 "snapshot: so does one that removes its copy of the config" 'rm -f "$snapfile".*'
# Each path's kind is recorded, present or not, so a lost copy is not read
# as a path that was absent: a weakened legacy file planted next to the live
# .coddy.yml is let go, and a command that then removed .coddy.yml with its
# copy alone would leave the planted one live.
kinds() { wire snap w && [ "$(cat "$snapfile..coddy.yml.kind")" = "$1" ] && [ "$(cat "$snapfile..claude_coddy.yml.kind")" = "$2" ]; }
t 0 "snapshot: records .coddy.yml as a file and the legacy path absent" kinds file absent
CODDY_AGENT_DIR=.claude tripped 0 "snapshot: a legacy file planted next to the live .coddy.yml is let go" 'echo "guard: warn" > .claude/coddy.yml'
report "snapshot: removing .coddy.yml with its copy alone then trips" 'rm -f "$snapfile..coddy.yml" .coddy.yml'
t 0 "snapshot: and the report names the snapshot" grep -q "$snapfile" <<<"$out"
git checkout -q -- .coddy.yml; rm .claude/coddy.yml
mv .coddy.yml .claude/coddy.yml
t 0 "snapshot: records .coddy.yml absent and the legacy file" kinds absent file
tripped 2 "snapshot: removing the legacy file's copy while it is the live one trips" 'rm -f "$snapfile..claude_coddy.yml"'
mkdir .coddy.yml
t 0 "snapshot: records a directory at .coddy.yml" kinds dir file
tripped 0 "config: a directory at .coddy.yml from before the command is left alone" 'true'
t 0 "config: and stands" test -d .coddy.yml
rmdir .coddy.yml; mkfifo .coddy.yml
t 0 "snapshot: records a FIFO at .coddy.yml" kinds fifo file
rm .coddy.yml; ln -s nowhere .coddy.yml
t 0 "snapshot: records a dangling link at .coddy.yml as other" kinds other file
t 0 "snapshot: with its target" test "$(cat "$snapfile..coddy.yml.link")" = nowhere
rm .coddy.yml; mv .claude/coddy.yml .coddy.yml
mv .coddy.yml "$tmp/aside"
tripped 0 "snapshot: quiet once the config is gone, .git/coddy kept" 'true'
mv "$tmp/aside" .coddy.yml
t 0 "snapshot: a tool_use_id that is not a plain word names the shared snapshot" sh -c "printf '{\"tool_use_id\":\"../x\"}' | '$here/bin/coddy' snap && test -f '${snapfile%-w}-shared'"
rm -f "${snapfile%-w}-shared"*

# No agent-dir rules without CODDY_AGENT_DIR; with it, its directory is free
# and its worktrees/ held to the lock.
t 2 "no agent dir: .claude/ is the main checkout" guard "$repo/.claude/notes.md"
t 2 "no agent dir: so is .claude/worktrees/" guard "$repo/.claude/worktrees/5/a.txt"
tripped 2 "no agent dir: a change under .claude/ trips" 'echo x > .claude/notes.md'; rm .claude/notes.md
export CODDY_AGENT_DIR=.codex
t 0 "agent dir: edits under it are allowed" guard "$repo/.codex/notes.md"
t 2 "agent dir: its worktrees/ is held to the lock" guard "$repo/.codex/worktrees/5/a.txt"
t 0 "agent dir: that rejection names the claim" says "issue 5 is not In Progress" guard "$repo/.codex/worktrees/5/a.txt"
t 2 "agent dir: .claude/ is not it" guard "$repo/.claude/notes.md"
tripped 0 "agent dir: a change under it is quiet" 'mkdir -p .codex && echo x > .codex/notes.md'; rm -r .codex
unset CODDY_AGENT_DIR

# start is create, ship is verify then push; the aliases stay.
t 0 "start makes the worktree" says 'created: .worktrees/1 on feat/1-thing' run start 1 feat/1-thing
t 0 "create is its alias" says 'exists: .worktrees/1' run create 1 feat/1-thing
t 0 "root: from inside an issue worktree without CODDY_ROOT" rooted "$repo/.worktrees/1" -u CODDY_ROOT
t 0 "root: from CODDY_ROOT naming a worktree" rooted / CODDY_ROOT="$repo/.worktrees/1"
t 1 "ship refuses before the claim" run ship 1
t 0 "claim" run claim 1
t 0 "the lock names CODDY_SESSION and CODDY_PID" holds "sess-a $$" .git/coddy/1/owner
t 1 "another session's claim is refused" as sess-b 1 claim 1
t 0 "that refusal names the owner" says "session sess-a" as sess-b 1 claim 1
t 0 "the owner's process re-claims under another session id" as sess-b $$ claim 1
t 0 "and the lock followed it" holds "sess-b $$" .git/coddy/1/owner
run claim 1 >/dev/null 2>&1
t 0 "guard allows the owner's edit" guard "$repo/.worktrees/1/a.txt"
ln -s ../../.coddy.yml .worktrees/1/cfg; ln .coddy.yml .worktrees/1/hard
t 0 "guard asks on .coddy.yml through a symlink in the owner's worktree" asks "$repo/.worktrees/1/cfg"
t 0 "guard asks on .coddy.yml through a hard link in the owner's worktree" asks "$repo/.worktrees/1/hard"
rm .worktrees/1/cfg .worktrees/1/hard
t 2 "guard blocks another session's edit" guard "$repo/.worktrees/1/a.txt" sess-b
# The Claude Code shims take their inputs from CLAUDE_* alone: an inherited
# CODDY_* value, however hostile, is ignored.
shim() { CLAUDE_PROJECT_DIR=$repo CODDY_ROOT=/ CODDY_AGENT_DIR=src CODDY_SESSION=sess-a CODDY_PID=$$ bash "$here/scripts/issue.sh" "$@"; }
shimguard() { printf '{"session_id":"sess-a","tool_input":{"file_path":"%s"}}' "$1" | shim guard; }
t 0 "shim: the root is CLAUDE_PROJECT_DIR, not an inherited CODDY_ROOT" says "^root: $repo\$" shim status
t 0 "shim: the session and pid are CLAUDE_*'s, so the owner's inherited ones do not make the claim mine" says '^owners: 1=sess-a (running)' shim status
t 2 "shim: the agent dir is .claude, not an inherited CODDY_AGENT_DIR" shimguard "$repo/src/x.c"
t 0 "shim: and .claude/ is free" shimguard "$repo/.claude/n.md"
# GIT_* from the environment (a settings env reaches the hooks) could move
# root resolution to another repository, where no config is: dropped.
GIT_DIR="$tmp/origin.git" t 0 "shim: GIT_DIR in the environment does not move the root" says "^root: $repo\$" shim status
GIT_DIR="$tmp/origin.git" t 2 "shim: so the guard still blocks the main checkout" shimguard "$repo/README.md"
shimv() { CLAUDE_PROJECT_DIR=$repo CODDY_ROOT=/ bash "$here/scripts/$1.sh"; }
t 0 "shim: config.sh takes the root from CLAUDE_PROJECT_DIR too" says '^tracker: github$' shimv config
t 0 "shim: so does detect.sh" says '^config: present$' shimv detect
GIT_DIR="$tmp/origin.git" t 0 "shim: config.sh drops GIT_DIR too" says '^tracker: github$' shimv config
GIT_DIR="$tmp/origin.git" t 0 "shim: so does detect.sh" says '^config: present$' shimv detect
CODDY_AGENT_DIR=.codex t 0 "agent dir: its worktree of a claimed issue is editable" guard "$repo/.codex/worktrees/1/a.txt"
echo x > .worktrees/1/a.txt
t 1 "push refuses another session" as sess-b 1 push 1 "feat(1): thing"
t 1 "ship stops on a failing verify" run ship 1 "feat(1): thing"
t 0 "and says so" says "verify" run ship 1 "feat(1): thing"
t 2 "and pushed nothing" git ls-remote --exit-code origin refs/heads/feat/1-thing
t 0 "push alone pushes without verify" says 'pushed: feat/1-thing' run push 1 "feat(1): thing"
t 0 "the branch reached the remote" git ls-remote --exit-code origin refs/heads/feat/1-thing
# The identity in GIT_AUTHOR_* and GIT_COMMITTER_* is kept by the shim (no
# git config holds one under this HOME), as the discovery variables are not.
echo y > .worktrees/1/b.txt
HOME="$tmp" GIT_DIR="$tmp/origin.git" t 0 "shim: push commits with the environment's identity, GIT_DIR dropped" says 'pushed: feat/1-thing' shim push 1 "feat(1): more"
was=$(git ls-remote origin refs/heads/feat/1-thing)
echo ok > .worktrees/1/ok.txt
t 0 "verify passes now" run verify 1
t 1 "ship refuses another session" as sess-b 1 ship 1 "feat(1): ok"
t 0 "ship verifies then pushes" says 'pushed: feat/1-thing' run ship 1 "feat(1): ok"
t 1 "ship moved the branch on the remote" test "$(git ls-remote origin refs/heads/feat/1-thing)" = "$was"
t 0 "status lists the claimed issue as mine" says '^owners: 1=me' run status
t 0 "sweep keeps the unmerged worktree" sh -c "'$here/bin/coddy' sweep; test -d '$repo/.worktrees/1'"
t 0 "the whole flow left the main checkout alone" wire trip flow

exit $fail
