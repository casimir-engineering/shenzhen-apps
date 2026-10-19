import { describe, it, expect, vi } from "vitest";
import * as T from "three";
import { simplifyNavigationGeometry } from "../src/core/navigation-lod-kernel";
import {
  createNavigationLod,
  createNavigationLods,
} from "../src/core/navigation-lod";
import type { NavigationLodInput } from "../src/core/navigation-lod-kernel";

function input(geometry: T.BufferGeometry): NavigationLodInput {
  return {
    id: 7,
    positions: new Float32Array(geometry.getAttribute("position").array),
    indices: new Uint32Array(geometry.index!.array),
    normals: new Float32Array(geometry.getAttribute("normal").array),
    uvs: geometry.hasAttribute("uv")
      ? new Float32Array(geometry.getAttribute("uv").array)
      : undefined,
    groups: geometry.groups.map((group) => ({
      ...group,
      materialIndex: group.materialIndex ?? 0,
    })),
  };
}
describe("navigation render-only index LOD", () => {
  it("reduces a curved mesh without moving vertices or mutating original indices/attributes", async () => {
    const geometry = new T.SphereGeometry(10, 64, 32),
      data = input(geometry),
      positions = data.positions.slice(),
      indices = data.indices.slice(),
      normals = data.normals!.slice();
    const result = await simplifyNavigationGeometry(data);
    expect(result).toBeDefined();
    expect(result!.triangleCount).toBeLessThan(
      result!.originalTriangleCount * 0.75,
    );
    expect(result!.indices.length % 3).toBe(0);
    expect(result!.indices.every((index) => index < positions.length / 3)).toBe(
      true,
    );
    expect(data.positions).toEqual(positions);
    expect(data.indices).toEqual(indices);
    expect(data.normals).toEqual(normals);
    expect(result!.relativeError).toBeGreaterThanOrEqual(0);
    expect(result!.relativeError).toBeLessThanOrEqual(0.0020001);
    expect(result!.error).toBeCloseTo(result!.relativeError * 20, 5);
    // Retained vertices stay on the original sphere, and every retained triangle is nondegenerate.
    const a = new T.Vector3(),
      b = new T.Vector3(),
      c = new T.Vector3();
    for (let i = 0; i < result!.indices.length; i += 3) {
      a.fromArray(positions, result!.indices[i] * 3);
      b.fromArray(positions, result!.indices[i + 1] * 3);
      c.fromArray(positions, result!.indices[i + 2] * 3);
      expect(a.length()).toBeCloseTo(10, 4);
      expect(b.sub(a).cross(c.sub(a)).lengthSq()).toBeGreaterThan(1e-12);
    }
  });
  it("unions face groups by material while retaining each material interface", async () => {
    const geometry = new T.PlaneGeometry(10, 10, 30, 30),
      data = input(geometry);
    data.groups = [];
    // Many face rows form two colored regions; the interface between regions stays locked.
    for (let row = 0; row < 30; row++)
      data.groups.push({
        start: row * 30 * 6,
        count: 30 * 6,
        materialIndex: row < 15 ? 0 : 1,
      });
    const result = await simplifyNavigationGeometry(data);
    expect(result).toBeDefined();
    expect(result!.groups.map((group) => group.materialIndex)).toEqual([0, 1]);
    expect(result!.groups.reduce((sum, group) => sum + group.count, 0)).toBe(
      result!.indices.length,
    );
    // Triangles retain their own side of the original material boundary at y=0.
    for (const group of result!.groups)
      for (let i = group.start; i < group.start + group.count; i += 3) {
        const ys = Array.from(result!.indices.slice(i, i + 3)).map(
          (index) => data.positions[index * 3 + 1],
        );
        if (group.materialIndex === 0)
          expect(Math.min(...ys)).toBeGreaterThanOrEqual(-1e-6);
        else expect(Math.max(...ys)).toBeLessThanOrEqual(1e-6);
      }
    expect(result!.error).toBeLessThan(0.002 * 10); // Includes UV attribute error; geometry remains exactly planar.
    expect(
      Array.from(result!.indices).every(
        (index) => data.positions[index * 3 + 2] === 0,
      ),
    ).toBe(true);
  });
  it("keeps tiny or irreducible topology on the full geometry path", async () => {
    expect(
      await simplifyNavigationGeometry(input(new T.BoxGeometry(1, 1, 1))),
    ).toBeUndefined();
    const geometry = new T.SphereGeometry(1, 8, 4),
      data = input(geometry);
    expect(
      await simplifyNavigationGeometry(data, { maxRelativeError: 0 }),
    ).toBeUndefined();
  });
  it("rejects malformed topology and nonfinite attributes instead of creating unsafe indices", async () => {
    for (const mutate of [
      (data: NavigationLodInput) => {
        data.positions[0] = NaN;
      },
      (data: NavigationLodInput) => {
        data.indices[0] = 1e9;
      },
      (data: NavigationLodInput) => {
        data.groups = [
          { start: 1, count: data.indices.length - 1, materialIndex: 0 },
        ];
      },
      (data: NavigationLodInput) => {
        data.groups = [
          { start: 0, count: data.indices.length, materialIndex: 0 },
          { start: 0, count: 3, materialIndex: 1 },
        ];
      },
      (data: NavigationLodInput) => {
        data.normals = new Float32Array(3);
      },
    ]) {
      const data = input(new T.SphereGeometry(1, 32, 16));
      mutate(data);
      expect(await simplifyNavigationGeometry(data)).toBeUndefined();
    }
  });
  it("does no worker work after cancellation and leaves source geometry intact", async () => {
    const source = new T.InstancedMesh(
        new T.SphereGeometry(1, 32, 16),
        new T.MeshStandardMaterial(),
        2,
      ),
      geometry = source.geometry,
      controller = new AbortController();
    controller.abort();
    const lods = await createNavigationLods([source], controller.signal);
    expect(lods.size).toBe(0);
    expect(source.geometry).toBe(geometry);
    expect(geometry.index!.count).toBeGreaterThan(0);
  });
  it("disposes only the LOD private index while retaining borrowed original GPU attributes", async () => {
    const source = new T.InstancedMesh(
      new T.SphereGeometry(2, 64, 32),
      new T.MeshStandardMaterial(),
      2,
    );
    source.geometry.computeBoundingBox();
    source.geometry.computeBoundingSphere();
    const simplified = (await simplifyNavigationGeometry(
      input(source.geometry),
    ))!;
    const lod = createNavigationLod(source, simplified),
      originalIndex = source.geometry.index,
      originalPosition = source.geometry.getAttribute("position");
    expect(lod.geometry.index).not.toBe(originalIndex);
    expect(lod.geometry.getAttribute("position")).toBe(originalPosition);
    expect(lod.geometry.boundingBox).toEqual(source.geometry.boundingBox);
    expect(lod.geometry.boundingBox).not.toBe(source.geometry.boundingBox);
    let disposalEvents = 0;
    lod.geometry.addEventListener("dispose", () => {
      disposalEvents++;
      expect(Object.keys(lod.geometry.attributes)).toHaveLength(0);
    });
    lod.dispose();
    lod.dispose();
    expect(disposalEvents).toBe(1);
    expect(source.geometry.index).toBe(originalIndex);
    expect(source.geometry.getAttribute("position")).toBe(originalPosition);
  });
  it("terminates in-flight worker work on cancellation without detaching source buffers", async () => {
    let worker: PendingWorker | undefined;
    class PendingWorker {
      onmessage: unknown;
      onerror: unknown;
      terminated = false;
      data?: NavigationLodInput;
      constructor() {
        worker = this;
      }
      postMessage(data: NavigationLodInput) {
        this.data = data;
      }
      terminate() {
        this.terminated = true;
      }
    }
    vi.stubGlobal("Worker", PendingWorker);
    try {
      const source = new T.InstancedMesh(
          new T.SphereGeometry(2, 32, 16),
          new T.MeshStandardMaterial(),
          2,
        ),
        controller = new AbortController();
      const pending = createNavigationLods([source], controller.signal);
      expect(worker?.data?.positions.buffer).not.toBe(
        source.geometry.getAttribute("position").array.buffer,
      );
      expect(worker?.data?.indices.buffer).not.toBe(
        source.geometry.index!.array.buffer,
      );
      controller.abort();
      expect((await pending).size).toBe(0);
      expect(worker?.terminated).toBe(true);
      expect(
        source.geometry.getAttribute("position").array.byteLength,
      ).toBeGreaterThan(0);
      expect(source.geometry.index!.array.byteLength).toBeGreaterThan(0);
    } finally {
      vi.unstubAllGlobals();
    }
  });
});
