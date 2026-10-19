import { describe, expect, it } from "vitest";
import {
  WheelGestureClassifier,
  pointerDrag,
  orbitMouseAction,
  wheelZoomSpeed,
} from "../src/core/navigation-gestures";
import { PerspectiveCamera, MOUSE, Vector3 } from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";

const plain = {
  shiftKey: false,
  ctrlKey: false,
  metaKey: false,
  altKey: false,
};
const modifiers = [
  plain,
  { ...plain, shiftKey: true },
  { ...plain, ctrlKey: true },
  { ...plain, metaKey: true },
  { ...plain, altKey: true },
  { ...plain, shiftKey: true, ctrlKey: true },
  { ...plain, shiftKey: true, metaKey: true },
  { ...plain, ctrlKey: true, metaKey: true },
  { ...plain, shiftKey: true, ctrlKey: true, metaKey: true, altKey: true },
];
// Saved values are compatibility inputs, not alternative navigation mappings.
const legacyStyles = [
  "onshape",
  "solidworks",
  "creo",
  "rhino",
  "fusion",
  "blender",
] as const;
const sample = (
  deltaX: number,
  deltaY: number,
  deltaMode = 0,
  ctrlKey = false,
  extra: Record<string, unknown> = {},
) => ({ deltaX, deltaY, deltaMode, ctrlKey, ...extra });

describe("wheel source discrimination", () => {
  it("uses native gesture and wheel hints authoritatively for tiny, integral, large and diagonal values", () => {
    for (const mode of ["auto", "mouse", "trackpad"] as const)
      for (const [x, y] of [
        [0, 0.25],
        [0, 1],
        [0, 7],
        [0, 100],
        [0, 120],
        [0, -240],
        [37.5, 0],
        [8.5, 18.5],
      ]) {
        const classifier = new WheelGestureClassifier();
        expect(
          classifier.classify(
            sample(x, y, 0, false, {
              nativeSource: "gesture",
              wheelDeltaY: -120,
              devicePixelRatio: 1,
            }),
            mode,
            0,
          ),
        ).toBe("swipe-zoom");
        expect(
          classifier.classify(
            sample(x, y, 0, false, { nativeSource: "wheel" }),
            mode,
            16,
          ),
        ).toBe("zoom");
      }
  });
  it("always zooms Ctrl pinch without inheriting a prior pan or wheel source", () => {
    const classifier = new WheelGestureClassifier();
    for (const nativeSource of ["gesture", "wheel", null])
      expect(
        classifier.classify(
          sample(0, 2, 0, true, { nativeSource, momentum: true }),
          "auto",
          16,
        ),
      ).toBe("zoom");
    expect(wheelZoomSpeed(1.3, true, true)).toBe(1.3);
  });
  it("recognizes recorded Chromium discrete wheel pairs at DPR1 and DPR2, including small and fractional pixels", () => {
    for (const dpr of [1, 2])
      for (const delta of [120, 100, 40, 7, 1, 0.25, -120, -7])
        expect(
          new WheelGestureClassifier().classify(
            sample(0, delta / dpr, 0, false, {
              wheelDeltaX: 0,
              wheelDeltaY: (-Math.sign(delta) * 120) / dpr,
              devicePixelRatio: dpr,
            }),
            "auto",
            0,
          ),
        ).toBe("zoom");
  });
  it("keeps browser line/page wheel zoom and momentum gesture pan distinct", () => {
    for (const deltaMode of [1, 2])
      expect(
        new WheelGestureClassifier().classify(
          sample(0, 1, deltaMode),
          "auto",
          0,
        ),
      ).toBe("zoom");
    for (const [x, y] of [
      [0, 120],
      [120, 0],
      [42, 63],
    ])
      expect(
        new WheelGestureClassifier().classify(
          sample(x, y, 0, false, { momentum: true }),
          "auto",
          0,
        ),
      ).toBe("swipe-zoom");
  });
  it("uses non-discrete precision metadata for vertical, horizontal and diagonal browser scrolling regardless of old preferences", () => {
    for (const mode of ["auto", "mouse", "trackpad"] as const)
      for (const [x, y] of [
        [0, 7],
        [0, 53],
        [0, 100],
        [37.5, 0],
        [14.5, 22.5],
      ])
        expect(
          new WheelGestureClassifier().classify(
            sample(x, y, 0, false, {
              wheelDeltaX: -3 * x,
              wheelDeltaY: -3 * y,
              devicePixelRatio: 1,
            }),
            mode,
            0,
          ),
        ).toBe("swipe-zoom");
  });
  it("native source precedes browser delta modes and momentum hints", () => {
    expect(
      new WheelGestureClassifier().classify(
        sample(0, 1, 1, false, { nativeSource: "gesture" }),
        "auto",
        0,
      ),
    ).toBe("swipe-zoom");
    expect(
      new WheelGestureClassifier().classify(
        sample(0, 0.25, 0, false, { nativeSource: "wheel", momentum: true }),
        "auto",
        0,
      ),
    ).toBe("zoom");
  });
  it("switches native devices immediately without a sticky previous-gesture classification", () => {
    const classifier = new WheelGestureClassifier();
    for (const [index, event] of [
      { source: "gesture", x: 0, y: 120, expected: "swipe-zoom" },
      { source: "wheel", x: 0, y: 0.25, expected: "zoom" },
      { source: "gesture", x: 37.5, y: 0, expected: "swipe-zoom" },
      { source: "wheel", x: 0, y: 7, expected: "zoom" },
      { source: "gesture", x: 8.5, y: 18.5, expected: "swipe-zoom" },
    ].entries())
      expect(
        classifier.classify(
          sample(event.x, event.y, 0, false, { nativeSource: event.source }),
          "auto",
          index,
        ),
      ).toBe(event.expected);
  });
});

