/**
 * Near/far planes for the camera's current pose.
 *
 * They must follow every navigation, not only the last fit: fitting a small
 * part used to leave a microscopic near plane behind, and zooming back out to
 * the assembly then ran out of depth precision (see-through and missing faces)
 * while the frozen far plane cut distant geometry away.
 *
 * Depth precision is set by the near plane: with a 24-bit depth buffer two
 * surfaces at depth z separate only when they are more than about
 * z² / (near · 2²⁴) apart. A near plane of 1/10,000 of the view distance
 * leaves 4 µm at 7 mm, so markings printed 1 µm proud of a connector fought
 * with the face under them (shredded text, spikes along the triangles). The
 * near plane is therefore pushed out to the nearest geometry actually in view
 * (`visible`, from the parts' bounding boxes clipped to the view), which is
 * thousands of times further away in any normal view.
 */
export interface ClippingInput {
  orthographic: boolean;
  /** Camera to orbit-target distance. */
  viewDistance: number;
  /** Camera to model-center distance. */
  centerDistance: number;
  /** Model-center depth along the view direction (positive is in front). */
  centerDepth: number;
  /** Model bounding-sphere radius. */
  radius: number;
  /**
   * Depth range of the bounding boxes of everything drawn, clipped to the
   * view's sides (see VisibleDepth): `min` is at or below the depth of any
   * drawn point, `max` at or above it (orthographic views only need `max`).
   * Absent, or infinite, when nothing is in view.
   */
  visible?: { min: number; max: number };
}

/** The grid helper spans at most ten model radii from the model center. */
const SCENE_RADII = 20;

/**
 * The smallest perspective near plane for a camera this far from its orbit
 * target: the near plane when nothing in view says it can be further.
 */
export function nearFloor(viewDistance: number) {
  return Math.max(viewDistance / 10000, 0.00001);
}

/** Share of the nearest visible depth kept in front of the near plane. */
const NEAR_SLACK = 0.9;

export function clippingRange({
  orthographic,
  viewDistance,
  centerDistance,
  centerDepth,
  radius,
  visible,
}: ClippingInput): { near: number; far: number } {
  const r = Number.isFinite(radius) && radius > 0 ? radius : 1;
  const span = r * SCENE_RADII;
  if (orthographic) {
    const seen =
      visible &&
      Number.isFinite(visible.min) &&
      Number.isFinite(visible.max) &&
      visible.max >= visible.min
        ? visible
        : undefined;
    if (seen) {
      // Precision is linear: spend it on the depth that is actually drawn.
      const margin = Math.max((seen.max - seen.min) * 0.05, r * 1e-3, 1e-5);
      return { near: seen.min - margin, far: seen.max + margin };
    }
    // Orthographic depth precision is linear, and the camera can sit anywhere
    // along the view axis after a pan or a part fit. Keep the whole scene in
    // the depth range, including geometry behind the camera position.
    const depth = Number.isFinite(centerDepth) ? centerDepth : 0;
    return {
      near: Math.min(depth - span, 0.00001),
      far: Math.max(depth + span, r * 100, 1000),
    };
  }
  const distance =
    Number.isFinite(viewDistance) && viewDistance > 0 ? viewDistance : r;
  const toCenter = Number.isFinite(centerDistance) ? centerDistance : distance;
  const floor = nearFloor(distance);
  return {
    near:
      visible && Number.isFinite(visible.min)
        ? Math.max(floor, visible.min * NEAR_SLACK)
        : floor,
    far: Math.max(distance * 100, toCenter + span, 1000),
  };
}

/** A box as plain numbers: min x, y, z, max x, y, z. */
export interface BoxLike {
  min: { x: number; y: number; z: number };
  max: { x: number; y: number; z: number };
}

