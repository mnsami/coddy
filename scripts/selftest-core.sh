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
{ echo 'version: 1'; cat .claude/coddy.yml; } > "$tmp/v1.yml"
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
t 0 "migrate: the file after --- is the expected v1, comments kept" sh -c "'$here/bin/coddy' migrate | sed '1,/^---\$/d' | cmp -s - '$tmp/v1.yml'"
t 0 "migrate: writes nothing" cmp -s .claude/coddy.yml "$tmp/v0.yml"
t 1 "migrate: and makes no .coddy.yml" test -e .coddy.yml
cp "$tmp/v1.yml" .coddy.yml
t 0 "migrate: a v1 config next to a leftover legacy file says remove" says '^changed: remove .claude/coddy.yml$' run migrate
t 1 "migrate: and prints no file" says '^---$' run migrate
rm .claude/coddy.yml
t 0 "migrate: a v1 config is current" says '^to: 1$' run migrate
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
# after <file>: the file migrate prints after its first --- line is <file>
after() { "$here/bin/coddy" migrate | sed '1,/^---$/d' | cmp -s - "$1"; }
rm .coddy.yml
printf -- '---\ntracker: github\n' > .claude/coddy.yml; printf -- '---\nversion: 1\ntracker: github\n' > "$tmp/want.yml"
t 0 "migrate: a leading --- keeps version below it" after "$tmp/want.yml"
printf 'tracker: github\r\n' > .claude/coddy.yml; printf 'version: 1\r\ntracker: github\r\n' > "$tmp/want.yml"
t 0 "migrate: a CRLF config gets a CRLF version line" after "$tmp/want.yml"
printf 'tracker: github\n\n\n' > .claude/coddy.yml; printf 'version: 1\ntracker: github\n\n\n' > "$tmp/want.yml"
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
doc() { HOME="$gh" CODDY_HOME="$cs" "$@" doctor; }
t 0 "doctor: through the link, the real install dir" says "^install: $(cd "$cs" && pwd -P)\$" doc "$gh/bin/coddy"
t 0 "doctor: via get.sh" says '^via: get.sh$' doc "$gh/bin/coddy"
t 0 "doctor: the installed commit" says "^commit: $(sha)\$" doc "$gh/bin/coddy"
t 0 "doctor: the version" says "^version: $(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$here/.claude-plugin/plugin.json")\$" doc "$gh/bin/coddy"
t 0 "doctor: from this checkout, via other" says '^via: other$' doc "$here/bin/coddy"
t 0 "doctor: naming this checkout" says "^install: $(cd "$here" && pwd -P)\$" doc "$here/bin/coddy"
t 0 "doctor: with no HOME" says '^via: other$' env -u HOME -u CODDY_HOME "$here/bin/coddy" doctor
t 1 "doctor: and no unbound variable" says 'unbound' env -u HOME -u CODDY_HOME "$here/bin/coddy" doctor
t 0 "doctor: a CDPATH does not move it" sh -c "cd '$here' && CDPATH='$gh' HOME='$gh' bash bin/coddy doctor | grep -qx 'install: $(cd "$here" && pwd -P)'"
mkdir -p "$tmp/dl/real/bin" "$tmp/dl/x"; cp "$here/bin/coddy" "$tmp/dl/real/bin/"; ln -s ../real/bin "$tmp/dl/x/bin"
t 0 "doctor: through a linked bin/, the real install dir" says "^install: $(cd "$tmp/dl/real" && pwd -P)\$" "$tmp/dl/x/bin/coddy" doctor

exit $fail
