const FIXTURE_CONTENT = Object.freeze({
  'dispatch-card': Object.freeze({
    eyebrow: 'Dispatch 24-0815',
    title: 'Harbor grid response',
    summary: 'A deterministic demand-response window is ready for local review.',
    details: Object.freeze([
      Object.freeze(['Window', '14:00–15:30']),
      Object.freeze(['Capacity', '2.8 MW']),
      Object.freeze(['Confidence', 'Verified']),
    ]),
    action: 'Review dispatch',
    note: 'Synthetic data only. No account or remote service is connected.',
  }),
  'localization-card': Object.freeze({
    eyebrow: 'Lokalisierungsprüfung 24-0815',
    title: 'Zusammenfassung der standortübergreifenden Bereitschaft',
    summary: 'Diese deterministische Langtextvariante prüft Umbruch, Vergrößerung und schmale Ansichten ohne entfernte Inhalte.',
    details: Object.freeze([
      Object.freeze(['Bereitschaftszeitraum', '14:00–15:30']),
      Object.freeze(['Zusammengefasste Kapazität', '2,8 MW']),
      Object.freeze(['Überprüfungsstatus', 'Vollständig bestätigt']),
    ]),
    action: 'Ausführliche Bereitschaftszusammenfassung prüfen',
    note: 'Ausschließlich synthetische Daten. Es besteht keine Verbindung zu Konten oder externen Diensten.',
  }),
});

function appendTextElement(document, parent, tagName, className, text) {
  const element = document.createElement(tagName);
  if (className) element.className = className;
  element.textContent = text;
  parent.append(element);
  return element;
}

export function renderSyntheticFixture(fixtureId, viewportElement) {
  const content = FIXTURE_CONTENT[fixtureId];
  if (!content) throw new Error(`Unknown synthetic fixture: ${fixtureId}`);
  if (!viewportElement || typeof viewportElement.replaceChildren !== 'function') {
    throw new TypeError('A fixture viewport element is required.');
  }
  const { ownerDocument: document } = viewportElement;
  const card = document.createElement('article');
  card.className = 'synthetic-card';
  card.dataset.fixture = fixtureId;
  card.setAttribute('aria-labelledby', 'synthetic-card-title');

  const header = document.createElement('header');
  header.className = 'synthetic-card__header';
  appendTextElement(document, header, 'p', 'synthetic-card__eyebrow', content.eyebrow);
  appendTextElement(document, header, 'h3', 'synthetic-card__title', content.title).id = 'synthetic-card-title';
  appendTextElement(document, header, 'p', 'synthetic-card__summary', content.summary);
  card.append(header);

  const details = document.createElement('dl');
  details.className = 'synthetic-card__details';
  for (const [label, value] of content.details) {
    const group = document.createElement('div');
    group.className = 'synthetic-card__detail';
    appendTextElement(document, group, 'dt', '', label);
    appendTextElement(document, group, 'dd', '', value);
    details.append(group);
  }
  card.append(details);

  const footer = document.createElement('footer');
  footer.className = 'synthetic-card__footer';
  const action = appendTextElement(document, footer, 'button', 'synthetic-card__action', content.action);
  action.type = 'button';
  action.addEventListener('click', () => {
    note.textContent = content.note;
    note.focus();
  });
  const note = appendTextElement(document, footer, 'p', 'synthetic-card__note', content.note);
  note.tabIndex = -1;
  footer.append(note);
  card.append(footer);

  viewportElement.replaceChildren(card);
  viewportElement.dataset.fixture = fixtureId;
  return card;
}

export function applySyntheticViewport(viewportElement, viewport) {
  if (!viewportElement || !viewport || !Number.isInteger(viewport.width) || !Number.isInteger(viewport.height)) {
    throw new TypeError('An exact integer viewport is required.');
  }
  viewportElement.style.setProperty('--fixture-viewport-width', `${viewport.width}px`);
  viewportElement.style.setProperty('--fixture-viewport-height', `${viewport.height}px`);
  viewportElement.dataset.viewportWidth = String(viewport.width);
  viewportElement.dataset.viewportHeight = String(viewport.height);
}

export function fixtureIds() {
  return Object.keys(FIXTURE_CONTENT);
}
