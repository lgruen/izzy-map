import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { expect, test, type Page } from "@playwright/test";
import {
  AERIAL_FIXTURE,
  CENTRE_TILE,
  COLOURS,
  SEASON_2023_FIXTURE,
  SEASON_2024_FIXTURE,
  blockLiveServices,
  blockTopoNetwork,
  centerFeature,
  chooseLayer,
  closePanel,
  jumpToTile,
  near,
  pixelAt,
  routeRasterFixtures,
  routeTasvegFixture,
  waitForMapIdle,
  waitForTiles,
} from "./helpers";
import { PRE_CHIPS } from "../src/chips";

const HERE = dirname(fileURLToPath(import.meta.url));
const COMMUNITIES = JSON.parse(
  readFileSync(join(HERE, "../src/generated/tasveg_communities.json"), "utf8"),
) as Record<string, { color: string; name: string }>;

const vis = (page: Page, layer: string) =>
  page.evaluate(
    (l) => (window as never as { __map: import("maplibre-gl").Map }).__map.getLayoutProperty(l, "visibility"),
    layer,
  );
const seedOpfs = (page: Page, name: string, bytes: Buffer) =>
  page.evaluate(async ({ name, b64 }) => {
    const buf = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
    const root = await navigator.storage.getDirectory();
    const fh = await root.getFileHandle(name, { create: true });
    const w = await fh.createWritable();
    await w.write(buf);
    await w.close();
  }, { name, b64: bytes.toString("base64") });
const setRange = (page: Page, value: number) =>
  page.locator("#lay-range").evaluate((el, v) => {
    (el as HTMLInputElement).value = String(v);
    el.dispatchEvent(new Event("input", { bubbles: true }));
  }, value);

test.beforeEach(async ({ page }) => {
  await blockTopoNetwork(page);
  await routeRasterFixtures(page); // vector + synthetic raster fixtures
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
  await expect(panel.locator("h3.leg-h")).toHaveCount(11);
});

test("Layers sheet switches the overlay: vegetation / pre-1750 / geology / none", async ({ page }) => {
  expect(await vis(page, "tasveg-fill")).toBe("visible");
  expect(await vis(page, "pre1750-fill")).toBe("none");
  expect(await vis(page, "geology-fill")).toBe("none");
  await chooseLayer(page, "overlay", "pre");
  expect(await vis(page, "tasveg-fill")).toBe("none");
  expect(await vis(page, "pre1750-fill")).toBe("visible");
  await expect.poll(() => centerFeature(page, "pre1750-fill"), { timeout: 20_000 }).not.toBeNull();
  expect((await centerFeature(page, "pre1750-fill"))!.MVS).toBeTruthy();
  await chooseLayer(page, "overlay", "geo");
  expect(await vis(page, "tasveg-fill")).toBe("none");
  expect(await vis(page, "pre1750-fill")).toBe("none");
  expect(await vis(page, "geology-fill")).toBe("visible");
  await expect.poll(() => centerFeature(page, "geology-fill"), { timeout: 20_000 }).not.toBeNull();
  expect((await centerFeature(page, "geology-fill"))!.SYMB).toBeTruthy();
  await chooseLayer(page, "overlay", "off");
  expect(await vis(page, "tasveg-fill")).toBe("none");
  expect(await vis(page, "pre1750-fill")).toBe("none");
  expect(await vis(page, "geology-fill")).toBe("none");
  await chooseLayer(page, "overlay", "veg");
  expect(await vis(page, "tasveg-fill")).toBe("visible");
  await expect(page.locator('.lay-row[data-overlay="veg"]')).toHaveClass(/\bon\b/);
  await expect(page.locator('.lay-row[data-overlay="geo"]')).not.toHaveClass(/\bon\b/);
  // status badges: nothing is downloaded in tests
  await expect(page.locator('.lay-row[data-overlay="veg"] .lay-status')).toContainText("not downloaded");
});

