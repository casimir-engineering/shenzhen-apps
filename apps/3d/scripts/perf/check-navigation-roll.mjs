import { chromium, expect } from "@playwright/test";
import fs from "node:fs/promises";

const software = process.argv.includes("--software");
const browser = await chromium.launch({
  headless: software,
  args: [
    "--use-gl=angle",
    software ? "--use-angle=swiftshader" : "--use-angle=metal",
    ...(software ? ["--enable-unsafe-swiftshader"] : []),
  ],
});
const page = await browser.newPage({ viewport: { width: 1000, height: 700 } });
const checks = [],
  errors = [];
const check = (value, label) => {
  expect(value, label).toBe(true);
  checks.push(label);
};
const close = (a, b, tolerance = 1e-6) =>
  a.every((v, i) => Math.abs(v - b[i]) < tolerance);
const state = () =>
  page.evaluate(() => window.measurementNavigation.snapshot());
const settle = () =>
  page.evaluate(
    () =>
      new Promise((resolve) =>
        requestAnimationFrame(() => requestAnimationFrame(resolve)),
      ),
  );
const emit = async (values) => {
  await page.evaluate(
    (values) =>
      window.measurementNavigation.emitRotation({
        degrees: 20,
        clientX: 500,
        clientY: 350,
        epochMs: Date.now(),
        ...values,
      }),
    values,
  );
  await settle();
  return state();
};
const unchanged = (a, b) =>
  close(a.position, b.position) &&
  close(a.target, b.target) &&
  close(a.quaternion, b.quaternion) &&
  Math.abs(a.zoom - b.zoom) < 1e-9;
