import './panel.css';
import {
  FIXTURES,
  PRESET_SCHEMA_ID,
  PRESET_SCHEMA_VERSION,
  RESERVED_PERSISTENCE_NAMESPACE,
  TWEAK_SCHEMA,
  TweakValidationError,
  VIEWPORT_PRESETS,
  applyTweakValues,
  createTweakStore,
} from './core.js';
import { mountNativeRenderer } from './native-renderer.js';
import { mountTweakpaneRenderer } from './tweakpane-renderer.js';
import { applySyntheticViewport, renderSyntheticFixture } from '../fixture.js';

export const DEVELOPMENT_MOUNT_BUDGET_MS = 500;
const GLOBAL_SLOT = '__FM_DESIGN_TWEAKS_PROOF__';
const TEST_SLOT = '__FM_TWEAKS_TEST__';
const SHORTCUT_LABEL = 'Alt + Shift + T';

function createElement(document, tagName, { className, text, attributes = {} } = {}) {
  const element = document.createElement(tagName);
  if (className) element.className = className;
  if (text !== undefined) element.textContent = text;
  for (const [name, value] of Object.entries(attributes)) element.setAttribute(name, value);
  return element;
}

function createSelect(document, { id, label, options }) {
  const wrapper = createElement(document, 'div', { className: 'fm-tweaks-field' });
  const labelElement = createElement(document, 'label', { text: label, attributes: { for: id } });
  const select = createElement(document, 'select', { attributes: { id, name: id } });
  for (const option of options) {
    const optionElement = createElement(document, 'option', { text: option.label, attributes: { value: option.value } });
    select.append(optionElement);
  }
  wrapper.append(labelElement, select);
  return { wrapper, select };
}

function createPanel(document) {
  const launcher = createElement(document, 'div', { className: 'fm-tweaks-launcher' });
  const toggle = createElement(document, 'button', {
    className: 'fm-tweaks-toggle',
    text: 'Design tweaks',
    attributes: {
      type: 'button',
      'data-tweaks-action': 'toggle',
      'aria-controls': 'fm-tweaks-panel',
      'aria-expanded': 'true',
      'aria-keyshortcuts': 'Alt+Shift+T',
    },
  });
  launcher.append(toggle);

  const panel = createElement(document, 'aside', {
    className: 'fm-tweaks-panel',
    attributes: {
      id: 'fm-tweaks-panel',
      'aria-labelledby': 'fm-tweaks-title',
      'data-proof-schema': PRESET_SCHEMA_ID,
      'data-persistence': 'memory-only',
    },
  });
  const headingRow = createElement(document, 'div', { className: 'fm-tweaks-heading-row' });
  const headingGroup = createElement(document, 'div');
  const eyebrow = createElement(document, 'p', { className: 'fm-tweaks-kicker', text: 'Development only' });
  const heading = createElement(document, 'h2', { text: 'Firstmate design tweaks', attributes: { id: 'fm-tweaks-title' } });
  const description = createElement(document, 'p', {
    className: 'fm-tweaks-description',
    text: `Memory-only synthetic proof. Toggle with ${SHORTCUT_LABEL}.`,
  });
  const close = createElement(document, 'button', {
    className: 'fm-tweaks-close',
    text: 'Close',
    attributes: { type: 'button', 'data-tweaks-action': 'close', 'aria-label': 'Close design tweaks' },
  });
  headingGroup.append(eyebrow, heading, description);
  headingRow.append(headingGroup, close);
  panel.append(headingRow);

  const context = createElement(document, 'fieldset', { className: 'fm-tweaks-section' });
  context.append(createElement(document, 'legend', { text: 'Synthetic context' }));
  const fixtureField = createSelect(document, {
    id: 'fm-tweaks-fixture',
    label: 'Fixture',
    options: FIXTURES.map((fixture) => ({ value: fixture.id, label: fixture.label })),
  });
  const viewportField = createSelect(document, {
    id: 'fm-tweaks-viewport',
    label: 'Viewport',
    options: VIEWPORT_PRESETS.map((viewport) => ({ value: `${viewport.width}x${viewport.height}`, label: `${viewport.label} CSS px` })),
  });
  context.append(fixtureField.wrapper, viewportField.wrapper);
  panel.append(context);

  const rendererFieldset = createElement(document, 'fieldset', { className: 'fm-tweaks-section fm-tweaks-renderers' });
  rendererFieldset.append(createElement(document, 'legend', { text: 'Renderer' }));
  const rendererChoices = createElement(document, 'div', { className: 'fm-tweaks-choice-row' });
  for (const [value, text] of [['native', 'Native'], ['tweakpane', 'Tweakpane 4.0.5']]) {
    const label = createElement(document, 'label', { className: 'fm-tweaks-choice' });
    const input = createElement(document, 'input', {
      attributes: { type: 'radio', name: 'fm-tweaks-renderer', value },
    });
    if (value === 'native') input.checked = true;
    label.append(input, document.createTextNode(text));
    rendererChoices.append(label);
  }
  rendererFieldset.append(rendererChoices);
  panel.append(rendererFieldset);

  const rendererHost = createElement(document, 'div', {
    className: 'fm-tweaks-renderer-host',
    attributes: { id: 'fm-tweaks-renderer-host' },
  });
  panel.append(rendererHost);

  const actions = createElement(document, 'fieldset', { className: 'fm-tweaks-section' });
  actions.append(createElement(document, 'legend', { text: 'Preset lifecycle' }));
  const actionGrid = createElement(document, 'div', { className: 'fm-tweaks-action-grid' });
  const actionDefinitions = [
    ['reset', 'Reset'],
    ['copy', 'Copy preset'],
    ['export', 'Export JSON'],
    ['copy-patch', 'Copy token suggestion'],
  ];
  for (const [action, text] of actionDefinitions) {
    actionGrid.append(createElement(document, 'button', {
      text,
      attributes: { type: 'button', 'data-tweaks-action': action },
    }));
  }
  actions.append(actionGrid);
  const importLabel = createElement(document, 'label', { text: 'Preset import JSON', attributes: { for: 'fm-tweaks-import' } });
  const importInput = createElement(document, 'textarea', {
    attributes: {
      id: 'fm-tweaks-import',
      name: 'fm-tweaks-import',
      rows: '5',
      spellcheck: 'false',
      'aria-describedby': 'fm-tweaks-import-help fm-tweaks-status',
    },
  });
  const importHelp = createElement(document, 'p', {
    className: 'fm-tweaks-help',
    text: 'The complete preset is validated before any fixture, viewport, or value changes.',
    attributes: { id: 'fm-tweaks-import-help' },
  });
  const importButton = createElement(document, 'button', {
    text: 'Import validated preset',
    attributes: { type: 'button', 'data-tweaks-action': 'import' },
  });
  actions.append(importLabel, importInput, importHelp, importButton);
  panel.append(actions);

  const boundary = createElement(document, 'p', {
    className: 'fm-tweaks-boundary',
    text: 'Token suggestions are data only. Applying one to source remains a separate reviewed code change.',
  });
  const status = createElement(document, 'p', {
    className: 'fm-tweaks-status',
    text: 'Ready. State is held in memory only.',
    attributes: { id: 'fm-tweaks-status', role: 'status', 'aria-live': 'polite', tabindex: '-1' },
  });
  panel.append(boundary, status);

  return {
    launcher,
    toggle,
    panel,
    close,
    fixtureSelect: fixtureField.select,
    viewportSelect: viewportField.select,
    rendererHost,
    rendererInputs: [...rendererFieldset.querySelectorAll('input[name="fm-tweaks-renderer"]')],
    importInput,
    status,
  };
}

