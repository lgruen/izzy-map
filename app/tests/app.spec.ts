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
  await expect(page.locator(".lay-row")).toHaveCount(9); // 4 bases + 4 overlays + trees
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

// ---------- search (search.ts; the real committed indexes served by the dev server) ----------

const jumpTo = (page: Page, lng: number, lat: number, zoom = 13) =>
  page.evaluate(([lng, lat, zoom]) => {
    (window as never as { __map: import("maplibre-gl").Map }).__map.jumpTo({ center: [lng, lat], zoom });
  }, [lng, lat, zoom] as const);
/** Camera after a fly/fit settles: [lng, lat, zoom]. */
const settledCamera = async (page: Page): Promise<[number, number, number]> => {
  await page.waitForFunction(
    () => !(window as never as { __map: import("maplibre-gl").Map }).__map.isMoving(),
    undefined,
    { timeout: 10_000 },
  );
  return page.evaluate(() => {
    const m = (window as never as { __map: import("maplibre-gl").Map }).__map;
    return [m.getCenter().lng, m.getCenter().lat, m.getZoom()] as [number, number, number];
  });
};
/** Open the search sheet (input focused) and type a query. */
const openSearch = async (page: Page, q: string) => {
  await page.locator("#btn-search").click();
  await expect(page.locator("#sr-input")).toBeFocused();
  await page.locator("#sr-input").fill(q);
};
const firstRow = (page: Page) => page.locator(".sr-row").first();

test("search: kunanyi flies to the mountain with a pin and a dismissible pill", async ({ page }) => {
  await openSearch(page, "kunanyi");
  await expect(firstRow(page)).toContainText(/Wellington/, { timeout: 20_000 });
  await page.keyboard.press("Enter");
  await expect(page.locator("#panel")).toBeHidden();
  const [lng, lat] = await settledCamera(page);
  expect(Math.abs(lng - 147.237), `lng ${lng}`).toBeLessThan(0.03);
  expect(Math.abs(lat + 42.896), `lat ${lat}`).toBeLessThan(0.03);
  // the geolocate control owns two markers of its own (dot + accuracy
  // circle), so count the search pin by its class
  await expect(page.locator(".maplibregl-marker.search-pin")).toHaveCount(1);
  await expect(page.locator("#search-pill")).toBeVisible();
  await expect(page.locator("#search-pill-name")).toContainText("Wellington");
  await page.locator("#search-pill-x").click();
  await expect(page.locator("#search-pill")).toBeHidden();
  await expect(page.locator(".maplibregl-marker.search-pin")).toHaveCount(0);
});

test("search: abbreviations and context words", async ({ page }) => {
  await openSearch(page, "eliz st hob");
  await expect(firstRow(page).locator("b")).toHaveText("Elizabeth Street", { timeout: 20_000 });
  await expect(firstRow(page).locator("small")).toContainText("Hobart");
  await page.locator("#sr-input").fill("mt wellington");
  await expect(firstRow(page).locator("b")).toContainText(/Mount Wellington/);
  await page.locator("#sr-input").fill("sandy bay rd");
  await expect(firstRow(page).locator("b")).toHaveText("Sandy Bay Road");
  // the register lists Elizabeth Street under Hobart only; the suburb comes
  // from the address file's per-suburb street rows
  await page.locator("#sr-input").fill("elizabeth st north hobart");
  await expect(firstRow(page).locator("b")).toHaveText("Elizabeth Street");
  await expect(firstRow(page).locator("small")).toContainText("North Hobart");
  await page.locator("#sr-input").fill("7 mile beach"); // a number word, not a house number
  await expect(firstRow(page).locator("b")).toHaveText("Seven Mile Beach");
  await page.locator("#sr-input").fill("salamanca"); // the square, not a farm of that name
  await expect(firstRow(page).locator("b")).toHaveText("Salamanca Square");
});

test("search: equal names rank by distance from the map centre", async ({ page }) => {
  await jumpTo(page, 147.14, -41.44); // Launceston
  await openSearch(page, "elizabeth street");
  await expect(firstRow(page).locator("b")).toHaveText("Elizabeth Street", { timeout: 20_000 });
  await expect(firstRow(page).locator("small")).toContainText("Launceston");
  await closePanel(page);
  await jumpTo(page, 147.33, -42.88); // Hobart
  await openSearch(page, "elizabeth street");
  await expect(firstRow(page).locator("b")).toHaveText("Elizabeth Street");
  await expect(firstRow(page).locator("small")).toContainText("Hobart");
  await expect(firstRow(page).locator("small")).not.toContainText("Launceston");
});

