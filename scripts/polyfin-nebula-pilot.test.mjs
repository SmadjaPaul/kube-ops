import test from 'node:test';
import assert from 'node:assert/strict';
import { validateManifestURL, inspectManifest, inspectStream } from './polyfin-nebula-pilot.mjs';

const good = 'https://nebula.eclipsemusic.app/private-token/manifest.json';
test('accepts an HTTPS tokenized URL without printing it', () => {
  assert.equal(validateManifestURL(good), good);
});
test('refuses unreviewed endpoints and unsafe manifest URLs', () => {
  for (const value of [
    'http://nebula.eclipsemusic.app/token/manifest.json',
    'https://attacker.invalid/token/manifest.json',
    'https://nebula.eclipsemusic.app/token/search',
    'https://user:pass@nebula.eclipsemusic.app/token/manifest.json',
    'https://nebula.eclipsemusic.app/token/manifest.json#fragment',
  ]) assert.throws(() => validateManifestURL(value));
});
test('requires Eclipse music search and stream, permits no catalog rows', () => {
  const info = inspectManifest({id:'nebula.test',name:'Nebula',version:'1.0.0',
    resources:['search','stream'], contentType:'music'});
  assert.equal(info.synthesizedMyMusic, true);
  assert.equal(info.musicCatalogRows, 0);
  assert.equal(info.catalogDeclared, false);
  assert.throws(() => inspectManifest({id:'x',name:'x',version:'1',resources:['search']}));
  assert.throws(() => inspectManifest({id:'x',name:'x',version:'1',
    resources:['search','stream'],contentType:'audiobook'}));
});
test('counts only supported catalog types', () => {
  assert.equal(inspectManifest({id:'x',name:'x',version:'1',
    resources:['search','stream','catalog'],
    catalogs:[{type:'track'},{type:'playlist'},{type:'unknown'}]}).musicCatalogRows, 2);
});
test('shows CDN host and format, never signed path or query', () => {
  const info = inspectStream({url:'https://cdn.torbox.test/secret-file?key=private',
    format:'flac', quality:'lossless', expiresAt:1893456000});
  assert.deepEqual(info, {hostname:'cdn.torbox.test',scheme:'https',
    format:'flac',quality:'lossless',expiring:true});
  assert.equal(JSON.stringify(info).includes('private'), false);
  assert.equal(JSON.stringify(info).includes('secret-file'), false);
});
