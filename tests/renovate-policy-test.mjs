import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const cfg = JSON.parse(await readFile(new URL('../renovate.json', import.meta.url), 'utf8'));

test('Renovate global defaults : pas d automerge Renovate, CI obligatoire', () => {
  assert.equal(cfg.automerge, false);
  assert.equal(cfg.platformAutomerge, false);
  assert.equal(cfg.ignoreTests, false);
  assert.equal(cfg.internalChecksFilter, 'strict');
  assert.equal(cfg.schedule, undefined, 'pas de fenetre horaire');
});

test('aucune regle ne combine matchUpdateTypes et rangeStrategy (config invalide)', () => {
  for (const r of cfg.packageRules) {
    assert.ok(!(r.matchUpdateTypes && r.rangeStrategy), r.description);
  }
});

test('Polyfin reste en revue manuelle', () => {
  const polyfin = cfg.packageRules.find((r) => r.matchPackageNames?.includes('ghcr.io/moodiness/polyfin'));
  assert.ok(polyfin);
  assert.equal(polyfin.automerge, false);
});

test('composants critiques en PR individuelles, apres les groupes', () => {
  const names = cfg.packageRules.filter((r) => r.description?.startsWith('Composant critique'));
  assert.ok(names.length >= 8);
  const lastGroup = Math.max(...cfg.packageRules.map((r, i) => (r.groupName ? i : -1)));
  for (const r of names) {
    assert.equal(r.groupName, null);
    assert.ok(cfg.packageRules.indexOf(r) > lastGroup);
  }
});

test('Factory/Mastra gele', () => {
  const freeze = cfg.packageRules.find((r) => r.matchFileNames?.includes('mastra-factory/**'));
  assert.equal(freeze.enabled, false);
});

test('Meilisearch reste bloque sur sa mineure (migration manuelle de la base)', () => {
  const meili = cfg.packageRules.find((r) => r.matchPackageNames?.includes('getmeili/meilisearch'));
  assert.ok(meili);
  assert.equal(meili.automerge, false);
  assert.match('v1.46.0', new RegExp(meili.allowedVersions.slice(1, -1)));
  assert.doesNotMatch('v1.57.0', new RegExp(meili.allowedVersions.slice(1, -1)));
});