function createEventScope() {
  const removers = [];
  return {
    listen(target, type, listener, options) {
      target.addEventListener(type, listener, options);
      removers.push(() => target.removeEventListener(type, listener, options));
    },
    dispose() {
      for (const remove of removers.splice(0).reverse()) remove();
    },
    count() {
      return removers.length;
    },
  };
}

async function writeClipboard(document, text) {
  if (globalThis.navigator?.clipboard?.writeText) {
    await globalThis.navigator.clipboard.writeText(text);
    return;
  }
  const temporary = createElement(document, 'textarea', { attributes: { 'aria-hidden': 'true' } });
  temporary.value = text;
  temporary.style.position = 'fixed';
  temporary.style.opacity = '0';
  document.body.append(temporary);
  temporary.select();
  const copied = document.execCommand?.('copy');
  temporary.remove();
  if (!copied) throw new Error('Clipboard access is unavailable.');
}

function viewportFromOption(value) {
  const [width, height] = value.split('x').map(Number);
  return { width, height };
}

function internalMount({
  appShell,
  fixtureViewport,
  mountStartedAt = performance.now(),
  rendererFactories = {
    native: mountNativeRenderer,
    tweakpane: mountTweakpaneRenderer,
  },
}) {
  if (!appShell || !fixtureViewport) throw new TypeError('The synthetic fixture shell is required.');
  const document = appShell.ownerDocument;
  const existing = globalThis[GLOBAL_SLOT];
  if (existing) existing.unmount();

  const eventScope = createEventScope();
  const store = createTweakStore();
  const elements = createPanel(document);
  let activeRenderer = null;
  let activeRendererName = 'native';
  let tweakTarget = null;
  let previousFocus = null;
  let unmounted = false;
  let lastCopiedText = null;
  let lastExportedText = null;
  let lastError = null;
  let unsubscribe = () => {};
  let mountElapsedMs = null;

  function setStatus(message, { error = false, focus = false } = {}) {
    lastError = error ? message : null;
    elements.status.textContent = message;
    elements.status.setAttribute('role', error ? 'alert' : 'status');
    elements.importInput.setAttribute('aria-invalid', error ? 'true' : 'false');
    if (focus) elements.status.focus();
  }

  function updateFixture(preset, reason) {
    if (reason === 'fixture' || reason === 'import' || !tweakTarget) {
      tweakTarget = renderSyntheticFixture(preset.fixture, fixtureViewport);
    }
    applySyntheticViewport(fixtureViewport, preset.viewport);
    applyTweakValues(tweakTarget, preset);
    elements.fixtureSelect.value = preset.fixture;
    elements.viewportSelect.value = `${preset.viewport.width}x${preset.viewport.height}`;
    activeRenderer?.update(preset.values);
  }

  function mountRenderer(name, { focus = false } = {}) {
    if (!rendererFactories[name]) throw new Error(`Renderer is unavailable: ${name}`);
    activeRenderer?.dispose();
    activeRenderer = null;
    try {
      activeRenderer = rendererFactories[name]({
        container: elements.rendererHost,
        schema: TWEAK_SCHEMA,
        values: store.snapshot().values,
        onChange(key, value) {
          try {
            store.setValue(key, value);
            setStatus(`${TWEAK_SCHEMA.byKey[key].label} updated in memory.`);
          } catch (error) {
            setStatus(error.message, { error: true, focus: true });
          }
        },
      });
      activeRendererName = name;
      for (const input of elements.rendererInputs) input.checked = input.value === name;
      if (focus) activeRenderer.focusFirst();
    } catch (error) {
      elements.rendererHost.replaceChildren();
      throw error;
    }
  }

  function openPanel({ focus = true } = {}) {
    if (!elements.panel.hidden) return;
    previousFocus = document.activeElement instanceof HTMLElement ? document.activeElement : elements.toggle;
    elements.panel.hidden = false;
    elements.toggle.setAttribute('aria-expanded', 'true');
    if (focus) elements.close.focus();
  }

  function closePanel({ returnFocus = true } = {}) {
    if (elements.panel.hidden) return;
    elements.panel.hidden = true;
    elements.toggle.setAttribute('aria-expanded', 'false');
    if (returnFocus) {
      const destination = previousFocus?.isConnected ? previousFocus : elements.toggle;
      destination.focus();
    }
  }

  async function copyPreset() {
    const text = store.exportPreset();
    await writeClipboard(document, text);
    lastCopiedText = text;
    setStatus('Canonical preset copied.');
  }

  async function copyPatch() {
    const text = store.tokenPatchSuggestion();
    await writeClipboard(document, text);
    lastCopiedText = text;
    setStatus('Deterministic token suggestion copied. Source was not changed.');
  }

  function exportPreset() {
    const text = store.exportPreset();
    const blob = new Blob([text], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const anchor = createElement(document, 'a', {
      attributes: {
        href: url,
        download: `firstmate-${store.snapshot().fixture}-preset-v${PRESET_SCHEMA_VERSION}.json`,
      },
    });
    document.body.append(anchor);
    anchor.click();
    anchor.remove();
    URL.revokeObjectURL(url);
    lastExportedText = text;
    setStatus('Canonical preset exported as a local JSON download.');
  }

  function importPreset() {
    try {
      store.importPresetText(elements.importInput.value);
      setStatus('Preset validated completely and imported atomically.');
    } catch (error) {
      const message = error instanceof TweakValidationError ? error.message : `Import failed: ${error.message}`;
      setStatus(message, { error: true, focus: true });
    }
  }

  function handleClick(event) {
    const action = event.target.closest?.('[data-tweaks-action]')?.dataset.tweaksAction;
    if (!action) return;
    if (action === 'toggle') {
      if (elements.panel.hidden) openPanel();
      else closePanel();
    } else if (action === 'close') closePanel();
    else if (action === 'reset') {
      store.reset();
      setStatus('Current fixture reset to its authored defaults.');
    } else if (action === 'copy') {
      void copyPreset().catch((error) => setStatus(`Copy failed: ${error.message}`, { error: true, focus: true }));
    } else if (action === 'copy-patch') {
      void copyPatch().catch((error) => setStatus(`Copy failed: ${error.message}`, { error: true, focus: true }));
    } else if (action === 'export') exportPreset();
    else if (action === 'import') importPreset();
  }

  function handleChange(event) {
    if (event.target === elements.fixtureSelect) {
      store.setFixture(elements.fixtureSelect.value);
      setStatus('Fixture changed. Its independent in-memory values were restored.');
    } else if (event.target === elements.viewportSelect) {
      store.setViewport(viewportFromOption(elements.viewportSelect.value));
      setStatus('Exact synthetic viewport changed.');
    } else if (event.target.name === 'fm-tweaks-renderer') {
      try {
        mountRenderer(event.target.value);
        setStatus(`${event.target.value === 'native' ? 'Native' : 'Tweakpane 4.0.5'} renderer active.`);
      } catch (error) {
        mountRenderer('native');
        setStatus(`Renderer failed and was cleaned up: ${error.message}`, { error: true, focus: true });
      }
    }
  }

  function handleKeydown(event) {
    const shortcut = event.altKey && event.shiftKey && !event.ctrlKey && !event.metaKey && event.key.toLowerCase() === 't';
    if (shortcut) {
      event.preventDefault();
      if (elements.panel.hidden) openPanel();
      else closePanel();
      return;
    }
    if (event.key === 'Escape' && !elements.panel.hidden) {
      event.preventDefault();
      closePanel();
    }
  }

  function diagnostics() {
    return {
      activeRenderer: activeRendererName,
      eventListenerCount: eventScope.count(),
      renderer: activeRenderer?.diagnostics() || null,
      store: store.diagnostics(),
      panelCount: document.querySelectorAll('#fm-tweaks-panel').length,
      launcherCount: document.querySelectorAll('.fm-tweaks-launcher').length,
      panelOpen: !elements.panel.hidden,
      mountElapsedMs,
      mountBudgetMs: DEVELOPMENT_MOUNT_BUDGET_MS,
      withinMountBudget: mountElapsedMs !== null && mountElapsedMs <= DEVELOPMENT_MOUNT_BUDGET_MS,
      lastCopiedText,
      lastExportedText,
      lastError,
      persistenceNamespace: RESERVED_PERSISTENCE_NAMESPACE,
      persistenceEnabled: false,
    };
  }

  function unmount() {
    if (unmounted) return;
    unmounted = true;
    activeRenderer?.dispose();
    activeRenderer = null;
    unsubscribe();
    eventScope.dispose();
    store.dispose();
    elements.panel.remove();
    elements.launcher.remove();
    if (globalThis[GLOBAL_SLOT] === controller) delete globalThis[GLOBAL_SLOT];
    if (globalThis[TEST_SLOT] === testApi) delete globalThis[TEST_SLOT];
  }

  const controller = { unmount, diagnostics };
  const testApi = {
    diagnostics,
    exportPreset: () => store.exportPreset(),
    importPreset(text) {
      elements.importInput.value = text;
      importPreset();
      return diagnostics();
    },
    setRenderer(name) {
      const input = elements.rendererInputs.find((candidate) => candidate.value === name);
      if (!input) throw new Error(`Unknown renderer: ${name}`);
      input.click();
      return diagnostics();
    },
    async remount() {
      unmount();
      const next = internalMount({ appShell, fixtureViewport, mountStartedAt: performance.now() });
      return next.diagnostics();
    },
    async simulateMountError() {
      unmount();
      let message = null;
      try {
        internalMount({
          appShell,
          fixtureViewport,
          mountStartedAt: performance.now(),
          rendererFactories: {
            native() {
              throw new Error('synthetic renderer failure');
            },
            tweakpane: mountTweakpaneRenderer,
          },
        });
      } catch (error) {
        message = error.message;
      }
      const afterError = {
        panelCount: document.querySelectorAll('#fm-tweaks-panel').length,
        launcherCount: document.querySelectorAll('.fm-tweaks-launcher').length,
      };
      const next = internalMount({ appShell, fixtureViewport, mountStartedAt: performance.now() });
      return { message, afterError, afterRecovery: next.diagnostics() };
    },
  };

  try {
    appShell.append(elements.launcher, elements.panel);
    eventScope.listen(appShell, 'click', handleClick);
    eventScope.listen(appShell, 'change', handleChange);
    eventScope.listen(document, 'keydown', handleKeydown);
    unsubscribe = store.subscribe(updateFixture);
    mountRenderer('native');
    updateFixture(store.snapshot(), 'import');
    mountElapsedMs = performance.now() - mountStartedAt;
    if (mountElapsedMs > DEVELOPMENT_MOUNT_BUDGET_MS) {
      setStatus(`Development mount exceeded its ${DEVELOPMENT_MOUNT_BUDGET_MS} ms budget.`, { error: true });
    }
    globalThis[GLOBAL_SLOT] = controller;
    globalThis[TEST_SLOT] = testApi;
    return controller;
  } catch (error) {
    unmount();
    throw error;
  }
}

export function mountDevelopmentProof(options) {
  return internalMount(options);
}

export function unmountDevelopmentProof() {
  globalThis[GLOBAL_SLOT]?.unmount();
}

if (import.meta.hot) {
  import.meta.hot.dispose(() => unmountDevelopmentProof());
}
