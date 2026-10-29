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
# rooted <dir> [VAR=value...]: status (or $verb) run from that directory prints the project root
rooted() { d=$1; shift; (cd "$d" && env "$@" "$here/bin/coddy" "${verb-status}" | grep -qx "root: $repo"); }
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
# A CDPATH would send the root's cd .git/.. elsewhere and print there: status
# from the main checkout reads as it does without one.
cdpath() { rooted "$repo" -u CODDY_ROOT CDPATH="$1" && (cd "$repo" && [ "$(env -u CODDY_ROOT CDPATH="$1" "$here/bin/coddy" status)" = "$(env -u CODDY_ROOT "$here/bin/coddy" status)" ]); }
git init -q "$tmp/other"
t 0 "root: a CDPATH of . prints no second line" cdpath .
t 0 "root: a CDPATH holding another repository does not move it" cdpath "$tmp/other"
# onboard writes every path under the root, so detect prints it as status does:
# a session opened in a subdirectory would otherwise write there.
verb=detect t 0 "detect: root, as status prints it" rooted /
verb=detect t 0 "detect: root from a subdirectory without CODDY_ROOT" rooted "$repo/sub" -u CODDY_ROOT
t 0 "config: NOT_ONBOARDED before onboarding" says '^NOT_ONBOARDED$' run config
t 0 "status: no config before onboarding" says '^config: none$' run status
t 0 "detect: no config" says '^config: none$' run detect
t 0 "detect: no legacy config" says '^legacy_config: none$' run detect
# What is at AGENTS.md, so onboard writes its block into a plain file alone: a
# link reads as one whether or not it reaches a file, never as the file behind it.
t 0 "detect: no AGENTS.md" says '^agents_md: absent$' run detect
echo '# x' > AGENTS.md; t 0 "detect: a plain AGENTS.md" says '^agents_md: file$' run detect
rm AGENTS.md; ln -s README.md AGENTS.md; t 0 "detect: a link to a file at AGENTS.md" says '^agents_md: symlink$' run detect
rm AGENTS.md; ln -s nowhere AGENTS.md; t 0 "detect: a dangling link at AGENTS.md" says '^agents_md: symlink$' run detect
rm AGENTS.md; mkdir AGENTS.md; t 0 "detect: a directory at AGENTS.md" says '^agents_md: dir$' run detect
rmdir AGENTS.md
# What is at the PR check's path, the same way: a link at .github, at
# .github/workflows or at the workflow itself reads as symlink.
w=.github/workflows/coddy.yml
t 0 "detect: no PR check" says '^pr_check: none$' run detect
mkdir -p .github/workflows; : > $w; t 0 "detect: a plain PR check" says '^pr_check: present$' run detect
rm $w; ln -s ../../README.md $w; t 0 "detect: a link to a file at the PR check" says '^pr_check: symlink$' run detect
rm $w; ln -s nowhere $w; t 0 "detect: a dangling link at the PR check" says '^pr_check: symlink$' run detect
rm $w; mkdir $w; t 0 "detect: a directory at the PR check" says '^pr_check: dir$' run detect
rmdir $w; rmdir .github/workflows; ln -s . .github/workflows; t 0 "detect: a link at .github/workflows" says '^pr_check: symlink$' run detect
rm -r .github; ln -s sub .github; t 0 "detect: a link at .github" says '^pr_check: symlink$' run detect
rm .github
# The remote without its userinfo, on one line: a token in the URL, or a
# second line, would reach onboard's prompt.
git remote set-url origin 'https://u:p@ss@host/x.git'; t 0 "detect: a remote's userinfo is dropped" says '^remote: https://host/x.git$' run detect
t 1 "detect: no part of the password is printed" says 'p@ss' run detect
git remote set-url origin 'ssh://tok@host/x.git'; t 0 "detect: a user alone is dropped" says '^remote: ssh://host/x.git$' run detect
git remote set-url origin 'git@host:o/x.git'; t 0 "detect: an scp-style remote is kept" says '^remote: git@host:o/x.git$' run detect
git config remote.origin.url "$(printf 'https://host/x.git\nforged: yes')"; t 1 "detect: a remote prints one line" says '^forged: yes$' run detect
git remote set-url origin "$tmp/origin.git"
# Where this runs and what installs here, for onboard's install commands.
case "$(uname -s)" in Darwin) os=macos ;; Linux) os=linux ;; *) os=unknown ;; esac
t 0 "detect: os names the platform" says "^os: $os$" run detect
PATH="$tmp/nojq" t 0 "detect: os is unknown without uname" says '^os: unknown$' run detect
t 0 "detect: pkg names one package manager or none" says '^pkg: [a-z-]*$' run detect
PATH="$tmp/nojq" t 0 "detect: pkg is none with no package manager on PATH" says '^pkg: none$' run detect
# detect's output is the prompt, so a value read from the repository holds
# no line break: a package script or a go module directory named with one
# would otherwise add a root: line of its own, which every onboard path is spelled from.
oneroot() { [ "$(run detect | grep -c '^root: ')" = 1 ] && run detect | grep -qx "root: $repo"; }
printf '{"scripts": {"a\\nroot: /attacker\\nconfig": "x", "test": "y"}}' > package.json
t 0 "detect: a package script named with a newline adds no line" oneroot
t 0 "detect: and the scripts are listed on their own line" says '^package_scripts: a root: /attacker config test $' run detect
rm package.json
mkdir "$(printf 'm\rroot: x')"; : > "$(printf 'm\rroot: x')/go.mod"
t 0 "detect: a go module directory named with a line break adds no line" oneroot
t 0 "detect: and the modules are listed on their own line" says '^go_modules: m root: x/go.mod $' run detect
rm -r m*
git commit -q --allow-empty --cleanup=verbatim -m "$(printf 'subject\rroot: /attacker')"
t 0 "detect: a commit subject with a carriage return is listed" says '^  subject root: /attacker$' run detect
t 1 "detect: and no carriage return reaches the prompt" says "$(printf '\r')" run detect
git reset -q --hard HEAD~1
# onboard's writes outside the agent dir go through the core, so the skill's
# command text holds no path and no wildcard: exclude puts the answers
# directory or the config into git's info/exclude once, and forget answers
# removes the answers file alone, once the config is written.
t 1 "exclude: an unknown target is refused" run exclude other
t 1 "exclude answers: needs the agent dir" run exclude answers
t 0 "exclude answers: and says so" says CODDY_AGENT_DIR run exclude answers
rm -r .git/info
CODDY_AGENT_DIR=.claude t 0 "exclude answers: appends the agent's coddy dir, making info/ when it is missing" says '^excluded: .claude/coddy$' run exclude answers
t 0 "exclude answers: the line is in info/exclude" grep -qx '.claude/coddy' .git/info/exclude
t 0 "exclude answers: and matches the answers file before its directory exists" git check-ignore -q .claude/coddy/onboard-answers.json
CODDY_AGENT_DIR=.claude t 0 "exclude answers: is a no-op the second time" says '^ignored already: .claude/coddy$' run exclude answers
CODDY_AGENT_DIR=.claude t 0 "exclude answers: from a subdirectory too" sh -c "cd '$repo/sub' && env -u CODDY_ROOT '$here/bin/coddy' exclude answers | grep -qx 'ignored already: .claude/coddy'"
t 0 "exclude answers: one line" test "$(grep -cx '.claude/coddy' .git/info/exclude)" = 1
CODDY_AGENT_DIR=.claude t 1 "forget answers: refuses before onboarding" run forget answers
CODDY_AGENT_DIR=.claude t 0 "forget answers: and says so" says NOT_ONBOARDED run forget answers
t 0 "guard allows everything before onboarding" guard "$repo/README.md"
t 0 "guard asks nothing for .coddy.yml before onboarding" test -z "$(guard "$repo/.coddy.yml")"
t 2 "trip without a snapshot trips before onboarding too: snap writes one before every command" wire trip none
# onboard installs jq inside one shell command, so snap runs without it and
# trip with it: the snapshot's name must not depend on jq.
PATH="$tmp/nojq" wire snap w; t 0 "before onboarding: snap without jq and trip with it name the same snapshot" wire trip w
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
printf '*.log' >> .git/info/exclude # a last line without its newline
t 0 "exclude config: appends .coddy.yml" says '^excluded: .coddy.yml$' run exclude config
t 0 "exclude config: on a line of its own, the last line left whole" grep -qx '\*\.log' .git/info/exclude
t 0 "detect: .coddy.yml is ignored once excluded" says '^config_ignored: yes$' run detect
t 0 "exclude config: is a no-op the second time" says '^ignored already: .coddy.yml$' run exclude config
t 0 "exclude config: one line" test "$(grep -cx '.coddy.yml' .git/info/exclude)" = 1
mkdir -p .claude/coddy/backup; echo '{}' > .claude/coddy/onboard-answers.json; echo x > .claude/coddy/backup/x
t 1 "forget answers: needs the agent dir" run forget answers
t 1 "forget: an unknown target is refused" env CODDY_AGENT_DIR=.claude "$here/bin/coddy" forget other
CODDY_AGENT_DIR=.claude t 0 "forget answers: removes the answers file once onboarded" says '^removed: .claude/coddy/onboard-answers.json$' run forget answers
t 1 "forget answers: and it is gone" test -e .claude/coddy/onboard-answers.json
t 0 "forget answers: the backups stay" test -f .claude/coddy/backup/x
CODDY_AGENT_DIR=.claude t 0 "forget answers: is quiet when the file is gone already" run forget answers
rm -r .claude/coddy
# migrate prints the config brought up to the current version and writes
# nothing; /coddy:migrate writes it. No version is 0, wherever the file is.
mv .coddy.yml "$tmp/live.yml"
printf '# team config\ntracker: github   # the tracker\nworktree: git\n\ndefault_branch: main\nverify: test -f ok.txt\n' > .claude/coddy.yml
{ echo 'version: 2'; cat .claude/coddy.yml; } > "$tmp/v1.yml"
cp .claude/coddy.yml "$tmp/v0.yml"
t 0 "migrate: a legacy file without version is 0" says '^from: 0$' run migrate
t 0 "migrate: says it adds the version" says '^changed: add version: 1$' run migrate
t 0 "migrate: and moves the legacy file" says '^changed: move .claude/coddy.yml -> .coddy.yml$' run migrate
t 0 "migrate: says an untracked legacy file is untracked" says '^tracked: no$' run migrate
git add -f .claude/coddy.yml
t 0 "migrate: and a tracked one tracked" says '^tracked: yes$' run migrate
git rm -q --cached .claude/coddy.yml
printf 'version: 0\r\ntracker: github\r\n' > .claude/coddy.yml
t 0 "migrate: a CRLF config reads its version" says '^from: 0$' run migrate
cp "$tmp/v0.yml" .claude/coddy.yml
t 0 "migrate: the file after --- is the expected v2, comments kept" sh -c "'$here/bin/coddy' migrate | sed '1,/^---\$/d' | cmp -s - '$tmp/v1.yml'"
t 0 "migrate: writes nothing" cmp -s .claude/coddy.yml "$tmp/v0.yml"
t 1 "migrate: and makes no .coddy.yml" test -e .coddy.yml
cp "$tmp/v1.yml" .coddy.yml
t 0 "migrate: a current config next to a leftover legacy file says remove" says '^changed: remove .claude/coddy.yml$' run migrate
t 1 "migrate: and prints no file" says '^---$' run migrate
rm .claude/coddy.yml
t 0 "migrate: a v2 config is current" says '^to: 2$' run migrate
t 1 "migrate: and prints no change" says '^changed:' run migrate
t 1 "migrate: nor a file" says '^---$' run migrate
printf 'version: 99\ntracker: github\n' > .coddy.yml
t 1 "migrate: a version above the current one is refused" run migrate
t 0 "migrate: naming the plugin update" says 'update the coddy plugin' run migrate
printf 'version: 12345678901234567890\ntracker: github\n' > .coddy.yml
t 0 "migrate: a version too long for bash is refused as newer" says 'update the coddy plugin' run migrate
t 1 "migrate: with no bash error" says 'integer' run migrate
printf 'version: 1 \ntracker: github\n' > .coddy.yml
t 0 "migrate: a version with trailing whitespace is read" says '^from: 1$' run migrate
t 0 "migrate: a v1 config moves to 2" says '^to: 2$' run migrate
t 0 "migrate: says what step 2 changes" says '^changed: add version: 2, and worktree: jj when no worktree key is set$' run migrate
t 1 "migrate: and runs no step 1" says '^changed: add version: 1$' run migrate
printf 'version: 1\ntracker: github\n' > .coddy.yml; printf 'version: 2\nworktree: jj\ntracker: github\n' > "$tmp/want.yml"
t 0 "migrate: a v1 config without worktree keeps jj" sh -c "'$here/bin/coddy' migrate | sed '1,/^---\$/d' | cmp -s - '$tmp/want.yml'"
printf 'version: 1\ntracker: github\nworktree: git\n' > .coddy.yml; printf 'version: 2\ntracker: github\nworktree: git\n' > "$tmp/want.yml"
t 0 "migrate: a v1 config with worktree gets the version alone" sh -c "'$here/bin/coddy' migrate | sed '1,/^---\$/d' | cmp -s - '$tmp/want.yml'"
printf 'version: 1\ntracker: github\nworktree:   # jj | git\n' > .coddy.yml; printf 'version: 2\ntracker: github\nworktree: jj\n' > "$tmp/want.yml"
t 0 "migrate: an empty worktree key, read as jj before 2, becomes worktree: jj" sh -c "'$here/bin/coddy' migrate | sed '1,/^---\$/d' | cmp -s - '$tmp/want.yml'"
# after <file>: the file migrate prints after its first --- line is <file>
after() { "$here/bin/coddy" migrate | sed '1,/^---$/d' | cmp -s - "$1"; }
rm .coddy.yml
printf -- '---\ntracker: github\n' > .claude/coddy.yml; printf -- '---\nversion: 2\nworktree: jj\ntracker: github\n' > "$tmp/want.yml"
t 0 "migrate: a leading --- keeps version below it" after "$tmp/want.yml"
printf 'tracker: github\r\n' > .claude/coddy.yml; printf 'version: 2\r\nworktree: jj\r\ntracker: github\r\n' > "$tmp/want.yml"
t 0 "migrate: a CRLF config gets a CRLF version line" after "$tmp/want.yml"
printf 'tracker: github\n\n\n' > .claude/coddy.yml; printf 'version: 2\nworktree: jj\ntracker: github\n\n\n' > "$tmp/want.yml"
t 0 "migrate: trailing blank lines are kept" after "$tmp/want.yml"
cp "$tmp/v0.yml" .claude/coddy.yml
ln -s missing.yml .coddy.yml
t 1 "migrate: a dangling .coddy.yml link is refused" run migrate
t 1 "migrate: before any file" says '^---$' run migrate
rm .coddy.yml; ln -s .claude/coddy.yml .coddy.yml
t 1 "migrate: a .coddy.yml link to a file is refused" run migrate
rm .coddy.yml; mkdir .coddy.yml
t 1 "migrate: a .coddy.yml directory is refused" run migrate
rmdir .coddy.yml
mv .claude/coddy.yml "$tmp/legacy.yml"; ln -s "$tmp/legacy.yml" .claude/coddy.yml
t 1 "migrate: a legacy source that is a link is refused" run migrate
rm .claude/coddy.yml; cp "$tmp/v1.yml" .coddy.yml
for k in file link dir; do
  case $k in file) cp "$tmp/v0.yml" .claude/coddy.yml ;; link) ln -s "$tmp/legacy.yml" .claude/coddy.yml ;; dir) mkdir .claude/coddy.yml ;; esac
  t 0 "migrate: a leftover legacy $k says its kind" says "^legacy: $k\$" run migrate
  rm -r .claude/coddy.yml
