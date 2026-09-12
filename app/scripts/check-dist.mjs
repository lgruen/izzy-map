// Post-build guard: the production bundle must ship BOTH workers and the
// service worker must precache them (offline is the product). MapLibre 6
// resolves its worker at runtime, so a missing setWorkerUrl() wiring breaks
// vector tiles only in the built app — never in the dev-server tests.
import { existsSync, readdirSync, readFileSync } from "node:fs";
const assets = readdirSync("dist/assets");
const sw = readFileSync("dist/sw.js", "utf8");
const need = [/^maplibre-gl-worker.*\.js$/, /^pdf\.worker.*\.mjs$/];
let ok = true;
for (const re of need) {
  const file = assets.find((f) => re.test(f));
  if (!file) { console.error(`check-dist: no asset matching ${re}`); ok = false; continue; }
  if (!sw.includes(`assets/${file}`)) { console.error(`check-dist: ${file} not precached by sw.js`); ok = false; continue; }
  console.log(`check-dist: ${file} built + precached`);
}
// The search indexes are the one JSON the SW precaches (offline search from
// first launch): both must ship, parse, be the version the app reads, hold
// a plausible number of rows and appear in the precache manifest.
for (const [rel, key, min] of [["search/gazetteer.json", "rows", 30_000], ["search/addresses.json", "streets", 13_000]]) {
  const path = `dist/${rel}`;
  if (!existsSync(path)) { console.error(`check-dist: ${path} missing (run pipeline/build_gazetteer.py)`); ok = false; continue; }
  let j;
  try { j = JSON.parse(readFileSync(path, "utf8")); } catch (e) { console.error(`check-dist: ${path} is not JSON: ${e.message}`); ok = false; continue; }
  if (j.version !== 1) { console.error(`check-dist: ${path} version ${j.version}, app reads 1`); ok = false; continue; }
  if (!Array.isArray(j[key]) || j[key].length <= min) { console.error(`check-dist: ${path} has ${j[key]?.length ?? 0} ${key}, expected > ${min}`); ok = false; continue; }
  if (!sw.includes(rel)) { console.error(`check-dist: ${rel} not precached by sw.js`); ok = false; continue; }
  console.log(`check-dist: ${rel} v${j.version}, ${j[key].length.toLocaleString()} ${key}, precached`);
}
process.exit(ok ? 0 : 1);
