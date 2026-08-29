// Tap -> community details bottom sheet (the offline "identify" panel).
import type { Map, MapGeoJSONFeature } from "maplibre-gl";
import { COMMUNITIES } from "./style";
import f2f from "./generated/f2f_index.json";
import { opfsFile } from "./storage";

const F2F = f2f as { baseUrl: string; index: Record<string, { file: string; page: number }> };

const esc = (s: string) =>
  s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!);

export function wireDetails(map: Map): void {
  const sheet = document.getElementById("sheet")!;

  map.on("click", (e) => {
    const feats = map.queryRenderedFeatures(e.point, { layers: ["tasveg-fill"] });
    if (!feats.length) {
      sheet.hidden = true;
      return;
    }
    show(feats[0]);
  });

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
    sheet.innerHTML = `
      <button class="sheet-close" aria-label="Close">×</button>
      <div class="sheet-head">
        <span class="swatch" style="background:${meta?.color ?? "#c8c8c8"}"></span>
        <div>
          <div class="sheet-code">${esc(code)}</div>
          <div class="sheet-name">${esc(p.VEGCODE_D ?? meta?.name ?? "Unknown community")}</div>
        </div>
      </div>
      ${rows
        .filter(([, v]) => v && v.trim())
        .map(([k, v]) => `<div class="kv"><span>${k}</span><span>${esc(v!)}</span></div>`)
        .join("")}
      <button class="sheet-desc" data-code="${esc(code)}">Full description
        <small>From Forest to Fjaeldmark</small></button>`;
    sheet.hidden = false;
    sheet.querySelector<HTMLButtonElement>(".sheet-close")!.onclick = () => (sheet.hidden = true);
    sheet.querySelector<HTMLButtonElement>(".sheet-desc")!.onclick = () => openDescription(code);
  }
}

/** Open the F2F chapter for a community, at its section page.
 * Offline: from the OPFS copy (downloaded during setup). Online fallback:
 * straight from nre.tas.gov.au (their server, their content). */
async function openDescription(code: string): Promise<void> {
  const entry = F2F.index[code];
  if (!entry) return;
  const local = await opfsFile("f2f/" + entry.file).catch(() => null);
  const pageFrag = `#page=${entry.page + 1}`;
  if (local) {
    const url = URL.createObjectURL(local);
    window.open(url + pageFrag, "_blank");
  } else if (navigator.onLine) {
    window.open(F2F.baseUrl + entry.file + pageFrag, "_blank");
  } else {
    alert("Description PDFs not downloaded yet — open Settings ⬇ while online.");
  }
}
