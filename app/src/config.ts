// Central config. DATA_BASE is where the .pmtiles archives + data-manifest
// live: Cloudflare R2 in production, the vite dev middleware locally.
export const DATA_BASE: string =
  import.meta.env.VITE_DATA_BASE ?? (import.meta.env.DEV ? "/dev-data" : "");

// LIST ArcGIS cached tile services — NOTE the path is {z}/{y}/{x}: row
// BEFORE column. Only statewide services stream live; sparse seasons come
// from their R2 archive (a directory lookup answers "absent" for free).
const LIST = "https://services.thelist.tas.gov.au/arcgis/rest/services/Basemaps";
const listTile = (service: string) => (z: number, x: number, y: number) =>
  `${LIST}/${service}/MapServer/tile/${z}/${y}/${x}`;

/** Zoom ceiling of the statewide packs (z0–15). Beyond it tiles come from a
 * downloaded detailed area, the live service, or MapLibre's parent fallback. */
export const PACK_MAXZOOM = 15;
/** @deprecated alias, kept for the caption code */
export const RASTER_MAXZOOM = PACK_MAXZOOM;

export interface RasterPack {
  file: string;
  label: string;
  hint: string;
  /** live tile URL on the LIST service (seasons: used only above z15 and
   * only where the season's z15 tile exists — see protocol.ts) */
  live?: (z: number, x: number, y: number) => string;
  /** deepest zoom the map requests: the service's native max (LIST aerial
   * goes to z19–23, but z18 = 0.44 m/px is already 64× the z15 pack per
   * tile; MapLibre's parent fallback reaches 10 levels, so this is a size
   * choice, not a fallback constraint) */
  maxzoom: number;
  /** typical tile size at z16–18, for detailed-area estimates (measured) */
  meanTileBytes: number;
  kind: "base" | "season";
  /** flying-season label, seasons only */
  season?: string;
}
const season = (yy: string, label: string, service: string, file: string, hint = "areas flown that season only") =>
  ({ file, label, hint, live: listTile(service), maxzoom: 18, meanTileBytes: 18_000, kind: "season", season: yy }) as const;

/** Offline raster packs. Hand-mirrors pipeline/packs.json (keys, files) —
 * the repo keeps overlay/pack wiring hand-curated, one pattern to follow. */
export const RASTER_PACKS = {
  topo: {
    file: "topo_tas.pmtiles",
    label: "Topographic map",
    hint: "statewide to zoom 15 — the map under everything. Large!",
    live: listTile("Topographic"),
    maxzoom: 18,
    meanTileBytes: 12_000,
    kind: "base",
  },
  aerial: {
    file: "aerial_tas.pmtiles",
    label: "Aerial photos (best available)",
    hint: "satellite-style imagery, statewide to zoom 15 — LIST's best-quality mosaic. Large!",
    live: listTile("Orthophoto"),
    maxzoom: 18,
    meanTileBytes: 18_000,
    kind: "base",
  },
  tasmap: {
    file: "tasmap_tas.pmtiles",
    label: "Paper map (Tasmap)",
    hint: "scans of the printed Tasmap sheets: 1:25,000 at zoom 15, 100K/250K/500K further out. Very large!",
    live: listTile("TasmapRaster"),
    maxzoom: 16,
    meanTileBytes: 16_000,
    kind: "base",
  },
  aerial2020: season("2019–20", "Aerial photos 2019–20", "AerialPhoto2020", "aerial_2020.pmtiles"),
  aerial2021: season("2020–21", "Aerial photos 2020–21", "AerialPhoto2021", "aerial_2021.pmtiles"),
  aerial2022: season("2021–22", "Aerial photos 2021–22", "AerialPhoto2022", "aerial_2022.pmtiles"),
  aerial2023: season("2022–23", "Aerial photos 2022–23", "AerialPhoto2023", "aerial_2023.pmtiles"),
  aerial2024: season("2023–24", "Aerial photos 2023–24", "AerialPhoto2024", "aerial_2024.pmtiles"),
  aerial2025: season("2024–25", "Aerial photos 2024–25", "AerialPhoto2025", "aerial_2025.pmtiles"),
  aerial2026: season("2025–26", "Aerial photos 2025–26", "AerialPhoto2026", "aerial_2026.pmtiles", "areas flown so far this season"),
} as const satisfies Record<string, RasterPack>;

/** Detail levels offered for area downloads (m/px at Tasmanian latitudes). */
export const DETAIL_LEVELS: { z: number; label: string; mpp: string }[] = [
  { z: 16, label: "Good", mpp: "1.7 m per pixel" },
  { z: 17, label: "Fine", mpp: "0.9 m per pixel" },
  { z: 18, label: "Finest", mpp: "0.4 m per pixel" },
];