describe("fixed camera drag controls", () => {
  it("maps left and middle to pan and right to orbit (pan with Command or Ctrl), independent of old presets", () => {
    for (const style of legacyStyles)
      for (const m of modifiers)
        for (const is2D of [false, true]) {
          expect(pointerDrag(style, 0, m, is2D)).toBe("pan");
          expect(pointerDrag(style, 1, m, is2D)).toBe("pan");
          expect(pointerDrag(style, 2, m, is2D)).toBe(
            is2D || m.ctrlKey || m.metaKey ? "pan" : "orbit",
          );
          expect(pointerDrag(style, 3, m, is2D)).toBe("none");
        }
  });
  it("compensates real OrbitControls modifier swaps and preserves the panned view center", () => {
    class Document extends EventTarget {}
    class Canvas extends EventTarget {
      ownerDocument = new Document();
      style = {};
      clientWidth = 600;
      clientHeight = 400;
      getRootNode() {
        return this.ownerDocument;
      }
      setPointerCapture() {}
      releasePointerCapture() {}
      getBoundingClientRect() {
        return { left: 0, top: 0, width: 600, height: 400 };
      }
    }
    const outcomes = new Map<string, { position: Vector3; target: Vector3 }>();
    for (const style of legacyStyles)
      for (const button of [0, 1, 2])
        for (const m of modifiers)
          for (const is2D of [false, true]) {
            const element = new Canvas(),
              camera = new PerspectiveCamera(45, 1.5, 0.01, 1000);
            const center = new Vector3(10, -4, 2);
            camera.position.copy(center).add(new Vector3(4, -7, 6));
            camera.up.set(0, 0, 1);
            const controls = new OrbitControls(
              camera,
              element as unknown as HTMLElement,
            );
            controls.target.copy(center);
            controls.update();
            const desired = pointerDrag(style, button, m, is2D),
              mapped = orbitMouseAction(desired, m);
            controls.mouseButtons[
              button === 0 ? "LEFT" : button === 1 ? "MIDDLE" : "RIGHT"
            ] =
              mapped === "rotate"
                ? MOUSE.ROTATE
                : mapped === "pan"
                  ? MOUSE.PAN
                  : mapped === "dolly"
                    ? MOUSE.DOLLY
                    : null;
            const event = (type: string, x: number, y: number) =>
              Object.assign(new Event(type), {
                pointerId: 1,
                pointerType: "mouse",
                button,
                clientX: x,
                clientY: y,
                pageX: x,
                pageY: y,
                ...m,
              });
            const beforePosition = camera.position.clone(),
              beforeTarget = controls.target.clone(),
              beforeDirection = beforePosition
                .clone()
                .sub(beforeTarget)
                .normalize(),
              beforeDistance = beforePosition.distanceTo(beforeTarget);
            element.dispatchEvent(event("pointerdown", 300, 200));
            element.ownerDocument.dispatchEvent(event("pointermove", 330, 220));
            const direction = camera.position
              .clone()
              .sub(controls.target)
              .normalize();
            if (desired === "pan") {
              expect(controls.target.distanceTo(beforeTarget)).toBeGreaterThan(
                0.001,
              );
              expect(direction.distanceTo(beforeDirection)).toBeLessThan(1e-8);
              expect(
                camera.position
                  .clone()
                  .sub(beforePosition)
                  .distanceTo(controls.target.clone().sub(beforeTarget)),
              ).toBeLessThan(1e-8);
            } else {
              expect(direction.distanceTo(beforeDirection)).toBeGreaterThan(
                0.001,
              );
              expect(controls.target.distanceTo(center)).toBeLessThan(1e-8);
            }
            expect(camera.position.distanceTo(controls.target)).toBeCloseTo(
              beforeDistance,
              10,
            );
            if (button < 2) {
              const key = JSON.stringify({ style, m, is2D });
              const previous = outcomes.get(key);
              if (previous) {
                expect(
                  camera.position.distanceTo(previous.position),
                ).toBeLessThan(1e-8);
                expect(
                  controls.target.distanceTo(previous.target),
                ).toBeLessThan(1e-8);
              } else
                outcomes.set(key, {
                  position: camera.position.clone(),
                  target: controls.target.clone(),
                });
            }
            element.ownerDocument.dispatchEvent(event("pointerup", 330, 220));
            controls.dispose();
          }
  });
});
