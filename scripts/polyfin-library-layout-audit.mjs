#!/usr/bin/env node
// Read-only audit for Polyfin's server-side Stremio catalog libraries.
// Never print an addon manifest address, tokens, cookies or arbitrary source JSON.
import { createHash } from 'node:crypto';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const API = 'https://media.smadja.dev/admin/api/scopes/shared/libraries';
const MOVIES = new Set(['movie', 'anime.movie']);
const SERIES = new Set(['series', 'anime.series']);
const timeout = 15000;

export function catalogKind(type) {
  if (MOVIES.has(type)) return 'movies';
  if (SERIES.has(type)) return 'series';
  if (type === 'tv') return 'live-tv';
  if (type === 'anime') return 'mixed-anime';
  if (type === 'collection') return 'collection';
  return 'other';
}

function safeName(value) {
  if (typeof value !== 'string') return '(unnamed)';
  return value.replace(/https?:\/\/\S+|\b[A-Za-z0-9_-]{32,}\b/gi, '[redacted]')
    .replace(/[\r\n\x00-\x1f]/g, ' ').trim().slice(0, 80) || '(unnamed)';
}

function fingerprint(value) {
  return createHash('sha256').update(String(value ?? '')).digest('hex').slice(0, 12);
}

export function auditLibraries(rows) {
  if (!Array.isArray(rows)) throw new Error('INVALID_LIBRARIES_RESPONSE');
  if (rows.length > 250) throw new Error('TOO_MANY_LIBRARIES');
  const libraries = rows.map((r, index) => {
    if (!r || typeof r !== 'object' || Array.isArray(r) || typeof r.name !== 'string')
      throw new Error('INVALID_LIBRARY_ROW');
    // Local folders and synthesized music libraries can have no catalog id.
    const type = typeof r.catalogType === 'string' ? r.catalogType : 'unspecified';
    const kind = catalogKind(type);
    return {
      position: index + 1,
      name: safeName(r.name),
      kind,
      catalogType: safeName(type),
      source: typeof r.addonId === 'string' ? fingerprint(r.addonId) : null,
      catalog: typeof r.catalogId === 'string'
        ? fingerprint([r.addonId, type, r.catalogId].join('\0')) : null,
      hiddenFromMenu: r.hideInMenus === true,
      showAs: typeof r.showAs === 'string' ? r.showAs : null,
    };
  });
  const groups = Object.fromEntries(['movies', 'series', 'mixed-anime', 'collection', 'live-tv', 'other']
    .map(kind => [kind, libraries.filter(r => r.kind === kind)]));
  return {
    readonly: true,
    count: libraries.length,
    groups,
    navigation: {
      candidateMovies: groups.movies.map(({ name, catalog, hiddenFromMenu }) => ({ name, catalog, hiddenFromMenu })),
      candidateSeries: groups.series.map(({ name, catalog, hiddenFromMenu }) => ({ name, catalog, hiddenFromMenu })),
      movieLibraryAmbiguous: groups.movies.length !== 1,
      seriesLibraryAmbiguous: groups.series.length !== 1,
      recommendation: 'Choose one primary movie and one primary series catalog by coverage; disabling other catalog libraries removes their home rows without uninstalling the addon. Hiding them only from menus retains home rows.',
      limitation: 'Smart Lists may aggregate catalogs but have their own sort and do not expose the library native genre filter. A full union with all native filters needs upstream support.'
    }
  };
}

async function run() {
  if (process.argv.slice(2).length) throw new Error('READ_ONLY_NO_FLAGS');
  const { authorizedAdminCookie } = await import('./polyfin-nebula-pilot.mjs');
  const cookie = await authorizedAdminCookie();
  const response = await fetch(API, {
    headers: { Cookie: cookie }, redirect: 'error', signal: AbortSignal.timeout(timeout)
  });
  if (!response.ok) throw new Error('HTTP_' + response.status);
  const length = Number(response.headers.get('content-length') || 0);
  if (length > 2_000_000) throw new Error('RESPONSE_TOO_LARGE');
  const body = await response.text();
  if (body.length > 2_000_000) throw new Error('RESPONSE_TOO_LARGE');
  let rows;
  try { rows = JSON.parse(body); } catch { throw new Error('INVALID_JSON'); }
  process.stdout.write(JSON.stringify(auditLibraries(rows), null, 2) + '\n');
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  run().catch(err => {
    const known = new Set(['READ_ONLY_NO_FLAGS', 'INVALID_LIBRARIES_RESPONSE',
      'TOO_MANY_LIBRARIES', 'INVALID_LIBRARY_ROW', 'HTTP_401', 'HTTP_403',
      'HTTP_404', 'INVALID_JSON', 'RESPONSE_TOO_LARGE']);
    process.stderr.write('POLYFIN_LIBRARY_AUDIT=BLOCKED ' +
      (known.has(err?.message) ? err.message : 'AUTH_OR_RUNTIME_ERROR') + '\n');
    process.exitCode = 1;
  });
}
