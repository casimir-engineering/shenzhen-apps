// Compares the converged ray-traced sample model with the raster view it replaces.
// Needs a real WebGPU adapter. Starts its own dev server on a free port unless
// PERF_BASE_URL points at a running one.
//   node tests/ray-tracing-exposure-browser.mjs [--headed] [--samples=128] [--save=dir]
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { chromium } from "@playwright/test";
import { startAppServer } from "../scripts/perf/app-server.mjs";

const headed = process.argv.includes("--headed");
const saveDir = process.argv
  .find((arg) => arg.startsWith("--save="))
  ?.slice("--save=".length);
const samples = Number(
  process.argv.find((arg) => arg.startsWith("--samples="))?.split("=")[1] ??
    128,
);
// Raster has no shadows, interreflection or reflected environment, so a
// faithful trace differs somewhat; it must never be blown out relative to it.
// Matte surfaces isolate the lighting conversion and get tighter limits.
const CASES = {
  sample: {
    matte: false,
    minLumaRatio: 0.85,
    maxLumaRatio: 1.25,
    maxHistogramDistance: 0.6,
  },
  matte: {
    matte: true,
    minLumaRatio: 0.9,
    maxLumaRatio: 1.08,
    maxHistogramDistance: 0.3,
  },
  "matte-fill": {
    matte: true,
    fill: true,
    minLumaRatio: 0.9,
    maxLumaRatio: 1.08,
    maxHistogramDistance: 0.3,
  },
};
const MAX_EXTRA_CLIPPED = 0.02,
  CONVERGENCE = 0.02;
const server = await startAppServer({
  readyPath: "/tests/ray-tracing-exposure.html",
});
const browser = await chromium
  .launch({
    headless: !headed,
    args: [
      "--enable-unsafe-webgpu",
      "--use-gl=angle",
      "--use-angle=metal",
      "--disable-backgrounding-occluded-windows",
    ],
  })
  .catch(async (error) => {
    await server.close();
    throw error;
  });
const report = { samples, cases: {} };
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
  await page.goto(`${server.origin}/tests/ray-tracing-exposure.html`);
  await page.waitForFunction(() => !!window.rayTracingExposure, undefined, {
    timeout: 120_000,
  });
  report.adapter = await page.evaluate(async () => {
    const found = await navigator.gpu?.requestAdapter();
    return found
      ? {
          vendor: found.info?.vendor,
          architecture: found.info?.architecture,
          fallback: !!found.info?.isFallbackAdapter,
        }
      : null;
  });
  if (!report.adapter || report.adapter.fallback)
    throw Error("No hardware WebGPU adapter is available in this browser.");
  let failed = false;
  for (const [name, limits] of Object.entries(CASES)) {
    const { captures, ...result } = await page.evaluate(
      (options) => window.rayTracingExposure(options),
      { samples, keep: !!saveDir, matte: limits.matte, fill: !!limits.fill },
    );
    if (errors.length) throw Error(errors.join("\n"));
    if (saveDir) {
      mkdirSync(saveDir, { recursive: true });
      for (const [capture, url] of Object.entries(captures))
        writeFileSync(
          join(saveDir, `${name}-${capture}.png`),
          Buffer.from(url.slice(url.indexOf(",") + 1), "base64"),
        );
    }
    const failures = [];
    const percent = (value) => `${(value * 100).toFixed(1)}%`;
    if (result.lumaRatio > limits.maxLumaRatio)
      failures.push(
        `Traced model is ${percent(result.lumaRatio)} of raster brightness (limit ${percent(limits.maxLumaRatio)})`,
      );
    if (result.lumaRatio < limits.minLumaRatio)
      failures.push(
        `Traced model is only ${percent(result.lumaRatio)} of raster brightness (limit ${percent(limits.minLumaRatio)})`,
      );
    if (result.histogramDistance > limits.maxHistogramDistance)
      failures.push(
        `Luma histogram distance ${result.histogramDistance.toFixed(3)} exceeds ${limits.maxHistogramDistance}`,
      );
    if (
      result.traced.clippedFraction >
      result.raster.clippedFraction + MAX_EXTRA_CLIPPED
    )
      failures.push(
        `Traced clipping ${percent(result.traced.clippedFraction)} vs raster ${percent(result.raster.clippedFraction)}`,
      );
    if (Math.abs(result.convergenceRatio - 1) > CONVERGENCE)
      failures.push(
        `Mean brightness drifted ${percent(result.convergenceRatio - 1)} between 32 and ${samples} samples`,
      );
    if (result.backgroundDifference > 2)
      failures.push(
        `Traced background differs from raster by ${result.backgroundDifference} levels`,
      );
    failed ||= failures.length > 0;
    report.cases[name] = { limits, ...result, failures };
  }
  console.log(JSON.stringify(report, null, 2));
  if (failed) process.exitCode = 1;
} finally {
  await browser.close();
  await server.close();
}
