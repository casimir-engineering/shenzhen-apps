import { describe, it, expect } from "vitest";
import * as T from "three";
import {
  estimateTraceScene,
  serializeTraceScene,
  traceCamera,
} from "../src/core/ray-tracing-scene";
import {
  RAY_TRACING_BUDGET,
  traceResourceEstimate,
  unpackTraceRgba8,
} from "../src/core/ray-tracing-types";
function source(count = 2) {
  const mesh = new T.InstancedMesh(
    new T.BoxGeometry(),
    new T.MeshStandardMaterial({ color: 0x3399cc }),
    count,
  );
  for (let i = 0; i < count; i++)
    mesh.setMatrixAt(i, new T.Matrix4().makeTranslation(i * 2, 0, 0));
  return mesh;
}
describe("ray-tracing private scene and resource preflight", () => {
  it("counts unique geometry once and instance transforms separately without triangle expansion", () => {
    const mesh = source(10000),
      single = estimateTraceScene([source(1)]),
      many = estimateTraceScene([mesh]);
    expect(many.uniqueTriangles).toBe(12);
    expect(many.geometryBytes).toBe(single.geometryBytes);
    expect(many.instances).toBe(10000);
    expect(many.estimatedBytes - single.estimatedBytes).toBe(9999 * 256);
  });
  it("refuses budgets before copying or worker creation", () => {
    expect(() =>
      estimateTraceScene([source(100)], {
        ...RAY_TRACING_BUDGET,
        maxInstances: 10,
      }),
    ).toThrow(/instances/);
    expect(() =>
      estimateTraceScene([source()], {
        ...RAY_TRACING_BUDGET,
        maxGeometryBytes: 1,
      }),
    ).toThrow(/memory budget/);
  });
  it("copies data while preserving source indices, vertex positions, materials and transforms", async () => {
    const mesh = source(),
      camera = new T.PerspectiveCamera();
    camera.position.set(3, 4, 5);
    const beforeIndex = mesh.geometry.index!.array.slice(),
      beforePositions = mesh.geometry.getAttribute("position").array.slice(),
      beforeMatrix = mesh.instanceMatrix.array.slice();
    const snapshot = await serializeTraceScene({ sources: [mesh], camera });
    expect(snapshot.geometries).toHaveLength(1);
    expect(snapshot.objects[0].matrices).toHaveLength(32);
    expect(snapshot.geometries[0].index.buffer).not.toBe(
      mesh.geometry.index!.array.buffer,
    );
    expect(snapshot.geometries[0].attributes.position.array.buffer).not.toBe(
      mesh.geometry.getAttribute("position").array.buffer,
    );
    snapshot.geometries[0].index[0] = 100;
    expect(mesh.geometry.index!.array).toEqual(beforeIndex);
    expect(mesh.geometry.getAttribute("position").array).toEqual(
      beforePositions,
    );
    expect(mesh.instanceMatrix.array).toEqual(beforeMatrix);
    expect(snapshot.materials[0].properties.color).toEqual(
      (mesh.material as T.MeshStandardMaterial).color.toArray(),
    );
  });
  it("omits zero-scale hidden instances but refuses other singular transforms", async () => {
    const mesh = source();
    mesh.setMatrixAt(0, new T.Matrix4().makeScale(0, 0, 0));
    const snapshot = await serializeTraceScene({
      sources: [mesh],
      camera: new T.PerspectiveCamera(),
    });
    expect(snapshot.objects[0].matrices.length / 16).toBe(1);
    mesh.setMatrixAt(1, new T.Matrix4().makeScale(1, 1, 0));
    await expect(
      serializeTraceScene({
        sources: [mesh],
        camera: new T.PerspectiveCamera(),
      }),
    ).rejects.toThrow(/non-invertible/);
  });
  it("cancels asynchronous serialization and never detaches raster data", async () => {
    const mesh = source(10000),
      controller = new AbortController(),
      pending = serializeTraceScene(
        { sources: [mesh], camera: new T.PerspectiveCamera() },
        controller.signal,
      );
    controller.abort();
    await expect(pending).rejects.toMatchObject({ name: "AbortError" });
    expect(mesh.instanceMatrix.array.byteLength).toBeGreaterThan(0);
  });
  it("makes unsupported shader and section features explicit", () => {
    const mesh = source();
    (mesh.material as T.MeshStandardMaterial).clippingPlanes = [new T.Plane()];
    expect(() => estimateTraceScene([mesh])).toThrow(/section clipping/);
    (mesh.material as T.MeshStandardMaterial).clippingPlanes = [];
    mesh.material = new T.MeshBasicMaterial();
    expect(() => estimateTraceScene([mesh])).toThrow(/unsupported material/);
  });
  it("serializes a private camera without modifying the raster projection or coordinate system", () => {
    const camera = new T.PerspectiveCamera(37, 1.5, 0.1, 1000);
    camera.position.set(10, 20, 30);
    camera.updateMatrixWorld();
    const before = camera.projectionMatrix.clone(),
      system = camera.coordinateSystem;
    const snapshot = traceCamera(camera);
    expect(snapshot.matrix).toEqual(camera.matrixWorld.toArray());
    expect(snapshot.fov).toBe(37);
    expect(camera.coordinateSystem).toBe(system);
    expect(camera.projectionMatrix).toEqual(before);
  });
  it("copies material textures and their transforms without changing raster textures", async () => {
    const mesh = source(),
      texture = new T.DataTexture(new Uint8Array([255, 0, 0, 255]), 1, 1);
    texture.offset.set(0.2, 0.3);
    texture.repeat.set(2, 3);
    const before = texture.matrix.clone();
    (mesh.material as T.MeshStandardMaterial).map = texture;
    const snapshot = await serializeTraceScene({
      sources: [mesh],
      camera: new T.PerspectiveCamera(),
    });
    expect(snapshot.textures[0].data?.buffer).not.toBe(
      texture.image.data.buffer,
    );
    expect(snapshot.textures[0].matrix).not.toEqual(before.toArray());
    expect(texture.matrix).toEqual(before);
    expect(snapshot.materials[0].textures.map).toBe(0);
  });
  it("normalizes single-material face groups while retaining multi-material bindings on shared geometry", async () => {
    const single = source(1),
      grouped = new T.Mesh(single.geometry, [
        new T.MeshStandardMaterial(),
        new T.MeshStandardMaterial(),
        new T.MeshStandardMaterial(),
        new T.MeshStandardMaterial(),
        new T.MeshStandardMaterial(),
        new T.MeshStandardMaterial(),
      ]);
    const snapshot = await serializeTraceScene({
      sources: [single, grouped],
      camera: new T.PerspectiveCamera(),
    });
    expect(snapshot.geometries).toHaveLength(2);
    expect(snapshot.geometries[0].groups).toEqual([
      { start: 0, count: 36, materialIndex: 0 },
    ]);
    expect(snapshot.geometries[1].groups.map((g) => g.materialIndex)).toEqual([
      0, 1, 2, 3, 4, 5,
    ]);
    single.geometry.setDrawRange(3, 9);
    expect(() => estimateTraceScene([single])).toThrow(/draw ranges/);
  });
  it("accounts for output pixels and rejects excessive resolution before GPU allocation", () => {
    expect(traceResourceEstimate(100, 100, 100)).toBe(
      100 + 10000 * 64 + 64 * 1024 ** 2,
    );
    expect(() => traceResourceEstimate(100, 4000, 4000)).toThrow(
      /pixel budget/,
    );
    expect(() => traceResourceEstimate(500 * 1024 ** 2, 1000, 1000)).toThrow(
      /memory budget/,
    );
  });
  it("removes WebGPU row padding when exporting a nonaligned canvas width", () => {
    const padded = new Uint8Array(256 + 12);
    padded.set([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]);
    padded.set([13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24], 256);
    expect(Array.from(unpackTraceRgba8(padded, 3, 2))).toEqual(
      Array.from({ length: 24 }, (_, i) => i + 1),
    );
    expect(() => unpackTraceRgba8(new Uint8Array(10), 3, 2)).toThrow(
      /Incomplete/,
    );
  });
});
