#!/usr/bin/env bash
# Installs hermy for any agent and the terminal: a checkout of main and the
# hermy command on PATH.
#   curl -fsSL https://raw.githubusercontent.com/mnsami/coddy/main/get.sh | bash
# Inputs, all optional: HERMY_REPO_URL (the repository), HERMY_HOME (the
# checkout, ~/.hermy), HERMY_BIN (where hermy is linked, ~/.local/bin).
# A rerun updates the checkout by fast-forward. Every refusal comes before
# any change. Reads nothing from stdin, which is this script under curl.
# Wrapped in main so a download cut short runs nothing.
set -u
main() {
  local url="${HERMY_REPO_URL:-https://github.com/mnsami/coddy}" home="${HERMY_HOME:-${HOME:?is not set: set it, or HERMY_HOME and HERMY_BIN}/.hermy}" bin="${HERMY_BIN:-${HOME:?is not set: set it, or HERMY_HOME and HERMY_BIN}/.local/bin}"
  local link state sha top v a
  # Absolute, so the link's target resolves from HERMY_BIN and the PATH line works anywhere.
  case "$home" in /*) ;; *) home="$PWD/$home" ;; esac
  case "$bin" in /*) ;; *) bin="$PWD/$bin" ;; esac
  bin="${bin%"${bin##*[!/]}"}" # no trailing /, so the PATH check below matches
  home="${home%"${home##*[!/]}"}" # nor in the link's target and the paths printed
  # git records a relative local repository by its absolute path; so does this, or a rerun would not match it.
  case "$url" in /*|*://*|[!/]*@*:*) ;; *) [ ! -e "$url" ] || url="$PWD/$url" ;; esac
  # A GIT_DIR or GIT_CONFIG_* from the caller would point git at another repository or config.
  for v in "${!GIT_@}"; do case $v in GIT_AUTHOR_*|GIT_COMMITTER_*|GIT_SSH*|GIT_ASKPASS) ;; *) unset "$v" ;; esac; done
  export GIT_TERMINAL_PROMPT=0
  die() { echo "hermy install: $*" >&2; exit 1; }
  # The same repository however its URL is spelled: ssh (scp form or ssh://)
  # or https, any case of host (and of path on github.com, which ignores it),
  # file:// or a plain path, with or without a trailing / or .git.
  norm() {
    local u="${1%/}" h; u="${u%.git}"; u="${u%/}"; u="${u#file://}"; u="${u//\/.\///}"
    case "$u" in
      ssh://*@*) u="https://${u#ssh://*@}" ;;
      ssh://*) u="https://${u#ssh://}" ;;
      [!/]*@*:*) h="${u#*@}"; u="https://${h%%:*}/${h#*:}" ;;
    esac
    case "$u" in https://*)
      h="${u#https://}"; u="https://$(printf %s "${h%%/*}" | tr '[:upper:]' '[:lower:]')${h#"${h%%/*}"}"
      case "$u" in https://github.com/*) u=$(printf %s "$u" | tr '[:upper:]' '[:lower:]') ;; esac ;;
    esac
    printf %s "$u"
  }

  [ "$(id -u)" != 0 ] || die "refusing to run as root: run it as the user who will use hermy"
  command -v git >/dev/null || die "git is needed: install it, then run this again"
  if [ -e "$home" ] || [ -L "$home" ]; then
    top=$(git -C "$home" rev-parse --show-toplevel 2>/dev/null)
    [ -n "$top" ] && [ "$top" -ef "$home" ] || die "$home is not a git checkout: move it aside, then run this again"
    [ "$(norm "$(git -C "$home" remote get-url origin 2>/dev/null)")" = "$(norm "$url")" ] || die "$home's origin is not $url: move it aside, then run this again"
    [ "$(git -C "$home" symbolic-ref -q --short HEAD)" = main ] || die "$home is not on main: switch it back (git -C $home switch main), then run this again"
    [ -z "$(git -C "$home" status --porcelain --untracked-files=no)" ] || die "$home has changes to tracked files: commit, stash or drop them, then run this again"
  fi
  link="$bin/hermy"
  if [ -e "$link" ] || [ -L "$link" ]; then
    [ -L "$link" ] && { [ "$(readlink "$link")" = "$home/bin/hermy" ] || [ "$link" -ef "$home/bin/hermy" ]; } ||
      die "$link is there already and is not a link to $home/bin/hermy: remove it, then run this again"
  fi
  # HERMY_BIN is made only once the checkout is in place, so a failed clone or fetch leaves none behind.
  a=$bin; while [ ! -e "$a" ] && [ ! -L "$a" ]; do a=${a%/*}; a=${a:-/}; done
  # Write access is needed unless the link is there already (checked above).
  [ -d "$a" ] && { [ -L "$link" ] || [ -w "$a" ]; } || die "could not create $bin or link hermy in it: make it a directory you can write to, then run this again"

  if [ -e "$home" ]; then
    sha=$(git -C "$home" rev-parse -q --verify --short HEAD)
    git -C "$home" fetch -q origin main || die "could not fetch from $url"
    local out; out=$(git -C "$home" merge --ff-only origin/main 2>&1) ||
      die "could not update $home (not a fast-forward, or an untracked file is in the way); the checkout and HEAD are unchanged. git says:
$out"
    if [ "$(git -C "$home" rev-parse --short HEAD)" = "$sha" ]; then state="up to date"; else state=updated; fi
  else
    git clone -q -b main -- "$url" "$home" || die "could not clone $url"
    state=cloned
  fi
  mkdir -p "$bin" 2>/dev/null || die "could not create $bin"
  [ -L "$link" ] || ln -s "$home/bin/hermy" "$link" || die "could not link $link"
  echo "$state: $home at $(git -C "$home" rev-parse --short HEAD)"
  echo "linked: $link"
  case ":$(printf %s "$PATH" | sed 's#/*:#:#g; s#/*$##'):" in *":$bin:"*) ;; *) echo "$bin is not on your PATH. Add this line to your shell's rc file:"; echo "  export PATH=\"$bin:\$PATH\"" ;; esac
  cat <<EOF

Next:
  Claude Code: install the plugin, which keeps its own copy and does not use $home:
    claude plugin marketplace add mnsami/coddy
    claude plugin install hermy@hermy
  Any other agent: in your project, have it read $home/skills/onboard/SKILL.md
    and follow it; the other skills are next to it under $home/skills/.
    The hermy command is $link.
EOF
}
main "$@"
