import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { expect, test } from "@playwright/test";
import { blockTopoNetwork, centerFeature, routeTasvegFixture, waitForMapIdle } from "./helpers";

const HERE = dirname(fileURLToPath(import.meta.url));
const COMMUNITIES = JSON.parse(
  readFileSync(join(HERE, "../src/generated/tasveg_communities.json"), "utf8"),
) as Record<string, { color: string; name: string }>;

test.beforeEach(async ({ page }) => {
  await routeTasvegFixture(page);
  await blockTopoNetwork(page);
  await page.goto("/");
  await waitForMapIdle(page);
});

test("map loads at the GPS position with a TASVEG polygon under it", async ({ page }) => {
  const props = await centerFeature(page);
  expect(props).not.toBeNull();
  expect(props!.VEGCODE).toMatch(/^[A-Z]{3}$/);
  expect(Object.keys(COMMUNITIES)).toContain(props!.VEGCODE);
});

test("tapping a polygon opens the details sheet with correct community", async ({ page }) => {
  const props = await centerFeature(page);
  const viewport = page.viewportSize()!;
  await page.mouse.click(viewport.width / 2, viewport.height / 2);
  const sheet = page.locator("#sheet");
  await expect(sheet).toBeVisible();
  await expect(sheet).toContainText(props!.VEGCODE);
  await expect(sheet).toContainText(props!.VEG_GROUP);
  // swatch shows the official colour for the community
  const swatchColor = await sheet.locator(".swatch").evaluate(
    (el) => getComputedStyle(el).backgroundColor,
  );
  const hex = COMMUNITIES[props!.VEGCODE].color;
  const [r, g, b] = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));
  expect(swatchColor.replace(/\s/g, "")).toBe(`rgb(${r},${g},${b})`);
  // close button hides it again
  await sheet.locator(".sheet-close").click();
  await expect(sheet).toBeHidden();
});

test("fill-colour style expression carries every official QML colour", async ({ page }) => {
  const expr = await page.evaluate(() => {
    const map = (window as never as { __map: import("maplibre-gl").Map }).__map;
    return map.getPaintProperty("tasveg-fill", "fill-color") as unknown[];
  });
  // ["match", ["get","VEGCODE"], code, colour, code, colour, ..., fallback]
  const flat = expr.flat(Infinity).map(String);
  for (const [code, meta] of Object.entries(COMMUNITIES)) {
    const i = flat.indexOf(code);
    expect(i, `code ${code} present`).toBeGreaterThan(0);
    expect(flat[i + 1], `colour for ${code}`).toBe(meta.color);
  }
});

test("legend lists all 156 communities in 11 groups", async ({ page }) => {
  await page.locator("#btn-legend").click();
  const panel = page.locator("#panel");
  await expect(panel).toBeVisible();
  await expect(panel.locator(".leg-row")).toHaveCount(Object.keys(COMMUNITIES).length);
  await expect(panel.locator("h3")).toHaveCount(11);
});

test("overlay switcher cycles vegetation -> geology -> off", async ({ page }) => {
  const vis = (layer: string) =>
    page.evaluate(
      (l) => (window as never as { __map: import("maplibre-gl").Map }).__map.getLayoutProperty(l, "visibility"),
      layer,
    );
  expect(await vis("tasveg-fill")).toBe("visible");
  expect(await vis("geology-fill")).toBe("none");
  await page.locator("#btn-veg").click(); // -> geology
  expect(await vis("tasveg-fill")).toBe("none");
  expect(await vis("geology-fill")).toBe("visible");
  await expect.poll(() => centerFeature(page, "geology-fill"), { timeout: 20_000 }).not.toBeNull();
  const geo = await centerFeature(page, "geology-fill");
  expect(geo!.SYMB).toBeTruthy();
  await page.locator("#btn-veg").click(); // -> off
  expect(await vis("tasveg-fill")).toBe("none");
  expect(await vis("geology-fill")).toBe("none");
  await page.locator("#btn-veg").click(); // -> vegetation again
  expect(await vis("tasveg-fill")).toBe("visible");
});

