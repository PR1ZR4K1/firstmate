import './base.css';
import { applySyntheticViewport, renderSyntheticFixture } from './fixture.js';

const fixtureViewport = document.querySelector('#fixture-viewport');
const appShell = document.querySelector('#app-shell');

renderSyntheticFixture('dispatch-card', fixtureViewport);
applySyntheticViewport(fixtureViewport, { width: 1024, height: 768 });

if (import.meta.env.MODE === 'development') {
  const mountStartedAt = performance.now();
  void import('./dev/entry.js').then(({ mountDevelopmentProof }) => {
    mountDevelopmentProof({ appShell, fixtureViewport, mountStartedAt });
  }).catch((error) => {
    console.error('Development controls could not mount.', error);
  });
}
