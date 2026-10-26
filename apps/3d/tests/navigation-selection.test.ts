import { describe, it, expect, vi } from "vitest";
import * as T from "three";
import { Viewer } from "../src/core/viewer";
import { ScenePickingIndex } from "../src/core/scene-picking";
import { VisibleDepth } from "../src/core/view-clipping";
import type { GeometryData, Pick } from "../src/core/types";
function fixture(matrix = new T.Matrix4().makeTranslation(10, 20, 30)) {
  const positions = new Float32Array([
    0, 0, 0, 2, 0, 0, 0, 2, 0, 50, 50, 50, 52, 50, 50, 50, 52, 50,
  ]);
  const geometry = new T.BufferGeometry()
    .setAttribute("position", new T.BufferAttribute(positions, 3))
    .setIndex([0, 1, 2, 3, 4, 5]);
  geometry.computeBoundingBox();
  const topology = {
    faces: [{ id: 7, firstIndex: 0, indexCount: 3 }],
    edges: [{ id: 9, points: new Float32Array([-1, 1, 2, 3, 1, 2]) }],
    vertices: [{ id: 10, position: [2, 4, 6] }],
  } as unknown as GeometryData["topology"];
  const data: GeometryData = {
    id: "geometry",
    geometry,
    materials: [],
    topology,
  };
  const camera = new T.PerspectiveCamera(45, 1.5, 0.01, 1000);
  camera.position.set(3, -10, 6);
  camera.up.set(0, 0, 1);
  const target = new T.Vector3(),
    controls = {
      target,
      update: vi.fn(() => {
        camera.lookAt(target);
        camera.updateMatrixWorld();
      }),
    };
  const viewer = Object.assign(Object.create(Viewer.prototype) as Viewer, {
    camera,
    controls,
    model: { geometries: new Map([["geometry", data]]) },
    parts: new Map([["part", { geometryId: "geometry" }]]),
    partDisplay: new Map([["part", matrix]]),
    mode: "feature",
    options: { hidden: new Set() },
    host: { clientWidth: 600, clientHeight: 400 },
    invalidate: vi.fn(),
    glide: { cancel: vi.fn() },
    center: new T.Vector3(),
    clipCenter: new T.Vector3(),
    clipForward: new T.Vector3(),
    clipOrigin: new T.Vector3(),
    clipBox: new T.Box3(),
    clipMatrix: new T.Matrix4(),
    clipFrustum: new T.Frustum(),
    visibleDepth: new VisibleDepth(),
    pickingIndex: new ScenePickingIndex(),
    grid: new T.Group(),
    overlay: new T.Group(),
    radius: 100,
  });
  const pick: Pick = {
    id: "pick",
    partId: "part",
    partName: "Part",
    geometryId: "geometry",
    point: [0, 0, 0],
    localPoint: [0, 0, 0],
    kind: "face",
    elementId: 7,
    triangleIndex: 0,
    snap: "Face",
    matrix: new T.Matrix4().toArray(),
  };
  return { viewer, camera, controls, target, data, geometry, pick, matrix };
}
describe("selection camera commands", () => {
  it("fits selected face vertices using displayed transforms instead of full-part bounds", () => {
    const f = fixture();
    f.viewer.fitSelection([f.pick]);
    expect(f.target.toArray()).toEqual([11, 21, 30]);
    for (const local of [
      [0, 0, 0],
      [2, 0, 0],
      [0, 2, 0],
    ]) {
      const p = new T.Vector3(...local)
        .applyMatrix4(f.matrix)
        .project(f.camera);
      expect(Math.abs(p.x)).toBeLessThan(1);
      expect(Math.abs(p.y)).toBeLessThan(1);
    }
  });
  it("fits edge and vertex geometry, preserving point-only zoom and distance", () => {
    const edge = fixture();
    edge.viewer.fitSelection([{ ...edge.pick, kind: "edge", elementId: 9 }]);
    expect(edge.target.toArray()).toEqual([11, 21, 32]);
    const vertex = fixture(),
      distance = vertex.camera.position.distanceTo(vertex.target);
    vertex.viewer.fitSelection([
      { ...vertex.pick, kind: "vertex", elementId: 10 },
    ]);
    expect(vertex.target.toArray()).toEqual([12, 24, 36]);
    expect(vertex.camera.position.distanceTo(vertex.target)).toBeCloseTo(
      distance,
      12,
    );
  });
  it("falls back to part bounds if the feature is absent or part mode is active", () => {
    for (const missing of [true, false]) {
      const f = fixture();
      if (!missing) Object.assign(f.viewer, { mode: "part" });
      f.viewer.fitSelection([{ ...f.pick, elementId: missing ? 999 : 7 }]);
      expect(f.target.toArray()).toEqual([36, 46, 55]);
    }
  });
  it("aligns a planar face under nonuniform/sheared display transforms and repeated command flips", () => {
    const matrix = new T.Matrix4().set(
        2,
        0.4,
        0,
        10,
        0,
        3,
        0.2,
        20,
        0.6,
        0,
        1,
        30,
        0,
        0,
        0,
        1,
      ),
      f = fixture(matrix);
    const points = [
        [0, 0, 0],
        [2, 0, 0],
        [0, 2, 0],
      ].map((p) => new T.Vector3(...p).applyMatrix4(matrix)),
      normal = new T.Vector3()
        .crossVectors(
          points[1].clone().sub(points[0]),
          points[2].clone().sub(points[0]),
        )
        .normalize();
    const distance = f.camera.position.distanceTo(f.target);
    expect(f.viewer.normalToFace(f.pick)).toBe(true);
    const first = f.camera.position.clone().sub(f.target).normalize();
    expect(Math.abs(first.dot(normal))).toBeCloseTo(1, 12);
    expect(f.camera.position.distanceTo(f.target)).toBeCloseTo(distance, 12);
    expect(f.viewer.normalToFace(f.pick)).toBe(true);
    expect(
      f.camera.position.clone().sub(f.target).normalize().dot(first),
    ).toBeCloseTo(-1, 12);
    expect(f.camera.position.distanceTo(f.target)).toBeCloseTo(distance, 12);
  });
  it("rejects curved/nonplanar and non-face selections without changing the camera", () => {
    const f = fixture();
    f.data.topology!.faces[0].indexCount = 6;
    const position = f.camera.position.clone();
    expect(f.viewer.normalToFace(f.pick)).toBe(false);
    expect(f.camera.position.equals(position)).toBe(true);
    expect(f.viewer.normalToFace({ ...f.pick, kind: "edge" })).toBe(false);
  });
  it("supports a connected mesh face and excludes hidden or missing hovered parts", () => {
    const f = fixture();
    f.data.topology = undefined;
    expect(f.viewer.normalToFace(f.pick)).toBe(true);
    Object.assign(f.viewer, { hoveredPartId: "part" });
    expect(f.viewer.getHoveredPartId()).toBe("part");
    Object.assign(f.viewer, { options: { hidden: new Set(["part"]) } });
    expect(f.viewer.getHoveredPartId()).toBeUndefined();
    Object.assign(f.viewer, {
      hoveredPartId: "gone",
      options: { hidden: new Set() },
    });
    expect(f.viewer.getHoveredPartId()).toBeUndefined();
  });
});
