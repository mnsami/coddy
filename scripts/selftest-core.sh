#!/usr/bin/env bash
# Runs bin/hermy as any agent would: no CLAUDE_* variable set, its inputs
# from HERMY_ROOT, HERMY_SESSION, HERMY_PID and HERMY_AGENT_DIR, the config
# at .hermy.yml with .claude/coddy.yml as the fallback. The Claude Code shims
# under scripts/ and the full lifecycle are selftest.sh's.
# Usage: bash scripts/selftest-core.sh
set -u
for v in "${!CLAUDE_@}"; do unset "$v" 2>/dev/null; done; unset HERMY_AGENT_DIR HERMY_EXEC HERMY_HOOKS HERMY_REF 2>/dev/null
# macOS ships no timeout: perl's alarm, which the exec keeps, stands in (a run cut short exits 142, not 124)
command -v timeout >/dev/null || timeout() { perl -e 'alarm shift; exec { $ARGV[0] } @ARGV or exit 127' "$@"; }
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"; fail=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export HERMY_ROOT="$repo" HERMY_SESSION=sess-a HERMY_PID=$$

# t <expected exit> <name> <command...>
t() {
  want=$1 name=$2; shift 2
  "$@" >/dev/null 2>&1; got=$?
  if [ "$got" = "$want" ]; then echo "ok   $name"; else echo "FAIL $name (exit $got, want $want)"; fail=1; fi
}
run() { "$here/bin/hermy" "$@"; } # by its exec bit, as PATH would run it
as() { HERMY_SESSION=$1 HERMY_PID=$2 run "${@:3}"; }
says() { "${@:2}" 2>&1 | grep -q "$1"; }
quiet() { local o; o=$("$@" 2>&1) && [ -z "$o" ]; } # exits 0 and prints nothing
holds() { read -r a b _ < "$2" && [ "$a $b" = "$1" ]; }
# guard <path> [session]: the edit hook's payload; another session runs in another process
guard() { local s=${2-sess-a} p=1; [ "$s" != sess-a ] || p=$$; printf '{"session":"%s","paths":["%s"]}' "$s" "$1" | HERMY_PID=$p run guard; }
# asks <path>: guard exits 0 and asks the user, as hook JSON
asks() { out=$(guard "$1") && printf %s "$out" | jq -e '.hermy == "ask" and (.text | contains(".hermy.yml"))'; }
wire() { printf '{"call":"%s"}' "$2" | run "$1"; }
tripped() { wire snap w; (cd "$repo" && eval "$3") >/dev/null 2>&1; t "$1" "$2" wire trip w; }
# report <name> <shell snippet>: as tripped, with trip's exit in $r and its report in $out
report() { wire snap w; (cd "$repo" && eval "$2") >/dev/null 2>&1; out=$(wire trip w 2>&1); r=$?; t 0 "$1" test "$r" = 2; }
snapbase="${TMPDIR:-/tmp}/hermy-snap-$(printf %s "$repo" | cksum | cut -d' ' -f1)"
snapfile="$snapbase-call-w"
# The legacy config's records: its path with / as _ after the snapshot's name and a dot.
lgs="$snapfile.$(printf %s .claude/coddy.yml | tr / _)"
# rooted <dir> [VAR=value...]: status (or $verb) run from that directory prints the project root
rooted() { d=$1; shift; (cd "$d" && env "$@" "$here/bin/hermy" "${verb-status}" | grep -qx "root: $repo"); }
# A PATH with everything the guard needs but jq.
mkdir "$tmp/nojq"; for x in bash sh sed awk cat grep git cmp ps sort comm tr cut cksum mkdir cp rm head sleep stat xargs readlink; do p=$(command -v "$x") && ln -s "$p" "$tmp/nojq/$x"; done

git init -q --bare "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$repo" 2>/dev/null
cd "$repo" || exit 1
git checkout -q -b main; echo hi > README.md; git add -A; git commit -q -m init; git push -q -u origin main
mkdir .claude sub

t 1 "the core reads no CLAUDE_ variable" grep -q CLAUDE_ "$here/bin/hermy"
# nor an input under the name from before the rename (spelled as a class, so this line holds no old name)
t 1 "the core reads no input under the old name" grep -q 'C[O]DDY_' "$here/bin/hermy"
t 1 "the core names no host payload key or envelope" grep -qE 'tool_input|tool_use_id|session_id|hookSpecificOutput|permissionDecision|additionalContext|hookEventName' "$here/bin/hermy"
t 0 "root: from HERMY_ROOT" rooted /
t 0 "root: from the working directory without HERMY_ROOT" rooted "$repo" -u HERMY_ROOT
t 0 "root: from a subdirectory without HERMY_ROOT" rooted "$repo/sub" -u HERMY_ROOT
# A CDPATH would send the root's cd .git/.. elsewhere and print there: status
# from the main checkout reads as it does without one.
cdpath() { rooted "$repo" -u HERMY_ROOT CDPATH="$1" && (cd "$repo" && [ "$(env -u HERMY_ROOT CDPATH="$1" "$here/bin/hermy" status)" = "$(env -u HERMY_ROOT "$here/bin/hermy" status)" ]); }
git init -q "$tmp/other"
t 0 "root: a CDPATH of . prints no second line" cdpath .
t 0 "root: a CDPATH holding another repository does not move it" cdpath "$tmp/other"
# onboard writes every path under the root, so detect prints it as status does:
# a session opened in a subdirectory would otherwise write there.
verb=detect t 0 "detect: root, as status prints it" rooted /
verb=detect t 0 "detect: root from a subdirectory without HERMY_ROOT" rooted "$repo/sub" -u HERMY_ROOT
t 0 "config: NOT_ONBOARDED before onboarding" says '^NOT_ONBOARDED$' run config
t 0 "status: no config before onboarding" says '^config: none$' run status
t 0 "detect: no config" says '^config: none$' run detect
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
w=.github/workflows/hermy.yml
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
# Native Windows, which hermy does not run on: detect names it for onboard to
# stop on, and doctor says so and exits 1, here outside a project, for each
# name uname -s gives there. MINGW's stub, last, stays for doctor in a project.
mkdir "$tmp/mingw"
for u in CYGWIN_NT-10.0 MSYS_NT-10.0 Windows_NT MINGW64_NT-10.0; do
  printf '#!/bin/sh\necho %s\n' "$u" > "$tmp/mingw/uname"; chmod +x "$tmp/mingw/uname"
  PATH="$tmp/mingw:$PATH" t 0 "detect: os is windows under $u" says '^os: windows$' run detect
  PATH="$tmp/mingw:$PATH" t 0 "doctor: names an unsupported platform under $u" says "^platform: windows ($u) is not supported: hermy runs on macOS, Linux and WSL\$" env HERMY_ROOT="$tmp" "$here/bin/hermy" doctor
  PATH="$tmp/mingw:$PATH" t 1 "doctor: and exits 1 outside a project under $u" env HERMY_ROOT="$tmp" "$here/bin/hermy" doctor
done
t 1 "doctor: no platform line on a supported one" says '^platform:' env HERMY_ROOT="$tmp" "$here/bin/hermy" doctor
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
t 0 "exclude answers: and says so" says HERMY_AGENT_DIR run exclude answers
rm -r .git/info
HERMY_AGENT_DIR=.claude t 0 "exclude answers: appends the agent's hermy dir, making info/ when it is missing" says '^excluded: .claude/hermy$' run exclude answers
t 0 "exclude answers: the line is in info/exclude" grep -qx '.claude/hermy' .git/info/exclude
t 0 "exclude answers: and matches the answers file before its directory exists" git check-ignore -q .claude/hermy/onboard-answers.json
HERMY_AGENT_DIR=.claude t 0 "exclude answers: is a no-op the second time" says '^ignored already: .claude/hermy$' run exclude answers
HERMY_AGENT_DIR=.claude t 0 "exclude answers: from a subdirectory too" sh -c "cd '$repo/sub' && env -u HERMY_ROOT '$here/bin/hermy' exclude answers | grep -qx 'ignored already: .claude/hermy'"
t 0 "exclude answers: one line" test "$(grep -cx '.claude/hermy' .git/info/exclude)" = 1
HERMY_AGENT_DIR=.claude t 1 "forget answers: refuses before onboarding" run forget answers
HERMY_AGENT_DIR=.claude t 0 "forget answers: and says so" says NOT_ONBOARDED run forget answers
t 0 "guard allows everything before onboarding" guard "$repo/README.md"
t 0 "guard asks nothing for .hermy.yml before onboarding" test -z "$(guard "$repo/.hermy.yml")"
t 2 "trip without a snapshot trips before onboarding too: snap writes one before every command" wire trip none
# onboard installs jq inside one shell command, so snap runs without it and
# trip with it: the snapshot's name must not depend on jq.
PATH="$tmp/nojq" wire snap w; t 0 "before onboarding: snap without jq and trip with it name the same snapshot" wire trip w
tripped 0 "before onboarding: a shell write to the main checkout is quiet" 'echo x > stray.txt'; rm stray.txt
# BASHOPTS is readonly in bash, so env hands it on: nullglob must not read
# an empty glob of the marker's records as some.
wire snap w; t 0 "before onboarding: trip is quiet with nullglob inherited" env BASHOPTS=nullglob "$here/bin/hermy" trip <<<'{"call":"w"}'
t 1 "before onboarding: snap made nothing under .git" test -e .git/hermy
printf '#!/bin/sh\n: > "%s"\n' "$tmp/prevran" > .git/hooks/pre-commit; chmod +x .git/hooks/pre-commit
t 0 "before onboarding: githook hands off to the hook before it" run githook pre-commit
t 0 "before onboarding: which runs" test -e "$tmp/prevran"
rm .git/hooks/pre-commit "$tmp/prevran"

tripped 0 "onboarding: the command that writes the config is let through" 'printf "tracker: github\nworktree: git\ndefault_branch: main\nverify: test -f ok.txt\n" > .claude/coddy.yml'
t 0 "onboarding: and the config stands" test -f .claude/coddy.yml
t 0 "config: the legacy file, when it is the only one, is named for /hermy:migrate in its place" says '^MIGRATE: .claude/coddy.yml$' run config
t 1 "config: and not printed" says '^worktree: git$' run config
t 0 "status names the legacy file" says '^config: .claude/coddy.yml$' run status
t 0 "detect names the legacy file alone" says '^config: .claude/coddy.yml$' run detect
printf 'tracker: github\nworktree: git\ndefault_branch: main\nverify: test -f ok.txt\nroadmap: R.md\n' > .hermy.yml
t 0 "config: .hermy.yml is read before the legacy file" says '^roadmap: R.md$' run config
t 0 "status names .hermy.yml" says '^config: .hermy.yml$' run status
# .coddy.yml, from before the rename, sits between the two.
printf 'tracker: github\nworktree: git\ndefault_branch: main\nverify: test -f ok.txt\nroadmap: M.md\n' > .coddy.yml
t 0 "config: .hermy.yml is read before .coddy.yml" says '^roadmap: R.md$' run config
mv .hermy.yml "$tmp/h.yml"
t 0 "config: .coddy.yml is read before the legacy file, and named for /hermy:migrate" says '^MIGRATE: .coddy.yml$' run config
t 0 "status names .coddy.yml" says '^config: .coddy.yml$' run status
t 0 "detect names .coddy.yml" says '^config: .coddy.yml$' run detect
rm .coddy.yml; mv "$tmp/h.yml" .hermy.yml
rm .claude/coddy.yml
t 0 "config: .hermy.yml alone" says '^roadmap: R.md$' run config
t 0 "detect names .hermy.yml" says '^config: .hermy.yml$' run detect
t 0 "detect: .hermy.yml is not ignored" says '^config_ignored: no$' run detect
printf '*.log' >> .git/info/exclude # a last line without its newline
t 0 "exclude config: appends .hermy.yml" says '^excluded: .hermy.yml$' run exclude config
t 0 "exclude config: on a line of its own, the last line left whole" grep -qx '\*\.log' .git/info/exclude
t 0 "detect: .hermy.yml is ignored once excluded" says '^config_ignored: yes$' run detect
t 0 "exclude config: is a no-op the second time" says '^ignored already: .hermy.yml$' run exclude config
t 0 "exclude config: one line" test "$(grep -cx '.hermy.yml' .git/info/exclude)" = 1
mkdir -p .claude/hermy/backup; echo '{}' > .claude/hermy/onboard-answers.json; echo x > .claude/hermy/backup/x
t 1 "forget answers: needs the agent dir" run forget answers
t 1 "forget: an unknown target is refused" env HERMY_AGENT_DIR=.claude "$here/bin/hermy" forget other
HERMY_AGENT_DIR=.claude t 0 "forget answers: removes the answers file once onboarded" says '^removed: .claude/hermy/onboard-answers.json$' run forget answers
t 1 "forget answers: and it is gone" test -e .claude/hermy/onboard-answers.json
t 0 "forget answers: the backups stay" test -f .claude/hermy/backup/x
HERMY_AGENT_DIR=.claude t 0 "forget answers: is quiet when the file is gone already" run forget answers
rm -r .claude/hermy
# migrate prints the config brought up to the current version and writes
# nothing; /hermy:migrate writes it. No version is 0, wherever the file is.
mv .hermy.yml "$tmp/live.yml"
printf '# team config\ntracker: github   # the tracker\nworktree: git\n\ndefault_branch: main\nverify: test -f ok.txt\n' > .claude/coddy.yml
{ echo 'version: 2'; cat .claude/coddy.yml; } > "$tmp/v1.yml"
cp .claude/coddy.yml "$tmp/v0.yml"
t 0 "migrate: a legacy file without version is 0" says '^from: 0$' run migrate
t 0 "migrate: says it adds the version" says '^changed: add version: 1$' run migrate
t 0 "migrate: and moves the legacy file" says '^changed: move .claude/coddy.yml -> .hermy.yml$' run migrate
t 0 "migrate: says an untracked legacy file is untracked" says '^tracked: no$' run migrate
git add -f .claude/coddy.yml
t 0 "migrate: and a tracked one tracked" says '^tracked: yes$' run migrate
git rm -q --cached .claude/coddy.yml
printf 'version: 0\r\ntracker: github\r\n' > .claude/coddy.yml
t 0 "migrate: a CRLF config reads its version" says '^from: 0$' run migrate
cp "$tmp/v0.yml" .claude/coddy.yml
t 0 "migrate: the file after --- is the expected v2, comments kept" sh -c "'$here/bin/hermy' migrate | sed '1,/^---\$/d' | cmp -s - '$tmp/v1.yml'"
t 0 "migrate: writes nothing" cmp -s .claude/coddy.yml "$tmp/v0.yml"
t 1 "migrate: and makes no .hermy.yml" test -e .hermy.yml
cp "$tmp/v1.yml" .hermy.yml
t 0 "migrate: a current config next to a leftover legacy file says remove" says '^changed: remove .claude/coddy.yml$' run migrate
t 1 "migrate: and prints no file" says '^---$' run migrate
rm .claude/coddy.yml
t 0 "migrate: a v2 config is current" says '^to: 2$' run migrate
t 1 "migrate: and prints no change" says '^changed:' run migrate
t 1 "migrate: nor a file" says '^---$' run migrate
printf 'version: 99\ntracker: github\n' > .hermy.yml
t 1 "migrate: a version above the current one is refused" run migrate
t 0 "migrate: naming the plugin update" says 'update the hermy plugin' run migrate
printf 'version: 12345678901234567890\ntracker: github\n' > .hermy.yml
t 0 "migrate: a version too long for bash is refused as newer" says 'update the hermy plugin' run migrate
t 1 "migrate: with no bash error" says 'integer' run migrate
printf 'version: 1 \ntracker: github\n' > .hermy.yml
t 0 "migrate: a version with trailing whitespace is read" says '^from: 1$' run migrate
t 0 "migrate: a v1 config moves to 2" says '^to: 2$' run migrate
t 0 "migrate: says what step 2 changes" says '^changed: add version: 2, and worktree: jj when no worktree key is set$' run migrate
t 1 "migrate: and runs no step 1" says '^changed: add version: 1$' run migrate
printf 'version: 1\ntracker: github\n' > .hermy.yml; printf 'version: 2\nworktree: jj\ntracker: github\n' > "$tmp/want.yml"
t 0 "migrate: a v1 config without worktree keeps jj" sh -c "'$here/bin/hermy' migrate | sed '1,/^---\$/d' | cmp -s - '$tmp/want.yml'"
printf 'version: 1\ntracker: github\nworktree: git\n' > .hermy.yml; printf 'version: 2\ntracker: github\nworktree: git\n' > "$tmp/want.yml"
t 0 "migrate: a v1 config with worktree gets the version alone" sh -c "'$here/bin/hermy' migrate | sed '1,/^---\$/d' | cmp -s - '$tmp/want.yml'"
printf 'version: 1\ntracker: github\nworktree:   # jj | git\n' > .hermy.yml; printf 'version: 2\ntracker: github\nworktree: jj\n' > "$tmp/want.yml"
t 0 "migrate: an empty worktree key, read as jj before 2, becomes worktree: jj" sh -c "'$here/bin/hermy' migrate | sed '1,/^---\$/d' | cmp -s - '$tmp/want.yml'"
# after <file>: the file migrate prints after its first --- line is <file>
after() { "$here/bin/hermy" migrate | sed '1,/^---$/d' | cmp -s - "$1"; }
rm .hermy.yml
printf -- '---\ntracker: github\n' > .claude/coddy.yml; printf -- '---\nversion: 2\nworktree: jj\ntracker: github\n' > "$tmp/want.yml"
t 0 "migrate: a leading --- keeps version below it" after "$tmp/want.yml"
printf 'tracker: github\r\n' > .claude/coddy.yml; printf 'version: 2\r\nworktree: jj\r\ntracker: github\r\n' > "$tmp/want.yml"
t 0 "migrate: a CRLF config gets a CRLF version line" after "$tmp/want.yml"
printf 'tracker: github\n\n\n' > .claude/coddy.yml; printf 'version: 2\nworktree: jj\ntracker: github\n\n\n' > "$tmp/want.yml"
t 0 "migrate: trailing blank lines are kept" after "$tmp/want.yml"
cp "$tmp/v0.yml" .claude/coddy.yml
ln -s missing.yml .hermy.yml
t 1 "migrate: a dangling .hermy.yml link is refused" run migrate
t 1 "migrate: before any file" says '^---$' run migrate
rm .hermy.yml; ln -s .claude/coddy.yml .hermy.yml
t 1 "migrate: a .hermy.yml link to a file is refused" run migrate
rm .hermy.yml; mkdir .hermy.yml
t 1 "migrate: a .hermy.yml directory is refused" run migrate
rmdir .hermy.yml
mv .claude/coddy.yml "$tmp/legacy.yml"; ln -s "$tmp/legacy.yml" .claude/coddy.yml
t 1 "migrate: a legacy source that is a link is refused" run migrate
rm .claude/coddy.yml; cp "$tmp/v1.yml" .hermy.yml
for k in file link dir; do
  case $k in file) cp "$tmp/v0.yml" .claude/coddy.yml ;; link) ln -s "$tmp/legacy.yml" .claude/coddy.yml ;; dir) mkdir .claude/coddy.yml ;; esac
  t 0 "migrate: a leftover legacy $k says its kind and path" says "^legacy: $k .claude/coddy.yml\$" run migrate
  rm -r .claude/coddy.yml
done
# .coddy.yml, from before the rename, moves the same way, and is a leftover below .hermy.yml.
rm .hermy.yml; cp "$tmp/v0.yml" .coddy.yml
t 0 "migrate: moves .coddy.yml" says '^changed: move .coddy.yml -> .hermy.yml$' run migrate
t 0 "migrate: says an untracked .coddy.yml is untracked" says '^tracked: no$' run migrate
t 0 "migrate: the file after --- is the expected v2" after "$tmp/v1.yml"
cp "$tmp/v0.yml" .claude/coddy.yml
t 0 "migrate: a legacy file below a live .coddy.yml is a leftover" says '^legacy: file .claude/coddy.yml$' run migrate
rm .claude/coddy.yml .coddy.yml; ln -s "$tmp/v0.yml" .coddy.yml
t 1 "migrate: a .coddy.yml source that is a link is refused" run migrate
rm .coddy.yml; cp "$tmp/v1.yml" .hermy.yml; cp "$tmp/v0.yml" .coddy.yml
t 0 "migrate: a .coddy.yml below a current .hermy.yml says remove" says '^changed: remove .coddy.yml$' run migrate
t 0 "migrate: and its kind and path" says '^legacy: file .coddy.yml$' run migrate
t 1 "migrate: and prints no file for it" says '^---$' run migrate
cp "$tmp/v0.yml" .claude/coddy.yml
t 0 "migrate: both below a current .hermy.yml say remove, each" sh -c "'$here/bin/hermy' migrate | grep -c '^changed: remove \\(.coddy.yml\\|.claude/coddy.yml\\)\$' | grep -qx 2"
rm .coddy.yml .claude/coddy.yml
# The records from before the rename: migrate names their move, and the PR
# check's workflow to rename in a PR, writing nothing; migrate records moves
# them, a directory at both merged one level down and a name taken there
# kept, and refuses a link at any of its four paths before moving anything.
AGENT_DIR=.claude
mkdir -p .git/coddy/7 .git/coddy/swept/7 .git/coddy/swept/8/a .git/coddy/.snap-x "$AGENT_DIR/coddy/backup/1" .github/workflows
printf 'sess-x 1 a b\n' > .git/coddy/7/owner; echo feat/7-x > .git/coddy/7.branch; echo b > "$AGENT_DIR/coddy/backup/1/x"; : > .github/workflows/coddy.yml
t 0 "migrate: a current config with records from before the rename names their move" says '^changed: move .git/coddy -> .git/hermy$' run migrate
HERMY_AGENT_DIR=.claude t 0 "migrate: and the agent dir's" says "^changed: move $AGENT_DIR/coddy -> $AGENT_DIR/hermy\$" run migrate
t 1 "migrate: not the agent dir's without HERMY_AGENT_DIR" says "^changed: move $AGENT_DIR/coddy" run migrate
t 0 "migrate: names the workflow to rename" says '^rename: .github/workflows/coddy.yml$' run migrate
t 1 "migrate: and prints no file for them" says '^---$' run migrate
t 0 "migrate: having moved nothing" sh -c "test -s .git/coddy/7/owner && ! test -e .git/hermy/7 && ! test -e '$AGENT_DIR/hermy'"
: > .github/workflows/hermy.yml
t 1 "migrate: no rename once hermy.yml is there" says '^rename:' run migrate
rm -r .github
mkdir "$tmp/lnk"
for p in .git/coddy .git/hermy "$AGENT_DIR/coddy" "$AGENT_DIR/hermy"; do
  [ ! -d "$p" ] || mv "$p" "$tmp/lnk/d"
  ln -s "$tmp/lnk/d" "$p"
  HERMY_AGENT_DIR=.claude t 1 "migrate records: a link at $p is refused" run migrate records
  rm "$p"; [ ! -d "$tmp/lnk/d" ] || mv "$tmp/lnk/d" "$p"
done
rmdir "$tmp/lnk"
t 0 "migrate records: having moved nothing" sh -c "test -s .git/coddy/7/owner && test -s '$AGENT_DIR/coddy/backup/1/x' && ! test -e .git/hermy/7 && ! test -e '$AGENT_DIR/hermy'"
mkdir -p .git/hermy/swept/8; cp .git/coddy/7/owner "$tmp/owner7"
HERMY_AGENT_DIR=.claude run migrate records > "$tmp/mr.out" 2>&1; r=$?
t 0 "migrate records: runs" test "$r" = 0
for l in 'moved: .git/coddy/7 -> .git/hermy/7' 'moved: .git/coddy/7.branch -> .git/hermy/7.branch' 'moved: .git/coddy/.snap-x -> .git/hermy/.snap-x' \
  'moved: .git/coddy/swept/7 -> .git/hermy/swept/7' 'kept: .git/coddy/swept/8' "moved: $AGENT_DIR/coddy/backup -> $AGENT_DIR/hermy/backup"; do
  t 0 "migrate records: prints $l" grep -qxF "$l" "$tmp/mr.out"
done
t 0 "migrate records: one line per entry" test "$(wc -l < "$tmp/mr.out")" -eq 6
t 0 "migrate records: the owner line byte for byte" cmp -s .git/hermy/7/owner "$tmp/owner7"
t 0 "migrate records: a name taken is left where it was" test -d .git/coddy/swept/8/a -a -d .git/hermy/swept/8 -a ! -e .git/hermy/swept/8/a
t 0 "migrate records: an emptied source goes" test ! -e "$AGENT_DIR/coddy"
t 0 "migrate: what is left is still named" says '^changed: move .git/coddy -> .git/hermy$' run migrate
t 0 "migrate records: a rerun moves nothing more" test "$(HERMY_AGENT_DIR=.claude run migrate records 2>&1)" = 'kept: .git/coddy/swept/8'
rm -r .git/coddy/swept/8
HERMY_AGENT_DIR=.claude t 0 "migrate records: once nothing is left, quietly" quiet run migrate records
t 0 "migrate records: and .git/coddy goes" test ! -e .git/coddy
HERMY_AGENT_DIR=.claude t 1 "migrate: and no move is named" says '^changed: move' run migrate
rm -r .git/hermy/7 .git/hermy/7.branch .git/hermy/.snap-x .git/hermy/swept "$AGENT_DIR/hermy"
mv "$tmp/live.yml" .hermy.yml

