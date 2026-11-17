// Lance en parallele les sous-checks passes en arguments (liste dans scripts.check).
// Memes scripts, memes commandes : aucun controle retire. Chaque sous-check ecrit son
// journal dans un dossier temporaire ; les journaux sont affiches dans l'ordre d'origine,
// avec la duree par sous-check. Echec si l'un echoue.
import { spawn } from "node:child_process";
import { mkdtempSync, openSync, readFileSync, closeSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const names = process.argv.slice(2);
if (names.length === 0) {
  console.error("run-checks-parallel: aucun sous-check passe en argument");
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
  return new Promise((resolve) =>
    child.on("close", (code) => {
      closeSync(fd);
      resolve({ name, code, ms: Date.now() - t0, log });
    }),
  );
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
