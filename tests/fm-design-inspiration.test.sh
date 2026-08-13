#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-design-inspiration.sh"
TMP_ROOT=$(fm_test_tmproot fm-design-inspiration)
MANIFEST_SCHEMA='firstmate.design-inspiration/v1'
PREFERENCES_SCHEMA='firstmate.design-inspiration.preferences/v1'
SERVER_HOME=''
SERVER_PORT=''

command -v jq >/dev/null 2>&1 || fail 'jq is required for design-inspiration interface tests'
command -v node >/dev/null 2>&1 || fail 'node is required for design-inspiration gallery interface tests'

cleanup_suite() {
  if [ -n "$SERVER_HOME" ]; then
    FM_HOME="$SERVER_HOME" FM_DESIGN_GALLERY_PORT="$SERVER_PORT" "$SCRIPT" gallery stop >/dev/null 2>&1 || true
  fi
  fm_test_cleanup
}
trap cleanup_suite EXIT
trap 'cleanup_suite; exit 130' INT
trap 'cleanup_suite; exit 143' TERM

new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data"
  printf '%s\n' "$home"
}

library_root() {
  printf '%s/data/design-inspiration\n' "$1"
}

reference_record() {
  local id=$1 url=$2 review=${3:-approved} method=${4:-manual-research}
  jq -cn \
    --arg id "$id" \
    --arg url "$url" \
    --arg review "$review" \
    --arg method "$method" \
    '{
      id: $id,
      title: ("Title " + $id),
      kind: "reference-only",
      provenance: {
        source_url: $url,
        source_label: ("Source " + $id),
        captured_on: "2026-02-21",
        capture_method: $method
      },
      aesthetic_families: ["editorial", "minimal"],
      interface_types: ["dashboard", "landing-page"],
      platforms: ["responsive-web"],
      tags: ["grid", "typography"],
      source_health: "healthy",
      observations: [("Abstract rhythm from " + $id + ".")],
      emulate: [("Clear hierarchy from " + $id + ".")],
      avoid_copying: [("Distinctive source composition from " + $id + ".")],
      local_assets: [],
      review_status: $review
    }'
}

reusable_record() {
  local id=$1 url=$2 review=${3:-approved}
  jq -cn \
    --arg id "$id" \
    --arg url "$url" \
    --arg review "$review" \
    '{
      id: $id,
      title: ("Title " + $id),
      kind: "reusable-asset",
      provenance: {
        source_url: $url,
        source_label: ("Source " + $id),
        captured_on: "2026-02-21",
        capture_method: "captain-provided"
      },
      aesthetic_families: ["expressive"],
      interface_types: ["portfolio"],
      platforms: ["responsive-web"],
      tags: ["imagery"],
      source_health: "unknown",
      observations: [("Abstract asset quality from " + $id + ".")],
      emulate: [("Expressive contrast from " + $id + ".")],
      avoid_copying: [("Source-specific arrangement from " + $id + ".")],
      local_assets: [],
      review_status: $review,
      license: {
        name: "CC BY 4.0",
        url: "https://creativecommons.org/licenses/by/4.0/",
        attribution: "Example Creator",
        verified_on: "2026-02-21"
      }
    }'
}

write_records() {
  local file=$1
  shift
  {
    printf '{"schema":"%s","items":[' "$MANIFEST_SCHEMA"
    local separator='' record
    for record in "$@"; do
      printf '%s%s' "$separator" "$record"
      separator=,
    done
    printf ']}\n'
  } >"$file"
}

write_preferences() {
  local file=$1
  shift
  {
    printf '{"schema":"%s","preferences":[' "$PREFERENCES_SCHEMA"
    local separator='' preference
    for preference in "$@"; do
      printf '%s%s' "$separator" "$preference"
      separator=,
    done
    printf ']}\n'
  } >"$file"
}

