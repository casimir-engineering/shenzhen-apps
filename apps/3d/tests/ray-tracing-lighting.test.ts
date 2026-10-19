import { describe, it, expect } from "vitest";
import {
  Color,
  DataTexture,
  DataUtils,
  HalfFloatType,
  RGBAFormat,
} from "three";
// The same CDF builder the WebGPU tracer uses for its environment light.
import { EquirectHdrInfoUniform } from "three-gpu-pathtracer/src/uniforms/EquirectHdrInfoUniform.js";
import {
  acesFilmic,
  buildEnvironment,
  equirectTexelDirection,
  environmentRadiance,
  inverseAcesFilmic,
  rasterIrradiance,
} from "../src/core/ray-tracing-lighting";
import type { RayTracingLighting } from "../src/core/ray-tracing-types";
import type { Vec3 } from "../src/core/types";

const linear = (hex: number) => new Color(hex).toArray() as Vec3;
const unit = (v: Vec3): Vec3 => {
  const l = Math.hypot(...v);
  return [v[0] / l, v[1] / l, v[2] / l];
};
const dot = (a: Vec3, b: Vec3) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
const luminance = (c: Vec3) => 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];

/** The viewer's default raster lights (src/core/viewer.ts), uniform fill on. */
const VIEWER: RayTracingLighting = {
  hemisphere: {
    up: [0, 1, 0],
    sky: linear(0xe9f5ff),
    ground: linear(0x64727a),
    intensity: 2.6,
  },
  ambient: { color: [1, 1, 1], intensity: 1.8 },
  directional: [
    { direction: unit([1, -2, 3]), color: [1, 1, 1], intensity: 3.2 },
    { direction: unit([-2, 1, 1]), color: linear(0xb3d5ff), intensity: 1.5 },
  ],
};

