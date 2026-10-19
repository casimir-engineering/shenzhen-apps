import {
  BatchedMesh,
  BufferAttribute,
  BufferGeometry,
  InstancedMesh,
  Material,
  Matrix4,
  MeshBasicMaterial,
  MeshPhongMaterial,
  MeshStandardMaterial,
  Mesh,
} from "three";
import type { TypedArrayConstructor } from "three";
import {
  createGpuMergedMesh,
  type GpuMergedMesh,
  type MergedPartSpan,
} from "./gpu-merged-mesh";

export interface RenderBatchOptions {
  multiDraw: boolean;
  /** Keep large repeated geometries on the hardware instancing path. */
  preserveInstancingAbove?: number;
  maxVerticesPerBatch?: number;
  maxIndicesPerBatch?: number;
  maxInstancesPerBatch?: number;
  mergeUniqueGeometries?: boolean;
}

type Range = { start: number; count: number };
interface Piece {
  geometry: BufferGeometry;
  ranges: Range[];
  sources: InstancedMesh[];
  instances: number;
}
interface Bucket {
  material: Material;
  pieces: Map<string, Piece>;
  tails: Map<string, Piece>;
  merged: boolean;
}
interface InstanceLink {
  batch: BatchedMesh;
  first: number;
  count: number;
}

const supportedMaterials = new Set([
  MeshBasicMaterial,
  MeshPhongMaterial,
  MeshStandardMaterial,
]);
const ignoredMaterialKeys = new Set([
  "uuid",
  "id",
  "name",
  "userData",
  "version",
  "_listeners",
]);

function materialKey(material: Material): string | undefined {
  if (
    !supportedMaterials.has(material.constructor as typeof MeshBasicMaterial) ||
    material.onBeforeCompile !== Material.prototype.onBeforeCompile ||
    material.customProgramCacheKey !==
      Material.prototype.customProgramCacheKey ||
    material.onBeforeRender !== Material.prototype.onBeforeRender
  )
    return undefined;
  const values = material as unknown as Record<string, unknown>;
  return JSON.stringify(
    Object.keys(material)
      .sort()
      .filter((key) => !ignoredMaterialKeys.has(key))
      .map((key) => {
        const value = values[key];
        return [
          key,
          value && typeof value === "object" && "isTexture" in value
            ? (value as unknown as { uuid: string }).uuid
            : value,
        ];
      }),
  );
}

function geometryKey(geometry: BufferGeometry): string | undefined {
  if (
    !geometry.getAttribute("position") ||
    Object.values(geometry.morphAttributes).some(
      (attributes) => attributes.length,
    )
  )
    return undefined;
  const attributes = Object.keys(geometry.attributes)
    .sort()
    .map((name) => {
      const attribute = geometry.getAttribute(name);
      if ("isInstancedBufferAttribute" in attribute) return undefined;
      return [
        name,
        attribute.itemSize,
        attribute.normalized,
        attribute.array.constructor.name,
        "gpuType" in attribute ? attribute.gpuType : undefined,
      ];
    });
  if (attributes.some((value) => value === undefined)) return undefined;
  // Pieces are indexed even when their input was not.
  return JSON.stringify(attributes);
}

function rangesByMaterial(source: InstancedMesh) {
  const geometry = source.geometry;
  const total =
    geometry.index?.count ?? geometry.getAttribute("position").count;
  const drawStart = Math.max(0, geometry.drawRange.start);
  const drawEnd = Math.min(total, drawStart + geometry.drawRange.count);
  const materials = Array.isArray(source.material)
    ? source.material
    : [source.material];
  const result = new Map<Material, Range[]>();
  const groups = Array.isArray(source.material)
    ? geometry.groups
    : [{ start: 0, count: total, materialIndex: 0 }];
  for (const group of groups) {
    const material = materials[group.materialIndex ?? 0];
    if (!material) continue;
    const start = Math.max(drawStart, group.start);
    const end = Math.min(drawEnd, group.start + group.count);
    if (end <= start) continue;
    const ranges = result.get(material) ?? [];
    ranges.push({ start, count: end - start });
    result.set(material, ranges);
  }
  return result;
}