test("pre-1750 tap shows subgroup details with official colour", async ({ page }) => {
  const UNITS = JSON.parse(
    readFileSync(join(HERE, "../src/generated/pre1750_units.json"), "utf8"),
  ) as Record<string, { name: string; group: string; color: string }>;
  await chooseLayer(page, "overlay", "pre");
  await closePanel(page);
  await expect.poll(() => centerFeature(page, "pre1750-fill"), { timeout: 20_000 }).not.toBeNull();
  const pre = await centerFeature(page, "pre1750-fill");
  const unit = UNITS[pre!.MVS];
  expect(unit).toBeTruthy();
  const viewport = page.viewportSize()!;
  await page.mouse.click(viewport.width / 2, viewport.height / 2);
  const sheet = page.locator("#sheet");
  await expect(sheet).toBeVisible();
  await expect(sheet).toContainText(unit.name.slice(0, 20));
  await expect(sheet).toContainText(unit.group.slice(0, 20));
  const swatchColor = await sheet
    .locator(".swatch")
    .evaluate((el) => getComputedStyle(el).backgroundColor);
  const [r, g, b] = [1, 3, 5].map((i) => parseInt(unit.color.slice(i, i + 2), 16));
  expect(swatchColor.replace(/\s/g, "")).toBe(`rgb(${r},${g},${b})`);
});

test("pre-1750 legend groups by NVIS Major Vegetation Group", async ({ page }) => {
  const UNITS = JSON.parse(
    readFileSync(join(HERE, "../src/generated/pre1750_units.json"), "utf8"),
  ) as Record<string, { group: string }>;
  const groups = new Set(Object.values(UNITS).map((u) => u.group));
  await chooseLayer(page, "overlay", "pre");
  await closePanel(page); // the sheet's scrim covers the toolbar
  await page.locator("#btn-legend").click();
  const panel = page.locator("#panel");
  await expect(panel).toContainText("Pre-1750 legend");
  await expect(panel.locator(".leg-row")).toHaveCount(Object.keys(UNITS).length);
  await expect(panel.locator("h3.leg-h")).toHaveCount(groups.size);
  // hand-curated chips must track the generated groups EXACTLY (both
  // directions): a renamed/added group silently falls back to truncation
  // (long names) or a raw name (short ones), and dead keys hide the drift
  expect(Object.keys(PRE_CHIPS).sort()).toEqual([...groups].sort());
  // no outline layer for pre-1750 -> no "Outlines" strength option
  await expect(panel.locator('.leg-op[data-op="outline"]')).toHaveCount(0);
});

test("geology tap shows unit details with official colour", async ({ page }) => {
  const UNITS = JSON.parse(
    readFileSync(join(HERE, "../src/generated/geology_units.json"), "utf8"),
  ) as Record<string, { description: string; color: string }>;
  await chooseLayer(page, "overlay", "geo");
  await closePanel(page);
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

test("legend follows the active overlay and sets the strength", async ({ page }) => {
  await chooseLayer(page, "overlay", "geo");
  await closePanel(page);
  await page.locator("#btn-legend").click();
  const panel = page.locator("#panel");
  await expect(panel).toContainText("Geology legend");
  await expect(panel.locator("h3.leg-h")).toHaveCount(12);
  const opacity = () =>
    page.evaluate(
      () => (window as never as { __map: import("maplibre-gl").Map }).__map.getPaintProperty("geology-fill", "fill-opacity"),
    );
  await panel.locator('.leg-op[data-op="light"]').click();
  expect(await opacity()).toBe(0.25);
  // Outlines only: no fill, the outline layer stays on
  await panel.locator('.leg-op[data-op="outline"]').click();
  expect(await opacity()).toBe(0);
  expect(await vis(page, "geology-outline")).toBe("visible");
  // the Layers sheet shows the same choice
  await closePanel(page);
  await page.locator("#btn-layers").click();
  await expect(page.locator('#lay-strength .leg-op[data-op="outline"]')).toHaveClass(/\bon\b/);
});

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
});

