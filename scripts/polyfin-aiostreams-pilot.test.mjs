import test from 'node:test';
import assert from 'node:assert/strict';
import { validateAIOStreamsURL, inspectStremioManifest, existingAddonCheck, run } from './polyfin-aiostreams-pilot.mjs';

const allowed='https://aiostreams.smadja.dev/opaque-user/manifest.json';
test('accepts only reviewed private AIOStreams endpoint',()=>{
  assert.equal(validateAIOStreamsURL(allowed),allowed);
  for (const input of [
    'http://aiostreams.smadja.dev/opaque-user/manifest.json',
    'https://evil.test/opaque-user/manifest.json',
    'https://aiostreams.smadja.dev.evil.test/manifest.json',
    'https://user:pw@aiostreams.smadja.dev/manifest.json',
    'https://aiostreams.smadja.dev:8443/manifest.json',
    'https://aiostreams.smadja.dev/manifest.json#fragment',
    'https://aiostreams.smadja.dev/stream/movie/tt1.json'
  ]) assert.throws(()=>validateAIOStreamsURL(input));
});
const movie={
  id:'com.aiostreams',name:'AIOStreams',version:'2.37.0',
  resources:[{name:'catalog'},'meta','stream'],types:['movie','series'],
  catalogs:[{type:'movie',id:'trending'},{type:'series',id:'popular'}]
};
test('classifies Stremio video catalog and stream resources',()=>{
  assert.deepEqual(inspectStremioManifest(movie),{
    resourceStream:true,resourceMeta:true,resourceCatalog:true,
    movies:true,series:true,videoCatalogs:2,requiresCatalogQualification:false
  });
  assert.equal(inspectStremioManifest({...movie,catalogs:[]}).requiresCatalogQualification,true);
  assert.throws(()=>inspectStremioManifest({...movie,resources:['meta']}));
  assert.throws(()=>inspectStremioManifest({...movie,types:['music']}));
  assert.throws(()=>inspectStremioManifest({id:'x'}));
});
test('refuses replacing an existing profile by ID, even if token differs',()=>{
  assert.equal(existingAddonCheck([{kind:'stremio',id:'com.aiostreams',
    manifestUrl:'REDACTED'}],movie),'EXISTING_ADDON_ID_REVIEW_PROFILE');
  assert.equal(existingAddonCheck([{kind:'eclipse',id:'com.aiostreams'}],movie),'ABSENT');
  assert.equal(existingAddonCheck([],movie),'ABSENT');
  assert.throws(()=>existingAddonCheck({},movie));
});
test('refuses unknown CLI flags before any secret or network access',async()=>{
  await assert.rejects(()=>run(['--unsafe']),/UNKNOWN_FLAG/);
});