/** Deterministic PRNG so the estimate is identical on every run. */
function mulberry32(seed: number) {
  return () => {
    seed |= 0;
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Inverse of `equirectTexelDirection`, as three-gpu-pathtracer's equirectDirectionToUv. */
function directionToUv([x, y, z]: Vec3) {
  return [
    Math.atan2(z, x) / (2 * Math.PI) + 0.5,
    1 - Math.acos(Math.max(-1, Math.min(1, y))) / Math.PI,
  ];
}

/**
 * CPU model of the tracer's first-bounce estimator for an unoccluded Lambertian
 * surface: one-sample next-event estimation choosing between the directional
 * lights and the environment by their weights, plus a cosine-sampled BSDF ray
 * that gathers the environment, combined with the power heuristic. Weights,
 * pdfs and selection mirror LogicKernel / EquirectHdrInfoNode /
 * LightsInfoNode in three-gpu-pathtracer 0.0.27.
 */
function traceLambert(
  lighting: RayTracingLighting,
  normal: Vec3,
  albedo: number,
  samples: number,
  seed = 1,
) {
  const env = buildEnvironment(lighting),
    { width, height } = env,
    pixels = width * height;
  const half = new Uint16Array(env.data.length);
  for (let i = 0; i < half.length; i++)
    half[i] = DataUtils.toHalfFloat(env.data[i]);
  const texture = new DataTexture(
    half,
    width,
    height,
    RGBAFormat,
    HalfFloatType,
  );
  // EquirectHdrInfoNode weights each texel by its solid angle (sin theta).
  const info = new (class extends EquirectHdrInfoUniform {
    getPixelWeight(r: number, g: number, b: number, row: number) {
      return (
        super.getPixelWeight(r, g, b) *
        Math.sin((Math.PI * (row + 0.5)) / height)
      );
    }
  })();
  info.updateFrom(texture);
  const totalSum: number = info.totalSum;
  const texel = (d: Vec3): Vec3 => {
    const [u, v] = directionToUv(d),
      x = Math.min(width - 1, Math.floor(u * width)),
      y = Math.min(height - 1, Math.floor(v * height)),
      i = (y * width + x) * 4;
    return [
      DataUtils.fromHalfFloat(half[i]),
      DataUtils.fromHalfFloat(half[i + 1]),
      DataUtils.fromHalfFloat(half[i + 2]),
    ];
  };
  const envPdf = (d: Vec3) =>
    (pixels * luminance(texel(d))) / (2 * Math.PI * Math.PI * totalSum);
  const envWeight = (Math.PI * Math.PI * totalSum) / (2 * pixels);
  // Discrete texel distribution the CDF textures encode.
  const cdf = new Float64Array(pixels);
  let running = 0;
  for (let i = 0; i < pixels; i++) {
    const row = Math.floor(i / width),
      c: Vec3 = [half[i * 4], half[i * 4 + 1], half[i * 4 + 2]].map((h) =>
        DataUtils.fromHalfFloat(h),
      ) as Vec3;
    running += luminance(c) * Math.sin((Math.PI * (row + 0.5)) / height);
    cdf[i] = running;
  }
  const lights = lighting.directional ?? [],
    lightWeights = lights.map((l) =>
      luminance(l.color.map((c) => c * l.intensity) as Vec3),
    ),
    totalWeight = lightWeights.reduce((a, b) => a + b, 0) + envWeight;
  const random = mulberry32(seed),
    power = (a: number, b: number) => (a * a) / (a * a + b * b);
  // Orthonormal basis around the normal for cosine sampling.
  const helper: Vec3 = Math.abs(normal[0]) < 0.9 ? [1, 0, 0] : [0, 1, 0];
  const cross = (a: Vec3, b: Vec3): Vec3 => [
    a[1] * b[2] - a[2] * b[1],
    a[2] * b[0] - a[0] * b[2],
    a[0] * b[1] - a[1] * b[0],
  ];
  const t = unit(cross(helper, normal)),
    b = cross(normal, t);
  const sum: Vec3 = [0, 0, 0];
  for (let s = 0; s < samples; s++) {
    // Next-event estimation.
    let pick = random() * totalWeight,
      chosen = -1;
    for (let i = 0; i < lights.length; i++)
      if ((pick -= lightWeights[i]) < 0) {
        chosen = i;
        break;
      }
    if (chosen >= 0) {
      const light = lights[chosen],
        cosine = dot(normal, light.direction);
      if (cosine > 0)
        for (let c = 0; c < 3; c++)
          sum[c] +=
            (light.color[c] * light.intensity * (albedo / Math.PI) * cosine) /
            (lightWeights[chosen] / totalWeight);
    } else {
      const target = random() * running;
      let lo = 0,
        hi = pixels - 1;
      while (lo < hi) {
        const mid = (lo + hi) >> 1;
        if (cdf[mid] < target) lo = mid + 1;
        else hi = mid;
      }
      const x = (lo % width) + random(),
        y = Math.floor(lo / width) + random();
      const theta = (x / width - 0.5) * 2 * Math.PI,
        phi = (1 - y / height) * Math.PI;
      const d: Vec3 = [
        Math.sin(phi) * Math.cos(theta),
        Math.cos(phi),
        Math.sin(phi) * Math.sin(theta),
      ];
      const cosine = dot(normal, d),
        lightPdf = envPdf(d) * (envWeight / totalWeight);
      if (cosine > 0 && lightPdf > 0) {
        const weight = power(lightPdf, cosine / Math.PI),
          radiance = texel(d);
        for (let c = 0; c < 3; c++)
          sum[c] +=
            (radiance[c] * (albedo / Math.PI) * cosine * weight) / lightPdf;
      }
    }
    // Cosine-sampled BSDF ray escaping to the environment.
    const r1 = random(),
      r2 = random(),
      radius = Math.sqrt(r1),
      angle = 2 * Math.PI * r2,
      lx = radius * Math.cos(angle),
      ly = radius * Math.sin(angle),
      lz = Math.sqrt(Math.max(0, 1 - r1));
    const d = unit([
      t[0] * lx + b[0] * ly + normal[0] * lz,
      t[1] * lx + b[1] * ly + normal[1] * lz,
      t[2] * lx + b[2] * ly + normal[2] * lz,
    ]);
    const bsdfPdf = lz / Math.PI,
      weight = power(bsdfPdf, envPdf(d) * (envWeight / totalWeight)),
      radiance = texel(d);
    // Throughput of a cosine-sampled Lambertian bounce is the albedo.
    for (let c = 0; c < 3; c++) sum[c] += radiance[c] * albedo * weight;
  }
  return sum.map((v) => v / samples) as Vec3;
}

describe("ray-traced lighting matches raster lighting", () => {
  it("lays texels out as the tracer's equirect lookup does", () => {
    for (const [x, y] of [
      [0, 0],
      [17, 9],
      [127, 63],
      [64, 31],
      [64, 32],
    ]) {
      const [u, v] = directionToUv(equirectTexelDirection(x, y, 128, 64));
      expect(u * 128).toBeCloseTo(x + 0.5, 6);
      expect(v * 64).toBeCloseTo(y + 0.5, 6);
    }
    // Row 0 is v = 0, the -Y pole; the last row faces +Y.
    expect(equirectTexelDirection(0, 0, 128, 64)[1]).toBeLessThan(-0.99);
    expect(equirectTexelDirection(0, 63, 128, 64)[1]).toBeGreaterThan(0.99);
  });

  it("gives an ambient light irradiance / PI radiance, not its intensity", () => {
    const radiance = environmentRadiance(
      { ambient: { color: [1, 0.5, 0.25], intensity: 2.6 } },
      [0, 0, 1],
    );
    expect(radiance[0]).toBeCloseTo(2.6 / Math.PI, 9);
    expect(radiance[1]).toBeCloseTo(1.3 / Math.PI, 9);
    expect(radiance[2]).toBeCloseTo(0.65 / Math.PI, 9);
  });

  it("splits the hemisphere light's sky and ground exactly at the horizon", () => {
    const { data, width, height } = buildEnvironment({
      hemisphere: VIEWER.hemisphere,
    });
    const { sky, ground, intensity } = VIEWER.hemisphere!;
    for (let y = 0; y < height; y++) {
      const expected = y < height / 2 ? ground : sky,
        i = (y * width + 5) * 4;
      for (let c = 0; c < 3; c++)
        expect(data[i + c]).toBeCloseTo((expected[c] * intensity) / Math.PI, 6);
    }
  });

  it("converges to the raster's diffuse shading for every surface orientation", () => {
    const albedo = 0.6;
    for (const normal of [
      [0, 1, 0],
      [0, -1, 0],
      [0, 0, 1],
      unit([1, -2, 3]),
      unit([-1, 0.3, -0.2]),
    ] as Vec3[]) {
      const traced = traceLambert(VIEWER, normal, albedo, 120_000, 7),
        raster = rasterIrradiance(VIEWER, normal).map(
          (e) => (albedo / Math.PI) * e,
        );
      for (let c = 0; c < 3; c++)
        expect(Math.abs(traced[c] / raster[c] - 1)).toBeLessThan(0.01);
    }
  });

  it("is PI times too bright when the fill intensity is used as radiance", () => {
    const normal: Vec3 = [0, 0, 1],
      albedo = 0.6;
    // The previous worker traced radiance = ambient intensity.
    const asRadiance: RayTracingLighting = {
      ambient: { color: [1, 1, 1], intensity: 2.6 * Math.PI },
    };
    const traced = traceLambert(asRadiance, normal, albedo, 40_000, 3)[0],
      raster =
        (albedo / Math.PI) *
        rasterIrradiance(
          { ambient: { color: [1, 1, 1], intensity: 2.6 } },
          normal,
        )[0];
    expect(traced / raster).toBeCloseTo(Math.PI, 1);
  });

  it("pre-inverts tone mapping so the traced background shows the raster colour", () => {
    for (const hex of [0x182126, 0xe9eeef]) {
      const color = linear(hex),
        shown = acesFilmic(inverseAcesFilmic(color, 1.35), 1.35);
      for (let c = 0; c < 3; c++) expect(shown[c]).toBeCloseTo(color[c], 4);
    }
  });
});
