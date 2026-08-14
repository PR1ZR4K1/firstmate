'use strict';

const controls = {
  search: document.querySelector('#search'),
  aesthetic: document.querySelector('#filter-aesthetic'),
  interfaceType: document.querySelector('#filter-interface'),
  platform: document.querySelector('#filter-platform'),
  tag: document.querySelector('#filter-tag'),
  kind: document.querySelector('#filter-kind'),
  health: document.querySelector('#filter-health'),
};
const cards = [...document.querySelectorAll('.reference-card')];
const itemById = new Map();
const selected = new Set();
const cardImageIndex = new Map();
const imageDialog = document.querySelector('#image-dialog');
const imageViewerTitle = document.querySelector('#image-viewer-title');
const imageViewerImage = document.querySelector('#image-viewer-image');
const imageViewerNavigation = document.querySelector('#image-viewer-navigation');
const imageViewerPrevious = document.querySelector('#image-viewer-previous');
const imageViewerPosition = document.querySelector('#image-viewer-position');
const imageViewerNext = document.querySelector('#image-viewer-next');
const imageViewerContext = document.querySelector('#image-viewer-context');
const imageViewerClose = document.querySelector('#image-viewer-close');
let csrfToken = '';
let liveTimer;
let viewerItem;
let viewerIndex = 0;
let viewerReturnFocus;

function announce(message) {
  const status = document.querySelector('#live-status');
  status.textContent = message;
  status.classList.add('visible');
  clearTimeout(liveTimer);
  liveTimer = setTimeout(() => status.classList.remove('visible'), 2600);
}

async function copyText(text, label) {
  try {
    if (navigator.clipboard && window.isSecureContext) {
      await navigator.clipboard.writeText(text);
    } else {
      const area = document.createElement('textarea');
      area.value = text;
      area.setAttribute('readonly', '');
      area.style.position = 'fixed';
      area.style.opacity = '0';
      document.body.append(area);
      area.select();
      if (!document.execCommand('copy')) throw new Error('copy command was refused');
      area.remove();
    }
    announce(label);
  } catch (error) {
    announce(`Copy failed: ${error.message}`);
  }
}

function matches(card, query) {
  const item = itemById.get(card.dataset.id);
  if (!item) return true;
  const haystack = [
    item.id,
    item.title,
    item.kind,
    item.review_status,
    item.source_health,
    item.provenance.source_label,
    item.provenance.source_url,
    ...item.aesthetic_families,
    ...item.interface_types,
    ...item.platforms,
    ...item.tags,
    ...item.observations,
    ...item.emulate,
    ...item.avoid_copying,
  ].join('\n').toLocaleLowerCase();
  return (!query || haystack.includes(query))
    && (!controls.aesthetic.value || item.aesthetic_families.includes(controls.aesthetic.value))
    && (!controls.interfaceType.value || item.interface_types.includes(controls.interfaceType.value))
    && (!controls.platform.value || item.platforms.includes(controls.platform.value))
    && (!controls.tag.value || item.tags.includes(controls.tag.value))
    && (!controls.kind.value || item.kind === controls.kind.value)
    && (!controls.health.value || item.source_health === controls.health.value);
}

function applyFilters() {
  const query = controls.search.value.trim().toLocaleLowerCase();
  let visible = 0;
  for (const card of cards) {
    card.hidden = !matches(card, query);
    if (!card.hidden) visible += 1;
  }
  document.querySelector('#result-count').textContent = `${visible} ${visible === 1 ? 'reference' : 'references'}`;
}

function updateSelection() {
  document.querySelector('#selection-count').textContent = String(selected.size);
  document.querySelector('#build-brief').disabled = selected.size === 0;
}

function element(name, text, className) {
  const node = document.createElement(name);
  if (text !== undefined) node.textContent = text;
  if (className) node.className = className;
  return node;
}

function appendTextList(parent, heading, values) {
  const section = element('section', undefined, 'detail-section');
  section.append(element('h3', heading));
  const list = element('ul');
  for (const value of values) list.append(element('li', value));
  section.append(list);
  parent.append(section);
}

function previewImages(item) {
  return Array.isArray(item.preview_images) ? item.preview_images : [];
}

function normalizedImageIndex(index, count) {
  return ((index % count) + count) % count;
}

