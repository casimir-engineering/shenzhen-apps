import { chromium, expect } from "@playwright/test";
import fs from "node:fs/promises";
import {
  fixedBindings,
  modifiers,
  discreteWheelCases,
  precisionWheelCases,
} from "../../tests/perf/navigation-reference-cases.mjs";
const software = process.argv.includes("--software");
const browser = await chromium.launch({
  headless: software,
  args: [
    "--use-gl=angle",
    software ? "--use-angle=swiftshader" : "--use-angle=metal",
    ...(software ? ["--enable-unsafe-swiftshader"] : []),
  ],
});
const page = await browser.newPage({
  viewport: { width: 1000, height: 700 },
  deviceScaleFactor: 1,
  hasTouch: true,
});
const checks = [],
  errors = [],
  wheelResponses = [],
  bindingResults = [],
  touchResults = [];
let renderer;
const check = (condition, name) => {
  expect(condition, name).toBe(true);
  checks.push(name);
};
page.on("pageerror", (error) => errors.push(error.message));
page.on("console", (message) => {
  if (message.type() === "error") errors.push(message.text());
});
const state = () =>
  page.evaluate(() => window.measurementNavigation.snapshot());
const close = (a, b, tolerance = 1e-6) =>
  a.length === b.length &&
  a.every((value, index) => Math.abs(value - b[index]) < tolerance);
const settle = () =>
  page.evaluate(
    () =>
      new Promise((resolve) =>
        requestAnimationFrame(() => requestAnimationFrame(resolve)),
      ),
  );
const reset = async (is2D = false, orthographic = false, options = {}) => {
  const initial = await page.evaluate(
    ({ is2D, orthographic, options }) =>
      window.measurementNavigation.reset(is2D, orthographic, options),
    { is2D, orthographic, options },
  );
  await settle();
  return initial;
};
const zoomChange = (before, after) =>
  Math.log(after.zoom / before.zoom) -
  Math.log(after.distance / before.distance);
