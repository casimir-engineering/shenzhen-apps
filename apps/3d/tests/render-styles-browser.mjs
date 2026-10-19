import { chromium } from "@playwright/test";
const software = process.argv.includes("--software");
const browser = await chromium.launch({
  headless: software,
  args: [
    "--use-gl=angle",
    software ? "--use-angle=swiftshader" : "--use-angle=metal",
    ...(software ? ["--enable-unsafe-swiftshader"] : []),
    "--disable-backgrounding-occluded-windows",
  ],
});
const page = await browser.newPage({
  viewport: { width: 640, height: 480 },
  deviceScaleFactor: 1,
});
const errors = [];
page.on("console", (message) => {
  if (message.type() === "error") errors.push(message.text());
});
page.on("pageerror", (error) => errors.push(error.message));
try {
  await page.goto(
    `${process.env.PERF_BASE_URL || "http://127.0.0.1:1420"}/tests/render-styles.html`,
  );
  await page.waitForFunction(() => !!window.renderStyleChecks);
  const result = await page.evaluate(() => window.renderStyleChecks());
  if (errors.length) throw new Error(JSON.stringify(errors));
  console.log(JSON.stringify(result, null, 2));
} finally {
  await browser.close();
}
