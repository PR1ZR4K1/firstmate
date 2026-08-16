export const PRESET_SCHEMA_VERSION = 1;
export const PRESET_SCHEMA_ID = 'firstmate.design-tweaks-preset/v1';
export const RESERVED_PERSISTENCE_NAMESPACE = 'fm-design-tweaks-proof:v1:';

const UNSAFE_KEYS = new Set(['__proto__', 'constructor', 'prototype']);
const ALLOWED_ENTRY_KEYS = new Set([
  'key',
  'kind',
  'label',
  'target',
  'defaultValue',
  'min',
  'max',
  'step',
  'unit',
  'options',
]);
const ALLOWED_TARGET_KEYS = new Set(['type', 'name']);
const ALLOWED_OPTION_KEYS = new Set(['label', 'value', 'cssValue']);
const ALLOWED_PRESET_KEYS = new Set(['schemaVersion', 'fixture', 'viewport', 'values']);
const ALLOWED_VIEWPORT_KEYS = new Set(['width', 'height']);
const SAFE_UNITS = new Set(['px', 'rem', '%']);
const SAFE_CSS_LITERAL = /^(?!.*(?:url\s*\(|expression\s*\(|javascript\s*:|[{};]))[-#(),.%\sa-zA-Z0-9]+$/;
const HEX_COLOR = /^#[0-9a-fA-F]{6}$/;
const ENTRY_KEY = /^[a-z][A-Za-z0-9]{0,63}$/;
const CSS_CUSTOM_PROPERTY = /^--[a-z][a-z0-9-]*$/;
const DATA_ATTRIBUTE = /^data-[a-z][a-z0-9-]*$/;

export class TweakValidationError extends Error {
  constructor(message, { code = 'invalid', path = '$' } = {}) {
    super(`${path}: ${message}`);
    this.name = 'TweakValidationError';
    this.code = code;
    this.path = path;
  }
}

function fail(message, code, path) {
  throw new TweakValidationError(message, { code, path });
}

function isRecord(value) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function assertRecord(value, path) {
  if (!isRecord(value)) fail('must be an object.', 'type', path);
}

function assertSafeKey(key, path) {
  if (UNSAFE_KEYS.has(key)) {
    fail(`unsafe object key "${key}" is not allowed.`, 'unsafe-key', path);
  }
}

function assertExactKeys(value, allowed, path) {
  for (const key of Object.keys(value)) {
    assertSafeKey(key, `${path}.${key}`);
    if (!allowed.has(key)) fail(`unknown key "${key}".`, 'unknown-key', `${path}.${key}`);
  }
}

function assertRequiredKeys(value, required, path) {
  for (const key of required) {
    if (!Object.hasOwn(value, key)) fail(`missing required key "${key}".`, 'missing-key', path);
  }
}

function cloneRecord(value) {
  const output = Object.create(null);
  for (const [key, child] of Object.entries(value)) output[key] = child;
  return output;
}

function deepFreeze(value) {
  if (value && typeof value === 'object' && !Object.isFrozen(value)) {
    Object.freeze(value);
    for (const child of Object.values(value)) deepFreeze(child);
  }
  return value;
}

function canonicalNumber(value) {
  return Object.is(value, -0) ? 0 : value;
}

function formatNumber(value) {
  const normalized = canonicalNumber(value);
  return Number.isInteger(normalized) ? String(normalized) : String(normalized);
}

function normalizeColor(value, path) {
  if (typeof value !== 'string' || !HEX_COLOR.test(value)) {
    fail('must be a six-digit hexadecimal color such as #2f6fed.', 'malformed-color', path);
  }
  return value.toLowerCase();
}

function validateTypedValue(entry, value, path) {
  switch (entry.kind) {
    case 'number': {
      if (typeof value !== 'number' || !Number.isFinite(value)) {
        fail('must be a finite number; NaN and Infinity are not allowed.', 'non-finite-number', path);
      }
      if (value < entry.min || value > entry.max) {
        fail(`must be between ${entry.min} and ${entry.max}.`, 'out-of-range', path);
      }
      const steps = (value - entry.min) / entry.step;
      if (Math.abs(steps - Math.round(steps)) > 1e-9) {
        fail(`must align to step ${entry.step} from ${entry.min}.`, 'step-mismatch', path);
      }
      return canonicalNumber(value);
    }
    case 'color':
      return normalizeColor(value, path);
    case 'select': {
      if (typeof value !== 'string' || !entry.options.some((option) => option.value === value)) {
        fail(`must be one of: ${entry.options.map((option) => option.value).join(', ')}.`, 'invalid-option', path);
      }
      return value;
    }
    case 'boolean':
      if (typeof value !== 'boolean') fail('must be true or false.', 'type', path);
      return value;
    default:
      fail(`unsupported control kind "${entry.kind}".`, 'unsupported-kind', path);
  }
}

function validateTarget(target, kind, path) {
  assertRecord(target, path);
  assertExactKeys(target, ALLOWED_TARGET_KEYS, path);
  assertRequiredKeys(target, ALLOWED_TARGET_KEYS, path);
  if (target.type === 'css-custom-property') {
    if (!CSS_CUSTOM_PROPERTY.test(target.name)) {
      fail('CSS targets must be custom properties beginning with --.', 'unsafe-target', `${path}.name`);
    }
    if (kind === 'boolean') {
      fail('boolean controls must target a declared data-* attribute.', 'target-kind', path);
    }
  } else if (target.type === 'data-attribute') {
    if (!DATA_ATTRIBUTE.test(target.name)) {
      fail('attribute targets must be data-* names.', 'unsafe-target', `${path}.name`);
    }
    if (kind !== 'boolean') {
      fail('only boolean controls may target a declared data-* attribute.', 'target-kind', path);
    }
  } else {
    fail('target type must be css-custom-property or data-attribute.', 'unsafe-target', `${path}.type`);
  }
  return Object.freeze({ type: target.type, name: target.name });
}

function validateSchemaEntry(raw, index) {
  const path = `$.entries[${index}]`;
  assertRecord(raw, path);
  assertExactKeys(raw, ALLOWED_ENTRY_KEYS, path);
  assertRequiredKeys(raw, new Set(['key', 'kind', 'label', 'target', 'defaultValue']), path);
  if (typeof raw.key !== 'string' || !ENTRY_KEY.test(raw.key) || UNSAFE_KEYS.has(raw.key)) {
    fail('key must be a safe lower-camel identifier.', 'unsafe-key', `${path}.key`);
  }
  if (typeof raw.label !== 'string' || raw.label.trim().length === 0 || raw.label.length > 80) {
    fail('label must be a non-empty string of at most 80 characters.', 'label', `${path}.label`);
  }
  if (!['number', 'color', 'select', 'boolean'].includes(raw.kind)) {
    fail('kind must be number, color, select, or boolean.', 'unsupported-kind', `${path}.kind`);
  }
  const target = validateTarget(raw.target, raw.kind, `${path}.target`);
  const entry = {
    key: raw.key,
    kind: raw.kind,
    label: raw.label,
    target,
  };
  if (raw.kind === 'number') {
    assertRequiredKeys(raw, new Set(['min', 'max', 'step', 'unit']), path);
    for (const key of ['min', 'max', 'step']) {
      if (typeof raw[key] !== 'number' || !Number.isFinite(raw[key])) {
        fail(`${key} must be finite.`, 'non-finite-number', `${path}.${key}`);
      }
    }
    if (raw.max <= raw.min || raw.step <= 0) fail('number bounds and step are inconsistent.', 'bounds', path);
    if (!SAFE_UNITS.has(raw.unit)) fail('unit is not in the bounded unit allowlist.', 'unsafe-value', `${path}.unit`);
    Object.assign(entry, { min: raw.min, max: raw.max, step: raw.step, unit: raw.unit });
  } else if (raw.kind === 'select') {
    if (!Array.isArray(raw.options) || raw.options.length < 2 || raw.options.length > 12) {
      fail('select options must contain between two and twelve entries.', 'options', `${path}.options`);
    }
    const values = new Set();
    entry.options = raw.options.map((option, optionIndex) => {
      const optionPath = `${path}.options[${optionIndex}]`;
      assertRecord(option, optionPath);
      assertExactKeys(option, ALLOWED_OPTION_KEYS, optionPath);
      assertRequiredKeys(option, ALLOWED_OPTION_KEYS, optionPath);
      if (typeof option.label !== 'string' || !option.label.trim()) fail('option label is required.', 'label', `${optionPath}.label`);
      if (typeof option.value !== 'string' || !ENTRY_KEY.test(option.value) || UNSAFE_KEYS.has(option.value)) {
        fail('option value must be a safe identifier.', 'unsafe-value', `${optionPath}.value`);
      }
      if (values.has(option.value)) fail(`duplicate option "${option.value}".`, 'duplicate-key', `${optionPath}.value`);
      values.add(option.value);
      if (typeof option.cssValue !== 'string' || !SAFE_CSS_LITERAL.test(option.cssValue)) {
        fail('option CSS value contains a forbidden construct.', 'unsafe-value', `${optionPath}.cssValue`);
      }
      return Object.freeze({ label: option.label, value: option.value, cssValue: option.cssValue });
    });
  }
  entry.defaultValue = validateTypedValue(entry, raw.defaultValue, `${path}.defaultValue`);
  return deepFreeze(entry);
}

export function defineTweakSchema(rawEntries) {
  if (!Array.isArray(rawEntries) || rawEntries.length === 0) {
    fail('schema entries must be a non-empty array.', 'schema', '$.entries');
  }
  const keys = new Set();
  const targets = new Set();
  const entries = rawEntries.map((entry, index) => {
    const normalized = validateSchemaEntry(entry, index);
    if (keys.has(normalized.key)) fail(`duplicate tweak key "${normalized.key}".`, 'duplicate-key', `$.entries[${index}].key`);
    if (targets.has(normalized.target.name)) fail(`duplicate target "${normalized.target.name}".`, 'duplicate-target', `$.entries[${index}].target.name`);
    keys.add(normalized.key);
    targets.add(normalized.target.name);
    return normalized;
  });
  const byKey = Object.create(null);
  for (const entry of entries) byKey[entry.key] = entry;
  return deepFreeze({ entries, byKey });
}

export const TWEAK_SCHEMA = defineTweakSchema([
  {
    key: 'cornerRadius',
    kind: 'number',
    label: 'Corner radius',
    target: { type: 'css-custom-property', name: '--proof-corner-radius' },
    min: 0,
    max: 32,
    step: 1,
    unit: 'px',
    defaultValue: 18,
  },
  {
    key: 'accentColor',
    kind: 'color',
    label: 'Accent color',
    target: { type: 'css-custom-property', name: '--proof-accent-color' },
    defaultValue: '#c65a3a',
  },
  {
    key: 'contentDensity',
    kind: 'select',
    label: 'Content density',
    target: { type: 'css-custom-property', name: '--proof-content-gap' },
    options: [
      { label: 'Compact', value: 'compact', cssValue: '0.75rem' },
      { label: 'Comfortable', value: 'comfortable', cssValue: '1.25rem' },
      { label: 'Roomy', value: 'roomy', cssValue: '1.75rem' },
    ],
    defaultValue: 'comfortable',
  },
  {
    key: 'emphasized',
    kind: 'boolean',
    label: 'Emphasize summary',
    target: { type: 'data-attribute', name: 'data-proof-emphasized' },
    defaultValue: false,
  },
]);

export const FIXTURES = deepFreeze([
  {
    id: 'dispatch-card',
    label: 'Dispatch summary',
    sensitive: false,
    defaults: {
      cornerRadius: 18,
      accentColor: '#c65a3a',
      contentDensity: 'comfortable',
      emphasized: false,
    },
  },
  {
    id: 'localization-card',
    label: 'Localization stress card',
    sensitive: true,
    defaults: {
      cornerRadius: 10,
      accentColor: '#2f6f68',
      contentDensity: 'roomy',
      emphasized: false,
    },
  },
]);

export const VIEWPORT_PRESETS = deepFreeze([
  { width: 320, height: 568, label: '320 × 568' },
  { width: 375, height: 667, label: '375 × 667' },
  { width: 768, height: 1024, label: '768 × 1024' },
  { width: 1024, height: 768, label: '1024 × 768' },
  { width: 1440, height: 900, label: '1440 × 900' },
]);

function fixtureById(fixtures, id, path = '$.fixture') {
  const fixture = fixtures.find((candidate) => candidate.id === id);
  if (!fixture) fail(`unknown fixture "${id}".`, 'unknown-fixture', path);
  return fixture;
}

function normalizeViewport(raw, path = '$.viewport') {
  assertRecord(raw, path);
  assertExactKeys(raw, ALLOWED_VIEWPORT_KEYS, path);
  assertRequiredKeys(raw, ALLOWED_VIEWPORT_KEYS, path);
  if (!Number.isInteger(raw.width) || !Number.isInteger(raw.height)) {
    fail('width and height must be integers.', 'viewport', path);
  }
  const preset = VIEWPORT_PRESETS.find((candidate) => candidate.width === raw.width && candidate.height === raw.height);
  if (!preset) {
    fail('viewport must match a supported fixed width and height.', 'unsupported-viewport', path);
  }
  return { width: preset.width, height: preset.height };
}

export function normalizeValues(schema, rawValues, { path = '$.values' } = {}) {
  assertRecord(rawValues, path);
  const expectedKeys = new Set(schema.entries.map((entry) => entry.key));
  for (const key of Object.keys(rawValues)) {
    assertSafeKey(key, `${path}.${key}`);
    if (!expectedKeys.has(key)) fail(`unknown tweak key "${key}".`, 'unknown-key', `${path}.${key}`);
  }
  for (const key of expectedKeys) {
    if (!Object.hasOwn(rawValues, key)) fail(`missing tweak key "${key}".`, 'missing-key', path);
  }
  const values = Object.create(null);
  for (const entry of schema.entries) {
    values[entry.key] = validateTypedValue(entry, rawValues[entry.key], `${path}.${entry.key}`);
  }
  return values;
}

export function normalizePreset(raw, { schema = TWEAK_SCHEMA, fixtures = FIXTURES } = {}) {
  assertRecord(raw, '$');
  assertExactKeys(raw, ALLOWED_PRESET_KEYS, '$');
  assertRequiredKeys(raw, ALLOWED_PRESET_KEYS, '$');
  if (raw.schemaVersion !== PRESET_SCHEMA_VERSION) {
    fail(`unsupported schema version "${String(raw.schemaVersion)}".`, 'unknown-version', '$.schemaVersion');
  }
  if (typeof raw.fixture !== 'string') fail('fixture must be a string.', 'type', '$.fixture');
  fixtureById(fixtures, raw.fixture);
  const values = normalizeValues(schema, raw.values);
  const viewport = normalizeViewport(raw.viewport);
  return {
    schemaVersion: PRESET_SCHEMA_VERSION,
    fixture: raw.fixture,
    viewport,
    values,
  };
}

class StrictJsonParser {
  constructor(text) {
    this.text = text;
    this.index = 0;
  }

  parse() {
    this.skipWhitespace();
    if (this.index >= this.text.length) fail('import is empty.', 'json', '$');
    const value = this.parseValue('$');
    this.skipWhitespace();
    if (this.index !== this.text.length) fail('import must contain exactly one JSON document.', 'json', '$');
    return value;
  }

  current() {
    return this.text[this.index];
  }

  skipWhitespace() {
    while (/\s/.test(this.current() || '')) this.index += 1;
  }

  parseValue(path) {
    this.skipWhitespace();
    const token = this.current();
    if (token === '{') return this.parseObject(path);
    if (token === '[') return this.parseArray(path);
    if (token === '"') return this.parseString(path);
    if (token === 't') return this.parseLiteral('true', true, path);
    if (token === 'f') return this.parseLiteral('false', false, path);
    if (token === 'n') return this.parseLiteral('null', null, path);
    if (token === 'N' || token === 'I' || (token === '-' && this.text[this.index + 1] === 'I')) {
      fail('numbers must be finite JSON numbers; NaN and Infinity are not allowed.', 'non-finite-number', path);
    }
    if (token === '-' || /[0-9]/.test(token || '')) return this.parseNumber(path);
    fail(`invalid JSON token near character ${this.index + 1}.`, 'json', path);
  }

  parseObject(path) {
    const value = Object.create(null);
    const keys = new Set();
    this.index += 1;
    this.skipWhitespace();
    if (this.current() === '}') {
      this.index += 1;
      return value;
    }
    while (this.index < this.text.length) {
      if (this.current() !== '"') fail('object keys must be quoted strings.', 'json', path);
      const key = this.parseString(path);
      const keyPath = `${path}.${key}`;
      assertSafeKey(key, keyPath);
      if (keys.has(key)) fail(`duplicate key "${key}".`, 'duplicate-key', keyPath);
      keys.add(key);
      this.skipWhitespace();
      if (this.current() !== ':') fail('expected a colon after the object key.', 'json', keyPath);
      this.index += 1;
      value[key] = this.parseValue(keyPath);
      this.skipWhitespace();
      if (this.current() === '}') {
        this.index += 1;
        return value;
      }
      if (this.current() !== ',') fail('expected a comma between object entries.', 'json', path);
      this.index += 1;
      this.skipWhitespace();
    }
    fail('unterminated object.', 'json', path);
  }

  parseArray(path) {
    const value = [];
    this.index += 1;
    this.skipWhitespace();
    if (this.current() === ']') {
      this.index += 1;
      return value;
    }
    while (this.index < this.text.length) {
      value.push(this.parseValue(`${path}[${value.length}]`));
      this.skipWhitespace();
      if (this.current() === ']') {
        this.index += 1;
        return value;
      }
      if (this.current() !== ',') fail('expected a comma between array entries.', 'json', path);
      this.index += 1;
      this.skipWhitespace();
    }
    fail('unterminated array.', 'json', path);
  }

  parseString(path) {
    const start = this.index;
    this.index += 1;
    let escaped = false;
    while (this.index < this.text.length) {
      const character = this.text[this.index];
      if (!escaped && character === '"') {
        this.index += 1;
        try {
          return JSON.parse(this.text.slice(start, this.index));
        } catch {
          fail('invalid JSON string.', 'json', path);
        }
      }
      if (!escaped && character.charCodeAt(0) < 0x20) fail('unescaped control character in string.', 'json', path);
      if (!escaped && character === '\\') escaped = true;
      else escaped = false;
      this.index += 1;
    }
    fail('unterminated string.', 'json', path);
  }

  parseLiteral(literal, value, path) {
    if (this.text.slice(this.index, this.index + literal.length) !== literal) {
      fail(`invalid JSON literal near character ${this.index + 1}.`, 'json', path);
    }
    this.index += literal.length;
    return value;
  }

  parseNumber(path) {
    const tail = this.text.slice(this.index);
    const match = /^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/.exec(tail);
    if (!match) fail('invalid JSON number.', 'json', path);
    this.index += match[0].length;
    const value = Number(match[0]);
    if (!Number.isFinite(value)) {
      fail('numbers must be finite; overflow, NaN, and Infinity are not allowed.', 'non-finite-number', path);
    }
    return canonicalNumber(value);
  }
}

export function parsePreset(text, options) {
  if (typeof text !== 'string') fail('import must be text.', 'type', '$');
  const raw = new StrictJsonParser(text).parse();
  return normalizePreset(raw, options);
}

function canonicalize(value) {
  if (value === null) return 'null';
  if (typeof value === 'boolean') return value ? 'true' : 'false';
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) fail('cannot serialize a non-finite number.', 'non-finite-number', '$');
    return JSON.stringify(canonicalNumber(value));
  }
  if (typeof value === 'string') return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map((child) => canonicalize(child)).join(',')}]`;
  if (isRecord(value)) {
    const keys = Object.keys(value).sort();
    return `{${keys.map((key) => `${JSON.stringify(key)}:${canonicalize(value[key])}`).join(',')}}`;
  }
  fail('value is not representable in canonical JSON.', 'type', '$');
}

export function serializePreset(preset, options) {
  return `${canonicalize(normalizePreset(preset, options))}\n`;
}

export function createTokenPatchSuggestion(preset, { schema = TWEAK_SCHEMA, fixtures = FIXTURES } = {}) {
  const normalized = normalizePreset(preset, { schema, fixtures });
  const cssCustomProperties = Object.create(null);
  const dataAttributes = Object.create(null);
  for (const entry of schema.entries) {
    const value = normalized.values[entry.key];
    if (entry.target.type === 'css-custom-property') {
      if (entry.kind === 'number') cssCustomProperties[entry.target.name] = `${formatNumber(value)}${entry.unit}`;
      else if (entry.kind === 'select') cssCustomProperties[entry.target.name] = entry.options.find((option) => option.value === value).cssValue;
      else cssCustomProperties[entry.target.name] = value;
    } else {
      dataAttributes[entry.target.name] = value;
    }
  }
  const suggestion = {
    schemaVersion: PRESET_SCHEMA_VERSION,
    fixture: normalized.fixture,
    viewport: normalized.viewport,
    cssCustomProperties,
    dataAttributes,
    reviewRequired: true,
  };
  return `${canonicalize(suggestion)}\n`;
}

function validateFixtureDefinitions(schema, fixtures) {
  if (!Array.isArray(fixtures) || fixtures.length === 0) fail('fixtures must be a non-empty array.', 'fixture', '$.fixtures');
  const ids = new Set();
  for (const fixture of fixtures) {
    assertRecord(fixture, '$.fixtures[]');
    assertSafeKey(fixture.id, `$.fixtures.${fixture.id}`);
    if (ids.has(fixture.id)) fail(`duplicate fixture "${fixture.id}".`, 'duplicate-key', '$.fixtures');
    ids.add(fixture.id);
    normalizeValues(schema, fixture.defaults, { path: `$.fixtures.${fixture.id}.defaults` });
  }
}

export function createTweakStore({
  schema = TWEAK_SCHEMA,
  fixtures = FIXTURES,
  initialFixture = fixtures[0].id,
  initialViewport = { width: VIEWPORT_PRESETS[3].width, height: VIEWPORT_PRESETS[3].height },
} = {}) {
  validateFixtureDefinitions(schema, fixtures);
  fixtureById(fixtures, initialFixture);
  let fixture = initialFixture;
  let viewport = normalizeViewport(initialViewport);
  let disposed = false;
  const valuesByFixture = new Map();
  const listeners = new Set();
  for (const definition of fixtures) {
    valuesByFixture.set(definition.id, normalizeValues(schema, definition.defaults, { path: `$.fixtures.${definition.id}.defaults` }));
  }

  function assertActive() {
    if (disposed) fail('store has been disposed.', 'disposed', '$');
  }

  function currentValues() {
    return valuesByFixture.get(fixture);
  }

  function snapshot() {
    assertActive();
    return normalizePreset({
      schemaVersion: PRESET_SCHEMA_VERSION,
      fixture,
      viewport,
      values: cloneRecord(currentValues()),
    }, { schema, fixtures });
  }

  function emit(reason) {
    const next = snapshot();
    for (const listener of [...listeners]) listener(next, reason);
  }

  function setValue(key, value) {
    assertActive();
    const entry = schema.byKey[key];
    if (!entry) fail(`unknown tweak key "${key}".`, 'unknown-key', `$.values.${key}`);
    const next = cloneRecord(currentValues());
    next[key] = validateTypedValue(entry, value, `$.values.${key}`);
    valuesByFixture.set(fixture, next);
    emit('value');
  }

  function setFixture(nextFixture) {
    assertActive();
    fixtureById(fixtures, nextFixture);
    if (nextFixture === fixture) return;
    fixture = nextFixture;
    emit('fixture');
  }

  function setViewport(nextViewport) {
    assertActive();
    const normalized = normalizeViewport(nextViewport);
    if (normalized.width === viewport.width && normalized.height === viewport.height) return;
    viewport = normalized;
    emit('viewport');
  }

  function reset() {
    assertActive();
    const definition = fixtureById(fixtures, fixture);
    valuesByFixture.set(fixture, normalizeValues(schema, definition.defaults, { path: `$.fixtures.${fixture}.defaults` }));
    emit('reset');
  }

  function importPresetText(text) {
    assertActive();
    const normalized = parsePreset(text, { schema, fixtures });
    valuesByFixture.set(normalized.fixture, cloneRecord(normalized.values));
    fixture = normalized.fixture;
    viewport = normalizeViewport(normalized.viewport);
    emit('import');
    return snapshot();
  }

  function exportPreset() {
    return serializePreset(snapshot(), { schema, fixtures });
  }

  function tokenPatchSuggestion() {
    return createTokenPatchSuggestion(snapshot(), { schema, fixtures });
  }

  function subscribe(listener) {
    assertActive();
    if (typeof listener !== 'function') fail('listener must be a function.', 'type', '$.listener');
    listeners.add(listener);
    return () => listeners.delete(listener);
  }

  function diagnostics() {
    return {
      disposed,
      fixtureCount: valuesByFixture.size,
      listenerCount: listeners.size,
      persistence: 'disabled',
    };
  }

  function dispose() {
    if (disposed) return;
    listeners.clear();
    valuesByFixture.clear();
    disposed = true;
  }

  return {
    schema,
    fixtures,
    snapshot,
    setValue,
    setFixture,
    setViewport,
    reset,
    importPresetText,
    exportPreset,
    tokenPatchSuggestion,
    subscribe,
    diagnostics,
    dispose,
  };
}

function assertTargetSurface(target) {
  if (!target || !target.style || typeof target.style.setProperty !== 'function' || typeof target.style.removeProperty !== 'function') {
    fail('target must expose a CSS style declaration.', 'target', '$.target');
  }
  if (typeof target.setAttribute !== 'function' || typeof target.removeAttribute !== 'function') {
    fail('target must expose attribute mutation methods.', 'target', '$.target');
  }
}

export function applyTweakValues(target, preset, {
  schema = TWEAK_SCHEMA,
  fixtures = FIXTURES,
} = {}) {
  assertTargetSurface(target);
  const normalized = normalizePreset(preset, { schema, fixtures });
  const defaults = fixtureById(fixtures, normalized.fixture).defaults;
  for (const entry of schema.entries) {
    if (entry.target.type === 'css-custom-property') target.style.removeProperty(entry.target.name);
    else target.removeAttribute(entry.target.name);
  }
  for (const entry of schema.entries) {
    const value = normalized.values[entry.key];
    if (Object.is(value, defaults[entry.key])) continue;
    if (entry.target.type === 'data-attribute') {
      if (value) target.setAttribute(entry.target.name, 'true');
      continue;
    }
    let cssValue;
    if (entry.kind === 'number') cssValue = `${formatNumber(value)}${entry.unit}`;
    else if (entry.kind === 'select') cssValue = entry.options.find((option) => option.value === value).cssValue;
    else cssValue = value;
    target.style.setProperty(entry.target.name, cssValue);
  }
  return normalized;
}
