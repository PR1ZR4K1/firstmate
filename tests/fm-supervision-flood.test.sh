#!/usr/bin/env bash
# Behavioral regression for concurrent supervision notification batching.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
WAKE_LIB="$ROOT/bin/fm-wake-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-supervision-flood-tests)

seen_sig() {
  if [ "$(uname)" = Darwin ]; then
    stat -f '%z:%Fm' "$1" 2>/dev/null
  else
    stat -c '%s:%Y' "$1" 2>/dev/null
  fi
}

hash_text_local() {
  if command -v md5 >/dev/null 2>&1; then
    printf '%s' "$1" | md5 -q
  else
    printf '%s' "$1" | md5sum | cut -d' ' -f1
  fi
}

make_fleet_case() {
  local name=$1 dir fakebin
  dir=$(make_case "$name")
  fakebin="$dir/fakebin"
  mkdir -p "$dir/captures" "$dir/current"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  capture-pane)
    target=
    while [ "$#" -gt 0 ]; do
      if [ "$1" = -t ]; then
        target=${2:-}
        break
      fi
      shift
    done
    cat "${FM_FAKE_CAPTURE_DIR:?}/${target##*:}" 2>/dev/null || true
    exit 0
    ;;
  display-message)
    case "$*" in
      *pane_current_command*) printf 'zsh\n'; exit 0 ;;
    esac
    printf '%%1\n'
    exit 0
    ;;
  list-windows) exit 0 ;;
esac
exit 1
SH
  cat > "$fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
set -u
id=${1:-}
if [ -f "${FM_FAKE_STATE_DIR:?}/$id" ]; then
  cat "${FM_FAKE_STATE_DIR}/$id"
else
  printf 'state: unknown · source: none · fixture has no current state\n'
fi
SH
  chmod +x "$fakebin/tmux" "$fakebin/fm-crew-state.sh"
  printf '%s\n' "$dir"
}

start_watch() {  # <case-dir> <out> [extra env assignments...]
  local dir=$1 out=$2
  shift 2
  PATH="$dir/fakebin:$PATH" \
    FM_STATE_OVERRIDE="$dir/state" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_FAKE_CAPTURE_DIR="$dir/captures" \
    FM_FAKE_STATE_DIR="$dir/current" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$@" "$WATCH" > "$out" &
}

