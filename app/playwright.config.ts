import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "tests",
  timeout: 60_000,
  retries: process.env.CI ? 1 : 0,
  use: {
    baseURL: "http://localhost:5200",
    geolocation: { latitude: -42.92, longitude: 147.235 }, // kunanyi summit area
    permissions: ["geolocation"],
  },
  projects: [
    { name: "webkit-iphone", use: { ...devices["iPhone 14"], browserName: "webkit" } },
    { name: "chromium-mobile", use: { ...devices["Pixel 7"], browserName: "chromium" } },
  ],
  webServer: {
    command: "npx vite --port 5200 --strictPort",
    url: "http://localhost:5200",
    reuseExistingServer: false,
    timeout: 30_000,
  },
});
