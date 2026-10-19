import type { Vec3 } from "./types";
export const MEASUREMENT_AXIS_COLORS = {
  dark: [0xff7373, 0x45db8d, 0x63aaff],
  light: [0xa94e4e, 0x247a50, 0x396caa],
} as const;

export interface MeasurementLabelLayout {
  anchorX: number;
  anchorY: number;
  width: number;
  height: number;
  x: number;
  y: number;
  visible: boolean;
}

/** Mutates four reused layout records; the main label keeps first choice. */
export function layoutMeasurementLabels(
  labels: MeasurementLabelLayout[],
  width: number,
  height: number,
) {
  for (let index = 0; index < labels.length; index++) {
    const label = labels[index];
    if (!label.visible) continue;
    label.x = Math.max(
      0,
      Math.min(width - label.width, label.anchorX - label.width / 2),
    );
    const top = label.anchorY - label.height * 1.5;
    for (let step = 0; step <= 20; step++) {
      const offset = Math.ceil(step / 2) * 18 * (step % 2 ? 1 : -1);
      label.y = Math.max(0, Math.min(height - label.height, top + offset));
      let overlaps = false;
      for (let previous = 0; previous < index; previous++) {
        const other = labels[previous];
        if (
          other.visible &&
          label.x < other.x + other.width + 8 &&
          label.x + label.width + 8 > other.x &&
          label.y < other.y + other.height + 8 &&
          label.y + label.height + 8 > other.y
        ) {
          overlaps = true;
          break;
        }
      }
      if (!overlaps || index === 0) break;
    }
  }
}

/** Ordered orthogonal route A → (Bx,Ay,Az) → (Bx,By,Az) → B. */
export function measurementComponents(a: Vec3, b: Vec3) {
  const corners: Vec3[] = [a, [b[0], a[1], a[2]], [b[0], b[1], a[2]], b];
  return ([0, 1, 2] as const)
    .filter((axis) => a[axis] !== b[axis])
    .map((axis) => {
      const start = corners[axis],
        end = corners[axis + 1];
      const midpoint: Vec3 = [
        (start[0] + end[0]) / 2,
        (start[1] + end[1]) / 2,
        (start[2] + end[2]) / 2,
      ];
      return { axis, start, end, midpoint };
    });
}
