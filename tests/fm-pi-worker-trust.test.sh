#!/usr/bin/env bash
# Executable-interface coverage for the backend-independent Pi worker launch line.
# fm-spawn constructs one shell line and hands it to each runtime adapter through
# send_literal before sending Enter separately.
# These cells prove every supported spawn backend preserves the complete line as
# one literal argument, including Pi's standalone --approve token and quoted
# model/executable values, without teaching any backend about project trust.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-worker-trust)
PAYLOAD="FM_PI_HARNESS=pi '/tmp/Pi Worker/bin/pi' --tui-mode regular --approve --model 'provider/model name' --thinking 'max' -e '/tmp/task extension.ts' 'typed brief'"

assert_argv() {  # <log> <label> <expected-arg>...
  local log=$1 label=$2
  shift 2
  python3 - "$log" "$label" "$@" <<'PY'
import sys

path, label, *expected = sys.argv[1:]
raw = open(path, "rb").read()
actual = [part.decode() for part in raw.split(b"\0") if part]
if actual != expected:
    raise SystemExit(f"{label}: backend argv changed the literal launch line: {actual!r} != {expected!r}")
payloads = [arg for arg in actual if "FM_PI_HARNESS=pi" in arg]
if len(payloads) != 1 or payloads[0].split().count("--approve") != 1:
    raise SystemExit(f"{label}: expected one literal launch payload containing one standalone --approve: {actual!r}")
PY
}

test_tmux_literal_transport() {
  local fakebin log
  fakebin="$TMP_ROOT/tmux-bin"
  log="$TMP_ROOT/tmux.argv"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\0' "$@" > "${FM_ARGV_LOG:?}"
SH
  chmod +x "$fakebin/tmux"
  FM_ARGV_LOG="$log" PATH="$fakebin:$PATH" \
    bash -c 'FM_BACKEND_LIB_DIR="$1/bin"; . "$1/bin/backends/tmux.sh"; fm_backend_tmux_send_literal session:worker "$2"' \
      _ "$ROOT" "$PAYLOAD"
  assert_argv "$log" tmux send-keys -t session:worker -l "$PAYLOAD"
  pass "tmux transports the guarded Pi worker launch line as one literal payload"
}

test_herdr_literal_transport() {
  local log="$TMP_ROOT/herdr.argv"
  FM_ARGV_LOG="$log" bash -c '
    . "$1/bin/backends/herdr.sh"
    fm_backend_herdr_target_ready() { fm_backend_herdr_parse_target "$1"; }
    fm_backend_herdr_cli() { printf "%s\0" "$@" > "$FM_ARGV_LOG"; }
    fm_backend_herdr_send_literal fleet:w1:p2 "$2"
  ' _ "$ROOT" "$PAYLOAD"
  assert_argv "$log" herdr fleet pane send-text w1:p2 "$PAYLOAD"
  pass "Herdr transports the guarded Pi worker launch line as one literal payload"
}

test_zellij_literal_transport() {
  local log="$TMP_ROOT/zellij.argv"
  FM_ARGV_LOG="$log" bash -c '
    . "$1/bin/backends/zellij.sh"
    fm_backend_zellij_target_ready() { fm_backend_zellij_parse_target "$1"; }
    fm_backend_zellij_cli() { printf "%s\0" "$@" > "$FM_ARGV_LOG"; }
    fm_backend_zellij_send_literal fleet:7 "$2" fm-worker
  ' _ "$ROOT" "$PAYLOAD"
  assert_argv "$log" zellij fleet action paste --pane-id 7 -- "$PAYLOAD"
  pass "Zellij transports the guarded Pi worker launch line as one literal payload"
}

test_cmux_literal_transport() {
  local log="$TMP_ROOT/cmux.argv"
  FM_ARGV_LOG="$log" bash -c '
    . "$1/bin/backends/cmux.sh"
    fm_backend_cmux_target_ready() { fm_backend_cmux_parse_target "$1"; }
    fm_backend_cmux_cli() { printf "%s\0" "$@" > "$FM_ARGV_LOG"; }
    fm_backend_cmux_send_literal workspace:surface "$2" fm-worker
  ' _ "$ROOT" "$PAYLOAD"
  assert_argv "$log" cmux send --workspace workspace --surface surface -- "$PAYLOAD"
  pass "cmux transports the guarded Pi worker launch line as one literal payload"
}

test_orca_literal_transport() {
  local log="$TMP_ROOT/orca.argv"
  FM_ARGV_LOG="$log" bash -c '
    . "$1/bin/backends/orca.sh"
    fm_backend_orca_tool_check() { return 0; }
    fm_backend_orca_run_json() { printf "%s\0" "$@" > "$FM_ARGV_LOG"; }
    fm_backend_orca_send_literal terminal-1 "$2"
  ' _ "$ROOT" "$PAYLOAD"
  assert_argv "$log" orca orca terminal send --terminal terminal-1 --text "$PAYLOAD" --json
  pass "Orca transports the guarded Pi worker launch line as one literal payload"
}

test_tmux_literal_transport
test_herdr_literal_transport
test_zellij_literal_transport
test_cmux_literal_transport
test_orca_literal_transport

echo "# all Pi worker project-trust transport tests passed"