test("search: a house number resolves to an address; property names resolve", async ({ page }) => {
  await openSearch(page, "12 elizabeth st hobart");
  await expect(firstRow(page).locator("b")).toHaveText(/^12 Elizabeth Street/, { timeout: 20_000 });
  await expect(firstRow(page).locator("small")).toContainText(/^Address · /);
  await page.keyboard.press("Enter");
  await expect(page.locator("#panel")).toBeHidden();
  const [lng, lat, zoom] = await settledCamera(page);
  expect(zoom).toBeGreaterThanOrEqual(17);
  expect(Math.abs(lng - 147.33), `lng ${lng}`).toBeLessThan(0.01);
  expect(Math.abs(lat + 42.88), `lat ${lat}`).toBeLessThan(0.01);
  await expect(page.locator("#search-pill-name")).toHaveText(/^12 Elizabeth Street/);
  await openSearch(page, "henry jones");
  await expect(page.locator(".sr-row small", { hasText: /^Property/ }).first()).toBeVisible();
  await expect(firstRow(page).locator("b")).toContainText(/Henry Jones/i);
});

test("search: works with every network path but the app shell cut", async ({ page }) => {
  // the dev server stands in for the service-worker precache (same pattern
  // as the OPFS offline test): nothing else may be reachable
  await page.route("**", (route) =>
    route.request().url().startsWith("http://localhost:5200") ? route.continue() : route.abort(),
  );
  await openSearch(page, "hobart");
  await expect(firstRow(page)).toBeVisible({ timeout: 20_000 });
  await expect(firstRow(page).locator("b")).toContainText(/Hobart/);
});

test("search: a failed index fetch is reported, then retried on the next keystroke", async ({ page }) => {
  // cut BEFORE the page loads, so no idle prefetch can have warmed the
  // indexes: the first search must say so, and the load promise must reset
  // so that the next keystroke, network back, succeeds
  await page.route("**/search/*.json", (route) => route.abort());
  await page.goto("/");
  await waitForMapIdle(page);
  await openSearch(page, "hobart");
  await expect(page.locator("#sr-list")).toContainText("Place names aren’t available", { timeout: 20_000 });
  await page.unroute("**/search/*.json");
  await page.locator("#sr-input").fill("hobart rivulet");
  await expect(firstRow(page).locator("b")).toContainText("Hobart Rivulet", { timeout: 20_000 });
});

test("search: keyboard navigation, Escape chain, wide-viewport card", async ({ page }) => {
  const wide = page.viewportSize()!.width >= 700;
  await openSearch(page, "sandy bay");
  const rows = page.locator(".sr-row");
  await expect(rows.nth(2)).toBeVisible({ timeout: 20_000 });
  await expect(rows.first()).toHaveClass(/\bon\b/); // Enter alone picks the first
  const third = (await rows.nth(2).locator("b").textContent())!;
  await page.keyboard.press("ArrowDown");
  await page.keyboard.press("ArrowDown");
  await expect(rows.nth(2)).toHaveClass(/\bon\b/);
  await expect(page.locator("#sr-input")).toHaveAttribute("aria-activedescendant", "sr-opt-2");
  await page.keyboard.press("Enter");
  await expect(page.locator("#panel")).toBeHidden();
  await expect(page.locator("#search-pill-name")).toHaveText(third);
  // reopening restores the query and its hits; Escape with the input
  // focused closes the sheet, a second Escape clears the pin
  await page.locator("#btn-search").click();
  await expect(page.locator("#sr-input")).toBeFocused();
  await expect(page.locator("#sr-input")).toHaveValue("sandy bay");
  await expect(rows.nth(2)).toBeVisible();
  const inner = (await page.locator(".panel-inner").boundingBox())!;
  if (wide) {
    expect(inner.width).toBeGreaterThanOrEqual(390);
    expect(inner.width).toBeLessThanOrEqual(410);
    expect(inner.x).toBeGreaterThanOrEqual(60);
    // no scrim: the toolbar stays live beside the card
    await page.locator("#btn-layers").click();
    await expect(page.locator("#panel")).toContainText("Map layers");
    await page.keyboard.press("Escape");
    await expect(page.locator("#panel")).toBeHidden();
    await page.locator("#btn-search").click();
    await expect(page.locator("#sr-input")).toBeFocused();
  } else {
    expect(inner.width).toBe(page.viewportSize()!.width);
    expect(inner.y).toBeLessThan(40); // top-anchored takeover
  }
  await page.keyboard.press("Escape");
  await expect(page.locator("#panel")).toBeHidden();
  await expect(page.locator("#search-pill")).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(page.locator("#search-pill")).toBeHidden();
  await expect(page.locator(".maplibregl-marker.search-pin")).toHaveCount(0);
});

