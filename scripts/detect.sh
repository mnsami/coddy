#!/usr/bin/env bash
# Facts about the current project that /coddy:onboard uses to pre-fill the
# config so it only asks about what it cannot infer.
cd "${CLAUDE_PROJECT_DIR:-$PWD}" || exit 0
echo "config: $([ -f .claude/coddy.yml ] && echo present || echo none)"
echo "remote: $(git remote get-url origin 2>/dev/null || echo none)"
echo "vcs: $([ -d .jj ] && echo jj || echo git)"
echo "default_branch: $( (git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main) | sed 's#^origin/##')"
echo "make_targets: $(grep -ohE '^[A-Za-z][A-Za-z0-9_-]*:' Makefile 2>/dev/null | tr -d : | tr '\n' ' ')"
echo "package_scripts: $(jq -r '.scripts // {} | keys | join(" ")' package.json 2>/dev/null)"
echo "go_modules: $(ls go.mod */go.mod 2>/dev/null | tr '\n' ' ')"
echo "roadmap: $(ls ROADMAP.md docs/ROADMAP.md .planning/ROADMAP.md 2>/dev/null | tr '\n' ' ')"
echo "claude_dir_gitignored: $(git check-ignore -q .claude 2>/dev/null && echo yes || echo no)"
echo "recent_commits:"
git log --format='  %s' -n 15 2>/dev/null
echo "recent_branches:"
git for-each-ref --sort=-committerdate --format='  %(refname:short)' refs/heads refs/remotes 2>/dev/null | grep -v HEAD | head -8
