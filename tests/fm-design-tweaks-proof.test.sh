#!/usr/bin/env bash
# Public-interface regression for the synthetic development-only design tweaks proof.
# Set FM_DESIGN_TWEAKS_BROWSER_E2E=1 to include Chrome behavior, accessibility,
# responsive, network, lifecycle, and production-runtime checks.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FIXTURE="$ROOT/tests/fixtures/fm-design-tweaks-proof"
TMP_ROOT=$(fm_test_tmproot fm-design-tweaks-proof)
LAB="$TMP_ROOT/fixture"
SERVER_PIDS=()
BROWSER_SESSIONS=()

cleanup_suite() {
  local pid session
  for session in "${BROWSER_SESSIONS[@]:-}"; do
    [ -n "$session" ] || continue
    CHROME_DEVTOOLS_AXI_SESSION="$session" chrome-devtools-axi stop >/dev/null 2>&1 || true
  done
  for pid in "${SERVER_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
  done
  fm_test_cleanup
}
trap cleanup_suite EXIT
trap 'cleanup_suite; exit 130' INT
trap 'cleanup_suite; exit 143' TERM

command -v node >/dev/null 2>&1 || fail 'node is required for the design tweaks proof'
command -v npm >/dev/null 2>&1 || fail 'npm is required for the design tweaks proof'
command -v jq >/dev/null 2>&1 || fail 'jq is required for the design tweaks proof'
command -v python3 >/dev/null 2>&1 || fail 'python3 is required for the design tweaks browser proof'

mkdir -p "$LAB"
(
  cd "$FIXTURE"
  tar --exclude='./node_modules' --exclude='./dist' --exclude='./dist-development' -cf - .
) | (
  cd "$LAB"
  tar -xf -
)

(
  cd "$LAB"
  npm ci --ignore-scripts --no-audit --no-fund >/dev/null
)

node - "$LAB" "$ROOT" <<'NODE'
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const root = process.argv[2];
const repo = process.argv[3];
const pkg = JSON.parse(fs.readFileSync(path.join(root, 'package.json')));
const lock = JSON.parse(fs.readFileSync(path.join(root, 'package-lock.json')));
const sources = JSON.parse(fs.readFileSync(path.join(root, 'SOURCES.lock.json')));
const installed = JSON.parse(fs.readFileSync(path.join(root, 'node_modules/tweakpane/package.json')));
const license = fs.readFileSync(path.join(root, sources.runtimePackage.localLicenseCopy));
assert.equal(pkg.dependencies.tweakpane, '4.0.5');
assert.equal(pkg.devDependencies.vite, '8.2.1');
assert.equal(lock.packages['node_modules/tweakpane'].version, '4.0.5');
assert.equal(lock.packages['node_modules/tweakpane'].integrity, sources.runtimePackage.npmIntegrity);
assert.equal(installed.version, '4.0.5');
assert.equal(installed.license, 'MIT');
assert.equal(crypto.createHash('sha256').update(license).digest('hex'), sources.runtimePackage.localLicenseSha256);
assert.equal(sources.runtimePackage.inspectedTarballSha256, '8cf819860e51128ea6031528c2ec6a92413785928d49c16170562d3f9f39134d');
assert.match(sources.runtimePackage.digestQualification, /not publisher signing/i);
assert.deepEqual(sources.runtimePackage.plugins, []);

const visualRoot = path.join(repo, 'docs/verification/assets/design-tweaks-proof');
const visualManifest = JSON.parse(fs.readFileSync(path.join(visualRoot, 'manifest.json')));
assert.equal(visualManifest.schema, 'firstmate.design-tweaks-visual-evidence/v1');
assert.deepEqual(visualManifest.conditions, {
  fontsSettled: true,
  animationsDisabled: true,
  transitionsDisabled: true,
  caretHidden: true,
  content: 'deterministic-synthetic-only',
});
assert.equal(visualManifest.comparisonTolerance.changedPixelPercentMaximum, 0.1);
assert.equal(visualManifest.comparisonTolerance.perChannelDeltaMaximum, 8);
assert.equal(visualManifest.captures.length, 4);
for (const capture of visualManifest.captures) {
  assert.equal(path.basename(capture.path), capture.path);
  const bytes = fs.readFileSync(path.join(visualRoot, capture.path));
  assert.equal(bytes.subarray(0, 8).toString('hex'), '89504e470d0a1a0a');
  assert.equal(bytes.readUInt32BE(16), capture.pixelWidth);
  assert.equal(bytes.readUInt32BE(20), capture.pixelHeight);
  assert.equal(crypto.createHash('sha256').update(bytes).digest('hex'), capture.sha256);
  assert.ok(['native', 'tweakpane-4.0.5'].includes(capture.renderer));
  assert.ok(['baseline', 'non-default', 'non-default-localization'].includes(capture.preset));
}
NODE
pass 'exact Tweakpane 4.0.5 pin, npm integrity, inspected tarball evidence, MIT attribution, and digest qualification agree'
pass 'desktop and mobile baseline and non-default visual evidence matches its deterministic manifest'

