// Tap -> community details bottom sheet (the offline "identify" panel).
import type maplibregl from "maplibre-gl";
import type { Map, MapGeoJSONFeature } from "maplibre-gl";
import { COMMUNITIES, GEOLOGY_UNITS } from "./style";
import f2f from "./generated/f2f_index.json";
import { opfsFile } from "./storage";
// Static import (not dynamic): a skipWaiting SW update while the app is
// resident would purge an old lazy chunk and strand descriptions offline.
import { openPdfViewer } from "./viewer";

const F2F = f2f as { baseUrl: string; index: Record<string, { file: string; page: number }> };

const esc = (s: string) =>
  s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!);

export function wireDetails(map: Map): void {
  const sheet = document.getElementById("sheet")!;

  const selection = () => map.getSource("selected") as maplibregl.GeoJSONSource | undefined;
  const clearSelection = () => {
    sheet.hidden = true;
    selection()?.setData({ type: "FeatureCollection", features: [] });
  };

  map.on("click", (e) => {
    // Hidden layers yield nothing, so this naturally answers for whichever
    // overlay is active.
    const feats = map.queryRenderedFeatures(e.point, {
      layers: ["tasveg-fill", "geology-fill"],
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
    else show(feats[0]);
  });

  function showGeology(f: MapGeoJSONFeature) {
    const p = f.properties as Record<string, string>;
    const symb = p.SYMB ?? "?";
    const unit = GEOLOGY_UNITS[symb];
    const ages =
      unit && (unit.maxAge || unit.minAge)
        ? `${unit.maxAge}${unit.minAge && unit.minAge !== unit.maxAge ? " – " + unit.minAge : ""}` +
          (unit.maxMa != null && unit.minMa != null
            ? ` (≈${Math.round(unit.maxMa)}–${Math.round(unit.minMa)} Ma)`
            : "")
        : "";
    const rows: [string, string | undefined][] = [
      ["Stratigraphy", p.STRAT || unit?.strat],
      ["Age", ages],
      ["Group", unit?.group],
    ];
    sheet.innerHTML = `
      <div class="handle"></div>
      <button class="sheet-close" aria-label="Close">×</button>
      <div class="sheet-head">
        <span class="swatch" style="background:${unit?.color ?? "#c8c8c8"}"></span>
        <div>
          <span class="sheet-code">${esc(symb)}</span>
          <div class="sheet-name">${esc(p.DESC || unit?.description || "Unknown unit")}</div>
        </div>
      </div>
      ${rows
        .filter(([, v]) => v && v.trim())
        .map(([k, v]) => `<div class="kv"><span>${k}</span><span>${esc(v!)}</span></div>`)
        .join("")}
      ${unit?.link
        ? `<button class="sheet-desc" data-link="${esc(unit.link)}">More about this unit
             <small>Geoscience Australia — needs reception</small></button>`
        : ""}`;
    sheet.hidden = false;
    sheet.querySelector<HTMLButtonElement>(".sheet-close")!.onclick = clearSelection;
    sheet.querySelector<HTMLButtonElement>(".sheet-desc")?.addEventListener("click", () => {
      window.open(unit!.link, "_blank");
    });
  }

  function show(f: MapGeoJSONFeature) {
    const p = f.properties as Record<string, string>;
    const code = p.VEGCODE ?? "?";
    const meta = COMMUNITIES[code];
    const rows: [string, string | undefined][] = [
      ["Group", p.VEG_GROUP],
      ["Forest structure", p.FOREST_STR],
      ["Notable tree", p.NOTABLE_TD],
      ["Weed type", p.WEED_TYP_D],
    ];
    const rawName = p.VEGCODE_D ?? meta?.name ?? "Unknown community";
    const name = rawName.replace(/^\([A-Z]{3}\)\s*/, ""); // chip already shows the code
    sheet.innerHTML = `
      <div class="handle"></div>
      <button class="sheet-close" aria-label="Close">×</button>
      <div class="sheet-head">
        <span class="swatch" style="background:${meta?.color ?? "#c8c8c8"}"></span>
        <div>
          <span class="sheet-code">${esc(code)}</span>
          <div class="sheet-name">${esc(name)}</div>
        </div>
      </div>
      ${rows
        .filter(([, v]) => v && v.trim())
        .map(([k, v]) => `<div class="kv"><span>${k}</span><span>${esc(v!)}</span></div>`)
        .join("")}
      <button class="sheet-desc" data-code="${esc(code)}">Read the full description
        <small>From Forest to Fjaeldmark</small></button>`;
    sheet.hidden = false;
    sheet.querySelector<HTMLButtonElement>(".sheet-close")!.onclick = clearSelection;
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