test("base map choice paints aerial photos, Tasmap scans, topo — and survives a reload", async ({ page }) => {
  await page.goto("/?pixels=1");
  await waitForMapIdle(page);
  await chooseLayer(page, "overlay", "off"); // overlays would tint the readback
  // zoom 14 renders the z15 PACK tiles (zoom 15 would ask for live z16)
  await jumpToTile(page, CENTRE_TILE.z, CENTRE_TILE.x, CENTRE_TILE.y);
  await chooseLayer(page, "base", "aerial");
  await waitForTiles(page);
  expect(await vis(page, "aerial")).toBe("visible");
  // not downloaded -> the topo map stays underneath (offline it is the map,
  // not a flat ocean colour); a local archive would hide it
  expect(await vis(page, "topo")).toBe("visible");
  const red = await pixelAt(page);
  expect(near(red, COLOURS.red), `aerial pixel ${red}`).toBe(true);
  // attribution follows what is on screen
  await expect(page.locator(".maplibregl-ctrl-attrib")).toContainText("CC BY-NC-ND");
  await chooseLayer(page, "base", "tasmap");
  await waitForTiles(page);
  const cream = await pixelAt(page);
  expect(near(cream, COLOURS.cream), `tasmap pixel ${cream}`).toBe(true);
  await chooseLayer(page, "base", "topo");
  await waitForTiles(page);
  const bg = await pixelAt(page);
  expect(near(bg, COLOURS.topoBg), `topo (blocked -> background) pixel ${bg}`).toBe(true);
  await expect(page.locator(".maplibregl-ctrl-attrib")).not.toContainText("CC BY-NC-ND");
  // persistence
  await chooseLayer(page, "base", "aerial");
  await page.reload();
  await waitForMapIdle(page);
  expect(await vis(page, "aerial")).toBe("visible");
  // online above the packs: the live service's high-zoom tiles (green)
  await jumpToTile(page, CENTRE_TILE.z, CENTRE_TILE.x, CENTRE_TILE.y, 16);
  await waitForTiles(page);
  expect(near(await pixelAt(page), COLOURS.green), "live z17 online").toBe(true);
  await page.locator("#btn-layers").click();
  await expect(page.locator('.lay-row[data-base="aerial"]')).toHaveClass(/\bon\b/);
});

test("season stack: newest season on top, older shows through gaps, slider cutoff", async ({ page }) => {
  await page.goto("/?pixels=1");
  await waitForMapIdle(page);
  await jumpToTile(page, CENTRE_TILE.z, CENTRE_TILE.x, CENTRE_TILE.y);
  await chooseLayer(page, "overlay", "off");
  await chooseLayer(page, "base", "seasons");
  await waitForTiles(page);
  // slider defaults to the newest season; 2023-24 (blue) covers the NE
  // quarter with a half-transparent edge tile at the centre, 2022-23
  // (green) covers the west half — topo (background) elsewhere
  expect(await vis(page, "aerial2024")).toBe("visible");
  expect(await vis(page, "topo")).toBe("visible");
  const east = await pixelAt(page, 40, 0);
  const west = await pixelAt(page, -40, 0);
  expect(near(east, COLOURS.blue), `east ${east}`).toBe(true);
  expect(near(west, COLOURS.green), `west (through transparent half) ${west}`).toBe(true);
  // nothing is downloaded: the caption must not claim a season it only
  // streams (probing remote archives would re-download tiles), it says so
  await expect(page.locator("#lay-caption")).toContainText("up to 2025–26");
  await expect(page.locator("#lay-caption")).toContainText("not on this device");
  // cutoff at 2022-23: the blue season disappears, green everywhere it exists
  await setRange(page, 3);
  await waitForTiles(page);
  expect(await vis(page, "aerial2024")).toBe("none");
  expect(await vis(page, "aerial2023")).toBe("visible");
  expect(near(await pixelAt(page, 40, 0), COLOURS.green)).toBe(true);
  expect(near(await pixelAt(page, -40, 0), COLOURS.green)).toBe(true);
  await expect(page.locator("#lay-cutoff")).toHaveText("2022–23");
  await expect(page.locator("#lay-caption")).toContainText("up to 2022–23");
  // cutoff before any fixture season: topo shows
  await setRange(page, 2);
  await waitForTiles(page);
  expect(near(await pixelAt(page, 40, 0), COLOURS.topoBg)).toBe(true);
  await expect(page.locator("#lay-caption")).toContainText("up to 2021–22");
  // ticks mark seasons that are not downloaded
  await expect(page.locator(".lay-tick.missing")).toHaveCount(7);
});

