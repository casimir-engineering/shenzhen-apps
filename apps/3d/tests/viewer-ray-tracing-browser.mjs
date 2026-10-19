import { chromium } from "@playwright/test";
const browser = await chromium.launch({
  headless: false,
  args: [
    "--use-gl=angle",
    "--use-angle=metal",
    "--disable-backgrounding-occluded-windows",
  ],
});
try {
  const page = await browser.newPage({
    viewport: { width: 480, height: 320 },
    deviceScaleFactor: 1,
  });
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  page.on("console", (message) => {
    if (message.type() === "error") errors.push(message.text());
  });
  await page.goto(
    `${process.env.PERF_BASE_URL || "http://127.0.0.1:1420"}/tests/viewer-ray-tracing.html`,
  );
  await page.bringToFront();
  await page.waitForFunction(() => !!window.viewerRayTracingChecks);
  const result = await page.evaluate(() => window.viewerRayTracingChecks());
  if (errors.length) throw Error(errors.join("\n"));
  console.log(JSON.stringify(result, null, 2));
} finally {
  await browser.close();
}
