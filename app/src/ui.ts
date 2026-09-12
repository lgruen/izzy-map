// Panels: layers, offline downloads manager, legend, about. One panel at a time.
import type { Map as MlMap } from "maplibre-gl";
import {
  ARCHIVES,
  BASE_KEYS,
  DATA_BASE,
  DETAIL_LEVELS,
  RASTER_MAXZOOM,
  SEASON_KEYS,
  TREE_SHEET_DIR,
  packOf,
  seasonLabel,
  type RasterKey,
} from "./config";
import {
  MAX_AREA_TILES,
  activeAreaDownload,
  deleteArea,
  downloadAreaLayer,
  estimateArea,
  listAreas,
  tileCount,
  upsertArea,
  type AreaMeta,
  type BBox,
} from "./areas";
import {
  QUOTA_MARGIN,
  activeDownload,
  deleteFile,
  download,
  listDir,
  opfsFile,
  partialBytes,
  storageInfo,
} from "./storage";
import {
  COMMUNITIES,
  GEOLOGY_UNITS,
  PRE1750_UNITS,
  TREES,
  type BaseMode,
  type LayerState,
  type OverlayMode,
  type Strength,
} from "./style";
import { GEO_CHIPS, PRE_CHIPS } from "./chips";
import { refreshArchives, refreshRasterTiles, seasonAt, status, tileAt } from "./protocol";
import {
  SHEET_IDS,
  SHEETS_TOTAL_BYTES,
  SheetError,
  clearGoneSheets,
  fetchSheet,
  goneSheets,
  markSheetGone,
  sheetPath,
} from "./sheets";
import f2f from "./generated/f2f_index.json";

const F2F = f2f as { baseUrl: string; index: Record<string, { file: string; page: number }> };
// F2F PDFs have no CORS on nre.tas.gov.au; this transparent non-caching
// relay adds it (see docs/LICENSING.md and pipeline/f2f-proxy/).
const F2F_PROXY: string = import.meta.env.VITE_F2F_PROXY ?? "";

const esc = (s: string) =>
  s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!);
const fmtMB = (b: number) => (b >= 1e9 ? (b / 1e9).toFixed(2) + " GB" : Math.round(b / 1e6) + " MB");
const fmtProgress = (p: { received: number; total: number | null }) =>
  `${fmtMB(p.received)}${p.total ? " of " + fmtMB(p.total) : ""}`;

interface DataManifest {
  version: string;
  archives: Record<string, { file: string; bytes: number; built?: string; note?: string }>;
}

async function fetchManifest(): Promise<DataManifest | null> {
  try {
    const r = await fetch(`${DATA_BASE}/data-manifest.json`, { cache: "no-cache" });
    return r.ok ? await r.json() : null;
  } catch {
    return null;
  }
}

// Wired by main.ts so the panels can read/set the live layer state.
interface LayerAccess {
  map: MlMap | null;
  get: () => LayerState;
  set: (patch: Partial<LayerState>) => void;
  /** re-push the same state: the topo underlay / background depend on
   * which archives are local, which downloads and deletes change */
  reapply: () => void;
}
let layers: LayerAccess = {
  map: null,
  get: () => ({ base: "topo", cutoff: SEASON_KEYS.length - 1, overlay: "veg", strength: "full", trees: false }),
  set: () => {},
  reapply: () => {},
};
export function setLayerAccess(a: LayerAccess): void {
  layers = a;
}

/** Transient pill naming a state change or a problem (the icon-only
 * toolbar can't). Longer messages get a longer fade. */
export function showPill(text: string, ms = 1800): void {
  const pill = document.getElementById("mode-pill")!;
  pill.textContent = text;
  pill.classList.remove("show");
  void pill.offsetWidth; // restart the animation
  pill.style.animationDuration = `${ms}ms`;
  pill.classList.add("show");
}

const panel = () => document.getElementById("panel")!;
const closeHooks: (() => void)[] = [];
export function closePanel(): void {
  panel().hidden = true;
  panel().className = "";
  for (const h of closeHooks.splice(0)) h();
}
export const isPanelOpen = (): boolean => !panel().hidden;
/** Runs when this panel closes or another replaces it (one-shot). */
export function onPanelClose(h: () => void): void {
  closeHooks.push(h);
}
/** `cls` is a layout variant on #panel ("search" = full-height takeover);
 * see-through is added by callers after the fact. */
export function openPanel(html: string, cls = ""): HTMLElement {
  for (const h of closeHooks.splice(0)) h(); // a panel replacing another
  const el = panel();
  el.innerHTML = `<div class="panel-inner" role="dialog" aria-modal="true"><div class="handle"></div><button class="panel-close" aria-label="Close">×</button>${html}</div>`;
  el.hidden = false;
  el.className = cls;
  el.querySelector<HTMLButtonElement>(".panel-close")!.onclick = closePanel;
  return el;
}

// ---------- shared: overlay strength control ----------

const STRENGTH_LABEL: Record<Strength, string> = { full: "Full", light: "Light", outline: "Outlines" };
/** Full / Light / Outlines-only. Pre-1750 has no outline layer, so the
 * Outlines choice is hidden there (style falls back to Light). */
function strengthHtml(s: LayerState): string {
  const opts: Strength[] = s.overlay === "pre" ? ["full", "light"] : ["full", "light", "outline"];
  return `<div class="leg-opacity" role="group" aria-label="Overlay strength">${opts
    .map((o) => `<button class="leg-op ${s.strength === o ? "on" : ""}" data-op="${o}">${STRENGTH_LABEL[o]}</button>`)
    .join("")}</div>`;
}
function wireStrength(root: HTMLElement): void {
  for (const op of root.querySelectorAll<HTMLButtonElement>(".leg-op")) {
    op.onclick = () => {
      layers.set({ strength: op.dataset.op as Strength });
      for (const b of root.querySelectorAll(".leg-op")) b.classList.toggle("on", b === op);
    };
  }
}

// ---------- Layers ----------

const I = (paths: string) =>
  `<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${paths}</svg>`;