test("geology tap shows unit details with official colour", async ({ page }) => {
  const UNITS = JSON.parse(
    readFileSync(join(HERE, "../src/generated/geology_units.json"), "utf8"),
  ) as Record<string, { description: string; color: string }>;
  await page.locator("#btn-veg").click(); // vegetation -> geology
  await expect.poll(() => centerFeature(page, "geology-fill"), { timeout: 20_000 }).not.toBeNull();
  const geo = await centerFeature(page, "geology-fill");
  const unit = UNITS[geo!.SYMB];
  expect(unit).toBeTruthy();
  const viewport = page.viewportSize()!;
  await page.mouse.click(viewport.width / 2, viewport.height / 2);
  const sheet = page.locator("#sheet");
  await expect(sheet).toBeVisible();
  await expect(sheet).toContainText(geo!.SYMB);
  await expect(sheet).toContainText(unit.description.slice(0, 20));
  const swatchColor = await sheet
    .locator(".swatch")
    .evaluate((el) => getComputedStyle(el).backgroundColor);
  const hex = unit.color;
  const [r, g, b] = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));
  expect(swatchColor.replace(/\s/g, "")).toBe(`rgb(${r},${g},${b})`);
});

test("legend follows the active overlay and sets opacity", async ({ page }) => {
  await page.locator("#btn-veg").click(); // -> geology
  await page.locator("#btn-legend").click();
  const panel = page.locator("#panel");
  await expect(panel).toContainText("Geology legend");
  await expect(panel.locator("h3")).toHaveCount(12);
  await panel.locator('.leg-op[data-op="0.25"]').click();
  const opacity = await page.evaluate(
    () => (window as never as { __map: import("maplibre-gl").Map }).__map.getPaintProperty("geology-fill", "fill-opacity"),
  );
  expect(opacity).toBe(0.25);
})

test("fallback tile is fully transparent (never fake ocean)", async ({ page }) => {
  // Regression: an earlier constant decoded to a half-opaque BLUE pixel, so
  // offline gaps rendered as water. Decode the constant the protocol module
  // actually exports and assert alpha 0.
  const alpha = await page.evaluate(async () => {
    const mod = await import("/src/protocol.ts");
    const png = await new Promise<HTMLImageElement>((ok, err) => {
      const img = new Image();
      img.onload = () => ok(img);
      img.onerror = err;
      img.src = "data:image/png;base64," + (mod as { BLANK_PNG_B64: string }).BLANK_PNG_B64;
    });
    const c = document.createElement("canvas");
    c.width = c.height = 1;
    const ctx = c.getContext("2d")!;
    ctx.drawImage(png, 0, 0);
    return ctx.getImageData(0, 0, 1, 1).data[3];
  });
  expect(alpha).toBe(0);
})

test("offline: OPFS archive keeps serving vegetation tiles", async ({ page, browserName }) => {
  test.skip(browserName === "webkit", "Playwright WebKit build lacks OPFS createWritable");
  // Seed OPFS with the fixture as if the user had downloaded it.
  await page.evaluate(async () => {
    const res = await fetch("/dev-data/tasveg.pmtiles");
    const buf = await res.arrayBuffer();
    const root = await navigator.storage.getDirectory();
    const fh = await root.getFileHandle("tasveg.pmtiles", { create: true });
    const w = await fh.createWritable();
    await w.write(buf);
    await w.close();
  });
  // Sever every non-dev-server network path and make the app believe it is
  // offline (context.setOffline would also kill localhost, and the dev
  // server stands in for the service-worker-cached shell).
  await page.route("**", (route) =>
    route.request().url().startsWith("http://localhost:5200")
      ? route.continue()
      : route.abort(),
  );
  await page.addInitScript(() => {
    Object.defineProperty(navigator, "onLine", { value: false });
  });
  await page.reload();
  await waitForMapIdle(page);
  const props = await centerFeature(page);
  expect(props).not.toBeNull();
  expect(props!.VEGCODE).toMatch(/^[A-Z]{3}$/);
});


// Minimal valid single-page PDF ("Hi") — synthetic, no licensed content.
const TINY_PDF = `%PDF-1.4
1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj
2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj
3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 595 842]/Contents 4 0 R>>endobj
4 0 obj<</Length 44>>stream
BT /F1 24 Tf 100 700 Td (Hi) Tj ET
endstream
endobj
xref
0 5
0000000000 65535 f 
0000000009 00000 n 
0000000052 00000 n 
0000000101 00000 n 
0000000179 00000 n 
trailer<</Size 5/Root 1 0 R>>
startxref
270
%%EOF`;

