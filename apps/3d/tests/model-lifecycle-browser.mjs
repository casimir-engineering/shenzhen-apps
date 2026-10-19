import { chromium, expect } from "@playwright/test";
import fs from "node:fs/promises";
import path from "node:path";
import os from "node:os";

const software = process.argv.includes("--software");
const userFixtures = process.argv.includes("--user-fixtures");
const output = "artifacts/perf/model-lifecycle-app";
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
  viewport: { width: 1440, height: 1000 },
  deviceScaleFactor: 1,
});
const errors = [],
  stages = [];
page.on("pageerror", (e) => errors.push(e.message));
page.on("console", (m) => {
  if (m.type() === "error") errors.push(m.text());
});
try {
  await page.goto(process.env.PERF_BASE_URL || "http://127.0.0.1:1420");
  await expect(
    page.getByRole("button", { name: "Sample model", exact: true }),
  ).toBeVisible();
  // Observe the actual instance created by App, without replacing its controls,
  // import lifecycle, effects, materials, or renderer.
  await page.evaluate(async () => {
    const { Viewer } = await import("/src/core/model-runtime.ts");
    const setModel = Viewer.prototype.setModel;
    Viewer.prototype.setModel = function (doc) {
      window.lifecycleViewer = this;
      return setModel.call(this, doc);
    };
  });
  const snapshot = () =>
    page.evaluate(() => {
      const v = window.lifecycleViewer,
        gl = v.renderer.getContext();
      return {
        name: v.model.name,
        parts: v.model.parts.length,
        geometries: v.model.geometries.size,
        triangles: [...v.model.geometries.values()].reduce(
          (n, g) =>
            n +
            (g.lines
              ? 0
              : (g.geometry.index?.count ??
                  g.geometry.attributes.position.count) / 3),
          0,
        ),
        near: v.camera.near,
        far: v.camera.far,
        distance: v.camera.position.distanceTo(v.controls.target),
        perspective: !!v.camera.isPerspectiveCamera,
        memory: { ...v.renderer.info.memory },
        contextLost: gl.isContextLost(),
        glError: gl.getError(),
        renderer: gl.getParameter(
          gl.getExtension("WEBGL_debug_renderer_info").UNMASKED_RENDERER_WEBGL,
        ),
        materialClipping: [...v.materials].some(
          (m) => m.clippingPlanes?.length,
        ),
      };
    });
  const step = userFixtures
    ? path.join(os.homedir(), "Downloads", "sample-assembly-large.step")
    : "fixtures/sample-assembly.step";
  const dxf = userFixtures
    ? path.join(os.homedir(), "Downloads", "sample-flat.dxf")
    : "tests/fixtures/drawing/engineering.dxf";
  const load = async (filename, label) => {
    await page.locator("input[type=file]").setInputFiles(filename);
    await expect(page.locator(".model-badge")).toContainText(
      filename === step ? "CAD model" : "2D drawing",
      { timeout: 120000 },
    );
    await expect(page.locator(".loading-overlay")).toHaveCount(0);
    await page.evaluate(
      () =>
        new Promise((resolve) =>
          requestAnimationFrame(() => requestAnimationFrame(resolve)),
        ),
    );
    const state = await snapshot();
    stages.push({ label, ...state });
    expect(state.contextLost).toBe(false);
    expect(state.glError).toBe(0);
    expect(state.materialClipping).toBe(false);
    if (!software) expect(state.renderer).toMatch(/Apple.*Metal|ANGLE.*Apple/i);
    if (filename === step) {
      expect(state.perspective).toBe(true);
      expect(state.near).toBeGreaterThanOrEqual(state.distance / 10001);
      expect(state.parts).toBe(3154);
      expect(state.geometries).toBe(16);
    } else expect(state.perspective).toBe(false);
    await expect(page.getByRole("alert")).toHaveCount(0);
    await page.screenshot({ path: `${output}/${label}.png` });
    return state;
  };
  const initial = await load(step, "initial-step");
  for (let i = 1; i <= 3; i++) {
    await load(dxf, `drawing-${i}`);
    const repeated = await load(step, `step-after-drawing-${i}`);
    expect(repeated.triangles).toBe(initial.triangles);
    // Closing disposes the renderer; opening again also exercises recreation.
    await page
      .getByRole("button", { name: "Close document", exact: true })
      .click();
    await expect(page.locator(".viewport-canvas canvas")).toHaveCount(0);
    await expect(
      page.getByRole("button", { name: "Sample model", exact: true }),
    ).toBeVisible();
  }
  expect(errors).toEqual([]);
  await fs.writeFile(
    `${output}/report.json`,
    JSON.stringify({ userFixtures, software, stages, errors }, null, 2),
  );
  console.log(
    JSON.stringify(
      {
        renderer: initial.renderer,
        stages: stages.length,
        errors,
        report: `${output}/report.json`,
      },
      null,
      2,
    ),
  );
} catch (error) {
  await page.screenshot({ path: `${output}/failure.png` }).catch(() => {});
  await fs.writeFile(
    `${output}/failure.json`,
    JSON.stringify({ message: error.message, stages, errors }, null, 2),
  );
  throw error;
} finally {
  await browser.close();
}
