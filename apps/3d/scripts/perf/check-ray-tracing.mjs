import { chromium } from "@playwright/test";
import fs from "node:fs";
import { startAppServer } from "./app-server.mjs";
const model = process.argv.includes("--sample") ? "sample" : "materials";
const server = await startAppServer({
  readyPath: `/tests/perf/ray-tracing.html?model=${model}`,
});
const browser = await chromium
  .launch({
    headless: false,
    args: ["--use-gl=angle", "--use-angle=metal"],
  })
  .catch(async (error) => {
    await server.close();
    throw error;
  });
try {
  const page = await browser.newPage({ viewport: { width: 600, height: 500 } });
  let logs = 0;
  const errors = [];
  page.on("console", (m) => {
    if (
      /GPU.*(error|failed)|Shader.*(error|failed)|validation failed/i.test(
        m.text(),
      )
    )
      errors.push(m.text().slice(0, 1000));
    if (logs++ < 20) console.log(m.text().slice(0, 1000));
  });
  page.on("pageerror", (e) => {
    errors.push(e.message);
    console.error(e);
  });
  await page.goto(
    `${server.origin}/tests/perf/ray-tracing.html?model=${model}`,
  );
  await page.bringToFront();
  const hardware = await page.evaluate(async () => {
    const adapter = await navigator.gpu?.requestAdapter({
      powerPreference: "high-performance",
    });
    if (!adapter) return { unsupported: true };
    const info = adapter.info;
    return {
      vendor: info.vendor,
      architecture: info.architecture,
      device: info.device,
      description: info.description,
      isFallbackAdapter: info.isFallbackAdapter,
    };
  });
  if (
    hardware.unsupported ||
    hardware.isFallbackAdapter ||
    /swiftshader|llvmpipe|software/i.test(JSON.stringify(hardware))
  )
    throw new Error("Hardware WebGPU adapter required");
  console.log(JSON.stringify({ hardware }));
  await page.waitForFunction(
    () =>
      window.rtStates?.some((s) =>
        ["ready", "error", "unsupported"].includes(s.status),
      ),
    null,
    { timeout: 180000 },
  );
  const states = await page.evaluate(() => window.rtStates);
  console.log(JSON.stringify(states.at(-1)));
  if (states.at(-1).status !== "ready")
    throw new Error(
      states.at(-1).reason || "No converged GPU ray tracing result",
    );
  if (!(await page.evaluate(() => window.rtUnchanged())))
    throw new Error("Ray tracing changed original source geometry/camera");
  fs.mkdirSync("artifacts/perf", { recursive: true });
  await page.screenshot({ path: "artifacts/perf/ray-tracer-page.png" });
  const visiblePng = await page.locator(".ray-tracing-overlay").screenshot();
  const result = await page.evaluate(async (visibleBytes) => {
    const blob = await window.rtSnapshot(),
      bitmap = await createImageBitmap(blob),
      canvas = new OffscreenCanvas(bitmap.width, bitmap.height),
      context = canvas.getContext("2d");
    context.drawImage(bitmap, 0, 0);
    const pixels = context.getImageData(0, 0, bitmap.width, bitmap.height).data,
      colors = new Set();
    for (let i = 0; i < pixels.length; i += 4)
      colors.add(`${pixels[i]},${pixels[i + 1]},${pixels[i + 2]}`);
    bitmap.close();
    const visible = await createImageBitmap(
      new Blob([new Uint8Array(visibleBytes)], { type: "image/png" }),
    );
    const comparison = new OffscreenCanvas(visible.width, visible.height),
      compareContext = comparison.getContext("2d");
    compareContext.drawImage(visible, 0, 0);
    const displayed = compareContext.getImageData(
      0,
      0,
      visible.width,
      visible.height,
    ).data;
    compareContext.clearRect(0, 0, visible.width, visible.height);
    const exported = await createImageBitmap(blob);
    compareContext.drawImage(exported, 0, 0, visible.width, visible.height);
    const reread = compareContext.getImageData(
      0,
      0,
      visible.width,
      visible.height,
    ).data;
    let total = 0,
      max = 0,
      bad = 0;
    for (let i = 0; i < reread.length; i++) {
      const difference = Math.abs(displayed[i] - reread[i]);
      total += difference;
      max = Math.max(max, difference);
      if (difference > 3) bad++;
    }
    visible.close();
    exported.close();
    return {
      displayParity: {
        backgroundDisplayed: Array.from(displayed.slice(0, 4)),
        backgroundExported: Array.from(reread.slice(0, 4)),
        meanChannelError: total / reread.length,
        maxChannelError: max,
        channelsOver3: bad,
        totalChannels: reread.length,
      },
      bytes: Array.from(new Uint8Array(await blob.arrayBuffer())),
      colors: colors.size,
      stats: window.rtStats,
    };
  }, Array.from(visiblePng));
  fs.writeFileSync("artifacts/perf/ray-display-comparison.png", visiblePng);
  fs.writeFileSync(
    "artifacts/perf/ray-export-comparison.png",
    Buffer.from(result.bytes),
  );
  console.log(JSON.stringify({ displayParity: result.displayParity }));
  if (
    result.displayParity.meanChannelError > 1 ||
    result.displayParity.channelsOver3 / result.displayParity.totalChannels >
      0.01
  )
    throw new Error("Export colors differ from the displayed trace");
  if (result.colors < 20)
    throw new Error("GPU ray-traced image has insufficient visible variation");
  if (
    model === "sample" &&
    (result.stats.instances !== 3154 || result.stats.geometryCount !== 16)
  )
    throw new Error("Sample assembly instancing was not preserved");
  const bytes = result.bytes;
  console.log(
    JSON.stringify({ model, colors: result.colors, scene: result.stats }),
  );
  fs.mkdirSync("artifacts/perf", { recursive: true });
  fs.writeFileSync(
    `artifacts/perf/ray-traced-${model}.png`,
    Buffer.from(bytes),
  );
  await page.screenshot({ path: "artifacts/perf/ray-tracer-page.png" });
  if ((await page.evaluate(() => window.rtPause())) !== "hidden")
    throw new Error("Navigation failed to reveal raster immediately");
  const previousStates = states.length;
  await page.evaluate(() => window.rtMove());
  await page.waitForFunction(
    (previous) =>
      window.rtStates.slice(previous).some((s) => s.status === "ready"),
    previousStates,
    { timeout: 180000 },
  );
  await page.evaluate(() => window.rtCancel());
  if (errors.length) throw new Error(errors.join("\n"));
  fs.writeFileSync(
    `artifacts/perf/ray-tracing-${model}.json`,
    JSON.stringify(
      {
        date: new Date().toISOString(),
        hardware,
        model,
        states,
        scene: result.stats,
        colors: result.colors,
        immutable: true,
        navigationPauseResume: true,
        pngReadback: true,
        displayParity: result.displayParity,
        shaderErrors: errors,
      },
      null,
      2,
    ) + "\n",
  );
  console.log(
    "GPU ray-tracing convergence, immutable source and PNG snapshot verified",
  );
} finally {
  await browser.close();
  await server.close();
}