const ICONS = {
  topo: I('<path d="M3 6.5 9 4l6 2.5L21 4v13.5L15 20l-6-2.5L3 20Z"/><path d="M9 4v13.5M15 6.5V20"/>'),
  tasmap: I('<path d="M4 4h16v16H4Z"/><path d="M4 9h16M4 15h16M9 4v16M15 4v16"/>'),
  aerial: I('<circle cx="12" cy="13" r="3.5"/><path d="M4 8h3l1.5-2.5h7L17 8h3v11H4Z"/>'),
  seasons: I('<circle cx="12" cy="12" r="8.5"/><path d="M12 7v5l3.5 2"/>'),
  veg: I('<path d="M20 4c-8.5 0-14 5.5-16 16 10.5-2 16-7.5 16-16Z"/><path d="M4 20C8 13 13 8 20 4"/>'),
  pre: I('<path d="M12 21v-7"/><path d="M12 14C12 10 9 7.5 4.5 7.5 4.5 12 7.5 14 12 14Z"/><path d="M12 14c0-4 3-6.5 7.5-6.5 0 4.5-3 6.5-7.5 6.5Z"/>'),
  geo: I('<path d="M3 8c3-2.5 6 1.5 9-.5s6-2 9-.5"/><path d="M3 13c3-2.5 6 1.5 9-.5s6-2 9-.5"/><path d="M3 18c3-2.5 6 1.5 9-.5s6-2 9-.5"/>'),
  off: I('<circle cx="12" cy="12" r="8.5"/><path d="M6 6l12 12"/>'),
  trees: I('<path d="M12 22v-6"/><path d="M12 2 7 9.5h2.5L6 16h12l-3.5-6.5H17Z"/>'),
};

const BASE_ROWS: { base: BaseMode; label: string; hint: string; icon: string }[] = [
  { base: "topo", label: "Topographic map", hint: "LIST topographic base map", icon: ICONS.topo },
  { base: "tasmap", label: "Paper map", hint: "scanned Tasmap sheets — 1:25,000 when zoomed in", icon: ICONS.tasmap },
  { base: "aerial", label: "Aerial photos", hint: "best available imagery, statewide", icon: ICONS.aerial },
  {
    base: "seasons",
    label: "Aerial photos by season",
    hint: "the newest photo flown up to a chosen season; the topo map shows where none exists",
    icon: ICONS.seasons,
  },
];
const OVERLAY_ROWS: { overlay: OverlayMode; label: string; hint: string; icon: string; archive?: "tasveg" | "pre1750" | "geology" }[] = [
  { overlay: "veg", label: "Vegetation (TASVEG 5.0)", hint: "plant communities today", icon: ICONS.veg, archive: "tasveg" },
  { overlay: "pre", label: "Pre-1750 vegetation", hint: "modelled, before European clearing", icon: ICONS.pre, archive: "pre1750" },
  { overlay: "geo", label: "Geology", hint: "1:500,000 rock units", icon: ICONS.geo, archive: "geology" },
  { overlay: "off", label: "None", hint: "base map only", icon: ICONS.off },
];

const STREAMS = "not downloaded — streams while online";
function baseStatus(base: BaseMode): string {
  if (base === "seasons") {
    const n = SEASON_KEYS.filter((k) => status.rasterLocal[k]).length;
    return n === SEASON_KEYS.length ? `✓ all ${n} seasons offline` : n ? `${n} of ${SEASON_KEYS.length} seasons offline` : STREAMS;
  }
  return status.rasterLocal[base] ? "✓ offline" : STREAMS;
}
const rowHtml = (attrs: string, on: boolean, icon: string, label: string, hint: string, stat: string, role = "radio") =>
  `<button class="lay-row ${on ? "on" : ""}" role="${role}" aria-checked="${on}" ${attrs}>${icon}
    <span class="lay-text"><b>${esc(label)}</b><small>${esc(hint)}</small><small class="lay-status">${esc(stat)}</small></span></button>`;

export function openLayers(): void {
  const s = layers.get();
  const ticks = SEASON_KEYS.map(
    (k, i) =>
      `<span class="lay-tick ${status.rasterLocal[k] ? "" : "missing"}" title="${status.rasterLocal[k] ? "downloaded" : "not downloaded"}">${esc(seasonLabel(i).replace(/^20/, ""))}</span>`,
  ).join("");
  const el = openPanel(`<h2>Map layers</h2>
    <h3 class="lay-h">Base map</h3>
    <div class="lay-group" role="radiogroup" aria-label="Base map">${BASE_ROWS.map((r) =>
      rowHtml(`data-base="${r.base}"`, s.base === r.base, r.icon, r.label, r.hint, baseStatus(r.base)),
    ).join("")}</div>
    <div class="lay-slider" id="lay-slider" ${s.base === "seasons" ? "" : "hidden"}>
      <label for="lay-range">Photos up to <b id="lay-cutoff">${esc(seasonLabel(s.cutoff))}</b></label>
      <input type="range" id="lay-range" min="0" max="${SEASON_KEYS.length - 1}" step="1" value="${s.cutoff}" aria-label="Newest season to show">
      <div class="lay-ticks">${ticks}</div>
      <p class="lay-caption muted" id="lay-caption">&nbsp;</p>
    </div>
    <h3 class="lay-h">Overlay</h3>
    <div class="lay-group" role="radiogroup" aria-label="Overlay">${OVERLAY_ROWS.map((r) =>
      rowHtml(
        `data-overlay="${r.overlay}"`,
        s.overlay === r.overlay,
        r.icon,
        r.label,
        r.hint,
        r.archive ? (status.vectorLocal[r.archive] ? "✓ offline" : STREAMS) : "",
      ),
    ).join("")}</div>
    <h3 class="lay-h">Overlay strength</h3>
    <div id="lay-strength">${strengthHtml(s)}</div>
    <h3 class="lay-h">Also show</h3>
    <div class="lay-group" role="group" aria-label="Also show">${rowHtml(
      'data-toggle="trees"',
      s.trees,
      ICONS.trees,
      "Significant trees (Hobart)",
      "City of Hobart register — dots and groups; tap one for its data sheet",
      "",
      "checkbox",
    )}</div>`);
  el.classList.add("see-through"); // choices preview live on the map behind

  const inner = el.querySelector<HTMLElement>(".panel-inner")!;
  const range = el.querySelector<HTMLInputElement>("#lay-range")!;
  let captionSeq = 0;
  const updateCaption = async () => {
    const st = layers.get();
    const cap = el.querySelector<HTMLElement>("#lay-caption");
    const map = layers.map;
    if (!cap || st.base !== "seasons" || !map) return;
    // 256 px raster sources render tiles at round(zoom + 1), not floor(zoom):
    // probing a coarser level would report a season whose parent tile exists
    // while the centre actually shows an older one (review finding)
    const z = Math.min(RASTER_MAXZOOM, Math.max(0, Math.round(map.getZoom() + 1)));
    const c = map.getCenter();
    const { x, y } = tileAt(c.lng, c.lat, z);
    const seq = ++captionSeq;
    const { idx, unknown } = await seasonAt(z, x, y, st.cutoff);
    if (seq !== captionSeq || panel().hidden) return;
    cap.textContent =
      idx != null
        ? `Showing ${seasonLabel(idx)} photos here`
        : unknown
          ? `No downloaded photos up to ${seasonLabel(st.cutoff)} here — seasons not on this device may stream while online`
          : `No photos up to ${seasonLabel(st.cutoff)} here — the topo map shows instead`;
  };
  let captionTimer = 0;
  const scheduleCaption = () => {
    clearTimeout(captionTimer);
    captionTimer = window.setTimeout(() => void updateCaption(), 250);
  };
  const sync = () => {
    const st = layers.get();
    for (const b of inner.querySelectorAll<HTMLElement>(".lay-row[data-base]")) {
      const on = b.dataset.base === st.base;
      b.classList.toggle("on", on);
      b.setAttribute("aria-checked", String(on));
    }
    for (const b of inner.querySelectorAll<HTMLElement>(".lay-row[data-overlay]")) {
      const on = b.dataset.overlay === st.overlay;
      b.classList.toggle("on", on);
      b.setAttribute("aria-checked", String(on));
    }
    for (const b of inner.querySelectorAll<HTMLElement>(".lay-row[data-toggle]")) {
      const on = b.dataset.toggle === "trees" && st.trees;
      b.classList.toggle("on", on);
      b.setAttribute("aria-checked", String(on));
    }
    inner.querySelector<HTMLElement>("#lay-slider")!.hidden = st.base !== "seasons";
    inner.querySelector<HTMLElement>("#lay-cutoff")!.textContent = seasonLabel(st.cutoff);
    range.value = String(st.cutoff);
    void updateCaption();
  };
  inner.addEventListener("click", (ev) => {
    const row = (ev.target as HTMLElement).closest<HTMLElement>(".lay-row");
    if (!row) return;
    if (row.dataset.base) layers.set({ base: row.dataset.base as BaseMode });
    if (row.dataset.toggle === "trees") layers.set({ trees: !layers.get().trees });
    if (row.dataset.overlay) {
      layers.set({ overlay: row.dataset.overlay as OverlayMode });
      // the strength options depend on the overlay (pre-1750 has no outlines)
      const box = inner.querySelector<HTMLElement>("#lay-strength")!;
      box.innerHTML = strengthHtml(layers.get());
      wireStrength(box);
    }
    sync();
  });
  range.addEventListener("input", () => {
    layers.set({ cutoff: Number(range.value) });
    inner.querySelector<HTMLElement>("#lay-cutoff")!.textContent = seasonLabel(Number(range.value));
    scheduleCaption();
  });
  wireStrength(inner.querySelector<HTMLElement>("#lay-strength")!);
  // the caption follows the map while the sheet is open
  const map = layers.map;
  if (map) {
    map.on("moveend", scheduleCaption);
    closeHooks.push(() => {
      clearTimeout(captionTimer);
      map.off("moveend", scheduleCaption);
    });
  }
  void updateCaption();
}

