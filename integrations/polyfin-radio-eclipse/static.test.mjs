import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const file = async path => JSON.parse(await readFile(new URL(path, import.meta.url), 'utf8'));

test('static Eclipse manifest needs only catalog and creates no extra My music library', async () => {
  const m = await file('./static/manifest.json');
  assert.equal(m.contentType, 'music');
  assert.deepEqual(m.resources, ['catalog']);
  assert.deepEqual(m.catalogs, [{ id:'stations', type:'track', name:'Radio' }]);
  assert.equal(m.id, 'dev.smadja.radio-france');
  assert.ok(m.name);
});
test('eight fixed Radio France stations have native direct MP3 URLs', async () => {
  const catalog = await file('./static/catalog/stations');
  assert.equal(catalog.items.length, 8);
  assert.equal(new Set(catalog.items.map(x => x.id)).size, 8);
  for (const t of catalog.items) {
    assert.equal(t.type, 'track');
    assert.equal(t.format, 'mp3');
    assert.equal(t.artist, 'Radio France');
    const url = new URL(t.streamURL);
    assert.equal(url.protocol, 'https:');
    assert.equal(url.hostname, 'icecast.radiofrance.fr');
    assert.match(url.pathname, /^\/[a-z0-9-]+\.mp3$/);
    assert.equal(url.searchParams.get('id'), 'openapi');
    assert.equal(t.duration, undefined);
    assert.equal(t.isrc, undefined);
  }
});
test('the static payload has no server endpoints, cookies, credentials or code', async () => {
  const manifest = await file('./static/manifest.json');
  const catalog = await file('./static/catalog/stations');
  assert.doesNotMatch(JSON.stringify([manifest,catalog]), /torbox|authorization|cookie|accessKey|secretKey|API_KEY/i);
  assert.equal(manifest.resources.includes('search'), false);
  assert.equal(manifest.resources.includes('stream'), false);
  assert.ok(catalog.items.every(x=>typeof x.streamURL === 'string'));
});
