import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { join, resolve, sep } from 'node:path';

// Argo CD's Git directory generator silently becomes unsafe when a directory
// is deleted but still referenced, particularly with automated prune:true.
// Check the explicitly listed roots. This is a *static* guard only: it does
// NOT validate ownership, live deletions or prune impact.
const ROOT = resolve('.');
const applicationSets = [
  'k8s/bootstrap/argocd-root/applications-applicationset.yaml',
  'k8s/bootstrap/argocd-root/infrastructure-applicationset.yaml',
];

// Historical, already-missing path on main: no rendered Kustomization exists.
// Track separately; do not synthesize a dummy Kustomization or assume no live
// resources are owned by the corresponding generated Application.
const KNOWN_MISSING = new Set(['k8s/applications/restore']);

function generatedPaths(source) {
  return [...source.matchAll(/^\s*- path:\s*(k8s\/[^\s#]+)\s*$/gm)].map(([, path]) => path);
}

test('every active Argo directory-generator root exists and has a Kustomization', () => {
  const observed = new Set();
  for (const sourcePath of applicationSets) {
    const source = readFileSync(join(ROOT, sourcePath), 'utf8');
    const dirs = generatedPaths(source);
    assert.ok(dirs.length > 0, `no generated roots parsed in ${sourcePath}`);

    for (const dir of dirs) {
      assert.ok(!dir.includes('..') && !dir.includes('*') && !dir.startsWith('/'), `unsafe git generator path: ${dir}`);
      assert.ok(!observed.has(dir), `duplicate generated root: ${dir}`);
      observed.add(dir);
      if (KNOWN_MISSING.has(dir)) continue;

      const absolute = resolve(ROOT, dir);
      assert.ok(absolute.startsWith(ROOT + sep), `generator path outside repo: ${dir}`);
      assert.ok(existsSync(absolute), `Argo references missing directory: ${dir}`);
      assert.ok(
        ['kustomization.yaml', 'kustomization.yml', 'Kustomization'].some(file => existsSync(join(absolute, file))),
        `Argo generator root has no Kustomization: ${dir}`,
      );
    }
  }

  // If the restore root becomes a real Kustomization, the exception must be
  // removed in the same PR, so it doesn't hide future regressions.
  for (const missing of KNOWN_MISSING) {
    assert.ok(
      !['kustomization.yaml', 'kustomization.yml', 'Kustomization'].some(file => existsSync(join(ROOT, missing, file))),
      `stale known-missing exception; remove waiver: ${missing}`,
    );
  }
});

test('the retained Docusaurus site remains present during Paperclip retirement', () => {
  assert.ok(existsSync(join(ROOT, 'website/package.json')), 'Docusaurus website deleted');
  assert.ok(existsSync(join(ROOT, 'netlify.toml')), 'site deployment configuration deleted');
});