// ---------- Downloads ----------

const chapters = [...new Set(Object.values(F2F.index).map((e) => e.file))];

/** What the panel needs to know about a download in progress, whether it
 * is one archive (storage.ts inflight) or a multi-file job (below). */
interface Inflight {
  status: () => string;
  attach: (cb: () => void) => void;
  cancel: () => void;
  promise: Promise<void>;
}

// Multi-file downloads (F2F chapters, tree sheets): one job per item key,
// module-level like storage.ts's inflight map so a reopened panel finds it
// again, shows Cancel and re-attaches for progress + completion.
interface Job {
  controller: AbortController;
  promise: Promise<void>;
  message: string;
  listeners: Set<() => void>;
}
const jobs = new Map<string, Job>();
const PAUSED = "paused — tap the button to continue";
function runJob(
  key: string,
  body: (signal: AbortSignal, report: (msg: string) => void) => Promise<void>,
  onReport?: (msg: string) => void,
): Promise<void> {
  const existing = jobs.get(key);
  if (existing) return existing.promise;
  const controller = new AbortController();
  const job: Job = { controller, promise: undefined as unknown as Promise<void>, message: "", listeners: new Set() };
  const report = (msg: string) => {
    job.message = msg;
    onReport?.(msg);
    for (const cb of job.listeners) cb();
  };
  job.promise = body(controller.signal, report)
    .catch((e: unknown) => {
      // a Cancel surfaces as whatever the aborted await threw — normalise
      if (controller.signal.aborted) throw new Error(PAUSED);
      throw e;
    })
    .finally(() => jobs.delete(key));
  jobs.set(key, job);
  return job.promise;
}
function activeJob(key: string): Inflight | null {
  const j = jobs.get(key);
  if (!j) return null;
  return {
    status: () => j.message,
    attach: (cb) => j.listeners.add(cb),
    cancel: () => j.controller.abort(),
    promise: j.promise,
  };
}

interface Item {
  key: string;
  section: string;
  label: string;
  hint: string;
  archive: string | null; // OPFS name for single-archive items
  bytes: number | null;
  note?: string;
  present: boolean;
  partial: number; // resumable bytes already on disk
  update: boolean; // installed, but the server archive differs (rebuilt)
  action: (report: (msg: string) => void) => Promise<void>;
  remove: () => Promise<void>;
  /** multi-file items: the running job, if any (single archives are
   * looked up through storage.ts's activeDownload instead) */
  busy?: () => Inflight | null;
  /** multi-file items: bytes already on the device (for "… on this device") */
  partialBytes?: () => Promise<number>;
  /** appended to "✓ downloaded" (e.g. sheets the council has withdrawn) */
  presentNote?: () => string;
}
const inflightOf = (it: Item): Inflight | null => {
  if (it.busy) return it.busy();
  if (!it.archive) return null;
  const a = activeDownload(it.archive);
  return a && {
    status: () => fmtProgress(a.progress),
    attach: (cb) => a.attach(() => cb()),
    cancel: a.cancel,
    promise: a.promise,
  };
};
const refreshPartial = (it: Item): Promise<number> =>
  it.partialBytes ? it.partialBytes() : it.archive ? partialBytes(it.archive) : Promise.resolve(0);

const SECTION_TITLES: Record<string, string> = {
  overlays: "Overlays",
  base: "Base maps",
  seasons: "Aerial photos by season",
  text: "Descriptions & documents",
};