test("search: normalisation, abbreviations, minimum length, road demotion, address decode", async ({ page }) => {
  const r = await page.evaluate(async () => {
    const m = (await import("/src/search.ts")) as typeof import("../src/search");
    const idx = m.buildIndex({
      version: 1, built: "", attribution: "",
      types: ["Road", "Mountain", "Suburb/Locality", "Property", "Square", "Pier", "Beach"],
      groups: ["Transport", "Natural Feature", "Cultural", "Property"],
      typeGroup: [0, 1, 2, 3, 2, 0, 1],
      places: ["", "North Hobart", "Wellington Park", "Longford", "Battery Point", "Hobart"],
      munis: ["", "Hobart", "Glenorchy, Hobart, Kingborough"],
      rows: [
        ["Sandy Bay Road", 0, 0, 1, -4290000, 14733000, [-100, -900, 100, 900]],
        ["Sandy Bay", 2, 0, 1, -4290500, 14732000],
        ["Mount Direction", 1, 0, 0, -4280000, 14730000],
        ["Elizabeth Street", 0, 1, 1, -4287000, 14731500],
        ["Elizabeth Street Pier", 5, 5, 1, -4288200, 14733500],
        ["Elizabeth Street Pier", 3, 5, 1, -4288200, 14733500], // the register's Property twin
        ["Kunanyi / Mount Wellington", 1, 2, 2, -4290464, 14722438],
        ["O'Briens Road", 0, 0, 0, -4300000, 14720000],
        ["Seven Mile Beach", 6, 0, 0, -4286000, 14750000],
        ["Salamanca", 3, 3, 0, -4160000, 14710000],
        ["Salamanca Square", 4, 4, 1, -4288800, 14733000],
        ["Henry Jones IXL Complex", 3, 5, 1, -4288000, 14733200],
      ],
    });
    const addr = m.buildAddrIndex({
      version: 1, built: "", attribution: "",
      streets: [
        ["Sandy Bay Road", "Sandy Bay", 14733000, -4290000, [1, 3, "5A", 7], [0, 10, 10, 10], [0, -5, -5, -5]],
        ["Elizabeth Street", "North Hobart", 14731500, -4287000, [2, 4], [0, 10], [0, 10]], // = the register row
        ["Elizabeth Street", "New Town", 14731000, -4285000, [300, 302, 304], [0, 10, 10], [0, 10, 10]],
        ["Seven Mile Beach Road", "Seven Mile Beach", 14750000, -4286000, [7, 9], [0, 10], [0, 10]],
      ],
    });
    const names = (q: string) => m.search(idx, addr, q).map((h) => h.name);
    return {
      norm: m.normalise("Saint-Mary’s Créek"),
      rd: names("sandy bay rd"),
      one: names("s").length,
      two: names("sa"),
      demote: names("sandy bay"),
      mt: names("mt direction"),
      ctx: names("eliz hob"),
      streetWord: names("eliz st hob"),
      pierTwin: m.search(idx, addr, "eliz st hob").filter((h) => h.name === "Elizabeth Street Pier").map((h) => h.type),
      apostrophe: [names("obriens rd")[0], names("o'briens")[0]],
      numberWord: names("7 mile beach"),
      unit: m.search(idx, addr, "1/3 sandy bay rd")[0],
      range: names("3-5 sandy bay rd")[0],
      unitSpace: names("1 3 sandy bay rd")[0],
      suburb: m.search(idx, addr, "elizabeth st new town"),
      dedupe: m.search(idx, addr, "elizabeth st north hobart"),
      plain: names("elizabeth street"),
      property: names("salamanca"),
      propertyOnly: names("henry jones"),
      multi: m.search(idx, addr, "kunanyi hob")[0],
      exact: m.search(idx, addr, "3 sandy bay rd")[0],
      nearest: m.search(idx, addr, "5 sandy bay rd")[0],
      km: m.search(idx, null, "sandy bay", { lng: 147.325, lat: -42.905 })[0].km,
    };
  });
  expect(r.norm).toBe("saint marys creek"); // apostrophes vanish, other punctuation splits
  expect(r.rd[0]).toBe("Sandy Bay Road");
  expect(r.one).toBe(0); // two-letter minimum
  expect(r.two).toContain("Sandy Bay");
  expect(r.demote[0]).toBe("Sandy Bay"); // the suburb outranks its road…
  expect(r.demote).toContain("Sandy Bay Road"); // …which still lists
  expect(r.mt[0]).toBe("Mount Direction");
  expect(r.ctx).toContain("Elizabeth Street"); // "hob" via the locality/council
  expect(r.streetWord[0]).toBe("Elizabeth Street"); // a street word: the road beats the pier
  expect(r.streetWord).toContain("Elizabeth Street Pier");
  expect(r.pierTwin).toEqual(["Pier"]); // a Property twinning a register row (same name + place) is dropped
  expect(r.apostrophe).toEqual(["O'Briens Road", "O'Briens Road"]);
  expect(r.numberWord[0]).toBe("Seven Mile Beach"); // "7" spelt out beats the address
  expect(r.numberWord).toContain("7 Seven Mile Beach Road");
  expect(r.unit.name).toBe("3 Sandy Bay Road"); // unit 1, number 3
  expect(r.unit.meta).toBe("Address · Sandy Bay");
  expect(r.range).toBe("3 Sandy Bay Road"); // a range keeps its first number
  expect(r.unitSpace).toBe("3 Sandy Bay Road");
  // a suburb the register does not list comes from the address file: one
  // Road row, pinned at the middle number, framed by all of them
  expect(r.suburb.map((h) => [h.name, h.type, h.meta])).toEqual([["Elizabeth Street", "Road", "Road · New Town"]]);
  expect(r.suburb[0].lon).toBeCloseTo(147.3101, 5);
  expect(r.suburb[0].lat).toBeCloseTo(-42.8499, 5);
  expect(r.suburb[0].bbox).toEqual([147.31, -42.85, 147.3102, -42.8498]);
  // …but a (name, place) the register has is shown once, from the register
  expect(r.dedupe.map((h) => h.meta)).toEqual(["Road · North Hobart, Hobart"]);
  // and without a suburb word the address file adds no duplicate rows
  expect(r.plain.filter((n) => n === "Elizabeth Street")).toHaveLength(1);
  expect(r.property[0]).toBe("Salamanca Square"); // the property "Salamanca" trails official names…
  expect(r.property).toContain("Salamanca");
  expect(r.propertyOnly).toEqual(["Henry Jones IXL Complex"]); // …but still answers alone
  // a multi-council MUNY matches as context in full but displays its first council only
  expect(r.multi.name).toBe("Kunanyi / Mount Wellington");
  expect(r.multi.meta).toBe("Mountain · Wellington Park, Glenorchy");
  expect(r.exact.name).toBe("3 Sandy Bay Road");
  expect(r.exact.meta).toBe("Address · Sandy Bay");
  expect(r.exact.lon).toBeCloseTo(147.3301, 5); // lon0 + 0 + 10 (1e-5°)
  expect(r.exact.lat).toBeCloseTo(-42.90005, 5);
  expect(r.nearest.name).toBe("5 Sandy Bay Road");
  expect(r.nearest.meta).toBe("Address · Sandy Bay · nearest: 5A");
  expect(r.km).toBeGreaterThan(0);
  expect(r.km).toBeLessThan(1);
});

