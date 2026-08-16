# Synthetic design tweaks proof verification

Audience: maintainer verification.

This record holds current evidence for the development-only synthetic proof documented in [`../design-tweaks-proof.md`](../design-tweaks-proof.md).
The fixture's public core API, native renderer, Tweakpane adapter, production assertion, and browser interface remain the executable owners.

Verification date: 2026-08-15.
Verification host: macOS Darwin 25.6.0 arm64.

## Versions and package evidence

```text
node v24.19.0
npm 11.17.0
chrome-devtools-axi 0.1.29
git 2.50.1
Vite 8.2.1
Tweakpane 4.0.5
```

`package.json` and `package-lock.json` pin Tweakpane with the exact string `4.0.5`.
The lockfile and npm metadata carry integrity `sha512-rxEXdSI+ArlG1RyO6FghC4ZUX8JkEfz8F3v1JuteXSV0pEtHJzyo07fcDG+NsJfN5L39kSbCYbB9cBGHyuI/tQ==`.
The assessment's inspected `tweakpane@4.0.5` tarball SHA-256 was reproduced as `8cf819860e51128ea6031528c2ec6a92413785928d49c16170562d3f9f39134d` with `npm pack tweakpane@4.0.5 --ignore-scripts` and `shasum -a 256`.
That SHA-256 is local artifact inspection evidence, not publisher signing and not proof that the npm artifact is reproducible from source.
The exact `4.0.5` source tag resolves through annotated tag object `5324cc96e61e03ffa6570a0a8563562f893fb829` to commit `f3312dd5c61905611cce79d0bffa36b2e7340daa`.
The npm tarball declares MIT in package metadata but omits its license file.
Firstmate therefore preserves the tag's exact `LICENSE.txt` blob `597ee0936f67ef27bca9f11385517836a42a1bd5` as `licenses/Tweakpane-MIT.license`, whose SHA-256 is `385accdd560bac0013a2965fe9d39c45808b7542d2bbb3ef0cceeb60b7da71c3`.
No Tweakpane plugin is present.

Current tracked evidence digests are:

```text
package-lock.json  2d9fdfac89d29228bf75db3839f63ad555b1c2decb04a72a305f699907ac46ce
SOURCES.lock.json  c9c06a0c0e733df59008a01dfacfec65e094496fe3ce3e9506e8b5a8b9a24e3d
Tweakpane-MIT.license  385accdd560bac0013a2965fe9d39c45808b7542d2bbb3ef0cceeb60b7da71c3
```

## Core and browser corpus

The focused portable command was:

```sh
bin/fm-test-run.sh tests/fm-design-tweaks-proof.test.sh
```

Its ten Node public-interface cases passed deterministic sorted-key round-trip, every fixed viewport and fixture, unknown versions and keys, duplicate keys, malformed colors, NaN, Infinity, numeric overflow, out-of-range and off-step numbers, missing values, unknown fixtures, unsupported viewports, unsafe object keys, fixture isolation, reset, disposal, and the complete mutation allowlist.
Schema-definition cases refused ordinary CSS properties, arbitrary selectors, event handlers, source snippets, URL-bearing CSS, invalid target kinds, and undeclared values.
The mutation case observed only the three declared CSS custom properties and one declared `data-*` attribute.

The complete live command was:

```sh
FM_DESIGN_TWEAKS_BROWSER_E2E=1 bin/fm-test-run.sh tests/fm-design-tweaks-proof.test.sh
```

It used `chrome-devtools-axi` against loopback static production and development evidence builds.
The result was:

```text
ok - exact Tweakpane 4.0.5 pin, npm integrity, inspected tarball evidence, MIT attribution, and digest qualification agree
ok - desktop and mobile baseline and non-default visual evidence matches its deterministic manifest
ok - canonical presets, invalid imports, fixture isolation, allowlist denial, reset, and disposal pass through the public core API
ok - production assets have zero disabled-tweaks bytes, no source maps, and no reachable development-controls chunk
ok - both renderers share the schema and pass controls, keyboard, focus, preset lifecycle, atomic errors, target sizing, and idempotent cleanup
ok - fixture interactions add no requests, persistence, polling, or source-writing behavior after load
ok - all supported page widths plus landscape keep the target and panel separate without losing controls
ok - mobile and dark-theme layouts preserve the exact viewport, localized content, controls, target visibility, and 200% zoom
ok - production runtime exposes no panel, shortcut global, renderer chunk, or source-map request
ok - forced-colors and reduced-motion modes keep the panel and controls legible without motion
ok - reset, copy, import, export, renderer, viewport, and lifecycle interactions do not mutate repository source
```

