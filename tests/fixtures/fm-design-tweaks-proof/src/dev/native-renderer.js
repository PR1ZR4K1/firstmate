function controlId(key) {
  return `fm-native-${key}`;
}

function displayValue(entry, value) {
  if (entry.kind === 'number') return `${value}${entry.unit}`;
  if (entry.kind === 'boolean') return value ? 'On' : 'Off';
  if (entry.kind === 'select') return entry.options.find((option) => option.value === value)?.label || value;
  return value;
}

export function mountNativeRenderer({ container, schema, values, onChange }) {
  if (!container || typeof container.replaceChildren !== 'function') throw new TypeError('Native renderer container is required.');
  const { ownerDocument: document } = container;
  const root = document.createElement('fieldset');
  root.className = 'fm-tweaks-controls fm-tweaks-controls--native';
  root.dataset.renderer = 'native';
  const legend = document.createElement('legend');
  legend.textContent = 'Native semantic controls';
  root.append(legend);

  const controls = new Map();
  const outputs = new Map();
  const disposers = [];

  for (const entry of schema.entries) {
    const row = document.createElement('div');
    row.className = 'fm-tweaks-control';
    row.dataset.tweakKey = entry.key;
    const id = controlId(entry.key);
    const label = document.createElement('label');
    label.htmlFor = id;
    label.textContent = entry.label;
    row.append(label);

    let control;
    if (entry.kind === 'select') {
      control = document.createElement('select');
      for (const option of entry.options) {
        const optionElement = document.createElement('option');
        optionElement.value = option.value;
        optionElement.textContent = option.label;
        control.append(optionElement);
      }
    } else {
      control = document.createElement('input');
      control.type = entry.kind === 'boolean' ? 'checkbox' : entry.kind;
      if (entry.kind === 'number') {
        control.min = String(entry.min);
        control.max = String(entry.max);
        control.step = String(entry.step);
        control.inputMode = 'decimal';
      }
    }
    control.id = id;
    control.name = entry.key;
    control.dataset.controlKind = entry.kind;

    const output = document.createElement('output');
    output.className = 'fm-tweaks-control__value';
    output.htmlFor = id;
    output.id = `${id}-value`;
    control.setAttribute('aria-describedby', output.id);

    const listener = () => {
      let next;
      if (entry.kind === 'boolean') next = control.checked;
      else if (entry.kind === 'number') next = control.valueAsNumber;
      else next = control.value;
      onChange(entry.key, next);
    };
    control.addEventListener('change', listener);
    disposers.push(() => control.removeEventListener('change', listener));
    row.append(control, output);
    root.append(row);
    controls.set(entry.key, control);
    outputs.set(entry.key, output);
  }

  function update(nextValues) {
    for (const entry of schema.entries) {
      const control = controls.get(entry.key);
      const value = nextValues[entry.key];
      if (entry.kind === 'boolean') control.checked = value;
      else control.value = String(value);
      outputs.get(entry.key).value = displayValue(entry, value);
      if (entry.kind === 'number') control.setAttribute('aria-valuetext', displayValue(entry, value));
    }
  }

  function focusFirst() {
    controls.values().next().value?.focus();
  }

  function dispose() {
    for (const remove of disposers.splice(0)) remove();
    root.remove();
    controls.clear();
    outputs.clear();
  }

  container.replaceChildren(root);
  update(values);
  return {
    name: 'native',
    element: root,
    update,
    focusFirst,
    dispose,
    diagnostics: () => ({ listenerCount: disposers.length, controlCount: controls.size }),
  };
}