export async function openDownloads(): Promise<void> {
  const el = openPanel(`<h2>Offline maps</h2><div id="dl-list">Checking…</div>
    <h3 class="dl-h">Detailed areas<button class="dl-all" id="area-new">Download this area…</button></h3>
    <div id="area-list"></div>
    <p class="muted">Full-resolution photos and maps for places you choose —
    down to 0.4 m per pixel, fetched straight from theLIST for just that
    area. Frame it on the map; zoom in past the statewide maps and it stays
    sharp offline.</p>
    <p id="storage-line" class="muted"></p>
    <p class="muted">Download on Wi-Fi at home and keep the app open while it
    runs — an interrupted download resumes where it stopped. Once done,
    everything works with no reception at all. Base maps are big; the
    seasons are small patches of the state.</p>`);
  el.querySelector<HTMLButtonElement>("#area-new")!.onclick = () => beginAreaFraming();
  void renderAreaList(el.querySelector<HTMLElement>("#area-list")!);
  const list = el.querySelector<HTMLElement>("#dl-list")!;
  const manifest = await fetchManifest();

  const items: Item[] = [];
  const archiveItem = async (
    key: string,
    section: string,
    label: string,
    hint: string,
    name: string,
  ): Promise<void> => {
    const remote = manifest?.archives[key];
    const file = await opfsFile(name);
    items.push({
      key,
      section,
      label,
      hint,
      archive: name,
      bytes: remote?.bytes ?? null,
      note: remote?.note,
      present: !!file,
      partial: await partialBytes(name),
      update: !!file && remote != null && remote.bytes !== file.size,
      action: async (report) => {
        await download(`${DATA_BASE}/${name}`, name, (p) =>
          report(`${fmtMB(p.received)}${p.total ? " of " + fmtMB(p.total) : ""}`),
        );
        await refreshArchives();
        layers.reapply();
      },
      remove: async () => {
        await deleteFile(name);
        await refreshArchives();
        layers.reapply();
      },
    });
  };

  for (const [key, label, hint] of [
    ["tasveg", "Vegetation map (TASVEG 5.0)", "statewide — the colour overlay + tap details"],
    ["pre1750", "Pre-1750 vegetation", "what grew here before European clearing? Statewide reconstruction (NVIS), modelled in 1 ha cells"],
    ["geology", "Geology map", "what rock am I standing on? Statewide 1:500,000 (Mineral Resources Tasmania); boundaries approximate"],
  ] as const)
    await archiveItem(key, "overlays", label, hint, ARCHIVES[key]);
  for (const key of BASE_KEYS) {
    const p = packOf(key);
    await archiveItem(key, "base", p.label, p.hint, p.file);
  }
  for (const key of SEASON_KEYS as readonly RasterKey[]) {
    const p = packOf(key);
    await archiveItem(key, "seasons", p.label, p.hint, p.file);
  }

  // bytes of the chapters already on the device (one directory walk)
  const f2fPartial = async () => {
    const have = await listDir("f2f");
    return chapters.reduce((sum, c) => sum + (have.get(c) ?? 0), 0);
  };
  const f2fHave = await listDir("f2f");
  const f2fPresent = chapters.every((c) => (f2fHave.get(c) ?? 0) > 0);
  items.push({
    key: "f2f",
    section: "text",
    label: "Community descriptions",
    hint: "the From Forest to Fjaeldmark chapters",
    archive: null,
    bytes: 37e6,
    present: f2fPresent,
    partial: f2fPresent ? 0 : chapters.reduce((sum, c) => sum + (f2fHave.get(c) ?? 0), 0),
    update: false,
    busy: () => activeJob("f2f"),
    partialBytes: f2fPartial,
    action: (report) =>
      runJob(
        "f2f",
        async (signal, rep) => {
          if (!F2F_PROXY) throw new Error("not configured yet");
          for (let i = 0; i < chapters.length; i++) {
            if (signal.aborted) throw new Error(PAUSED);
            rep(`chapter ${i + 1} of ${chapters.length}`);
            const name = "f2f/" + chapters[i];
            if (await opfsFile(name)) continue;
            // Cancel reaches the chapter in flight through its own controller
            const p = download(`${F2F_PROXY}/${chapters[i]}`, name);
            const onAbort = () => activeDownload(name)?.cancel();
            signal.addEventListener("abort", onAbort, { once: true });
            try {
              await p;
            } finally {
              signal.removeEventListener("abort", onAbort);
            }
          }
        },
        report,
      ),
    remove: async () => {
      for (const c of chapters) await deleteFile("f2f/" + c);
    },
  });

  // Hobart significant-tree data sheets: 282 council PDFs from arcgis.com,
  // one file each under trees/. Optional — a tap fetches a single sheet
  // while online; this is the "take them all up the mountain" path.
  // "Complete" = every sheet is on the device OR the council has withdrawn
  // it (sheets.ts gone-set; ArcGIS answers those with HTTP 400 + HTML, and
  // one such item must not brick the whole batch for ever).
  const sheetsHave = await listDir(TREE_SHEET_DIR);
  // a zero-byte file is an interrupted write's shell, not a sheet
  const sheetOnDevice = (have: Map<string, number>, id: string) => (have.get(id + ".pdf") ?? 0) > 0;
  const sheetsPartial = (have: Map<string, number>) =>
    SHEET_IDS.reduce((sum, id) => sum + (sheetOnDevice(have, id) ? TREES.sheets[id].bytes : 0), 0);
  const sheetsPresent = (have: Map<string, number>) => {
    const gone = goneSheets();
    return SHEET_IDS.every((id) => sheetOnDevice(have, id) || id in gone);
  };
  // withdrawn ids (a successful fetch always clears the mark, so "marked"
  // already means "not on the device"); read live — a reopened panel must
  // not show a count snapshotted before the batch finished
  const sheetsGoneCount = () => {
    const gone = goneSheets();
    return SHEET_IDS.filter((id) => id in gone).length;
  };
  const present0 = sheetsPresent(sheetsHave);
  // Several withdrawals IN A ROW are not withdrawals: a captive portal (or a
  // 403 wall) answers every request the same way. Undo those marks and stop
  // — otherwise a login page would file all 282 sheets as "gone" and the row
  // would read "✓ downloaded".
  const GONE_STREAK_LIMIT = 5;
  items.push({
    key: "treeSheets",
    section: "text",
    label: "Significant tree data sheets",
    hint: "City of Hobart — one PDF per listed tree; sheets also fetch on tap while online",
    archive: null,
    bytes: SHEETS_TOTAL_BYTES,
    present: present0,
    partial: present0 ? 0 : sheetsPartial(sheetsHave),
    update: false,
    busy: () => activeJob("treeSheets"),
    partialBytes: async () => sheetsPartial(await listDir(TREE_SHEET_DIR)),
    presentNote: () => {
      const n = sheetsGoneCount();
      return n ? `${n} sheet${n === 1 ? "" : "s"} no longer published` : "";
    },
    action: (report) =>
      runJob(
        "treeSheets",
        async (signal, rep) => {
          const have = await listDir(TREE_SHEET_DIR);
          const n = SHEET_IDS.length;
          const total = SHEETS_TOTAL_BYTES;
          let done = sheetsPartial(have);
          // preflight like storage.ts does per archive: 282 small writes
          // would otherwise fail one by one at the quota wall
          const { usage, quota } = await storageInfo();
          const remaining = total - done;
          if (quota && quota - usage < remaining + QUOTA_MARGIN) {
            throw new Error(
              `Not enough free space — this needs about ${fmtMB(remaining)} free. ` +
                "Delete something and try again.",
            );
          }
          let streak = 0;
          const skipped: string[] = [];
          const retried = new Set<string>();
          for (let i = 0; i < n; i++) {
            const id = SHEET_IDS[i];
            if (sheetOnDevice(have, id)) continue;
            if (signal.aborted) throw new Error(PAUSED);
            rep(`sheet ${i + 1} of ${n} · ${fmtMB(done)} of ${fmtMB(total)}`);
            try {
              await fetchSheet(id, signal);
            } catch (e) {
              // fetchSheet dedupes per id: this may have JOINED a tap's fetch
              // that the card's dismissal aborted — not our Cancel, so fetch
              // the sheet again ourselves (the map entry is gone by now)
              if (e instanceof SheetError && e.kind === "aborted" && !signal.aborted && !retried.has(id)) {
                retried.add(id);
                i--;
                continue;
              }
              // network loss / our abort / 5xx stop the batch as before; a
              // 4xx or a non-PDF body is "the council took this one down":
              // remember it, skip it, keep going
              if (!(e instanceof SheetError) || (e.kind !== "gone" && e.kind !== "notpdf")) throw e;
              markSheetGone(id, true);
              skipped.push(id);
              if (++streak >= GONE_STREAK_LIMIT) {
                for (const s of skipped.slice(-streak)) markSheetGone(s, false);
                throw new Error(
                  "Several sheets in a row weren't PDFs — a Wi-Fi login page may be in the way. " +
                    "Try again on another network.",
                );
              }
              continue;
            }
            streak = 0;
            done += TREES.sheets[id].bytes;
          }
        },
        report,
      ),
    remove: async () => {
      for (const id of SHEET_IDS) await deleteFile(sheetPath(id));
      clearGoneSheets(); // a fresh download re-checks withdrawn ids
    },
  });

  // Last error per item, shown until the next attempt.
  const errors = new Map<string, string>();
  // Downloads whose completion already triggers a re-render.
  const watched = new Set<string>();
  // "Download all seasons" in progress (one batch at a time; Cancel ends it).
  let batch = false;
  let batchCancelled = false;
  const downloadable = (it: Item) => it.bytes !== null && (!it.present || it.update) && !inflightOf(it);

  const liveStatus = (key: string): HTMLElement | null =>
    list.querySelector(`[data-key="${key}"] .dl-status`);

  const render = () => {
    if (panel().hidden) return; // user closed the panel — nothing to draw into
    let section = "";
    list.innerHTML = items
      .map((it) => {
        const inflight = inflightOf(it);
        const btn = inflight ? "Cancel"
          : it.update ? "Update"
          : it.present ? "Delete"
          : it.partial > 0 ? "Resume"
          : "Download";
        const status = errors.get(it.key)
          ?? (inflight
            ? inflight.status() || "starting…"
            : it.update
              ? `✓ downloaded · newer version available${it.bytes ? " (" + fmtMB(it.bytes) + ")" : ""}`
              : it.present
                ? `✓ downloaded${it.presentNote?.() ? " · " + it.presentNote() : ""}`
                : it.partial > 0
                  // multi-file items hold usable files (a tap-fetched sheet
                  // was never "paused"); an archive's chunks are a pause
                  ? it.partialBytes
                    ? `${fmtMB(it.partial)}${it.bytes ? " of " + fmtMB(it.bytes) : ""} on this device`
                    : `paused at ${fmtMB(it.partial)}${it.bytes ? " of " + fmtMB(it.bytes) : ""}`
                  : "");
        const size = it.bytes ? " · " + fmtMB(it.bytes) : it.present ? "" : " · not available yet";
        const disabled = !inflight && !it.present && it.partial === 0 && it.bytes === null && it.key !== "f2f";
        const head = it.section !== section
          ? `<h3 class="dl-h">${esc(SECTION_TITLES[it.section] ?? it.section)}${
              it.section === "seasons"
                ? `<button class="dl-all" ${
                    batch || !items.some((x) => x.section === "seasons" && downloadable(x)) ? "disabled" : ""
                  }>${batch ? "Downloading…" : "Download all"}</button>`
                : ""
            }</h3>`
          : "";
        section = it.section;
        // an outdated or half-downloaded archive must stay deletable
        // without a full re-download first (review finding)
        const secondary = !inflight && (it.update || (!it.present && it.partial > 0))
          ? '<button class="dl-btn dl-secondary">Delete</button>'
          : "";
        return `${head}<div class="dl-item" data-key="${it.key}">
          <div class="dl-info"><b>${esc(it.label)}</b><small>${esc(it.hint)}${size}</small>${
            it.note ? `<small class="dl-note">${esc(it.note)}</small>` : ""
          }<small class="dl-status">${status}</small></div>
          <div class="dl-actions">${secondary}<button class="dl-btn" ${disabled ? "disabled" : ""}>${btn}</button></div>
        </div>`;
      })
      .join("");
    void storageInfo().then(({ usage, quota }) => {
      const line = el.querySelector("#storage-line");
      if (line) line.textContent =
        `Storage: ${fmtMB(usage)} used, ${fmtMB(Math.max(0, quota - usage))} available`;
    });
    // any in-flight download must re-render this panel when it settles
    for (const it of items) {
      const act = inflightOf(it);
      if (act && !watched.has(it.key)) {
        watched.add(it.key);
        act.attach(() => {
          const stat = liveStatus(it.key);
          if (stat && !errors.get(it.key)) stat.textContent = act.status();
        });
        void act.promise
          .then(() => {
            it.present = true;
            it.partial = 0;
            it.update = false;
          })
          .catch(async (e: Error) => {
            it.partial = await refreshPartial(it);
            errors.set(it.key, e.message);
          })
          .finally(() => {
            watched.delete(it.key);
            render();
          });
      }
    }
  };

  /** Start (or resume) an item. An Update keeps the installed archive
   * serving until the replacement is fully assembled (assembly swaps the
   * file atomically) — unless space is too tight to hold both, in which
   * case the old one goes first. it.action registers the download
   * synchronously, so the immediate render shows Cancel + live progress. */
  const startItem = async (it: Item): Promise<void> => {
    errors.delete(it.key);
    if (it.update) {
      const { usage, quota } = await storageInfo();
      const tight = it.bytes !== null && quota > 0 && quota - usage < 2 * it.bytes + 300e6;
      if (tight) {
        const stat = liveStatus(it.key);
        if (stat) stat.textContent = "freeing space first…";
        await it.remove();
        it.present = false;
        it.partial = 0;
      }
      it.update = false;
    }
    const p = it.action((msg) => {
      const stat = liveStatus(it.key);
      if (stat) stat.textContent = msg;
    });
    render();
    try {
      await p;
      it.present = true;
      it.partial = 0;
    } catch (e) {
      it.partial = await refreshPartial(it);
      errors.set(it.key, e instanceof Error ? e.message : String(e));
    }
    render();
  };

  // Event delegation: handlers never go stale, state read at tap time.
  list.onclick = async (ev) => {
    const target = ev.target as HTMLElement;
    if (target.closest(".dl-all")) {
      if (batch) return;
      // seasons are small: fetch every missing/outdated one, in order; the
      // first failure (or a Cancel) ends the batch instead of marching on
      batch = true;
      batchCancelled = false;
      render();
      try {
        for (const it of items) {
          if (batchCancelled) break;
          if (it.section !== "seasons" || !downloadable(it)) continue;
          await startItem(it);
          if (!it.present) break;
        }
      } finally {
        batch = false;
        render();
      }
      return;
    }
    const row = target.closest<HTMLElement>(".dl-item");
    if (!row || !target.closest(".dl-btn")) return;
    const it = items.find((x) => x.key === row.dataset.key);
    if (!it) return;
    errors.delete(it.key);

    const act = inflightOf(it);
    if (act) {
      // only a season's Cancel ends "Download all seasons" — cancelling a
      // sheet batch or an overlay must leave that batch marching on
      if (it.section === "seasons") batchCancelled = true;
      act.cancel();
      await act.promise.catch(() => {}); // settles via the watcher above
      return;
    }
    if (target.closest(".dl-secondary") || (it.present && !it.update)) {
      await it.remove();
      it.present = false;
      it.partial = 0;
      it.update = false;
      render();
      return;
    }
    await startItem(it);
  };

  render();
}

