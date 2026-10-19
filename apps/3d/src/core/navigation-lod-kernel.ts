// @ts-expect-error Three bundles meshoptimizer's MIT module without declarations.
import { MeshoptSimplifier } from "three/addons/libs/meshopt_simplifier.module.js";

export interface LodGroup {
  start: number;
  count: number;
  materialIndex: number;
}
export interface NavigationLodInput {
  id: number;
  positions: Float32Array;
  indices: Uint32Array;
  normals?: Float32Array;
  uvs?: Float32Array;
  colors?: Float32Array;
  colorSize?: number;
  groups: LodGroup[];
}
export interface NavigationLodResult {
  id: number;
  indices: Uint32Array;
  groups: LodGroup[];
  /** Meshoptimizer's reported metric, converted to geometry coordinates; not Hausdorff distance. */
  error: number;
  relativeError: number;
  originalTriangleCount: number;
  triangleCount: number;
}
export interface NavigationLodSettings {
  ratio?: number;
  maxRelativeError?: number;
}

/** Index-only simplification: every retained vertex still references the original attributes. */
export async function simplifyNavigationGeometry(
  input: NavigationLodInput,
  settings: NavigationLodSettings = {},
): Promise<NavigationLodResult | undefined> {
  const { positions, indices } = input;
  const vertexCount = positions.length / 3;
  if (
    !MeshoptSimplifier.supported ||
    !Number.isInteger(vertexCount) ||
    vertexCount < 3 ||
    indices.length < 96 ||
    indices.length % 3 !== 0
  )
    return;
  if (
    !positions.every(Number.isFinite) ||
    !indices.every((index) => index < vertexCount)
  )
    return;
  const ratio = settings.ratio ?? 0.3,
    maxError = settings.maxRelativeError ?? 0.002;
  if (
    !(ratio > 0 && ratio < 1) ||
    !(maxError >= 0 && Number.isFinite(maxError))
  )
    return;
  const attributes: { values: Float32Array; size: number; weight: number }[] =
    [];
  if (input.normals)
    attributes.push({ values: input.normals, size: 3, weight: 0.01 });
  if (input.uvs) attributes.push({ values: input.uvs, size: 2, weight: 0.01 });
  if (input.colors)
    attributes.push({
      values: input.colors,
      size: input.colorSize ?? 3,
      weight: 0.01,
    });
  if (
    attributes.some(
      (a) =>
        a.values.length !== vertexCount * a.size ||
        !a.values.every(Number.isFinite),
    )
  )
    return;
  const attributeSize = attributes.reduce((sum, a) => sum + a.size, 0),
    attributeData = new Float32Array(vertexCount * attributeSize),
    weights: number[] = [];
  let attributeOffset = 0;
  for (const attribute of attributes) {
    for (let vertex = 0; vertex < vertexCount; vertex++)
      for (let component = 0; component < attribute.size; component++)
        attributeData[vertex * attributeSize + attributeOffset + component] =
          attribute.values[vertex * attribute.size + component];
    weights.push(...Array(attribute.size).fill(attribute.weight));
    attributeOffset += attribute.size;
  }
  // Material interfaces are independent open borders and are locked during edge collapse.
  const materialIndices = new Map<number, number[]>(),
    coverage = new Uint8Array(indices.length);
  const groups = input.groups.length
    ? input.groups
    : [{ start: 0, count: indices.length, materialIndex: 0 }];
  for (const group of groups) {
    if (
      !Number.isInteger(group.start) ||
      !Number.isInteger(group.count) ||
      group.start < 0 ||
      group.count < 0 ||
      group.start % 3 ||
      group.count % 3 ||
      group.start + group.count > indices.length ||
      !Number.isInteger(group.materialIndex) ||
      group.materialIndex < 0
    )
      return;
    const list = materialIndices.get(group.materialIndex) ?? [];
    for (let i = group.start; i < group.start + group.count; i++) {
      if (coverage[i]) return;
      coverage[i] = 1;
      list.push(indices[i]);
    }
    materialIndices.set(group.materialIndex, list);
  }
  if (coverage.some((covered) => !covered)) return;
  await MeshoptSimplifier.ready;
  const scale = MeshoptSimplifier.getScale(positions, 3) as number;
  if (!(scale > 0 && Number.isFinite(scale))) return;
  const pieces: Uint32Array[] = [],
    outputGroups: LodGroup[] = [];
  let count = 0,
    relativeError = 0;
  for (const [materialIndex, list] of materialIndices) {
    const source = new Uint32Array(list),
      target = Math.max(3, Math.floor((source.length * ratio) / 3) * 3);
    let simplified: Uint32Array = source;
    let error = 0;
    if (source.length >= 96) {
      const result = MeshoptSimplifier.simplifyWithAttributes(
        source,
        positions,
        3,
        attributeData,
        attributeSize,
        weights,
        null,
        target,
        maxError,
        ["LockBorder"],
      ) as [Uint32Array, number];
      if (
        !Number.isFinite(result[1]) ||
        result[1] > maxError + 1e-7 ||
        result[0].length % 3 ||
        !result[0].every((index) => index < vertexCount)
      )
        return;
      [simplified, error] = result;
    }
    if (!simplified.length) return;
    pieces.push(simplified);
    outputGroups.push({
      start: count,
      count: simplified.length,
      materialIndex,
    });
    count += simplified.length;
    relativeError = Math.max(relativeError, error);
  }
  // A small reduction is not worth additional GPU index storage and scene bookkeeping.
  if (count >= indices.length * 0.85) return;
  const output = new Uint32Array(count);
  let offset = 0;
  for (const piece of pieces) {
    output.set(piece, offset);
    offset += piece.length;
  }
  return {
    id: input.id,
    indices: output,
    groups: outputGroups,
    error: relativeError * scale,
    relativeError,
    originalTriangleCount: indices.length / 3,
    triangleCount: count / 3,
  };
}
