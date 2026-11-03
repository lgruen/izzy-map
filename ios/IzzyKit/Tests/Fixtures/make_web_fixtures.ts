// Fixture generator (provenance): runs the WEB APP's own code — the NBY1
// parser + sitesAround from app/src/plants.ts and formatAge from
// app/src/details.ts, sliced out verbatim — over the real generated data,
// plus the extent/name expressions copied from details.ts. Run once with
// Node ≥ 23 (native type stripping) from this directory:
//   node make_web_fixtures.ts > web.json
// The web app was deleted after commit 04ea5d9; the committed web.json is the
// record. To re-run: `git worktree add /tmp/izzy-web 04ea5d9` and point `app`
// below at /tmp/izzy-web/app/src/ (the data now lives in ios/IzzyMap/Resources/Data).
import { readFileSync, writeFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
const app = "/Users/leo/izzy-map/app/src/";
const gen = app + "generated/";
const slice = (file: string, from: RegExp, to: RegExp) => {
  const lines = readFileSync(app + file, "utf8").split("\n");
  const a = lines.findIndex((l) => from.test(l));
  const b = lines.findIndex((l, i) => i > a && to.test(l));
  return lines.slice(a, b).join("\n");
};
const dir = mkdtempSync(join(tmpdir(), "izzyfx-"));
const mod = join(dir, "web.ts");
writeFileSync(
  mod,
  slice("plants.ts", /^const NBY_MAGIC/, /^\/\/ ---------- loading/) + "\n" +
    slice("details.ts", /^export function formatAge/, /^const esc/) + "\n",
);
const { parseNearby, sitesAround, formatAge } = await import(mod);

const buf = readFileSync(gen + "nearby.bin");
const g = parseNearby(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength));
const R = JSON.parse(readFileSync(gen + "records.json", "utf8"));
const pts: [string, number, number][] = [
  ["Hobart GPO", -42.88234, 147.3272],
  ["kunanyi summit", -42.8962, 147.2367],
  ["Mt Field NP", -42.6817, 146.7158],
  ["Cradle Mountain", -41.6848, 145.9513],
  ["Freycinet", -42.1214, 148.2858],
  ["Launceston", -41.4344, 147.1376],
  ["South East Cape", -43.643, 146.829],
  ["Currie, King Island", -39.9314, 143.8503],
  ["Whitemark, Flinders Island", -40.1228, 148.0135],
  ["South-west grid corner", -44.0, 143.5],
  ["Open sea west of Macquarie Hbr", -42.3, 144.6],
  ["Near a half-step tie (col 382.4999…)", -42.885, 147.325],
];
const nearby = pts.map(([name, lat, lon]) => ({
  name, lat, lon,
  sites: Object.fromEntries([...sitesAround(g, R.grid, lon, lat)].sort((a, b) => a[0] - b[0])),
}));
const geo = JSON.parse(readFileSync(gen + "geology_units.json", "utf8"));
const age = Object.fromEntries(Object.entries(geo).map(([k, u]: [string, any]) => [k, formatAge(u.maxMa ?? null, u.minMa ?? null)]));
const pre = JSON.parse(readFileSync(gen + "pre1750_units.json", "utf8"));
// details.ts showPre1750, with the default locale pinned to en-AU
const extent = Object.fromEntries(Object.entries(pre).map(([k, unit]: [string, any]) => [k,
  unit.ha < 100 ? `${unit.ha} ha statewide` : `~${Math.round(unit.ha / 100).toLocaleString("en-AU")} km² statewide`]));
const com = JSON.parse(readFileSync(gen + "tasveg_communities.json", "utf8"));
const names = Object.fromEntries(Object.entries(com).map(([k, c]: [string, any]) => [k, c.name.replace(/^\([A-Z]{3}\)\s*/, "")]));
console.log(JSON.stringify({ nearbyCells: g.n, nearby, age, extent, names }));