/** Compact one material's triangles without touching the original triangle order. */
function compactPiece(piece: Piece) {
  const source = piece.geometry;
  const remap = new Map<number, number>();
  const vertices: number[] = [];
  const indices = new Uint32Array(
    piece.ranges.reduce((sum, range) => sum + range.count, 0),
  );
  let offset = 0;
  for (const range of piece.ranges) {
    for (let i = range.start, end = range.start + range.count; i < end; i++) {
      const original = source.index ? source.index.getX(i) : i;
      let mapped = remap.get(original);
      if (mapped === undefined) {
        mapped = vertices.length;
        remap.set(original, mapped);
        vertices.push(original);
      }
      indices[offset++] = mapped;
    }
  }
  const geometry = new BufferGeometry();
  for (const name of Object.keys(source.attributes)) {
    const input = source.getAttribute(name);
    const ArrayType = input.array.constructor as TypedArrayConstructor;
    const output = new BufferAttribute(
      new ArrayType(vertices.length * input.itemSize),
      input.itemSize,
      input.normalized,
    );
    if ("gpuType" in input) output.gpuType = input.gpuType;
    for (let i = 0; i < vertices.length; i++) {
      for (let c = 0; c < input.itemSize; c++)
        output.setComponent(i, c, input.getComponent(vertices[i], c));
    }
    geometry.setAttribute(name, output);
  }
  geometry.setIndex(new BufferAttribute(indices, 1));
  return geometry;
}

/**
 * Sources remain the authoritative picking/measurement proxies outside the
 * rendered scene. Remove all returned objects before disposing this layer.
 * Geometry, material and instance-buffer identities/capacities remain fixed;
 * recreate the layer after replacing them. Updates never run per frame.
 */
