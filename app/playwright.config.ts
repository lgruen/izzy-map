import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "tests",
  // CI runs 3 map-rendering browsers on a 4-vCPU runner under software GL:
  // the heavy raster pixel tests then need well over 60 s (4 workers hit
  // the 60 s cap and failed, 2026-09-12). A generous cap costs nothing when
  // tests pass.
  timeout: process.env.CI ? 120_000 : 60_000,
  retries: process.env.CI ? 1 : 0,
  // One spec file: without fullyParallel each project runs its tests
  // serially in a single worker, so only three workers can ever be busy
  // and the CI default of two left one idle for the long tail (20 min).
  // Every test has its own browser context (localStorage/OPFS isolated),
  // so order does not matter. 4 workers starved the WebGL tests (see above).
  fullyParallel: true,
  workers: process.env.CI ? 3 : undefined,
  use: {
    baseURL: "http://localhost:5200",
    geolocation: { latitude: -42.92, longitude: 147.235 }, // kunanyi summit area
    permissions: ["geolocation"],
  },
  projects: [
    { name: "webkit-iphone", use: { ...devices["iPhone 14"], browserName: "webkit" } },
    { name: "chromium-mobile", use: { ...devices["Pixel 7"], browserName: "chromium" } },
    // iPad in landscape (Magic Keyboard use): exercises the wide-viewport
    // card layout, Escape handling and the iPadOS (Mac-like) UA.
    {
      name: "webkit-ipad",
      use: { ...devices["iPad Pro 11 landscape"], browserName: "webkit" },
    },
  ],
  webServer: {
    command: "npx vite --port 5200 --strictPort",
    url: "http://localhost:5200",
    reuseExistingServer: false,
    timeout: 30_000,
  },
});
