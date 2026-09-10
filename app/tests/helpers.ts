import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import type { Page } from "@playwright/test";
import { PMTiles, type RangeResponse, type Source } from "pmtiles";

const HERE = dirname(fileURLToPath(import.meta.url));
const fixture = (name: string) => readFileSync(join(HERE, "fixtures", name));
const FIXTURE = fixture("tasveg_test.pmtiles");
const GEO_FIXTURE = fixture("geology.pmtiles");
const PRE_FIXTURE = fixture("pre1750_test.pmtiles");
// synthetic solid-colour rasters (pipeline/make_raster_fixtures.py)
export const AERIAL_FIXTURE = fixture("aerial_test.pmtiles"); // red
export const TASMAP_FIXTURE = fixture("tasmap_test.pmtiles"); // cream
export const SEASON_2023_FIXTURE = fixture("aerial_2023_test.pmtiles"); // green, west half
export const SEASON_2024_FIXTURE = fixture("aerial_2024_test.pmtiles"); // blue, NE quarter
export const COLOURS = {
  red: [200, 30, 30],
  cream: [243, 233, 198],
  green: [40, 150, 80],
  blue: [40, 80, 200],
  topoBg: [238, 243, 240], // #eef3f0 — LIST blocked in tests, so topo = background
} as const;
/** z15 tile containing the test GPS point (printed by the fixture script). */
export const CENTRE_TILE = { z: 15, x: 29785, y: 20717 };

/** Serve a committed fixture (with HTTP Range support, which the pmtiles
 * FetchSource depends on) regardless of whether the local data/ build
 * products exist — so tests run identically in CI. */
function serveFixture(buf: Buffer) {
  return async (route: Parameters<Parameters<Page["route"]>[1]>[0]) => {
    const range = /bytes=(\d+)-(\d*)/.exec(route.request().headers()["range"] ?? "");
    if (range) {
      const start = Number(range[1]);
      const end = range[2] ? Math.min(Number(range[2]), buf.length - 1) : buf.length - 1;
      await route.fulfill({
        status: 206,
        headers: {
          "Content-Range": `bytes ${start}-${end}/${buf.length}`,
          "Accept-Ranges": "bytes",
        },
        body: buf.subarray(start, end + 1),
      });
    } else {
      await route.fulfill({ status: 200, body: buf });
    }
  };
}

export async function routeTasvegFixture(page: Page): Promise<void> {
  await page.route("**/dev-data/tasveg.pmtiles", serveFixture(FIXTURE));
  await page.route("**/dev-data/geology.pmtiles", serveFixture(GEO_FIXTURE));
  await page.route("**/dev-data/pre1750.pmtiles", serveFixture(PRE_FIXTURE));
}

/** Block LIST topo tile fetches so tests don't depend on the network. */
export async function blockTopoNetwork(page: Page): Promise<void> {
  await page.route("**/services.thelist.tas.gov.au/**", (route) => route.abort());
}

class BufferSource implements Source {
  constructor(private buf: Buffer, private key: string) {}
  getKey(): string {
    return this.key;
  }
  async getBytes(offset: number, length: number): Promise<RangeResponse> {
    const start = this.buf.byteOffset + offset;
    return { data: this.buf.buffer.slice(start, start + length) as ArrayBuffer };
  }
}

/** Raster packs: the season archives come from "R2" (dev-data), the
 * statewide services stream live from LIST — both served from the synthetic
 * fixtures here. Registered AFTER blockTopoNetwork (Playwright matches the
 * most recent route first), so Orthophoto/Tasmap tiles resolve while the
 * Topographic service stays blocked. Every raster archive URL is routed
 * explicitly: a developer's data/ may hold the real multi-GB packs. */
