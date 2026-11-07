import test from 'node:test';
import assert from 'node:assert/strict';
import { auditLibraries, catalogKind } from './polyfin-library-layout-audit.mjs';

const a = (name, type, id) => ({ name, catalogType: type, catalogId: id,
  addonId: 'addon-private-uuid', hideInMenus: false,
  manifestUrl: 'https://secret.example/manifest.json?token=never-print',
  opaqueCredential: 'DO-NOT-PRINT' });

test('catalog type mapping distinguishes video, Live TV, music and collections', () => {
  assert.equal(catalogKind('movie'), 'movies');
  assert.equal(catalogKind('anime.movie'), 'movies');
  assert.equal(catalogKind('series'), 'series');
  assert.equal(catalogKind('anime.series'), 'series');
  assert.equal(catalogKind('tv'), 'live-tv');
  assert.equal(catalogKind('collection'), 'collection');
  assert.equal(catalogKind('track'), 'other');
});

test('repeated catalogs are reported without modification or source credentials', () => {
  const result = auditLibraries([
    a('Popular', 'movie', 'popular'), a('Populaire', 'movie', 'popular-fr'),
    a('Popular', 'series', 'series'), a('Radio France', 'tv', 'radio'),
  ]);
  assert.equal(result.readonly, true);
  assert.equal(result.navigation.movieLibraryAmbiguous, true);
  assert.equal(result.navigation.seriesLibraryAmbiguous, false);
  assert.equal(result.groups['live-tv'].length, 1);
  const output = JSON.stringify(result);
  assert.doesNotMatch(output, /secret|DO-NOT-PRINT|manifest\.json|addon-private-uuid/i);
  assert.deepEqual(result.groups.movies.map(x => x.name), ['Popular', 'Populaire']);
});

test('hidden-in-menu status is not conflated with disabled library', () => {
  const r = a('Year', 'movie', 'year');
  r.hideInMenus = true;
  const out = auditLibraries([r]);
  assert.equal(out.groups.movies[0].hiddenFromMenu, true);
  assert.match(out.navigation.recommendation, /home rows/);
});

test('synthesized music and local libraries without catalog ID remain inventoriable', () => {
  const out = auditLibraries([{ name: 'Ma musique', kind: 'music', addonId: 'some-id' }]);
  assert.equal(out.groups.other.length, 1);
  assert.equal(out.groups.other[0].catalog, null);
});

test('malformed rows and response are rejected fail closed', () => {
  assert.throws(() => auditLibraries({ libraries: [] }), /INVALID_LIBRARIES_RESPONSE/);
  assert.throws(() => auditLibraries([{}]), /INVALID_LIBRARY_ROW/);
});
