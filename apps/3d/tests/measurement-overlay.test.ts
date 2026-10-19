import { describe, expect, it } from "vitest";
import {
  measurementComponents,
  MEASUREMENT_AXIS_COLORS,
  layoutMeasurementLabels,
} from "../src/core/measurement-overlay";
describe("orthogonal measurement overlay", () => {
  it("follows the signed XYZ route and computes each actual midpoint", () => {
    expect(measurementComponents([1, 2, 3], [-2, 6, 15])).toEqual([
      { axis: 0, start: [1, 2, 3], end: [-2, 2, 3], midpoint: [-0.5, 2, 3] },
      { axis: 1, start: [-2, 2, 3], end: [-2, 6, 3], midpoint: [-2, 4, 3] },
      { axis: 2, start: [-2, 6, 3], end: [-2, 6, 15], midpoint: [-2, 6, 9] },
    ]);
  });
  it("omits zero-length components without shifting the remaining axes", () => {
    expect(measurementComponents([1, 2, 3], [1, 2, 3])).toEqual([]);
    expect(measurementComponents([1, 2, 3], [1, 2, -1])).toEqual([
      { axis: 2, start: [1, 2, 3], end: [1, 2, -1], midpoint: [1, 2, 1] },
    ]);
  });
  it("uses brighter semantic axis lines on dark geometry and strong colors in light mode", () => {
    expect(MEASUREMENT_AXIS_COLORS.dark).toEqual([
      0xff7373, 0x45db8d, 0x63aaff,
    ]);
    expect(MEASUREMENT_AXIS_COLORS.light).toEqual([
      0xa94e4e, 0x247a50, 0x396caa,
    ]);
  });
  it("keeps four crowded labels deterministic, separated and inside the viewport", () => {
    const labels = Array.from({ length: 4 }, () => ({
      anchorX: 100,
      anchorY: 120,
      width: 80,
      height: 28,
      x: 0,
      y: 0,
      visible: true,
    }));
    layoutMeasurementLabels(labels, 200, 240);
    expect(labels[0]).toMatchObject({ x: 60, y: 78 });
    for (let i = 0; i < labels.length; i++) {
      const a = labels[i];
      expect(a.x).toBeGreaterThanOrEqual(0);
      expect(a.x + a.width).toBeLessThanOrEqual(200);
      expect(a.y).toBeGreaterThanOrEqual(0);
      expect(a.y + a.height).toBeLessThanOrEqual(240);
      for (let j = 0; j < i; j++) {
        const b = labels[j];
        expect(
          a.y + a.height + 8 <= b.y ||
            b.y + b.height + 8 <= a.y ||
            a.x + a.width + 8 <= b.x ||
            b.x + b.width + 8 <= a.x,
        ).toBe(true);
      }
    }
    const before = JSON.stringify(labels);
    layoutMeasurementLabels(labels, 200, 240);
    expect(JSON.stringify(labels)).toBe(before);
  });
  it("clamps edge anchors and ignores hidden labels", () => {
    const labels = [
      {
        anchorX: -10,
        anchorY: -10,
        width: 60,
        height: 28,
        x: 0,
        y: 0,
        visible: true,
      },
      {
        anchorX: 200,
        anchorY: 150,
        width: 60,
        height: 28,
        x: 0,
        y: 0,
        visible: true,
      },
      {
        anchorX: 100,
        anchorY: 100,
        width: 60,
        height: 28,
        x: 0,
        y: 0,
        visible: false,
      },
    ];
    layoutMeasurementLabels(labels, 200, 150);
    expect(labels[0]).toMatchObject({ x: 0, y: 0 });
    expect(labels[1]).toMatchObject({ x: 140, y: 108 });
    expect(labels[2]).toMatchObject({ x: 0, y: 0 });
  });
});
