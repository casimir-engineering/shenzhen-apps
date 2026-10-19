import { MathUtils, Vector3 } from "three";
import type { AmbientLight, DirectionalLight, Material } from "three";

export type RenderStyle =
  "shaded" | "shaded-edges" | "wireframe" | "hidden-line";
export const DEFAULT_LIGHT_AZIMUTH = MathUtils.radToDeg(Math.atan2(-2, 1));
export const DEFAULT_LIGHT_ELEVATION = MathUtils.radToDeg(
  Math.atan2(3, Math.sqrt(5)),
);

const surfaceDefaults = new WeakMap<
  Material,
  {
    colorWrite: boolean;
    polygonOffset: boolean;
    polygonOffsetFactor: number;
    polygonOffsetUnits: number;
  }
>();

export function isLineOnlyStyle(style: RenderStyle = "shaded") {
  return style === "wireframe" || style === "hidden-line";
}

/** Called after applying the user's opacity, so shaded restoration is lossless. */
export function applySurfaceRenderStyle(
  material: Material,
  style: RenderStyle = "shaded",
) {
  let original = surfaceDefaults.get(material);
  if (!original) {
    original = {
      colorWrite: material.colorWrite,
      polygonOffset: material.polygonOffset,
      polygonOffsetFactor: material.polygonOffsetFactor,
      polygonOffsetUnits: material.polygonOffsetUnits,
    };
    surfaceDefaults.set(material, original);
  }
  const depthOnly = isLineOnlyStyle(style);
  material.colorWrite = depthOnly ? false : original.colorWrite;
  material.polygonOffset = depthOnly || original.polygonOffset;
  material.polygonOffsetFactor = depthOnly ? 1 : original.polygonOffsetFactor;
  material.polygonOffsetUnits = depthOnly ? 1 : original.polygonOffsetUnits;
  if (depthOnly) {
    material.opacity = 1;
    material.transparent = false;
    material.depthWrite = true;
  }
}

export interface ViewerLightingOptions {
  lightAzimuth?: number;
  lightElevation?: number;
  lightIntensity?: number;
  uniformLight?: boolean;
  uniformIntensity?: number;
}

function finite(value: number | undefined, fallback: number) {
  return value !== undefined && Number.isFinite(value) ? value : fallback;
}

export function updateViewerLighting(
  key: DirectionalLight,
  uniform: AmbientLight,
  center: Vector3,
  radius: number,
  options: ViewerLightingOptions,
) {
  const azimuth = MathUtils.degToRad(
    finite(options.lightAzimuth, DEFAULT_LIGHT_AZIMUTH),
  );
  const elevation = MathUtils.degToRad(
    MathUtils.clamp(
      finite(options.lightElevation, DEFAULT_LIGHT_ELEVATION),
      -90,
      90,
    ),
  );
  const direction = new Vector3(
    Math.cos(elevation) * Math.cos(azimuth),
    Math.cos(elevation) * Math.sin(azimuth),
    Math.sin(elevation),
  );
  key.target.position.copy(center);
  key.position.copy(center).addScaledVector(direction, Math.max(1, radius * 4));
  key.intensity = Math.max(0, finite(options.lightIntensity, 3.2));
  uniform.visible = !!options.uniformLight;
  uniform.intensity = uniform.visible
    ? Math.max(0, finite(options.uniformIntensity, 2.6))
    : 0;
  return direction;
}
