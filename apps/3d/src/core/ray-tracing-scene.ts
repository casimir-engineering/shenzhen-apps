import * as T from "three";
import { RAY_TRACING_BUDGET } from "./ray-tracing-types";
import type {
  RayTracingBudget,
  RayTracingInput,
  TraceCamera,
  TraceGeometry,
  TraceMaterial,
  TraceScene,
  TraceTexture,
} from "./ray-tracing-types";
const textureSlots = [
  "map",
  "normalMap",
  "roughnessMap",
  "metalnessMap",
  "alphaMap",
  "aoMap",
  "emissiveMap",
  "transmissionMap",
  "thicknessMap",
  "clearcoatMap",
  "clearcoatNormalMap",
  "clearcoatRoughnessMap",
  "specularColorMap",
  "specularIntensityMap",
];
const numericSlots = [
  "opacity",
  "roughness",
  "metalness",
  "alphaTest",
  "side",
  "transmission",
  "thickness",
  "ior",
  "attenuationDistance",
  "clearcoat",
  "clearcoatRoughness",
  "specularIntensity",
  "emissiveIntensity",
  "aoMapIntensity",
  "normalMapType",
  "transparent",
  "vertexColors",
  "flatShading",
  "depthWrite",
];
const colorSlots = ["color", "emissive", "attenuationColor", "specularColor"];
const attributeNames = [
  "position",
  "normal",
  "tangent",
  "color",
  "uv",
  "uv1",
  "uv2",
  "uv3",
  "uv4",
  "uv5",
  "uv6",
  "uv7",
];
function abort(signal?: AbortSignal) {
  if (signal?.aborted)
    throw new DOMException("Ray tracing preparation canceled", "AbortError");
}
const yieldTask = () => new Promise<void>((resolve) => setTimeout(resolve, 0));
function materials(source: T.Mesh) {
  return Array.isArray(source.material) ? source.material : [source.material];
}
function validateMaterial(material: T.Material) {
  if (!(material instanceof T.MeshStandardMaterial))
    throw new Error(
      "Ray tracing supports standard and physical mesh materials; this model uses an unsupported material.",
    );
  if (
    material.onBeforeCompile !== T.Material.prototype.onBeforeCompile ||
    material.customProgramCacheKey !==
      T.Material.prototype.customProgramCacheKey
  )
    throw new Error("Ray tracing cannot reproduce custom material shaders.");
  if (material.clippingPlanes?.length)
    throw new Error("Turn off section clipping before enabling ray tracing.");
}
export function traceCamera(camera: T.Camera): TraceCamera {
  camera.updateMatrixWorld();
  const c = camera as T.PerspectiveCamera | T.OrthographicCamera;
  if (!(c instanceof T.PerspectiveCamera || c instanceof T.OrthographicCamera))
    throw new Error("Ray tracing needs a perspective or orthographic camera.");
  return {
    type: c instanceof T.PerspectiveCamera ? "perspective" : "orthographic",
    matrix: c.matrixWorld.toArray(),
    near: c.near,
    far: c.far,
    zoom: c.zoom,
    ...(c instanceof T.PerspectiveCamera
      ? { fov: c.fov, aspect: c.aspect }
      : { left: c.left, right: c.right, top: c.top, bottom: c.bottom }),
  };
}
/** Preflight uses unique geometry storage plus per-instance transforms, never expanded triangle counts. */
export function estimateTraceScene(
  sources: readonly T.Mesh[],
  budget: RayTracingBudget = { ...RAY_TRACING_BUDGET },
) {
  const geometries = new Map<T.BufferGeometry, Set<boolean>>(),
    textures = new Set<T.Texture>(),
    materialSet = new Set<T.Material>();
  let instances = 0,
    geometryBytes = 0,
    textureBytes = 0,
    triangles = 0;
  for (const source of sources) {
    if (!source.visible) continue;
    const geometry = source.geometry,
      position = geometry.getAttribute("position");
    if (!position || position.itemSize !== 3)
      throw new Error("Ray tracing needs valid triangle positions.");
    if (
      Object.values(geometry.morphAttributes).some((a) => a.length) ||
      (source as T.SkinnedMesh).isSkinnedMesh
    )
      throw new Error(
        "Animated and morphed meshes are not supported by the still-frame ray tracer.",
      );
    instances += (source as T.InstancedMesh).isInstancedMesh
      ? (source as T.InstancedMesh).count
      : 1;
    const count = geometry.index?.count ?? position.count;
    if (
      geometry.drawRange.start !== 0 ||
      (Number.isFinite(geometry.drawRange.count) &&
        geometry.drawRange.count < count)
    )
      throw new Error(
        "Partial mesh draw ranges are not supported by ray tracing.",
      );
    const grouped = Array.isArray(source.material);
    if (grouped)
      for (const group of geometry.groups)
        if (
          !Number.isInteger(group.materialIndex ?? 0) ||
          (group.materialIndex ?? 0) < 0 ||
          (group.materialIndex ?? 0) >= materials(source).length
        )
          throw new Error(
            "A mesh material group references an unavailable material.",
          );
    const variants = geometries.get(geometry) ?? new Set<boolean>();
    if (!variants.has(grouped)) {
      variants.add(grouped);
      geometries.set(geometry, variants);
      if (count % 3)
        throw new Error("Ray tracing requires complete triangles.");
      triangles += count / 3;
      let stride = 80;
      for (const name of attributeNames.slice(6))
        if (geometry.hasAttribute(name)) stride += 16;
      geometryBytes += position.count * stride + (count / 3) * 64;
    }
    for (const material of materials(source)) {
      validateMaterial(material);
      materialSet.add(material);
      for (const slot of textureSlots) {
        const texture = (material as unknown as Record<string, T.Texture>)[
          slot
        ];
        if (texture?.isTexture) textures.add(texture);
      }
    }
  }
  for (const texture of textures) {
    const image = texture.image as {
      width: number;
      height: number;
      data?: Uint8Array | Uint16Array | Float32Array;
    };
    if (!image || !image.width || !image.height)
      throw new Error("A material texture has no readable image.");
    if (image.width > 4096 || image.height > 4096)
      throw new Error(
        "Ray tracing currently supports textures up to 4096 × 4096.",
      );
    if (
      (texture as T.CompressedTexture).isCompressedTexture ||
      (texture as T.VideoTexture).isVideoTexture ||
      (texture as T.CubeTexture).isCubeTexture
    )
      throw new Error(
        "Compressed, video and cube material textures are not supported by ray tracing.",
      );
    textureBytes += image.width * image.height * 16;
  }
  const estimatedBytes =
    geometryBytes + instances * 256 + materialSet.size * 2048 + textureBytes;
  if (!instances) throw new Error("No visible triangle meshes to ray trace.");
  if (instances > budget.maxInstances)
    throw new Error(
      `Ray tracing supports up to ${budget.maxInstances.toLocaleString()} instances in this mode; raster remains available.`,
    );
  if (
    geometryBytes > budget.maxGeometryBytes ||
    estimatedBytes > budget.maxBytes
  )
    throw new Error(
      `This scene exceeds the ray-tracing memory budget (${Math.round(budget.maxBytes / 1024 ** 2)} MiB); raster remains available.`,
    );
  if (
    textures.size > budget.maxTextures ||
    textureBytes > budget.maxTextureBytes
  )
    throw new Error(
      "This scene exceeds the ray-tracing texture budget; raster remains available.",
    );
  return {
    instances,
    uniqueTriangles: triangles,
    geometryBytes,
    textureBytes,
    estimatedBytes,
    materials: materialSet.size,
  };
}
export async function serializeTraceScene(
  input: RayTracingInput,
  signal?: AbortSignal,
  budget: RayTracingBudget = { ...RAY_TRACING_BUDGET },
  progress?: (value: number) => void,
): Promise<TraceScene> {
  abort(signal);
  const estimate = estimateTraceScene(input.sources, budget);
  const geometries: TraceGeometry[] = [],
    materialList: TraceMaterial[] = [],
    textures: TraceTexture[] = [],
    objects: TraceScene["objects"] = [];
  const geometryIds = new Map<T.BufferGeometry, Map<boolean, number>>(),
    materialIds = new Map<T.Material, number>(),
    materialKeys = new Map<string, number>(),
    textureIds = new Map<T.Texture, number>();
  try {
    async function textureId(texture: T.Texture) {
      if (textureIds.has(texture)) return textureIds.get(texture)!;
      const id = textures.length;
      textureIds.set(texture, id);
      const matrix = texture.matrixAutoUpdate
        ? new T.Matrix3().setUvTransform(
            texture.offset.x,
            texture.offset.y,
            texture.repeat.x,
            texture.repeat.y,
            texture.rotation,
            texture.center.x,
            texture.center.y,
          )
        : texture.matrix;
      const image = texture.image as {
        width: number;
        height: number;
        data?: Uint8Array | Uint16Array | Float32Array;
      };
      const data = image.data;
      const entry: TraceTexture = {
        id,
        width: image.width,
        height: image.height,
        type: texture.type,
        format: texture.format,
        colorSpace: texture.colorSpace,
        flipY: texture.flipY,
        wrapS: texture.wrapS,
        wrapT: texture.wrapT,
        magFilter: texture.magFilter,
        minFilter: texture.minFilter,
        channel: texture.channel,
        matrix: matrix.toArray(),
      };
      if (data) {
        if (!(
          data instanceof Uint8Array ||
          data instanceof Uint16Array ||
          data instanceof Float32Array
        ))
          throw new Error(
            "This texture data format is not supported by ray tracing.",
          );
        entry.data = data.slice();
      } else {
        entry.bitmap = await createImageBitmap(
          image as unknown as ImageBitmapSource,
        );
      }
      textures.push(entry);
      abort(signal);
      return id;
    }
    async function materialId(material: T.Material) {
      if (materialIds.has(material)) return materialIds.get(material)!;
      const props = material as unknown as Record<string, unknown>,
        entry: TraceMaterial = {
          type: (material as T.MeshPhysicalMaterial).isMeshPhysicalMaterial
            ? "physical"
            : "standard",
          properties: {},
          textures: {},
        };
      for (const slot of numericSlots) {
        const value = props[slot];
        if (
          typeof value === "boolean" ||
          (typeof value === "number" && Number.isFinite(value))
        )
          entry.properties[slot] = value;
      }
      for (const slot of colorSlots) {
        const value = props[slot];
        if (value instanceof T.Color) entry.properties[slot] = value.toArray();
      }
      if (props.normalScale instanceof T.Vector2)
        entry.properties.normalScale = props.normalScale.toArray();
      for (const slot of textureSlots) {
        const value = props[slot];
        if (value instanceof T.Texture)
          entry.textures[slot] = await textureId(value);
      }
      const key = JSON.stringify(entry);
      let id = materialKeys.get(key);
      if (id === undefined) {
        id = materialList.length;
        if (id >= budget.maxMaterials)
          throw new Error(
            "This scene exceeds the ray-tracing material budget.",
          );
        materialList.push(entry);
        materialKeys.set(key, id);
      }
      materialIds.set(material, id);
      return id;
    }
    for (
      let sourceIndex = 0;
      sourceIndex < input.sources.length;
      sourceIndex++
    ) {
      abort(signal);
      const source = input.sources[sourceIndex];
      if (!source.visible) continue;
      source.updateWorldMatrix(true, false);
      const original = source.geometry;
      const grouped = Array.isArray(source.material),
        variants = geometryIds.get(original) ?? new Map<boolean, number>();
      let geometry = variants.get(grouped);
      if (geometry === undefined) {
        geometry = geometries.length;
        variants.set(grouped, geometry);
        geometryIds.set(original, variants);
        const attributes: TraceGeometry["attributes"] = {};
        for (const name of attributeNames) {
          const attribute = original.getAttribute(name);
          if (!attribute) continue;
          const array = new Float32Array(attribute.count * attribute.itemSize);
          for (let vertex = 0; vertex < attribute.count; vertex++) {
            for (let component = 0; component < attribute.itemSize; component++)
              array[vertex * attribute.itemSize + component] =
                attribute.getComponent(vertex, component);
            if (
              name === "position" &&
              !array.subarray(vertex * 3, vertex * 3 + 3).every(Number.isFinite)
            )
              throw new Error("Ray tracing needs finite vertex positions.");
            if (vertex && vertex % 65536 === 0) {
              await yieldTask();
              abort(signal);
            }
          }
          attributes[name] = { array, itemSize: attribute.itemSize };
        }
        const count =
            original.index?.count ?? original.getAttribute("position").count,
          index = original.index
            ? new Uint32Array(original.index.array)
            : Uint32Array.from({ length: count }, (_, i) => i);
        if (index.some((i) => i >= original.getAttribute("position").count))
          throw new Error(
            "Ray-tracing triangle indices exceed the vertex count.",
          );
        geometries.push({
          id: geometry,
          attributes,
          index,
          groups: grouped
            ? original.groups.map((g) => ({
                start: g.start,
                count: g.count,
                materialIndex: g.materialIndex ?? 0,
              }))
            : [{ start: 0, count, materialIndex: 0 }],
        });
      }
      if (
        !source.matrixWorld.elements.every(Number.isFinite) ||
        Math.abs(source.matrixWorld.determinant()) < 1e-15
      )
        throw new Error(
          "Ray tracing cannot use a non-invertible world transform.",
        );
      const objectMaterials = [];
      for (const material of materials(source))
        objectMaterials.push(await materialId(material));
      const instanced = (source as T.InstancedMesh).isInstancedMesh,
        instanceSource = source as T.InstancedMesh,
        count = instanced ? instanceSource.count : 1,
        matrices: number[] = [],
        colors: number[] = [];
      const matrix = new T.Matrix4();
      for (let i = 0; i < count; i++) {
        if (instanced) instanceSource.getMatrixAt(i, matrix);
        else matrix.identity();
        const e = matrix.elements;
        if (
          e[0] === 0 &&
          e[1] === 0 &&
          e[2] === 0 &&
          e[4] === 0 &&
          e[5] === 0 &&
          e[6] === 0 &&
          e[8] === 0 &&
          e[9] === 0 &&
          e[10] === 0
        )
          continue;
        if (!e.every(Number.isFinite) || Math.abs(matrix.determinant()) < 1e-15)
          throw new Error(
            "Ray tracing cannot use a non-invertible instance transform.",
          );
        matrices.push(...e);
        if (instanced && instanceSource.instanceColor) {
          colors.push(
            instanceSource.instanceColor.getX(i),
            instanceSource.instanceColor.getY(i),
            instanceSource.instanceColor.getZ(i),
          );
        }
        if (i && i % 4096 === 0) {
          await yieldTask();
          abort(signal);
        }
      }
      if (matrices.length)
        objects.push({
          geometry,
          materials: objectMaterials,
          matrices: new Float32Array(matrices),
          matrix: source.matrixWorld.toArray(),
          ...(colors.length ? { colors: new Float32Array(colors) } : {}),
        });
      progress?.((sourceIndex + 1) / input.sources.length);
      await yieldTask();
    }
    abort(signal);
    if (!objects.length)
      throw new Error("No visible triangle instances to ray trace.");
    return {
      geometries,
      materials: materialList,
      textures,
      objects,
      camera: traceCamera(input.camera),
      lighting: input.lighting ?? {},
      background: (input.background?.toArray() ?? [0.08, 0.1, 0.12]) as [
        number,
        number,
        number,
      ],
      estimatedBytes: estimate.estimatedBytes,
      budget,
    };
  } catch (error) {
    for (const texture of textures) texture.bitmap?.close();
    throw error;
  }
}
export function traceTransfers(scene: TraceScene): Transferable[] {
  const transfers: Transferable[] = [];
  for (const geometry of scene.geometries) {
    transfers.push(geometry.index.buffer);
    for (const attribute of Object.values(geometry.attributes))
      transfers.push(attribute.array.buffer);
  }
  for (const object of scene.objects) {
    transfers.push(object.matrices.buffer);
    if (object.colors) transfers.push(object.colors.buffer);
  }
  for (const texture of scene.textures) {
    if (texture.bitmap) transfers.push(texture.bitmap);
    if (texture.data) transfers.push(texture.data.buffer);
  }
  return transfers;
}