/**
 * Depth range of boxes inside a camera's view, for the clipping planes.
 *
 * Depth is measured along the view direction from the camera. Only the four
 * side planes of the view are used (never near/far, which this computes). A
 * box partly in view counts only for its part in view: the faces of the box
 * are clipped to the side planes, so a board stretching behind the camera
 * does not drag the near plane to zero. Each result bounds the depth of
 * anything inside the boxes and in view: `min` from below, `max` from above.
 */
export class VisibleDepth {
  min = Infinity;
  max = -Infinity;
  /** Side planes, 4 × (nx, ny, nz, d); inside is n·p + d ≥ 0. */
  private planes = new Float64Array(16);
  /** Depth = dot(forward, p) + offset. */
  private forward = new Float64Array(3);
  private offset = 0;
  /** Perspective camera position: the apex of the view, at depth 0. */
  private apex?: { x: number; y: number; z: number };
  private a = new Float64Array(3 * 12);
  private b = new Float64Array(3 * 12);

  /**
   * `sides` are the view's left, right, bottom and top planes in world space
   * (Three's Frustum planes 0–3), `forward` the unit view direction and
   * `origin` the camera position. `perspective` views meet at the camera.
   */
  reset(
    sides: readonly { normal: { x: number; y: number; z: number }; constant: number }[],
    forward: { x: number; y: number; z: number },
    origin: { x: number; y: number; z: number },
    perspective: boolean,
  ) {
    this.apex = perspective ? { x: origin.x, y: origin.y, z: origin.z } : undefined;
    for (let i = 0; i < 4; i++) {
      const { normal, constant } = sides[i];
      this.planes[i * 4] = normal.x;
      this.planes[i * 4 + 1] = normal.y;
      this.planes[i * 4 + 2] = normal.z;
      this.planes[i * 4 + 3] = constant;
    }
    this.forward[0] = forward.x;
    this.forward[1] = forward.y;
    this.forward[2] = forward.z;
    this.offset = -(forward.x * origin.x + forward.y * origin.y + forward.z * origin.z);
    this.min = Infinity;
    this.max = -Infinity;
  }

  /** Smallest depth of the box's corners: a lower bound for anything in it. */
  lowerBound(box: BoxLike): number {
    const f = this.forward;
    return (
      Math.min(f[0] * box.min.x, f[0] * box.max.x) +
      Math.min(f[1] * box.min.y, f[1] * box.max.y) +
      Math.min(f[2] * box.min.z, f[2] * box.max.z) +
      this.offset
    );
  }

  /** Largest depth of the box's corners. */
  upperBound(box: BoxLike): number {
    const f = this.forward;
    return (
      Math.max(f[0] * box.min.x, f[0] * box.max.x) +
      Math.max(f[1] * box.min.y, f[1] * box.max.y) +
      Math.max(f[2] * box.min.z, f[2] * box.max.z) +
      this.offset
    );
  }

  /** -1: entirely outside a side plane; 1: entirely inside all four; 0: crossing. */
  classify(box: BoxLike): -1 | 0 | 1 {
    let inside = 1 as -1 | 0 | 1;
    const p = this.planes;
    for (let i = 0; i < 16; i += 4) {
      const nx = p[i],
        ny = p[i + 1],
        nz = p[i + 2],
        d = p[i + 3];
      const high =
        Math.max(nx * box.min.x, nx * box.max.x) +
        Math.max(ny * box.min.y, ny * box.max.y) +
        Math.max(nz * box.min.z, nz * box.max.z) +
        d;
      if (high < 0) return -1;
      const low =
        Math.min(nx * box.min.x, nx * box.max.x) +
        Math.min(ny * box.min.y, ny * box.max.y) +
        Math.min(nz * box.min.z, nz * box.max.z) +
        d;
      if (low < 0) inside = 0;
    }
    return inside;
  }

  /** Widen the range by the bounds of a box (conservative; no clipping). */
  addBounds(box: BoxLike) {
    this.min = Math.min(this.min, this.lowerBound(box));
    this.max = Math.max(this.max, this.upperBound(box));
  }

