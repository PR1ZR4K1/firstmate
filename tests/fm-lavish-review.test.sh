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
  assert_grep "must ignore .lavish/" "$TMP_ROOT/unignored.out" \
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
  pass "Git ignore and symlink guards keep Lavish artifacts inside the intended local review root"
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
test_generated_workers_prepare_but_never_present
