// Panels: offline downloads manager, legend, about. One panel at a time.
import { ARCHIVES, DATA_BASE } from "./config";
import {
  activeDownload,
  deleteFile,
  download,
  opfsFile,
  partialBytes,
  storageInfo,
} from "./storage";
import { COMMUNITIES, GEOLOGY_UNITS, type OverlayMode } from "./style";
import { refreshArchives } from "./protocol";
import f2f from "./generated/f2f_index.json";

const F2F = f2f as { baseUrl: string; index: Record<string, { file: string; page: number }> };
// F2F PDFs have no CORS on nre.tas.gov.au; this transparent non-caching
// relay adds it (see docs/LICENSING.md and pipeline/f2f-proxy/).
const F2F_PROXY: string = import.meta.env.VITE_F2F_PROXY ?? "";

const fmtMB = (b: number) => (b >= 1e9 ? (b / 1e9).toFixed(2) + " GB" : Math.round(b / 1e6) + " MB");
const fmtProgress = (p: { received: number; total: number | null }) =>
  `${fmtMB(p.received)}${p.total ? " of " + fmtMB(p.total) : ""}`;

interface DataManifest {
  version: string;
  archives: Record<string, { file: string; bytes: number }>;
}

async function fetchManifest(): Promise<DataManifest | null> {
  try {
    const r = await fetch(`${DATA_BASE}/data-manifest.json`, { cache: "no-cache" });
    return r.ok ? await r.json() : null;
  } catch {
    return null;
  }
}

// Wired by main.ts so the legend can read/set the live overlay state.
interface OverlayAccess {
  getMode: () => OverlayMode;
  getOpacity: () => number;
  setOpacity: (v: number) => void;
}
let overlay: OverlayAccess = {
  getMode: () => "veg",
  getOpacity: () => 0.5,
  setOpacity: () => {},
};
export function setOverlayAccess(a: OverlayAccess): void {
  overlay = a;
}

const panel = () => document.getElementById("panel")!;
export function closePanel(): void {
  panel().hidden = true;
}
function openPanel(html: string): HTMLElement {
  const el = panel();
  el.innerHTML = `<div class="panel-inner" role="dialog" aria-modal="true"><div class="handle"></div><button class="panel-close" aria-label="Close">×</button>${html}</div>`;
  el.hidden = false;
  el.querySelector<HTMLButtonElement>(".panel-close")!.onclick = closePanel;
  return el;
}

// ---------- Downloads ----------

const chapters = [...new Set(Object.values(F2F.index).map((e) => e.file))];

interface Item {
  key: string;
  label: string;
  hint: string;
  archive: string | null; // OPFS name for single-archive items
  bytes: number | null;
  present: boolean;
  partial: number; // resumable bytes already on disk
  action: (report: (msg: string) => void) => Promise<void>;
  remove: () => Promise<void>;
}

