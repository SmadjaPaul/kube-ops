// Lance en parallele les sous-checks de `npm run check` (memes scripts, memes commandes,
// aucun contrôle retire). La liste est lue dans package.json pour ne pas la dupliquer.
// Chaque sous-check ecrit son journal dans un dossier temporaire ; le journal est
// affiche dans l'ordre d'origine, avec la duree par sous-check. Echec si l'un echoue.
import { spawn } from "node:child_process";
import { mkdtempSync, openSync, readFileSync, readSync, closeSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const pkg = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"));
const names = [...pkg.scripts["check:sequence"].matchAll(/npm run ([^\s&]+)/g)].map((m) => m[1]);
if (names.length === 0) {
  console.error("run-checks-parallel: aucun sous-check trouve dans scripts.check");
  process.exit(1);
}

const dir = mkdtempSync(join(tmpdir(), "npm-check-"));
const started = Date.now();
const runs = names.map((name) => {
  const log = join(dir, `${name.replace(/[:/]/g, "_")}.log`);
  const fd = openSync(log, "w");
  const t0 = Date.now();
  const child = spawn("npm", ["run", name], {
    cwd: new URL("..", import.meta.url).pathname,
    stdio: ["ignore", fd, fd],
    env: process.env,
  });
  const done = new Promise((resolve) =>
    child.on("close", (code) => {
      closeSync(fd);
      resolve({ name, code, ms: Date.now() - t0, log });
    }),
  );
  return done;
});

const results = await Promise.all(runs);
let failed = 0;
for (const r of results) {
  console.log(`\n::group::${r.name} (${(r.ms / 1000).toFixed(1)}s, rc=${r.code})`);
  process.stdout.write(readFileSync(r.log, "utf8"));
  console.log("::endgroup::");
  if (r.code !== 0) failed += 1;
}
console.log("\nRESUME sous-checks (duree en secondes, en parallele) :");
for (const r of results) console.log(`  ${r.code === 0 ? "OK  " : "FAIL"} ${(r.ms / 1000).toFixed(1).padStart(7)}s  ${r.name}`);
console.log(`total wall ${((Date.now() - started) / 1000).toFixed(1)}s, echecs=${failed}/${results.length}`);
process.exit(failed ? 1 : 0);