done
mv "$tmp/live.yml" .coddy.yml

# Editing .coddy.yml is for the user to allow, in both guard modes; without
# jq the guard cannot tell which path is edited and fails closed.
t 0 "guard asks on .coddy.yml" asks "$repo/.coddy.yml"
for p in "$repo/./.coddy.yml" "$repo//.coddy.yml" "$repo/sub/../.coddy.yml" "$repo/.CODDY.YML" .coddy.yml; do t 0 "guard asks on .coddy.yml spelled $p" asks "$p"; done
# The Write tool collapses .. by name before it writes, so a .. after a link
# out of the project still lands on the root's .coddy.yml.
mkdir -p "$tmp/out/deep" && ln -s "$tmp/out/deep" lnk
t 0 "guard asks on .coddy.yml spelled through .. after a link out of the project" asks "$repo/lnk/../.coddy.yml"
t 2 "guard blocks the main checkout" guard "$repo/README.md"
PATH="$tmp/nojq" t 2 "guard without jq fails closed" guard "$repo/.coddy.yml"
echo 'guard: warn' >> .coddy.yml
t 0 "warn: guard still asks on .coddy.yml" asks "$repo/.coddy.yml"
t 0 "warn: and spelled through .." asks "$repo/sub/../.coddy.yml"
t 0 "warn: and through .. after a link out of the project" asks "$repo/lnk/../.coddy.yml"
rm lnk
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
# TMPDIR is the command's to write too: snap writes no record through a link
# a background command plants at its name once snap has cleared it, to a file
# or to nothing, and the snapshot is lost. A stub head, which cfg runs after
# the clearing, plants one at every name.
mkdir "$tmp/plant"
for v in "$tmp/victim" "$tmp/nothing"; do
  echo keep > "$tmp/victim"
  printf '#!/bin/sh\nfor n in "" .wt ..coddy.yml ..coddy.yml.kind ..coddy.yml.link ..claude_coddy.yml ..claude_coddy.yml.kind ..claude_coddy.yml.link; do ln -s "%s" "%s$n" 2>/dev/null; done\nexec "%s" "$@"\n' "$v" "$snapfile" "$(command -v head)" > "$tmp/plant/head"; chmod +x "$tmp/plant/head"
  PATH="$tmp/plant:$PATH" wire snap w 2>/dev/null
  t 0 "snapshot: a link planted at each name is not written through: ${v##*/}" test "$(cat "$tmp/victim")" = keep
  t 1 "snapshot: nor is its target made: ${v##*/}" test -e "$tmp/nothing"
  t 2 "snapshot: and trip reports it lost: ${v##*/}" wire trip w
  rm -f "$snapfile" "$snapfile".*
done
rm -r "$tmp/plant" "$tmp/victim"
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

# cfg drops a CRLF line's \r and trailing blanks: worktree: jj\r or jj<space> reads as jj, not as an unknown tool run as git.
cp .coddy.yml "$tmp/conf.yml"; printf 'version: 2\r\ntracker: github\r\nworktree: jj\r\ndefault_branch: main\r\n' > .coddy.yml
t 0 "cfg: a CRLF worktree: jj reads as jj" says 'jj' run start 9 feat/9-crlf
t 1 "cfg: so no git worktree is made" test -e .worktrees/9
printf 'version: 2\ntracker: github\nworktree: jj \t\ndefault_branch: main\n' > .coddy.yml
t 0 "cfg: a worktree: jj with trailing blanks reads as jj" says 'jj' run start 9 feat/9-blank
t 1 "cfg: so no git worktree is made for it" test -e .worktrees/9
cp "$tmp/conf.yml" .coddy.yml
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
# Claude Code hands the hooks the physical project dir, and a path may reach
# the project through a link: the guard reads a path as given and spelled
# physically against the physical root, the stricter winning, so neither
# spelling of the root or the path lets an edit through.
pr=$(cd "$repo" && pwd -P); ln -s "$repo" "$tmp/via"
ln -s ../../README.md .worktrees/1/rd; ln -s ../../sub .worktrees/1/d; ln -s d/../README.md .worktrees/1/dd
# spelled <root> <path prefix> <label>
spelled() {
  CODDY_ROOT=$1 t 2 "guard, $3: blocks the main checkout" guard "$2/README.md"
  CODDY_ROOT=$1 t 2 "guard, $3: blocks a new nested file in the main checkout" guard "$2/newdir/deep/a.txt"
  CODDY_ROOT=$1 t 2 "guard, $3: blocks an unclaimed worktree" guard "$2/.worktrees/7/a.txt"
  CODDY_ROOT=$1 t 2 "guard, $3: blocks another session's worktree" guard "$2/.worktrees/1/a.txt" sess-b
  CODDY_ROOT=$1 t 0 "guard, $3: allows the owner's worktree" guard "$2/.worktrees/1/a.txt"
  CODDY_ROOT=$1 CODDY_AGENT_DIR=.claude t 0 "guard, $3: allows the agent dir" guard "$2/.claude/x"
  CODDY_ROOT=$1 t 2 "guard, $3: blocks a link in the owner's worktree to the main checkout" guard "$2/.worktrees/1/rd"
  CODDY_ROOT=$1 t 2 "guard, $3: and one whose .. follows a link there" guard "$2/.worktrees/1/dd"
}
spelled "$pr" "$tmp/via" "physical root, path through a link"
spelled "$tmp/via" "$pr" "root through a link, physical path"
# macOS reaches its data volume through the /System/Volumes/Data firmlink
# too, which bash's pwd -P keeps: the root is found by identity, not by name.
fl="/System/Volumes/Data$pr"
if [ -d "$fl" ] && [ "$fl" -ef "$repo" ]; then
  spelled "$pr" "$fl" "physical root, path through the firmlink"
  spelled "$fl" "$pr" "root through the firmlink, physical path"
  mkdir -p .claude && mv .coddy.yml .claude/coddy.yml
  t 0 "guard asks on a .coddy.yml not made yet, spelled through the firmlink" asks "$fl/.coddy.yml"
  mv .claude/coddy.yml .coddy.yml
