import test from 'node:test';
import assert from 'node:assert/strict';
import { validateManifestURL, inspectManifest, inspectStream, sessionCookie, selectSearchTrack } from './polyfin-nebula-pilot.mjs';

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
test('accepts Eclipse resource objects like upstream Polyfin', () => {
  assert.equal(inspectManifest({id:'x',name:'x',version:'1',
    resources:[{name:'search'}, {name:'stream'}]}).search, true);
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

test('selects the exact Eclipse track and rejects Polyfin-shaped or ambiguous rows', () => {
  const track = selectSearchTrack({tracks: [
    {id:'wrong', title:'One More Time', artist:'Other Artist'},
    {id:'eclipse-raw-id', title:'One More Time', artist:'Daft Punk'},
  ]}, {title:'One More Time', artist:'Daft Punk'});
  assert.deepEqual(track, {id:'eclipse-raw-id', title:'One More Time', artist:'Daft Punk'});
  assert.throws(() => selectSearchTrack({tracks:[{id:'polyfin-uuid',Name:'One More Time'}]},
    {title:'One More Time', artist:'Daft Punk'}), /SEARCH_TRACK_NOT_FOUND/);
});

test('extracts only the official native Polyfin session cookie', () => {
  assert.equal(sessionCookie('polyfin_session=OpaqueSecret123; Path=/admin; HttpOnly; Secure; SameSite=Strict'),
    'polyfin_session=OpaqueSecret123');
  for (const header of [null, '', 'other_cookie=123; Path=/admin',
    'polyfin_session=bad\nX-Other: true']) assert.throws(() => sessionCookie(header));
});
