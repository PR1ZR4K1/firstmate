#!/usr/bin/env bash
# Lavish adapter for the generic process-to-event runner.
#
# Usage:
#   fm-procevent-lavish.sh arm <artifact.html>
#   fm-procevent-lavish.sh arm <artifact.html> --after-sequence <n> --agent-reply <message>
#   fm-procevent-lavish.sh recover <artifact.html> --after-sequence <n> --delivery <delivered|not-delivered>
#   fm-procevent-lavish.sh classify <result-file>
#   fm-procevent-lavish.sh terminal <result-file>
#   fm-procevent-lavish.sh source-id <artifact.html>
#   fm-procevent-lavish.sh retire <artifact.html>
#
# arm        Validate Firstmate's private local artifact shape, then register one
#            blocking poll through the generic process-event runner. A reply
#            continuation is keyed to the exact feedback sequence that
#            authorized it. In one source-locked operation, arm stores the reply,
#            publishes its continuation registration, and durably acknowledges
#            that result; an interrupted partial operation leaves either the
#            result re-announceable or a registered command waiting for that
#            acknowledgement. The reply never enters retryable argv, and its
#            delivery is claimed before Lavish can POST it. The message must be
#            one non-empty line of at most 4096 bytes. A continuation
#            registration never replays a claimed reply.
# recover    Resolve a surfaced ambiguous continuation only after inspecting the
#            live local session. `delivered` arms a plain poll without reposting
#            the reply. `not-delivered` explicitly releases that one sequence for
#            one retry. Recovery allows only the matching ambiguous result to
#            remain unhandled, so it stays re-announceable until recovery has
#            succeeded and the handler acknowledges that exact result afterward.
# classify   Print the lifecycle state a handler should act on: feedback, ended,
#            waiting, missing, ambiguous, or unknown.
# terminal   Exit 0 for every completed feedback, ended, missing, or ambiguous
#            result so the current registration retires before handler work.
#            An ordinary open-session feedback result is explicitly re-armed by
#            its handler; waiting or unknown results stay armed for recovery.
#
# This adapter owns the Lavish-specific poll command, canonical source identity,
# complete prompt-preserving output normalization, sequence-keyed continuation
# receipts, response classification, and registration stop verdict.
# Ownership, durable capture, publication, and restart recovery belong to
# bin/fm-procevent.sh. bin/fm-lavish-review.sh owns the safe artifact check and
# the home-scoped loopback runtime envelope used by every poll.
#
# It wraps ONLY the currently published interface, verified against 0.1.50:
#   Usage: lavish-axi poll <html-file> [--agent-reply "..."]
# The blocking form has no timeout. Before generic capture, this adapter keeps a
# DOM snapshot only when its encoded value is at most 16384 bytes and otherwise
# replaces that nonessential field with a byte-count marker. Session, prompts,
# decision keys, answers, artifact failures, and next-step fields are preserved
# whole. The adapter requests a 16 MiB capture bound from the generic runner so
# the installed server's complete prompt payload survives after DOM bounding.
# An explicit FM_PROCEVENT_MAX_OUTPUT_BYTES still overrides that request.
#
# The adapter invokes only `bin/fm-lavish-review.sh run poll`; it never opens,
# exports, publishes, or shares an artifact.
#
# LOSS LIMITATION, stated plainly. The published poll destructively clears
# feedback before returning it. A result lost after that clearing and before the
# runner reads the process output is unrecoverable, and no Firstmate wrapper can
# close that source-side handoff window. Never describe this path as
# at-least-once, no-loss, or lossless. The only durability this proves is the
# runner's own: output that reached the runner is stored before it is announced.
# Reply delivery has a narrower guarantee: an interrupted claimed continuation
# is surfaced as ambiguous and never reposted until explicit inspected recovery.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LAVISH_CAPTURE_MAX_BYTES=16777216
LAVISH_DOM_MAX_BYTES=16384

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

hash_text() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  fi
}

# Canonical identity is physical, not the path string: Lavish itself keys a
# session on the realpath of the artifact. The path checker rejects symlinked or
# multiply linked artifacts and unsafe roots before returning the physical path.
cmd_source_id() {
  local artifact=${1-} real
  [ "$#" -eq 1 ] && [ -n "$artifact" ] || usage
  real=$(checked_artifact "$artifact") || exit 1
  printf 'lavish-%s\n' "$(hash_text "$real" | awk '{print substr($1,1,16)}')"
}