// ---------- Hobart significant trees (bundled trees.json is the fixture) ----------

type TreeFeature = {
  geometry: { type: string; coordinates: [number, number] };
  properties: { ref: string; sheet: string; acc: string };
};
const TREES = JSON.parse(readFileSync(join(HERE, "../src/generated/trees.json"), "utf8")) as {
  points: { features: TreeFeature[] };
  areas: { features: { geometry: { type: string }; properties: { ref: string; sheet: string; acc: string } }[] };
  refs: Record<string, { name: string; label: string; common: string; address: string; sheets: string[] }>;
  accuracy: Record<string, string>;
  sheets: Record<string, { bytes: number; title: string }>;
};
const TREE_LAYER_IDS = ["trees-area-fill", "trees-area-outline", "trees-cluster", "trees-cluster-count", "trees-point", "trees-label"];
const SHEET_ROUTE = "**/www.arcgis.com/sharing/rest/content/items/*/data";
// Derived from the data, formatted as ui.ts's fmtMB does, so a regenerated
// trees.json (a new season of listings) cannot break the wording tests.
const SHEET_COUNT = Object.keys(TREES.sheets).length;
const SHEETS_MB = `${Math.round(Object.values(TREES.sheets).reduce((a, s) => a + s.bytes, 0) / 1e6)} MB`;
/** The closest pair of dots with different refs 4–10 m apart: both inside
 * one 12 px tap box at z17 (~0.9 m/px), yet far enough that a click lands
 * unambiguously nearer to one of them. */
const closeTreePair = (): [TreeFeature, TreeFeature] => {
  const pts = TREES.points.features;
  const m = (a: [number, number], b: [number, number]) =>
    Math.hypot((a[0] - b[0]) * 81_500, (a[1] - b[1]) * 111_000);
  let best: [number, TreeFeature, TreeFeature] | null = null;
  for (let i = 0; i < pts.length; i++) {
    for (let j = i + 1; j < pts.length; j++) {
      if (pts[i].properties.ref === pts[j].properties.ref) continue;
      const d = m(pts[i].geometry.coordinates, pts[j].geometry.coordinates);
      if (d >= 4 && d <= 10 && (!best || d < best[0])) best = [d, pts[i], pts[j]];
    }
  }
  expect(best, "a pair of distinct trees 4–10 m apart").not.toBeNull();
  return [best![1], best![2]];
};
/** A point with no neighbour within 40 m, so the 12 px tap box at z17
 * (~11 m) cannot answer with a different tree. */
const isolatedTree = (): TreeFeature => {
  const pts = TREES.points.features;
  const m = (a: [number, number], b: [number, number]) =>
    Math.hypot((a[0] - b[0]) * 81_500, (a[1] - b[1]) * 111_000);
  return pts.find((p, i) => pts.every((q, j) => j === i || m(p.geometry.coordinates, q.geometry.coordinates) >= 40))!;
};
const enableTrees = async (page: Page) => {
  await page.locator("#btn-layers").click();
  await page.locator('.lay-row[data-toggle="trees"]').click();
  await closePanel(page);
};
/** Jump to a tree at z17 (no clusters) and tap exactly on it. */
const tapTree = async (page: Page, f: TreeFeature) => {
  const [lng, lat] = f.geometry.coordinates;
  await jumpTo(page, lng, lat, 17);
  await waitForTiles(page);
  const pt = await page.evaluate(([lng, lat]) => {
    const map = (window as never as { __map: import("maplibre-gl").Map }).__map;
    const p = map.project([lng, lat]);
    const r = map.getContainer().getBoundingClientRect();
    return { x: r.left + p.x, y: r.top + p.y };
  }, [lng, lat] as const);
  await page.mouse.click(pt.x, pt.y);
};
const routeSheets = (page: Page) =>
  page.route(SHEET_ROUTE, (route) =>
    route.fulfill({ status: 200, contentType: "application/pdf", body: Buffer.from(TINY_PDF) }),
  );