core_output=$(cd "$LAB" && npm run test:core 2>&1) || fail "core interface tests failed: $core_output"
assert_contains "$core_output" 'pass 10' 'core interface corpus did not run all expected cases'
assert_contains "$core_output" 'fail 0' 'core interface corpus reported a failure'
pass 'canonical presets, invalid imports, fixture isolation, allowlist denial, reset, and disposal pass through the public core API'

production_output=$(cd "$LAB" && npm run build:assert 2>&1) || fail "production build assertion failed: $production_output"
production_json=$(printf '%s\n' "$production_output" | tail -1)
printf '%s' "$production_json" | jq -e '
  .assertion == "firstmate.design-tweaks-production-absence/v1"
  and .assetCount > 0
  and .disabledTweaksBytes == 0
  and .sourceMaps == 0
  and .reachableEntries == ["index.html"]
' >/dev/null || fail "production absence evidence was incomplete: $production_json"
pass 'production assets have zero disabled-tweaks bytes, no source maps, and no reachable development-controls chunk'

if [ "${FM_DESIGN_TWEAKS_BROWSER_E2E:-0}" != 1 ]; then
  pass 'live Chrome corpus is available through FM_DESIGN_TWEAKS_BROWSER_E2E=1'
  exit 0
fi

command -v chrome-devtools-axi >/dev/null 2>&1 || fail 'chrome-devtools-axi is required for the requested browser corpus'

dev_build=$(cd "$LAB" && npm run build:development 2>&1) || fail "development evidence build failed: $dev_build"
assert_contains "$dev_build" 'built in' 'development evidence build did not complete'

source_digest() {
  (
    cd "$LAB"
    find . -type f \
      ! -path './node_modules/*' \
      ! -path './dist/*' \
      ! -path './dist-development/*' \
      -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256
  )
}

choose_port() {
  node -e '
    const net = require("node:net");
    const server = net.createServer();
    server.listen(0, "127.0.0.1", () => {
      process.stdout.write(String(server.address().port));
      server.close();
    });
  '
}

start_server() {
  local directory=$1 port=$2 log=$3 attempt=0
  python3 -m http.server "$port" --bind 127.0.0.1 --directory "$directory" >"$log" 2>&1 &
  SERVER_PIDS+=("$!")
  while [ "$attempt" -lt 200 ]; do
    if curl -fsS "http://127.0.0.1:$port/" >/dev/null 2>&1; then return 0; fi
    sleep 0.1
    attempt=$((attempt + 1))
  done
  fail "local evidence server did not become ready on port $port: $(cat "$log")"
}

before_source=$(source_digest)
before_repo=$(git -C "$ROOT" status --porcelain=v1 --untracked-files=all)
DEV_PORT=$(choose_port)
start_server "$LAB/dist-development" "$DEV_PORT" "$TMP_ROOT/dev-server.log"
PROD_PORT=$(choose_port)
start_server "$LAB/dist" "$PROD_PORT" "$TMP_ROOT/prod-server.log"

BROWSER_SESSION="fm-tweaks-$PPID-$$"
BROWSER_SESSIONS+=("$BROWSER_SESSION")
CHROME_DEVTOOLS_AXI_SESSION="$BROWSER_SESSION" chrome-devtools-axi open "http://127.0.0.1:$DEV_PORT/" >/dev/null
CHROME_DEVTOOLS_AXI_SESSION="$BROWSER_SESSION" chrome-devtools-axi resize 1440 900 >/dev/null

