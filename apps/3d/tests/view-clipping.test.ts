import { describe, expect, it } from "vitest";
import { clippingRange } from "../src/core/view-clipping";

const assembly = { radius: 1000, centerDistance: 3000, centerDepth: 3000 };

describe("camera clipping follows the current view", () => {
  it("depends on the current pose, not on the last fitted part", () => {
    // Fit the whole assembly, then a 5 mm part, then zoom back out: the
    // range must match the assembly view again (it used to stay at the part's).
    const whole = clippingRange({
      orthographic: false,
      viewDistance: 3000,
      ...assembly,
    });
    clippingRange({
      orthographic: false,
      viewDistance: 30,
      radius: 1000,
      centerDistance: 40,
      centerDepth: 35,
    });
    const back = clippingRange({
      orthographic: false,
      viewDistance: 3000,
      ...assembly,
    });
    expect(back).toEqual(whole);
    expect(whole.near).toBeCloseTo(0.3, 12);
  });

  it("keeps the perspective near plane proportional to the view distance", () => {
    const close = clippingRange({
      orthographic: false,
      viewDistance: 30,
      ...assembly,
    });
    const far = clippingRange({
      orthographic: false,
      viewDistance: 600,
      ...assembly,
    });
    expect(close.near).toBeCloseTo(0.003, 12);
    expect(far.near).toBeCloseTo(0.06, 12);
  });

  it("never lets the far plane cut the assembly or its grid", () => {
    const zoomedIn = clippingRange({
      orthographic: false,
      viewDistance: 30,
      radius: 1000,
      centerDistance: 40,
      centerDepth: 35,
    });
    expect(zoomedIn.far).toBeGreaterThanOrEqual(40 + 1000 * 14);
    const zoomedOut = clippingRange({
      orthographic: false,
      viewDistance: 50_000,
      ...assembly,
    });
    expect(zoomedOut.far).toBeGreaterThanOrEqual(50_000 * 100);
  });

  it("keeps geometry behind an orthographic camera position", () => {
    // A part fit puts the orthographic camera inside the assembly.
    const range = clippingRange({
      orthographic: true,
      viewDistance: 20,
      centerDistance: 30,
      centerDepth: -30,
      radius: 1000,
    });
    expect(range.near).toBeLessThanOrEqual(-30 - 1000 * 14);
    expect(range.far).toBeGreaterThanOrEqual(-30 + 1000 * 14);
  });

  it("falls back safely without a model", () => {
    const range = clippingRange({
      orthographic: false,
      viewDistance: NaN,
      centerDistance: NaN,
      centerDepth: NaN,
      radius: 0,
    });
    expect(Number.isFinite(range.near) && range.near > 0).toBe(true);
    expect(range.far).toBeGreaterThan(range.near);
  });
});