continuation_dir() { printf '%s/lavish-continuations\n' "$STATE"; }
continuation_base() { printf '%s/%s.%s\n' "$(continuation_dir)" "$1" "$2"; }
registration_file() { printf '%s/%s.source\n' "$(fm_procevent_registry_dir "$STATE")" "$1"; }

single_link_regular_file() {
  perl -e '
    my @s = lstat($ARGV[0]);
    exit 1 unless @s;
    exit 1 unless (($s[2] & 0170000) == 0100000);
    exit($s[3] == 1 ? 0 : 1);
  ' "$1"
}

ensure_continuation_dir() {
  local dir path
  dir=$(continuation_dir)
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    [ -d "$dir" ] && [ ! -L "$dir" ] \
      || die "unsafe Lavish continuation state directory: $dir"
  else
    (umask 077; mkdir -p "$dir") \
      || die "cannot create Lavish continuation state directory: $dir"
  fi
  chmod 700 "$dir" || die "cannot enforce private Lavish continuation state: $dir"
  while IFS= read -r -d '' path; do
    case "$path" in
      *.ready|*.claimed|*.delivered|*/.receipt.*|*/.poll-raw.*|*/.poll-normalized.*) ;;
      *) die "unexpected file in Lavish continuation state: $path" ;;
    esac
    single_link_regular_file "$path" \
      || die "unsafe Lavish continuation state file: $path"
    chmod 600 "$path" || die "cannot enforce private Lavish continuation state file: $path"
  done < <(find "$dir" -type f -print0 2>/dev/null)
  path=$(find "$dir" ! -type d ! -type f -print -quit 2>/dev/null) \
    || die "cannot inspect Lavish continuation state: $dir"
  [ -z "$path" ] || die "unsafe Lavish continuation state entry: $path"
}

receipt_read() {  # <file>; sets RECEIPT_ARTIFACT and RECEIPT_REPLY
  local file=$1 _extra
  [ -f "$file" ] && [ ! -L "$file" ] && single_link_regular_file "$file" || return 1
  {
    IFS= read -r RECEIPT_ARTIFACT \
      && IFS= read -r RECEIPT_REPLY \
      && ! IFS= read -r _extra
  } < "$file" || return 1
  [ -n "$RECEIPT_ARTIFACT" ] && [ -n "$RECEIPT_REPLY" ] || return 1
  case "$RECEIPT_ARTIFACT$RECEIPT_REPLY" in *$'\n'*) return 1 ;; esac
}

