// Quick visual check: load the dev app with a simulated GPS position and
// save screenshots. Usage: node scripts/shot.mjs [lat] [lon] [zoom-label]
import { webkit } from "playwright";

const lat = Number(process.argv[2] ?? -42.92);
const lon = Number(process.argv[3] ?? 147.235);
const label = process.argv[4] ?? "kunanyi";

const browser = await webkit.launch();
const ctx = await browser.newContext({
  viewport: { width: 390, height: 844 },
  deviceScaleFactor: 2,
  geolocation: { latitude: lat, longitude: lon },
  permissions: ["geolocation"],
});
const page = await ctx.newPage();
page.on("console", (m) => {
  if (m.type() === "error") console.log("console.error:", m.text());
});
page.on("pageerror", (e) => console.log("pageerror:", e.message));
await page.goto("http://localhost:5199/");
await page.waitForTimeout(9000); // map load + geolocate fly-in + tiles
await page.screenshot({ path: `/tmp/izzy-${label}.png` });

// tap the centre to open the details sheet
await page.mouse.click(195, 422);
await page.waitForTimeout(1200);
await page.screenshot({ path: `/tmp/izzy-${label}-tap.png` });
await browser.close();
console.log("saved /tmp/izzy-" + label + ".png and -tap.png");