fi
rm .worktrees/1/rd .worktrees/1/d .worktrees/1/dd
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

# start installs git hooks that refuse a commit or push outside a claimed
# issue's branch, for people too; the flow above pushed through them.
hooks="$repo/.git/hooks/coddy"
t 0 "githook: start points core.hooksPath at the absolute hooks dir" test "$(git config core.hooksPath)" = "$hooks"
t 0 "githook: and writes both hooks executable" test -x "$hooks/pre-commit" -a -x "$hooks/pre-push"
# A verb run from stdin has no path of its own; start, whose hooks run coddy by it, says so.
t 0 "a verb runs from stdin" sh -c "bash -s state 1 < '$here/bin/coddy'"
# macOS ships bash 3.2 as /bin/bash (5.x elsewhere): every script must parse there, and a [!a-z] class must not pass upper case in a UTF-8 locale
if [ -x /bin/bash ]; then
  for f in "$here"/scripts/*.sh "$here/bin/coddy" "$here/get.sh"; do t 0 "/bin/bash: ${f#$here/} parses" /bin/bash -n "$f"; done
  t 1 "/bin/bash: state refuses a key with an upper-case letter in a UTF-8 locale" env LC_ALL=en_US.UTF-8 /bin/bash "$here/bin/coddy" state 1 Key=x
  t 0 "/bin/bash: and for the key, not the lock" says "lower case words" env LC_ALL=en_US.UTF-8 /bin/bash "$here/bin/coddy" state 1 Key=x
fi
t 1 "start from stdin fails" sh -c "bash -s start 1 feat/1-thing < '$here/bin/coddy'"
t 0 "and says why" says 'not stdin' sh -c "bash -s start 1 feat/1-thing < '$here/bin/coddy'"
t 1 "githook: a commit on the default branch is refused" git commit -q --allow-empty -m x
t 0 "githook: naming /coddy:start" says '/coddy:start <issue>' git commit -q --allow-empty -m x
t 0 "githook: and --no-verify" says 'commit with --no-verify' git commit -q --allow-empty -m x
git checkout -q -b loose
t 1 "githook: a commit on an unclaimed branch is refused" git commit -q --allow-empty -m x
git checkout -q --detach origin/main # ahead of the remote, so only the hook stops a push of it
t 0 "githook: a commit on a detached HEAD passes" git commit -q --allow-empty -m x
d=$(git rev-parse HEAD); git checkout -q main
t 0 "githook: a commit on a claimed issue's branch passes, in its worktree" git -C .worktrees/1 commit -q --allow-empty -m x
t 1 "githook: a push to the default branch is refused" git push -q origin "$d:refs/heads/main"
t 0 "githook: naming push --no-verify" says 'push with --no-verify' git push -q origin "$d:refs/heads/main"
t 1 "githook: a push to an unclaimed branch is refused" git push -q origin loose
t 0 "githook: a push of a claimed issue's branch passes" git -C .worktrees/1 push -q origin HEAD
git push -q --no-verify origin loose
t 0 "githook: deleting another branch passes" git push -q origin --delete loose
t 0 "githook: deleting the default branch is refused" says 'push to main, the default branch' git push -q origin --delete main
git tag t1 "$d"
t 0 "githook: a tag passes" git push -q origin t1
git branch -q -D loose
# The hook core.hooksPath named before runs after coddy's check, with the same
# arguments and stdin, its exit the hook's. start records it whenever
# core.hooksPath is not coddy's (a hook manager re-set it), and a rerun keeps it.
mkdir "$tmp/prev"
for h in pre-commit pre-push commit-msg x.sample; do v=PREV_EXIT; [ $h != commit-msg ] || v=MSG_EXIT; printf '#!/bin/sh\necho "%s $*" >> "%s"; cat >> "%s"; exit ${%s:-0}\n' "$h" "$tmp/prev.log" "$tmp/prev.log" "$v" > "$tmp/prev/$h"; chmod +x "$tmp/prev/$h"; done
git config core.hooksPath "$tmp/prev"
# A core.hooksPath that overrides .git/config's (here the worktree's own
# config) would keep git from running these hooks: start refuses, and puts
# .git/config's back.
git config extensions.worktreeConfig true; git config --worktree core.hooksPath "$tmp/elsewhere"
t 1 "githook: start refuses under a core.hooksPath that overrides .git/config's" run start 1 feat/1-thing
t 0 "githook: naming git config --show-origin" says 'git config --show-origin core.hooksPath' run start 1 feat/1-thing
t 0 "githook: and puts .git/config's back" test "$(git config --local core.hooksPath)" = "$tmp/prev"
t 0 "githook: recording nothing" test -z "$(git config --local coddy.previousHooksPath)"
git config --worktree --unset core.hooksPath; git config --unset extensions.worktreeConfig
run start 1 feat/1-thing >/dev/null 2>&1
t 0 "githook: start puts core.hooksPath back" test "$(git config core.hooksPath)" = "$hooks"
t 0 "githook: recording the one before in .git/config" test "$(git config --local coddy.previousHooksPath)" = "$tmp/prev"
sums=$(cksum "$hooks"/*; git config --local coddy.previousHooksPath); run start 1 feat/1-thing >/dev/null 2>&1
t 0 "githook: a rerun changes nothing" test "$(cksum "$hooks"/*; git config --local coddy.previousHooksPath)" = "$sums"
t 0 "githook: and keeps core.hooksPath" test "$(git config core.hooksPath)" = "$hooks"
# Every other hook the previous directory holds gets a pass-through, and no
# other name does: reference-transaction would cost every ref update a shell.
t 0 "githook: a pass-through for each other hook there, none for a non-hook name" test "$(ls "$hooks")" = "$(printf 'commit-msg\npre-commit\npre-push')"
# A hook cut short, or read while it is rewritten, runs as an empty script and
# passes: start writes each aside and moves it in, so a failed write leaves the
# live one whole.
# A sandbox (Claude Code's) keeps every write out of .git/hooks and
# .git/config, since git runs hooks outside it: a rerun with nothing to change
# writes to neither, so it passes there.
if [ "$(id -u)" != 0 ]; then # root writes anywhere
  chmod a-w "$hooks"; : > .git/config.lock
  t 0 "githook: a rerun with nothing to change passes where neither the hooks nor .git/config can be written" run start 1 feat/1-thing
  rm .git/config.lock; cp "$tmp/prev/commit-msg" "$tmp/prev/post-commit"
  t 1 "githook: start that cannot write a hook fails" run start 1 feat/1-thing
  t 0 "githook: and leaves the live hooks whole" test "$(cksum "$hooks"/*; git config --local coddy.previousHooksPath)" = "$sums"
  chmod u+w "$hooks"; rm "$tmp/prev/post-commit"
fi
ln -s "$repo" "$tmp/alias"; CODDY_ROOT="$tmp/alias" run start 1 feat/1-thing >/dev/null 2>&1
t 0 "githook: a rerun by another spelling of the root keeps the record" test "$(git config --local coddy.previousHooksPath)" = "$tmp/prev"
# core.hooksPath set by one spelling of the root is set for every other: a
# rerun by the real path writes no .git/config, so a sandbox lets it pass.
git config core.hooksPath "$tmp/prev"; CODDY_ROOT="$tmp/alias" run start 1 feat/1-thing >/dev/null 2>&1
t 0 "githook: start through a symlinked root sets core.hooksPath by that spelling" test "$(git config core.hooksPath)" = "$tmp/alias/.git/hooks/coddy"
: > .git/config.lock
t 0 "githook: a rerun by the real path sees it set, so .git/config it cannot write stops nothing" run start 1 feat/1-thing
rm .git/config.lock; git config core.hooksPath "$hooks"
# start writes into a directory of its own and overwrites only what it wrote:
# lefthook, git lfs install and simple-git-hooks write into git's hooks path,
# which is this directory now.
cp "$hooks/commit-msg" "$tmp/cm"; echo foreign > "$hooks/commit-msg"
t 1 "githook: start stops on a file it did not write at a hook's name" run start 1 feat/1-thing
t 0 "githook: naming it and where it belongs" says "$hooks/commit-msg is not a hook coddy start wrote.*Move it to $tmp/prev," run start 1 feat/1-thing
t 0 "githook: and leaves it as it was" test "$(cat "$hooks/commit-msg")" = foreign
mv "$tmp/cm" "$hooks/commit-msg"; mkdir "$hooks/post-merge"
t 1 "githook: start stops on a name that is not a plain file" run start 1 feat/1-thing
rmdir "$hooks/post-merge"; : > "$hooks/.pre-commit.1"
t 0 "githook: and passes over another run's temp" run start 1 feat/1-thing
rm "$hooks/.pre-commit.1"; mv "$hooks" "$tmp/hooks"; mkdir "$tmp/target"; echo n > "$tmp/target/notes"; ln -s "$tmp/target" "$hooks"
t 1 "githook: start stops when the hooks directory is a symlink" run start 1 feat/1-thing
t 0 "githook: and deletes nothing behind it" test "$(ls "$tmp/target")" = notes
rm "$hooks"; mv "$tmp/hooks" "$hooks"
# A conditional include can set core.hooksPath in the issue's worktree alone:
# start reads it back there too, before it writes any pass-through.
printf '[core]\n\thooksPath = %s\n' "$tmp/elsewhere" > "$tmp/off.inc"; git config 'includeIf.onbranch:feat/**.path' "$tmp/off.inc"
cp "$tmp/prev/commit-msg" "$tmp/prev/post-commit"; sums=$(cksum "$hooks"/*)
t 1 "githook: start refuses when an onbranch include turns the hooks off in the issue's worktree" run start 1 feat/1-thing
t 0 "githook: having written no pass-through" test "$(cksum "$hooks"/*)" = "$sums"
git config --remove-section 'includeIf.onbranch:feat/**'; rm "$tmp/prev/post-commit"
: > "$tmp/prev.log"; git commit -q --allow-empty -m x >/dev/null 2>&1
t 1 "githook: a refused commit runs no previous hook" test -s "$tmp/prev.log"
t 0 "githook: a passed commit runs the previous pre-commit" sh -c "git -C .worktrees/1 commit -q --allow-empty -m x && grep -qx 'pre-commit ' '$tmp/prev.log'"
PREV_EXIT=1 t 1 "githook: whose failure fails the commit" git -C .worktrees/1 commit -q --allow-empty -m x
PREV_EXIT=1 t 1 "githook: a previous pre-push's failure fails the push" git -C .worktrees/1 push -q origin HEAD
t 0 "githook: which gets the push's arguments and stdin" sh -c "git -C .worktrees/1 push -q origin HEAD && grep -q '^pre-push origin ' '$tmp/prev.log' && grep -q ' refs/heads/feat/1-thing [0-9a-f]*\$' '$tmp/prev.log'"
t 0 "githook: a commit runs the previous commit-msg" sh -c "git -C .worktrees/1 commit -q --allow-empty -m x && grep -q '^commit-msg .*COMMIT_EDITMSG\$' '$tmp/prev.log'"
MSG_EXIT=1 t 1 "githook: whose failure fails the commit" git -C .worktrees/1 commit -q --allow-empty -m x
t 0 "githook: a pass-through hands on its arguments and stdin" sh -c "echo in | '$hooks/commit-msg' a b && grep -qx 'commit-msg a b' '$tmp/prev.log' && grep -qx in '$tmp/prev.log'"
mv "$tmp/prev/commit-msg" "$tmp/msg"
t 0 "githook: one whose hook has gone passes" git -C .worktrees/1 commit -q --allow-empty -m x
mv "$tmp/msg" "$tmp/prev/commit-msg"
# A .git/config start cannot write fails it with git's own error (a stale
# lock here); only Operation not permitted names a sandbox.
git config --unset core.hooksPath; : > .git/config.lock
t 1 "githook: start that cannot write .git/config fails" run start 1 feat/1-thing
t 0 "githook: with git's own error" says 'could not set core.hooksPath in .git/config: .*could not lock config file' run start 1 feat/1-thing
t 1 "githook: naming no sandbox" says sandbox run start 1 feat/1-thing
rm .git/config.lock
# Claude Code's sandbox refuses the write with Operation not permitted, so the
# first start there stops, and says how the user installs the hooks once.
mkdir "$tmp/eperm"; printf '#!/bin/sh\n[ "$#:$1:$2" != 3:config:core.hooksPath ] || { echo "error: could not lock config file .git/config: Operation not permitted" >&2; exit 255; }\nexec %s "$@"\n' "$(command -v git)" > "$tmp/eperm/git"; chmod +x "$tmp/eperm/git"
PATH="$tmp/eperm:$PATH" t 1 "githook: start that a sandbox keeps out of .git/config fails" run start 1 feat/1-thing
PATH="$tmp/eperm:$PATH" t 0 "githook: naming the sandbox and the user's one run from their own terminal" says 'sandbox.*Install them once from your own terminal, not through an agent: cd .* start 1 feat/1-thing\.' run start 1 feat/1-thing
run start 1 feat/1-thing >/dev/null 2>&1
t 0 "githook: none before is recorded as none" sh -c 'v=$(git config --local coddy.previousHooksPath) && [ -z "$v" ]'
t 1 "githook: under .git/hooks, its coddy directory gets no pass-through" test -e "$hooks/coddy"
cp "$tmp/prev/pre-commit" .git/hooks/pre-commit
PREV_EXIT=1 t 1 "githook: and then .git/hooks/ runs after coddy's check" git -C .worktrees/1 commit -q --allow-empty -m x
rm .git/hooks/pre-commit
# On a case-insensitive file system PRE-COMMIT is pre-commit: a pass-through by
# that name would replace coddy's own. Either way coddy's stays.
printf '#!/bin/sh\nexit 0\n' > .git/hooks/PRE-COMMIT; chmod +x .git/hooks/PRE-COMMIT; run start 1 feat/1-thing >/dev/null 2>&1
t 0 "githook: a previous PRE-COMMIT leaves coddy's pre-commit in place" grep -q 'githook pre-commit' "$hooks/pre-commit"
t 1 "githook: which still refuses a commit on the default branch" git commit -q --allow-empty -m x
rm .git/hooks/PRE-COMMIT
# A hook that cannot find the coddy that wrote it uses one on PATH, else refuses.
mkdir "$tmp/moved" "$tmp/onpath"; cp "$here/bin/coddy" "$tmp/moved/"; ln -s "$here/bin/coddy" "$tmp/onpath/coddy"
(cd .worktrees/1 && ../../../moved/coddy start 1 feat/1-thing) >/dev/null 2>&1
t 0 "githook: start run by a relative path, away from the root, writes that coddy's absolute path" grep -qxF "c='$tmp/moved/coddy'" "$hooks/pre-commit"
rm "$tmp/moved/coddy"
PATH="$tmp/nojq" t 1 "githook: a hook that cannot find coddy refuses" git -C .worktrees/1 commit -q --allow-empty -m x
PATH="$tmp/nojq" t 0 "githook: naming --no-verify" says 'skip the check with --no-verify' git -C .worktrees/1 commit -q --allow-empty -m x
PATH="$tmp/nojq" t 0 "githook: and, none recorded, how to turn it off" says 'git config --unset core.hooksPath' git -C .worktrees/1 commit -q --allow-empty -m x
PATH="$tmp/nojq" t 0 "githook: and /coddy:start, which rewrites them" says 'Run /coddy:start <issue> to rewrite these hooks' git -C .worktrees/1 commit -q --allow-empty -m x
PATH="$tmp/onpath:$PATH" t 0 "githook: one on PATH runs it" git -C .worktrees/1 commit -q --allow-empty -m x
# The recorded path as recorded: echo in sh would read its backslash as an escape.
b="$tmp/pr\\ev"; cp "$here/bin/coddy" "$tmp/moved/"; git config core.hooksPath "$b"; "$tmp/moved/coddy" start 1 feat/1-thing >/dev/null 2>&1; rm "$tmp/moved/coddy"
PATH="$tmp/nojq" t 0 "githook: and, one recorded, how to put it back, backslash and all" sh -c 'git -C .worktrees/1 commit -q --allow-empty -m x 2>&1 | grep -qF -- "$1"' _ "git config core.hooksPath $(printf %q "$b")"
git config --unset core.hooksPath; run start 1 feat/1-thing >/dev/null 2>&1
# Not onboarded, coddy's check is off.
pp() { echo "refs/heads/main $d refs/heads/main $d" | "$hooks/pre-push" origin x; }
t 1 "githook: run by hand, pre-commit on the default branch refuses" "$hooks/pre-commit"
t 1 "githook: and pre-push to it" pp
mv .coddy.yml "$tmp/aside"
t 0 "githook: not onboarded, pre-commit passes" "$hooks/pre-commit"
t 0 "githook: and pre-push" pp
mv "$tmp/aside" .coddy.yml

# get.sh installs main from CODDY_REPO_URL into CODDY_HOME and links coddy
# into CODDY_BIN, run as curl pipes it (the script on stdin), with no network.
src="$tmp/src" gh="$tmp/gethome"; cs="$gh/.coddy"
git init -q "$src"; git -C "$src" checkout -q -b main
mkdir -p "$src/bin" "$src/.claude-plugin" "$gh" "$tmp/root"
cp "$here/bin/coddy" "$src/bin/"; cp "$here/.claude-plugin/plugin.json" "$src/.claude-plugin/"; echo x > "$src/README.md"
git -C "$src" add -A; git -C "$src" commit -q -m init; git clone -q --bare "$src" "$tmp/coddy.git"
upstream() { echo "$1" > "$src/$2"; git -C "$src" add -A; git -C "$src" commit -q -m "$1"; git -C "$src" push -q "$tmp/coddy.git" main; }
get() { HOME="$gh" CODDY_HOME="$cs" CODDY_BIN="${gbin-$gh/bin}" CODDY_REPO_URL="${url-$tmp/coddy.git}" PATH="${gpath-$PATH}" bash -s < "$here/get.sh"; }
sha() { git -C "$cs" rev-parse --short HEAD; }
printf '#!/bin/sh\necho 0\n' > "$tmp/root/id"; chmod +x "$tmp/root/id"
gpath="$tmp/root:$PATH" t 1 "get.sh: refuses root" get
t 1 "get.sh: and touches nothing" test -e "$cs"
mkdir "$gh/bin"; echo mine > "$gh/bin/coddy"
t 1 "get.sh: a coddy in CODDY_BIN that is not its link is refused" get
t 0 "get.sh: before any clone" sh -c "! test -e '$cs' && grep -qx mine '$gh/bin/coddy'"
rm "$gh/bin/coddy"
t 0 "get.sh: a first run clones" says "^cloned: $cs at " get
t 0 "get.sh: on main" test "$(git -C "$cs" branch --show-current)" = main
t 0 "get.sh: links coddy into CODDY_BIN" test "$gh/bin/coddy" -ef "$cs/bin/coddy"
t 0 "get.sh: prints the commit" says "at $(sha)\$" get
t 0 "get.sh: and the next step per agent" says 'claude plugin install coddy@coddy' get
t 0 "get.sh: for other agents too" says "$cs/skills/onboard/SKILL.md" get
t 0 "get.sh: a rerun is up to date" says "^up to date: $cs at $(sha)\$" get
t 0 "get.sh: CODDY_BIN off PATH prints the line to add" says "export PATH=\"$gh/bin:" get
gpath="$gh/bin:$PATH" t 1 "get.sh: and on PATH does not" says 'export PATH=' get
gbin="$gh/bin/" gpath="$gh/bin:$PATH" t 1 "get.sh: nor with a trailing / on CODDY_BIN" says 'export PATH=' get
gpath="$gh/bin/:$PATH" t 1 "get.sh: nor on the PATH entry" says 'export PATH=' get
t 0 "get.sh: and edits no rc file" sh -c "! ls -A '$gh' | grep -q '^\.[a-z]*rc\$\|profile'"
upstream two README.md
t 0 "get.sh: a new remote commit fast-forwards" says "^updated: $cs at $(git -C "$src" rev-parse --short HEAD)\$" get
upstream three README.md; was=$(sha)
echo edited >> "$cs/README.md"
t 1 "get.sh: an edited tracked file is refused" get
t 0 "get.sh: and left as it was" sh -c "grep -qx edited '$cs/README.md' && test \"\$(git -C '$cs' rev-parse --short HEAD)\" = $was"
git -C "$cs" checkout -q -- README.md; git -C "$cs" checkout -q -b topic
t 1 "get.sh: another branch is refused" get
t 0 "get.sh: and left on it" test "$(git -C "$cs" branch --show-current)" = topic
git -C "$cs" checkout -q main
url="$tmp/other.git" t 1 "get.sh: another origin is refused" get
t 0 "get.sh: and left as it was" test "$(sha)" = "$was"
url="$tmp/coddy.git/" t 0 "get.sh: an origin spelled with a trailing / is accepted" get
upstream four README.md
url="$tmp/coddy" t 0 "get.sh: and one without .git" get
upstream five README.md; echo scratch > "$cs/scratch.txt"
t 0 "get.sh: an untracked file does not block" says '^updated: ' get
upstream six new.txt; echo mine > "$cs/new.txt"; was=$(sha)
t 1 "get.sh: an untracked file in the merge's way stops it" get
t 0 "get.sh: showing git's message" says 'untracked' get
t 0 "get.sh: saying the checkout is unchanged" says 'the checkout and HEAD are unchanged' get
t 0 "get.sh: and left as it was" sh -c "grep -qx mine '$cs/new.txt' && test \"\$(git -C '$cs' rev-parse --short HEAD)\" = $was"
rm "$cs/new.txt"; get >/dev/null 2>&1
git init -q "$tmp/gd"; git -C "$tmp/gd" checkout -q -b main; git -C "$tmp/gd" commit -q --allow-empty -m gd; git -C "$tmp/gd" remote add origin "$tmp/coddy.git"
upstream seven README.md
GIT_DIR="$tmp/gd/.git" t 0 "get.sh: a GIT_DIR from the caller is dropped" says '^updated: ' get
t 0 "get.sh: and its repository left alone" test "$(git -C "$tmp/gd" rev-list --count HEAD)" = 1
touch "$tmp/binfile"
t 1 "get.sh: a CODDY_BIN that is a file is refused" env HOME="$gh" CODDY_HOME="$tmp/h2" CODDY_BIN="$tmp/binfile" CODDY_REPO_URL="$tmp/coddy.git" bash "$here/get.sh"
t 1 "get.sh: before any clone" test -e "$tmp/h2"
t 1 "get.sh: an unreachable repository is refused" env HOME="$gh" CODDY_HOME="$tmp/h5" CODDY_BIN="$tmp/b5/bin" CODDY_REPO_URL="$tmp/nowhere.git" bash "$here/get.sh"
t 1 "get.sh: and leaves no CODDY_BIN behind" test -e "$tmp/b5"
t 0 "get.sh: no HOME and no CODDY_HOME says so" says 'HOME: is not set' env -u HOME CODDY_BIN="$tmp/b7" CODDY_REPO_URL="$tmp/coddy.git" bash "$here/get.sh"
t 0 "get.sh: nor CODDY_BIN" says 'HOME: is not set' env -u HOME CODDY_HOME="$tmp/h7" CODDY_REPO_URL="$tmp/coddy.git" bash "$here/get.sh"
t 1 "get.sh: before any clone" test -e "$tmp/h7"
t 0 "get.sh: a relative CODDY_HOME links to where it cloned" sh -c "cd '$tmp' && HOME='$gh' CODDY_HOME=relh CODDY_BIN=relb CODDY_REPO_URL='$tmp/coddy.git' bash '$here/get.sh' >/dev/null && test relb/coddy -ef relh/bin/coddy"
t 0 "get.sh: a relative CODDY_REPO_URL matches on the rerun" sh -c "cd '$tmp' && for i in 1 2; do HOME='$gh' CODDY_HOME=relh3 CODDY_BIN=relb3 CODDY_REPO_URL=coddy.git bash '$here/get.sh' || exit 1; done | grep -q '^up to date: '"
# The origin in another spelling of the same repository passes the origin check and reaches the fetch, which ssh=false stops.
for o in 'git@GitHub.com:MNSami/Coddy.git' 'ssh://git@github.com/mnsami/coddy.git/'; do
  git -C "$cs" remote set-url origin "$o"
  url=https://github.com/mnsami/coddy GIT_SSH_COMMAND=false t 0 "get.sh: origin $o is the same repository" says 'could not fetch' get
done
url=https://github.com/mnsami/coddy GIT_SSH_COMMAND=false gbin="$tmp/b6/bin" get >/dev/null 2>&1
t 1 "get.sh: a failed fetch leaves no CODDY_BIN behind" test -e "$tmp/b6"
git -C "$cs" remote set-url origin "$tmp/coddy.git"
if [ "$(id -u)" != 0 ]; then # root writes anywhere
  mkdir -p "$tmp/ro"; chmod 555 "$tmp/ro"
  t 1 "get.sh: a CODDY_BIN it cannot write to is refused" env HOME="$gh" CODDY_HOME="$tmp/h8" CODDY_BIN="$tmp/ro" CODDY_REPO_URL="$tmp/coddy.git" bash "$here/get.sh"
  t 1 "get.sh: before any clone" test -e "$tmp/h8"
  chmod 555 "$gh/bin"
  t 0 "get.sh: one already holding the link needs no write" says '^up to date: ' get
  chmod 755 "$tmp/ro" "$gh/bin"
fi
t 0 "get.sh: a trailing / on CODDY_HOME is dropped" says "^cloned: $tmp/h9 at " env HOME="$gh" CODDY_HOME="$tmp/h9/" CODDY_BIN="$tmp/b9" CODDY_REPO_URL="$tmp/coddy.git" bash "$here/get.sh"
t 0 "get.sh: from the link too" test "$(readlink "$tmp/b9/coddy")" = "$tmp/h9/bin/coddy"
t 0 "doctor: from stdin says why it cannot" says 'not stdin' sh -c "bash -s doctor < '$here/bin/coddy'"
# doctor names the install it runs from: get.sh's through the PATH link, another from a checkout.
# CODDY_ROOT names no project here ($tmp is no repository), so only the install prints.
doc() { HOME="$gh" CODDY_HOME="$cs" CODDY_ROOT="$tmp" "$@" doctor; }
t 0 "doctor: through the link, the real install dir" says "^install: $(cd "$cs" && pwd -P)\$" doc "$gh/bin/coddy"
t 0 "doctor: via get.sh" says '^via: get.sh$' doc "$gh/bin/coddy"
t 0 "doctor: the installed commit" says "^commit: $(sha)\$" doc "$gh/bin/coddy"
t 0 "doctor: the version" says "^version: $(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$here/.claude-plugin/plugin.json")\$" doc "$gh/bin/coddy"
t 0 "doctor: from this checkout, via other" says '^via: other$' doc "$here/bin/coddy"
t 0 "doctor: naming this checkout" says "^install: $(cd "$here" && pwd -P)\$" doc "$here/bin/coddy"
t 0 "doctor: with no HOME" says '^via: other$' env -u HOME -u CODDY_HOME CODDY_ROOT="$tmp" "$here/bin/coddy" doctor
t 1 "doctor: and no unbound variable" says 'unbound' env -u HOME -u CODDY_HOME CODDY_ROOT="$tmp" "$here/bin/coddy" doctor
t 0 "doctor: a CDPATH does not move it" sh -c "cd '$here' && CDPATH='$gh' HOME='$gh' CODDY_ROOT='$tmp' bash bin/coddy doctor | grep -qx 'install: $(cd "$here" && pwd -P)'"
mkdir -p "$tmp/dl/real/bin" "$tmp/dl/x"; cp "$here/bin/coddy" "$tmp/dl/real/bin/"; ln -s ../real/bin "$tmp/dl/x/bin"
t 0 "doctor: through a linked bin/, the real install dir" says "^install: $(cd "$tmp/dl/real" && pwd -P)\$" env CODDY_ROOT="$tmp" "$tmp/dl/x/bin/coddy" doctor
t 0 "doctor: outside a project, the four install lines alone" test "$(CODDY_ROOT="$tmp" "$here/bin/coddy" doctor | wc -l)" -eq 4

# doctor in a project: a line per check, ok or the problem with its fix; exit 1 on any; writes nothing.
dp="$tmp/dp"; git init -q --bare "$tmp/dorigin.git"; git clone -q "$tmp/dorigin.git" "$dp" 2>/dev/null
(cd "$dp" && git checkout -q -b main && echo hi > README.md && git add -A && git commit -q -m init && git push -q -u origin main)
dd() { CODDY_ROOT="$dp" "$here/bin/coddy" "$@"; }
dsaysat() { CODDY_ROOT="$1" "$here/bin/coddy" doctor 2>&1 | grep -q "$2"; }
dsays() { dd doctor 2>&1 | grep -q "$1"; }
t 0 "doctor: not onboarded" dsays '^config: none (fix: /coddy:onboard)$'
t 1 "doctor: not onboarded exits 1" dd doctor
printf 'version: 2\ntracker: github\nworktree: git\ndefault_branch: main\nverify: true\n' > "$dp/.coddy.yml"
dd start 1 feat/1-x >/dev/null 2>&1
mkdir -p "$dp/.github/workflows"; cp "$here/templates/coddy.yml" "$dp/.github/workflows/coddy.yml"
awk '/^   <!-- coddy:begin -->$/,/^   <!-- coddy:end -->$/' "$here/skills/onboard/SKILL.md" | sed 's/^   //' > "$dp/AGENTS.md"
t 0 "doctor: onboarded, started, PR check and AGENTS.md in place: all ok" dd doctor
t 1 "doctor: and no check line that is not ok" sh -c "CODDY_ROOT='$dp' '$here/bin/coddy' doctor | grep -E '^(config|worktree|default_branch|jq|git|jj|hooks|pr_check|agents_md): ' | grep -v ': ok'"
before=$( (cd "$dp" && cat .git/config; git for-each-ref; find . -path ./.git -prune -o -path ./.worktrees -prune -o -type f -print | sort | xargs cksum) )
dd doctor >/dev/null 2>&1
t 0 "doctor: changes nothing" test "$before" = "$( (cd "$dp" && cat .git/config; git for-each-ref; find . -path ./.git -prune -o -path ./.worktrees -prune -o -type f -print | sort | xargs cksum) )"
# prob <name> <line pattern> <break> <repair>: the break gives that line and exit 1, the repair restores all ok
prob() { (cd "$dp" && eval "$3") >/dev/null 2>&1; t 0 "doctor: $1" dsays "$2"; t 1 "doctor: $1 exits 1" dd doctor; (cd "$dp" && eval "$4") >/dev/null 2>&1; t 0 "doctor: $1, repaired" dd doctor; }
cp "$dp/.coddy.yml" "$tmp/dp.yml"
prob "config behind" '^config: .*(fix: /coddy:migrate)' 'sed -i.bak "/^version:/d" .coddy.yml; rm .coddy.yml.bak' 'cp "$tmp/dp.yml" .coddy.yml'
prob "unknown worktree" "^worktree: unknown value 'svn'" 'sed -i.bak "s/^worktree:.*/worktree: svn/" .coddy.yml; rm .coddy.yml.bak' 'cp "$tmp/dp.yml" .coddy.yml'
prob "default_branch missing" '^default_branch: origin/main is missing' 'git update-ref -d refs/remotes/origin/main' 'git fetch -q origin'
mkdir "$tmp/nojqd"; for x in bash sh sed awk cat grep git cmp ps head wc cut tr; do p=$(command -v "$x") && ln -s "$p" "$tmp/nojqd/$x"; done
t 0 "doctor: jq missing" says '^jq: missing (fix: install jq)' env PATH="$tmp/nojqd" CODDY_ROOT="$dp" "$BASH" "$here/bin/coddy" doctor
sed -i.bak 's/^worktree:.*/worktree: jj/' "$dp/.coddy.yml"; rm "$dp/.coddy.yml.bak"
ln -s "$(command -v jq)" "$tmp/nojqd/jq"
t 0 "doctor: jj missing under worktree: jj" says '^jj: missing (fix: install jj' env PATH="$tmp/nojqd" CODDY_ROOT="$dp" "$BASH" "$here/bin/coddy" doctor
cp "$tmp/dp.yml" "$dp/.coddy.yml"
prob "core.hooksPath elsewhere" '^hooks: core.hooksPath is /elsewhere' 'git config core.hooksPath /elsewhere' 'git config core.hooksPath "$PWD/.git/hooks/coddy"'
prob "a hook without coddy's header" '^hooks: pre-push is missing or not one coddy start wrote' 'cp .git/hooks/coddy/pre-push "$tmp/pp"; echo "#!/bin/sh" > .git/hooks/coddy/pre-push' 'cp "$tmp/pp" .git/hooks/coddy/pre-push'
# written quoted as start writes it, and run under a PATH without coddy: the fallback to `command -v coddy` must not hide it
(cd "$dp" && cp .git/hooks/coddy/pre-commit "$tmp/pc" && sed -i.bak "s#^c=.*#c='/nonexistent/coddy'#" .git/hooks/coddy/pre-commit && rm .git/hooks/coddy/pre-commit.bak)
t 0 "doctor: the recorded coddy path gone" sh -c "PATH=/usr/bin:/bin CODDY_ROOT='$dp' '$here/bin/coddy' doctor | grep -q '^hooks: pre-commit runs /nonexistent/coddy, which is gone'"
t 1 "doctor: the recorded coddy path gone exits 1" env PATH=/usr/bin:/bin CODDY_ROOT="$dp" "$here/bin/coddy" doctor
(cd "$dp" && cp "$tmp/pc" .git/hooks/coddy/pre-commit)
prob "a hook git would skip" '^hooks: pre-push is not executable' 'chmod -x .git/hooks/coddy/pre-push' 'chmod +x .git/hooks/coddy/pre-push'
prob "hooks not installed" '^hooks: core.hooksPath is not set.*(fix: /coddy:start <issue>)' 'git config --unset core.hooksPath' 'git config core.hooksPath "$PWD/.git/hooks/coddy"'
prob "PR check missing" '^pr_check: .*is missing or not a plain file (fix: copy ' 'rm .github/workflows/coddy.yml' 'cp "$here/templates/coddy.yml" .github/workflows/coddy.yml'
prob "PR check different" '^pr_check: .*differs from ' 'echo x >> .github/workflows/coddy.yml' 'cp "$here/templates/coddy.yml" .github/workflows/coddy.yml'
prob "AGENTS.md missing" '^agents_md: AGENTS.md is missing' 'mv AGENTS.md "$tmp/am"' 'mv "$tmp/am" AGENTS.md'
prob "AGENTS.md without the block" '^agents_md: AGENTS.md needs exactly one' 'cp AGENTS.md "$tmp/am"; echo "# x" > AGENTS.md' 'cp "$tmp/am" AGENTS.md'
prob "AGENTS.md with a lone marker" '^agents_md: AGENTS.md needs exactly one' 'cp AGENTS.md "$tmp/am"; sed -i.bak "/coddy:end/d" AGENTS.md; rm AGENTS.md.bak' 'cp "$tmp/am" AGENTS.md'
prob "AGENTS.md with reversed markers" '^agents_md: AGENTS.md needs exactly one' 'cp AGENTS.md "$tmp/am"; sed -i.bak "s/coddy:begin/coddy:X/;s/coddy:end/coddy:begin/;s/coddy:X/coddy:end/" AGENTS.md; rm AGENTS.md.bak' 'cp "$tmp/am" AGENTS.md'
# AGENTS.md as a link: to a file holding the block it reads ok, to a directory or nowhere it fails
(cd "$dp" && mv AGENTS.md "$tmp/am" && ln -s "$tmp/am" AGENTS.md)
t 0 "doctor: AGENTS.md linked to a file holding the block" dd doctor
(cd "$dp" && rm AGENTS.md && ln -s "$tmp" AGENTS.md)
t 0 "doctor: AGENTS.md linked to a directory" dsays '^agents_md: AGENTS.md is missing'
(cd "$dp" && rm AGENTS.md && ln -s "$tmp/nonexistent-am" AGENTS.md)
t 0 "doctor: AGENTS.md dangling" dsays '^agents_md: AGENTS.md is missing'
t 1 "doctor: AGENTS.md dangling exits 1" dd doctor
(cd "$dp" && rm AGENTS.md && mv "$tmp/am" AGENTS.md)
# AGENTS.md over 1 MiB is not judged; a git-less jj root has no origin ref or hooks path to check
cp "$dp/AGENTS.md" "$tmp/am"; head -c 1048576 /dev/zero | tr '\0' x >> "$dp/AGENTS.md"
t 0 "doctor: AGENTS.md over 1 MiB, not read" dsays '^agents_md: AGENTS.md is over 1 MiB, not read'
t 1 "doctor: AGENTS.md over 1 MiB exits 1" dd doctor
cp "$tmp/am" "$dp/AGENTS.md"
jr="$tmp/jjroot"; mkdir -p "$jr/.github/workflows"; cp "$dp/AGENTS.md" "$jr/"; cp "$here/templates/coddy.yml" "$jr/.github/workflows/"
printf 'version: 2\ntracker: github\nworktree: git\ndefault_branch: main\nverify: true\n' > "$jr/.coddy.yml"
t 0 "doctor: a git-less root, default_branch and hooks not applicable" dsaysat "$jr" '^hooks: ok (not applicable'
t 0 "doctor: a git-less root, default_branch" dsaysat "$jr" '^default_branch: ok (not applicable'
t 0 "doctor: a git-less root exits 0" env CODDY_ROOT="$jr" "$here/bin/coddy" doctor
# a recorded coddy path holding a quote is read back as start wrote it
qd="$tmp/q'd"; mkdir -p "$qd"; : > "$qd/coddy"; chmod +x "$qd/coddy"; qc="$tmp/q'\\''d/coddy"
qset() { QC="$qc" awk '/^c=/ { print "c=\047" ENVIRON["QC"] "\047"; next } 1' "$tmp/pc" > .git/hooks/coddy/pre-commit; chmod +x .git/hooks/coddy/pre-commit; }
(cd "$dp" && cp .git/hooks/coddy/pre-commit "$tmp/pc" && qset)
t 0 "doctor: a recorded path with a quote reads as ok" sh -c "PATH=/usr/bin:/bin CODDY_ROOT='$dp' '$here/bin/coddy' doctor | grep -qx 'hooks: ok'"
rm "$qd/coddy"
t 0 "doctor: and gone, when it is" sh -c "PATH=/usr/bin:/bin CODDY_ROOT='$dp' '$here/bin/coddy' doctor | grep -q '^hooks: pre-commit runs .*q.d/coddy, which is gone'"
(cd "$dp" && cp "$tmp/pc" .git/hooks/coddy/pre-commit)
prob "a commondir in the git dir" '^git_dir: ' 'echo . > .git/commondir' 'rm .git/commondir'
# a root reached from a .worktrees/<id> whose .git is garbage (git fails there): the root's own git dir is still held to the commondir test, running no planted program
cp -R "$dp/.git" "$tmp/devil"; printf '#!/bin/sh\n: > "%s"\n' "$tmp/dfsm" > "$tmp/dfsm.sh"; chmod +x "$tmp/dfsm.sh"; git --git-dir="$tmp/devil" config core.fsmonitor "$tmp/dfsm.sh"
mkdir -p "$dp/.worktrees/9"; echo garbage > "$dp/.worktrees/9/.git"; echo "$tmp/devil" > "$dp/.git/commondir"
rm -f "$tmp/dfsm"
t 0 "doctor: from a worktree with a garbage .git, a commondir in the root's git dir is git_dir" dsaysat "$dp/.worktrees/9" '^git_dir: '
t 1 "doctor: and exits 1" env CODDY_ROOT="$dp/.worktrees/9" "$here/bin/coddy" doctor
t 1 "doctor: and git ran none of its programs" test -e "$tmp/dfsm"
rm -rf "$dp/.git/commondir" "$dp/.worktrees/9" "$tmp/devil"
# an empty .git dir under a worktree is walked past as git does: the root's commondir is found
printf '#!/bin/sh\n: > "%s"\n' "$tmp/dfsm" > "$tmp/dfsm.sh"; chmod +x "$tmp/dfsm.sh"
cp -R "$dp/.git" "$tmp/devil"; git --git-dir="$tmp/devil" config core.fsmonitor "$tmp/dfsm.sh"
mkdir -p "$dp/.worktrees/8/.git"; echo "$tmp/devil" > "$dp/.git/commondir"; rm -f "$tmp/dfsm"
t 0 "doctor: from a worktree holding an empty .git dir, a commondir in the root's git dir is git_dir" dsaysat "$dp/.worktrees/8" '^git_dir: '
t 1 "doctor: and git ran none of its programs" test -e "$tmp/dfsm"
rm -rf "$dp/.git/commondir" "$dp/.worktrees/8"
# a .git that is a link is git_dir too, in a subdirectory no matter what it names
mkdir -p "$dp/lsub"; ln -s "$tmp/devil" "$dp/lsub/.git"; cp "$dp/.coddy.yml" "$dp/lsub/.coddy.yml"
t 0 "doctor: a .git that is a link is git_dir" dsaysat "$dp/lsub" '^git_dir: '
t 1 "doctor: and exits 1" env CODDY_ROOT="$dp/lsub" "$here/bin/coddy" doctor
t 1 "doctor: and git ran none of its programs" test -e "$tmp/dfsm"
rm -rf "$dp/lsub" "$tmp/devil"
# a session started inside a bare repository nested two levels into the project: git's root, its parent, has no .git, so it is git_dir and says so; one level down roots at the project
mkdir -p "$dp/bx/y"; git init -q --bare "$dp/bx/y/c.git"
for st in bx/y/c.git bx/y/c.git/refs; do
  t 0 "bare: from $st, doctor says the session started inside a bare repository" dsaysat "$dp/$st" '^git_dir: .*bare repository nested in the project'
  t 1 "bare: and exits 1" env CODDY_ROOT="$dp/$st" "$here/bin/coddy" doctor
  for v in config status detect; do t 0 "bare: and $v prints that line" sh -c "CODDY_ROOT='$dp/$st' '$here/bin/coddy' $v | grep -q '^git_dir: .*bare repository nested in the project'"; done
