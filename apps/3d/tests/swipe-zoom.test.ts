import { describe, expect, it } from "vitest";
import {
  SWIPE_HOLD_MS,
  WheelGestureClassifier,
  swipeZoomStep,
} from "../src/core/navigation-gestures";
import { PerspectiveCamera } from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";

const swipe = (deltaY: number, extra: Record<string, unknown> = {}) => ({
  deltaX: 0,
  deltaY,
  deltaMode: 0,
  ctrlKey: false,
  nativeSource: "gesture" as const,
  ...extra,
});
const classify = (
  event: ReturnType<typeof swipe>,
  time = 0,
  c = new WheelGestureClassifier(),
) => c.classify(event, "auto", time);

describe("two-finger swipe zooms by default", () => {
  it("zooms for native trackpad swipes in any direction", () => {
    for (const [x, y] of [
      [0, 3],
      [0, -40],
      [20, 5],
      [30, 0],
    ])
      expect(classify(swipe(y, { deltaX: x }))).toBe("swipe-zoom");
  });
  it("zooms for browser-heuristic swipes and their momentum", () => {
    expect(classify(swipe(7, { nativeSource: null, wheelDeltaY: -21 }))).toBe(
      "swipe-zoom",
    );
    expect(classify(swipe(120, { nativeSource: null, momentum: true }))).toBe(
      "swipe-zoom",
    );
  });
});

describe("Command or Control + swipe pans", () => {
  it("pans with Command held, native and browser", () => {
    expect(classify(swipe(9, { metaKey: true }))).toBe("pan");
    expect(
      classify(
        swipe(7, { metaKey: true, nativeSource: null, wheelDeltaY: -21 }),
      ),
    ).toBe("pan");
  });
  it("pans with the Control key held down", () => {
    expect(classify(swipe(9, { ctrlKey: true, ctrlHeld: true }))).toBe("pan");
  });
  it("keeps panning through inertia after the key is released, then zooms again", () => {
    const c = new WheelGestureClassifier();
    expect(classify(swipe(20, { metaKey: true }), 0, c)).toBe("pan");
    for (let t = 16; t < 400; t += 16)
      expect(classify(swipe(5), t, c)).toBe("pan");
    expect(classify(swipe(20), 400 + SWIPE_HOLD_MS, c)).toBe("swipe-zoom");
  });
  it("pressing the key mid-swipe pans at once", () => {
    const c = new WheelGestureClassifier();
    expect(classify(swipe(20), 0, c)).toBe("swipe-zoom");
    expect(classify(swipe(20, { metaKey: true }), 16, c)).toBe("pan");
  });
});

describe("pinch and mouse wheel are unchanged", () => {
  it("pinch (Ctrl wheel without the Control key down) zooms from any source", () => {
    for (const nativeSource of ["gesture", "wheel", null] as const)
      for (const metaKey of [false, true])
        expect(
          classify(
            swipe(2, { ctrlKey: true, ctrlHeld: false, nativeSource, metaKey }),
          ),
        ).toBe("zoom");
    // Hosts that don't report Control state still treat Ctrl+wheel as pinch.
    expect(classify(swipe(2, { ctrlKey: true }))).toBe("zoom");
  });
  it("mouse wheel zooms, with or without Command or Control", () => {
    for (const extra of [
      {},
      { metaKey: true },
      { ctrlKey: true, ctrlHeld: true },
    ]) {
      expect(classify(swipe(120, { nativeSource: "wheel", ...extra }))).toBe(
        "zoom",
      );
      expect(
        classify(
          swipe(120, { nativeSource: null, wheelDeltaY: -120, ...extra }),
        ),
      ).toBe("zoom");
      expect(
        classify(swipe(1, { nativeSource: null, deltaMode: 1, ...extra })),
      ).toBe("zoom");
    }
  });
  it("a wheel or pinch ends any held pan", () => {
    const c = new WheelGestureClassifier();
    classify(swipe(20, { metaKey: true }), 0, c);
    classify(swipe(120, { nativeSource: "wheel" }), 16, c);
    expect(classify(swipe(20), 32, c)).toBe("swipe-zoom");
  });
});

describe("swipe zoom step", () => {
  it("follows the wheel's direction and is proportional", () => {
    expect(swipeZoomStep(10, 0, 800, 1.3)?.out).toBe(true);
    expect(swipeZoomStep(-10, 0, 800, 1.3)?.out).toBe(false);
    expect(swipeZoomStep(0, 0, 800, 1.3)).toBeNull();
    const small = swipeZoomStep(4, 0, 800, 1.3)!.scale;
    const large = swipeZoomStep(40, 0, 800, 1.3)!.scale;
    expect(small).toBeLessThan(1);
    expect(Math.log(large)).toBeCloseTo(10 * Math.log(small), 10);
    expect(swipeZoomStep(-4, 0, 800, 1.3)!.scale).toBeCloseTo(small, 12);
  });
  it("zooms a real camera in and out and keeps the view center", () => {
    class Canvas extends EventTarget {
      ownerDocument = new EventTarget();
      style = {};
      getRootNode() {
        return this.ownerDocument;
      }
      setPointerCapture() {}
      releasePointerCapture() {}
      getBoundingClientRect() {
        return { left: 0, top: 0, width: 600, height: 400 };
      }
    }
    const camera = new PerspectiveCamera(50, 1, 0.1, 1000);
    camera.position.set(0, 0, 10);
    const controls = new OrbitControls(
      camera,
      new Canvas() as unknown as HTMLElement,
    );
    controls.zoomToCursor = false;
    const apply = (dy: number) => {
      const step = swipeZoomStep(dy, 0, 800, controls.zoomSpeed)!;
      if (step.out) controls.dollyOut(step.scale);
      else controls.dollyIn(step.scale);
    };
    apply(-30);
    const near = camera.position.distanceTo(controls.target);
    expect(near).toBeLessThan(10);
    apply(60);
    expect(camera.position.distanceTo(controls.target)).toBeGreaterThan(near);
    expect(controls.target.length()).toBe(0);
  });
});