export async function routeRasterFixtures(page: Page): Promise<void> {
  await page.route("**/dev-data/*.pmtiles", (route) => route.fulfill({ status: 404, body: "" }));
  // ...and the manifest: a developer's data/ carries the real one
  await page.route("**/dev-data/data-manifest.json", (route) => route.fulfill({ status: 404, body: "" }));
  await routeTasvegFixture(page);
  await page.route("**/dev-data/aerial_2023.pmtiles", serveFixture(SEASON_2023_FIXTURE));
  await page.route("**/dev-data/aerial_2024.pmtiles", serveFixture(SEASON_2024_FIXTURE));
  const live = async (service: string, buf: Buffer) => {
    const pm = new PMTiles(new BufferSource(buf, service));
    await page.route(new RegExp(`Basemaps/${service}/MapServer/tile/(\\d+)/(\\d+)/(\\d+)$`), async (route) => {
      const m = /tile\/(\d+)\/(\d+)\/(\d+)$/.exec(route.request().url())!;
      const [z, y, x] = [Number(m[1]), Number(m[2]), Number(m[3])]; // LIST order: z/y/x
      const t = await pm.getZxy(z, x, y);
      if (t?.data) await route.fulfill({ status: 200, contentType: "image/jpeg", body: Buffer.from(t.data) });
      else await route.fulfill({ status: 404, body: "" });
    });
  };
  await live("Orthophoto", AERIAL_FIXTURE);
  await live("TasmapRaster", TASMAP_FIXTURE);
}

export async function waitForMapIdle(page: Page): Promise<void> {
  await page.waitForFunction(() => {
    const map = (window as never as { __map?: { loaded(): boolean; isMoving(): boolean } }).__map;
    return !!map && map.loaded() && !map.isMoving();
  }, { timeout: 30_000 });
  // give symbol placement / geolocate fly-in a beat to settle
  await page.waitForTimeout(1500);
}

/** Wait until every visible source has its tiles and the raster cross-fade
 * (300 ms default) has finished, so pixel readbacks are final. */
export async function waitForTiles(page: Page): Promise<void> {
  await page.waitForFunction(() => {
    const map = (window as never as { __map?: { loaded(): boolean; areTilesLoaded(): boolean; isMoving(): boolean } }).__map;
    return !!map && map.loaded() && map.areTilesLoaded() && !map.isMoving();
  }, { timeout: 30_000 });
  await page.waitForTimeout(700);
}

export async function centerFeature(
  page: Page,
  layer = "tasveg-fill",
): Promise<Record<string, string> | null> {
  return page.evaluate((l) => {
    const map = (window as never as { __map: import("maplibre-gl").Map }).__map;
    const c = map.project(map.getCenter());
    const feats = map.queryRenderedFeatures([c.x, c.y], { layers: [l] });
    return (feats[0]?.properties as Record<string, string>) ?? null;
  }, layer);
}

/** RGB painted on the map canvas at (centre + dx, centre + dy) CSS px.
 * Needs the page opened with ?pixels=1 (preserveDrawingBuffer). */
export async function pixelAt(page: Page, dx = 0, dy = 0): Promise<[number, number, number]> {
  return page.evaluate(([dx, dy]) => {
    const map = (window as never as { __map: import("maplibre-gl").Map }).__map;
    const c = map.getCanvas();
    const gl = (c.getContext("webgl2") ?? c.getContext("webgl")) as WebGLRenderingContext;
    const ratio = c.width / c.clientWidth;
    const px = Math.round((c.clientWidth / 2 + dx) * ratio);
    const py = Math.round((c.clientHeight / 2 + dy) * ratio);
    const out = new Uint8Array(4);
    gl.readPixels(px, c.height - 1 - py, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, out);
    return [out[0], out[1], out[2]];
  }, [dx, dy] as const);
}

export function near(actual: readonly number[], expected: readonly number[], tol = 22): boolean {
  return actual.every((v, i) => Math.abs(v - expected[i]) <= tol);
}

/** Centre the map on a tile (so pixel offsets land inside it). */
export async function jumpToTile(page: Page, z: number, x: number, y: number): Promise<void> {
  await page.evaluate(([z, x, y]) => {
    const n = 2 ** z;
    const lon = ((x + 0.5) / n) * 360 - 180;
    const lat = (Math.atan(Math.sinh(Math.PI * (1 - (2 * (y + 0.5)) / n))) * 180) / Math.PI;
    (window as never as { __map: import("maplibre-gl").Map }).__map.jumpTo({ center: [lon, lat], zoom: z });
  }, [z, x, y] as const);
}

/** Open the Layers sheet and pick a base / overlay row (leaves it open). */
export async function chooseLayer(page: Page, kind: "base" | "overlay", value: string): Promise<void> {
  if (await page.locator("#panel").isHidden() || (await page.locator(".lay-row").count()) === 0)
    await page.locator("#btn-layers").click();
  await page.locator(`.lay-row[data-${kind}="${value}"]`).click();
}
export async function closePanel(page: Page): Promise<void> {
  await page.locator(".panel-close").click();
}
