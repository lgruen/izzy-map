// Assembles the MapLibre style: base rasters (topo / Tasmap scans / aerial
// photos / the chronological season stack) + the vector overlays using the
// official colours (generated from the QML etc. by the pipeline). Mimics
// LISTmap's "TASVEG 5.0" + "Outlines and Labels" look.
import type { StyleSpecification, ExpressionSpecification, RasterSourceSpecification } from "maplibre-gl";
import type { Map as MlMap } from "maplibre-gl";
import type { FeatureCollection, MultiPolygon, Point, Polygon } from "geojson";
import communities from "./generated/tasveg_communities.json";
import geologyUnits from "./generated/geology_units.json";
import pre1750Units from "./generated/pre1750_units.json";
import trees from "./generated/trees.json";
import {
  ATTRIBUTION_AERIAL,
  ATTRIBUTION_GEOLOGY,
  ATTRIBUTION_PRE1750,
  ATTRIBUTION_TASMAP,
  ATTRIBUTION_TASVEG,
  ATTRIBUTION_TOPO,
  ATTRIBUTION_TREES,
  SEASON_KEYS,
  packOf,
  type RasterKey,
} from "./config";

export type OverlayMode = "veg" | "pre" | "geo" | "off";
export type BaseMode = "topo" | "tasmap" | "aerial" | "seasons";
export type Strength = "full" | "light" | "outline";

/** Everything the Layers sheet controls; persisted as one localStorage key. */
export interface LayerState {
  base: BaseMode;
  /** index into SEASON_KEYS: seasons up to and including this one are shown */
  cutoff: number;
  overlay: OverlayMode;
  strength: Strength;
  /** Hobart significant-tree register: an independent "also show" toggle,
   * not an overlay mode — it sits on top of whichever overlay is chosen. */
  trees: boolean;
}
export const DEFAULT_STATE: LayerState = {
  base: "topo",
  cutoff: SEASON_KEYS.length - 1,
  overlay: "veg",
  strength: "full",
  trees: false,
};
export const BASES: readonly BaseMode[] = ["topo", "tasmap", "aerial", "seasons"];
export const OVERLAYS: readonly OverlayMode[] = ["veg", "pre", "geo", "off"];
export const STRENGTHS: readonly Strength[] = ["full", "light", "outline"];

/** Background per base: what shows where an archive has no tile (pruned
 * ocean / no imagery). Aerial = the exact colour of LIST's constant ocean
 * tile (#1e525f); Tasmap = the sheets' printed sea (#aae0fc): the pack
 * drops the uniform-sea tiles of the 100K series and the transparent
 * beyond-the-sheet tiles of the 25K series, both of which are water
 * (measured from the learned sentinels, 2026-09-10). */
export const BASE_BG: Record<BaseMode, string> = {
  topo: "#eef3f0",
  seasons: "#eef3f0",
  tasmap: "#aae0fc",
  aerial: "#1e525f",
};

export const fillOpacity = (s: Strength): number =>
  s === "full" ? 0.5 : s === "light" ? 0.25 : 0;

export type Communities = Record<
  string,
  { name: string; group: string; color: string; outline: string; label: string }
>;
export const COMMUNITIES = communities as Communities;

export type GeologyUnits = Record<
  string,
  {
    description: string;
    group: string;
    strat: string;
    maxAge: string;
    minAge: string;
    maxMa: number | null;
    minMa: number | null;
    color: string;
    link: string;
  }
>;
export const GEOLOGY_UNITS = geologyUnits as GeologyUnits;

/** NVIS Major Vegetation Subgroups present in the Tasmanian pre-1750
 * reconstruction, keyed by MVS number (as string, matching tile props). */
export type Pre1750Units = Record<
  string,
  {
    name: string;
    group: string;
    groupDesc: string;
    color: string;
    order: number;
    groupOrder: number;
    ha: number;
  }
>;
export const PRE1750_UNITS = pre1750Units as Pre1750Units;

/** Hobart significant trees (pipeline/build_trees.py). Tiny dataset, so it
 * ships as bundled GeoJSON rather than a PMTiles archive: 460 points + 34
 * areas keyed by register `ref`; the per-ref facts live in `refs`, the
 * sheet PDFs are fetched on demand (sheets.ts). */
