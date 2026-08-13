#!/usr/bin/env node
// Localhost gallery implementation for bin/fm-design-inspiration.sh.
// The shell helper's header and --help output own commands and schemas.
// This file uses only Node built-ins, binds only to 127.0.0.1, and has no
// external request, telemetry, account, publish, or share code path.

import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HOST = '127.0.0.1';
const RUNTIME_SCHEMA = 'firstmate.design-inspiration.gallery-runtime/v1';
const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const APP_PATH = path.join(SCRIPT_DIR, 'fm-design-inspiration-gallery-app.js');
const PREVIEW_TYPES = new Map([
  ['.png', 'image/png'],
  ['.jpg', 'image/jpeg'],
  ['.jpeg', 'image/jpeg'],
  ['.webp', 'image/webp'],
  ['.avif', 'image/avif'],
  ['.bmp', 'image/bmp'],
]);

function fail(message, code = 1) {
  process.stderr.write(`fm-design-inspiration-gallery: ${message}\n`);
  process.exit(code);
}

function parseArgs(argv) {
  const result = { command: argv[0] || '' };
  for (let index = 1; index < argv.length; index += 1) {
    const argument = argv[index];
    if (!argument.startsWith('--') || index + 1 >= argv.length) {
      fail(`invalid argument: ${argument}`, 2);
    }
    const key = argument.slice(2);
    if (Object.hasOwn(result, key)) {
      fail(`duplicate argument: ${argument}`, 2);
    }
    result[key] = argv[index + 1];
    index += 1;
  }
  return result;
}

function requireInteger(value, name, minimum, maximum) {
  if (!/^[0-9]+$/.test(value || '')) {
    fail(`${name} must be an integer`, 2);
  }
  const number = Number(value);
  if (!Number.isSafeInteger(number) || number < minimum || number > maximum) {
    fail(`${name} must be from ${minimum} through ${maximum}`, 2);
  }
  return number;
}

function requireToken(value) {
  if (!/^[a-f0-9]{64}$/.test(value || '')) {
    fail('token must be 64 lowercase hexadecimal characters', 2);
  }
  return value;
}

function canonicalHome(value) {
  if (!value || !path.isAbsolute(value)) {
    fail('home must be an absolute path', 2);
  }
  const stat = fs.lstatSync(value);
  if (!stat.isDirectory() || stat.isSymbolicLink()) {
    fail('home must be a real directory', 2);
  }
  return fs.realpathSync(value);
}