receipt_write_ready_locked() {  # <source-id> <sequence> <artifact> <reply>
  local id=$1 seq=$2 artifact=$3 reply=$4 base ready claimed delivered tmp dir
  dir=$(continuation_dir)
  base=$(continuation_base "$id" "$seq")
  ready="$base.ready"; claimed="$base.claimed"; delivered="$base.delivered"
  [ ! -e "$ready" ] && [ ! -L "$ready" ] \
    && [ ! -e "$claimed" ] && [ ! -L "$claimed" ] \
    && [ ! -e "$delivered" ] && [ ! -L "$delivered" ] || return 2
  tmp=$(umask 077; mktemp "$dir/.receipt.XXXXXX") || return 1
  if printf '%s\n%s\n' "$artifact" "$reply" > "$tmp" \
    && chmod 0600 "$tmp" \
    && mv -f -- "$tmp" "$ready"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

receipt_claim_locked() {  # <source-id> <sequence>; 0 new claim, 2 ambiguous, 1 error
  local base ready claimed delivered
  base=$(continuation_base "$1" "$2")
  ready="$base.ready"; claimed="$base.claimed"; delivered="$base.delivered"
  if [ -e "$claimed" ] || [ -L "$claimed" ] || [ -e "$delivered" ] || [ -L "$delivered" ]; then
    return 2
  fi
  receipt_read "$ready" || return 1
  mv -- "$ready" "$claimed" || return 1
  return 0
}

receipt_mark_delivered_locked() {  # <source-id> <sequence>
  local base claimed delivered
  base=$(continuation_base "$1" "$2")
  claimed="$base.claimed"; delivered="$base.delivered"
  receipt_read "$claimed" || return 1
  [ ! -e "$delivered" ] && [ ! -L "$delivered" ] || return 1
  mv -- "$claimed" "$delivered"
}

recovery_pending_is_exact_ambiguity() {  # <source-id> <reply-source-sequence>
  local id=$1 reply_sequence=$2 result adapter classification recorded_sequence count=0
  AMBIGUITY_RESULT_SEQUENCE=
  for result in "$(fm_procevent_inbox_dir "$STATE")/$id".*.result; do
    [ -f "$result" ] && [ ! -L "$result" ] || continue
    [ -f "${result%.result}.handled" ] && [ ! -L "${result%.result}.handled" ] && continue
    adapter=$(fm_procevent_result_adapter "$result" 2>/dev/null) || return 1
    [ "$adapter" = lavish ] || return 1
    classification=$(cmd_classify "$result") || return 1
    [ "$classification" = ambiguous ] || return 1
    recorded_sequence=$(continuation_field "$result" source_sequence)
    [ "$recorded_sequence" = "$reply_sequence" ] || return 1
    count=$((count + 1))
    [ "$count" -le 1 ] || return 1
    AMBIGUITY_RESULT_SEQUENCE=$(fm_procevent_result_sequence "$result")
  done
  return 0
}

source_has_other_unhandled_result() {  # <source-id> <allowed-sequence>
  local id=$1 allowed=$2 result sequence
  for result in "$(fm_procevent_inbox_dir "$STATE")/$id".*.result; do
    [ -f "$result" ] && [ ! -L "$result" ] || continue
    sequence=$(fm_procevent_result_sequence "$result")
    [ "$sequence" = "$allowed" ] && continue
    [ -f "${result%.result}.handled" ] && [ ! -L "${result%.result}.handled" ] || return 0
  done
  return 1
}

prior_result_is_lavish() {  # <source-id> <sequence>
  local id=$1 seq=$2 result adapter
  result="$(fm_procevent_inbox_dir "$STATE")/$id.$seq.result"
  [ -f "$result" ] && [ ! -L "$result" ] || return 1
  adapter=$(fm_procevent_result_adapter "$result" 2>/dev/null) || return 1
  [ "$adapter" = lavish ]
}

ambiguous_receipt_exists() {  # <source-id>
  local path
  for path in "$(continuation_dir)/$1".*.claimed; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      if ! { [ -f "$path" ] && [ ! -L "$path" ] && single_link_regular_file "$path"; }; then
        die "unsafe claimed Lavish reply receipt: $path"
      fi
      return 0
    fi
  done
  return 1
}

claim_allows_registration_locked() {  # <source-id>
  local state
  [ -e "$(fm_procevent_claim_path "$1")" ] || return 0
  fm_procevent_claim_state_locked "$1"
  state=$?
  [ "$state" -eq 1 ]
}

publish_poll_registration_locked() {  # <artifact> <source-id> <initial|sequence>
  local artifact=$1 id=$2 mode=$3 reg
  reg=$(registration_file "$id")
  [ ! -e "$reg" ] && [ ! -L "$reg" ] || return 2
  claim_allows_registration_locked "$id" || return 3
  fm_procevent_registration_publish_locked "$STATE" lavish "$id" \
    "$SCRIPT_DIR/fm-procevent-lavish.sh" _poll "$artifact" "$id" "$mode"
}

registration_matches_poll_locked() {  # <artifact> <source-id> <initial|sequence>
  local artifact=$1 id=$2 mode=$3 file line1 line2 line3 arg1 arg2 arg3 arg4 arg5 _extra
  file=$(registration_file "$id")
  [ -f "$file" ] && [ ! -L "$file" ] && single_link_regular_file "$file" || return 1
  {
    IFS= read -r line1 \
      && IFS= read -r line2 \
      && IFS= read -r line3 \
      && IFS= read -r arg1 \
      && IFS= read -r arg2 \
      && IFS= read -r arg3 \
      && IFS= read -r arg4 \
      && IFS= read -r arg5 \
      && ! IFS= read -r _extra
  } < "$file" || return 1
  [ "$line1" = adapter=lavish ] \
    && [ "$line2" = argc=5 ] \
    && [ "$line3" = argv: ] \
    && [ "$arg1" = "$SCRIPT_DIR/fm-procevent-lavish.sh" ] \
    && [ "$arg2" = _poll ] \
    && [ "$arg3" = "$artifact" ] \
    && [ "$arg4" = "$id" ] \
    && [ "$arg5" = "$mode" ]
}

validate_reply() {
  local reply=$1 bytes
  [ -n "$reply" ] || die "--agent-reply requires a non-empty message"
  case "$reply" in *$'\n'*) die "--agent-reply must be one line" ;; esac
  bytes=$(printf '%s' "$reply" | wc -c | tr -d '[:space:]')
  [ "$bytes" -le 4096 ] || die "--agent-reply cannot exceed 4096 bytes"
}