export interface TreeProps {
  /** register reference, e.g. "D5" */
  ref: string;
  /** ArcGIS Online item id of the data-sheet PDF */
  sheet: string;
  /** position-accuracy code (see `accuracy`) */
  acc: string;
}
export interface TreesData {
  meta: {
    item: string;
    source: string;
    licence: string;
    attribution: string;
    built: string;
    itemModified: string;
    points: number;
    areas: number;
  };
  points: FeatureCollection<Point, TreeProps>;
  areas: FeatureCollection<Polygon | MultiPolygon, TreeProps>;
  refs: Record<
    string,
    {
      /** botanical name, verbatim from the register (may hold "×", curly quotes) */
      name: string;
      /** Latin-1-safe short label for the map (glyphs are 0-255.pbf only) */
      label: string;
      /** common name, "" when the register has none */
      common: string;
      address: string;
      trees: number | null;
      /** Object_Metadata, verbatim (may be "") */
      note: string;
      sheets: string[];
    }
  >;
  accuracy: Record<string, string>;
  sheets: Record<string, { bytes: number; title: string }>;
}
export const TREES = trees as unknown as TreesData;
/** Tree layers a tap consults (details.ts), topmost first. */
export const TREE_LAYERS = ["trees-point", "trees-cluster", "trees-area-fill"] as const;
const TREE_GREEN = "#16940d";

function colorMatch(): ExpressionSpecification {
  const pairs: string[] = [];
  for (const [code, meta] of Object.entries(COMMUNITIES)) {
    pairs.push(code, meta.color);
  }
  return ["match", ["get", "VEGCODE"], ...pairs, "#c8c8c8"] as unknown as ExpressionSpecification;
}

/** ref -> short label, as a match expression (the tiles carry only `ref`). */
function treeLabelMatch(): ExpressionSpecification {
  const pairs: string[] = [];
  for (const [ref, meta] of Object.entries(TREES.refs)) pairs.push(ref, meta.label);
  return ["match", ["get", "ref"], ...pairs, ""] as unknown as ExpressionSpecification;
}

/** Raster layer ids == source ids == pack keys, in paint order. Topo stays
 * under the season stack so "no photo by then here" reads as the map. */
export const RASTER_LAYER_ORDER: readonly RasterKey[] = ["topo", "tasmap", "aerial", ...SEASON_KEYS];

/** Which packs are on this device (protocol.ts `status.rasterLocal`). */
export type LocalPacks = Partial<Record<RasterKey, boolean>>;

/** The topo map stays visible under the season stack (gaps read as map, not
 * sea) and under an aerial/Tasmap base that is NOT downloaded: while online
 * the imagery streams over it, offline the map is still usable instead of a
 * flat ocean-coloured screen (review finding). */
export function rasterVisibility(s: LayerState, local: LocalPacks = {}): Record<RasterKey, boolean> {
  const underlay = s.base === "seasons" || ((s.base === "aerial" || s.base === "tasmap") && !local[s.base]);
  const v: Partial<Record<RasterKey, boolean>> = {
    topo: s.base === "topo" || underlay,
    tasmap: s.base === "tasmap",
    aerial: s.base === "aerial",
  };
  SEASON_KEYS.forEach((k, i) => (v[k] = s.base === "seasons" && i <= s.cutoff));
  return v as Record<RasterKey, boolean>;
}

/** Background follows the base only once its archive is local; otherwise
 * the topo underlay is what shows through gaps. */
export function backgroundFor(s: LayerState, local: LocalPacks = {}): string {
  return (s.base === "aerial" || s.base === "tasmap") && !local[s.base] ? BASE_BG.topo : BASE_BG[s.base];
}

/** Overlay layer id -> visible. Outline/label layers stay on with their
 * overlay; strength only drives the fill opacity (Outlines = fill 0). */
export function overlayVisibility(s: LayerState): Record<string, boolean> {
  return {
    "tasveg-fill": s.overlay === "veg",
    "tasveg-outline": s.overlay === "veg",
    "tasveg-label": s.overlay === "veg",
    "geology-fill": s.overlay === "geo",
    "geology-outline": s.overlay === "geo",
    "pre1750-fill": s.overlay === "pre",
    "trees-area-fill": s.trees,
    "trees-area-outline": s.trees,
    "trees-cluster": s.trees,
    "trees-cluster-count": s.trees,
    "trees-point": s.trees,
    "trees-label": s.trees,
  };
}

/** Pre-1750 has no outline layer (1 ha cell edges would read as noise), so
 * "Outlines only" would leave nothing — it falls back to Light there. */
export function fillOpacityFor(overlay: OverlayMode, s: Strength): number {
  return overlay === "pre" && s === "outline" ? 0.25 : fillOpacity(s);
}

const vis = (on: boolean) => ({ visibility: on ? "visible" : "none" }) as const;

