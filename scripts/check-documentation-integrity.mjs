#!/usr/bin/env node

/**
 * Offline P0 documentation guardrails.
 *
 * This checks facts that Git can prove: tracked agent-router paths, local
 * links, declared just/npm commands, and the public-documentation boundary for
 * files changed by a pull request. It deliberately does not claim semantic,
 * Argo, Kubernetes, or runtime correctness.
 */

import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { isAbsolute, relative, resolve } from 'node:path';

const ROOT = resolve(new URL('..', import.meta.url).pathname);
const EXTERNAL_PREFIXES = ['http://', 'https://', 'mailto:', 'tel:', 'git@', 'ssh://'];
const CODE_EXTENSIONS = ['.md', '.json', '.yaml', '.yml', '.toml', '.sh', '.mjs', '.ts', '.py'];
const PUBLIC_DOC_EXTENSIONS = ['.md', '.mdx'];
const NON_REPOSITORY_REFERENCES = new Set(['Gateway/internal', 'infrastructure/prd']);
const CROSS_REPOSITORY_RECIPES = new Set(['kube-access-sync']);
const DEFAULT_RETIRED_PLATFORMS = ['Flux', 'home-ops'];
const DEFAULT_RETIRED_IAM = ['Bitwarden', 'bitwarden-backend'];
const PRIVATE_DOC_PATTERNS = [
  { pattern: /-----BEGIN [A-Z ]+ PRIVATE KEY-----/, name: 'private key material' },
  { pattern: /\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}\b/, name: 'GitHub token material' },
  { pattern: /\bgithub_pat_[A-Za-z0-9_]{20,}\b/, name: 'GitHub token material' },
  { pattern: /\bxox[baprs]-[A-Za-z0-9-]{20,}\b/, name: 'Slack token material' },
  { pattern: /\bAKIA[0-9A-Z]{16}\b/, name: 'AWS access-key material' },
  { pattern: /\b(?:10\.(?:[0-9]{1,3}\.){2}[0-9]{1,3}|192\.168\.(?:[0-9]{1,3}\.)[0-9]{1,3}|172\.(?:1[6-9]|2[0-9]|3[01])\.(?:[0-9]{1,3}\.)[0-9]{1,3})\b/, name: 'private network address' },
  { pattern: /\/(?:Users|home)\/[A-Za-z0-9._-]+\//, name: 'workstation path' },
  { pattern: /~\/\.kube\/config\b/, name: 'ambient kubeconfig path' },
];

function trackedFiles(root = ROOT) {
  return new Set(
    execFileSync('git', ['-C', root, 'ls-files', '-z'], { encoding: 'utf8' })
      .split('\0')
      .filter(Boolean),
  );
}

function localPathLike(value) {
  if (!value || /\s/.test(value) || EXTERNAL_PREFIXES.some(prefix => value.startsWith(prefix))) return false;
  if (value.startsWith(('#', '$', '{', '<', '!', '-', '~')) || value === './' || value === '../') return false;
  if (NON_REPOSITORY_REFERENCES.has(value)) return false;
  return value.includes('/') || CODE_EXTENSIONS.some(extension => value.endsWith(extension));
}

function isPublicDocumentation(name) {
  return name.startsWith('website/docs/') && PUBLIC_DOC_EXTENSIONS.some(extension => name.endsWith(extension));
}

function fencedContentRemoved(text) {
  return text.replace(/(^|\n)\s*(```|~~~)[^\n]*\n[\s\S]*?\n\s*\2\s*(?=\n|$)/g, '$1');
}

function referencedPaths(text) {
  const source = fencedContentRemoved(text);
  const refs = new Set();
  for (const match of source.matchAll(/`([^`\n]+)`/g)) {
    if (localPathLike(match[1])) refs.add(match[1]);
  }
  for (const match of source.matchAll(/(?<!!)\[[^\]\n]+\]\(([^)\n]+)\)/g)) {
    const target = match[1].trim().split(/\s+/, 1)[0].replace(/^<|>$/g, '');
    if (!target || target.startsWith('#') || EXTERNAL_PREFIXES.some(prefix => target.startsWith(prefix))) continue;
    const path = target.split('#', 1)[0].split('?', 1)[0];
    if (localPathLike(path)) refs.add(path);
  }
  return refs;
}

