import type { Camera, Color, InstancedMesh, Mesh } from "three";
import type { Vec3 } from "./types";
export type RayTracingStatus =
  "unsupported" | "preparing" | "rendering" | "ready" | "error";
export interface RayTracingState {
  status: RayTracingStatus;
  samples: number;
  target: number;
  progress: number;
  reason?: string;
  estimatedBytes?: number;
}
export interface RayTracingSettings {
  samples: 32 | 128 | 512;
  resolution: 0.5 | 1;
}
/**
 * The raster viewer's lights, in Three's units and linear colours, so the
 * worker can trace the same lighting. Directions point toward the light.
 */
export interface RayTracingLighting {
  /** Three `HemisphereLight`: `sky` lights surfaces facing `up`. */
  hemisphere?: { up: Vec3; sky: Vec3; ground: Vec3; intensity: number };
  /** Three `AmbientLight`. */
  ambient?: { color: Vec3; intensity: number };
  /** Three `DirectionalLight`s. */
  directional?: { direction: Vec3; color: Vec3; intensity: number }[];
}
export interface RayTracingInput {
  sources: readonly (InstancedMesh | Mesh)[];
  camera: Camera;
  lighting?: RayTracingLighting;
  background?: Color;
}
export interface RayTracingBudget {
  maxBytes: number;
  maxGeometryBytes: number;
  maxInstances: number;
  maxMaterials: number;
  maxTextures: number;
  maxTextureBytes: number;
  maxPixels: number;
}
export const RAY_TRACING_BUDGET: Readonly<RayTracingBudget> = {
  maxBytes: 512 * 1024 ** 2,
  maxGeometryBytes: 128 * 1024 ** 2,
  maxInstances: 400000,
  maxMaterials: 2048,
  maxTextures: 64,
  maxTextureBytes: 64 * 1024 ** 2,
  maxPixels: 6_000_000,
};
export interface TraceAttribute {
  array: Float32Array;
  itemSize: number;
}
export interface TraceGeometry {
  id: number;
  attributes: Record<string, TraceAttribute>;
  index: Uint32Array;
  groups: { start: number; count: number; materialIndex: number }[];
}
export interface TraceMaterial {
  type: "standard" | "physical";
  properties: Record<string, number | boolean | string | number[]>;
  textures: Record<string, number>;
}
export interface TraceTexture {
  id: number;
  bitmap?: ImageBitmap;
  data?: Uint8Array | Uint16Array | Float32Array;
  width: number;
  height: number;
  type: number;
  format: number;
  colorSpace: string;
  flipY: boolean;
  wrapS: number;
  wrapT: number;
  magFilter: number;
  minFilter: number;
  channel: number;
  matrix: number[];
}
export interface TraceObject {
  geometry: number;
  materials: number[];
  matrices: Float32Array;
  matrix: number[];
  colors?: Float32Array;
}
export interface TraceCamera {
  type: "perspective" | "orthographic";
  matrix: number[];
  near: number;
  far: number;
  zoom: number;
  fov?: number;
  aspect?: number;
  left?: number;
  right?: number;
  top?: number;
  bottom?: number;
}
export interface TraceScene {
  geometries: TraceGeometry[];
  materials: TraceMaterial[];
  textures: TraceTexture[];
  objects: TraceObject[];
  camera: TraceCamera;
  lighting: RayTracingLighting;
  background: [number, number, number];
  estimatedBytes: number;
  budget: RayTracingBudget;
}

/** Conservative working estimate, not a browser/process peak-memory measurement. */
export function traceResourceEstimate(
  sceneBytes: number,
  width: number,
  height: number,
  budget: RayTracingBudget = RAY_TRACING_BUDGET,
) {
  const pixels = width * height;
  if (
    !Number.isSafeInteger(width) ||
    !Number.isSafeInteger(height) ||
    width < 1 ||
    height < 1 ||
    pixels > budget.maxPixels
  )
    throw new Error(
      "Ray-tracing canvas exceeds its pixel budget; choose half resolution.",
    );
  // Pixel accumulation/output/readback plus a fixed reserve for the bounded 65,536-path wavefront pool.
  const estimatedBytes = sceneBytes + pixels * 64 + 64 * 1024 ** 2;
  if (estimatedBytes > budget.maxBytes)
    throw new Error(
      "This scene and resolution exceed the ray-tracing memory budget; choose half resolution or use raster rendering.",
    );
  return estimatedBytes;
}

/** Three's WebGPU readback retains 256-byte row alignment, except after the final row. */
export function unpackTraceRgba8(
  data: Uint8Array,
  width: number,
  height: number,
) {
  const row = width * 4,
    stride = Math.ceil(row / 256) * 256;
  const packed = new Uint8ClampedArray(row * height);
  if (data.length === packed.length) {
    packed.set(data);
    return packed;
  }
  if (data.length < (height - 1) * stride + row)
    throw new Error("Incomplete GPU image readback.");
  for (let y = 0; y < height; y++)
    packed.set(data.subarray(y * stride, y * stride + row), y * row);
  return packed;
}