function rasterSource(key: RasterKey, attribution: string): RasterSourceSpecification {
  return {
    type: "raster",
    tiles: [`raster://${key}/{z}/{x}/{y}`],
    tileSize: 256,
    minzoom: 0,
    // the service's native ceiling (≤ 18): above the z15 packs, tiles come
    // from a downloaded detailed area or the live service; a miss throws so
    // MapLibre shows the stretched z15 parent instead of a hole
    maxzoom: packOf(key).maxzoom,
    attribution,
  };
}

export function buildStyle(s: LayerState, local: LocalPacks = {}): StyleSpecification {
  const rv = rasterVisibility(s, local);
  const ov = overlayVisibility(s);
  const opacity = fillOpacityFor(s.overlay, s.strength);
  const sources: StyleSpecification["sources"] = {
    topo: rasterSource("topo", ATTRIBUTION_TOPO),
    tasmap: rasterSource("tasmap", ATTRIBUTION_TASMAP),
    aerial: rasterSource("aerial", ATTRIBUTION_AERIAL),
  };
  for (const k of SEASON_KEYS) sources[k] = rasterSource(k, ATTRIBUTION_AERIAL);
  Object.assign(sources, {
    tasveg: { type: "vector", url: "pmtiles://tasveg", attribution: ATTRIBUTION_TASVEG },
    geology: { type: "vector", url: "pmtiles://geology", attribution: ATTRIBUTION_GEOLOGY },
    pre1750: { type: "vector", url: "pmtiles://pre1750", attribution: ATTRIBUTION_PRE1750 },
    selected: {
      type: "geojson",
      data: { type: "FeatureCollection", features: [] },
    },
    // dashed frame shown while the user frames a detailed-area download
    "area-frame": {
      type: "geojson",
      data: { type: "FeatureCollection", features: [] },
    },
    // Hobart significant trees: bundled GeoJSON, clustered until z15 so the
    // CBD does not read as one green smear (clusters are re-evaluated at
    // integer zooms: clusterMaxZoom 14 = clusters shown up to z15)
    "trees-points": {
      type: "geojson",
      data: TREES.points,
      cluster: true,
      clusterRadius: 32,
      clusterMaxZoom: 14,
      attribution: ATTRIBUTION_TREES,
    },
    "trees-areas": { type: "geojson", data: TREES.areas, attribution: ATTRIBUTION_TREES },
  });
  return {
    version: 8,
    // relative glyph path keeps it self-hosted (offline requirement)
    glyphs: "glyphs/{fontstack}/{range}.pbf",
    sources,
    layers: [
      { id: "bg", type: "background", paint: { "background-color": backgroundFor(s, local) } },
      ...RASTER_LAYER_ORDER.map((key) => ({
        id: key,
        type: "raster" as const,
        source: key,
        layout: vis(rv[key]),
        // stacked seasons cross-fading independently flicker — snap instead
        paint: (SEASON_KEYS as readonly string[]).includes(key) ? { "raster-fade-duration": 0 } : {},
      })),
      {
        id: "tasveg-fill",
        type: "fill",
        source: "tasveg",
        "source-layer": "tasveg",
        layout: vis(ov["tasveg-fill"]),
        paint: { "fill-color": colorMatch(), "fill-opacity": opacity },
      },
      {
        id: "tasveg-outline",
        type: "line",
        source: "tasveg",
        "source-layer": "tasveg",
        minzoom: 11,
        layout: vis(ov["tasveg-outline"]),
        paint: { "line-color": "#c8c800", "line-width": 1 },
      },
      {
        id: "geology-fill",
        type: "fill",
        source: "geology",
        "source-layer": "geology",
        layout: vis(ov["geology-fill"]),
        // official MRT unit colour ships per-feature in the tiles
        paint: { "fill-color": ["get", "color"], "fill-opacity": opacity },
      },
      {
        id: "geology-outline",
        type: "line",
        source: "geology",
        "source-layer": "geology",
        minzoom: 9,
        layout: vis(ov["geology-outline"]),
        paint: { "line-color": "#5a5147", "line-width": 0.8 },
      },
      {
        id: "pre1750-fill",
        type: "fill",
        source: "pre1750",
        "source-layer": "pre1750",
        layout: vis(ov["pre1750-fill"]),
        // official NVIS class colour ships per-feature in the tiles; no
        // outline layer — the 1-ha cell edges would read as noise
        paint: { "fill-color": ["get", "color"], "fill-opacity": opacity },
      },
      {
        id: "area-frame",
        type: "line",
        source: "area-frame",
        paint: { "line-color": "#1e4434", "line-width": 3, "line-dasharray": [2, 1.5] },
      },
      {
        id: "tasveg-label",
        type: "symbol",
        source: "tasveg",
        "source-layer": "tasveg",
        minzoom: 13,
        layout: {
          ...vis(ov["tasveg-label"]),
          "text-field": ["get", "VEGCODE"],
          "text-font": ["Noto Sans Bold"],
          "text-size": 13,
        },
        paint: {
          "text-color": "#f5e600",
          "text-halo-color": "#3a3a00",
          "text-halo-width": 1.4,
        },
      },
      // ---- Hobart significant trees: MUST REMAIN LAST (they sit on top of
      // every overlay and its labels; a test pins the order), followed only
      // by the two selection highlights. ----
      {
        id: "trees-area-fill",
        type: "fill",
        source: "trees-areas",
        minzoom: 12,
        layout: vis(ov["trees-area-fill"]),
        paint: { "fill-color": "#b3fc08", "fill-opacity": 0.35 },
      },
      {
        id: "trees-area-outline",
        type: "line",
        source: "trees-areas",
        minzoom: 12,
        layout: vis(ov["trees-area-outline"]),
        paint: { "line-color": TREE_GREEN, "line-width": 2 },
      },
      {
        id: "trees-cluster",
        type: "circle",
        source: "trees-points",
        filter: ["has", "point_count"],
        minzoom: 10,
        layout: vis(ov["trees-cluster"]),
        paint: {
          "circle-radius": ["step", ["get", "point_count"], 14, 10, 18, 50, 24],
          "circle-color": TREE_GREEN,
          "circle-stroke-color": "#ffffff",
          "circle-stroke-width": 2,
        },
      },
      {
        id: "trees-cluster-count",
        type: "symbol",
        source: "trees-points",
        filter: ["has", "point_count"],
        minzoom: 10,
        layout: {
          ...vis(ov["trees-cluster-count"]),
          "text-field": ["get", "point_count_abbreviated"],
          "text-font": ["Noto Sans Bold"],
          "text-size": 12,
          "text-allow-overlap": true,
        },
        paint: { "text-color": "#ffffff" },
      },
      {
        id: "trees-point",
        type: "circle",
        source: "trees-points",
        filter: ["!", ["has", "point_count"]],
        minzoom: 10,
        layout: vis(ov["trees-point"]),
        paint: {
          "circle-radius": ["interpolate", ["linear"], ["zoom"], 10, 3, 16, 7],
          "circle-color": TREE_GREEN,
          "circle-stroke-color": "#ffffff",
          "circle-stroke-width": 1.5,
        },
      },
      {
        id: "trees-label",
        type: "symbol",
        source: "trees-points",
        filter: ["!", ["has", "point_count"]],
        minzoom: 16,
        layout: {
          ...vis(ov["trees-label"]),
          "text-field": treeLabelMatch(),
          "text-font": ["Noto Sans Regular"],
          "text-size": 11,
          "text-anchor": "top",
          "text-offset": [0, 0.9],
          "text-optional": true,
        },
        paint: {
          "text-color": "#ffffff",
          "text-halo-color": "#1e3a1e",
          "text-halo-width": 1.2,
        },
      },
      // Selection highlights sit above the trees too: a selected tree AREA's
      // red outline was tinted and mostly overpainted by trees-area-fill/
      // -outline when this layer lived below them (review finding).
      {
        id: "selected-outline",
        type: "line",
        source: "selected",
        paint: {
          "line-color": "#ff3b30",
          "line-width": 3,
        },
      },
      // ring around a selected tree point (selected-outline covers polygons)
      {
        id: "selected-point",
        type: "circle",
        source: "selected",
        filter: ["==", ["geometry-type"], "Point"],
        paint: {
          "circle-radius": 11,
          "circle-color": "rgba(0,0,0,0)",
          "circle-stroke-color": "#ff3b30",
          "circle-stroke-width": 3,
        },
      },
    ],
  };
}

/** Push a LayerState onto a loaded map (the style's layers must exist —
 * callers defer to the load event before the first call). */
export function applyLayerState(map: MlMap, s: LayerState, local: LocalPacks = {}): void {
  map.setPaintProperty("bg", "background-color", backgroundFor(s, local));
  const rv = rasterVisibility(s, local);
  for (const key of RASTER_LAYER_ORDER)
    map.setLayoutProperty(key, "visibility", rv[key] ? "visible" : "none");
  const ov = overlayVisibility(s);
  for (const [id, on] of Object.entries(ov))
    map.setLayoutProperty(id, "visibility", on ? "visible" : "none");
  const opacity = fillOpacityFor(s.overlay, s.strength);
  if (s.overlay === "veg") map.setPaintProperty("tasveg-fill", "fill-opacity", opacity);
  if (s.overlay === "geo") map.setPaintProperty("geology-fill", "fill-opacity", opacity);
  if (s.overlay === "pre") map.setPaintProperty("pre1750-fill", "fill-opacity", opacity);
}