// ---------- Detailed areas ----------

const LAYER_CHOICES: { id: string; label: string; hint: string; keys: readonly RasterKey[] }[] = [
  { id: "aerial", label: "Aerial photos", hint: "best available", keys: ["aerial"] },
  { id: "seasons", label: "Aerial photos by season", hint: "all seasons, where flown", keys: SEASON_KEYS },
  { id: "tasmap", label: "Paper map", hint: "1:25,000 sheets, to zoom 16", keys: ["tasmap"] },
  { id: "topo", label: "Topographic map", hint: "to zoom 18", keys: ["topo"] },
];

const areaLayerLabel = (meta: AreaMeta): string =>
  LAYER_CHOICES.filter((c) => c.keys.some((k) => meta.layers.includes(k))).map((c) => c.label).join(", ");
const areaBytes = (meta: AreaMeta): number => Object.values(meta.bytes).reduce((a, b) => a + (b ?? 0), 0);
const areaDone = (meta: AreaMeta): boolean => meta.layers.every((k) => meta.complete[k]);
const areaBusy = (meta: AreaMeta) => meta.layers.some((k) => activeAreaDownload(meta.id, k));

let endFraming: (() => void) | null = null;

/** Draw the dashed frame of the current view and let the user pan/zoom to
 * the area they want, then continue to the setup sheet. */