  /** Widen the range by the part of the box inside the view. */
  addBox(box: BoxLike) {
    const where = this.classify(box);
    if (where < 0) return;
    if (where > 0) return this.addBounds(box);
    const o = this.apex;
    if (
      o &&
      o.x >= box.min.x && o.x <= box.max.x &&
      o.y >= box.min.y && o.y <= box.max.y &&
      o.z >= box.min.z && o.z <= box.max.z
    ) {
      // The camera is inside: the box reaches right up to it.
      this.min = Math.min(this.min, 0);
      this.max = Math.max(this.max, this.upperBound(box));
      return;
    }
    const x = [box.min.x, box.max.x],
      y = [box.min.y, box.max.y],
      z = [box.min.z, box.max.z];
    // The six faces, each as four corners in order.
    for (let axis = 0; axis < 3; axis++)
      for (let side = 0; side < 2; side++) {
        const a = this.a;
        for (let k = 0; k < 4; k++) {
          const u = k === 1 || k === 2 ? 1 : 0,
            v = k >= 2 ? 1 : 0;
          const corner =
            axis === 0
              ? [x[side], y[u], z[v]]
              : axis === 1
                ? [x[u], y[side], z[v]]
                : [x[u], y[v], z[side]];
          a[k * 3] = corner[0];
          a[k * 3 + 1] = corner[1];
          a[k * 3 + 2] = corner[2];
        }
        this.clipFace(4);
      }
  }

  /** Clip the polygon in `a` (count vertices) to the side planes; add its depths. */
  private clipFace(count: number) {
    let from = this.a,
      to = this.b;
    const p = this.planes;
    for (let i = 0; i < 16 && count; i += 4) {
      let out = 0;
      for (let k = 0; k < count; k++) {
        const j = (k + 1) % count;
        const sk =
          p[i] * from[k * 3] + p[i + 1] * from[k * 3 + 1] + p[i + 2] * from[k * 3 + 2] + p[i + 3];
        const sj =
          p[i] * from[j * 3] + p[i + 1] * from[j * 3 + 1] + p[i + 2] * from[j * 3 + 2] + p[i + 3];
        if (sk >= 0) {
          to[out * 3] = from[k * 3];
          to[out * 3 + 1] = from[k * 3 + 1];
          to[out * 3 + 2] = from[k * 3 + 2];
          out++;
        }
        if (sk >= 0 !== sj >= 0) {
          const t = sk / (sk - sj);
          for (let c = 0; c < 3; c++)
            to[out * 3 + c] = from[k * 3 + c] + (from[j * 3 + c] - from[k * 3 + c]) * t;
          out++;
        }
      }
      count = out;
      [from, to] = [to, from];
    }
    const f = this.forward;
    for (let k = 0; k < count; k++) {
      const depth = f[0] * from[k * 3] + f[1] * from[k * 3 + 1] + f[2] * from[k * 3 + 2] + this.offset;
      if (depth < this.min) this.min = depth;
      if (depth > this.max) this.max = depth;
    }
  }
}

/**
 * Thickness, as a share of the largest size, under which a part is a decal:
 * printed text and logos, labels, silkscreen, zero-thickness sheets. Markings
 * printed 1 µm proud on a 0.2 mm letter are 0.005; a 0.035 mm pad on a 1 mm
 * land (0.035) and a 1.6 mm board 30 mm long (0.05) are not decals.
 */
const DECAL_RATIO = 0.02;

/**
 * Whether a part's local bounds make it a decal, drawn a step towards the
 * camera (polygon offset) so it shows over the face it lies on even where
 * the two are coplanar, as a sheet on a face or a marking's underside is.
 */
export function isDecal(bounds: BoxLike): boolean {
  const x = bounds.max.x - bounds.min.x,
    y = bounds.max.y - bounds.min.y,
    z = bounds.max.z - bounds.min.z;
  const largest = Math.max(x, y, z);
  return (
    Number.isFinite(largest) &&
    largest > 0 &&
    Math.min(x, y, z) <= largest * DECAL_RATIO
  );
}
