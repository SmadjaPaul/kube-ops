/**
 * A deliberately narrow Project Gutenberg source for the French public-domain work Candide.
 *
 * Project Gutenberg asks automated clients to use an authorized mirror rather than its main
 * website. This source talks only to the official generated-content mirror, and exposes only the
 * French edition of Candide by Voltaire (ebook 59859). It does not search or fetch any other work.
 */

const MIRROR = 'https://gutenberg.pglaf.org';
const BOOK_ID = '59859';
const RDF_URL = `${MIRROR}/cache/epub/${BOOK_ID}/pg${BOOK_ID}.rdf`;
const EPUB_URL = `${MIRROR}/cache/epub/${BOOK_ID}/pg${BOOK_ID}.epub`;
const BOOK_TITLE = 'Candide';
const AUTHOR = 'Voltaire';

function normalize(value) {
  return String(value ?? '')
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, ' ')
    .trim();
}

function checkedBaseUrl(config) {
  let parsed;
  try {
    parsed = new URL(config.baseUrl);
  } catch {
    throw new Error('Configure the official Project Gutenberg mirror URL.');
  }
  if (parsed.origin !== MIRROR) throw new Error('This source only permits the official Project Gutenberg mirror.');
}

async function fileSize(host) {
  const response = await host.fetch(EPUB_URL, { method: 'HEAD' });
  if (!response.ok) return null;
  const length = Number(response.headers.get('content-length'));
  return Number.isSafeInteger(length) && length > 0 ? length : null;
}

export default {
  apiVersion: 1,
  version: '1.0.0',
  type: 'gutenberg-fr-candide',
  label: 'Project Gutenberg mirror — Candide (FR)',
  requiresCredential: false,
  credentialKind: null,
  mediaKinds: ['ebook'],
  usesCategories: false,
  seedsBack: false,
  defaultBaseUrl: MIRROR,
  baseUrlHint: 'Official generated-content mirror. This curated source only returns French Candide by Voltaire.',

  async search(query, config, host) {
    checkedBaseUrl(config);
    if (query.mediaKind !== 'ebook') return [];
    if (query.language && query.language.toLowerCase() !== 'fr') return [];
    if (!normalize(query.title).includes('candide')) return [];
    if (query.author && !normalize(query.author).includes('voltaire')) return [];

    const sizeBytes = await fileSize(host);
    if (sizeBytes === null) return [];

    return [{
      guid: BOOK_ID,
      title: 'Candide — Voltaire (French EPUB, Project Gutenberg #59859)',
      bookTitle: BOOK_TITLE,
      author: AUTHOR,
      language: 'fr',
      format: 'epub',
      downloadUrl: EPUB_URL,
      infoUrl: RDF_URL,
      sizeBytes,
      seeders: null,
      leechers: null,
      freeleech: true,
      primaryFileCount: 1,
    }];
  },

  async test(config, host) {
    try {
      checkedBaseUrl(config);
      const metadata = await host.fetch(RDF_URL);
      if (!metadata.ok) return { success: false, error: 'The official mirror did not return the curated book metadata.' };
      const rdf = await metadata.text();
      if (!/<dcterms:title>Candide, ou l'optimisme<\/dcterms:title>/.test(rdf) || !/<pgterms:name>Voltaire<\/pgterms:name>/.test(rdf)) {
        return { success: false, error: 'The mirror metadata did not match Candide by Voltaire.' };
      }
      if (!/<rdf:value[^>]*>fr<\/rdf:value>/.test(rdf)) {
        return { success: false, error: 'The mirror metadata did not identify a French edition.' };
      }
      if ((await fileSize(host)) === null) return { success: false, error: 'The curated EPUB is not available on the official mirror.' };
      return { success: true, indexerName: 'Project Gutenberg mirror — Candide (FR)' };
    } catch (error) {
      return { success: false, error: error instanceof Error ? error.message : String(error) };
    }
  },

  async resolveFile(release, config) {
    checkedBaseUrl(config);
    if (release.guid !== BOOK_ID || release.format !== 'epub' || release.downloadUrl !== EPUB_URL) {
      throw new Error('This source only resolves the curated Candide EPUB.');
    }
    return { url: EPUB_URL, fileName: 'Candide.epub', sizeBytes: release.sizeBytes, format: 'epub' };
  },
};
