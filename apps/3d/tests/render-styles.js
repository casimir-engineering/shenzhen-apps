import * as T from "three";
import { Viewer } from "/src/core/viewer.ts";

const viewer = new Viewer(document.querySelector("#viewer"));
const checks = [];
function check(condition, message, details) {
  if (!condition)
    throw new Error(`${message}: ${JSON.stringify(details ?? null)}`);
  checks.push({ message, ...(details === undefined ? {} : { details }) });
}
const options = (change) =>
  viewer.applyOptions({ ...viewer.options, ...change });
function pixels() {
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
  return data;
}
function countColored(data) {
  let count = 0;
  for (let i = 0; i < data.length; i += 4)
    if (
      Math.max(
        Math.abs(data[i] - data[0]),
        Math.abs(data[i + 1] - data[1]),
        Math.abs(data[i + 2] - data[2]),
      ) > 8
    )
      count++;
  return count;
}
function difference(a, b) {
  let count = 0;
  for (let i = 0; i < a.length; i += 4)
    if (
      Math.max(
        Math.abs(a[i] - b[i]),
        Math.abs(a[i + 1] - b[i + 1]),
        Math.abs(a[i + 2] - b[i + 2]),
      ) > 8
    )
      count++;
  return count;
}

window.renderStyleChecks = async () => {
  const geometry = new T.BoxGeometry(2, 2, 2);
  const originalIndex = [...geometry.index.array];
  const material = new T.MeshStandardMaterial({
    color: 0xb49a80,
    roughness: 0.5,
  });
  const doc = {
    name: "Styles fixture",
    format: "test",
    geometries: new Map([
      ["box", { id: "box", geometry, materials: [material] }],
    ]),
    parts: [
      {
        id: "box-0",
        name: "Box",
        geometryId: "box",
        matrix: new T.Matrix4().toArray(),
        parentId: "root",
        path: [],
      },
    ],
    roots: [],
    unit: "mm",
    sourceUnit: "mm",
    warnings: [],
    importMs: 0,
    bytes: 0,
    is2D: false,
  };
  viewer.setModel(doc);
  options({ grid: false, navigationDetail: "full", renderStyle: "shaded" });
  viewer.camera.position.set(5, -7, 5);
  viewer.controls.target.set(0, 0, 0);
  viewer.controls.update();
  const shaded = pixels(),
    filled = countColored(shaded);
  options({ renderStyle: "hidden-line" });
  const hidden = pixels(),
    hiddenCount = countColored(hidden);
  check(
    hiddenCount > 100 && hiddenCount < filled * 0.25,
    "Hidden-line draws sparse edges rather than shaded faces",
    { hiddenCount, filled },
  );
  const dashed = viewer.edgeSets.get("creases:hidden");
  dashed.forEach((line) => {
    line.visible = false;
  });
  const visibleOnly = pixels();
  dashed.forEach((line) => {
    line.visible = true;
  });
  check(
    difference(hidden, visibleOnly) > 20,
    "Occluded dashed edges add visible pixels behind the depth prepass",
    difference(hidden, visibleOnly),
  );
  const edgePositions = viewer.edgeSets
    .get("creases:visible")[0]
    .geometry.getAttribute("position");
  options({ renderStyle: "wireframe" });
  const wires = pixels();
  check(
    viewer.edgeSets
      .get("triangles:visible")[0]
      .geometry.getAttribute("position").count > edgePositions.count,
    "Wireframe includes triangle diagonals beyond CAD creases",
  );
  check(
    difference(wires, hidden) > 100,
    "Wireframe and CAD hidden-line produce distinct images",
  );
  options({
    renderStyle: "hidden-line",
    section: true,
    sectionAxis: "z",
    sectionPosition: 0.5,
  });
  const clipped = pixels();
  check(
    countColored(clipped) > 0 && difference(clipped, hidden) > 100,
    "Section plane clips solid and dashed edges",
  );
  const pick = { partId: "box-0", localPoint: [0, 0, 0.5] };
  check(
    !viewer.projectPick(pick).visible,
    "Annotation projection excludes section-clipped points",
  );
  options({ section: false, explode: 0.5, hidden: new Set(["box-0"]) });
  check(
    countColored(pixels()) === 0,
    "Hidden zero matrices leave no stray solid or dashed pixels",
  );
  check(
    !viewer.projectPick(pick).visible,
    "Annotation projection excludes hidden occurrences",
  );
  check(
    viewer.edgeSets
      .get("creases:visible")[0]
      .geometry.getAttribute("position") === edgePositions,
    "Hide, section and style changes reuse unique edge positions",
  );
  options({ hidden: new Set(), explode: 0, renderStyle: "shaded", opacity: 1 });
  check(
    difference(pixels(), shaded) === 0,
    "Returning to shaded restores the original image exactly",
  );
  options({ lightAzimuth: 116.565051177078, lightElevation: 20 });
  check(
    difference(pixels(), shaded) > 1000,
    "Moving the key light changes surface shading",
  );
  options({ uniformLight: true, uniformIntensity: 3 });
  check(
    viewer.uniformLight.visible && viewer.uniformLight.intensity === 3,
    "Uniform ambient fill follows its controls",
  );
  check(
    originalIndex.every((value, i) => geometry.index.array[i] === value),
    "Rendering styles preserve original triangle order",
  );
  const distance = viewer.camera.position.distanceTo(viewer.controls.target);
  viewer.focusPick({ partId: "box-0", localPoint: [0.5, 0.5, 0.5] });
  check(
    Math.abs(
      viewer.camera.position.distanceTo(viewer.controls.target) - distance,
    ) < 1e-9,
    "Focusing an annotation retains camera distance",
  );
  let changed = 0;
  viewer.onViewChanged = () => changed++;
  pixels();
  check(changed > 0, "View change callback runs after rendering");
  const gl = viewer.renderer.getContext();
  const ext = gl.getExtension("WEBGL_debug_renderer_info");
  const renderer = ext
    ? gl.getParameter(ext.UNMASKED_RENDERER_WEBGL)
    : gl.getParameter(gl.RENDERER);
  viewer.dispose();
  return { renderer, checks };
};
