#!/usr/bin/env bash
# Behavior tests for Firstmate's Lavish routing, private artifact boundary, and
# worker-versus-captain review ownership.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELPER="$ROOT/bin/fm-lavish-review.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-lavish-review)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

expect_recommendation() {  # <expected> <shape>
  local expected=$1 shape=$2 actual
  actual=$("$HELPER" recommend "$shape") \
    || fail "review shape was refused: $shape"
  [ "$actual" = "$expected" ] \
    || fail "review shape $shape returned $actual instead of $expected"
}

test_routing_is_closed_and_keeps_simple_chat() {
  local shape out rc=0
  for shape in simple-yes-no routine-notification; do
    expect_recommendation chat "$shape"
  done
  for shape in explicit-visual multi-option-decision structured-input comparison \
    plan architecture data-flow ui-review rich-report rich-work-description; do
    expect_recommendation lavish "$shape"
  done
  out=$("$HELPER" recommend ambiguous 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "unknown review shape silently selected a presentation"
  assert_contains "$out" "unknown review shape" \
    "unknown review shape refusal did not explain the closed routing set"
  pass "Lavish routing keeps simple questions and routine notices in chat and selects rich review shapes explicitly"
}

test_private_local_artifact_boundary() {
  local home fakebin calls out artifact checked outside rc=0
  home="$TMP_ROOT/private-home"
  mkdir -p "$home/state"
  fakebin=$(fm_fakebin "$TMP_ROOT/no-side-effects")
  calls="$TMP_ROOT/unexpected-side-effects"
  for command in lavish-axi curl open xdg-open; do
    cat > "$fakebin/$command" <<SH
#!/usr/bin/env bash
printf '%s\\n' '$command' >> '$calls'
exit 99
SH
    chmod +x "$fakebin/$command"
  done

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$HELPER" prepare "$home" sample-review) \
    || fail "private home review path could not be prepared"
  artifact=$(printf '%s\n' "$out" | awk -F ': ' '$1 == "artifact" { print $2 }')
  [ "$artifact" = "$home/.lavish/sample-review/review.html" ] \
    || fail "prepared artifact escaped the private .lavish root: $artifact"
  assert_absent "$artifact" "prepare must not impose or overwrite an HTML design"
  assert_absent "$calls" "preparing a private review invoked an external or Lavish lifecycle command"

  printf '<!doctype html><html><body><h1>Sample</h1></body></html>\n' > "$artifact"
  checked=$(FM_HOME="$home" "$HELPER" check "$artifact") \
    || fail "prepared private artifact did not pass its pre-arm check"
  [ "$checked" = "$artifact" ] || fail "artifact check returned a different path: $checked"

  outside="$TMP_ROOT/outside"
  mkdir -p "$outside"
  rc=0
  FM_HOME="$home" "$HELPER" prepare "$outside" sample-review > "$TMP_ROOT/outside.out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "non-Git path outside FM_HOME was accepted as a review root"
  assert_no_grep 'artifact:' "$TMP_ROOT/outside.out" \
    "refused outside root still published an artifact path"

  rc=0
  FM_HOME="$home" "$HELPER" prepare "$home" ../escape > "$TMP_ROOT/slug.out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "path traversal was accepted as a review slug"
  assert_absent "$home/escape" "invalid review slug created a path outside .lavish"
  pass "Lavish review preparation is private, local, design-neutral, and free of open, poll, share, or network side effects"
}

test_git_ignore_and_symlink_guards() {
  local home project artifact out rc=0
  home="$TMP_ROOT/guard-home"
  project="$TMP_ROOT/subject-project"
  mkdir -p "$home" "$project"
  git -C "$project" init -q

  FM_HOME="$home" "$HELPER" prepare "$project" subject-ui > "$TMP_ROOT/unignored.out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "Git review root without a .lavish ignore rule was accepted"
  assert_grep "must ignore every Lavish review file" "$TMP_ROOT/unignored.out" \
    "unignored Git root refusal did not explain the privacy requirement"

  printf '.lavish/\n' > "$project/.gitignore"
  out=$(FM_HOME="$home" "$HELPER" prepare "$project" subject-ui) \
    || fail "ignored Git review root was refused"
  artifact=$(printf '%s\n' "$out" | awk -F ': ' '$1 == "artifact" { print $2 }')
  printf '<!doctype html><html><body>Subject UI</body></html>\n' > "$artifact"
  FM_HOME="$home" "$HELPER" check "$artifact" >/dev/null \
    || fail "ignored Git review artifact failed its path check"
  git -C "$project" check-ignore -q -- .lavish/subject-ui/review.html \
    || fail "prepared Git artifact was not actually ignored"
  rc=0
  FM_HOME="$home" "$HELPER" check "$project/.lavish/subject-ui/../subject-ui/review.html" \
    > "$TMP_ROOT/nonphysical-artifact.out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "non-physical artifact alias passed the pre-arm check"
  assert_grep "physical absolute prepared path" "$TMP_ROOT/nonphysical-artifact.out" \
    "non-physical artifact refusal did not name the canonical-path requirement"
  printf 'outside asset\n' > "$TMP_ROOT/outside-asset.png"
  ln -s "$TMP_ROOT/outside-asset.png" "$project/.lavish/subject-ui/linked-asset.png"
  rc=0
  FM_HOME="$home" "$HELPER" check "$artifact" > "$TMP_ROOT/asset-symlink.out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "symlinked sibling asset passed the pre-arm check"
  assert_grep "cannot contain symlinks or special files" "$TMP_ROOT/asset-symlink.out" \
    "symlinked asset refusal did not identify the unsafe review tree"
  rm -f "$project/.lavish/subject-ui/linked-asset.png"

  printf 'outside hardlink asset\n' > "$TMP_ROOT/outside-hardlink-asset.png"
  ln "$TMP_ROOT/outside-hardlink-asset.png" "$project/.lavish/subject-ui/hardlinked-asset.png"
  rc=0
  FM_HOME="$home" "$HELPER" check "$artifact" > "$TMP_ROOT/asset-hardlink.out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "hardlinked sibling asset passed the pre-arm check"
  assert_grep "single-link regular file" "$TMP_ROOT/asset-hardlink.out" \
    "hardlinked asset refusal did not identify the confinement violation"
  rc=0
  FM_HOME="$home" "$HELPER" prepare "$project" subject-ui > "$TMP_ROOT/prepare-asset-hardlink.out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "prepare accepted an existing hardlinked sibling asset"
  rm -f "$project/.lavish/subject-ui/hardlinked-asset.png"

  mkdir -p "$project/.lavish/hardlinked-ui"
  printf '<html>outside hardlink target</html>\n' > "$TMP_ROOT/outside-hardlink-target.html"
  ln "$TMP_ROOT/outside-hardlink-target.html" "$project/.lavish/hardlinked-ui/review.html"
  rc=0
  FM_HOME="$home" "$HELPER" prepare "$project" hardlinked-ui > "$TMP_ROOT/artifact-hardlink.out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "prepare accepted a hardlinked review artifact"
  assert_grep "single-link regular file" "$TMP_ROOT/artifact-hardlink.out" \
    "hardlinked artifact refusal did not identify the confinement violation"
  rc=0
  FM_HOME="$home" "$HELPER" check "$project/.lavish/hardlinked-ui/review.html" \
    > "$TMP_ROOT/check-artifact-hardlink.out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "pre-arm check accepted a hardlinked review artifact"

  mkdir -p "$project/.lavish/tracked-ui"
  printf '<html>tracked private review</html>\n' > "$project/.lavish/tracked-ui/review.html"
  git -C "$project" add -f .lavish/tracked-ui/review.html
  rc=0
  FM_HOME="$home" "$HELPER" prepare "$project" tracked-ui > "$TMP_ROOT/tracked-artifact.out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "prepare accepted a tracked private review artifact"
  assert_grep "must be untracked" "$TMP_ROOT/tracked-artifact.out" \
    "tracked review refusal did not name the index boundary"
  git -C "$project" reset -q -- .lavish/tracked-ui/review.html
  printf 'tracked asset\n' > "$project/.lavish/subject-ui/tracked.css"
  git -C "$project" add -f .lavish/subject-ui/tracked.css
  rc=0
  FM_HOME="$home" "$HELPER" check "$artifact" > "$TMP_ROOT/tracked-asset.out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "pre-arm check accepted a tracked sibling asset"
  assert_grep "must be untracked" "$TMP_ROOT/tracked-asset.out" \
    "tracked asset refusal did not identify the complete index check"
  git -C "$project" reset -q -- .lavish/subject-ui/tracked.css
  rm -f "$project/.lavish/subject-ui/tracked.css"

  printf '.lavish/**\n!.lavish/negated-ui/\n!.lavish/negated-ui/review.html\n' > "$project/.gitignore"
  rc=0
  FM_HOME="$home" "$HELPER" prepare "$project" negated-ui > "$TMP_ROOT/negated-artifact.out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "prepare accepted an artifact negated out of the ignore rules"
  assert_grep "must ignore every Lavish review file" "$TMP_ROOT/negated-artifact.out" \
    "negated artifact refusal did not name the exact-path ignore boundary"

  printf '.lavish/**\n!.lavish/subject-ui/\n.lavish/subject-ui/**\n!.lavish/subject-ui/public.txt\n' > "$project/.gitignore"
  printf 'unignored asset\n' > "$project/.lavish/subject-ui/public.txt"
  rc=0
  FM_HOME="$home" "$HELPER" check "$artifact" > "$TMP_ROOT/negated-asset.out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "pre-arm check accepted an asset negated out of ignore rules"
  assert_grep "must ignore every Lavish review file" "$TMP_ROOT/negated-asset.out" \
    "negated asset refusal did not identify the complete-tree privacy check"
  rm -f "$project/.lavish/subject-ui/public.txt"
  printf '.lavish/\n' > "$project/.gitignore"

  rm -f "$artifact"
  printf '<html>outside target</html>\n' > "$TMP_ROOT/outside-target.html"
  ln -s "$TMP_ROOT/outside-target.html" "$artifact"
  rc=0
  FM_HOME="$home" "$HELPER" check "$artifact" > "$TMP_ROOT/artifact-symlink.out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "symlinked review artifact passed the pre-arm check"
  assert_grep "real regular file" "$TMP_ROOT/artifact-symlink.out" \
    "symlinked artifact refusal did not identify the unsafe file"

  rm -rf "$project/.lavish"
  mkdir -p "$TMP_ROOT/elsewhere-lavish"
  ln -s "$TMP_ROOT/elsewhere-lavish" "$project/.lavish"
  rc=0
  FM_HOME="$home" "$HELPER" prepare "$project" linked-root > "$TMP_ROOT/root-symlink.out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "symlinked .lavish root was accepted"
  assert_grep "unsafe .lavish root" "$TMP_ROOT/root-symlink.out" \
    "symlinked .lavish refusal did not identify the unsafe root"
  pass "Git index, ignore, symlink, and hardlink guards confine the complete Lavish review tree"
}

test_private_runtime_envelope() {
  local home fakebin log state_dir port_one port_two mode out before after rc=0
  home="$TMP_ROOT/runtime-home"
  mkdir -p "$home/state"
  fakebin=$(fm_fakebin "$TMP_ROOT/runtime-bin")
  log="$TMP_ROOT/runtime-envelope.log"
  cat > "$fakebin/lavish-axi" <<SH
#!/usr/bin/env bash
printf 'state=%s\n' "\${LAVISH_AXI_STATE_DIR-unset}" >> "$log"
printf 'host=%s\n' "\${LAVISH_AXI_HOST-unset}" >> "$log"
printf 'link=%s\n' "\${LAVISH_AXI_LINK_HOST-unset}" >> "$log"
printf 'allowed=%s\n' "\${LAVISH_AXI_ALLOWED_HOSTS-unset}" >> "$log"
printf 'port=%s\n' "\${LAVISH_AXI_PORT-unset}" >> "$log"
printf 'telemetry=%s\n' "\${LAVISH_AXI_TELEMETRY-unset}" >> "$log"
printf 'publish-token=%s\n' "\${LAVISH_AXI_HTML_APP_TOKEN-unset}" >> "$log"
printf 'argv=' >> "$log"
printf '<%s>' "\$@" >> "$log"
printf '\n' >> "$log"
printf 'private state\n' > "\$LAVISH_AXI_STATE_DIR/fixture-state"
SH
  chmod +x "$fakebin/lavish-axi"

  PATH="$fakebin:$PATH" FM_HOME="$home" \
    LAVISH_AXI_STATE_DIR="$TMP_ROOT/ambient-state" \
    LAVISH_AXI_HOST=0.0.0.0 LAVISH_AXI_LINK_HOST=public.example \
    LAVISH_AXI_ALLOWED_HOSTS='*' LAVISH_AXI_PORT=61234 \
    LAVISH_AXI_TELEMETRY=on LAVISH_AXI_HTML_APP_TOKEN=secret \
    "$HELPER" run --help
  PATH="$fakebin:$PATH" FM_HOME="$home" LAVISH_AXI_PORT=60000 \
    "$HELPER" run design

  state_dir="$home/state/lavish-axi"
  assert_grep "state=$state_dir" "$log" \
    "Lavish commands did not share the home-scoped state directory"
  [ "$(grep -c "^state=$state_dir$" "$log")" = 2 ] \
    || fail "Lavish lifecycle commands did not use one consistent state identity"
  assert_no_grep "$TMP_ROOT/ambient-state" "$log" \
    "ambient Lavish state escaped the Firstmate home"
  assert_grep 'host=127.0.0.1' "$log" "Lavish runtime did not force loopback binding"
  assert_grep 'link=127.0.0.1' "$log" "Lavish runtime emitted a non-loopback link"
  assert_grep 'allowed=127.0.0.1 localhost' "$log" \
    "Lavish runtime did not close the allowed-host set"
  assert_grep 'telemetry=off' "$log" "Lavish runtime did not disable telemetry"
  assert_grep 'publish-token=unset' "$log" \
    "ambient publication credentials crossed the private runtime envelope"
  port_one=$(awk -F= '$1 == "port" { print $2; exit }' "$log")
  port_two=$(awk -F= '$1 == "port" { value=$2 } END { print value }' "$log")
  [ "$port_one" = "$port_two" ] || fail "Lavish runtime port changed between lifecycle commands"
  [ "$port_one" != 61234 ] && [ "$port_one" != 60000 ] \
    || fail "ambient Lavish port overrode the home-scoped server identity"
  case "$port_one" in ''|*[!0-9]*) fail "Lavish runtime port is not numeric: $port_one" ;; esac
  [ "$port_one" -ge 20000 ] && [ "$port_one" -lt 50000 ] \
    || fail "Lavish runtime port escaped its deterministic private range: $port_one"
  mode=$(PATH="${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" bash -c \
    '. "$1/bin/fm-pr-lib.sh"; fm_pr_file_mode "$2"' _ "$ROOT" "$state_dir/fixture-state")
  assert_contains "$mode" 600 "Lavish runtime files are not owner-only"
  mode=$(PATH="${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" bash -c \
    '. "$1/bin/fm-pr-lib.sh"; fm_pr_file_mode "$2"' _ "$ROOT" "$state_dir")
  assert_contains "$mode" 700 "Lavish runtime directory is not owner-only"

  before=$(grep -c '^argv=' "$log")
  mkdir -p "$TMP_ROOT/outside-runtime-root/.lavish/outside"
  printf '<html>outside private root</html>\n' \
    > "$TMP_ROOT/outside-runtime-root/.lavish/outside/review.html"
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$HELPER" run open \
    "$TMP_ROOT/outside-runtime-root/.lavish/outside/review.html" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "Lavish runtime opened an artifact outside the private review root"
  assert_contains "$out" "neither the active FM_HOME nor a Git worktree root" \
    "outside runtime artifact refusal did not name the private root"
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$HELPER" run export "$home/.lavish/missing/review.html" --out "$TMP_ROOT/export.html" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "Lavish runtime accepted an export path override"
  assert_contains "$out" "export path overrides are not allowed" \
    "export override refusal did not name the confinement boundary"
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$HELPER" run share "$state_dir/fixture-state" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "private Lavish runtime exposed external sharing"
  assert_contains "$out" "does not support external sharing" \
    "share refusal did not name the private workflow boundary"
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$HELPER" run setup hooks 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "Lavish runtime allowed global setup mutation"
  assert_contains "$out" "does not modify global tool setup" \
    "setup refusal did not name the global-state boundary"
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$HELPER" run server 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "Lavish runtime allowed direct server startup"
  assert_contains "$out" "owns server startup" \
    "server refusal did not name the lifecycle boundary"
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$HELPER" run publish "$home/.lavish/future/review.html" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "Lavish runtime passed an unknown future command through"
  assert_contains "$out" "unsupported command" \
    "unknown command refusal did not preserve the closed runtime surface"
  after=$(grep -c '^argv=' "$log")
  [ "$before" = "$after" ] || fail "refused Lavish commands still invoked the installed CLI"

  rc=0
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$HELPER" run stop --port 49999 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "Lavish runtime accepted a CLI port identity override"
  assert_contains "$out" "port overrides are not allowed" \
    "Lavish port override refusal did not name the identity boundary"
  [ "$(grep -c '^argv=' "$log")" = "$before" ] \
    || fail "Lavish override refusal still invoked the installed CLI"
  pass "Lavish lifecycle commands use one owner-only loopback runtime with telemetry disabled"
}

