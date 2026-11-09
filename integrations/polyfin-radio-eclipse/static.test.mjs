import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const file = async path => JSON.parse(await readFile(new URL(path, import.meta.url), 'utf8'));
const expected = ['fip', 'fip-cultes', 'fip-sacre-francais', 'fip-groove', 'fip-rock', 'fip-jazz', 'fip-reggae', 'fip-pop', 'fip-electro', 'fip-monde', 'fip-nouveautes', 'fip-hip-hop', 'fip-metal', 'france-inter', 'france-info', 'france-musique', 'mouv'];

test('static Eclipse manifest needs only catalog and creates no extra My music library', async () => {
  const m = await file('./static/manifest.json');
  assert.equal(m.contentType, 'music');
  assert.deepEqual(m.resources, ['catalog']);
  assert.deepEqual(m.catalogs, [{ id:'stations', type:'track', name:'Radio' }]);
  assert.equal(m.id, 'dev.smadja.radio-france');
  assert.equal(m.version, '0.2.0');
  assert.ok(m.name);
});

test('all 13 FIP feeds and 4 other Radio France stations use direct HTTPS MP3', async () => {
  const catalog = await file('./static/catalog/stations');
  assert.deepEqual(catalog.items.map(t => t.id), expected);
  assert.equal(new Set(catalog.items.map(x => x.id)).size, 17);
  assert.equal(catalog.items.filter(t => t.id.startsWith('fip')).length, 13);
  for (const t of catalog.items) {
    assert.equal(t.type, 'track');
    assert.equal(t.format, 'mp3');
    assert.equal(t.artist, 'Radio France');
    assert.equal(t.album, 'Radios en direct');
    const url = new URL(t.streamURL);
    assert.equal(url.protocol, 'https:');
    assert.equal(url.hostname, 'icecast.radiofrance.fr');
    assert.match(url.pathname, /^\/[a-z0-9-]+\.mp3$/);
    assert.equal(url.searchParams.get('id'), 'openapi');
    assert.equal(t.duration, undefined);
    assert.equal(t.isrc, undefined);
  }
});

test('each station has a self-hosted valid PNG thumbnail, not a third-party image hotlink', async () => {
  const catalog = await file('./static/catalog/stations');
  for (const t of catalog.items) {
    const imageUrl = new URL(t.artworkURL);
    assert.equal(imageUrl.origin, 'https://raw.githubusercontent.com');
    assert.equal(imageUrl.pathname, `/SmadjaPaul/kube-ops/main/integrations/polyfin-radio-eclipse/static/artwork/${t.id}.png`);
    const data = await readFile(new URL(`./static/artwork/${t.id}.png`, import.meta.url));
    assert.ok(data.subarray(0, 8).equals(Buffer.from([137,80,78,71,13,10,26,10])));
    assert.equal(data.readUInt32BE(16), 192);
    assert.equal(data.readUInt32BE(20), 192);
    assert.ok(data.length > 1000 && data.length < 100_000);
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
