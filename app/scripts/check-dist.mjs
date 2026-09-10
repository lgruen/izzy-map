// Post-build guard: the production bundle must ship BOTH workers and the
// service worker must precache them (offline is the product). MapLibre 6
// resolves its worker at runtime, so a missing setWorkerUrl() wiring breaks
// vector tiles only in the built app — never in the dev-server tests.
import { readdirSync, readFileSync } from "node:fs";
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
process.exit(ok ? 0 : 1);
