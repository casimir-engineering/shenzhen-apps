import { describe, expect, it, vi } from "vitest";
import {
  BatchedMesh,
  BoxGeometry,
  InstancedMesh,
  Matrix4,
  Mesh,
  MeshBasicMaterial,
  MeshPhongMaterial,
  MeshStandardMaterial,
  Plane,
  ShaderLib,
  Texture,
  Vector3,
} from "three";
import type { WebGLProgramParametersWithUniforms, WebGLRenderer } from "three";
import { createGpuMergedMesh } from "../src/core/gpu-merged-mesh";
import { createRenderBatches } from "../src/core/render-batches";

function fixture() {
  const material = new MeshStandardMaterial();
  const fallback = new BatchedMesh(2, 48, 72, material);
  const first = fallback.addGeometry(new BoxGeometry());
  const second = fallback.addGeometry(new BoxGeometry(2, 3, 4));
  const a = fallback.addInstance(first);
  const b = fallback.addInstance(second);
  const spans = [first, second].map((id, i) => ({
    ...fallback.getGeometryRangeAt(id)!,
    instanceId: i,
  }));
  const merged = createGpuMergedMesh(fallback, spans);
  return { fallback, merged, a, b };
}

describe("single-draw GPU merged geometry", () => {
  it("shares vertex/index buffers and stores one transformation ID per vertex", () => {
    const { fallback, merged } = fixture();
    expect(merged.object).toBeInstanceOf(Mesh);
    expect(merged.object).not.toBeInstanceOf(BatchedMesh);
    expect(merged.object.geometry.getAttribute("position")).toBe(
      fallback.geometry.getAttribute("position"),
    );
    expect(merged.object.geometry.getAttribute("normal")).toBe(
      fallback.geometry.getAttribute("normal"),
    );
    expect(merged.object.geometry.index).toBe(fallback.geometry.index);
    expect([
      ...merged.object.geometry.getAttribute("mergedPartId").array,
    ]).toEqual([...Array(24).fill(0), ...Array(24).fill(1)]);
    expect(fallback.geometry.getAttribute("mergedPartId")).toBeUndefined();
    expect(merged.object.visible).toBe(true);
    expect(fallback.visible).toBe(false);
    merged.dispose();
    fallback.dispose();
  });

  it("updates translated/scaled and hidden occurrences entirely in the texture", () => {
    const { fallback, merged, a, b } = fixture();
    const positions = merged.object.geometry.getAttribute("position");
    const snapshot = positions.array.slice();
    const version = positions.version;
    const matrix = new Matrix4().makeScale(2, 3, 4).setPosition(20, 30, 40);
    merged.setMatrixAt(a, matrix);
    merged.setMatrixAt(b, matrix, false);
    const data = merged.matrixTexture.image.data as Float32Array;
    expect([...data.slice(0, 16)]).toEqual(matrix.elements);
    expect([...data.slice(16, 32)]).toEqual(Array(16).fill(0));
    expect(positions.array).toEqual(snapshot);
    expect(positions.version).toBe(version);
    expect(merged.matrixTexture.image.width % 4).toBe(0);
    merged.dispose();
    fallback.dispose();
  });

  it.each([
    ["standard", MeshStandardMaterial, ShaderLib.standard.vertexShader],
    ["phong", MeshPhongMaterial, ShaderLib.phong.vertexShader],
    ["basic", MeshBasicMaterial, ShaderLib.basic.vertexShader],
  ] as const)(
    "uses native %s normal/world/clipping shader chunks",
    (_, Constructor, vertexShader) => {
      const fallback = new BatchedMesh(1, 24, 36, new Constructor());
      const id = fallback.addGeometry(new BoxGeometry());
      fallback.addInstance(id);
      const merged = createGpuMergedMesh(fallback, [
        { ...fallback.getGeometryRangeAt(id)!, instanceId: 0 },
      ]);
      const shader = {
        vertexShader,
        uniforms: {},
      } as WebGLProgramParametersWithUniforms;
      merged.object.material.onBeforeCompile(shader, {} as WebGLRenderer);
      expect(merged.object.material.defines?.USE_BATCHING).toBe(1);
      expect(shader.uniforms.batchingTexture.value).toBe(merged.matrixTexture);
      expect(shader.vertexShader).toContain(
        "getBatchingMatrix( mergedPartId )",
      );
      expect(shader.vertexShader).toContain("batchingMatrix[3][3] == 0.0");
      expect(shader.vertexShader).toContain("#include <batching_pars_vertex>");
      expect(shader.vertexShader).toContain("#include <project_vertex>");
      expect(shader.vertexShader).toContain("#include <worldpos_vertex>");
      expect(shader.vertexShader).toContain(
        "#include <clipping_planes_vertex>",
      );
      expect(shader.vertexShader).not.toContain("#include <batching_vertex>");
      merged.dispose();
      fallback.dispose();
    },
  );

  it("switches to sorted transparent fallback and returns to a merged opaque draw", () => {
    const { fallback, merged } = fixture();
    const material = fallback.material as MeshStandardMaterial;
    material.transparent = true;
    material.opacity = 0.35;
    material.depthWrite = false;
    material.clippingPlanes = [new Plane(new Vector3(0, 0, 1), 2)];
    merged.syncMaterial();
    expect(merged.object.visible).toBe(false);
    expect(fallback.visible).toBe(true);
    expect(merged.object.material.opacity).toBe(0.35);
    expect(merged.object.material.depthWrite).toBe(false);
    expect(merged.object.material.clippingPlanes).toBe(material.clippingPlanes);
    material.transparent = false;
    merged.syncMaterial();
    expect(merged.object.visible).toBe(true);
    expect(fallback.visible).toBe(false);
    merged.dispose();
    fallback.dispose();
  });

  it("retains textures and vertex colors without owning the material's textures", () => {
    const texture = new Texture();
    const material = new MeshStandardMaterial({
      map: texture,
      vertexColors: true,
      alphaTest: 0.5,
    });
    const fallback = new BatchedMesh(1, 24, 36, material);
    const id = fallback.addGeometry(new BoxGeometry());
    fallback.addInstance(id);
    const merged = createGpuMergedMesh(fallback, [
      { ...fallback.getGeometryRangeAt(id)!, instanceId: 0 },
    ]);
    expect((merged.object.material as MeshStandardMaterial).map).toBe(texture);
    expect(merged.object.material.vertexColors).toBe(true);
    expect(merged.object.material.alphaTest).toBe(0.5);
    const disposeTexture = vi.spyOn(texture, "dispose");
    const disposeMatrix = vi.spyOn(merged.matrixTexture, "dispose");
    merged.dispose();
    merged.dispose();
    expect(disposeTexture).not.toHaveBeenCalled();
    expect(disposeMatrix).toHaveBeenCalledTimes(1);
    fallback.dispose();
  });
});

