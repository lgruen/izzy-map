// In-app PDF viewer (pdf.js) for the From Forest to Fjaeldmark chapters.
// Needed because Safari ignores #page= fragments on blob: URLs, so deep
// linking to a community's section only works if we control the rendering.
// Works identically from an OPFS File (offline) or a URL (online, via the
// CORS proxy).
import * as pdfjs from "pdfjs-dist";
import type { PDFDocumentProxy } from "pdfjs-dist";

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
  const root = el();
  root.innerHTML = `
    <div class="pdf-bar">
      <span class="pdf-title">${title.replace(/</g, "&lt;")}</span>
      <span class="pdf-pageno"></span>
      <button class="pdf-close" aria-label="Close">×</button>
    </div>
    <div class="pdf-scroll"></div>`;
  root.hidden = false;
  root.querySelector<HTMLButtonElement>(".pdf-close")!.onclick = close;

  const scroll = root.querySelector<HTMLElement>(".pdf-scroll")!;
  let doc: PDFDocumentProxy;
  try {
    doc = await (typeof source === "string"
      ? pdfjs.getDocument({ url: source })
      : pdfjs.getDocument({ data: await source.arrayBuffer() })
    ).promise;
  } catch (e) {
    scroll.innerHTML = `<p class="pdf-error">Couldn't open the document: ${
      e instanceof Error ? e.message : e
    }</p>`;
    return;
  }
  currentDoc = doc;

  // Uniform-size placeholders sized from page 1, lazily rendered on approach.
  const first = await doc.getPage(1);
  const baseVp = first.getViewport({ scale: 1 });
  const width = Math.min(scroll.clientWidth, 900);
  const scale = width / baseVp.width;
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
  const rendered = new Set<number>();
  const render = async (n: number) => {
    if (rendered.has(n) || !currentDoc) return;
    rendered.add(n);
    const page = await doc.getPage(n);
    const vp = page.getViewport({ scale: scale * devicePixelRatio });
    const canvas = document.createElement("canvas");
    canvas.width = vp.width;
    canvas.height = vp.height;
    canvas.style.width = "100%";
    await page.render({ canvas, canvasContext: canvas.getContext("2d")!, viewport: vp }).promise;
    holders[n - 1].replaceChildren(canvas);
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

  const pageStride = baseVp.height * scale + 8; // holder height + flex gap
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
  let userScrolled = false;
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
function close(): void {
  el().hidden = true;
  el().innerHTML = "";
  void currentDoc?.cleanup();
  currentDoc = null;
}