const assertAction = (before, after, action, name) => {
  const scaled = Math.abs(zoomChange(before, after)) > 1e-6;
  if (action === "orbit")
    check(
      !close(after.quaternion, before.quaternion) &&
        close(after.target, before.target) &&
        !scaled,
      `${name}: orbits about the unchanged target`,
    );
  if (action === "pan") {
    const cameraTranslation = after.position.map(
      (value, index) => value - before.position[index],
    );
    const targetTranslation = after.target.map(
      (value, index) => value - before.target[index],
    );
    check(
      close(after.quaternion, before.quaternion) &&
        !scaled &&
        Math.hypot(...cameraTranslation) > 1e-6 &&
        close(cameraTranslation, targetTranslation),
      `${name}: translates camera and target together without rotation or zoom`,
    );
  }
  if (action === "zoom")
    check(
      scaled && close(after.quaternion, before.quaternion),
      `${name}: changes scale without rotation`,
    );
  if (action === "none")
    check(
      close(after.position, before.position) &&
        close(after.target, before.target) &&
        close(after.quaternion, before.quaternion) &&
        !scaled,
      `${name}: leaves the camera unchanged`,
    );
  check(after.picks === before.picks, `${name}: does not select geometry`);
};
const drag = async (
  button,
  keys = [],
  { dx = 60, dy = 35, releaseAfterPress = false, pressAfterDown = [] } = {},
) => {
  await page.evaluate(() => {
    if (window.__contextMenus) return;
    window.__contextMenus = [];
    window.addEventListener("contextmenu", (e) =>
      window.__contextMenus.push(e.defaultPrevented),
    );
  });
  await page.mouse.move(500, 350);
  for (const key of keys) await page.keyboard.down(key);
  await page.mouse.down({ button });
  try {
    if (releaseAfterPress)
      for (const key of [...keys].reverse()) await page.keyboard.up(key);
    for (const key of pressAfterDown) await page.keyboard.down(key);
    await page.mouse.move(500 + dx, 350 + dy, { steps: 4 });
  } finally {
    await page.mouse.up({ button });
    for (const key of [...new Set([...keys, ...pressAfterDown])].reverse())
      await page.keyboard.up(key);
  }
  await settle();
  // A right or Ctrl+click drag must never open the browser's context menu.
  const menus = await page.evaluate(() => {
    const seen = window.__contextMenus || [];
    window.__contextMenus = [];
    return seen;
  });
  check(
    menus.every(Boolean),
    `${button}+${keys.join("+") || "plain"} drag: context menu is suppressed`,
  );
  return state();
};
const wheel = async (event) => {
  await page.evaluate((values) => {
    const { wheelDeltaX, wheelDeltaY, momentum, ...init } = values;
    const event = new WheelEvent("wheel", {
      bubbles: true,
      cancelable: true,
      clientX: 500,
      clientY: 350,
      ...init,
    });
    for (const [name, value] of Object.entries({
      wheelDeltaX,
      wheelDeltaY,
      momentum,
    }))
      if (value !== undefined) Object.defineProperty(event, name, { value });
    document.querySelector("canvas").dispatchEvent(event);
  }, event);
  await settle();
  return state();
};
try {
  await page.goto(
    `${process.env.PERF_BASE_URL || "http://127.0.0.1:1420"}/tests/perf/measurement-navigation.html`,
  );
  await page.waitForFunction(() => !!window.measurementNavigation);
  await page.reload({ waitUntil: "networkidle" });
  await page.waitForFunction(() => !!window.measurementNavigation);
  await page.bringToFront();
  renderer = await page.evaluate(() => {
    const gl = window.measurementNavigation.viewer.renderer.getContext(),
      debug = gl.getExtension("WEBGL_debug_renderer_info");
    return gl.getParameter(debug ? debug.UNMASKED_RENDERER_WEBGL : gl.RENDERER);
  });
  if (!software)
    check(
      /Apple.*Metal|ANGLE.*Apple/i.test(renderer) &&
        !/SwiftShader/i.test(renderer),
      "Actual Apple hardware renderer",
    );
  for (const is2D of [false, true])
    for (const orthographic of [false, true]) {
      const mode = `${is2D ? "2D" : "3D"} ${orthographic ? "orthographic" : "perspective"}`;
      for (const binding of fixedBindings) {
        const initial = await reset(is2D, orthographic);
        for (const keys of modifiers) {
          await page.evaluate(
            (initial) => window.measurementNavigation.restore(initial),
            initial,
          );
          // Command or Ctrl held when a right drag starts turns it into a pan.
          const wanted =
            binding.button === "right" &&
            (keys.includes("Control") || keys.includes("Meta"))
              ? "pan"
              : binding.action;
          const action = is2D && wanted === "orbit" ? "pan" : wanted;
          const after = await drag(binding.button, keys);
          const name = `${mode} ${keys.join("+") || "plain"}+${binding.button}`;
          assertAction(initial, after, action, name);
          bindingResults.push({
            mode,
            button: binding.button,
            modifiers: keys,
            expected: action,
          });
        }
      }
      for (const legacy of ["auto", "mouse", "trackpad"]) {
        for (const event of discreteWheelCases) {
          const initial = await reset(is2D, orthographic, {
            navigation: legacy,
          });
          const after = await wheel(event),
            amount = zoomChange(initial, after);
          check(
            Number.isFinite(amount) &&
              Math.abs(amount) > 1e-9 &&
              Math.sign(amount) === -Math.sign(event.deltaY),
            `${mode} saved=${legacy} discrete tick ${event.deltaY}/${event.deltaMode}: zooms`,
          );
          check(
            close(initial.quaternion, after.quaternion) &&
              close(initial.target, after.target) &&
              after.picks === 0,
            `${mode} discrete wheel never pans, rotates or selects`,
          );
          wheelResponses.push({
            mode,
            legacy,
            source: "browser-discrete",
            ...event,
            amount,
          });
        }
        for (const event of precisionWheelCases) {
          const initial = await reset(is2D, orthographic, {
            navigation: legacy,
          });
          const after = await wheel(event);
          assertAction(
            initial,
            after,
            event.deltaY === 0 ? "none" : "zoom",
            `${mode} saved=${legacy} precision/momentum ${event.deltaX}/${event.deltaY}: zooms (vertical only)`,
          );
          if (event.deltaY !== 0)
            check(
              Math.sign(zoomChange(initial, after)) ===
                -Math.sign(event.deltaY),
              `${mode}: swipe zoom direction follows the wheel`,
            );
          wheelResponses.push({
            mode,
            legacy,
            source: "browser-precision",
            ...event,
            amount: zoomChange(initial, after),
          });
          for (const key of ["metaKey", "ctrlKey"]) {
            await page.evaluate(
              (initial) => window.measurementNavigation.restore(initial),
              initial,
            );
            if (key === "ctrlKey") await page.keyboard.down("Control");
            const held = await wheel({ ...event, [key]: true });
            if (key === "ctrlKey") await page.keyboard.up("Control");
            // A held swipe ends once its inertia has stopped.
            await page.waitForTimeout(150);
            assertAction(
              initial,
              held,
              "pan",
              `${mode} saved=${legacy} ${key} + precision ${event.deltaX}/${event.deltaY}: pans`,
            );
          }
        }
        for (const deltaY of [-2, 2]) {
          const initial = await reset(is2D, orthographic, {
            navigation: legacy,
          });
          const after = await wheel({
            deltaX: 0,
            deltaY,
            deltaMode: 0,
            ctrlKey: true,
          });
          assertAction(
            initial,
            after,
            "zoom",
            `${mode} saved=${legacy} Ctrl pinch`,
          );
          check(
            Math.sign(zoomChange(initial, after)) === -Math.sign(deltaY),
            `${mode}: pinch direction is preserved`,
          );
        }
      }
      const initial = await reset(is2D, orthographic);
      const left = await drag("left");
      assertAction(initial, left, "pan", `${mode} left drag`);
      await page.evaluate(
        (initial) => window.measurementNavigation.restore(initial),
        initial,
      );
      const middle = await drag("middle");
      check(
        close(left.position, middle.position) &&
          close(left.target, middle.target) &&
          close(left.quaternion, middle.quaternion),
        `${mode}: identical left and middle drags produce the same pan`,
      );
      const rightAfterPan = await drag("right");
      assertAction(
        middle,
        rightAfterPan,
        is2D ? "pan" : "orbit",
        `${mode}: right drag after panning`,
      );
      if (!is2D) {
        check(
          !close(initial.target, middle.target) &&
            close(rightAfterPan.target, middle.target) &&
            Math.abs(rightAfterPan.distance - middle.distance) < 1e-6,
          `${mode}: right orbit keeps the panned view center and camera distance, without snapping to the object`,
        );
      }
    }
  // Genuine browser wheel delivery supplements the deterministic DOM delta matrix.
  for (const orthographic of [false, true]) {
    const initial = await reset(false, orthographic);
    await page.mouse.move(500, 350);
    await page.mouse.wheel(14.5, 22.5);
    await settle();
    const after = await state();
    check(
      zoomChange(initial, after) < 0 && close(initial.target, after.target),
      "Actual fractional mixed-axis browser wheel zooms instead of panning",
    );
    const trackpad = await reset(false, orthographic);
    const swiped = await wheel({
        deltaX: -8.5,
        deltaY: -18.5,
        deltaMode: 0,
        wheelDeltaX: 25.5,
        wheelDeltaY: 55.5,
      }),
      event = await page.evaluate(() =>
        window.measurementNavigation.wheelSample(),
      );
    assertAction(
      trackpad,
      swiped,
      "zoom",
      "Precision DOM wheel sample zooms without panning",
    );
    await page.evaluate(
      (initial) => window.measurementNavigation.restore(initial),
      trackpad,
    );
    const swipedPan = await wheel({
      deltaX: -8.5,
      deltaY: -18.5,
      deltaMode: 0,
      wheelDeltaX: 25.5,
      wheelDeltaY: 55.5,
      metaKey: true,
    });
    await page.waitForTimeout(150);
    await page.evaluate(
      (initial) => window.measurementNavigation.restore(initial),
      trackpad,
    );
    const middle = await drag("middle", [], {
      dx: -event.deltaX,
      dy: -event.deltaY,
    });
    check(
      close(middle.position, swipedPan.position) &&
        close(middle.target, swipedPan.target),
      "Middle-button pan matches oppositely signed precision scrolling",
    );
    const horizontal = await reset(false, orthographic, {
      navigation: "mouse",
    });
    assertAction(
      horizontal,
      await wheel({
        deltaX: 37.5,
        deltaY: 0,
        deltaMode: 0,
        wheelDeltaX: -120,
        wheelDeltaY: 0,
      }),
      "none",
      "Pure horizontal mouse wheel does not become trackpad pan",
    );
  }
  for (const scenario of [
    {
      button: "right",
      keys: ["Shift"],
      releaseAfterPress: true,
      expected: "orbit",
    },
    {
      button: "middle",
      keys: ["Control"],
      releaseAfterPress: true,
      expected: "pan",
    },
    {
      button: "left",
      keys: ["Meta"],
      releaseAfterPress: true,
      expected: "pan",
    },
    {
      button: "right",
      keys: [],
      pressAfterDown: ["Shift", "Control", "Meta"],
      expected: "orbit",
    },
    {
      button: "right",
      keys: ["Meta"],
      releaseAfterPress: true,
      expected: "pan",
    },
    {
      button: "right",
      keys: ["Control"],
      releaseAfterPress: true,
      expected: "pan",
    },
  ]) {
    const initial = await reset(false, false);
    const after = await drag(scenario.button, scenario.keys, scenario);
    assertAction(
      initial,
      after,
      scenario.expected,
      `${scenario.button}: modifier changes during a drag do not change the action`,
    );
  }
  for (const is2D of [false, true])
    for (const orthographic of [false, true]) {
      await reset(is2D, orthographic);
      for (const item of [
        { event: precisionWheelCases[2], action: "zoom" },
        { event: discreteWheelCases[1], action: "zoom" },
        { event: precisionWheelCases[10], action: "none" },
        {
          event: { deltaX: 0, deltaY: -2, deltaMode: 0, ctrlKey: true },
          action: "zoom",
        },
        { event: discreteWheelCases[4], action: "zoom" },
        { event: precisionWheelCases[11], action: "zoom" },
      ]) {
        const before = await state();
        const after = await wheel(item.event);
        assertAction(
          before,
          after,
          item.action,
          `${is2D ? "2D" : "3D"} ${orthographic ? "ortho" : "perspective"}: switching wheel, swipe and pinch without resetting the camera`,
        );
      }
    }
  // Projection recreation and model replacement must retain fixed controls.
  await reset(false, false);
  const projected = await page.evaluate(() => {
    const f = window.measurementNavigation;
    f.viewer.setProjection(true);
    return f.snapshot();
  });
  assertAction(
    projected,
    await drag("middle"),
    "pan",
    "Projection recreation retains middle-button pan",
  );
  const wheelBefore = await state(),
    wheelAfter = await wheel({
      deltaY: 120,
      deltaX: 0,
      deltaMode: 0,
      wheelDeltaY: -120,
    });
  check(
    zoomChange(wheelBefore, wheelAfter) < 0,
    "Projection recreation retains discrete-wheel zoom",
  );
  const twoD = await page.evaluate(() =>
    window.measurementNavigation.replaceModel(true),
  );
  assertAction(
    twoD,
    await drag("right"),
    "pan",
    "2D replacement locks right drag to pan",
  );
  const threeD = await page.evaluate(() =>
    window.measurementNavigation.replaceModel(false),
  );
  assertAction(
    threeD,
    await drag("right"),
    "orbit",
    "3D replacement restores right-button orbit",
  );
  const cdp = await page.context().newCDPSession(page);
  const touch = async (start, end, type = "pan") => {
    const points = (values) =>
      values.map(([x, y], id) => ({
        x,
        y,
        id,
        radiusX: 1,
        radiusY: 1,
        force: 1,
      }));
    await cdp.send("Input.dispatchTouchEvent", {
      type: "touchStart",
      touchPoints: points(start),
    });
    for (let step = 1; step <= 8; step++)
      await cdp.send("Input.dispatchTouchEvent", {
        type: "touchMove",
        touchPoints: points(
          start.map((p, index) =>
            p.map((v, axis) => v + ((end[index][axis] - v) * step) / 8),
          ),
        ),
      });
    await cdp.send("Input.dispatchTouchEvent", {
      type: type === "cancel" ? "touchCancel" : "touchEnd",
      touchPoints: [],
    });
    await page.waitForTimeout(150);
    await settle();
    return state();
  };
  for (const is2D of [false, true])
    for (const orthographic of [false, true]) {
      const mode = `${is2D ? "2D" : "3D"} ${orthographic ? "orthographic" : "perspective"}`;
      const initial = await reset(is2D, orthographic),
        panned = await touch(
          [
            [470, 350],
            [530, 350],
          ],
          [
            [505, 370],
            [565, 370],
          ],
        );
      assertAction(
        initial,
        panned,
        "pan",
        `${mode}: actual two-finger touch pan`,
      );
      const pinchBefore = await reset(is2D, orthographic),
        pinched = await touch(
          [
            [450, 350],
            [550, 350],
          ],
          [
            [410, 350],
            [590, 350],
          ],
        );
      assertAction(
        pinchBefore,
        pinched,
        "zoom",
        `${mode}: actual two-finger touch pinch`,
      );
      check(
        zoomChange(pinchBefore, pinched) > 0,
        `${mode}: spreading touch fingers zooms in`,
      );
      touchResults.push({
        mode,
        panPicks: panned.picks,
        pinchPicks: pinched.picks,
      });
    }
  const canceled = await reset();
  assertAction(
    canceled,
    await touch(
      [
        [470, 350],
        [530, 350],
      ],
      [
        [500, 370],
        [560, 370],
      ],
      "cancel",
    ),
    "pan",
    "Canceled two-finger navigation does not select",
  );
  await cdp.detach();
  await reset();
  await page.mouse.move(500, 350);
  await page.mouse.down();
  await page.mouse.move(550, 350, { steps: 3 });
  await page.mouse.move(500, 350, { steps: 3 });
  await page.mouse.up();
  check(
    (await state()).picks === 0,
    "Drag returning to its starting position does not create a selection",
  );
  await page.mouse.click(500, 350);
  check(
    (await state()).picks === 1,
    "Ordinary surface click still selects after touch cancellation and camera resets",
  );
  const overlay = await page.evaluate(async () => {
    const v = window.measurementNavigation.viewer;
    v.setOverlay({
      points: [
        [0, 0, 0],
        [4, -3, 2],
      ],
      path: [
        [0, 0, 0],
        [4, -3, 2],
      ],
      text: "5.385 mm",
      axisTexts: ["ΔX 4 mm", "ΔY −3 mm", "ΔZ 2 mm"],
    });
    await new Promise((r) => requestAnimationFrame(r));
    return [...v.overlay.children]
      .filter((o) => o.name.startsWith("measurement-axis"))
      .map((o) => ({
        name: o.name,
        vertices: [...o.geometry.attributes.position.array],
        color: o.material.color.getHexString(),
        dashed: o.material.isLineDashedMaterial,
        depthTest: o.material.depthTest,
      }));
  });
  check(
    overlay.length === 3 &&
      overlay.every((line) => line.dashed && !line.depthTest),
    "Three independent dashed components remain readable over geometry",
  );
  check(
    overlay.map((line) => line.color).join(",") === "ff7373,45db8d,63aaff",
    "Dark-scene axis lines use legible saturated red/green/blue",
  );
  expect(overlay.map((line) => line.vertices)).toEqual([
    [0, 0, 0, 4, 0, 0],
    [4, 0, 0, 4, -3, 0],
    [4, -3, 0, 4, -3, 2],
  ]);
  checks.push("Exact connector receives signed XYZ orthogonal route");
  for (const [axis, text] of [
    ["x", "ΔX 4 mm"],
    ["y", "ΔY −3 mm"],
    ["z", "ΔZ 2 mm"],
  ])
    await expect(
      page.locator(`.dimension-axis-label[data-axis=${axis}]`),
    ).toHaveText(text);
  await expect(page.locator(".dimension-axis-label:not([hidden])")).toHaveCount(
    3,
  );
  const placements = await page.evaluate(() => {
    const v = window.measurementNavigation.viewer;
    return v.axisLabels.map((label, index) => {
      const p = v.axisMidpoints[index].clone().project(v.camera),
        anchor = v.labelLayout[index + 1];
      return (
        Math.abs(anchor.anchorX - (p.x * 0.5 + 0.5) * 1000) < 0.01 &&
        Math.abs(anchor.anchorY - (-p.y * 0.5 + 0.5) * 700) < 0.01
      );
    });
  });
  check(
    placements.every(Boolean),
    "Each axis label retains its projected segment midpoint anchor",
  );
  await drag("middle", ["Shift"]);
  await wheel({ deltaX: 0, deltaY: -7, deltaMode: 0, ctrlKey: true });
  const navigatedAxes = await page.evaluate(() => {
    const v = window.measurementNavigation.viewer;
    return {
      routes: v.axisLines.map((line) => [
        ...line.geometry.attributes.position.array,
      ]),
      anchors: v.axisMidpoints.map((midpoint, index) => {
        const p = midpoint.clone().project(v.camera),
          anchor = v.labelLayout[index + 1];
        return (
          Math.abs(anchor.anchorX - (p.x * 0.5 + 0.5) * 1000) < 0.01 &&
          Math.abs(anchor.anchorY - (-p.y * 0.5 + 0.5) * 700) < 0.01
        );
      }),
    };
  });
  expect(navigatedAxes.routes).toEqual(overlay.map((line) => line.vertices));
  check(
    navigatedAxes.anchors.every(Boolean),
    "Axis routes stay exact and labels follow camera pan/pinch",
  );
  const readable = await page.evaluate(() => {
    const labels = [
      ...document.querySelectorAll(".dimension-label:not([hidden])"),
    ].map((label) => label.getBoundingClientRect());
    return labels.every(
      (a, i) =>
        a.left >= 0 &&
        a.top >= 0 &&
        a.right <= 1000 &&
        a.bottom <= 700 &&
        labels
          .slice(0, i)
          .every(
            (b) =>
              a.right + 7.9 <= b.left ||
              b.right + 7.9 <= a.left ||
              a.bottom + 7.9 <= b.top ||
              b.bottom + 7.9 <= a.top,
          ),
    );
  });
  check(
    readable,
    "Crowded midpoint labels remain separated by eight pixels and clamped to viewport",
  );
  const dash = await page.evaluate(async () => {
    const v = window.measurementNavigation.viewer,
      first = v.axisLines[0].material.dashSize;
    v.zoom(2);
    await new Promise((r) => requestAnimationFrame(r));
    const pixel = v.worldPerPixel(),
      material = v.axisLines[0].material,
      valid =
        Math.abs(material.dashSize / pixel - 7) < 1e-6 &&
        Math.abs(material.gapSize / pixel - 4) < 1e-6 &&
        material.dashSize < first;
    v.zoom(0.5);
    await new Promise((r) => requestAnimationFrame(r));
    return valid;
  });
  check(dash, "Dash and gap track seven and four pixels when zoom changes");
  const exported = await page.evaluate(async () => {
    const blob = await window.measurementNavigation.viewer.screenshot();
    return { type: blob.type, size: blob.size };
  });
  check(
    exported.type === "image/png" && exported.size > 1000,
    "PNG includes the measured viewport and component labels",
  );
  await fs.mkdir("artifacts/perf", { recursive: true });
  await page.screenshot({ path: "artifacts/perf/measurement-navigation.png" });
  const light = await page.evaluate(async () => {
    document.documentElement.dataset.theme = "light";
    const v = window.measurementNavigation.viewer;
    v.applyOptions({ ...v.options, theme: "light" });
    await new Promise((r) => requestAnimationFrame(r));
    return {
      lines: v.axisLines.map((line) => line.material.color.getHexString()),
      labels: v.axisLabels.map((label) => getComputedStyle(label).color),
    };
  });
  check(
    light.lines.join(",") === "a94e4e,247a50,396caa" &&
      light.labels.join(",") ===
        "rgb(169, 78, 78),rgb(36, 122, 80),rgb(57, 108, 170)",
    "Light theme preserves matched axis line and label colors",
  );
  await page.screenshot({
    path: "artifacts/perf/measurement-navigation-light.png",
  });
  await page.evaluate(() =>
    window.measurementNavigation.viewer.setOverlay({
      points: [
        [0, 0, 0],
        [0, 0, 2],
      ],
      text: "2mm",
      axisTexts: ["ΔX 0", "ΔY 0", "ΔZ 2"],
    }),
  );
  await expect(page.locator(".dimension-axis-label:not([hidden])")).toHaveCount(
    1,
  );
  check(
    (await page.evaluate(
      () => window.measurementNavigation.viewer.axisLines.length,
    )) === 1,
    "Zero-length X and Y components are omitted",
  );
  await page.evaluate(() =>
    window.measurementNavigation.viewer.setOverlay({
      points: [
        [0, 0, 0],
        [4, -3, 2],
      ],
      path: [
        [0, 0, 0],
        [2, 1, 3],
        [4, -3, 2],
      ],
      axisTexts: ["X", "Y", "Z"],
    }),
  );
  check(
    (await page.evaluate(
      () => window.measurementNavigation.viewer.axisLines.length,
    )) === 0,
    "Geodesic paths do not acquire orthogonal components",
  );
  await page.evaluate(() =>
    window.measurementNavigation.viewer.setOverlay({
      points: [
        [0, 0, 0],
        [4, -3, 2],
      ],
      showAxes: false,
    }),
  );
  check(
    (await page.evaluate(
      () => window.measurementNavigation.viewer.axisLines.length,
    )) === 0,
    "App can explicitly suppress clearance or other component guides",
  );
  expect(errors).toEqual([]);
  const report = {
    date: new Date().toISOString(),
    renderer,
    checks,
    wheelResponses,
    bindingResults,
    touchResults,
    errors,
  };
  await fs.writeFile(
    "artifacts/perf/measurement-navigation.json",
    JSON.stringify(report, null, 2),
  );
  console.log(
    JSON.stringify(
      {
        renderer,
        checks: checks.length,
        wheelCases: wheelResponses.length,
        bindingCases: bindingResults.length,
        touchCases: touchResults.length,
        errors,
        report: "artifacts/perf/measurement-navigation.json",
      },
      null,
      2,
    ),
  );
} catch (error) {
  await fs.mkdir("artifacts/perf", { recursive: true });
  await page
    .screenshot({ path: "artifacts/perf/measurement-navigation-failure.png" })
    .catch(() => {});
  await fs.writeFile(
    "artifacts/perf/measurement-navigation-failure.json",
    JSON.stringify(
      {
        date: new Date().toISOString(),
        renderer,
        completedChecks: checks.length,
        error: error.message,
        errors,
      },
      null,
      2,
    ),
  );
  throw error;
} finally {
  await browser.close();
}
