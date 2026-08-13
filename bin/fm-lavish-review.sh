#!/usr/bin/env bash
# Firstmate's narrow safety helper for Lavish review routing and local artifact
# placement.
#
# Usage:
#   fm-lavish-review.sh recommend <review-shape>
#   fm-lavish-review.sh prepare <root> <slug>
#   fm-lavish-review.sh check <artifact.html>
#
# recommend maps one already-classified review shape to its presentation:
#   chat:   simple-yes-no, routine-notification
#   lavish: explicit-visual, multi-option-decision, structured-input,
#           comparison, plan, architecture, data-flow, ui-review, rich-report,
#           rich-work-description
# The lavish-review skill owns the semantic classification that chooses a shape.
# This command keeps the normalized routing table closed and testable.
#
# prepare creates only <root>/.lavish/<slug>/ at owner-only directory modes and
# prints the expected <root>/.lavish/<slug>/review.html path.
# It never creates or rewrites HTML or assets, so the artifact's author remains
# responsible for opening every matching lavish-axi playbook and matching the
# subject project's design system.
# An allowed root is the physical active FM_HOME or a physical Git worktree root.
# A Git root must already ignore .lavish/ so private review material cannot be
# staged accidentally.
# Slugs use lowercase letters, digits, and hyphens, start and end with an
# alphanumeric character, and are at most 64 bytes.
# Existing .lavish roots, review directories, review.html files, and sibling
# asset trees must contain only real directories and regular files, never
# symlinks or special files.
#
# check accepts only the exact prepared shape
# <allowed-root>/.lavish/<slug>/review.html, requires a real regular HTML file,
# and repeats the root, ignore, and symlink checks before a review is armed.
#
# This helper performs no Lavish lifecycle action.
# It never opens a browser, polls, exports, publishes, shares, or contacts a
# network service.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
  exit 2
}

physical_dir() {
  local path=${1%/}
  [ -n "$path" ] || return 1
  [ -d "$path" ] && [ ! -L "$path" ] || return 1
  CDPATH='' cd -- "$path" 2>/dev/null && pwd -P
}

slug_valid() {
  local slug=${1-}
  case "$slug" in
    ''|*[!a-z0-9-]*|-*|*-) return 1 ;;
  esac
  [ "${#slug}" -le 64 ]
}

assert_allowed_root() {
  local root=$1 home git_top
  home=$(physical_dir "$FM_HOME" 2>/dev/null || true)
  if [ -n "$home" ] && [ "$root" = "$home" ]; then
    return 0
  fi
  git_top=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null) \
    || die "review root is neither the active FM_HOME nor a Git worktree root: $root"
  git_top=$(physical_dir "$git_top" 2>/dev/null) \
    || die "cannot resolve Git review root: $root"
  [ "$git_top" = "$root" ] \
    || die "review root must be the Git worktree top level: $root"
}

assert_git_root_ignores_lavish() {
  local root=$1 git_top
  [ ! -L "$root/.lavish" ] || die "unsafe .lavish root: $root/.lavish"
  git_top=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null || true)
  [ -n "$git_top" ] || return 0
  git_top=$(physical_dir "$git_top" 2>/dev/null) \
    || die "cannot resolve Git review root: $root"
  [ "$git_top" = "$root" ] \
    || die "review root must be the Git worktree top level: $root"
  git -C "$root" check-ignore -q --no-index -- .lavish/.firstmate-private-probe \
    || die "Git review roots must ignore .lavish/ before private artifacts are prepared: $root"
}

assert_root() {
  local input=${1%/} root
  [ -n "$input" ] || die "review root is required"
  case "$input" in *$'\n'*) die "review roots cannot contain newlines" ;; esac
  [ ! -L "$input" ] || die "review root cannot be a symlink: $input"
  root=$(physical_dir "$input" 2>/dev/null) \
    || die "review root is not a physical directory: $input"
  [ "$input" = "$root" ] \
    || die "review root must use its physical absolute path: $input"
  assert_allowed_root "$root"
  assert_git_root_ignores_lavish "$root"
  printf '%s\n' "$root"
}

