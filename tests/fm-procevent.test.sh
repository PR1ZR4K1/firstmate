#!/usr/bin/env bash
# Behavior tests for the generic process-to-event runner and its Lavish adapter.
#
# The source under test is a fake blocking process that returns only when its
# trigger file appears, so completion is a real process event and no test here
# depends on a discovery timer. The Lavish adapter is exercised through its own
# public commands against the currently published poll shape; no live Lavish
# server is started.
#
# Delivery is deliberately NOT asserted as at-least-once or lossless: the
# published Lavish poll clears feedback destructively before returning it, so
# the only durability under test is the runner's own - output that reached the
# runner is stored before it is announced.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-procevent-tests)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"

BLOCKER="$TMP_ROOT/blocker.sh"
cat > "$BLOCKER" <<'SH'
#!/usr/bin/env bash
# Blocks until the trigger exists, then emits its payload. Completion is the
# event; nothing here polls on a schedule.
trigger=$1; shift
while [ ! -e "$trigger" ]; do sleep 0.05; done
[ -n "${BLOCKER_STDERR:-}" ] && printf 'noise on stderr\n' >&2
[ -n "${BLOCKER_EXIT:-}" ] && exit "$BLOCKER_EXIT"
printf '%s\n' "$@"
SH
chmod +x "$BLOCKER"

pe() { FM_HOME="$1" "$ROOT/bin/fm-procevent.sh" "${@:2}"; }

# Every source this suite registers is tracked so teardown can stop its runner.
# A runner started by reconcile is detached and reparented, so a source that
# never completes outlives the suite unless it is retired explicitly - removing
# the fixture directory does not stop an already-running child.
PE_TRACKED=()
pe_register() {  # <home> <adapter> <source-id> -- <argv>...
  local home=$1 adapter=$2 id=$3
  shift 3
  PE_TRACKED+=("$home|$id")
  pe "$home" register "$adapter" "$id" "$@"
}

procevent_teardown() {
  local entry home seen=$'\n'
  for entry in ${PE_TRACKED[@]+"${PE_TRACKED[@]}"}; do
    home=${entry%%|*}
    case "$seen" in
      *$'\n'"$home"$'\n'*) continue ;;
    esac
    seen+="$home"$'\n'
    FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  done
  fm_test_cleanup
}
trap procevent_teardown EXIT
new_home() { mkdir -p "$1/state"; }
wake_payloads() { awk -F '\t' '{print $5}' "$1/state/.wake-queue" 2>/dev/null; }

first_result() {  # <home> <source-id>: print the first captured result, if any
  local g
  for g in "$1/state/procevent-inbox/$2".*.result; do
    [ -e "$g" ] || continue
    printf '%s\n' "$g"
    return 0
  done
  return 1
}

count_results() {  # <home> <source-id>
  local g n=0
  for g in "$1/state/procevent-inbox/$2".*.result; do
    [ -e "$g" ] && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

wait_for() {  # <file> [tries]
  local f=$1 n=${2:-100}
  for _ in $(seq 1 "$n"); do [ -s "$f" ] && return 0; sleep 0.1; done
  return 1
}

hold_source_lock() {  # <source-id> <ready-file> <release-file>
  local id=$1 ready=$2 release=$3 parent=$$
  FM_HOME="$TMP_ROOT/lock-helper-home" bash -c '
    . "$1/bin/fm-pr-lib.sh"
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-procevent-lib.sh"
    fm_procevent_source_lock_acquire "$2" || exit 1
    trap "fm_procevent_source_lock_release \"$2\"" EXIT
    printf "ready\n" > "$3"
    while [ ! -e "$4" ]; do
      kill -0 "$5" 2>/dev/null || exit 0
      sleep 0.02
    done
  ' _ "$ROOT" "$id" "$ready" "$release" "$parent" &
  HOLDER_PID=$!
}

hold_source_lock_then_handle() {  # <home> <source-id> <sequence> <ready-file> <release-file>
  local home=$1 id=$2 seq=$3 ready=$4 release=$5 parent=$$
  FM_HOME="$home" bash -c '
    . "$1/bin/fm-pr-lib.sh"
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-procevent-lib.sh"
    fm_procevent_source_lock_acquire "$2" || exit 1
    trap "fm_procevent_source_lock_release \"$2\"" EXIT
    printf "ready\n" > "$4"
    while [ ! -e "$5" ]; do
      kill -0 "$6" 2>/dev/null || exit 1
      sleep 0.02
    done
    fm_procevent_mark_handled "$3/state" "$2" "$7"
  ' _ "$ROOT" "$id" "$home" "$ready" "$release" "$parent" "$seq" &
  HOLDER_PID=$!
}

# --- inert with nothing configured ------------------------------------------
IDLE="$TMP_ROOT/idle"; new_home "$IDLE"
out=$(pe "$IDLE" list)
assert_contains "$out" "no sources registered" "an unconfigured home reports no sources"
out=$(pe "$IDLE" reconcile)
assert_contains "$out" "published=0 started=0" "reconcile is a no-op with nothing registered"
[ -z "$(ls -A "$IDLE/state" 2>/dev/null)" ] || fail "an unconfigured home generated state: $(ls -A "$IDLE/state")"
pass "no configured source means no generated state and no process"

sup=$(PATH="${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" bash -c \
  '. "$1/bin/fm-supervision-lib.sh"; fm_supervision_needed "$2" && echo yes || echo no' _ "$ROOT" "$IDLE/state")
assert_contains "$sup" no "an unconfigured home does not need supervision"

# --- a blocking source completes into exactly one normalized event ----------
H1="$TMP_ROOT/h1"; new_home "$H1"
TRIG="$TMP_ROOT/trigger-one"
out=$(pe_register "$H1" lavish src-one -- "$BLOCKER" "$TRIG" "payload one")
assert_contains "$out" "registered: src-one" "register records a source"

sup=$(PATH="${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" bash -c \
  '. "$1/bin/fm-supervision-lib.sh"; fm_supervision_needed "$2" && echo yes || echo no' _ "$ROOT" "$H1/state")
assert_contains "$sup" yes "a registered source needs supervision with no task metadata"

pe "$H1" reconcile >/dev/null
sleep 0.5
out=$(pe "$H1" start src-one)
assert_contains "$out" "already owned" "a duplicate start loses instead of running a second child"

: > "$TRIG"
wait_for "$H1/state/.wake-queue" || fail "no event was published after the source completed"
payload=$(wake_payloads "$H1")
assert_contains "$payload" "procevent lavish src-one 1" "completion publishes the committed result sequence"
assert_not_contains "$payload" "payload one" "source output never reaches the event line"
[ "$(printf '%s\n' "$payload" | grep -c .)" = 1 ] || fail "expected exactly one event, got: $payload"
pass "one blocking completion yields exactly one bounded normalized event"

RESULT=$(first_result "$H1" src-one || true)
[ -n "$RESULT" ] || fail "no durable result was captured"
mode=$(PATH="${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" bash -c \
  '. "$1/bin/fm-pr-lib.sh"; fm_pr_file_mode "$2"' _ "$ROOT" "$RESULT")
assert_contains "$mode" 600 "the captured result is private"
assert_grep 'payload one' "$RESULT" "the captured result holds the source output verbatim"
assert_grep 'lavish' "${RESULT%.result}.adapter" "the captured result retains its immutable adapter"
assert_absent "${RESULT%.result}.handled" "publication alone never marks a result handled"

# --- the public start boundary establishes generation group ownership -------
HPG="$TMP_ROOT/hpg"; new_home "$HPG"
DIRECT_TRIGGER="$TMP_ROOT/direct-trigger"
pe_register "$HPG" lavish direct-src -- "$BLOCKER" "$DIRECT_TRIGGER" "direct result" >/dev/null
pe "$HPG" start direct-src > "$TMP_ROOT/direct-start.out" &
direct_runner=$!
wait_for "$FM_PROCEVENT_CLAIM_ROOT/direct-src.claim" || fail "direct start never claimed its source"
direct_leader=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/direct-src.claim")
direct_group=$(ps -o pgid= -p "$direct_leader" 2>/dev/null | tr -d '[:space:]')
[ "$direct_group" = "$direct_leader" ] \
  || fail "direct start claimed before leading its process group: pid=$direct_leader pgid=$direct_group"
: > "$DIRECT_TRIGGER"
wait "$direct_runner" || fail "direct start failed after its source completed"
assert_contains "$(cat "$TMP_ROOT/direct-start.out")" "captured:" "direct start captures its result"
pass "public start owns the process group recorded by its claim"

SHARED_TRIGGER="$TMP_ROOT/shared-trigger"
SHARED_SIBLING="$TMP_ROOT/shared-sibling"
SHARED_LAUNCHER="$TMP_ROOT/shared-launcher.pl"
cat > "$SHARED_LAUNCHER" <<'PL'
use strict;
use warnings;
my ($sibling_file, @command) = @ARGV;
pipe(my $reader, my $writer) or exit 125;
defined(my $runner = fork) or exit 125;
if ($runner == 0) {
  close $reader;
  setpgrp(0, 0) or exit 125;
  print {$writer} "ready\n";
  close $writer;
  exec @command;
  exit 125;
}
close $writer;
<$reader>;
close $reader;
defined(my $sibling = fork) or exit 125;
if ($sibling == 0) {
  setpgrp(0, $runner) or exit 125;
  open(my $out, '>', $sibling_file) or exit 125;
  print {$out} "$$\n";
  close $out;
  sleep 30;
  exit 0;
}
waitpid($runner, 0);
waitpid($sibling, 0);
exit 0;
PL
pe_register "$HPG" lavish shared-src -- "$BLOCKER" "$SHARED_TRIGGER" "shared result" >/dev/null
FM_HOME="$HPG" perl "$SHARED_LAUNCHER" "$SHARED_SIBLING" \
  "$ROOT/bin/fm-procevent.sh" start shared-src > "$TMP_ROOT/shared-start.out" &
shared_launcher=$!
wait_for "$SHARED_SIBLING" || fail "shared caller group never started its unrelated sibling"
wait_for "$FM_PROCEVENT_CLAIM_ROOT/shared-src.claim" || fail "shared-group start never claimed its source"
shared_sibling=$(cat "$SHARED_SIBLING")
pe "$HPG" retire shared-src >/dev/null
kill -0 "$shared_sibling" 2>/dev/null || fail "retirement signaled an unrelated caller-group process"
kill "$shared_sibling" 2>/dev/null || true
wait "$shared_launcher" || fail "shared caller-group fixture did not exit cleanly"
pass "public start never claims an inherited caller process group"

# --- an unhandled result remains eligible for re-announcement on restart ----
# A result is durable but nothing has ever acknowledged handling it. Every
# reconcile call - not just the first restart after a crash - must keep
# re-announcing it, because the only thing that stops re-announcement is an
# explicit handled acknowledgement, never a prior publication.
H2="$TMP_ROOT/h2"; new_home "$H2"
future_status=0
future_out=$(pe "$H2" handled src-cut 7 2>&1) || future_status=$?
[ "$future_status" -ne 0 ] || fail "handled accepted a generation that has not been captured"
assert_contains "$future_out" "cannot durably record handling" "premature acknowledgement is rejected through the public interface"
assert_absent "$H2/state/procevent-inbox/src-cut.7.handled" "premature acknowledgement creates no marker for the future generation"
mkdir -p "$H2/state/procevent-inbox"
printf 'stranded result\n' > "$H2/state/procevent-inbox/src-cut.7.result"
printf 'lavish\n' > "$H2/state/procevent-inbox/src-cut.7.adapter"
chmod 0600 "$H2/state/procevent-inbox/src-cut.7.result" "$H2/state/procevent-inbox/src-cut.7.adapter"
out=$(pe "$H2" reconcile)
assert_contains "$out" "published=1" "a durably captured but unhandled result is announced after restart"
assert_contains "$(wake_payloads "$H2")" "procevent lavish src-cut 7" "durable adapter identity survives without a registration"
assert_absent "$H2/state/procevent-inbox/src-cut.7.handled" "recovery alone never marks the recovered result handled"
mv "$H2/state/.wake-queue" "$H2/state/.wake-queue.drained-1"
out=$(pe "$H2" reconcile)
assert_contains "$out" "published=1" "an unhandled result is re-announced on every reconcile, not only the first"
assert_contains "$(wake_payloads "$H2")" "procevent lavish src-cut 7" "the repeat wake preserves its deduplication identity"
[ "$(count_results "$H2" src-cut)" = 1 ] || fail "repeat re-announcement created a second durable copy"
mv "$H2/state/.wake-queue" "$H2/state/.wake-queue.drained-2"

ack_out=$(pe "$H2" handled src-cut 7)
assert_contains "$ack_out" "handled: src-cut 7" "the owned handling interface newly authorizes the first acknowledgement"
assert_present "$H2/state/procevent-inbox/src-cut.7.handled" "acknowledgement durably records handling"
before=$(wake_payloads "$H2" | wc -l | tr -d ' ')
out=$(pe "$H2" reconcile)
assert_contains "$out" "published=0" "reconcile stops re-announcing once a result is durably handled"
[ "$(wake_payloads "$H2" | wc -l | tr -d ' ')" = "$before" ] || fail "a handled result was announced again"

repeat_out=$(pe "$H2" handled src-cut 7)
assert_contains "$repeat_out" "already-handled: src-cut 7" "repeated acknowledgement is safe and reports the repeat distinctly"
case "$repeat_out" in
  handled:*) fail "a repeat acknowledgement re-authorized a second handled effect: $repeat_out" ;;
