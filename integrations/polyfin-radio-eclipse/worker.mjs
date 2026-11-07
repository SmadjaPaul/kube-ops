// Stateless Eclipse addon: Radio France live stations as music library rows.
// The Worker serves JSON only. It NEVER fetches or proxies MP3 media bytes.
const stations = Object.freeze([
  ['fip','FIP','https://icecast.radiofrance.fr/fip-midfi.mp3?id=openapi'],
  ['fip-rock','FIP Rock','https://icecast.radiofrance.fr/fiprock-midfi.mp3?id=openapi'],
  ['fip-jazz','FIP Jazz','https://icecast.radiofrance.fr/fipjazz-midfi.mp3?id=openapi'],
  ['fip-electro','FIP Electro','https://icecast.radiofrance.fr/fipelectro-midfi.mp3?id=openapi'],
  ['france-inter','France Inter','https://icecast.radiofrance.fr/franceinter-midfi.mp3?id=openapi'],
  ['france-musique','France Musique','https://icecast.radiofrance.fr/francemusique-midfi.mp3?id=openapi'],
  ['france-info','France Info','https://icecast.radiofrance.fr/franceinfo-midfi.mp3?id=openapi'],
  ['mouv',"Mouv'",'https://icecast.radiofrance.fr/mouv-midfi.mp3?id=openapi']
].map(([id,name,url])=>Object.freeze({id,name,url})));
const lookup = new Map(stations.map(s=>[s.id,s]));
const manifest = Object.freeze({
  id:'dev.smadja.radio-france', name:'Radio France — direct', version:'0.1.0',
  description:'Stations Radio France en direct (MP3), sans proxy ni inscription.',
  contentType:'music', resources:['search','stream','catalog'], types:['track'],
  catalogs:[{id:'stations',type:'track',name:'Radios'}]
});
const headers = Object.freeze({
  'content-type':'application/json; charset=utf-8',
  'access-control-allow-origin':'*',
  'access-control-allow-methods':'GET, HEAD, OPTIONS',
  'cache-control':'public, max-age=60',
  'x-content-type-options':'nosniff'
});
function asTrack(s, catalog=false) {
  // Live stations have no finite duration and no ISRC; never invent either.
  const r = {id:s.id,title:s.name,artist:'Radio France',album:'Radios en direct',format:'mp3'};
  if (catalog) r.type='track';
  return r;
}
function json(obj,status=200,method='GET') {
  return new Response(method==='HEAD'?null:JSON.stringify(obj),{status,headers});
}
export default {
  async fetch(request) {
    const method=request.method;
    if(method==='OPTIONS') return new Response(null,{status:204,headers});
    if(method!=='GET'&&method!=='HEAD') return json({error:'method_not_allowed'},405,method);
    let u;
    try {u=new URL(request.url);} catch {return json({error:'bad_request'},400,method);}
    if(u.pathname==='/healthz') return json({ok:true},200,method);
    if(u.pathname==='/manifest.json') return json(manifest,200,method);
    if(u.pathname==='/search') {
      const q=(u.searchParams.get('q')||'').toLocaleLowerCase('fr').trim().slice(0,120);
      const found=stations.filter(s=>!q||(s.name+' Radio France live direct').toLocaleLowerCase('fr').includes(q));
      return json({tracks:found.map(s=>asTrack(s))},200,method);
    }
    if(u.pathname==='/catalog/stations') {
      const raw=u.searchParams.get('skip')||'0';
      if(!/^\d{1,6}$/.test(raw)||Number(raw)%100!==0) return json({error:'invalid_skip'},400,method);
      return json({items:stations.slice(Number(raw),Number(raw)+100).map(s=>asTrack(s,true))},200,method);
    }
    if(u.pathname.startsWith('/stream/')) {
      const station=lookup.get(u.pathname.slice('/stream/'.length));
      if(!station) return json({error:'not_found'},404,method);
      // Static publisher allowlist: no SSRF, keys, credentials, redirect or media relay.
      return json({url:station.url,format:'mp3',codec:'mp3',container:'mp3',manifest:'none',encrypted:false,quality:'midfi'},200,method);
    }
    return json({error:'not_found'},404,method);
  }
};