cmd_recommend() {
  [ "$#" -eq 1 ] || usage
  case "$1" in
    simple-yes-no|routine-notification) printf 'chat\n' ;;
    explicit-visual|multi-option-decision|structured-input|comparison|plan|architecture|data-flow|ui-review|rich-report|rich-work-description)
      printf 'lavish\n'
      ;;
    *) die "unknown review shape: $1" ;;
  esac
}

cmd_prepare() {
  local root slug lavish_dir review_dir artifact
  [ "$#" -eq 2 ] || usage
  root=$(assert_root "$1")
  slug=$2
  slug_valid "$slug" || die "review slug must be lowercase alphanumeric with internal hyphens and at most 64 bytes: $slug"
  lavish_dir="$root/.lavish"
  review_dir="$lavish_dir/$slug"
  artifact="$review_dir/review.html"

  if [ -e "$lavish_dir" ] || [ -L "$lavish_dir" ]; then
    [ -d "$lavish_dir" ] && [ ! -L "$lavish_dir" ] \
      || die "unsafe .lavish root: $lavish_dir"
  else
    (umask 077; mkdir -m 700 -- "$lavish_dir") \
      || die "cannot create private .lavish root: $lavish_dir"
  fi
  chmod 700 "$lavish_dir" || die "cannot enforce private .lavish root mode: $lavish_dir"

  if [ -e "$review_dir" ] || [ -L "$review_dir" ]; then
    [ -d "$review_dir" ] && [ ! -L "$review_dir" ] \
      || die "unsafe Lavish review directory: $review_dir"
  else
    (umask 077; mkdir -m 700 -- "$review_dir") \
      || die "cannot create private Lavish review directory: $review_dir"
  fi
  chmod 700 "$review_dir" || die "cannot enforce private review directory mode: $review_dir"

  if [ -e "$artifact" ] || [ -L "$artifact" ]; then
    [ -f "$artifact" ] && [ ! -L "$artifact" ] \
      || die "unsafe Lavish artifact path: $artifact"
  fi

  printf 'review_dir: %s\n' "$review_dir"
  printf 'artifact: %s\n' "$artifact"
}

cmd_check() {
  local input artifact_name review_input review_dir slug lavish_dir root unsafe
  [ "$#" -eq 1 ] || usage
  input=$1
  case "$input" in *$'\n'*) die "artifact paths cannot contain newlines" ;; esac
  [ -f "$input" ] && [ ! -L "$input" ] \
    || die "Lavish artifact must be a real regular file: $input"
  artifact_name=${input##*/}
  [ "$artifact_name" = review.html ] \
    || die "Lavish artifact must use the prepared review.html path: $input"

  review_input=${input%/*}
  [ "$review_input" != "$input" ] || die "artifact path must include its review directory: $input"
  [ -d "$review_input" ] && [ ! -L "$review_input" ] \
    || die "Lavish review directory cannot be a symlink: $review_input"
  review_dir=$(physical_dir "$review_input" 2>/dev/null) \
    || die "cannot resolve Lavish review directory: $review_input"
  unsafe=$(find "$review_dir" ! -type d ! -type f -print -quit 2>/dev/null) \
    || die "cannot inspect the Lavish review tree: $review_dir"
  [ -z "$unsafe" ] \
    || die "Lavish review trees cannot contain symlinks or special files: $unsafe"
  slug=${review_dir##*/}
  slug_valid "$slug" || die "unsafe Lavish review directory slug: $slug"

  lavish_dir=${review_dir%/*}
  [ "${lavish_dir##*/}" = .lavish ] \
    || die "Lavish artifacts must live under an allowed .lavish root: $input"
  [ -d "$lavish_dir" ] && [ ! -L "$lavish_dir" ] \
    || die "Lavish artifact root cannot be a symlink: $lavish_dir"
  root=${lavish_dir%/*}
  root=$(assert_root "$root")
  [ "$review_dir" = "$root/.lavish/$slug" ] \
    || die "Lavish artifact path did not resolve to its allowed local root: $input"
  [ "$input" = "$review_dir/review.html" ] \
    || die "Lavish artifact must use its physical absolute prepared path: $input"

  printf '%s\n' "$review_dir/review.html"
}

case "${1-}" in
  recommend) shift; cmd_recommend "$@" ;;
  prepare) shift; cmd_prepare "$@" ;;
  check) shift; cmd_check "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