esac
pass "an unhandled result survives restart and repeat drains, and only explicit acknowledgement stops its re-announcement"

HRACE="$TMP_ROOT/hrace"; new_home "$HRACE"
mkdir -p "$HRACE/state/procevent-inbox"
printf 'racing result\n' > "$HRACE/state/procevent-inbox/racing-src.1.result"
printf 'lavish\n' > "$HRACE/state/procevent-inbox/racing-src.1.adapter"
chmod 0600 "$HRACE/state/procevent-inbox/racing-src.1.result" "$HRACE/state/procevent-inbox/racing-src.1.adapter"
RACE_PUBLISH_READY="$TMP_ROOT/race-publish-ready"
RACE_PUBLISH_RELEASE="$TMP_ROOT/race-publish-release"
RACE_RECONCILE_OUT="$TMP_ROOT/race-reconcile.out"
hold_source_lock_then_handle "$HRACE" racing-src 1 "$RACE_PUBLISH_READY" "$RACE_PUBLISH_RELEASE"
RACE_HANDLE_PID=$HOLDER_PID
wait_for "$RACE_PUBLISH_READY" || fail "publication race barrier did not acquire the source lock"
pe "$HRACE" reconcile > "$RACE_RECONCILE_OUT" &
RACE_RECONCILE_PID=$!
sleep 0.3
assert_absent "$HRACE/state/.wake-queue" "publication bypassed the source serialization boundary"
: > "$RACE_PUBLISH_RELEASE"
wait "$RACE_HANDLE_PID" || fail "publication race barrier could not record handling"
wait "$RACE_RECONCILE_PID" || fail "reconcile failed after the concurrent acknowledgement"
assert_contains "$(cat "$RACE_RECONCILE_OUT")" "published=0" "reconcile rechecks handling at the serialized publication boundary"
assert_present "$HRACE/state/procevent-inbox/racing-src.1.handled" "the concurrent acknowledgement remains durable"
assert_absent "$HRACE/state/.wake-queue" "an acknowledged result was appended after handling completed"
pass "publication cannot race a handled acknowledgement"

HPRIVATE="$TMP_ROOT/hprivate"; new_home "$HPRIVATE"
mkdir -p "$HPRIVATE/state/procevent-inbox"
printf 'private result\n' > "$HPRIVATE/state/procevent-inbox/private-src.1.result"
printf 'lavish\n' > "$HPRIVATE/state/procevent-inbox/private-src.1.adapter"
chmod 0600 "$HPRIVATE/state/procevent-inbox/private-src.1.result" "$HPRIVATE/state/procevent-inbox/private-src.1.adapter"
FAIL_CHMOD_BIN="$TMP_ROOT/fail-chmod-bin"
mkdir -p "$FAIL_CHMOD_BIN"
cat > "$FAIL_CHMOD_BIN/chmod" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$FAIL_CHMOD_BIN/chmod"
private_status=0
private_out=$(PATH="$FAIL_CHMOD_BIN:$PATH" pe "$HPRIVATE" handled private-src 1 2>&1) || private_status=$?
[ "$private_status" -ne 0 ] || fail "handled succeeded when private mode enforcement failed"
assert_contains "$private_out" "cannot durably record handling" "mode enforcement failure is reported through the owned interface"
assert_absent "$HPRIVATE/state/procevent-inbox/private-src.1.handled" "failed mode enforcement left an authoritative marker"
private_out=$(umask 000; pe "$HPRIVATE" handled private-src 1)
assert_contains "$private_out" "handled: private-src 1" "handling succeeds after private mode enforcement recovers"
private_mode=$(PATH="${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" bash -c \
  '. "$1/bin/fm-pr-lib.sh"; fm_pr_file_mode "$2"' _ "$ROOT" "$HPRIVATE/state/procevent-inbox/private-src.1.handled")
assert_contains "$private_mode" 600 "the handled marker is private under a permissive caller umask"
pass "handled acknowledgement creation is private and fails safely"

# --- a terminal result retires its source, on the adapter's verdict alone ----
# The runner must carry no notion of its own about what "done" means for a
# source. It asks that source's adapter whether the captured result ends the
# source, and retires the registration only on that adapter's verdict. Two
# fixture adapters isolate exactly that decision - one that ends on any result,
# one with no terminal knowledge at all - so the observed behavior is proven to
# follow the adapter rather than any condition built into the runner.
ADAPTER_ROOT="$TMP_ROOT/adapter-root"
mkdir -p "$ADAPTER_ROOT/bin"
cat > "$ADAPTER_ROOT/bin/fm-procevent-endnow.sh" <<'SH'
#!/usr/bin/env bash
# Fixture adapter: every captured result ends this source.
case "${1-}" in
  terminal) [ -f "${2-}" ] && exit 0 || exit 1 ;;
esac
exit 2
SH
cat > "$ADAPTER_ROOT/bin/fm-procevent-openended.sh" <<'SH'
#!/usr/bin/env bash
# Fixture adapter with no terminal knowledge at all: nothing ever ends it.
exit 2
SH
cat > "$ADAPTER_ROOT/bin/fm-procevent-applying.sh" <<'SH'
#!/usr/bin/env bash
case "${1-}" in
  autohandle)
    printf '%s %s\n' "$2" "$3" >> "$FM_HOME/state/applied"
    "$FM_PROCEVENT_UNDER_TEST" handled "$2" "$3" >/dev/null
    ;;
  *) exit 2 ;;
esac
SH
chmod +x "$ADAPTER_ROOT/bin/fm-procevent-endnow.sh" "$ADAPTER_ROOT/bin/fm-procevent-openended.sh" \
  "$ADAPTER_ROOT/bin/fm-procevent-applying.sh"

pe_adapter() {  # <home> <command>...: run the runner against the fixture adapters
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$ADAPTER_ROOT" FM_PROCEVENT_UNDER_TEST="$ROOT/bin/fm-procevent.sh" \
    FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" "$@"
}

HPUBLISH="$TMP_ROOT/hpublish"; new_home "$HPUBLISH"
PE_TRACKED+=("$HPUBLISH|publish-src")
pe_adapter "$HPUBLISH" register applying publish-src -- /bin/echo "apply after publish" >/dev/null
mkdir "$HPUBLISH/state/.wake-queue"
out=$(pe_adapter "$HPUBLISH" start publish-src 2>&1)
assert_contains "$out" "not-autohandled: publish-src" "failed publication did not suppress automatic application"
assert_absent "$HPUBLISH/state/applied" "a result was applied before its wake was durably published"
assert_absent "$HPUBLISH/state/procevent-inbox/publish-src.1.handled" "a result was acknowledged before its wake was durably published"
rmdir "$HPUBLISH/state/.wake-queue"
out=$(pe_adapter "$HPUBLISH" reconcile)
assert_contains "$out" "published=1" "the unpublished capture was not announced on later reconciliation"
assert_contains "$(wake_payloads "$HPUBLISH")" "procevent applying publish-src 1" "later reconciliation did not deliver the capture to a handler"
FM_HOME="$HPUBLISH" FM_PROCEVENT_UNDER_TEST="$ROOT/bin/fm-procevent.sh" \
  "$ADAPTER_ROOT/bin/fm-procevent-applying.sh" autohandle publish-src 1 \
    "$HPUBLISH/state/procevent-inbox/publish-src.1.result"
assert_grep 'publish-src 1' "$HPUBLISH/state/applied" "the handler could not apply the later announcement"
assert_present "$HPUBLISH/state/procevent-inbox/publish-src.1.handled" "the later handler application was not acknowledged"
pass "automatic application waits for durable publication and failed publication remains recoverable"

HTERM="$TMP_ROOT/hterm"; new_home "$HTERM"
PE_TRACKED+=("$HTERM|ends-src")
pe_adapter "$HTERM" register endnow ends-src -- /bin/echo "terminal payload" >/dev/null
out=$(pe_adapter "$HTERM" start ends-src)
assert_contains "$out" "captured:" "a terminal result is still captured durably"
assert_contains "$out" "retired: ends-src" "the runner reports the adapter-driven retirement"
assert_absent "$HTERM/state/procevent/ends-src.source" "an adapter-classified terminal result retires its registration"
assert_absent "$FM_PROCEVENT_CLAIM_ROOT/ends-src.claim" "terminal retirement releases this runner's own claim"
assert_contains "$(wake_payloads "$HTERM")" "procevent endnow ends-src 1" "the terminal result is still announced"
[ "$(count_results "$HTERM" ends-src)" = 1 ] || fail "terminal retirement lost or duplicated the captured result"
TERMINAL_RESULT=$(first_result "$HTERM" ends-src || true)
assert_grep 'terminal payload' "$TERMINAL_RESULT" "automatic retirement retains the captured output verbatim"
out=$(pe_adapter "$HTERM" reconcile)
assert_contains "$out" "started=0" "a retired terminal source is never restarted"
assert_contains "$out" "published=1" "an unhandled terminal result is still re-announced until acknowledged"
[ "$(count_results "$HTERM" ends-src)" = 1 ] || fail "a retired terminal source ran its poll again"
out=$(pe_adapter "$HTERM" retire ends-src)
assert_contains "$out" "retired: ends-src" "explicit retirement stays supported and idempotent after automatic retirement"
ack_out=$(pe_adapter "$HTERM" handled ends-src 1)
assert_contains "$ack_out" "handled: ends-src 1" "a terminal result is acknowledged through the owned interface"
out=$(pe_adapter "$HTERM" reconcile)
assert_contains "$out" "published=0" "an acknowledged terminal result stops being re-announced"
pass "an adapter-classified terminal result is captured once, announced, and retires its source automatically"

HOPEN="$TMP_ROOT/hopen"; new_home "$HOPEN"
PE_TRACKED+=("$HOPEN|open-src")
pe_adapter "$HOPEN" register openended open-src -- /bin/echo "open payload" >/dev/null
out=$(pe_adapter "$HOPEN" start open-src)
assert_contains "$out" "captured:" "a result from an adapter with no terminal verdict is captured"
assert_not_contains "$out" "retired:" "an adapter with no terminal verdict never retires its source"
assert_present "$HOPEN/state/procevent/open-src.source" "a source with no terminal verdict stays armed"
pe_adapter "$HOPEN" retire open-src >/dev/null
pass "a source stays armed unless its own adapter classifies the result terminal"

