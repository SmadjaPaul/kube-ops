import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
const script = resolve('scripts/inventory.mjs');
const haveYq = spawnSync('yq', ['--version'], { encoding: 'utf8' }).status === 0;
function file(root, path, body) {
  const target = join(root, path);
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target, body);
}
test('inventory reports dormant subtrees and excludes their HTTPRoutes', { skip: !haveYq }, () => {
  const root = mkdtempSync(join(tmpdir(), 'k8s-inventory-'));
  try {
    file(root, 'k8s/bootstrap/argocd-root/applications-applicationset.yaml',
      'directories:\n  - path: k8s/applications/catalog\n  - path: k8s/applications/restore\n');
    file(root, 'k8s/bootstrap/argocd-root/infrastructure-applicationset.yaml',
      'directories:\n  - path: k8s/infrastructure/controllers\n');
    file(root, 'k8s/infrastructure/controllers/kustomization.yaml', 'resources: []\n');
    file(root, 'k8s/applications/catalog/kustomization.yaml', 'resources:\n  - active\n');
    file(root, 'k8s/applications/catalog/active/kustomization.yaml', 'resources:\n  - route.yaml\n');
    file(root, 'k8s/applications/catalog/active/route.yaml',
      'kind: HTTPRoute\nspec:\n  hostnames:\n    - live.smadja.dev\n');
    file(root, 'k8s/applications/catalog/dormant/kustomization.yaml', 'resources:\n  - route.yaml\n');
    file(root, 'k8s/applications/catalog/dormant/route.yaml',
      'kind: HTTPRoute\nspec:\n  hostnames:\n    - stale.smadja.dev\n');
    const r = spawnSync(process.execPath, [script, '--root', root], { encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr);
    const parsed = JSON.parse(r.stdout);
    assert.deepEqual(parsed.declaredHostnames, ['live.smadja.dev']);
    assert.ok(parsed.dormantApplicationDirs.includes('k8s/applications/catalog/dormant'));
    assert.ok(!parsed.dormantApplicationDirs.includes('k8s/applications/catalog/active'));
    assert.deepEqual(parsed.missingRoots, [{ type: 'applications', path: 'k8s/applications/restore' }]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
