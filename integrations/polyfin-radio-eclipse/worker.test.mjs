import test from 'node:test';
import assert from 'node:assert/strict';
import worker from './worker.mjs';
async function req(path,method='GET') {
  const res=await worker.fetch(new Request('https://example.workers.dev'+path,{method}));
  const body=method==='HEAD'||res.status===204?null:await res.json();
  return {res,body};
}
test('Eclipse manifest exposes a distinct music addon with a Radio catalog',async()=>{
  const {res,body}=await req('/manifest.json');
  assert.equal(res.status,200);
  assert.equal(body.id,'dev.smadja.radio-france');
  assert.equal(body.contentType,'music');
  assert.ok(body.resources.includes('catalog'));
  assert.deepEqual(body.catalogs,[{id:'stations',type:'track',name:'Radios'}]);
});
test('eight playable station records and no invented finite duration or ISRC',async()=>{
  const {body}=await req('/catalog/stations?skip=0');
  assert.equal(body.items.length,8);
  assert.equal(new Set(body.items.map(x=>x.id)).size,8);
  for(const t of body.items){
    assert.equal(t.type,'track');
    assert.equal(t.artist,'Radio France');
    assert.equal(t.duration,undefined);
    assert.equal(t.isrc,undefined);
  }
  assert.deepEqual((await req('/catalog/stations?skip=100')).body.items,[]);
  assert.equal((await req('/catalog/stations?skip=1')).res.status,400);
});
test('search respects query while listing radio names',async()=>{
  assert.equal((await req('/search?q=FIP')).body.tracks.length,4);
  assert.deepEqual((await req('/search?q=france%20musique')).body.tracks.map(x=>x.id),['france-musique']);
  assert.deepEqual((await req('/search?q=nobody')).body.tracks,[]);
});
test('stream endpoint serves only fixed official MP3 radio URLs',async()=>{
  const {body}=await req('/stream/fip');
  assert.equal(body.codec,'mp3');
  assert.equal(body.container,'mp3');
  assert.equal(body.manifest,'none');
  assert.ok(body.url.startsWith('https://icecast.radiofrance.fr/fip-'));
  assert.equal((await req('/stream/unknown')).res.status,404);
  assert.equal((await req('/stream/https:%2f%2fexample.com')).res.status,404);
});
test('CORS, HEAD, OPTIONS, method and secret-safety contract',async()=>{
  assert.equal((await req('/search?q=FIP')).res.headers.get('access-control-allow-origin'),'*');
  assert.equal((await req('/stream/fip','POST')).res.status,405);
  assert.equal((await req('/manifest.json','HEAD')).res.status,200);
  assert.equal((await req('/manifest.json','OPTIONS')).res.status,204);
  assert.doesNotMatch(JSON.stringify((await req('/search')).body),/torbox|secret|token/i);
});