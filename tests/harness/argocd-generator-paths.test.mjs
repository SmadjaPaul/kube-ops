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
  'k8s/bootstrap/argocd-root/infrastructure-applicationset.yaml',
  'k8s/clusters/oracle-a1/argocd-root/infrastructure-applicationset.yaml',
];

// No waiver remains: k8s/applications/restore was removed from the ApplicationSet.
// Add a path here only for a documented, temporary, already-missing root.
const KNOWN_MISSING = new Set([]);

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
    assert.ok(observed.has(missing), `stale known-missing waiver; generator no longer references: ${missing}`);
    assert.ok(
      !['kustomization.yaml', 'kustomization.yml', 'Kustomization'].some(file => existsSync(join(ROOT, missing, file))),
      `stale known-missing exception; remove waiver: ${missing}`,
    );
  }
});

// PLT-394 I1-I3: App of Apps infra-root. One owner per directory, ordered waves, no cascade.
const INFRA_ROOT = 'k8s/bootstrap/infra-root';
const ALLOWED_WAVES = new Set(['-30', '-20', '-10', '0', '10']);

function infraRootApplications() {
  const kustomization = readFileSync(join(ROOT, INFRA_ROOT, 'kustomization.yaml'), 'utf8');
  const files = [...kustomization.matchAll(/^\s*-\s+(\S+\.ya?ml)\s*$/gm)].map(([, f]) => f);
  return files.map(file => {
    const src = readFileSync(join(ROOT, INFRA_ROOT, file), 'utf8');
    const field = re => (src.match(re) || [])[1];
    return {
      file,
      src,
      kind: field(/^kind:\s*(\S+)\s*$/m),
      name: field(/^  name:\s*(\S+)\s*$/m),
      path: field(/^\s+path:\s*(k8s\/[^\s#]+)\s*$/m),
      wave: field(/argocd\.argoproj\.io\/sync-wave:\s*"?(-?\d+)"?/),
      project: field(/^  project:\s*(\S+)\s*$/m),
    };
  });
}

test('infra-root: every child Application is ordered, non-cascading and owns a directory nobody else generates', () => {
  const root = readFileSync(join(ROOT, 'k8s/bootstrap/argocd-root/kustomization.yaml'), 'utf8');
  assert.match(root, /^\s*-\s+infra-root-application\.yaml\s*$/m, 'root must render infra-root');
  const parent = readFileSync(join(ROOT, 'k8s/bootstrap/argocd-root/infra-root-application.yaml'), 'utf8');
  assert.match(parent, new RegExp(`path: ${INFRA_ROOT}\\s*$`, 'm'));
  assert.match(parent, /sync-options: Prune=false/, 'root must never prune infra-root');
  assert.doesNotMatch(parent, /finalizers:/, 'infra-root must not cascade on deletion');

  const appsetDirs = new Set(generatedPaths(readFileSync(join(ROOT, applicationSets[0]), 'utf8')));
  const apps = infraRootApplications();
  assert.ok(apps.length >= 3, 'infra-root must render at least 3 Applications');
  const names = new Set();
  const paths = new Set();
  for (const app of apps) {
    assert.equal(app.kind, 'Application', `${app.file}: kind`);
    assert.ok(app.name?.startsWith('infra-'), `${app.file}: name must start with infra-`);
    assert.ok(!names.has(app.name), `duplicate Application ${app.name}`);
    names.add(app.name);
    assert.ok(ALLOWED_WAVES.has(app.wave), `${app.name}: sync-wave ${app.wave} not in -30/-20/-10/0/10`);
    assert.equal(app.project, 'infrastructure', `${app.name}: project`);
    assert.match(app.src, /sync-options: Prune=false/, `${app.name}: infra-root must never prune it`);
    assert.doesNotMatch(app.src, /finalizers:/, `${app.name}: no resources-finalizer (no cascade)`);
    assert.ok(app.path && !app.path.includes('..'), `${app.name}: source path`);
    assert.ok(!paths.has(app.path), `${app.path} owned by two infra-root Applications`);
    paths.add(app.path);
    assert.ok(existsSync(join(ROOT, app.path, 'kustomization.yaml')), `${app.name}: ${app.path} has no kustomization.yaml`);
    for (const dir of appsetDirs) {
      const overlap = app.path === dir || app.path.startsWith(`${dir}/`) || dir.startsWith(`${app.path}/`);
      assert.ok(!overlap, `${app.path} (infra-root ${app.name}) overlaps ApplicationSet infrastructure root ${dir}`);
    }
  }
});

test('infra-root: monitoring is split per component and the aggregate still lists every component', () => {
  const aggregate = readFileSync(join(ROOT, 'k8s/infrastructure/monitoring/kustomization.yaml'), 'utf8');
  const components = [...aggregate.matchAll(/^\s*-\s+(\S+)\s*$/gm)].map(([, c]) => `k8s/infrastructure/monitoring/${c}`);
  const owned = new Set(infraRootApplications().map(a => a.path));
  for (const component of components) {
    assert.ok(owned.has(component), `${component} is in the monitoring aggregate but has no infra-root Application`);
  }
  assert.ok(!existsSync(join(ROOT, 'k8s/infrastructure/monitoring/namespace.yaml')), 'top-level files would have no Application');
});

test('the retained Docusaurus site remains present during Paperclip retirement', () => {
  assert.ok(existsSync(join(ROOT, 'website/package.json')), 'Docusaurus website deleted');
  assert.ok(existsSync(join(ROOT, 'netlify.toml')), 'site deployment configuration deleted');
});

test('OKE infrastructure: ESO precedes netbird-router and the project admits the cluster kinds ESO renders', () => {
  const root = 'k8s/clusters/oracle-a1/argocd-root';
  const appset = readFileSync(join(ROOT, root, 'infrastructure-applicationset.yaml'), 'utf8');
  const paths = generatedPaths(appset);
  const eso = paths.indexOf('k8s/clusters/oracle-a1/external-secrets');
  const nb = paths.indexOf('k8s/clusters/oracle-a1/netbird-router');
  assert.ok(eso >= 0 && nb > eso, 'external-secrets must be listed before netbird-router');

  const project = readFileSync(join(ROOT, root, 'infrastructure-project.yaml'), 'utf8');
  for (const kind of ['CustomResourceDefinition', 'ValidatingWebhookConfiguration', 'ClusterRole', 'ClusterRoleBinding', 'ClusterSecretStore']) {
    assert.match(project, new RegExp(`kind: ${kind}\\b`), `infrastructure project must whitelist ${kind}`);
  }
  const apps = readFileSync(join(ROOT, root, 'apps-project.yaml'), 'utf8');
  assert.match(apps, /namespace: '!netbird'/, 'apps project must exclude the netbird namespace');
});
