/**
 * Near/far planes for the camera's current pose.
 *
 * They must follow every navigation, not only the last fit: fitting a small
 * part used to leave a microscopic near plane behind, and zooming back out to
 * the assembly then ran out of depth precision (see-through and missing faces)
 * while the frozen far plane cut distant geometry away.
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
}

/** The grid helper spans at most ten model radii from the model center. */
const SCENE_RADII = 20;

export function clippingRange({
  orthographic,
  viewDistance,
  centerDistance,
  centerDepth,
  radius,
}: ClippingInput): { near: number; far: number } {
  const r = Number.isFinite(radius) && radius > 0 ? radius : 1;
  const span = r * SCENE_RADII;
  if (orthographic) {
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
  return {
    near: Math.max(distance / 10000, 0.00001),
    far: Math.max(distance * 100, toCenter + span, 1000),
  };
}
