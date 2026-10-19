import fs from "node:fs";
import path from "node:path";
import { chromium } from "@playwright/test";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";

const source = process.argv.includes("--baseline") ? "baseline" : "current";
const outputArg = process.argv.find((arg) => arg.startsWith("--output="));
const output = outputArg?.slice(9) || `artifacts/perf/${source}.json`;
const baselineRef =
  process.argv.find((arg) => arg.startsWith("--baseline-ref="))?.slice(15) ||
  "7937fa8";
const baselineCommit = execFileSync("git", ["rev-parse", baselineRef], {
  encoding: "utf8",
}).trim();
const snapshot = "artifacts/perf/baseline-src";
if (source === "baseline" && !fs.existsSync(`${snapshot}/src/core/viewer.ts`)) {
  fs.mkdirSync(snapshot, { recursive: true });
  const archive = execFileSync(
    "git",
    ["archive", baselineCommit, "src", "vendor"],
    { maxBuffer: 512 * 1024 * 1024 },
  );
  execFileSync("tar", ["-x", "-C", snapshot], { input: archive });
}
const viewerPath =
  source === "baseline"
    ? `${snapshot}/src/core/viewer.ts`
    : "src/core/viewer.ts";
const viewerSha256 = createHash("sha256")
  .update(fs.readFileSync(viewerPath))
  .digest("hex");
if (source === "baseline") {
  const expected = createHash("sha256")
    .update(
      execFileSync("git", ["show", `${baselineCommit}:src/core/viewer.ts`]),
    )
    .digest("hex");
  if (viewerSha256 !== expected)
    throw new Error(
      "Baseline snapshot does not match requested git revision; remove artifacts/perf/baseline-src to regenerate it.",
    );
}
const hardware =
  process.platform === "darwin"
    ? {
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
      }
    : {};
const durationMs = Number(process.env.PERF_DURATION_MS || 8000);
const cases = (process.env.PERF_CASES || "1,10,50,100,unique10").split(",");
const launchArgs = [
  "--use-gl=angle",
  "--use-angle=metal",
  "--disable-background-timer-throttling",
  "--disable-renderer-backgrounding",
  "--disable-backgrounding-occluded-windows",
];
const browser = await chromium.launch({ headless: false, args: launchArgs });
const page = await browser.newPage({
  viewport: { width: 1440, height: 900 },
  deviceScaleFactor: Number(process.env.PERF_DPR || 2),
});
page.on("console", (message) => {
  if (message.type() === "error") console.error(message.text());
});
page.on("pageerror", (error) => console.error(error));
try {
  await page.goto(
    `${process.env.PERF_BASE_URL || "http://127.0.0.1:1420"}/tests/perf/index.html?source=${source}&timer=${process.env.PERF_GPU_TIMER === "0" ? "0" : "1"}`,
  );
  await page.waitForFunction(() => !!window.bench, { timeout: 120000 });
  await page.bringToFront();
  const info = await page.evaluate(() => window.bench.info());
  console.log(JSON.stringify(info, null, 2));
  if (
    !/Apple M5 Max|Apple.*Metal|ANGLE.*Apple/.test(info.renderer) ||
    /SwiftShader|llvmpipe/i.test(info.renderer)
  )
    throw new Error(`Hardware Apple GPU required, got ${info.renderer}`);
  const result = {
    source,
    sourceCommit: source === "baseline" ? baselineCommit : null,
    viewerSha256,
    hardware,
    recordedAt: new Date().toISOString(),
    commit: execFileSync("git", ["rev-parse", "HEAD"], {
      encoding: "utf8",
    }).trim(),
    browserVersion: browser.version(),
    launchArgs,
    ...info,
    model: await page.evaluate(() => window.bench.load()),
    cases: [],
  };
  console.log("Model", result.model);
  for (const scenario of cases) {
    const unique = scenario.startsWith("unique");
    const copies = Number(scenario.replace("unique", ""));
    console.log(`Running ${scenario}`);
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
  await page.screenshot({ path: output.replace(/\.json$/, ".png") });
  console.log(`Saved ${output}`);
} finally {
  await browser.close();
}