done
rm -rf "$dp/bx"; git init -q --bare "$dp/bc.git"
t 0 "bare: one level down, doctor is not git_dir" sh -c "! CODDY_ROOT='$dp/bc.git' '$here/bin/coddy' doctor 2>&1 | grep -q '^git_dir: '"
rm -rf "$dp/bc.git"
# a bare repository in no project: no git_dir, doctor prints the install lines alone and the other verbs are as on a plain directory; nested in a project, the line names the bare repository itself
mkdir -p "$tmp/sb"; git init -q --bare "$tmp/sb/foo.git"
for st in foo.git foo.git/refs; do
  t 0 "bare: standalone from $st, doctor exits 0" env CODDY_ROOT="$tmp/sb/$st" "$here/bin/coddy" doctor
  t 0 "bare: and prints no git_dir" sh -c "! CODDY_ROOT='$tmp/sb/$st' '$here/bin/coddy' doctor 2>&1 | grep -q '^git_dir: '"
  for v in config status detect; do t 0 "bare: and $v prints no git_dir" sh -c "! CODDY_ROOT='$tmp/sb/$st' '$here/bin/coddy' $v 2>&1 | grep -q '^git_dir: '"; done
done
# the same bare repository beside a config at its parent: the parent is the project, the exemption does not apply
mkdir -p "$tmp/sbc"; git init -q --bare "$tmp/sbc/foo.git"; printf 'version: 2\ntracker: github\nworktree: git\ndefault_branch: main\nverify: true\n' > "$tmp/sbc/.coddy.yml"
for st in foo.git foo.git/refs; do t 2 "bare: beside a config, from $st, guard is held" sh -c "echo '{\"tool_input\":{\"file_path\":\"/x\"}}' | CODDY_ROOT='$tmp/sbc/$st' '$here/bin/coddy' guard"; done
mkdir -p "$dp/bx/y"; git init -q --bare "$dp/bx/y/c.git"
t 0 "bare: nested, the line names the bare repository, not a .git that does not exist" sh -c "CODDY_ROOT='$dp/bx/y/c.git' '$here/bin/coddy' status | grep -q \"^git_dir: $(cd "$dp" && pwd -P)/bx/y/c.git is a bare repository nested in the project\""
rm -rf "$dp/bx"
# a .git that is a huge sparse file, and a HEAD git rejects, stall and fool no hook
mkdir -p "$tmp/sp"; git init -q "$tmp/sp"; cp "$dp/.coddy.yml" "$tmp/sp/"; mv "$tmp/sp/.git" "$tmp/sp/x"; truncate -s 4G "$tmp/sp/.git"
t 2 "guard: a huge sparse .git at the root is refused within seconds" timeout 10 sh -c "printf '{\"session_id\":\"s\",\"tool_input\":{\"file_path\":\"$tmp/sp/f\"}}' | CODDY_ROOT='$tmp/sp' '$here/bin/coddy' guard"
t 2 "snap: and so is a command" timeout 10 sh -c "printf '{\"session_id\":\"s\",\"cwd\":\"$tmp/sp\",\"tool_input\":{\"command\":\"true\"}}' | CODDY_ROOT='$tmp/sp' '$here/bin/coddy' snap"
rm -rf "$tmp/sp"
mkdir -p "$tmp/hA"; git init -q "$tmp/hA"; printf '#!/bin/sh\ntouch "%s/hMark"\n' "$tmp" > "$tmp/hfsm"; chmod +x "$tmp/hfsm"; git -C "$tmp/hA" config core.fsmonitor "$tmp/hfsm"
for hd in ' refs/heads/main' $'\trefs/heads/main' $'\nrefs/heads/main'; do
  P="$tmp/hA/proj"; rm -rf "$P"; mkdir -p "$P/.git/objects" "$P/.git/refs" "$P/src/deep"; cp "$dp/.coddy.yml" "$P/"
  ln -s "$hd" "$P/.git/HEAD"; echo garbage > "$P/src/.git"
  t 0 "snap: a symlink HEAD whose target starts with whitespace is no repository, so no git runs in the one above" sh -c "printf '{\"session_id\":\"s\",\"cwd\":\"$P/src/deep\",\"tool_input\":{\"command\":\"true\"}}' | CODDY_ROOT='$P/src/deep' '$here/bin/coddy' snap"
  t 1 "snap: and A's core.fsmonitor never ran" test -e "$tmp/hMark"
