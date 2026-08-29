import { webkit } from "playwright";
const browser = await webkit.launch();
const ctx = await browser.newContext({
  viewport: { width: 390, height: 844 },
  deviceScaleFactor: 2,
  geolocation: { latitude: -42.92, longitude: 147.235 },
  permissions: ["geolocation"],
});
const page = await ctx.newPage();
await page.goto("http://localhost:5199/");
await page.waitForTimeout(7000);
for (const [btn, name] of [["#btn-legend", "legend"], ["#btn-downloads", "downloads"], ["#btn-about", "about"]]) {
  await page.click(btn);
  await page.waitForTimeout(1200);
  await page.screenshot({ path: `/tmp/izzy-${name}.png` });
  if (name === "legend") {
    await page.mouse.wheel(0, 600); // scroll inside panel? panel scrolls via inner
    await page.evaluate(() => document.querySelector(".panel-inner").scrollBy(0, 700));
    await page.waitForTimeout(400);
    await page.screenshot({ path: "/tmp/izzy-legend-scrolled.png" });
  }
  await page.click(".panel-close");
  await page.waitForTimeout(400);
}
await browser.close();
console.log("panel shots saved");
