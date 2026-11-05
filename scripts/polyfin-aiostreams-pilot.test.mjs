import test from 'node:test';
import assert from 'node:assert/strict';
import { validateAIOStreamsURL, localPreflightURL, inspectStremioManifest, existingAddonCheck, createdAddonOK, run } from './polyfin-aiostreams-pilot.mjs';

const allowed = 'https://aiostreams.smadja.dev/opaque-user/manifest.json';
const internal = 'http://aiostreams.media.svc.cluster.local/opaque-user/manifest.json';
test('converts legacy public input to private Service URL, without public requests',()=>{
  assert.equal(validateAIOStreamsURL(allowed), internal);
  assert.equal(validateAIOStreamsURL(internal), internal);
  assert.equal(localPreflightURL(internal), 'http://127.0.0.1:13000/opaque-user/manifest.json');
  const withToken = 'https://aiostreams.smadja.dev/opaque/manifest.json?key=private';
  assert.equal(validateAIOStreamsURL(withToken),
    'http://aiostreams.media.svc.cluster.local/opaque/manifest.json?key=private');
  assert.equal(localPreflightURL(validateAIOStreamsURL(withToken)),
    'http://127.0.0.1:13000/opaque/manifest.json?key=private');
});
test('refuses arbitrary hosts, protocols, ports, userinfo and fragments',()=>{
  for (const input of [
    'http://aiostreams.smadja.dev/opaque-user/manifest.json',
    'https://aiostreams.media.svc.cluster.local/opaque-user/manifest.json',
    'http://aiostreams.media.svc.cluster.local:3000/opaque-user/manifest.json',
    'http://evil.svc.cluster.local/opaque-user/manifest.json',
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
  assert.equal(existingAddonCheck([{kind:'stremio',id:'local-polyfin-uuid',
    name:'AIOStreams',manifestUrl:'REDACTED'}],movie),'EXISTING_ADDON_REVIEW_PROFILE');
  assert.equal(existingAddonCheck([{kind:'stremio',name:'AIOStreams family profile'}],
    movie),'EXISTING_ADDON_REVIEW_PROFILE');
  assert.equal(existingAddonCheck([{kind:'eclipse',name:'AIOStreams'}],movie),'ABSENT');
  assert.equal(existingAddonCheck([],movie),'ABSENT');
  assert.throws(()=>existingAddonCheck({},movie));
});
test('refuses unknown CLI flags before any secret or network access',async()=>{
  await assert.rejects(()=>run(['--unsafe']),/UNKNOWN_FLAG/);
});

test('native Polyfin returns a local addon UUID distinct from manifest ID',()=>{
  assert.equal(createdAddonOK({kind:'stremio',id:'polyfin-local-uuid',name:'AIOStreams'},movie),true);
  assert.equal(createdAddonOK({kind:'eclipse',id:'local',name:'AIOStreams'},movie),false);
  assert.equal(createdAddonOK({kind:'stremio',id:'local',name:'Another'},movie),false);
});
