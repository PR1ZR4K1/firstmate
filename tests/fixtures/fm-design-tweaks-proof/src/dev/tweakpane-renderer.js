import { Pane } from 'tweakpane';

function bindingParameters(entry) {
  if (entry.kind === 'number') {
    return { label: entry.label, min: entry.min, max: entry.max, step: entry.step };
  }
  if (entry.kind === 'select') {
    const options = Object.create(null);
    for (const option of entry.options) options[option.label] = option.value;
    return { label: entry.label, options };
  }
  return { label: entry.label };
}

function decorateBinding(binding, entry) {
  const element = binding.element;
  element.dataset.tweakKey = entry.key;
  element.setAttribute('role', 'group');
  element.setAttribute('aria-label', entry.label);
  const interactive = [...element.querySelectorAll('input, button, select, [tabindex]')]
    .filter((candidate, index, all) => all.indexOf(candidate) === index);
  interactive.forEach((control, index) => {
    if (!control.getAttribute('aria-label') && !control.getAttribute('aria-labelledby')) {
      const suffix = interactive.length > 1 ? ` ${index + 1}` : '';
      control.setAttribute('aria-label', `${entry.label}${suffix}`);
    }
    control.dataset.tweakControl = entry.key;
  });
}

export function mountTweakpaneRenderer({ container, schema, values, onChange }) {
  if (!container || typeof container.replaceChildren !== 'function') throw new TypeError('Tweakpane renderer container is required.');
  const { ownerDocument: document } = container;
  const root = document.createElement('fieldset');
  root.className = 'fm-tweaks-controls fm-tweaks-controls--tweakpane';
  root.dataset.renderer = 'tweakpane';
  const legend = document.createElement('legend');
  legend.textContent = 'Tweakpane 4.0.5 controls';
  const host = document.createElement('div');
  host.className = 'fm-tweakpane-host';
  root.append(legend, host);
  container.replaceChildren(root);

  const model = Object.create(null);
  for (const entry of schema.entries) model[entry.key] = values[entry.key];
  const pane = new Pane({ container: host });
  const bindings = new Map();
  const handlers = new Map();
  let syncing = false;

  try {
    for (const entry of schema.entries) {
      const binding = pane.addBinding(model, entry.key, bindingParameters(entry));
      const handler = (event) => {
        if (!syncing) onChange(entry.key, event.value);
      };
      binding.on('change', handler);
      decorateBinding(binding, entry);
      bindings.set(entry.key, binding);
      handlers.set(entry.key, handler);
    }
  } catch (error) {
    pane.dispose();
    root.remove();
    throw error;
  }

  function update(nextValues) {
    syncing = true;
    try {
      for (const entry of schema.entries) {
        model[entry.key] = nextValues[entry.key];
        bindings.get(entry.key).refresh();
        decorateBinding(bindings.get(entry.key), entry);
      }
    } finally {
      syncing = false;
    }
  }

  function focusFirst() {
    root.querySelector('input:not([disabled]), button:not([disabled]), select:not([disabled]), [tabindex="0"]')?.focus();
  }

  function dispose() {
    for (const entry of schema.entries) {
      const binding = bindings.get(entry.key);
      const handler = handlers.get(entry.key);
      if (binding && handler) binding.off('change', handler);
    }
    bindings.clear();
    handlers.clear();
    pane.dispose();
    root.remove();
  }

  update(values);
  return {
    name: 'tweakpane',
    element: root,
    update,
    focusFirst,
    dispose,
    diagnostics: () => ({ listenerCount: handlers.size, controlCount: bindings.size }),
  };
}