test("a local statewide archive answers in-bounds gaps itself; only out-of-bounds tiles go live", async ({ page, browserName }) => {
  test.skip(browserName === "webkit", "Playwright WebKit build lacks OPFS createWritable");
  // Install the NE-quarter fixture AS the statewide aerial pack: its header
  // bounds cover the whole fixture bbox, but it holds tiles only in the NE
  // quarter — so in-bounds misses (pruned ocean in the real pack) must come
  // back blank with NO request to the LIST service, while a tile outside
  // its bounds may still be fetched live (the fixture's Orthophoto route).
  await seedOpfs(page, "aerial_tas.pmtiles", SEASON_2024_FIXTURE);
  let liveHits = 0;
  page.on("request", (r) => {
    if (r.url().includes("/Orthophoto/")) liveHits++;
  });
  await page.goto("/?pixels=1");
  await waitForMapIdle(page);
  // the fly-in leaves the map at zoom 15 (= z16 requests); look at z15 tiles
  await jumpToTile(page, CENTRE_TILE.z, CENTRE_TILE.x + 2, CENTRE_TILE.y - 2);
  await chooseLayer(page, "overlay", "off");
  await chooseLayer(page, "base", "aerial");
  await expect(page.locator('.lay-row[data-base="aerial"] .lay-status')).toContainText("offline");
  expect(await vis(page, "topo")).toBe("none"); // local archive: no underlay
  // NE of the centre: the local archive has it (blue) — no live request
  await waitForTiles(page);
  expect(near(await pixelAt(page), COLOURS.blue)).toBe(true);
  // SW of the centre: inside the archive's bounds, no tile -> blank -> the
  // aerial background (ocean colour), still no live request
  await jumpToTile(page, CENTRE_TILE.z, CENTRE_TILE.x - 3, CENTRE_TILE.y + 3);
  await waitForTiles(page);
  expect(near(await pixelAt(page), [0x1e, 0x52, 0x5f])).toBe(true);
  expect(liveHits).toBe(0);
  // well east of the fixture bbox (147.32°E is x≈29793 at z15): outside the
  // archive's bounds, so the live service is consulted — and answers red
  await jumpToTile(page, CENTRE_TILE.z, CENTRE_TILE.x + 40, CENTRE_TILE.y);
  await waitForTiles(page);
  expect(liveHits).toBeGreaterThan(0);
});

test("seasons never consult the live service; a local season serves its tiles", async ({ page, browserName }) => {
  test.skip(browserName === "webkit", "Playwright WebKit build lacks OPFS createWritable");
  await seedOpfs(page, "aerial_2024.pmtiles", SEASON_2024_FIXTURE);
  let remoteHits = 0;
  let listHits = 0;
  page.on("request", (r) => {
    if (r.url().includes("aerial_2024.pmtiles")) remoteHits++;
    if (r.url().includes("AerialPhoto")) listHits++;
  });
  await page.goto("/?pixels=1");
  await waitForMapIdle(page);
  await jumpToTile(page, CENTRE_TILE.z, CENTRE_TILE.x + 2, CENTRE_TILE.y - 2);
  await chooseLayer(page, "overlay", "off");
  await chooseLayer(page, "base", "seasons");
  await waitForTiles(page);
  expect(near(await pixelAt(page), COLOURS.blue)).toBe(true); // from OPFS
  // the caption names a season only when a LOCAL archive has the tile
  await expect(page.locator("#lay-caption")).toContainText("Showing 2023–24 photos here");
  await jumpToTile(page, CENTRE_TILE.z, CENTRE_TILE.x - 3, CENTRE_TILE.y + 3);
  await waitForTiles(page);
  expect(near(await pixelAt(page), COLOURS.green)).toBe(true); // 2022-23 from "R2"
  await expect(page.locator("#lay-caption")).toContainText("not on this device");
  expect(remoteHits).toBe(0); // the local 2023-24 archive was never fetched remotely
  expect(listHits).toBe(0); // no season ever hits the LIST tile service
  await expect(page.locator('.lay-row[data-base="seasons"] .lay-status')).toContainText("1 of 7 seasons offline");
  await expect(page.locator(".lay-tick.missing")).toHaveCount(6);
});