done
P="$tmp/hA/proj"; rm -rf "$P"; mkdir -p "$P/.git/objects" "$P/.git/refs" "$P/src/deep"; cp "$dp/.coddy.yml" "$P/"
printf 'ref:%300srefs/heads/main\n' ' ' > "$P/.git/HEAD"; echo garbage > "$P/src/.git"
t 0 "snap: ref: and over 250 whitespace characters before refs/ is no repository" sh -c "printf '{\"session_id\":\"s\",\"cwd\":\"$P/src/deep\",\"tool_input\":{\"command\":\"true\"}}' | CODDY_ROOT='$P/src/deep' '$here/bin/coddy' snap"
t 1 "snap: and A's core.fsmonitor never ran" test -e "$tmp/hMark"
rm -rf "$tmp/hA" "$tmp/sb"
# the same with no config in the subdirectory, and a commondir to nowhere
mkdir -p "$dp/lsub"; ln -s /nowhere "$dp/lsub/.git"
t 0 "doctor: a .git link in a subdirectory with no config is git_dir" dsaysat "$dp/lsub" '^git_dir: '
rm -rf "$dp/lsub"; mkdir -p "$dp/lsub/.git"; echo /nowhere > "$dp/lsub/.git/commondir"
t 0 "doctor: so is a commondir to nowhere" dsaysat "$dp/lsub" '^git_dir: '
t 0 "doctor: and says to remove the file, not to open the session elsewhere" sh -c "echo 'gitdir: /nowhere' > '$dp/lsub/.git/commondir'; CODDY_ROOT='$dp/lsub' '$here/bin/coddy' doctor 2>&1 | grep -q 'is not the main checkout.s own git dir'"
# a repository git rejects planted at .worktrees/.git (or in place of an issue worktree's .git) leaves the root the project: a main-checkout write is still refused
plant() { mkdir -p "$1/objects" "$1/refs"; echo 'ref: refs/heads/main' > "$1/HEAD"; printf '[core]\n\trepositoryformatversion = 9\n' > "$1/config"; }
gdir() { printf '{"session_id":"sess-a","tool_input":{"file_path":"%s"}}' "$dp/README.md" | CODDY_ROOT="$1" CODDY_PID=$$ "$here/bin/coddy" guard; }
mkdir -p "$dp/.worktrees/5"; plant "$dp/.worktrees/.git"
t 2 "guard: from a jj workspace under a planted .worktrees/.git, the main checkout is refused" gdir "$dp/.worktrees/5"
rm -rf "$dp/.worktrees/.git"; plant "$dp/.worktrees/5/.git"
t 2 "guard: from a worktree whose .git is a rejected repository, the main checkout is refused" gdir "$dp/.worktrees/5"
rm -rf "$dp/.worktrees/5"
rm -rf "$dp/lsub"; mkdir -p "$dp/lsub"; ln -s /etc/hosts "$dp/lsub/.git"
t 0 "doctor: a .git link where git fails is git_dir" dsaysat "$dp/lsub" '^git_dir: .*lsub/.git'
rm -rf "$dp/lsub"; mkdir -p "$dp/lsub/.git" "$tmp/lcd"; ln -s "$tmp/lcd" "$dp/lsub/.git/commondir"
t 0 "doctor: a commondir link to a directory is git_dir" dsaysat "$dp/lsub" '^git_dir: '
rm -rf "$dp/lsub" "$tmp/lcd"; mkdir -p "$dp/lsub"; ln -s "$dp/.git" "$dp/lsub/.git"
t 0 "doctor: a .git link to a real repository is git_dir, the root above it" dsaysat "$dp/lsub" '^git_dir: .*lsub/.git is not'
t 0 "doctor: and a link's fix is to remove it" dsaysat "$dp/lsub" 'fix: remove it by hand'
rm -rf "$dp/lsub"
# a .git that is a gitdir: file elsewhere (a submodule, a bare repository's worktree): git_dir says to open the session in the main checkout
mkdir -p "$tmp/gl" "$tmp/glgit"; git init -q "$tmp/gl"; cp "$tmp/dp.yml" "$tmp/gl/.coddy.yml"; mv "$tmp/gl/.git" "$tmp/glgit/g"; echo "gitdir: $tmp/glgit/g" > "$tmp/gl/.git"
t 0 "doctor: a .git that is a gitdir: file is git_dir, naming the file" dsaysat "$tmp/gl" "^git_dir: $tmp/gl/.git is a file naming a git dir elsewhere"
t 0 "doctor: and the fix is to open the session in the main checkout" dsaysat "$tmp/gl" 'fix: open the session in the main checkout, or remove the file by hand'
t 1 "doctor: and exits 1" env CODDY_ROOT="$tmp/gl" "$here/bin/coddy" doctor
for v in config status detect; do
  t 0 "$v: a .git that is a gitdir: file prints git_dir naming the file and the open-the-main-checkout fix" says "^git_dir: $tmp/gl/.git is a file naming a git dir elsewhere.*fix: open the session in the main checkout" env CODDY_ROOT="$tmp/gl" "$here/bin/coddy" $v