function libraryPaths(home) {
  const root = path.join(home, 'data', 'design-inspiration');
  const stat = fs.lstatSync(root);
  if (!stat.isDirectory() || stat.isSymbolicLink()) {
    throw new Error('private library root must be a real directory');
  }
  return {
    root: fs.realpathSync(root),
    manifest: path.join(root, 'manifest.json'),
    preferences: path.join(root, 'preferences.json'),
  };
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function readJsonRegular(file) {
  const stat = fs.lstatSync(file);
  if (!stat.isFile() || stat.isSymbolicLink()) {
    throw new Error(`${path.basename(file)} must be a regular non-symlink file`);
  }
  return readJson(file);
}

function previewAsset(item) {
  const thumbnail = item.local_assets.find(asset => asset.role === 'thumbnail');
  if (thumbnail) return thumbnail;
  return item.local_assets.find(asset => PREVIEW_TYPES.has(path.extname(asset.path).toLowerCase())) || null;
}

function citationFor(item) {
  if (item.review_status === 'unreviewed') {
    return `Consider private design reference \`${item.id}\` as an unreviewed candidate; do not treat it as evidence of captain taste or reuse its images or code.`;
  }
  if (item.review_status === 'rejected') {
    return `Use private design reference \`${item.id}\` only as a recorded avoid example; do not reuse its images or code.`;
  }
  if (item.kind === 'reference-only') {
    return `Use captain-approved private design reference \`${item.id}\` for abstract inspiration only; do not reuse its images or code.`;
  }
  return `Use captain-approved private design reference \`${item.id}\` and follow its recorded license and attribution before reusing any asset.`;
}

function emptyPreference(id) {
  return {
    id,
    favorite: false,
    avoid: false,
    notes: '',
    ratings: {
      typography: null,
      color: null,
      density: null,
      imagery: null,
      motion: null,
      overall_affinity: null,
    },
  };
}

function loadModel(home) {
  const paths = libraryPaths(home);
  const manifest = readJsonRegular(paths.manifest);
  const preferenceDocument = readJsonRegular(paths.preferences);
  const preferences = new Map(preferenceDocument.preferences.map(entry => [entry.id, entry]));
  const items = [...manifest.items]
    .sort((left, right) => left.id.localeCompare(right.id, 'en'))
    .map(item => {
      const preview = previewAsset(item);
      return {
        ...item,
        aesthetic_families: [...item.aesthetic_families].sort(),
        interface_types: [...item.interface_types].sort(),
        platforms: [...item.platforms].sort(),
        tags: [...item.tags].sort(),
        local_assets: [...item.local_assets].sort((left, right) => left.path.localeCompare(right.path, 'en')),
        preference: preferences.get(item.id) || emptyPreference(item.id),
        citation: citationFor(item),
        preview_url: preview ? `/asset/${encodeURIComponent(item.id)}` : null,
      };
    });
  return { paths, items };
}

function html(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

function optionMarkup(values) {
  return values.map(value => `<option value="${html(value)}">${html(value)}</option>`).join('');
}

function uniqueFacet(items, field) {
  return [...new Set(items.flatMap(item => item[field]))].sort((left, right) => left.localeCompare(right, 'en'));
}

function rightsText(item) {
  if (item.kind === 'reference-only') return 'Inspiration only - no asset reuse rights';
  return `Reusable only under ${item.license.name}`;
}

function renderCard(item) {
  const preview = item.preview_url
    ? `<img src="${html(item.preview_url)}" alt="Local preview of ${html(item.title)}" loading="lazy">`
    : '<div class="preview-placeholder" role="img" aria-label="No cached local preview">No cached local preview</div>';
  const tags = [...item.aesthetic_families, ...item.interface_types, ...item.platforms, ...item.tags]
    .map(tag => `<span class="tag">${html(tag)}</span>`)
    .join('');
  const badges = [
    item.preference.favorite ? '<span class="preference-badge">Favorite</span>' : '',
    item.preference.avoid ? '<span class="preference-badge avoid">Avoid</span>' : '',
  ].join('');
  const selectionDisabled = item.review_status === 'approved' ? '' : ' disabled';
  const selectionHint = item.review_status === 'approved'
    ? `Select ${item.id} for a design brief`
    : `${item.id} must be captain-approved before it can enter a design brief`;
  return `<article class="reference-card" tabindex="0" data-id="${html(item.id)}" data-kind="${html(item.kind)}" data-health="${html(item.source_health)}" data-aesthetic="${html(item.aesthetic_families.join(' '))}" data-interface="${html(item.interface_types.join(' '))}" data-platform="${html(item.platforms.join(' '))}" data-tags="${html(item.tags.join(' '))}">
  <div class="preview">${preview}</div>
  <div class="card-body">
    <div class="card-id-row"><code class="reference-id">${html(item.id)}</code>${badges}</div>
    <h2>${html(item.title)}</h2>
    <p class="emulate">${html(item.emulate[0])}</p>
    <div class="tag-list" aria-label="Reference facets">${tags}</div>
    <p class="rights ${item.kind === 'reference-only' ? 'reference-only' : 'reusable'}">${html(rightsText(item))}</p>
    <p class="health">Source health: <strong>${html(item.source_health)}</strong></p>
    <div class="card-actions">
      <button type="button" data-copy-id="${html(item.id)}">Copy ID</button>
      <button type="button" data-copy-citation="${html(item.id)}">Copy citation</button>
      <button type="button" data-detail="${html(item.id)}">Details</button>
    </div>
    <label class="selection"><input type="checkbox" data-select="${html(item.id)}" aria-label="${html(selectionHint)}"${selectionDisabled}> Add to brief</label>
  </div>
</article>`;
}

function renderHtml(model) {
  const aesthetics = uniqueFacet(model.items, 'aesthetic_families');
  const interfaces = uniqueFacet(model.items, 'interface_types');
  const platforms = uniqueFacet(model.items, 'platforms');
  const tags = uniqueFacet(model.items, 'tags');
  const cards = model.items.length > 0
    ? model.items.map(renderCard).join('\n')
    : '<p class="empty-state">The private library is empty. Add and validate references before browsing.</p>';
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>Private design inspiration</title>
<link rel="stylesheet" href="/style.css">
</head>
<body>
<a class="skip-link" href="#gallery">Skip to references</a>
<header class="site-header">
  <div>
    <p class="eyebrow">Firstmate private library</p>
    <h1>Design inspiration</h1>
    <p>Browse neutral source records, then select captain-approved references for a bounded design brief.</p>
  </div>
  <div class="privacy-note" role="note">Loopback only. No account, sharing, telemetry, external proxy, or external preview fetch.</div>
</header>
<main>
  <section class="controls" aria-labelledby="filter-heading">
    <h2 id="filter-heading">Search and filters</h2>
    <div class="control-grid">
      <label>Search <input id="search" type="search" autocomplete="off" placeholder="ID, title, observation, tag"></label>
      <label>Aesthetic family <select id="filter-aesthetic"><option value="">All</option>${optionMarkup(aesthetics)}</select></label>
      <label>Interface or page type <select id="filter-interface"><option value="">All</option>${optionMarkup(interfaces)}</select></label>
      <label>Platform <select id="filter-platform"><option value="">All</option>${optionMarkup(platforms)}</select></label>
      <label>Tag <select id="filter-tag"><option value="">All</option>${optionMarkup(tags)}</select></label>
      <label>Rights <select id="filter-kind"><option value="">All</option><option value="reference-only">Inspiration only</option><option value="reusable-asset">Reusable with license</option></select></label>
      <label>Source health <select id="filter-health"><option value="">All</option><option value="healthy">Healthy</option><option value="redirected">Redirected</option><option value="unavailable">Unavailable</option><option value="blocked">Blocked</option><option value="unknown">Unknown</option></select></label>
    </div>
    <p id="result-count" aria-live="polite">${model.items.length} references</p>
  </section>

  <section class="rights-legend" aria-labelledby="rights-heading">
    <h2 id="rights-heading">Rights legend</h2>
    <p><span class="legend-swatch reference-only"></span><strong>Inspiration only</strong> means abstract qualities may inform direction, but images, code, and source-specific expression may not be reused.</p>
    <p><span class="legend-swatch reusable"></span><strong>Reusable with license</strong> means reuse is limited to the recorded license and attribution terms.</p>
  </section>

  <section id="gallery" class="gallery" aria-label="Design references">
${cards}
  </section>

  <section class="brief-builder" aria-labelledby="brief-heading">
    <div>
      <h2 id="brief-heading">Selected-direction brief</h2>
      <p><span id="selection-count">0</span> captain-approved references selected.</p>
    </div>
    <label>Intent for this project or surface
      <textarea id="brief-intent" rows="3" placeholder="Users, product outcome, content hierarchy, and representative surface"></textarea>
    </label>
    <label>Additional project guardrails
      <textarea id="brief-guardrails" rows="2" placeholder="Design-system, platform, performance, brand, or implementation constraints"></textarea>
    </label>
    <button type="button" id="build-brief" disabled>Build four-pillar brief</button>
  </section>
</main>

<dialog id="detail-dialog" aria-labelledby="detail-title">
  <form method="dialog" class="dialog-close"><button type="submit" aria-label="Close reference details">Close</button></form>
  <div id="detail-content"></div>
</dialog>

<dialog id="brief-dialog" aria-labelledby="generated-brief-title">
  <form method="dialog" class="dialog-close"><button type="submit" aria-label="Close generated brief">Close</button></form>
  <h2 id="generated-brief-title">Four-pillar design brief</h2>
  <label>Generated brief <textarea id="generated-brief" rows="24" readonly></textarea></label>
  <button type="button" id="copy-brief">Copy brief</button>
</dialog>

<p id="live-status" class="live-status" role="status" aria-live="polite"></p>
<script src="/app.js" defer></script>
</body>
</html>
`;
}

const STYLE_CSS = `
:root {
  color-scheme: light dark;
  --background: #f4f1ea;
  --surface: #fffdf8;
  --ink: #17201d;
  --muted: #53605b;
  --line: #c8cec8;
  --accent: #075f56;
  --accent-ink: #ffffff;
  --reuse: #236c3d;
  --reference: #9a5b12;
  --danger: #8a2f2f;
  font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
}
* { box-sizing: border-box; }
html { overflow-x: hidden; }
body { margin: 0; min-width: 0; overflow-x: hidden; background: var(--background); color: var(--ink); line-height: 1.5; }
button, input, select, textarea { font: inherit; }
button, input, select, textarea, .reference-card { outline-offset: 3px; }
:focus-visible { outline: 3px solid #d16b00; }
button { border: 1px solid var(--accent); border-radius: .45rem; padding: .55rem .75rem; background: var(--accent); color: var(--accent-ink); cursor: pointer; }
button:disabled { cursor: not-allowed; opacity: .55; }
input, select, textarea { width: 100%; min-width: 0; border: 1px solid var(--line); border-radius: .4rem; padding: .55rem; background: var(--surface); color: var(--ink); }
textarea { resize: vertical; }
code, .health, .rights, .tag { overflow-wrap: anywhere; }
.skip-link { position: absolute; left: .75rem; top: -5rem; z-index: 20; padding: .6rem; background: var(--surface); color: var(--ink); }
.skip-link:focus { top: .75rem; }
.site-header { display: grid; grid-template-columns: minmax(0, 1fr) minmax(15rem, 28rem); gap: 1.5rem; align-items: end; padding: clamp(1.25rem, 4vw, 3.5rem); background: #102d29; color: #fff; }
.site-header h1 { margin: 0; font-size: clamp(2rem, 6vw, 4.5rem); line-height: .95; }
.site-header p { max-width: 68ch; }
.eyebrow { margin: 0 0 .5rem; letter-spacing: .12em; text-transform: uppercase; font-size: .78rem; }
.privacy-note { border: 1px solid #70918c; border-radius: .6rem; padding: 1rem; }
main { width: min(100%, 96rem); margin-inline: auto; padding: clamp(1rem, 3vw, 2rem); }
.controls, .rights-legend, .brief-builder { margin-block: 1rem 2rem; padding: 1rem; border: 1px solid var(--line); border-radius: .75rem; background: var(--surface); }
.control-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(100%, 13rem), 1fr)); gap: .85rem; }
.control-grid label, .brief-builder label { display: grid; gap: .35rem; font-weight: 650; }
.rights-legend { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(100%, 20rem), 1fr)); gap: .6rem 1.5rem; }
.rights-legend h2 { grid-column: 1 / -1; }
.legend-swatch { display: inline-block; width: .8rem; height: .8rem; margin-right: .4rem; border-radius: 50%; }
.legend-swatch.reference-only { background: var(--reference); }
.legend-swatch.reusable { background: var(--reuse); }
.gallery { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(100%, 18rem), 1fr)); gap: 1rem; align-items: start; }
.reference-card { min-width: 0; overflow: hidden; border: 1px solid var(--line); border-radius: .8rem; background: var(--surface); box-shadow: 0 .25rem 1rem rgb(0 0 0 / .08); }
.reference-card[hidden] { display: none; }
.preview { aspect-ratio: 16 / 10; background: #dfe4de; overflow: hidden; }
.preview img { width: 100%; height: 100%; object-fit: cover; display: block; }
.preview-placeholder { display: grid; place-items: center; width: 100%; height: 100%; padding: 1rem; color: #3d4945; background: repeating-linear-gradient(135deg, #e6e9e4, #e6e9e4 1rem, #dce1db 1rem, #dce1db 2rem); text-align: center; }
.card-body { display: grid; gap: .65rem; padding: 1rem; }
.card-body h2, .card-body p { margin: 0; overflow-wrap: anywhere; }
.card-id-row { display: flex; flex-wrap: wrap; gap: .4rem; justify-content: space-between; align-items: center; }
.reference-id { font-size: .9rem; font-weight: 750; }
.preference-badge { border-radius: 999px; padding: .15rem .45rem; background: #d6eee3; color: #184f31; font-size: .75rem; }
.preference-badge.avoid { background: #f4dede; color: #742525; }
.tag-list { display: flex; flex-wrap: wrap; gap: .3rem; }
.tag { border: 1px solid var(--line); border-radius: 999px; padding: .1rem .4rem; font-size: .75rem; color: var(--muted); }
.rights { border-left: .35rem solid; padding-left: .55rem; font-weight: 650; }
.rights.reference-only { border-color: var(--reference); }
.rights.reusable { border-color: var(--reuse); }
.card-actions { display: flex; flex-wrap: wrap; gap: .45rem; }
.card-actions button { flex: 1 1 7rem; }
.selection { display: flex; gap: .5rem; align-items: center; }
.selection input { width: auto; }
.brief-builder { display: grid; gap: 1rem; }
dialog { width: min(calc(100% - 2rem), 54rem); max-height: calc(100% - 2rem); overflow: auto; border: 1px solid var(--line); border-radius: .8rem; background: var(--surface); color: var(--ink); }
dialog::backdrop { background: rgb(0 0 0 / .62); }
.dialog-close { display: flex; justify-content: flex-end; }
.detail-grid { display: grid; gap: 1rem; }
.detail-section { border-top: 1px solid var(--line); padding-top: .8rem; }
.detail-section ul { padding-left: 1.3rem; }
.preference-form { display: grid; gap: .8rem; }
.preference-flags, .rating-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(100%, 10rem), 1fr)); gap: .7rem; }
.preference-flags label { display: flex; align-items: center; gap: .45rem; }
.preference-flags input { width: auto; }
.rating-grid label { display: grid; gap: .25rem; }
.live-status { position: fixed; inset: auto 1rem 1rem auto; max-width: min(28rem, calc(100% - 2rem)); margin: 0; padding: .7rem 1rem; border-radius: .5rem; background: #102d29; color: #fff; transform: translateY(150%); transition: transform .18s ease; }
.live-status.visible { transform: translateY(0); }
.empty-state { grid-column: 1 / -1; padding: 2rem; border: 1px dashed var(--line); text-align: center; }
@media (max-width: 48rem) {
  .site-header { grid-template-columns: 1fr; }
  .site-header h1 { line-height: 1.05; }
}
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after { scroll-behavior: auto !important; animation-duration: .01ms !important; animation-iteration-count: 1 !important; transition-duration: .01ms !important; }
}
@media (prefers-color-scheme: dark) {
  :root { --background: #111815; --surface: #1b2420; --ink: #eff7f1; --muted: #b7c4bd; --line: #4c5a53; --accent: #91d5c8; --accent-ink: #102d29; }
  .preview-placeholder { color: #d6dfda; background: repeating-linear-gradient(135deg, #27332d, #27332d 1rem, #202a25 1rem, #202a25 2rem); }
  .preference-badge { background: #244d39; color: #dff5e8; }
  .preference-badge.avoid { background: #582d2d; color: #ffe5e5; }
}
`;

function loadAppJs() {
  const stat = fs.lstatSync(APP_PATH);
  if (!stat.isFile() || stat.isSymbolicLink()) {
    throw new Error('gallery app must be a regular non-symlink file');
  }
  return fs.readFileSync(APP_PATH, 'utf8');
}

function runHelper(helper, home, args, input) {
  const result = spawnSync(helper, args, {
    env: { ...process.env, FM_HOME: home },
    input,
    encoding: 'utf8',
    timeout: 10_000,
    maxBuffer: 2 * 1024 * 1024,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error((result.stderr || result.stdout || 'private library command failed').trim());
  }
  return result.stdout;
}

function securityHeaders(contentType) {
  return {
    'Content-Type': contentType,
    'Cache-Control': 'no-store',
    'Content-Security-Policy': "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'",
    'Referrer-Policy': 'no-referrer',
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'DENY',
  };
}

function jsonResponse(response, status, value) {
  response.writeHead(status, securityHeaders('application/json; charset=utf-8'));
  response.end(`${JSON.stringify(value)}\n`);
}

function textResponse(response, status, contentType, value) {
  response.writeHead(status, securityHeaders(contentType));
  response.end(value);
}

function requestBody(request, maximum = 64 * 1024) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    request.on('data', chunk => {
      size += chunk.length;
      if (size > maximum) {
        reject(new Error('request body is too large'));
        request.destroy();
        return;
      }
      chunks.push(chunk);
    });
    request.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    request.on('error', reject);
  });
}

function isEmptyPreference(preference) {
  return preference.favorite === false
    && preference.avoid === false
    && preference.notes === ''
    && Object.values(preference.ratings || {}).every(value => value === null);
}

function realPreviewPath(model, item) {
  const preview = previewAsset(item);
  if (!preview) return null;
  const candidate = path.join(model.paths.root, preview.path);
  const real = fs.realpathSync(candidate);
  const prefix = `${model.paths.root}${path.sep}`;
  if (!real.startsWith(prefix)) throw new Error('preview path escaped the private library');
  const stat = fs.lstatSync(real);
  if (!stat.isFile() || stat.isSymbolicLink()) throw new Error('preview is not a regular local file');
  const type = PREVIEW_TYPES.get(path.extname(real).toLowerCase());
  if (!type) return null;
  return { real, type };
}

function serveCommand(options) {
  const home = canonicalHome(options.home);
  const helper = fs.realpathSync(options.helper || '');
  const port = requireInteger(options.port, 'port', 1024, 65535);
  const token = requireToken(options.token);
  const ready = path.resolve(options.ready || '');
  const runtime = path.join(libraryPaths(home).root, '.gallery');
  const runtimeReal = fs.realpathSync(runtime);
  if (path.dirname(ready) !== runtimeReal || path.basename(ready) !== `ready.${token}`) {
    fail('ready path is outside the private gallery runtime', 2);
  }
  runHelper(helper, home, ['validate']);

  let preferenceQueue = Promise.resolve();
  let server;
  const expectedHost = `${HOST}:${port}`;
  const expectedOrigin = `http://${expectedHost}`;

  async function handler(request, response) {
    if (request.headers.host !== expectedHost) {
      jsonResponse(response, 421, { error: 'loopback Host boundary rejected' });
      return;
    }
    const origin = request.headers.origin;
    if (origin && origin !== expectedOrigin) {
      jsonResponse(response, 403, { error: 'cross-origin request rejected' });
      return;
    }
    const url = new URL(request.url, expectedOrigin);
    try {
      if (request.method === 'GET' && url.pathname === '/health') {
        if (request.headers['x-firstmate-token'] !== token) {
          jsonResponse(response, 404, { error: 'not found' });
          return;
        }
        const address = server.address();
        jsonResponse(response, 200, { ok: true, address: address.address, port: address.port, schema: RUNTIME_SCHEMA });
        return;
      }
      if (request.method === 'POST' && url.pathname === '/__control/stop') {
        if (request.headers['x-firstmate-token'] !== token) {
          jsonResponse(response, 404, { error: 'not found' });
          return;
        }
        jsonResponse(response, 200, { stopped: true });
        setImmediate(() => server.close(() => process.exit(0)));
        setTimeout(() => process.exit(0), 1500).unref();
        return;
      }
      if (request.method === 'GET' && url.pathname === '/') {
        runHelper(helper, home, ['validate']);
        textResponse(response, 200, 'text/html; charset=utf-8', renderHtml(loadModel(home)));
        return;
      }
      if (request.method === 'GET' && url.pathname === '/style.css') {
        textResponse(response, 200, 'text/css; charset=utf-8', STYLE_CSS);
        return;
      }
      if (request.method === 'GET' && url.pathname === '/app.js') {
        textResponse(response, 200, 'text/javascript; charset=utf-8', loadAppJs());
        return;
      }
      if (request.method === 'GET' && url.pathname === '/api/library') {
        runHelper(helper, home, ['validate']);
        const model = loadModel(home);
        jsonResponse(response, 200, {
          schema: 'firstmate.design-inspiration.gallery-api/v1',
          csrf_token: token,
          items: model.items.map(item => ({ ...item, rights_summary: rightsText(item) })),
        });
        return;
      }
      if (request.method === 'POST' && url.pathname === '/api/preferences') {
        if (request.headers['x-firstmate-token'] !== token) {
          jsonResponse(response, 403, { error: 'private request token rejected' });
          return;
        }
        if ((request.headers['content-type'] || '').split(';')[0].trim() !== 'application/json') {
          jsonResponse(response, 415, { error: 'application/json is required' });
          return;
        }
        const body = await requestBody(request);
        const submitted = JSON.parse(body);
        preferenceQueue = preferenceQueue.then(() => {
          runHelper(helper, home, ['validate']);
          const model = loadModel(home);
          const id = submitted?.preference?.id;
          if (typeof id !== 'string' || !model.items.some(item => item.id === id)) {
            throw new Error('preference ID is not present in the private manifest');
          }
          const current = readJsonRegular(model.paths.preferences).preferences.filter(entry => entry.id !== id);
          if (!isEmptyPreference(submitted.preference)) current.push(submitted.preference);
          const document = {
            schema: 'firstmate.design-inspiration.preferences/v1',
            preferences: current,
          };
          runHelper(helper, home, ['preferences', 'import', '-'], `${JSON.stringify(document)}\n`);
          return isEmptyPreference(submitted.preference) ? null : submitted.preference;
        });
        const saved = await preferenceQueue;
        jsonResponse(response, 200, { preference: saved });
        return;
      }
      if (request.method === 'GET' && url.pathname.startsWith('/asset/')) {
        runHelper(helper, home, ['validate']);
        const id = decodeURIComponent(url.pathname.slice('/asset/'.length));
        if (!/^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$/.test(id)) {
          jsonResponse(response, 404, { error: 'asset not found' });
          return;
        }
        const model = loadModel(home);
        const item = model.items.find(candidate => candidate.id === id);
        const preview = item ? realPreviewPath(model, item) : null;
        if (!preview) {
          jsonResponse(response, 404, { error: 'asset not found' });
          return;
        }
        response.writeHead(200, {
          ...securityHeaders(preview.type),
          'Content-Length': fs.statSync(preview.real).size,
          'Content-Disposition': 'inline',
        });
        fs.createReadStream(preview.real).pipe(response);
        return;
      }
      jsonResponse(response, 404, { error: 'not found' });
    } catch (error) {
      jsonResponse(response, 400, { error: error.message });
    }
  }

  server = http.createServer(handler);
  server.on('clientError', (_error, socket) => socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n'));
  server.on('error', error => fail(error.message));
  server.listen(port, HOST, () => {
    fs.writeFileSync(ready, `${token}\n`, { encoding: 'utf8', mode: 0o600, flag: 'wx' });
  });
  const shutdown = () => server.close(() => process.exit(0));
  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);
  process.on('SIGHUP', () => {});
}

function localRequest(port, token, method, pathname) {
  return new Promise((resolve, reject) => {
    const request = http.request({
      host: HOST,
      port,
      method,
      path: pathname,
      headers: {
        Host: `${HOST}:${port}`,
        'X-Firstmate-Token': token,
        'Content-Length': '0',
      },
      timeout: 1200,
    }, response => {
      const chunks = [];
      response.on('data', chunk => chunks.push(chunk));
      response.on('end', () => resolve({ status: response.statusCode, body: Buffer.concat(chunks).toString('utf8') }));
    });
    request.on('timeout', () => request.destroy(new Error('loopback request timed out')));
    request.on('error', reject);
    request.end();
  });
}

async function probeCommand(options, stop = false) {
  const port = requireInteger(options.port, 'port', 1024, 65535);
  const token = requireToken(options.token);
  try {
    const result = await localRequest(port, token, stop ? 'POST' : 'GET', stop ? '/__control/stop' : '/health');
    if (result.status !== 200) process.exit(1);
    if (!stop) {
      const health = JSON.parse(result.body);
      if (health.ok !== true || health.address !== HOST || health.port !== port) process.exit(1);
      process.stdout.write(`${JSON.stringify(health)}\n`);
    }
  } catch {
    process.exit(1);
  }
}

const options = parseArgs(process.argv.slice(2));

switch (options.command) {
  case 'render': {
    const home = canonicalHome(options.home);
    process.stdout.write(renderHtml(loadModel(home)));
    break;
  }
  case 'serve':
    serveCommand(options);
    break;
  case 'probe':
    await probeCommand(options, false);
    break;
  case 'stop':
    await probeCommand(options, true);
    break;
  default:
    fail('usage: fm-design-inspiration-gallery.mjs render|serve|probe|stop [options]', 2);
}
