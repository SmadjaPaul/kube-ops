import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import plugin from '../../k8s/applications/media/bookorbit/plugins/gutenberg-fr-candide.mjs';

const config = { baseUrl: 'https://gutenberg.pglaf.org', settings: null };
const query = {
  title: "Candide ou l'optimisme",
  author: 'Voltaire',
  isbn13: null,
  isbn13s: [],
  mediaKind: 'ebook',
  language: 'fr',
  limit: 20,
};

function host(fetch = async (url) => new Response(null, { status: url.endsWith('.epub') ? 200 : 404 })) {
  return { fetch };
}

test('only returns the curated French Candide EPUB from the official mirror', async () => {
  const result = await plugin.search(query, config, host(async () => new Response(null, {
    status: 200,
    headers: { 'content-length': '123126' },
  })));

  assert.equal(result.length, 1);
  assert.equal(result[0].guid, '59859');
  assert.equal(result[0].language, 'fr');
  assert.equal(result[0].format, 'epub');
  assert.equal(result[0].sizeBytes, 123126);
  assert.equal(new URL(result[0].downloadUrl).hostname, 'gutenberg.pglaf.org');
});

test('does not expose a result for other works, media, or languages', async () => {
  const mockHost = host(async () => new Response(null, { status: 200, headers: { 'content-length': '123126' } }));
  assert.deepEqual(await plugin.search({ ...query, title: 'Les Misérables' }, config, mockHost), []);
  assert.deepEqual(await plugin.search({ ...query, mediaKind: 'audiobook' }, config, mockHost), []);
  assert.deepEqual(await plugin.search({ ...query, language: 'en' }, config, mockHost), []);
});

test('refuses a changed base URL and an altered release identifier', async () => {
  await assert.rejects(plugin.search(query, { ...config, baseUrl: 'https://www.gutenberg.org' }, host()), /only permits the official/);
  await assert.rejects(plugin.resolveFile({ guid: '19942', format: 'epub', downloadUrl: 'https://gutenberg.pglaf.org/a.epub' }, config), /only resolves the curated/);
});

test('connection test validates the mirror metadata and direct EPUB', async () => {
  const rdf = `<dcterms:title>Candide, ou l'optimisme</dcterms:title><pgterms:name>Voltaire</pgterms:name><rdf:value rdf:datatype="http://purl.org/dc/terms/RFC4646">fr</rdf:value>`;
  const result = await plugin.test(config, host(async (url, init = {}) => {
    if (init.method === 'HEAD') return new Response(null, { status: 200, headers: { 'content-length': '123126' } });
    assert.equal(url, 'https://gutenberg.pglaf.org/cache/epub/59859/pg59859.rdf');
    return new Response(rdf, { status: 200 });
  }));
  assert.deepEqual(result, { success: true, indexerName: 'Project Gutenberg mirror — Candide (FR)' });
});

test('plugin contains no central Gutenberg fallback', async () => {
  const source = await readFile(new URL('../../k8s/applications/media/bookorbit/plugins/gutenberg-fr-candide.mjs', import.meta.url), 'utf8');
  assert.doesNotMatch(source, /www\.gutenberg\.org|https:\/\/gutenberg\.org/);
});
