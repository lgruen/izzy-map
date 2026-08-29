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
      <button class="pdf-close" aria-label="Close">×</button>
    </div>
    <div class="pdf-scroll"><div class="pdf-pages"></div></div>`;
  root.hidden = false;
  root.querySelector<HTMLButtonElement>(".pdf-close")!.onclick = close;

  const scroll = root.querySelector<HTMLElement>(".pdf-scroll")!;
  const pages = root.querySelector<HTMLElement>(".pdf-pages")!;
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
  // A4 two-column text at phone width is unreadably small, so pinch-zoom
  // re-lays-out at wider widths with two-axis panning (native scrolling).
  const first = await doc.getPage(1);
  const baseVp = first.getViewport({ scale: 1 });
  const MAX_ZOOM = 3;
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
    pages.appendChild(holder);
    holders.push(holder);
  }

  const pageNo = root.querySelector<HTMLElement>(".pdf-pageno")!;
  // Canvas memory is the iOS killer: ~7 MB per page at dpr 3, and WebKit
  // enforces a global canvas budget. Clamp the render dpr and keep only a
  // small LRU window of rendered pages; evicted holders return to
  // placeholders and re-render on approach.
  const dpr = Math.min(devicePixelRatio || 1, 2);
  // A page at zoom z costs z² the pixels, so the LRU window shrinks as zoom
  // grows to keep total canvas memory roughly flat (10 pages at fit width,
  // ~5 at 3×; 48 ≈ the old ceiling of 10 pages at 2.2×).
  const maxRendered = () =>
    Math.min(10, Math.max(4, Math.floor(48 / (width / fitWidth) ** 2)));
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
      while (rendered.length > maxRendered()) {
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

  // Continuous zoom: pinch on touch, ctrl+wheel on desktop (trackpads report
  // pinches that way). Re-rendering pages on every finger move would melt the
  // phone, so during the gesture only the pages container is scaled with a
  // CSS transform (cheap but blurry); when the gesture ends the layout
  // re-flows at the final width and pages re-render sharp. Panning needs no
  // code at all — it's native two-axis scrolling.
  const clampF = (f: number) =>
    Math.min(Math.max(f, fitWidth / width), (fitWidth * MAX_ZOOM) / width);

  type Gesture = { xw: number; yw: number; xRel: number; yRel: number; f: number };
  /** Anchor a gesture at a viewport point: xw/yw is the document point under
   * it in pages-container coordinates, xRel/yRel its position in the scroll
   * viewport. The preview transform and the final re-layout both pin xw/yw
   * to xRel/yRel, so the spot under the fingers never jumps. */
  const startGesture = (clientX: number, clientY: number): Gesture => {
    const r = scroll.getBoundingClientRect();
    const xRel = clientX - r.left;
    const yRel = clientY - r.top;
    const g = {
      xw: scroll.scrollLeft + xRel - pages.offsetLeft,
      yw: scroll.scrollTop + yRel - pages.offsetTop,
      xRel,
      yRel,
      f: 1,
    };
    pages.style.transformOrigin = `${g.xw}px ${g.yw}px`;
    return g;
  };

  const relayout = (g: Gesture) => {
    const newWidth = Math.round(width * clampF(g.f));
    const ratio = newWidth / width;
    if (ratio !== 1) {
      width = newWidth;
      scale = width / baseVp.width;
      pageStride = baseVp.height * scale + 8;
      generation++; // in-flight renders at the old scale must discard
      rendered.length = 0; // all canvases are the wrong size now
      for (const h of holders) {
        h.replaceChildren();
        h.style.width = `${width}px`;
        h.style.height = `${baseVp.height * scale}px`;
      }
      // Centering a wider-than-viewport flex child makes its left edge
      // unreachable — switch to flex-start once pages overflow.
      scroll.classList.toggle("zoomed", width > scroll.clientWidth);
    }
    userScrolled = true; // a zoom must also stop the initial jump loop
    pages.style.transform = "";
    // Reading offsetLeft/Top here forces layout, so the centering offset is
    // the post-zoom one.
    scroll.scrollLeft = g.xw * ratio + pages.offsetLeft - g.xRel;
    scroll.scrollTop = g.yw * ratio + pages.offsetTop - g.yRel;
    // IO won't re-fire for holders that never left its window — render the
    // visible ones explicitly or the page being read stays blank.
    renderViewport();
  };

  let pinch: (Gesture & { dist: number; startX: number; startY: number }) | null = null;
  const mid = (t: TouchList) => ({
    x: (t[0].clientX + t[1].clientX) / 2,
    y: (t[0].clientY + t[1].clientY) / 2,
    dist: Math.hypot(t[0].clientX - t[1].clientX, t[0].clientY - t[1].clientY),
  });
  scroll.addEventListener(
    "touchstart",
    (e) => {
      if (e.touches.length !== 2) return;
      e.preventDefault(); // our pinch, not Safari's page zoom
      const m = mid(e.touches);
      pinch = { ...startGesture(m.x, m.y), dist: m.dist, startX: m.x, startY: m.y };
    },
    { passive: false },
  );
  scroll.addEventListener(
    "touchmove",
    (e) => {
      if (!pinch || e.touches.length !== 2) return;
      e.preventDefault();
      const m = mid(e.touches);
      const r = scroll.getBoundingClientRect();
      pinch.f = clampF(m.dist / pinch.dist);
      // Follow the midpoint too, so two-finger panning works mid-pinch.
      pinch.xRel = m.x - r.left;
      pinch.yRel = m.y - r.top;
      pages.style.transform = `translate(${m.x - pinch.startX}px, ${
        m.y - pinch.startY
      }px) scale(${pinch.f})`;
    },
    { passive: false },
  );
  const endPinch = () => {
    if (!pinch) return;
    relayout(pinch);
    pinch = null;
  };
  scroll.addEventListener("touchend", endPinch);
  scroll.addEventListener("touchcancel", endPinch);

  let wheel: (Gesture & { timer: number }) | null = null;
  scroll.addEventListener(
    "wheel",
    (e) => {
      if (!e.ctrlKey) return; // plain wheel keeps scrolling natively
      e.preventDefault(); // don't zoom the whole app
      wheel ??= { ...startGesture(e.clientX, e.clientY), timer: 0 };
      clearTimeout(wheel.timer);
      wheel.f = clampF(wheel.f * Math.exp(-e.deltaY / 100));
      pages.style.transform = `scale(${wheel.f})`;
      wheel.timer = window.setTimeout(() => {
        relayout(wheel!);
        wheel = null;
      }, 140);
    },
    { passive: false },
  );

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
