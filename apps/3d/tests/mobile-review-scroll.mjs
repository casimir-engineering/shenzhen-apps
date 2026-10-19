import { chromium, devices, expect } from "@playwright/test";
const browser = await chromium.launch({
  args: [
    "--use-gl=angle",
    "--use-angle=swiftshader",
    "--enable-unsafe-swiftshader",
  ],
});
try {
  const page = await browser.newPage({ ...devices["iPhone 13"] });
  await page.goto(process.env.E2E_BASE_URL || "http://127.0.0.1:1420");
  await page
    .getByRole("button", { name: "Sample model", exact: true })
    .click();
  await expect(page.locator(".model-badge")).toBeVisible();
  const show = page.getByRole("button", {
    name: "Show measurements",
    exact: true,
  });
  if (await show.isVisible()) await show.click();
  await page.getByRole("button", { name: /^Notes/ }).click();
  await page.getByRole("button", { name: "Add note", exact: true }).click();
  const panel = page.locator(".review-content"),
    box = await panel.boundingBox(),
    before = await panel.evaluate((el) => ({
      top: el.scrollTop,
      height: el.clientHeight,
      content: el.scrollHeight,
    }));
  const cdp = await page.context().newCDPSession(page),
    x = box.x + 6,
    y = box.y + box.height - 15;
  await cdp.send("Input.dispatchTouchEvent", {
    type: "touchStart",
    touchPoints: [{ x, y }],
  });
  for (let i = 1; i <= 10; i++) {
    await cdp.send("Input.dispatchTouchEvent", {
      type: "touchMove",
      touchPoints: [{ x, y: y - i * 15 }],
    });
    await new Promise((r) => setTimeout(r, 20));
  }
  await cdp.send("Input.dispatchTouchEvent", {
    type: "touchEnd",
    touchPoints: [],
  });
  await expect
    .poll(() => panel.evaluate((el) => el.scrollTop))
    .toBeGreaterThan(10);
  await expect(
    page.getByRole("button", { name: "Save note", exact: true }),
  ).toBeInViewport({ ratio: 1 });
  console.log(
    JSON.stringify({
      engine: "Chromium mobile touch emulation",
      before,
      after: await panel.evaluate((el) => ({
        top: el.scrollTop,
        height: el.clientHeight,
        content: el.scrollHeight,
      })),
      saveInView: await page
        .getByRole("button", { name: "Save note", exact: true })
        .evaluate((el) => {
          const r = el.getBoundingClientRect();
          return r.y >= 0 && r.bottom <= innerHeight;
        }),
      actualTouchGesture: true,
    }),
  );
} finally {
  await browser.close();
}
