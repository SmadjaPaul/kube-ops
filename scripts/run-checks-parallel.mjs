// Lance en parallele des sous-checks. Arguments :
//   <nom>                 script npm (`npm run <nom>`)
//   --bash-list <fichier> un test bash par ligne (commentaires # ignores), lance avec `bash <chemin>`
//   --jobs N              concurrence maximale (defaut : nombre de coeurs)
//   --first a,b,c         noms a demarrer en premier (les plus longs, pour reduire la duree totale)
// Memes scripts, memes commandes : aucun controle retire. Chaque sous-check ecrit son journal dans
// un dossier temporaire ; les journaux sont affiches groupes par sous-check, dans l'ordre d'origine,
// puis un resume trie par duree decroissante. Echec (code 1) si l'un echoue.
// SKIP_CHECKS (virgules) : sous-checks sautes par le workflow quand leur perimetre n'est pas touche.
// Les sous-checks bash doivent etre independants (mktemp, pas d'ecriture dans le depot, pas de port fixe) ;
// les rendus kustomize --enable-helm passent par scripts/lib/render-cache.sh (verrou par racine).
import { spawn } from "node:child_process";
import { mkdtempSync, openSync, readFileSync, closeSync } from "node:fs";
import { tmpdir, cpus } from "node:os";
import { join } from "node:path";

const root = new URL("..", import.meta.url).pathname;
const skipped = new Set((process.env.SKIP_CHECKS || "").split(",").map((x) => x.trim()).filter(Boolean));
let jobs = Number(process.env.CHECK_JOBS) || cpus().length;
let first = [];
const items = []; // { name, cmd, args }
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === "--jobs") jobs = Number(argv[++i]);
  else if (a === "--first") first = argv[++i].split(",").filter(Boolean);
  else if (a === "--bash-list") {
    const lines = readFileSync(join(root, argv[++i]), "utf8").split("\n").map((l) => l.trim()).filter((l) => l && !l.startsWith("#"));
    for (const l of lines) items.push({ name: l, cmd: "bash", args: [l] });
  } else items.push({ name: a, cmd: "npm", args: ["run", a] });
}
let todo = items.filter((it) => !skipped.has(it.name));
for (const n of skipped) if (items.some((it) => it.name === n)) console.log(`SKIPPED (perimetre non touche): ${n}`);
if (todo.length === 0) {
  console.error("run-checks-parallel: aucun sous-check a executer");
  process.exit(1);
}
const rank = (it) => { const k = first.indexOf(it.name); return k < 0 ? first.length : k; };
const order = new Map(todo.map((it, i) => [it.name, i]));
const queue = [...todo].sort((a, b) => rank(a) - rank(b) || order.get(a.name) - order.get(b.name));

const dir = mkdtempSync(join(tmpdir(), "npm-check-"));
const started = Date.now();
const results = new Map();
const runOne = (it) => {
  const log = join(dir, `${it.name.replace(/[^A-Za-z0-9_.-]/g, "_")}.log`);
  const fd = openSync(log, "w");
  const t0 = Date.now();
  const child = spawn(it.cmd, it.args, { cwd: root, stdio: ["ignore", fd, fd], env: process.env });
  return new Promise((resolve) => {
    const done = (code) => {
      closeSync(fd);
      results.set(it.name, { name: it.name, code, ms: Date.now() - t0, log });
      resolve();
    };
    child.on("error", () => done(127));
    child.on("close", (code) => done(code ?? 1));
  });
};
const worker = async () => {
  while (queue.length) await runOne(queue.shift());
};
await Promise.all(Array.from({ length: Math.max(1, Math.min(jobs, todo.length)) }, worker));

const ordered = todo.map((it) => results.get(it.name));
let failed = 0;
for (const r of ordered) {
  console.log(`\n::group::${r.name} (${(r.ms / 1000).toFixed(1)}s, rc=${r.code})`);
  process.stdout.write(readFileSync(r.log, "utf8"));
  console.log("::endgroup::");
  if (r.code !== 0) failed += 1;
}
console.log(`\nRESUME sous-checks (duree en secondes, jobs=${jobs}, tries par duree) :`);
for (const r of [...ordered].sort((a, b) => b.ms - a.ms)) console.log(`  ${r.code === 0 ? "OK  " : "FAIL"} ${(r.ms / 1000).toFixed(1).padStart(7)}s  ${r.name}`);
const sum = ordered.reduce((s, r) => s + r.ms, 0);
console.log(`total wall ${((Date.now() - started) / 1000).toFixed(1)}s (somme sequentielle ${(sum / 1000).toFixed(1)}s), echecs=${failed}/${ordered.length}`);
process.exit(failed ? 1 : 0);
