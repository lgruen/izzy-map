// Panels: layers, offline downloads manager, legend, about. One panel at a time.
import type { Map as MlMap } from "maplibre-gl";
import {
  ARCHIVES,
  BASE_KEYS,
  DATA_BASE,
  RASTER_MAXZOOM,
  SEASON_KEYS,
  packOf,
  seasonLabel,
  type RasterKey,
} from "./config";
import {
  activeDownload,
  deleteFile,
  download,
  opfsFile,
  partialBytes,
  storageInfo,
} from "./storage";
import {
  COMMUNITIES,
  GEOLOGY_UNITS,
  PRE1750_UNITS,
  type BaseMode,
  type LayerState,
  type OverlayMode,
  type Strength,
} from "./style";
import { GEO_CHIPS, PRE_CHIPS } from "./chips";
import { refreshArchives, seasonAt, status, tileAt } from "./protocol";
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
  get: () => ({ base: "topo", cutoff: SEASON_KEYS.length - 1, overlay: "veg", strength: "full" }),
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
  panel().classList.remove("see-through");
  for (const h of closeHooks.splice(0)) h();
}
export const isPanelOpen = (): boolean => !panel().hidden;
function openPanel(html: string): HTMLElement {
  for (const h of closeHooks.splice(0)) h(); // a panel replacing another
  const el = panel();
  el.innerHTML = `<div class="panel-inner" role="dialog" aria-modal="true"><div class="handle"></div><button class="panel-close" aria-label="Close">×</button>${html}</div>`;
  el.hidden = false;
  el.classList.remove("see-through");
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
const rowHtml = (attrs: string, on: boolean, icon: string, label: string, hint: string, stat: string) =>
  `<button class="lay-row ${on ? "on" : ""}" role="radio" aria-checked="${on}" ${attrs}>${icon}
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
    <div id="lay-strength">${strengthHtml(s)}</div>`);
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
    inner.querySelector<HTMLElement>("#lay-slider")!.hidden = st.base !== "seasons";
    inner.querySelector<HTMLElement>("#lay-cutoff")!.textContent = seasonLabel(st.cutoff);
    range.value = String(st.cutoff);
    void updateCaption();
  };
  inner.addEventListener("click", (ev) => {
    const row = (ev.target as HTMLElement).closest<HTMLElement>(".lay-row");
    if (!row) return;
    if (row.dataset.base) layers.set({ base: row.dataset.base as BaseMode });
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
}

const SECTION_TITLES: Record<string, string> = {
  overlays: "Overlays",
  base: "Base maps",
  seasons: "Aerial photos by season",
  text: "Descriptions",
};

export async function openDownloads(): Promise<void> {
  const el = openPanel(`<h2>Offline maps</h2><div id="dl-list">Checking…</div>
    <p id="storage-line" class="muted"></p>
    <p class="muted">Download on Wi-Fi at home and keep the app open while it
    runs — an interrupted download resumes where it stopped. Once done,
    everything works with no reception at all. Base maps are big; the
    seasons are small patches of the state.</p>`);
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

  const f2fPresent = (await Promise.all(chapters.map((c) => opfsFile("f2f/" + c)))).every(Boolean);
  items.push({
    key: "f2f",
    section: "text",
    label: "Community descriptions",
    hint: "the From Forest to Fjaeldmark chapters",
    archive: null,
    bytes: 37e6,
    present: f2fPresent,
    partial: 0,
    update: false,
    action: async (report) => {
      if (!F2F_PROXY) throw new Error("not configured yet");
      for (let i = 0; i < chapters.length; i++) {
        report(`chapter ${i + 1} of ${chapters.length}`);
        if (await opfsFile("f2f/" + chapters[i])) continue;
        await download(`${F2F_PROXY}/${chapters[i]}`, "f2f/" + chapters[i]);
      }
    },
    remove: async () => {
      for (const c of chapters) await deleteFile("f2f/" + c);
    },
  });

  // Last error per item, shown until the next attempt.
  const errors = new Map<string, string>();
  // Downloads whose completion already triggers a re-render.
  const watched = new Set<string>();
  // "Download all seasons" in progress (one batch at a time; Cancel ends it).
  let batch = false;
  let batchCancelled = false;
  const downloadable = (it: Item) =>
    it.bytes !== null && (!it.present || it.update) && !(it.archive && activeDownload(it.archive));

  const liveStatus = (key: string): HTMLElement | null =>
    list.querySelector(`[data-key="${key}"] .dl-status`);

  const render = () => {
    if (panel().hidden) return; // user closed the panel — nothing to draw into
    let section = "";
    list.innerHTML = items
      .map((it) => {
        const inflight = it.archive ? activeDownload(it.archive) : null;
        const btn = inflight ? "Cancel"
          : it.update ? "Update"
          : it.present ? "Delete"
          : it.partial > 0 ? "Resume"
          : "Download";
        const status = errors.get(it.key)
          ?? (inflight
            ? fmtProgress(inflight.progress)
            : it.update
              ? `✓ downloaded · newer version available${it.bytes ? " (" + fmtMB(it.bytes) + ")" : ""}`
              : it.present
                ? "✓ downloaded"
                : it.partial > 0
                  ? `paused at ${fmtMB(it.partial)}${it.bytes ? " of " + fmtMB(it.bytes) : ""}`
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
      const act = it.archive ? activeDownload(it.archive) : null;
      if (act && it.archive && !watched.has(it.archive)) {
        watched.add(it.archive);
        act.attach((pr) => {
          const stat = liveStatus(it.key);
          if (stat && !errors.get(it.key)) stat.textContent = fmtProgress(pr);
        });
        void act.promise
          .then(() => {
            it.present = true;
            it.partial = 0;
            it.update = false;
          })
          .catch(async (e: Error) => {
            it.partial = it.archive ? await partialBytes(it.archive) : 0;
            errors.set(it.key, e.message);
          })
          .finally(() => {
            if (it.archive) watched.delete(it.archive);
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
      it.partial = it.archive ? await partialBytes(it.archive) : 0;
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

    const act = it.archive ? activeDownload(it.archive) : null;
    if (act) {
      batchCancelled = true;
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
    <p>Community descriptions: Kitchener &amp; Harris (2013), <i>From Forest to
    Fjaeldmark</i>, Ed. 2, DPIPWE — © Government of Tasmania.</p>
    <p class="muted">TASVEG mapping boundaries are indicative only.
    Built for personal use. <a href="https://github.com/lgruen/izzy-map">Source</a></p>`);
}