cmd_arm() {
  local artifact=${1-} real id seq='' reply='' receipt_status=0 publish_status=0 handled_status=3
  [ -n "$artifact" ] || usage
  shift
  case "$#" in
    0) ;;
    4)
      [ "$1" = --after-sequence ] && [ "$3" = --agent-reply ] || usage
      seq=$2; reply=$4
      case "$seq" in ''|*[!0-9]*) die "--after-sequence requires a positive integer" ;; esac
      [ "$seq" -gt 0 ] || die "--after-sequence requires a positive integer"
      validate_reply "$reply"
      ;;
    *) usage ;;
  esac
  command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
  real=$(checked_artifact "$artifact") || exit 1
  id=$(cmd_source_id "$real") || exit 1
  ensure_continuation_dir

  if [ -z "$seq" ]; then
    ambiguous_receipt_exists "$id" \
      && die "an ambiguous Lavish reply must be recovered explicitly before a plain poll is armed"
    fm_procevent_source_lock_acquire "$id" || die "cannot lock Lavish source: $id"
    publish_poll_registration_locked "$real" "$id" initial
    publish_status=$?
    fm_procevent_source_lock_release "$id"
    case "$publish_status" in
      0) ;;
      2) die "Lavish source is already armed: $id" ;;
      3) die "Lavish source still has a live or uncertain owner: $id" ;;
      *) die "cannot publish the Lavish poll registration: $id" ;;
    esac
  else
    prior_result_is_lavish "$id" "$seq" \
      || die "reply continuation requires the exact Lavish result sequence: $id $seq"
    source_has_other_unhandled_result "$id" "$seq" \
      && die "other Lavish results for this source must be handled before reply continuation"
    fm_procevent_source_lock_acquire "$id" || die "cannot lock Lavish source: $id"
    receipt_write_ready_locked "$id" "$seq" "$real" "$reply"
    receipt_status=$?
    if [ "$receipt_status" -eq 2 ]; then
      if receipt_read "$(continuation_base "$id" "$seq").ready" \
        && [ "$RECEIPT_ARTIFACT" = "$real" ] \
        && [ "$RECEIPT_REPLY" = "$reply" ]; then
        receipt_status=0
      fi
    fi
    if [ "$receipt_status" -eq 0 ]; then
      if [ -e "$(registration_file "$id")" ] || [ -L "$(registration_file "$id")" ]; then
        registration_matches_poll_locked "$real" "$id" "$seq" || publish_status=4
      else
        publish_poll_registration_locked "$real" "$id" "$seq"
        publish_status=$?
      fi
    fi
    if [ "$receipt_status" -eq 0 ] && [ "$publish_status" -eq 0 ]; then
      fm_procevent_mark_handled "$STATE" "$id" "$seq"
      handled_status=$?
      if [ "$handled_status" -ne 0 ] && [ "$handled_status" -ne 1 ]; then
        rm -f -- "$(registration_file "$id")"
        publish_status=5
      fi
    fi
    fm_procevent_source_lock_release "$id"
    case "$receipt_status" in
      0) ;;
      2) die "reply continuation already exists for Lavish result: $id $seq" ;;
      *) die "cannot create the private Lavish reply receipt: $id $seq" ;;
    esac
    case "$publish_status" in
      0) ;;
      2) die "Lavish source is already armed: $id" ;;
      3) die "Lavish source still has a live or uncertain owner: $id" ;;
      4) die "existing Lavish registration does not match this continuation: $id" ;;
      5) die "continuation stayed unarmed because result acknowledgement failed: $id $seq" ;;
      *) die "cannot publish the Lavish continuation registration: $id" ;;
    esac
  fi
  printf 'armed: %s\n' "$id"
  printf 'artifact: %s\n' "$real"
  if [ -n "$seq" ]; then
    printf 'after_sequence: %s\n' "$seq"
    case "$handled_status" in
      0) printf 'handled: %s %s\n' "$id" "$seq" ;;
      1) printf 'already-handled: %s %s\n' "$id" "$seq" ;;
    esac
  fi
}