preference_record() {
  local id=$1 favorite=${2:-false} avoid=${3:-false} notes=${4:-}
  jq -cn \
    --arg id "$id" \
    --argjson favorite "$favorite" \
    --argjson avoid "$avoid" \
    --arg notes "$notes" \
    '{
      id: $id,
      favorite: $favorite,
      avoid: $avoid,
      notes: $notes,
      ratings: {
        typography: 5,
        color: 4,
        density: 3,
        imagery: null,
        motion: 2,
        overall_affinity: 5
      }
    }'
}

expect_failure() {
  local needle=$1
  shift
  local output
  if output=$("$@" 2>&1); then
    fail "expected command to fail: $*"
  fi
  assert_contains "$output" "$needle" "failure did not explain '$needle'"
}

tree_digest() {
  local root=$1 file
  while IFS= read -r file; do
    shasum "$file"
  done < <(find "$root" -type f -print | LC_ALL=C sort)
}

choose_port() {
  node -e '
    const net = require("node:net");
    const server = net.createServer();
    server.listen(0, "127.0.0.1", () => {
      console.log(server.address().port);
      server.close();
    });
  '
}

test_init_and_help() {
  local home lib before after help license_rule
  home=$(new_home init)
  lib=$(library_root "$home")
  printf 'do-not-touch\n' >"$home/sibling.txt"

  FM_HOME="$home" "$SCRIPT" init >/dev/null
  assert_present "$lib/manifest.json" 'init did not create the manifest below the private root'
  assert_present "$lib/preferences.json" 'init did not create the separate private preferences file'
  assert_present "$lib/assets" 'init did not create the private assets directory'
  jq -e --arg schema "$MANIFEST_SCHEMA" '. == {schema:$schema, items:[]}' "$lib/manifest.json" >/dev/null \
    || fail 'init did not create the canonical empty source manifest'
  jq -e --arg schema "$PREFERENCES_SCHEMA" '. == {schema:$schema, preferences:[]}' "$lib/preferences.json" >/dev/null \
    || fail 'init did not create the canonical empty preferences document'

  before=$(tree_digest "$home")
  FM_HOME="$home" "$SCRIPT" init >/dev/null
  after=$(tree_digest "$home")
  [ "$before" = "$after" ] || fail 'repeated init overwrote private data'
  [ "$(cat "$home/sibling.txt")" = 'do-not-touch' ] || fail 'init changed a sibling outside the private root'

  help=$(FM_HOME=relative "$SCRIPT" --help)
  license_rule=$(printf "Forbidden when kind is \`%s\`." reference-only)
  assert_contains "$help" "$MANIFEST_SCHEMA" 'help omitted the manifest schema version'
  assert_contains "$help" "$PREFERENCES_SCHEMA" 'help omitted the preferences schema version'
  assert_contains "$help" "$license_rule" 'help omitted the reference-only license rule'
  assert_contains "$help" 'binds only to 127.0.0.1' 'help omitted the loopback-only binding contract'
  assert_contains "$help" 'no publish, share, account, telemetry, external proxy, or external fetch' 'help omitted no-network and no-share defaults'
  pass 'init is idempotent and help owns both private schemas and gallery safety'
}