function pathExistsAsTracked(root, owner, ref, tracked) {
  const candidates = [resolve(root, ref), resolve(owner, '..', ref)];
  return candidates.some(candidate => {
    const rel = relative(root, candidate);
    if (rel.startsWith('..') || isAbsolute(rel)) return false;
    if (ref.includes('*') || ref.includes('?')) {
      const regex = new RegExp(`^${rel.replace(/[.+^${}()|[\\]\\]/g, '\\$&').replace(/\*/g, '.*').replace(/\?/g, '.')}$`);
      return [...tracked].some(name => regex.test(name));
    }
    if (tracked.has(rel)) return true;
    return [...tracked].some(name => name.startsWith(`${rel.replace(/\/$/, '')}/`));
  });
}

function justRecipes(root) {
  const text = readFileSync(resolve(root, '.justfile'), 'utf8');
  return new Set([...text.matchAll(/^([A-Za-z][\w-]*)(?:\s+[^:]*)?:\s*(?:#.*)?$/gm)].map(([, name]) => name));
}

function packageScripts(root, path) {
  const packagePath = resolve(root, path);
  if (!existsSync(packagePath)) return new Set();
  return new Set(Object.keys(JSON.parse(readFileSync(packagePath, 'utf8')).scripts ?? {}));
}

function validateDocumentationPolicy(root) {
  const path = resolve(root, 'docs/documentation-integrity.json');
  if (!existsSync(path)) throw new Error('docs/documentation-integrity.json is missing');
  const policy = JSON.parse(readFileSync(path, 'utf8'));
  if (policy.schema_version !== 1) throw new Error('unsupported documentation policy version');
  if (!policy.scope?.agent_router || !policy.scope?.public_documents) throw new Error('documentation policy scope is incomplete');
  if (!policy.retired_reference_policy?.platforms?.length || !policy.retired_reference_policy?.iam?.length) {
    throw new Error('documentation policy retired-reference inventory is incomplete');
  }
  return policy;
}

export function checkAgentDocs(root = ROOT) {
  validateDocumentationPolicy(root);
  const tracked = trackedFiles(root);
  const agents = [...tracked].filter(name => name === 'AGENTS.md' || name.endsWith('/AGENTS.md'));
  const errors = [];
  if (agents.length === 0) return ['no tracked AGENTS.md router found'];

  const recipes = justRecipes(root);
  const rootScripts = packageScripts(root, 'package.json');
  const websiteScripts = packageScripts(root, 'website/package.json');
  for (const name of agents) {
    errors.push(...validateAgentText(
      root,
      name,
      readFileSync(resolve(root, name), 'utf8'),
      tracked,
      recipes,
      rootScripts,
      websiteScripts,
    ));
  }
  return errors;
}

export function validateAgentText(root, name, source, tracked, recipes, rootScripts, websiteScripts) {
  const errors = [];
  const agentPath = resolve(root, name);
  for (const ref of [...referencedPaths(source)].sort()) {
      if (!pathExistsAsTracked(root, agentPath, ref, tracked)) {
        errors.push(`${name}: missing tracked path ${ref}`);
      }
  }
  for (const skill of [...source.matchAll(/\.agents\/skills\/([A-Za-z0-9_-]+)/g)].map(([, value]) => value)) {
    const skillPath = `${skill}/SKILL.md`;
    if (!tracked.has(`.agents/skills/${skillPath}`)) errors.push(`${name}: missing skill ${skillPath}`);
  }
  for (const recipe of [...source.matchAll(/`just ([a-z][\w-]*)/g)].map(([, value]) => value)) {
    if (!recipes.has(recipe) && !CROSS_REPOSITORY_RECIPES.has(recipe)) errors.push(`${name}: unknown just recipe ${recipe}`);
  }
  for (const script of [...source.matchAll(/`npm run ([a-z][\w:-]*)/g)].map(([, value]) => value)) {
    if (!rootScripts.has(script) && !websiteScripts.has(script)) errors.push(`${name}: unknown npm script ${script}`);
  }
  return errors;
}

function termsPattern(terms) {
  return new RegExp(`\\b(?:${terms.map(term => term.replace(/[.*+?^${}()|[\\]\\]/g, '\\$&')).join('|')})\\b`, 'i');
}

export function findPublicDocumentationViolations(text, policy = null) {
  const violations = [];
  const platformPattern = termsPattern(policy?.retired_reference_policy?.platforms ?? DEFAULT_RETIRED_PLATFORMS);
  const iamPattern = termsPattern(policy?.retired_reference_policy?.iam ?? DEFAULT_RETIRED_IAM);
  for (const { pattern, name } of PRIVATE_DOC_PATTERNS) {
    if (pattern.test(text)) violations.push(name);
  }
  for (const line of text.split('\n')) {
    if (platformPattern.test(line) && !/(historical|legacy|retired|no longer|old|superseded|retained)/i.test(line)) {
      violations.push('active retired platform reference');
    }
    if (iamPattern.test(line) && /(?:from|using|integration|token|secret|pull|store|create|save|read|backend)/i.test(line) && !/(historical|legacy|retired|not V1|old|superseded|retained)/i.test(line)) {
      violations.push('active retired IAM reference');
    }
  }
  return [...new Set(violations)];
}

export function checkPublicFiles(root = ROOT, files = [], policy = null) {
  const errors = [];
  for (const name of files) {
    if (!isPublicDocumentation(name)) continue;
    const path = resolve(root, name);
    if (!existsSync(path)) {
      errors.push(`${name}: changed public document is missing`);
      continue;
    }
    for (const violation of findPublicDocumentationViolations(readFileSync(path, 'utf8'), policy)) {
      errors.push(`${name}: ${violation}`);
    }
  }
  return errors;
}

function changedFiles(root, base) {
  return execFileSync('git', ['-C', root, 'diff', '--name-only', `${base}...HEAD`], { encoding: 'utf8' })
    .split('\n')
    .filter(Boolean);
}

function checkPublicDiff(root, base, policy) {
  const diff = execFileSync('git', ['-C', root, 'diff', '--unified=0', `${base}...HEAD`, '--', 'website/docs'], { encoding: 'utf8' });
  const errors = [];
  let file = null;
  for (const line of diff.split('\n')) {
    if (line.startsWith('+++ b/')) file = line.slice('+++ b/'.length);
    if (!file || !isPublicDocumentation(file)) continue;
    if (!line.startsWith('+') || line.startsWith('+++')) continue;
    for (const violation of findPublicDocumentationViolations(line.slice(1), policy)) {
      errors.push(`${file}: added line: ${violation}`);
    }
  }
  return errors;
}

function main() {
  const args = process.argv.slice(2);
  const explicit = [];
  let base = null;
  for (let index = 0; index < args.length; index += 1) {
    if (args[index] === '--files') explicit.push(...args.slice(index + 1));
    if (args[index] === '--changed-from') base = args[index + 1];
  }
  const files = base ? changedFiles(ROOT, base) : explicit;
  const policy = validateDocumentationPolicy(ROOT);
  const agentErrors = checkAgentDocs(ROOT);
  const publicErrors = base ? checkPublicDiff(ROOT, base, policy) : checkPublicFiles(ROOT, files, policy);
  for (const error of [...agentErrors, ...publicErrors]) console.error(`DOC_INTEGRITY=FAIL ${error}`);
  if (agentErrors.length || publicErrors.length) return 1;
  console.log(`DOC_INTEGRITY=PASS agents=${[...trackedFiles()].filter(name => name === 'AGENTS.md' || name.endsWith('/AGENTS.md')).length} public_files=${files.filter(isPublicDocumentation).length}`);
  console.log('DOC_SEMANTIC_FRESHNESS=NOT_EXECUTED');
  return 0;
}

if (import.meta.url === `file://${process.argv[1]}`) process.exit(main());
