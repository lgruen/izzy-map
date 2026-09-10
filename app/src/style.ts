// Assembles the MapLibre style: base rasters (topo / Tasmap scans / aerial
// photos / the chronological season stack) + the vector overlays using the
// official colours (generated from the QML etc. by the pipeline). Mimics
// LISTmap's "TASVEG 5.0" + "Outlines and Labels" look.
import type { StyleSpecification, ExpressionSpecification, RasterSourceSpecification } from "maplibre-gl";
import type { Map as MlMap } from "maplibre-gl";
import communities from "./generated/tasveg_communities.json";
import geologyUnits from "./generated/geology_units.json";
import pre1750Units from "./generated/pre1750_units.json";
import {
  ATTRIBUTION_AERIAL,
  ATTRIBUTION_GEOLOGY,
  ATTRIBUTION_PRE1750,
  ATTRIBUTION_TASMAP,
  ATTRIBUTION_TASVEG,
  ATTRIBUTION_TOPO,
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
}
export const DEFAULT_STATE: LayerState = {
  base: "topo",
  cutoff: SEASON_KEYS.length - 1,
  overlay: "veg",
  strength: "full",
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

function colorMatch(): ExpressionSpecification {
  const pairs: string[] = [];
  for (const [code, meta] of Object.entries(COMMUNITIES)) {
    pairs.push(code, meta.color);
  }
  return ["match", ["get", "VEGCODE"], ...pairs, "#c8c8c8"] as unknown as ExpressionSpecification;
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
        id: "selected-outline",
        type: "line",
        source: "selected",
        paint: {
          "line-color": "#ff3b30",
          "line-width": 3,
        },
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