export function createRenderBatches(
  sources: readonly InstancedMesh[],
  options: RenderBatchOptions,
) {
  const maxVertices = options.maxVerticesPerBatch ?? 1_000_000;
  const maxIndices = options.maxIndicesPerBatch ?? 3_000_000;
  const maxInstances = options.maxInstancesPerBatch ?? 65_536;
  const preserveAbove = options.preserveInstancingAbove ?? 128;
  const objects: Mesh[] = [];
  const mergedMeshes = new Map<BatchedMesh, GpuMergedMesh>();
  const geometryOccurrences = new Map<BufferGeometry, number>();
  for (const source of sources)
    geometryOccurrences.set(
      source.geometry,
      (geometryOccurrences.get(source.geometry) ?? 0) + 1,
    );
  const batchedSources = new Set<InstancedMesh>();
  const buckets = new Map<string, Bucket>();
  const materialKeys = new WeakMap<Material, string | undefined>();
  const internedMaterialKeys = new Map<string, string>();
  const materialCopies = new Map<string, Material>();
  const materialOrigins = new Map<Material, Material>();
  const links = new Map<InstancedMesh, InstanceLink[]>();
  const regrouped: { source: InstancedMesh; object: InstancedMesh }[] = [];
  const renderedInstances = new Map<InstancedMesh, InstancedMesh>();
  const ownedGeometries: BufferGeometry[] = [];
  const ownedInstances: InstancedMesh[] = [];
  const borrowedAttributeReferences = new Map<object, number>();
  const matrix = new Matrix4();
  const world = new Matrix4();
  let disposed = false;
  const stats = {
    sourceCount: sources.length,
    batchedSourceCount: 0,
    regroupedSourceCount: 0,
    fallbackSourceCount: 0,
    materialBatchCount: 0,
    copiedVertices: 0,
    copiedIndices: 0,
    mergedChunkCount: 0,
  };

  const keyForMaterial = (material: Material) => {
    if (!materialKeys.has(material)) {
      let key = materialKey(material);
      if (key !== undefined) {
        const existing = internedMaterialKeys.get(key);
        if (existing !== undefined) key = existing;
        else internedMaterialKeys.set(key, key);
      }
      materialKeys.set(material, key);
    }
    return materialKeys.get(material);
  };
  const copyMaterial = (material: Material, key: string) => {
    let clone = materialCopies.get(key);
    if (!clone) {
      clone = material.clone();
      materialCopies.set(key, clone);
      materialOrigins.set(clone, material);
    }
    return clone;
  };

  const preserveSource = (
    source: InstancedMesh,
    ranges?: Map<Material, Range[]>,
    keys?: Map<Material, string>,
  ) => {
    // Reorder only the render index: CAD often has hundreds of face groups but
    // only a few actual materials. Keep one contiguous group per material.
    const geometry = new BufferGeometry();
    for (const name of Object.keys(source.geometry.attributes)) {
      const attribute = source.geometry.getAttribute(name);
      geometry.setAttribute(name, attribute);
      borrowedAttributeReferences.set(
        attribute,
        (borrowedAttributeReferences.get(attribute) ?? 0) + 1,
      );
    }
    let materials: Material | Material[] = source.material;
    const regroup =
      ranges &&
      keys &&
      source.geometry.groups.length > ranges.size &&
      Array.isArray(source.material);
    if (regroup) {
      const indices = new Uint32Array(
        [...ranges.values()]
          .flat()
          .reduce((sum, range) => sum + range.count, 0),
      );
      const copies: Material[] = [];
      let offset = 0;
      for (const [material, spans] of ranges) {
        const start = offset;
        for (const span of spans)
          for (let i = span.start, end = i + span.count; i < end; i++)
            indices[offset++] = source.geometry.index
              ? source.geometry.index.getX(i)
              : i;
        geometry.addGroup(start, offset - start, copies.length);
        copies.push(copyMaterial(material, keys.get(material)!));
      }
      materials = copies;
      geometry.setIndex(new BufferAttribute(indices, 1));
    } else {
      geometry.setIndex(source.geometry.index);
      geometry.groups = source.geometry.groups.map((group) => ({ ...group }));
      geometry.drawRange = { ...source.geometry.drawRange };
      geometry.morphAttributes = source.geometry.morphAttributes;
      geometry.morphTargetsRelative = source.geometry.morphTargetsRelative;
      if (geometry.index)
        borrowedAttributeReferences.set(
          geometry.index,
          (borrowedAttributeReferences.get(geometry.index) ?? 0) + 1,
        );
    }
    geometry.addEventListener("dispose", () => {
      for (const name of Object.keys(geometry.attributes)) {
        const attribute = geometry.getAttribute(name);
        const references = borrowedAttributeReferences.get(attribute)! - 1;
        borrowedAttributeReferences.set(attribute, references);
        if (references > 0) geometry.deleteAttribute(name);
      }
      if (!regroup && geometry.index) {
        const references = borrowedAttributeReferences.get(geometry.index)! - 1;
        borrowedAttributeReferences.set(geometry.index, references);
        if (references > 0) geometry.setIndex(null);
      }
    });
    // Capacity lives in the borrowed buffer; avoid allocating a second large
    // matrix array merely to overwrite it immediately.
    const object = new InstancedMesh(geometry, materials, 0);
    object.instanceMatrix = source.instanceMatrix;
    object.instanceColor = source.instanceColor;
    object.morphTexture = source.morphTexture;
    object.count = source.count;
    object.matrixAutoUpdate = false;
    object.frustumCulled = false;
    object.raycast = () => {};
    objects.push(object);
    ownedGeometries.push(geometry);
    ownedInstances.push(object);
    regrouped.push({ source, object });
    renderedInstances.set(source, object);
    batchedSources.add(source);
    if (regroup) stats.regroupedSourceCount++;
    else stats.fallbackSourceCount++;
  };

  for (const source of sources) {
    const schema = geometryKey(source.geometry);
    if (!schema || source.instanceColor || source.morphTexture) {
      preserveSource(source);
      continue;
    }
    const ranges = rangesByMaterial(source);
    const keys = new Map<Material, string>();
    let supported = ranges.size > 0;
    for (const material of ranges.keys()) {
      const key = keyForMaterial(material);
      if (key === undefined) supported = false;
      else keys.set(material, key);
    }
    if (!supported) {
      preserveSource(source);
      continue;
    }
    let mirrored = false;
    for (let i = 0; i < source.count && !mirrored; i++) {
      source.getMatrixAt(i, matrix);
      mirrored = matrix.determinant() < 0;
    }
    const indexCount =
      source.geometry.index?.count ??
      source.geometry.getAttribute("position").count;
    const mergeUnique =
      options.mergeUniqueGeometries !== false &&
      source.count === 1 &&
      geometryOccurrences.get(source.geometry) === 1;
    if (
      (!options.multiDraw && !mergeUnique) ||
      source.count === 0 ||
      source.count > preserveAbove ||
      source.count > maxInstances ||
      source.geometry.getAttribute("position").count > maxVertices ||
      indexCount > maxIndices ||
      mirrored
    ) {
      preserveSource(source, ranges, keys);
      continue;
    }
    // Merge equivalent material entries before creating pieces, including
    // geometries whose groups refer to separate but identical materials.
    const compatible = new Map<
      string,
      { material: Material; ranges: Range[] }
    >();
    for (const [material, spans] of ranges) {
      const key = keys.get(material)!;
      const entry = compatible.get(key) ?? { material, ranges: [] };
      entry.ranges.push(...spans);
      compatible.set(key, entry);
    }
    for (const [materialSignature, entry] of compatible) {
      const merged = mergeUnique && !entry.material.transparent;
      const key = `${schema}:${materialSignature}:${merged}`;
      let bucket = buckets.get(key);
      if (!bucket) {
        bucket = {
          material: copyMaterial(entry.material, materialSignature),
          pieces: new Map(),
          tails: new Map(),
          merged,
        };
        buckets.set(key, bucket);
      }
      const pieceKey = `${source.geometry.uuid}:${entry.ranges.map((range) => `${range.start},${range.count}`).join(";")}`;
      let piece = bucket.tails.get(pieceKey);
      if (!piece || piece.instances + source.count > maxInstances) {
        piece = {
          geometry: source.geometry,
          ranges: entry.ranges,
          sources: [],
          instances: 0,
        };
        bucket.pieces.set(`${pieceKey}:${bucket.pieces.size}`, piece);
        bucket.tails.set(pieceKey, piece);
      }
      piece.sources.push(source);
      piece.instances += source.count;
    }
    batchedSources.add(source);
    stats.batchedSourceCount++;
  }

  for (const bucket of buckets.values()) {
    let pending: { piece: Piece; geometry: BufferGeometry }[] = [];
    let vertices = 0,
      indices = 0,
      instances = 0;
    const flush = () => {
      if (!pending.length) return;
      const batch = new BatchedMesh(
        instances,
        vertices,
        indices,
        bucket.material,
      );
      batch.name = "Material render batch";
      batch.frustumCulled = false;
      batch.perObjectFrustumCulled = false;
      batch.sortObjects = bucket.material.transparent;
      batch.raycast = () => {};
      const spans: MergedPartSpan[] = [];
      for (const { piece, geometry } of pending) {
        const geometryId = batch.addGeometry(geometry);
        for (const source of piece.sources) {
          let first = -1;
          for (let i = 0; i < source.count; i++) {
            const id = batch.addInstance(geometryId);
            if (first === -1) first = id;
          }
          const list = links.get(source) ?? [];
          list.push({ batch, first, count: source.count });
          links.set(source, list);
          if (bucket.merged) {
            const range = batch.getGeometryRangeAt(geometryId)!;
            spans.push({
              vertexStart: range.vertexStart,
              vertexCount: range.vertexCount,
              instanceId: first,
            });
          }
        }
        geometry.dispose();
      }
      objects.push(batch);
      if (bucket.merged) {
        const merged = createGpuMergedMesh(batch, spans);
        mergedMeshes.set(batch, merged);
        objects.push(merged.object);
        stats.mergedChunkCount++;
      }
      stats.materialBatchCount++;
      stats.copiedVertices += vertices;
      stats.copiedIndices += indices;
      pending = [];
      vertices = indices = instances = 0;
    };
    for (const piece of bucket.pieces.values()) {
      const geometry = compactPiece(piece);
      const vertexCount = geometry.getAttribute("position").count;
      const indexCount = geometry.index!.count;
      if (
        pending.length &&
        (vertices + vertexCount > maxVertices ||
          indices + indexCount > maxIndices ||
          instances + piece.instances > maxInstances)
      )
        flush();
      pending.push({ piece, geometry });
      vertices += vertexCount;
      indices += indexCount;
      instances += piece.instances;
    }
    flush();
  }

  function syncFromSources() {
    if (disposed) return;
    for (const [source, sourceLinks] of links) {
      source.updateWorldMatrix(true, false);
      const capacity = sourceLinks[0].count;
      for (let i = 0; i < capacity; i++) {
        source.getMatrixAt(i, matrix);
        world.multiplyMatrices(source.matrixWorld, matrix);
        const e = matrix.elements;
        const visible =
          source.visible &&
          i < source.count &&
          (e[0] !== 0 ||
            e[1] !== 0 ||
            e[2] !== 0 ||
            e[4] !== 0 ||
            e[5] !== 0 ||
            e[6] !== 0 ||
            e[8] !== 0 ||
            e[9] !== 0 ||
            e[10] !== 0);
        for (const link of sourceLinks) {
          link.batch.setMatrixAt(link.first + i, world);
          link.batch.setVisibleAt(link.first + i, visible);
          mergedMeshes
            .get(link.batch)
            ?.setMatrixAt(link.first + i, world, visible);
        }
      }
    }
    for (const { source, object } of regrouped) {
      source.updateWorldMatrix(true, false);
      object.matrix.copy(source.matrixWorld);
      object.count = source.count;
      object.visible = source.visible;
    }
  }

  function syncMaterials() {
    if (disposed) return;
    for (const [material, original] of materialOrigins) {
      const recompile =
        material.transparent !== original.transparent ||
        (material.clippingPlanes?.length ?? 0) !==
          (original.clippingPlanes?.length ?? 0) ||
        material.clipIntersection !== original.clipIntersection;
      material.opacity = original.opacity;
      material.transparent = original.transparent;
      material.depthWrite = original.depthWrite;
      material.colorWrite = original.colorWrite;
      material.polygonOffset = original.polygonOffset;
      material.polygonOffsetFactor = original.polygonOffsetFactor;
      material.polygonOffsetUnits = original.polygonOffsetUnits;
      material.visible = original.visible;
      material.clippingPlanes = original.clippingPlanes;
      material.clipIntersection = original.clipIntersection;
      material.clipShadows = original.clipShadows;
      if (recompile) material.needsUpdate = true;
    }
    for (const object of objects)
      if (object instanceof BatchedMesh)
        object.sortObjects = (object.material as Material).transparent;
    for (const merged of mergedMeshes.values()) merged.syncMaterial();
  }

  syncFromSources();
  return {
    objects,
    renderedInstances: renderedInstances as ReadonlyMap<
      InstancedMesh,
      InstancedMesh
    >,
    batchedSources: batchedSources as ReadonlySet<InstancedMesh>,
    stats,
    syncFromSources,
    syncMaterials,
    dispose() {
      if (disposed) return;
      disposed = true;
      for (const object of objects)
        if (object instanceof BatchedMesh) object.dispose();
      for (const merged of mergedMeshes.values()) merged.dispose();
      for (const object of ownedInstances) {
        object.morphTexture = null;
        object.dispose();
      }
      for (const geometry of ownedGeometries) geometry.dispose();
      for (const material of materialCopies.values()) material.dispose();
    },
  };
}

export type RenderBatches = ReturnType<typeof createRenderBatches>;
