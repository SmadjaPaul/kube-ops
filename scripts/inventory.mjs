#!/usr/bin/env node
// Git-only Kustomize source inventory. Argo/kubectl runtime evidence is separate.
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { resolve, join, dirname, relative, sep } from 'node:path';
import { spawnSync } from 'node:child_process';
const args = process.argv.slice(2);
if (args.length && (args.length !== 2 || args[0] !== '--root')) {
  console.error('Usage: node scripts/inventory.mjs [--root REPOSITORY_ROOT]');
  process.exit(2);
}
const root = resolve(args[1] || '.');
const activeDirs = new Set(), activeFiles = new Set(), hosts = new Set();
const warnings = [], missingRoots = [];
function safe(path) {
  const full = resolve(root, path);
  if (full !== root && !full.startsWith(root + sep)) throw Error('Outside repository: ' + path);
  return full;
}
function rel(path) { return relative(root, path).split(sep).join('/'); }
function kust(dir) {
  return ['kustomization.yaml', 'kustomization.yml', 'Kustomization']
    .find(name => existsSync(join(dir, name)));
}
function yq(file, expr, flags = ['eval', '-o=json']) {
  const r = spawnSync('yq', [...flags, expr, file], { encoding: 'utf8' });
  if (r.status !== 0 || r.error) throw Error('Cannot parse ' + rel(file) + ': ' + (r.error?.message || r.stderr));
  return r.stdout.trim();
}
function roots(path) {
  const src = readFileSync(safe(path), 'utf8');
  return [...src.matchAll(/^\s*-\s+path:\s*(k8s\/[^\s#]+)\s*$/gm)].map(x => x[1]);
}
function visit(path) {
  if (/^(https?:\/\/|git::)/.test(path)) {
    warnings.push({ type: 'remote-resource', path }); return;
  }
  const abs = safe(path);
  if (!existsSync(abs)) { warnings.push({ type: 'missing-resource', path }); return; }
  if (statSync(abs).isFile()) {
    activeFiles.add(rel(abs));
    if (/\.ya?ml$/.test(abs) && /^\s*kind:\s*(HTTPRoute|GRPCRoute|TLSRoute)\s*$/m.test(readFileSync(abs, 'utf8'))) {
      const output = yq(abs,
        'select(.kind == "HTTPRoute" or .kind == "GRPCRoute" or .kind == "TLSRoute") | .spec.hostnames[]',
        ['eval', '-r']);
      output.split('\n').map(x => x.trim()).filter(x => x && x !== 'null' && x !== '---')
        .forEach(x => hosts.add(x));
    }
    return;
  }
  if (activeDirs.has(rel(abs))) return;
  const name = kust(abs);
  if (!name) { warnings.push({ type: 'missing-kustomization', path: rel(abs) }); return; }
  activeDirs.add(rel(abs));
  const data = JSON.parse(yq(join(abs, name), '.resources // []'));
  if (!Array.isArray(data) || data.some(x => typeof x !== 'string')) {
    throw Error('Invalid Kustomization resources: ' + rel(join(abs, name)));
  }
  for (const resource of data) {
    visit(/^(https?:\/\/|git::)/.test(resource) ? resource : rel(resolve(abs, resource)));
  }
}
const appRoots = roots('k8s/bootstrap/argocd-root/applications-applicationset.yaml');
const infraRoots = roots('k8s/bootstrap/argocd-root/infrastructure-applicationset.yaml');
for (const [type, paths] of [['applications', appRoots], ['infrastructure', infraRoots]]) {
  for (const path of paths) {
    if (!existsSync(safe(path))) { missingRoots.push({ type, path }); continue; }
    visit(path);
  }
}
const dirs = [];
function walk(dir) {
  if (!existsSync(dir)) return;
  for (const ent of readdirSync(dir, { withFileTypes: true })) {
    if (!ent.isDirectory()) continue;
    const path = join(dir, ent.name);
    if (kust(path)) dirs.push(rel(path));
    walk(path);
  }
}
walk(safe('k8s/applications'));
const used = [...activeDirs];
const candidates = dirs.filter(path => !activeDirs.has(path) && !used.some(a => a.startsWith(path + '/')));
const dormant = candidates.filter(path => !candidates.some(parent => parent !== path && path.startsWith(parent + '/'))).sort();
console.log(JSON.stringify({
  source: 'git-only Argo ApplicationSet + local Kustomize resources graph',
  caveats: [
    'Not runtime/Argo reconciliation evidence',
    'Helm charts and Kustomize generators are not expanded',
    'Hostnames are read only from directly included local Gateway API route YAML',
  ],
  applicationRoots: appRoots,
  infrastructureRoots: infraRoots,
  missingRoots,
  activeKustomizationDirs: used.sort(),
  dormantApplicationDirs: dormant,
  declaredHostnames: [...hosts].sort(),
  warnings,
}, null, 2));