HREPLACE="$TMP_ROOT/hreplace"; new_home "$HREPLACE"
PE_TRACKED+=("$HREPLACE|replace-src")
OLD_TRIGGER="$TMP_ROOT/replace-old-trigger"
pe_adapter "$HREPLACE" register endnow replace-src -- "$BLOCKER" "$OLD_TRIGGER" "old terminal payload" >/dev/null
pe_adapter "$HREPLACE" start replace-src > "$TMP_ROOT/replace-old.out" 2>&1 &
replace_old_pid=$!
wait_for "$FM_PROCEVENT_CLAIM_ROOT/replace-src.claim" || fail "the old registration was never claimed"
pe_adapter "$HREPLACE" register openended replace-src -- /bin/echo "replacement payload" >/dev/null
touch "$OLD_TRIGGER"
wait "$replace_old_pid" || fail "the old terminal runner failed"
assert_contains "$(cat "$TMP_ROOT/replace-old.out")" "cannot retire terminal source" \
  "an old runner refuses to retire a replacement registration"
assert_present "$HREPLACE/state/procevent/replace-src.source" \
  "a replacement registration survives the old runner's terminal result"
assert_contains "$(cat "$HREPLACE/state/procevent/replace-src.source")" "adapter=openended" \
  "the surviving registration is the replacement generation"
out=$(pe_adapter "$HREPLACE" start replace-src)
assert_contains "$out" "captured:" "the replacement registration remains independently runnable"
[ "$(count_results "$HREPLACE" replace-src)" = 2 ] \
  || fail "the replacement generation did not capture its own result"
pe_adapter "$HREPLACE" retire replace-src >/dev/null
pass "terminal retirement preserves and releases a concurrently replaced registration"

HRETFAIL="$TMP_ROOT/hretfail"; new_home "$HRETFAIL"
PE_TRACKED+=("$HRETFAIL|retire-fail-src")
FAIL_RM_BIN=$(fm_fakebin "$TMP_ROOT/retire-fail-bin")
REAL_RM=$(command -v rm)
export REAL_RM
cat > "$FAIL_RM_BIN/rm" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in */retire-fail-src.source) exit 1 ;; esac
done
exec "$REAL_RM" "$@"
SH
chmod +x "$FAIL_RM_BIN/rm"
pe_adapter "$HRETFAIL" register endnow retire-fail-src -- /bin/echo "one terminal payload" >/dev/null
out=$(PATH="$FAIL_RM_BIN:$PATH" pe_adapter "$HRETFAIL" start retire-fail-src 2>&1)
assert_contains "$out" "cannot retire terminal source" "a failed registration removal is reported"
assert_present "$HRETFAIL/state/procevent/retire-fail-src.source" \
  "failed retirement preserves the exact registration"
assert_present "$FM_PROCEVENT_CLAIM_ROOT/retire-fail-src.claim" \
  "failed retirement preserves its terminal ownership claim"
out=$(PATH="$FAIL_RM_BIN:$PATH" pe_adapter "$HRETFAIL" reconcile)
assert_contains "$out" "started=0" "failed terminal retirement never restarts the poll"
[ "$(count_results "$HRETFAIL" retire-fail-src)" = 1 ] \
  || fail "failed retirement allowed recurring terminal capture"
pe_adapter "$HRETFAIL" reconcile >/dev/null
assert_absent "$HRETFAIL/state/procevent/retire-fail-src.source" \
  "repeated retirement removes the same registration once removal recovers"
assert_absent "$FM_PROCEVENT_CLAIM_ROOT/retire-fail-src.claim" \
  "the claim releases only after that registration is removed"
[ "$(count_results "$HRETFAIL" retire-fail-src)" = 1 ] \
  || fail "retirement recovery reran the terminal source"
pass "failed terminal retirement is fail-closed and idempotently recoverable"

