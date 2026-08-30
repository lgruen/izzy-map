// Tap -> community details bottom sheet (the offline "identify" panel).
import type maplibregl from "maplibre-gl";
import type { Map, MapGeoJSONFeature } from "maplibre-gl";
import { COMMUNITIES, GEOLOGY_UNITS, PRE1750_UNITS } from "./style";
import f2f from "./generated/f2f_index.json";
import { opfsFile } from "./storage";
// Static import (not dynamic): a skipWaiting SW update while the app is
// resident would purge an old lazy chunk and strand descriptions offline.
import { openPdfViewer } from "./viewer";

const F2F = f2f as { baseUrl: string; index: Record<string, { file: string; page: number }> };

/** Plain-English age for a lay reader: numbers first, no stage jargon.
 * The common cases (statewide dolerite, beach sand) must read well. */
export function formatAge(maxMa: number | null, minMa: number | null): string {
  if (maxMa == null) return "";
  const fmt = (ma: number) => (ma >= 10 ? String(Math.round(ma)) : ma.toFixed(1));
  if (maxMa < 0.02) return "Geologically recent (roughly the last 12,000 years)";
  const hi = fmt(maxMa);
  if (minMa == null || fmt(minMa) === hi) return `About ${hi} million years old`;
  if (minMa < 0.02) return `About ${hi} million years ago – recent`;
  return `About ${hi}–${fmt(minMa)} million years old`;
}

const esc = (s: string) =>
  s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!);

/** Closes the sheet and clears the highlight — assigned by wireDetails so
 * the overlay switcher can dismiss a stale answer on mode change. */
export let clearDetails: () => void = () => {};