export function beginAreaFraming(): void {
  const map = layers.map;
  if (!map) return;
  endFraming?.(); // a second entry must not leave the first frame's listener behind
  closePanel();
  const bar = document.getElementById("areabar")!;
  const text = document.getElementById("areabar-text")!;
  const nextBtn = document.getElementById("areabar-next") as HTMLButtonElement;
  bar.hidden = false;
  // the first-run nudge sits in the same spot; stand it down while framing
  const nudge = document.getElementById("nudge");
  const nudgeWasShown = !!nudge && !nudge.hidden;
  if (nudge) nudge.hidden = true;
  const frameBounds = (): BBox => {
    const b = map.getBounds();
    const dw = (b.getEast() - b.getWest()) * 0.08;
    const dh = (b.getNorth() - b.getSouth()) * 0.1;
    return [b.getWest() + dw, b.getSouth() + dh, b.getEast() - dw, b.getNorth() - dh];
  };
  const src = () => map.getSource("area-frame") as { setData(d: unknown): void } | undefined;
  const draw = () => {
    const bbox = frameBounds();
    const [w, s, e, n] = bbox;
    src()?.setData({
      type: "Feature",
      properties: {},
      geometry: { type: "Polygon", coordinates: [[[w, s], [e, s], [e, n], [w, n], [w, s]]] },
    });
    // the cap is per layer at the chosen detail; warn on the default (z17)
    const tooBig = tileCount(bbox, 0, 17) > MAX_AREA_TILES;
    text.textContent = tooBig
      ? "Too large for one download — zoom in"
      : "Frame the area you want in detail, then tap Next";
    nextBtn.disabled = tooBig;
  };
  const end = () => {
    map.off("move", draw);
    bar.hidden = true;
    if (nudge && nudgeWasShown) nudge.hidden = false;
    src()?.setData({ type: "FeatureCollection", features: [] });
    endFraming = null;
  };
  endFraming = end;
  map.on("move", draw);
  draw();
  document.getElementById("areabar-cancel")!.onclick = end;
  nextBtn.onclick = () => {
    const bbox = frameBounds();
    end();
    void openAreaSetup(bbox);
  };
}

const kmSize = (b: BBox): string => {
  const [w, s, e, n] = b;
  const midLat = ((s + n) / 2) * (Math.PI / 180);
  const kmW = (e - w) * 111.32 * Math.cos(midLat);
  const kmH = (n - s) * 110.57;
  return `${kmW.toFixed(1)} × ${kmH.toFixed(1)} km`;
};

async function openAreaSetup(bbox: BBox): Promise<void> {
  const n = (await listAreas()).length + 1;
  const el = openPanel(`<h2>Detailed area</h2>
    <form class="area-form" id="area-form">
    <p class="muted">${esc(kmSize(bbox))} — tiles are fetched from theLIST for this area only, at every zoom.</p>
    <label for="area-name">Name</label>
    <input type="text" id="area-name" value="Area ${n}" maxlength="40" autocomplete="off">
    <h3 class="lay-h">Layers</h3>
    ${LAYER_CHOICES.map(
      (c) => `<label class="area-opt"><input type="checkbox" name="layer" value="${c.id}" ${c.id === "aerial" ? "checked" : ""}>${esc(c.label)}<small>${esc(c.hint)}</small></label>`,
    ).join("")}
    <h3 class="lay-h">Detail</h3>
    ${DETAIL_LEVELS.map(
      (d) => `<label class="area-opt"><input type="radio" name="zmax" value="${d.z}" ${d.z === 17 ? "checked" : ""}>${esc(d.label)}<small>zoom ${d.z} · ${esc(d.mpp)}</small></label>`,
    ).join("")}
    <p class="area-est" id="area-est"></p>
    <button type="submit" class="sheet-desc area-go">Download</button>
    </form>`);
  const form = el.querySelector<HTMLFormElement>("#area-form")!;
  const chosen = () => ({
    keys: [...form.querySelectorAll<HTMLInputElement>('input[name="layer"]:checked')].flatMap(
      (i) => LAYER_CHOICES.find((c) => c.id === i.value)!.keys,
    ) as RasterKey[],
    zmax: Number(form.querySelector<HTMLInputElement>('input[name="zmax"]:checked')!.value),
  });
  const estimate = () => {
    const { keys, zmax } = chosen();
    const est = estimateArea(bbox, zmax, keys);
    const seasons = keys.filter((k) => (SEASON_KEYS as readonly string[]).includes(k));
    const fixed = keys.filter((k) => !seasons.includes(k)).reduce((a, k) => a + est[k].bytes, 0);
    const seasonMax = seasons.reduce((a, k) => a + est[k].bytes, 0);
    const parts = [];
    if (fixed) parts.push(`about ${fmtMB(fixed)}`);
    if (seasonMax) parts.push(`seasons up to ${fmtMB(seasonMax)} (only where flown)`);
    const tooBig = keys.some((k) => est[k].tiles > MAX_AREA_TILES);
    el.querySelector("#area-est")!.textContent = !keys.length
      ? "choose at least one layer"
      : tooBig
        ? `Too large for one download at this detail (over ${MAX_AREA_TILES.toLocaleString()} tiles per layer) — pick less detail or a smaller area`
        : parts.join(" + ");
    el.querySelector<HTMLButtonElement>(".area-go")!.disabled = keys.length === 0 || tooBig;
  };
  form.addEventListener("change", estimate);
  estimate();
  form.onsubmit = async (ev) => {
    ev.preventDefault();
    const { keys, zmax } = chosen();
    if (!keys.length) return;
    const meta: AreaMeta = {
      id: Date.now().toString(36),
      name: (form.querySelector<HTMLInputElement>("#area-name")!.value.trim() || `Area ${n}`).slice(0, 40),
      bbox,
      zmax,
      layers: keys,
      created: new Date().toISOString(),
      bytes: {},
      tiles: {},
      complete: {},
    };
    await upsertArea(meta);
    await openAreaProgress(meta);
  };
}

