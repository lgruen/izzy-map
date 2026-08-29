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

test("veg layer toggle hides and restores the overlay", async ({ page }) => {
  await page.locator("#btn-veg").click();
  await page.waitForTimeout(400);
  expect(await centerFeature(page)).toBeNull();
  await page.locator("#btn-veg").click();
  await page.waitForTimeout(400);
  expect(await centerFeature(page)).not.toBeNull();
});

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