function setCardImage(item, requestedIndex) {
  const images = previewImages(item);
  if (images.length === 0) return 0;
  const card = cards.find(candidate => candidate.dataset.id === item.id);
  if (!card) return 0;
  const index = normalizedImageIndex(requestedIndex, images.length);
  const current = images[index];
  const image = card.querySelector('[data-card-image]');
  const openButton = card.querySelector('[data-open-image-viewer]');
  const position = card.querySelector('[data-card-image-position]');
  const hint = card.querySelector('[data-card-image-hint]');
  cardImageIndex.set(item.id, index);
  if (image) {
    image.src = current.url;
    image.alt = `Local preview of ${item.title}, image ${index + 1} of ${images.length}`;
  }
  if (openButton) {
    openButton.dataset.imageIndex = String(index);
    openButton.setAttribute('aria-label', `View ${item.title} image ${index + 1} of ${images.length} larger`);
  }
  if (position) position.textContent = `Image ${index + 1} of ${images.length}`;
  if (hint) {
    hint.textContent = images.length === 1
      ? '1 local image - activate the preview to inspect it larger.'
      : `${images.length} local images - image ${index + 1} is shown; browse or inspect it larger.`;
  }
  return index;
}

function moveCardImage(id, delta) {
  const item = itemById.get(id);
  if (!item) {
    announce('Local image records are still loading');
    return;
  }
  setCardImage(item, (cardImageIndex.get(id) || 0) + delta);
}

function setViewerImage(requestedIndex) {
  if (!viewerItem) return;
  const images = previewImages(viewerItem);
  if (images.length === 0) return;
  viewerIndex = normalizedImageIndex(requestedIndex, images.length);
  const current = images[viewerIndex];
  imageViewerTitle.textContent = `${viewerItem.id}: ${viewerItem.title}`;
  imageViewerImage.src = current.url;
  imageViewerImage.alt = `Larger local preview of ${viewerItem.title}, image ${viewerIndex + 1} of ${images.length}`;
  imageViewerImage.hidden = false;
  imageViewerPosition.textContent = `Image ${viewerIndex + 1} of ${images.length}`;
  imageViewerContext.textContent = `Image ${viewerIndex + 1} of ${images.length}. Validated local ${current.role.replaceAll('-', ' ')}: ${current.path}. ${viewerItem.rights_summary}.`;
  imageViewerNavigation.hidden = images.length < 2;
  imageViewerPrevious.setAttribute('aria-label', `Previous enlarged image for ${viewerItem.title}`);
  imageViewerNext.setAttribute('aria-label', `Next enlarged image for ${viewerItem.title}`);
  setCardImage(viewerItem, viewerIndex);
}

function openImageViewer(id, index, returnFocus) {
  const item = itemById.get(id);
  if (!item || previewImages(item).length === 0) {
    announce('No validated local image is available to inspect');
    return;
  }
  viewerItem = item;
  viewerReturnFocus = returnFocus;
  setViewerImage(index);
  imageDialog.showModal();
  imageViewerClose.focus({ preventScroll: true });
}

function moveViewerImage(delta) {
  if (viewerItem && previewImages(viewerItem).length > 1) setViewerImage(viewerIndex + delta);
}

function initializeCardGalleries() {
  for (const item of itemById.values()) {
    if (previewImages(item).length > 0) setCardImage(item, 0);
  }
}

function ratingSelect(name, value) {
  const label = element('label');
  label.textContent = name.replaceAll('_', ' ');
  const select = element('select');
  select.name = name;
  select.setAttribute('aria-label', `${name.replaceAll('_', ' ')} rating`);
  const blank = element('option', 'Not rated');
  blank.value = '';
  select.append(blank);
  for (let rating = 1; rating <= 5; rating += 1) {
    const option = element('option', `${rating} of 5`);
    option.value = String(rating);
    option.selected = value === rating;
    select.append(option);
  }
  label.append(select);
  return label;
}

