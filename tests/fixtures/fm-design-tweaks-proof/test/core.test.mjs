import test from 'node:test';
import assert from 'node:assert/strict';
import {
  FIXTURES,
  PRESET_SCHEMA_VERSION,
  TWEAK_SCHEMA,
  TweakValidationError,
  VIEWPORT_PRESETS,
  applyTweakValues,
  createTokenPatchSuggestion,
  createTweakStore,
  defineTweakSchema,
  parsePreset,
  serializePreset,
} from '../src/dev/core.js';

function canonicalPreset(overrides = {}) {
  return {
    schemaVersion: PRESET_SCHEMA_VERSION,
    fixture: 'dispatch-card',
    viewport: { width: 1024, height: 768 },
    values: {
      cornerRadius: 18,
      accentColor: '#c65a3a',
      contentDensity: 'comfortable',
      emphasized: false,
    },
    ...overrides,
  };
}

function importText(overrides = {}) {
  return JSON.stringify(canonicalPreset(overrides));
}

function fakeTarget() {
  const properties = new Map();
  const attributes = new Map();
  const calls = [];
  return {
    properties,
    attributes,
    calls,
    style: {
      setProperty(name, value) {
        calls.push(['set-property', name, value]);
        properties.set(name, value);
      },
      removeProperty(name) {
        calls.push(['remove-property', name]);
        properties.delete(name);
      },
    },
    setAttribute(name, value) {
      calls.push(['set-attribute', name, value]);
      attributes.set(name, value);
    },
    removeAttribute(name) {
      calls.push(['remove-attribute', name]);
      attributes.delete(name);
    },
  };
}

function assertValidation(fn, code) {
  assert.throws(fn, (error) => error instanceof TweakValidationError && error.code === code);
}

test('one bounded library-independent schema owns all four supported controls', () => {
  assert.deepEqual(TWEAK_SCHEMA.entries.map((entry) => entry.kind), ['number', 'color', 'select', 'boolean']);
  assert.deepEqual(TWEAK_SCHEMA.entries.map((entry) => entry.target.type), [
    'css-custom-property',
    'css-custom-property',
    'css-custom-property',
    'data-attribute',
  ]);
  assert.deepEqual(VIEWPORT_PRESETS.map((viewport) => viewport.width), [320, 375, 768, 1024, 1440]);
  assert.equal(FIXTURES.length, 2);
});

test('canonical presets round-trip to stable sorted-key bytes', () => {
  const text = serializePreset(canonicalPreset());
  assert.equal(text, '{"fixture":"dispatch-card","schemaVersion":1,"values":{"accentColor":"#c65a3a","contentDensity":"comfortable","cornerRadius":18,"emphasized":false},"viewport":{"height":768,"width":1024}}\n');
  assert.equal(serializePreset(parsePreset(text)), text);
  const reordered = '{"values":{"emphasized":false,"cornerRadius":18,"contentDensity":"comfortable","accentColor":"#C65A3A"},"viewport":{"width":1024,"height":768},"fixture":"dispatch-card","schemaVersion":1}';
  assert.equal(serializePreset(parsePreset(reordered)), text);
});

test('every supported exact viewport and fixture survives export', () => {
  for (const fixture of FIXTURES) {
    for (const viewport of VIEWPORT_PRESETS) {
      const values = fixture.defaults;
      const normalized = parsePreset(JSON.stringify({
        schemaVersion: 1,
        fixture: fixture.id,
        viewport: { width: viewport.width, height: viewport.height },
        values,
      }));
      assert.deepEqual(normalized.viewport, { width: viewport.width, height: viewport.height });
      assert.equal(normalized.fixture, fixture.id);
    }
  }
});

