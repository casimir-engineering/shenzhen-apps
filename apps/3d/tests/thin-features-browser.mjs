// Thin and coplanar features must render without depth fighting at every zoom: the pixel test of
// tests/thin-features.js, from very close to far, from above, at an angle and grazing, with the orbit target on the
// marking or on the far side of the model.
//
//   node tests/thin-features-browser.mjs              hidden Electron on the Mac's GPU (nothing on the screen)
//   node tests/thin-features-browser.mjs --software   headless Chromium with SwiftShader (any machine)
//   --save=DIR                                        also writes a PNG of every view
//
// A Vite dev server starts on a free loopback port unless PERF_BASE_URL names one that is running.
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { startAppServer } from "../scripts/perf/app-server.mjs";

const root = fileURLToPath(new URL("..", import.meta.url));
const software = process.argv.includes("--software") || process.platform !== "darwin";
const save = process.argv.find((a) => a.startsWith("--save="))?.slice(7);
/** Largest share of checked pixels allowed to show the wrong surface in any view. */
const LIMIT = 0.002;

export async function openHarness({ software, width = 960, height = 640 }) {
  const server = await startAppServer({ readyPath: "/tests/thin-features.html" });
  const url = `${server.origin}/tests/thin-features.html`;
  const profile = await fs.mkdtemp(path.join(os.tmpdir(), "shenzhen-3d-thin-"));
  let page, close;
  if (software) {
    const { chromium } = await import("@playwright/test");
    const browser = await chromium.launch({
      headless: true,
      args: ["--use-gl=angle", "--use-angle=swiftshader", "--enable-unsafe-swiftshader"],
    });
    page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 1 });
    await page.goto(url);
    close = () => browser.close();
  } else {
    const { _electron } = await import("@playwright/test");
    const { createRequire } = await import("node:module");
    const require = createRequire(import.meta.url);
    const { hiddenElectronApp, anyWindowVisible } = require("../electron/hidden-electron.cjs");
    const dist = path.join(root, "artifacts/hidden-electron");
    hiddenElectronApp(path.join(dist, "Electron.app"));
    process.env.ELECTRON_OVERRIDE_DIST_PATH = dist;
    const app = await _electron.launch({
      args: [path.join(root, "tests/thin-features-electron.cjs"), `--user-data-dir=${path.join(profile, "user-data")}`],
      env: {
        ...process.env,
        THIN_FEATURES_URL: url,
        THIN_FEATURES_WIDTH: String(width),
        THIN_FEATURES_HEIGHT: String(height),
      },
    });
    page = await app.firstWindow();
    if (await anyWindowVisible(app)) throw new Error("A test window became visible");
    close = () => app.close();
  }
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  page.on("console", (m) => m.type() === "error" && errors.push(m.text()));
  await page.waitForFunction(() => !!window.thin, null, { timeout: 60_000 });
  return {
    page,
    errors,
    close: async () => {
      await close();
      await server.close();
      await fs.rm(profile, { recursive: true, force: true });
    },
  };
}

/** Views around the marking at (0, 0, 2): name, distance (mm), elevation, azimuth, orbit target. */
export const VIEWS = [
  ["top, very close", 1.5, 90, -90],
  ["top, close", 6, 90, -90],
  ["angled, close", 6, 40, -60],
  ["angled, mid", 25, 40, -60],
  ["angled, far", 120, 40, -60],
  ["grazing, close", 6, 12, -20],
  ["orbit at 0°", 10, 35, 0],
  ["orbit at 90°", 10, 35, 90],
  ["orbit at 180°", 10, 35, 180],
  ["orbit at 270°", 10, 35, 270],
  ["angled, orbit target behind the model", 6, 40, -60, [0, 0, -40]],
];

async function main() {
  const harness = await openHarness({ software });
  const { page } = harness;
  let failed = false;
  try {
    console.log(JSON.stringify(await page.evaluate(() => window.thin.info())));
    if (save) await fs.mkdir(save, { recursive: true });
    for (const proud of [0.01, 0.001]) {
      await page.evaluate((proud) => window.thin.loadFixture({ proud }), proud);
      for (const [name, distance, elevation, azimuth, orbit] of VIEWS) {
        const result = await page.evaluate(
          (v) => {
            window.thin.view(v);
            return window.thin.check();
          },
          { target: [0, 0, 2], distance, elevation, azimuth, orbit },
        );
        const ok = result.fraction <= LIMIT && result.checked > 500;
        failed ||= !ok;
        console.log(
          `${ok ? "ok  " : "FAIL"} ${proud * 1000} µm proud, ${name}: ${(result.fraction * 100).toFixed(2)}% of ${result.checked} pixels wrong ${JSON.stringify(result.wrongBy)} near ${result.near.toPrecision(3)} far ${result.far.toPrecision(3)}`,
        );
        if (save) {
          const png = await page.evaluate(() => window.thin.capture());
          const file = `${proud * 1000}um-${name.replace(/[^a-z0-9]+/gi, "-")}.png`;
          await fs.writeFile(path.join(save, file), Buffer.from(png.split(",")[1], "base64"));
        }
      }
    }
    if (harness.errors.length) throw new Error(harness.errors.join("\n"));
  } finally {
    await harness.close();
  }
  if (failed) {
    console.error("Thin or coplanar features showed the wrong surface.");
    process.exit(1);
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) await main();
