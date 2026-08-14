#!/usr/bin/env bash
# Firstmate's safety helper and private runtime envelope for Lavish reviews.
#
# Usage:
#   fm-lavish-review.sh recommend <review-shape>
#   fm-lavish-review.sh prepare <root> <slug>
#   fm-lavish-review.sh check <artifact.html>
#   fm-lavish-review.sh run <lavish-axi-argv>...
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
# responsible for opening every matching Lavish playbook and matching the
# subject project's design system.
# An allowed root is the physical active FM_HOME or a physical Git worktree root.
# A Git root must ignore the exact future review path before preparation, and
# every existing file in the review tree must remain ignored and untracked.
# Slugs use lowercase letters, digits, and hyphens, start and end with an
# alphanumeric character, and are at most 64 bytes.
# Existing .lavish roots, review directories, review.html files, and sibling
# asset trees must contain only real directories and single-link regular files,
# never symlinks, hardlinks, or special files.
#
# check accepts only the exact prepared shape
# <allowed-root>/.lavish/<slug>/review.html, requires a real single-link HTML
# file, and repeats the root, Git, symlink, hardlink, and tree checks before a
# review is opened or armed.
#
# run is the only Firstmate review-lifecycle envelope for the installed CLI.
# It executes the supplied lavish-axi argv with an owner-only state directory
# under the physical FM_HOME, a deterministic home-specific port, loopback-only
# bind and links, telemetry disabled, a clean Lavish environment, and umask 077.
# It validates every lifecycle HTML argument, rejects CLI --port and export
# --out overrides, and keeps default exports beside their private source.
# Open, poll, help, design, end, stop, and every supported local lifecycle
# command therefore resolve to one consistent home-scoped server. It refuses
# external `share` and global `setup` subcommands entirely.
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

single_link_regular_file() {
  perl -e '
    my @s = lstat($ARGV[0]);
    exit 1 unless @s;
    exit 1 unless (($s[2] & 0170000) == 0100000);
    exit($s[3] == 1 ? 0 : 1);
  ' "$1"
}

assert_single_link_file() {  # <path> <label>
  single_link_regular_file "$1" \
    || die "$2 must be a single-link regular file: $1"
}

assert_safe_file_tree() {  # <directory> <label>
  local directory=$1 label=$2 unsafe path
  unsafe=$(find "$directory" ! -type d ! -type f -print -quit 2>/dev/null) \
    || die "cannot inspect $label: $directory"
  [ -z "$unsafe" ] \
    || die "$label cannot contain symlinks or special files: $unsafe"
  while IFS= read -r -d '' path; do
    case "$path" in *$'\n'*) die "$label paths cannot contain newlines" ;; esac
    assert_single_link_file "$path" "$label file"
  done < <(find "$directory" -type f -print0 2>/dev/null)
}

assert_allowed_root() {
  local root=$1 home git_top
  home=$(physical_dir "$FM_HOME" 2>/dev/null || true)
  if [ -n "$home" ] && [ "$root" = "$home" ]; then
    git_top=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null || true)
    if [ -n "$git_top" ]; then
      git_top=$(physical_dir "$git_top" 2>/dev/null) \
        || die "cannot resolve Git review root: $root"
      [ "$git_top" = "$root" ] \
        || die "review root must be the Git worktree top level: $root"
    fi
    return 0
  fi
  git_top=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null) \
    || die "review root is neither the active FM_HOME nor a Git worktree root: $root"
  git_top=$(physical_dir "$git_top" 2>/dev/null) \
    || die "cannot resolve Git review root: $root"
  [ "$git_top" = "$root" ] \
    || die "review root must be the Git worktree top level: $root"
}

git_root_for_review() {  # <root>; print a physical Git top level or nothing
  local root=$1 git_top
  git_top=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null) || return 1
  git_top=$(physical_dir "$git_top" 2>/dev/null) || return 1
  [ "$git_top" = "$root" ] || return 1
  printf '%s\n' "$git_top"
}

