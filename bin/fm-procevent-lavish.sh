#!/usr/bin/env bash
# Lavish adapter for the generic process-to-event runner.
#
# Usage:
#   fm-procevent-lavish.sh arm <artifact.html> [--agent-reply <message>]
#   fm-procevent-lavish.sh classify <result-file>
#   fm-procevent-lavish.sh terminal <result-file>
#   fm-procevent-lavish.sh source-id <artifact.html>
#   fm-procevent-lavish.sh retire <artifact.html>
#
# arm        Validate Firstmate's private local artifact shape, then register one
#            blocking lavish-axi poll through the generic process-event runner.
#            After handling ordinary feedback and revising the artifact, arm
#            again with --agent-reply so the browser sees the response before it
#            accepts more feedback. The message must be one non-empty line of at
#            most 4096 bytes.
# classify   Print the lifecycle state a handler should act on: feedback, ended,
#            waiting, missing, or unknown.
# terminal   Exit 0 for every completed feedback, ended, or missing result so the
#            current poll registration retires before handler work. An ordinary
#            open-session feedback result is explicitly re-armed by its handler;
#            this prevents the watcher's next reconciliation from starting a
#            plain poll before --agent-reply can be sent. Waiting or unknown
#            results stay armed for recovery.
#
# This adapter is deliberately thin. It owns only what is specific to Lavish:
# safe local artifact validation, canonical source identity, the argv for the
# currently published poll command, and how to read a completed result.
# Ownership, durable capture, publication, and restart recovery all belong to
# bin/fm-procevent.sh.
#
# It wraps ONLY the currently published interface, verified against 0.1.50:
#   Usage: lavish-axi poll <html-file> [--agent-reply "..."]
# and that command "long-polls indefinitely" server-side. The adapter therefore
# runs the blocking form with no timeout flag, so results arrive as real
# server-side events. It adds no periodic discovery, no timer fallback, and no
# dependency on any unreleased capability.
#
# The adapter invokes only `lavish-axi poll`; it never opens, exports, publishes,
# or shares an artifact. bin/fm-lavish-review.sh owns the allowed path check.
#
# LOSS LIMITATION, stated plainly. The published poll destructively clears
# feedback before returning it. A result lost after that clearing and before the
# runner reads the process output is unrecoverable, and no Firstmate wrapper can
# close that source-side handoff window. Never describe this path as
# at-least-once, no-loss, or lossless. The only durability this proves is the
# runner's own: output that reached the runner is stored before it is announced.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}" >&2
  exit 2
}

checked_artifact() {
  local artifact=${1-}
  [ -n "$artifact" ] || usage
  "$SCRIPT_DIR/fm-lavish-review.sh" check "$artifact" \
    || die "artifact failed Firstmate's private local path check: $artifact"
}

# Canonical identity is physical, not the path string: Lavish itself keys a
# session on the realpath of the artifact. The path checker rejects symlinked
# artifacts and roots before returning the one physical prepared path.
cmd_source_id() {
  local artifact=${1-} real
  [ -n "$artifact" ] || usage
  real=$(checked_artifact "$artifact") || exit 1
  if command -v shasum >/dev/null 2>&1; then
    printf 'lavish-%s\n' "$(printf '%s' "$real" | shasum -a 256 | awk '{print substr($1,1,16)}')"
  else
    printf 'lavish-%s\n' "$(printf '%s' "$real" | sha256sum | awk '{print substr($1,1,16)}')"
  fi
}