const drag = async (button) => {
  await page.mouse.move(500, 350);
  await page.mouse.down({ button });
  await page.mouse.move(540, 375, { steps: 4 });
  await page.mouse.up({ button });
  await settle();
  return state();
};
page.on("pageerror", (error) => errors.push(error.message));
page.on("console", (message) => {
  if (message.type() === "error") errors.push(message.text());
});
let renderer;
try {
  await page.goto(
    `${process.env.PERF_BASE_URL || "http://127.0.0.1:1420"}/tests/perf/measurement-navigation.html`,
  );
  await page.waitForFunction(
    () => typeof window.measurementNavigation?.viewer.rollView === "function",
  );
  await page.bringToFront();
  renderer = await page.evaluate(() => {
    const gl = window.measurementNavigation.viewer.renderer.getContext(),
      debug = gl.getExtension("WEBGL_debug_renderer_info");
    return gl.getParameter(debug ? debug.UNMASKED_RENDERER_WEBGL : gl.RENDERER);
  });
  if (!software)
    check(
      /Apple.*Metal|ANGLE.*Apple/i.test(renderer) &&
        !/SwiftShader/.test(renderer),
      "Hardware Apple Metal renderer",
    );
  check(
    (await page.evaluate(() =>
      window.measurementNavigation.rotationSubscribers(),
    )) === 1,
    "Viewer subscribes once to native rotation",
  );
  for (const orthographic of [false, true]) {
    const mode = orthographic ? "orthographic" : "perspective";
    await page.evaluate(
      (orthographic) => window.measurementNavigation.reset(false, orthographic),
      orthographic,
    );
    await settle();
    const initial = await state();
    const projection = await page.evaluate(() => {
      const v = window.measurementNavigation.viewer;
      v.camera.updateMatrixWorld();
      const anchor = v.controls.target
        .clone()
        .addScaledVector(
          v.camera.position
            .clone()
            .setFromMatrixColumn(v.camera.matrixWorld, 0),
          2,
        );
      const before = anchor.clone().project(v.camera).toArray();
      const geometry = [...v.model.geometries.values()][0].geometry;
      const position = geometry.attributes.position.array.slice(),
        index = geometry.index.array.slice();
      v.rollView(30);
      v.camera.updateMatrixWorld();
      return {
        before,
        after: anchor.project(v.camera).toArray(),
        positionStable: position.every(
          (x, i) => x === geometry.attributes.position.array[i],
        ),
        indexStable: index.every((x, i) => x === geometry.index.array[i]),
      };
    });
    await settle();
    const rolled = await state();
    check(
      close(initial.position, rolled.position) &&
        close(initial.target, rolled.target) &&
        Math.abs(initial.distance - rolled.distance) < 1e-6 &&
        initial.zoom === rolled.zoom,
      `${mode}: roll preserves position, target, distance and zoom`,
    );
    check(
      !close(initial.quaternion, rolled.quaternion),
      `${mode}: roll changes camera orientation`,
    );
    check(
      projection.after[1] > projection.before[1] && projection.after[0] > 0,
      `${mode}: positive native CCW angle turns model counterclockwise`,
    );
    check(
      projection.positionStable && projection.indexStable,
      `${mode}: roll leaves source geometry buffers unchanged`,
    );
    await page.evaluate(() =>
      window.measurementNavigation.viewer.rollView(-30),
    );
    await settle();
    check(
      unchanged(initial, await state()),
      `${mode}: opposite roll restores camera`,
    );
    const native = await emit({ degrees: 17 });
    check(
      !close(initial.quaternion, native.quaternion) &&
        close(initial.target, native.target),
      `${mode}: native subscription routes canvas twist`,
    );
    const coalesced = await page.evaluate(async () => {
      const f = window.measurementNavigation,
        before = f.snapshot();
      for (const degrees of [7, -3, -4])
        f.emitRotation({
          degrees,
          clientX: 500,
          clientY: 350,
          epochMs: Date.now(),
        });
      await new Promise((r) =>
        requestAnimationFrame(() => requestAnimationFrame(r)),
      );
      return { before, after: f.snapshot() };
    });
    check(
      unchanged(coalesced.before, coalesced.after),
      `${mode}: same-frame rotation increments sum without drift`,
    );
    const beforePan = await state(),
      afterPan = await drag("middle");
    check(
      close(beforePan.quaternion, afterPan.quaternion) &&
        !close(beforePan.target, afterPan.target) &&
        close(
          afterPan.position.map((v, i) => v - beforePan.position[i]),
          afterPan.target.map((v, i) => v - beforePan.target[i]),
        ),
      `${mode}: pan remains screen-aligned after roll`,
    );
    const beforeOrbit = await state(),
      afterOrbit = await drag("right");
    check(
      close(beforeOrbit.target, afterOrbit.target) &&
        Math.abs(beforeOrbit.distance - afterOrbit.distance) < 1e-6 &&
        !close(beforeOrbit.quaternion, afterOrbit.quaternion),
      `${mode}: right orbit retains panned center after roll`,
    );
    check(
      afterOrbit.picks === 0,
      `${mode}: roll and subsequent navigation do not select`,
    );
    const preset = await page.evaluate(() => {
      const f = window.measurementNavigation;
      f.viewer.preset("iso");
      return f.snapshot();
    });
    check(
      close(preset.quaternion, initial.quaternion) &&
        close(preset.up, initial.up) &&
        close(preset.target, afterOrbit.target),
      `${mode}: isometric preset clears roll while retaining view center`,
    );
  }
  await page.evaluate(() => window.measurementNavigation.reset());
  await settle();
  for (const values of [
    { clientX: -1 },
    { clientX: 1001 },
    { clientY: -1 },
    { clientY: 701 },
    { degrees: 0 },
    { degrees: 181 },
    { degrees: NaN },
    { degrees: Infinity },
  ]) {
    const before = await state();
    check(
      unchanged(before, await emit(values)),
      "Out-of-bounds or invalid native twist leaves camera unchanged",
    );
  }
  await page.evaluate(() => {
    const b = document.createElement("button");
    b.id = "roll-ui";
    b.textContent = "Overlay control";
    Object.assign(b.style, {
      position: "absolute",
      left: "460px",
      top: "330px",
      width: "100px",
      height: "40px",
      zIndex: "10",
    });
    document.querySelector("#viewer").append(b);
  });
  const overlayBefore = await state();
  check(
    unchanged(overlayBefore, await emit({})),
    "Native twist over clickable overlay does not move viewport",
  );
  await page
    .locator("#roll-ui")
    .evaluate((node) => (node.style.pointerEvents = "none"));
  check(
    !unchanged(overlayBefore, await emit({})),
    "Pointer-transparent overlay does not intercept canvas twist",
  );
  await page.locator("#roll-ui").evaluate((node) => node.remove());
  await page.mouse.move(500, 350);
  await page.mouse.down({ button: "middle" });
  const pressed = await state();
  check(
    unchanged(pressed, await emit({})),
    "Native twist during pointer drag is ignored",
  );
  await page.mouse.up({ button: "middle" });
  const disposed = await state();
  await page.evaluate(() => window.measurementNavigation.viewer.dispose());
  check(
    (await page.evaluate(() =>
      window.measurementNavigation.rotationSubscribers(),
    )) === 0,
    "Viewer disposal unsubscribes native rotation",
  );
  check(
    unchanged(disposed, await emit({})),
    "Disposed Viewer ignores later native rotation",
  );
  check(errors.length === 0, "No browser or graphics errors");
  await fs.mkdir("artifacts/perf", { recursive: true });
  await fs.writeFile(
    "artifacts/perf/navigation-roll.json",
    JSON.stringify(
      {
        date: new Date().toISOString(),
        renderer,
        checks,
        errors,
        scope:
          "Mock native subscription and direct camera API; no physical trackpad event claim",
      },
      null,
      2,
    ) + "\n",
  );
  console.log(
    JSON.stringify({ passed: true, checks: checks.length, renderer }),
  );
} finally {
  await browser.close();
}