export function wireDetails(map: Map): void {
  const sheet = document.getElementById("sheet")!;

  const selection = () => map.getSource("selected") as maplibregl.GeoJSONSource | undefined;
  const clearSelection = () => {
    sheet.hidden = true;
    selection()?.setData({ type: "FeatureCollection", features: [] });
  };

  clearDetails = clearSelection;

  map.on("click", (e) => {
    // Hidden layers yield nothing, so this naturally answers for whichever
    // overlay is active.
    const feats = map.queryRenderedFeatures(e.point, {
      layers: ["tasveg-fill", "geology-fill", "pre1750-fill"],
    });
    if (!feats.length) {
      clearSelection();
      return;
    }
    // Outline the answering polygon (tile-clipped geometry is fine for a
    // highlight) so near boundaries it's clear which one was identified.
    selection()?.setData({
      type: "Feature",
      geometry: feats[0].geometry,
      properties: {},
    });
    if (feats[0].layer.id === "geology-fill") showGeology(feats[0]);
    else if (feats[0].layer.id === "pre1750-fill") showPre1750(feats[0]);
    else show(feats[0]);
  });

  /** Shared sheet shell (handle, close button, swatch + code + name head,
   * key/value rows, overlay-specific tail markup). Wires the close button;
   * callers wire anything in their tail afterwards. */
  function renderSheet(o: {
    color: string;
    code: string;
    name: string;
    rows: [string, string | undefined][];
    tail: string;
  }): void {
    sheet.innerHTML = `
      <div class="handle"></div>
      <button class="sheet-close" aria-label="Close">×</button>
      <div class="sheet-head">
        <span class="swatch" style="background:${esc(o.color)}"></span>
        <div>
          <span class="sheet-code">${esc(o.code)}</span>
          <div class="sheet-name">${esc(o.name)}</div>
        </div>
      </div>
      ${o.rows
        .filter(([, v]) => v && v.trim())
        .map(([k, v]) => `<div class="kv"><span>${esc(k)}</span><span>${esc(v!)}</span></div>`)
        .join("")}
      ${o.tail}`;
    sheet.hidden = false;
    sheet.querySelector<HTMLButtonElement>(".sheet-close")!.onclick = clearSelection;
  }

  function showPre1750(f: MapGeoJSONFeature) {
    const p = f.properties as Record<string, string>;
    const mvs = p.MVS ?? "?";
    const unit = PRE1750_UNITS[mvs];
    // 1 cell = 1 ha; the estimated pre-1750 extent across Tasmania. Tiny
    // classes (a few cells) must not round to "0 km²".
    const extent = !unit ? undefined
      : unit.ha < 100 ? `${unit.ha} ha statewide`
      : `~${Math.round(unit.ha / 100).toLocaleString()} km² statewide`;
    renderSheet({
      color: unit?.color ?? "#c8c8c8",
      code: `MVS ${mvs}`,
      name: unit?.name || "Unknown class",
      rows: [
        ["Group", unit ? `${unit.group} — ${unit.groupDesc}` : undefined],
        ["Pre-1750 extent", extent],
      ],
      tail: `<p class="sheet-note">Estimated vegetation before European clearing —
        a model built from remnants and historical records (NVIS&nbsp;V7.0,
        1&nbsp;ha cells). Cell edges are grid artefacts, not real boundaries.</p>`,
    });
  }

  function showGeology(f: MapGeoJSONFeature) {
    const p = f.properties as Record<string, string>;
    const symb = p.SYMB ?? "?";
    const unit = GEOLOGY_UNITS[symb];
    renderSheet({
      color: unit?.color ?? "#c8c8c8",
      code: symb,
      name: unit?.description || "Unknown unit",
      rows: [
        ["Stratigraphy", unit?.strat],
        ["Age", formatAge(unit?.maxMa ?? null, unit?.minMa ?? null)],
        ["Group", unit?.group],
      ],
      tail: unit?.link
        ? `<button class="sheet-desc" data-link="${esc(unit.link)}">More about this unit
             <small>Geoscience Australia — needs reception</small></button>`
        : "",
    });
    sheet.querySelector<HTMLButtonElement>(".sheet-desc")?.addEventListener("click", () => {
      if (!navigator.onLine) {
        alert("This link needs reception — try again when you have signal.");
        return;
      }
      window.open(unit!.link, "_blank");
    });
  }

  function show(f: MapGeoJSONFeature) {
    const p = f.properties as Record<string, string>;
    const code = p.VEGCODE ?? "?";
    const meta = COMMUNITIES[code];
    const rawName = p.VEGCODE_D ?? meta?.name ?? "Unknown community";
    renderSheet({
      color: meta?.color ?? "#c8c8c8",
      code,
      name: rawName.replace(/^\([A-Z]{3}\)\s*/, ""), // chip already shows the code
      rows: [
        ["Group", p.VEG_GROUP],
        ["Forest structure", p.FOREST_STR],
        ["Notable tree", p.NOTABLE_TD],
        ["Weed type", p.WEED_TYP_D],
      ],
      tail: `<button class="sheet-desc" data-code="${esc(code)}">Read the full description
        <small>From Forest to Fjaeldmark</small></button>`,
    });
    sheet.querySelector<HTMLButtonElement>(".sheet-desc")!.onclick = () => openDescription(code);
  }
}

/** Open the F2F chapter for a community at its section page, in the in-app
 * pdf.js viewer. Offline: from the OPFS copy (downloaded during setup).
 * Online fallback: via the CORS proxy straight off nre.tas.gov.au. */
async function openDescription(code: string): Promise<void> {
  const entry = F2F.index[code];
  if (!entry) return;
  const local = await opfsFile("f2f/" + entry.file).catch(() => null);
  const proxy = (import.meta.env.VITE_F2F_PROXY as string | undefined) ?? "";
  const title = COMMUNITIES[code]?.label ?? code;
  if (local) {
    await openPdfViewer(local, entry.page, title);
  } else if (navigator.onLine && proxy) {
    await openPdfViewer(`${proxy}/${entry.file}`, entry.page, title);
  } else {
    alert("Descriptions aren't downloaded yet — open the offline maps panel (⬇) while online.");
  }
}