test_malformed_manifest_and_duplicates() {
  local home lib alpha beta
  home=$(new_home malformed)
  lib=$(library_root "$home")
  FM_HOME="$home" "$SCRIPT" init >/dev/null

  printf '{not-json\n' >"$lib/manifest.json"
  expect_failure 'manifest.json is not valid JSON' env FM_HOME="$home" "$SCRIPT" validate

  alpha=$(reference_record alpha 'https://example.test/alpha')
  alpha=$(printf '%s' "$alpha" | jq -c 'del(.title)')
  write_records "$lib/manifest.json" "$alpha"
  expect_failure 'missing a required field' env FM_HOME="$home" "$SCRIPT" validate

  alpha=$(reference_record alpha 'https://example.test/alpha')
  alpha=$(printf '%s' "$alpha" | jq -c '.unexpected = true')
  write_records "$lib/manifest.json" "$alpha"
  expect_failure 'has an unknown field' env FM_HOME="$home" "$SCRIPT" validate

  alpha=$(reference_record repeated 'https://example.test/one')
  beta=$(reference_record repeated 'https://example.test/two')
  write_records "$lib/manifest.json" "$alpha" "$beta"
  expect_failure 'duplicate id: repeated' env FM_HOME="$home" "$SCRIPT" validate

  alpha=$(reference_record alpha 'https://example.test/shared')
  beta=$(reference_record beta 'https://example.test/shared')
  write_records "$lib/manifest.json" "$alpha" "$beta"
  expect_failure 'duplicate source URL: https://example.test/shared' env FM_HOME="$home" "$SCRIPT" validate

  alpha=$(reference_record alpha 'https://example.test/date')
  alpha=$(printf '%s' "$alpha" | jq -c '.provenance.captured_on = "2026-02-31"')
  write_records "$lib/manifest.json" "$alpha"
  expect_failure 'must be a real YYYY-MM-DD date' env FM_HOME="$home" "$SCRIPT" validate
  pass 'malformed strict records, duplicate IDs and URLs, and impossible dates are rejected'
}

test_manifest_facets_and_license_rules() {
  local home lib reference reusable
  home=$(new_home facets-license)
  lib=$(library_root "$home")
  FM_HOME="$home" "$SCRIPT" init >/dev/null

  reference=$(reference_record inspiration 'https://example.test/inspiration')
  write_records "$lib/manifest.json" "$reference"
  FM_HOME="$home" "$SCRIPT" validate >/dev/null || fail 'complete reference-only record should validate'

  reference=$(printf '%s' "$reference" | jq -c '.aesthetic_families = []')
  write_records "$lib/manifest.json" "$reference"
  expect_failure 'aesthetic_families must be a non-empty unique array' env FM_HOME="$home" "$SCRIPT" validate

  reference=$(reference_record inspiration 'https://example.test/inspiration')
  reference=$(printf '%s' "$reference" | jq -c '.license = {name:"CC0", url:"https://example.test/license", attribution:"None", verified_on:"2026-02-21"}')
  write_records "$lib/manifest.json" "$reference"
  expect_failure 'reference-only and must not carry a reuse license' env FM_HOME="$home" "$SCRIPT" validate

  reusable=$(reusable_record reusable 'https://example.test/reusable')
  reusable=$(printf '%s' "$reusable" | jq -c 'del(.license)')
  write_records "$lib/manifest.json" "$reusable"
  expect_failure 'reusable-asset and requires a complete license object' env FM_HOME="$home" "$SCRIPT" validate

  reusable=$(reusable_record reusable 'https://example.test/reusable')
  write_records "$lib/manifest.json" "$reusable"
  FM_HOME="$home" "$SCRIPT" validate >/dev/null || fail 'reusable asset with a complete explicit license should validate'
  pass 'gallery facets and reference-only versus reusable-license rules validate strictly'
}

