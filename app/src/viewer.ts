// In-app PDF viewer (pdf.js) for the From Forest to Fjaeldmark chapters.
// Needed because Safari ignores #page= fragments on blob: URLs, so deep
// linking to a community's section only works if we control the rendering.
// Works identically from an OPFS File (offline) or a URL (online, via the
// CORS proxy).
import * as pdfjs from "pdfjs-dist";
import type { PDFDocumentLoadingTask, PDFDocumentProxy } from "pdfjs-dist";

pdfjs.GlobalWorkerOptions.workerSrc = new URL(
  "pdfjs-dist/build/pdf.worker.min.mjs",
  import.meta.url,
).toString();

const el = () => document.getElementById("pdfview")!;

export async function openPdfViewer(
  source: File | string,
  pageIndex: number,
  title: string,
): Promise<void> {
  close(); // destroy any previous document + worker before opening anew
  const root = el();
  root.innerHTML = `
    <div class="pdf-bar">
      <span class="pdf-title">${title.replace(/</g, "&lt;")}</span>
      <span class="pdf-pageno"></span>
      <button class="pdf-zoom" aria-label="Zoom">1×</button>
      <button class="pdf-close" aria-label="Close">×</button>
    </div>
    <div class="pdf-scroll"></div>`;
  root.hidden = false;
  root.querySelector<HTMLButtonElement>(".pdf-close")!.onclick = close;

  const scroll = root.querySelector<HTMLElement>(".pdf-scroll")!;
  let userScrolled = false;
  let doc: PDFDocumentProxy;
  try {
    const task = typeof source === "string"
      ? pdfjs.getDocument({ url: source })
      : pdfjs.getDocument({ data: await source.arrayBuffer() });
    currentTask = task;
    doc = await task.promise;
  } catch (e) {
    scroll.innerHTML = `<p class="pdf-error">Couldn't open the document: ${
      e instanceof Error ? e.message : e
    }</p>`;
    return;
  }
  currentDoc = doc;

  // Uniform-size placeholders sized from page 1, lazily rendered on approach.
  // A4 two-column text at phone width is unreadably small, so a zoom cycle
  // re-lays-out at wider widths with horizontal panning.
  const first = await doc.getPage(1);
  const baseVp = first.getViewport({ scale: 1 });
  const ZOOMS = [1, 1.6, 2.2];
  let zoomIdx = 0;
  const fitWidth = Math.min(scroll.clientWidth, 900);
  let width = fitWidth;
  let scale = width / baseVp.width;
  const holders: HTMLDivElement[] = [];
  for (let i = 1; i <= doc.numPages; i++) {
    const holder = document.createElement("div");
    holder.className = "pdf-page";
    holder.dataset.page = String(i);
    holder.style.width = `${width}px`;
    holder.style.height = `${baseVp.height * scale}px`;
    scroll.appendChild(holder);
    holders.push(holder);
  }

  const pageNo = root.querySelector<HTMLElement>(".pdf-pageno")!;
  // Canvas memory is the iOS killer: ~7 MB per page at dpr 3, and WebKit
  // enforces a global canvas budget. Clamp the render dpr and keep only a
  // small LRU window of rendered pages; evicted holders return to
  // placeholders and re-render on approach.
  const dpr = Math.min(devicePixelRatio || 1, 2);
  const MAX_RENDERED = 10;
  const rendered: number[] = []; // LRU order, most recent last
  const inFlight = new Set<number>();
  let generation = 0; // bumped by zoom: in-flight renders at old scale discard
  const render = async (n: number) => {
    if (!currentDoc || inFlight.has(n)) return;
    const at = rendered.indexOf(n);
    if (at >= 0) {
      rendered.splice(at, 1);
      rendered.push(n);
      return;
    }
    inFlight.add(n);
    const gen = generation;
    try {
      const page = await doc.getPage(n);
      const vp = page.getViewport({ scale: scale * dpr });
      const canvas = document.createElement("canvas");
      canvas.width = vp.width;
      canvas.height = vp.height;
      canvas.style.width = "100%";
      await page.render({ canvas, canvasContext: canvas.getContext("2d")!, viewport: vp }).promise;
      if (gen !== generation) return; // zoomed while rendering — stale size
      holders[n - 1].replaceChildren(canvas);
      rendered.push(n);
      while (rendered.length > MAX_RENDERED) {
        const evict = rendered.shift()!;
        holders[evict - 1].replaceChildren();
      }
    } finally {
      inFlight.delete(n);
    }
  };

  /** Render the pages around the current scroll position (IO only fires on
   * boundary crossings, so pages already inside the window need this after
   * a zoom re-layout). */
  const renderViewport = () => {
    const first = Math.max(1, Math.floor(scroll.scrollTop / pageStride));
    for (let n = first; n <= Math.min(doc.numPages, first + 3); n++) void render(n);
  };

  const zoomBtn = root.querySelector<HTMLButtonElement>(".pdf-zoom")!;
  zoomBtn.onclick = () => {
    const keepPage = scroll.scrollTop / pageStride; // fractional page position
    zoomIdx = (zoomIdx + 1) % ZOOMS.length;
    width = Math.round(fitWidth * ZOOMS[zoomIdx]);
    scale = width / baseVp.width;
    pageStride = baseVp.height * scale + 8;
    zoomBtn.textContent = `${ZOOMS[zoomIdx]}×`;
    generation++; // in-flight renders at the old scale must discard
    rendered.length = 0; // all canvases are the wrong size now
    userScrolled = true; // a zoom must also stop the initial jump loop
    for (const h of holders) {
      h.replaceChildren();
      h.style.width = `${width}px`;
      h.style.height = `${baseVp.height * scale}px`;
    }
    scroll.classList.toggle("zoomed", zoomIdx > 0);
    scroll.scrollTop = keepPage * pageStride;
    // IO won't re-fire for holders that never left its window — render the
    // visible ones explicitly or the page being read stays blank.
    renderViewport();
  };

  const io = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        void render(Number((entry.target as HTMLElement).dataset.page));
      }
    },
    { root: scroll, rootMargin: "150% 0%" },
  );
  holders.forEach((h) => io.observe(h));

  let pageStride = baseVp.height * scale + 8; // holder height + flex gap
  scroll.addEventListener("scroll", () => {
    const n = Math.min(doc.numPages, Math.floor(scroll.scrollTop / pageStride) + 1);
    pageNo.textContent = `${n} / ${doc.numPages}`;
  }, { passive: true });
  pageNo.textContent = `${pageIndex + 1} / ${doc.numPages}`;

  // Jump to the community's section page. The scroll offset is computed
  // arithmetically (uniform holder heights), NOT from offsetTop — during
  // progressive layout offsetTop reads low, and WebKit's scroll anchoring
  // then walks the position as canvases render. Keep re-asserting until the
  // container is tall enough and the value sticks; stop the moment the user
  // scrolls themselves.
  const idx = Math.min(pageIndex, doc.numPages - 1);
  const want = Math.round(pageStride * idx);
  for (const ev of ["touchstart", "wheel"])
    scroll.addEventListener(ev, () => (userScrolled = true), { once: true, passive: true });
  let settled = 0;
  const jump = (attempt: number) => {
    if (userScrolled || attempt > 60) return;
    if (scroll.scrollHeight >= want + scroll.clientHeight) {
      scroll.scrollTop = want;
      if (Math.abs(scroll.scrollTop - want) <= 2) settled++;
      else settled = 0;
      if (settled >= 4) return; // stayed put across several frames — done
    }
    setTimeout(() => jump(attempt + 1), 50);
  };
  jump(0);
}

let currentDoc: PDFDocumentProxy | null = null;
let currentTask: PDFDocumentLoadingTask | null = null;
function close(): void {
  el().hidden = true;
  el().innerHTML = "";
  void currentTask?.destroy(); // frees the worker + document, not just pages
  currentTask = null;
  currentDoc = null;
}
