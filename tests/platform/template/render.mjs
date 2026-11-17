// Rend le skeleton du template platform-application SANS Backstage (moteur nunjitsu, delimiteurs ${{ }}).
// Usage : node render.mjs <template.json> <params.json> <skeletonDir> <outDir>
// template.json = template.yaml converti en JSON (fait par test_template.py).
import { createTemplateRenderer } from 'nunjitsu';
import fs from 'node:fs';
import path from 'node:path';

const [, , templatePath, paramsPath, skeletonDir, outDir] = process.argv;
if (!outDir) {
  console.error('usage: render.mjs template.json params.json skeletonDir outDir');
  process.exit(2);
}
const tpl = JSON.parse(fs.readFileSync(templatePath, 'utf8'));
const parameters = JSON.parse(fs.readFileSync(paramsPath, 'utf8'));
const renderer = createTemplateRenderer();

// Expression unique `${{ expr }}` : garde le type (entier, booleen), comme Backstage.
const EXPR_ONLY = /^\$\{\{((?:(?!\}\})[\s\S])+)\}\}$/;
function evaluate(value, ctx) {
  if (typeof value !== 'string') return value;
  const m = value.match(EXPR_ONLY);
  if (m) return JSON.parse(renderer.render('${{ (' + m[1] + ') | dump }}', ctx));
  return renderer.render(value, ctx);
}

const fetchStep = tpl.spec.steps.find((s) => s.action === 'fetch:template');
if (!fetchStep) throw new Error('aucune etape fetch:template');
const ctx = { parameters, values: {} };
for (const [k, v] of Object.entries(fetchStep.input.values)) ctx.values[k] = evaluate(v, ctx);

const src = path.resolve(skeletonDir);
function walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const abs = path.join(dir, entry.name);
    if (entry.isDirectory()) { walk(abs); continue; }
    const rel = path.relative(src, abs);
    const outRel = renderer.render(rel, ctx); // noms de fichiers/dossiers templates
    const outAbs = path.join(path.resolve(outDir), outRel);
    fs.mkdirSync(path.dirname(outAbs), { recursive: true });
    fs.writeFileSync(outAbs, renderer.render(fs.readFileSync(abs, 'utf8'), ctx));
  }
}
walk(src);
console.log('ok');