browser_result=$(CHROME_DEVTOOLS_AXI_SESSION="$BROWSER_SESSION" chrome-devtools-axi run <<'EOF'
await page.wait('#fm-tweaks-panel', 30000);
await page.eval(async () => {
  await document.fonts.ready;
  const style = document.createElement('style');
  style.id = 'fm-static-evidence';
  style.textContent = '*,*::before,*::after{animation:none!important;transition:none!important;scroll-behavior:auto!important}';
  document.head.append(style);
});
await page.wait(100);

const initial = await page.eval(() => {
  const resources = performance.getEntriesByType('resource').map((entry) => ({ name: entry.name, initiatorType: entry.initiatorType }));
  const panel = document.querySelector('#fm-tweaks-panel');
  const region = document.querySelector('.fixture-region').getBoundingClientRect();
  const panelRect = panel.getBoundingClientRect();
  const overlap = Math.max(0, Math.min(region.right, panelRect.right) - Math.max(region.left, panelRect.left))
    * Math.max(0, Math.min(region.bottom, panelRect.bottom) - Math.max(region.top, panelRect.top));
  return {
    diagnostics: window.__FM_TWEAKS_TEST__.diagnostics(),
    resources,
    pageFits: document.documentElement.scrollWidth === document.documentElement.clientWidth,
    panelTargetOverlap: overlap,
    storageKeys: Object.keys(localStorage).sort(),
  };
});
const nativeAccessibility = await page.eval(() => {
  const controls = [...document.querySelectorAll('[data-renderer="native"] input, [data-renderer="native"] select')];
  function name(element) {
    return (element.getAttribute('aria-label') || [...(element.labels || [])].map((label) => label.textContent).join(' ')).trim();
  }
  function adequateTarget(element) {
    const rect = element.getBoundingClientRect();
    if (rect.width >= 44 && rect.height >= 44) return true;
    return [...(element.labels || [])].some((label) => {
      const labelRect = label.getBoundingClientRect();
      return labelRect.width >= 44 && labelRect.height >= 44;
    });
  }
  return {
    names: controls.map(name),
    values: controls.map((control) => control.type === 'checkbox' ? control.checked : control.value),
    unnamed: controls.filter((control) => !name(control)).length,
    undersized: controls.filter((control) => !adequateTarget(control)).length,
    described: controls.every((control) => control.getAttribute('aria-describedby')),
  };
});

await page.press('Escape');
const escapedInitial = await page.eval(() => ({
  hidden: document.querySelector('#fm-tweaks-panel').hidden,
  focus: document.activeElement.className,
}));
await page.eval(() => document.querySelector('.synthetic-card__action').focus());
await page.press('Alt+Shift+T');
const shortcutOpened = await page.eval(() => ({
  open: !document.querySelector('#fm-tweaks-panel').hidden,
  closeFocused: document.activeElement.matches('.fm-tweaks-close'),
}));
await page.press('Escape');
const focusReturned = await page.eval(() => document.activeElement.matches('.synthetic-card__action'));
await page.press('Alt+Shift+T');

await page.eval(() => document.querySelector('.fm-tweaks-close').focus());
const tabOrder = [];
for (let index = 0; index < 6; index += 1) {
  await page.press('Tab');
  tabOrder.push(await page.eval(() => document.activeElement.id || document.activeElement.name || document.activeElement.getAttribute('aria-label')));
}
const focusVisible = await page.eval(() => {
  const active = document.activeElement;
  const style = getComputedStyle(active);
  return active.matches(':focus-visible') && parseFloat(style.outlineWidth) >= 2;
});

await page.fill('[data-renderer="native"] [name="cornerRadius"]', '24');
await page.press('Enter');
await page.fill('[data-renderer="native"] [name="accentColor"]', '#315f9f');
await page.eval(() => {
  const color = document.querySelector('[data-renderer="native"] [name="accentColor"]');
  color.dispatchEvent(new Event('change', { bubbles: true }));
  const density = document.querySelector('[data-renderer="native"] [name="contentDensity"]');
  density.value = 'roomy';
  density.dispatchEvent(new Event('change', { bubbles: true }));
});
await page.click('[data-renderer="native"] [name="emphasized"]');
await page.wait(50);
const nativePreset = await page.eval(() => JSON.parse(window.__FM_TWEAKS_TEST__.exportPreset()));

await page.click('[data-tweaks-action="copy"]');
await page.wait(80);
await page.click('[data-tweaks-action="export"]');
await page.wait(80);
const copiedAndExported = await page.eval(() => {
  const diagnostics = window.__FM_TWEAKS_TEST__.diagnostics();
  return {
    copied: diagnostics.lastCopiedText,
    exported: diagnostics.lastExportedText,
    current: window.__FM_TWEAKS_TEST__.exportPreset(),
    error: diagnostics.lastError,
  };
});

await page.click('[data-tweaks-action="reset"]');
const resetPreset = await page.eval(() => JSON.parse(window.__FM_TWEAKS_TEST__.exportPreset()));
const importedText = '{"fixture":"localization-card","schemaVersion":1,"values":{"accentColor":"#315f9f","contentDensity":"compact","cornerRadius":12,"emphasized":true},"viewport":{"height":667,"width":375}}\n';
await page.fill('#fm-tweaks-import', importedText);
await page.click('[data-tweaks-action="import"]');
const importedPreset = await page.eval(() => JSON.parse(window.__FM_TWEAKS_TEST__.exportPreset()));
const beforeInvalid = await page.eval(() => window.__FM_TWEAKS_TEST__.exportPreset());
await page.fill('#fm-tweaks-import', importedText.replace('"schemaVersion":1', '"schemaVersion":99'));
await page.click('[data-tweaks-action="import"]');
const invalidImport = await page.eval(() => ({
  unchanged: window.__FM_TWEAKS_TEST__.exportPreset(),
  invalid: document.querySelector('#fm-tweaks-import').getAttribute('aria-invalid'),
  role: document.querySelector('#fm-tweaks-status').getAttribute('role'),
  message: document.querySelector('#fm-tweaks-status').textContent,
  focused: document.activeElement.id,
}));

await page.eval(() => {
  const fixture = document.querySelector('#fm-tweaks-fixture');
  fixture.value = 'dispatch-card';
  fixture.dispatchEvent(new Event('change', { bubbles: true }));
});
const dispatchAfterIsolation = await page.eval(() => JSON.parse(window.__FM_TWEAKS_TEST__.exportPreset()));
await page.eval(() => {
  const fixture = document.querySelector('#fm-tweaks-fixture');
  fixture.value = 'localization-card';
  fixture.dispatchEvent(new Event('change', { bubbles: true }));
});
const localizationAfterIsolation = await page.eval(() => JSON.parse(window.__FM_TWEAKS_TEST__.exportPreset()));

const viewportResults = await page.eval(() => {
  const select = document.querySelector('#fm-tweaks-viewport');
  const results = [];
  for (const option of select.options) {
    select.value = option.value;
    select.dispatchEvent(new Event('change', { bubbles: true }));
    const frame = document.querySelector('#fixture-viewport');
    const card = document.querySelector('.synthetic-card');
    results.push({
      width: frame.dataset.viewportWidth,
      height: frame.dataset.viewportHeight,
      actualWidth: frame.getBoundingClientRect().width,
      actualHeight: frame.getBoundingClientRect().height,
      cardFits: card.scrollWidth <= card.clientWidth,
      actionFits: card.querySelector('button').getBoundingClientRect().width <= card.getBoundingClientRect().width,
    });
  }
  return results;
});

await page.eval(() => {
  const viewport = document.querySelector('#fm-tweaks-viewport');
  viewport.value = '375x667';
  viewport.dispatchEvent(new Event('change', { bubbles: true }));
});
await page.click('input[name="fm-tweaks-renderer"][value="tweakpane"]');
await page.eval(() => document.querySelector('input[name="fm-tweaks-renderer"][value="tweakpane"]').focus());
const tweakpaneTabOrder = [];
for (let index = 0; index < 5; index += 1) {
  await page.press('Tab');
  tweakpaneTabOrder.push(await page.eval(() => document.activeElement.getAttribute('aria-label') || document.activeElement.labels?.[0]?.textContent || document.activeElement.tagName));
}
await page.fill('[data-renderer="tweakpane"] [data-tweak-key="cornerRadius"] input[type="text"]', '26');
await page.press('Enter');
await page.fill('[data-renderer="tweakpane"] [data-tweak-key="accentColor"] .tp-colv_t input[type="text"]', '#7b426f');
await page.press('Enter');
await page.eval(() => {
  const select = document.querySelector('[data-renderer="tweakpane"] [data-tweak-key="contentDensity"] select');
  select.selectedIndex = 1;
  select.dispatchEvent(new Event('change', { bubbles: true }));
});
await page.click('[data-renderer="tweakpane"] [data-tweak-key="emphasized"] input[type="checkbox"]');
await page.wait(50);
const tweakpanePreset = await page.eval(() => JSON.parse(window.__FM_TWEAKS_TEST__.exportPreset()));

const accessibility = await page.eval(() => {
  function visible(element) {
    const rect = element.getBoundingClientRect();
    const style = getComputedStyle(element);
    return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none';
  }
  function name(element) {
    const labelledby = element.getAttribute('aria-labelledby');
    if (labelledby) return labelledby.split(/\s+/).map((id) => document.getElementById(id)?.textContent || '').join(' ').trim();
    return (element.getAttribute('aria-label') || [...(element.labels || [])].map((label) => label.textContent).join(' ') || element.textContent || '').trim();
  }
  function adequateTarget(element) {
    const rect = element.getBoundingClientRect();
    if (rect.width >= 44 && rect.height >= 44) return true;
    return [...(element.labels || [])].some((label) => {
      const labelRect = label.getBoundingClientRect();
      return labelRect.width >= 44 && labelRect.height >= 44;
    });
  }
  const interactive = [...document.querySelectorAll('#fm-tweaks-panel button, #fm-tweaks-panel input, #fm-tweaks-panel select, #fm-tweaks-panel textarea, #fm-tweaks-panel [tabindex="0"]')]
    .filter(visible);
  const groups = [...document.querySelectorAll('#fm-tweaks-panel fieldset')];
  return {
    unnamed: interactive.filter((element) => !name(element)).map((element) => element.outerHTML),
    undersized: interactive.filter((element) => !adequateTarget(element)).map((element) => name(element)),
    positiveTabindex: interactive.filter((element) => element.tabIndex > 0).length,
    unnamedGroups: groups.filter((group) => !group.querySelector(':scope > legend')?.textContent.trim()).length,
    importDescription: document.querySelector('#fm-tweaks-import').getAttribute('aria-describedby'),
    rendererKeys: [...document.querySelectorAll('[data-renderer="tweakpane"] [data-tweak-key]')].map((element) => element.dataset.tweakKey),
    currentValues: interactive.filter((element) => element.matches('[data-tweak-control]')).map((element) => ({
      name: name(element),
      value: element.type === 'checkbox' ? element.checked : element.value ?? element.getAttribute('aria-valuenow'),
    })),
  };
});

const remounted = await page.eval(async () => window.__FM_TWEAKS_TEST__.remount());
const remountedAgain = await page.eval(async () => window.__FM_TWEAKS_TEST__.remount());
const errorCleanup = await page.eval(async () => window.__FM_TWEAKS_TEST__.simulateMountError());
await page.press('Escape');
const oneShortcutEffect = await page.eval(() => ({
  panelCount: document.querySelectorAll('#fm-tweaks-panel').length,
  open: !document.querySelector('#fm-tweaks-panel').hidden,
}));

const final = await page.eval(() => {
  const resources = performance.getEntriesByType('resource').map((entry) => ({ name: entry.name, initiatorType: entry.initiatorType }));
  const panel = document.querySelector('#fm-tweaks-panel');
  const styles = getComputedStyle(panel);
  const motion = [...panel.querySelectorAll('*')].map((element) => getComputedStyle(element));
  return {
    diagnostics: window.__FM_TWEAKS_TEST__.diagnostics(),
    resources,
    storageKeys: Object.keys(localStorage).sort(),
    panelColors: { color: styles.color, background: styles.backgroundColor },
    contrastRatio: (() => {
      const channels = (color) => (color.match(/[0-9.]+/g) || []).slice(0, 3).map(Number);
      const luminance = (color) => {
        const values = channels(color).map((value) => {
          const channel = value / 255;
          return channel <= 0.03928 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4;
        });
        return 0.2126 * values[0] + 0.7152 * values[1] + 0.0722 * values[2];
      };
      const foreground = luminance(styles.color);
      const background = luminance(styles.backgroundColor);
      return (Math.max(foreground, background) + 0.05) / (Math.min(foreground, background) + 0.05);
    })(),
    noAnimation: motion.every((style) => style.animationName === 'none' || parseFloat(style.animationDuration) <= 0.001),
    noTransition: motion.every((style) => parseFloat(style.transitionDuration) <= 0.001),
    pageFits: document.documentElement.scrollWidth === document.documentElement.clientWidth,
  };
});

console.log(JSON.stringify({
  initial,
  nativeAccessibility,
  escapedInitial,
  shortcutOpened,
  focusReturned,
  tabOrder,
  focusVisible,
  nativePreset,
  copiedAndExported,
  resetPreset,
  importedPreset,
  beforeInvalid,
  invalidImport,
  dispatchAfterIsolation,
  localizationAfterIsolation,
  viewportResults,
  tweakpaneTabOrder,
  tweakpanePreset,
  accessibility,
  remounted,
  remountedAgain,
  errorCleanup,
  oneShortcutEffect,
  final,
}));
EOF
)