cmd_arm() {
  local artifact=${1-} id real agent_reply='' reply_bytes
  [ -n "$artifact" ] || usage
  shift
  case "$#" in
    0) ;;
    2)
      [ "$1" = --agent-reply ] || usage
      agent_reply=$2
      [ -n "$agent_reply" ] || die "--agent-reply requires a non-empty message"
      case "$agent_reply" in *$'\n'*) die "--agent-reply must be one line" ;; esac
      reply_bytes=$(printf '%s' "$agent_reply" | wc -c | tr -d '[:space:]')
      [ "$reply_bytes" -le 4096 ] || die "--agent-reply cannot exceed 4096 bytes"
      ;;
    *) usage ;;
  esac
  command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
  real=$(checked_artifact "$artifact") || exit 1
  id=$(cmd_source_id "$real") || exit 1
  # The blocking form has no --timeout-ms, so completion is a server event.
  # Registration stores argv one element per line and executes it directly.
  if [ -n "$agent_reply" ]; then
    "$SCRIPT_DIR/fm-procevent.sh" register lavish "$id" -- \
      lavish-axi poll "$real" --agent-reply "$agent_reply" || exit 1
  else
    "$SCRIPT_DIR/fm-procevent.sh" register lavish "$id" -- \
      lavish-axi poll "$real" || exit 1
  fi
  printf 'armed: %s\n' "$id"
  printf 'artifact: %s\n' "$real"
}

cmd_retire() {
  local artifact=${1-} id
  [ -n "$artifact" ] || usage
  id=$(cmd_source_id "$artifact") || exit 1
  "$SCRIPT_DIR/fm-procevent.sh" retire "$id"
}

# Read one field of the response's leading `session:` block. Those fields are
# INDENTED, so each is read as the first indented match inside that block rather
# than an anchored whole-line match; anchoring on "^status:" silently never
# matches and treats every ended review as feedback. Confining the read to the
# leading block is also what stops prompt payload text from forging a session
# field. <field> is a fixed field name supplied by this adapter, never by input.
session_field() {  # <result-file> <field>
  awk -v field="$2" '
    $0 == "session:" { in_s=1; next }
    in_s && $0 !~ /^[[:space:]]/ { exit }
    in_s && $0 ~ "^[[:space:]]+" field ":[[:space:]]*[A-Za-z_]+[[:space:]]*$" {
      sub("^[[:space:]]+" field ":[[:space:]]*", ""); sub(/[[:space:]]*$/, ""); print; exit }
  ' "$1"
}

# Classify a completed result into a lifecycle state for the handler.
cmd_classify() {
  local file=${1-} status error_code error_message
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  status=$(session_field "$file" status)
  case "$status" in
    feedback) printf 'feedback\n'; return 0 ;;
    ended)    printf 'ended\n'; return 0 ;;
    waiting)  printf 'waiting\n'; return 0 ;;
  esac
  error_message=$(awk 'NR == 1 && /^error:[[:space:]]*/ { sub(/^error:[[:space:]]*/, ""); print }' "$file")
  error_code=$(awk '
    NR == 1 && /^error:[[:space:]]*/ { in_error=1; next }
    in_error && /^code:[[:space:]]*[A-Z_]+[[:space:]]*$/ {
      sub(/^code:[[:space:]]*/, ""); sub(/[[:space:]]*$/, ""); print; exit }
    in_error { exit }
  ' "$file")
  if [ "$error_code" = NOT_FOUND ] || [[ "$error_message" == "No active Lavish Editor session"* ]]; then
    printf 'missing\n'
  else
    printf 'unknown\n'
  fi
}

# Whether a captured result retires this registration before the runner can
# restart it. A returned feedback poll is finished even when its browser session
# remains open, and only its handler knows when the revision plus --agent-reply
# are ready. Ended and missing sessions also stop. Waiting and unknown output
# stay registered so ordinary recovery can reconcile an interrupted poll.
cmd_terminal() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  case "$(cmd_classify "$file")" in
    feedback|ended|missing) return 0 ;;
  esac
  return 1
}

case "${1-}" in
  arm)       shift; cmd_arm "$@" ;;
  retire)    shift; cmd_retire "$@" ;;
  source-id) shift; cmd_source_id "$@" ;;
  classify)  shift; cmd_classify "$@" ;;
  terminal)  shift; cmd_terminal "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
