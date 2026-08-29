// Assembles the MapLibre style: LIST topo raster + TASVEG vector overlay
// using the official community colours (generated from the QML by the
// pipeline). Mimics LISTmap's "TASVEG 5.0" + "Outlines and Labels" look.
import type { StyleSpecification, ExpressionSpecification } from "maplibre-gl";
import communities from "./generated/tasveg_communities.json";
import geologyUnits from "./generated/geology_units.json";
import { ATTRIBUTION, TOPO_MAXZOOM } from "./config";

export type OverlayMode = "veg" | "geo" | "off";

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

function colorMatch(): ExpressionSpecification {
  const pairs: string[] = [];
  for (const [code, meta] of Object.entries(COMMUNITIES)) {
    pairs.push(code, meta.color);
  }
  return ["match", ["get", "VEGCODE"], ...pairs, "#c8c8c8"] as unknown as ExpressionSpecification;
}

export function buildStyle(mode: OverlayMode, opacity: number): StyleSpecification {
  const vegVisible = mode === "veg";
  const geoVisible = mode === "geo";
  const vegOpacity = opacity;
  return {
    version: 8,
    // relative glyph path keeps it self-hosted (offline requirement)
    glyphs: "glyphs/{fontstack}/{range}.pbf",
    sources: {
      topo: {
        type: "raster",
        tiles: ["topo://{z}/{x}/{y}"],
        tileSize: 256,
        minzoom: 0,
        maxzoom: TOPO_MAXZOOM,
        attribution: ATTRIBUTION,
      },
      tasveg: {
        type: "vector",
        url: "pmtiles://tasveg",
      },
      geology: {
        type: "vector",
        url: "pmtiles://geology",
      },
      selected: {
        type: "geojson",
        data: { type: "FeatureCollection", features: [] },
      },
    },
    layers: [
      { id: "bg", type: "background", paint: { "background-color": "#eef3f0" } },
      { id: "topo", type: "raster", source: "topo" },
      {
        id: "tasveg-fill",
        type: "fill",
        source: "tasveg",
        "source-layer": "tasveg",
        layout: { visibility: vegVisible ? "visible" : "none" },
        paint: { "fill-color": colorMatch(), "fill-opacity": vegOpacity },
      },
      {
        id: "tasveg-outline",
        type: "line",
        source: "tasveg",
        "source-layer": "tasveg",
        minzoom: 11,
        layout: { visibility: vegVisible ? "visible" : "none" },
        paint: { "line-color": "#c8c800", "line-width": 1 },
      },
      {
        id: "geology-fill",
        type: "fill",
        source: "geology",
        "source-layer": "geology",
        layout: { visibility: geoVisible ? "visible" : "none" },
        // official MRT unit colour ships per-feature in the tiles
        paint: { "fill-color": ["get", "color"], "fill-opacity": opacity },
      },
      {
        id: "geology-outline",
        type: "line",
        source: "geology",
        "source-layer": "geology",
        minzoom: 9,
        layout: { visibility: geoVisible ? "visible" : "none" },
        paint: { "line-color": "#5a5147", "line-width": 0.8 },
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
        id: "tasveg-label",
        type: "symbol",
        source: "tasveg",
        "source-layer": "tasveg",
        minzoom: 13,
        layout: {
          visibility: vegVisible ? "visible" : "none",
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
