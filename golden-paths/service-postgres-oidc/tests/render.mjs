// Rend golden-paths/service-postgres-oidc/template.yaml SANS Backstage.
// Moteur : nunjitsu 0.7.0 (le moteur reel de Backstage, delimiteurs ${{ }} et {% %}).
// Entrees : template.json (template.yaml converti en JSON), params.json (parameters),
// skeleton/, racine du depot (sources fetch:plain), repertoire de travail (workspace).
// Sortie : <work>/out (ce que publish:github:pull-request commitrait), codes de sortie stricts.
import { createTemplateRenderer } from 'nunjitsu';
import Ajv from 'ajv';
import fs from 'node:fs';
import path from 'node:path';

const [, , templatePath, paramsPath, skeletonDir, repoRoot, workDir] = process.argv;
if (!workDir) {
  console.error('usage: render.mjs template.json params.json skeleton repoRoot workDir');
  process.exit(2);
}
const tpl = JSON.parse(fs.readFileSync(templatePath, 'utf8'));
const parameters = JSON.parse(fs.readFileSync(paramsPath, 'utf8'));
const renderer = createTemplateRenderer();

// Validation des parametres : pages fusionnees en un schema, comme le formulaire Backstage.
const schema = { type: 'object', properties: {}, required: [], allOf: [] };
for (const page of tpl.spec.parameters) {
  Object.assign(schema.properties, page.properties ?? {});
  schema.required.push(...(page.required ?? []));
  schema.allOf.push(...(page.allOf ?? []));
}
schema.required = [...new Set(schema.required)];
if (schema.allOf.length === 0) delete schema.allOf;
const ajv = new Ajv({ allErrors: true, strict: false });
const validate = ajv.compile(schema);
if (!validate(parameters)) {
  console.error('FAIL: parametres refuses par le schema:');
  for (const e of validate.errors) console.error(`  ${e.instancePath || '/'} ${e.message}`);
  process.exit(1);
}

// Une seule expression, sans `}}` interne : "${{ a }}.${{ b }}" n'est pas une expression unique.
const EXPR_ONLY = /^\$\{\{((?:(?!\}\})[\s\S])+)\}\}$/;

// Une valeur seule `${{ expr }}` garde son type (liste, entier) comme dans Backstage ;
// un texte avec interpolations devient une chaine.
function evaluate(value, ctx) {
  if (typeof value !== 'string') return value;
  const m = value.match(EXPR_ONLY);
  if (m) return JSON.parse(renderer.render('${{ (' + m[1] + ') | dump }}', ctx));
  return renderer.render(value, ctx);
}

function fail(msg) {
  console.error('FAIL: ' + msg);
  process.exit(1);
}

fs.mkdirSync(workDir, { recursive: true });
const ws = path.resolve(workDir);
const ctxParams = { parameters };

// Chaque etape est executee dans l'ordre avec les memes regles que le moteur Backstage.
let values = {};
for (const step of tpl.spec.steps) {
  const input = step.input ?? {};
  switch (step.action) {
    case 'fetch:template': {
      // 1. valeurs exposees au skeleton
      for (const [k, v] of Object.entries(input.values)) values[k] = evaluate(v, ctxParams);
      if (input.url !== './skeleton') fail(`fetch:template url inattendue: ${input.url}`);
      const src = path.resolve(skeletonDir);
      const dst = path.join(ws, input.targetPath);
      renderTree(src, dst, { values });
      break;
    }
    case 'fetch:plain': {
      // Fichier existant du depot, copie tel quel (l'URL pointe sur la branche main du depot)
      const m = input.url.match(/\/blob\/main\/(.+)$/);
      if (!m) fail(`fetch:plain url non reconnue: ${input.url}`);
      const from = path.join(path.resolve(repoRoot), m[1]);
      if (!fs.existsSync(from)) fail(`source absente du depot: ${m[1]}`);
      const to = path.join(ws, input.targetPath.replace(/^\.\//, ''));
      fs.mkdirSync(path.dirname(to), { recursive: true });
      fs.copyFileSync(from, to);
      break;
    }
    case 'roadiehq:utils:fs:replace': {
      for (const f of input.files) {
        const file = path.join(ws, f.file.replace(/^\.\//, ''));
        const find = f.find;
        const replaceWith = evaluate(f.replaceWith, ctxParams);
        const original = fs.readFileSync(file, 'utf8');
        const count = original.split(find).length - 1;
        // Fail-closed : 0 ou plusieurs occurrences = erreur, jamais d'edition partielle.
        if (count !== 1) fail(`${f.file}: ancre trouvee ${count} fois (attendu 1): ${JSON.stringify(find)}`);
        fs.writeFileSync(file, original.replace(find, () => replaceWith));
      }
      break;
    }
    case 'publish:github:pull-request': {
      // Non execute ici : on consigne ce qui serait publie.
      const branch = evaluate(input.branchName, ctxParams);
      const title = evaluate(input.title, ctxParams);
      fs.writeFileSync(path.join(ws, 'publish-plan.json'), JSON.stringify({ branch, title, sourcePath: input.sourcePath, update: input.update }, null, 2) + '\n');
      break;
    }
    default:
      fail(`action non geree par le test: ${step.action}`);
  }
}

// Rend chaque fichier du skeleton (chemin et contenu) avec les valeurs du template.
function renderTree(srcDir, dstDir, ctx) {
  for (const ent of fs.readdirSync(srcDir, { withFileTypes: true })) {
    const name = renderer.render(ent.name, ctx);
    const src = path.join(srcDir, ent.name);
    const dst = path.join(dstDir, name);
    if (ent.isDirectory()) {
      renderTree(src, dst, ctx);
    } else {
      fs.mkdirSync(path.dirname(dst), { recursive: true });
      fs.writeFileSync(dst, renderer.render(fs.readFileSync(src, 'utf8'), ctx));
    }
  }
}
console.log('rendu OK: ' + path.join(ws, 'out'));
