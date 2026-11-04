#!/usr/bin/env node
// Polyfin 0.60 / Nebula pilot. No tokenized URLs, keys or cookies in argv, logs or Git.
// Run from an authorized operator environment with reachability to Polyfin and Nebula.
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const approvedHost = 'nebula.eclipsemusic.app';
const polyfinURL = 'https://media.smadja.dev';
const timeoutMs = 15_000;

function fail(code) { throw new Error(code); }

export function validateManifestURL(raw) {
  let url;
  try { url = new URL(String(raw).trim()); } catch { fail('INVALID_URL'); }
  if (url.protocol !== 'https:' || url.username || url.password || url.hash) fail('UNSAFE_URL');
  if (url.hostname !== approvedHost || url.port) fail('UNREVIEWED_HOST');
  if (!url.pathname.endsWith('/manifest.json')) fail('NOT_MANIFEST_URL');
  return url.toString();
}

export function inspectManifest(manifest) {
  if (!manifest || typeof manifest !== 'object' || Array.isArray(manifest)) fail('INVALID_MANIFEST');
  for (const key of ['id', 'name', 'version']) {
    if (typeof manifest[key] !== 'string' || !manifest[key].trim()) fail('INVALID_MANIFEST');
  }
  if (!Array.isArray(manifest.resources) ||
      !manifest.resources.includes('search') || !manifest.resources.includes('stream')) {
    fail('MISSING_SEARCH_OR_STREAM');
  }
  if (manifest.contentType && manifest.contentType !== 'music') fail('NOT_MUSIC');
  const catalogs = Array.isArray(manifest.catalogs) ? manifest.catalogs : [];
  return {
    search: true, stream: true,
    catalogDeclared: manifest.resources.includes('catalog'),
    musicCatalogRows: catalogs.filter(c => ['track', 'album', 'artist', 'playlist'].includes(c?.type)).length,
    // Polyfin creates a "My music" library for addons that support search.
    synthesizedMyMusic: true,
  };
}

export function inspectStream(stream) {
  if (!stream || typeof stream !== 'object') fail('INVALID_STREAM');
  let url;
  try { url = new URL(stream.url); } catch { fail('INVALID_STREAM_URL'); }
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) fail('INVALID_STREAM_URL');
  return {
    hostname: url.hostname, // No path, query or token ever printed.
    scheme: url.protocol.replace(':', ''),
    format: typeof stream.format === 'string' ? stream.format : null,
    quality: typeof stream.quality === 'string' ? stream.quality : null,
    expiring: stream.expiresAt != null,
  };
}

async function loadSecretFile(envKey) {
  const path = process.env[envKey];
  if (!path) fail('MISSING_' + envKey);
  const value = (await readFile(path, 'utf8')).trim();
  if (!value) fail('EMPTY_' + envKey);
  return value;
}

async function fetchJSON(url, init = {}) {
  const response = await fetch(url, {
    ...init,
    redirect: 'error',
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (!response.ok) fail('HTTP_' + response.status);
  const size = Number(response.headers.get('content-length') || '0');
  if (size > 1_048_576) fail('RESPONSE_TOO_LARGE');
  const body = await response.text();
  if (body.length > 1_048_576) fail('RESPONSE_TOO_LARGE');
  try { return JSON.parse(body); } catch { fail('INVALID_JSON'); }
}

export async function run() {
  const apply = process.argv.includes('--apply');
  if (process.argv.slice(2).some(arg => arg !== '--apply')) fail('UNKNOWN_FLAG');
  const manifestURL = validateManifestURL(await loadSecretFile('POLYFIN_NEBULA_URL_FILE'));
  const manifest = await fetchJSON(manifestURL);
  const summary = inspectManifest(manifest);
  process.stdout.write('NEBULA_MANIFEST_PASS ' + JSON.stringify(summary) + '\n');
  if (!apply) {
    process.stdout.write('NEBULA_INSTALL=NOT_EXECUTED (use --apply with an authorized admin session)\n');
    return;
  }
  if (process.env.POLYFIN_APPLY_NEBULA !== 'YES') fail('EXPLICIT_APPLY_APPROVAL_REQUIRED');
  const cookie = await loadSecretFile('POLYFIN_ADMIN_COOKIE_FILE');
  if (cookie.includes('\n') || cookie.includes('\r')) fail('INVALID_COOKIE_FILE');
  const endpoint = polyfinURL + '/admin/api/scopes/shared/addons';
  const installed = await fetchJSON(endpoint, { headers: { Cookie: cookie } });
  if (!Array.isArray(installed)) fail('UNEXPECTED_INSTALLED_LIST');
  if (installed.some(item => item?.kind === 'eclipse' && /nebula/i.test(item?.name || ''))) {
    process.stdout.write('NEBULA_INSTALL=ALREADY_PRESENT\n');
    return;
  }
  const created = await fetchJSON(endpoint, {
    method: 'POST',
    headers: { Cookie: cookie, 'Content-Type': 'application/json' },
    body: JSON.stringify({ manifestUrl: manifestURL }),
  });
  if (created.kind !== 'eclipse') fail('UNEXPECTED_ADDON_KIND');
  process.stdout.write('NEBULA_INSTALL=PASS ' +
    JSON.stringify({ kind: created.kind, enabledLibraries: created.enabledLibraries ?? null,
      catalogCount: created.catalogCount ?? null }) + '\n');
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  run().catch(error => {
    // Never print fetch error strings or untrusted remote content: URLs may contain tokens.
    const known = new Set(['INVALID_URL', 'UNSAFE_URL', 'UNREVIEWED_HOST', 'NOT_MANIFEST_URL',
      'INVALID_MANIFEST', 'MISSING_SEARCH_OR_STREAM', 'NOT_MUSIC', 'INVALID_STREAM',
      'INVALID_STREAM_URL', 'RESPONSE_TOO_LARGE', 'INVALID_JSON', 'INVALID_COOKIE_FILE',
      'UNEXPECTED_INSTALLED_LIST', 'UNEXPECTED_ADDON_KIND', 'UNKNOWN_FLAG',
      'EXPLICIT_APPLY_APPROVAL_REQUIRED']);
    const reason = typeof error?.message === 'string' && 
      (known.has(error.message) || /^HTTP_[0-9]{3}$/.test(error.message) ||
        /^(MISSING|EMPTY)_POLYFIN_/.test(error.message))
      ? error.message : 'NETWORK_OR_RUNTIME_ERROR';
    process.stderr.write('NEBULA_PILOT_BLOCKED=' + reason + '\n');
    process.exitCode = 1;
  });
}