const seedSheet = (page: Page, id: string) =>
  page.evaluate(async ({ pdf, id }) => {
    const root = await navigator.storage.getDirectory();
    const dir = await root.getDirectoryHandle("trees", { create: true });
    const w = await (await dir.getFileHandle(id + ".pdf", { create: true })).createWritable();
    await w.write(new TextEncoder().encode(pdf));
    await w.close();
  }, { pdf: TINY_PDF, id });
const sheetSize = (page: Page, id: string) =>
  page.evaluate(async (id) => {
    try {
      const root = await navigator.storage.getDirectory();
      const dir = await root.getDirectoryHandle("trees");
      return (await (await dir.getFileHandle(id + ".pdf")).getFile()).size;
    } catch {
      return null;
    }
  }, id);

test("trees: data sanity and the layers stay on top of the style", async ({ page }) => {
  for (const f of [...TREES.points.features, ...TREES.areas.features]) {
    expect(TREES.refs[f.properties.ref], `ref ${f.properties.ref}`).toBeTruthy();
    expect(TREES.sheets[f.properties.sheet], `sheet ${f.properties.sheet}`).toBeTruthy();
    expect(TREES.accuracy[f.properties.acc], `accuracy ${f.properties.acc}`).toBeTruthy();
  }
  for (const [ref, r] of Object.entries(TREES.refs)) {
    expect(/^[\x00-\xff]*$/.test(r.label), `label of ${ref} is Latin-1 (glyphs are 0-255.pbf only)`).toBe(true);
    expect(r.label.length, `label of ${ref}`).toBeGreaterThan(0);
    expect(r.sheets.length, `sheets of ${ref}`).toBeGreaterThan(0);
    for (const id of r.sheets) expect(TREES.sheets[id]).toBeTruthy();
  }
  expect(Object.values(TREES.sheets).reduce((a, s) => a + s.bytes, 0)).toBeGreaterThan(300e6);
  const ids = await page.evaluate(() =>
    (window as never as { __map: import("maplibre-gl").Map }).__map.getStyle().layers.map((l) => l.id),
  );
  // both selection highlights paint ABOVE the trees (a selected tree area's
  // red ring was tinted and overpainted by trees-area-fill below them)
  expect(ids.slice(-8)).toEqual([...TREE_LAYER_IDS, "selected-outline", "selected-point"]);
  expect(ids.indexOf("tasveg-label")).toBeLessThan(ids.indexOf("trees-area-fill"));
});

test("trees: Layers toggle shows the register, persists, leaves the overlay alone", async ({ page }) => {
  for (const l of TREE_LAYER_IDS) expect(await vis(page, l)).toBe("none");
  await page.locator("#btn-layers").click();
  const row = page.locator('.lay-row[data-toggle="trees"]');
  await expect(row).toHaveAttribute("role", "checkbox");
  await expect(row).toHaveAttribute("aria-checked", "false");
  await row.click();
  await expect(row).toHaveClass(/\bon\b/);
  await expect(row).toHaveAttribute("aria-checked", "true");
  await closePanel(page);
  for (const l of ["trees-point", "trees-area-fill", "trees-cluster"]) expect(await vis(page, l)).toBe("visible");
  expect(await vis(page, "tasveg-fill")).toBe("visible"); // independent of the overlay
  await expect(page.locator(".maplibregl-ctrl-attrib")).toContainText("City of Hobart");
  await page.reload();
  await waitForMapIdle(page);
  expect(await vis(page, "trees-point")).toBe("visible");
  expect(await vis(page, "tasveg-fill")).toBe("visible");
  await page.locator("#btn-layers").click();
  await expect(row).toHaveClass(/\bon\b/);
  await row.click();
  await expect(row).not.toHaveClass(/\bon\b/);
  expect(await vis(page, "trees-point")).toBe("none");
  expect(await vis(page, "trees-label")).toBe("none");
});

