import { describe, expect, it } from "vitest";
import * as T from "three";
import { ScenePickingIndex } from "../src/core/scene-picking";
import {
  clippingRange,
  isDecal,
  VisibleDepth,
} from "../src/core/view-clipping";

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

/** A camera at `position` looking at `target`, and VisibleDepth reset for it. */
function depthFor(position: number[], target: number[], orthographic = false) {
  const camera = orthographic
    ? new T.OrthographicCamera(-10, 10, 10, -10, 0.1, 1000)
    : new T.PerspectiveCamera(38, 1.5, 0.1, 1000);
  camera.up.set(0, 0, 1);
  camera.position.set(...(position as [number, number, number]));
  camera.lookAt(...(target as [number, number, number]));
  camera.updateMatrixWorld();
  const frustum = new T.Frustum().setFromProjectionMatrix(
    new T.Matrix4().multiplyMatrices(
      camera.projectionMatrix,
      camera.matrixWorldInverse,
    ),
  );
  const depth = new VisibleDepth();
  depth.reset(
    frustum.planes,
    camera.getWorldDirection(new T.Vector3()),
    camera.position,
    !orthographic,
  );
  return { depth, camera };
}
const box = (min: number[], max: number[]) =>
  new T.Box3(
    new T.Vector3(...(min as [number, number, number])),
    new T.Vector3(...(max as [number, number, number])),
  );

describe("the near plane follows the nearest geometry in view", () => {
  it("gives thin features depth precision close up", () => {
    // 7 mm above a connector on a board: the old near plane, 1/10,000 of the
    // view distance, left about 4 µm of depth resolution there.
    const old = clippingRange({
      orthographic: false,
      viewDistance: 7,
      radius: 30,
      centerDistance: 20,
      centerDepth: 15,
    });
    const now = clippingRange({
      orthographic: false,
      viewDistance: 7,
      radius: 30,
      centerDistance: 20,
      centerDepth: 15,
      visible: { min: 5.5, max: Infinity },
    });
    const resolution = (near: number) => (7 * 7) / (near * 2 ** 24);
    expect(resolution(old.near)).toBeGreaterThan(0.003);
    expect(resolution(now.near)).toBeLessThan(1e-6);
    expect(now.near).toBeLessThan(5.5);
  });

  it("never pulls the near plane in closer than before", () => {
    const range = clippingRange({
      orthographic: false,
      viewDistance: 300,
      radius: 30,
      centerDistance: 300,
      centerDepth: 300,
      visible: { min: 0, max: 400 },
    });
    expect(range.near).toBeCloseTo(0.03, 12);
  });

  it("counts only the part of a box that is in view", () => {
    // A board stretching far behind and below the camera, which looks down at
    // its middle: its nearest corners are behind the camera, but the nearest
    // board in view is the bottom edge of the picture.
    const { depth, camera } = depthFor([0, -10, 10], [0, 0, 0]);
    const board = box([-100, -100, -1], [100, 100, 0]);
    expect(depth.lowerBound(board)).toBeLessThan(0);
    depth.addBox(board);
    expect(depth.min).toBeGreaterThan(5);
    // Every board point in view is at least that deep.
    const raycaster = new T.Raycaster();
    for (const [x, y] of [[0, -1], [-1, -1], [1, -1], [0, 0], [1, 1]]) {
      raycaster.setFromCamera(new T.Vector2(x, y), camera);
      const hit = raycaster.ray.intersectBox(board, new T.Vector3());
      if (!hit) continue;
      const pointDepth = hit
        .sub(camera.position)
        .dot(camera.getWorldDirection(new T.Vector3()));
      expect(pointDepth).toBeGreaterThanOrEqual(depth.min - 1e-9);
    }
  });

  it("ignores boxes outside the view and reaches the camera from inside one", () => {
    const { depth } = depthFor([0, 0.001, 50], [0, 0, 0]);
    depth.addBox(box([500, 500, 0], [510, 510, 10]));
    expect(depth.min).toBe(Infinity);
    depth.addBox(box([-1, -1, 0], [1, 1, 2]));
    expect(depth.min).toBeCloseTo(48, 3);
    depth.addBox(box([-5, -5, 45], [5, 5, 55]));
    expect(depth.min).toBe(0);
  });

  it("finds the nearest part through the picking index", () => {
    const geometry = new T.BoxGeometry(1, 1, 1);
    const mesh = new T.InstancedMesh(geometry, new T.MeshBasicMaterial(), 500);
    const matrix = new T.Matrix4();
    for (let i = 0; i < 500; i++)
      mesh.setMatrixAt(i, matrix.makeTranslation((i % 25) * 4, Math.floor(i / 25) * 4, 0));
    const index = new ScenePickingIndex();
    index.setObjects([mesh]);
    // One tall part, 10 mm high, under the camera.
    const tall = 10 * 25 + 10;
    mesh.setMatrixAt(tall, matrix.makeTranslation(40, 40, 0).scale(new T.Vector3(1, 1, 10)));
    index.setObjects([mesh]);
    const { depth } = depthFor([40, 40.001, 30], [40, 40, 0]);
    index.addVisibleDepth(depth, true);
    expect(depth.min).toBeCloseTo(25, 3);
    // Hidden parts (zero matrices) are not counted.
    mesh.setMatrixAt(tall, new T.Matrix4().makeScale(0, 0, 0));
    index.setObjects([mesh]);
    const { depth: again } = depthFor([40, 40.001, 30], [40, 40, 0]);
    index.addVisibleDepth(again, false);
    expect(again.min).toBeCloseTo(29.5, 3);
    expect(again.max).toBeCloseTo(30.5, 3);
  });

  it("spends orthographic precision on the depth in view", () => {
    const range = clippingRange({
      orthographic: true,
      viewDistance: 20,
      centerDistance: 30,
      centerDepth: 30,
      radius: 1000,
      visible: { min: 10, max: 50 },
    });
    expect(range.near).toBeLessThanOrEqual(10);
    expect(range.far).toBeGreaterThanOrEqual(50);
    expect(range.far - range.near).toBeLessThan(100);
  });
});

describe("decals", () => {
  it("are parts far thinner than they are wide", () => {
    expect(isDecal(box([0, 0, 3.4], [0.1, 0.2, 3.401]))).toBe(true);
    expect(isDecal(box([0, 0, 0.785], [30, 20, 0.785]))).toBe(true);
    expect(isDecal(box([0, 0, 0], [1, 1, 0.035]))).toBe(false);
    expect(isDecal(box([0, 0, 0], [30, 20, 1.6]))).toBe(false);
    expect(isDecal(new T.Box3())).toBe(false);
  });
});
