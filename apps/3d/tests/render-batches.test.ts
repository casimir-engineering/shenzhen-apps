import { describe, expect, it, vi } from "vitest";
import {
  BatchedMesh,
  BoxGeometry,
  BufferAttribute,
  BufferGeometry,
  Color,
  InstancedMesh,
  Matrix4,
  MeshBasicMaterial,
  MeshStandardMaterial,
  Plane,
  ShaderMaterial,
  Texture,
  Vector3,
} from "three";
import { createRenderBatches } from "../src/core/render-batches";

function source(
  geometry = new BoxGeometry(),
  material = new MeshStandardMaterial(),
  count = 1,
) {
  return new InstancedMesh(geometry, material, count);
}

function faceGroups() {
  const geometry = new BoxGeometry();
  geometry.clearGroups();
  for (let start = 0; start < 36; start += 3)
    geometry.addGroup(start, 3, (start / 3) % 2);
  return new InstancedMesh(
    geometry,
    [
      new MeshStandardMaterial({ color: "red" }),
      new MeshStandardMaterial({ color: "blue" }),
    ],
    200,
  );
}

describe("render-only material batching", () => {
  it("combines distinct geometries with compatible materials without changing originals", () => {
    const a = source();
    const b = source(new BoxGeometry(2, 3, 4));
    const indices = a.geometry.index!.array.slice();
    const groups = a.geometry.groups.map((group) => ({ ...group }));
    const layer = createRenderBatches([a, b], {
      multiDraw: true,
      mergeUniqueGeometries: false,
    });
    expect(layer.objects).toHaveLength(1);
    expect(layer.objects[0]).toBeInstanceOf(BatchedMesh);
    expect((layer.objects[0] as BatchedMesh).instanceCount).toBe(2);
    expect(layer.stats.copiedVertices).toBe(48);
    expect(a.geometry.index!.array).toEqual(indices);
    expect(a.geometry.groups).toEqual(groups);
    expect(layer.objects[0].raycast).not.toBe(a.raycast);
    layer.dispose();
  });

  it("copies shared geometry once across source proxies and occurrences", () => {
    const a = source(new BoxGeometry(), new MeshStandardMaterial(), 3);
    const b = source(a.geometry, new MeshStandardMaterial(), 2);
    const layer = createRenderBatches([a, b], {
      multiDraw: true,
      mergeUniqueGeometries: false,
    });
    const batch = layer.objects[0] as BatchedMesh;
    expect(batch.instanceCount).toBe(5);
    expect(layer.stats.copiedVertices).toBe(24);
    expect(layer.stats.copiedIndices).toBe(36);
    layer.dispose();
  });

  it("combines CAD face groups per material while retaining high-count hardware instancing", () => {
    const original = faceGroups();
    const originalIndex = original.geometry.index!.array.slice();
    const layer = createRenderBatches([original], {
      multiDraw: true,
      mergeUniqueGeometries: false,
    });
    const rendered = layer.renderedInstances.get(original)!;
    expect(rendered).not.toBe(original);
    expect(rendered.geometry).not.toBe(original.geometry);
    expect(rendered.instanceMatrix).toBe(original.instanceMatrix);
    expect(rendered.geometry.getAttribute("position")).toBe(
      original.geometry.getAttribute("position"),
    );
    expect(rendered.geometry.groups).toHaveLength(2);
    expect(rendered.geometry.groups.map((group) => group.count)).toEqual([
      18, 18,
    ]);
    expect(original.geometry.groups).toHaveLength(12);
    expect(original.geometry.index!.array).toEqual(originalIndex);
    expect([...rendered.geometry.index!.array].sort((a, b) => a - b)).toEqual(
      [...originalIndex].sort((a, b) => a - b),
    );
    layer.dispose();
  });

  it("uses separate render proxies even without multi-draw and permits independent LOD geometry", () => {
    const original = source();
    const geometry = original.geometry;
    const layer = createRenderBatches([original], {
      multiDraw: false,
      mergeUniqueGeometries: false,
    });
    const rendered = layer.renderedInstances.get(original)!;
    expect(layer.objects).toEqual([rendered]);
    expect(rendered.instanceMatrix).toBe(original.instanceMatrix);
    rendered.geometry = new BoxGeometry(0.5, 0.5, 0.5);
    expect(original.geometry).toBe(geometry);
    rendered.geometry.dispose();
    layer.dispose();
  });

  it("keeps colors, textures, transparency and custom shaders in compatible buckets", () => {
    const map = new Texture();
    const a = source(new BoxGeometry(), new MeshStandardMaterial({ map }));
    const b = source(new BoxGeometry(), new MeshStandardMaterial({ map }));
    const c = source(
      new BoxGeometry(),
      new MeshStandardMaterial({ color: "red" }),
    );
    const d = source(
      new BoxGeometry(),
      new MeshStandardMaterial({ transparent: true, opacity: 0.3 }),
    );
    const custom = new InstancedMesh(
      new BoxGeometry(),
      new ShaderMaterial(),
      1,
    );
    const layer = createRenderBatches([a, b, c, d, custom], {
      multiDraw: true,
      mergeUniqueGeometries: false,
    });
    expect(layer.stats.materialBatchCount).toBe(3);
    expect(layer.renderedInstances.has(custom)).toBe(true);
    expect(layer.renderedInstances.get(custom)!.material).toBe(custom.material);
    const batches = layer.objects.filter(
      (object) => object instanceof BatchedMesh,
    );
    expect(
      batches.find(
        (batch) => (batch.material as MeshStandardMaterial).map === map,
      )!.instanceCount,
    ).toBe(2);
    expect(
      batches.find((batch) =>
        (batch.material as MeshStandardMaterial).color.equals(new Color("red")),
      ),
    ).toBeDefined();
    expect(
      batches.find(
        (batch) => (batch.material as MeshStandardMaterial).opacity === 0.3,
      )!.sortObjects,
    ).toBe(true);
    layer.dispose();
  });

  it("updates transform, hide, count and section/opacity without rebuilding buffers", () => {
    const original = source(new BoxGeometry(), new MeshStandardMaterial(), 2);
    const layer = createRenderBatches([original], {
      multiDraw: true,
      mergeUniqueGeometries: false,
    });
    const batch = layer.objects[0] as BatchedMesh;
    const geometry = batch.geometry;
    original.position.set(10, 0, 0);
    original.setMatrixAt(0, new Matrix4().makeTranslation(2, 3, 4));
    original.setMatrixAt(1, new Matrix4().makeScale(0, 0, 0));
    layer.syncFromSources();
    const matrix = new Matrix4();
    batch.getMatrixAt(0, matrix);
    expect(matrix.elements.slice(12, 15)).toEqual([12, 3, 4]);
    expect(batch.getVisibleAt(1)).toBe(false);
    original.count = 0;
    layer.syncFromSources();
    expect(batch.getVisibleAt(0)).toBe(false);
    original.material.clippingPlanes = [new Plane(new Vector3(0, 0, 1), 3)];
    original.material.opacity = 0.4;
    original.material.transparent = true;
    original.material.depthWrite = false;
    layer.syncMaterials();
    const material = batch.material as MeshStandardMaterial;
    expect(material.clippingPlanes).toBe(original.material.clippingPlanes);
    expect(material.opacity).toBe(0.4);
    expect(material.depthWrite).toBe(false);
    expect(batch.sortObjects).toBe(true);
    expect(batch.geometry).toBe(geometry);
    layer.dispose();
  });

  it("respects draw ranges and grouped material subsets in render copies", () => {
    const original = faceGroups();
    original.count = 1;
    original.geometry.setDrawRange(3, 9);
    const layer = createRenderBatches([original], {
      multiDraw: true,
      mergeUniqueGeometries: false,
    });
    expect(layer.stats.copiedIndices).toBe(9);
    expect(layer.stats.materialBatchCount).toBe(2);
    expect(original.geometry.drawRange).toEqual({ start: 3, count: 9 });
    layer.dispose();
  });

  it("splits bounded batches rather than reserving a giant buffer", () => {
    const originals = Array.from({ length: 5 }, () => source());
    const layer = createRenderBatches(originals, {
      multiDraw: true,
      mergeUniqueGeometries: false,
      maxVerticesPerBatch: 48,
      maxInstancesPerBatch: 2,
    });
    expect(layer.stats.materialBatchCount).toBe(3);
    for (const object of layer.objects) {
      expect(
        object.geometry.getAttribute("position").count,
      ).toBeLessThanOrEqual(48);
      expect((object as BatchedMesh).instanceCount).toBeLessThanOrEqual(2);
    }
    layer.dispose();
  });

  it("splits many identical source geometries by instance capacity", () => {
    const geometry = new BoxGeometry();
    const originals = Array.from({ length: 5 }, () => source(geometry));
    const layer = createRenderBatches(originals, {
      multiDraw: true,
      mergeUniqueGeometries: false,
      maxInstancesPerBatch: 2,
    });
    expect(layer.stats.materialBatchCount).toBe(3);
    expect(layer.stats.copiedVertices).toBe(72);
    layer.dispose();
  });

  it("preserves nonindexed geometry and normalized vertex colors", () => {
    const geometry = new BufferGeometry();
    geometry.setAttribute(
      "position",
      new BufferAttribute(new Float32Array([0, 0, 0, 1, 0, 0, 0, 1, 0]), 3),
    );
    geometry.setAttribute(
      "color",
      new BufferAttribute(
        new Uint8Array([255, 0, 0, 0, 255, 0, 0, 0, 255]),
        3,
        true,
      ),
    );
    const original = new InstancedMesh(
      geometry,
      new MeshBasicMaterial({ vertexColors: true }),
      1,
    );
    const layer = createRenderBatches([original], {
      multiDraw: true,
      mergeUniqueGeometries: false,
    });
    expect(layer.objects[0].geometry.getAttribute("color").array).toEqual(
      geometry.getAttribute("color").array,
    );
    expect(geometry.index).toBeNull();
    layer.dispose();
  });

  it("disposes owned resources once without disposing originals or textures", () => {
    const a = source();
    const repeated = faceGroups();
    const disposeGeometry = vi.spyOn(a.geometry, "dispose");
    const disposeMaterial = vi.spyOn(a.material, "dispose");
    const disposeRepeatedGeometry = vi.spyOn(repeated.geometry, "dispose");
    const layer = createRenderBatches([a, repeated], {
      multiDraw: true,
      mergeUniqueGeometries: false,
    });
    const owned = layer.objects[0];
    const disposeOwned = vi.spyOn(owned, "dispose");
    layer.dispose();
    layer.dispose();
    expect(disposeGeometry).not.toHaveBeenCalled();
    expect(disposeMaterial).not.toHaveBeenCalled();
    expect(disposeRepeatedGeometry).not.toHaveBeenCalled();
    expect(disposeOwned).toHaveBeenCalledTimes(1);
  });
});