The native and Tweakpane renderers each changed number, color, select, and boolean values through their rendered controls and produced the same canonical preset shape.
Keyboard checks covered the visible toggle, `Alt+Shift+T`, Escape, sequential Tab movement, visible focus, and focus return to the prior fixture action.
The accessibility-equivalent DOM and Chrome accessibility inspection found semantic fieldsets and legends, accessible names for every visible control and Tweakpane subcontrol, exposed current values, an associated import description and alert, no positive tab index, and a 44 by 44 CSS-pixel control or associated label target.
Reset, clipboard copy, local download export, complete valid import, invalid import, fixture switching, and token-suggestion behavior all ran through rendered public controls.
The invalid rendered import retained byte-identical prior state, set `aria-invalid=true`, exposed an alert with the validation path, and moved focus to the error.
Two ordinary remounts and one injected renderer failure each returned to exactly one panel, one launcher, three delegated document/interface listeners, four active renderer listeners, and one store subscriber.
The observed development mount was 3.9 milliseconds against the 500 millisecond budget.
No timer or polling loop exists in the proof.

After fixture load and all interactions, the browser resource-entry count was unchanged.
Every loaded resource was loopback-local and there was no fetch, XMLHttpRequest, beacon, event source, remote asset, or proof-originated request.
The browser storage key set was unchanged and diagnostics reported persistence disabled for both fixtures.
A complete pre-interaction and post-interaction source digest plus repository status comparison was identical.

The 320, 375, 768, 1024, and 1440 CSS-pixel viewport controls each produced the exact declared target width and height.
At 375 CSS pixels the panel followed the target in document flow, the localized German fixture and long action remained contained, and the page had no horizontal overflow.
A 200 percent text-zoom exercise retained every panel control without page or panel overflow.
Light, dark, forced-colors, and reduced-motion browser modes retained distinct foreground and background colors, visible focus, all controls, and no active animation or transition.

## Production boundary

The exact production command was:

```sh
cd tests/fixtures/fm-design-tweaks-proof
npm run build:assert
```

The current assertion output was:

```json
{"assertion":"firstmate.design-tweaks-production-absence/v1","assetCount":4,"totalBytes":10898,"disabledTweaksBytes":0,"reachableEntries":["index.html"],"sourceMaps":0}
```

The assertion scans all emitted assets and the reachable manifest graph rather than trusting the runtime condition.
The production browser then observed no panel or launcher, no development global, no renderer chunk or identifier, and no source-map request.
This establishes zero emitted development-controls bytes and zero disabled runtime behavior for the current production build.

## Harness and runtime applicability

The fixture is reached only through its focused test and contributor commands under `tests/fixtures/`.
Claude, Codex, OpenCode, Pi, pi-signed, and Grok primary sessions do not import or launch it.
Kimi and Muse workers do not import or launch it.
The tmux, Herdr, Zellij, Orca, and cmux worker backends do not import or launch it.
Codex App remains inapplicable because the proof adds no selectable worker surface.
The one test-runner edit classifies the focused shell test and changes no harness, dispatch, supervision, or backend behavior.

## Deterministic visual evidence

Fonts were awaited through `document.fonts.ready`, every animation and transition was disabled by a local capture style, carets were hidden, and each capture used deterministic synthetic content.
The desktop viewport was 1440 by 900 CSS pixels and the mobile viewport was 375 by 667 CSS pixels.
The full-page images intentionally retain the exact target viewport and the non-overlaying panel in one frame.
The machine-readable [visual evidence manifest](assets/design-tweaks-proof/manifest.json) owns capture conditions, dimensions, hashes, renderer and preset identities, themes, and comparison tolerance.

- [Desktop native baseline](assets/design-tweaks-proof/desktop-native-baseline.png) is 1440 by 1116 pixels with SHA-256 `11df9d5217ba46b736af1ed64789d2b69c7f2ed5a979e41ae48500d9c62615ba`.
- [Desktop Tweakpane non-default](assets/design-tweaks-proof/desktop-tweakpane-nondefault.png) is 1440 by 1116 pixels with SHA-256 `d95230b4b8a005042a38c970e0c73e4825107c373915492035e4bb5c438144cf`.
- [Mobile native baseline](assets/design-tweaks-proof/mobile-native-baseline.png) is 375 by 2560 pixels with SHA-256 `391ac2b6126644e403ece946a1771c5d7b6fd63c7a2b5e625c114a4f735a014c`.
- [Mobile Tweakpane non-default](assets/design-tweaks-proof/mobile-tweakpane-nondefault.png) is 375 by 2426 pixels with SHA-256 `3eea6f17dcd315b0847695816915cb055ac2abefad000dd50507ecc56af3874c`.

For recaptures on the same pinned host and browser, the review tolerance is at most 0.1 percent changed pixels with a maximum per-channel delta of 8 to accommodate raster antialiasing.
A changed layout, clipped content, missing control, different fixture state, or comparison beyond that tolerance requires inspected replacement evidence rather than an automatic baseline update.
Cross-host raster output is reviewed visually and recaptured with new hashes instead of being treated as byte-equivalent.
