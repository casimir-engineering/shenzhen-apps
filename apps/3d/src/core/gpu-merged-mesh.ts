import {
  BatchedMesh,
  BufferAttribute,
  BufferGeometry,
  DataTexture,
  FloatType,
  Material,
  Mesh,
  RGBAFormat,
} from "three";
import type { Matrix4 } from "three";

export interface MergedPartSpan {
  vertexStart: number;
  vertexCount: number;
  instanceId: number;
}

/**
 * A single GPU draw for uniquely positioned geometry, sharing the fallback's
 * vertex/index buffers. The fallback retains sorted transparency rendering.
 * Remove both objects before disposing either rendering path.
 */
export function createGpuMergedMesh(
  fallback: BatchedMesh,
  spans: readonly MergedPartSpan[],
) {
  const geometry = new BufferGeometry();
  for (const [name, attribute] of Object.entries(fallback.geometry.attributes))
    geometry.setAttribute(name, attribute);
  geometry.setIndex(fallback.geometry.index);
  geometry.drawRange = { ...fallback.geometry.drawRange };
  const ids = new Float32Array(geometry.getAttribute("position").count);
  for (const span of spans)
    ids.fill(
      span.instanceId,
      span.vertexStart,
      span.vertexStart + span.vertexCount,
    );
  geometry.setAttribute("mergedPartId", new BufferAttribute(ids, 1));

  // Four RGBA texels per matrix; rows never split a matrix.
  const size = Math.max(
    4,
    Math.ceil(Math.sqrt(fallback.maxInstanceCount * 4) / 4) * 4,
  );
  const data = new Float32Array(size * size * 4);
  const matrixTexture = new DataTexture(
    data,
    size,
    size,
    RGBAFormat,
    FloatType,
  );
  const origin = fallback.material as Material;
  const material = origin.clone();
  material.defines = { ...material.defines, USE_BATCHING: 1 };
  material.onBeforeCompile = (shader) => {
    shader.uniforms.batchingTexture = { value: matrixTexture };
    shader.vertexShader = `attribute float mergedPartId;\n${shader.vertexShader}`;
    shader.vertexShader = shader.vertexShader.replace(
      "#include <batching_vertex>",
      `mat4 batchingMatrix = getBatchingMatrix( mergedPartId );
// Invisible occurrences have a zero homogeneous component. Clip their entire
// primitive before native normal handling divides by zero scale.
if ( batchingMatrix[3][3] == 0.0 ) {
  gl_Position = vec4( 2.0, 2.0, 2.0, 1.0 );
  return;
}`,
    );
  };
  material.customProgramCacheKey = () => "gpu-merged-mesh-v1";
  const object = new Mesh(geometry, material);
  object.name = "Merged GPU material chunk";
  object.matrixAutoUpdate = false;
  object.frustumCulled = false;
  object.raycast = () => {};
  let disposed = false;

  function syncMaterial() {
    const recompile =
      material.transparent !== origin.transparent ||
      (material.clippingPlanes?.length ?? 0) !==
        (origin.clippingPlanes?.length ?? 0) ||
      material.clipIntersection !== origin.clipIntersection;
    material.opacity = origin.opacity;
    material.transparent = origin.transparent;
    material.depthWrite = origin.depthWrite;
    material.colorWrite = origin.colorWrite;
    material.polygonOffset = origin.polygonOffset;
    material.polygonOffsetFactor = origin.polygonOffsetFactor;
    material.polygonOffsetUnits = origin.polygonOffsetUnits;
    material.visible = origin.visible;
    material.clippingPlanes = origin.clippingPlanes;
    material.clipIntersection = origin.clipIntersection;
    material.clipShadows = origin.clipShadows;
    if (recompile) material.needsUpdate = true;
    object.visible = !origin.transparent;
    fallback.visible = origin.transparent;
  }

  syncMaterial();
  return {
    object,
    matrixTexture,
    setMatrixAt(instanceId: number, matrix: Matrix4, visible = true) {
      if (disposed) return;
      const offset = instanceId * 16;
      if (visible) matrix.toArray(data, offset);
      else data.fill(0, offset, offset + 16);
      matrixTexture.needsUpdate = true;
    },
    syncMaterial,
    dispose() {
      if (disposed) return;
      disposed = true;
      // Both rendering paths are detached. This wrapper also frees shared
      // vertex buffers if its fallback geometry was never rendered/registered.
      geometry.dispose();
      material.dispose();
      matrixTexture.dispose();
    },
  };
}

export type GpuMergedMesh = ReturnType<typeof createGpuMergedMesh>;