test("trees: tapping a tree opens its card with the register facts and a data-sheet button", async ({ page }) => {
  await enableTrees(page);
  const f = isolatedTree();
  const meta = TREES.refs[f.properties.ref];
  await tapTree(page, f);
  const sheet = page.locator("#sheet");
  await expect(sheet).toBeVisible();
  await expect(sheet.locator(".sheet-code")).toHaveText(f.properties.ref);
  await expect(sheet.locator(".sheet-name")).toHaveText(meta.name);
  await expect(sheet).toContainText(meta.address);
  await expect(sheet).toContainText(TREES.accuracy[f.properties.acc]);
  const size = `${(TREES.sheets[f.properties.sheet].bytes / 1e6).toFixed(1)} MB`;
  await expect(sheet.locator(".sheet-desc")).toContainText(size);
  await expect(sheet.locator(".sheet-desc")).toHaveAttribute("data-sheet", f.properties.sheet);
  // nothing on the device: the button says it will fetch
  await expect(sheet.locator(".sheet-desc small")).toContainText("fetched and kept");
  const swatch = await sheet.locator(".swatch").evaluate((el) => getComputedStyle(el).backgroundColor);
  expect(swatch.replace(/\s/g, "")).toBe("rgb(22,148,13)");
  // the highlight is the tapped point (ring layer), not a polygon outline
  const sel = await page.evaluate(() => {
    const map = (window as never as { __map: import("maplibre-gl").Map }).__map;
    const src = map.getSource("selected") as import("maplibre-gl").GeoJSONSource;
    return (src.serialize() as { data: { type: string; geometry?: { type: string } } }).data;
  });
  expect(sel.type).toBe("Feature");
  expect(sel.geometry?.type).toBe("Point");
  // Escape closes; the ring goes with it
  await page.keyboard.press("Escape");
  await expect(sheet).toBeHidden();
});

test("trees: tapping a cluster zooms in instead of opening a card", async ({ page }) => {
  await enableTrees(page);
  await jumpTo(page, 147.325, -42.885, 12); // Hobart CBD: hundreds of trees -> clusters
  await waitForTiles(page);
  const pt = await page.evaluate(() => {
    const map = (window as never as { __map: import("maplibre-gl").Map }).__map;
    const clusters = map.queryRenderedFeatures({ layers: ["trees-cluster"] });
    // a cluster with no lone dot inside the tap box (dots answer first)
    for (const c of clusters) {
      const p = map.project((c.geometry as { coordinates: [number, number] }).coordinates);
      const dots = map.queryRenderedFeatures([[p.x - 14, p.y - 14], [p.x + 14, p.y + 14]], { layers: ["trees-point"] });
      if (!dots.length) {
        const r = map.getContainer().getBoundingClientRect();
        return { x: r.left + p.x, y: r.top + p.y, n: clusters.length, count: c.properties.point_count as number };
      }
    }
    return null;
  });
  expect(pt, "a tappable cluster on screen").not.toBeNull();
  expect(pt!.count).toBeGreaterThan(1);
  await page.mouse.click(pt!.x, pt!.y);
  await expect
    .poll(() => page.evaluate(() => (window as never as { __map: import("maplibre-gl").Map }).__map.getZoom()), { timeout: 10_000 })
    .toBeGreaterThan(12.5);
  await expect(page.locator("#sheet")).toBeHidden();
});

test("trees: a data sheet on the device opens offline in the in-app viewer", async ({ page, browserName }) => {
  test.skip(browserName === "webkit", "Playwright WebKit build lacks OPFS createWritable");
  const f = isolatedTree();
  await seedSheet(page, f.properties.sheet);
  await enableTrees(page);
  // no reception: nothing but the dev server (app-shell stand-in) answers
  await page.route("**", (route) =>
    route.request().url().startsWith("http://localhost:5200") ? route.continue() : route.abort(),
  );
  await tapTree(page, f);
  await expect(page.locator(".sheet-desc small")).toContainText("on this device");
  await page.locator(".sheet-desc").click();
  await expect(page.locator("#pdfview")).toBeVisible();
  await expect(page.locator(".pdf-title")).toContainText(f.properties.ref);
  await expect(page.locator(".pdf-page canvas").first()).toBeVisible({ timeout: 20_000 });
  await page.keyboard.press("Escape");
  await expect(page.locator("#pdfview")).toBeHidden();
});

test("trees: a sheet not on the device is fetched from www.arcgis.com once and kept", async ({ page, browserName }) => {
  test.skip(browserName === "webkit", "Playwright WebKit build lacks OPFS createWritable");
  await routeSheets(page);
  const hosts: string[] = [];
  page.on("request", (r) => {
    if (r.url().includes("arcgis.com")) hosts.push(new URL(r.url()).host);
  });
  const f = isolatedTree();
  await enableTrees(page);
  await tapTree(page, f);
  await expect(page.locator(".sheet-desc small")).toContainText("fetched and kept");
  await page.locator(".sheet-desc").click();
  await expect(page.locator("#pdfview")).toBeVisible();
  await expect(page.locator(".pdf-page canvas").first()).toBeVisible({ timeout: 20_000 });
  expect(await sheetSize(page, f.properties.sheet)).toBe(TINY_PDF.length);
  // only the CORS-capable host is ever asked, never the council portal
  expect(hosts.length).toBeGreaterThan(0);
  expect(hosts.every((h) => h === "www.arcgis.com"), hosts.join(",")).toBe(true);
  await page.keyboard.press("Escape");
  // the caption now knows the sheet is local
  await expect(page.locator(".sheet-desc small")).toContainText("on this device");
});

