import * as T from "three";
import type {
  NavigationLodInput,
  NavigationLodResult,
} from "./navigation-lod-kernel";

export interface NavigationLod {
  source: T.InstancedMesh;
  geometry: T.BufferGeometry;
  /** Local-coordinate meshoptimizer error metric; multiply by maximum instance/world scale before projection. */
  error: number;
  relativeError: number;
  originalTriangleCount: number;
  triangleCount: number;
  dispose(): void;
}
function copyAttribute(
  attribute: T.BufferAttribute | T.InterleavedBufferAttribute | undefined,
): Float32Array | undefined {
  if (!attribute) return;
  const result = new Float32Array(attribute.count * attribute.itemSize);
  for (let vertex = 0; vertex < attribute.count; vertex++)
    for (let component = 0; component < attribute.itemSize; component++)
      result[vertex * attribute.itemSize + component] = attribute.getComponent(
        vertex,
        component,
      );
  return result;
}
function inputFor(
  source: T.InstancedMesh,
  id: number,
): NavigationLodInput | undefined {
  const geometry = source.geometry,
    position = geometry.getAttribute("position"),
    index = geometry.index;
  if (
    !index ||
    !position ||
    position.itemSize !== 3 ||
    index.count < 96 ||
    geometry.drawRange.start !== 0 ||
    geometry.drawRange.count < index.count ||
    Object.values(geometry.morphAttributes).some(
      (attributes) => attributes.length,
    )
  )
    return;
  const groups = Array.isArray(source.material)
    ? geometry.groups.map((group) => ({
        start: group.start,
        count: group.count,
        materialIndex: group.materialIndex ?? 0,
      }))
    : [{ start: 0, count: index.count, materialIndex: 0 }];
  return {
    id,
    positions: copyAttribute(position)!,
    indices: new Uint32Array(index.array),
    normals: copyAttribute(geometry.getAttribute("normal")),
    uvs: copyAttribute(geometry.getAttribute("uv")),
    colors: copyAttribute(geometry.getAttribute("color")),
    colorSize: geometry.getAttribute("color")?.itemSize,
    groups,
  };
}
export function createNavigationLod(
  source: T.InstancedMesh,
  result: NavigationLodResult,
): NavigationLod {
  const geometry = new T.BufferGeometry(),
    original = source.geometry;
  for (const [name, attribute] of Object.entries(original.attributes))
    geometry.setAttribute(name, attribute);
  geometry.setIndex(new T.BufferAttribute(result.indices, 1));
  for (const group of result.groups)
    geometry.addGroup(group.start, group.count, group.materialIndex);
  geometry.boundingBox = original.boundingBox?.clone() ?? null;
  geometry.boundingSphere = original.boundingSphere?.clone() ?? null;
  let disposed = false;
  return {
    source,
    geometry,
    error: result.error,
    relativeError: result.relativeError,
    originalTriangleCount: result.originalTriangleCount,
    triangleCount: result.triangleCount,
    dispose() {
      if (disposed) return;
      disposed = true;
      // Renderer disposal must release only the private LOD index, never borrowed vertex GPU buffers.
      for (const name of Object.keys(geometry.attributes))
        geometry.deleteAttribute(name);
      geometry.dispose();
    },
  };
}
/** Optional rendering acceleration: a failed/aborted worker always leaves original geometry usable. */
export async function createNavigationLods(
  sources: readonly T.InstancedMesh[],
  signal?: AbortSignal,
): Promise<Map<T.InstancedMesh, NavigationLod>> {
  const result = new Map<T.InstancedMesh, NavigationLod>();
  if (signal?.aborted || !sources.length || typeof Worker === "undefined")
    return result;
  const worker = new Worker(
    new URL("../workers/navigation-lod.worker.ts", import.meta.url),
    { type: "module" },
  );
  let aborted = false;
  const abort = () => {
    aborted = true;
    worker.terminate();
  };
  signal?.addEventListener("abort", abort, { once: true });
  try {
    for (let id = 0; id < sources.length && !aborted; id++) {
      const source = sources[id],
        input = inputFor(source, id);
      if (!input) continue;
      const simplified = await new Promise<NavigationLodResult | undefined>(
        (resolve) => {
          const stop = () => resolve(undefined);
          signal?.addEventListener("abort", stop, { once: true });
          const done = (value: NavigationLodResult | undefined) => {
            signal?.removeEventListener("abort", stop);
            resolve(value);
          };
          worker.onmessage = ({ data }) => done(data.result);
          worker.onerror = () => {
            aborted = true;
            done(undefined);
          };
          const transfers = [
            input.positions.buffer,
            input.indices.buffer,
            ...[input.normals, input.uvs, input.colors]
              .filter((attribute): attribute is Float32Array => !!attribute)
              .map((attribute) => attribute.buffer),
          ];
          worker.postMessage(input, transfers);
        },
      );
      if (simplified && !aborted)
        result.set(source, createNavigationLod(source, simplified));
    }
  } finally {
    worker.terminate();
    signal?.removeEventListener("abort", abort);
    if (aborted) {
      for (const lod of result.values()) lod.dispose();
      result.clear();
    }
  }
  return result;
}
