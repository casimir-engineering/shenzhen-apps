import * as T from "three";
import { Viewer } from "/src/core/viewer.ts";
const viewer = new Viewer(document.querySelector("#viewer"));
const geometry = new T.SphereGeometry(1, 20, 12);
const original = Array.from(geometry.index.array);
const material = new T.MeshStandardMaterial({
  color: 0x319fb0,
  roughness: 0.4,
});
const part = {
  id: "sphere-0",
  name: "Sphere",
  geometryId: "sphere",
  matrix: new T.Matrix4().toArray(),
  parentId: "root",
  path: [],
};
const doc = {
  name: "RT integration",
  format: "test",
  geometries: new Map([
    ["sphere", { id: "sphere", geometry, materials: [material] }],
  ]),
  parts: [part],
  roots: [],
  unit: "mm",
  sourceUnit: "mm",
  warnings: [],
  importMs: 0,
  bytes: 0,
  is2D: false,
};
const options = (change) =>
  viewer.applyOptions({ ...viewer.options, ...change });
const states = [];
viewer.onRayTracingState = (state) => states.push(state);
const waitFor = async (condition) => {
  const start = performance.now();
  while (!condition()) {
    if (performance.now() - start > 45000)
      throw Error("Timed out: " + JSON.stringify(states.at(-1)));
    if (states.at(-1)?.status === "error") throw Error(states.at(-1).reason);
    await new Promise((resolve) => setTimeout(resolve, 40));
  }
};
const checks = [];
function check(ok, message) {
  if (!ok) throw Error(message);
  checks.push(message);
}
function alphaPixels() {
  viewer.draw();
  const gl = viewer.renderer.getContext();
  const data = new Uint8Array(
    gl.drawingBufferWidth * gl.drawingBufferHeight * 4,
  );
  gl.readPixels(
    0,
    0,
    gl.drawingBufferWidth,
    gl.drawingBufferHeight,
    gl.RGBA,
    gl.UNSIGNED_BYTE,
    data,
  );
  return data.filter((value, i) => i % 4 === 3 && value > 0).length;
}
window.viewerRayTracingChecks = async () => {
  viewer.setModel(doc);
  options({
    grid: false,
    rayTracing: true,
    raySamples: 32,
    rayResolution: 0.5,
    navigationDetail: "full",
  });
  await waitFor(
    () => states.at(-1)?.status === "ready" && viewer.rayTracer.imageVisible,
  );
  check(
    viewer.renderer.getContext().getContextAttributes().alpha,
    "Main WebGL context supports transparent annotation composition",
  );
  check(
    alphaPixels() === 0,
    "Converged trace reveals underlying worker canvas through transparent raster",
  );
  check(
    viewer.content.visible && viewer.scene.background.isColor,
    "Overlay-only drawing restores scene state",
  );
  const generation = viewer.rayTraceGeneration,
    tracer = viewer.rayTracer,
    worker = tracer.worker;
  viewer.setOverlay({ points: [[0, 0, 0]], text: "RT dimension" });
  check(
    alphaPixels() > 10 && tracer.imageVisible,
    "Measurement markers render over a live traced image without pausing it",
  );
  viewer.setSelectionMode("part", "auto", true);
  viewer.highlight([
    {
      ...part,
      partId: part.id,
      kind: "face",
      triangleIndex: 0,
      localPoint: [0, 0, 0],
      point: [0, 0, 0],
    },
  ]);
  check(
    alphaPixels() > 100 && tracer.imageVisible,
    "Selection highlight remains visible over traced surfaces",
  );
  const blob = await viewer.screenshot(),
    bitmap = await createImageBitmap(blob);
  const canvas = new OffscreenCanvas(bitmap.width, bitmap.height),
    context = canvas.getContext("2d");
  context.drawImage(bitmap, 0, 0);
  bitmap.close();
  const rgba = context.getImageData(0, 0, canvas.width, canvas.height).data;
  const colors = new Set();
  for (let i = 0; i < rgba.length; i += 4)
    colors.add(rgba.slice(i, i + 3).join());
  check(
    canvas.width === viewer.renderer.domElement.width &&
      rgba.every((value, i) => i % 4 !== 3 || value === 255) &&
      colors.size > 100,
    "Screenshot composites traced image, transparent raster overlays and dimension label at full output size",
  );
  viewer.highlight([]);
  viewer.setOverlay({ points: [] });
  viewer.camera.position.x += 0.1;
  viewer.controls.update();
  check(
    !tracer.imageVisible,
    "Camera movement reveals full raster immediately",
  );
  check(
    alphaPixels() ===
      viewer.renderer.domElement.width * viewer.renderer.domElement.height,
    "Navigation renders the complete opaque raster scene",
  );
  await waitFor(() => tracer.imageVisible);
  check(
    viewer.rayTraceGeneration === generation && tracer.worker === worker,
    "Camera updates reuse worker scene instead of serializing model geometry",
  );
  options({ raySamples: 128 });
  check(
    tracer.worker === worker,
    "Sample setting changes reuse the prepared scene",
  );
  options({ section: true });
  await waitFor(() => states.at(-1)?.status === "unsupported");
  check(
    !tracer.imageVisible && alphaPixels() > 0,
    "Section clipping falls back to complete raster with an explicit unsupported reason",
  );
  options({ section: false, renderStyle: "wireframe" });
  check(
    states.at(-1).status === "unsupported" && !viewer.rayTraceEnabled,
    "Line-only rendering rejects traced overlay and preserves raster style",
  );
  options({ rayTracing: false, renderStyle: "shaded" });
  check(
    !document.querySelector(".ray-tracing-overlay"),
    "Disabling ray tracing removes worker canvas",
  );
  check(
    original.every((value, i) => geometry.index.array[i] === value),
    "Ray tracing and overlay rendering preserve source geometry",
  );
  viewer.dispose();
  check(
    !document.querySelector("canvas"),
    "Viewer disposal removes both graphics canvases",
  );
  return {
    checks,
    statuses: [...new Set(states.map((state) => state.status))],
    pngBytes: blob.size,
  };
};
