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
  const resources = Array.isArray(manifest.resources)
    ? manifest.resources.map(resource => typeof resource === 'string' ? resource : resource?.name)
    : [];
  if (!resources.includes('search') || !resources.includes('stream')) fail('MISSING_SEARCH_OR_STREAM');
  if (manifest.contentType && manifest.contentType !== 'music') fail('NOT_MUSIC');
  const catalogs = Array.isArray(manifest.catalogs) ? manifest.catalogs : [];
  return {
    search: true, stream: true,
    catalogDeclared: resources.includes('catalog'),
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

export function selectSearchTrack(payload, { title, artist }) {
  const tracks = Array.isArray(payload?.tracks) ? payload.tracks : [];
  const match = tracks.find(track =>
    track && track.title === title && track.artist === artist &&
    typeof track.id === 'string' && track.id.trim());
  if (!match) fail('SEARCH_TRACK_NOT_FOUND');
  return match;
}

async function searchAndResolve(manifestURL) {
  const baseURL = manifestURL.slice(0, -'manifest.json'.length);
  const searchURL = baseURL + 'search?q=' + encodeURIComponent('Daft Punk');
  const searchStarted = performance.now();
  const search = await fetchJSON(searchURL);
  const track = selectSearchTrack(search, { title: 'One More Time', artist: 'Daft Punk' });
  const streamURL = baseURL + 'stream/' + encodeURIComponent(track.id);
  const streamStarted = performance.now();
  const stream = await fetchJSON(streamURL);
  return {
    trackTitle: track.title,
    trackArtist: track.artist,
    searchLatencyMs: Math.round(performance.now() - searchStarted),
    stream: { ...inspectStream(stream), latencyMs: Math.round(performance.now() - streamStarted) },
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

// Native Polyfin 0.60 login returns an HttpOnly cookie. Keep it in memory only.
export function sessionCookie(setCookie) {
  if (typeof setCookie !== 'string') fail('ADMIN_SESSION_COOKIE_MISSING');
  const part = setCookie.split(';', 1)[0];
  if (!/^polyfin_session=[A-Za-z0-9._~+/=-]+$/.test(part)) fail('ADMIN_SESSION_COOKIE_MISSING');
  return part;
}

export async function authorizedAdminCookie() {
  const cookieFile = process.env.POLYFIN_ADMIN_COOKIE_FILE;
  const userFile = process.env.POLYFIN_ADMIN_USERNAME_FILE;
  const passwordFile = process.env.POLYFIN_ADMIN_PASSWORD_FILE;
  if (cookieFile && (userFile || passwordFile)) fail('AMBIGUOUS_ADMIN_AUTH');
  let cookie;
  if (cookieFile) {
    cookie = await loadSecretFile('POLYFIN_ADMIN_COOKIE_FILE');
    if (cookie.includes('\n') || cookie.includes('\r') ||
        !/^polyfin_session=[A-Za-z0-9._~+/=-]+$/.test(cookie)) fail('INVALID_COOKIE_FILE');
  } else if (userFile && passwordFile) {
    const name = await loadSecretFile('POLYFIN_ADMIN_USERNAME_FILE');
    const password = await loadSecretFile('POLYFIN_ADMIN_PASSWORD_FILE');
    const response = await fetch(polyfinURL + '/admin/api/session', {
      method: 'POST',
      redirect: 'error',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name, password }),
      signal: AbortSignal.timeout(timeoutMs),
    });
    if (!response.ok) fail('ADMIN_LOGIN_HTTP_' + response.status);
    cookie = sessionCookie(response.headers.get('set-cookie'));
    await response.body?.cancel();
  } else {
    fail('MISSING_ADMIN_AUTH');
  }
  const session = await fetchJSON(polyfinURL + '/admin/api/session', {
    headers: { Cookie: cookie },
  });
  if (session?.user?.isAdministrator !== true) fail('NOT_POLYFIN_ADMIN');
  return cookie;
}

export async function run() {
  const apply = process.argv.includes('--apply');
  const resolveTrack = process.argv.includes('--resolve-track');
  const resolveSearch = process.argv.includes('--resolve-search');
  if (process.argv.slice(2).some(arg => !['--apply', '--resolve-track', '--resolve-search'].includes(arg))) fail('UNKNOWN_FLAG');
  const manifestURL = validateManifestURL(await loadSecretFile('POLYFIN_NEBULA_URL_FILE'));
  const manifest = await fetchJSON(manifestURL);
  const summary = inspectManifest(manifest);
  process.stdout.write('NEBULA_MANIFEST_PASS ' + JSON.stringify(summary) + '\n');
  if (resolveSearch) {
    if (process.env.POLYFIN_RESOLVE_TRACK !== 'YES') fail('EXPLICIT_RESOLVE_APPROVAL_REQUIRED');
    const result = await searchAndResolve(manifestURL);
    process.stdout.write('NEBULA_SEARCH_PASS ' + JSON.stringify({
      title: result.trackTitle, artist: result.trackArtist, latencyMs: result.searchLatencyMs,
    }) + '\n');
    process.stdout.write('NEBULA_STREAM_PASS ' + JSON.stringify(result.stream) + '\n');
  }
  if (resolveTrack) {
    // Explicit only: resolving an uncached track can initiate a TorBox download.
    if (process.env.POLYFIN_RESOLVE_TRACK !== 'YES') fail('EXPLICIT_RESOLVE_APPROVAL_REQUIRED');
    const trackId = await loadSecretFile('POLYFIN_NEBULA_TRACK_ID_FILE');
    if (trackId.length > 500) fail('INVALID_TRACK_ID');
    const streamURL = manifestURL.slice(0, -'manifest.json'.length) +
      'stream/' + encodeURIComponent(trackId);
    const started = performance.now();
    const stream = await fetchJSON(streamURL);
    process.stdout.write('NEBULA_STREAM_PASS ' +
      JSON.stringify({ ...inspectStream(stream), latencyMs: Math.round(performance.now() - started) }) + '\n');
  }
  if (!apply) {
    process.stdout.write('NEBULA_INSTALL=NOT_EXECUTED (use --apply with an authorized admin session)\n');
    return;
  }
  if (process.env.POLYFIN_APPLY_NEBULA !== 'YES') fail('EXPLICIT_APPLY_APPROVAL_REQUIRED');
  const cookie = await authorizedAdminCookie();
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
      'EXPLICIT_APPLY_APPROVAL_REQUIRED', 'EXPLICIT_RESOLVE_APPROVAL_REQUIRED', 'INVALID_TRACK_ID',
      'SEARCH_TRACK_NOT_FOUND', 'ADMIN_SESSION_COOKIE_MISSING', 'AMBIGUOUS_ADMIN_AUTH', 'MISSING_ADMIN_AUTH',
      'NOT_POLYFIN_ADMIN']);
    const reason = error?.name === 'TimeoutError' || error?.name === 'AbortError'
      ? 'ADDON_TIMEOUT_15S'
      : typeof error?.message === 'string' &&
        (known.has(error.message) || /^(HTTP|ADMIN_LOGIN_HTTP)_[0-9]{3}$/.test(error.message) ||
          /^(MISSING|EMPTY)_POLYFIN_/.test(error.message))
        ? error.message : 'NETWORK_OR_RUNTIME_ERROR';
    process.stderr.write('NEBULA_PILOT_BLOCKED=' + reason + '\n');
    process.exitCode = 1;
  });
}
