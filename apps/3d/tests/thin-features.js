// Thin and coplanar features: a pixel test page driven by tests/thin-features-browser.mjs.
//
// The fixture is a 4 × 3 × 2 mm body with a printed marking on its top face (a ring with a hole and a few strokes,
// `proud` mm high, so its underside lies exactly in the body's top plane) and a zero-thickness label lying exactly
// in that plane. Each rendered pixel is checked against a ray cast in double precision from the same camera: the
// pixel must show the surface the ray meets first (the marking over the body; the label over the coplanar body face).
// Pixels next to a boundary between surfaces are skipped, since antialiasing blends them.
import * as T from "three";
import { MeshBVH, acceleratedRaycast } from "three-mesh-bvh";
import { Viewer } from "/src/core/viewer.ts";
import { importFiles } from "/src/core/importers.ts";

T.Mesh.prototype.raycast = acceleratedRaycast;
const viewer = new Viewer(document.querySelector("#viewer"));
window.viewer = viewer;

// Distinct hues, so that lighting and sheen never move one surface's pixels into another's class.
const COLORS = { body: 0xefe9dc, marking: 0x1d4ed8, label: 0xd02020 };
const material = (color) =>
  new T.MeshStandardMaterial({
    color,
    roughness: 0.48,
    metalness: 0.12,
    side: T.DoubleSide,
  });

function markingShapes() {
  const shapes = [];
  // A logo: a ring, a face with a hole like the ones that showed radial spikes.
  const ring = new T.Shape().absarc(-0.8, 0, 0.5, 0, Math.PI * 2, false);
  ring.holes.push(new T.Path().absarc(-0.8, 0, 0.3, 0, Math.PI * 2, true));
  shapes.push(ring);
  // Text-like strokes, 80 µm wide.
  for (let row = 0; row < 3; row++)
    for (let column = 0; column < 5; column++) {
      const x = 0.05 + column * 0.3,
        y = -0.5 + row * 0.4;
      shapes.push(
        new T.Shape()
          .moveTo(x, y)
          .lineTo(x + 0.08, y)
          .lineTo(x + 0.08, y + 0.3)
          .lineTo(x + 0.22, y + 0.3)
          .lineTo(x + 0.22, y + 0.38)
          .lineTo(x, y + 0.38)
          .closePath(),
      );
    }
  return shapes;
}

/** The fixture's three surfaces as geometries in model coordinates. */
function fixtureGeometries(proud) {
  const top = 2;
  const body = new T.BoxGeometry(4, 3, 2).translate(0, 0, 1);
  const marking = new T.ExtrudeGeometry(markingShapes(), {
    depth: proud,
    bevelEnabled: false,
    curveSegments: 48,
  }).translate(0, 0, top);
  const label = new T.ShapeGeometry(
    new T.Shape()
      .moveTo(-1.8, 0.8)
      .lineTo(-1.1, 0.8)
      .lineTo(-1.1, 1.3)
      .lineTo(-1.8, 1.3)
      .closePath(),
  ).translate(0, 0, top);
  for (const g of [body, marking, label]) {
    g.clearGroups();
    g.addGroup(0, g.index ? g.index.count : g.attributes.position.count, 0);
  }
  return { body, marking, label };
}

function documentOf(name, geometries, colors) {
  const entries = Object.entries(geometries);
  return {
    name,
    format: "test",
    geometries: new Map(
      entries.map(([id, geometry]) => [
        id,
        { id, geometry, materials: [material(colors[id])] },
      ]),
    ),
    parts: entries.map(([id]) => ({
      id: id + "-0",
      name: id,
      geometryId: id,
      matrix: new T.Matrix4().toArray(),
      parentId: "root",
      path: [name, id],
    })),
    roots: [],
    unit: "mm",
    sourceUnit: "mm",
    warnings: [],
    importMs: 0,
    bytes: 0,
    is2D: false,
  };
}