test("trees: Offline maps offers all data sheets as one optional download", async ({ page }) => {
  await page.locator("#btn-downloads").click();
  const row = page.locator('.dl-item[data-key="treeSheets"]');
  await expect(row).toContainText("Significant tree data sheets");
  await expect(row).toContainText(SHEETS_MB);
  await expect(row.locator(".dl-btn")).toHaveText("Download");
  await expect(row.locator(".dl-btn")).toBeEnabled();
  await expect(page.locator("#dl-list")).toContainText("Descriptions & documents");
  // the About panel names the register and where the sheets come from
  await closePanel(page);
  await page.locator("#btn-about").click();
  await expect(page.locator("#panel")).toContainText("City of Hobart significant tree register");
  await expect(page.locator("#panel")).toContainText("keeps only on the device");
});

test("trees: the sheet batch downloads every PDF into OPFS and deletes them again", async ({ page, browserName }) => {
  test.skip(browserName === "webkit", "Playwright WebKit build lacks OPFS createWritable");
  await routeSheets(page);
  const ids = Object.keys(TREES.sheets);
  // an empty shell (interrupted copy fallback) is not "on the device": the
  // row still offers Download and the batch fetches that sheet for real
  await page.evaluate(async (id) => {
    const root = await navigator.storage.getDirectory();
    const dir = await root.getDirectoryHandle("trees", { create: true });
    await (await (await dir.getFileHandle(id + ".pdf", { create: true })).createWritable()).close();
  }, ids[0]);
  await page.locator("#btn-downloads").click();
  const row = page.locator('.dl-item[data-key="treeSheets"]');
  await expect(row.locator(".dl-btn")).toHaveText("Download");
  await row.locator(".dl-btn").click();
  await expect(row.locator(".dl-btn")).toHaveText("Cancel");
  await expect(row.locator(".dl-status")).toContainText(new RegExp(`sheet \\d+ of ${SHEET_COUNT}`));
  await expect(row.locator(".dl-status")).toHaveText("✓ downloaded", { timeout: 60_000 });
  await expect(row.locator(".dl-btn")).toHaveText("Delete");
  expect(await sheetSize(page, ids[0])).toBe(TINY_PDF.length);
  expect(await sheetSize(page, ids[ids.length - 1])).toBe(TINY_PDF.length);
  await closePanel(page);
  await page.locator("#btn-downloads").click();
  await expect(page.locator('.dl-item[data-key="treeSheets"] .dl-btn')).toHaveText("Delete");
  await page.locator('.dl-item[data-key="treeSheets"] .dl-btn').click();
  await expect(page.locator('.dl-item[data-key="treeSheets"] .dl-btn')).toHaveText("Download");
  expect(await sheetSize(page, ids[0])).toBeNull();
});

test("trees: Cancel pauses the sheet batch and Resume continues where it stopped", async ({ page, browserName }) => {
  test.skip(browserName === "webkit", "Playwright WebKit build lacks OPFS createWritable");
  let served = 0;
  await page.route(SHEET_ROUTE, async (route) => {
    served++;
    await new Promise((r) => setTimeout(r, served <= 3 ? 10 : 400)); // slow after a few
    // the request in flight at Cancel time is gone by the time this fires
    await route.fulfill({ status: 200, contentType: "application/pdf", body: Buffer.from(TINY_PDF) }).catch(() => {});
  });
  await page.locator("#btn-downloads").click();
  const row = page.locator('.dl-item[data-key="treeSheets"]');
  await row.locator(".dl-btn").click();
  await expect(row.locator(".dl-status")).toContainText(new RegExp(`sheet [4-9] of ${SHEET_COUNT}`), { timeout: 15_000 });
  await row.locator(".dl-btn", { hasText: "Cancel" }).click();
  await expect(row.locator(".dl-btn:not(.dl-secondary)")).toHaveText("Resume");
  await expect(row.locator(".dl-status")).toContainText("paused");
  await expect(row.locator(".dl-secondary")).toHaveText("Delete"); // a half batch stays deletable
  const before = served;
  // reopening the panel finds the paused state again (no job running)
  await closePanel(page);
  await page.locator("#btn-downloads").click();
  await expect(row.locator(".dl-btn:not(.dl-secondary)")).toHaveText("Resume");
  // ...worded as what is there, not as a pause (a single tap-fetched sheet
  // reaches this state without anything having been paused)
  await expect(row).toContainText(new RegExp(`\\d+ MB of ${SHEETS_MB} on this device`));
  await expect(row).not.toContainText("paused");
  // Resume skips what is already on the device
  await page.unroute(SHEET_ROUTE);
  await routeSheets(page);
  await row.locator(".dl-btn:not(.dl-secondary)").click();
  await expect(row.locator(".dl-status")).toHaveText("✓ downloaded", { timeout: 60_000 });
  expect(served).toBe(before); // the slow route saw no further requests
});

