#!/usr/bin/env bash
# Opt-in live guard for Pi's process-local project-trust override.
# It launches every installed Pi-family executable in a private tmux server with
# an isolated PI_CODING_AGENT_DIR and a synthetic project extension.
# No model prompt is submitted and no trust-dialog key is sent.
# The extension marker therefore proves that --approve bypassed the interactive
# trust prompt and loaded a protected project resource for this process only.
set -u

if [ "${FM_PI_WORKER_TRUST_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_PI_WORKER_TRUST_LIVE_E2E=1 to run the isolated real-Pi worker project-trust regression"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tmux >/dev/null 2>&1 || fail "tmux not found"

TMP_ROOT=$(fm_test_tmproot fm-pi-worker-trust-live-e2e)
SOCKET="fm-pi-worker-trust-$$"
REAL_HOME=${HOME:-}
CHECKED=0

cleanup_live_trust() {
  tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup_live_trust EXIT INT TERM

file_fingerprint() {  # <path>
  local path=$1
  if [ -e "$path" ] || [ -L "$path" ]; then
    printf 'present:'
    shasum -a 256 "$path" | awk '{print $1}'
  else
    printf 'absent\n'
  fi
}

REAL_TRUST="$REAL_HOME/.pi/agent/trust.json"
REAL_SETTINGS="$REAL_HOME/.pi/agent/settings.json"
REAL_TRUST_BEFORE=$(file_fingerprint "$REAL_TRUST")
REAL_SETTINGS_BEFORE=$(file_fingerprint "$REAL_SETTINGS")

run_installed_harness() {  # <pi|pi-signed> <absolute-executable>
  local harness=$1 executable=$2 case_dir project agent_dir isolated_home marker session version version_number
  local settings_before screen marker_text
  case_dir="$TMP_ROOT/$harness"
  project="$case_dir/synthetic-project"
  agent_dir="$case_dir/pi-agent"
  isolated_home="$case_dir/home"
  marker="$case_dir/project-extension.loaded"
  session="trust-${harness//-/_}"
  version=$($executable --version 2>/dev/null | head -n 1 | tr -d '\r')
  [ -n "$version" ] || version=unknown
  version_number=$(printf '%s\n' "$version" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
  [ -n "$version_number" ] || fail "$harness reported an unparseable version: $version"

  mkdir -p "$project/.pi/extensions" "$agent_dir" "$isolated_home"
  project=$(cd "$project" && pwd -P)
  printf '{\n  "defaultProjectTrust": "ask",\n  "quietStartup": false,\n  "lastChangelogVersion": "%s"\n}' \
    "$version_number" > "$agent_dir/settings.json"
  cp "$agent_dir/settings.json" "$case_dir/settings.before.json"
  settings_before=$(file_fingerprint "$agent_dir/settings.json")
  cat > "$project/.pi/extensions/scoped-trust-probe.js" <<'JS'
import { writeFileSync } from "node:fs";

export default function scopedTrustProbe() {
  writeFileSync(process.env.FM_PI_TRUST_PROBE, `loaded:${process.cwd()}\n`, "utf8");
}
JS

  tmux -L "$SOCKET" new-session -d -s "$session" -c "$project" -x 180 -y 50 \
    -e "HOME=$isolated_home" \
    -e "PI_CODING_AGENT_DIR=$agent_dir" \
    -e "PI_OFFLINE=1" \
    -e "PI_SKIP_VERSION_CHECK=1" \
    -e "FM_PI_TRUST_PROBE=$marker" \
    "$executable" --approve --offline --no-session --no-context-files --no-tools \
    || fail "$harness $version could not start in the isolated project"

  for _ in $(seq 1 100); do
    [ -s "$marker" ] && break
    sleep 0.1
  done
  screen=$(tmux -L "$SOCKET" capture-pane -p -t "$session" -S -200 2>/dev/null || true)
  [ -s "$marker" ] || fail \
    "$harness $version did not load the synthetic protected project extension without input; captured screen: $screen"
  marker_text=$(cat "$marker")
  [ "$marker_text" = "loaded:$project" ] || fail \
    "$harness $version loaded the project extension from an unexpected cwd: $marker_text"
  if printf '%s\n' "$screen" | grep -qiE 'trust[[:space:]]+(the[[:space:]]+)?project([[:space:]]+folder)?'; then
    fail "$harness $version displayed a project trust prompt despite --approve: $screen"
  fi
  [ ! -e "$agent_dir/trust.json" ] && [ ! -L "$agent_dir/trust.json" ] \
    || fail "$harness $version persisted a project trust store under the isolated PI_CODING_AGENT_DIR"
  if [ "$(file_fingerprint "$agent_dir/settings.json")" != "$settings_before" ]; then
    diff -u "$case_dir/settings.before.json" "$agent_dir/settings.json" >&2 || true
    fail "$harness $version changed the isolated global settings file"
  fi

  tmux -L "$SOCKET" kill-session -t "$session" >/dev/null 2>&1 || true
  pass "$harness $version loads a protected project extension without a trust prompt or persistent trust entry"
  CHECKED=$((CHECKED + 1))
}

for harness in pi pi-signed; do
  executable=$(command -v "$harness" 2>/dev/null || true)
  if [ -z "$executable" ] || [ ! -x "$executable" ]; then
    printf '# %s is not installed, so its live project-trust behavior is unverified here\n' "$harness"
    continue
  fi
  case "$executable" in
    /*) ;;
    *) executable=$(cd "$(dirname "$executable")" && pwd -P)/$(basename "$executable") ;;
  esac
  run_installed_harness "$harness" "$executable"
done

[ "$CHECKED" -gt 0 ] || fail "no Pi-family executable is installed, so the opt-in live guard proved nothing"
[ "$(file_fingerprint "$REAL_TRUST")" = "$REAL_TRUST_BEFORE" ] \
  || fail "the isolated live guard changed the real ~/.pi/agent/trust.json"
[ "$(file_fingerprint "$REAL_SETTINGS")" = "$REAL_SETTINGS_BEFORE" ] \
  || fail "the isolated live guard changed the real ~/.pi/agent/settings.json"

printf '# checked %s installed Pi-family executable(s); real trust and settings fingerprints stayed unchanged\n' "$CHECKED"
echo "# all live Pi worker project-trust assertions passed"