stop_watch() {
  kill "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}

assert_stays_live() {  # <pid> <tenths>
  local pid=$1 ticks=$2 i=0
  while [ "$i" -lt "$ticks" ]; do
    is_live_non_zombie "$pid" || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

wait_for_queue_rows() {  # <queue> <minimum> [tenths]
  local queue=$1 minimum=$2 ticks=${3:-80} i=0 rows
  while [ "$i" -lt "$ticks" ]; do
    rows=$(awk -F '\t' 'NF == 5 { n++ } END { print n + 0 }' "$queue" 2>/dev/null)
    [ "$rows" -ge "$minimum" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

begin_handling() {  # <state>
  local state=$1
  FM_STATE_OVERRIDE="$state" bash -c \
    '. "$1"; fm_recovery_marker_begin_handling "$2"' \
    _ "$WAKE_LIB" "$state/.watcher-down"
}

drain_to_files() {  # <state> <out> <err>
  FM_STATE_OVERRIDE="$1" "$DRAIN" > "$2" 2> "$3"
}

ack_pair_from() {  # <drain-stderr>
  local err=$1 sequence generation
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err" | tail -1)
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err" | tail -1)
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  printf '%s\t%s\n' "$sequence" "$generation"
}

ack_from_drain() {  # <state> <drain-stderr>
  local state=$1 pair sequence generation
  pair=$(ack_pair_from "$2") || return 1
  sequence=${pair%%$'\t'*}
  generation=${pair##*$'\t'}
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation"
}

prime_parked_task() {  # <case-dir> <id> <frame>
  local dir=$1 id=$2 frame=$3 state status window key hash
  state="$dir/state"
  status="$state/$id.status"
  window="fleet:fm-$id"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf 'window=%s\nkind=ship\nharness=pi\nbackend=tmux\n' "$window" > "$state/$id.meta"
  printf 'needs-decision [key=choice-%s]: choose A or B\n' "$id" > "$status"
  printf 'state: parked · source: run-step · parked at ask-user\n' > "$dir/current/$id"
  printf '%s\n' "$frame" > "$dir/captures/fm-$id"
  hash=$(hash_text_local "$frame")
  printf '%s' "$hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$(seen_sig "$status")" > "$state/.seen-${id}_status"
  cp "$status" "$state/.hb-surfaced-$id"
}

test_five_parked_decisions_stay_quiet_and_real_wedge_surfaces() {
  local dir state out pid round id frame window key hash
  dir=$(make_fleet_case parked-fleet)
  state="$dir/state"
  for id in task1 task2 task3 task4 task5; do
    prime_parked_task "$dir" "$id" "parked frame one for $id"
  done

  round=1
  while [ "$round" -le 2 ]; do
    if [ "$round" -eq 2 ]; then
      for id in task1 task2 task3 task4 task5; do
        frame="parked frame two for $id"
        printf '%s\n' "$frame" > "$dir/captures/fm-$id"
        window="fleet:fm-$id"
        key=$(printf '%s' "$window" | tr ':/.' '___')
        hash=$(hash_text_local "$frame")
        printf '%s' "$hash" > "$state/.hash-$key"
        printf '1\n' > "$state/.count-$key"
      done
    fi
    out="$dir/parked-$round.out"
    start_watch "$dir" "$out" env FM_STALE_ESCALATE_SECS=1
    pid=$!
    if ! assert_stays_live "$pid" 30; then
      stop_watch "$pid"
      fail "parked fleet emitted a repeated stale notification in round $round: $(cat "$out")"
    fi
    [ ! -s "$out" ] || { stop_watch "$pid"; fail "parked fleet printed a wake in round $round: $(cat "$out")"; }
    [ ! -s "$state/.wake-queue" ] || { stop_watch "$pid"; fail "parked fleet queued stale work in round $round"; }
    stop_watch "$pid"
    drain_to_files "$state" "$dir/stopped-$round.drain" "$dir/stopped-$round.err"
    ack_from_drain "$state" "$dir/stopped-$round.err" \
      || fail "the intentionally stopped parked watcher could not retire its empty recovery episode"
    round=$((round + 1))
  done

  # Absorption is permitted only after the matching captain-relevant event was
  # surfaced. Removing that receipt must make the same parked state actionable.
  rm -f "$state/.hb-surfaced-task1"
  frame='parked frame with no surfaced decision receipt'
  printf '%s\n' "$frame" > "$dir/captures/fm-task1"
  key=$(printf '%s' 'fleet:fm-task1' | tr ':/.' '___')
  printf '%s' "$(hash_text_local "$frame")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  out="$dir/first-decision.out"
  start_watch "$dir" "$out" env FM_STALE_ESCALATE_SECS=1
  pid=$!
  wait_for_exit "$pid" 50 || fail "a parked decision with no surfaced receipt was suppressed"
  grep -F 'stale: fleet:fm-task1' "$dir/first-decision.out" >/dev/null \
    || fail "the first parked-decision notification did not identify task1"
  drain_to_files "$state" "$dir/first-decision.drain" "$dir/first-decision.err"
  ack_from_drain "$state" "$dir/first-decision.err" \
    || fail "the first parked-decision notification could not be acknowledged"

  # One current worker is genuinely working on a static pane. It must retain the
  # existing wedge timer and escalation while the other four parked tasks stay quiet.
  printf 'state: working · source: run-step · validating (running)\n' > "$dir/current/task3"
  frame='static working frame for task3'
  printf '%s\n' "$frame" > "$dir/captures/fm-task3"
  window='fleet:fm-task3'
  key=$(printf '%s' "$window" | tr ':/.' '___')
  hash=$(hash_text_local "$frame")
  printf '%s' "$hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$hash" > "$state/.stale-$key"
  printf '%s\n' $(( $(date +%s) - 10 )) > "$state/.stale-since-$key"
  rm -f "$state/.wedge-escalations-$key"
  start_watch "$dir" "$dir/wedge.out" env FM_STALE_ESCALATE_SECS=2
  pid=$!
  wait_for_exit "$pid" 60 || fail "real working wedge did not escalate"
  grep -F "stale: $window" "$dir/wedge.out" | grep -F 'possible wedge' >/dev/null \
    || fail "real working wedge lost its actionable escalation: $(cat "$dir/wedge.out")"
  awk -F '\t' -v target="$window" '$3 == "stale" && $4 == target { found=1 } END { exit found ? 0 : 1 }' "$state/.wake-queue" \
    || fail "real working wedge was not durable"
  pass "five parked decisions do not repeat stale escalation, their first notification remains mandatory, and a real wedge still escalates"
}

test_five_turn_ends_form_one_bounded_delivery_and_ack_race_survives() {
  local dir state queue out pid id raw unique pair cutoff generation race_rows
  dir=$(make_fleet_case turnend-batch)
  state="$dir/state"
  queue="$state/.wake-queue"
  for id in task1 task2 task3 task4 task5; do
    printf 'kind=ship\nharness=pi\n' > "$state/$id.meta"
    : > "$state/$id.turn-ended"
  done

  start_watch "$dir" "$dir/first-batch.out"
  pid=$!
  wait_for_exit "$pid" 120 || fail "five initial turn ends did not close one watcher cycle"
  out=$(cat "$dir/first-batch.out")
  [ "$out" = 'signal: batch (5 sources queued; drain for durable identities)' ] \
    || fail "five-source notification was not one bounded batch: $out"
  [ "${#out}" -le 96 ] || fail "five-source notification exceeded its fixed bound"
  raw=$(awk -F '\t' 'NF == 5 { n++ } END { print n + 0 }' "$queue")
  unique=$(awk -F '\t' 'NF == 5 && $3 == "signal" { seen[$4]=1 } END { for (key in seen) n++; print n + 0 }' "$queue")
  [ "$raw" -eq 5 ] || fail "before/after grace scans duplicated the five durable sources ($raw rows)"
  [ "$unique" -eq 5 ] || fail "initial batch lost a durable source identity ($unique unique)"
  begin_handling "$state" || fail "fixture could not mark the first batch notification delivered"

  # The same five workers finish another near-simultaneous turn while the first
  # notification is waiting to be drained. They must join that handling generation
  # without closing a second watcher cycle or producing another injection.
  start_watch "$dir" "$dir/during-handling.out"
  pid=$!
  assert_stays_live "$pid" 30 || { stop_watch "$pid"; fail "successor watcher did not stay live before the concurrent turn ends"; }
  sleep 1
  for id in task1 task2 task3 task4 task5; do
    touch "$state/$id.turn-ended"
  done
  wait_for_queue_rows "$queue" 10 80 || { stop_watch "$pid"; fail "concurrent turn ends were not durably added to the active batch"; }
  is_live_non_zombie "$pid" || { stop_watch "$pid"; fail "concurrent turn ends closed another watcher cycle"; }
  [ ! -s "$dir/during-handling.out" ] || { stop_watch "$pid"; fail "concurrent turn ends emitted a duplicate notification: $(cat "$dir/during-handling.out")"; }

  drain_to_files "$state" "$dir/first.drain" "$dir/first.err"
  unique=$(awk -F '\t' 'NF == 5 && $3 == "signal" { seen[$4]=1 } END { for (key in seen) n++; print n + 0 }' "$dir/first.drain")
  [ "$unique" -eq 5 ] || { stop_watch "$pid"; fail "the bounded drain did not present all five source identities"; }
  pair=$(ack_pair_from "$dir/first.err") || { stop_watch "$pid"; fail "first batch drain omitted its acknowledgement"; }
  cutoff=${pair%%$'\t'*}
  generation=${pair##*$'\t'}

  # A source races after the drain snapshot but before acknowledgement. Its higher
  # sequence must survive, and acknowledgement must reopen one notification rather
  # than consume it or leave it hidden behind the handling generation.
  sleep 1
  touch "$state/task3.turn-ended"
  race_rows=$((cutoff + 1))
  while :; do
    raw=$(awk -F '\t' -v cutoff="$cutoff" 'NF == 5 && $2 ~ /^[0-9]+$/ && $2 > cutoff { n++ } END { print n + 0 }' "$queue")
    [ "$raw" -ge 1 ] && break
    race_rows=$((race_rows - 1))
    [ "$race_rows" -gt $((cutoff - 80)) ] || { stop_watch "$pid"; fail "racing turn end was not appended above the drain sequence"; }
    sleep 0.1
  done
  is_live_non_zombie "$pid" || { stop_watch "$pid"; fail "racing turn end emitted a duplicate pre-ack notification"; }
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$cutoff" \
    --recovery-generation "$generation" \
    || { stop_watch "$pid"; fail "first batch acknowledgement failed"; }

  wait_for_exit "$pid" 60 || fail "surviving racing source did not trigger one post-ack notification"
  [ "$(cat "$dir/during-handling.out")" = 'check: rearm-resurface' ] \
    || fail "post-ack notification was not the bounded recovery reason: $(cat "$dir/during-handling.out")"
  raw=$(awk -F '\t' 'NF == 5 { n++ } END { print n + 0 }' "$queue")
  [ "$raw" -eq 1 ] || fail "acknowledgement consumed or duplicated the racing source ($raw rows remain)"
  awk -F '\t' -v cutoff="$cutoff" '$2 > cutoff && $3 == "signal" && $4 == "task3.turn-ended" { found=1 } END { exit found ? 0 : 1 }' "$queue" \
    || fail "the exact racing source identity did not survive acknowledgement"

  drain_to_files "$state" "$dir/race.drain" "$dir/race.err"
  awk -F '\t' '$3 == "signal" && $4 == "task3.turn-ended" { found=1 } END { exit found ? 0 : 1 }' "$dir/race.drain" \
    || fail "the post-ack drain did not present the racing source"
  ack_from_drain "$state" "$dir/race.err" || fail "the racing source could not be acknowledged"
  [ ! -s "$queue" ] || fail "final acknowledgement left a source queued"
  case "$(cat "$state/.watcher-down" 2>/dev/null || true)" in
    acked:*) ;;
    *) fail "final acknowledgement did not retire the handled generation" ;;
  esac
  pass "five near-simultaneous turn ends produce one bounded delivery; every source and a drain/ack race remain durable"
}

test_single_worker_notification_is_unchanged() {
  local dir state expected out raw
  dir=$(make_fleet_case single-worker)
  state="$dir/state"
  printf 'kind=ship\nharness=pi\n' > "$state/solo.meta"
  : > "$state/solo.turn-ended"
  expected="signal: $state/solo.turn-ended"

  start_watch "$dir" "$dir/watch.out"
  wait_for_exit "$!" 100 || fail "single-worker turn end did not surface"
  out=$(cat "$dir/watch.out")
  [ "$out" = "$expected" ] || fail "single-worker reason changed: $out"
  raw=$(awk -F '\t' -v key='solo.turn-ended' -v payload="$expected" \
    'NF == 5 && $3 == "signal" && $4 == key && $5 == payload { n++ } END { print n + 0 }' "$state/.wake-queue")
  [ "$raw" -eq 1 ] || fail "single-worker notification no longer has one exact durable row"
  drain_to_files "$state" "$dir/drain.out" "$dir/drain.err"
  ack_from_drain "$state" "$dir/drain.err" || fail "single-worker notification could not be acknowledged"
  pass "ordinary single-worker notification reason and durable identity are unchanged"
}

test_five_parked_decisions_stay_quiet_and_real_wedge_surfaces
test_five_turn_ends_form_one_bounded_delivery_and_ack_race_survives
test_single_worker_notification_is_unchanged
