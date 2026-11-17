#!/usr/bin/env node
// Catalogue Backstage dérivé de Git uniquement : aucun second inventaire saisi à la main.
// Usage : node scripts/catalog/generate-catalog.mjs [--root DIR] [--check]
//   sans --check : écrit catalog/generated/all.yaml et catalog/locations.yaml ;
//   avec --check : régénère en mémoire, échoue si un fichier diffère ou si le format est invalide.
// Sources réutilisées : scripts/inventory.mjs (graphe Kustomize actif depuis les racines Argo),
// HTTPRoute et Namespace des ressources actives, docs/operations/backup-coverage-classes.tsv,
// blueprints Authentik (groupes). Une valeur absente de Git n'est jamais inventée : l'annotation est omise.
import { existsSync, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { basename, dirname, join, relative, resolve, sep } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const API_VERSION = 'backstage.io/v1alpha1';
// Expression de nommage Backstage (metadata.name, 63 caractères au plus).
export const NAME_RE = /^([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9\-_.]*[A-Za-z0-9])$/;

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const INVENTORY = join(REPO_ROOT, 'scripts/inventory.mjs');
export const GENERATED = 'catalog/generated/all.yaml';
export const LOCATIONS = 'catalog/locations.yaml';
const TSV = 'docs/operations/backup-coverage-classes.tsv';
const APPSET = 'k8s/bootstrap/argocd-root/applications-applicationset.yaml';
const BLUEPRINTS = 'k8s/infrastructure/auth/authentik/extra/blueprints';
const SERVICE_RE = /^k8s\/applications\/([^/]+)\/([^/]+)$/;
const KUST_NAMES = ['kustomization.yaml', 'kustomization.yml', 'Kustomization'];
const CLASS_ORDER = ['IRREPLACEABLE', 'USEFUL', 'REBUILDABLE'];

// Constantes du pilote, justifiées dans le checkpoint E-catalogue.md :
// - OWNER : le dépôt n'a pas de CODEOWNERS ; un seul propriétaire humain connu (contrat).
// - CLUSTER : la racine applications pointe vers le serveur in-cluster de l'Argo du dépôt (homelab).
const OWNER = 'group:default/homelab';
const GROUP = 'homelab';
const CLUSTER = 'homelab';
const HEADER = '# Généré par scripts/catalog/generate-catalog.mjs depuis Git. Ne pas éditer à la main.\n';
const LOCATIONS_TEXT = `${HEADER}apiVersion: backstage.io/v1alpha1
kind: Location
metadata:
  name: kube-ops
  description: Catalogue généré depuis Git, plus les catalog-info.yaml posés dans les services.
spec:
  targets:
    - ./generated/all.yaml
    - ../k8s/applications/**/catalog-info.yaml
`;

const rel = (root, file) => relative(root, file).split(sep).join('/');

function readDocs(root, file) {
  const r = spawnSync('yq', ['eval', '-o=json', '-I=0', '.', file], { encoding: 'utf8' });
  if (r.status !== 0 || r.error) throw new Error(`Cannot parse ${rel(root, file)}: ${r.error?.message || r.stderr}`);
  return r.stdout.split('\n').map(x => x.trim()).filter(x => x && x !== 'null').map(x => JSON.parse(x));
}

function kustFile(dir) {
  return KUST_NAMES.map(n => join(dir, n)).find(existsSync);
}

function walkFiles(dir, visit) {
  if (!existsSync(dir)) return;
  for (const ent of readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    const p = join(dir, ent.name);
    if (ent.isDirectory()) walkFiles(p, visit);
    else visit(p);
  }
}

// Fichiers YAML et namespaces atteignables depuis le kustomization d'un service (liens locaux seulement).
function collectTree(root, dir, acc = { files: new Set(), namespaces: new Set(), seen: new Set() }) {
  if (acc.seen.has(dir)) return acc;
  acc.seen.add(dir);
  const kf = kustFile(dir);
  if (!kf) return acc;
  const [k = {}] = readDocs(root, kf);
  if (typeof k.namespace === 'string') acc.namespaces.add(k.namespace);
  const resources = Array.isArray(k.resources) ? k.resources : [];
  for (const res of resources) {
    if (typeof res !== 'string' || /^(https?:\/\/|git::)/.test(res)) continue;
    const p = resolve(dir, res);
    if (!existsSync(p)) continue;
    if (statSync(p).isDirectory()) collectTree(root, p, acc);
    else if (/\.ya?ml$/.test(p)) acc.files.add(p);
  }
  return acc;
}

function parseTsv(root) {
  const map = new Map();
  for (const line of readFileSync(join(root, TSV), 'utf8').split('\n')) {
    if (!line || line.startsWith('#')) continue;
    const [ns, , cls] = line.split('\t');
    if (!ns || !cls) continue;
    if (!map.has(ns)) map.set(ns, new Set());
    map.get(ns).add(cls);
  }
  return map;
}

function dataClassOf(namespaces, tsv) {
  const classes = new Set();
  for (const ns of namespaces) for (const c of tsv.get(ns) ?? []) classes.add(c);
  if (!classes.size) return undefined;
  return CLASS_ORDER.find(c => classes.has(c)) ?? [...classes].sort().join(',');
}

function runInventory(root) {
  const r = spawnSync(process.execPath, [INVENTORY, '--root', root], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
  if (r.status !== 0) throw new Error(`inventory failed: ${r.stderr}`);
  return JSON.parse(r.stdout);
}

function discoverCatalogInfo(root) {
  const found = [];
  walkFiles(join(root, 'k8s/applications'), file => {
    if (/^catalog-info\.ya?ml$/.test(basename(file))) found.push(file);
  });
  return found.map(file => ({ dir: rel(root, dirname(file)), entries: readDocs(root, file).map(doc => ({ source: rel(root, file), doc })) }));
}

function serviceEntity(root, group, name, dir, ctx) {
  const tree = collectTree(root, join(root, dir));
  const namespaces = new Set(tree.namespaces);
  const routes = [];
  for (const file of [...tree.files].sort()) {
    for (const doc of readDocs(root, file)) {
      if (doc.kind === 'HTTPRoute') routes.push(doc);
      if (doc.kind === 'Namespace' && typeof doc.metadata?.name === 'string') namespaces.add(doc.metadata.name);
    }
  }
  const hostnames = [...new Set(routes.flatMap(r => r.spec?.hostnames ?? []))].sort();
  const exposure = [...new Set(routes.flatMap(r => (r.spec?.parentRefs ?? []).map(p => p.name)))]
    .filter(n => n === 'internal' || n === 'external').sort();
  const bpFile = join(root, BLUEPRINTS, `apps-${name}.yaml`);
  const groups = existsSync(bpFile)
    ? [...new Set([...readFileSync(bpFile, 'utf8').matchAll(/group:\s*!Find \[authentik_core\.group, \[name, "([^"]+)"\]\]/g)].map(m => m[1]))].sort()
    : [];
  const annotations = { 'backstage.io/source-location': `url:${ctx.repo}/tree/${ctx.revision}/${dir}` };
  annotations['homelab.smadja.dev/cluster'] = CLUSTER;
  if (namespaces.size) annotations['homelab.smadja.dev/namespace'] = [...namespaces].sort().join(',');
  if (exposure.length) annotations['homelab.smadja.dev/exposure'] = exposure.join(',');
  if (hostnames.length) annotations['homelab.smadja.dev/hostname'] = hostnames.join(',');
  if (groups.length) annotations['homelab.smadja.dev/access-groups'] = groups.join(',');
  const dataClass = dataClassOf(namespaces, ctx.tsv);
  if (dataClass) annotations['homelab.smadja.dev/data-class'] = dataClass;
  return {
    apiVersion: API_VERSION,
    kind: 'Component',
    metadata: { name, annotations },
    spec: { type: 'service', lifecycle: 'production', owner: OWNER, system: `apps-${group}` },
  };
}

export function buildCatalog(root) {
  const inv = runInventory(root);
  const appset = readFileSync(join(root, APPSET), 'utf8');
  const repo = (appset.match(/^\s*repoURL:\s*(\S+)/m)?.[1] ?? '').replace(/\.git$/, '');
  const revision = appset.match(/^\s*revision:\s*(\S+)/m)?.[1];
  if (!repo || !revision) throw new Error(`repoURL/revision introuvables dans ${APPSET}`);
  const ctx = { repo, revision, tsv: parseTsv(root) };

  const discovered = discoverCatalogInfo(root);
  const excluded = new Set(discovered.map(d => d.dir));
  const serviceDirs = inv.activeKustomizationDirs
    .map(d => ({ dir: d, m: d.match(SERVICE_RE) }))
    .filter(x => x.m && !excluded.has(x.dir))
    .sort((a, b) => a.dir.localeCompare(b.dir));

  const groups = [...new Set(serviceDirs.map(x => x.m[1]))].sort();
  const components = serviceDirs.map(x => serviceEntity(root, x.m[1], x.m[2], x.dir, ctx))
    .sort((a, b) => a.metadata.name.localeCompare(b.metadata.name));
  const systems = groups.map(g => ({
    apiVersion: API_VERSION,
    kind: 'System',
    metadata: { name: `apps-${g}` },
    spec: { owner: OWNER },
  }));
  const group = { apiVersion: API_VERSION, kind: 'Group', metadata: { name: GROUP }, spec: { type: 'team', children: [] } };
  const entities = [group, ...systems, ...components];
  const allText = HEADER + entities.map(e => `---\n${emit(e)}\n`).join('');
  return {
    entries: entities,
    discovered: discovered.flatMap(d => d.entries),
    allText,
    locText: LOCATIONS_TEXT,
    missingRoots: inv.missingRoots,
    warnings: inv.warnings,
  };
}

function emit(value, indent = 0) {
  const pad = '  '.repeat(indent);
  const lines = [];
  for (const [key, v] of Object.entries(value)) {
    if (v === undefined) continue;
    const k = /^[A-Za-z][A-Za-z0-9_.\/-]*$/.test(key) ? key : JSON.stringify(key);
    if (Array.isArray(v)) {
      if (!v.length) lines.push(`${pad}${k}: []`);
      else { lines.push(`${pad}${k}:`); for (const x of v) lines.push(`${pad}  - ${JSON.stringify(x)}`); }
    } else if (v && typeof v === 'object') {
      if (!Object.keys(v).length) lines.push(`${pad}${k}: {}`);
      else { lines.push(`${pad}${k}:`); lines.push(emit(v, indent + 1)); }
    } else {
      lines.push(`${pad}${k}: ${JSON.stringify(v)}`);
    }
  }
  return lines.join('\n');
}

// Format des entités : apiVersion, kind, metadata.name, champs Component, annotations non vides, unicité.
export function validateEntries(entries) {
  const errors = [];
  const seen = new Map();
  for (const { source, doc } of entries) {
    if (!doc || typeof doc !== 'object' || Array.isArray(doc)) { errors.push(`${source}: document non objet`); continue; }
    if (doc.apiVersion !== API_VERSION) errors.push(`${source}: apiVersion ${JSON.stringify(doc.apiVersion)} != ${API_VERSION}`);
    if (typeof doc.kind !== 'string' || !doc.kind) errors.push(`${source}: kind manquant`);
    const name = doc.metadata?.name;
    if (typeof name !== 'string' || name.length > 63 || !NAME_RE.test(name)) {
      errors.push(`${source}: metadata.name invalide ${JSON.stringify(name)}`);
    }
    const ns = doc.metadata?.namespace ?? 'default';
    if (typeof ns !== 'string' || !NAME_RE.test(ns)) errors.push(`${source}: metadata.namespace invalide ${JSON.stringify(ns)}`);
    if (doc.kind === 'Component') {
      for (const f of ['type', 'lifecycle', 'owner']) {
        if (typeof doc.spec?.[f] !== 'string' || !doc.spec[f]) errors.push(`${source}: spec.${f} manquant pour Component`);
      }
    }
    for (const [k, v] of Object.entries(doc.metadata?.annotations ?? {})) {
      if (typeof v !== 'string' || v.trim() === '') errors.push(`${source}: annotation ${k} vide (absente au lieu de vide)`);
    }
    const key = `${doc.kind}:${ns}:${name}`;
    if (seen.has(key)) errors.push(`${source}: doublon ${key} (déjà vu dans ${seen.get(key)})`);
    else seen.set(key, source);
  }
  return errors;
}

function parseArgs(argv) {
  const out = { root: REPO_ROOT, check: false };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--check') out.check = true;
    else if (argv[i] === '--root' && argv[i + 1]) out.root = resolve(argv[++i]);
    else throw new Error(`argument inconnu: ${argv[i]}`);
  }
  return out;
}

function main(argv) {
  const args = parseArgs(argv);
  const built = buildCatalog(args.root);
  const errors = validateEntries([...built.entries.map(doc => ({ source: GENERATED, doc })), ...built.discovered]);
  if (errors.length) {
    console.error(errors.join('\n'));
    process.exit(1);
  }
  const targets = [[GENERATED, built.allText], [LOCATIONS, built.locText]];
  if (args.check) {
    const stale = targets.filter(([f, text]) => {
      const p = join(args.root, f);
      return !existsSync(p) || readFileSync(p, 'utf8') !== text;
    }).map(([f]) => f);
    if (stale.length) {
      console.error(`STALE: ${stale.join(', ')} ne correspond pas a Git. Lancer : node scripts/catalog/generate-catalog.mjs`);
      process.exit(1);
    }
    console.log(`CATALOG_ENTITIES=${built.entries.length} DISCOVERED_ENTRIES=${built.discovered.length} STATUS=FRESH`);
    return;
  }
  for (const [f, text] of targets) {
    const p = join(args.root, f);
    mkdirSync(dirname(p), { recursive: true });
    writeFileSync(p, text);
  }
  console.log(`CATALOG_ENTITIES=${built.entries.length} DISCOVERED_ENTRIES=${built.discovered.length} WRITTEN=${targets.map(([f]) => f).join(',')}`);
  for (const m of built.missingRoots) console.log(`WARN missing-argo-root ${m.type} ${m.path}`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main(process.argv.slice(2));