let oracle;
function loadFixture({ proud = 0.01 } = {}) {
  const geometries = fixtureGeometries(proud);
  viewer.setModel(documentOf("Thin features", geometries, COLORS));
  viewer.applyOptions({ ...viewer.options, navigationDetail: "full" });
  // The oracle keeps its own copies: the viewer may reorder or batch the ones it was given.
  const copies = fixtureGeometries(proud);
  oracle = Object.entries(copies).map(([id, geometry]) => {
    geometry.boundsTree = new MeshBVH(geometry);
    const mesh = new T.Mesh(geometry, new T.MeshBasicMaterial({ side: T.DoubleSide }));
    mesh.userData.surface = id;
    return mesh;
  });
  for (const mesh of oracle) mesh.updateMatrixWorld(true);
  return { proud };
}

/** Open a model the way the app does: base64 bytes, or a URL on this server (`url:/artifacts/…`). */
async function loadStep(source, name, quality = "balanced") {
  const start = performance.now();
  const bytes = source.startsWith("url:")
    ? new Uint8Array(await (await fetch(source.slice(4))).arrayBuffer())
    : Uint8Array.from(atob(source), (c) => c.charCodeAt(0));
  const doc = await importFiles([new File([bytes], name)], quality, () => {});
  viewer.setModel(doc);
  viewer.applyOptions({ ...viewer.options, navigationDetail: "full" });
  oracle = undefined;
  return {
    ms: performance.now() - start,
    parts: doc.parts.length,
    bounds: viewer.getBounds().toArray?.() ?? null,
  };
}

/**
 * Put the camera `distance` mm from `target`, looking at it from `azimuth`/`elevation` degrees. The orbit target
 * (which the app's clipping planes follow) is `orbit`, or `target` itself.
 */
function view({ target = [0, 0, 2], azimuth = -60, elevation = 45, distance = 10, orbit, roll = 0 }) {
  const camera = viewer.camera;
  const a = T.MathUtils.degToRad(azimuth),
    e = T.MathUtils.degToRad(elevation);
  const t = new T.Vector3(...target);
  camera.up.set(0, 0, 1);
  camera.position
    .copy(t)
    .add(new T.Vector3(Math.cos(e) * Math.cos(a), Math.cos(e) * Math.sin(a), Math.sin(e)).multiplyScalar(distance));
  viewer.controls.target.copy(orbit ? new T.Vector3(...orbit) : t);
  camera.lookAt(t);
  if (roll) camera.rotateZ(T.MathUtils.degToRad(roll));
  camera.updateMatrixWorld();
}

/** Draw now and return the drawing buffer, bottom row first. */
function pixels() {
  viewer.draw();
  const gl = viewer.renderer.getContext();
  const width = gl.drawingBufferWidth,
    height = gl.drawingBufferHeight;
  const data = new Uint8Array(width * height * 4);
  gl.readPixels(0, 0, width, height, gl.RGBA, gl.UNSIGNED_BYTE, data);
  return { data, width, height };
}

function classify(r, g, b) {
  // Red, and pink when grazing light washes it out (240, 226, 235); the cream body stays under r − g = 10.
  if (r > g + 10 && r >= b) return "label";
  // Blue, even when washed out (205, 218, 245).
  if (b > r + 25) return "marking";
  if (Math.max(r, g, b) - Math.min(r, g, b) < 22 && Math.min(r, g, b) > 120) return "body";
  return "other";
}

/** First surface along each pixel's ray, in double precision; coplanar ties go to the label (a sheet on a face). */
function expected(width, height, step) {
  const camera = viewer.camera;
  camera.updateMatrixWorld();
  const raycaster = new T.Raycaster();
  raycaster.firstHitOnly = false;
  const out = new Array(Math.ceil(width / step) * Math.ceil(height / step));
  const ndc = new T.Vector2();
  let k = 0;
  for (let y = 0; y < height; y += step)
    for (let x = 0; x < width; x += step, k++) {
      ndc.set(((x + 0.5) / width) * 2 - 1, ((y + 0.5) / height) * 2 - 1);
      raycaster.setFromCamera(ndc, camera);
      let best;
      for (const mesh of oracle) {
        const hit = mesh.geometry.boundsTree.raycastFirst(raycaster.ray, T.DoubleSide);
        if (!hit) continue;
        const surface = mesh.userData.surface;
        if (
          !best ||
          hit.distance < best.distance - 1e-9 ||
          (Math.abs(hit.distance - best.distance) <= 1e-9 && surface === "label")
        )
          best = { distance: hit.distance, surface };
      }
      out[k] = best?.surface ?? "none";
    }
  return { out, columns: Math.ceil(width / step), rows: Math.ceil(height / step) };
}