test('invalid imports reject atomically with classified errors', () => {
  const store = createTweakStore();
  store.setValue('cornerRadius', 24);
  const before = store.exportPreset();
  const invalidCases = [
    ['unknown-version', importText({ schemaVersion: 2 })],
    ['unknown-key', JSON.stringify({ ...canonicalPreset(), extra: true })],
    ['unknown-key', importText({ values: { ...canonicalPreset().values, display: 'none' } })],
    ['missing-key', importText({ values: { accentColor: '#c65a3a', contentDensity: 'comfortable', emphasized: false } })],
    ['malformed-color', importText({ values: { ...canonicalPreset().values, accentColor: '#fff' } })],
    ['malformed-color', importText({ values: { ...canonicalPreset().values, accentColor: 'url(https://example.invalid/x)' } })],
    ['non-finite-number', importText().replace('18', 'NaN')],
    ['non-finite-number', importText().replace('18', 'Infinity')],
    ['non-finite-number', importText().replace('18', '1e999')],
    ['out-of-range', importText({ values: { ...canonicalPreset().values, cornerRadius: 33 } })],
    ['step-mismatch', importText({ values: { ...canonicalPreset().values, cornerRadius: 18.5 } })],
    ['unknown-fixture', importText({ fixture: 'real-project' })],
    ['unsupported-viewport', importText({ viewport: { width: 999, height: 768 } })],
    ['type', importText({ values: { ...canonicalPreset().values, emphasized: 'true' } })],
    ['invalid-option', importText({ values: { ...canonicalPreset().values, contentDensity: 'source-code' } })],
    ['json', `${importText()}\n${importText()}`],
  ];
  for (const [code, text] of invalidCases) {
    assertValidation(() => store.importPresetText(text), code);
    assert.equal(store.exportPreset(), before, `state changed after ${code}`);
  }
  store.dispose();
});

test('duplicate keys and prototype-pollution keys reject at every JSON object boundary', () => {
  const duplicateCases = [
    '{"schemaVersion":1,"schemaVersion":1,"fixture":"dispatch-card","viewport":{"width":1024,"height":768},"values":{"accentColor":"#c65a3a","contentDensity":"comfortable","cornerRadius":18,"emphasized":false}}',
    '{"schemaVersion":1,"fixture":"dispatch-card","viewport":{"width":1024,"width":1024,"height":768},"values":{"accentColor":"#c65a3a","contentDensity":"comfortable","cornerRadius":18,"emphasized":false}}',
    '{"schemaVersion":1,"fixture":"dispatch-card","viewport":{"width":1024,"height":768},"values":{"accentColor":"#c65a3a","accentColor":"#c65a3a","contentDensity":"comfortable","cornerRadius":18,"emphasized":false}}',
  ];
  for (const text of duplicateCases) assertValidation(() => parsePreset(text), 'duplicate-key');

  for (const key of ['__proto__', 'constructor', 'prototype']) {
    const text = `{"schemaVersion":1,"fixture":"dispatch-card","viewport":{"width":1024,"height":768},"values":{"accentColor":"#c65a3a","contentDensity":"comfortable","cornerRadius":18,"emphasized":false,"${key}":true}}`;
    assertValidation(() => parsePreset(text), 'unsafe-key');
  }
  assert.equal({}.polluted, undefined);
});

test('fixture values remain isolated in memory and reset returns authored defaults', () => {
  const store = createTweakStore();
  store.setValue('cornerRadius', 27);
  store.setFixture('localization-card');
  assert.equal(store.snapshot().values.cornerRadius, 10);
  store.setValue('accentColor', '#315f9f');
  store.setFixture('dispatch-card');
  assert.equal(store.snapshot().values.cornerRadius, 27);
  assert.equal(store.snapshot().values.accentColor, '#c65a3a');
  store.reset();
  assert.equal(store.snapshot().values.cornerRadius, 18);
  store.setFixture('localization-card');
  assert.equal(store.snapshot().values.accentColor, '#315f9f');
  assert.deepEqual(store.diagnostics(), {
    disposed: false,
    fixtureCount: 2,
    listenerCount: 0,
    persistence: 'disabled',
  });
  store.dispose();
});

