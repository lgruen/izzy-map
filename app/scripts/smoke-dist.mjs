// Usage: npm run build && npx vite preview --port 4173 &  then  node scripts/smoke-dist.mjs
// Smoke test of the PRODUCTION bundle (vite preview): the map must load and
// a TASVEG polygon must be queryable at the GPS point — only possible if the
// MapLibre worker (vector tile parsing) actually started.
import { chromium, webkit } from "playwright";
for (const [name, engine] of [["chromium", chromium], ["webkit", webkit]]) {
  const browser = await engine.launch();
  const ctx = await browser.newContext({
    viewport: { width: 390, height: 844 },
    geolocation: { latitude: -42.92, longitude: 147.235 },
    permissions: ["geolocation"],
  });
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push("pageerror: " + e.message));
  page.on("console", (m) => { if (m.type() === "error") errors.push("console: " + m.text()); });
  await page.goto("http://localhost:4173/");
  await page.waitForFunction(() => window.__map && window.__map.loaded() && !window.__map.isMoving(), null, { timeout: 60000 });
  await page.waitForTimeout(4000);
  const r = await page.evaluate(() => {
    const m = window.__map; const c = m.project(m.getCenter());
    const f = m.queryRenderedFeatures([c.x, c.y], { layers: ["tasveg-fill"] })[0];
    return { zoom: m.getZoom().toFixed(1), vegcode: f?.properties?.VEGCODE ?? null, sw: !!navigator.serviceWorker?.controller, workerUrl: (document.querySelector("script[type=module]") ? "module" : "?") };
  });
  console.log(name, JSON.stringify(r), errors.length ? errors.slice(0, 3) : "no errors");
  await browser.close();
}