function renderPreferenceForm(item) {
  const preference = item.preference;
  const form = element('form', undefined, 'preference-form');
  form.dataset.preferenceForm = item.id;
  form.append(element('h3', 'Private captain annotations'));
  const flags = element('div', undefined, 'preference-flags');
  for (const [name, labelText] of [['favorite', 'Favorite'], ['avoid', 'Avoid']]) {
    const label = element('label');
    const input = element('input');
    input.type = 'checkbox';
    input.name = name;
    input.checked = Boolean(preference[name]);
    label.append(input, document.createTextNode(labelText));
    flags.append(label);
  }
  const favorite = flags.querySelector('[name="favorite"]');
  const avoid = flags.querySelector('[name="avoid"]');
  favorite.addEventListener('change', () => { if (favorite.checked) avoid.checked = false; });
  avoid.addEventListener('change', () => { if (avoid.checked) favorite.checked = false; });
  form.append(flags);

  const notesLabel = element('label', 'Notes');
  const notes = element('textarea');
  notes.name = 'notes';
  notes.rows = 4;
  notes.maxLength = 2000;
  notes.value = preference.notes;
  notesLabel.append(notes);
  form.append(notesLabel);

  const ratings = element('div', undefined, 'rating-grid');
  for (const name of ['typography', 'color', 'density', 'imagery', 'motion', 'overall_affinity']) {
    ratings.append(ratingSelect(name, preference.ratings[name]));
  }
  form.append(ratings);
  const save = element('button', 'Save private annotations');
  save.type = 'submit';
  form.append(save);
  form.addEventListener('submit', savePreference);
  return form;
}

function showDetail(id) {
  const item = itemById.get(id);
  if (!item) return;
  const content = document.querySelector('#detail-content');
  content.replaceChildren();
  const title = element('h2', `${item.id}: ${item.title}`);
  title.id = 'detail-title';
  content.append(title);
  const grid = element('div', undefined, 'detail-grid');
  grid.append(element('p', `Rights: ${item.rights_summary}`));
  grid.append(element('p', `Review status: ${item.review_status}. Source health: ${item.source_health}.`));
  grid.append(element('p', `Attribution source: ${item.provenance.source_label}.`));
  const source = element('p');
  source.append(document.createTextNode('Canonical source URL: '), element('code', item.provenance.source_url));
  grid.append(source);
  const copySource = element('button', 'Copy canonical source URL');
  copySource.type = 'button';
  copySource.addEventListener('click', () => copyText(item.provenance.source_url, 'Source URL copied'));
  grid.append(copySource);
  grid.append(element('p', `Captured on ${item.provenance.captured_on} by ${item.provenance.capture_method}.`));
  appendTextList(grid, 'Neutral visual observations', item.observations);
  appendTextList(grid, 'What to emulate abstractly', item.emulate);
  appendTextList(grid, 'What not to copy', item.avoid_copying);
  if (item.license) {
    appendTextList(grid, 'Recorded reuse terms', [
      `${item.license.name}: ${item.license.url}`,
      `Attribution: ${item.license.attribution}`,
      `Verified on: ${item.license.verified_on}`,
    ]);
  } else {
    appendTextList(grid, 'Recorded reuse terms', ['Reference-only. No image, code, or source-specific reuse rights are recorded.']);
  }
  const assets = item.local_assets.length
    ? item.local_assets.map(asset => `${asset.path} - ${asset.role} - SHA-256 ${asset.sha256} - added ${asset.added_on}`)
    : ['No local asset is cached. The gallery uses a truthful placeholder and performs no external preview fetch.'];
  appendTextList(grid, 'Local asset provenance', assets);
  grid.append(renderPreferenceForm(item));
  content.append(grid);
  document.querySelector('#detail-dialog').showModal();
}

function updateCardPreference(item) {
  const row = document.querySelector(`.reference-card[data-id="${item.id}"] .card-id-row`);
  if (!row) return;
  for (const badge of row.querySelectorAll('.preference-badge')) badge.remove();
  if (item.preference.favorite) row.append(element('span', 'Favorite', 'preference-badge'));
  if (item.preference.avoid) row.append(element('span', 'Avoid', 'preference-badge avoid'));
}

async function savePreference(event) {
  event.preventDefault();
  const form = event.currentTarget;
  const item = itemById.get(form.dataset.preferenceForm);
  const formData = new FormData(form);
  const ratings = {};
  for (const name of ['typography', 'color', 'density', 'imagery', 'motion', 'overall_affinity']) {
    const raw = formData.get(name);
    ratings[name] = raw ? Number(raw) : null;
  }
  const preference = {
    id: item.id,
    favorite: formData.get('favorite') === 'on',
    avoid: formData.get('avoid') === 'on',
    notes: String(formData.get('notes') || ''),
    ratings,
  };
  try {
    const response = await fetch('/api/preferences', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Firstmate-Token': csrfToken },
      body: JSON.stringify({ preference }),
    });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || 'preference save failed');
    item.preference = result.preference || {
      id: item.id,
      favorite: false,
      avoid: false,
      notes: '',
      ratings: { typography: null, color: null, density: null, imagery: null, motion: null, overall_affinity: null },
    };
    updateCardPreference(item);
    announce('Private annotations saved');
    showDetail(item.id);
  } catch (error) {
    announce(`Save failed: ${error.message}`);
  }
}

