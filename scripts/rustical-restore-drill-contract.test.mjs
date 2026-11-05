import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
const root = 'k8s/optional/rustical-restore-drill';
const read = path => readFileSync(join(root, path), 'utf8');

test('each overlay references only its synthetic namespace',()=>{
  for (const [overlay, ns] of [
    ['source','rustical-restore-source'],
    ['target','rustical-restore-target'],
    ['target-reader','rustical-restore-target']]) {
    const manifest = read(overlay === 'target-reader' ? 'target/namespace.yaml' : overlay+'/namespace.yaml');
    assert.match(manifest, new RegExp('name: '+ns+'\\b'));
    const k = read(overlay+'/kustomization.yaml');
    assert.match(k, new RegExp('namespace: '+ns+'\\b'));
  }
});
test('target requires restore before deploying reader, no target PVC',()=>{
  const k = read('target/kustomization.yaml');
  assert.match(k, /\.\.\/base\/networkpolicy\.yaml/);
  assert.doesNotMatch(k, /pvc\.yaml|deployment\.yaml|\.\.\/base\s*$/m);
  const reader = read('target-reader/kustomization.yaml');
  assert.match(reader, /\.\.\/base\/deployment\.yaml/);
  assert.doesNotMatch(reader, /pvc\.yaml/);
});
test('fixture is offline private-only, uses exact pinned image',()=>{
  const d=read('base/deployment.yaml');
  const p=read('base/networkpolicy.yaml');
  const s=read('base/service.yaml');
  assert.match(d, /rustical:0\.18\.0@sha256:[a-f0-9]{64}/);
  assert.match(d, /RUSTICAL_DATA_STORE__SQLITE__DB_URL/);
  assert.match(d, /automountServiceAccountToken: false/);
  assert.doesNotMatch(d, /envFrom|secretKeyRef|RUSTICAL_OIDC__|imagePullPolicy:\s*Always/);
  assert.match(p, /egressDeny:/);
  assert.match(p, /toEntities: \[all\]/);
  assert.match(p, /enableDefaultDeny:/);
  assert.match(d, /backup.velero.io\/backup-volumes: data/);
  assert.match(p, /rustical-restore-probe/);
  assert.match(s, /type: ClusterIP/);
  const all = ['base/pvc.yaml','base/deployment.yaml','base/service.yaml','base/networkpolicy.yaml',
    'source/namespace.yaml','target/namespace.yaml'].map(read).join('\n');
  assert.doesNotMatch(all, /kind: (HTTPRoute|ExternalSecret|Secret|ClusterRole|Ingress)/);
  assert.doesNotMatch(all, /media\.smadja\.dev|calendar\.smadja\.dev|auth\.smadja\.dev/);
});
