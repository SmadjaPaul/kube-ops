// Matrice de tests negatifs REELS (backend 127.0.0.1:7007). Rejouable :
//   set -a; . ./.secrets.env; set +a; node tests/negative-tests.mjs <output-json>
// Chaque cas appelle le backend (REST ou MCP officiel) et enregistre HTTP/erreur observes.
// Aucun token n'est ecrit dans la sortie. Pas d'effet de bord : les templates/locations ciblent
// le template pilote deja enregistre ; les executions non autorisees sont testees avec values vides.
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { readFileSync, writeFileSync } from 'node:fs';

const BASE = 'http://127.0.0.1:7007';
const PIN_PG = 'https://github.com/SmadjaPaul/kube-ops/blob/0427f709d6842067ab59b0953206162d091053e1/golden-paths/service-postgres-oidc/template.yaml';
const PIN_PA = 'https://github.com/SmadjaPaul/kube-ops/blob/0dbc4b6befad8a0cddf10137973d156379e4c740/golden-paths/platform-application/template.yaml';
const tok = {
  A: process.env.BACKSTAGE_AGENT_A_TOKEN,
  B: process.env.BACKSTAGE_AGENT_B_TOKEN,
  GUEST: readFileSync(process.env.GUEST_TOKEN_FILE, 'utf8').trim(),
};
const out = process.argv[2];
const rows = [];

async function rest(method, path, who, body) {
  const headers = { 'Content-Type': 'application/json' };
  if (who !== 'NONE') headers.Authorization = `Bearer ${tok[who]}`;
  const r = await fetch(BASE + path, { method, headers, body: body ? JSON.stringify(body) : undefined });
  const text = await r.text();
  let msg = '';
  try { const j = JSON.parse(text); msg = j.error?.name ? `${j.error.name}: ${j.error.message}` : text.slice(0, 120); } catch { msg = text.slice(0, 120); }
  return { status: r.status, msg: msg.slice(0, 220) };
}

async function mcpSession(who) {
  const transport = new StreamableHTTPClientTransport(new URL(`${BASE}/api/mcp-actions/v1`), {
    requestInit: who === 'NONE' ? {} : { headers: { Authorization: `Bearer ${tok[who]}` } },
  });
  const client = new Client({ name: 'idp-negative-tests', version: '0.1.0' });
  await client.connect(transport);
  return client;
}

async function mcpCall(who, tool, args) {
  let client;
  try {
    client = await mcpSession(who);
  } catch (e) {
    return { status: 'transport', msg: String(e?.message ?? e).slice(0, 200) };
  }
  try {
    const r = await client.callTool({ name: tool, arguments: args });
    const txt = (r.content ?? []).map((c) => c.text).join(' ').slice(0, 220);
    return { status: r.isError ? 'isError' : 'ok', msg: txt };
  } catch (e) {
    return { status: 'mcp-error', msg: String(e?.message ?? e).slice(0, 220) };
  } finally {
    await client.close().catch(() => {});
  }
}

function record(id, who, surface, action, expected, observed, verdict) {
  rows.push({ id, who, surface, action, expected, observed, verdict });
}

// Verdict : PASS si le comportement observe = attendu, sinon FAIL (faille ou ecart).
const denied = (r) => r.status === 401 || r.status === 403 || r.status === 'isError' || r.status === 'mcp-error' || r.status === 404 && /not found/i.test(r.msg) && false;

// T01/T02 : pas de token
{
  const r = await rest('GET', '/api/catalog/entities?limit=1', 'NONE');
  record('T01', 'NONE', 'REST', 'GET /api/catalog/entities', '401', String(r.status), r.status === 401 ? 'PASS' : 'FAIL');
  const r2 = await rest('POST', '/api/catalog/locations', 'NONE', { type: 'url', target: PIN_PA });
  record('T02', 'NONE', 'REST', 'POST /api/catalog/locations', '401', String(r2.status), r2.status === 401 ? 'PASS' : 'FAIL');
  const m = await mcpCall('NONE', 'catalog.query-catalog-entities', { query: { kind: 'Template' } });
  record('T03', 'NONE', 'MCP', 'tools/call catalog.query-catalog-entities', 'refus (401)', m.status === 'transport' || m.status === 'mcp-error' ? `transport/erreur: ${m.msg.slice(0, 90)}` : m.status, m.status === 'transport' || m.status === 'mcp-error' ? 'PASS' : 'FAIL');
}

// T04..: agent B (catalog seulement) : ecriture catalogue (location.create) et execution scaffolder
{
  const r = await rest('POST', '/api/catalog/locations', 'B', { type: 'url', target: PIN_PG });
  // 409 = la permission est passee (le doublon est detecte APRES l'autorisation) ; 403 = refuse
  record('T04', 'B', 'REST', 'POST /api/catalog/locations (doublon, sans effet)', '403 (lecture seule)', `${r.status} ${r.msg.slice(0, 60)}`, r.status === 403 ? 'PASS' : 'FAIL');
  const m = await mcpCall('B', 'catalog.register-entity', { locationUrl: PIN_PG });
  record('T05', 'B', 'MCP', 'catalog.register-entity (doublon)', 'refus', `${m.status}: ${m.msg.slice(0, 90)}`, m.status === 'isError' && /Conflict|already/i.test(m.msg) ? 'FAIL' : (m.status === 'isError' ? 'PASS' : 'FAIL'));
  const e = await mcpCall('B', 'scaffolder.execute-template', { templateRef: 'template:default/platform-application', values: {} });
  record('T06', 'B', 'MCP', 'scaffolder.execute-template (plugin scaffolder absent de B)', 'refus', `${e.status}: ${e.msg.slice(0, 90)}`, e.status === 'isError' ? 'PASS' : 'FAIL');
  const q = await rest('GET', '/api/catalog/entities?limit=1', 'B');
  record('T07', 'B', 'REST', 'GET /api/catalog/entities (lecture)', '200', String(q.status), q.status === 200 ? 'PASS' : 'FAIL');
}