test_asset_paths_hashes_and_symlinks() {
  local home lib record hash outside symlink_home data_symlink_home
  home=$(new_home assets)
  lib=$(library_root "$home")
  outside="$TMP_ROOT/outside-asset.png"
  printf 'outside image bytes\n' >"$outside"
  FM_HOME="$home" "$SCRIPT" init >/dev/null

  record=$(reference_record unsafe 'https://example.test/unsafe')
  record=$(printf '%s' "$record" | jq -c '.local_assets = [{path:"../outside.png",role:"thumbnail",sha256:("a"*64),added_on:"2026-02-21"}]')
  write_records "$lib/manifest.json" "$record"
  expect_failure 'path must be a safe relative path below assets/' env FM_HOME="$home" "$SCRIPT" validate

  record=$(reference_record missing 'https://example.test/missing')
  record=$(printf '%s' "$record" | jq -c '.local_assets = [{path:"assets/missing.png",role:"thumbnail",sha256:("a"*64),added_on:"2026-02-21"}]')
  write_records "$lib/manifest.json" "$record"
  expect_failure 'local asset does not exist: assets/missing.png' env FM_HOME="$home" "$SCRIPT" validate

  printf 'local preview bytes\n' >"$lib/assets/preview.png"
  hash=$(shasum -a 256 "$lib/assets/preview.png" | awk '{print $1}')
  record=$(reference_record preview 'https://example.test/preview')
  record=$(printf '%s' "$record" | jq -c --arg hash "$hash" '.local_assets = [{path:"assets/preview.png",role:"thumbnail",sha256:$hash,added_on:"2026-02-21"}]')
  write_records "$lib/manifest.json" "$record"
  FM_HOME="$home" "$SCRIPT" validate >/dev/null || fail 'safe existing hash-bound local preview should validate'
  printf 'changed\n' >>"$lib/assets/preview.png"
  expect_failure 'SHA-256 does not match provenance' env FM_HOME="$home" "$SCRIPT" validate

  rm -f "$lib/assets/preview.png"
  ln -s "$outside" "$lib/assets/preview.png"
  expect_failure 'symlink rejected below private library root' env FM_HOME="$home" "$SCRIPT" validate
  [ "$(cat "$outside")" = 'outside image bytes' ] || fail 'symlink validation changed the external target'

  symlink_home=$(new_home symlink-root)
  mkdir "$TMP_ROOT/external-library"
  ln -s "$TMP_ROOT/external-library" "$symlink_home/data/design-inspiration"
  expect_failure 'private library root must not be a symlink' env FM_HOME="$symlink_home" "$SCRIPT" init
  assert_absent "$TMP_ROOT/external-library/manifest.json" 'init followed a private-root symlink and wrote outside its root'

  data_symlink_home="$TMP_ROOT/data-symlink-home"
  mkdir "$data_symlink_home" "$TMP_ROOT/external-data"
  ln -s "$TMP_ROOT/external-data" "$data_symlink_home/data"
  expect_failure 'Firstmate data root must not be a symlink' env FM_HOME="$data_symlink_home" "$SCRIPT" init
  assert_absent "$TMP_ROOT/external-data/design-inspiration" 'init followed a data-root symlink and wrote outside its root'
  pass 'local asset provenance, traversal, hashes, and symlinks stop unsafe file access'
}

test_preferences_validation_and_deterministic_import_export() {
  local home lib alpha beta pref_alpha pref_beta exported_one exported_two canonical bad source_digest
  home=$(new_home preferences)
  lib=$(library_root "$home")
  FM_HOME="$home" "$SCRIPT" init >/dev/null
  alpha=$(reference_record alpha 'https://example.test/alpha')
  beta=$(reference_record beta 'https://example.test/beta')
  write_records "$lib/manifest.json" "$alpha" "$beta"

  pref_alpha=$(preference_record alpha true false 'Strong type, calm color.')
  pref_beta=$(preference_record beta false true 'Avoid the density.')
  write_preferences "$lib/preferences.json" "$pref_beta" "$pref_alpha"
  source_digest=$(shasum "$lib/manifest.json")
  exported_one=$(FM_HOME="$home" "$SCRIPT" preferences export)
  exported_two=$(FM_HOME="$home" "$SCRIPT" preferences export)
  [ "$exported_one" = "$exported_two" ] || fail 'preference export changed bytes across identical runs'
  [ "$(printf '%s' "$exported_one" | jq -r '.preferences[].id' | paste -sd, -)" = 'alpha,beta' ] || fail 'preference export did not sort stable IDs'

  canonical="$TMP_ROOT/preferences-import.json"
  printf '%s\n' "$exported_one" >"$canonical"
  FM_HOME="$home" "$SCRIPT" preferences import "$canonical" >/dev/null
  [ "$(shasum "$lib/manifest.json")" = "$source_digest" ] || fail 'preference import overwrote the neutral source manifest'
  [ "$(FM_HOME="$home" "$SCRIPT" preferences export)" = "$exported_one" ] || fail 'preference import/export was not deterministic'

  bad=$(preference_record alpha true true conflict)
  write_preferences "$canonical" "$bad"
  expect_failure 'cannot be both favorite and avoid' env FM_HOME="$home" "$SCRIPT" preferences import "$canonical"

  bad=$(preference_record absent false false unknown)
  write_preferences "$canonical" "$bad"
  expect_failure 'unknown preference id: absent' env FM_HOME="$home" "$SCRIPT" preferences import "$canonical"

  write_preferences "$canonical" "$pref_alpha" "$pref_alpha"
  expect_failure 'duplicate preference id: alpha' env FM_HOME="$home" "$SCRIPT" preferences import "$canonical"

  bad=$(printf '%s' "$pref_alpha" | jq -c '.ratings.motion = 6')
  write_preferences "$canonical" "$bad"
  expect_failure 'must be null or an integer from 1 through 5' env FM_HOME="$home" "$SCRIPT" preferences import "$canonical"
  pass 'private preferences validate separately and import/export deterministically without source mutation'
}

