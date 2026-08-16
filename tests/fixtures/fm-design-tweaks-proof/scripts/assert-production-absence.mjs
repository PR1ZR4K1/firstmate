import { readFile, readdir, lstat } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';

const root = path.resolve(process.cwd(), 'dist');
const manifestPath = path.join(root, '.vite', 'manifest.json');
const forbiddenMarkers = [
  'Firstmate design tweaks',
  'Alt + Shift + T',
  'firstmate.design-tweaks-preset/v1',
  'fm-design-tweaks-proof:v1:',
  'fm-tweaks-',
  'data-proof-schema',
  'tweakpane',
  'lil-gui',
  'sourceMappingURL=',
];

async function filesBelow(directory) {
  const output = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const absolute = path.join(directory, entry.name);
    if (entry.isDirectory()) output.push(...await filesBelow(absolute));
    else if (entry.isFile()) output.push(absolute);
    else throw new Error(`Production output contains a non-regular entry: ${absolute}`);
  }
  return output.sort();
}

function reachableManifestKeys(manifest) {
  const entries = Object.entries(manifest);
  const byFile = new Map(entries.map(([key, value]) => [value.file, key]));
  const queue = entries.filter(([, value]) => value.isEntry).map(([key]) => key);
  const reached = new Set();
  while (queue.length > 0) {
    const key = queue.shift();
    if (reached.has(key)) continue;
    reached.add(key);
    const record = manifest[key];
    if (!record) throw new Error(`Manifest references a missing record: ${key}`);
    for (const reference of [...(record.imports || []), ...(record.dynamicImports || [])]) {
      if (manifest[reference]) queue.push(reference);
      else if (byFile.has(reference)) queue.push(byFile.get(reference));
      else throw new Error(`Manifest contains an unresolved import: ${reference}`);
    }
  }
  return [...reached].sort();
}

try {
  const rootStat = await lstat(root);
  if (!rootStat.isDirectory() || rootStat.isSymbolicLink()) throw new Error('Production output must be a real directory.');
  const files = await filesBelow(root);
  if (files.length === 0) throw new Error('Production build emitted no assets.');
  if (files.some((file) => file.endsWith('.map'))) throw new Error('Production build emitted a source map.');

  let totalBytes = 0;
  for (const file of files) {
    const bytes = await readFile(file);
    totalBytes += bytes.byteLength;
    const text = bytes.toString('utf8');
    for (const marker of forbiddenMarkers) {
      if (text.toLowerCase().includes(marker.toLowerCase())) {
        throw new Error(`Production asset ${path.relative(root, file)} contains forbidden development marker: ${marker}`);
      }
    }
  }

  const manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
  const manifestKeys = Object.keys(manifest);
  if (manifestKeys.some((key) => /(?:^|\/)dev\/|tweaks|tweakpane|lil-gui/i.test(key))) {
    throw new Error('Production manifest exposes a development controls module.');
  }
  const reachable = reachableManifestKeys(manifest);
  if (reachable.some((key) => /dev\/|tweaks|tweakpane|lil-gui/i.test(key))) {
    throw new Error('Production entry can reach a development controls chunk.');
  }

  process.stdout.write(`${JSON.stringify({
    assertion: 'firstmate.design-tweaks-production-absence/v1',
    assetCount: files.length,
    totalBytes,
    disabledTweaksBytes: 0,
    reachableEntries: reachable,
    sourceMaps: 0,
  })}\n`);
} catch (error) {
  process.stderr.write(`production-absence assertion failed: ${error.message}\n`);
  process.exitCode = 1;
}