async function loadLibrary() {
  try {
    const response = await fetch('/api/library', { headers: { Accept: 'application/json' } });
    const payload = await response.json();
    if (!response.ok) throw new Error(payload.error || 'library load failed');
    csrfToken = payload.csrf_token;
    for (const item of payload.items) itemById.set(item.id, item);
    initializeCardGalleries();
    applyFilters();
  } catch (error) {
    announce(`Library unavailable: ${error.message}`);
  }
}

for (const control of Object.values(controls)) {
  control.addEventListener(control === controls.search ? 'input' : 'change', applyFilters);
}

document.addEventListener('click', event => {
  const previousImage = event.target.closest('[data-card-image-previous]');
  if (previousImage) {
    moveCardImage(previousImage.dataset.cardImagePrevious, -1);
    return;
  }
  const nextImage = event.target.closest('[data-card-image-next]');
  if (nextImage) {
    moveCardImage(nextImage.dataset.cardImageNext, 1);
    return;
  }
  const openImage = event.target.closest('[data-open-image-viewer]');
  if (openImage) {
    openImageViewer(openImage.dataset.openImageViewer, Number(openImage.dataset.imageIndex), openImage);
    return;
  }
  const idButton = event.target.closest('[data-copy-id]');
  if (idButton) copyText(idButton.dataset.copyId, `Reference ID ${idButton.dataset.copyId} copied`);
  const citationButton = event.target.closest('[data-copy-citation]');
  if (citationButton) {
    const item = itemById.get(citationButton.dataset.copyCitation);
    if (item) copyText(item.citation, `Citation for ${item.id} copied`);
  }
  const detailButton = event.target.closest('[data-detail]');
  if (detailButton) showDetail(detailButton.dataset.detail);
});

document.addEventListener('change', event => {
  if (!event.target.matches('[data-select]')) return;
  if (event.target.checked) selected.add(event.target.dataset.select);
  else selected.delete(event.target.dataset.select);
  updateSelection();
});

document.querySelector('#gallery').addEventListener('keydown', event => {
  const card = event.target.closest('.reference-card');
  if (!card || event.target !== card) return;
  if (event.key === 'Enter') {
    event.preventDefault();
    showDetail(card.dataset.id);
    return;
  }
  if (!['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown'].includes(event.key)) return;
  const visible = cards.filter(candidate => !candidate.hidden);
  const index = visible.indexOf(card);
  if (index < 0) return;
  const delta = event.key === 'ArrowLeft' || event.key === 'ArrowUp' ? -1 : 1;
  const next = visible[(index + delta + visible.length) % visible.length];
  event.preventDefault();
  next.focus();
});

document.querySelector('#build-brief').addEventListener('click', async () => {
  const intent = document.querySelector('#brief-intent').value.trim();
  if (!intent) {
    announce('Add a complete project intent before building the brief');
    document.querySelector('#brief-intent').focus();
    return;
  }
  try {
    const response = await fetch('/api/brief', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Firstmate-Token': csrfToken },
      body: JSON.stringify({
        ids: [...selected],
        intent,
        guardrails: document.querySelector('#brief-guardrails').value.trim(),
      }),
    });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || 'brief generation failed');
    document.querySelector('#generated-brief').value = result.brief;
    document.querySelector('#brief-dialog').showModal();
  } catch (error) {
    announce(`Brief failed: ${error.message}`);
  }
});

document.querySelector('#copy-brief').addEventListener('click', () => {
  copyText(document.querySelector('#generated-brief').value, 'Four-pillar brief copied');
});

imageViewerPrevious.addEventListener('click', () => moveViewerImage(-1));
imageViewerNext.addEventListener('click', () => moveViewerImage(1));
imageDialog.addEventListener('keydown', event => {
  if (event.key === 'ArrowLeft') {
    event.preventDefault();
    moveViewerImage(-1);
  } else if (event.key === 'ArrowRight') {
    event.preventDefault();
    moveViewerImage(1);
  }
});
imageDialog.addEventListener('close', () => {
  const returnFocus = viewerReturnFocus;
  viewerItem = undefined;
  viewerReturnFocus = undefined;
  imageViewerImage.hidden = true;
  imageViewerImage.removeAttribute('src');
  imageViewerImage.alt = '';
  if (returnFocus && returnFocus.isConnected) {
    queueMicrotask(() => returnFocus.focus({ preventScroll: true }));
  }
});

loadLibrary();