/** Run every incomplete layer of an area in turn (resume-safe). */
function runArea(
  meta: AreaMeta,
  onStart: (key: RasterKey) => void,
  report: (key: RasterKey, p: { done: number; total: number; bytes: number } | string) => void,
): Promise<void> {
  return (async () => {
    for (const key of meta.layers) {
      if (meta.complete[key]) continue;
      onStart(key);
      report(key, "checking…");
      await downloadAreaLayer(meta, key, (p) => report(key, p));
      report(key, "✓ done");
    }
    refreshRasterTiles(meta.layers);
  })();
}

async function openAreaProgress(meta: AreaMeta): Promise<void> {
  // Every lookup goes through THIS sheet's root: the panel element is
  // shared, and the Offline maps rows use the same data-key markup — a
  // download still running after the user moved on must not write its
  // progress into the statewide pack rows (review finding).
  const el = openPanel(`<div class="area-progress" data-area-progress="${esc(meta.id)}"><h2>${esc(meta.name)}</h2>
    <p class="muted">${esc(areaLayerLabel(meta))} · zoom ${meta.zmax} · ${esc(kmSize(meta.bbox))}</p>
    <div>${meta.layers.map(
      (k) => `<div class="dl-item" data-key="${k}"><div class="dl-info"><b>${esc(packOf(k).label)}</b><small class="dl-status">${meta.complete[k] ? "✓ done" : "waiting…"}</small></div></div>`,
    ).join("")}</div>
    <div class="dl-actions"><button class="dl-btn area-cancel">Cancel</button></div>
    <p class="muted">Keep the app open. Cancelling keeps what has arrived — Resume later from Offline maps.</p></div>`);
  const root = () => el.querySelector<HTMLElement>(`[data-area-progress="${meta.id}"]`);
  const line = (k: RasterKey) => root()?.querySelector<HTMLElement>(`[data-key="${k}"] .dl-status`) ?? null;
  const button = () => root()?.querySelector<HTMLButtonElement>(".area-cancel") ?? null;
  let current: RasterKey | null = null;
  button()!.onclick = () => {
    if (current) activeAreaDownload(meta.id, current)?.cancel();
  };
  try {
    await runArea(
      meta,
      (k) => (current = k),
      (k, p) => {
        const s = line(k);
        if (s) s.textContent = typeof p === "string" ? p : `${p.done.toLocaleString()} of ${p.total.toLocaleString()} tiles · ${fmtMB(p.bytes)}`;
      },
    );
    const btn = button();
    if (btn) {
      btn.textContent = "Done";
      btn.onclick = () => void openDownloads();
    }
  } catch (e) {
    if (current) {
      const s = line(current);
      if (s) s.textContent = e instanceof Error ? e.message : String(e);
    }
    const btn = button();
    if (btn) {
      btn.textContent = "Back";
      btn.onclick = () => void openDownloads();
    }
  }
}

async function renderAreaList(host: HTMLElement): Promise<void> {
  const areas = await listAreas();
  if (!areas.length) {
    host.innerHTML = `<p class="muted">No detailed areas yet.</p>`;
    return;
  }
  host.innerHTML = areas
    .map((a) => {
      const busy = areaBusy(a);
      const stat = busy ? "downloading…" : areaDone(a) ? "✓ downloaded" : "incomplete — tap Resume";
      const btn = busy ? "Open" : areaDone(a) ? "" : "Resume";
      return `<div class="dl-item area-row" data-area="${a.id}">
        <div class="dl-info"><b>${esc(a.name)}</b><small>${esc(areaLayerLabel(a))} · zoom ${a.zmax} · ${fmtMB(areaBytes(a))}</small><small class="dl-status">${stat}</small></div>
        <div class="dl-actions">${btn ? `<button class="dl-btn area-primary">${btn}</button>` : ""}<button class="dl-btn dl-secondary area-delete">Delete</button></div>
      </div>`;
    })
    .join("");
  host.onclick = async (ev) => {
    const row = (ev.target as HTMLElement).closest<HTMLElement>(".area-row");
    if (!row) return;
    const meta = areas.find((a) => a.id === row.dataset.area);
    if (!meta) return;
    if ((ev.target as HTMLElement).closest(".area-delete")) {
      const stat = row.querySelector<HTMLElement>(".dl-status");
      if (stat) stat.textContent = "deleting…";
      try {
        await deleteArea(meta.id); // stops and awaits any running layer first
        refreshRasterTiles(meta.layers);
      } catch (e) {
        if (stat) stat.textContent = e instanceof Error ? e.message : String(e);
        return;
      }
      await renderAreaList(host);
      return;
    }
    if ((ev.target as HTMLElement).closest(".area-primary")) await openAreaProgress(meta);
  };
}

// ---------- Legend ----------

