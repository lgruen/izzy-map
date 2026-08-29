import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import type { Page } from "@playwright/test";

const HERE = dirname(fileURLToPath(import.meta.url));
const FIXTURE = readFileSync(join(HERE, "fixtures", "tasveg_test.pmtiles"));

/** Serve the committed Hobart-clip TASVEG fixture (with HTTP Range support,
 * which the pmtiles FetchSource depends on) regardless of whether the local
 * data/ build products exist — so tests run identically in CI. */
export async function routeTasvegFixture(page: Page): Promise<void> {
  await page.route("**/dev-data/tasveg.pmtiles", async (route) => {
    const range = /bytes=(\d+)-(\d*)/.exec(route.request().headers()["range"] ?? "");
    if (range) {
      const start = Number(range[1]);
      const end = range[2] ? Math.min(Number(range[2]), FIXTURE.length - 1) : FIXTURE.length - 1;
      await route.fulfill({
        status: 206,
        headers: {
          "Content-Range": `bytes ${start}-${end}/${FIXTURE.length}`,
          "Accept-Ranges": "bytes",
        },
        body: FIXTURE.subarray(start, end + 1),
      });
    } else {
      await route.fulfill({ status: 200, body: FIXTURE });
    }
  });
}

/** Block LIST topo tile fetches so tests don't depend on the network. */
export async function blockTopoNetwork(page: Page): Promise<void> {
  await page.route("**/services.thelist.tas.gov.au/**", (route) => route.abort());
}

export async function waitForMapIdle(page: Page): Promise<void> {
  await page.waitForFunction(() => {
    const map = (window as never as { __map?: { loaded(): boolean; isMoving(): boolean } }).__map;
    return !!map && map.loaded() && !map.isMoving();
  }, { timeout: 30_000 });
  // give symbol placement / geolocate fly-in a beat to settle
  await page.waitForTimeout(1500);
}

export async function centerFeature(page: Page): Promise<Record<string, string> | null> {
  return page.evaluate(() => {
    const map = (window as never as { __map: import("maplibre-gl").Map }).__map;
    const c = map.project(map.getCenter());
    const feats = map.queryRenderedFeatures([c.x, c.y], { layers: ["tasveg-fill"] });
    return (feats[0]?.properties as Record<string, string>) ?? null;
  });
}
