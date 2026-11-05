#!/usr/bin/env node
// PLT: Admit an existing AIOStreams Stremio manifest into Polyfin 0.60.
// No signed manifest URL, auth token, provider response or session cookie
// may be written to stdout, stderr, argv, Git or Linear.
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
import { authorizedAdminCookie } from './polyfin-nebula-pilot.mjs';

const origin = 'https://media.smadja.dev';
const timeout = 15_000;
function fail(code) { throw new Error(code); }

export function validateAIOStreamsURL(value) {
  let url;
  try { url = new URL(String(value).trim()); } catch { fail('INVALID_MANIFEST_URL'); }
  if (url.protocol !== 'https:' || url.hostname !== 'aiostreams.smadja.dev' ||
      url.port || url.username || url.password || url.hash ||
      !url.pathname.endsWith('/manifest.json')) fail('UNREVIEWED_MANIFEST_URL');
  return url.toString();
}

export function inspectStremioManifest(m) {
  if (!m || Array.isArray(m) || typeof m !== 'object' ||
      typeof m.id !== 'string' || !m.id.trim() ||
      typeof m.name !== 'string' || !m.name.trim() ||
      typeof m.version !== 'string' || !m.version.trim())
    fail('INVALID_STREMIO_MANIFEST');
  const resources = Array.isArray(m.resources)
    ? m.resources.map(r => typeof r === 'string' ? r : r?.name) : [];
  const types = Array.isArray(m.types) ? m.types : [];
  if (!resources.includes('stream') || !types.some(t => t === 'movie' || t === 'series'))
    fail('MISSING_VIDEO_STREAM_RESOURCE');
  const catalogs = Array.isArray(m.catalogs) ? m.catalogs : [];
  return {
    resourceStream: true,
    resourceMeta: resources.includes('meta'),
    resourceCatalog: resources.includes('catalog'),
    movies: types.includes('movie'),
    series: types.includes('series'),
    videoCatalogs: catalogs.filter(c => c && ['movie','series'].includes(c.type)).length,
    // A stream-only addon may need another metadata addon for catalogs.
    requiresCatalogQualification: !catalogs.some(c => c && ['movie','series'].includes(c.type))
  };
}

async function loadFile(name) {
  const path = process.env[name];
  if (!path) fail('MISSING_MANIFEST_FILE');
  const value = (await readFile(path, 'utf8')).trim();
  if (!value || value.length > 8_192) fail('INVALID_MANIFEST_FILE');
  return value;
}

async function jsonRequest(url, options={}) {
  const r = await fetch(url, {
    ...options, redirect:'error', signal:AbortSignal.timeout(timeout)
  });
  if (!r.ok) fail('HTTP_' + r.status);
  const size = Number(r.headers.get('content-length') || 0);
  if (size > 1_048_576) fail('RESPONSE_TOO_LARGE');
  const text = await r.text();
  if (text.length > 1_048_576) fail('RESPONSE_TOO_LARGE');
  try { return JSON.parse(text); } catch { fail('INVALID_JSON'); }
}

export function existingAddonCheck(rows, manifest) {
  if (!Array.isArray(rows)) fail('INVALID_INSTALLED_ADDONS');
  // IDs alone cannot prove that a tokenized AIOStreams profile has the same
  // URL. If occupied, refuse to silently overwrite or duplicate it.
  return rows.some(a => a?.kind === 'stremio' && a?.id === manifest.id)
    ? 'EXISTING_ADDON_ID_REVIEW_PROFILE' : 'ABSENT';
}

export async function run(argv=process.argv.slice(2)) {
  if (argv.some(a => a !== '--apply') || argv.filter(a => a === '--apply').length > 1)
    fail('UNKNOWN_FLAG');
  const apply = argv.includes('--apply');
  const manifestURL = validateAIOStreamsURL(await loadFile('POLYFIN_AIOSTREAMS_MANIFEST_URL_FILE'));
  const manifest = await jsonRequest(manifestURL);
  const summary = inspectStremioManifest(manifest);
  process.stdout.write('AIOSTREAMS_MANIFEST_PASS ' + JSON.stringify(summary) + '\n');
  if (!apply) {
    process.stdout.write('AIOSTREAMS_INSTALL=NOT_EXECUTED\n');
    return;
  }
  if (process.env.POLYFIN_APPLY_AIOSTREAMS !== 'YES') fail('EXPLICIT_APPLY_APPROVAL_REQUIRED');
  // Same credential-file/cookie modes used by the already-qualified Nebula
  // native admin session; it verifies isAdministrator=true.
  const cookie = await authorizedAdminCookie();
  const endpoint = origin + '/admin/api/scopes/shared/addons';
  const present = await jsonRequest(endpoint, {headers:{Cookie:cookie}});
  const state = existingAddonCheck(present, manifest);
  if (state !== 'ABSENT') {
    process.stdout.write('AIOSTREAMS_INSTALL=' + state + '\n');
    return;
  }
  const created = await jsonRequest(endpoint, {
    method:'POST',
    headers:{Cookie:cookie, 'Content-Type':'application/json'},
    body:JSON.stringify({manifestUrl:manifestURL})
  });
  if (created?.kind !== 'stremio' || created?.id !== manifest.id) fail('UNEXPECTED_CREATED_ADDON');
  process.stdout.write('AIOSTREAMS_INSTALL=PASS ' + JSON.stringify({
    kind:'stremio', catalogCount:Number(created.catalogCount ?? 0),
    enabledLibraries:created.enabledLibraries ?? null,
    libraryLimit:created.libraryLimit ?? null
  }) + '\n');
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  run().catch(err=>{
    const m=String(err?.message || '');
    const known=new Set([
      'INVALID_MANIFEST_URL','UNREVIEWED_MANIFEST_URL','INVALID_STREMIO_MANIFEST',
      'MISSING_VIDEO_STREAM_RESOURCE','MISSING_MANIFEST_FILE','INVALID_MANIFEST_FILE',
      'INVALID_INSTALLED_ADDONS','RESPONSE_TOO_LARGE','INVALID_JSON','UNKNOWN_FLAG',
      'EXPLICIT_APPLY_APPROVAL_REQUIRED','UNEXPECTED_CREATED_ADDON'
    ]);
    const code=known.has(m) || /^HTTP_[0-9]{3}$/.test(m)
      ? m : (err?.name === 'TimeoutError' || err?.name === 'AbortError')
        ? 'TIMEOUT_15S' : 'NETWORK_OR_AUTH_ERROR';
    process.stderr.write('AIOSTREAMS_PILOT_BLOCKED=' + code + '\n');
    process.exitCode=1;
  });
}
