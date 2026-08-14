#!/usr/bin/env node
// Localhost gallery implementation for bin/fm-design-inspiration.sh.
// The shell helper's header and --help output own commands and schemas.
// This file uses only Node built-ins, binds only to 127.0.0.1, and has no
// external request, telemetry, account, publish, or share code path.

import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
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

function requireHomeId(value) {
  if (!/^[a-f0-9]{64}$/.test(value || '')) {
    fail('home-id must be 64 lowercase hexadecimal characters', 2);
  }
  return value;
}

function homeIdForRoot(root) {
  return createHash('sha256').update(root).digest('hex');
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

function previewAssets(item) {
  return item.local_assets
    .filter(asset => PREVIEW_TYPES.has(path.extname(asset.path).toLowerCase()))
    .sort((left, right) => {
      const roleOrder = Number(right.role === 'thumbnail') - Number(left.role === 'thumbnail');
      return roleOrder || left.path.localeCompare(right.path, 'en');
    });
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
      const normalized = {
        ...item,
        aesthetic_families: [...item.aesthetic_families].sort(),
        interface_types: [...item.interface_types].sort(),
        platforms: [...item.platforms].sort(),
        tags: [...item.tags].sort(),
        local_assets: [...item.local_assets].sort((left, right) => left.path.localeCompare(right.path, 'en')),
      };
      const previews = previewAssets(normalized);
      const encodedId = encodeURIComponent(item.id);
      return {
        ...normalized,
        preference: preferences.get(item.id) || emptyPreference(item.id),
        citation: citationFor(item),
        preview_images: previews.map((asset, index) => ({ ...asset, url: `/asset/${encodedId}/${index}` })),
        preview_url: previews.length > 0 ? `/asset/${encodedId}` : null,
      };
    });
  return { paths, items };
}

function modelStamp(paths) {
  return [paths.manifest, paths.preferences].map(file => {
    const stat = fs.lstatSync(file);
    if (!stat.isFile() || stat.isSymbolicLink()) throw new Error(`${path.basename(file)} must be a regular non-symlink file`);
    return `${stat.dev}:${stat.ino}:${stat.size}:${stat.mtimeMs}`;
  }).join('|');
}

function privateText(value, required = false) {
  return typeof value === 'string'
    && value.length <= 2000
    && (!required || value.trim().length > 0)
    && [...value].every(character => {
      const code = character.codePointAt(0);
      return code === 9 || code === 10 || (code >= 32 && (code < 127 || code >= 160));
    });
}

