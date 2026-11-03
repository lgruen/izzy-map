// Fixture generator (provenance): the web app's own proj4 path (app/src/mga.ts
// definition of EPSG:28355, proj4 2.21.0 from app/node_modules) for 14
// Tasmanian points incl. the extremes. Cross-checked 2026-11-03 against
// PROJ (pyproj, same +proj=utm +zone=55 +south +ellps=GRS80): identical to
// 0.1 mm at every point.   node make_mga.mjs > mga.json
// The web app (and its node_modules) was deleted after commit 04ea5d9: re-run
// from a worktree of that commit after `npm ci` in its app/.
import { createRequire } from "module";
const require = createRequire("/Users/leo/izzy-map/app/package.json");
const proj4mod = require("proj4"); const proj4 = proj4mod.default ?? proj4mod;
proj4.defs("EPSG:28355","+proj=utm +zone=55 +south +ellps=GRS80 +towgs84=0,0,0,0,0,0,0 +units=m +no_defs");
const pts = [
 ["Hobart GPO", -42.88234, 147.32720],
 ["Launceston", -41.43440, 147.13760],
 ["King Island, Cape Wickham", -39.58670, 143.94220],
 ["King Island, Currie", -39.93140, 143.85030],
 ["Macquarie Harbour, Strahan", -42.15330, 145.32830],
 ["Macquarie Harbour, Gordon River mouth", -42.39500, 145.43800],
 ["Flinders Island, Whitemark", -40.12280, 148.01350],
 ["Flinders Island, Mt Strzelecki", -40.20300, 148.07000],
 ["South East Cape", -43.64300, 146.82900],
 ["Cape Grim", -40.68280, 144.69100],
 ["Eddystone Point", -40.99300, 148.34800],
 ["Cradle Mountain", -41.68480, 145.95130],
 ["Maatsuyker Island", -43.65700, 146.27100],
 ["Central meridian 147E", -42.00000, 147.00000],
];
const out = pts.map(([name, lat, lon]) => { const [e, n] = proj4("EPSG:4326","EPSG:28355",[lon, lat]); return { name, lat, lon, e: Number(e.toFixed(4)), n: Number(n.toFixed(4)) }; });
console.log(JSON.stringify(out, null, 1));