export type RasterKey = keyof typeof RASTER_PACKS;
export const RASTER_KEYS = Object.keys(RASTER_PACKS) as RasterKey[];
/** Widened accessor: the `as const` table is a union of literal objects, so
 * optional fields (live, season) are only reachable through RasterPack. */
export const packOf = (key: RasterKey): RasterPack => RASTER_PACKS[key];
/** Statewide base packs, in download-panel order. */
export const BASE_KEYS = ["topo", "aerial", "tasmap"] as const satisfies readonly RasterKey[];
/** Per-season aerial packs, CHRONOLOGICAL — the style stacks them in this
 * order so the newest season paints on top. */
export const SEASON_KEYS = [
  "aerial2020", "aerial2021", "aerial2022", "aerial2023", "aerial2024", "aerial2025", "aerial2026",
] as const satisfies readonly RasterKey[];
export type SeasonKey = (typeof SEASON_KEYS)[number];
export const seasonLabel = (i: number): string => RASTER_PACKS[SEASON_KEYS[i]].season;

/** Vector overlay archives served through the pmtiles protocol. */
export const ARCHIVES = {
  tasveg: "tasveg.pmtiles",
  geology: "geology.pmtiles",
  pre1750: "pre1750.pmtiles",
} as const;
export const VECTOR_ARCHIVES = ["tasveg", "geology", "pre1750"] as const;
export type VectorKey = (typeof VECTOR_ARCHIVES)[number];

// Attribution is attached per source so the map control shows exactly what
// is on screen (MapLibre de-duplicates identical strings); the About panel
// carries the full text. Two licence regimes — see docs/LICENSING.md.
export const ATTRIBUTION_TOPO =
  '<a href="https://www.thelist.tas.gov.au">Topographic Basemap from theLIST</a> © State of Tasmania (CC BY 3.0 AU)';
export const ATTRIBUTION_AERIAL =
  '<a href="https://www.thelist.tas.gov.au">Aerial photos from theLIST</a> © State of Tasmania (CC BY-NC-ND 3.0 AU)';
export const ATTRIBUTION_TASMAP =
  '<a href="https://www.thelist.tas.gov.au">Tasmap from theLIST</a> © State of Tasmania (CC BY-NC-ND 3.0 AU)';
export const ATTRIBUTION_TASVEG =
  '<a href="https://www.thelist.tas.gov.au">TASVEG 5.0 from theLIST</a> © State of Tasmania (CC BY 3.0 AU)';
export const ATTRIBUTION_GEOLOGY =
  "Geology from Mineral Resources Tasmania © State of Tasmania (CC BY 3.0 AU)";
export const ATTRIBUTION_PRE1750 =
  "Pre-1750 vegetation: NVIS V7.0 © Commonwealth of Australia, DCCEEW (CC BY 4.0)";
// Hobart significant trees (app/src/generated/trees.json, committed derived
// data; see docs/LICENSING.md). The per-tree data sheets are City of Hobart
// PDFs hosted as ArcGIS Online items.
export const ATTRIBUTION_TREES =
  '<a href="https://www.hobartcity.com.au/Environment-and-Sustainability/Trees/Significant-trees">Significant trees: City of Hobart</a> (CC BY 4.0)';
/** Sheet PDFs are fetched from www.arcgis.com, NOT the council's
 * hobartcc.maps.arcgis.com portal: only this host answers the item `data`
 * call with CORS headers on its 302 to the signed S3 URL. The preflight
 * allow-list does not include `Range`, so the request must stay a simple
 * GET with no custom headers (a plain fetch(url) — never storage.download()). */
export const TREE_SHEET_BASE = "https://www.arcgis.com/sharing/rest/content/items";
export const treeSheetUrl = (id: string): string => `${TREE_SHEET_BASE}/${id}/data`;
/** OPFS directory holding the fetched sheets (`<id>.pdf`). */
export const TREE_SHEET_DIR = "trees";
// Search indexes (app/public/search/*.json, committed; see docs/LICENSING.md §1)
export const ATTRIBUTION_NAMES =
  "Place and street names from theLIST © State of Tasmania (CC BY 3.0 AU)";
export const ATTRIBUTION_ADDRESSES =
  "Street addresses from theLIST © State of Tasmania (CC BY 3.0 AU)";

// Tasmania-ish default view for before the first GPS fix
export const HOME = { center: [146.6, -42.2] as [number, number], zoom: 7 };