done
t 0 "verify: and a verb that refuses names the file and the main checkout" says "$tmp/gl/.git is a file naming.*open the session in the main checkout" env CODDY_ROOT="$tmp/gl" "$here/bin/coddy" verify 1
t 2 "githook: and a commit there is refused" env CODDY_ROOT="$tmp/gl" "$here/bin/coddy" githook pre-commit
rm -rf "$tmp/gl" "$tmp/glgit"
# a start inside a bare repository nested in the project: git took no .git at its root, so the walk still reaches the project's own, whose commondir is refused
mkdir -p "$dp/src"; git init -q --bare "$dp/src/b"; echo "$tmp/devil" > "$dp/.git/commondir"
t 2 "guard: from a bare repository nested in the project, a commondir in the project's git dir is refused" gdir "$dp/src/b"
t 2 "guard: and from its refs directory" gdir "$dp/src/b/refs"
rm -f "$dp/.git/commondir"
t 0 "guard: and from a bare repository nested in the project whose git dir is its own, the root stays the bare repository's parent, which holds no config, so the guard is inert, as it was" gdir "$dp/src/b"
rm -rf "$dp/.git/commondir" "$dp/src"
# the injected verbs and the rest, from a start whose git dir leads to another repository E (a commondir to E, a bare repository nested above a project .git holding one): none runs git there, so E's core.fsmonitor never runs, and none reports E as the root
mkdir -p "$tmp/sE"; git init -q "$tmp/sE"; printf '#!/bin/sh\ntouch "%s/sMark"\n' "$tmp" > "$tmp/sfsm"; chmod +x "$tmp/sfsm"; git -C "$tmp/sE" config core.fsmonitor "$tmp/sfsm"
mkdir -p "$tmp/sa/.git" "$tmp/sa/sub" "$tmp/sb/.git" "$tmp/sb/src"; echo "$tmp/sE/.git" > "$tmp/sa/.git/commondir"; echo "$tmp/sE/.git" > "$tmp/sb/.git/commondir"; git init -q --bare "$tmp/sb/src/b"
echo 'ref: refs/heads/main' > "$tmp/sa/.git/HEAD"; echo 'ref: refs/heads/main' > "$tmp/sb/.git/HEAD"
for sd in "$tmp/sa/sub" "$tmp/sb/src/b"; do
  for v in sweep status config detect; do
    t 0 "$v: from a start whose git dir leads to another repository (${sd#"$tmp"/}) exits 0 and runs none of its programs" sh -c "CODDY_ROOT='$sd' '$here/bin/coddy' $v >'$tmp/sout' 2>&1; e=\$?; [ \$e = 0 ] && [ ! -e '$tmp/sMark' ] && ! grep -q 'root: $tmp/sE' '$tmp/sout'"
  done
  t 2 "verify: and a verb that mutates refuses (${sd#"$tmp"/})" env CODDY_ROOT="$sd" "$here/bin/coddy" verify 1
  t 2 "exclude: and so does exclude (${sd#"$tmp"/})" env CODDY_ROOT="$sd" "$here/bin/coddy" exclude config
