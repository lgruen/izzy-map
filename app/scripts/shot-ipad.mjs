// Visual check of the wide-viewport (iPad) layout: map, Layers sheet,
// legend, details card, in landscape and portrait.
// Usage: node scripts/shot-ipad.mjs   (dev server on :5199)
import { webkit } from "playwright";

const browser = await webkit.launch();
for (const [label, viewport] of [["land", { width: 1194, height: 834 }], ["port", { width: 834, height: 1194 }]]) {
  const ctx = await browser.newContext({
    viewport,
    deviceScaleFactor: 2,
    geolocation: { latitude: -42.92, longitude: 147.235 },
    permissions: ["geolocation"],
  });
  const page = await ctx.newPage();
  page.on("pageerror", (e) => console.log("pageerror:", e.message));
  await page.goto("http://localhost:5199/");
  await page.waitForTimeout(9000);
  await page.screenshot({ path: `/tmp/izzy-ipad-${label}.png` });
  await page.locator("#btn-layers").click();
  await page.waitForTimeout(600);
  await page.screenshot({ path: `/tmp/izzy-ipad-${label}-layers.png` });
  await page.locator(".panel-close").click();
  await page.locator("#btn-legend").click();
  await page.waitForTimeout(600);
  await page.screenshot({ path: `/tmp/izzy-ipad-${label}-legend.png` });
  await page.locator(".panel-close").click();
  await page.mouse.click(viewport.width / 2, viewport.height / 2);
  await page.waitForTimeout(1000);
  await page.screenshot({ path: `/tmp/izzy-ipad-${label}-details.png` });
  await ctx.close();
}
await browser.close();
console.log("saved /tmp/izzy-ipad-{land,port}[-layers|-legend|-details].png");