test("trees: a withdrawn sheet (HTTP 400 + HTML) is skipped and remembered; a tap re-checks it", async ({ page, browserName }) => {
  test.skip(browserName === "webkit", "Playwright WebKit build lacks OPFS createWritable");
  const f = isolatedTree();
  const goneId = f.properties.sheet;
  let goneNow = true;
  // ArcGIS answers a removed item with 400 and an HTML page (verified live), not 404
  await page.route(SHEET_ROUTE, (route) =>
    goneNow && route.request().url().includes(goneId)
      ? route.fulfill({ status: 400, contentType: "text/html", body: "<html><body>Item does not exist</body></html>" })
      : route.fulfill({ status: 200, contentType: "application/pdf", body: Buffer.from(TINY_PDF) }),
  );
  await page.locator("#btn-downloads").click();
  const row = page.locator('.dl-item[data-key="treeSheets"]');
  await row.locator(".dl-btn").click();
  // the batch marches past the withdrawn sheet and completes
  await expect(row.locator(".dl-status")).toHaveText("✓ downloaded · 1 sheet no longer published", { timeout: 60_000 });
  await expect(row.locator(".dl-btn")).toHaveText("Delete");
  expect(await sheetSize(page, goneId)).toBeNull();
  const gone = () => page.evaluate(() => Object.keys(JSON.parse(localStorage.getItem("treeSheetsGone") ?? "{}")));
  expect(await gone()).toEqual([goneId]);
  // a reopened panel still counts the collection as complete
  await closePanel(page);
  await page.locator("#btn-downloads").click();
  await expect(row.locator(".dl-btn")).toHaveText("Delete");
  await expect(row.locator(".dl-status")).toContainText("1 sheet no longer published");
  await closePanel(page);
  // the card says why the sheet is missing, and a tap tries once more —
  // with the real reason in the alert, not the "open it once while online" wording
  const alerts: string[] = [];
  page.on("dialog", (d) => {
    alerts.push(d.message());
    void d.dismiss();
  });
  await enableTrees(page);
  await tapTree(page, f);
  await expect(page.locator(".sheet-desc small")).toContainText("not published by the council any more");
  await page.locator(".sheet-desc").click();
  await expect.poll(() => alerts.length).toBe(1);
  expect(alerts[0]).toContain("no longer published by the council");
  await expect(page.locator("#pdfview")).toBeHidden();
  // republished: the same tap fetches it and forgets the mark
  goneNow = false;
  await page.locator(".sheet-desc").click();
  await expect(page.locator("#pdfview")).toBeVisible();
  expect(await sheetSize(page, goneId)).toBe(TINY_PDF.length);
  expect(await gone()).toEqual([]);
  await page.keyboard.press("Escape");
  await expect(page.locator("#pdfview")).toBeHidden();
  await page.locator("#btn-downloads").click();
  await expect(row.locator(".dl-status")).toHaveText("✓ downloaded");
});

test("trees: dismissing the card while its sheet is fetching aborts it — no viewer, no alert", async ({ page, browserName }) => {
  test.skip(browserName === "webkit", "Playwright WebKit build lacks OPFS createWritable");
  let requests = 0;
  await page.route(SHEET_ROUTE, async (route) => {
    requests++;
    await new Promise((r) => setTimeout(r, 3000));
    await route.fulfill({ status: 200, contentType: "application/pdf", body: Buffer.from(TINY_PDF) }).catch(() => {});
  });
  const alerts: string[] = [];
  page.on("dialog", (d) => {
    alerts.push(d.message());
    void d.dismiss();
  });
  const f = isolatedTree();
  await enableTrees(page);
  await tapTree(page, f);
  await page.locator(".sheet-desc").click();
  await expect(page.locator(".sheet-desc small")).toContainText("fetching…");
  await expect.poll(() => requests).toBe(1);
  await page.keyboard.press("Escape"); // closes the card -> aborts the fetch
  await expect(page.locator("#sheet")).toBeHidden();
  await page.waitForTimeout(3500);
  await expect(page.locator("#pdfview")).toBeHidden();
  expect(alerts).toEqual([]);
  expect(await sheetSize(page, f.properties.sheet)).toBeNull();
});

test("trees: of two dots inside one tap box the nearest answers", async ({ page }) => {
  await enableTrees(page);
  const [a, b] = closeTreePair();
  for (const f of [a, b, a]) {
    await tapTree(page, f);
    await expect(page.locator("#sheet .sheet-code")).toHaveText(f.properties.ref);
  }
});

test("trees: a vegetation card survives the trees toggle; a tree card survives an overlay switch", async ({ page }) => {
  const viewport = page.viewportSize()!;
  await page.mouse.click(viewport.width / 2, viewport.height / 2);
  const sheet = page.locator("#sheet");
  await expect(sheet).toBeVisible();
  await expect(sheet).toHaveAttribute("data-kind", "veg");
  await enableTrees(page); // flips `trees` — not this card's concern
  await expect(sheet).toBeVisible();
  await expect(sheet).toHaveAttribute("data-kind", "veg");
  await tapTree(page, isolatedTree());
  await expect(sheet).toHaveAttribute("data-kind", "tree");
  await chooseLayer(page, "overlay", "geo"); // a tree card does not depend on the overlay
  await closePanel(page);
  await expect(sheet).toBeVisible();
  await page.locator("#btn-layers").click();
  await page.locator('.lay-row[data-toggle="trees"]').click(); // trees off: the card must go with its dots
  await closePanel(page);
  await expect(sheet).toBeHidden();
});