done
rm -rf "$tmp/sE" "$tmp/sa" "$tmp/sb" "$tmp/sfsm" "$tmp/sMark" "$tmp/sout"
# githook reads the root's .git/config and runs its hooks: from a bare repository nested in a project whose .git is a link to E's, it runs none of E's
mkdir -p "$tmp/hE/hooks" "$tmp/hp/src"; git init -q "$tmp/hE/r"; printf '#!/bin/sh\ntouch "%s/hMark"\n' "$tmp" > "$tmp/hE/r/.git/hooks/pre-commit"; chmod +x "$tmp/hE/r/.git/hooks/pre-commit"
cp "$tmp/dp.yml" "$tmp/hp/.coddy.yml"; ln -s "$tmp/hE/r/.git" "$tmp/hp/.git"; git init -q --bare "$tmp/hp/src/b"; git -C "$tmp/hp/src/b" config core.worktree "$tmp/hp/src"
t 2 "githook: a commit from a bare repository nested in a project whose .git is a link is refused" env CODDY_ROOT="$tmp/hp/src/b" "$here/bin/coddy" githook pre-commit
t 0 "githook: and runs none of the linked repository's hooks" test ! -e "$tmp/hMark"
rm -rf "$tmp/hE" "$tmp/hp" "$tmp/hMark"
# a session outside any project whose .git directory leads to an onboarded repository: the root is that repository, so the hooks refuse
mkdir -p "$tmp/d2/sub/.git" "$tmp/d2/.git/objects" "$tmp/d2/.git/refs"; echo 'ref: refs/heads/main' > "$tmp/d2/.git/HEAD"; echo "$dp/.git" > "$tmp/d2/.git/commondir"
t 2 "guard: a commondir to an onboarded repository above a rejected .git is refused" gdir "$tmp/d2/sub"
rm -rf "$tmp/d2"
# a session in an absorbed submodule of an onboarded project: doctor names the .git file, not a missing config
mkdir -p "$tmp/smsub" "$tmp/smsup"; git init -q "$tmp/smsub"; git -C "$tmp/smsub" -c user.name=t -c user.email=t@t commit -q --allow-empty -m i
git init -q "$tmp/smsup"; cp "$tmp/dp.yml" "$tmp/smsup/.coddy.yml"; git -C "$tmp/smsup" -c protocol.file.allow=always submodule add -q "$tmp/smsub" sm
t 0 "doctor: a session in an absorbed submodule is git_dir, naming its .git file" dsaysat "$tmp/smsup/sm" "^git_dir: $tmp/smsup/sm/.git is a file naming a git dir elsewhere"
t 1 "doctor: and exits 1" env CODDY_ROOT="$tmp/smsup/sm" "$here/bin/coddy" doctor
for v in config status detect; do
  t 0 "$v: a session in an absorbed submodule prints git_dir naming its .git file and the open-the-main-checkout fix" says "^git_dir: $tmp/smsup/sm/.git is a file naming a git dir elsewhere.*fix: open the session in the main checkout" env CODDY_ROOT="$tmp/smsup/sm" "$here/bin/coddy" $v