test_search_citation_and_brief_output() {
  local home lib alpha zulu search citation card_one card_two citation_id
  home=$(new_home outputs)
  lib=$(library_root "$home")
  FM_HOME="$home" "$SCRIPT" init >/dev/null
  zulu=$(reusable_record zulu 'https://example.test/zulu')
  alpha=$(reference_record alpha 'https://example.test/alpha')
  write_records "$lib/manifest.json" "$zulu" "$alpha"

  search=$(FM_HOME="$home" "$SCRIPT" search --aesthetic editorial --interface dashboard --platform responsive-web --tag grid --kind reference-only --health healthy hierarchy)
  assert_contains "$search" $'alpha\treference-only\tapproved\thealthy\teditorial,minimal\tdashboard,landing-page\tresponsive-web\tgrid,typography' 'compound gallery filters and search did not return alpha'
  assert_not_contains "$search" $'zulu\treusable-asset' 'compound gallery filters returned a nonmatching record'

  citation=$(FM_HOME="$home" "$SCRIPT" citation alpha)
  citation_id=$(printf "captain-approved private design reference \`%s\`" alpha)
  assert_contains "$citation" "$citation_id" 'citation omitted the stable reference ID'
  assert_contains "$citation" 'abstract inspiration only' 'citation blurred inspiration-only rights'
  assert_contains "$(FM_HOME="$home" "$SCRIPT" citation zulu)" 'recorded license and attribution' 'reusable citation omitted its license boundary'

  card_one=$(FM_HOME="$home" "$SCRIPT" render-card zulu alpha)
  card_two=$(FM_HOME="$home" "$SCRIPT" render-card alpha zulu)
  [ "$card_one" = "$card_two" ] || fail 'render-card depended on requested ID order'
  for heading in '## Aesthetic' '## References' '## Intent' '## Guardrails'; do
    assert_contains "$card_one" "$heading" "prompt card omitted $heading"
  done
  assert_not_contains "$card_one" "$home" 'prompt card leaked a temporary absolute path'
  assert_contains "$card_one" 'abstract inspiration only and no reusable asset rights' 'card blurred reference-only rights'
  assert_contains "$card_one" 'Its recorded license is' 'card omitted reusable license and attribution'

  alpha=$(reference_record seed 'https://example.test/seed' unreviewed automated-seed)
  write_records "$lib/manifest.json" "$alpha"
  expect_failure 'is unreviewed, not captain-approved' env FM_HOME="$home" "$SCRIPT" render-card seed
  assert_contains "$(FM_HOME="$home" "$SCRIPT" citation seed)" 'unreviewed candidate' 'seed citation omitted its unreviewed state'
  pass 'gallery filters, stable citations, four-pillar briefs, and approved-only selection are deterministic'
}