test("above z15: live tiles online, downloaded area offline, stretched z15 parent elsewhere", async ({ page, browserName }) => {
  test.skip(browserName === "webkit", "Playwright WebKit build lacks OPFS createWritable");
  // the statewide aerial pack (red, z12-15) is installed
  await seedOpfs(page, "aerial_tas.pmtiles", AERIAL_FIXTURE);
  await page.goto("/?pixels=1");
  await waitForMapIdle(page);
  await chooseLayer(page, "overlay", "off");
  await chooseLayer(page, "base", "aerial");
  await closePanel(page);
  // online at z17 the map now shows the live high-zoom tiles (green)
  await jumpToTile(page, 17, CENTRE_TILE.x * 4 + 1, CENTRE_TILE.y * 4 + 1);
  await waitForTiles(page);
  expect(near(await pixelAt(page), COLOURS.green), "live z17").toBe(true);

  // frame this view as a detailed area and download the aerial layer
  await page.locator("#btn-downloads").click();
  await page.locator("#area-new").click();
  await expect(page.locator("#areabar")).toBeVisible();
  await page.locator("#areabar-next").click();
  await expect(page.locator("#area-form")).toBeVisible();
  await expect(page.locator("#area-est")).toContainText("about");
  await page.locator('input[name="zmax"][value="17"]').check();
  await page.locator("#area-name").fill("Test patch");
  await page.locator(".area-go").click();
  await expect(page.locator(".area-cancel")).toHaveText("Done", { timeout: 60_000 });
  await expect(page.locator('[data-key="aerial"] .dl-status')).toHaveText("✓ done");
  await page.locator(".area-cancel").click();
  await expect(page.locator(".area-row")).toContainText("Test patch");
  await expect(page.locator(".area-row .dl-status")).toContainText("✓ downloaded");
  await closePanel(page);

  // lose reception: the area still renders its own z17 tiles from OPFS ...
  await blockLiveServices(page);
  await page.reload();
  await waitForMapIdle(page);
  await jumpToTile(page, 17, CENTRE_TILE.x * 4 + 1, CENTRE_TILE.y * 4 + 1);
  await waitForTiles(page);
  expect(near(await pixelAt(page), COLOURS.green), "area z17 offline").toBe(true);
  // ... and outside the area MapLibre falls back to the stretched z15 pack
  // tile (red) instead of a hole (the protocol's miss is a 404, which is
  // what makes MapLibre request the parent without a camera move)
  await jumpToTile(page, 17, (CENTRE_TILE.x + 6) * 4, CENTRE_TILE.y * 4);
  await expect.poll(async () => near(await pixelAt(page), COLOURS.red), { timeout: 10_000 }).toBe(true);

  // delete the area: back to the stretched parent inside it too
  await page.locator("#btn-downloads").click();
  await page.locator(".area-row .area-delete").click();
  await expect(page.locator("#area-list")).toContainText("No detailed areas");
  await closePanel(page);
  await jumpToTile(page, 17, CENTRE_TILE.x * 4 + 1, CENTRE_TILE.y * 4 + 1);
  await expect.poll(async () => near(await pixelAt(page), COLOURS.red), { timeout: 10_000 }).toBe(true);
});

test("downloads panel offers Update for a rebuilt archive and shows its note", async ({ page, browserName }) => {
  test.skip(browserName === "webkit", "Playwright WebKit build lacks OPFS createWritable");
  // The server now holds a rebuilt 2023-24 archive (stand-in: the 2022-23
  // fixture, a different size) while the device has the old one installed.
  await page.route("**/dev-data/data-manifest.json", (route) =>
    route.fulfill({
      json: {
        version: "2026-09-12",
        archives: {
          tasveg: { file: "tasveg.pmtiles", bytes: 3_460_947 },
          aerial2024: {
            file: "aerial_2024.pmtiles",
            bytes: SEASON_2023_FIXTURE.length,
            built: "2026-09-12",
            note: "Season still being flown",
          },
        },
      },
    }),
  );
  await page.route("**/dev-data/aerial_2024.pmtiles", async (route) => {
    const range = /bytes=(\d+)-(\d*)/.exec(route.request().headers()["range"] ?? "");
    const buf = SEASON_2023_FIXTURE;
    const start = range ? Number(range[1]) : 0;
    const end = range && range[2] ? Math.min(Number(range[2]), buf.length - 1) : buf.length - 1;
    await route.fulfill({
      status: 206,
      headers: { "Content-Range": `bytes ${start}-${end}/${buf.length}`, "Accept-Ranges": "bytes" },
      body: buf.subarray(start, end + 1),
    });
  });
  await seedOpfs(page, "aerial_2024.pmtiles", SEASON_2024_FIXTURE);
  await page.reload();
  await waitForMapIdle(page);
  await page.locator("#btn-downloads").click();
  const row = page.locator('.dl-item[data-key="aerial2024"]');
  await expect(row.locator(".dl-btn:not(.dl-secondary)")).toHaveText("Update");
  await expect(row.locator(".dl-secondary")).toHaveText("Delete"); // outdated stays deletable
  await expect(row).toContainText("Season still being flown");
  await expect(row).toContainText("newer version available");
  await expect(page.locator("#dl-list .dl-h .dl-all")).toHaveCount(1);
  await expect(page.locator("#dl-list .dl-h .dl-all")).toBeEnabled(); // 2023-24 is downloadable
  // packs the manifest doesn't list yet are not offered
  await expect(page.locator('.dl-item[data-key="tasmap"] .dl-btn')).toBeDisabled();
  // Update = replace in place: the new archive is fetched from "R2" and
  // swapped in; the row settles as a plain installed archive
  await row.locator(".dl-btn:not(.dl-secondary)").click();
  await expect(row.locator(".dl-btn:not(.dl-secondary)")).toHaveText("Delete", { timeout: 20_000 });
  await expect(row).toContainText("✓ downloaded");
  await expect(row).not.toContainText("newer version");
  const installed = await page.evaluate(async () => {
    const root = await navigator.storage.getDirectory();
    return (await (await root.getFileHandle("aerial_2024.pmtiles")).getFile()).size;
  });
  expect(installed).toBe(SEASON_2023_FIXTURE.length);
  // reopening must not offer the same update again
  await closePanel(page);
  await page.locator("#btn-downloads").click();
  await expect(page.locator('.dl-item[data-key="aerial2024"] .dl-btn:not(.dl-secondary)')).toHaveText("Delete");
  await expect(page.locator("#dl-list .dl-h .dl-all")).toBeDisabled(); // nothing left to fetch
});