sanitize_poll_output() {  # <raw> <normalized>
  perl - "$1" "$2" "$LAVISH_DOM_MAX_BYTES" <<'PL'
use strict;
use warnings;
use bytes;
my ($source, $dest, $limit) = @ARGV;
open(my $in, '<', $source) or exit 1;
open(my $out, '>', $dest) or exit 1;
while (my $line = <$in>) {
  if ($line =~ /^dom_snapshot:[ \t]*(.*?)(?:\r?\n)?$/s) {
    my $value = $1;
    if (length($value) > $limit) {
      print {$out} 'dom_snapshot: "[omitted by Firstmate; ', length($value), ' encoded bytes]"', "\n" or exit 1;
      next;
    }
  }
  print {$out} $line or exit 1;
}
close($in) or exit 1;
close($out) or exit 1;
PL
}

continuation_field() {  # <result-file> <field>
  awk -v field="$2" '
    $0 == "continuation:" { in_c=1; next }
    in_c && $0 !~ /^[[:space:]]/ { exit }
    in_c && $0 ~ "^[[:space:]]+" field ":[[:space:]]*[A-Za-z0-9_-]+[[:space:]]*$" {
      sub("^[[:space:]]+" field ":[[:space:]]*", ""); sub(/[[:space:]]*$/, ""); print; exit }
  ' "$1"
}

# Read one field of the response's leading `session:` block. Payload text cannot
# forge a session field because the read stops at the next top-level field.
session_field() {  # <result-file> <field>
  awk -v field="$2" '
    $0 == "session:" { in_s=1; next }
    in_s && $0 !~ /^[[:space:]]/ { exit }
    in_s && $0 ~ "^[[:space:]]+" field ":[[:space:]]*[A-Za-z_]+[[:space:]]*$" {
      sub("^[[:space:]]+" field ":[[:space:]]*", ""); sub(/[[:space:]]*$/, ""); print; exit }
  ' "$1"
}

emit_ambiguous() {  # <source-sequence> <reason-slug> [normalized-output]
  local seq=$1 reason=$2 normalized=${3-}
  printf 'continuation:\n'
  printf '  status: ambiguous\n'
  printf '  source_sequence: %s\n' "$seq"
  printf '  reason: %s\n' "$reason"
  if [ -n "$normalized" ] && [ -s "$normalized" ]; then
    cat "$normalized"
  fi
}