test_html_escaping_and_deterministic_rendering() {
  local home lib record html_one html_two hostile
  home=$(new_home html)
  lib=$(library_root "$home")
  FM_HOME="$home" "$SCRIPT" init >/dev/null
  hostile='<script>alert("pwn")</script> & source'
  record=$(reference_record hostile 'https://example.test/hostile')
  record=$(printf '%s' "$record" | jq -c --arg hostile "$hostile" '.title=$hostile | .provenance.source_label=$hostile | .observations=[$hostile] | .emulate=[$hostile] | .avoid_copying=[$hostile]')
  write_records "$lib/manifest.json" "$record"
  html_one=$(FM_HOME="$home" "$SCRIPT" gallery render)
  html_two=$(FM_HOME="$home" "$SCRIPT" gallery render)
  [ "$html_one" = "$html_two" ] || fail 'gallery render changed bytes across identical runs'
  assert_not_contains "$html_one" '<script>alert("pwn")</script>' 'gallery emitted unescaped untrusted source text'
  assert_contains "$html_one" '&lt;script&gt;alert(&quot;pwn&quot;)&lt;/script&gt; &amp; source' 'gallery did not visibly preserve escaped untrusted text'
  assert_contains "$html_one" 'No cached local preview' 'uncached entry did not render a truthful placeholder'
  assert_contains "$html_one" 'data-copy-id="hostile"' 'gallery omitted one-click stable ID copying'
  assert_contains "$html_one" 'data-copy-citation="hostile"' 'gallery omitted one-click citation copying'
  assert_contains "$html_one" 'Inspiration only - no asset reuse rights' 'gallery omitted truthful rights wording'
  assert_contains "$html_one" '<link rel="stylesheet" href="/style.css">' 'gallery omitted its local stylesheet'
  assert_contains "$html_one" 'tabindex="0"' 'gallery cards omitted keyboard focus'
  pass 'deterministic gallery HTML escapes untrusted data and carries offline, rights, and accessibility affordances'
}

test_read_commands_do_not_mutate_storage() {
  local home lib alpha before after outside
  home=$(new_home read-only)
  lib=$(library_root "$home")
  outside="$home/outside"
  mkdir "$outside"
  FM_HOME="$home" "$SCRIPT" init >/dev/null
  alpha=$(reference_record alpha 'https://example.test/read-only')
  write_records "$lib/manifest.json" "$alpha"
  before=$(tree_digest "$home")

  FM_HOME="$home" "$SCRIPT" validate >/dev/null
  FM_HOME="$home" "$SCRIPT" search alpha >/dev/null
  FM_HOME="$home" "$SCRIPT" citation alpha >/dev/null
  FM_HOME="$home" "$SCRIPT" render-index >/dev/null
  FM_HOME="$home" "$SCRIPT" render-card alpha >/dev/null
  FM_HOME="$home" "$SCRIPT" preferences export >/dev/null
  FM_HOME="$home" "$SCRIPT" gallery render >/dev/null

  after=$(tree_digest "$home")
  [ "$before" = "$after" ] || fail 'a read command mutated private storage or a sibling file'
  [ -z "$(find "$outside" -mindepth 1 -print -quit)" ] || fail 'a command wrote outside the private library root'
  pass 'validation, search, citation, exports, and rendering are read-only'
}