assert_git_private_file() {  # <root> <relative-file>
  local root=$1 relative=$2
  case "$relative" in ''|/*|*$'\n'*) die "unsafe Git review path: $relative" ;; esac
  if git -C "$root" ls-files --error-unmatch -- ":(literal)$relative" >/dev/null 2>&1; then
    die "Lavish review files must be untracked: $root/$relative"
  fi
  git -C "$root" check-ignore -q -- "$relative" \
    || die "Git review roots must ignore every Lavish review file: $root/$relative"
}

assert_git_future_review() {  # <root> <slug>
  local root=$1 slug=$2
  git_root_for_review "$root" >/dev/null 2>&1 || return 0
  assert_git_private_file "$root" ".lavish/$slug/review.html"
}

assert_git_review_tree() {  # <root> <slug> <review-dir>
  local root=$1 slug=$2 review_dir=$3 path relative
  git_root_for_review "$root" >/dev/null 2>&1 || return 0
  assert_git_future_review "$root" "$slug"
  while IFS= read -r -d '' path; do
    case "$path" in *$'\n'*) die "Lavish review file paths cannot contain newlines" ;; esac
    relative=${path#"$root"/}
    [ "$relative" != "$path" ] \
      || die "Lavish review file escaped its Git root: $path"
    assert_git_private_file "$root" "$relative"
  done < <(find "$review_dir" -type f -print0 2>/dev/null)
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
  [ ! -L "$root/.lavish" ] || die "unsafe .lavish root: $root/.lavish"
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
  assert_git_future_review "$root" "$slug"
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

  assert_safe_file_tree "$review_dir" "Lavish review trees"
  if [ -e "$artifact" ] || [ -L "$artifact" ]; then
    assert_single_link_file "$artifact" "Lavish artifact"
  fi
  assert_git_review_tree "$root" "$slug" "$review_dir"

  printf 'review_dir: %s\n' "$review_dir"
  printf 'artifact: %s\n' "$artifact"
}

cmd_check() {
  local input artifact_name review_input review_dir slug lavish_dir root
  [ "$#" -eq 1 ] || usage
  input=$1
  case "$input" in *$'\n'*) die "artifact paths cannot contain newlines" ;; esac
  [ -f "$input" ] && [ ! -L "$input" ] \
    || die "Lavish artifact must be a real regular file: $input"
  assert_single_link_file "$input" "Lavish artifact"
  artifact_name=${input##*/}
  [ "$artifact_name" = review.html ] \
    || die "Lavish artifact must use the prepared review.html path: $input"

  review_input=${input%/*}
  [ "$review_input" != "$input" ] || die "artifact path must include its review directory: $input"
  [ -d "$review_input" ] && [ ! -L "$review_input" ] \
    || die "Lavish review directory cannot be a symlink: $review_input"
  review_dir=$(physical_dir "$review_input" 2>/dev/null) \
    || die "cannot resolve Lavish review directory: $review_input"
  assert_safe_file_tree "$review_dir" "Lavish review trees"
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
  assert_git_review_tree "$root" "$slug" "$review_dir"

  printf '%s\n' "$review_dir/review.html"
}

hash_text() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  fi
}

runtime_port() {  # <physical-home>
  local digest prefix value
  digest=$(hash_text "$1") || return 1
  prefix=${digest:0:8}
  value=$((16#$prefix))
  printf '%s\n' "$((20000 + value % 30000))"
}

prepare_runtime_dir() {  # print owner-only runtime directory
  local home state runtime path
  home=$(physical_dir "$FM_HOME" 2>/dev/null) \
    || die "active FM_HOME is not a physical directory: $FM_HOME"
  state="$home/state"
  runtime="$state/lavish-axi"
  if [ -e "$state" ] || [ -L "$state" ]; then
    [ -d "$state" ] && [ ! -L "$state" ] \
      || die "unsafe Firstmate state directory: $state"
  else
    (umask 077; mkdir -m 700 -- "$state") \
      || die "cannot create Firstmate state directory: $state"
  fi
  if [ -e "$runtime" ] || [ -L "$runtime" ]; then
    [ -d "$runtime" ] && [ ! -L "$runtime" ] \
      || die "unsafe Lavish runtime state directory: $runtime"
  else
    (umask 077; mkdir -m 700 -- "$runtime") \
      || die "cannot create Lavish runtime state directory: $runtime"
  fi
  assert_safe_file_tree "$runtime" "Lavish runtime state"
  while IFS= read -r -d '' path; do
    chmod 700 "$path" || die "cannot enforce owner-only Lavish runtime directory mode: $path"
  done < <(find "$runtime" -type d -print0 2>/dev/null)
  while IFS= read -r -d '' path; do
    chmod 600 "$path" || die "cannot enforce owner-only Lavish runtime file mode: $path"
  done < <(find "$runtime" -type f -print0 2>/dev/null)
  printf '%s\n' "$runtime"
}

cmd_run() {
  local lavish runtime home port arg artifact=''
  local -a clean_env
  [ "$#" -ge 1 ] || usage
  case "$1" in
    share) die "the private Lavish runtime does not support external sharing" ;;
    setup) die "the private Lavish runtime does not modify global tool setup" ;;
    server) die "the private Lavish runtime owns server startup through reviewed lifecycle commands" ;;
    --help|--version|-v|-V|design|stop) ;;
    playbook)
      [ "$#" -ge 2 ] || die "Lavish playbook requires a playbook id or --help"
      ;;
    open|poll|end|export)
      [ "$#" -ge 2 ] || die "Lavish $1 requires a private artifact path"
      [ "$2" = --help ] || artifact=$2
      ;;
    *.html|*.htm) artifact=$1 ;;
    *) die "unsupported command for the private Lavish runtime: $1" ;;
  esac
  for arg in "$@"; do
    case "$arg" in
      --port|--port=*) die "Lavish runtime port overrides are not allowed" ;;
      --out|--out=*) die "Lavish export path overrides are not allowed" ;;
    esac
  done
  [ -z "$artifact" ] || cmd_check "$artifact" >/dev/null
  lavish=$(command -v lavish-axi 2>/dev/null) || die "lavish-axi is not installed"
  runtime=$(prepare_runtime_dir)
  home=$(physical_dir "$FM_HOME" 2>/dev/null) \
    || die "active FM_HOME is not a physical directory: $FM_HOME"
  port=$(runtime_port "$home") || die "cannot derive the home-scoped Lavish runtime port"
  clean_env=(
    env -i
    "HOME=${HOME:-$home}"
    "PATH=$PATH"
    "TMPDIR=${TMPDIR:-/tmp}"
    "LANG=${LANG:-C}"
    "LAVISH_AXI_STATE_DIR=$runtime"
    "LAVISH_AXI_HOST=127.0.0.1"
    "LAVISH_AXI_LINK_HOST=127.0.0.1"
    "LAVISH_AXI_ALLOWED_HOSTS=127.0.0.1 localhost"
    "LAVISH_AXI_PORT=$port"
    "LAVISH_AXI_TELEMETRY=off"
  )
  [ -z "${DISPLAY:-}" ] || clean_env+=("DISPLAY=$DISPLAY")
  [ -z "${WAYLAND_DISPLAY:-}" ] || clean_env+=("WAYLAND_DISPLAY=$WAYLAND_DISPLAY")
  [ -z "${XDG_RUNTIME_DIR:-}" ] || clean_env+=("XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR")
  [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] || clean_env+=("DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS")
  umask 077
  exec "${clean_env[@]}" "$lavish" "$@"
}

case "${1-}" in
  recommend) shift; cmd_recommend "$@" ;;
  prepare) shift; cmd_prepare "$@" ;;
  check) shift; cmd_check "$@" ;;
  run) shift; cmd_run "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
