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
// Plants: the "recorded near here" grid ships as a hashed .bin asset the SW
// must precache (a data: URL or a missed glob = no nearby list offline), and
// it must parse (NBY1 magic, consistent offsets). plants.json/records.json
// are lazy JS chunks (named after the JSON file): check they are precached.
{
  const bin = assets.find((f) => /^nearby-.*\.bin$/.test(f));
  if (!bin) { console.error("check-dist: no nearby-*.bin asset (inlined? see assetsInlineLimit)"); ok = false; }
  else if (!sw.includes(`assets/${bin}`)) { console.error(`check-dist: ${bin} not precached by sw.js`); ok = false; }
  else {
    const b = readFileSync(`dist/assets/${bin}`);
    const n = b.length >= 8 ? b.readUInt32LE(4) : -1;
    const pairsAt = 8 + 4 * n + 4 * (n + 1);
    const magicOk = b.length >= 8 && b.readUInt32LE(0) === 0x4e425931;
    const sizeOk = magicOk && b.length >= pairsAt && b.length >= pairsAt + 4 * b.readUInt32LE(8 + 4 * n + 4 * n);
    if (!magicOk || !sizeOk) { console.error(`check-dist: ${bin} does not parse as NBY1`); ok = false; }
    else console.log(`check-dist: ${bin} NBY1, ${n.toLocaleString()} cells, ${(b.length / 1e6).toFixed(2)} MB, precached`);
  }
  for (const [label, re] of [["plants.json", /^plants-.*\.js$/], ["records.json", /^records-.*\.js$/]]) {
    const chunk = assets.find((f) => re.test(f));
    if (!chunk) { console.error(`check-dist: no chunk carrying ${label}`); ok = false; continue; }
    if (!sw.includes(`assets/${chunk}`)) { console.error(`check-dist: ${label} chunk ${chunk} not precached by sw.js`); ok = false; continue; }
    console.log(`check-dist: ${label} -> ${chunk} (${(readFileSync(`dist/assets/${chunk}`).length / 1e6).toFixed(2)} MB), precached`);
  }
}
process.exit(ok ? 0 : 1);