# Editing .hermy.yml is for the user to allow, in both guard modes; without
# jq the guard cannot tell which path is edited and fails closed.
t 0 "guard asks on .hermy.yml" asks "$repo/.hermy.yml"
for p in "$repo/./.hermy.yml" "$repo//.hermy.yml" "$repo/sub/../.hermy.yml" "$repo/.HERMY.YML" .hermy.yml; do t 0 "guard asks on .hermy.yml spelled $p" asks "$p"; done
# A shim whose host cannot ask sets HERMY_ASK=0: the ask blocks, saying so.
HERMY_ASK=0 t 2 "guard: under HERMY_ASK=0 the ask on .hermy.yml blocks" guard "$repo/.hermy.yml"
HERMY_ASK=0 t 0 "guard: that refusal says the host cannot ask" says 'This host cannot ask, so hermy refuses it' guard "$repo/.hermy.yml"
HERMY_ASK=1 t 0 "guard: any other HERMY_ASK still asks" asks "$repo/.hermy.yml"
# .coddy.yml, from before the rename, below a live .hermy.yml is let go by the
# config lock, so an edit of it is held like any path in the main checkout, and
# one that is a link to .git/config is refused, never asked.
casks() { out=$(guard "$1") && printf %s "$out" | jq -e '.hermy == "ask" and (.text | contains(".coddy.yml"))'; }
t 2 "guard does not ask on .coddy.yml below a live .hermy.yml" guard "$repo/.coddy.yml"
t 0 "guard: holding it as the main checkout" says 'edits belong in an issue worktree' guard "$repo/.coddy.yml"
ln -s .git/config .coddy.yml
t 2 "guard refuses a .coddy.yml below a live .hermy.yml that is a link to .git/config" guard "$repo/.coddy.yml"
t 0 "guard: as a .git path, not asked" says 'lies in a .git or .jj below the project root' guard "$repo/.coddy.yml"
rm .coddy.yml
# Live while .hermy.yml is absent, it is asked, and so is .hermy.yml above it.
mv .hermy.yml .coddy.yml
for p in "$repo/.coddy.yml" "$repo/sub/../.coddy.yml" "$repo/.CODDY.YML"; do t 0 "guard asks on a live .coddy.yml spelled $p" casks "$p"; done
t 0 "guard asks on .hermy.yml above a live .coddy.yml" asks "$repo/.hermy.yml"
# The legacy .claude/coddy.yml below it lies in the agent dir, free like any
# path there, and one that is a link to .git/config is refused.
lasks() { out=$(guard "$1") && jq -e '.hermy == "ask" and (.text | contains(".claude/coddy.yml"))' <<<"$out"; }
HERMY_AGENT_DIR=.claude t 0 "guard does not ask on the legacy config below a live .coddy.yml" quiet guard "$repo/.claude/coddy.yml"
ln -s ../.git/config .claude/coddy.yml
HERMY_AGENT_DIR=.claude t 2 "guard refuses a legacy config below a live .coddy.yml that is a link to .git/config" guard "$repo/.claude/coddy.yml"
rm .claude/coddy.yml
# Live while both above it are absent, it is asked, and so are both above it.
mv .coddy.yml .claude/coddy.yml
HERMY_AGENT_DIR=.claude t 0 "guard asks on a live legacy config" lasks "$repo/.claude/coddy.yml"
HERMY_AGENT_DIR=.claude t 0 "guard asks on .coddy.yml above a live legacy config" casks "$repo/.coddy.yml"
HERMY_AGENT_DIR=.claude t 0 "guard asks on .hermy.yml above a live legacy config" asks "$repo/.hermy.yml"
mv .claude/coddy.yml .hermy.yml
# The Write tool collapses .. by name before it writes, so a .. after a link
# out of the project still lands on the root's .hermy.yml.
mkdir -p "$tmp/out/deep" && ln -s "$tmp/out/deep" lnk
t 0 "guard asks on .hermy.yml spelled through .. after a link out of the project" asks "$repo/lnk/../.hermy.yml"
# And is compared with .hermy.yml spelled so: a .. after a link back into
# the project lands outside it, where it is refused for its ..
mkdir s2d && ln -s "$repo/s2d" "$tmp/s2"
t 2 "guard reads .. by name, so one after a link back into the project is not .hermy.yml" guard "$tmp/s2/../.hermy.yml"
rm -r s2d "$tmp/s2"
t 2 "guard blocks the main checkout" guard "$repo/README.md"
# The hooks drop every PATH entry at or under the root they resolve before
# they run a tool, so one opened in a subdirectory, whose launcher went by
# that directory, runs no jq or sed planted in the root.
mkdir nm; for x in sed jq; do printf '#!/bin/sh\necho %s >> "%s/planted"\nexit 0\n' "$x" "$tmp" > "nm/$x"; chmod +x "nm/$x"; done
PATH="$repo/nm:$PATH" HERMY_ROOT="$repo/sub" t 0 "hooks: guard from a subdirectory reads the payload past a jq in the root" says 'edits belong in an issue worktree' guard "$repo/README.md"
PATH="$repo/nm:$PATH" HERMY_ROOT="$repo/sub" wire snap w; echo x > stray.txt
PATH="$repo/nm:$PATH" HERMY_ROOT="$repo/sub" t 2 "hooks: snap and trip from a subdirectory, past a jq and a sed in the root, still trip" wire trip w
t 1 "hooks: and none ran a planted one" test -e "$tmp/planted"
rm stray.txt
# A link on the way counts, not only where the entry lands: nl, a link in the
# root to a directory outside it, and via, one outside through nl.
mkdir "$tmp/lo"; cp nm/* "$tmp/lo/"; ln -s "$tmp/lo" nl; ln -s "$repo/nl" "$tmp/via"
for p in "$repo/nl" "$tmp/via"; do
  PATH="$p:$PATH" HERMY_ROOT="$repo/sub" t 0 "hooks: guard from a subdirectory reads the payload past a jq through a link in the root ($p)" says 'edits belong in an issue worktree' guard "$repo/README.md"
  PATH="$p:$PATH" HERMY_ROOT="$repo/sub" wire snap w; echo x > stray.txt
  PATH="$p:$PATH" HERMY_ROOT="$repo/sub" t 2 "hooks: snap and trip from a subdirectory, past a jq and a sed through a link in the root, still trip ($p)" wire trip w; rm stray.txt
done
t 1 "hooks: and none ran a planted one through a link" test -e "$tmp/planted"
rm -r nm nl "$tmp/lo" "$tmp/via"
# The fingerprint hashes a dirty file as it is: a clean filter the
# attributes name is a program, and none runs.
git config filter.mark.clean "echo x >> '$tmp/filtered'; cat"; echo 'filtered.txt filter=mark' > .git/info/attributes; echo x > filtered.txt
tripped 0 "fingerprint: a dirty file under a clean filter, unchanged, is quiet" 'true'
tripped 2 "fingerprint: and changed, trips" 'echo y > filtered.txt'
t 1 "fingerprint: and no clean filter ran" test -e "$tmp/filtered"
rm .git/info/attributes filtered.txt; git config --unset filter.mark.clean
# git status writes the index for a tracked file whose stat changed, which
# fires post-index-change from core.hooksPath: a directory in the project
# here (husky's .husky/_, a .githooks). The fingerprint writes no index and
# runs no hook.
mkdir .githooks; printf '#!/bin/sh\necho x >> "%s"\n' "$tmp/indexed" > .githooks/post-index-change; chmod +x .githooks/post-index-change
git config core.hooksPath .githooks; touch README.md
tripped 0 "fingerprint: a touched tracked file under a core.hooksPath in the project is quiet" 'touch README.md'
t 1 "fingerprint: and no post-index-change ran" test -e "$tmp/indexed"
git config --unset core.hooksPath; rm -r .githooks
PATH="$tmp/nojq" t 2 "guard without jq fails closed" guard "$repo/.hermy.yml"
echo 'guard: warn' >> .hermy.yml
t 0 "warn: guard still asks on .hermy.yml" asks "$repo/.hermy.yml"
t 0 "warn: and spelled through .." asks "$repo/sub/../.hermy.yml"
t 0 "warn: and through .. after a link out of the project" asks "$repo/lnk/../.hermy.yml"
rm lnk
t 0 "warn: guard lets the main checkout through" guard "$repo/README.md"
# un, snap's unchecked notice, is the core's own: one in the environment (a
# settings env) reaches no guard notice.
out=$(un=XYZ guard "$repo/README.md")
t 0 "warn: guard's notice says the edit was let through" grep -q 'was let through' <<<"$out"
t 1 "warn: and carries no un from the environment" grep -q XYZ <<<"$out"
PATH="$tmp/nojq" t 2 "warn: guard without jq fails closed" guard "$repo/.hermy.yml"
sed -i.bak '/^guard:/d' .hermy.yml && rm .hermy.yml.bak
wire snap flow

# The config lock holds both paths: .hermy.yml is restored, and one created
# while .claude/coddy.yml was the live config is removed, so it cannot shadow it.
cp .hermy.yml "$tmp/conf.orig"
same() { cmp -s "$repo/$1" "$tmp/conf.orig"; }
tripped 2 "config: deleting .hermy.yml trips" 'rm .hermy.yml'
t 0 "config: restored after the deletion" same .hermy.yml
tripped 2 "config: rewriting .hermy.yml trips" 'echo "verify: true" >> .hermy.yml'
t 0 "config: restored after the rewrite" same .hermy.yml
t 0 "config: that report names the file" says 'changed .hermy.yml' sh -c "cd '$repo' && printf '{\"call\":\"w\"}' | '$here/bin/hermy' snap && echo x >> .hermy.yml && printf '{\"call\":\"w\"}' | '$here/bin/hermy' trip"
tripped 2 "config: a link in its place trips, the same content behind it" 'cp .hermy.yml "$tmp/else" && ln -sf "$tmp/else" .hermy.yml'
t 1 "config: and the link is gone" test -L .hermy.yml
t 0 "config: a file with its content back" same .hermy.yml
tripped 2 "config: a directory in its place trips" 'rm .hermy.yml && mkdir .hermy.yml'
t 0 "config: and the file is back" same .hermy.yml
# A config the user keeps as a link is not a change; retargeting the link,
# or writing the file behind it, is, and what comes back is a plain file.
mv .hermy.yml "$tmp/linked"; ln -s "$tmp/linked" .hermy.yml
tripped 0 "config: a config that was a link already is left alone" 'true'
t 0 "config: and is still that link" test -L .hermy.yml
# TMPDIR is the command's to write too: snap writes no record through a link
# a background command plants at its name once snap has cleared it, to a file
# or to nothing, and the snapshot is lost. A stub head, which cfg runs after
# the clearing, plants one at every name.
mkdir "$tmp/plant"
for v in "$tmp/victim" "$tmp/nothing"; do
  echo keep > "$tmp/victim"
  printf '#!/bin/sh\nfor n in "" .wt ..hermy.yml ..hermy.yml.kind ..hermy.yml.link ..coddy.yml ..coddy.yml.kind ..coddy.yml.link .%s .%s.kind .%s.link; do ln -s "%s" "%s$n" 2>/dev/null; done\nexec "%s" "$@"\n' "${lgs#"$snapfile."}" "${lgs#"$snapfile."}" "${lgs#"$snapfile."}" "$v" "$snapfile" "$(command -v head)" > "$tmp/plant/head"; chmod +x "$tmp/plant/head"
  PATH="$tmp/plant:$PATH" wire snap w 2>/dev/null
  t 0 "snapshot: a link planted at each name is not written through: ${v##*/}" test "$(cat "$tmp/victim")" = keep
  t 1 "snapshot: nor is its target made: ${v##*/}" test -e "$tmp/nothing"
  t 2 "snapshot: and trip reports it lost: ${v##*/}" wire trip w
  rm -f "$snapfile" "$snapfile".*
done
# A record that fails drops the others too: a link planted at the
# fingerprint's alone leaves no copy of the config behind.
printf '#!/bin/sh\nln -s "%s" "%s.wt" 2>/dev/null\nexec "%s" "$@"\n' "$tmp/nothing" "$snapfile" "$(command -v head)" > "$tmp/plant/head"
PATH="$tmp/plant:$PATH" wire snap w 2>/dev/null
none() { for f in "$snapfile"*; do [ ! -e "$f" ] && [ ! -L "$f" ] || return 1; done; }
t 0 "snapshot: a record that fails leaves none of the others" none
t 2 "snapshot: and trip reports it lost" wire trip w
rm -r "$tmp/plant" "$tmp/victim"
tripped 2 "config: retargeting the link trips, the same content behind it" 'ln -sf "$tmp/else" .hermy.yml'
t 1 "config: and the link is gone" test -L .hermy.yml
t 0 "config: a plain file with its content back" same .hermy.yml
ln -sf "$tmp/linked" .hermy.yml
tripped 2 "config: writing the file behind the link trips" 'echo "verify: true" >> "$tmp/linked"'
t 1 "config: and the link is gone" test -L .hermy.yml
t 0 "config: a plain file with its content back" same .hermy.yml
# A restore the file system refuses is reported as such, with its copy kept.
if [ "$(id -u)" != 0 ]; then
  copy="$snapfile..hermy.yml"
  wire snap w; rm .hermy.yml; chmod a-w .; out=$(wire trip w 2>&1); r=$?; chmod u+w .
  t 0 "config: a restore the directory refuses still trips" test "$r" = 2
  t 0 "config: and says the file could not be put back" grep -q 'could not be put back' <<<"$out"
  t 0 "config: keeping its copy" cmp -s "$copy" "$tmp/conf.orig"
  cp "$tmp/conf.orig" .hermy.yml; rm -f "$copy"
fi
mv .hermy.yml .claude/coddy.yml
tripped 2 "config: a .hermy.yml created next to the live legacy file trips" 'cp .claude/coddy.yml .hermy.yml'
t 1 "config: and is removed" test -e .hermy.yml
t 0 "config: the legacy file stands" same .claude/coddy.yml
ln -s ../.hermy.yml .claude/cfg
HERMY_AGENT_DIR=.claude t 0 "guard asks on a dangling link to .hermy.yml from the agent dir while the legacy file is live" asks "$repo/.claude/cfg"
rm .claude/cfg
ln -s ../.hermy.yml .claude/c10; for i in 9 8 7 6 5 4 3 2 1; do ln -s "c$((i+1))" ".claude/c$i"; done
HERMY_AGENT_DIR=.claude t 0 "guard asks through a dangling chain of ten links" asks "$repo/.claude/c1"
rm .claude/c[0-9]*
# A path the walk cannot follow is refused before warn mode: let through, a
# write may land on a .hermy.yml not made yet, which nothing asked about.
ln -s ../.hermy.yml .claude/c41; for i in $(seq 40 -1 1); do ln -s "c$((i+1))" ".claude/c$i"; done
echo 'guard: warn' >> .claude/coddy.yml
HERMY_AGENT_DIR=.claude t 2 "warn: guard refuses a chain of 41 links to .hermy.yml while the legacy file is live" guard "$repo/.claude/c1"
cp "$tmp/conf.orig" .claude/coddy.yml; rm .claude/c[0-9]*
tripped 2 "config: deleting the legacy file trips" 'rm .claude/coddy.yml'
t 0 "config: the legacy file is restored" same .claude/coddy.yml
# Once .hermy.yml is live the legacy file is ignored, so the lock lets it go.
# .claude is the agent dir here, as from the shims, so the tripwire skips it too.
cp .claude/coddy.yml .hermy.yml
HERMY_AGENT_DIR=.claude tripped 0 "config: changing the legacy file next to a live .hermy.yml is quiet" 'echo "verify: true" >> .claude/coddy.yml'
t 0 "config: and the change stands" grep -q '^verify: true$' .claude/coddy.yml
HERMY_AGENT_DIR=.claude tripped 0 "config: deleting the legacy file next to a live .hermy.yml is quiet" 'rm .claude/coddy.yml'
t 1 "config: and it is not restored" test -e .claude/coddy.yml
# So snap records its kind alone: a sparse 1 TiB one stalls no snap.
dd if=/dev/null of=.claude/coddy.yml bs=1048576 seek=1048576 count=0 2>/dev/null
t 0 "config: a sparse 1 TiB legacy file next to a live .hermy.yml does not stall snap" timeout 10 sh -c "printf '{\"call\":\"w\"}' | '$here/bin/hermy' snap"
t 0 "config: which records its kind" test "$(cat "$lgs.kind")" = file
t 1 "config: and no copy of it" test -e "$lgs"
t 0 "config: and trip lets it go" wire trip w
rm .claude/coddy.yml
# .coddy.yml, from before the rename, sits between the two: restored while it
# is live, a .hermy.yml made above it removed, a .coddy.yml made above the
# live legacy file removed, and let go below a live .hermy.yml, as the legacy
# file is below a live .coddy.yml.
mv .hermy.yml .coddy.yml
tripped 2 "config: deleting a live .coddy.yml trips" 'rm .coddy.yml'
t 0 "config: and it is restored" same .coddy.yml
tripped 2 "config: a .hermy.yml created next to a live .coddy.yml trips" 'cp .coddy.yml .hermy.yml'
t 1 "config: and is removed" test -e .hermy.yml
t 0 "config: the .coddy.yml stands" same .coddy.yml
# One the directory keeps from removal is reported as such, and as now live.
if [ "$(id -u)" != 0 ]; then # root writes anywhere
  wire snap w; cp .coddy.yml .hermy.yml; chmod a-w .; out=$(wire trip w 2>&1); r=$?; chmod u+w .
  t 0 "config: a .hermy.yml the directory keeps from removal still trips" test "$r" = 2
  t 0 "config: and says it could not be removed and is now the live config" grep -q 'changed .hermy.yml, which switches the hermy guardrails, and it could not be removed, so it is now the live config' <<<"$out"
  t 1 "config: never that it has been removed" grep -q 'has been removed' <<<"$out"
  rm .hermy.yml
fi
mv .coddy.yml .claude/coddy.yml
tripped 2 "config: a .coddy.yml created next to the live legacy file trips" 'cp .claude/coddy.yml .coddy.yml'
t 1 "config: and is removed" test -e .coddy.yml
cp .claude/coddy.yml .coddy.yml
HERMY_AGENT_DIR=.claude tripped 0 "config: changing the legacy file next to a live .coddy.yml is quiet" 'echo "verify: true" >> .claude/coddy.yml'
t 0 "config: and the change stands" grep -q '^verify: true$' .claude/coddy.yml
HERMY_AGENT_DIR=.claude tripped 0 "config: deleting the legacy file next to a live .coddy.yml is quiet" 'rm .claude/coddy.yml'
t 1 "config: and it is not restored" test -e .claude/coddy.yml
t 0 "config: the live .coddy.yml stands" same .coddy.yml
mv .coddy.yml .hermy.yml; cp .hermy.yml .coddy.yml
tripped 0 "config: changing .coddy.yml next to a live .hermy.yml is quiet" 'echo "verify: true" >> .coddy.yml'
t 0 "config: and the change stands" grep -q '^verify: true$' .coddy.yml
tripped 0 "config: deleting .coddy.yml next to a live .hermy.yml is quiet" 'rm .coddy.yml'
t 1 "config: and it is not restored" test -e .coddy.yml
t 0 "config: the .hermy.yml stands" same .hermy.yml
# A copy holds 64 KiB and a byte at most, so a .hermy.yml past 64 KiB could
# not be put back: snap refuses every command while it is, in either guard
# mode, naming /hermy:config, its size read from 64 KiB and a byte at most,
# so a sparse 1 TiB one is refused at once.
{ cat "$tmp/conf.orig"; head -c 66000 /dev/zero | tr '\0' '#'; echo; } > .hermy.yml; cp .hermy.yml "$tmp/conf.big"
t 2 "config: snap refuses every command while .hermy.yml is over 64 KiB" wire snap w
t 0 "config: naming /hermy:config" says '.hermy.yml is over 64 KiB, .*with /hermy:config' wire snap w
t 0 "config: and leaving no record" none
echo 'guard: warn' >> .hermy.yml
t 2 "config: under guard: warn too" wire snap w
dd if=/dev/null of=.hermy.yml bs=1048576 seek=1048576 count=0 2>/dev/null
t 2 "config: a sparse 1 TiB .hermy.yml is refused at once" timeout 10 sh -c "printf '{\"call\":\"w\"}' | '$here/bin/hermy' snap"
cp "$tmp/conf.orig" .hermy.yml
tripped 0 "config: brought back under 64 KiB, commands run as before" 'true'
# One that grows past it between snap's check and its copy is cut short:
# trip reports it as changed and leaves it as it is. A stub head grows it on
# its second read of 64 KiB and a byte, the copy.
mkdir "$tmp/grow"; cat > "$tmp/grow/head" <<EOF
#!/bin/sh
if [ "\$*" = "-c 65537 -- $repo/.hermy.yml" ]; then
  if [ -e "$tmp/grow/n" ]; then cat "$tmp/conf.big" > "$repo/.hermy.yml"; else : > "$tmp/grow/n"; fi