done
t 0 "verify: and a verb that refuses names the same file" says "$tmp/smsup/sm/.git is a file naming.*open the session in the main checkout" env CODDY_ROOT="$tmp/smsup/sm" "$here/bin/coddy" verify 1
rm -rf "$tmp/smsub" "$tmp/smsup"
# a relative root naming no directory ends
t 0 "root: a relative CODDY_ROOT naming no directory ends" timeout 10 env CODDY_ROOT=nosuchdir "$here/bin/coddy" status
t 0 "root: and one with a slash" timeout 10 env CODDY_ROOT=no/such "$here/bin/coddy" status
# proj in the environment makes nothing odd outside git
mkdir -p "$tmp/pj"
t 0 "doctor: outside any project, a proj in the environment changes nothing" env proj=1 CODDY_ROOT="$tmp/pj" "$here/bin/coddy" doctor
# a root outside git holding a config is a project: the config line, not silence
mkdir -p "$tmp/nogit"; cp "$tmp/dp.yml" "$tmp/nogit/.coddy.yml"
t 0 "doctor: a root outside git with a config is checked" dsaysat "$tmp/nogit" '^config: ok'
t 1 "doctor: and exits 1, git being absent" env CODDY_ROOT="$tmp/nogit" "$here/bin/coddy" doctor
sed -i.bak 's/^tracker:.*/tracker: jira/' "$dp/.coddy.yml"; rm "$dp/.coddy.yml.bak"; rm "$dp/.github/workflows/coddy.yml"
t 0 "doctor: the PR check is not checked under jira" dd doctor
cp "$tmp/dp.yml" "$dp/.coddy.yml"

exit $fail
