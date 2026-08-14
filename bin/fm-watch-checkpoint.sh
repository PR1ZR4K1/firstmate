#!/usr/bin/env bash
# Run one bounded foreground watcher checkpoint for harnesses that should not
# rely on background-task completion to wake the model.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECONDS_ARG=${FM_CODEX_WATCH_CHECKPOINT:-180}

usage() {
  cat <<'EOF'
Usage: fm-watch-checkpoint.sh [--seconds <n>]

Run bin/fm-watch.sh in the foreground for a bounded checkpoint.
On an actionable watcher wake, pass through the watcher output and exit 0.
On a quiet checkpoint, print "checkpoint: no actionable wake within <n>s" and exit 124.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --seconds)
      [ "$#" -gt 1 ] || { echo "error: --seconds requires a value" >&2; exit 2; }
      SECONDS_ARG=$2
      shift 2
      ;;
    --seconds=*)
      SECONDS_ARG=${1#--seconds=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$SECONDS_ARG" in
  ''|*[!0-9]*) echo "error: --seconds must be a positive integer" >&2; exit 2 ;;
  0) echo "error: --seconds must be greater than zero" >&2; exit 2 ;;
esac

OUT=$(mktemp "${TMPDIR:-/tmp}/fm-watch-checkpoint.out.XXXXXX") || exit 1
ERR=$(mktemp "${TMPDIR:-/tmp}/fm-watch-checkpoint.err.XXXXXX") || {
  rm -f "$OUT"
  exit 1
}
trap 'rm -f "$OUT" "$ERR"' EXIT

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
CHECKPOINT_RECOVERY_MARKER="$STATE/.watcher-down"
CHECKPOINT_RECOVERY_BEFORE_PRESENT=0
if [ -e "$CHECKPOINT_RECOVERY_MARKER" ] || [ -L "$CHECKPOINT_RECOVERY_MARKER" ]; then
  CHECKPOINT_RECOVERY_BEFORE_PRESENT=1
fi
fm_recovery_marker_snapshot "$CHECKPOINT_RECOVERY_MARKER" || true
CHECKPOINT_RECOVERY_BEFORE=$FM_RECOVERY_MARKER_TOKEN

quiet_checkpoint_cleanup() {
  local lock="$STATE/.watch.lock" marker=$CHECKPOINT_RECOVERY_MARKER
  local i=0 token generation cleanup_status=0

  # The timeout can land before the watcher installs its EXIT trap. Acquire the
  # singleton ourselves after its process dies so the ordinary stale-owner guard
  # performs the only safe reclaim; never remove a live or inconclusive owner.
  while [ "$i" -lt 50 ]; do
    if fm_lock_try_acquire "$lock"; then
      fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
      fm_recovery_marker_snapshot "$marker" || true
      token=$FM_RECOVERY_MARKER_TOKEN
      # A quiet, intentionally bounded checkpoint is not a downtime episode.
      # Retire only the episode this checkpoint created, and only while the queue
      # lock proves that no actionable row raced the timeout. Pre-existing pending
      # or malformed recovery evidence belongs to another handling turn.
      if [ ! -s "$FM_WAKE_QUEUE" ]; then
        case "$CHECKPOINT_RECOVERY_BEFORE_PRESENT:$CHECKPOINT_RECOVERY_BEFORE:$token" in
          0::pending:*|1:acked:*:pending:*)
            generation=${token##*:}
            fm_recovery_marker_ack "$marker" "$generation" || cleanup_status=1
            ;;
        esac
      fi
      fm_lock_release "$FM_WAKE_QUEUE_LOCK"
      fm_lock_release "$lock"
      return "$cleanup_status"
    fi
    # A just-killed child may remain a short-lived zombie after the Perl timeout
    # parent exits. Give that exact owner time to disappear; a genuinely live
    # external watcher remains untouched and is accepted after the bounded wait.
    sleep 0.1
    i=$((i + 1))
  done
  fm_pid_alive "${FM_LOCK_HELD_PID:-}" && return 0
  return 1
}

run_with_perl_timeout() {
  perl -e '
    my $seconds = shift;
    my $pid = fork;
    die "fork failed\n" unless defined $pid;
    if (!$pid) {
      setpgrp(0, 0);
      exec @ARGV;
      die "exec failed: $!\n";
    }
    local $SIG{ALRM} = sub {
      kill "TERM", -$pid;
      select undef, undef, undef, 0.2;
      kill "KILL", -$pid;
      waitpid $pid, 0;
      exit 124;
    };
    alarm $seconds;
    waitpid $pid, 0;
    exit($? >> 8);
  ' "$SECONDS_ARG" "$SCRIPT_DIR/fm-watch.sh"
}

set +e
if command -v timeout >/dev/null 2>&1; then
  timeout "$SECONDS_ARG" "$SCRIPT_DIR/fm-watch.sh" >"$OUT" 2>"$ERR"
  RC=$?
elif command -v gtimeout >/dev/null 2>&1; then
  gtimeout "$SECONDS_ARG" "$SCRIPT_DIR/fm-watch.sh" >"$OUT" 2>"$ERR"
  RC=$?
else
  run_with_perl_timeout >"$OUT" 2>"$ERR"
  RC=$?
fi
set -e

if grep -E '^(signal:|stale:|check:|heartbeat($|:))' "$OUT" >/dev/null 2>&1; then
  cat "$OUT"
  [ ! -s "$ERR" ] || cat "$ERR" >&2
  exit 0
fi

if grep -E '^watcher: already running' "$OUT" "$ERR" >/dev/null 2>&1; then
  [ ! -s "$OUT" ] || cat "$OUT"
  [ ! -s "$ERR" ] || cat "$ERR" >&2
  echo "checkpoint: watcher is already running outside this foreground checkpoint" >&2
  exit 1
fi

if [ "$RC" -eq 124 ]; then
  if ! quiet_checkpoint_cleanup; then
    echo "checkpoint: timed-out watcher cleanup could not be confirmed" >&2
    exit 1
  fi
  printf 'checkpoint: no actionable wake within %ss\n' "$SECONDS_ARG"
  exit 124
fi

[ ! -s "$OUT" ] || cat "$OUT"
[ ! -s "$ERR" ] || cat "$ERR" >&2
exit "$RC"