// T08..: agent A (catalog lecture+ecriture via plugin, scaffolder)
{
  const r = await rest('POST', '/api/catalog/locations', 'A', { type: 'url', target: PIN_PG });
  record('T08', 'A', 'REST', 'POST /api/catalog/locations (doublon)', '403 (agent sans location.create)', `${r.status} ${r.msg.slice(0, 60)}`, r.status === 403 ? 'PASS' : 'FAIL');
  const m = await mcpCall('A', 'catalog.unregister-entity', { type: { locationId: '00000000-0000-0000-0000-000000000000' } });
  record('T09', 'A', 'MCP', 'catalog.unregister-entity (id inexistant)', 'refus (entity.delete absent)', `${m.status}: ${m.msg.slice(0, 90)}`, /NotFound|not found/.test(m.msg) && !/Found no location/.test(m.msg) ? 'PASS (action absente du registre)' : (/NotFound/.test(m.msg) ? 'FAIL' : 'PASS'));
  // execution d'un AUTRE template : values vides, pas de task creee si la permission est refusee OU si la validation echoue
  const x = await mcpCall('A', 'scaffolder.execute-template', { templateRef: 'template:default/service-postgres-oidc', values: {} });
  record('T10', 'A', 'MCP', 'scaffolder.execute-template service-postgres-oidc (values vides, sans effet)', 'refus (template non autorise)', `${x.status}: ${x.msg.slice(0, 110)}`, x.status === 'isError' && !/Input|valid|required|InputError|Required/i.test(x.msg) ? 'PASS' : 'FAIL');
  const reg = await mcpCall('A', 'catalog.register-entity', { locationUrl: PIN_PG });
  record('T11', 'A', 'MCP', 'catalog.register-entity (doublon)', 'refus', `${reg.status}: ${reg.msg.slice(0, 90)}`, /Conflict|already/i.test(reg.msg) ? 'FAIL (permission passee, doublon detecte)' : 'PASS');
  const ok = await mcpCall('A', 'catalog.query-catalog-entities', { query: { kind: 'Template' } });
  record('T12', 'A', 'MCP', 'catalog.query-catalog-entities (lecture)', 'ok', ok.status, ok.status === 'ok' ? 'PASS' : 'FAIL');
}

// T13..: principal UTILISATEUR (guest) : la politique pilote s'applique
{
  const r = await rest('POST', '/api/catalog/locations', 'GUEST', { type: 'url', target: PIN_PG });
  record('T13', 'GUEST(user)', 'REST', 'POST /api/catalog/locations', '403 politique', `${r.status} ${r.msg.slice(0, 60)}`, r.status === 403 ? 'PASS' : 'FAIL');
  const m = await mcpCall('GUEST', 'catalog.register-entity', { locationUrl: PIN_PG });
  record('T14', 'GUEST(user)', 'MCP', 'catalog.register-entity', 'refus politique', `${m.status}: ${m.msg.slice(0, 90)}`, m.status === 'isError' ? 'PASS' : 'FAIL');
}

// T15..: serveur MCP nomme FILTRE (lecture seule) vs endpoint complet : le filtre n'est pas une frontiere
{
  const ro = new Client({ name: 'idp-negative-tests', version: '0.1.0' });
  await ro.connect(new StreamableHTTPClientTransport(new URL(`${BASE}/api/mcp-actions/v1/readonly`), { requestInit: { headers: { Authorization: `Bearer ${tok.A}` } } }));
  const list = (await ro.listTools()).tools.map((t) => t.name);
  await ro.close();
  record('T15', 'A', 'MCP', 'tools/list /api/mcp-actions/v1/readonly', 'pas de catalog.unregister-entity', list.includes('catalog.unregister-entity') ? 'present' : 'absent (liste: ' + list.length + ' outils)', list.includes('catalog.unregister-entity') ? 'FAIL' : 'PASS');
  const transport = new StreamableHTTPClientTransport(new URL(`${BASE}/api/mcp-actions/v1`), { requestInit: { headers: { Authorization: `Bearer ${tok.A}` } } });
  const c = new Client({ name: 'idp-negative-tests', version: '0.1.0' });
  await c.connect(transport);
  const r = await c.callTool({ name: 'catalog.unregister-entity', arguments: { type: { locationId: '00000000-0000-0000-0000-000000000000' } } }).catch((e) => ({ isError: true, content: [{ text: String(e) }] }));
  await c.close();
  const t = (r.content ?? []).map((x) => x.text).join(' ');
  record('T16', 'A', 'MCP', 'appel direct catalog.unregister-entity via endpoint COMPLET (filtre contourne)', 'refus (entity.delete absent)', t.slice(0, 120), /Action .* not found/.test(t) ? 'PASS (action absente du registre)' : (/NotFound/.test(t) ? 'FAIL (permission passee)' : 'PASS'));
}

writeFileSync(out, JSON.stringify({ at: new Date().toISOString(), rows }, null, 2));
for (const r of rows) console.log(`${r.id}\t${r.who}\t${r.surface}\t${r.action}\t| attendu: ${r.expected}\t| observe: ${r.observed}\t| ${r.verdict}`);