fi
exec "$(command -v head)" "\$@"
EOF
chmod +x "$tmp/grow/head"
PATH="$tmp/grow:$PATH" wire snap w; out=$(wire trip w 2>&1); r=$?
t 0 "config: one grown past 64 KiB after snap's check is reported as changed" test "$r" = 2
t 0 "config: that report says why" grep -q '.hermy.yml is over 64 KiB, more than hermy keeps a copy of' <<<"$out"
t 0 "config: and it is left as it is" cmp -s .hermy.yml "$tmp/conf.big"
cp "$tmp/conf.orig" .hermy.yml; rm -r "$tmp/grow"
# The fingerprint has a budget (HERMY_BUDGET seconds, which the shims
# ignore): past it, its git is killed, snap lets the command run and tells
# the agent it goes unchecked, trip reports the command, and the config lock
# still holds. A git that sleeps on merge-base, the fingerprint's first git
# call (SECONDS counts whole seconds, so a budget of 2 may end after 1),
# stands in for a huge checkout. It records its own pid and its sleep's, to
# show none outlives the hook.
mkdir "$tmp/slow"; printf '#!/bin/sh\ncase " $* " in *" merge-base "*) echo $$ >> "%s"; sleep 60 & echo $! >> "%s"; wait ;; esac\nexec "%s" "$@"\n' "$tmp/slow/pids" "$tmp/slow/pids" "$(command -v git)" > "$tmp/slow/git"; chmod +x "$tmp/slow/git"
slow() { : > "$tmp/slow/pids"; printf '{"call":"w"}' | HERMY_BUDGET=2 PATH="$tmp/slow:$PATH" run "$1"; }
left() { [ -s "$tmp/slow/pids" ] || return 0; while read -r p; do ! kill -0 "$p" 2>/dev/null || return 0; done < "$tmp/slow/pids"; return 1; }
SECONDS=0; out=$(slow snap); r=$?
t 0 "budget: snap past it lets the command run, within seconds" test "$r:$((SECONDS <= 8))" = 0:1
t 0 "budget: telling the agent it goes unchecked" jq -e '.hermy == "note" and (.text | contains("so this command runs unchecked"))' <<<"$out"
t 0 "budget: its snapshot says so" grep -qx unchecked "$snapfile"
t 1 "budget: and no git of its fingerprint is left running" left
rm .hermy.yml; out=$(wire trip w 2>&1); r=$?
t 0 "budget: trip reports a command whose snapshot is unchecked" test "$r" = 2
t 0 "budget: saying so" grep -q 'that command ran unchecked' <<<"$out"
t 0 "budget: and the config lock still puts back a deleted .hermy.yml" same .hermy.yml
tripped 0 "budget: the next command is checked afresh" 'true'
wire snap w; rm .hermy.yml
SECONDS=0; out=$(slow trip 2>&1); r=$?
t 0 "budget: trip past it reports the command, within seconds" test "$r:$((SECONDS <= 8))" = 2:1
t 0 "budget: saying it could not be checked" grep -q 'to fingerprint after that command ran' <<<"$out"
t 0 "budget: and the config lock still puts back a deleted .hermy.yml" same .hermy.yml
t 1 "budget: and no git of its fingerprint is left running" left
t 0 "budget: nor any snapshot record" none
# Past git status the notice names how many dirty paths it listed: a git
# that sleeps on hash-object, the fingerprint's last call.
mkdir "$tmp/slowh"; sed 's/ merge-base / hash-object /' "$tmp/slow/git" > "$tmp/slowh/git"; chmod +x "$tmp/slowh/git"
echo a > dirty.txt; : > "$tmp/slow/pids"
out=$(printf '{"call":"w"}' | HERMY_BUDGET=2 PATH="$tmp/slowh:$PATH" run snap)
t 0 "budget: past git status, the notice names the dirty paths it listed" jq -e '.hermy == "note" and (.text | test("checkout, which has [0-9]+ dirty or untracked paths, within"))' <<<"$out"
t 1 "budget: and no git of its fingerprint is left running" left
wire trip w 2>/dev/null; rm -r dirty.txt "$tmp/slowh"
# A member of its group that ignores TERM gets KILL once the job is gone.
mkdir "$tmp/slowt"; sed 's/ merge-base "\*) / merge-base "*) trap "" TERM; /' "$tmp/slow/git" > "$tmp/slowt/git"; chmod +x "$tmp/slowt/git"
: > "$tmp/slow/pids"; printf '{"call":"w"}' | HERMY_BUDGET=2 PATH="$tmp/slowt:$PATH" run snap >/dev/null
t 0 "budget: a TERM-ignoring git was started" test -s "$tmp/slow/pids"
t 1 "budget: and is gone once snap returns" left
wire trip w 2>/dev/null; rm -r "$tmp/slowt"
# The admin dirs' check (admin) has half the budget, from the hook's start:
# past it snap refuses every command, in either guard mode, naming
# .git/worktrees, with no record left. A budget of 0 stands in for more
# entries than it checks in 10 seconds.
mkdir -p .git/worktrees/many
adm() { printf '{"call":"w"}' | HERMY_BUDGET=0 run snap; }
t 2 "budget: snap refuses once the admin dirs take more than half of it" adm
t 0 "budget: naming .git/worktrees, to clear by hand" says "/.git/worktrees' holds more entries than hermy can check in 0 seconds before a shell command, so hermy refuses every command until you remove, by hand" adm
t 0 "budget: leaving no record" none
echo 'guard: warn' >> .hermy.yml
t 2 "budget: under guard: warn too" adm
cp "$tmp/conf.orig" .hermy.yml
tripped 0 "budget: within it, the same admin dir passes" 'true'
rm -r .git/worktrees
# A source of the fingerprint that fails makes the run unchecked, named in
# fixed text, at snap or at trip, on every command while it keeps failing:
# git status, git worktree list and, in a jj repository with a jj that names
# a workspace's root, jj workspace list. A failed listing read as an empty
# one would hide the command's change, or name a worktree there before as
# made. No jj on PATH, an empty .jj or a jj before 0.38 lists no workspace,
# as it always has; a jj whose version cannot be read is broken, not absent.
mkdir "$tmp/fsrc" "$tmp/jjnew" "$tmp/jjold" "$tmp/jjdead"
printf '#!/bin/sh\ncase " $* " in *" ${FAIL:?} "*) exit 128 ;; esac\nexec "%s" "$@"\n' "$(command -v git)" > "$tmp/fsrc/git"
printf '#!/bin/sh\n[ "$1" != --version ] || { echo "jj 0.46.0"; exit 0; }\nexit 1\n' > "$tmp/jjnew/jj"
printf '#!/bin/sh\n[ "$1" != --version ] || { echo "jj 0.37.0"; exit 0; }\nexit 1\n' > "$tmp/jjold/jj"
printf '#!/bin/sh\nexit 1\n' > "$tmp/jjdead/jj"; chmod +x "$tmp/fsrc/git" "$tmp/jjnew/jj" "$tmp/jjold/jj" "$tmp/jjdead/jj"
# A repo config jj cannot read fails it inside the repository, --version included.
mkdir "$tmp/jjbad" "$tmp/jjbadold"; printf '#!/bin/sh\n[ "$1" != --version ] || [ -e .jj/repo ] || { echo "jj 0.46.0"; exit 0; }\nexit 1\n' > "$tmp/jjbad/jj"
sed 's/0\.46/0.37/' "$tmp/jjbad/jj" > "$tmp/jjbadold/jj"; chmod +x "$tmp/jjbad/jj" "$tmp/jjbadold/jj"
# A PATH with no jj on it: each entry holding one stands in a copy of its links but jj.
nojp="" i=0; IFS=: read -ra ds <<<"$PATH"
for d in "${ds[@]}"; do
  [ ! -e "$d/jj" ] || { i=$((i+1)); mkdir -p "$tmp/nojj/$i"; ln -s "$d"/* "$tmp/nojj/$i/"; rm "$tmp/nojj/$i/jj"; d=$tmp/nojj/$i; }
  nojp+=${nojp:+:}$d
done
# unchecked <source> <the call, as named> <stub dir> [stub dir for a snap that works]:
# the source failing at snap and trip, twice, then at trip alone
unchecked() {
  for i in 1 2; do
    out=$(PATH="$3:$PATH" wire snap w); echo x >> README.md
    t 0 "unchecked: $1 failing, snap says the command runs unchecked ($i)" jq -e --arg s "since $2 failed, so this command runs unchecked" '.hermy == "note" and (.text | contains($s))' <<<"$out"
    out=$(PATH="$3:$PATH" wire trip w 2>&1); r=$?
    t 0 "unchecked: and trip reports the edit's command ($i)" test "$r" = 2
    t 0 "unchecked: as one that ran unchecked, naming $2 ($i)" grep -q "ran unchecked: the main checkout could not be fingerprinted before it ran, since $2 failed" <<<"$out"
  done
  git checkout -q README.md; PATH="${4:-$3}:$PATH" FAIL=none wire snap w >/dev/null; echo x >> README.md; out=$(PATH="$3:$PATH" wire trip w 2>&1); r=$?
  t 0 "unchecked: $1 failing at trip alone, an edit trips" test "$r" = 2
  t 0 "unchecked: saying the checkout could not be fingerprinted, naming $2" grep -q "could not be fingerprinted after that command ran, since $2 failed" <<<"$out"
  git checkout -q README.md
}
FAIL=status unchecked "git status" "git status" "$tmp/fsrc"
FAIL='worktree list' unchecked "git worktree list" "git worktree list" "$tmp/fsrc"
mkdir -p .jj/repo; unchecked "jj workspace list in a jj repository" "jj workspace list" "$tmp/jjnew" "$tmp/jjold"
unchecked "jj workspace list on a repo config jj cannot read" "jj workspace list" "$tmp/jjbad" "$tmp/jjold"
unchecked "jj workspace list with a jj whose version cannot be read" "jj workspace list" "$tmp/jjdead" "$tmp/jjold"
PATH="$tmp/jjold:$PATH" tripped 0 "unchecked: a jj before 0.38 failing lists no workspace, as before" 'true'
PATH="$tmp/jjbadold:$PATH" tripped 0 "unchecked: so does one on a repo config it cannot read, its version read outside the repository" 'true'
PATH=$nojp t 0 "unchecked: no jj on PATH in a jj repository is refused, as before" says 'no jj is on PATH outside the project' wire snap w
rmdir .jj/repo; PATH="$tmp/jjnew:$PATH" tripped 0 "unchecked: an empty .jj lists no workspace, as before" 'true'
rmdir .jj
# A plain jj root (.jj/repo, no .git, worktree: jj) has no git to fail: git
# status and git worktree list failing there by design leave the run
# checked. Under worktree: git the same root has lost its .git: unchecked.
mkdir -p "$tmp/nogit/.jj/repo"; { echo 'worktree: jj'; grep -v '^worktree:' .hermy.yml; } > "$tmp/nogit/.hermy.yml"
PATH="$tmp/jjold:$PATH" HERMY_ROOT="$tmp/nogit" tripped 0 "unchecked: a plain jj root with no .git runs checked, as before" 'true'
cp .hermy.yml "$tmp/nogit/"
PATH="$tmp/jjold:$PATH" HERMY_ROOT="$tmp/nogit" tripped 2 "unchecked: one with no .git under worktree: git runs unchecked" 'true'
rm -r "$tmp/nogit"
# One whose .git snap saw and the command moved aside is held to it: the
# run is unchecked, its git calls failing there read as no empty listing,
# and so is every command after it while .git stays away.
wire snap w >/dev/null; mv .git "$tmp/g"; echo x >> README.md; out=$(wire trip w 2>&1); r=$?
t 0 "unchecked: a .git the command moved aside, with an edit, trips" test "$r" = 2
t 0 "unchecked: saying its .git is gone" grep -q 'could not be fingerprinted after that command ran, since its .git is gone' <<<"$out"
wire snap w >/dev/null; echo y >> README.md; out=$(wire trip w 2>&1); r=$?
mv "$tmp/g" .git; git checkout -q README.md
t 0 "unchecked: the next command, .git still away, trips too" test "$r" = 2
t 0 "unchecked: as one that ran unchecked, git status failing" grep -q 'ran unchecked: .*since .*git status failed' <<<"$out"
tripped 0 "unchecked: the next command is checked afresh" 'true'
# So is one whose .jj/repo snap saw, with a jj that lists fine: moved aside,
# jj there lists no workspace, which would hide one the command made.
mkdir -p "$tmp/jjok" .jj/repo; printf '#!/bin/sh\n[ "$1" != --version ] || echo "jj 0.46.0"\n' > "$tmp/jjok/jj"; chmod +x "$tmp/jjok/jj"
PATH="$tmp/jjok:$PATH" wire snap w >/dev/null; mv .jj "$tmp/j"; out=$(PATH="$tmp/jjok:$PATH" wire trip w 2>&1); r=$?
rm -r "$tmp/j"
t 0 "unchecked: a .jj the command moved aside trips" test "$r" = 2
t 0 "unchecked: saying its .jj is gone" grep -q 'could not be fingerprinted after that command ran, since its .jj is gone' <<<"$out"
PATH="$tmp/jjok:$PATH" tripped 0 "unchecked: the next command is checked afresh" 'true'
# A git worktree there before, its listing failing at snap alone, is named
# neither made nor moved: the run is unchecked.
git worktree add -q --detach "$tmp/owt"
FAIL='worktree list' PATH="$tmp/fsrc:$PATH" wire snap w >/dev/null; out=$(wire trip w 2>&1); r=$?
t 0 "unchecked: a git worktree listing that failed at snap alone trips" test "$r" = 2
t 0 "unchecked: as a command that ran unchecked" grep -q 'ran unchecked: .*since git worktree list failed' <<<"$out"
t 1 "unchecked: naming no worktree there before as made, moved, renamed or re-created" grep -qE "', (made|moved, renamed or re-created) \(" <<<"$out"
git worktree remove --force "$tmp/owt"
# The fingerprint failing on its own (a sort that fails) is hermy's failure:
# at trip it is reported as such, an edit or not; at snap the snapshot says
# so, and trip reports that, not a command that touched the snapshot.
mkdir "$tmp/nosort"; printf '#!/bin/sh\ncat >/dev/null; exit 1\n' > "$tmp/nosort/sort"; chmod +x "$tmp/nosort/sort"
wire snap w >/dev/null; echo x >> README.md; out=$(PATH="$tmp/nosort:$PATH" wire trip w 2>&1); r=$?
t 0 "unchecked: trip's fingerprint failing, with an edit, trips" test "$r" = 2
t 0 "unchecked: saying the fingerprint failed" grep -q 'could not be fingerprinted after that command ran, since the fingerprint failed' <<<"$out"
git checkout -q README.md
out=$(PATH="$tmp/nosort:$PATH" wire snap w)
t 0 "unchecked: snap's fingerprint failing says the command runs unchecked" jq -e '.hermy == "note" and (.text | contains("since the fingerprint failed, so this command runs unchecked"))' <<<"$out"
t 0 "unchecked: its snapshot says so" grep -qx 'unchecked fp' "$snapfile"
out=$(wire trip w 2>&1); r=$?
t 0 "unchecked: and trip reports it" test "$r" = 2
t 0 "unchecked: as a fingerprint that failed, not a snapshot the command touched" grep -q 'ran unchecked: .*since the fingerprint failed' <<<"$out"
tripped 0 "unchecked: the next command is checked afresh" 'true'
# A git status that leaves a child running with every fd above stderr open
# (the fsmonitor daemon a git before 2.55 starts under core.fsmonitor=true)
# holds no end of the fingerprint's pipe: snap and trip finish well within
# the budget, checked.
mkdir "$tmp/fsmon"; printf '#!/bin/sh\ncase " $* " in *" status "*) sleep 30 </dev/null >/dev/null 2>&1 & echo $! >> "%s" ;; esac\nexec "%s" "$@"\n' "$tmp/fsmon/pids" "$(command -v git)" > "$tmp/fsmon/git"; chmod +x "$tmp/fsmon/git"
SECONDS=0; PATH="$tmp/fsmon:$PATH" wire snap w >/dev/null; r=$?
t 0 "unchecked: a git status leaving a child that holds its fds, snap finishes within seconds" test "$r:$((SECONDS <= 8))" = 0:1
t 1 "unchecked: and its snapshot is checked" grep -q '^unchecked' "$snapfile"
SECONDS=0; PATH="$tmp/fsmon:$PATH" wire trip w; r=$?
t 0 "unchecked: and trip, quiet, within seconds too" test "$r:$((SECONDS <= 8))" = 0:1
while read -r p; do kill "$p" 2>/dev/null; done < "$tmp/fsmon/pids"; rm -r "$tmp/fsmon"
rm -rf "$tmp/fsrc" "$tmp/nosort" "$tmp/jjnew" "$tmp/jjold" "$tmp/jjdead" "$tmp/nojj" "$tmp/jjbad" "$tmp/jjbadold"
# A file git cannot read in its place is a change like any other.
report "config: an unreadable file in its place trips" 'echo "guard: warn" > .hermy.yml && chmod 000 .hermy.yml'
t 0 "config: and is restored" same .hermy.yml
# No change from git stands on its own: a commit made here, a checkout of
# the committed copy over a changed one, or a pull of a shared config is
# put back, since nothing a shell command cannot write tells it from a
# forged one, and the report sends the user to /hermy:config, which reads
# the accepted copy from HEAD. The restored file then differs from HEAD,
# which the fingerprint does not report as the command's change.
git add -f .hermy.yml && git commit -q -m conf && git push -q origin main
tripped 2 "config: a change committed here in the same command trips" 'echo "guard: warn" >> .hermy.yml && git commit -qam warn'
t 0 "config: and is restored" same .hermy.yml
git reset -q --hard origin/main
echo 'roadmap: X.md' >> .hermy.yml
tripped 2 "config: a checkout of the committed copy over a changed one trips" 'git checkout -- .hermy.yml'
t 0 "config: and the changed one is put back" grep -q '^roadmap: X.md$' .hermy.yml
git checkout -q -- .hermy.yml
git clone -q -b main "$tmp/origin.git" "$tmp/mate" 2>/dev/null
(cd "$tmp/mate" && echo 'roadmap: Y.md' >> .hermy.yml && git commit -q -am up && git push -q origin HEAD:main)
report "config: a pull of a changed shared config trips" 'git fetch -q origin && git merge -q --ff-only origin/main'
t 0 "config: and is put back" same .hermy.yml
t 0 "config: and the report says /hermy:config accepts it" grep -q 'accept it with /hermy:config' <<<"$out"
t 1 "config: and does not call the restored file the command's change" grep -q 'changed the main checkout' <<<"$out"
t 0 "config: and HEAD holds the pulled copy for /hermy:config to read" sh -c "git show HEAD:.hermy.yml | grep -q '^roadmap: Y.md$'"
tripped 0 "config: the restored file is quiet afterwards" 'true'
git reset -q --hard HEAD~1 # back to before the pull, so the config matches HEAD and the flow snapshot again
# TMPDIR is the command's to write too, so trip opens nothing there that is
# not a plain file: a FIFO planted at the snapshot's link record would hang it.
# bounded <expected exit> <name>: trip in the background, failed and killed after 5s
bounded() { wire trip w >/dev/null 2>&1 & tp=$!; i=0; while kill -0 $tp 2>/dev/null && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
  if kill -0 $tp 2>/dev/null; then kill $tp 2>/dev/null; pkill -f "$snapfile" 2>/dev/null; wait $tp 2>/dev/null; r=124; else wait $tp; r=$?; fi; t 0 "$2" test "$r" = "$1"; }
wire snap w; echo "guard: warn" >> .hermy.yml; mkfifo "$snapfile..hermy.yml.link"
bounded 2 "config: a FIFO planted at the link record does not hang trip"
t 0 "config: and the change is restored" same .hermy.yml
t 1 "config: and the snapshot is cleaned up, the FIFO with it" test -e "$snapfile..hermy.yml.link"
# The snapshot is what trip checks a command against, so a command that
# removes it, or its copy of the config, is rejected; a project that left the
# workflow by hand, its config gone with no claim or git hooks left, is quiet.
report "snapshot: a command that removes it trips" 'rm -f "$snapfile"'
t 0 "snapshot: and the report names it" grep -q "$snapfile" <<<"$out"
tripped 2 "snapshot: so does one that removes it with the config" 'rm -f "$snapfile" .hermy.yml'
git checkout -q -- .hermy.yml
tripped 2 "snapshot: so does one that removes its copy of the config" 'rm -f "$snapfile".*'
report "snapshot: so does one that rewrites it as not onboarded, its records left, and removes the config" 'echo NOT_ONBOARDED > "$snapfile" && rm .hermy.yml'
t 0 "snapshot: and the report names it" grep -q "$snapfile" <<<"$out"
git checkout -q -- .hermy.yml
tripped 2 "snapshot: so does one that rewrites it as not onboarded alone, the config untouched" 'echo NOT_ONBOARDED > "$snapfile"'
wire snap w; echo NOT_ONBOARDED > "$snapfile"
t 2 "snapshot: and so with nullglob inherited" env BASHOPTS=nullglob "$here/bin/hermy" trip <<<'{"call":"w"}'
# Each path's kind is recorded, present or not, so a lost copy is not read
# as a path that was absent: a weakened legacy file planted next to the live
# .hermy.yml is let go, and a command that then removed .hermy.yml with its
# copy alone would leave the planted one live.
kinds() { wire snap w && [ "$(cat "$snapfile..hermy.yml.kind")" = "$1" ] && [ "$(cat "$lgs.kind")" = "$2" ] && [ "$(cat "$snapfile..coddy.yml.kind")" = absent ]; }
t 0 "snapshot: records .hermy.yml as a file and the legacy path absent" kinds file absent
HERMY_AGENT_DIR=.claude tripped 0 "snapshot: a legacy file planted next to the live .hermy.yml is let go" 'echo "guard: warn" > .claude/coddy.yml'
report "snapshot: removing .hermy.yml with its copy alone then trips" 'rm -f "$snapfile..hermy.yml" .hermy.yml'
t 0 "snapshot: and the report names the snapshot" grep -q "$snapfile" <<<"$out"
git checkout -q -- .hermy.yml; rm .claude/coddy.yml
mv .hermy.yml .claude/coddy.yml
t 0 "snapshot: records .hermy.yml absent and the legacy file" kinds absent file
tripped 2 "snapshot: removing the legacy file's copy while it is the live one trips" 'rm -f "$lgs"'
mkdir .hermy.yml
t 0 "snapshot: records a directory at .hermy.yml" kinds dir file
tripped 0 "config: a directory at .hermy.yml from before the command is left alone" 'true'
t 0 "config: and stands" test -d .hermy.yml
rmdir .hermy.yml; mkfifo .hermy.yml
t 0 "snapshot: records a FIFO at .hermy.yml" kinds fifo file
rm .hermy.yml; ln -s nowhere .hermy.yml
t 0 "snapshot: records a dangling link at .hermy.yml as other" kinds other file
t 0 "snapshot: with its target" test "$(cat "$snapfile..hermy.yml.link")" = nowhere
rm .hermy.yml; mv .claude/coddy.yml .hermy.yml
mv .hermy.yml "$tmp/aside"
tripped 0 "snapshot: quiet once the config is gone, no claim or git hooks left" 'true'
mv "$tmp/aside" .hermy.yml
t 0 "snapshot: a call that is not a plain word, with no session or pid, names the shared snapshot" env -u HERMY_PID sh -c "printf '{\"call\":\"../x\"}' | '$here/bin/hermy' snap && test -f '$snapbase-shared'"
rm -f "$snapbase-shared"
# With no call id, each session keeps a shared snapshot of its own (else its
# pid's), its name reduced to a plain word, so two never take each other's.
# sw <verb> <session>: the hook with that session and no call id
sw() { printf '{"session":"%s"}' "$2" | run "$1"; }
t 0 "snapshot: with no call id, the session names it" sh -c "printf '{\"session\":\"../a\"}' | '$here/bin/hermy' snap && test -f '$snapbase-session-a'"
t 0 "snapshot: with no call id or session, the pid names it" sh -c "printf '{}' | '$here/bin/hermy' snap && test -f '$snapbase-pid-$$'"
rm -f "$snapbase-session-"* "$snapbase-pid-"*
# Each kind has a prefix of its own, so a call id spelled as a session's
# snapshot name never takes that session's snapshot.
for c in session-a shared-a; do
  sw snap a >/dev/null 2>&1; wire snap "$c" >/dev/null 2>&1; wire trip "$c" >/dev/null 2>&1
  t 0 "snapshot: a call id spelled $c leaves session a's snapshot alone" sw trip a
done
sw snap a >/dev/null 2>&1; sw snap b >/dev/null 2>&1; sw trip b >/dev/null 2>&1
out=$(sw trip a 2>&1); r=$?
t 0 "snapshot: two sessions with no call id, interleaved, each trip finds its own" test "$r" = 0
t 1 "snapshot: and none reports it lost" grep -q 'left no snapshot' <<<"$out"
sw snap a >/dev/null 2>&1; sw snap b >/dev/null 2>&1; git worktree add -q --detach "$tmp/stray" 2>/dev/null
t 2 "snapshot: a stray worktree one session's command made trips that session's trip" sw trip a
out=$(sw trip b 2>&1)
t 1 "snapshot: while the other's reports no lost snapshot" grep -q 'left no snapshot' <<<"$out"
git worktree remove --force "$tmp/stray"; rm -f "$snapbase-session-"*

# No agent-dir rules without HERMY_AGENT_DIR; with it, its directory is free
# and its worktrees/ held to the lock.
t 2 "no agent dir: .claude/ is the main checkout" guard "$repo/.claude/notes.md"
t 2 "no agent dir: so is .claude/worktrees/" guard "$repo/.claude/worktrees/5/a.txt"
tripped 2 "no agent dir: a change under .claude/ trips" 'echo x > .claude/notes.md'; rm .claude/notes.md
export HERMY_AGENT_DIR=.codex
t 0 "agent dir: edits under it are allowed" guard "$repo/.codex/notes.md"
t 2 "agent dir: its worktrees/ is held to the lock" guard "$repo/.codex/worktrees/5/a.txt"
t 0 "agent dir: that rejection names the claim" says "issue 5 is not In Progress" guard "$repo/.codex/worktrees/5/a.txt"
t 2 "agent dir: .claude/ is not it" guard "$repo/.claude/notes.md"
tripped 0 "agent dir: a change under it is quiet" 'mkdir -p .codex && echo x > .codex/notes.md'; rm -r .codex
unset HERMY_AGENT_DIR

# cfg drops a CRLF line's \r and trailing blanks: worktree: jj\r or jj<space> reads as jj, not as an unknown tool run as git.
cp .hermy.yml "$tmp/conf.yml"; printf 'version: 2\r\ntracker: github\r\nworktree: jj\r\ndefault_branch: main\r\n' > .hermy.yml
t 0 "cfg: a CRLF worktree: jj reads as jj" says 'jj' run start 9 feat/9-crlf
t 1 "cfg: so no git worktree is made" test -e .worktrees/9
printf 'version: 2\ntracker: github\nworktree: jj \t\ndefault_branch: main\n' > .hermy.yml
t 0 "cfg: a worktree: jj with trailing blanks reads as jj" says 'jj' run start 9 feat/9-blank
t 1 "cfg: so no git worktree is made for it" test -e .worktrees/9
cp "$tmp/conf.yml" .hermy.yml
# start is create, ship is verify then push; the aliases stay.
t 0 "start makes the worktree" says 'created: .worktrees/1 on feat/1-thing' run start 1 feat/1-thing
t 0 "create is its alias" says 'exists: .worktrees/1' run create 1 feat/1-thing
t 0 "root: from inside an issue worktree without HERMY_ROOT" rooted "$repo/.worktrees/1" -u HERMY_ROOT
t 0 "root: from HERMY_ROOT naming a worktree" rooted / HERMY_ROOT="$repo/.worktrees/1"
t 1 "ship refuses before the claim" run ship 1
# A claim that makes the lock but cannot create its owner file (a umask that
# leaves the lock read-only) leaves no lock, so the claim below is no retry
# refused as one in flight.
if [ "$(id -u)" != 0 ]; then # root writes anywhere
  uclaim() { (umask 0277; run claim 1); }
  t 1 "claim: one that cannot create its owner file fails" uclaim
  t 0 "claim: saying it could not record the claim" says 'could not record the claim' uclaim
  t 1 "claim: and leaves no lock" test -e .git/hermy/1
fi
t 0 "claim" run claim 1
t 0 "the lock names HERMY_SESSION and HERMY_PID" holds "sess-a $$" .git/hermy/1/owner
# Then the start: local, as 0.6.0's started prints it in C and compares it,
# UTC, the one this hermy compares, and, where /proc is (Linux), the start in
# clock ticks since boot, compared instead.
lstart=$(LC_ALL=C ps -o lstart= -p $$ | awk '{$1=$1; gsub(/ /,"_")} 1')
ustart=$(TZ=UTC0 LC_ALL=C ps -o lstart= -p $$ | awk '{$1=$1; gsub(/ /,"_"); print $0 "_UTC"}')
tks=$(awk '{sub(/.*\) /, ""); print " t" $20}' /proc/$$/stat 2>/dev/null)
# ownline <session pid> <file>: the owner line is that process's. Where it has
# ticks, they are compared and the starts by their format alone: ps derives
# lstart from the wall clock, which a clock correction moves by a second
# between claim's read and the one above; the ticks it does not.
ownline() {
  local f='(Mon|Tue|Wed|Thu|Fri|Sat|Sun)_(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)_[0-9]{1,2}_[0-9]{2}:[0-9]{2}:[0-9]{2}_[0-9]{4}'
  if [ -n "$tks" ]; then grep -qxE "$1 $f ${f}_UTC$tks" "$2"; else grep -qx "$1 $lstart $ustart" "$2"; fi
}
t 0 "and the process's start, local as 0.6.0 compares it, then UTC, then its ticks where /proc is" ownline "sess-a $$" .git/hermy/1/owner
t 1 "another session's claim is refused" as sess-b 1 claim 1
t 0 "that refusal names the owner" says "session sess-a" as sess-b 1 claim 1
t 0 "the owner's process re-claims under another session id" as sess-b $$ claim 1
t 0 "and the lock followed it" holds "sess-b $$" .git/hermy/1/owner
run claim 1 >/dev/null 2>&1
t 0 "guard allows the owner's edit" guard "$repo/.worktrees/1/a.txt"
ln -s ../../.hermy.yml .worktrees/1/cfg; ln .hermy.yml .worktrees/1/hard
t 0 "guard asks on .hermy.yml through a symlink in the owner's worktree" asks "$repo/.worktrees/1/cfg"
t 0 "guard asks on .hermy.yml through a hard link in the owner's worktree" asks "$repo/.worktrees/1/hard"
rm .worktrees/1/cfg .worktrees/1/hard
# An edit naming several paths is held on every one.
guardp() { printf '{"session":"sess-a","paths":%s}' "$1" | run guard; }
t 2 "guard: two paths, one outside any worktree, is refused" guardp "[\"$repo/.worktrees/1/a.txt\",\"$repo/README.md\"]"
t 0 "guard: two paths, one the config, asks" guardp "[\"$repo/.worktrees/1/a.txt\",\"$repo/.hermy.yml\"]"
t 0 "guard: that ask is one neutral line" eval 'guardp "[\"$repo/.worktrees/1/a.txt\",\"$repo/.hermy.yml\"]" | jq -e ".hermy == \"ask\""'
t 2 "guard: a refused path beats an ask" guardp "[\"$repo/.hermy.yml\",\"$repo/README.md\"]"
t 2 "guard: an empty paths list is refused" guardp '[]'
t 0 "guard: two paths in the claimed worktree pass" guardp "[\"$repo/.worktrees/1/a.txt\",\"$repo/.worktrees/1/b.txt\"]"
HERMY_ASK=0 t 2 "guard: under HERMY_ASK=0 two paths, one the config, block" guardp "[\"$repo/.worktrees/1/a.txt\",\"$repo/.hermy.yml\"]"
t 2 "guard: and so under a shim's HERMY_ASK=0 it never exported" bash -c 'HERMY_ASK=0; . "$1" guard' _ "$here/bin/hermy" <<<"{\"session\":\"sess-a\",\"paths\":[\"$repo/.worktrees/1/a.txt\",\"$repo/.hermy.yml\"]}"
# A NUL in a path makes bash warn on stderr; the ask on stdout still wins.
t 0 "guard: two paths, the config's with a NUL, still ask" eval 'guardp "[\"$repo/.worktrees/1/a.txt\",\"$repo/.hermy.yml\\u0000\"]" 2>/dev/null | jq -e ".hermy == \"ask\""'
# A host's shim hands over every file one apply_patch string names. Codex-
# and Copilot-shaped shims, the self-test's alone, share one extractor.
cat > "$tmp/patchshim" <<'EOF'
# Codex sends apply_patch with the patch as its command's last word, Copilot
# as an Edit whose tool_input is the patch string.
hermy_in() {
  jq -c 'def patch: if (.tool_input | type) == "string" then .tool_input
      elif (.tool_input.command | type) == "array" then .tool_input.command[-1]
      else .tool_input.input // "" end;
    {paths: [patch | splits("\n") | rtrimstr("\r") | capture("^\\*\\*\\* (?:(?:Update|Add|Delete) File|Move to): (?<p>.+)$") | .p],
     cwd: (.cwd // ""), call: (.tool_use_id // ""), session: (.session_id // "")}'
}
EOF
printf '. %q\n' "$here/bin/hermy" >> "$tmp/patchshim"
# patch <path...>: an apply_patch string updating each path
patch() { local p; printf '*** Begin Patch\n'; for p; do printf '*** Update File: %s\n@@\n-hi\n+ho\n' "$p"; done; printf '*** End Patch\n'; }
# codexp <patch> and copilot <path...>: the guard's payload as each host sends it
codexp() { jq -cn --arg p "$1" --arg c "$repo" '{session_id: "sess-a", tool_use_id: "c1", cwd: $c, tool_name: "apply_patch", tool_input: {command: ["apply_patch", $p]}}' | bash "$tmp/patchshim" guard; }
codex() { codexp "$(patch "$@")"; }
copilot() { jq -cn --arg p "$(patch "$@")" --arg c "$repo" '{session_id: "sess-a", tool_use_id: "c1", cwd: $c, tool_name: "Edit", tool_input: $p}' | bash "$tmp/patchshim" guard; }
t 0 "apply_patch: a Codex patch of two files in the claimed worktree passes" codex .worktrees/1/a.txt .worktrees/1/b.txt
t 2 "apply_patch: a Codex patch of README.md is refused" codex README.md
t 0 "apply_patch: a Copilot Edit patching a file in the claimed worktree passes" copilot .worktrees/1/a.txt
t 2 "apply_patch: a Copilot Edit patching README.md is refused" copilot README.md
t 2 "apply_patch: a patch of the claimed worktree and README.md is refused" codex .worktrees/1/a.txt README.md
t 2 "apply_patch: a move out of the claimed worktree onto README.md is refused" codexp "$(printf '*** Begin Patch\n*** Update File: .worktrees/1/a.txt\n*** Move to: README.md\n@@\n-hi\n+ho\n*** End Patch')"
many=$(jq -cn --arg d "$repo/.worktrees/1/" '[range(0;65)|$d+"f\(.)"]')
t 2 "guard: a payload with more paths than the cap is refused" guardp "$many"
t 0 "guard: that refusal names the cap" eval 'guardp "$many" 2>&1 | grep -q "too many paths, more than the 64"'
# Past its deadline (HERMY_GUARD_BUDGET lowers it) an edit naming several
# paths is refused before the next path, in warn mode too.
two="[\"$repo/.worktrees/1/a.txt\",\"$repo/.worktrees/1/b.txt\"]"
HERMY_GUARD_BUDGET=0 t 2 "guard: an edit naming several paths past its deadline is refused" guardp "$two"
HERMY_GUARD_BUDGET=0 t 0 "guard: that refusal names the deadline" says "too many paths to check in time, 0 of them checked when its 0 s deadline passed" guardp "$two"
cp .hermy.yml "$tmp/dl.yml"; echo 'guard: warn' >> .hermy.yml
HERMY_GUARD_BUDGET=0 t 2 "guard: and so under guard: warn" guardp "$two"
# Under guard: warn a path let through with a note keeps it when another asks:
# the ask carries both.
wa="[\"$repo/.hermy.yml\",\"$repo/README.md\"]"
t 0 "guard: warn, the config and a path outside any worktree: the ask carries both" eval 'guardp "$wa" | jq -e ".hermy == \"ask\" and (.text | test(\"changes the hermy guardrails\") and test(\"let through .guard: warn.\"))"'
# An exported HERMY_ASK=0 is the parent's to apply: its refusal keeps the note.
HERMY_ASK=0 t 2 "guard: warn, HERMY_ASK=0 exported, the config and a path outside any worktree are refused" guardp "$wa"
HERMY_ASK=0 t 0 "guard: that refusal carries the other path's note" eval 'guardp "$wa" 2>&1 | grep "This host cannot ask" | grep -q "let through .guard: warn."'
cp "$tmp/dl.yml" .hermy.yml
# Two config paths asked in one edit: the one ask names both.
mv .hermy.yml .coddy.yml
t 0 "guard: an edit of .hermy.yml and a live .coddy.yml asks once, naming both" eval 'guardp "[\"$repo/.hermy.yml\",\"$repo/.coddy.yml\"]" | jq -e ".hermy == \"ask\" and (.text | contains(\"Editing .hermy.yml \") and contains(\"Editing .coddy.yml \"))"'
mv .coddy.yml .hermy.yml
# A path's verdict the parent cannot read (a jq that prints no JSON for the
# child's ask alone) refuses the edit, naming the path, never passes it.
mkdir "$tmp/oddjq"
printf '#!/bin/sh\nfor a; do [ "$a" != %s ] || { echo "not json"; exit 0; }; done\nexec %s "$@"\n' "'{hermy: \"ask\", text: \$m}'" "$(command -v jq)" > "$tmp/oddjq/jq"; chmod +x "$tmp/oddjq/jq"
cfgtwo="[\"$repo/.worktrees/1/a.txt\",\"$repo/.hermy.yml\"]"
PATH="$tmp/oddjq:$PATH" t 2 "guard: an unreadable verdict on one of several paths is refused" guardp "$cfgtwo"
PATH="$tmp/oddjq:$PATH" t 0 "guard: that refusal names the path" says "could not read its verdict on path 2 of 2" guardp "$cfgtwo"
t 0 "guard: eight paths in the claimed worktree pass within it" guardp "$(jq -cn --arg d "$repo/.worktrees/1/" '[range(0;8)|$d+"f\(.)"]')"
# Shift_JIS, GBK and GB18030 take 0x78 as a trail byte, so a path ending in
# a lead byte reads with the x the guard puts after it as one character: the
# guard reads byte-wise. ぁ, in UTF-8 as the payload carries it, ends in 0x81.
h=$(printf '\343\201\201') mb=""
ln -s ../../.hermy.yml ".worktrees/1/cfg$h"; ln -s ../../README.md ".worktrees/1/rd$h"
for mb in $(locale -a 2>/dev/null | grep -ix -e ja_JP.SJIS -e zh_CN.GB18030 -e zh_CN.GBK); do
  LC_ALL=$mb t 0 "guard under $mb asks on .hermy.yml through a link named cfgぁ in the owner's worktree" asks "$repo/.worktrees/1/cfg$h"
  LC_ALL=$mb t 2 "guard under $mb blocks a link named rdぁ there to the main checkout" guard "$repo/.worktrees/1/rd$h"
done
[ -n "$mb" ] || echo "skip guard under a double-byte locale: none of ja_JP.SJIS, zh_CN.GB18030, zh_CN.GBK installed"
rm ".worktrees/1/cfg$h" ".worktrees/1/rd$h"
t 2 "guard blocks another session's edit" guard "$repo/.worktrees/1/a.txt" sess-b
# Claude Code hands the hooks the physical project dir, and a path may reach
# the project through a link: the guard reads a path as given and spelled
# physically against the physical root, the stricter winning, so neither
# spelling of the root or the path lets an edit through.
pr=$(cd "$repo" && pwd -P); ln -s "$repo" "$tmp/via"
ln -s ../../README.md .worktrees/1/rd; ln -s ../../sub .worktrees/1/d; ln -s d/../README.md .worktrees/1/dd
ln -s ../../newdir .worktrees/1/L; ln -s sub2 .worktrees/1/M; mkdir $'.worktrees/1\n'; ln -s $'../1\n' .worktrees/1/nl
# A link target under PATH_MAX that, glued to its directory as text, is
# over it: each link is read from inside its own directory, so none reads
# as no entry and no link. Issue 2 is another session's, 7 unclaimed.
pad=$(printf './%.0s' $(seq $(( ($(getconf PATH_MAX / 2>/dev/null || echo 1024) - 40) / 2 ))))
ln -s "$pad../../sub" .worktrees/1/E; ln -s "$pad../2" .worktrees/1/E2; ln -s "$pad../7" .worktrees/1/E7
ln -s "$pad../../README.md" .worktrees/1/lng; ln -s "${pad}L2" .worktrees/1/la; ln -s ../../README.md .worktrees/1/L2
mkdir .git/hermy/2 .worktrees/2 .worktrees/7; echo "sess-b 1" > .git/hermy/2/owner
# spelled <root> <path prefix> <label>
spelled() {
  HERMY_ROOT=$1 t 2 "guard, $3: blocks the main checkout" guard "$2/README.md"
  HERMY_ROOT=$1 t 2 "guard, $3: blocks a new nested file in the main checkout" guard "$2/newdir/deep/a.txt"
  HERMY_ROOT=$1 t 2 "guard, $3: blocks an unclaimed worktree" guard "$2/.worktrees/7/a.txt"
  HERMY_ROOT=$1 t 2 "guard, $3: blocks another session's worktree" guard "$2/.worktrees/1/a.txt" sess-b
  HERMY_ROOT=$1 t 0 "guard, $3: allows the owner's worktree" guard "$2/.worktrees/1/a.txt"
  HERMY_ROOT=$1 HERMY_AGENT_DIR=.claude t 0 "guard, $3: allows the agent dir" guard "$2/.claude/x"
  HERMY_ROOT=$1 t 2 "guard, $3: blocks a link in the owner's worktree to the main checkout" guard "$2/.worktrees/1/rd"
  HERMY_ROOT=$1 t 2 "guard, $3: and one whose .. follows a link there" guard "$2/.worktrees/1/dd"
  HERMY_ROOT=$1 t 2 "guard, $3: blocks a dangling link in the owner's worktree to the main checkout" guard "$2/.worktrees/1/L/a.txt"
  HERMY_ROOT=$1 t 0 "guard, $3: allows a dangling link in the owner's worktree to it" guard "$2/.worktrees/1/M/a.txt"
  HERMY_ROOT=$1 t 2 "guard, $3: blocks a directory named the owner's id and a newline" guard "$2/.worktrees/1\\n/x"
  HERMY_ROOT=$1 t 2 "guard, $3: and that name itself" guard "$2/.worktrees/1\\n"
  HERMY_ROOT=$1 t 2 "guard, $3: and a link in the owner's worktree to it" guard "$2/.worktrees/1/nl"
  HERMY_ROOT=$1 t 2 "guard, $3: blocks a new file through a long link to the main checkout" guard "$2/.worktrees/1/E/n1/n2.txt"
  HERMY_ROOT=$1 t 2 "guard, $3: and one to another session's worktree" guard "$2/.worktrees/1/E2/n1/n2.txt"
  HERMY_ROOT=$1 t 2 "guard, $3: and one to an unclaimed worktree" guard "$2/.worktrees/1/E7/n1/n2.txt"
  HERMY_ROOT=$1 t 2 "guard, $3: blocks a long link to a main-checkout file" guard "$2/.worktrees/1/lng"
  HERMY_ROOT=$1 t 2 "guard, $3: and a long link to a link there" guard "$2/.worktrees/1/la"
}
spelled "$pr" "$pr" "physical root and path"
spelled "$pr" "$tmp/via" "physical root, path through a link"
spelled "$tmp/via" "$pr" "root through a link, physical path"
# macOS reaches its data volume through the /System/Volumes/Data firmlink
# too, which bash's pwd -P keeps: the root is found by identity, not by name.
fl="/System/Volumes/Data$pr"
if [ -d "$fl" ] && [ "$fl" -ef "$repo" ]; then
  spelled "$pr" "$fl" "physical root, path through the firmlink"
  spelled "$fl" "$pr" "root through the firmlink, physical path"
  mkdir -p .claude && mv .hermy.yml .claude/coddy.yml
  t 0 "guard asks on a .hermy.yml not made yet, spelled through the firmlink" asks "$fl/.hermy.yml"
  mv .claude/coddy.yml .hermy.yml
fi
mkdir -p .claude && mv .hermy.yml .claude/coddy.yml
ln -s "${pad}C2" .worktrees/1/cfg; ln -s ../../.hermy.yml .worktrees/1/C2
t 0 "guard asks on a .hermy.yml not made yet, through a long link in the owner's worktree" asks "$repo/.worktrees/1/cfg"
rm .worktrees/1/cfg .worktrees/1/C2; mv .claude/coddy.yml .hermy.yml
# A readlink that takes one argument and no -n (BusyBox without
# FEATURE_READLINK_FOLLOW) still reads each link, its newline dropped.
mkdir "$tmp/rl1"; printf '#!/bin/sh\n[ $# = 1 ] || exit 1\ncase $1 in -*) exit 1 ;; esac\nt=$(%s -n "$1" && printf x) || exit 1\nprintf "%%s\\n" "${t%%x}"\n' "$(command -v readlink)" > "$tmp/rl1/readlink"; chmod +x "$tmp/rl1/readlink"
PATH="$tmp/rl1:$PATH" t 2 "guard, one-argument readlink: blocks a link to the main checkout" guard "$repo/.worktrees/1/rd"
PATH="$tmp/rl1:$PATH" t 2 "guard, one-argument readlink: blocks a dangling link to it" guard "$repo/.worktrees/1/L/a.txt"
PATH="$tmp/rl1:$PATH" t 0 "guard, one-argument readlink: allows a dangling link to the owner's worktree" guard "$repo/.worktrees/1/M/a.txt"
# A readlink that never works cannot follow a dangling chain to .hermy.yml:
# refused before the mode is read, so under guard: warn too. Its directory is
# spelled physically: one spelled through a link it cannot read is no PATH
# entry for the hooks.
mkdir "$tmp/rl0"; printf '#!/bin/sh\nexit 1\n' > "$tmp/rl0/readlink"; chmod +x "$tmp/rl0/readlink"; rl0=$(cd -P "$tmp/rl0" && pwd -P)
cp .hermy.yml "$tmp/conf.yml"; { grep -v '^guard:' "$tmp/conf.yml"; echo "guard: warn"; } > .claude/coddy.yml; rm .hermy.yml
ln -s C2 .worktrees/1/cfg; ln -s ../../.hermy.yml .worktrees/1/C2
PATH="$rl0:$PATH" t 2 "guard: warn, a readlink that always fails: refuses a link chain to a .hermy.yml not made yet" guard "$repo/.worktrees/1/cfg"
rm .worktrees/1/cfg .worktrees/1/C2 .claude/coddy.yml; mv "$tmp/conf.yml" .hermy.yml
# The owner's edit moves the owner line only once all three readings allow it.
printf 'sess-old %s\n' $$ > "$tmp/own"; cp "$tmp/own" .git/hermy/1/owner
t 2 "guard: the owner's process under a new id is refused a link to the main checkout" guard "$repo/.worktrees/1/rd"
t 0 "guard: and the owner line is left as it was" cmp -s "$tmp/own" .git/hermy/1/owner
t 0 "guard: an edit it is allowed" guard "$repo/.worktrees/1/a.txt"
t 0 "guard: moves the owner line to it" holds "sess-a $$" .git/hermy/1/owner
t 0 "guard: with both starts" ownline "sess-a $$" .git/hermy/1/owner
t 2 "guard: blocks a relative path against a cwd named the owner's id and a newline" run guard < <(printf '{"session":"sess-a","cwd":"%s","paths":["x"]}' "$repo/.worktrees/1\\n")
rm .worktrees/1/rd .worktrees/1/d .worktrees/1/dd .worktrees/1/L .worktrees/1/M .worktrees/1/nl; rmdir $'.worktrees/1\n'
rm .worktrees/1/E .worktrees/1/E2 .worktrees/1/E7 .worktrees/1/lng .worktrees/1/la .worktrees/1/L2; rm -r .git/hermy/2; rmdir .worktrees/2 .worktrees/7
# ps prints a start time in the locale's language, and the guard runs in C:
# the start is read in C, so a claim, an edit, a status and another claim
# under another locale compare one format, and an owner line an earlier
# hermy wrote in another locale counts by its pid alone.
de=$(locale -a 2>/dev/null | grep -ix -m1 -e de_DE.UTF-8 -e de_DE.utf8)
if [ -n "$de" ]; then
  fresh() { rm -r .git/hermy/1; LC_ALL=$de run claim 1 >/dev/null 2>&1; cp .git/hermy/1/owner "$tmp/own"; }
  newsid() { run guard < <(printf '{"session":"sess-c","paths":["%s"]}' "$repo/.worktrees/1/a.txt"); }
  fresh
  t 0 "under $de: claim writes both starts in C" ownline "sess-a $$" "$tmp/own"
  LC_ALL=$de t 0 "under $de: guard allows the owner's edit" guard "$repo/.worktrees/1/a.txt"
  t 0 "under $de: and leaves the owner line as claim wrote it" cmp -s "$tmp/own" .git/hermy/1/owner
  LC_ALL=$de t 0 "under $de: status from another session shows the owner running" says '^owners: 1=sess-a (running)' as sess-b 1 status
  LC_ALL=$de t 1 "under $de: another session's claim is refused" as sess-b 1 claim 1
  fresh
  LC_ALL=$de t 0 "under $de: guard allows the owner's process under a new session id (/clear)" newsid
  printf 'sess-a %s %s\n' $$ "$(LC_ALL=$de ps -o lstart= -p $$ | awk '{$1=$1; gsub(/ /,"_")} 1')" > .git/hermy/1/owner
  LC_ALL=C t 0 "an owner line holding a start written under $de: status shows its live pid running" says '^owners: 1=sess-a (running)' as sess-b 1 status
  LC_ALL=C t 0 "and guard allows the owner's process under a new session id (/clear)" newsid
  LC_ALL=C t 0 "and rewrites the owner line in the C format, local start then UTC" ownline "sess-c $$" .git/hermy/1/owner
  rm -r .git/hermy/1; run claim 1 >/dev/null 2>&1
else
  echo "skip a claim under another locale: de_DE.UTF-8 not installed"
fi
# ps prints a start in local time: read in UTC, so a claim and a check
# under different time zones compare one time.
rm -r .git/hermy/1; TZ=UTC run claim 1 >/dev/null 2>&1
TZ=Asia/Tokyo t 1 "claimed under TZ=UTC: another session's claim from TZ=Asia/Tokyo is refused while the owner runs" as sess-b 1 claim 1
TZ=Asia/Tokyo t 0 "and status from there shows the owner running" says '^owners: 1=sess-a (running)' as sess-b 1 status
rm -r .git/hermy/1; run claim 1 >/dev/null 2>&1
# The owner line is built before its file is opened: no ps runs while the
# lock holds an empty owner file, which another session reads as a claim in
# flight. The stub ps logs the owner file's state at each call.
mkdir "$tmp/ownps"; printf '#!/bin/sh\nif [ ! -d "%s" ]; then echo none; elif [ -s "%s/owner" ]; then echo full; else echo empty; fi >> "%s"\nexec "%s" "$@"\n' "$repo/.git/hermy/1" "$repo/.git/hermy/1" "$tmp/ownps/seen" "$(command -v ps)" > "$tmp/ownps/ps"; chmod +x "$tmp/ownps/ps"
filled() { [ -s "$tmp/ownps/seen" ] && ! grep -qx empty "$tmp/ownps/seen"; }
: > "$tmp/ownps/seen"; PATH="$tmp/ownps:$PATH" run claim 1 >/dev/null 2>&1
t 0 "re-claim: ps never runs while the owner file is empty" filled
rm -r .git/hermy/1; : > "$tmp/ownps/seen"; PATH="$tmp/ownps:$PATH" run claim 1 >/dev/null 2>&1
t 0 "claim: nor while the lock has no owner file" filled
t 0 "claim: and the owner line is whole" ownline "sess-a $$" .git/hermy/1/owner
printf 'sess-old %s\n' $$ > .git/hermy/1/owner; : > "$tmp/ownps/seen"
PATH="$tmp/ownps:$PATH" t 0 "guard: the owner's process under a new id edits" guard "$repo/.worktrees/1/a.txt"
t 0 "guard: and ps never runs while the owner file it moves is empty" filled
t 0 "guard: and the moved owner line is whole" ownline "sess-a $$" .git/hermy/1/owner
# A path or cwd over 4096 bytes is refused before any work on it, in both
# modes: reading one takes time quadratic in its length, and a hook that
# outlasts its timeout lets the edit through before Claude Code 2.1.295.
over="$repo/$(printf './%.0s' $(seq 2050))README.md"
under="$repo/.worktrees/1/"; under="$under$(printf './%.0s' $(seq $(( (4096 - ${#under} - 5) / 2 ))))a.txt"
cp .hermy.yml "$tmp/conf.yml"
for v in block warn; do
  { grep -v '^guard:' "$tmp/conf.yml"; echo "guard: $v"; } > .hermy.yml
  t 2 "guard: $v refuses a path over 4096 bytes, promptly" timeout 1 "$here/bin/hermy" guard < <(printf '{"session":"sess-a","paths":["%s"]}' "$over")
  t 2 "guard: $v refuses a cwd over 4096 bytes" timeout 1 "$here/bin/hermy" guard < <(printf '{"session":"sess-a","cwd":"%s","paths":["README.md"]}' "${over%/README.md}")
  t 0 "guard: $v allows a path of 4096 bytes in the owner's worktree" guard "$under"
done
cp "$tmp/conf.yml" .hermy.yml
# That cap bounds the path's length, not the walk's time: each cd costs time
# in the depth, and links repeat steps there. 30 links in the owner's
# worktree, each 400 steps at depth 300 (most of a minute on macOS), are refused
# once the walk's 5 seconds have passed, not let through after it.
deep=$(printf 'd/%.0s' $(seq 300)); mkdir -p ".worktrees/1/$deep"
ln -s "$(printf '../d/%.0s' $(seq 200))" ".worktrees/1/${deep}B"
t 2 "guard: refuses a walk that outlasts its time budget, promptly" timeout 15 "$here/bin/hermy" guard < <(printf '{"session":"sess-a","paths":["%s"]}' "$pr/.worktrees/1/$deep$(printf 'B/%.0s' $(seq 30))a.txt")
rm -r .worktrees/1/d
# Nor the tail a missing directory leaves, joined and read in time
# quadratic in its length: 40 links, each putting 60 components after the
# next, the last into a missing directory, leave one past 4096 bytes.
x=$(printf '/x%.0s' $(seq 60))
for i in $(seq 39); do ln -s "S$((i+1))$x" ".worktrees/1/S$i"; done; ln -s "nodir$x" .worktrees/1/S40
t 2 "guard: refuses a tail past 4096 bytes after a missing directory, promptly" timeout 15 "$here/bin/hermy" guard < <(printf '{"session":"sess-a","paths":["%s"]}' "$pr/.worktrees/1/S1/a.txt")
rm .worktrees/1/S[0-9]*
# The Claude Code shims take their inputs from CLAUDE_* alone: an inherited
# HERMY_* value, however hostile, is ignored.
shim() { CLAUDE_PROJECT_DIR=$repo HERMY_ROOT=/ HERMY_AGENT_DIR=src HERMY_SESSION=sess-a HERMY_PID=$$ bash "$here/scripts/issue.sh" "$@"; }
shimguard() { printf '{"session_id":"sess-a","tool_input":{"file_path":"%s"}}' "$1" | shim guard; }
t 0 "shim: the root is CLAUDE_PROJECT_DIR, not an inherited HERMY_ROOT" says "^root: $repo\$" shim status
t 0 "shim: the session and pid are CLAUDE_*'s, so the owner's inherited ones do not make the claim mine" says '^owners: 1=sess-a (running)' shim status
t 2 "shim: the agent dir is .claude, not an inherited HERMY_AGENT_DIR" shimguard "$repo/src/x.c"
t 0 "shim: and .claude/ is free" shimguard "$repo/.claude/n.md"
# GIT_* from the environment (a settings env reaches the hooks) could move
# root resolution to another repository, where no config is: dropped.
GIT_DIR="$tmp/origin.git" t 0 "shim: GIT_DIR in the environment does not move the root" says "^root: $repo\$" shim status
GIT_DIR="$tmp/origin.git" t 2 "shim: so the guard still blocks the main checkout" shimguard "$repo/README.md"
shimv() { CLAUDE_PROJECT_DIR=$repo HERMY_ROOT=/ bash "$here/scripts/$1.sh"; }
t 0 "shim: config.sh takes the root from CLAUDE_PROJECT_DIR too" says '^tracker: github$' shimv config
t 0 "shim: so does detect.sh" says '^config: .hermy.yml$' shimv detect
GIT_DIR="$tmp/origin.git" t 0 "shim: config.sh drops GIT_DIR too" says '^tracker: github$' shimv config
GIT_DIR="$tmp/origin.git" t 0 "shim: so does detect.sh" says '^config: .hermy.yml$' shimv detect
HERMY_AGENT_DIR=.codex t 0 "agent dir: its worktree of a claimed issue is editable" guard "$repo/.codex/worktrees/1/a.txt"
echo x > .worktrees/1/a.txt
t 1 "push refuses another session" as sess-b 1 push 1 "feat(1): thing"
t 1 "ship stops on a failing verify" run ship 1 "feat(1): thing"
t 0 "and says so" says "verify" run ship 1 "feat(1): thing"
t 2 "and pushed nothing" git ls-remote --exit-code origin refs/heads/feat/1-thing
t 0 "push alone pushes without verify" says 'pushed: feat/1-thing' run push 1 "feat(1): thing" -- a.txt
t 0 "the branch reached the remote" git ls-remote --exit-code origin refs/heads/feat/1-thing
# The identity in GIT_AUTHOR_* and GIT_COMMITTER_* is kept by the shim (no
# git config holds one under this HOME), as the discovery variables are not.
echo y > .worktrees/1/b.txt
HOME="$tmp" GIT_DIR="$tmp/origin.git" t 0 "shim: push commits with the environment's identity, GIT_DIR dropped" says 'pushed: feat/1-thing' shim push 1 "feat(1): more" -- b.txt
was=$(git ls-remote origin refs/heads/feat/1-thing)
echo ok > .worktrees/1/ok.txt
t 0 "verify passes now" run verify 1
# cfg: a quoted value runs to its closing quote, an unquoted one loses a blank-led # comment
cp .hermy.yml "$tmp/conf.bak"; vc() { printf 'tracker: github\nworktree: git\ndefault_branch: main\n%s\n' "$1" > .hermy.yml; }
printf '#include\n' > .worktrees/1/main.c
vc "verify: \"grep -q '#include' main.c && true\""; t 0 "cfg: a # inside quotes stays in the command" run verify 1
vc 'verify: test -f ok.txt  # tests'; t 0 "cfg: a trailing comment is dropped and the command runs" run verify 1
vc 'verify: test -f ok.txt#x'; t 1 "cfg: a # with no blank before it stays" run verify 1
vc "verify: \"test -f '#ok' && false\""; t 1 "cfg: a quoted # does not turn a failing verify into a pass" run verify 1
t 1 "cfg: and ship refuses" run ship 1 "feat(1): nope"
rm -f .worktrees/1/e2e
vc 'verify: "true && test \"x\" = \"x\" && touch e2e"'; t 0 "cfg: an escaped quote does not end a double-quoted value" run verify 1
t 0 "cfg: and the part after it ran" test -f .worktrees/1/e2e
vc 'verify: "true" && false'; t 1 "cfg: text after the closing quote is kept, not dropped" run verify 1
vc 'verify: |'; t 1 "verify: a block scalar is refused" run verify 1
t 0 "verify: and the message names the key" says 'verify: a block scalar' run verify 1
for h in '>2' '|2' '>-2' '>2-' '>+1'; do vc "verify: $h"; t 1 "verify: $h is refused" run verify 1; t 0 "verify: $h names the key" says 'verify: a block scalar' run verify 1; t 1 "verify: $h made no file" test -e .worktrees/1/2; done
rm -f .worktrees/1/out; vc 'verify: >out'; t 0 "verify: >out still runs" run verify 1
vc 'verify: |x'; t 1 "verify: |x is not refused as a block scalar" says 'block scalar' run verify 1; rm -f .worktrees/1/out
cp "$tmp/conf.bak" .hermy.yml; rm .worktrees/1/main.c
t 1 "ship refuses another session" as sess-b 1 ship 1 "feat(1): ok"
t 0 "ship verifies then pushes" says 'pushed: feat/1-thing' run ship 1 "feat(1): ok" -- ok.txt e2e
t 1 "ship moved the branch on the remote" test "$(git ls-remote origin refs/heads/feat/1-thing)" = "$was"
t 0 "status lists the claimed issue as mine" says '^owners: 1=me' run status
t 0 "sweep keeps the unmerged worktree" sh -c "'$here/bin/hermy' sweep; test -d '$repo/.worktrees/1'"
t 0 "the whole flow left the main checkout alone" wire trip flow

# start installs git hooks that refuse a commit or push outside a claimed
# issue's branch, for people too; the flow above pushed through them.
hooks="$repo/.git/hooks/hermy"
t 0 "githook: start points core.hooksPath at the absolute hooks dir" test "$(git config core.hooksPath)" = "$hooks"
t 0 "githook: and writes both hooks executable" test -x "$hooks/pre-commit" -a -x "$hooks/pre-push"
# A verb run from stdin has no path of its own; start, whose hooks run hermy by it, says so.
t 0 "a verb runs from stdin" sh -c "bash -s state 1 < '$here/bin/hermy'"
# macOS ships bash 3.2 as /bin/bash (5.x elsewhere): every script must parse there, and a [!a-z] class must not pass upper case in a UTF-8 locale
if [ -x /bin/bash ]; then
  for f in "$here"/scripts/*.sh "$here/bin/hermy" "$here/get.sh"; do t 0 "/bin/bash: ${f#$here/} parses" /bin/bash -n "$f"; done
  t 1 "/bin/bash: state refuses a key with an upper-case letter in a UTF-8 locale" env LC_ALL=en_US.UTF-8 /bin/bash "$here/bin/hermy" state 1 Key=x
  t 0 "/bin/bash: and for the key, not the lock" says "lower case words" env LC_ALL=en_US.UTF-8 /bin/bash "$here/bin/hermy" state 1 Key=x
  printf 'verify: "a # b"  # c\r\n' > "$tmp/cfg3.yml"
  t 0 "/bin/bash: cfg reads a quoted # and drops the comment and the CR" test "$(/bin/bash -c "$(sed -n '/^cfg() {/,/^}/p' "$here/bin/hermy")"'; cfg verify "$1"' _ "$tmp/cfg3.yml")" = "a # b"
fi
t 1 "start from stdin fails" sh -c "bash -s start 1 feat/1-thing < '$here/bin/hermy'"
t 0 "and says why" says 'not stdin' sh -c "bash -s start 1 feat/1-thing < '$here/bin/hermy'"
t 1 "githook: a commit on the default branch is refused" git commit -q --allow-empty -m x
t 0 "githook: naming /hermy:start" says '/hermy:start <issue>' git commit -q --allow-empty -m x
t 0 "githook: and --no-verify" says 'commit with --no-verify' git commit -q --allow-empty -m x
git checkout -q -b loose
t 1 "githook: a commit on an unclaimed branch is refused" git commit -q --allow-empty -m x
git checkout -q --detach origin/main # ahead of the remote, so only the hook stops a push of it
t 0 "githook: a commit on a detached HEAD passes" git commit -q --allow-empty -m x
d=$(git rev-parse HEAD); git checkout -q main
t 0 "githook: a commit on a claimed issue's branch passes, in its worktree" git -C .worktrees/1 commit -q --allow-empty -m x
t 1 "githook: a push to the default branch is refused" git push -q origin "$d:refs/heads/main"
t 0 "githook: naming push --no-verify" says 'push with --no-verify' git push -q origin "$d:refs/heads/main"
# From a claimed issue's worktree too. Every worktree shares main, moved for
# the push to $d, which the remote lacks: an up-to-date ref sends the hook
# no line to refuse.
m=$(git rev-parse main); git update-ref refs/heads/main "$d"
t 1 "githook: git push origin main from a claimed issue's worktree is refused" git -C .worktrees/1 push -q origin main
t 0 "githook: naming the default branch" says 'push to main, the default branch' git -C .worktrees/1 push -q origin main
git update-ref refs/heads/main "$m"
t 1 "githook: a push to an unclaimed branch is refused" git push -q origin loose
t 0 "githook: a push of a claimed issue's branch passes" git -C .worktrees/1 push -q origin HEAD
git push -q --no-verify origin loose
t 0 "githook: deleting another branch passes" git push -q origin --delete loose
t 0 "githook: deleting the default branch is refused" says 'push to main, the default branch' git push -q origin --delete main
git tag t1 "$d"
t 0 "githook: a tag passes" git push -q origin t1
git branch -q -D loose
# The hook core.hooksPath named before runs after hermy's check, with the same
# arguments and stdin, its exit the hook's. start records it whenever
# core.hooksPath is not hermy's (a hook manager re-set it), and a rerun keeps it.
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
t 0 "githook: recording nothing" test -z "$(git config --local hermy.previousHooksPath)"
git config --worktree --unset core.hooksPath; git config --unset extensions.worktreeConfig
run start 1 feat/1-thing >/dev/null 2>&1
t 0 "githook: start puts core.hooksPath back" test "$(git config core.hooksPath)" = "$hooks"
t 0 "githook: recording the one before in .git/config" test "$(git config --local hermy.previousHooksPath)" = "$tmp/prev"
sums=$(cksum "$hooks"/*; git config --local hermy.previousHooksPath); run start 1 feat/1-thing >/dev/null 2>&1
t 0 "githook: a rerun changes nothing" test "$(cksum "$hooks"/*; git config --local hermy.previousHooksPath)" = "$sums"
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
  t 0 "githook: and leaves the live hooks whole" test "$(cksum "$hooks"/*; git config --local hermy.previousHooksPath)" = "$sums"
  chmod u+w "$hooks"; rm "$tmp/prev/post-commit"
fi
ln -s "$repo" "$tmp/alias"; HERMY_ROOT="$tmp/alias" run start 1 feat/1-thing >/dev/null 2>&1
t 0 "githook: a rerun by another spelling of the root keeps the record" test "$(git config --local hermy.previousHooksPath)" = "$tmp/prev"
# core.hooksPath set by one spelling of the root is set for every other: a
# rerun by the real path writes no .git/config, so a sandbox lets it pass.
git config core.hooksPath "$tmp/prev"; HERMY_ROOT="$tmp/alias" run start 1 feat/1-thing >/dev/null 2>&1
t 0 "githook: start through a symlinked root sets core.hooksPath by that spelling" test "$(git config core.hooksPath)" = "$tmp/alias/.git/hooks/hermy"
: > .git/config.lock
t 0 "githook: a rerun by the real path sees it set, so .git/config it cannot write stops nothing" run start 1 feat/1-thing
rm .git/config.lock; git config core.hooksPath "$hooks"
# start writes into a directory of its own and overwrites only what it wrote:
# lefthook, git lfs install and simple-git-hooks write into git's hooks path,
# which is this directory now.
cp "$hooks/commit-msg" "$tmp/cm"; echo foreign > "$hooks/commit-msg"
t 1 "githook: start stops on a file it did not write at a hook's name" run start 1 feat/1-thing
t 0 "githook: naming it and where it belongs" says "$hooks/commit-msg is not a hook hermy start wrote.*Move it to $tmp/prev," run start 1 feat/1-thing
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
# A push whose commit the hook refuses unstages only what it named: a named
# file stays untracked, the tracked change stays as git add -u staged it.
echo y >> .worktrees/1/a.txt; echo s > .worktrees/1/.env
PREV_EXIT=1 t 1 "push: a commit the previous pre-commit refuses fails the push" run push 1 "feat(1): refused" -- .env
t 0 "push: leaving the named file untracked, not added" test "$(git -C .worktrees/1 status --porcelain -- .env)" = "?? .env"
t 0 "push: and the tracked change as git add -u staged it" test "$(git -C .worktrees/1 status --porcelain -- a.txt)" = "M  a.txt"
git -C .worktrees/1 checkout -q HEAD -- a.txt
# A merge whose resolution the hook refuses stays a merge: push resets no
# MERGE_HEAD, so the next ship still commits it with both parents.
tip=$(git -C .worktrees/1 rev-parse HEAD)
git -C .worktrees/1 checkout -q -b side; echo side > .worktrees/1/a.txt; git -C .worktrees/1 commit -q --no-verify -am side
git -C .worktrees/1 checkout -q feat/1-thing; echo mine > .worktrees/1/a.txt; git -C .worktrees/1 commit -q --no-verify -am mine
git -C .worktrees/1 merge -q side >/dev/null 2>&1; echo both > .worktrees/1/a.txt; git -C .worktrees/1 add a.txt
PREV_EXIT=1 t 1 "push: a merge commit the previous pre-commit refuses fails the push" run push 1 "feat(1): merge" -- .env
t 0 "push: leaving the merge in progress" git -C .worktrees/1 rev-parse -q --verify MERGE_HEAD
t 0 "push: its resolution staged" test "$(git -C .worktrees/1 status --porcelain -- a.txt)" = "M  a.txt"
t 0 "push: and the named file untracked" test "$(git -C .worktrees/1 status --porcelain -- .env)" = "?? .env"
git -C .worktrees/1 merge --abort; git -C .worktrees/1 reset -q --hard "$tip"; git -C .worktrees/1 branch -q -D side; rm .worktrees/1/.env
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
PATH="$tmp/eperm:$PATH" t 0 "githook: naming the sandbox and the user's one run from their own terminal" says 'sandbox.*Install them once from your own terminal, not through an agent: in .*, run start for issue 1 on branch feat/1-thing with the hermy at .*/hermy\. A rerun then writes nothing' run start 1 feat/1-thing
run start 1 feat/1-thing >/dev/null 2>&1
t 0 "githook: none before is recorded as none" sh -c 'v=$(git config --local hermy.previousHooksPath) && [ -z "$v" ]'
t 1 "githook: under .git/hooks, its hermy directory gets no pass-through" test -e "$hooks/hermy"
cp "$tmp/prev/pre-commit" .git/hooks/pre-commit
PREV_EXIT=1 t 1 "githook: and then .git/hooks/ runs after hermy's check" git -C .worktrees/1 commit -q --allow-empty -m x
rm .git/hooks/pre-commit
# A hermy hook is never handed off to: a copy of it in .git/hooks, or another
# repository's hermy hooks directory as the previous path, would exec itself.
cp "$hooks/pre-commit" .git/hooks/pre-commit
t 0 "githook: a copy of hermy's pre-commit in .git/hooks is not run again" timeout 20 git -C .worktrees/1 commit -q --allow-empty -m x
rm .git/hooks/pre-commit
cp -R "$hooks" "$tmp/otherhooks"; git config --local hermy.previousHooksPath "$tmp/otherhooks"
t 0 "githook: another repository's hermy hooks directory as the previous path is not run" timeout 20 git -C .worktrees/1 commit -q --allow-empty -m x
git config --local --unset hermy.previousHooksPath; rm -rf "$tmp/otherhooks"
# On a case-insensitive file system PRE-COMMIT is pre-commit: a pass-through by
# that name would replace hermy's own. Either way hermy's stays.
printf '#!/bin/sh\nexit 0\n' > .git/hooks/PRE-COMMIT; chmod +x .git/hooks/PRE-COMMIT; run start 1 feat/1-thing >/dev/null 2>&1
t 0 "githook: a previous PRE-COMMIT leaves hermy's pre-commit in place" grep -q 'githook pre-commit' "$hooks/pre-commit"
t 1 "githook: which still refuses a commit on the default branch" git commit -q --allow-empty -m x
rm .git/hooks/PRE-COMMIT
# The hooks run hermy by the path start embeds and nothing else: a hermy on
# PATH, in the project or not, may be one a sandboxed command planted.
mkdir "$tmp/moved" "$tmp/onpath" "$repo/plant"; cp "$here/bin/hermy" "$tmp/moved/"
printf '#!/bin/sh\n: > "%s"\n' "$tmp/planted" > "$tmp/onpath/hermy"; cp "$tmp/onpath/hermy" "$repo/plant/"; chmod +x "$tmp/onpath/hermy" "$repo/plant/hermy"
plant="$repo/plant:$tmp/onpath:$PATH"
(cd .worktrees/1 && ../../../moved/hermy start 1 feat/1-thing) >/dev/null 2>&1
t 0 "githook: start run by a relative path, away from the root, writes that hermy's absolute path" grep -qxF "c='$tmp/moved/hermy'" "$hooks/pre-commit"
rm "$tmp/moved/hermy"
PATH="$plant" t 1 "githook: a hook whose hermy is gone refuses, with a hermy on PATH" git -C .worktrees/1 commit -q --allow-empty -m x
t 1 "githook: running none of them" test -e "$tmp/planted"
PATH="$plant" t 0 "githook: naming the path gone" says "$tmp/moved/hermy, the hermy that checks this commit, is gone" git -C .worktrees/1 commit -q --allow-empty -m x
PATH="$plant" t 0 "githook: what puts it back" says "is gone\. When it is the launcher your agent points at its hermy install as a session starts, a new session puts it back; either way, one run of hermy's start from your own terminal, with a hermy installed outside the project, puts these hooks back\." git -C .worktrees/1 commit -q --allow-empty -m x
PATH="$plant" t 1 "githook: naming no agent, since the core is any agent's" says Claude git -C .worktrees/1 commit -q --allow-empty -m x
PATH="$plant" t 0 "githook: --no-verify" says '\. --no-verify skips the check' git -C .worktrees/1 commit -q --allow-empty -m x
PATH="$plant" t 0 "githook: and, none recorded, how to turn it off, in words" says 'unset core.hooksPath in .git/config, which named no directory before hermy\.$' git -C .worktrees/1 commit -q --allow-empty -m x
PATH="$plant" t 1 "githook: with no command to paste" says 'git config\|/hermy:start' git -C .worktrees/1 commit -q --allow-empty -m x
# The recorded path as recorded: echo in sh would read its backslash as an escape.
b="$tmp/pr\\ev"; cp "$here/bin/hermy" "$tmp/moved/"; git config core.hooksPath "$b"; "$tmp/moved/hermy" start 1 feat/1-thing >/dev/null 2>&1; rm "$tmp/moved/hermy"
PATH="$tmp/nojq" t 0 "githook: and, one recorded, how to put it back, backslash and all" sh -c 'git -C .worktrees/1 commit -q --allow-empty -m x 2>&1 | grep -qF -- "$1"' _ "set core.hooksPath in .git/config back to $b, the directory it named before hermy."
git config --unset core.hooksPath
# Behind a launcher (HERMY_EXEC, which an adapter's link keeps pointed at its
# current install) the hooks stay byte for byte the same across updates, so a
# sandboxed start after one writes nothing, and a commit runs the current hermy.
mkdir "$tmp/v1" "$tmp/v2" "$tmp/data"; cp "$here/bin/hermy" "$tmp/v1/"
{ head -1 "$here/bin/hermy"; printf 'echo "$*" >> "%s"\n' "$tmp/v2.log"; tail -n +2 "$here/bin/hermy"; } > "$tmp/v2/hermy"; chmod +x "$tmp/v2/hermy"
t 0 "link: prints nothing and exits 0" quiet "$tmp/v1/hermy" link "$tmp/data"
t 0 "link: points <dir>/hermy at the hermy it ran, by its real path" test "$(readlink "$tmp/data/hermy")" = "$(cd "$tmp/v1" && pwd -P)/hermy"
ino=$(ls -i "$tmp/data/hermy"); "$tmp/v1/hermy" link "$tmp/data"
t 0 "link: pointing there already, it makes no new link" test "$(ls -i "$tmp/data/hermy")" = "$ino"
t 0 "link: into a directory that is not there, nothing and exit 0" quiet "$tmp/v1/hermy" link "$tmp/nodata"
HERMY_EXEC="$tmp/data/hermy" "$tmp/v1/hermy" start 1 feat/1-thing >/dev/null 2>&1
t 0 "githook: start writes HERMY_EXEC's path, not its own" grep -qxF "c='$tmp/data/hermy'" "$hooks/pre-commit"
sums=$(cksum "$hooks"/*; git config --local --list)
"$tmp/v2/hermy" link "$tmp/data"; rm -r "$tmp/v1"
t 0 "link: an update repoints it" test "$(readlink "$tmp/data/hermy")" = "$(cd "$tmp/v2" && pwd -P)/hermy"
if [ "$(id -u)" != 0 ]; then # root writes anywhere
  chmod a-w "$hooks" .git
  HERMY_EXEC="$tmp/data/hermy" t 0 "githook: after an update, start passes where neither the hooks nor .git/config can be written" "$tmp/v2/hermy" start 1 feat/1-thing
  t 0 "githook: and so does start run by the launcher's path, the terminal run a sandbox's refusal names" "$tmp/data/hermy" start 1 feat/1-thing
  chmod u+w "$hooks" .git
fi
t 0 "githook: and the hooks are byte for byte as they were" test "$(cksum "$hooks"/*; git config --local --list)" = "$sums"
: > "$tmp/v2.log"
PATH="$tmp/nojq" t 0 "githook: a commit on the claimed branch, with no hermy on PATH, runs the launcher's" git -C .worktrees/1 commit -q --allow-empty -m x
t 0 "githook: the current hermy, not the one start ran" grep -q '^githook pre-commit' "$tmp/v2.log"
PATH="$plant" git -C .worktrees/1 commit -q --allow-empty -m x >/dev/null 2>&1
t 1 "githook: a hermy on PATH, in the project or not, never runs" test -e "$tmp/planted"
# git runs the hooks outside any sandbox: hermy runs under a bash from PATH,
# and finds its tools there, past every entry that is relative or lies in the
# repository (the checkout, the hook's own worktree), where a sandboxed
# command could plant one; the hook before gets PATH as git gave it.
g=$(command -v git); mkdir "$tmp/rel" "$repo/tools"
for x in bash sed git; do printf '#!/bin/sh\n: > "%s"\nexec %s "$@"\n' "$tmp/planted" "$(command -v "$x")" > "$repo/tools/$x"; chmod +x "$repo/tools/$x"; cp "$repo/tools/$x" "$tmp/rel/"; done
printf '#!/bin/sh\nprintf %%s "$PATH" > "%s"\n' "$tmp/prevpath" > .git/hooks/pre-commit; chmod +x .git/hooks/pre-commit
: > "$tmp/v2.log"
PATH="../../../rel:$repo/tools:$PATH" t 0 "githook: a commit with bash, sed and git first on PATH, in the repository or by a relative entry, passes" "$g" -C .worktrees/1 commit -q --allow-empty -m x
t 0 "githook: having run the launcher's hermy" grep -q '^githook pre-commit' "$tmp/v2.log"
t 1 "githook: and none of them" test -e "$tmp/planted"
t 0 "githook: the hook before gets PATH as git gave it" grep -qF ":../../../rel:$repo/tools:" "$tmp/prevpath"
"$g" worktree add -q --detach "$tmp/w" 2>/dev/null; mkdir "$tmp/w/plant"; cp "$repo/tools/bash" "$repo/tools/sed" "$repo/tools/git" "$tmp/w/plant/"
PATH="$tmp/w/plant:$PATH" t 0 "githook: a commit in a worktree outside the checkout, with them first on PATH in that worktree, passes" "$g" -C "$tmp/w" commit -q --allow-empty -m x
t 1 "githook: running none of them either" test -e "$tmp/planted"
out=$(PATH="$repo/tools" "$g" -C .worktrees/1 commit -q --allow-empty -m x 2>&1); r=$?
t 0 "githook: with no bash on PATH but in the repository, the hook refuses" test "$r" = 1
t 0 "githook: saying why, in plain text" grep -qF "hermy: no bash on PATH outside the repository at $(cd "$repo" && pwd -P), so $tmp/data/hermy, the hermy that checks this commit, cannot run." <<<"$out"
t 1 "githook: having run none of them" test -e "$tmp/planted"
rm -r .git/hooks/pre-commit "$repo/tools"
# That bash runs with -p, as hooks.json's do: a BASH_ENV file, or a function
# exported under the name of a command the core runs, would pass the check.
printf ': > "%s"\nexit 0\n' "$tmp/envran" > "$tmp/benv"
BASH_ENV="$tmp/benv" t 1 "githook: a BASH_ENV in git's environment does not pass a commit on the default branch" git commit -q --allow-empty -m x
t 1 "githook: nor is it read" test -e "$tmp/envran"
t 1 "githook: nor does a git function exported into git's environment" bash -c "git() { : > '$tmp/envran'; }; export -f git; exec \"\$0\" commit -q --allow-empty -m x" "$g"
t 1 "githook: which the core never runs" test -e "$tmp/envran"
rm "$tmp/data/hermy"
PATH="$plant" t 1 "githook: with the launcher gone, the hook refuses" git -C .worktrees/1 commit -q --allow-empty -m x
PATH="$plant" t 0 "githook: naming it gone" says "$tmp/data/hermy, the hermy that checks this commit, is gone" git -C .worktrees/1 commit -q --allow-empty -m x
t 1 "githook: and running none on PATH" test -e "$tmp/planted"
# start refuses a hermy the project holds, by any path to it: git runs it
# outside the sandbox, and a sandboxed command can rewrite it.
mkdir "$repo/bin"; cp "$here/bin/hermy" "$repo/bin/"; ln -s "$repo/bin/hermy" "$tmp/inlink"; ln -s "$here/bin/hermy" "$repo/bin/mid"; ln -s "$repo/bin/mid" "$tmp/chain"
sums=$(cksum "$hooks"/*; git config --local --list)
t 1 "start run from <root>/bin/hermy is refused" "$repo/bin/hermy" start 1 feat/1-thing
inside='is inside the project at .*, or a link on the way to its file lies there\. git runs its hooks outside any sandbox'
t 0 "saying why" says "$inside" "$repo/bin/hermy" start 1 feat/1-thing
HERMY_EXEC="$tmp/inlink" t 0 "so is a HERMY_EXEC that resolves to a file there" says "$inside" run start 1 feat/1-thing
HERMY_EXEC="$tmp/chain" t 0 "and one whose links pass through the project" says "$inside" run start 1 feat/1-thing
HERMY_EXEC="$tmp/alias/bin/hermy" t 0 "and one through a link to the root" says "$inside" run start 1 feat/1-thing
HERMY_EXEC=bin/hermy t 0 "and a relative HERMY_EXEC" says "HERMY_EXEC must be an absolute path" run start 1 feat/1-thing
# A link to a directory on the way counts too: cd -P passes it unseen, and the
# hook names the path through it, which a sandboxed command can repoint.
ln -s "$here/bin" "$repo/lnk"; ln -s "$repo/lnk" "$tmp/dirchain"
t 0 "start run through a link in the project to a directory outside it is refused" says "$inside" "$repo/lnk/hermy" start 1 feat/1-thing
HERMY_EXEC="$tmp/dirchain/hermy" t 0 "and a HERMY_EXEC whose directory's links pass through the project" says "$inside" run start 1 feat/1-thing
HERMY_EXEC="$here/bin/hermy/" t 0 "and one with a trailing slash, which names no file" says "could not follow .* to its file" run start 1 feat/1-thing
# A session's sandbox writes its own directory, which may be a worktree of the
# repository outside the checkout, or wherever the call began.
mkdir "$tmp/w/plug"; cp "$here/bin/hermy" "$tmp/w/plug/"
HERMY_EXEC="$tmp/w/plug/hermy" t 0 "and a HERMY_EXEC in a worktree of the repository outside the checkout" says "$inside" run start 1 feat/1-thing
mkdir "$tmp/nowtl"; printf '#!/bin/sh\ncase " $* " in *" worktree list "*) exit 0 ;; esac\nexec %s "$@"\n' "$g" > "$tmp/nowtl/git"; chmod +x "$tmp/nowtl/git"
PATH="$tmp/nowtl:$PATH" HERMY_ROOT="$tmp/w" t 0 "and one where the call began, with git listing no worktree" says "$inside" "$tmp/w/plug/hermy" start 1 feat/1-thing
# A listing that fails is no empty one: start cannot tell where the hermy
# path sits, and refuses in plain text.
sed 's/) exit 0 ;;/) exit 128 ;;/' "$tmp/nowtl/git" > "$tmp/nowtl/g2"; mv "$tmp/nowtl/g2" "$tmp/nowtl/git"; chmod +x "$tmp/nowtl/git"
PATH="$tmp/nowtl:$PATH" t 1 "start refuses when git worktree list fails" run start 1 feat/1-thing
PATH="$tmp/nowtl:$PATH" t 0 "saying it cannot tell where the hermy path lies" says 'git worktree list failed, so start cannot tell whether .* lies in a worktree of the repository' run start 1 feat/1-thing
# So does jj's, under worktree: jj in a jj repository, with a jj that names a workspace's root.
mkdir "$tmp/jjwl"; printf '#!/bin/sh\n[ "$1" != --version ] || { echo "jj 0.46.0"; exit 0; }\nexit 1\n' > "$tmp/jjwl/jj"; chmod +x "$tmp/jjwl/jj"
cp .hermy.yml "$tmp/wc.yml"; { echo 'worktree: jj'; grep -v '^worktree:' "$tmp/wc.yml"; } > .hermy.yml; mkdir -p .jj/repo
PATH="$tmp/jjwl:$PATH" t 1 "start refuses when jj workspace list fails under worktree: jj" run start 1 feat/1-thing
PATH="$tmp/jjwl:$PATH" t 0 "saying it cannot tell where the hermy path lies" says 'jj workspace list failed, so start cannot tell whether .* lies in a worktree of the repository' run start 1 feat/1-thing
cp "$tmp/wc.yml" .hermy.yml; rm -r .jj
t 0 "having written nothing" test "$(cksum "$hooks"/*; git config --local --list)" = "$sums"
"$g" worktree remove --force "$tmp/w"
rm -r "${repo:?}/bin" "$repo/plant" "$repo/lnk" "$tmp/inlink" "$tmp/chain" "$tmp/dirchain"
git config --unset core.hooksPath; run start 1 feat/1-thing >/dev/null 2>&1
# No config next to a started issue's leftovers (a claim, .git/hooks/hermy)
# is a config removed, not never written: guard, snap and the git hooks
# refuse, naming both in plain text, and a Write of a config is asked.
pp() { echo "refs/heads/main $d refs/heads/main $d" | "$hooks/pre-push" origin x; }
t 1 "githook: run by hand, pre-commit on the default branch refuses" "$hooks/pre-commit"
t 1 "githook: and pre-push to it" pp
mv .hermy.yml "$tmp/aside"
t 1 "removed config: with a claim and the git hooks left, pre-commit on main refuses" "$hooks/pre-commit"
t 1 "removed config: and pre-push" pp
t 0 "removed config: naming the missing config and the hooks directory" says 'no config file is at .hermy.yml, .coddy.yml or .claude/coddy.yml, yet .git/hooks/hermy is there' "$hooks/pre-commit"
t 2 "removed config: guard refuses an edit" guard "$repo/README.md"
t 2 "removed config: snap refuses a command" wire snap w
t 0 "removed config: snap names the config and the hooks directory" says 'no config file is at .hermy.yml, .coddy.yml or .claude/coddy.yml, yet .git/hooks/hermy is there' wire snap w
t 1 "removed config: and writes no not-onboarded snapshot" test -e "$snapfile"
tm=$(guard "$repo/README.md" 2>&1)
t 0 "removed config: guard names the config and the hooks directory" grep -q 'no config file is at .hermy.yml, .coddy.yml or .claude/coddy.yml, yet .git/hooks/hermy is there' <<<"$tm"
t 0 "removed config: and both ways out, in words" grep -q 'write .hermy.yml with the Write tool.*remove the claim locks under .git/hermy and .git/coddy and the .git/hooks/hermy and .git/hooks/coddy directories, and set core.hooksPath back to the hermy.previousHooksPath that .git/config records (coddy.previousHooksPath when that is missing).*when that is empty or missing, unset core.hooksPath, never set it to an empty value' <<<"$tm"
t 1 "removed config: with no command to paste" grep -qE 'git config |rm -|`' <<<"$tm"
t 0 "removed config: and that a tracked config comes back from HEAD in your own terminal" grep -qF 'when git tracks it, restore it from HEAD with git in your own terminal' <<<"$tm"
t 2 "removed config: guard refuses a path outside the project too" guard "$tmp/elsewhere.txt"
t 0 "removed config: a Write of .hermy.yml is asked" asks "$repo/.hermy.yml"
t 1 "removed config: naming no /hermy:config, which stops without a config" grep -qF '/hermy:config' <<<"$out"
lasks() { out=$(guard "$1") && jq -e '.hermy == "ask" and (.text | contains(".claude/coddy.yml"))' <<<"$out"; }
t 0 "removed config: and one of .claude/coddy.yml" lasks "$repo/.claude/coddy.yml"
t 0 "removed config: and one of .coddy.yml" casks "$repo/.coddy.yml"
t 2 "removed config: but no other edit under .claude/" guard "$repo/.claude/notes.md"
mv "$hooks" "$tmp/hooks-aside"
t 2 "removed config: a claim alone is enough for guard" guard "$repo/README.md"
t 0 "removed config: naming the claim" says 'yet .git/hermy/1 is there' guard "$repo/README.md"
t 2 "removed config: and for snap" wire snap w
t 1 "removed config: and for githook" run githook pre-commit
mv .git/hermy/1 "$tmp/lock-aside"
# What a project left by hand keeps (a .branch or .base record, swept/, a dot name) is no leftover.
sw=; [ -e .git/hermy/swept ] || [ -L .git/hermy/swept ] || { sw=1; mkdir .git/hermy/swept; }
: > .git/hermy/zz.base; : > .git/hermy/.zz.tmp
t 0 "removed config: a branch or base record, swept/ or a dot name is no leftover: guard is inert" quiet guard "$repo/README.md"
wire snap w; t 0 "removed config: and snap writes the not-onboarded snapshot" grep -qx NOT_ONBOARDED "$snapfile"; wire trip w
t 0 "removed config: and githook hands off" run githook pre-commit
rm .git/hermy/zz.base .git/hermy/.zz.tmp; [ -z "$sw" ] || rmdir .git/hermy/swept
: > .git/hermy/9
t 2 "removed config: a claim marker from before locks is a leftover too" guard "$repo/README.md"
rm .git/hermy/9
mv "$tmp/hooks-aside" "$hooks"
t 2 "removed config: the git hooks directory alone is enough for guard" guard "$repo/README.md"
t 2 "removed config: and for snap" wire snap w
t 1 "removed config: and for pre-commit" "$hooks/pre-commit"
mv "$tmp/lock-aside" .git/hermy/1
# A FIFO at .hermy.yml is no config, and the leftovers are found without opening it.
mkfifo .hermy.yml
t 2 "removed config: a FIFO at .hermy.yml does not hang guard" timeout 5 sh -c "printf '{\"session\":\"sess-a\",\"paths\":[\"$repo/README.md\"]}' | '$here/bin/hermy' guard"
t 2 "removed config: nor snap" timeout 5 sh -c "printf '{\"call\":\"w\"}' | '$here/bin/hermy' snap"
rm .hermy.yml
mv "$tmp/aside" .hermy.yml
tripped 0 "removed config: once it is back, the next command is checked as before" 'true'
# A command that rewrites the snapshot as not onboarded and removes the
# config trips (#112), and every hook after it refuses.
report "removed config: a command that rewrites the snapshot as not onboarded and removes the config trips" 'echo NOT_ONBOARDED >| "$snapfile"; rm .hermy.yml'
t 2 "removed config: and the next guard refuses" guard "$repo/README.md"
t 2 "removed config: and the next snap" wire snap w
git checkout -q -- .hermy.yml
# A hook manager's install re-points core.hooksPath (husky's prepare, on every
# npm install): the tripwire reports it once, in words of its own, and start
# putting it back is quiet. Without hermy's hooks there is nothing to report.
report "tripwire: core.hooksPath re-pointed off hermy's hooks trips" 'git config core.hooksPath .husky/_'
t 0 "tripwire: naming the value and that the hooks are off" grep -qF "core.hooksPath is now '.husky/_', not hermy's hooks directory, so hermy's git hooks are off" <<<"$out"
t 0 "tripwire: and /hermy:start" grep -qF "/hermy:start <issue> puts them back" <<<"$out"
t 1 "tripwire: not an undo" grep -qF "Undo it" <<<"$out"
tripped 0 "tripwire: the next command does not trip on it again" 'true'
tripped 0 "tripwire: start putting core.hooksPath back is quiet" 'run start 1 feat/1-thing'
t 0 "tripwire: and it is back" test "$(git config core.hooksPath)" = "$hooks"
report "tripwire: core.hooksPath unset trips" 'git config --unset core.hooksPath'
t 0 "tripwire: saying it is unset" grep -qF "core.hooksPath is now unset" <<<"$out"
tripped 0 "tripwire: and only once" 'true'
# git sets no bound on the value: a long one is named cut short, within the budget.
report "tripwire: a 100 KB core.hooksPath trips" 'git config core.hooksPath "/$(head -c 100000 /dev/zero | tr "\0" a)"'
t 0 "tripwire: naming it cut short" grep -qF "core.hooksPath is now '/aaaa" <<<"$out"
t 0 "tripwire: and saying so" grep -qF "aaa' (cut short), not hermy's hooks directory" <<<"$out"
mv "$hooks" "$tmp/hooks.aside"
tripped 0 "tripwire: without .git/hooks/hermy, a core.hooksPath change is quiet" 'git config core.hooksPath .husky/_'
# A project onboarded before the rename keeps its hooks in .git/hooks/coddy
# until its first hermy start: core.hooksPath is held to that directory meanwhile.
mkdir .git/hooks/coddy; git config core.hooksPath "$repo/.git/hooks/coddy"
tripped 0 "tripwire: with .git/hooks/coddy alone, core.hooksPath left naming it is quiet" 'true'
report "tripwire: with .git/hooks/coddy alone, core.hooksPath unset trips" 'git config --unset core.hooksPath'
t 0 "tripwire: saying the hooks are off" grep -qF "core.hooksPath is now unset, not hermy's hooks directory, so hermy's git hooks are off" <<<"$out"
git config core.hooksPath "$repo/.git/hooks/coddy"
report "tripwire: with .git/hooks/coddy alone, core.hooksPath re-pointed trips" 'git config core.hooksPath .husky/_'
t 0 "tripwire: naming /hermy:start" grep -qF "/hermy:start <issue> puts them back" <<<"$out"
rmdir .git/hooks/coddy
mv "$tmp/hooks.aside" "$hooks"; git config --unset core.hooksPath; run start 1 feat/1-thing >/dev/null 2>&1
t 0 "tripwire: start put them back" test "$(git config core.hooksPath)" = "$hooks"
# hooks: off is for an adapter that runs the shell hooks (HERMY_HOOKS=1)
# alone: the core run without it never says it, and with it names the causes.
t 1 "hooks: start without HERMY_HOOKS never says the hooks are off" says 'hooks: off' run start 1 feat/1-thing
t 1 "hooks: nor claim" says 'hooks: off' run claim 1
HERMY_HOOKS=yes t 1 "hooks: nor start with HERMY_HOOKS other than 1" says 'hooks: off' run start 1 feat/1-thing
HERMY_HOOKS=1 t 0 "hooks: with HERMY_HOOKS=1 and no snap mark for the session, start does, naming the causes" says '^hooks: off: .*disableAllHooks.*allowManagedHooksOnly.*hermy@hermy.*2\.1\.139' run start 1 feat/1-thing
# The mark is a directory snap makes with mkdir: a FIFO planted at its name
# after snap clears it (an rm that leaves it stands in for that race) neither
# holds snap nor is written through, a linked .git/hermy gets no mark, and a
# session's first snap prunes within the fingerprint's budget.
mkdir "$tmp/keeprm"; printf '#!/bin/sh\ncase "$*" in */.git/hermy/.snap-*) exit 0 ;; esac\nexec "%s" "$@"\n' "$(command -v rm)" > "$tmp/keeprm/rm"; chmod +x "$tmp/keeprm/rm"
msnap() { printf '{"session":"%s","call":"w"}' "$1" | timeout 10 env "${@:2}" "$here/bin/hermy" snap; }
mkfifo .git/hermy/.snap-sess-f
t 0 "hooks: a FIFO at the mark's name does not hold snap" msnap sess-f PATH="$tmp/keeprm:$PATH"
t 0 "hooks: and is left a FIFO" test -p .git/hermy/.snap-sess-f
rm -f .git/hermy/.snap-sess-f
mv .git/hermy "$tmp/hermy.real"; mkdir "$tmp/hermy.out"; ln -s "$tmp/hermy.out" .git/hermy
t 0 "hooks: snap runs with .git/hermy a link" msnap sess-l
t 1 "hooks: and makes no mark through it" test -e "$tmp/hermy.out/.snap-sess-l"
rm .git/hermy; mv "$tmp/hermy.real" .git/hermy
mkdir "$tmp/slowf"; printf '#!/bin/sh\ncase " $* " in *" -mmin "*) echo $$ >> "%s"; sleep 60 & echo $! >> "%s"; wait ;; esac\nexec "%s" "$@"\n' "$tmp/slow/pids" "$tmp/slow/pids" "$(command -v find)" > "$tmp/slowf/find"; chmod +x "$tmp/slowf/find"
# A budget of 4, not 2: half of it is the admin dirs' check's, which by now
# has worktree 1's entry to read, and a half of 1 may end at once.
: > "$tmp/slow/pids"; SECONDS=0; msnap sess-p HERMY_BUDGET=4 PATH="$tmp/slowf:$PATH" >/dev/null 2>&1; r=$?
t 0 "hooks: a slow prune of day-old marks holds snap no longer than the fingerprint's budget" test "$r:$((SECONDS <= 10))" = 0:1
t 0 "hooks: that prune was started" test -s "$tmp/slow/pids"
t 1 "hooks: and none of it is left running" left
t 0 "hooks: the session's mark is there all the same" test -d .git/hermy/.snap-sess-p
wire trip w >/dev/null 2>&1; rm -rf .git/hermy/.snap-* "$tmp/keeprm" "$tmp/slowf" "$tmp/hermy.out"
# A moved checkout's core.hooksPath names hermy's hooks by the old path: start
# keeps the record of the one before rather than taking that one for it.
mv1="$tmp/mv1" mv2="$tmp/mv2"
git init -q --bare "$tmp/mvo.git"; git clone -q "$tmp/mvo.git" "$mv1" 2>/dev/null
(cd "$mv1" && git checkout -q -b main && echo hi > README.md && git add -A && git commit -q -m init && git push -q -u origin main && cp "$repo/.hermy.yml" . && git config core.hooksPath .husky/_)
HERMY_ROOT="$mv1" run start 3 feat/3-mv >/dev/null 2>&1
t 0 "moved checkout: start records the hook manager's core.hooksPath" test "$(git -C "$mv1" config --local hermy.previousHooksPath)" = .husky/_
mv "$mv1" "$mv2"; HERMY_ROOT="$mv2" run start 4 feat/4-mv >/dev/null 2>&1
t 0 "moved checkout: start points core.hooksPath at the new path" test "$(git -C "$mv2" config core.hooksPath)" = "$mv2/.git/hooks/hermy"
t 0 "moved checkout: and keeps that record, not the old path" test "$(git -C "$mv2" config --local hermy.previousHooksPath)" = .husky/_
# A project onboarded before the rename (#463), as that version left it: its
# config at .coddy.yml, its hooks under .git/hooks/coddy carrying the old
# header, core.hooksPath there and the hook before them recorded in
# coddy.previousHooksPath. start moves core.hooksPath to .git/hooks/hermy and
# records that hook as hermy's, a commit on the claimed issue's branch passes
# and runs it, and no hook with the old header ever runs.
lg="$tmp/lg"
git init -q --bare "$tmp/lgo.git"; git clone -q "$tmp/lgo.git" "$lg" 2>/dev/null
mkdir "$tmp/lgprev"; printf '#!/bin/sh\necho prev >> "%s"\n' "$tmp/lg.log" > "$tmp/lgprev/pre-commit"; chmod +x "$tmp/lgprev/pre-commit"
(cd "$lg" && git checkout -q -b main && echo hi > README.md && git add -A && git commit -q -m init && git push -q -u origin main && cp "$repo/.hermy.yml" .coddy.yml && mkdir .git/hooks/coddy &&
  for h in pre-commit pre-push; do printf '#!/bin/sh\n# Written by coddy start: the hook from before the rename.\necho old >> "%s"; exit 1\n' "$tmp/lg.log" > .git/hooks/coddy/$h; chmod +x .git/hooks/coddy/$h; done &&
  git config core.hooksPath "$lg/.git/hooks/coddy" && git config coddy.previousHooksPath "$tmp/lgprev")
lgr() { HERMY_ROOT="$lg" run "$@"; }
# Moving core.hooksPath off .git/hooks/coddy holds that directory to the rule
# hermy's own is held to, before anything is written: a hook another tool
# installed among the old ones (git lfs install's post-merge), or a link in
# its place, stops start.
printf '#!/bin/sh\nexit 0\n' > "$lg/.git/hooks/coddy/post-merge"; chmod +x "$lg/.git/hooks/coddy/post-merge"
t 1 "old name: start stops on a file in .git/hooks/coddy it did not write" lgr start 5 feat/5-old
t 0 "old name: naming it and where it belongs" says "$lg/.git/hooks/coddy/post-merge is not a hook hermy start wrote before the rename.*Move it to $tmp/lgprev," lgr start 5 feat/5-old
t 0 "old name: having written no hook and no config" sh -c '! test -e "$1/.git/hooks/hermy" && test "$(git -C "$1" config core.hooksPath)" = "$1/.git/hooks/coddy" && ! git -C "$1" config --local hermy.previousHooksPath' - "$lg"
rm "$lg/.git/hooks/coddy/post-merge"; mv "$lg/.git/hooks/coddy" "$tmp/lgold"; ln -s "$tmp/lgold" "$lg/.git/hooks/coddy"
t 1 "old name: start stops when .git/hooks/coddy is a symlink" lgr start 5 feat/5-old
t 0 "old name: having written no hook" test ! -e "$lg/.git/hooks/hermy"
rm "$lg/.git/hooks/coddy"; mv "$tmp/lgold" "$lg/.git/hooks/coddy"
lgr start 5 feat/5-old >/dev/null 2>&1; lgr claim 5 >/dev/null 2>&1
t 0 "old name: start points core.hooksPath at hermy's directory" test "$(git -C "$lg" config core.hooksPath)" = "$lg/.git/hooks/hermy"
t 0 "old name: recording the hook before the old ones as hermy's" test "$(git -C "$lg" config --local hermy.previousHooksPath)" = "$tmp/lgprev"
t 0 "old name: a commit on the claimed issue's branch passes" git -C "$lg/.worktrees/5" commit -q --allow-empty -m x
t 0 "old name: running the hook before, never an old one" test "$(cat "$tmp/lg.log")" = prev
t 1 "old name: a commit on the default branch is refused" git -C "$lg" commit -q --allow-empty -m x
t 0 "old name: start removes the hooks from before the rename and their directory" test ! -e "$lg/.git/hooks/coddy"
t 1 "old name: and the old record, hermy's being set" git -C "$lg" config --local coddy.previousHooksPath
lgr start 5 feat/5-old >/dev/null 2>&1
t 0 "old name: a rerun keeps the record" test "$(git -C "$lg" config --local hermy.previousHooksPath)" = "$tmp/lgprev"
# Once hermy's are in place, start removes only what it wrote under the old
# name, the directory once empty, and the old record only once hermy's is
# set; a removal that fails stops it, naming what it could not remove.
mkdir "$lg/.git/hooks/coddy"; printf '#!/bin/sh\n# Written by coddy start: the hook from before the rename.\necho old >> "%s"; exit 1\n' "$tmp/lg.log" > "$lg/.git/hooks/coddy/pre-commit"; chmod +x "$lg/.git/hooks/coddy/pre-commit"
printf '#!/bin/sh\nexit 0\n' > "$lg/.git/hooks/coddy/post-merge"; git -C "$lg" config coddy.previousHooksPath "$tmp/lgprev"; git -C "$lg" config --unset hermy.previousHooksPath
lgr start 5 feat/5-old >/dev/null 2>&1
t 0 "old name: start leaves a file in .git/hooks/coddy it did not write, and so the directory" test -f "$lg/.git/hooks/coddy/post-merge" -a ! -e "$lg/.git/hooks/coddy/pre-commit"
t 0 "old name: and the old record while hermy's is missing" test "$(git -C "$lg" config --local coddy.previousHooksPath)" = "$tmp/lgprev"
if [ "$(id -u)" != 0 ]; then # root writes anywhere
  printf '#!/bin/sh\n# Written by coddy start: x\n' > "$lg/.git/hooks/coddy/pre-push"; chmod a-w "$lg/.git/hooks/coddy"
  t 1 "old name: start that cannot remove an old hook fails" lgr start 5 feat/5-old
  t 0 "old name: naming it" says "could not remove $lg/.git/hooks/coddy/pre-push" lgr start 5 feat/5-old
  chmod u+w "$lg/.git/hooks/coddy"; rm "$lg/.git/hooks/coddy/pre-push"
fi
rm "$lg/.git/hooks/coddy/post-merge"; git -C "$lg" config hermy.previousHooksPath "$tmp/lgprev"
printf '#!/bin/sh\n# Written by coddy start: x\n' > "$lg/.git/hooks/coddy/.pre-push.123" # a temp an old start left
lgr start 5 feat/5-old >/dev/null 2>&1
t 0 "old name: the directory goes once empty, a temp an old start left included, and the old record once hermy's is set" sh -c '! test -e "$1/.git/hooks/coddy" && ! git -C "$1" config --local coddy.previousHooksPath' - "$lg"
if [ "$(id -u)" != 0 ]; then
  chmod a-w "$lg/.git/hooks" "$lg/.git/hooks/hermy"; : > "$lg/.git/config.lock"
  t 0 "old name: a rerun then writes nothing, so it passes where neither the hooks nor .git/config can be written" lgr start 5 feat/5-old
  chmod u+w "$lg/.git/hooks" "$lg/.git/hooks/hermy"; rm "$lg/.git/config.lock"
fi
# githook never runs a hook carrying the old header, and reads the old record while hermy's is missing.
mkdir "$lg/.git/hooks/coddy"; printf '#!/bin/sh\n# Written by coddy start: the hook from before the rename.\necho old >> "%s"; exit 1\n' "$tmp/lg.log" > "$lg/.git/hooks/coddy/pre-commit"; chmod +x "$lg/.git/hooks/coddy/pre-commit"
git -C "$lg" config hermy.previousHooksPath "$lg/.git/hooks/coddy"; : > "$tmp/lg.log"
t 0 "old name: githook never hands off to a hook carrying the old header" git -C "$lg/.worktrees/5" commit -q --allow-empty -m x
t 0 "old name: which never ran" test ! -s "$tmp/lg.log"
git -C "$lg" config --unset hermy.previousHooksPath; git -C "$lg" config coddy.previousHooksPath "$tmp/lgprev"
t 0 "old name: githook reads coddy.previousHooksPath while hermy's is missing" git -C "$lg/.worktrees/5" commit -q --allow-empty -m x
t 0 "old name: and runs that hook" test "$(cat "$tmp/lg.log")" = prev
# Its leftovers are a removed config's too (left): with no config, the old
# hooks directory alone, or a claim under the old records alone, refuses.
lgguard() { printf '{"session":"sess-a","paths":["%s"]}' "$lg/README.md" | HERMY_ROOT="$lg" run guard; }
mv "$lg/.coddy.yml" "$tmp/lg.yml"; rm -rf "$lg/.git/hooks/hermy" "$lg/.git/hermy"
t 2 "old name: no config next to .git/hooks/coddy refuses an edit" lgguard
t 0 "old name: naming it" says 'yet .git/hooks/coddy is there' lgguard
mv "$lg/.git/hooks/coddy" "$tmp/lghooks"; mkdir -p "$lg/.git/coddy/5"
t 2 "old name: and next to a claim under .git/coddy" lgguard
t 0 "old name: naming it" says 'yet .git/coddy/5 is there' lgguard
rmdir "$lg/.git/coddy/5"; mkdir "$lg/.git/coddy/swept"; : > "$lg/.git/coddy/5.branch"; : > "$lg/.git/coddy/.snap-x"
t 0 "old name: its swept/, .branch record and dot names are no leftover" quiet lgguard

# A project as it stood before the rename, taken through /hermy:migrate's
# verbs and start, ends where a fresh hermy onboarding and claim does: the
# same records under .git/hermy, hooks under .git/hooks/hermy, git config
# keys and backups under the agent dir, with nothing from before the rename
# left but the workflow, which migrate names to rename in a PR. The project
# is onboarded and claimed fresh first, its state kept, then turned into the
# old layout in place, so both are read at the same root.
fx="$tmp/fx" AGENT_DIR=.claude
git init -q --bare "$tmp/fxo.git"; git clone -q "$tmp/fxo.git" "$fx" 2>/dev/null
mkdir "$tmp/fxprev"; printf '#!/bin/sh\nexit 0\n' > "$tmp/fxprev/pre-commit"; cp "$tmp/fxprev/pre-commit" "$tmp/fxprev/post-merge"; chmod +x "$tmp/fxprev"/*
printf 'version: 2\ntracker: github\nworktree: git\ndefault_branch: main\n' > "$tmp/fx.yml"
(cd "$fx" && git checkout -q -b main && echo hi > README.md && git add -A && git commit -q -m init && git push -q -u origin main && cp "$tmp/fx.yml" .hermy.yml &&
  git config core.hooksPath "$tmp/fxprev" && mkdir -p "$AGENT_DIR/hermy/backup/20261116-120000" && echo old > "$AGENT_DIR/hermy/backup/20261116-120000/AGENTS.md")
fxr() { HERMY_ROOT="$fx" HERMY_AGENT_DIR=.claude run "$@"; }
fxr start 6 feat/6-fx >/dev/null 2>&1; fxr claim 6 >/dev/null 2>&1
# every path under hermy's three directories, each file's content, and the git config keys either name writes
fxstate() (cd "$fx" && find .git/hermy .git/hooks/hermy "$AGENT_DIR/hermy" | sort && find .git/hermy .git/hooks/hermy "$AGENT_DIR/hermy" -type f -exec cksum {} + | sort && git config --local --get-regexp '^(core\.hookspath|hermy\.|c[o]ddy\.)')
fxstate > "$tmp/fx.want"
t 0 "migration: the fresh project holds a claim, its hooks with a pass-through, and the hook before recorded" sh -c 'test -s "$1/.git/hermy/6/owner" && test -s "$1/.git/hermy/6.branch" && test -x "$1/.git/hooks/hermy/post-merge" && grep -qx "hermy.previoushookspath $2" "$3"' - "$fx" "$tmp/fxprev" "$tmp/fx.want"
(cd "$fx" && mv .hermy.yml .coddy.yml && mv .git/hermy .git/coddy && mv "$AGENT_DIR/hermy" "$AGENT_DIR/coddy" && mv .git/hooks/hermy .git/hooks/coddy &&
  for f in .git/hooks/coddy/*; do sed 's/^# Written by hermy start: /# Written by coddy start: /' "$f" > "$f.n" && chmod +x "$f.n" && mv "$f.n" "$f"; done &&
  git config core.hooksPath "$fx/.git/hooks/coddy" && git config coddy.previousHooksPath "$tmp/fxprev" && git config --unset hermy.previousHooksPath &&
  mkdir -p .github/workflows && cp "$here/templates/hermy.yml" .github/workflows/coddy.yml)
t 0 "migration: the old layout carries the old header" grep -q '^# Written by coddy start: ' "$fx/.git/hooks/coddy/pre-commit"
t 0 "migration: config names the config from before the rename for /hermy:migrate" says '^MIGRATE: .coddy.yml$' fxr config
fxr migrate > "$tmp/fx.mig" 2>&1
for l in 'changed: move .coddy.yml -> .hermy.yml' 'changed: move .git/coddy -> .git/hermy' "changed: move $AGENT_DIR/coddy -> $AGENT_DIR/hermy" 'rename: .github/workflows/coddy.yml'; do
  t 0 "migration: migrate prints $l" grep -qxF "$l" "$tmp/fx.mig"
done
# the skill's order: exclude answers, migrate records, the Write of .hermy.yml, the rm of the source; then start
fxr exclude answers >/dev/null 2>&1
t 0 "migration: migrate records" fxr migrate records
sed '1,/^---$/d' "$tmp/fx.mig" > "$fx/.hermy.yml"; rm "$fx/.coddy.yml"
t 0 "migration: config prints the config once it is .hermy.yml" says '^tracker: github$' fxr config
t 0 "migration: start on the claimed issue" fxr start 6 feat/6-fx
fxstate > "$tmp/fx.got"
t 0 "migration: ends with the records, hooks, git config keys and backups of a fresh onboarding and claim" cmp -s "$tmp/fx.want" "$tmp/fx.got"
t 0 "migration: and its config" cmp -s "$fx/.hermy.yml" "$tmp/fx.yml"
t 0 "migration: nothing from before the rename is left but the workflow" sh -c 'cd "$1" && test -z "$(find . -iname "*c[o]ddy*" ! -path ./.github/workflows/c[o]ddy.yml -print)"' - "$fx"
fxr migrate > "$tmp/fx.mig" 2>&1
t 0 "migration: migrate then names the workflow alone" test "$(grep -e '^changed:' -e '^rename:' "$tmp/fx.mig")" = 'rename: .github/workflows/coddy.yml'
if [ "$(id -u)" != 0 ]; then # root writes anywhere
  chmod a-w "$fx/.git/hooks" "$fx/.git/hooks/hermy"; : > "$fx/.git/config.lock"
  t 0 "migration: a rerun of start writes nothing, so it passes where neither the hooks nor .git/config can be written" fxr start 6 feat/6-fx
  chmod u+w "$fx/.git/hooks" "$fx/.git/hooks/hermy"; rm "$fx/.git/config.lock"
fi

# get.sh installs the latest release (main while there is none) from
# HERMY_REPO_URL into HERMY_HOME and links hermy
# into HERMY_BIN, run as curl pipes it (the script on stdin), with no network.
src="$tmp/src" gh="$tmp/gethome"; cs="$gh/.hermy"
git init -q "$src"; git -C "$src" checkout -q -b main
mkdir -p "$src/bin" "$src/.claude-plugin" "$gh" "$tmp/root"
cp "$here/bin/hermy" "$src/bin/"; cp "$here/.claude-plugin/plugin.json" "$src/.claude-plugin/"; echo x > "$src/README.md"
git -C "$src" add -A; git -C "$src" commit -q -m init; git clone -q --bare "$src" "$tmp/hermy.git"
upstream() { echo "$1" > "$src/$2"; git -C "$src" add -A; git -C "$src" commit -q -m "$1"; git -C "$src" push -q "$tmp/hermy.git" main; }
get() { HOME="$gh" HERMY_HOME="$cs" HERMY_BIN="${gbin-$gh/bin}" HERMY_REPO_URL="${url-$tmp/hermy.git}" HERMY_REF="${gref-}" PATH="${gpath-$PATH}" bash -s < "$here/get.sh"; }
sha() { git -C "$cs" rev-parse --short HEAD; }
printf '#!/bin/sh\necho 0\n' > "$tmp/root/id"; chmod +x "$tmp/root/id"
gpath="$tmp/root:$PATH" t 1 "get.sh: refuses root" get
t 1 "get.sh: and touches nothing" test -e "$cs"
mkdir "$gh/bin"; echo mine > "$gh/bin/hermy"
t 1 "get.sh: a hermy in HERMY_BIN that is not its link is refused" get
t 0 "get.sh: before any clone" sh -c "! test -e '$cs' && grep -qx mine '$gh/bin/hermy'"
rm "$gh/bin/hermy"
t 0 "get.sh: a first run with no release tag clones main" says "^cloned: $cs at main ($(git -C "$src" rev-parse --short HEAD))\$" get
t 0 "get.sh: on main" test "$(git -C "$cs" branch --show-current)" = main
t 0 "get.sh: links hermy into HERMY_BIN" test "$gh/bin/hermy" -ef "$cs/bin/hermy"
t 0 "get.sh: prints the commit" says "at main ($(sha))\$" get
t 0 "get.sh: and the next step per agent" says 'claude plugin install hermy@hermy' get
t 0 "get.sh: for other agents too" says "$cs/skills/onboard/SKILL.md" get
t 0 "get.sh: a rerun is up to date" says "^up to date: $cs at main ($(sha))\$" get
t 0 "get.sh: HERMY_BIN off PATH prints the line to add" says "export PATH=\"$gh/bin:" get
gpath="$gh/bin:$PATH" t 1 "get.sh: and on PATH does not" says 'export PATH=' get
gbin="$gh/bin/" gpath="$gh/bin:$PATH" t 1 "get.sh: nor with a trailing / on HERMY_BIN" says 'export PATH=' get
gpath="$gh/bin/:$PATH" t 1 "get.sh: nor on the PATH entry" says 'export PATH=' get
t 0 "get.sh: and edits no rc file" sh -c "! ls -A '$gh' | grep -q '^\.[a-z]*rc\$\|profile'"
upstream two README.md
t 0 "get.sh: a new remote commit fast-forwards" says "^updated: $cs at main ($(git -C "$src" rev-parse --short HEAD))\$" get
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
url="$tmp/hermy.git/" t 0 "get.sh: an origin spelled with a trailing / is accepted" get
upstream four README.md
url="$tmp/hermy" t 0 "get.sh: and one without .git" get
upstream five README.md; echo scratch > "$cs/scratch.txt"
t 0 "get.sh: an untracked file does not block" says '^updated: ' get
upstream six new.txt; echo mine > "$cs/new.txt"; was=$(sha)
t 1 "get.sh: an untracked file in the merge's way stops it" get
t 0 "get.sh: showing git's message" says 'untracked' get
t 0 "get.sh: saying the checkout is unchanged" says 'the checkout and HEAD are unchanged' get
t 0 "get.sh: and left as it was" sh -c "grep -qx mine '$cs/new.txt' && test \"\$(git -C '$cs' rev-parse --short HEAD)\" = $was"
rm "$cs/new.txt"; get >/dev/null 2>&1
git init -q "$tmp/gd"; git -C "$tmp/gd" checkout -q -b main; git -C "$tmp/gd" commit -q --allow-empty -m gd; git -C "$tmp/gd" remote add origin "$tmp/hermy.git"
upstream seven README.md
GIT_DIR="$tmp/gd/.git" t 0 "get.sh: a GIT_DIR from the caller is dropped" says '^updated: ' get
t 0 "get.sh: and its repository left alone" test "$(git -C "$tmp/gd" rev-list --count HEAD)" = 1
# The latest release: the v* tag nearest origin/main's tip, checked out detached; HERMY_REF picks main or a tag.
short() { git -C "$src" rev-parse --short "$1"; }
upstream tagged README.md; git -C "$src" tag v1; git -C "$src" push -q "$tmp/hermy.git" v1
t 0 "get.sh: a rerun moves to the release tag" says "^updated: $cs at v1 ($(short v1))\$" get
t 1 "get.sh: detached" git -C "$cs" symbolic-ref -q HEAD
t 0 "get.sh: a rerun on it is up to date, its detached HEAD passing" says "^up to date: $cs at v1 ($(short v1))\$" get
git -C "$src" checkout -q -b side; echo side > "$src/README.md"; git -C "$src" commit -q -am side; git -C "$src" tag v9; git -C "$src" checkout -q main
git -C "$src" push -q "$tmp/hermy.git" v9
t 0 "get.sh: a v* tag main does not reach is skipped" says "^up to date: $cs at v1 (" get
upstream eight README.md; git -C "$src" tag v2; git -C "$src" push -q "$tmp/hermy.git" v2; upstream nine README.md
t 0 "get.sh: a newer release tag is followed" says "^updated: $cs at v2 ($(short v2))\$" get
echo edited >> "$cs/README.md"
t 1 "get.sh: detached, an edited tracked file is still refused" get
git -C "$cs" checkout -q -- README.md
gref=main t 0 "get.sh: HERMY_REF=main follows the tip" says "^updated: $cs at main ($(short main))\$" get
t 0 "get.sh: on branch main" test "$(git -C "$cs" branch --show-current)" = main
git -C "$src" tag v3; git -C "$src" push -q "$tmp/hermy.git" v3
t 0 "get.sh: a release tag on the commit it is at is fetched too" says "^up to date: $cs at v3 ($(short v3))\$" get
t 1 "get.sh: and checked out detached" git -C "$cs" symbolic-ref -q HEAD
gref=v1 t 0 "get.sh: HERMY_REF names a tag" says "^updated: $cs at v1 ($(short v1))\$" get
t 1 "get.sh: detached on it" git -C "$cs" symbolic-ref -q HEAD
# v9: a tag main never reached, as one pushed on an unreviewed commit is.
for r in -x nosuch HEAD "$(git -C "$src" rev-parse main)" 'v1~1' origin/main v9; do
  gref=$r t 1 "get.sh: HERMY_REF=$r is refused" get
  gref=$r t 0 "get.sh: by name" says "HERMY_REF=$r" get
  t 0 "get.sh: and the checkout left as it was" test "$(sha)" = "$(short v1)"
done
t 0 "get.sh: unset again, the latest release" says "^updated: $cs at v3 (" get
t 0 "get.sh: a first run lands on the latest release" says "^cloned: $tmp/h10 at v3 ($(short v3))\$" env HOME="$gh" HERMY_HOME="$tmp/h10" HERMY_BIN="$tmp/b10" HERMY_REPO_URL="$tmp/hermy.git" bash "$here/get.sh"
t 1 "get.sh: detached" git -C "$tmp/h10" symbolic-ref -q HEAD
upstream ten extra.txt; git -C "$src" tag v4; git -C "$src" push -q "$tmp/hermy.git" v4; echo mine > "$tmp/h10/extra.txt"
t 1 "get.sh: an untracked file in the way of the release stops it" env HOME="$gh" HERMY_HOME="$tmp/h10" HERMY_BIN="$tmp/b10" HERMY_REPO_URL="$tmp/hermy.git" bash "$here/get.sh"
t 0 "get.sh: and left as it was" sh -c "grep -qx mine '$tmp/h10/extra.txt' && test \"\$(git -C '$tmp/h10' rev-parse --short HEAD)\" = $(short v3)"
get >/dev/null 2>&1
upstream eleven README.md; was=$(sha); git -C "$src" tag -f v4 >/dev/null; git -C "$src" push -q -f "$tmp/hermy.git" v4
t 1 "get.sh: a release tag moved on the remote stops the run" get
t 0 "get.sh: showing git's reason" says ' v4 .*would clobber' get
t 0 "get.sh: and the way out" says "moved on the remote: delete the local one (git -C $cs tag -d -- 'v4')" get
t 0 "get.sh: and left as it was" sh -c "test \"\$(git -C '$cs' rev-parse --short HEAD)\" = $was && git -C '$cs' diff --quiet HEAD"
git -C "$cs" tag -d v4 >/dev/null
t 0 "get.sh: with the local tag deleted, the moved one is followed" says "^updated: $cs at v4 ($(short v4))\$" get
# A moved tag's name, which git lets hold shell syntax, is single-quoted in the delete to paste, and printed as printable ASCII alone.
m="x'\$(id);"$'\302\233'y; git -C "$src" tag "$m"; git -C "$src" push -q "$tmp/hermy.git" "refs/tags/$m"; get >/dev/null 2>&1
git -C "$src" tag -f "$m" v1 >/dev/null; git -C "$src" push -q -f "$tmp/hermy.git" "refs/tags/$m"
t 1 "get.sh: a moved tag named with shell syntax stops the run" get
get > "$tmp/gm.out" 2>&1
t 0 "get.sh: naming it single-quoted in the delete" grep -qF "(git -C $cs tag -d -- 'x'\\''\$(id);y')" "$tmp/gm.out"
LC_ALL=C t 1 "get.sh: and none of its bytes past ASCII" grep -q $'\302\233' "$tmp/gm.out"
git -C "$src" push -q "$tmp/hermy.git" ":refs/tags/$m"; git -C "$src" tag -d "$m" >/dev/null; git -C "$cs" tag -d "$m" >/dev/null
# A tag named origin/main, on a commit main does not hold, would shadow the remote branch.
git -C "$src" checkout -q side; echo bad > "$src/README.md"; git -C "$src" commit -q -am bad; git -C "$src" tag origin/main; git -C "$src" checkout -q main
git -C "$src" push -q "$tmp/hermy.git" refs/tags/origin/main
t 0 "get.sh: a tag named origin/main does not move the release" says "^up to date: $cs at v4 ($(short v4))\$" get
gref=main t 0 "get.sh: nor main's tip" says "^up to date: $cs at main ($(short main))\$" get
git -C "$src" push -q "$tmp/hermy.git" :refs/tags/origin/main; git -C "$src" tag -d origin/main >/dev/null; git -C "$cs" tag -d origin/main >/dev/null
# A commit inside a branch merged with a merge commit was never main's state: a release tag there is not followed.
git -C "$src" checkout -q -b pr; echo backdoor > "$src/README.md"; git -C "$src" commit -q -am pr1; git -C "$src" tag v5
echo eleven > "$src/README.md"; git -C "$src" commit -q -am pr2; git -C "$src" checkout -q main; git -C "$src" merge -q --no-ff -m merge pr
git -C "$src" push -q "$tmp/hermy.git" main v5
t 0 "get.sh: a release tag inside a merged branch is not followed" says "^up to date: $cs at v4 ($(short v4))\$" get
git -C "$src" tag v6; git -C "$src" push -q "$tmp/hermy.git" v6
t 0 "get.sh: one on the merge commit is" says "^updated: $cs at v6 ($(short v6))\$" get
gref=v5 t 1 "get.sh: HERMY_REF naming a tag inside a merged branch is refused" get
gref=v5 t 0 "get.sh: by name" says "HERMY_REF=v5 is not a tag main itself was at" get
t 0 "get.sh: and the checkout left as it was" test "$(sha)" = "$(short v6)"
# A tag object whose own name is not its ref's: describe prints that name, and rev-parse would find another tag by it.
git -C "$src" checkout -q side; git -C "$src" tag evil; git -C "$src" checkout -q main
git -C "$src" update-ref refs/tags/v7 "$(printf 'object %s\ntype commit\ntag evil\ntagger T <t@example.com> 0 +0000\n\nm\n' "$(git -C "$src" rev-parse main)" | git -C "$src" mktag)"
git -C "$src" push -q "$tmp/hermy.git" v7 evil; was=$(sha)
t 1 "get.sh: a release tag object named otherwise is refused" get
t 0 "get.sh: saying the checkout is unchanged" says 'release tag .*the checkout and HEAD are unchanged' get
t 0 "get.sh: naming the tag" says "^warning: tag .*'v7'" get
t 0 "get.sh: and left as it was" sh -c "test \"\$(git -C '$cs' rev-parse --short HEAD)\" = $was && git -C '$cs' diff --quiet HEAD"
git -C "$src" push -q "$tmp/hermy.git" :refs/tags/v7 :refs/tags/evil; git -C "$src" tag -d v7 evil >/dev/null; git -C "$cs" tag -d v7 evil >/dev/null
t 0 "get.sh: with both tags gone, the release is v6 again" says "^up to date: $cs at v6 ($(short v6))\$" get
git -C "$src" push -q "$tmp/hermy.git" :refs/tags/v6; git -C "$src" tag -d v6 >/dev/null
t 0 "get.sh: a release tag deleted on the remote moves the rerun to the one before" says "^updated: $cs at v4 ($(short v4))\$" get
t 1 "get.sh: and is deleted here too" git -C "$cs" rev-parse -q --verify refs/tags/v6
# A tag named main on the remote does not stand in for the branch: not in the fetch, nor in the branch check.
git -C "$src" push -q "$tmp/hermy.git" side:refs/tags/main; upstream twelve README.md; git -C "$src" tag v8; git -C "$src" push -q "$tmp/hermy.git" v8
t 0 "get.sh: with a tag named main, a detached rerun follows a new release" says "^updated: $cs at v8 ($(short v8))\$" get
upstream thirteen README.md
gref=main t 0 "get.sh: and HERMY_REF=main the branch's tip" says "^updated: $cs at main ($(short main))\$" get
upstream fourteen README.md
gref=main t 0 "get.sh: a rerun on branch main is not refused" says "^updated: $cs at main ($(short main))\$" get
git -C "$src" push -q "$tmp/hermy.git" :refs/tags/main; git -C "$cs" tag -d main >/dev/null
get >/dev/null 2>&1; git -C "$cs" branch -f main v9; was=$(sha)
gref=main t 1 "get.sh: detached, a local main with commits the remote's does not is refused" get
gref=main t 0 "get.sh: saying so" says 'local main in .* has commits that the remote.s main does not; the checkout and HEAD are unchanged' get
t 0 "get.sh: and left as it was" test "$(sha)" = "$was"
git -C "$cs" branch -D main >/dev/null
gref=main t 0 "get.sh: with that main dropped, it is made again" says "^updated: $cs at main ($(short main))\$" get
# A release tag's name reaches the terminal as printable ASCII alone.
c1=$(printf 'v8\302\233x'); upstream fifteen README.md; git -C "$src" tag "$c1"; git -C "$src" push -q "$tmp/hermy.git" "$c1"
t 0 "get.sh: a release tag named past ASCII is printed without those bytes" says "^updated: $cs at v8x ($(short main))\$" get
LC_ALL=C t 1 "get.sh: none of them" says $'\302\233' get
git -C "$src" push -q "$tmp/hermy.git" ":refs/tags/$c1"; git -C "$src" tag -d "$c1" >/dev/null; get >/dev/null 2>&1
t 1 "get.sh: a first run with a HERMY_REF naming nothing is refused" env HOME="$gh" HERMY_HOME="$tmp/h11" HERMY_BIN="$tmp/b11" HERMY_REPO_URL="$tmp/hermy.git" HERMY_REF=nosuch bash "$here/get.sh"
t 1 "get.sh: and links nothing" test -e "$tmp/b11"
mkdir -p "$tmp/gh12"; printf '[clone]\n\tdefaultRemoteName = upstream\n' > "$tmp/gh12/.gitconfig"
t 0 "get.sh: a first run keeps the remote origin under a clone.defaultRemoteName" says "^cloned: $tmp/h12 at v8 ($(short v8))\$" env HOME="$tmp/gh12" HERMY_HOME="$tmp/h12" HERMY_BIN="$tmp/b12" HERMY_REPO_URL="$tmp/hermy.git" bash "$here/get.sh"
touch "$tmp/binfile"
t 1 "get.sh: a HERMY_BIN that is a file is refused" env HOME="$gh" HERMY_HOME="$tmp/h2" HERMY_BIN="$tmp/binfile" HERMY_REPO_URL="$tmp/hermy.git" bash "$here/get.sh"
t 1 "get.sh: before any clone" test -e "$tmp/h2"
t 1 "get.sh: an unreachable repository is refused" env HOME="$gh" HERMY_HOME="$tmp/h5" HERMY_BIN="$tmp/b5/bin" HERMY_REPO_URL="$tmp/nowhere.git" bash "$here/get.sh"
t 1 "get.sh: and leaves no HERMY_BIN behind" test -e "$tmp/b5"
t 0 "get.sh: no HOME and no HERMY_HOME says so" says 'HOME: is not set' env -u HOME HERMY_BIN="$tmp/b7" HERMY_REPO_URL="$tmp/hermy.git" bash "$here/get.sh"
t 0 "get.sh: nor HERMY_BIN" says 'HOME: is not set' env -u HOME HERMY_HOME="$tmp/h7" HERMY_REPO_URL="$tmp/hermy.git" bash "$here/get.sh"
t 1 "get.sh: before any clone" test -e "$tmp/h7"
t 0 "get.sh: a relative HERMY_HOME links to where it cloned" sh -c "cd '$tmp' && HOME='$gh' HERMY_HOME=relh HERMY_BIN=relb HERMY_REPO_URL='$tmp/hermy.git' bash '$here/get.sh' >/dev/null && test relb/hermy -ef relh/bin/hermy"
t 0 "get.sh: a relative HERMY_REPO_URL matches on the rerun" sh -c "cd '$tmp' && for i in 1 2; do HOME='$gh' HERMY_HOME=relh3 HERMY_BIN=relb3 HERMY_REPO_URL=hermy.git bash '$here/get.sh' || exit 1; done | grep -q '^up to date: '"
# The origin in another spelling of the same repository passes the origin check and reaches the fetch, which ssh=false stops.
for o in 'git@GitHub.com:MNSami/Coddy.git' 'ssh://git@github.com/mnsami/coddy.git/'; do
  git -C "$cs" remote set-url origin "$o"
  url=https://github.com/mnsami/coddy GIT_SSH_COMMAND=false t 0 "get.sh: origin $o is the same repository" says 'could not fetch' get
done
url=https://github.com/mnsami/coddy GIT_SSH_COMMAND=false gbin="$tmp/b6/bin" get >/dev/null 2>&1
t 1 "get.sh: a failed fetch leaves no HERMY_BIN behind" test -e "$tmp/b6"
git -C "$cs" remote set-url origin "$tmp/hermy.git"
if [ "$(id -u)" != 0 ]; then # root writes anywhere
  mkdir -p "$tmp/ro"; chmod 555 "$tmp/ro"
  t 1 "get.sh: a HERMY_BIN it cannot write to is refused" env HOME="$gh" HERMY_HOME="$tmp/h8" HERMY_BIN="$tmp/ro" HERMY_REPO_URL="$tmp/hermy.git" bash "$here/get.sh"
  t 1 "get.sh: before any clone" test -e "$tmp/h8"
  chmod 555 "$gh/bin"
  t 0 "get.sh: one already holding the link needs no write" says '^up to date: ' get
  chmod 755 "$tmp/ro" "$gh/bin"
fi
t 0 "get.sh: a trailing / on HERMY_HOME is dropped" says "^cloned: $tmp/h9 at " env HOME="$gh" HERMY_HOME="$tmp/h9/" HERMY_BIN="$tmp/b9" HERMY_REPO_URL="$tmp/hermy.git" bash "$here/get.sh"
t 0 "get.sh: from the link too" test "$(readlink "$tmp/b9/hermy")" = "$tmp/h9/bin/hermy"
t 0 "doctor: from stdin says why it cannot" says 'not stdin' sh -c "bash -s doctor < '$here/bin/hermy'"
# doctor names the install it runs from: get.sh's through the PATH link, another from a checkout.
# HERMY_ROOT names no project here ($tmp is no repository), so only the install prints.
doc() { HOME="$gh" HERMY_HOME="$cs" HERMY_ROOT="$tmp" "$@" doctor; }
t 0 "doctor: through the link, the real install dir" says "^install: $(cd "$cs" && pwd -P)\$" doc "$gh/bin/hermy"
t 0 "doctor: via get.sh" says '^via: get.sh$' doc "$gh/bin/hermy"
t 0 "doctor: the installed commit" says "^commit: $(sha)\$" doc "$gh/bin/hermy"
t 0 "doctor: the version" says "^version: $(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$here/.claude-plugin/plugin.json")\$" doc "$gh/bin/hermy"
t 0 "doctor: from this checkout, via other" says '^via: other$' doc "$here/bin/hermy"
t 0 "doctor: naming this checkout" says "^install: $(cd "$here" && pwd -P)\$" doc "$here/bin/hermy"
t 0 "doctor: with no HOME" says '^via: other$' env -u HOME -u HERMY_HOME HERMY_ROOT="$tmp" "$here/bin/hermy" doctor
t 1 "doctor: and no unbound variable" says 'unbound' env -u HOME -u HERMY_HOME HERMY_ROOT="$tmp" "$here/bin/hermy" doctor
t 0 "doctor: a CDPATH does not move it" sh -c "cd '$here' && CDPATH='$gh' HOME='$gh' HERMY_ROOT='$tmp' bash bin/hermy doctor | grep -qx 'install: $(cd "$here" && pwd -P)'"
mkdir -p "$tmp/dl/real/bin" "$tmp/dl/x"; cp "$here/bin/hermy" "$tmp/dl/real/bin/"; ln -s ../real/bin "$tmp/dl/x/bin"
t 0 "doctor: through a linked bin/, the real install dir" says "^install: $(cd "$tmp/dl/real" && pwd -P)\$" env HERMY_ROOT="$tmp" "$tmp/dl/x/bin/hermy" doctor
t 0 "doctor: outside a project, the five install lines alone" test "$(HERMY_ROOT="$tmp" "$here/bin/hermy" doctor | wc -l)" -eq 5
# The bash the hooks run: the first on PATH, its directory spelled
# physically, past every entry that is empty, relative or in the project.
pbash() { local d; d=$(command -v bash) && d=$(cd -P "${d%/*}" && pwd -P) && echo "$d/bash"; }
ptmp=$(cd -P "$tmp" && pwd -P); mkdir "$tmp/np"
t 0 "doctor: the bash on PATH" says "^bash: $(pbash) [0-9]*\.[0-9]*\.[0-9]*\$" env HERMY_ROOT="$tmp" "$here/bin/hermy" doctor
mkdir "$repo/nm"; printf '#!/bin/sh\necho 9.9.9\n' > "$repo/nm/bash"; chmod +x "$repo/nm/bash"
for w in "an entry in the project:$repo:$repo/nm" "one in the root, from a subdirectory:$repo/sub:$repo/nm" "a relative entry:$repo:nm" "an empty entry:$repo/nm:"; do
  IFS=: read -r a r e <<<"$w"
  t 0 "doctor: the bash the hooks run, past $a" says "^bash: $(pbash) [0-9]*\.[0-9]*\.[0-9]*\$" sh -c 'cd "$1" && PATH="$2:$PATH" HERMY_ROOT="$1" "$3" "$4" doctor' - "$r" "$e" "$BASH" "$here/bin/hermy"
done
mkdir -p "$repo/sub/.git/objects" "$repo/sub/.git/refs"; echo junk > "$repo/sub/.git/HEAD"
t 0 "doctor: the bash the hooks run, past one in the root, from a subdirectory whose .git is no repository" says "^bash: $(pbash) [0-9]*\.[0-9]*\.[0-9]*\$" sh -c 'cd "$1" && PATH="$2:$PATH" HERMY_ROOT="$1" "$3" "$4" doctor' - "$repo/sub" "$repo/nm" "$BASH" "$here/bin/hermy"
rm -r "$repo/sub/.git" "$repo/nm"
mkdir "$tmp/nobash"; for x in sed head uname tr git readlink; do p=$(command -v "$x") && ln -s "$p" "$tmp/nobash/$x"; done
t 0 "doctor: no bash on PATH" says '^bash: missing$' env PATH="$tmp/nobash" HERMY_ROOT="$tmp" "$BASH" "$here/bin/hermy" doctor
t 0 "doctor: and exits 0 for it" env PATH="$tmp/nobash" HERMY_ROOT="$tmp" "$BASH" "$here/bin/hermy" doctor
mkdir "$tmp/c"$'\n'"b"; ln -s "$BASH" "$tmp/c"$'\n'"b/bash"
t 0 "doctor: a bash whose path holds a line break, on one line" says "^bash: $ptmp/cb/bash [0-9]*\.[0-9]*\.[0-9]*\$" env PATH="$tmp/c"$'\n'"b:$PATH" HERMY_ROOT="$tmp/np" "$BASH" "$here/bin/hermy" doctor
t 0 "doctor: a function named bash is not the bash on PATH" says "^bash: $(pbash) [0-9]*\.[0-9]*\.[0-9]*\$" env 'BASH_FUNC_bash%%=() { echo 9.9.9; }' HERMY_ROOT="$tmp" "$BASH" "$here/bin/hermy" doctor
mkdir "$tmp/fakebash"; printf '#!/bin/sh\necho ..\n' > "$tmp/fakebash/bash"; chmod +x "$tmp/fakebash/bash"
t 0 "doctor: a bash that prints no version reads unknown" says "^bash: $ptmp/fakebash/bash unknown\$" env PATH="$tmp/fakebash:$PATH" HERMY_ROOT="$tmp/np" "$BASH" "$here/bin/hermy" doctor

# doctor in a project: a line per check, ok or the problem with its fix; exit 1 on any; writes nothing.
dp="$tmp/dp"; git init -q --bare "$tmp/dorigin.git"; git clone -q "$tmp/dorigin.git" "$dp" 2>/dev/null
(cd "$dp" && git checkout -q -b main && echo hi > README.md && git add -A && git commit -q -m init && git push -q -u origin main)
dd() { HERMY_ROOT="$dp" "$here/bin/hermy" "$@"; }
dsaysat() { HERMY_ROOT="$1" "$here/bin/hermy" doctor 2>&1 | grep -q "$2"; }
dsays() { dd doctor 2>&1 | grep -q "$1"; }
t 0 "doctor: not onboarded" dsays '^config: none (fix: /hermy:onboard)$'
t 1 "doctor: not onboarded exits 1" dd doctor
printf 'version: 2\ntracker: github\nworktree: git\ndefault_branch: main\nverify: true\n' > "$dp/.hermy.yml"
dd start 1 feat/1-x >/dev/null 2>&1
mkdir -p "$dp/.github/workflows"; cp "$here/templates/hermy.yml" "$dp/.github/workflows/hermy.yml"
awk '/^   <!-- hermy:begin -->$/,/^   <!-- hermy:end -->$/' "$here/skills/onboard/SKILL.md" | sed 's/^   //' > "$dp/AGENTS.md"
t 0 "doctor: onboarded, started, PR check and AGENTS.md in place: all ok" dd doctor
PATH="$tmp/mingw:$PATH" t 1 "doctor: all ok under MINGW still exits 1" dd doctor
t 1 "doctor: and no check line that is not ok" sh -c "HERMY_ROOT='$dp' '$here/bin/hermy' doctor | grep -E '^(config|worktree|default_branch|jq|git|jj|hooks|worktrees|pr_check|agents_md): ' | grep -v ': ok'"
before=$( (cd "$dp" && cat .git/config; git for-each-ref; find . -path ./.git -prune -o -path ./.worktrees -prune -o -type f -print | sort | xargs cksum) )
dd doctor >/dev/null 2>&1
t 0 "doctor: changes nothing" test "$before" = "$( (cd "$dp" && cat .git/config; git for-each-ref; find . -path ./.git -prune -o -path ./.worktrees -prune -o -type f -print | sort | xargs cksum) )"
# prob <name> <line pattern> <break> <repair>: the break gives that line and exit 1, the repair restores all ok
prob() { (cd "$dp" && eval "$3") >/dev/null 2>&1; t 0 "doctor: $1" dsays "$2"; t 1 "doctor: $1 exits 1" dd doctor; (cd "$dp" && eval "$4") >/dev/null 2>&1; t 0 "doctor: $1, repaired" dd doctor; }
cp "$dp/.hermy.yml" "$tmp/dp.yml"
prob "config behind" '^config: .*(fix: /hermy:migrate)' 'sed -i.bak "/^version:/d" .hermy.yml; rm .hermy.yml.bak' 'cp "$tmp/dp.yml" .hermy.yml'
prob "unknown worktree" "^worktree: unknown value 'svn'" 'sed -i.bak "s/^worktree:.*/worktree: svn/" .hermy.yml; rm .hermy.yml.bak' 'cp "$tmp/dp.yml" .hermy.yml'
prob "default_branch missing" '^default_branch: origin/main is missing' 'git update-ref -d refs/remotes/origin/main' 'git fetch -q origin'
mkdir "$tmp/nojqd"; for x in bash sh sed awk cat grep git cmp ps head wc cut tr; do p=$(command -v "$x") && ln -s "$p" "$tmp/nojqd/$x"; done
t 0 "doctor: jq missing" says '^jq: missing (fix: install jq)' env PATH="$tmp/nojqd" HERMY_ROOT="$dp" "$BASH" "$here/bin/hermy" doctor
sed -i.bak 's/^worktree:.*/worktree: jj/' "$dp/.hermy.yml"; rm "$dp/.hermy.yml.bak"
ln -s "$(command -v jq)" "$tmp/nojqd/jq"
t 0 "doctor: jj missing under worktree: jj" says '^jj: missing (fix: install jj' env PATH="$tmp/nojqd" HERMY_ROOT="$dp" "$BASH" "$here/bin/hermy" doctor
cp "$tmp/dp.yml" "$dp/.hermy.yml"
prob "core.hooksPath elsewhere" '^hooks: core.hooksPath is /elsewhere' 'git config core.hooksPath /elsewhere' 'git config core.hooksPath "$PWD/.git/hooks/hermy"'
prob "more entries under .git/worktrees than the shell hooks check in time" '^worktrees: .git/worktrees holds more than 10000 entries' 'cd .git/worktrees && seq -f "zz%g" 10000 | xargs mkdir' 'cd .git/worktrees && seq -f "zz%g" 10000 | xargs rmdir'
prob "a hook without hermy's header" '^hooks: pre-push is missing or not one hermy start wrote' 'cp .git/hooks/hermy/pre-push "$tmp/pp"; echo "#!/bin/sh" > .git/hooks/hermy/pre-push' 'cp "$tmp/pp" .git/hooks/hermy/pre-push'
# written quoted as start writes it, and run with a hermy on PATH, which the hooks never run
(cd "$dp" && cp .git/hooks/hermy/pre-commit "$tmp/pc" && sed -i.bak "s#^c=.*#c='/nonexistent/hermy'#" .git/hooks/hermy/pre-commit && rm .git/hooks/hermy/pre-commit.bak)
t 0 "doctor: the recorded hermy path gone, whatever is on PATH" sh -c "PATH='$tmp/onpath:/usr/bin:/bin' HERMY_ROOT='$dp' '$here/bin/hermy' doctor | grep -qx 'hooks: pre-commit runs /nonexistent/hermy, which is gone (fix: /hermy:start <issue>)'"
t 1 "doctor: the recorded hermy path gone exits 1" env PATH="$tmp/onpath:/usr/bin:/bin" HERMY_ROOT="$dp" "$here/bin/hermy" doctor
(cd "$dp" && cp "$tmp/pc" .git/hooks/hermy/pre-commit)
# A sandboxed start cannot rewrite what git runs outside the sandbox: a hook
# recording a hermy in the project (claude --plugin-dir . did) is put right from
# the user's own terminal.
term="(fix: one run of hermy's start from your own terminal, with a hermy installed outside the project)\$"
inhook() { cp .git/hooks/hermy/pre-commit "$tmp/pc"; mkdir bin; cp "$here/bin/hermy" bin/; sed -i.bak "s#^c=.*#c='$PWD/bin/hermy'#" .git/hooks/hermy/pre-commit; rm .git/hooks/hermy/pre-commit.bak; }
prob "a hook running a hermy in the project" "^hooks: pre-commit runs .*/bin/hermy, which lies in the project or a worktree of it, or is reached through a link there $term" inhook 'cp "$tmp/pc" .git/hooks/hermy/pre-commit; rm -r bin'
PATH="$tmp/nowtl:$PATH" t 0 "doctor: git worktree list failing" dsays '^hooks: git worktree list failed, so whether pre-commit runs a file in a worktree of the project cannot be told (fix: '
PATH="$tmp/nowtl:$PATH" t 1 "doctor: git worktree list failing exits 1" dd doctor
PATH="$tmp/jjwl:$PATH" prob "jj workspace list failing under worktree: jj" '^hooks: jj workspace list failed, so whether pre-commit runs a file in a worktree of the project cannot be told (fix: repair what makes jj workspace list fail here)$' 'sed -i.bak "s/^worktree:.*/worktree: jj/" .hermy.yml; rm .hermy.yml.bak; mkdir -p .jj/repo' 'cp "$tmp/dp.yml" .hermy.yml; rm -r .jj'
rm -r "$tmp/jjwl"
prob "a hook git would skip" '^hooks: pre-push is not executable' 'chmod -x .git/hooks/hermy/pre-push' 'chmod +x .git/hooks/hermy/pre-push'
prob "hooks not installed" '^hooks: core.hooksPath is not set.*(fix: /hermy:start <issue>)' 'git config --unset core.hooksPath' 'git config core.hooksPath "$PWD/.git/hooks/hermy"'
prob "PR check missing" '^pr_check: .*is missing or not a plain file (fix: copy ' 'rm .github/workflows/hermy.yml' 'cp "$here/templates/hermy.yml" .github/workflows/hermy.yml'
prob "PR check different" '^pr_check: .*differs from ' 'echo x >> .github/workflows/hermy.yml' 'cp "$here/templates/hermy.yml" .github/workflows/hermy.yml'
# The workflow from before the rename stands while hermy's is absent, when it is
# that template byte for byte: this one with the old name back (old, built so
# no line here holds it), as long as this template is unchanged since.
old=$(printf 'c%sddy' o)
(cd "$dp" && mv .github/workflows/hermy.yml "$tmp/hwf" && sed "s/hermy/$old/g" "$here/templates/hermy.yml" > ".github/workflows/$old.yml")
t 0 "doctor: the PR check from before the rename, as its template was, stands" dsays "^pr_check: ok (.github/workflows/$old.yml, from before the rename)\$"
t 0 "doctor: and all ok" dd doctor
(cd "$dp" && echo x >> ".github/workflows/$old.yml")
t 0 "doctor: one that differs does not" dsays '^pr_check: .github/workflows/hermy.yml is missing or not a plain file'
(cd "$dp" && sed "s/hermy/$old/g" "$here/templates/hermy.yml" > ".github/workflows/$old.yml" && cp "$tmp/hwf" .github/workflows/hermy.yml && echo x >> .github/workflows/hermy.yml)
t 0 "doctor: nor once hermy's is there" dsays '^pr_check: .*differs from '
(cd "$dp" && rm ".github/workflows/$old.yml" && mv "$tmp/hwf" .github/workflows/hermy.yml)
# The blob id held is SHA-1's, whatever object format the project's repository uses.
if git init -q --object-format=sha256 "$tmp/d256" 2>/dev/null; then
  mkdir -p "$tmp/d256/.github/workflows"; printf 'tracker: github\nworktree: git\ndefault_branch: main\n' > "$tmp/d256/.hermy.yml"
  sed "s/hermy/$old/g" "$here/templates/hermy.yml" > "$tmp/d256/.github/workflows/$old.yml"
  t 0 "doctor: the PR check from before the rename stands in a SHA-256 repository" sh -c "HERMY_ROOT='$tmp/d256' '$here/bin/hermy' doctor | grep -q '^pr_check: ok (.github/workflows/$old.yml, from before the rename)\$'"
  rm -rf "$tmp/d256"
fi
# tracker: gitlab holds the job file to the template, as github its workflow, and .gitlab-ci.yml to including it.
glt="$here/templates/hermy.gitlab-ci.yml"; gli='include:\n  - local: .gitlab/hermy.yml\n'
(cd "$dp" && sed -i.bak 's/^tracker:.*/tracker: gitlab/' .hermy.yml && rm .hermy.yml.bak && mkdir .gitlab && cp "$glt" .gitlab/hermy.yml && printf "$gli" > .gitlab-ci.yml)
t 0 "doctor: gitlab: the job file and its include in place: all ok" dsays '^pr_check: ok$'
t 0 "doctor: gitlab: exits 0" dd doctor
t 1 "doctor: gitlab: and the GitHub workflow is not asked for" sh -c "mv '$dp/.github' '$tmp/dgh'; HERMY_ROOT='$dp' '$here/bin/hermy' doctor | grep -q '^pr_check: .*github'; r=\$?; mv '$tmp/dgh' '$dp/.github'; exit \$r"
prob "gitlab: the job file missing" '^pr_check: .gitlab/hermy.yml is missing or not a plain file (fix: copy ' 'rm .gitlab/hermy.yml' 'cp "$glt" .gitlab/hermy.yml'
prob "gitlab: the job file different" '^pr_check: .gitlab/hermy.yml differs from ' 'echo x >> .gitlab/hermy.yml' 'cp "$glt" .gitlab/hermy.yml'
prob "gitlab: a link at the job file" '^pr_check: .gitlab/hermy.yml is missing or not a plain file' 'rm .gitlab/hermy.yml; ln -s "$glt" .gitlab/hermy.yml' 'rm .gitlab/hermy.yml; cp "$glt" .gitlab/hermy.yml'
prob "gitlab: a link at .gitlab" '^pr_check: .gitlab/hermy.yml is missing or not a plain file' 'mv .gitlab "$tmp/dgl"; ln -s "$tmp/dgl" .gitlab' 'rm .gitlab; mv "$tmp/dgl" .gitlab'
prob "gitlab: .gitlab-ci.yml missing" '^pr_check: .gitlab-ci.yml is missing or not a plain file' 'rm .gitlab-ci.yml' 'printf "$gli" > .gitlab-ci.yml'
prob "gitlab: a link at .gitlab-ci.yml" '^pr_check: .gitlab-ci.yml is missing or not a plain file' 'rm .gitlab-ci.yml; printf "$gli" > "$tmp/dci"; ln -s "$tmp/dci" .gitlab-ci.yml' 'rm .gitlab-ci.yml; printf "$gli" > .gitlab-ci.yml'
prob "gitlab: a directory at .gitlab-ci.yml" '^pr_check: .gitlab-ci.yml is missing or not a plain file' 'rm .gitlab-ci.yml; mkdir .gitlab-ci.yml' 'rmdir .gitlab-ci.yml; printf "$gli" > .gitlab-ci.yml'
prob "gitlab: .gitlab-ci.yml not including it" '^pr_check: .gitlab-ci.yml does not include .gitlab/hermy.yml (fix: ' 'printf "stages: [test]\n" > .gitlab-ci.yml' 'printf "$gli" > .gitlab-ci.yml'
prob "gitlab: the include commented out" '^pr_check: .gitlab-ci.yml does not include' 'printf "include:\n  # - local: .gitlab/hermy.yml\n  - local: other.yml\n" > .gitlab-ci.yml' 'printf "$gli" > .gitlab-ci.yml'
prob "gitlab: the path outside the include" '^pr_check: .gitlab-ci.yml does not include' 'printf "include:\n  - local: other.yml\nvariables:\n  X: .gitlab/hermy.yml\n" > .gitlab-ci.yml' 'printf "$gli" > .gitlab-ci.yml'
prob "gitlab: a longer name in the include" '^pr_check: .gitlab-ci.yml does not include' 'printf "include:\n  - local: .gitlab/hermy.yml.bak\n" > .gitlab-ci.yml' 'printf "$gli" > .gitlab-ci.yml'
prob "gitlab: .gitlab-ci.yml over 1 MiB, not read" '^pr_check: .gitlab-ci.yml is over 1 MiB, not read' 'head -c 1048577 /dev/zero | tr "\0" "\n" >> .gitlab-ci.yml' 'printf "$gli" > .gitlab-ci.yml'
for form in 'include: .gitlab/hermy.yml' "include: '/.gitlab/hermy.yml'" 'include:\n- local: .gitlab/hermy.yml' 'include:\n  - "/.gitlab/hermy.yml"' 'stages: [test]\n\ninclude:\n  - local: a.yml\n\n  # ours\n  - local: .gitlab/hermy.yml  # the check\nb: c' 'include: [{local: .gitlab/hermy.yml}]' 'include: [.gitlab/hermy.yml, a.yml]' 'include:\r\n  - local: .gitlab/hermy.yml\r'; do
  printf "$form\n" > "$dp/.gitlab-ci.yml"
  t 0 "doctor: gitlab: an include written as: $form" dsays '^pr_check: ok$'
done
(cd "$dp" && cp "$tmp/dp.yml" .hermy.yml && rm -r .gitlab .gitlab-ci.yml)
prob "AGENTS.md missing" '^agents_md: AGENTS.md is missing' 'mv AGENTS.md "$tmp/am"' 'mv "$tmp/am" AGENTS.md'
prob "AGENTS.md without the block" '^agents_md: AGENTS.md needs exactly one' 'cp AGENTS.md "$tmp/am"; echo "# x" > AGENTS.md' 'cp "$tmp/am" AGENTS.md'
prob "AGENTS.md with a lone marker" '^agents_md: AGENTS.md needs exactly one' 'cp AGENTS.md "$tmp/am"; sed -i.bak "/hermy:end/d" AGENTS.md; rm AGENTS.md.bak' 'cp "$tmp/am" AGENTS.md'
prob "AGENTS.md with reversed markers" '^agents_md: AGENTS.md needs exactly one' 'cp AGENTS.md "$tmp/am"; sed -i.bak "s/hermy:begin/hermy:X/;s/hermy:end/hermy:begin/;s/hermy:X/hermy:end/" AGENTS.md; rm AGENTS.md.bak' 'cp "$tmp/am" AGENTS.md'
# The block from before the rename stands, its markers both of that spelling.
(cd "$dp" && cp AGENTS.md "$tmp/am" && sed -i.bak "s/hermy:begin/$old:begin/;s/hermy:end/$old:end/" AGENTS.md && rm AGENTS.md.bak)
t 0 "doctor: AGENTS.md with the block from before the rename" dsays '^agents_md: ok$'
(cd "$dp" && sed -i.bak "s/$old:end/hermy:end/" AGENTS.md && rm AGENTS.md.bak)
t 0 "doctor: but not markers that mix both spellings" dsays '^agents_md: AGENTS.md needs exactly one'
# onboard replaces the old block only with no hermy marker in the file, so a stray one is a problem.
(cd "$dp" && sed -i.bak "s/hermy:begin/$old:begin/;s/hermy:end/$old:end/" AGENTS.md && rm AGENTS.md.bak && echo '<!-- hermy:begin -->' >> AGENTS.md)
t 0 "doctor: nor the old block beside a lone hermy marker" dsays '^agents_md: AGENTS.md needs exactly one'
(cd "$dp" && cp "$tmp/am" AGENTS.md)
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
jr="$tmp/jjroot"; mkdir -p "$jr/.github/workflows"; cp "$dp/AGENTS.md" "$jr/"; cp "$here/templates/hermy.yml" "$jr/.github/workflows/"
printf 'version: 2\ntracker: github\nworktree: git\ndefault_branch: main\nverify: true\n' > "$jr/.hermy.yml"
t 0 "doctor: a git-less root, default_branch and hooks not applicable" dsaysat "$jr" '^hooks: ok (not applicable'
t 0 "doctor: a git-less root, default_branch" dsaysat "$jr" '^default_branch: ok (not applicable'
t 0 "doctor: a git-less root exits 0" env HERMY_ROOT="$jr" "$here/bin/hermy" doctor
# a recorded hermy path holding a quote is read back as start wrote it
qd="$tmp/q'd"; mkdir -p "$qd"; : > "$qd/hermy"; chmod +x "$qd/hermy"; qc="$tmp/q'\\''d/hermy"
qset() { QC="$qc" awk '/^c=/ { print "c=\047" ENVIRON["QC"] "\047"; next } 1' "$tmp/pc" > .git/hooks/hermy/pre-commit; chmod +x .git/hooks/hermy/pre-commit; }
(cd "$dp" && cp .git/hooks/hermy/pre-commit "$tmp/pc" && qset)
t 0 "doctor: a recorded path with a quote reads as ok" sh -c "PATH=/usr/bin:/bin HERMY_ROOT='$dp' '$here/bin/hermy' doctor | grep -qx 'hooks: ok'"
rm "$qd/hermy"
t 0 "doctor: and gone, when it is" sh -c "PATH=/usr/bin:/bin HERMY_ROOT='$dp' '$here/bin/hermy' doctor | grep -q '^hooks: pre-commit runs .*q.d/hermy, which is gone'"
(cd "$dp" && cp "$tmp/pc" .git/hooks/hermy/pre-commit)
prob "a commondir in the git dir" '^git_dir: ' 'echo . > .git/commondir' 'rm .git/commondir'
# a root reached from a .worktrees/<id> whose .git is garbage (git fails there): the root's own git dir is still held to the commondir test, running no planted program
cp -R "$dp/.git" "$tmp/devil"; printf '#!/bin/sh\n: > "%s"\n' "$tmp/dfsm" > "$tmp/dfsm.sh"; chmod +x "$tmp/dfsm.sh"; git --git-dir="$tmp/devil" config core.fsmonitor "$tmp/dfsm.sh"
mkdir -p "$dp/.worktrees/9"; echo garbage > "$dp/.worktrees/9/.git"; echo "$tmp/devil" > "$dp/.git/commondir"
rm -f "$tmp/dfsm"
t 0 "doctor: from a worktree with a garbage .git, a commondir in the root's git dir is git_dir" dsaysat "$dp/.worktrees/9" '^git_dir: '
t 1 "doctor: and exits 1" env HERMY_ROOT="$dp/.worktrees/9" "$here/bin/hermy" doctor
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
mkdir -p "$dp/lsub"; ln -s "$tmp/devil" "$dp/lsub/.git"; cp "$dp/.hermy.yml" "$dp/lsub/.hermy.yml"
t 0 "doctor: a .git that is a link is git_dir" dsaysat "$dp/lsub" '^git_dir: '
t 1 "doctor: and exits 1" env HERMY_ROOT="$dp/lsub" "$here/bin/hermy" doctor
t 1 "doctor: and git ran none of its programs" test -e "$tmp/dfsm"
rm -rf "$dp/lsub" "$tmp/devil"
# a session started inside a bare repository nested two levels into the project: git's root, its parent, has no .git, so it is git_dir and says so; one level down roots at the project
mkdir -p "$dp/bx/y"; git init -q --bare "$dp/bx/y/c.git"
for st in bx/y/c.git bx/y/c.git/refs; do
  t 0 "bare: from $st, doctor says the session started inside a bare repository" dsaysat "$dp/$st" '^git_dir: .*bare repository nested in the project'
  t 1 "bare: and exits 1" env HERMY_ROOT="$dp/$st" "$here/bin/hermy" doctor
  for v in config status detect; do t 0 "bare: and $v prints that line" sh -c "HERMY_ROOT='$dp/$st' '$here/bin/hermy' $v | grep -q '^git_dir: .*bare repository nested in the project'"; done
done
rm -rf "$dp/bx"; git init -q --bare "$dp/bc.git"
t 0 "bare: one level down, doctor is not git_dir" sh -c "! HERMY_ROOT='$dp/bc.git' '$here/bin/hermy' doctor 2>&1 | grep -q '^git_dir: '"
rm -rf "$dp/bc.git"
# a bare repository in no project: no git_dir, doctor prints the install lines alone and the other verbs are as on a plain directory; nested in a project, the line names the bare repository itself
mkdir -p "$tmp/sb"; git init -q --bare "$tmp/sb/foo.git"
for st in foo.git foo.git/refs; do
  t 0 "bare: standalone from $st, doctor exits 0" env HERMY_ROOT="$tmp/sb/$st" "$here/bin/hermy" doctor
  t 0 "bare: and prints no git_dir" sh -c "! HERMY_ROOT='$tmp/sb/$st' '$here/bin/hermy' doctor 2>&1 | grep -q '^git_dir: '"
  for v in config status detect; do t 0 "bare: and $v prints no git_dir" sh -c "! HERMY_ROOT='$tmp/sb/$st' '$here/bin/hermy' $v 2>&1 | grep -q '^git_dir: '"; done
done
# the same bare repository beside a config at its parent: the parent is the project, the exemption does not apply
mkdir -p "$tmp/sbc"; git init -q --bare "$tmp/sbc/foo.git"; printf 'version: 2\ntracker: github\nworktree: git\ndefault_branch: main\nverify: true\n' > "$tmp/sbc/.hermy.yml"
for st in foo.git foo.git/refs; do t 2 "bare: beside a config, from $st, guard is held" sh -c "echo '{\"paths\":[\"/x\"]}' | HERMY_ROOT='$tmp/sbc/$st' '$here/bin/hermy' guard"; done
mkdir -p "$dp/bx/y"; git init -q --bare "$dp/bx/y/c.git"
t 0 "bare: nested, the line names the bare repository, not a .git that does not exist" sh -c "HERMY_ROOT='$dp/bx/y/c.git' '$here/bin/hermy' status | grep -q \"^git_dir: $(cd "$dp" && pwd -P)/bx/y/c.git is a bare repository nested in the project\""
rm -rf "$dp/bx"
# a .git that is a huge sparse file, and a HEAD git rejects, stall and fool no hook
mkdir -p "$tmp/sp"; git init -q "$tmp/sp"; cp "$dp/.hermy.yml" "$tmp/sp/"; mv "$tmp/sp/.git" "$tmp/sp/x"; truncate -s 4G "$tmp/sp/.git"
t 2 "guard: a huge sparse .git at the root is refused within seconds" timeout 10 sh -c "printf '{\"session\":\"s\",\"paths\":[\"$tmp/sp/f\"]}' | HERMY_ROOT='$tmp/sp' '$here/bin/hermy' guard"
t 2 "snap: and so is a command" timeout 10 sh -c "printf '{\"session\":\"s\",\"cwd\":\"$tmp/sp\",\"command\":\"true\"}' | HERMY_ROOT='$tmp/sp' '$here/bin/hermy' snap"
rm -rf "$tmp/sp"
mkdir -p "$tmp/hA"; git init -q "$tmp/hA"; printf '#!/bin/sh\ntouch "%s/hMark"\n' "$tmp" > "$tmp/hfsm"; chmod +x "$tmp/hfsm"; git -C "$tmp/hA" config core.fsmonitor "$tmp/hfsm"
for hd in ' refs/heads/main' $'\trefs/heads/main' $'\nrefs/heads/main'; do
  P="$tmp/hA/proj"; rm -rf "$P"; mkdir -p "$P/.git/objects" "$P/.git/refs" "$P/src/deep"; cp "$dp/.hermy.yml" "$P/"
  ln -s "$hd" "$P/.git/HEAD"; echo garbage > "$P/src/.git"
  t 0 "snap: a symlink HEAD whose target starts with whitespace is no repository, so no git runs in the one above" sh -c "printf '{\"session\":\"s\",\"cwd\":\"$P/src/deep\",\"command\":\"true\"}' | HERMY_ROOT='$P/src/deep' '$here/bin/hermy' snap"
  t 1 "snap: and A's core.fsmonitor never ran" test -e "$tmp/hMark"
done
P="$tmp/hA/proj"; rm -rf "$P"; mkdir -p "$P/.git/objects" "$P/.git/refs" "$P/src/deep"; cp "$dp/.hermy.yml" "$P/"
printf 'ref:%300srefs/heads/main\n' ' ' > "$P/.git/HEAD"; echo garbage > "$P/src/.git"
t 0 "snap: ref: and over 250 whitespace characters before refs/ is no repository" sh -c "printf '{\"session\":\"s\",\"cwd\":\"$P/src/deep\",\"command\":\"true\"}' | HERMY_ROOT='$P/src/deep' '$here/bin/hermy' snap"
t 1 "snap: and A's core.fsmonitor never ran" test -e "$tmp/hMark"
rm -rf "$tmp/hA" "$tmp/sb"
# the same with no config in the subdirectory, and a commondir to nowhere
mkdir -p "$dp/lsub"; ln -s /nowhere "$dp/lsub/.git"
t 0 "doctor: a .git link in a subdirectory with no config is git_dir" dsaysat "$dp/lsub" '^git_dir: '
rm -rf "$dp/lsub"; mkdir -p "$dp/lsub/.git"; echo /nowhere > "$dp/lsub/.git/commondir"
t 0 "doctor: so is a commondir to nowhere" dsaysat "$dp/lsub" '^git_dir: '
t 0 "doctor: and says to remove the file, not to open the session elsewhere" sh -c "echo 'gitdir: /nowhere' > '$dp/lsub/.git/commondir'; HERMY_ROOT='$dp/lsub' '$here/bin/hermy' doctor 2>&1 | grep -q 'is not the main checkout.s own git dir'"
# a repository git rejects planted at .worktrees/.git (or in place of an issue worktree's .git) leaves the root the project: a main-checkout write is still refused
plant() { mkdir -p "$1/objects" "$1/refs"; echo 'ref: refs/heads/main' > "$1/HEAD"; printf '[core]\n\trepositoryformatversion = 9\n' > "$1/config"; }
gdir() { printf '{"session":"sess-a","paths":["%s"]}' "$dp/README.md" | HERMY_ROOT="$1" HERMY_PID=$$ "$here/bin/hermy" guard; }
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
mkdir -p "$tmp/gl" "$tmp/glgit"; git init -q "$tmp/gl"; cp "$tmp/dp.yml" "$tmp/gl/.hermy.yml"; mv "$tmp/gl/.git" "$tmp/glgit/g"; echo "gitdir: $tmp/glgit/g" > "$tmp/gl/.git"
t 0 "doctor: a .git that is a gitdir: file is git_dir, naming the file" dsaysat "$tmp/gl" "^git_dir: $tmp/gl/.git is a file naming a git dir elsewhere"
t 0 "doctor: and the fix is to open the session in the main checkout" dsaysat "$tmp/gl" 'fix: open the session in the main checkout, or remove the file by hand'
t 1 "doctor: and exits 1" env HERMY_ROOT="$tmp/gl" "$here/bin/hermy" doctor
for v in config status detect; do
  t 0 "$v: a .git that is a gitdir: file prints git_dir naming the file and the open-the-main-checkout fix" says "^git_dir: $tmp/gl/.git is a file naming a git dir elsewhere.*fix: open the session in the main checkout" env HERMY_ROOT="$tmp/gl" "$here/bin/hermy" $v
done
t 0 "verify: and a verb that refuses names the file and the main checkout" says "$tmp/gl/.git is a file naming.*open the session in the main checkout" env HERMY_ROOT="$tmp/gl" "$here/bin/hermy" verify 1
t 2 "githook: and a commit there is refused" env HERMY_ROOT="$tmp/gl" "$here/bin/hermy" githook pre-commit
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
    t 0 "$v: from a start whose git dir leads to another repository (${sd#"$tmp"/}) exits 0 and runs none of its programs" sh -c "HERMY_ROOT='$sd' '$here/bin/hermy' $v >'$tmp/sout' 2>&1; e=\$?; [ \$e = 0 ] && [ ! -e '$tmp/sMark' ] && ! grep -q 'root: $tmp/sE' '$tmp/sout'"
  done
  t 2 "verify: and a verb that mutates refuses (${sd#"$tmp"/})" env HERMY_ROOT="$sd" "$here/bin/hermy" verify 1
  t 2 "exclude: and so does exclude (${sd#"$tmp"/})" env HERMY_ROOT="$sd" "$here/bin/hermy" exclude config
  t 2 "drop: and so does drop (${sd#"$tmp"/})" env HERMY_ROOT="$sd" "$here/bin/hermy" drop 1
  t 2 "refresh: and so does refresh (${sd#"$tmp"/})" env HERMY_ROOT="$sd" "$here/bin/hermy" refresh 1
done
rm -rf "$tmp/sE" "$tmp/sa" "$tmp/sb" "$tmp/sfsm" "$tmp/sMark" "$tmp/sout"
# githook reads the root's .git/config and runs its hooks: from a bare repository nested in a project whose .git is a link to E's, it runs none of E's
mkdir -p "$tmp/hE/hooks" "$tmp/hp/src"; git init -q "$tmp/hE/r"; printf '#!/bin/sh\ntouch "%s/hMark"\n' "$tmp" > "$tmp/hE/r/.git/hooks/pre-commit"; chmod +x "$tmp/hE/r/.git/hooks/pre-commit"
cp "$tmp/dp.yml" "$tmp/hp/.hermy.yml"; ln -s "$tmp/hE/r/.git" "$tmp/hp/.git"; git init -q --bare "$tmp/hp/src/b"; git -C "$tmp/hp/src/b" config core.worktree "$tmp/hp/src"
t 2 "githook: a commit from a bare repository nested in a project whose .git is a link is refused" env HERMY_ROOT="$tmp/hp/src/b" "$here/bin/hermy" githook pre-commit
t 0 "githook: and runs none of the linked repository's hooks" test ! -e "$tmp/hMark"
rm -rf "$tmp/hE" "$tmp/hp" "$tmp/hMark"
# a session outside any project whose .git directory leads to an onboarded repository: the root is that repository, so the hooks refuse
mkdir -p "$tmp/d2/sub/.git" "$tmp/d2/.git/objects" "$tmp/d2/.git/refs"; echo 'ref: refs/heads/main' > "$tmp/d2/.git/HEAD"; echo "$dp/.git" > "$tmp/d2/.git/commondir"
t 2 "guard: a commondir to an onboarded repository above a rejected .git is refused" gdir "$tmp/d2/sub"
rm -rf "$tmp/d2"
# a session in an absorbed submodule of an onboarded project: doctor names the .git file, not a missing config
mkdir -p "$tmp/smsub" "$tmp/smsup"; git init -q "$tmp/smsub"; git -C "$tmp/smsub" -c user.name=t -c user.email=t@t commit -q --allow-empty -m i
git init -q "$tmp/smsup"; cp "$tmp/dp.yml" "$tmp/smsup/.hermy.yml"; git -C "$tmp/smsup" -c protocol.file.allow=always submodule add -q "$tmp/smsub" sm
t 0 "doctor: a session in an absorbed submodule is git_dir, naming its .git file" dsaysat "$tmp/smsup/sm" "^git_dir: $tmp/smsup/sm/.git is a file naming a git dir elsewhere"
t 1 "doctor: and exits 1" env HERMY_ROOT="$tmp/smsup/sm" "$here/bin/hermy" doctor
for v in config status detect; do
  t 0 "$v: a session in an absorbed submodule prints git_dir naming its .git file and the open-the-main-checkout fix" says "^git_dir: $tmp/smsup/sm/.git is a file naming a git dir elsewhere.*fix: open the session in the main checkout" env HERMY_ROOT="$tmp/smsup/sm" "$here/bin/hermy" $v
done
t 0 "verify: and a verb that refuses names the same file" says "$tmp/smsup/sm/.git is a file naming.*open the session in the main checkout" env HERMY_ROOT="$tmp/smsup/sm" "$here/bin/hermy" verify 1
rm -rf "$tmp/smsub" "$tmp/smsup"
# a relative root naming no directory ends
t 0 "root: a relative HERMY_ROOT naming no directory ends" timeout 10 env HERMY_ROOT=nosuchdir "$here/bin/hermy" status
t 0 "root: and one with a slash" timeout 10 env HERMY_ROOT=no/such "$here/bin/hermy" status
# proj in the environment makes nothing odd outside git
mkdir -p "$tmp/pj"
t 0 "doctor: outside any project, a proj in the environment changes nothing" env proj=1 HERMY_ROOT="$tmp/pj" "$here/bin/hermy" doctor
# a root outside git holding a config is a project: the config line, not silence
mkdir -p "$tmp/nogit"; cp "$tmp/dp.yml" "$tmp/nogit/.hermy.yml"
t 0 "doctor: a root outside git with a config is checked" dsaysat "$tmp/nogit" '^config: ok'
t 1 "doctor: and exits 1, git being absent" env HERMY_ROOT="$tmp/nogit" "$here/bin/hermy" doctor
sed -i.bak 's/^tracker:.*/tracker: jira/' "$dp/.hermy.yml"; rm "$dp/.hermy.yml.bak"; rm "$dp/.github/workflows/hermy.yml"
t 0 "doctor: the PR check is not checked under jira" dd doctor
cp "$tmp/dp.yml" "$dp/.hermy.yml"

# marks <tool> <stage> <commit> <case>...: mark, the fingerprint start takes
# around a read-only agent, moves with every change to issue 7's worktree or
# its records and with nothing else, in a repository of its own; <stage>,
# <commit> and each <case>, a name and its command after a colon, are that
# tool's, run in the worktree. Its digest is the first line, and mark given
# it exits 1 once it no longer holds, printing its lines.
marks() {
  local tool=$1 r="$tmp/mark-$1" a b c
  git clone -q "$tmp/origin.git" "$r" 2>/dev/null
  printf 'version: 2\ntracker: github\nworktree: %s\ndefault_branch: main\n' "$tool" > "$r/.hermy.yml"
  [ "$tool" = git ] || (cd "$r" && jj git init --colocate && echo '.jj/' >> .git/info/exclude) >/dev/null 2>&1
  m() { HERMY_ROOT="$r" run mark 7 "$@"; }
  # its own names: a function defined here is global, and same is the config cases'
  msame() { a=$(m) && b=$(m) && [ -n "$a" ] && [ "$a" = "$b" ]; }
  # moves <command> [line]: mark's output, or the line of that name, moves with the command
  moves() { a=$(set -o pipefail; m | grep "^${2-}") && (cd "$r/.worktrees/7" && eval "$1") >/dev/null 2>&1 && b=$(set -o pipefail; m | grep "^${2-}") && [ "$a" != "$b" ]; }
  # mholds <command>: mark given the digest taken before the command
  mholds() { local d; d=$(m | sed -n '1s/^digest: //p') && [ -n "$d" ] && (cd "$r/.worktrees/7" && eval "$1") >/dev/null 2>&1 && m "$d"; }
  HERMY_ROOT="$r" run start 7 feat/7-mark >/dev/null 2>&1; HERMY_ROOT="$r" run claim 7 >/dev/null 2>&1
  t 0 "mark: $tool: stays the same with nothing changed" msame
  t 0 "mark: $tool: moves on the state file's first write" moves "HERMY_ROOT='$r' '$here/bin/hermy' state 7 phase=think"
  t 0 "mark: $tool: moves on a tracked edit" moves 'echo y >> README.md'
  t 0 "mark: $tool: moves on a new untracked file" moves 'echo n > new.txt'
  t 0 "mark: $tool: moves on an untracked file in a new directory" moves 'mkdir d && echo n > d/f'
  t 0 "mark: $tool: moves on an untracked file's edit" moves 'echo m > new.txt'
  t 0 "mark: $tool: moves on an untracked file's mode" moves 'chmod +x new.txt'
  t 0 "mark: $tool: moves on a staged change" moves "$2"
  t 0 "mark: $tool: moves on a commit" moves "$3"
  t 0 "mark: $tool: moves on a state write" moves "HERMY_ROOT='$r' '$here/bin/hermy' state 7 phase=review"
  t 0 "mark: $tool: moves on a base record's write" moves "echo main > '$r/.git/hermy/7.base'"
  t 0 "mark: $tool: moves on a branch record's write" moves "echo feat/7-other > '$r/.git/hermy/7.branch'"
  shift 3; for c; do t 0 "mark: $tool: moves on ${c%%:*}" moves "${c#*:}"; done
  # git reads past a replace ref, so the edit one hides shows in the unstaged diff itself
  [ "$tool" = jj ] || t 0 "mark: git: an edit a replace ref hides moves the unstaged diff" moves 'echo r >> README.md && git replace "$(git rev-parse :README.md)" "$(git hash-object -w README.md)"' unstaged
  t 0 "mark: $tool: and stays the same after them" msame
  t 0 "mark: $tool: passes the digest it printed" mholds true
  t 1 "mark: $tool: fails one the worktree no longer holds" mholds 'echo w >> README.md'
  t 0 "mark: $tool: and prints its lines" says '^state ' mholds 'echo v >> README.md'
  t 1 "mark: $tool: refuses an empty digest" m ''
  t 1 "mark: $tool: and one that is not lower-case hex" m gggggggggggggggggggggggggggggggggggggggg
  # A FIFO git or jj opens as an ignore or attributes file would hang it.
  for p in .worktrees/7/.gitignore .git/info/attributes; do
    mkfifo "$r/$p"; t 1 "mark: $tool: refuses a FIFO at $p, promptly" timeout 10 env HERMY_ROOT="$r" "$here/bin/hermy" mark 7; rm -f "$r/$p"
  done
  t 1 "mark: $tool: refuses an issue with no worktree" env HERMY_ROOT="$r" "$here/bin/hermy" mark 8
}
# The pointer and commondir are rewritten to another spelling of the same
# path, so git still works and only mark's lines tell.
marks git 'git add new.txt' 'git commit -qam c' \
  'a branch switch at the same commit:git switch -qc feat/7-x' \
  'a detach at the same commit:git checkout -q --detach' \
  "a .git pointer rewrite:printf 'gitdir: %s/.\n' \"\$(sed -n 's/^gitdir: //p' .git)\" > \"\$tmp/p\" && cat \"\$tmp/p\" > .git" \
  "a commondir rewrite:echo ../../. > '$tmp/mark-git/.git/worktrees/7/commondir'" \
  'a tracked edit whose blob is rewritten in place:echo s >> new.txt && o=$(git rev-parse :new.txt) && n=$(git hash-object -w new.txt) && d=$tmp/mark-git/.git/objects && rm -f "$d/${o:0:2}/${o:2}" && cp "$d/${n:0:2}/${n:2}" "$d/${o:0:2}/${o:2}"' \
  'a move of the stacked base:git update-ref refs/heads/main HEAD' \
  'the removal of the base record:rm "$tmp/mark-git/.git/hermy/7.base"' \
  'a move of default_branch on the remote:git update-ref refs/remotes/origin/main HEAD'
# jj judges a tracked file by its size and mtime, so the same size with the mtime put back moves no @.
if command -v jj >/dev/null; then marks jj "jj file track 'root-file:\"new.txt\"'" 'JJ_USER=t JJ_EMAIL=t@t jj commit -m c' \
  'a same-size rewrite with its mtime put back:touch -r README.md "$tmp/ref" && tr y z < README.md > "$tmp/rw" && cat "$tmp/rw" > README.md && touch -r "$tmp/ref" README.md' \
  'a move of the stacked base:jj bookmark set main -r @-' \
  'the removal of the base record:rm "$tmp/mark-jj/.git/hermy/7.base"' \
  'a move of default_branch on the remote:git -C "$tmp/mark-jj" update-ref refs/remotes/origin/main "$(jj log --no-graph -r @- -T commit_id)"'; fi

# start, on a new worktree, copies in the ignored files .worktreeinclude
# names, then runs setup there with the issue and its port offset; a
# failing setup exits non-zero and keeps the worktree.
s="$tmp/setup"; git clone -q "$tmp/origin.git" "$s" 2>/dev/null
st() { HERMY_ROOT="$s" run start "$@"; }
sc() { printf 'version: 2\ntracker: github\nworktree: git\ndefault_branch: main\nsetup: %s\n' "$1" > "$s/.hermy.yml"; }
sc 'env > setup.out'; echo .env >> "$s/.git/info/exclude"; echo '*.env' > "$s/.worktreeinclude"; echo s > "$s/.env"; echo k > "$s/keep.env"
printf '%s\n' '-a b.env' l.env in/ m.env >> "$s/.git/info/exclude"; echo d > "$s/-a b.env"; echo m > "$s/m.env"; ln -s .env "$s/l.env"
# a branch whose in/ is a link out of the worktree, where the main checkout's holds an ignored file
o="$tmp/setup-out"; mkdir "$o"; git -C "$s" worktree add -q -b feat/140-link "$tmp/setup-lnk" origin/main && ln -s "$o" "$tmp/setup-lnk/in" && git -C "$tmp/setup-lnk" add in && git -C "$tmp/setup-lnk" commit -q -m link && git -C "$s" worktree remove "$tmp/setup-lnk"
mkdir -p "$s/in/sub"; echo z > "$s/in/sub/z.env"
st 137 feat/137-setup > "$tmp/setup.log" 2>&1; t 0 "setup: start makes the worktree and runs it" test $? = 0
t 0 "setup: prints the port offset, issue 137's last two digits times ten" grep -qx 'port_offset: 370' "$tmp/setup.log"
t 0 "setup: runs in the new worktree with the offset set" grep -qx 'HERMY_PORT_OFFSET=370' "$s/.worktrees/137/setup.out"
t 0 "setup: and the issue" grep -qx 'HERMY_ISSUE=137' "$s/.worktrees/137/setup.out"
t 0 "worktreeinclude: an ignored file it names is copied in" cmp -s "$s/.env" "$s/.worktrees/137/.env"
t 1 "worktreeinclude: one git does not ignore is not" test -e "$s/.worktrees/137/keep.env"
t 0 "worktreeinclude: a name with a leading dash and a blank is copied" cmp -s "$s/-a b.env" "$s/.worktrees/137/-a b.env"
t 1 "worktreeinclude: a link is not" test -e "$s/.worktrees/137/l.env"
st 140 feat/140-link >/dev/null 2>&1
t 1 "worktreeinclude: nothing is made through a link the branch holds" test -e "$o/sub"
t 0 "worktreeinclude: a file that sorts after it is still copied" cmp -s "$s/m.env" "$s/.worktrees/140/m.env"
sc 'exit 3'
t 1 "setup: a failing one makes start exit non-zero" st 138 feat/138-setup
t 0 "setup: and keeps the worktree" test -d "$s/.worktrees/138"
t 0 "setup: a rerun finds the worktree" says '^exists: ' st 138 feat/138-setup
sc '|'
t 1 "setup: a block scalar is refused" st 139 feat/139-setup
t 1 "setup: before any worktree is made" test -e "$s/.worktrees/139"
# a hook manager setup installs (husky's prepare, on npm ci) re-sets core.hooksPath: start puts hermy's back
sc 'git config core.hooksPath .husky/_'; st 141 feat/141-setup >/dev/null 2>&1
t 0 "setup: runs before the git hooks, which keep core.hooksPath" test "$(git -C "$s" config core.hooksPath)" -ef "$s/.git/hooks/hermy"
# Under jj, auto-track is off before setup where jj's config can be written,
# so a setup that runs jj tracks no new file; where a sandbox keeps that
# write out, setup still runs and start then names the sandbox.
if command -v jj >/dev/null; then
  sj="$tmp/setup-jj"; git clone -q "$tmp/origin.git" "$sj" 2>/dev/null; (cd "$sj" && jj git init --colocate && echo '.jj/' >> .git/info/exclude) >/dev/null 2>&1
  printf 'version: 2\ntracker: github\nworktree: jj\ndefault_branch: main\nsetup: echo x > made.txt && jj st\n' > "$sj/.hermy.yml"
  # the main checkout's own .gitignore ignores sec.env, which the new workspace's does not
  echo '*.env' > "$sj/.worktreeinclude"; echo .env >> "$sj/.git/info/exclude"; echo sec.env > "$sj/.gitignore"; echo s > "$sj/.env"; echo k > "$sj/sec.env"
  HERMY_ROOT="$sj" run start 142 feat/142-setup >/dev/null 2>&1
  t 0 "setup: under jj, the jj it runs tracks no new file" sh -c "l=\$(cd '$sj/.worktrees/142' && jj --ignore-working-copy file list) && printf '%s\n' \"\$l\" | grep -qx README.md && ! printf '%s\n' \"\$l\" | grep -qx made.txt"
  t 0 "worktreeinclude: under jj, a file both checkouts ignore is copied in" cmp -s "$sj/.env" "$sj/.worktrees/142/.env"
  t 1 "worktreeinclude: under jj, one only the main checkout ignores is not" test -e "$sj/.worktrees/142/sec.env"
  mkdir -p "$tmp/sbjj"; printf '#!/bin/sh\ncase " $* " in *" config set "*) printf "Error: Failed to write config file\\nCaused by: Operation not permitted (os error 1)\\n" >&2; exit 1 ;; esac\nexec %s "$@"\n' "$(command -v jj)" > "$tmp/sbjj/jj"; chmod +x "$tmp/sbjj/jj"
  PATH="$tmp/sbjj:$PATH" HERMY_ROOT="$sj" run start 143 feat/143-setup > "$tmp/setup-jj.log" 2>&1
  t 0 "setup: under jj, a sandbox that keeps out the auto-track write fails start" test $? != 0
  t 0 "setup: but setup has run first" test -e "$sj/.worktrees/143/made.txt"
  t 0 "setup: naming the sandbox" grep -q 'A sandbox blocks it' "$tmp/setup-jj.log"
  # A jj config dir it cannot write (workspace configs read-only): setup's
  # jj tracks no new file all the same, and its temporary config is gone
  # whether setup passes or fails.
  ut() { l=$(cd "$sj/.worktrees/$1" && jj --ignore-working-copy file list) && printf '%s\n' "$l" | grep -qx README.md && ! printf '%s\n' "$l" | grep -qx made.txt; }
  if [ "$(id -u)" != 0 ]; then # root writes anywhere
    jx="$tmp/setup-xdg"; mkdir -p "$jx/jj/workspaces" "$tmp/setup-tmp"; chmod 555 "$jx/jj/workspaces"
    XDG_CONFIG_HOME="$jx" TMPDIR="$tmp/setup-tmp" HERMY_ROOT="$sj" run start 144 feat/144-setup >/dev/null 2>&1
    t 0 "setup: under jj, with the workspace config read-only, the jj it runs tracks no new file" ut 144
    t 0 "setup: and its temporary jj config is removed" test -z "$(ls -A "$tmp/setup-tmp")"
    printf 'version: 2\ntracker: github\nworktree: jj\ndefault_branch: main\nsetup: echo x > made.txt && jj st && exit 3\n' > "$sj/.hermy.yml"
    t 1 "setup: under jj, a failing one makes start exit non-zero" env XDG_CONFIG_HOME="$jx" TMPDIR="$tmp/setup-tmp" HERMY_ROOT="$sj" "$here/bin/hermy" start 145 feat/145-setup
    t 0 "setup: tracking no new file" ut 145
    t 0 "setup: and removing its temporary jj config" test -z "$(ls -A "$tmp/setup-tmp")"
    chmod 755 "$jx/jj/workspaces"
  fi
fi

exit $fail