# --- end-user-aligned regression: one Send & End, one captured result -------
# The dogfood defect: a real armed Lavish source received one human `Send & End`
# action, and the runner captured four results - the human's real feedback, then
# recurring empty ended sessions - because it kept restarting a source whose own
# adapter already knew the session had ended. Driven through the adapter's own
# arm command against a stand-in for the published poll shape, so registration,
# the runner, capture, publication, and retirement all run for real.
HLT="$TMP_ROOT/hlt"; new_home "$HLT"
LAVISH_BIN=$(fm_fakebin "$TMP_ROOT/lavish-stub")
LAVISH_POLL_COUNT="$LAVISH_BIN/poll-count"
cat > "$LAVISH_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
# Stand-in for `lavish-axi poll <file>` around a human `Send & End`: the final
# feedback is delivered exactly once carrying session_ended, and every later
# poll returns an empty ended session immediately.
count_file="$(dirname "$0")/poll-count"
n=$(cat "$count_file" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s\n' "$n" > "$count_file"
if [ "$n" = 1 ]; then
  printf 'session:\n  file: /review.html\n  status: feedback\n  session_ended: true\n  ended_by: user\nfeedback[1]{text}:\n  ship it\n'
else
  printf 'session:\n  file: /review.html\n  status: ended\n  ended_by: user\n'
fi
SH
chmod +x "$LAVISH_BIN/lavish-axi"
FM_HOME="$HLT" "$ROOT/bin/fm-lavish-review.sh" prepare "$HLT" send-and-end >/dev/null
REVIEW_ART="$HLT/.lavish/send-and-end/review.html"
printf '<h1>review</h1>\n' > "$REVIEW_ART"
lavish_id=$(FM_HOME="$HLT" "$ROOT/bin/fm-procevent-lavish.sh" source-id "$REVIEW_ART")
PE_TRACKED+=("$HLT|$lavish_id")
PATH="$LAVISH_BIN:$PATH" FM_HOME="$HLT" "$ROOT/bin/fm-procevent-lavish.sh" arm "$REVIEW_ART" >/dev/null
for _ in $(seq 1 6); do
  PATH="$LAVISH_BIN:$PATH" pe "$HLT" reconcile >/dev/null
  sleep 0.3
done
[ "$(cat "$LAVISH_POLL_COUNT")" = 1 ] \
  || fail "an ended review kept being polled: $(cat "$LAVISH_POLL_COUNT") polls for one Send & End"
[ "$(count_results "$HLT" "$lavish_id")" = 1 ] \
  || fail "one Send & End produced $(count_results "$HLT" "$lavish_id") captured results"
[ "$(wake_payloads "$HLT" | sort -u | grep -c .)" = 1 ] \
  || fail "one Send & End produced more than one distinct event: $(wake_payloads "$HLT" | sort -u)"
assert_contains "$(wake_payloads "$HLT")" "procevent lavish $lavish_id 1" "the human's final feedback is announced"
assert_absent "$HLT/state/procevent/$lavish_id.source" "the ended review source retires automatically"
assert_absent "$FM_PROCEVENT_CLAIM_ROOT/$lavish_id.claim" "the ended review releases its owned claim"
LAVISH_RESULT=$(first_result "$HLT" "$lavish_id" || true)
assert_grep 'ship it' "$LAVISH_RESULT" "automatic retirement retains the human's final feedback"
out=$(PATH="$LAVISH_BIN:$PATH" FM_HOME="$HLT" "$ROOT/bin/fm-procevent-lavish.sh" retire "$REVIEW_ART")
assert_contains "$out" "retired: $lavish_id" "explicit adapter retirement stays supported after automatic retirement"
pass "one Send & End yields exactly one captured result, automatic retirement, and no recurring poll"

# Ordinary feedback also retires its completed poll before handler work.
# Continuation is explicit and carries --agent-reply through the same durable
# callback, so no plain poll can race ahead and leave the browser waiting for an
# agent response that was never sent.
HLF="$TMP_ROOT/hlf"; new_home "$HLF"
LAVISH_REPLY_BIN=$(fm_fakebin "$TMP_ROOT/lavish-reply-stub")
LAVISH_REPLY_COUNT="$LAVISH_REPLY_BIN/reply-count"
LAVISH_REPLY_LOG="$LAVISH_REPLY_BIN/reply-argv"
cat > "$LAVISH_REPLY_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
count_file="$(dirname "$0")/reply-count"
log_file="$(dirname "$0")/reply-argv"
n=$(cat "$count_file" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s\n' "$n" > "$count_file"
printf -- 'call=%s\n' "$n" >> "$log_file"
for arg in "$@"; do printf '<%s>\n' "$arg" >> "$log_file"; done
if [ "$n" = 1 ]; then
  printf 'session:\n  file: /review.html\n  status: feedback\nprompts[1]{text}:\n  choose sample A\n'
else
  printf 'session:\n  file: /review.html\n  status: ended\n  ended_by: agent\n'
fi
SH
chmod +x "$LAVISH_REPLY_BIN/lavish-axi"
FM_HOME="$HLF" "$ROOT/bin/fm-lavish-review.sh" prepare "$HLF" ordinary-feedback >/dev/null
REPLY_ART="$HLF/.lavish/ordinary-feedback/review.html"
printf '<h1>ordinary feedback</h1>\n' > "$REPLY_ART"
reply_id=$(FM_HOME="$HLF" "$ROOT/bin/fm-procevent-lavish.sh" source-id "$REPLY_ART")
PE_TRACKED+=("$HLF|$reply_id")
PATH="$LAVISH_REPLY_BIN:$PATH" FM_HOME="$HLF" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$REPLY_ART" >/dev/null
PATH="$LAVISH_REPLY_BIN:$PATH" pe "$HLF" reconcile >/dev/null
for _ in $(seq 1 60); do
  [ "$(count_results "$HLF" "$reply_id")" -ge 1 ] && break
  sleep 0.1
done
[ "$(count_results "$HLF" "$reply_id")" = 1 ] \
  || fail "ordinary feedback was not captured exactly once"
for _ in $(seq 1 60); do
  [ ! -e "$HLF/state/procevent/$reply_id.source" ] && break
  sleep 0.1
done
assert_absent "$HLF/state/procevent/$reply_id.source" \
  "ordinary feedback left a plain poll registration armed before handler work"
assert_absent "$HLF/state/procevent-inbox/$reply_id.1.handled" \
  "feedback was acknowledged before its revision and reply continuation were ready"

reply_arm_out=$(PATH="$LAVISH_REPLY_BIN:$PATH" FM_HOME="$HLF" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$REPLY_ART" \
  --after-sequence 1 --agent-reply "Applied the sample choice.")
assert_contains "$reply_arm_out" "handled: $reply_id 1" \
  "sequence-keyed arm did not atomically acknowledge the revised feedback"
assert_present "$HLF/state/procevent-inbox/$reply_id.1.handled" \
  "reply continuation publication left its source feedback unacknowledged"
assert_no_grep 'Applied the sample choice.' "$HLF/state/procevent/$reply_id.source" \
  "retryable source argv stored the agent reply"
assert_grep '_poll' "$HLF/state/procevent/$reply_id.source" \
  "Lavish continuation did not route through the adapter-owned receipt command"
PATH="$LAVISH_REPLY_BIN:$PATH" pe "$HLF" reconcile >/dev/null
for _ in $(seq 1 60); do
  [ "$(count_results "$HLF" "$reply_id")" -ge 2 ] && break
  sleep 0.1
done
[ "$(count_results "$HLF" "$reply_id")" = 2 ] \
  || fail "the handler-mediated Lavish re-arm did not capture its next result"
assert_grep '<poll>' "$LAVISH_REPLY_LOG" "Lavish callback invokes only the poll subcommand"
assert_grep '<--agent-reply>' "$LAVISH_REPLY_LOG" "Lavish continuation carries the agent-reply flag"
assert_grep '<Applied the sample choice.>' "$LAVISH_REPLY_LOG" "Lavish continuation preserves the reply as one argv element"
assert_no_grep '<share>' "$LAVISH_REPLY_LOG" "Lavish callback must never publish or share"
[ "$(cat "$LAVISH_REPLY_COUNT")" = 2 ] \
  || fail "explicit continuation ran an unexpected number of polls: $(cat "$LAVISH_REPLY_COUNT")"
assert_present "$HLF/state/lavish-continuations/$reply_id.1.delivered" \
  "successful continuation did not retain its sequence-keyed delivery receipt"
reply_receipt_mode=$(PATH="${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" bash -c \
  '. "$1/bin/fm-pr-lib.sh"; fm_pr_file_mode "$2"' _ "$ROOT" \
  "$HLF/state/lavish-continuations/$reply_id.1.delivered")
assert_contains "$reply_receipt_mode" 600 "Lavish reply receipt is not owner-only"
pass "ordinary feedback stops before handler work and resumes through a sequence-keyed reply receipt"

# Reproduce the registration-before-acknowledgement crash cut directly from its
# durable records. The continuation command must wait without touching Lavish,
# while repeating the same public arm commits handling and releases it exactly
# once instead of losing the continuation after the prior result was drained.
HARM="$TMP_ROOT/harm-cut"; new_home "$HARM"
LAVISH_ARM_BIN=$(fm_fakebin "$TMP_ROOT/lavish-arm-cut-stub")
LAVISH_ARM_COUNT="$LAVISH_ARM_BIN/arm-count"
cat > "$LAVISH_ARM_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
count_file="$(dirname "$0")/arm-count"
n=$(cat "$count_file" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s\n' "$n" > "$count_file"
printf 'session:\n  file: /review.html\n  status: ended\n  ended_by: agent\n'
SH
chmod +x "$LAVISH_ARM_BIN/lavish-axi"
FM_HOME="$HARM" "$ROOT/bin/fm-lavish-review.sh" prepare "$HARM" arm-cut >/dev/null
ARM_ART="$HARM/.lavish/arm-cut/review.html"
printf '<h1>arm cut</h1>\n' > "$ARM_ART"
arm_id=$(FM_HOME="$HARM" "$ROOT/bin/fm-procevent-lavish.sh" source-id "$ARM_ART")
PE_TRACKED+=("$HARM|$arm_id")
mkdir -p "$HARM/state/procevent-inbox" "$HARM/state/lavish-continuations"
printf 'session:\n  file: /review.html\n  status: feedback\n' \
  > "$HARM/state/procevent-inbox/$arm_id.1.result"
printf 'lavish\n' > "$HARM/state/procevent-inbox/$arm_id.1.adapter"
printf '%s\n%s\n' "$ARM_ART" 'Resume after durable cut.' \
  > "$HARM/state/lavish-continuations/$arm_id.1.ready"
chmod 0600 "$HARM/state/procevent-inbox/$arm_id.1.result" \
  "$HARM/state/procevent-inbox/$arm_id.1.adapter" \
  "$HARM/state/lavish-continuations/$arm_id.1.ready"
FM_HOME="$HARM" "$ROOT/bin/fm-procevent.sh" register lavish "$arm_id" -- \
  "$ROOT/bin/fm-procevent-lavish.sh" _poll "$ARM_ART" "$arm_id" 1 >/dev/null
PATH="$LAVISH_ARM_BIN:$PATH" pe "$HARM" reconcile >/dev/null
wait_for "$FM_PROCEVENT_CLAIM_ROOT/$arm_id.claim" || fail "partial arm registration never started its waiting command"
sleep 0.3
assert_absent "$LAVISH_ARM_COUNT" \
  "partial arm invoked Lavish before its source result was durably handled"
arm_cut_out=$(PATH="$LAVISH_ARM_BIN:$PATH" FM_HOME="$HARM" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$ARM_ART" \
  --after-sequence 1 --agent-reply 'Resume after durable cut.')
assert_contains "$arm_cut_out" "handled: $arm_id 1" \
  "idempotent arm recovery did not commit the missing acknowledgement"
for _ in $(seq 1 100); do
  [ "$(count_results "$HARM" "$arm_id")" -ge 2 ] && break
  sleep 0.1
done
[ "$(cat "$LAVISH_ARM_COUNT")" = 1 ] \
  || fail "recovered arm cut did not invoke exactly one continuation poll"
assert_present "$HARM/state/lavish-continuations/$arm_id.1.delivered" \
  "recovered arm cut did not commit its delivered receipt"
pass "a registration-before-acknowledgement cut remains re-announceable and resumes once"

# A large DOM snapshot precedes prompts in Lavish 0.1.50 output. The adapter must
# bound that nonessential field before the generic capture bound while retaining
# a complete decision payload even when that payload itself exceeds 1 MiB.
HBIG="$TMP_ROOT/hbig"; new_home "$HBIG"
LAVISH_BIG_BIN=$(fm_fakebin "$TMP_ROOT/lavish-big-stub")
cat > "$LAVISH_BIG_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
printf 'session:\n  file: /review.html\n  status: feedback\n'
perl -e 'print "dom_snapshot: ", "d" x 1200000, "\n"'
printf 'prompts[1]{text}:\n  '
perl -e 'print "p" x 1200000, " decision-tail\n"'
printf 'next_step: apply the complete keyed decision\n'
SH
chmod +x "$LAVISH_BIG_BIN/lavish-axi"
FM_HOME="$HBIG" "$ROOT/bin/fm-lavish-review.sh" prepare "$HBIG" oversized-feedback >/dev/null
BIG_ART="$HBIG/.lavish/oversized-feedback/review.html"
printf '<h1>oversized feedback</h1>\n' > "$BIG_ART"
big_id=$(FM_HOME="$HBIG" "$ROOT/bin/fm-procevent-lavish.sh" source-id "$BIG_ART")
PE_TRACKED+=("$HBIG|$big_id")
PATH="$LAVISH_BIG_BIN:$PATH" FM_HOME="$HBIG" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$BIG_ART" >/dev/null
PATH="$LAVISH_BIG_BIN:$PATH" pe "$HBIG" reconcile >/dev/null
for _ in $(seq 1 100); do
  [ "$(count_results "$HBIG" "$big_id")" -ge 1 ] && break
  sleep 0.1
done
BIG_RESULT=$(first_result "$HBIG" "$big_id" || true)
[ -n "$BIG_RESULT" ] || fail "oversized Lavish feedback was not captured"
[ "$(wc -c < "$BIG_RESULT" | tr -d ' ')" -gt 1048576 ] \
  || fail "complete oversized prompt data was not retained"
assert_grep 'dom_snapshot: "[omitted by Firstmate; 1200000 encoded bytes]"' "$BIG_RESULT" \
  "oversized DOM data was not bounded independently"
assert_grep 'decision-tail' "$BIG_RESULT" \
  "the decision tail after an oversized DOM snapshot was truncated"
assert_grep 'next_step: apply the complete keyed decision' "$BIG_RESULT" \
  "fields after the complete oversized prompt were lost"
assert_contains "$(FM_HOME="$HBIG" "$ROOT/bin/fm-procevent-lavish.sh" classify "$BIG_RESULT")" feedback \
  "normalized oversized feedback no longer classified as feedback"
pass "oversized DOM data is bounded before complete prompt and decision capture"

# The interruption cut after a reply is claimed must never replay that reply.
# A replacement runner emits one ambiguous result, and inspected delivered
# recovery continues with a plain poll that cannot repost the reply.
HREPLAY="$TMP_ROOT/hreplay"; new_home "$HREPLAY"
LAVISH_REPLAY_BIN=$(fm_fakebin "$TMP_ROOT/lavish-replay-stub")
LAVISH_REPLAY_COUNT="$LAVISH_REPLAY_BIN/replay-count"
LAVISH_REPLAY_LOG="$LAVISH_REPLAY_BIN/replay-argv"
LAVISH_REPLAY_STARTED="$LAVISH_REPLAY_BIN/reply-started"
cat > "$LAVISH_REPLAY_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
root=$(dirname "$0")
count_file="$root/replay-count"
log_file="$root/replay-argv"
n=$(cat "$count_file" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s\n' "$n" > "$count_file"
printf 'call=%s\n' "$n" >> "$log_file"
for arg in "$@"; do printf '<%s>\n' "$arg" >> "$log_file"; done
if [ "$n" = 1 ]; then
  printf 'started\n' > "$root/reply-started"
  sleep 30
else
  printf 'session:\n  file: /review.html\n  status: ended\n  ended_by: agent\n'
fi
SH
chmod +x "$LAVISH_REPLAY_BIN/lavish-axi"
FM_HOME="$HREPLAY" "$ROOT/bin/fm-lavish-review.sh" prepare "$HREPLAY" replay-cut >/dev/null
REPLAY_ART="$HREPLAY/.lavish/replay-cut/review.html"
printf '<h1>reply replay cut</h1>\n' > "$REPLAY_ART"
replay_id=$(FM_HOME="$HREPLAY" "$ROOT/bin/fm-procevent-lavish.sh" source-id "$REPLAY_ART")
PE_TRACKED+=("$HREPLAY|$replay_id")
mkdir -p "$HREPLAY/state/procevent-inbox"
printf 'session:\n  file: /review.html\n  status: feedback\nprompts[1]{text}:\n  first choice\n' \
  > "$HREPLAY/state/procevent-inbox/$replay_id.1.result"
printf 'lavish\n' > "$HREPLAY/state/procevent-inbox/$replay_id.1.adapter"
chmod 0600 "$HREPLAY/state/procevent-inbox/$replay_id.1.result" \
  "$HREPLAY/state/procevent-inbox/$replay_id.1.adapter"
pe "$HREPLAY" handled "$replay_id" 1 >/dev/null
PATH="$LAVISH_REPLAY_BIN:$PATH" FM_HOME="$HREPLAY" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$REPLAY_ART" \
  --after-sequence 1 --agent-reply "Applied replay-safe choice." >/dev/null
assert_no_grep 'Applied replay-safe choice.' "$HREPLAY/state/procevent/$replay_id.source" \
  "reply content leaked into retryable continuation argv"
PATH="$LAVISH_REPLAY_BIN:$PATH" pe "$HREPLAY" reconcile >/dev/null
wait_for "$LAVISH_REPLAY_STARTED" || fail "reply interruption fixture never began delivery"
wait_for "$FM_PROCEVENT_CLAIM_ROOT/$replay_id.claim" || fail "reply interruption fixture never claimed its source"
replay_leader=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/$replay_id.claim")
case "$replay_leader" in ''|*[!0-9]*) fail "reply interruption fixture has no runner leader" ;; esac
kill -KILL -"$replay_leader" 2>/dev/null || fail "could not interrupt the claimed reply generation"
for _ in $(seq 1 50); do kill -0 -"$replay_leader" 2>/dev/null || break; sleep 0.1; done
kill -0 -"$replay_leader" 2>/dev/null && fail "interrupted reply generation remained live"
PATH="$LAVISH_REPLAY_BIN:$PATH" pe "$HREPLAY" reconcile >/dev/null
for _ in $(seq 1 100); do
  [ "$(count_results "$HREPLAY" "$replay_id")" -ge 2 ] && break
  sleep 0.1
done
[ "$(cat "$LAVISH_REPLAY_COUNT")" = 1 ] \
  || fail "interruption replayed the claimed reply: $(cat "$LAVISH_REPLAY_COUNT") calls"
REPLAY_AMBIGUOUS="$HREPLAY/state/procevent-inbox/$replay_id.2.result"
assert_present "$REPLAY_AMBIGUOUS" "interrupted reply did not surface a durable ambiguity"
assert_contains "$(FM_HOME="$HREPLAY" "$ROOT/bin/fm-procevent-lavish.sh" classify "$REPLAY_AMBIGUOUS")" ambiguous \
  "interrupted claimed reply did not classify as ambiguous"
for _ in $(seq 1 60); do
  [ ! -e "$HREPLAY/state/procevent/$replay_id.source" ] && break
  sleep 0.1
done
assert_absent "$HREPLAY/state/procevent/$replay_id.source" \
  "ambiguous continuation remained armed for automatic replay"
replay_recover_out=$(PATH="$LAVISH_REPLAY_BIN:$PATH" FM_HOME="$HREPLAY" \
  "$ROOT/bin/fm-procevent-lavish.sh" recover "$REPLAY_ART" \
  --after-sequence 1 --delivery delivered)
assert_contains "$replay_recover_out" "acknowledge_ambiguity_sequence: 2" \
  "delivered recovery did not retain the ambiguity acknowledgement handoff"
pe "$HREPLAY" handled "$replay_id" 2 >/dev/null
PATH="$LAVISH_REPLAY_BIN:$PATH" pe "$HREPLAY" reconcile >/dev/null
for _ in $(seq 1 100); do
  [ "$(count_results "$HREPLAY" "$replay_id")" -ge 3 ] && break
  sleep 0.1
done
[ "$(cat "$LAVISH_REPLAY_COUNT")" = 2 ] \
  || fail "delivered recovery ran an unexpected number of polls"
[ "$(grep -F -c '<--agent-reply>' "$LAVISH_REPLAY_LOG" || true)" = 1 ] \
  || fail "delivered recovery reposted the agent reply"
assert_present "$HREPLAY/state/lavish-continuations/$replay_id.1.delivered" \
  "delivered recovery did not preserve its durable sequence receipt"
pass "an interrupted claimed reply surfaces ambiguity and never replays automatically"

# The opposite inspected outcome also stays explicit: not-delivered recovery
# releases exactly the claimed sequence for one adapter-owned retry.
HRETRY="$TMP_ROOT/hretry"; new_home "$HRETRY"
LAVISH_RETRY_BIN=$(fm_fakebin "$TMP_ROOT/lavish-retry-stub")
LAVISH_RETRY_COUNT="$LAVISH_RETRY_BIN/retry-count"
LAVISH_RETRY_LOG="$LAVISH_RETRY_BIN/retry-argv"
cat > "$LAVISH_RETRY_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
root=$(dirname "$0")
count_file="$root/retry-count"
log_file="$root/retry-argv"
n=$(cat "$count_file" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s\n' "$n" > "$count_file"
printf 'call=%s\n' "$n" >> "$log_file"
for arg in "$@"; do printf '<%s>\n' "$arg" >> "$log_file"; done
if [ "$n" = 1 ]; then
  exit 7
fi
printf 'session:\n  file: /review.html\n  status: ended\n  ended_by: agent\n'
SH
chmod +x "$LAVISH_RETRY_BIN/lavish-axi"
FM_HOME="$HRETRY" "$ROOT/bin/fm-lavish-review.sh" prepare "$HRETRY" explicit-retry >/dev/null
RETRY_ART="$HRETRY/.lavish/explicit-retry/review.html"
printf '<h1>explicit retry</h1>\n' > "$RETRY_ART"
retry_id=$(FM_HOME="$HRETRY" "$ROOT/bin/fm-procevent-lavish.sh" source-id "$RETRY_ART")
PE_TRACKED+=("$HRETRY|$retry_id")
mkdir -p "$HRETRY/state/procevent-inbox"
printf 'session:\n  file: /review.html\n  status: feedback\n' \
  > "$HRETRY/state/procevent-inbox/$retry_id.1.result"
printf 'lavish\n' > "$HRETRY/state/procevent-inbox/$retry_id.1.adapter"
chmod 0600 "$HRETRY/state/procevent-inbox/$retry_id.1.result" \
  "$HRETRY/state/procevent-inbox/$retry_id.1.adapter"
pe "$HRETRY" handled "$retry_id" 1 >/dev/null
PATH="$LAVISH_RETRY_BIN:$PATH" FM_HOME="$HRETRY" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$RETRY_ART" \
  --after-sequence 1 --agent-reply "Retry only after inspection." >/dev/null
PATH="$LAVISH_RETRY_BIN:$PATH" pe "$HRETRY" reconcile >/dev/null
for _ in $(seq 1 100); do
  [ "$(count_results "$HRETRY" "$retry_id")" -ge 2 ] && break
  sleep 0.1
done
[ "$(cat "$LAVISH_RETRY_COUNT")" = 1 ] || fail "failed reply was replayed before explicit recovery"
RETRY_AMBIGUOUS="$HRETRY/state/procevent-inbox/$retry_id.2.result"
assert_contains "$(FM_HOME="$HRETRY" "$ROOT/bin/fm-procevent-lavish.sh" classify "$RETRY_AMBIGUOUS")" ambiguous \
  "failed reply did not surface ambiguous delivery"
for _ in $(seq 1 60); do
  [ ! -e "$HRETRY/state/procevent/$retry_id.source" ] && break
  sleep 0.1
done
assert_absent "$HRETRY/state/procevent/$retry_id.source" \
  "failed reply ambiguity remained armed before inspected recovery"
retry_recover_out=$(PATH="$LAVISH_RETRY_BIN:$PATH" FM_HOME="$HRETRY" \
  "$ROOT/bin/fm-procevent-lavish.sh" recover "$RETRY_ART" \
  --after-sequence 1 --delivery not-delivered)
assert_contains "$retry_recover_out" "acknowledge_ambiguity_sequence: 2" \
  "not-delivered recovery did not retain the ambiguity acknowledgement handoff"
pe "$HRETRY" handled "$retry_id" 2 >/dev/null
PATH="$LAVISH_RETRY_BIN:$PATH" pe "$HRETRY" reconcile >/dev/null
for _ in $(seq 1 100); do
  [ "$(count_results "$HRETRY" "$retry_id")" -ge 3 ] && break
  sleep 0.1
done
[ "$(cat "$LAVISH_RETRY_COUNT")" = 2 ] || fail "inspected not-delivered recovery did not run exactly one retry"
[ "$(grep -F -c '<--agent-reply>' "$LAVISH_RETRY_LOG" || true)" = 2 ] \
  || fail "not-delivered recovery did not preserve the exact reply on its one retry"
pass "inspected not-delivered recovery releases exactly one explicit reply retry"

# --- end-user-aligned regression: the exact drain-before-handling restart cut
# Reproduces the confirmed defect through the public interface end to end: a
# real blocking source completes, its result is captured and published, the
# wake is drained without any handling, a replacement session's reconcile must
# resurface the exact same source and sequence, and only the owned handling
# interface may retire it - safely and without ever authorizing a paired
# effect a second time.
HW="$TMP_ROOT/hw"; new_home "$HW"
TRIGW="$TMP_ROOT/trigger-restart-cut"
pe_register "$HW" lavish restart-cut-src -- "$BLOCKER" "$TRIGW" "restart cut payload" >/dev/null
pe "$HW" reconcile >/dev/null
sleep 0.5
: > "$TRIGW"
wait_for "$HW/state/.wake-queue" || fail "the restart-cut source published no event"
assert_contains "$(wake_payloads "$HW")" "procevent lavish restart-cut-src 1" \
  "capture and publish reaches the wake queue before any handling"

# Retire the registration now that the source has completed and captured its
# one result. The fixture's trigger file persists on disk, so a still-armed
# registration would let every further reconcile call restart the blocker and
# capture a fresh generation; retiring leaves only the durable inbox and wake
# state under test, matching the exact restart cut - the source side is done,
# only the handling side is still open.
pe "$HW" retire restart-cut-src >/dev/null

# Drain the wake without handling it: the end-user experience of a session
# reading the wake queue at turn end without yet acting on this specific line.
mv "$HW/state/.wake-queue" "$HW/state/.wake-queue.drained-unhandled"
[ -z "$(wake_payloads "$HW")" ] || fail "the wake queue was not actually drained"

# Simulate a replacement Firstmate session: reconcile runs cold, as it would on
# a fresh process with no memory of the prior turn.
out=$(pe "$HW" reconcile)
assert_contains "$out" "published=1" \
  "a replacement session's reconcile resurfaces a drained-but-unhandled result"
assert_contains "$(wake_payloads "$HW")" "procevent lavish restart-cut-src 1" \
  "the exact same captured source and sequence resurfaces, never a substitute"

# Acknowledge handling through the owned interface.
ack_out=$(pe "$HW" handled restart-cut-src 1)
assert_contains "$ack_out" "handled: restart-cut-src 1" \
  "the first acknowledgement newly authorizes the paired effect"

mv "$HW/state/.wake-queue" "$HW/state/.wake-queue.post-handle"
out=$(pe "$HW" reconcile)
assert_contains "$out" "published=0" \
  "a later reconcile does not resurface a result once it is durably handled"
[ -z "$(wake_payloads "$HW")" ] || fail "a handled result was announced again: $(wake_payloads "$HW")"

auth_count=0
for _ in 1 2 3; do
  repeat_ack=$(pe "$HW" handled restart-cut-src 1)
  assert_contains "$repeat_ack" "already-handled: restart-cut-src 1" "repeated acknowledgement stays safe and idempotent"
  case "$repeat_ack" in handled:*) auth_count=$((auth_count + 1)) ;; esac
done
[ "$auth_count" -eq 0 ] || fail "a result already durably handled was authorized again: count=$auth_count"
pass "a drained-but-unhandled result survives a replacement session and is retired only by explicit handling, never twice"

HP="$TMP_ROOT/hp"; new_home "$HP"
mkdir -p "$HP/state/procevent-inbox"
for seq in 10 2 1; do
  printf '%s\n' "$seq" > "$HP/state/procevent-inbox/ordered-src.$seq.result"
  printf 'lavish\n' > "$HP/state/procevent-inbox/ordered-src.$seq.adapter"
  chmod 0600 "$HP/state/procevent-inbox/ordered-src.$seq.result" "$HP/state/procevent-inbox/ordered-src.$seq.adapter"
done
pending=$(bash -c '. "$1/bin/fm-procevent-lib.sh"; fm_procevent_pending "$2"' _ "$ROOT" "$HP/state")
expected=$(printf '%s\n' \
  "$HP/state/procevent-inbox/ordered-src.1.result" \
  "$HP/state/procevent-inbox/ordered-src.2.result" \
  "$HP/state/procevent-inbox/ordered-src.10.result")
[ "$pending" = "$expected" ] || fail "pending results were not emitted in numeric sequence order: $pending"
pe "$HP" reconcile >/dev/null
deduped=$(FM_HOME="$HP" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_wake_print_deduped "$2/state/.wake-queue" | awk -F "\t" "{print \$5}"
' _ "$ROOT" "$HP")
expected=$(printf '%s\n' \
  'check: procevent lavish ordered-src 1' \
  'check: procevent lavish ordered-src 2' \
  'check: procevent lavish ordered-src 10')
[ "$deduped" = "$expected" ] || fail "distinct result generations were coalesced or reordered: $deduped"
pass "pending results preserve numeric order and distinct wake identity"

# --- two homes cannot both own one canonical source -------------------------
HA="$TMP_ROOT/ha"; HB="$TMP_ROOT/hb"; new_home "$HA"; new_home "$HB"
TRIG2="$TMP_ROOT/trigger-two"
pe_register "$HA" lavish shared-src -- "$BLOCKER" "$TRIG2" "shared" >/dev/null
pe_register "$HB" lavish shared-src -- "$BLOCKER" "$TRIG2" "shared" >/dev/null
pe "$HA" reconcile >/dev/null
sleep 0.5
out=$(pe "$HB" start shared-src)
assert_contains "$out" "already owned" "a second home cannot own a source another home already owns"
[ -z "$(wake_payloads "$HB")" ] || fail "the losing home published an event"
pass "one owner per canonical source across homes"

# A source whose child never completes must not survive retirement. This is the
# leak that reparented four orphaned runners: the fixture directory was removed
# while the detached child kept blocking, with nothing left to reap it.
runner_pid=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/shared-src.claim" 2>/dev/null)
[ -n "$runner_pid" ] || fail "no runner pid recorded for the blocked source"
kill -0 "$runner_pid" 2>/dev/null || fail "the blocked runner is not live before retirement"
pe "$HA" retire shared-src >/dev/null
for _ in $(seq 1 40); do kill -0 "$runner_pid" 2>/dev/null || break; sleep 0.1; done
kill -0 "$runner_pid" 2>/dev/null && fail "retire left the blocked runner alive"
assert_absent "$FM_PROCEVENT_CLAIM_ROOT/shared-src.claim" "retire releases the claim"
pass "retiring a never-completing source stops its runner and its blocked child"

# reconcile must also stop a runner whose registration was removed out from under it.
TRIG4="$TMP_ROOT/trigger-four"
HZ="$TMP_ROOT/hz"; new_home "$HZ"
pe_register "$HZ" lavish orphan-src -- "$BLOCKER" "$TRIG4" "orphan" >/dev/null
pe "$HZ" reconcile >/dev/null
sleep 0.5
orphan_pid=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/orphan-src.claim" 2>/dev/null)
if [ -z "$orphan_pid" ] || ! kill -0 "$orphan_pid" 2>/dev/null; then
  fail "orphan fixture runner did not start"
fi
rm -f "$HZ/state/procevent/orphan-src.source"
out=$(pe "$HZ" reconcile)
assert_contains "$out" "stopped=1" "reconcile stops a runner whose registration was removed"
for _ in $(seq 1 40); do kill -0 "$orphan_pid" 2>/dev/null || break; sleep 0.1; done
kill -0 "$orphan_pid" 2>/dev/null && fail "reconcile left an orphaned runner alive"
pass "reconcile reaps a runner whose source registration is gone"

# --- a stale claim is reclaimable, a live one is not ------------------------
CLAIM="$FM_PROCEVENT_CLAIM_ROOT/stale-src.claim"
mkdir -p "$FM_PROCEVENT_CLAIM_ROOT"
HC="$TMP_ROOT/hc"; new_home "$HC"
printf '%s\n%s\nstale-token\nstale-identity\n' "$HC" "999999" > "$CLAIM"
chmod 0600 "$CLAIM"
pe_register "$HC" lavish stale-src -- /bin/echo recovered >/dev/null
printf 'partial sensitive output\n' > "$HC/state/procevent/.stale-src.stale-token.output"
chmod 0600 "$HC/state/procevent/.stale-src.stale-token.output"
out=$(pe "$HC" start stale-src)
assert_contains "$out" "captured:" "a claim whose runner is gone is reclaimable"
assert_absent "$CLAIM" "the replacement claim generation is released after completion"
assert_absent "$HC/state/procevent/.stale-src.stale-token.output" "stale claim recovery removes its abandoned staging generation"
pass "stale-owner recovery removes abandoned output without displacing a live owner"

HC_OLD="$TMP_ROOT/hc-old"; new_home "$HC_OLD"
HC_NEW="$TMP_ROOT/hc-new"; new_home "$HC_NEW"
HC_OLD_STATE="$TMP_ROOT/hc-old-state"
mkdir -p "$HC_OLD_STATE/procevent"
printf '%s\n%s\ncross-home-token\ncross-home-identity\n%s\n' \
  "$HC_OLD" "999999" "$HC_OLD_STATE/procevent" > "$FM_PROCEVENT_CLAIM_ROOT/cross-home-src.claim"
chmod 0600 "$FM_PROCEVENT_CLAIM_ROOT/cross-home-src.claim"
printf 'partial cross-home output\n' > "$HC_OLD_STATE/procevent/.cross-home-src.cross-home-token.output"
chmod 0600 "$HC_OLD_STATE/procevent/.cross-home-src.cross-home-token.output"
pe_register "$HC_NEW" lavish cross-home-src -- /bin/echo recovered >/dev/null
out=$(pe "$HC_NEW" start cross-home-src)
assert_contains "$out" "captured:" "a second home can replace a stale source owner"
assert_absent "$HC_OLD_STATE/procevent/.cross-home-src.cross-home-token.output" "cross-home reclaim removes the old generation's recorded staging file"
pass "cross-home stale recovery removes abandoned output from the old state directory"

HR="$TMP_ROOT/hr"; new_home "$HR"
RACE_TRIGGER="$TMP_ROOT/race-trigger"
RACE_LOG="$TMP_ROOT/race-executions"
RACE_BLOCKER="$TMP_ROOT/race-blocker.sh"
cat > "$RACE_BLOCKER" <<'SH'
#!/usr/bin/env bash
printf 'started\n' >> "$1"
while [ ! -e "$2" ]; do sleep 0.05; done
printf 'race result\n'
SH
chmod +x "$RACE_BLOCKER"
pe_register "$HR" lavish race-src -- "$RACE_BLOCKER" "$RACE_LOG" "$RACE_TRIGGER" >/dev/null
printf '%s\n%s\nold-token\nold-identity\n' "$TMP_ROOT/gone-home" 999999 > "$FM_PROCEVENT_CLAIM_ROOT/race-src.claim"
chmod 0600 "$FM_PROCEVENT_CLAIM_ROOT/race-src.claim"
race_pids=()
for _ in $(seq 1 24); do
  pe "$HR" start race-src >/dev/null &
  race_pids+=("$!")
done
wait_for "$RACE_LOG" || fail "no contender acquired the stale claim"
sleep 0.5
[ "$(wc -l < "$RACE_LOG" | tr -d ' ')" = 1 ] || fail "stale-claim race started more than one runner"
: > "$RACE_TRIGGER"
for race_pid in "${race_pids[@]}"; do wait "$race_pid" 2>/dev/null || true; done
pass "concurrent stale-claim replacement starts exactly one runner"

# --- a crashed runner leader must not make its live child group look stale ---
# The runner is its own process group leader, so SIGKILL on the leader alone
# leaves the blocking source child running in that group. Classifying the
# missing leader as stale would release ownership and start a second poller
# against one canonical source, which for a destructive source means two
# concurrent long polls racing on the same session. The surviving group must be
# stopped before ownership can move.
HG="$TMP_ROOT/hg"; new_home "$HG"
ORPHAN_TRIGGER="$TMP_ROOT/orphan-trigger"
ORPHAN_LOG="$TMP_ROOT/orphan-executions"
ORPHAN_GROUP="$TMP_ROOT/orphan-group"
ORPHAN_OVERLAP="$TMP_ROOT/orphan-overlap"
ORPHAN_BLOCKER="$TMP_ROOT/orphan-blocker.sh"
cat > "$ORPHAN_BLOCKER" <<'SH'
#!/usr/bin/env bash
printf 'started\n' >> "$1"
if [ -s "$3" ]; then
  IFS= read -r old_group < "$3"
  if kill -0 "-$old_group" 2>/dev/null; then
    printf 'overlap\n' > "$4"
  fi
fi
while [ ! -e "$2" ]; do sleep 0.05; done
printf 'orphan result\n'
SH
chmod +x "$ORPHAN_BLOCKER"
pe_register "$HG" lavish orphan-src -- \
  "$ORPHAN_BLOCKER" "$ORPHAN_LOG" "$ORPHAN_TRIGGER" "$ORPHAN_GROUP" "$ORPHAN_OVERLAP" >/dev/null
pe "$HG" reconcile >/dev/null
wait_for "$FM_PROCEVENT_CLAIM_ROOT/orphan-src.claim" || fail "leader-crash fixture never claimed its source"
wait_for "$ORPHAN_LOG" || fail "leader-crash fixture source never started"
orphan_leader=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/orphan-src.claim")
case "$orphan_leader" in ''|*[!0-9]*) fail "could not read the runner leader pid: $orphan_leader" ;; esac
printf '%s\n' "$orphan_leader" > "$ORPHAN_GROUP"

kill -KILL "$orphan_leader" 2>/dev/null || fail "could not kill the runner leader"
for _ in $(seq 1 50); do kill -0 "$orphan_leader" 2>/dev/null || break; sleep 0.1; done
kill -0 "$orphan_leader" 2>/dev/null && fail "the runner leader survived SIGKILL"
kill -0 -"$orphan_leader" 2>/dev/null || fail "fixture invalid: the owned child group did not survive the leader"

orphan_out=$(pe "$HG" reconcile)
kill -0 -"$orphan_leader" 2>/dev/null \
  && fail "reconcile left the crashed generation's process group alive: $orphan_out"
sleep 0.5
assert_absent "$ORPHAN_OVERLAP" "no replacement source starts while the crashed generation remains alive"
case "$orphan_out" in
  *"started=1"*)
    [ -e "$FM_PROCEVENT_CLAIM_ROOT/orphan-src.claim" ] \
      || fail "a replacement runner started without recording its own claim"
    [ "$(wc -l < "$ORPHAN_LOG" | tr -d ' ')" = 2 ] \
      || fail "reconcile did not start exactly one replacement source: $(cat "$ORPHAN_LOG")"
    ;;
  *"started=0"*)
    [ -e "$FM_PROCEVENT_CLAIM_ROOT/orphan-src.claim" ] \
      || fail "refusing to replace must preserve the claim for retry: $orphan_out"
    [ "$(wc -l < "$ORPHAN_LOG" | tr -d ' ')" = 1 ] \
      || fail "reconcile started a source while refusing replacement: $(cat "$ORPHAN_LOG")"
    ;;
  *) fail "unexpected reconcile result for a crashed leader: $orphan_out" ;;
esac
: > "$ORPHAN_TRIGGER"
pe "$HG" retire orphan-src >/dev/null
pass "a crashed runner leader never lets a live owned group be reclaimed as stale"

# Counterexample: a genuinely dead generation - no leader and no surviving
# group - must still be reclaimable, or crash recovery would deadlock.
HG2="$TMP_ROOT/hg2"; new_home "$HG2"
DEAD_TRIGGER="$TMP_ROOT/dead-gen-trigger"
DEAD_LOG="$TMP_ROOT/dead-gen-executions"
pe_register "$HG2" lavish dead-gen-src -- "$RACE_BLOCKER" "$DEAD_LOG" "$DEAD_TRIGGER" >/dev/null
printf '%s\n%s\ndead-token\ndead-identity\n%s\n' "$HG2" 999999 "$HG2/state/procevent" \
  > "$FM_PROCEVENT_CLAIM_ROOT/dead-gen-src.claim"
chmod 0600 "$FM_PROCEVENT_CLAIM_ROOT/dead-gen-src.claim"
dead_out=$(pe "$HG2" reconcile)
assert_contains "$dead_out" "started=1" "a generation with no leader and no group is still reclaimable"
wait_for "$DEAD_LOG" || fail "the replacement source never started for a truly dead generation"
: > "$DEAD_TRIGGER"
pe "$HG2" retire dead-gen-src >/dev/null
pass "a truly dead generation with no surviving group is still safely reclaimed"

HJ="$TMP_ROOT/hj"; new_home "$HJ"
TORN_TRIGGER="$TMP_ROOT/torn-trigger"
pe_register "$HJ" lavish torn-src -- "$BLOCKER" "$TORN_TRIGGER" "torn" >/dev/null
pe "$HJ" reconcile >/dev/null
wait_for "$FM_PROCEVENT_CLAIM_ROOT/torn-src.claim" || fail "torn-read fixture runner did not claim its source"
awk 'NR == 3 { print "replacement-token"; next } { print }' \
  "$FM_PROCEVENT_CLAIM_ROOT/torn-src.claim" > "$TMP_ROOT/torn-next.claim"
chmod 0600 "$TMP_ROOT/torn-next.claim"
TORN_READY="$TMP_ROOT/torn-lock-ready"
TORN_RELEASE="$TMP_ROOT/torn-lock-release"
hold_source_lock torn-src "$TORN_READY" "$TORN_RELEASE"
torn_holder_pid=$HOLDER_PID
wait_for "$TORN_READY" || fail "could not hold the torn-read source boundary"
pe "$HJ" list > "$TMP_ROOT/torn-list.out" &
torn_list_pid=$!
sleep 0.2
kill -0 "$torn_list_pid" 2>/dev/null || fail "claim reader escaped the source boundary during replacement"
mv "$TMP_ROOT/torn-next.claim" "$FM_PROCEVENT_CLAIM_ROOT/torn-src.claim"
: > "$TORN_RELEASE"
wait "$torn_list_pid" || fail "claim reader failed after serialized replacement"
wait "$torn_holder_pid" || fail "torn-read source boundary holder failed"
assert_contains "$(cat "$TMP_ROOT/torn-list.out")" "live" "claim reader observes one coherent replacement generation"
pe "$HJ" retire torn-src >/dev/null
pass "claim replacement cannot produce a torn ownership snapshot"

HK="$TMP_ROOT/hk"; new_home "$HK"
START_LOG="$TMP_ROOT/retire-start-executions"
START_BLOCKER="$TMP_ROOT/retire-start-blocker.sh"
cat > "$START_BLOCKER" <<'SH'
#!/usr/bin/env bash
printf 'started\n' >> "$1"
sleep 30
SH
chmod +x "$START_BLOCKER"
pe_register "$HK" lavish retire-start-src -- "$START_BLOCKER" "$START_LOG" >/dev/null
START_READY="$TMP_ROOT/retire-start-lock-ready"
START_RELEASE="$TMP_ROOT/retire-start-lock-release"
hold_source_lock retire-start-src "$START_READY" "$START_RELEASE"
retire_start_holder_pid=$HOLDER_PID
wait_for "$START_READY" || fail "could not hold the retire-start source boundary"
pe "$HK" start retire-start-src > "$TMP_ROOT/retire-start.out" 2>&1 &
retire_start_pid=$!
sleep 0.2
kill -0 "$retire_start_pid" 2>/dev/null || fail "start did not wait for the source lifecycle boundary"
rm -f "$HK/state/procevent/retire-start-src.source"
: > "$START_RELEASE"
wait "$retire_start_pid" 2>/dev/null || true
wait "$retire_start_holder_pid" || fail "retire-start source boundary holder failed"
assert_absent "$START_LOG" "a start queued before retirement must revalidate the registration"
assert_absent "$FM_PROCEVENT_CLAIM_ROOT/retire-start-src.claim" "retirement cannot leave a late claim"
pass "retirement and start share one serialized lifecycle boundary"

HI="$TMP_ROOT/hi"; new_home "$HI"
pe_register "$HI" lavish reused-src -- /bin/true >/dev/null
sleep 60 &
innocent_pid=$!
printf '%s\n%s\nreused-token\nnot-the-live-process-identity\n' \
  "$HI" "$innocent_pid" > "$FM_PROCEVENT_CLAIM_ROOT/reused-src.claim"
chmod 0600 "$FM_PROCEVENT_CLAIM_ROOT/reused-src.claim"
pe "$HI" retire reused-src >/dev/null
kill -0 "$innocent_pid" 2>/dev/null || fail "retirement signaled a PID whose identity did not match the claim"
kill "$innocent_pid" 2>/dev/null || true
wait "$innocent_pid" 2>/dev/null || true
assert_absent "$FM_PROCEVENT_CLAIM_ROOT/reused-src.claim" "retirement releases the exact reused-pid claim"
pass "PID reuse cannot signal an unrelated process"

HL="$TMP_ROOT/hl"; new_home "$HL"
IDENTITY_TRIGGER="$TMP_ROOT/identity-trigger"
pe_register "$HL" lavish identity-src -- "$BLOCKER" "$IDENTITY_TRIGGER" "identity" >/dev/null
pe "$HL" reconcile >/dev/null
wait_for "$FM_PROCEVENT_CLAIM_ROOT/identity-src.claim" || fail "identity fixture runner did not claim its source"
identity_pid=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/identity-src.claim")
IDENTITY_FAKEBIN=$(fm_fakebin "$TMP_ROOT/identity-tools")
cat > "$IDENTITY_FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$IDENTITY_FAKEBIN/ps"
identity_status=0
identity_out=$(PATH="$IDENTITY_FAKEBIN:$PATH" FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/no-proc" \
  pe "$HL" retire identity-src 2>&1) || identity_status=$?
[ "$identity_status" -ne 0 ] || fail "retirement succeeded despite uncertain live identity"
assert_contains "$identity_out" "source remains registered" "uncertain retirement reports preserved state"
kill -0 "$identity_pid" 2>/dev/null || fail "uncertain retirement signaled the runner"
assert_present "$HL/state/procevent/identity-src.source" "uncertain retirement preserves registration"
assert_present "$FM_PROCEVENT_CLAIM_ROOT/identity-src.claim" "uncertain retirement preserves claim generation"
pe "$HL" retire identity-src >/dev/null
pass "transient identity failure preserves the live source for retry"

HM="$TMP_ROOT/hm"; new_home "$HM"
SWEEP_TRIGGER_ONE="$TMP_ROOT/sweep-trigger-one"
SWEEP_TRIGGER_TWO="$TMP_ROOT/sweep-trigger-two"
pe_register "$HM" lavish sweep-one -- "$BLOCKER" "$SWEEP_TRIGGER_ONE" "sweep one" >/dev/null
pe_register "$HM" lavish sweep-two -- "$BLOCKER" "$SWEEP_TRIGGER_TWO" "sweep two" >/dev/null
pe "$HM" reconcile >/dev/null
wait_for "$FM_PROCEVENT_CLAIM_ROOT/sweep-one.claim" || fail "home sweep fixture one did not start"
wait_for "$FM_PROCEVENT_CLAIM_ROOT/sweep-two.claim" || fail "home sweep fixture two did not start"
sweep_pid_one=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/sweep-one.claim")
sweep_pid_two=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/sweep-two.claim")
rm -f "$HM/state/procevent/sweep-two.source"
out=$(pe "$HM" sweep-home --preflight)
assert_contains "$out" "sweep preflight: ready" "home sweep preflight validates the full bounded snapshot"
assert_present "$HM/state/procevent/sweep-one.source" "home sweep preflight does not remove registrations"
assert_present "$FM_PROCEVENT_CLAIM_ROOT/sweep-one.claim" "home sweep preflight does not release claims"
out=$(pe "$HM" sweep-home)
assert_contains "$out" "swept: attempted=2" "home sweep retires registrations and owned claim-only sources"
for sweep_pid in "$sweep_pid_one" "$sweep_pid_two"; do
  for _ in $(seq 1 40); do kill -0 "$sweep_pid" 2>/dev/null || break; sleep 0.1; done
  kill -0 "$sweep_pid" 2>/dev/null && fail "home sweep left a runner alive"
done
assert_absent "$HM/state/procevent/sweep-one.source" "home sweep removes registrations"
assert_absent "$FM_PROCEVENT_CLAIM_ROOT/sweep-one.claim" "home sweep releases the first claim"
assert_absent "$FM_PROCEVENT_CLAIM_ROOT/sweep-two.claim" "home sweep releases a claim with no registration"
pass "bounded home sweep preflights then retires every locally owned source"

HN="$TMP_ROOT/hn"; HO="$TMP_ROOT/ho"; new_home "$HN"; new_home "$HO"
FOREIGN_TRIGGER="$TMP_ROOT/foreign-trigger"
pe_register "$HN" lavish foreign-src -- "$BLOCKER" "$FOREIGN_TRIGGER" "foreign" >/dev/null
pe_register "$HO" lavish foreign-src -- "$BLOCKER" "$FOREIGN_TRIGGER" "foreign" >/dev/null
pe "$HN" reconcile >/dev/null
wait_for "$FM_PROCEVENT_CLAIM_ROOT/foreign-src.claim" || fail "foreign-owner fixture did not start"
foreign_pid=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/foreign-src.claim")
out=$(pe "$HO" sweep-home)
assert_contains "$out" "swept: attempted=1" "home sweep retires the local registration"
kill -0 "$foreign_pid" 2>/dev/null || fail "home sweep signaled a foreign-home runner"
assert_present "$FM_PROCEVENT_CLAIM_ROOT/foreign-src.claim" "home sweep preserves a foreign-home claim"
[ "$(sed -n '1p' "$FM_PROCEVENT_CLAIM_ROOT/foreign-src.claim")" = "$HN" ] || fail "home sweep changed foreign claim ownership"
assert_absent "$HO/state/procevent/foreign-src.source" "home sweep removes only the local registration"
pe "$HN" retire foreign-src >/dev/null
pass "home sweep leaves foreign-home claims and runners untouched"

HU="$TMP_ROOT/hu"; new_home "$HU"
SWEEP_UNCERTAIN_TRIGGER="$TMP_ROOT/sweep-uncertain-trigger"
pe_register "$HU" lavish sweep-uncertain -- "$BLOCKER" "$SWEEP_UNCERTAIN_TRIGGER" "uncertain" >/dev/null
pe "$HU" reconcile >/dev/null
wait_for "$FM_PROCEVENT_CLAIM_ROOT/sweep-uncertain.claim" || fail "uncertain sweep fixture did not start"
sweep_uncertain_pid=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/sweep-uncertain.claim")
sweep_status=0
sweep_out=$(PATH="$IDENTITY_FAKEBIN:$PATH" FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/no-sweep-proc" \
  pe "$HU" sweep-home 2>&1) || sweep_status=$?
[ "$sweep_status" -ne 0 ] || fail "home sweep succeeded with an uncertain runner identity"
assert_contains "$sweep_out" "home sweep preflight failed" "uncertain home sweep reports a retryable refusal"
kill -0 "$sweep_uncertain_pid" 2>/dev/null || fail "uncertain home sweep signaled the runner"
assert_present "$HU/state/procevent/sweep-uncertain.source" "uncertain home sweep preserves registration"
assert_present "$FM_PROCEVENT_CLAIM_ROOT/sweep-uncertain.claim" "uncertain home sweep preserves the claim"
pe "$HU" sweep-home >/dev/null
pass "home sweep refuses safely until runner identity is readable"

HV="$TMP_ROOT/hv"; new_home "$HV"
mkdir -p "$HV/state/procevent-inbox"
printf 'already captured\n' > "$HV/state/procevent-inbox/result-only.1.result"
sup=$(bash -c '. "$1/bin/fm-supervision-lib.sh"; fm_supervision_needed "$2" && echo yes || echo no' _ "$ROOT" "$HV/state")
assert_contains "$sup" no "registration-free results do not broaden continuous supervision"
out=$(pe "$HV" sweep-home)
assert_contains "$out" "swept: attempted=0" "result-only homes need no process cleanup"
pass "healthy runtime behavior remains registration-only"

# --- argv boundaries, stderr, exit status, bounds, malformed output ---------
HD="$TMP_ROOT/hd"; new_home "$HD"
TRIG3="$TMP_ROOT/trigger-three"
pe_register "$HD" lavish argv-src -- "$BLOCKER" "$TRIG3" "one arg with spaces" "second; rm -rf /tmp/nope" >/dev/null
pe "$HD" reconcile >/dev/null
: > "$TRIG3"
wait_for "$HD/state/.wake-queue" || fail "argv source published no event"
R=$(first_result "$HD" argv-src || true)
assert_grep 'one arg with spaces' "$R" "an argument containing spaces survives as one argument"
assert_grep 'second; rm -rf /tmp/nope' "$R" "a shell-looking argument is passed literally, never interpreted"
assert_absent /tmp/nope "no shell interpretation occurred"
assert_not_contains "$(wake_payloads "$HD")" "rm -rf" "argv content never reaches the event line"

newline_status=0
newline_out=$(pe_register "$HD" lavish newline-src -- /bin/echo $'first\nsecond' 2>&1) || newline_status=$?
[ "$newline_status" -ne 0 ] || fail "registration accepted an argv element containing a newline"
assert_contains "$newline_out" "cannot contain newlines" "newline rejection explains the unsupported representation"
assert_absent "$HD/state/procevent/newline-src.source" "newline rejection publishes no corrupt registration"
pass "registration rejects unrepresentable newline arguments"

HE="$TMP_ROOT/he"; new_home "$HE"
pe_register "$HE" lavish fail-src -- /bin/sh -c 'exit 7' >/dev/null
out=$(pe "$HE" start fail-src)
assert_contains "$out" "no-result" "a failing source with no output publishes nothing"
[ -z "$(wake_payloads "$HE")" ] || fail "a failing source published an event"
assert_present "$HE/state/procevent/fail-src.source" "a failing source stays registered for retry"
pass "nonzero exit with no output stays armed and silent"

HF="$TMP_ROOT/hf"; new_home "$HF"
# shellcheck disable=SC2016  # single quotes are deliberate: the child shell expands this.
pe_register "$HF" lavish big-src -- /bin/sh -c 'printf "x%.0s" $(seq 1 5000)' >/dev/null
FM_PROCEVENT_MAX_OUTPUT_BYTES=100 FM_HOME="$HF" "$ROOT/bin/fm-procevent.sh" start big-src >/dev/null 2>&1
RB=$(first_result "$HF" big-src || true)
[ -n "$RB" ] || fail "bounded output was not captured at all"
[ "$(wc -c < "$RB" | tr -d ' ')" -le 100 ] || fail "output bound was not enforced"
pass "oversized output is bounded rather than published whole or dropped"

HG="$TMP_ROOT/hg-live"; new_home "$HG"
NOISY="$TMP_ROOT/noisy.sh"
NOISY_PID="$TMP_ROOT/noisy.pid"
cat > "$NOISY" <<'SH'
#!/usr/bin/env bash
trap '' TERM PIPE
printf '%s\n' "$$" > "$1"
while :; do
  printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n'
done
SH
chmod +x "$NOISY"
pe_register "$HG" lavish noisy-src -- "$NOISY" "$NOISY_PID" >/dev/null
FM_PROCEVENT_MAX_OUTPUT_BYTES=100 pe "$HG" reconcile >/dev/null
wait_for "$NOISY_PID" || fail "noisy source child did not start"
noisy_child=$(cat "$NOISY_PID")
staged=
for _ in $(seq 1 100); do
  for candidate in "$HG/state/procevent"/.noisy-src.*.output; do
    if [ -f "$candidate" ]; then staged=$candidate; break; fi
  done
  [ -n "$staged" ] && break
  sleep 0.1
done
[ -n "$staged" ] || fail "noisy source created no bounded staging file"
sleep 0.2
[ "$(wc -c < "$staged" | tr -d ' ')" -le 100 ] || fail "live staging exceeded the configured output bound"
pe "$HG" retire noisy-src >/dev/null
kill -0 "$noisy_child" 2>/dev/null && fail "TERM-resistant source child survived runner retirement"
assert_absent "$staged" "retirement removes the tracked partial staging file"
pass "live output stays bounded and retirement reaps the whole source group"

HBAD="$TMP_ROOT/hbad"; new_home "$HBAD"
pe_register "$HBAD" lavish bad-limit -- /bin/true >/dev/null
bad_limit_status=0
bad_limit_out=$(FM_PROCEVENT_MAX_OUTPUT_BYTES=invalid pe "$HBAD" start bad-limit 2>&1) || bad_limit_status=$?
[ "$bad_limit_status" -ne 0 ] || fail "an invalid output bound was accepted"
assert_contains "$bad_limit_out" "must be a nonnegative integer" "invalid output bound reports its contract"
assert_absent "$FM_PROCEVENT_CLAIM_ROOT/bad-limit.claim" "invalid output bound leaves no source claim"
pass "invalid output bounds fail closed"

# --- the Lavish adapter uses the published poll shape -----------------------
HART="$TMP_ROOT/hartifact"; new_home "$HART"
FM_HOME="$HART" "$ROOT/bin/fm-lavish-review.sh" prepare "$HART" adapter-source >/dev/null
ART="$HART/.lavish/adapter-source/review.html"
printf '<h1>fixture</h1>\n' > "$ART"
sid=$(FM_HOME="$HART" "$ROOT/bin/fm-procevent-lavish.sh" source-id "$ART")
case "$sid" in lavish-*) : ;; *) fail "adapter source id has an unexpected shape: $sid" ;; esac
sid2=$(FM_HOME="$HART" "$ROOT/bin/fm-procevent-lavish.sh" source-id "$ART")
[ "$sid" = "$sid2" ] || fail "adapter source id is not stable"
ART_ALIAS="$HART/.lavish/adapter-source/review-alias.html"
ln -s "$ART" "$ART_ALIAS"
symlink_artifact_status=0
symlink_artifact_out=$(FM_HOME="$HART" "$ROOT/bin/fm-procevent-lavish.sh" source-id "$ART_ALIAS" 2>&1) || symlink_artifact_status=$?
[ "$symlink_artifact_status" -ne 0 ] || fail "Lavish source identity accepted a symlinked artifact"
assert_contains "$symlink_artifact_out" "private local path check" "Lavish rejects symlinked artifacts before registration"
ART_NEWLINE="$ART"$'\n'
newline_artifact_status=0
newline_artifact_out=$(FM_HOME="$HART" "$ROOT/bin/fm-procevent-lavish.sh" source-id "$ART_NEWLINE" 2>&1) || newline_artifact_status=$?
[ "$newline_artifact_status" -ne 0 ] || fail "Lavish source identity accepted an artifact path ending in a newline"
assert_contains "$newline_artifact_out" "cannot contain newlines" "Lavish rejects newline paths before registration"
pass "the adapter derives stable private identity and rejects symlink or newline paths"

HS="$TMP_ROOT/hs"; new_home "$HS"
mkdir -p "$HS/state/procevent"
: > "$HS/state/procevent/source-only.source"
guard_out=$(FM_ROOT_OVERRIDE="$TMP_ROOT/guard-root" FM_HOME="$HS" FM_GUARD_GRACE=1 \
  "$ROOT/bin/fm-guard.sh" 2>&1)
assert_contains "$guard_out" "WATCHER DOWN - SUPERVISION IS OFF" \
  "the general guard warns when only a process-event source needs supervision"
assert_contains "$guard_out" "1 process-event source(s) registered" \
  "the general guard identifies the source-only supervision need"
pass "source-only homes trigger the general supervision guard"

CLS="$TMP_ROOT/cls"
printf 'session:\n  file: /a.html\n  status: feedback\nprompts[1]{uid}:\n  p1\n' > "$CLS"
out=$("$ROOT/bin/fm-procevent-lavish.sh" classify "$CLS")
assert_contains "$out" feedback "the adapter reads the indented session status"
printf 'session:\n  file: /a.html\n  status: feedback\nprompts[1]{text}:\n  No active Lavish Editor session; code: NOT_FOUND\n' > "$CLS"
assert_contains "$("$ROOT/bin/fm-procevent-lavish.sh" classify "$CLS")" feedback "prompt text cannot override a valid session status"
printf 'session:\n  file: /a.html\n  status: ended\n' > "$CLS"
assert_contains "$("$ROOT/bin/fm-procevent-lavish.sh" classify "$CLS")" ended "an ended session classifies as ended"
printf 'error: No active Lavish Editor session for this file\ncode: NOT_FOUND\n' > "$CLS"
assert_contains "$("$ROOT/bin/fm-procevent-lavish.sh" classify "$CLS")" missing "an explicit missing session classifies as missing"
printf 'continuation:\n  status: ambiguous\n  source_sequence: 4\n  reason: reply-delivery-already-claimed\nsession:\n  status: feedback\nprompts[1]{text}:\n  retained decision\n' > "$CLS"
assert_contains "$("$ROOT/bin/fm-procevent-lavish.sh" classify "$CLS")" ambiguous \
  "a claimed reply cut takes precedence over appended retained feedback"
printf 'garbage that is not a session block\n' > "$CLS"
assert_contains "$("$ROOT/bin/fm-procevent-lavish.sh" classify "$CLS")" unknown "malformed output classifies as unknown rather than a lifecycle state"
pass "the adapter classifies feedback and ambiguous continuation results safely"

# The adapter, not the runner, decides which results stop a Lavish registration.
# Every completed feedback poll retires before handler work so a plain automatic
# restart cannot race ahead of the required revision and --agent-reply.
TRM="$TMP_ROOT/terminal-verdict"
printf 'session:\n  file: /a.html\n  status: feedback\n  session_ended: true\n  ended_by: user\n' > "$TRM"
assert_contains "$("$ROOT/bin/fm-procevent-lavish.sh" classify "$TRM")" feedback \
  "a final feedback delivery still classifies as feedback for the handler"
"$ROOT/bin/fm-procevent-lavish.sh" terminal "$TRM" \
  || fail "a feedback delivery carrying session_ended was not reported terminal"
printf 'session:\n  file: /a.html\n  status: feedback\n' > "$TRM"
"$ROOT/bin/fm-procevent-lavish.sh" terminal "$TRM" \
  || fail "ordinary feedback did not retire before handler-mediated re-arm"
printf 'session:\n  file: /a.html\n  status: ended\n  ended_by: user\n' > "$TRM"
"$ROOT/bin/fm-procevent-lavish.sh" terminal "$TRM" || fail "an ended session was not reported terminal"
printf 'error: No active Lavish Editor session for this file\ncode: NOT_FOUND\n' > "$TRM"
"$ROOT/bin/fm-procevent-lavish.sh" terminal "$TRM" || fail "a missing session was not reported terminal"
printf 'session:\n  file: /a.html\n  status: waiting\n' > "$TRM"
"$ROOT/bin/fm-procevent-lavish.sh" terminal "$TRM" && fail "a waiting session was reported terminal"
printf 'continuation:\n  status: ambiguous\n  source_sequence: 9\n  reason: reply-delivery-not-confirmed\n' > "$TRM"
"$ROOT/bin/fm-procevent-lavish.sh" terminal "$TRM" \
  || fail "an ambiguous reply delivery remained armed for automatic replay"
printf 'garbage that is not a session block\n' > "$TRM"
"$ROOT/bin/fm-procevent-lavish.sh" terminal "$TRM" && fail "an unreadable result was reported terminal"
printf 'session:\n  file: /a.html\n  status: waiting\nfeedback[1]{text}:\n  session_ended: true\n' > "$TRM"
"$ROOT/bin/fm-procevent-lavish.sh" terminal "$TRM" \
  && fail "prompt payload text was read as a session-level terminal marker"
pass "the adapter stops every completed Lavish poll before handler re-arm, and payload text cannot forge a lifecycle field"

# --- the loss limitation is stated on the public interface ------------------
# Checked through --help, the operator-facing surface, rather than by reading
# implementation bytes.
adapter_help=$("$ROOT/bin/fm-procevent-lavish.sh" --help 2>&1 || true)
assert_contains "$adapter_help" "destructively clears" \
  "the adapter's help states the destructive-source loss limitation"
assert_contains "$adapter_help" "Never describe" \
  "the adapter's help forbids an at-least-once or lossless description"
assert_contains "$adapter_help" "never replays a claimed reply" \
  "the adapter's help states the sequence-keyed reply boundary"
assert_contains "$adapter_help" "surfaced as ambiguous" \
  "the adapter's help states the interrupted-delivery recovery boundary"
# shellcheck disable=SC2016 # Backticks are literal public-help text.
assert_contains "$adapter_help" 'invokes only `bin/fm-lavish-review.sh run poll`' \
  "the adapter's help routes polling through the private runtime envelope"

runner_help=$("$ROOT/bin/fm-procevent.sh" --help 2>&1 || true)
assert_contains "$runner_help" "Durability boundary" \
  "the runner's help scopes what it actually proves"
assert_not_contains "$runner_help" "exactly-once" \
  "the runner's help claims no exactly-once delivery"
pass "the published interfaces state the loss limitation and claim no lossless delivery"

printf '\nall procevent tests passed\n'