test('schema definition denies selectors, arbitrary properties, handlers, URLs, snippets, and unsafe targets', () => {
  const number = {
    key: 'safeNumber',
    kind: 'number',
    label: 'Safe number',
    target: { type: 'css-custom-property', name: '--safe-number' },
    min: 0,
    max: 10,
    step: 1,
    unit: 'px',
    defaultValue: 2,
  };
  assertValidation(() => defineTweakSchema([{ ...number, target: { type: 'css-custom-property', name: 'display' } }]), 'unsafe-target');
  assertValidation(() => defineTweakSchema([{ ...number, target: { type: 'css-custom-property', name: 'background-image:url(x)' } }]), 'unsafe-target');
  assertValidation(() => defineTweakSchema([{ ...number, target: { type: 'data-attribute', name: 'onclick' } }]), 'unsafe-target');
  assertValidation(() => defineTweakSchema([{ ...number, target: { ...number.target, selector: 'body' } }]), 'unknown-key');
  assertValidation(() => defineTweakSchema([{ ...number, source: 'export default alert(1)' }]), 'unknown-key');
  assertValidation(() => defineTweakSchema([{
    key: 'unsafeChoice',
    kind: 'select',
    label: 'Unsafe choice',
    target: { type: 'css-custom-property', name: '--safe-choice' },
    defaultValue: 'safe',
    options: [
      { label: 'Safe', value: 'safe', cssValue: '1rem' },
      { label: 'Remote', value: 'remote', cssValue: 'url(https://example.invalid/x)' },
    ],
  }]), 'unsafe-value');
});

test('application touches only declared CSS custom properties and data attributes', () => {
  const target = fakeTarget();
  const preset = canonicalPreset({
    values: {
      cornerRadius: 24,
      accentColor: '#315f9f',
      contentDensity: 'roomy',
      emphasized: true,
    },
  });
  applyTweakValues(target, preset);
  assert.deepEqual([...target.properties], [
    ['--proof-corner-radius', '24px'],
    ['--proof-accent-color', '#315f9f'],
    ['--proof-content-gap', '1.75rem'],
  ]);
  assert.deepEqual([...target.attributes], [['data-proof-emphasized', 'true']]);
  assert.equal(target.calls.some((call) => call.join(' ').includes('selector')), false);

  applyTweakValues(target, canonicalPreset());
  assert.equal(target.properties.size, 0);
  assert.equal(target.attributes.size, 0);
  assertValidation(() => applyTweakValues(target, canonicalPreset({ values: { ...canonicalPreset().values, onclick: true } })), 'unknown-key');
});

test('token patch suggestions are canonical data and never apply source', () => {
  const suggestion = createTokenPatchSuggestion(canonicalPreset({
    values: { ...canonicalPreset().values, cornerRadius: 24, emphasized: true },
  }));
  assert.equal(suggestion, createTokenPatchSuggestion(parsePreset(importText({
    values: { ...canonicalPreset().values, cornerRadius: 24, emphasized: true },
  }))));
  const parsed = JSON.parse(suggestion);
  assert.equal(parsed.reviewRequired, true);
  assert.deepEqual(parsed.cssCustomProperties, {
    '--proof-accent-color': '#c65a3a',
    '--proof-content-gap': '1.25rem',
    '--proof-corner-radius': '24px',
  });
  assert.deepEqual(parsed.dataAttributes, { 'data-proof-emphasized': true });
  assert.equal(suggestion.includes('selector'), false);
  assert.equal(suggestion.includes('source'), false);
});

test('subscriptions and disposal are idempotent', () => {
  const store = createTweakStore();
  let calls = 0;
  const unsubscribe = store.subscribe(() => { calls += 1; });
  store.setValue('cornerRadius', 19);
  assert.equal(calls, 1);
  unsubscribe();
  unsubscribe();
  store.setValue('cornerRadius', 20);
  assert.equal(calls, 1);
  store.dispose();
  store.dispose();
  assertValidation(() => store.snapshot(), 'disposed');
});