cmd_poll_internal() {
  local artifact=${1-} expected_id=${2-} mode=${3-} real id dir raw normalized rc status claim_status mark_status
  [ "$#" -eq 3 ] || usage
  case "$mode" in
    initial) ;;
    ''|*[!0-9]*) die "invalid internal continuation sequence" ;;
    *) [ "$mode" -gt 0 ] || die "invalid internal continuation sequence" ;;
  esac
  real=$(checked_artifact "$artifact") || exit 1
  id=$(cmd_source_id "$real") || exit 1
  [ "$id" = "$expected_id" ] || die "internal Lavish source identity changed"
  ensure_continuation_dir
  dir=$(continuation_dir)
  rm -f -- "$dir/.poll-raw.$id.$mode."* "$dir/.poll-normalized.$id.$mode."*
  raw=$(umask 077; mktemp "$dir/.poll-raw.$id.$mode.XXXXXX") || die "cannot stage Lavish poll output"
  normalized=$(umask 077; mktemp "$dir/.poll-normalized.$id.$mode.XXXXXX") || { rm -f -- "$raw"; die "cannot stage normalized Lavish output"; }
  POLL_RAW=$raw
  POLL_NORMALIZED=$normalized
  trap 'rm -f -- "$POLL_RAW" "$POLL_NORMALIZED"' EXIT

  if [ "$mode" = initial ]; then
    "$SCRIPT_DIR/fm-lavish-review.sh" run poll "$real" > "$raw"
    rc=$?
    sanitize_poll_output "$raw" "$normalized" || die "cannot normalize Lavish poll output"
    cat "$normalized"
    return "$rc"
  fi

  # A crash may publish the registration before the same source-locked arm
  # operation records handling. Waiting here consumes nothing externally; the
  # still-unhandled result keeps waking firstmate, and an idempotent repeat arm
  # commits the marker before this command claims or posts its reply.
  while ! fm_procevent_is_handled "$STATE" "$id" "$mode"; do
    sleep 0.1
  done
  fm_procevent_source_lock_acquire "$id" || die "cannot lock Lavish continuation: $id"
  receipt_claim_locked "$id" "$mode"
  claim_status=$?
  if [ "$claim_status" -eq 0 ]; then
    receipt_read "$(continuation_base "$id" "$mode").claimed" || claim_status=1
  fi
  fm_procevent_source_lock_release "$id"
  case "$claim_status" in
    0) ;;
    2) emit_ambiguous "$mode" reply-delivery-already-claimed; return 0 ;;
    *) emit_ambiguous "$mode" reply-receipt-unreadable; return 0 ;;
  esac
  [ "$RECEIPT_ARTIFACT" = "$real" ] \
    || { emit_ambiguous "$mode" reply-artifact-identity-changed; return 0; }

  "$SCRIPT_DIR/fm-lavish-review.sh" run poll "$real" --agent-reply "$RECEIPT_REPLY" > "$raw"
  rc=$?
  sanitize_poll_output "$raw" "$normalized" || { emit_ambiguous "$mode" poll-output-normalization-failed; return 0; }
  status=$(session_field "$normalized" status)
  if [ "$rc" -ne 0 ] || { [ "$status" != feedback ] && [ "$status" != ended ] && [ "$status" != waiting ]; }; then
    emit_ambiguous "$mode" reply-delivery-not-confirmed "$normalized"
    return 0
  fi

  mark_status=0
  fm_procevent_source_lock_acquire "$id" || mark_status=1
  if [ "$mark_status" -eq 0 ]; then
    receipt_mark_delivered_locked "$id" "$mode" || mark_status=1
    fm_procevent_source_lock_release "$id"
  fi
  if [ "$mark_status" -ne 0 ]; then
    emit_ambiguous "$mode" reply-delivery-receipt-not-committed "$normalized"
    return 0
  fi
  cat "$normalized"
}