export function openLegend(): void {
  const state = layers.get();
  const live = state.overlay;
  const mode = live === "geo" ? "geo" : live === "pre" ? "pre" : "veg";
  const slug = (g: string) => g.replace(/[^a-z0-9]+/gi, "-").toLowerCase();

  const groupBy = (ids: string[], groupOf: (id: string) => string) => {
    const m = new Map<string, string[]>();
    for (const id of ids) {
      const g = groupOf(id);
      if (!m.has(g)) m.set(g, []);
      m.get(g)!.push(id);
    }
    return m;
  };

  let groups: Map<string, string[]>;
  let row: (id: string) => string;
  if (mode === "pre") {
    const codes = Object.keys(PRE1750_UNITS).sort(
      (a, b) => PRE1750_UNITS[a].order - PRE1750_UNITS[b].order,
    );
    groups = groupBy(codes, (c) => PRE1750_UNITS[c].group);
    row = (c) => {
      const u = PRE1750_UNITS[c];
      return `<div class="leg-row"><span class="swatch" style="background:${esc(u.color)}"></span>
        <span>${esc(u.name)}</span></div>`;
    };
  } else if (mode === "geo") {
    groups = groupBy(Object.keys(GEOLOGY_UNITS), (s) => GEOLOGY_UNITS[s].group);
    row = (symb) => {
      const u = GEOLOGY_UNITS[symb];
      return `<div class="leg-row"><span class="swatch" style="background:${esc(u.color)}"></span>
        <span><b>${esc(symb)}</b> ${esc(u.description)}</span></div>`;
    };
  } else {
    groups = groupBy(Object.keys(COMMUNITIES), (c) => COMMUNITIES[c].group);
    row = (c) =>
      `<div class="leg-row"><span class="swatch" style="background:${esc(COMMUNITIES[c].color)}"></span>
       <span><b>${esc(c)}</b> ${esc(COMMUNITIES[c].name.replace(/^\([A-Z]{3}\)\s*/, ""))}</span></div>`;
  }

  // Vegetation sorts alphabetically; geology sorts oldest -> youngest (the
  // narrative a geology map implies), "Other units" last; pre-1750 follows
  // the official NVIS group order (structurally tallest -> sparsest).
  const groupAge = (ids: string[]) =>
    Math.max(...ids.map((id) => GEOLOGY_UNITS[id]?.maxMa ?? 0));
  const sorted =
    mode === "geo"
      ? [...groups.entries()].sort((a, b) => {
          if (a[0] === "Other units") return 1;
          if (b[0] === "Other units") return -1;
          return groupAge(b[1]) - groupAge(a[1]);
        })
      : mode === "pre"
        ? [...groups.entries()].sort(
            (a, b) => PRE1750_UNITS[a[1][0]].groupOrder - PRE1750_UNITS[b[1][0]].groupOrder,
          )
        : [...groups.entries()].sort();
  // Chip labels: veg group first-words are unique; geology + pre-1750
  // groups get hand-curated short names from chips.ts (truncation produced
  // near-identical twins; tests pin PRE_CHIPS to the generated groups).
  const chipLabel = (g: string) =>
    mode === "veg"
      ? g.split(/[ ,]/)[0]
      : (mode === "geo" ? GEO_CHIPS[g] : PRE_CHIPS[g])
        ?? (g.length > 22 ? g.slice(0, 21).trimEnd() + "…" : g);
  const hiddenNote =
    live === "off"
      ? `<p class="muted">The overlay is currently hidden — choose one in Map layers.</p>`
      : mode === "pre"
        ? `<p class="muted">An estimate of the plant communities here before European
           clearing, modelled from remnants and historical records (NVIS, 1&nbsp;ha cells).</p>`
        : "";
  const TITLES = { veg: "Vegetation", pre: "Pre-1750", geo: "Geology" } as const;
  const el = openPanel(
    `<div class="leg-top"><div class="leg-head"><h2>${TITLES[mode]} legend</h2>
      ${strengthHtml({ ...state, overlay: mode })}</div>
      <div class="leg-chips">${sorted
        .map(([g]) => `<button class="leg-chip" data-target="${slug(g)}">${chipLabel(g)}</button>`)
        .join("")}</div>${hiddenNote}</div>` +
      sorted
        .map(
          ([g, ids]) =>
            `<h3 class="leg-h" id="leg-${slug(g)}">${g}<span class="leg-count">${ids.length}</span></h3>` +
            ids.map(row).join(""),
        )
        .join(""),
  );
  el.classList.add("see-through"); // lighter scrim: strength changes stay visible
  const inner = el.querySelector<HTMLElement>(".panel-inner")!;
  for (const chip of el.querySelectorAll<HTMLButtonElement>(".leg-chip")) {
    chip.onclick = () => {
      const h = el.querySelector<HTMLElement>(`#leg-${chip.dataset.target}`);
      if (h) inner.scrollTop = h.offsetTop - inner.querySelector<HTMLElement>(".leg-top")!.offsetHeight - 8;
    };
  }
  wireStrength(inner.querySelector<HTMLElement>(".leg-head")!);
}

// ---------- About ----------

export function openAbout(): void {
  openPanel(`<h2>IzzyMap</h2>
    <p class="about-lede">Which plant community am I standing in?</p>
    <p>Offline vegetation, topographic and aerial maps of Tasmania, made for
    one hiker's pocket.</p>
    <p class="muted">While the map is open the screen stays awake during GPS
    following — close the app or press the side button to save battery.</p>
    <p>Topographic Basemap from theLIST © State of Tasmania<br>
    TASVEG 5.0 from theLIST © State of Tasmania<br>
    Geology 1:500,000 from Mineral Resources Tasmania © State of Tasmania<br>
    Place names and street addresses: Nomenclature, Transport Segments, Named Feature Extents, Locality areas and Address Points from theLIST © State of Tasmania<br>
    <a href="https://creativecommons.org/licenses/by/3.0/au/">CC BY 3.0 AU</a></p>
    <p>Aerial Photo Basemap and seasonal aerial photos from theLIST © State of Tasmania<br>
    Tasmap 1:25,000 / 100,000 / 250,000 / 500,000 sheets from theLIST © State of Tasmania<br>
    <a href="https://creativecommons.org/licenses/by-nc-nd/3.0/au/">CC BY-NC-ND 3.0 AU</a> —
    reproduced unaltered for personal, non-commercial use.</p>
    <p>Pre-1750 vegetation: National Vegetation Information System V7.0<br>
    © Commonwealth of Australia (DCCEEW)
    <a href="https://creativecommons.org/licenses/by/4.0/">CC BY 4.0</a> —
    an estimate of what grew where before European clearing, modelled from
    remnant vegetation and historical records.</p>
    <p>Significant trees: City of Hobart significant tree register (ArcGIS
    Online, <a href="https://creativecommons.org/licenses/by/4.0/">CC BY 4.0</a>).
    The per-tree data sheets are City of Hobart documents this device fetches
    from arcgis.com and keeps only on the device.</p>
    <p>Community descriptions: Kitchener &amp; Harris (2013), <i>From Forest to
    Fjaeldmark</i>, Ed. 2, DPIPWE — © Government of Tasmania.</p>
    <p class="muted">TASVEG mapping boundaries are indicative only.
    Built for personal use. <a href="https://github.com/lgruen/izzy-map">Source</a></p>`);
}
