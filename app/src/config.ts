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

export const RASTER_MAXZOOM = 15; // raster archive ceiling; overzooms beyond

export interface RasterPack {
  file: string;
  label: string;
  hint: string;
  /** live tile URL for statewide services (topo, aerial, tasmap) */
  live?: (z: number, x: number, y: number) => string;
  kind: "base" | "season";
  /** flying-season label, seasons only */
  season?: string;
}

/** Offline raster packs. Hand-mirrors pipeline/packs.json (keys, files) —
 * the repo keeps overlay/pack wiring hand-curated, one pattern to follow. */
export const RASTER_PACKS = {
  topo: {
    file: "topo_tas.pmtiles",
    label: "Topographic map",
    hint: "statewide to zoom 15 — the map under everything. Large!",
    live: listTile("Topographic"),
    kind: "base",
  },
  aerial: {
    file: "aerial_tas.pmtiles",
    label: "Aerial photos (best available)",
    hint: "satellite-style imagery, statewide to zoom 15 — LIST's best-quality mosaic. Very large!",
    live: listTile("Orthophoto"),
    kind: "base",
  },
  tasmap: {
    file: "tasmap_tas.pmtiles",
    label: "Paper map (Tasmap)",
    hint: "scans of the printed Tasmap sheets: 1:25,000 at zoom 15, 100K/250K/500K further out. Huge!",
    live: listTile("TasmapRaster"),
    kind: "base",
  },
  aerial2020: { file: "aerial_2020.pmtiles", label: "Aerial photos 2019–20", hint: "areas flown that season only", kind: "season", season: "2019–20" },
  aerial2021: { file: "aerial_2021.pmtiles", label: "Aerial photos 2020–21", hint: "areas flown that season only", kind: "season", season: "2020–21" },
  aerial2022: { file: "aerial_2022.pmtiles", label: "Aerial photos 2021–22", hint: "areas flown that season only", kind: "season", season: "2021–22" },
  aerial2023: { file: "aerial_2023.pmtiles", label: "Aerial photos 2022–23", hint: "areas flown that season only", kind: "season", season: "2022–23" },
  aerial2024: { file: "aerial_2024.pmtiles", label: "Aerial photos 2023–24", hint: "areas flown that season only", kind: "season", season: "2023–24" },
  aerial2025: { file: "aerial_2025.pmtiles", label: "Aerial photos 2024–25", hint: "areas flown that season only", kind: "season", season: "2024–25" },
  aerial2026: { file: "aerial_2026.pmtiles", label: "Aerial photos 2025–26", hint: "areas flown so far this season", kind: "season", season: "2025–26" },
} as const satisfies Record<string, RasterPack>;

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

// Tasmania-ish default view for before the first GPS fix
export const HOME = { center: [146.6, -42.2] as [number, number], zoom: 7 };
