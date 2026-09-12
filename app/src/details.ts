// Tap -> community details bottom sheet (the offline "identify" panel).
import type { GeoJSONSource, Map, MapGeoJSONFeature } from "maplibre-gl";
import type { Point } from "geojson";
import { COMMUNITIES, GEOLOGY_UNITS, PRE1750_UNITS, TREES, TREE_LAYERS, type TreeProps } from "./style";
import f2f from "./generated/f2f_index.json";
import { opfsFile } from "./storage";
import { SHEETS_TOTAL_BYTES, SheetError, fetchSheet, fmtSheetMB, goneSheets, sheetPath } from "./sheets";
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

  const selection = () => map.getSource("selected") as GeoJSONSource | undefined;
  // The tap-fetch of a tree's data sheet in flight, if any: dismissing the
  // card (or showing another tree) aborts it so the viewer can never pop up
  // over whatever the user moved on to.
  let sheetFetch: AbortController | null = null;
  const cancelSheetFetch = () => {
    sheetFetch?.abort();
    sheetFetch = null;
  };
  const clearSelection = () => {
    cancelSheetFetch();
    sheet.hidden = true;
    selection()?.setData({ type: "FeatureCollection", features: [] });
  };

  clearDetails = clearSelection;

  map.on("click", (e) => {
    // Trees first: a dot is a small target, so it gets a 12 px padded box
    // (hidden layers yield nothing — the toggle off costs nothing here).
    // Among dots the NEAREST answers, not the topmost: 16 register pairs
    // stand < 12 m apart (M6/M7 5 m), all inside one box at z17. A dot
    // still beats an area or a cluster under it (topmost-first fallback).
    const pad = 12;
    const hits = map.queryRenderedFeatures(
      [[e.point.x - pad, e.point.y - pad], [e.point.x + pad, e.point.y + pad]],
      { layers: [...TREE_LAYERS] },
    );
    let tree: MapGeoJSONFeature | undefined;
    let best = Infinity;
    for (const h of hits) {
      if (h.layer.id !== "trees-point") continue;
      const d = e.point.dist(map.project((h.geometry as Point).coordinates as [number, number]));
      if (d < best) {
        best = d;
        tree = h;
      }
    }
    tree ??= hits[0];
    if (tree) {
      if (tree.layer.id === "trees-cluster") {
        // a cluster is not a tree: zoom to where it splits (Promise in
        // MapLibre 6), capped so the whole CBD never jumps to street level
        clearSelection();
        const src = map.getSource("trees-points") as GeoJSONSource;
        const center = (tree.geometry as Point).coordinates as [number, number];
        void src
          .getClusterExpansionZoom(tree.properties.cluster_id as number)
          .then((z) => map.easeTo({ center, zoom: Math.min(z, 17) }))
          .catch(() => map.easeTo({ center, zoom: map.getZoom() + 2 }));
        return;
      }
      selection()?.setData({ type: "Feature", geometry: tree.geometry, properties: {} });
      showTree(tree);
      return;
    }
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
   * callers wire anything in their tail afterwards. `kind` is stamped on
   * #sheet as data-kind so main.ts can tell a tree card from an overlay
   * answer (a trees toggle must not dismiss a vegetation card, nor an
   * overlay switch a tree card). */
  function renderSheet(o: {
    kind: "veg" | "geo" | "pre" | "tree";
    color: string;
    code: string;
    name: string;
    rows: [string, string | undefined][];
    tail: string;
  }): void {
    cancelSheetFetch(); // a new card supersedes the previous tree's fetch
    sheet.dataset.kind = o.kind;
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
      kind: "pre",
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
      kind: "geo",
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

  /** Significant-tree card: the register facts from the bundled table and
   * a button for the council's data sheet (a PDF the device fetches from
   * arcgis.com once and keeps; the caption says which it will be). */
  function showTree(f: MapGeoJSONFeature) {
    const p = f.properties as Partial<TreeProps>;
    const ref = p.ref ?? "?";
    const meta = TREES.refs[ref];
    const id = p.sheet && TREES.sheets[p.sheet] ? p.sheet : meta?.sheets[0] ?? "";
    const bytes = TREES.sheets[id]?.bytes ?? 0;
    const caption = (tail: string) => `City of Hobart · ${fmtSheetMB(bytes)} · ${tail}`;
    renderSheet({
      kind: "tree",
      color: "#16940d",
      code: ref,
      name: meta?.name ?? "Significant tree",
      rows: [
        ["Common name", meta?.common || undefined],
        ["Address", meta?.address],
        ["Trees in this listing", meta?.trees && meta.trees > 1 ? String(meta.trees) : undefined],
        ["Register note", meta?.note || undefined],
        ["Position accuracy", p.acc ? TREES.accuracy[p.acc] : undefined],
      ],
      tail: id
        ? `<button class="sheet-desc" data-sheet="${esc(id)}">Open the data sheet
             <small>${esc(caption("checking…"))}</small></button>`
        : "",
    });
    const btn = sheet.querySelector<HTMLButtonElement>(".sheet-desc");
    if (!btn) return;
    const small = btn.querySelector("small")!;
    const title = meta ? `${meta.label} — ${ref}` : `Significant tree ${ref}`;
    // Which path the button will take. Guarded: the sheet may show another
    // tree by the time OPFS answers (innerHTML replaced -> btn detached).
    const refresh = () =>
      localSheet(id).then((file) => {
        if (!btn.isConnected) return;
        small.textContent = caption(
          file ? "on this device"
            : goneSheets()[id] ? "not published by the council any more — tap to check again"
            : "fetched and kept the first time — needs reception",
        );
      });
    void refresh();
    btn.onclick = async () => {
      btn.disabled = true;
      if (!(await localSheet(id)) && btn.isConnected) small.textContent = caption("fetching…");
      // Bounded and cancellable: a 30 s ceiling (a stalled cellular fetch
      // must not hold the button for ever) and an abort when the card goes
      // away; the viewer opens only if this card still shows this tree.
      const ctl = (sheetFetch = new AbortController());
      const timer = setTimeout(() => ctl.abort(new DOMException("timed out", "TimeoutError")), 30_000);
      try {
        await openTreeSheet(id, title, ctl.signal, () => btn.isConnected && !sheet.hidden);
      } finally {
        clearTimeout(timer);
        if (sheetFetch === ctl) sheetFetch = null;
        btn.disabled = false;
        void refresh();
      }
    };
  }

  function show(f: MapGeoJSONFeature) {
    const p = f.properties as Record<string, string>;
    const code = p.VEGCODE ?? "?";
    const meta = COMMUNITIES[code];
    const rawName = p.VEGCODE_D ?? meta?.name ?? "Unknown community";
    renderSheet({
      kind: "veg",
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

/** The stored sheet, or null — a zero-byte shell (an interrupted copy
 * fallback in storage.ts) is not a sheet pdf.js could open. */
async function localSheet(id: string): Promise<File | null> {
  const file = await opfsFile(sheetPath(id));
  return file && file.size > 0 ? file : null;
}

const NOT_ON_DEVICE =
  "This data sheet isn't on the device yet — open it once while online, or download all " +
  `sheets from Offline maps (${Math.round(SHEETS_TOTAL_BYTES / 1e6)} MB).`;

/** Open a tree's data sheet in the in-app viewer. Offline: the OPFS copy
 * (from an earlier tap or the bulk download). Otherwise fetch it once from
 * arcgis.com into OPFS and open THAT — pdf.js is only ever handed a local
 * File, never the remote URL. A withdrawn ("gone") id is still tried: the
 * council may have republished it, and a success forgets the mark. */
async function openTreeSheet(
  id: string,
  title: string,
  signal: AbortSignal,
  stillWanted: () => boolean,
): Promise<void> {
  let file = await localSheet(id);
  if (!file) {
    try {
      await fetchSheet(id, signal);
      file = await localSheet(id);
    } catch (e) {
      // our own abort = the card was dismissed; nothing to tell anyone
      if (signal.aborted && e instanceof SheetError && e.kind === "aborted") return;
      // no reception (or a fetch someone else cancelled): say how to get it;
      // anything else — withdrawn, captive portal, HTTP 5xx, timeout — the
      // SheetError message already explains (review finding: the offline
      // wording used to answer every failure, even while online)
      const offline = !(e instanceof SheetError) || e.kind === "offline" || e.kind === "aborted";
      if (stillWanted()) alert(offline ? NOT_ON_DEVICE : e.message);
      return;
    }
  }
  if (!file) {
    if (stillWanted()) alert(NOT_ON_DEVICE);
    return;
  }
  if (!stillWanted()) return;
  await openPdfViewer(file, 0, title);
}