/**
 * Pixels that show a different surface than the ray oracle, among pixels whose 3 × 3 neighbourhood (in oracle
 * samples) all meet the same surface.
 */
function check({ step = 1 } = {}) {
  const { data, width, height } = pixels();
  const { out, columns, rows } = expected(width, height, step);
  const counts = { checked: 0, wrong: 0, marking: 0, label: 0, body: 0 };
  const wrongBy = {};
  for (let j = 1; j < rows - 1; j++)
    for (let i = 1; i < columns - 1; i++) {
      const surface = out[j * columns + i];
      if (surface === "none") continue;
      let uniform = true;
      for (let dj = -1; dj <= 1 && uniform; dj++)
        for (let di = -1; di <= 1; di++)
          if (out[(j + dj) * columns + i + di] !== surface) {
            uniform = false;
            break;
          }
      if (!uniform) continue;
      const p = ((j * step) * width + i * step) * 4;
      const seen = classify(data[p], data[p + 1], data[p + 2]);
      counts.checked++;
      counts[surface]++;
      if (seen !== surface) {
        counts.wrong++;
        const key = surface + "→" + seen;
        wrongBy[key] = (wrongBy[key] ?? 0) + 1;
      }
    }
  return {
    ...counts,
    wrongBy,
    near: viewer.camera.near,
    far: viewer.camera.far,
    fraction: counts.wrong / Math.max(counts.checked, 1),
  };
}

/** PNG of the current view, as a data URL. */
function capture() {
  viewer.draw();
  return viewer.renderer.domElement.toDataURL("image/png");
}

/** Pin the clipping planes (for comparing against a known-good depth range); undefined restores the app's. */
let pinned;
const sync = Object.getPrototypeOf(viewer).syncClipping;
viewer.syncClipping = function () {
  if (!pinned) return sync.call(this);
  this.camera.near = pinned.near;
  this.camera.far = pinned.far;
  this.camera.updateProjectionMatrix();
};
function pinClipping(range) {
  pinned = range;
}

function info() {
  const gl = viewer.renderer.getContext();
  const debug = gl.getExtension("WEBGL_debug_renderer_info");
  return {
    renderer: debug ? gl.getParameter(debug.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER),
    depthBits: gl.getParameter(gl.DEPTH_BITS),
    clipControl: !!gl.getExtension("EXT_clip_control"),
    drawingBuffer: [gl.drawingBufferWidth, gl.drawingBufferHeight],
    dpr: devicePixelRatio,
  };
}

/** Milliseconds per frame (draw and clipping) over `frames` orbit steps, and the clipping share. */
function orbitTiming({ frames = 120, distance, elevation = 35, target } = {}) {
  const box = viewer.getBounds(),
    center = box.getCenter(new T.Vector3()),
    size = box.getSize(new T.Vector3()).length();
  const gl = viewer.renderer.getContext();
  const sync = viewer.syncClipping.bind(viewer);
  let clipping = 0;
  viewer.syncClipping = () => {
    const t = performance.now();
    sync();
    clipping += performance.now() - t;
  };
  const pixel = new Uint8Array(4);
  const start = performance.now();
  for (let i = 0; i < frames; i++) {
    view({ target: target ?? center.toArray(), distance: distance ?? size, elevation, azimuth: (i * 360) / frames });
    viewer.draw();
    gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, pixel); // wait for the GPU
  }
  const total = performance.now() - start;
  viewer.syncClipping = sync;
  return { frameMs: total / frames, clippingMs: clipping / frames };
}

window.thin = {
  orbitTiming, loadFixture, loadStep, view, check, capture, pinClipping, info, pixels };