cmd_recover() {
  local artifact=${1-} seq delivery real id base claimed delivered ready publish_status=0
  [ -n "$artifact" ] || usage
  shift
  [ "$#" -eq 4 ] && [ "$1" = --after-sequence ] && [ "$3" = --delivery ] || usage
  seq=$2; delivery=$4
  case "$seq" in ''|*[!0-9]*) die "--after-sequence requires a positive integer" ;; esac
  [ "$seq" -gt 0 ] || die "--after-sequence requires a positive integer"
  case "$delivery" in delivered|not-delivered) ;; *) die "--delivery must be delivered or not-delivered" ;; esac
  real=$(checked_artifact "$artifact") || exit 1
  id=$(cmd_source_id "$real") || exit 1
  ensure_continuation_dir
  recovery_pending_is_exact_ambiguity "$id" "$seq" \
    || die "only the matching Lavish ambiguity may remain unhandled during recovery"
  base=$(continuation_base "$id" "$seq")
  ready="$base.ready"; claimed="$base.claimed"; delivered="$base.delivered"

  fm_procevent_source_lock_acquire "$id" || die "cannot lock Lavish continuation: $id"
  if [ -e "$(registration_file "$id")" ] || [ -L "$(registration_file "$id")" ]; then
    fm_procevent_source_lock_release "$id"
    die "Lavish source is already armed: $id"
  fi
  if [ "$delivery" = delivered ]; then
    if [ -f "$claimed" ] && [ ! -L "$claimed" ]; then
      [ ! -e "$delivered" ] && [ ! -L "$delivered" ] \
        || { fm_procevent_source_lock_release "$id"; die "delivered reply receipt already exists: $id $seq"; }
      receipt_read "$claimed" || { fm_procevent_source_lock_release "$id"; die "ambiguous reply receipt is unreadable: $id $seq"; }
      [ "$RECEIPT_ARTIFACT" = "$real" ] \
        || { fm_procevent_source_lock_release "$id"; die "ambiguous reply artifact identity changed"; }
      mv -- "$claimed" "$delivered" || { fm_procevent_source_lock_release "$id"; die "cannot commit delivered reply recovery"; }
    elif ! { [ -f "$delivered" ] && [ ! -L "$delivered" ] && receipt_read "$delivered" && [ "$RECEIPT_ARTIFACT" = "$real" ]; }; then
      fm_procevent_source_lock_release "$id"
      die "no claimed reply exists for delivered recovery: $id $seq"
    fi
    publish_poll_registration_locked "$real" "$id" initial
    publish_status=$?
  else
    if ! { [ -f "$claimed" ] && [ ! -L "$claimed" ] && receipt_read "$claimed"; }; then
      fm_procevent_source_lock_release "$id"
      die "no claimed reply exists for not-delivered recovery: $id $seq"
    fi
    [ "$RECEIPT_ARTIFACT" = "$real" ] \
      || { fm_procevent_source_lock_release "$id"; die "ambiguous reply artifact identity changed"; }
    [ ! -e "$ready" ] && [ ! -L "$ready" ] \
      || { fm_procevent_source_lock_release "$id"; die "reply retry is already prepared: $id $seq"; }
    mv -- "$claimed" "$ready" \
      || { fm_procevent_source_lock_release "$id"; die "cannot release reply for inspected retry"; }
    publish_poll_registration_locked "$real" "$id" "$seq"
    publish_status=$?
    if [ "$publish_status" -ne 0 ]; then
      mv -- "$ready" "$claimed" 2>/dev/null || true
    fi
  fi
  fm_procevent_source_lock_release "$id"
  case "$publish_status" in
    0) ;;
    2) die "Lavish source is already armed: $id" ;;
    3) die "Lavish source still has a live or uncertain owner: $id" ;;
    *) die "cannot publish the recovered Lavish poll registration: $id" ;;
  esac
  printf 'recovered: %s\n' "$id"
  printf 'delivery: %s\n' "$delivery"
  printf 'after_sequence: %s\n' "$seq"
  [ -z "$AMBIGUITY_RESULT_SEQUENCE" ] \
    || printf 'acknowledge_ambiguity_sequence: %s\n' "$AMBIGUITY_RESULT_SEQUENCE"
}

cmd_retire() {
  local artifact=${1-} id
  [ "$#" -eq 1 ] && [ -n "$artifact" ] || usage
  id=$(cmd_source_id "$artifact") || exit 1
  "$SCRIPT_DIR/fm-procevent.sh" retire "$id"
}

cmd_classify() {
  local file=${1-} continuation_status status error_code error_message
  [ "$#" -eq 1 ] && [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  continuation_status=$(continuation_field "$file" status)
  [ "$continuation_status" != ambiguous ] || { printf 'ambiguous\n'; return 0; }
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

cmd_terminal() {
  local file=${1-}
  [ "$#" -eq 1 ] && [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  case "$(cmd_classify "$file")" in
    feedback|ended|missing|ambiguous) return 0 ;;
  esac
  return 1
}

cmd_output_limit() {
  [ "$#" -eq 0 ] || usage
  printf '%s\n' "$LAVISH_CAPTURE_MAX_BYTES"
}

case "${1-}" in
  arm)          shift; cmd_arm "$@" ;;
  recover)      shift; cmd_recover "$@" ;;
  retire)       shift; cmd_retire "$@" ;;
  source-id)    shift; cmd_source_id "$@" ;;
  classify)     shift; cmd_classify "$@" ;;
  terminal)     shift; cmd_terminal "$@" ;;
  output-limit) shift; cmd_output_limit "$@" ;;
  _poll)        shift; cmd_poll_internal "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
