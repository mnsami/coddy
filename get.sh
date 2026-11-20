#!/usr/bin/env bash
# Installs hermy for any agent and the terminal: a checkout of the latest
# release (the newest v* tag on main's first-parent line, detached; main while
# there is none) and the hermy command on PATH.
#   curl -fsSL https://raw.githubusercontent.com/mnsami/hermy/main/get.sh | bash
# Inputs, all optional: HERMY_REPO_URL (the repository), HERMY_HOME (the
# checkout, ~/.hermy), HERMY_BIN (where hermy is linked, ~/.local/bin),
# HERMY_REF (main for the tip, or, to pin, a tag on main's first-parent line,
# a state main itself was at, nothing else; the latest release without it).
# A rerun moves the checkout to that target, main by fast-forward. Every
# refusal comes before any change to the checkout, but a first run's refusal
# of its target (a HERMY_REF that is no tag main itself was at, a latest
# release tag object named otherwise, or whose ref resolves off main's
# first-parent line), which comes once it has cloned main, linking nothing.
# Reads nothing from stdin, which is this script under curl.
# Wrapped in main so a download cut short runs nothing.
set -u
main() {
  local url="${HERMY_REPO_URL:-https://github.com/mnsami/hermy}" home="${HERMY_HOME:-${HOME:?is not set: set it, or HERMY_HOME and HERMY_BIN}/.hermy}" bin="${HERMY_BIN:-${HOME:?is not set: set it, or HERMY_HOME and HERMY_BIN}/.local/bin}"
  local link state sha top v a on ref c out tags
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
  # Text from the remote reaches the terminal as line breaks and printable ASCII alone.
  clean() { printf '%s\n' "$1" | LC_ALL=C tr -cd '\012\040-\176'; }
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
  # HERMY_REF reaches git as an argument.
  case "${HERMY_REF:-}" in -*) die "HERMY_REF=$HERMY_REF starts with -: name a tag, or main, then run this again" ;; esac
  if [ -e "$home" ] || [ -L "$home" ]; then
    top=$(git -C "$home" rev-parse --show-toplevel 2>/dev/null)
    [ -n "$top" ] && [ "$top" -ef "$home" ] || die "$home is not a git checkout: move it aside, then run this again"
    [ "$(norm "$(git -C "$home" remote get-url origin 2>/dev/null)")" = "$(norm "$url")" ] || die "$home's origin is not $url: move it aside, then run this again"
    # A detached HEAD is where a release leaves it. The full name: with a tag named main, --short prints heads/main.
    on=$(git -C "$home" symbolic-ref -q HEAD)
    [ -z "$on" ] || [ "$on" = refs/heads/main ] || die "$home is on ${on#refs/heads/}, not main: switch it back (git -C $home switch main), then run this again"
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
    sha=$(git -C "$home" rev-parse -q --verify HEAD) state=updated
    # Every tag: one on a commit the checkout has already is not followed otherwise. --prune drops one the remote
    # deleted (--prune-tags is ignored beside a refspec given here). refs/heads/main: a tag named main would be fetched
    # for it. A tag moved on the remote fails the fetch and stops the run; LC_ALL=C keeps git's reason matchable.
    out=$(LC_ALL=C git -C "$home" fetch --prune origin refs/heads/main 'refs/tags/*:refs/tags/*' 2>&1) || {
      out=$(clean "$out")
      # Each name single-quoted for the command to paste: git lets one hold ; $ ( ) ` and '.
      tags=$(printf '%s\n' "$out" | sed -n "s/'/'\\\\''/g; s/^ ! \[rejected\] *\([^ ]*\) .*(would clobber existing tag)\$/'\1'/p" | tr '\n' ' ')
      [ -z "$tags" ] || tags="; a release tag moved on the remote: delete the local one (git -C $home tag -d -- ${tags% }), then run this again"
      die "could not fetch from $url$tags. git says:
$out"
    }
  else
    # -o origin: a clone.defaultRemoteName of the user's would name it otherwise.
    git clone -q -o origin -b main -- "$url" "$home" || die "could not clone $url"
    sha='' state=cloned on=refs/heads/main
  fi
  # The latest release: the v* tag nearest origin/main's tip on its first-parent line, so a state main itself
  # was at and never a commit inside a merged branch; a reverted release does not move it.
  # Full ref names: a fetched tag named origin/main (or main) would shadow the short one.
  ref=${HERMY_REF:-} c=''
  if [ -z "$ref" ] && out=$(LC_ALL=C git -C "$home" describe --first-parent --tags --abbrev=0 --match 'v[0-9]*' refs/remotes/origin/main 2>&1); then
    ref=${out##*$'\n'}
    # A tag object named otherwise than its ref: git warns and prints the object's name, which may be another tag's.
    # Its ref, read again, is held to the first-parent line as a pinned tag is: a file system that folds case may
    # open another tag's ref by that name.
    case $out in *"is externally known as"*|*"is really '"*) ;; *)
      c=$(git -C "$home" rev-parse -q --verify "refs/tags/$ref^{commit}") && git -C "$home" rev-list --first-parent refs/remotes/origin/main | grep -qxF "$c" || c='' ;;
    esac
    [ -n "$c" ] || die "the latest release tag in $url is not one main was at; the checkout and HEAD are unchanged: name a release in HERMY_REF, or main, then run this again. git says:
$(clean "$out")"
  fi
  ref=${ref:-main}
  if [ "$ref" = main ]; then
    # Detached: main moves only by fast-forward, and checkout -B moves nothing when it fails.
    if [ "$on" = refs/heads/main ]; then out=$(git -C "$home" merge --ff-only refs/remotes/origin/main 2>&1)
    else
      # A local main that is gone is made again.
      ! git -C "$home" rev-parse -q --verify refs/heads/main >/dev/null || git -C "$home" merge-base --is-ancestor refs/heads/main refs/remotes/origin/main ||
        die "the local main in $home has commits that the remote's main does not; the checkout and HEAD are unchanged: move them to another branch or drop them, then run this again"
      out=$(git -C "$home" checkout -q -B main refs/remotes/origin/main 2>&1)
    fi ||
      die "could not update $home (not a fast-forward, or an untracked file is in the way); the checkout and HEAD are unchanged. git says:
$(clean "$out")"
  else
    if [ -z "$c" ]; then
      # A tag by its own ref and nothing else: no commit id, branch or revision such as v1~1.
      { git -C "$home" show-ref -q --verify "refs/tags/$ref" && c=$(git -C "$home" rev-parse -q --verify "refs/tags/$ref^{commit}"); } ||
        die "HERMY_REF=$ref is not a tag of $url: name a tag, or main, then run this again"
      # A pinned tag too must be on main's first-parent line, the one describe reads above: a tag pushed on an
      # unreviewed commit, or on one inside a merged branch, is no state main itself was at.
      git -C "$home" rev-list --first-parent refs/remotes/origin/main | grep -qxF "$c" ||
        die "HERMY_REF=$ref is not a tag main itself was at in $url; the checkout and HEAD are unchanged: name a release, or main, then run this again"
    fi
    out=$(git -C "$home" checkout -q --detach "$c" 2>&1) ||
      die "could not check out $(clean "$ref") in $home (an untracked file is in the way); the checkout and HEAD are unchanged. git says:
$(clean "$out")"
  fi
  [ "$(git -C "$home" rev-parse HEAD)" != "$sha" ] || state="up to date"
  mkdir -p "$bin" 2>/dev/null || die "could not create $bin"
  [ -L "$link" ] || ln -s "$home/bin/hermy" "$link" || die "could not link $link"
  echo "$state: $home at $(clean "$ref") ($(git -C "$home" rev-parse --short HEAD))"
  echo "linked: $link"
  case ":$(printf %s "$PATH" | sed 's#/*:#:#g; s#/*$##'):" in *":$bin:"*) ;; *) echo "$bin is not on your PATH. Add this line to your shell's rc file:"; echo "  export PATH=\"$bin:\$PATH\"" ;; esac
  cat <<EOF

Next:
  Claude Code: install the plugin, which keeps its own copy and does not use $home:
    claude plugin marketplace add mnsami/hermy
    claude plugin install hermy@hermy
  Any other agent: in your project, have it read $home/skills/onboard/SKILL.md
    and follow it; the other skills are next to it under $home/skills/.
    The hermy command is $link.
EOF
}
main "$@"
