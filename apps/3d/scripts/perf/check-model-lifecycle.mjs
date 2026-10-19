import { chromium } from "@playwright/test";
import fs from "node:fs/promises";

const software = process.argv.includes("--software");
const diagnostic = process.argv.includes("--diagnostic");
const userFixtures = process.argv.includes("--user-fixtures");
const output = "artifacts/perf/model-lifecycle";
await fs.mkdir(output, { recursive: true });
const browser = await chromium.launch({
  headless: software,
  args: [
    "--use-gl=angle",
    software ? "--use-angle=swiftshader" : "--use-angle=metal",
    ...(software ? ["--enable-unsafe-swiftshader"] : []),
  ],
});
const page = await browser.newPage({
  viewport: { width: 1200, height: 800 },
  deviceScaleFactor: 1,
});
const errors = [],
  stages = [];
page.on("pageerror", (e) => errors.push(e.message));
page.on("console", (m) => {
  if (m.type() === "error") errors.push(m.text());
});
try {
  await page.goto(
    `${process.env.PERF_BASE_URL || "http://127.0.0.1:1420"}/tests/perf/model-lifecycle.html`,
  );
  await page.waitForFunction(() => !!window.modelLifecycle);
  const renderer = await page.evaluate(() => {
    const gl = window.modelLifecycle.viewer.renderer.getContext();
    return gl.getParameter(
      gl.getExtension("WEBGL_debug_renderer_info").UNMASKED_RENDERER_WEBGL,
    );
  });
  if (!software && !/Apple.*Metal|ANGLE.*Apple/i.test(renderer))
    throw Error(`Unexpected renderer: ${renderer}`);
  const step = userFixtures
    ? "/artifacts/perf/lifecycle-fixtures/sample-assembly-large.step"
    : "/fixtures/sample-assembly.step";
  const dxf = userFixtures
    ? "/artifacts/perf/lifecycle-fixtures/sample-flat.dxf"
    : "/tests/fixtures/drawing/engineering.dxf";
  const load = async (url, name, label) => {
    const state = await page.evaluate(
      ({ url, name }) => window.modelLifecycle.load(url, name),
      { url, name },
    );
    stages.push({ label, ...state });
    if (state.contextLost || state.glError)
      throw Error(`GPU error at ${label}`);
    await page.screenshot({ path: `${output}/${label}.png` });
    return state;
  };
  const initial = await load(step, "sample-assembly.step", "initial-step");
  for (let i = 1; i <= 3; i++) {
    await load(dxf, "drawing.dxf", `drawing-${i}`);
    const state = await load(step, "sample-assembly.step", `step-after-drawing-${i}`);
    if (
      state.parts !== initial.parts ||
      state.geometries !== initial.geometries ||
      state.triangles !== initial.triangles
    )
      throw Error("Model geometry changed across replacement");
    const reference = await page.evaluate(() =>
      window.modelLifecycle.depthReference(),
    );
    stages.push({ label: `depth-reference-${i}`, ...reference });
    await page.screenshot({ path: `${output}/depth-reference-${i}.png` });
    if (!diagnostic && reference.difference.changed !== 0)
      throw Error(
        `Projection transition loses depth precision: ${JSON.stringify(reference)}`,
      );
    const cleared = await page.evaluate(() => window.modelLifecycle.clear());
    stages.push({ label: `clear-${i}`, ...cleared });
  }
  if (errors.length) throw Error(`Browser errors: ${JSON.stringify(errors)}`);
  await fs.writeFile(
    `${output}/report.json`,
    JSON.stringify(
      { renderer, userFixtures, diagnostic, stages, errors },
      null,
      2,
    ),
  );
  console.log(
    JSON.stringify(
      {
        renderer,
        userFixtures,
        stages: stages.length,
        depthDifferences: stages
          .filter((s) => s.difference)
          .map((s) => s.difference),
        errors,
      },
      null,
      2,
    ),
  );
} catch (error) {
  await fs.writeFile(
    `${output}/failure.json`,
    JSON.stringify({ message: error.message, stages, errors }, null, 2),
  );
  throw error;
} finally {
  await browser.close();
}