printf '%s' "$browser_result" | jq -e '
  .initial.diagnostics.panelCount == 1
  and .initial.diagnostics.launcherCount == 1
  and .initial.diagnostics.withinMountBudget == true
  and .initial.diagnostics.persistenceEnabled == false
  and .initial.diagnostics.eventListenerCount == 3
  and .initial.diagnostics.store.listenerCount == 1
  and .initial.pageFits == true
  and .initial.panelTargetOverlap == 0
  and .nativeAccessibility.names == ["Corner radius","Accent color","Content density","Emphasize summary"]
  and .nativeAccessibility.values == ["18","#c65a3a","comfortable",false]
  and .nativeAccessibility.unnamed == 0
  and .nativeAccessibility.undersized == 0
  and .nativeAccessibility.described == true
  and .escapedInitial.hidden == true
  and .escapedInitial.focus == "fm-tweaks-toggle"
  and .shortcutOpened == {open:true, closeFocused:true}
  and .focusReturned == true
  and (.tabOrder | length) == 6
  and .tabOrder[0] == "fm-tweaks-fixture"
  and .focusVisible == true
  and .nativePreset.values == {accentColor:"#315f9f",contentDensity:"roomy",cornerRadius:24,emphasized:true}
  and .copiedAndExported.copied == .copiedAndExported.current
  and .copiedAndExported.exported == .copiedAndExported.current
  and .copiedAndExported.error == null
  and .resetPreset.values == {accentColor:"#c65a3a",contentDensity:"comfortable",cornerRadius:18,emphasized:false}
  and .importedPreset.fixture == "localization-card"
  and .importedPreset.viewport == {height:667,width:375}
  and .importedPreset.values == {accentColor:"#315f9f",contentDensity:"compact",cornerRadius:12,emphasized:true}
  and .invalidImport.unchanged == .beforeInvalid
  and .invalidImport.invalid == "true"
  and .invalidImport.role == "alert"
  and (.invalidImport.message | contains("unsupported schema version"))
  and .invalidImport.focused == "fm-tweaks-status"
  and .dispatchAfterIsolation.values == {accentColor:"#c65a3a",contentDensity:"comfortable",cornerRadius:18,emphasized:false}
  and .localizationAfterIsolation.values == {accentColor:"#315f9f",contentDensity:"compact",cornerRadius:12,emphasized:true}
  and (.viewportResults | map(.width|tonumber)) == [320,375,768,1024,1440]
  and (.viewportResults | all((.actualWidth == (.width|tonumber)) and (.actualHeight >= (.height|tonumber)) and .cardFits and .actionFits))
  and (.tweakpaneTabOrder | length) == 5
  and (.tweakpaneTabOrder[0] | startswith("Corner radius"))
  and .tweakpanePreset.values == {accentColor:"#7b426f",contentDensity:"comfortable",cornerRadius:26,emphasized:false}
  and .accessibility.unnamed == []
  and .accessibility.undersized == []
  and .accessibility.positiveTabindex == 0
  and .accessibility.unnamedGroups == 0
  and (.accessibility.importDescription | contains("fm-tweaks-status"))
  and .accessibility.rendererKeys == ["cornerRadius","accentColor","contentDensity","emphasized"]
  and (.accessibility.currentValues | length) >= 4
  and .remounted.panelCount == 1
  and .remountedAgain.panelCount == 1
  and .remountedAgain.eventListenerCount == 3
  and .errorCleanup.message == "synthetic renderer failure"
  and .errorCleanup.afterError == {panelCount:0,launcherCount:0}
  and .errorCleanup.afterRecovery.panelCount == 1
  and .errorCleanup.afterRecovery.eventListenerCount == 3
  and .oneShortcutEffect == {panelCount:1,open:false}
  and .final.diagnostics.panelCount == 1
  and .final.diagnostics.renderer.listenerCount == 4
  and .final.diagnostics.store.listenerCount == 1
  and .final.storageKeys == .initial.storageKeys
  and (.final.resources | length) == (.initial.resources | length)
  and (.final.resources | all(.name | startswith("http://127.0.0.1:")))
  and (.final.resources | all(.initiatorType != "fetch" and .initiatorType != "xmlhttprequest" and .initiatorType != "beacon"))
  and .final.panelColors.color != .final.panelColors.background
  and .final.contrastRatio >= 4.5
  and .final.noAnimation == true
  and .final.noTransition == true
  and .final.pageFits == true