test_generated_workers_prepare_but_never_present() {
  local home ship scout charter
  home="$TMP_ROOT/brief-home"
  mkdir -p "$home/data" "$home/state"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$BRIEF" lavish-ship sample --mode no-mistakes >/dev/null
  ship="$home/data/lavish-ship/brief.md"
  assert_grep "# Lavish review boundary" "$ship" \
    "ship brief omitted the worker-side Lavish boundary"
  assert_grep "return that path or rebuildable material to firstmate" "$ship" \
    "ship worker was not told to hand the artifact to firstmate"
  assert_grep "Never address the captain through the artifact" "$ship" \
    "ship worker may address the captain through a visual artifact"
  assert_grep "run \`lavish-axi poll\` directly" "$ship" \
    "ship worker was not forbidden from direct destructive polling"
  assert_grep "answer your own finding" "$ship" \
    "ship worker may answer its own review finding"
  assert_grep "act on visual feedback as approval" "$ship" \
    "ship worker may treat visual feedback as authority"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$BRIEF" lavish-scout sample --scout >/dev/null
  scout="$home/data/lavish-scout/brief.md"
  assert_grep "# Lavish review boundary" "$scout" \
    "scout brief omitted the worker-side Lavish boundary"
  assert_grep "Only firstmate owns the captain-facing review and approved callback" "$scout" \
    "scout worker was allowed to create a parallel captain wait path"
  assert_grep "publish or share it" "$scout" \
    "scout worker was allowed to publish private review material"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SECONDMATE_CHARTER='Review sample material.' \
    "$BRIEF" lavish-mate --secondmate --no-projects >/dev/null
  charter="$home/data/lavish-mate/brief.md"
  assert_grep "return its path or a rebuildable report to the main firstmate" "$charter" \
    "routed secondmate review did not return through the main firstmate"
  assert_grep "never open, poll, publish, or share a captain-facing review" "$charter" \
    "routed secondmate could bypass the main captain liaison"
  pass "generated worker instructions allow private artifact preparation without captain communication, polling, sharing, self-answer, or authority expansion"
}

test_routing_is_closed_and_keeps_simple_chat
test_private_local_artifact_boundary
test_git_ignore_and_symlink_guards
test_private_runtime_envelope
test_generated_workers_prepare_but_never_present
