// Raster versus converged ray-traced exposure on the sample model, through the
// real Viewer and its PNG export. Driven by tests/ray-tracing-exposure-browser.mjs.
import { Viewer } from "/src/core/viewer.ts";
import { createDemo } from "/src/core/demo.ts";

let viewer, states;
const options = (change) =>
  viewer.applyOptions({ ...viewer.options, ...change });

async function waitFor(condition, label) {
  const start = performance.now();
  while (!condition()) {
    const last = states.at(-1);
    if (last?.status === "error" || last?.status === "unsupported")
      throw Error(`${label}: ${last.reason}`);
    if (performance.now() - start > 120_000)
      throw Error(`Timed out waiting for ${label}: ${JSON.stringify(last)}`);
    await new Promise((resolve) => setTimeout(resolve, 40));
  }
}

const captures = {};
const dataUrl = (blob) =>
  new Promise((resolve) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.readAsDataURL(blob);
  });

async function pixels(blob, name, keep) {
  if (keep) captures[name] = await dataUrl(blob);
  const bitmap = await createImageBitmap(blob);
  const canvas = new OffscreenCanvas(bitmap.width, bitmap.height),
    context = canvas.getContext("2d");
  context.drawImage(bitmap, 0, 0);
  bitmap.close();
  return {
    width: canvas.width,
    height: canvas.height,
    rgba: context.getImageData(0, 0, canvas.width, canvas.height).data,
  };
}

/** Display luma (Rec. 709 weights on encoded 8-bit values) per pixel. */
const luma = (rgba, i) =>
  0.2126 * rgba[i] + 0.7152 * rgba[i + 1] + 0.0722 * rgba[i + 2];

/** Pixels that differ from the raster background colour belong to the model. */
function modelMask(image) {
  const { rgba } = image,
    mask = new Uint8Array(rgba.length / 4);
  const bg = [rgba[0], rgba[1], rgba[2]];
  for (let p = 0; p < mask.length; p++) {
    const i = p * 4;
    mask[p] =
      Math.abs(rgba[i] - bg[0]) +
        Math.abs(rgba[i + 1] - bg[1]) +
        Math.abs(rgba[i + 2] - bg[2]) >
      12
        ? 1
        : 0;
  }
  return mask;
}

const BINS = 8;
function stats(image, mask) {
  const { rgba } = image,
    histogram = new Array(BINS).fill(0);
  let sum = 0,
    count = 0,
    clipped = 0;
  for (let p = 0; p < mask.length; p++) {
    if (!mask[p]) continue;
    const i = p * 4,
      y = luma(rgba, i);
    sum += y;
    count++;
    if (Math.max(rgba[i], rgba[i + 1], rgba[i + 2]) >= 250) clipped++;
    histogram[Math.min(BINS - 1, Math.floor((y / 256) * BINS))]++;
  }
  return {
    pixels: count,
    meanLuma: sum / Math.max(1, count),
    clippedFraction: clipped / Math.max(1, count),
    histogram: histogram.map((n) => +(n / Math.max(1, count)).toFixed(4)),
  };
}

const histogramDistance = (a, b) =>
  a.reduce((total, value, i) => total + Math.abs(value - b[i]), 0) / 2;

/**
 * `matte` swaps the sample model's metals for rough dielectrics. Raster has no
 * reflected environment, so matte surfaces isolate exposure from material
 * algorithm differences. `fill` turns on the uniform fill light at its default.
 */
window.rayTracingExposure = async ({
  samples = 128,
  keep = false,
  matte = false,
  fill = false,
} = {}) => {
  for (const name of Object.keys(captures)) delete captures[name];
  viewer = new Viewer(document.querySelector("#viewer"));
  states = [];
  viewer.onRayTracingState = (state) => states.push(state);
  const doc = createDemo();
  if (matte)
    for (const { materials } of doc.geometries.values())
      for (const material of materials)
        Object.assign(material, { metalness: 0, roughness: 1 });
  viewer.setModel(doc);
  options({
    grid: false,
    rayTracing: false,
    rayResolution: 1,
    raySamples: 32,
    navigationDetail: "full",
    uniformLight: fill,
    uniformIntensity: 2.6,
  });
  const raster = await pixels(await viewer.screenshot(), "raster", keep);
  const mask = modelMask(raster);
  const traced = {};
  options({ rayTracing: true });
  await waitFor(
    () =>
      states.at(-1)?.status === "ready" &&
      states.at(-1).target === 32 &&
      viewer.rayTracer?.imageVisible,
    "32-sample trace",
  );
  traced[32] = await pixels(await viewer.screenshot(), "traced-32", keep);
  if (samples !== 32) {
    options({ raySamples: samples });
    await waitFor(
      () =>
        states.at(-1)?.status === "ready" &&
        states.at(-1).target === samples &&
        viewer.rayTracer?.imageVisible,
      `${samples}-sample trace`,
    );
    traced[samples] = await pixels(
      await viewer.screenshot(),
      `traced-${samples}`,
      keep,
    );
  }
  const rasterStats = stats(raster, mask),
    early = stats(traced[32], mask),
    final = stats(traced[samples], mask);
  viewer.dispose();
  return {
    captures: { ...captures },
    size: [raster.width, raster.height],
    samples,
    raster: rasterStats,
    traced32: early,
    traced: final,
    lumaRatio: final.meanLuma / rasterStats.meanLuma,
    backgroundDifference: Math.max(
      ...[0, 1, 2].map((c) =>
        Math.abs(raster.rgba[c] - traced[samples].rgba[c]),
      ),
    ),
    convergenceRatio: final.meanLuma / early.meanLuma,
    histogramDistance: histogramDistance(
      final.histogram,
      rasterStats.histogram,
    ),
  };
};