export async function openDownloads(): Promise<void> {
  const el = openPanel(`<h2>Offline maps</h2><div id="dl-list">Checking…</div>
    <p id="storage-line" class="muted"></p>
    <p class="muted">Download on Wi-Fi at home and keep the app open while it
    runs — an interrupted download resumes where it stopped. Once done,
    everything works with no reception at all.</p>`);
  const list = el.querySelector<HTMLElement>("#dl-list")!;
  const manifest = await fetchManifest();

  const items: Item[] = [];
  for (const [key, label, hint] of [
    ["tasveg", "Vegetation map (TASVEG 5.0)", "statewide — the colour overlay + tap details"],
    ["geology", "Geology map (1:500k, MRT)", "statewide — what rock am I standing on?"],
    ["topo", "Topographic base map", "statewide to zoom 15 — the map under it. Large!"],
  ] as const) {
    const name = ARCHIVES[key];
    items.push({
      key,
      label,
      hint,
      archive: name,
      bytes: manifest?.archives[key]?.bytes ?? null,
      present: !!(await opfsFile(name)),
      partial: await partialBytes(name),
      action: async (report) => {
        await download(`${DATA_BASE}/${name}`, name, (p) =>
          report(`${fmtMB(p.received)}${p.total ? " of " + fmtMB(p.total) : ""}`),
        );
        await refreshArchives();
      },
      remove: async () => {
        await deleteFile(name);
        await refreshArchives();
      },
    });
  }

  const f2fPresent = (await Promise.all(chapters.map((c) => opfsFile("f2f/" + c)))).every(Boolean);
  items.push({
    key: "f2f",
    label: "Community descriptions",
    hint: "the From Forest to Fjaeldmark chapters",
    archive: null,
    bytes: 37e6,
    present: f2fPresent,
    partial: 0,
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

  const liveStatus = (key: string): HTMLElement | null =>
    list.querySelector(`[data-key="${key}"] .dl-status`);

  const render = () => {
    if (panel().hidden) return; // user closed the panel — nothing to draw into
    list.innerHTML = items
      .map((it) => {
        const inflight = it.archive ? activeDownload(it.archive) : null;
        const btn = inflight ? "Cancel" : it.present ? "Delete" : it.partial > 0 ? "Resume" : "Download";
        const status = errors.get(it.key)
          ?? (inflight
            ? fmtProgress(inflight.progress)
            : it.present
              ? "✓ downloaded"
              : it.partial > 0
                ? `paused at ${fmtMB(it.partial)}${it.bytes ? " of " + fmtMB(it.bytes) : ""}`
                : "");
        const size = it.bytes ? " · " + fmtMB(it.bytes) : it.present ? "" : " · not available yet";
        const disabled = !inflight && !it.present && it.partial === 0 && it.bytes === null && it.key !== "f2f";
        return `<div class="dl-item" data-key="${it.key}">
          <div class="dl-info"><b>${it.label}</b><small>${it.hint}${size}</small><small class="dl-status">${status}</small></div>
          <button class="dl-btn" ${disabled ? "disabled" : ""}>${btn}</button>
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

  // Event delegation: handlers never go stale, state read at tap time.
  list.onclick = async (ev) => {
    const row = (ev.target as HTMLElement).closest<HTMLElement>(".dl-item");
    if (!row || !(ev.target as HTMLElement).closest(".dl-btn")) return;
    const it = items.find((x) => x.key === row.dataset.key);
    if (!it) return;
    errors.delete(it.key);

    const act = it.archive ? activeDownload(it.archive) : null;
    if (act) {
      act.cancel();
      await act.promise.catch(() => {}); // settles via the watcher above
      return;
    }
    if (it.present) {
      await it.remove();
      it.present = false;
      it.partial = 0;
      render();
      return;
    }
    // start (or resume): it.action registers the download synchronously,
    // so the immediate render shows Cancel + live progress.
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

  render();
}

// ---------- Legend ----------

export function openLegend(): void {
  const mode = overlay.getMode() === "geo" ? "geo" : "veg";
  const slug = (g: string) => g.replace(/[^a-z0-9]+/gi, "-").toLowerCase();

  let groups: Map<string, string[]>;
  let row: (id: string) => string;
  if (mode === "geo") {
    groups = new Map();
    for (const [symb, u] of Object.entries(GEOLOGY_UNITS)) {
      if (!groups.has(u.group)) groups.set(u.group, []);
      groups.get(u.group)!.push(symb);
    }
    row = (symb) => {
      const u = GEOLOGY_UNITS[symb];
      return `<div class="leg-row"><span class="swatch" style="background:${u.color}"></span>
        <span><b>${symb}</b> ${u.description}</span></div>`;
    };
  } else {
    groups = new Map();
    for (const [code, m] of Object.entries(COMMUNITIES)) {
      if (!groups.has(m.group)) groups.set(m.group, []);
      groups.get(m.group)!.push(code);
    }
    row = (c) =>
      `<div class="leg-row"><span class="swatch" style="background:${COMMUNITIES[c].color}"></span>
       <span><b>${c}</b> ${COMMUNITIES[c].name.replace(/^\([A-Z]{3}\)\s*/, "")}</span></div>`;
  }

  const sorted = [...groups.entries()].sort();
  const opacity = overlay.getOpacity();
  // Chip labels: veg group first-words are unique; geology groups need more
  // (three start with "Devonian"/"Late"/"Early") — truncate the full name.
  const chipLabel = (g: string) =>
    mode === "geo" ? (g.length > 22 ? g.slice(0, 21).trimEnd() + "…" : g) : g.split(/[ ,]/)[0];
  const el = openPanel(
    `<div class="leg-top"><div class="leg-head"><h2>${mode === "geo" ? "Geology" : "Vegetation"} legend</h2>
      <div class="leg-opacity" role="group" aria-label="Overlay strength">
        <button class="leg-op ${opacity === 0.5 ? "on" : ""}" data-op="0.5">Full</button>
        <button class="leg-op ${opacity === 0.25 ? "on" : ""}" data-op="0.25">Light</button>
      </div></div>
      <div class="leg-chips">${sorted
        .map(([g]) => `<button class="leg-chip" data-target="${slug(g)}">${chipLabel(g)}</button>`)
        .join("")}</div></div>` +
      sorted
        .map(
          ([g, ids]) =>
            `<h3 class="leg-h" id="leg-${slug(g)}">${g}<span class="leg-count">${ids.length}</span></h3>` +
            ids.map(row).join(""),
        )
        .join(""),
  );
  const inner = el.querySelector<HTMLElement>(".panel-inner")!;
  for (const chip of el.querySelectorAll<HTMLButtonElement>(".leg-chip")) {
    chip.onclick = () => {
      const h = el.querySelector<HTMLElement>(`#leg-${chip.dataset.target}`);
      if (h) inner.scrollTop = h.offsetTop - inner.querySelector<HTMLElement>(".leg-top")!.offsetHeight - 8;
    };
  }
  for (const op of el.querySelectorAll<HTMLButtonElement>(".leg-op")) {
    op.onclick = () => {
      overlay.setOpacity(Number(op.dataset.op));
      for (const b of el.querySelectorAll(".leg-op"))
        b.classList.toggle("on", b === op);
    };
  }
}

// ---------- About ----------

export function openAbout(): void {
  openPanel(`<h2>IzzyMap</h2>
    <p class="about-lede">Which plant community am I standing in?</p>
    <p>Offline vegetation and topographic maps of Tasmania, made for one
    hiker's pocket.</p>
    <p class="muted">While the map is open the screen stays awake during GPS
    following — close the app or press the side button to save battery.</p>
    <p>Topographic Basemap from theLIST © State of Tasmania<br>
    TASVEG 5.0 from theLIST © State of Tasmania<br>
    Geology 1:500,000 from Mineral Resources Tasmania © State of Tasmania<br>
    <a href="https://creativecommons.org/licenses/by/3.0/au/">CC BY 3.0 AU</a></p>
    <p>Community descriptions: Kitchener &amp; Harris (2013), <i>From Forest to
    Fjaeldmark</i>, Ed. 2, DPIPWE — © Government of Tasmania.</p>
    <p class="muted">TASVEG mapping boundaries are indicative only.
    Built for personal use. <a href="https://github.com/lgruen/izzy-map">Source</a></p>`);
}
