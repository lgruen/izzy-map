// Visual QA for the pre-1750 overlay: statewide -> overzoom views.
// Usage: npx vite --port 5199 & node scripts/shot-pre1750.mjs
import { webkit } from "playwright";

const browser = await webkit.launch();
const ctx = await browser.newContext({
  viewport: { width: 390, height: 844 },
  deviceScaleFactor: 2,
  geolocation: { latitude: -42.92, longitude: 147.235 },
  permissions: ["geolocation"],
});
const page = await ctx.newPage();
await page.addInitScript(() => localStorage.setItem("overlayMode", "pre"));
page.on("pageerror", (e) => console.log("pageerror:", e.message));
await page.goto("http://localhost:5199/");
await page.waitForTimeout(8000); // map load + geolocate fly-in

const shots = [
  ["statewide", 146.6, -42.2, 6.3],
  ["midlands", 147.3, -42.0, 8.5],
  ["kunanyi", 147.235, -42.92, 11],
  ["overzoom", 147.235, -42.92, 13.5],
];
for (const [label, lon, lat, zoom] of shots) {
  await page.evaluate(
    ([ln, lt, z]) => window.__map.jumpTo({ center: [ln, lt], zoom: z }),
    [lon, lat, zoom],
  );
  await page.waitForTimeout(3500);
  await page.screenshot({ path: `/tmp/izzy-pre-${label}.png` });
}
await browser.close();
console.log("saved /tmp/izzy-pre-*.png");