' >/dev/null || fail "desktop renderer, lifecycle, accessibility, preset, or network corpus failed: $browser_result"
pass 'both renderers share the schema and pass controls, keyboard, focus, preset lifecycle, atomic errors, target sizing, and idempotent cleanup'
pass 'fixture interactions add no requests, persistence, polling, or source-writing behavior after load'

for dimensions in '320 800' '375 800' '667 375' '768 900' '1024 900' '1440 900'; do
  width=${dimensions% *}
  height=${dimensions#* }
  CHROME_DEVTOOLS_AXI_SESSION="$BROWSER_SESSION" chrome-devtools-axi resize "$width" "$height" >/dev/null
  responsive_result=$(CHROME_DEVTOOLS_AXI_SESSION="$BROWSER_SESSION" chrome-devtools-axi run <<'EOF'
await page.eval(() => {
  const panel = document.querySelector('#fm-tweaks-panel');
  if (panel.hidden) document.querySelector('[data-tweaks-action="toggle"]').click();
});
const result = await page.eval(() => {
  const panel = document.querySelector('#fm-tweaks-panel');
  const region = document.querySelector('.fixture-region');
  const panelRect = panel.getBoundingClientRect();
  const regionRect = region.getBoundingClientRect();
  const overlap = Math.max(0, Math.min(regionRect.right, panelRect.right) - Math.max(regionRect.left, panelRect.left))
    * Math.max(0, Math.min(regionRect.bottom, panelRect.bottom) - Math.max(regionRect.top, panelRect.top));
  return {
    pageFits: document.documentElement.scrollWidth === document.documentElement.clientWidth,
    panelFits: panel.scrollWidth <= panel.clientWidth,
    targetPanelOverlap: overlap,
    panelControls: panel.querySelectorAll('button,input,select,textarea').length,
  };
});
console.log(JSON.stringify(result));
EOF
)
  printf '%s' "$responsive_result" | jq -e '
    .pageFits
    and .panelFits
    and .targetPanelOverlap == 0
    and .panelControls >= 10
  ' >/dev/null || fail "supported page width ${width}x${height} hid the target or controls: $responsive_result"
done
pass 'all supported page widths plus landscape keep the target and panel separate without losing controls'

CHROME_DEVTOOLS_AXI_SESSION="$BROWSER_SESSION" chrome-devtools-axi emulate --viewport '375x667x1,mobile,touch' --color-scheme dark >/dev/null
mobile_result=$(CHROME_DEVTOOLS_AXI_SESSION="$BROWSER_SESSION" chrome-devtools-axi run <<'EOF'
await page.wait('#fm-tweaks-panel', 30000);
await page.eval(async () => { await document.fonts.ready; });
await page.eval(() => {
  const fixture = document.querySelector('#fm-tweaks-fixture');
  fixture.value = 'localization-card';
  fixture.dispatchEvent(new Event('change', { bubbles: true }));
  const viewport = document.querySelector('#fm-tweaks-viewport');
  viewport.value = '375x667';
  viewport.dispatchEvent(new Event('change', { bubbles: true }));
});
const normal = await page.eval(() => {
  const panel = document.querySelector('#fm-tweaks-panel');
  const frame = document.querySelector('#fixture-viewport');
  const region = document.querySelector('.fixture-region');
  const card = document.querySelector('.synthetic-card');
  const panelRect = panel.getBoundingClientRect();
  const regionRect = region.getBoundingClientRect();
  return {
    pageFits: document.documentElement.scrollWidth === document.documentElement.clientWidth,
    frameExact: frame.getBoundingClientRect().width === 375,
    regionContainsHorizontalInspection: region.scrollWidth >= 375,
    cardFits: card.scrollWidth <= card.clientWidth,
    actionFits: card.querySelector('button').getBoundingClientRect().width <= card.getBoundingClientRect().width,
    panelBelowTarget: panelRect.top >= regionRect.bottom,
    panelFits: panel.scrollWidth <= panel.clientWidth,
    darkColors: { color: getComputedStyle(panel).color, background: getComputedStyle(panel).backgroundColor },
    contrastRatio: (() => {
      const style = getComputedStyle(panel);
      const luminance = (color) => {
        const values = (color.match(/[0-9.]+/g) || []).slice(0, 3).map(Number).map((value) => {
          const channel = value / 255;
          return channel <= 0.03928 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4;
        });
        return 0.2126 * values[0] + 0.7152 * values[1] + 0.0722 * values[2];
      };
      const foreground = luminance(style.color);
      const background = luminance(style.backgroundColor);
      return (Math.max(foreground, background) + 0.05) / (Math.min(foreground, background) + 0.05);
    })(),
  };
});
await page.eval(() => { document.documentElement.style.fontSize = '200%'; });
const zoomed = await page.eval(() => ({
  pageFits: document.documentElement.scrollWidth === document.documentElement.clientWidth,
  panelFits: document.querySelector('#fm-tweaks-panel').scrollWidth <= document.querySelector('#fm-tweaks-panel').clientWidth,
  controlsPresent: document.querySelectorAll('#fm-tweaks-panel button, #fm-tweaks-panel input, #fm-tweaks-panel select, #fm-tweaks-panel textarea').length >= 10,
}));
await page.eval(() => { document.documentElement.style.fontSize = ''; });
console.log(JSON.stringify({ normal, zoomed }));
EOF
)
printf '%s' "$mobile_result" | jq -e '
  .normal.pageFits
  and .normal.frameExact
  and .normal.regionContainsHorizontalInspection
  and .normal.cardFits
  and .normal.actionFits
  and .normal.panelBelowTarget
  and .normal.panelFits
  and .normal.darkColors.color != .normal.darkColors.background
  and .normal.contrastRatio >= 4.5
  and .zoomed.pageFits
  and .zoomed.panelFits
  and .zoomed.controlsPresent
' >/dev/null || fail "mobile, dark-theme, localization, or zoom corpus failed: $mobile_result"
pass 'mobile and dark-theme layouts preserve the exact viewport, localized content, controls, target visibility, and 200% zoom'

CHROME_DEVTOOLS_AXI_SESSION="$BROWSER_SESSION" chrome-devtools-axi open "http://127.0.0.1:$PROD_PORT/" >/dev/null
CHROME_DEVTOOLS_AXI_SESSION="$BROWSER_SESSION" chrome-devtools-axi wait 100 >/dev/null
production_runtime=$(CHROME_DEVTOOLS_AXI_SESSION="$BROWSER_SESSION" chrome-devtools-axi run <<'EOF'
console.log(JSON.stringify(await page.eval(() => ({
  panelCount: document.querySelectorAll('#fm-tweaks-panel,.fm-tweaks-launcher').length,
  globals: [typeof window.__FM_DESIGN_TWEAKS_PROOF__, typeof window.__FM_TWEAKS_TEST__],
  scripts: [...document.scripts].map((script) => script.src),
  links: [...document.querySelectorAll('link')].map((link) => link.href),
  maps: performance.getEntriesByType('resource').some((entry) => entry.name.endsWith('.map')),
}))));
EOF
)
printf '%s' "$production_runtime" | jq -e '
  .panelCount == 0
  and .globals == ["undefined","undefined"]
  and ([.scripts[],.links[]] | all(test("tweak|entry-.*dev";"i")|not))
  and .maps == false
' >/dev/null || fail "production runtime leaked proof behavior: $production_runtime"
pass 'production runtime exposes no panel, shortcut global, renderer chunk, or source-map request'

ACCESS_SESSION="${BROWSER_SESSION}-access"
BROWSER_SESSIONS+=("$ACCESS_SESSION")
CHROME_DEVTOOLS_AXI_SESSION="$ACCESS_SESSION" \
CHROME_DEVTOOLS_AXI_CHROME_ARGS='--force-high-contrast --force-prefers-reduced-motion' \
  chrome-devtools-axi open "http://127.0.0.1:$DEV_PORT/" >/dev/null
CHROME_DEVTOOLS_AXI_SESSION="$ACCESS_SESSION" chrome-devtools-axi resize 1024 768 >/dev/null
access_result=$(CHROME_DEVTOOLS_AXI_SESSION="$ACCESS_SESSION" chrome-devtools-axi run <<'EOF'
await page.wait('#fm-tweaks-panel', 30000);
const result = await page.eval(() => {
  const panel = document.querySelector('#fm-tweaks-panel');
  const controls = [...panel.querySelectorAll('button,input,select,textarea')].filter((element) => element.getBoundingClientRect().width > 0);
  controls[0]?.focus();
  const styles = controls.map((element) => getComputedStyle(element));
  return {
    forcedColors: matchMedia('(forced-colors: active)').matches,
    reducedMotion: matchMedia('(prefers-reduced-motion: reduce)').matches,
    panelVisible: panel.getBoundingClientRect().width > 0,
    controlsVisible: controls.length >= 10,
    motionDisabled: styles.every((style) => style.animationName === 'none' || parseFloat(style.animationDuration) <= 0.001)
      && styles.every((style) => parseFloat(style.transitionDuration) <= 0.001),
    focusColor: getComputedStyle(controls[0]).outlineColor,
  };
});
console.log(JSON.stringify(result));
EOF
)
printf '%s' "$access_result" | jq -e '
  .forcedColors
  and .reducedMotion
  and .panelVisible
  and .controlsVisible
  and .motionDisabled
  and (.focusColor | length) > 0
' >/dev/null || fail "high-contrast or reduced-motion corpus failed: $access_result"
pass 'forced-colors and reduced-motion modes keep the panel and controls legible without motion'

after_source=$(source_digest)
after_repo=$(git -C "$ROOT" status --porcelain=v1 --untracked-files=all)
[ "$before_source" = "$after_source" ] || fail 'browser interactions changed synthetic fixture source files'
[ "$before_repo" = "$after_repo" ] || fail 'browser interactions changed the repository'
pass 'reset, copy, import, export, renderer, viewport, and lifecycle interactions do not mutate repository source'