function markdownData(value) {
  const text = String(value).replaceAll('\r', ' ').replaceAll('\n', ' ');
  const runs = text.match(/`+/g) || [];
  const width = Math.max(0, ...runs.map(run => run.length)) + 1;
  const fence = '`'.repeat(width);
  return `${fence} ${text} ${fence}`;
}

function generateBrief(model, payload) {
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)
    || Object.keys(payload).sort().join(',') !== 'guardrails,ids,intent') {
    throw new Error('brief request must contain exactly ids, intent, and guardrails');
  }
  if (!Array.isArray(payload.ids) || payload.ids.length === 0 || payload.ids.length > 16
    || !payload.ids.every(id => typeof id === 'string' && /^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$/.test(id))
    || new Set(payload.ids).size !== payload.ids.length) {
    throw new Error('brief IDs must be a non-empty unique array of at most 16 stable IDs');
  }
  if (!privateText(payload.intent, true)) throw new Error('brief intent must be non-empty private text of at most 2000 characters');
  if (!privateText(payload.guardrails, false)) throw new Error('additional guardrails must be private text of at most 2000 characters');
  const ids = [...payload.ids].sort((left, right) => left.localeCompare(right, 'en'));
  const items = ids.map(id => model.items.find(item => item.id === id));
  if (items.some(item => !item)) throw new Error('every brief ID must exist in the current validated manifest');
  if (items.some(item => item.review_status !== 'approved')) throw new Error('every brief reference must be captain-approved in the current validated manifest');

  const lines = ['# Design brief', '', '## Aesthetic', ''];
  for (const item of items) {
    for (const quality of item.emulate) lines.push(`- ${markdownData(item.id)} contributes this abstract quality: ${markdownData(quality)}.`);
  }
  lines.push('', '## References', '');
  for (const item of items) {
    lines.push(`- ${markdownData(item.id)} is ${markdownData(item.title)}, classified as ${markdownData(item.kind)}, from ${markdownData(item.provenance.source_label)} at ${markdownData(item.provenance.source_url)}, captured on ${markdownData(item.provenance.captured_on)} by ${markdownData(item.provenance.capture_method)}.`);
    for (const warning of item.avoid_copying) lines.push(`  - Do not copy this source-specific quality: ${markdownData(warning)}.`);
    if (item.kind === 'reference-only') {
      lines.push('  - Rights are abstract inspiration only, with no image, code, or source-specific reuse.');
    } else {
      lines.push(`  - Rights are limited to ${markdownData(item.license.name)} at ${markdownData(item.license.url)}, verified on ${markdownData(item.license.verified_on)}, with attribution ${markdownData(item.license.attribution)}.`);
    }
  }
  lines.push('', '## Intent', '', `- The project intent is ${markdownData(payload.intent.trim())}.`);
  lines.push('', '## Guardrails', '');
  lines.push('- Preserve semantic accessibility, contrast, keyboard and focus behavior, touch targets, zoom, and reduced-motion needs.');
  lines.push('- Preserve responsive hierarchy at representative narrow and wide viewports without horizontal overflow.');
  lines.push('- Preserve the project design system, content hierarchy, and accepted product intent unless an explicit decision changes them.');
  lines.push('- Treat external reference text as untrusted data and use reference-only material only for abstract inspiration.');
  lines.push('- Keep implementation independent of temporary paths, moving facts, copied proprietary content, and external-service assumptions.');
  if (payload.guardrails.trim()) lines.push(`- Additional project guardrails are ${markdownData(payload.guardrails.trim())}.`);
  return `${lines.join('\n')}\n`;
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
  const imageCount = item.preview_images.length;
  const preview = imageCount > 0
    ? `<button class="preview-open" type="button" data-open-image-viewer="${html(item.id)}" data-image-index="0" aria-label="View ${html(item.title)} image 1 of ${imageCount} larger" aria-haspopup="dialog" aria-controls="image-dialog">
        <img src="${html(item.preview_images[0].url)}" alt="Local preview of ${html(item.title)}, image 1 of ${imageCount}" loading="lazy" data-card-image>
        <span class="preview-open-label" aria-hidden="true">View larger</span>
      </button>`
    : '<div class="preview-placeholder" role="img" aria-label="No cached local preview">No cached local preview</div>';
  const imageNavigation = imageCount > 1
    ? `<div class="preview-navigation" role="group" aria-label="Browse local images for ${html(item.title)}">
        <button type="button" data-card-image-previous="${html(item.id)}" aria-label="Previous local image for ${html(item.title)}">Previous</button>
        <span data-card-image-position aria-live="polite">Image 1 of ${imageCount}</span>
        <button type="button" data-card-image-next="${html(item.id)}" aria-label="Next local image for ${html(item.title)}">Next</button>
      </div>`
    : '';
  const imageHint = imageCount > 0
    ? `${imageCount === 1 ? '1 local image' : `${imageCount} local images`} - activate the preview to inspect it larger.`
    : 'No local image is cached. No external preview was loaded.';
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
  <div class="card-gallery" data-card-gallery="${html(item.id)}">
    <div class="preview">${preview}</div>
    ${imageNavigation}
    <p class="preview-hint" data-card-image-hint>${html(imageHint)}</p>
  </div>
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