test("offline: descriptions open from OPFS via the in-app viewer", async ({ page, browserName }) => {
  test.skip(browserName === "webkit", "Playwright WebKit build lacks OPFS createWritable");
  await routeTasvegFixture(page);
  await page.goto("/");
  await waitForMapIdle(page);
  const props = await centerFeature(page);
  // Seed the chapter file the tapped community needs with the synthetic PDF.
  await page.evaluate(async ({ pdf, code }) => {
    const mod = await fetch("/src/generated/f2f_index.json").then((r) => r.json());
    const file = mod.index[code].file as string;
    const root = await navigator.storage.getDirectory();
    const dir = await root.getDirectoryHandle("f2f", { create: true });
    const fh = await dir.getFileHandle(file, { create: true });
    const w = await fh.createWritable();
    await w.write(new TextEncoder().encode(pdf));
    await w.close();
  }, { pdf: TINY_PDF, code: props!.VEGCODE });
  // Go "offline": kill everything except the dev server (app shell stand-in).
  await page.route("**", (route) =>
    route.request().url().startsWith("http://localhost:5200") ? route.continue() : route.abort(),
  );
  const viewport = page.viewportSize()!;
  await page.mouse.click(viewport.width / 2, viewport.height / 2);
  await page.locator(".sheet-desc").click();
  await expect(page.locator("#pdfview")).toBeVisible();
  await expect(page.locator(".pdf-page canvas").first()).toBeVisible({ timeout: 20_000 });

  // Pinch out (fingers spread to 2× apart): pages must re-lay-out at twice
  // the width and re-render sharp at the new scale.
  const before = await page.locator(".pdf-page").first().evaluate((el) => el.clientWidth);
  await page.evaluate(() => {
    const scroll = document.querySelector<HTMLElement>(".pdf-scroll")!;
    const send = (type: string, pts: [number, number][]) => {
      const touches = pts.map(
        ([clientX, clientY], identifier) =>
          new Touch({ identifier, target: scroll, clientX, clientY }),
      );
      scroll.dispatchEvent(
        new TouchEvent(type, { touches, changedTouches: touches, bubbles: true, cancelable: true }),
      );
    };
    send("touchstart", [[150, 300], [250, 300]]);
    send("touchmove", [[100, 300], [300, 300]]);
    send("touchend", []);
  });
  await expect(page.locator(".pdf-page").first()).toHaveJSProperty("clientWidth", before * 2);
  await expect(page.locator(".pdf-page canvas").first()).toBeVisible({ timeout: 20_000 });
});

test("interrupted archive download resumes from completed chunks", async ({ page, browserName }) => {
  test.skip(browserName === "webkit", "Playwright WebKit build lacks OPFS createWritable");
  const CHUNK = 256 * 1024;
  const rangeStarts: number[] = [];
  let served = 0;
  const FIXTURE_LEN = 3_460_947; // committed Hobart-clip fixture
  await page.route("**/dev-data/resume-src.pmtiles", async (route) => {
    const m = /bytes=(\d+)-(\d*)/.exec(route.request().headers()["range"] ?? "");
    const start = m ? Number(m[1]) : 0;
    rangeStarts.push(start);
    served++;
    if (served === 4) return route.abort(); // simulated connection loss
    const { readFileSync } = await import("node:fs");
    const { join, dirname } = await import("node:path");
    const { fileURLToPath } = await import("node:url");
    const fx = readFileSync(join(dirname(fileURLToPath(import.meta.url)), "fixtures", "tasveg_test.pmtiles"));
    const end = m && m[2] ? Math.min(Number(m[2]), fx.length - 1) : fx.length - 1;
    await route.fulfill({
      status: 206,
      headers: {
        "Content-Range": `bytes ${start}-${end}/${fx.length}`,
        ETag: '"fixture-v1"',
      },
      body: fx.subarray(start, end + 1),
    });
  });
  const result = await page.evaluate(async (chunk) => {
    const { download, opfsFile, partialBytes } = await import("/src/storage.ts");
    const err = await download("/dev-data/resume-src.pmtiles", "resume-test.pmtiles", undefined, { chunkSize: chunk })
      .then(() => null, (e: Error) => e.message);
    const partial = await partialBytes("resume-test.pmtiles");
    await download("/dev-data/resume-src.pmtiles", "resume-test.pmtiles", undefined, { chunkSize: chunk });
    const file = await opfsFile("resume-test.pmtiles");
    const head = await file!.slice(0, 7).text();
    const partsAfter = await partialBytes("resume-test.pmtiles");
    return { err, partial, size: file!.size, head, partsAfter };
  }, CHUNK);
  expect(result.err).toContain("Connection lost");
  expect(result.partial).toBe(3 * CHUNK); // three committed chunks survive
  // the resume's first request continued exactly at the committed boundary
  expect(rangeStarts[4]).toBe(3 * CHUNK);
  expect(result.head).toBe("PMTiles");
  expect(result.size).toBe(FIXTURE_LEN);
  expect(result.partsAfter).toBe(0); // parts cleaned up after assembly
})
