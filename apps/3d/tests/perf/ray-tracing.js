import * as T from "three";
import { ProgressiveRayTracer } from "/src/core/progressive-ray-tracer.ts";
import { estimateTraceScene } from "/src/core/ray-tracing-scene.ts";
const sample = new URLSearchParams(location.search).get("model") === "sample";
const host = document.querySelector("#viewer"),
  renderer = new T.WebGLRenderer({
    antialias: true,
    powerPreference: "high-performance",
  });
renderer.setSize(sample ? 480 : 256, sample ? 300 : 192);
host.style.width = renderer.domElement.width + "px";
host.style.height = renderer.domElement.height + "px";
host.appendChild(renderer.domElement);
const camera = new T.PerspectiveCamera(
  40,
  renderer.domElement.width / renderer.domElement.height,
  0.1,
  100,
);
let sources = [];
if (sample) {
  const { importFiles } = await import("/src/core/importers.ts");
  const blob = await (await fetch("/fixtures/sample-assembly.step")).blob();
  const doc = await importFiles(
    [new File([blob], "sample-assembly.step")],
    "balanced",
    () => {},
  );
  for (const [id, data] of doc.geometries) {
    const parts = doc.parts.filter((p) => p.geometryId === id);
    const mesh = new T.InstancedMesh(
      data.geometry,
      data.materials.length === 1 ? data.materials[0] : data.materials,
      parts.length,
    );
    parts.forEach((p, i) =>
      mesh.setMatrixAt(i, new T.Matrix4().fromArray(p.matrix)),
    );
    mesh.computeBoundingSphere();
    sources.push(mesh);
  }
} else {
  const map = new T.DataTexture(
    new Uint8Array([
      255, 255, 255, 255, 20, 80, 100, 255, 20, 80, 100, 255, 255, 255, 255,
      255,
    ]),
    2,
    2,
  );
  map.colorSpace = T.SRGBColorSpace;
  map.needsUpdate = true;
  const source = new T.InstancedMesh(
    new T.SphereGeometry(0.7, 24, 16),
    new T.MeshStandardMaterial({
      color: 0x319fb0,
      roughness: 0.35,
      metalness: 0.1,
      map,
    }),
    2,
  );
  source.setMatrixAt(0, new T.Matrix4().makeTranslation(-0.9, 0, 0));
  source.setMatrixAt(1, new T.Matrix4().makeTranslation(0.9, 0, 0));
  source.setColorAt(0, new T.Color(1, 1, 1));
  source.setColorAt(1, new T.Color(0.8, 1, 0.8));
  source.computeBoundingSphere();
  sources.push(source);
  const glass = new T.Mesh(
    new T.SphereGeometry(0.35, 16, 12),
    new T.MeshPhysicalMaterial({
      color: 0xffffff,
      transmission: 0.8,
      thickness: 0.2,
      roughness: 0.08,
      transparent: true,
      opacity: 0.7,
    }),
  );
  glass.position.set(0, -0.3, 1);
  sources.push(glass);
}
const bounds = new T.Box3();
for (const source of sources) {
  source.updateMatrixWorld();
  bounds.union(new T.Box3().setFromObject(source));
}
const center = bounds.getCenter(new T.Vector3()),
  radius = bounds.getSize(new T.Vector3()).length() / 2;
camera.near = radius / 1000;
camera.far = radius * 100;
camera.up.set(0, 0, 1);
camera.position
  .copy(center)
  .add(new T.Vector3(1, -1, 1.2).normalize().multiplyScalar(radius * 3.5));
camera.lookAt(center);
camera.updateProjectionMatrix();
camera.updateMatrixWorld();
const scene = new T.Scene();
scene.background = new T.Color(0x182126);
scene.add(...sources, new T.HemisphereLight(0xffffff, 0x444444, 3));
renderer.render(scene, camera);
window.rtStates = [];
const tracer = new ProgressiveRayTracer(host, renderer, (state) => {
  window.rtStates.push(state);
  console.log("RT_STATE", JSON.stringify(state));
});
window.tracer = tracer;
window.rtStats = estimateTraceScene(sources);
window.rtStats.geometryCount = new Set(sources.map((s) => s.geometry)).size;
window.rtOriginal = sources.map((s) => ({
  index: Array.from(s.geometry.index.array),
  positions: Array.from(s.geometry.attributes.position.array),
  matrix: s.instanceMatrix
    ? Array.from(s.instanceMatrix.array)
    : s.matrix.toArray(),
}));
const originalCoordinates = camera.coordinateSystem;
window.rtUnchanged = () =>
  camera.coordinateSystem === originalCoordinates &&
  sources.every(
    (s, i) =>
      JSON.stringify(Array.from(s.geometry.index.array)) ===
        JSON.stringify(window.rtOriginal[i].index) &&
      JSON.stringify(Array.from(s.geometry.attributes.position.array)) ===
        JSON.stringify(window.rtOriginal[i].positions) &&
      JSON.stringify(
        s.instanceMatrix
          ? Array.from(s.instanceMatrix.array)
          : s.matrix.toArray(),
      ) === JSON.stringify(window.rtOriginal[i].matrix),
  );
window.rtReady = tracer.prepare(
  {
    sources,
    camera,
    // Ambient intensity PI is environment radiance 1 (see ray-tracing-lighting.ts).
    lighting: sample
      ? { ambient: { color: [1, 1, 1], intensity: Math.PI } }
      : {
          ambient: { color: [1, 1, 1], intensity: 0.5 * Math.PI },
          directional: [
            { direction: [1, -2, 3], color: [1, 1, 1], intensity: 3.2 },
          ],
        },
    background: new T.Color(0x182126),
  },
  { samples: 32, resolution: sample ? 1 : 0.5 },
);
window.rtSnapshot = () => tracer.snapshot();
window.rtCancel = () => tracer.cancel();
window.rtPause = () => {
  tracer.setMoving(true);
  return document.querySelector(".ray-tracing-overlay").style.visibility;
};
window.rtMove = () => {
  camera.position.x += radius * 0.05;
  camera.lookAt(center);
  camera.updateMatrixWorld();
  tracer.setCamera(camera);
  tracer.setMoving(false);
};