describe("merged render-layer integration", () => {
  function original() {
    return new InstancedMesh(new BoxGeometry(), new MeshStandardMaterial(), 1);
  }

  it.each([true, false])(
    "merges unique opaque sources with multi-draw=%s",
    (multiDraw) => {
      const a = original(),
        b = original();
      const layer = createRenderBatches([a, b], { multiDraw });
      expect(layer.stats.mergedChunkCount).toBe(1);
      expect(layer.objects).toHaveLength(2);
      expect(layer.objects.filter((object) => object.visible)).toHaveLength(1);
      expect(layer.objects.find((object) => object.visible)).not.toBeInstanceOf(
        BatchedMesh,
      );
      expect(layer.renderedInstances.size).toBe(0);
      a.setMatrixAt(0, new Matrix4().makeTranslation(7, 8, 9));
      a.instanceMatrix.needsUpdate = true;
      layer.syncFromSources();
      a.material.opacity = b.material.opacity = 0.4;
      a.material.transparent = b.material.transparent = true;
      layer.syncMaterials();
      const visible = layer.objects.filter((object) => object.visible);
      expect(visible).toHaveLength(1);
      expect(visible[0]).toBeInstanceOf(BatchedMesh);
      expect((visible[0] as BatchedMesh).sortObjects).toBe(true);
      const matrix = new Matrix4();
      (visible[0] as BatchedMesh).getMatrixAt(0, matrix);
      expect(matrix.elements.slice(12, 15)).toEqual([7, 8, 9]);
      layer.dispose();
    },
  );

  it("keeps repeated/shared geometry and initially transparent sources on native paths", () => {
    const a = original();
    const b = new InstancedMesh(a.geometry, new MeshStandardMaterial(), 1);
    const repeated = new InstancedMesh(
      new BoxGeometry(),
      new MeshStandardMaterial(),
      4,
    );
    const alpha = original();
    alpha.material.transparent = true;
    const layer = createRenderBatches([a, b, repeated, alpha], {
      multiDraw: true,
    });
    expect(layer.stats.mergedChunkCount).toBe(0);
    expect(
      layer.objects.every(
        (object) =>
          object instanceof BatchedMesh || object instanceof InstancedMesh,
      ),
    ).toBe(true);
    layer.dispose();
  });
});
