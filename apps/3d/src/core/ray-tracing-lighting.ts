/**
 * Converts the raster viewer's lights into the ray tracer's light sources so a
 * converged trace has the raster view's exposure. Loaded only by the
 * ray-tracing worker and tests, never at startup.
 *
 * Three.js (physically based lights since r155) shades an ambient or hemisphere
 * light as irradiance E, giving diffuse radiance albedo * E / PI. An environment
 * of radiance L delivers irradiance PI * L to an unoccluded surface, so the
 * equivalent environment radiance is E / PI. A sky/ground split environment
 * reproduces Three's hemisphere term exactly:
 *   E(n) = PI * [S (1 + n.u) / 2 + G (1 - n.u) / 2] for radiances S above and
 *   G below the plane normal to u, i.e. S = I * sky / PI and G = I * ground / PI.
 * Directional lights are traced as directional lights with the same intensity.
 */
import type { RayTracingLighting } from "./ray-tracing-types";
import type { Vec3 } from "./types";

/**
 * Equirect resolution. Rows split exactly at the horizon for a +/-Y hemisphere,
 * and the band blended by linear filtering stays within 1.4 degrees of it.
 */
export const ENVIRONMENT_WIDTH = 128;
export const ENVIRONMENT_HEIGHT = 64;

/**
 * Direction of an equirect texel centre, matching three-gpu-pathtracer's
 * `equirectUvToDirection` with data row 0 at v = 0 (flipY = false).
 */
export function equirectTexelDirection(
  x: number,
  y: number,
  width: number,
  height: number,
): Vec3 {
  const theta = ((x + 0.5) / width - 0.5) * 2 * Math.PI,
    phi = (1 - (y + 0.5) / height) * Math.PI;
  return [
    Math.sin(phi) * Math.cos(theta),
    Math.cos(phi),
    Math.sin(phi) * Math.sin(theta),
  ];
}

/** Environment radiance seen along `direction`. */
export function environmentRadiance(
  lighting: RayTracingLighting,
  direction: Vec3,
): Vec3 {
  const out: Vec3 = [0, 0, 0];
  const ambient = lighting.ambient;
  if (ambient && ambient.intensity > 0)
    for (let c = 0; c < 3; c++)
      out[c] += (ambient.color[c] * ambient.intensity) / Math.PI;
  const hemisphere = lighting.hemisphere;
  if (hemisphere && hemisphere.intensity > 0) {
    const [ux, uy, uz] = hemisphere.up,
      side =
        direction[0] * ux + direction[1] * uy + direction[2] * uz >= 0
          ? hemisphere.sky
          : hemisphere.ground;
    for (let c = 0; c < 3; c++)
      out[c] += (side[c] * hemisphere.intensity) / Math.PI;
  }
  return out;
}

/** Linear RGBA radiance texels for an equirect environment, row 0 first. */
export function buildEnvironment(
  lighting: RayTracingLighting,
  width = ENVIRONMENT_WIDTH,
  height = ENVIRONMENT_HEIGHT,
) {
  const data = new Float32Array(width * height * 4);
  for (let y = 0; y < height; y++)
    for (let x = 0; x < width; x++) {
      const radiance = environmentRadiance(
          lighting,
          equirectTexelDirection(x, y, width, height),
        ),
        i = (y * width + x) * 4;
      data[i] = radiance[0];
      data[i + 1] = radiance[1];
      data[i + 2] = radiance[2];
      data[i + 3] = 1;
    }
  return { data, width, height };
}

/**
 * Diffuse irradiance Three's raster shader gives a surface with unit normal
 * `normal`, ignoring shadows (raster has none). Reference for tests.
 */
export function rasterIrradiance(
  lighting: RayTracingLighting,
  normal: Vec3,
): Vec3 {
  const out: Vec3 = [0, 0, 0];
  const dot = (a: Vec3, b: Vec3) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
  if (lighting.ambient)
    for (let c = 0; c < 3; c++)
      out[c] += lighting.ambient.color[c] * lighting.ambient.intensity;
  if (lighting.hemisphere) {
    const { up, sky, ground, intensity } = lighting.hemisphere,
      weight = 0.5 * dot(normal, up) + 0.5;
    for (let c = 0; c < 3; c++)
      out[c] += (ground[c] + (sky[c] - ground[c]) * weight) * intensity;
  }
  for (const light of lighting.directional ?? []) {
    const cosine = Math.max(0, dot(normal, light.direction));
    for (let c = 0; c < 3; c++)
      out[c] += light.color[c] * light.intensity * cosine;
  }
  return out;
}

// ACES filmic as implemented by Three's WebGPU (TSL) output pass. Rows.
const ACES_IN = [
  [0.59719, 0.35458, 0.04823],
  [0.076, 0.90834, 0.01566],
  [0.0284, 0.13383, 0.83777],
];
const ACES_OUT = [
  [1.60475, -0.53108, -0.07367],
  [-0.10208, 1.10813, -0.00605],
  [-0.00327, -0.07276, 1.07602],
];
const multiply = (m: number[][], v: Vec3): Vec3 => [
  m[0][0] * v[0] + m[0][1] * v[1] + m[0][2] * v[2],
  m[1][0] * v[0] + m[1][1] * v[1] + m[1][2] * v[2],
  m[2][0] * v[0] + m[2][1] * v[1] + m[2][2] * v[2],
];
function invert3(m: number[][]) {
  const [[a, b, c], [d, e, f], [g, h, i]] = m,
    A = e * i - f * h,
    B = -(d * i - f * g),
    C = d * h - e * g,
    det = a * A + b * B + c * C;
  return [
    [A / det, -(b * i - c * h) / det, (b * f - c * e) / det],
    [B / det, (a * i - c * g) / det, -(a * f - c * d) / det],
    [C / det, -(a * h - b * g) / det, (a * e - b * d) / det],
  ];
}
const ACES_IN_INVERSE = invert3(ACES_IN),
  ACES_OUT_INVERSE = invert3(ACES_OUT);
const fit = (v: number) =>
  (v * (v + 0.0245786) - 0.000090537) /
  (v * (v + 0.432951) * 0.983729 + 0.238081);

/** Three's WebGPU ACES filmic tone mapping of a linear colour. */
export function acesFilmic(color: Vec3, exposure: number): Vec3 {
  const scaled = color.map((c) => (c * exposure) / 0.6) as Vec3;
  const fitted = multiply(ACES_IN, scaled).map(fit) as Vec3;
  return multiply(ACES_OUT, fitted).map((c) =>
    Math.min(1, Math.max(0, c)),
  ) as Vec3;
}

/**
 * Linear colour that ACES filmic maps to `display`. Raster draws its plain
 * background without tone mapping, so the traced background is pre-inverted
 * to look the same after the trace's output transform.
 */
export function inverseAcesFilmic(display: Vec3, exposure: number): Vec3 {
  const target = display.map((c) => Math.min(0.999, Math.max(0, c))) as Vec3;
  const fitted = multiply(ACES_OUT_INVERSE, target).map((y) => {
    if (y <= fit(0)) return 0;
    let lo = 0,
      hi = 1;
    while (fit(hi) < y && hi < 1e6) hi *= 2;
    for (let k = 0; k < 64; k++) {
      const mid = (lo + hi) / 2;
      if (fit(mid) < y) lo = mid;
      else hi = mid;
    }
    return (lo + hi) / 2;
  }) as Vec3;
  return multiply(ACES_IN_INVERSE, fitted).map((c) =>
    Math.max(0, (c * 0.6) / exposure),
  ) as Vec3;
}
