# Synthetic design tweaks proof

Audience: operator current.

Firstmate includes one synthetic, development-only fixture that demonstrates a library-independent tweaks schema through native semantic controls and Tweakpane 4.0.5.
It is a proof for Firstmate contributors, not an integration path for a real project.
It has no account, credential, remote asset, telemetry, source-writing helper, hook, MCP server, or mutable remote instruction.

## Run the proof

Use an exact clean install that skips package lifecycle scripts, then start the loopback development server.

```sh
cd tests/fixtures/fm-design-tweaks-proof
npm ci --ignore-scripts --no-audit --no-fund
npm run dev -- --port 4173
```

Open `http://127.0.0.1:4173/` locally.
The panel is present only in Vite's compile-time `development` mode and toggles with `Alt+Shift+T` or its visible button.
The ordinary production build keeps the synthetic fixture but removes the complete tweaks panel and adapter.

Run the production boundary directly with:

```sh
npm run build:assert
```

That command builds in production mode and inspects every emitted asset plus the reachable manifest graph.
It refuses emitted panel UI or styles, the shortcut, the reserved persistence namespace, preset schema metadata, Tweakpane or lil-gui identifiers, a development-controls chunk, and source-map output or references.

## Supported behavior

The core schema owns four controls: a bounded number, a six-digit color, a select from declared options, and a boolean.
A declared CSS custom property is the only target for number, color, and select entries.
A declared `data-*` attribute is the only target for a boolean entry.
The core accepts no selector, ordinary CSS property, undeclared attribute, JavaScript expression, source snippet, handler, URL, remote module, or prototype-pollution key.
The native and Tweakpane renderers consume the same core schema and preset state, while Tweakpane-specific objects remain inside its adapter.

A preset carries schema version 1, one synthetic fixture identity, one exact viewport, and every declared value.
The supported viewport dimensions are 320 by 568, 375 by 667, 768 by 1024, 1024 by 768, and 1440 by 900 CSS pixels.
Serialization recursively sorts object keys and ends with one newline, so equivalent state has identical bytes.
An import is parsed with duplicate-key detection and validated completely before any fixture, viewport, or value changes.
Reset restores authored fixture defaults, Copy writes canonical JSON, Import commits validated JSON, and Export downloads the same canonical JSON.
The token suggestion is deterministic data only and never changes source.

State stays in memory for every fixture.
No browser persistence is implemented, including for the synthetic fixture marked sensitive.
Each fixture retains independent values until reset or page reload.
Mount, unmount, remount, and error cleanup converge to one panel, one launcher, one document listener set, and one renderer listener set.
The development mount budget is 500 milliseconds and the proof runs no continuous poll.
At narrow widths the panel follows the target instead of overlaying it, while the target viewport remains an exact horizontally inspectable surface.

## Package and verification owners

[`../tests/fixtures/fm-design-tweaks-proof/SOURCES.lock.json`](../tests/fixtures/fm-design-tweaks-proof/SOURCES.lock.json) owns the exact Tweakpane package integrity, inspected tarball digest, tagged source commit, MIT attribution, and update policy.
The adjacent `NOTICE` and `licenses/Tweakpane-MIT.license` preserve attribution and terms.
The tarball SHA-256 is local inspection evidence and is not represented as publisher signing.

[`verification/design-tweaks-proof.md`](verification/design-tweaks-proof.md) records current build, browser, performance, network, accessibility, source-mutation, and visual evidence.
Run the focused portable checks with:

```sh
bin/fm-test-run.sh tests/fm-design-tweaks-proof.test.sh
```

Run the live browser corpus through `chrome-devtools-axi` with:

```sh
FM_DESIGN_TWEAKS_BROWSER_E2E=1 bin/fm-test-run.sh tests/fm-design-tweaks-proof.test.sh
```