test("a failed GPS fix is announced instead of silently spinning", async ({ page }) => {
  await page.addInitScript(() => {
    const fail = (_ok: unknown, err?: (e: { code: number; message: string }) => void) => {
      setTimeout(() => err?.({ code: 2, message: "Position unavailable" }), 50);
      return 1;
    };
    Object.defineProperty(navigator, "geolocation", {
      value: { getCurrentPosition: fail, watchPosition: fail, clearWatch: () => {} },
    });
  });
  await page.reload();
  await waitForMapIdle(page);
  await expect(page.locator("#mode-pill")).toContainText("No location fix", { timeout: 15_000 });
  await expect(page.locator("#mode-pill")).toContainText("Wi-Fi-only iPads");
});

test("wide viewports get side cards; Escape dismisses sheets", async ({ page }) => {
  const wide = page.viewportSize()!.width >= 700;
  await page.locator("#btn-legend").click();
  const panel = page.locator(".panel-inner");
  const box = (await panel.boundingBox())!;
  if (wide) {
    expect(box.width).toBeGreaterThanOrEqual(390);
    expect(box.width).toBeLessThanOrEqual(410);
    expect(box.x).toBeGreaterThanOrEqual(60); // beside the toolbar, not over it
    expect(box.y).toBeLessThan(40); // top-anchored card
  } else {
    expect(box.width).toBe(page.viewportSize()!.width); // full-width bottom sheet
  }
  await page.keyboard.press("Escape");
  await expect(page.locator("#panel")).toBeHidden();
  const viewport = page.viewportSize()!;
  await page.mouse.click(viewport.width / 2, viewport.height / 2);
  const sheet = page.locator("#sheet");
  await expect(sheet).toBeVisible();
  const sb = (await sheet.boundingBox())!;
  if (wide) {
    expect(sb.width).toBeLessThanOrEqual(410);
    expect(sb.x).toBeGreaterThanOrEqual(60);
    expect(sb.y + sb.height).toBeGreaterThan(viewport.height - 80); // bottom-left card
  }
  await page.keyboard.press("Escape");
  await expect(sheet).toBeHidden();
  await page.locator("#btn-layers").click();
  await expect(page.locator(".lay-row")).toHaveCount(8);
  if (wide) {
    // no scrim on wide viewports: the toolbar stays live beside the card,
    // so the legend button swaps the card instead of closing it
    await page.locator("#btn-legend").click();
    await expect(page.locator("#panel")).toContainText("legend");
  } else {
    // phones keep the scrim: a tap outside the sheet dismisses it
    await page.mouse.click(viewport.width / 2, 40);
    await expect(page.locator("#panel")).toBeHidden();
    await page.locator("#btn-layers").click();
  }
  await page.keyboard.press("Escape");
  await expect(page.locator("#panel")).toBeHidden();
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
  // hardware keyboard: Escape closes the viewer
  await page.keyboard.press("Escape");
  await expect(page.locator("#pdfview")).toBeHidden();
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
});
