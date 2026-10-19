import fs from "node:fs";
import path from "node:path";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { _electron } from "@playwright/test";

async function bounded(promise, milliseconds, message) {
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error(message)), milliseconds);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

const output =
  process.argv.find((arg) => arg.startsWith("--output="))?.slice(9) ||
  "artifacts/perf/electron-current.json";
const scenarios = (process.env.PERF_CASES || "1,100,unique10").split(",");
const durationMs = Number(process.env.PERF_DURATION_MS || 8000);
const launchArgs = ["electron/main.cjs"];
const app = await _electron.launch({
  args: launchArgs,
  env: {
    ...process.env,
    SHENZHEN_3D_DEV_URL: `http://127.0.0.1:1420/tests/perf/index.html?source=current&timer=${process.env.PERF_GPU_TIMER === "0" ? "0" : "1"}`,
  },
});
try {
  const page = await app.firstWindow();
  page.on("pageerror", (error) => console.error(error));
  await app.evaluate(({ app, BrowserWindow }) => {
    const window = BrowserWindow.getAllWindows()[0];
    window.setContentSize(1440, 900);
    window.show();
    window.focus();
    app.focus({ steal: true });
  });
  await page.bringToFront();
  try {
    await page.waitForFunction(() => !!window.bench, null, {
      timeout: 15000,
      polling: 100,
    });
  } catch {
    await page.reload({ waitUntil: "commit" });
    await page.waitForFunction(() => !!window.bench, null, {
      timeout: 15000,
      polling: 100,
    });
  }
  console.log(
    "Electron benchmark module ready",
    page.url(),
    await app.evaluate(({ app, BrowserWindow }) => ({
      hidden: app.isHidden(),
      windows: BrowserWindow.getAllWindows().map((window) => ({
        visible: window.isVisible(),
        focused: window.isFocused(),
        minimized: window.isMinimized(),
      })),
    })),
  );
  const info = await bounded(
    page.evaluate(() => window.bench.info()),
    10000,
    "Electron rAF capability sampling timed out",
  );
  console.log("Electron GPU and rAF", JSON.stringify(info));
  console.log("Loading sample STEP…");
  const model = await bounded(
    page.evaluate(() => window.bench.load()),
    45000,
    "Electron CAD import timed out",
  );
  console.log("Electron CAD model ready", JSON.stringify(model));
  if (process.env.PERF_READY_ONLY === "1") process.exitCode = 0;
  const versions = await app.evaluate(() => process.versions);
  const result = {
    engine: "actual Electron desktop shell, development benchmark URL",
    source: "current",
    recordedAt: new Date().toISOString(),
    commit: execFileSync("git", ["rev-parse", "HEAD"], {
      encoding: "utf8",
    }).trim(),
    shellSha256: createHash("sha256")
      .update(fs.readFileSync("electron/main.cjs"))
      .digest("hex"),
    viewerSha256: createHash("sha256")
      .update(fs.readFileSync("src/core/viewer.ts"))
      .digest("hex"),
    versions,
    launchArgs,
    hardware: {
      macOS: execFileSync("sw_vers", ["-productVersion"], {
        encoding: "utf8",
      }).trim(),
      cpu: execFileSync("sysctl", ["-n", "machdep.cpu.brand_string"], {
        encoding: "utf8",
      }).trim(),
      memoryBytes: Number(
        execFileSync("sysctl", ["-n", "hw.memsize"], {
          encoding: "utf8",
        }).trim(),
      ),
    },
    ...info,
    model,
    cases: [],
  };
  console.log(
    JSON.stringify({ ...info, versions, model: result.model }, null, 2),
  );
  for (const scenario of process.env.PERF_READY_ONLY === "1" ? [] : scenarios) {
    console.log(`Running Electron ${scenario}`);
    const unique = scenario.startsWith("unique"),
      copies = Number(scenario.replace("unique", ""));
    result.cases.push(
      await page.evaluate((options) => window.bench.run(options), {
        copies,
        unique,
        durationMs,
        edges: process.env.PERF_EDGES === "1",
      }),
    );
    fs.mkdirSync(path.dirname(output), { recursive: true });
    fs.writeFileSync(output, JSON.stringify(result, null, 2) + "\n");
    console.log(JSON.stringify(result.cases.at(-1)));
  }
  if (process.env.PERF_READY_ONLY !== "1")
    await page.screenshot({ path: output.replace(/\.json$/, ".png") });
  console.log(
    process.env.PERF_READY_ONLY === "1"
      ? "Electron readiness probe complete"
      : `Saved ${output}`,
  );
} finally {
  await app.close();
}