test_loopback_server_and_no_network_defaults() {
  local home lib alpha port start status page style app library cross_host outside_host external_count=0 response headers prefs before
  home=$(new_home server)
  lib=$(library_root "$home")
  FM_HOME="$home" "$SCRIPT" init >/dev/null
  alpha=$(reference_record alpha 'https://example.invalid/must-not-fetch')
  write_records "$lib/manifest.json" "$alpha"
  port=$(choose_port)
  SERVER_HOME=$home
  SERVER_PORT=$port

  start=$(FM_HOME="$home" FM_DESIGN_GALLERY_PORT="$port" "$SCRIPT" gallery start)
  assert_contains "$start" "running: http://127.0.0.1:$port/" 'gallery start omitted its stable loopback URL'
  status=$(FM_HOME="$home" FM_DESIGN_GALLERY_PORT="$port" "$SCRIPT" gallery status)
  assert_contains "$status" 'bound 127.0.0.1' 'gallery status did not verify loopback binding'

  if command -v lsof >/dev/null 2>&1; then
    outside_host=$(lsof -nP -a -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $9}')
    [ "$outside_host" = "127.0.0.1:$port" ] || fail "gallery listener was not loopback-only: $outside_host"
  fi

  headers="$TMP_ROOT/server-headers.txt"
  page=$(curl -fsS -D "$headers" "http://127.0.0.1:$port/")
  style=$(curl -fsS "http://127.0.0.1:$port/style.css")
  app=$(curl -fsS "http://127.0.0.1:$port/app.js")
  assert_contains "$page" 'No account, sharing, telemetry, external proxy, or external preview fetch.' 'served gallery omitted no-network/no-share disclosure'
  assert_contains "$(cat "$headers")" "connect-src 'self'" 'served gallery CSP did not forbid external network connections'
  assert_contains "$style" 'prefers-reduced-motion: reduce' 'served gallery stylesheet omitted reduced-motion support'
  assert_contains "$style" 'overflow-x: hidden' 'served gallery stylesheet omitted horizontal-overflow protection'
  assert_contains "$app" "['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown']" 'served gallery app omitted keyboard card navigation'
  assert_contains "$app" '## Aesthetic' 'served gallery app omitted the aesthetic brief pillar'
  assert_contains "$app" '## References' 'served gallery app omitted the references brief pillar'
  assert_contains "$app" '## Intent' 'served gallery app omitted the intent brief pillar'
  assert_contains "$app" '## Guardrails' 'served gallery app omitted the guardrails brief pillar'
  library=$(curl -fsS "http://127.0.0.1:$port/api/library")
  assert_contains "$library" 'https://example.invalid/must-not-fetch' 'library API omitted canonical source provenance'
  assert_contains "$library" '"preview_url":null' 'uncached source was not represented as a local placeholder state'

  if curl -sS -o /dev/null -w '%{http_code}' -H 'Host: example.test' "http://127.0.0.1:$port/" | grep -qx 421; then :; else
    fail 'gallery did not reject a non-loopback Host header'
  fi
  cross_host=$(curl -sS -o /dev/null -w '%{http_code}' -H "Origin: https://example.test" "http://127.0.0.1:$port/api/library")
  [ "$cross_host" = 403 ] || fail "gallery did not reject a cross-origin request: HTTP $cross_host"

  prefs=$(preference_record alpha true false 'Saved only in private preferences.')
  before=$(shasum "$lib/manifest.json")
  response=$(curl -fsS -X POST \
    -H 'Content-Type: application/json' \
    -H "X-Firstmate-Token: $(printf '%s' "$library" | jq -r '.csrf_token')" \
    --data "$(jq -cn --argjson preference "$prefs" '{preference:$preference}')" \
    "http://127.0.0.1:$port/api/preferences")
  assert_contains "$response" 'Saved only in private preferences.' 'gallery did not persist a private captain annotation'
  [ "$(shasum "$lib/manifest.json")" = "$before" ] || fail 'gallery annotation overwrote the neutral source manifest'
  jq -e '.preferences[0].id == "alpha" and .preferences[0].favorite == true' "$lib/preferences.json" >/dev/null \
    || fail 'gallery annotation was not persisted to the separate private preferences file'

  FM_HOME="$home" FM_DESIGN_GALLERY_PORT="$port" "$SCRIPT" gallery stop >/dev/null
  SERVER_HOME=''
  if FM_HOME="$home" FM_DESIGN_GALLERY_PORT="$port" "$SCRIPT" gallery status >/dev/null 2>&1; then
    fail 'gallery still reported running after an explicit stop'
  fi
  [ "$external_count" -eq 0 ] || fail 'gallery made an external request'
  pass 'gallery lifecycle is loopback-only, origin-bound, offline by default, and privately mutable only'
}

test_init_and_help
test_malformed_manifest_and_duplicates
test_manifest_facets_and_license_rules
test_asset_paths_hashes_and_symlinks
test_preferences_validation_and_deterministic_import_export
test_search_citation_and_brief_output
test_html_escaping_and_deterministic_rendering
test_read_commands_do_not_mutate_storage
test_loopback_server_and_no_network_defaults