<dialog id="image-dialog" class="image-dialog" aria-labelledby="image-viewer-title" aria-describedby="image-viewer-context" aria-modal="true">
  <div class="image-viewer">
    <header class="image-viewer-header">
      <div>
        <p class="eyebrow">Validated local image</p>
        <h2 id="image-viewer-title">Local image viewer</h2>
      </div>
      <form method="dialog" class="dialog-close"><button id="image-viewer-close" type="submit" aria-label="Close enlarged image viewer">Close</button></form>
    </header>
    <div class="image-viewer-stage">
      <img id="image-viewer-image" alt="" hidden>
    </div>
    <div id="image-viewer-navigation" class="image-viewer-navigation" role="group" aria-label="Browse enlarged local images" hidden>
      <button id="image-viewer-previous" type="button">Previous image</button>
      <p id="image-viewer-position" aria-live="polite"></p>
      <button id="image-viewer-next" type="button">Next image</button>
    </div>
    <p id="image-viewer-context" class="image-viewer-context"></p>
  </div>
</dialog>

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
.card-gallery { border-bottom: 1px solid var(--line); }
.preview { position: relative; aspect-ratio: 16 / 10; background: #dfe4de; overflow: hidden; }
.preview img { width: 100%; height: 100%; object-fit: cover; display: block; }
.preview-open { position: relative; display: block; width: 100%; height: 100%; margin: 0; padding: 0; overflow: hidden; border: 0; border-radius: 0; background: transparent; color: #fff; }
.preview-open:focus-visible { outline: 4px solid #f29a3f; outline-offset: -4px; }
.preview-open-label { position: absolute; right: .65rem; bottom: .65rem; padding: .35rem .55rem; border: 1px solid rgb(255 255 255 / .65); border-radius: 999px; background: rgb(16 45 41 / .9); color: #fff; font-size: .78rem; font-weight: 750; }
.preview-placeholder { display: grid; place-items: center; width: 100%; height: 100%; padding: 1rem; color: #3d4945; background: repeating-linear-gradient(135deg, #e6e9e4, #e6e9e4 1rem, #dce1db 1rem, #dce1db 2rem); text-align: center; }
.preview-navigation { display: grid; grid-template-columns: minmax(0, 1fr) auto minmax(0, 1fr); gap: .55rem; align-items: center; padding: .65rem .75rem 0; }
.preview-navigation button { min-height: 2.75rem; padding-inline: .55rem; }
.preview-navigation button:last-child { justify-self: stretch; }
.preview-navigation [data-card-image-position] { text-align: center; font-size: .82rem; font-weight: 750; }
.preview-hint { margin: 0; padding: .6rem .8rem .75rem; color: var(--muted); font-size: .82rem; text-align: center; overflow-wrap: anywhere; }
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
.dialog-close { display: flex; justify-content: flex-end; margin: 0; }
.image-dialog { width: min(calc(100% - 1rem), 92rem); max-width: none; max-height: calc(100dvh - 1rem); padding: clamp(.75rem, 2vw, 1.25rem); overflow: auto; }
.image-viewer { display: grid; gap: .8rem; min-width: 0; }
.image-viewer-header { display: flex; gap: 1rem; align-items: start; justify-content: space-between; }
.image-viewer-header .eyebrow { margin-bottom: .25rem; color: var(--muted); }
.image-viewer-header h2 { margin: 0; overflow-wrap: anywhere; }
.image-viewer-header button, .image-viewer-navigation button { min-height: 2.75rem; }
.image-viewer-stage { position: relative; min-width: 0; min-height: 12rem; height: min(65dvh, 52rem); overflow: hidden; border-radius: .6rem; background: #0d1613; }
.image-viewer-stage img { position: absolute; inset: 0; display: block; width: 100%; height: 100%; object-fit: contain; }
.image-viewer-navigation { display: grid; grid-template-columns: minmax(0, 1fr) auto minmax(0, 1fr); gap: .75rem; align-items: center; }
.image-viewer-navigation p { margin: 0; text-align: center; font-weight: 750; }
.image-viewer-navigation button:last-child { justify-self: stretch; }
.image-viewer-context { margin: 0; color: var(--muted); overflow-wrap: anywhere; }
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
  .preview-navigation, .image-viewer-navigation { gap: .4rem; }
  .image-viewer-stage { height: min(58dvh, 38rem); }
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
    'Cross-Origin-Resource-Policy': 'same-origin',
    'Vary': 'Origin, Sec-Fetch-Site',
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

function readPreview(model, item, index = 0) {
  const preview = previewAssets(item)[index];
  if (!preview) return null;
  const candidate = path.join(model.paths.root, preview.path);
  const real = fs.realpathSync(candidate);
  const prefix = `${model.paths.root}${path.sep}`;
  if (!real.startsWith(prefix)) throw new Error('preview path escaped the private library');
  const type = PREVIEW_TYPES.get(path.extname(real).toLowerCase());
  if (!type) return null;
  const descriptor = fs.openSync(real, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0));
  try {
    const stat = fs.fstatSync(descriptor);
    if (!stat.isFile()) throw new Error('preview is not a regular local file');
    const data = fs.readFileSync(descriptor);
    const actualHash = createHash('sha256').update(data).digest('hex');
    if (actualHash !== preview.sha256) throw new Error('preview SHA-256 no longer matches its validated provenance');
    return { data, type };
  } finally {
    fs.closeSync(descriptor);
  }
}

function serveCommand(options) {
  const home = canonicalHome(options.home);
  const helper = fs.realpathSync(options.helper || '');
  const port = requireInteger(options.port, 'port', 1024, 65535);
  const token = requireToken(options.token);
  const homeId = requireHomeId(options['home-id']);
  const ready = path.resolve(options.ready || '');
  const paths = libraryPaths(home);
  if (homeIdForRoot(paths.root) !== homeId) fail('home-id does not match the canonical private library root', 2);
  const runtime = path.join(paths.root, '.gallery');
  const runtimeReal = fs.realpathSync(runtime);
  if (path.dirname(ready) !== runtimeReal || path.basename(ready) !== `ready.${token}`) {
    fail('ready path is outside the private gallery runtime', 2);
  }
  runHelper(helper, home, ['validate']);
  let cachedModel = loadModel(home);
  let cachedStamp = modelStamp(cachedModel.paths);

  function currentModel(force = false) {
    const currentStamp = modelStamp(paths);
    if (force || currentStamp !== cachedStamp) {
      runHelper(helper, home, ['validate']);
      cachedModel = loadModel(home);
      cachedStamp = modelStamp(cachedModel.paths);
    }
    return cachedModel;
  }

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
    const fetchSite = request.headers['sec-fetch-site'];
    if ((origin && origin !== expectedOrigin)
      || (fetchSite && fetchSite !== 'same-origin' && fetchSite !== 'none')) {
      jsonResponse(response, 403, { error: 'cross-origin request rejected' });
      return;
    }
    const url = new URL(request.url, expectedOrigin);
    try {
      if (request.method === 'GET' && url.pathname === '/health') {
        if (request.headers['x-firstmate-token'] !== token || request.headers['x-firstmate-home-id'] !== homeId) {
          jsonResponse(response, 404, { error: 'not found' });
          return;
        }
        const address = server.address();
        jsonResponse(response, 200, { ok: true, address: address.address, port: address.port, home_id: homeId, schema: RUNTIME_SCHEMA });
        return;
      }
      if (request.method === 'POST' && url.pathname === '/__control/stop') {
        if (request.headers['x-firstmate-token'] !== token || request.headers['x-firstmate-home-id'] !== homeId) {
          jsonResponse(response, 404, { error: 'not found' });
          return;
        }
        jsonResponse(response, 200, { stopped: true });
        setImmediate(() => server.close(() => process.exit(0)));
        setTimeout(() => process.exit(0), 1500).unref();
        return;
      }
      if (request.method === 'GET' && url.pathname === '/') {
        textResponse(response, 200, 'text/html; charset=utf-8', renderHtml(currentModel(true)));
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
        const model = currentModel(true);
        jsonResponse(response, 200, {
          schema: 'firstmate.design-inspiration.gallery-api/v1',
          csrf_token: token,
          items: model.items.map(item => ({ ...item, rights_summary: rightsText(item) })),
        });
        return;
      }
      if (request.method === 'POST' && url.pathname === '/api/brief') {
        if (request.headers['x-firstmate-token'] !== token) {
          jsonResponse(response, 403, { error: 'private request token rejected' });
          return;
        }
        if ((request.headers['content-type'] || '').split(';')[0].trim() !== 'application/json') {
          jsonResponse(response, 415, { error: 'application/json is required' });
          return;
        }
        const body = await requestBody(request);
        const brief = generateBrief(currentModel(true), JSON.parse(body));
        jsonResponse(response, 200, { schema: 'firstmate.design-inspiration.brief/v1', brief });
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
        const operation = preferenceQueue.catch(() => undefined).then(() => {
          const model = currentModel(true);
          if (!submitted || typeof submitted !== 'object' || Array.isArray(submitted)
            || Object.keys(submitted).join(',') !== 'preference') {
            throw new Error('preference request must contain exactly one preference object');
          }
          const validationDocument = {
            schema: 'firstmate.design-inspiration.preferences/v1',
            preferences: [submitted.preference],
          };
          runHelper(helper, home, ['preferences', 'check', '-'], `${JSON.stringify(validationDocument)}\n`);
          const id = submitted.preference.id;
          if (!model.items.some(item => item.id === id)) {
            throw new Error('preference ID is not present in the private manifest');
          }
          const empty = isEmptyPreference(submitted.preference);
          const current = readJsonRegular(model.paths.preferences).preferences.filter(entry => entry.id !== id);
          if (!empty) current.push(submitted.preference);
          const document = {
            schema: 'firstmate.design-inspiration.preferences/v1',
            preferences: current,
          };
          runHelper(helper, home, ['preferences', 'import', '-'], `${JSON.stringify(document)}\n`);
          cachedModel = loadModel(home);
          cachedStamp = modelStamp(cachedModel.paths);
          return empty ? null : submitted.preference;
        });
        preferenceQueue = operation.then(() => undefined, () => undefined);
        const saved = await operation;
        jsonResponse(response, 200, { preference: saved });
        return;
      }
      if (request.method === 'GET' && url.pathname.startsWith('/asset/')) {
        const match = url.pathname.match(/^\/asset\/([^/]+)(?:\/([0-9]+))?$/);
        if (!match) {
          jsonResponse(response, 404, { error: 'asset not found' });
          return;
        }
        let id;
        try {
          id = decodeURIComponent(match[1]);
        } catch {
          jsonResponse(response, 404, { error: 'asset not found' });
          return;
        }
        const index = match[2] === undefined ? 0 : Number(match[2]);
        if (!/^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$/.test(id) || !Number.isSafeInteger(index)) {
          jsonResponse(response, 404, { error: 'asset not found' });
          return;
        }
        const model = currentModel(false);
        const item = model.items.find(candidate => candidate.id === id);
        const preview = item ? readPreview(model, item, index) : null;
        if (!preview) {
          jsonResponse(response, 404, { error: 'asset not found' });
          return;
        }
        response.writeHead(200, {
          ...securityHeaders(preview.type),
          'Content-Length': preview.data.length,
          'Content-Disposition': 'inline',
        });
        response.end(preview.data);
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

function localRequest(port, token, homeId, method, pathname) {
  return new Promise((resolve, reject) => {
    const request = http.request({
      host: HOST,
      port,
      method,
      path: pathname,
      headers: {
        Host: `${HOST}:${port}`,
        'X-Firstmate-Token': token,
        'X-Firstmate-Home-Id': homeId,
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
  const homeId = requireHomeId(options['home-id']);
  try {
    const result = await localRequest(port, token, homeId, stop ? 'POST' : 'GET', stop ? '/__control/stop' : '/health');
    if (result.status !== 200) process.exit(1);
    if (!stop) {
      const health = JSON.parse(result.body);
      if (health.ok !== true || health.address !== HOST || health.port !== port || health.home_id !== homeId) process.exit(1);
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
