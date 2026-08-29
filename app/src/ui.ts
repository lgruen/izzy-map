// Panels: offline downloads manager, legend, about. One panel at a time.
import { ARCHIVES, DATA_BASE } from "./config";
import { deleteFile, download, opfsFile, storageInfo } from "./storage";
import { COMMUNITIES } from "./style";
import { refreshArchives } from "./protocol";
import f2f from "./generated/f2f_index.json";

const F2F = f2f as { baseUrl: string; index: Record<string, { file: string; page: number }> };
// F2F PDFs have no CORS on nre.tas.gov.au; this pass-through proxy adds it.
// Set after the Cloudflare Worker is deployed (see pipeline/f2f-proxy/).
const F2F_PROXY: string = import.meta.env.VITE_F2F_PROXY ?? "";

const fmtMB = (b: number) => (b >= 1e9 ? (b / 1e9).toFixed(2) + " GB" : Math.round(b / 1e6) + " MB");

interface ManifestEntry {
  file: string;
  bytes: number;
}
interface DataManifest {
  version: string;
  archives: Record<string, ManifestEntry>;
}

async function fetchManifest(): Promise<DataManifest | null> {
  try {
    const r = await fetch(`${DATA_BASE}/data-manifest.json`, { cache: "no-cache" });
    return r.ok ? await r.json() : null;
  } catch {
    return null;
  }
}

const panel = () => document.getElementById("panel")!;
export function closePanel(): void {
  panel().hidden = true;
}
function openPanel(html: string): HTMLElement {
  const el = panel();
  el.innerHTML = `<div class="panel-inner"><button class="panel-close" aria-label="Close">×</button>${html}</div>`;
  el.hidden = false;
  el.querySelector<HTMLButtonElement>(".panel-close")!.onclick = closePanel;
  return el;
}

// ---------- Downloads ----------

const chapters = [...new Set(Object.values(F2F.index).map((e) => e.file))];

export async function openDownloads(): Promise<void> {
  const el = openPanel(`<h2>Offline data</h2><div id="dl-list">Checking…</div>
    <p id="storage-line" class="muted"></p>
    <p class="muted">Download on Wi-Fi. Everything keeps working in airplane
    mode afterwards.</p>`);
  const list = el.querySelector<HTMLElement>("#dl-list")!;
  const manifest = await fetchManifest();

  const items: {
    key: string;
    label: string;
    hint: string;
    bytes: number | null;
    present: boolean;
    action: (report: (msg: string) => void) => Promise<void>;
    remove: () => Promise<void>;
  }[] = [];

  for (const [key, label, hint] of [
    ["tasveg", "Vegetation map (TASVEG 5.0)", "statewide, required for the overlay"],
    ["topo", "Topographic base map", "statewide to zoom 15"],
  ] as const) {
    const name = ARCHIVES[key];
    const present = !!(await opfsFile(name));
    const bytes = manifest?.archives[key]?.bytes ?? null;
    items.push({
      key,
      label,
      hint,
      bytes,
      present,
      action: async (report) => {
        await download(`${DATA_BASE}/${name}`, name, (p) =>
          report(`${fmtMB(p.received)}${p.total ? " / " + fmtMB(p.total) : ""}`),
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
    hint: "From Forest to Fjaeldmark chapters",
    bytes: 37e6,
    present: f2fPresent,
    action: async (report) => {
      if (!F2F_PROXY) throw new Error("description proxy not configured yet");
      for (let i = 0; i < chapters.length; i++) {
        report(`chapter ${i + 1} / ${chapters.length}`);
        if (await opfsFile("f2f/" + chapters[i])) continue;
        await download(`${F2F_PROXY}/${chapters[i]}`, "f2f/" + chapters[i]);
      }
    },
    remove: async () => {
      for (const c of chapters) await deleteFile("f2f/" + c);
    },
  });

  const render = async () => {
    list.innerHTML = items
      .map(
        (it) => `<div class="dl-item" data-key="${it.key}">
          <div class="dl-info"><b>${it.label}</b><small>${it.hint}${
            it.bytes ? " · " + fmtMB(it.bytes) : ""
          }</small><small class="dl-status">${it.present ? "✓ downloaded" : ""}</small></div>
          <button class="dl-btn">${it.present ? "Delete" : "Download"}</button>
        </div>`,
      )
      .join("");
    const { usage, quota } = await storageInfo();
    el.querySelector("#storage-line")!.textContent =
      `Storage used: ${fmtMB(usage)} of ${fmtMB(quota)} available`;

    for (const it of items) {
      const row = list.querySelector(`[data-key="${it.key}"]`)!;
      const btn = row.querySelector<HTMLButtonElement>(".dl-btn")!;
      const status = row.querySelector<HTMLElement>(".dl-status")!;
      btn.onclick = async () => {
        btn.disabled = true;
        try {
          if (it.present) {
            await it.remove();
            it.present = false;
          } else {
            await it.action((msg) => (status.textContent = msg));
            it.present = true;
          }
        } catch (e) {
          status.textContent = "failed: " + (e instanceof Error ? e.message : e);
          btn.disabled = false;
          return;
        }
        await render();
      };
    }
  };
  await render();
}

// ---------- Legend ----------

export function openLegend(): void {
  const groups = new Map<string, string[]>();
  for (const [code, m] of Object.entries(COMMUNITIES)) {
    if (!groups.has(m.group)) groups.set(m.group, []);
    groups.get(m.group)!.push(code);
  }
  openPanel(
    `<h2>TASVEG legend</h2>` +
      [...groups.entries()]
        .sort()
        .map(
          ([g, codes]) =>
            `<h3>${g}</h3>` +
            codes
              .map(
                (c) =>
                  `<div class="leg-row"><span class="swatch" style="background:${COMMUNITIES[c].color}"></span>
                   <span><b>${c}</b> ${COMMUNITIES[c].name}</span></div>`,
              )
              .join(""),
        )
        .join(""),
  );
}

// ---------- About ----------

export function openAbout(): void {
  openPanel(`<h2>IzzyMap</h2>
    <p>Offline Tasmania vegetation &amp; topographic map.</p>
    <p>Topographic Basemap from theLIST © State of Tasmania<br>
    TASVEG 5.0 from theLIST © State of Tasmania<br>
    <a href="https://creativecommons.org/licenses/by/3.0/au/">CC BY 3.0 AU</a></p>
    <p>Community descriptions: Kitchener &amp; Harris (2013), <i>From Forest to
    Fjaeldmark</i>, Ed. 2, DPIPWE — © Government of Tasmania.</p>
    <p class="muted">TASVEG mapping boundaries are indicative only.
    Built for personal use. <a href="https://github.com/lgruen/izzy-map">Source</a></p>`);
}
