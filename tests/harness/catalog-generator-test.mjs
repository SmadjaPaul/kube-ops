import test from 'node:test';
import assert from 'node:assert/strict';
import { API_VERSION, validateEntries } from '../../scripts/catalog/generate-catalog.mjs';

const component = (name, extra = {}) => ({
  apiVersion: API_VERSION,
  kind: 'Component',
  metadata: { name, annotations: { 'homelab.smadja.dev/cluster': 'homelab' } },
  spec: { type: 'service', lifecycle: 'production', owner: 'group:default/homelab', ...extra },
});

test('a well-formed Component passes validation', () => {
  assert.deepEqual(validateEntries([{ source: 'x', doc: component('immich') }]), []);
});

test('invalid metadata.name is rejected (underscore at start, too long, forbidden characters)', () => {
  for (const name of ['_bad', 'bad name', 'a'.repeat(64), 'bad!']) {
    const errors = validateEntries([{ source: 'x', doc: component(name) }]);
    assert.ok(errors.some(e => e.includes('metadata.name invalide')), `${name} should be rejected`);
  }
});

test('wrong apiVersion and missing kind are rejected', () => {
  const doc = { ...component('ok'), apiVersion: 'backstage.io/v1' };
  assert.ok(validateEntries([{ source: 'x', doc }]).some(e => e.includes('apiVersion')));
  const noKind = { ...component('ok') };
  delete noKind.kind;
  assert.ok(validateEntries([{ source: 'x', doc: noKind }]).some(e => e.includes('kind manquant')));
});

test('a Component without owner is rejected', () => {
  const doc = component('ok');
  delete doc.spec.owner;
  assert.ok(validateEntries([{ source: 'x', doc }]).some(e => e.includes('spec.owner manquant')));
});

test('an empty annotation value is rejected (unknown values must be absent, not empty)', () => {
  const doc = component('ok');
  doc.metadata.annotations['homelab.smadja.dev/hostname'] = '';
  assert.ok(validateEntries([{ source: 'x', doc }]).some(e => e.includes('annotation homelab.smadja.dev/hostname vide')));
});

test('duplicate kind/namespace/name is rejected across sources', () => {
  const errors = validateEntries([
    { source: 'all.yaml', doc: component('immich') },
    { source: 'k8s/applications/media/immich/catalog-info.yaml', doc: component('immich') },
  ]);
  assert.ok(errors.some(e => e.includes('doublon Component:default:immich')));
});
