import { Viewer } from "/src/core/viewer.ts";
import { importFiles, disposeDocument } from "/src/core/importers.ts";
import { cad } from "/src/core/cad-client.ts";

const viewer = new Viewer(document.querySelector("#viewer"));
viewer.applyOptions({
  ...viewer.options,
  grid: false,
  navigationDetail: "full",
  renderStyle: "shaded",
  edges: false,
});
let model;
const snapshot = () => ({
  parts: model?.parts.length,
  geometries: model?.geometries.size,
  triangles: model
    ? [...model.geometries.values()].reduce(
        (n, g) =>
          n +
          (g.lines
            ? 0
            : (g.geometry.index?.count ??
                g.geometry.attributes.position.count) / 3),
        0,
      )
    : 0,
  near: viewer.camera.near,
  far: viewer.camera.far,
  distance: viewer.camera.position.distanceTo(viewer.controls.target),
  position: viewer.camera.position.toArray(),
  target: viewer.controls.target.toArray(),
  orthographic: !!viewer.camera.isOrthographicCamera,
  bounds: viewer.bounds.toArray?.() ?? {
    min: viewer.bounds.min.toArray(),
    max: viewer.bounds.max.toArray(),
  },
  memory: { ...viewer.renderer.info.memory },
  contextLost: viewer.renderer.getContext().isContextLost(),
  glError: viewer.renderer.getContext().getError(),
});
const pixels = () => {
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
};
const difference = (a, b) => {
  let changed = 0;
  for (let i = 0; i < a.length; i += 4)
    if (
      Math.max(
        Math.abs(a[i] - b[i]),
        Math.abs(a[i + 1] - b[i + 1]),
        Math.abs(a[i + 2] - b[i + 2]),
      ) > 3
    )
      changed++;
  return { changed, fraction: changed / (a.length / 4) };
};
window.modelLifecycle = {
  viewer,
  snapshot,
  async load(url, name) {
    cad.cancel();
    viewer.clearModel();
    if (model) disposeDocument(model);
    model = undefined;
    const bytes = await (await fetch(url)).arrayBuffer();
    model = await importFiles([new File([bytes], name)], "balanced", () => {});
    // App's effects install the document before applying its 2D/3D projection.
    viewer.setModel(model);
    viewer.setProjection(model.is2D);
    await viewer.whenReady;
    viewer.draw();
    return snapshot();
  },
  depthReference() {
    const actual = pixels(),
      before = snapshot();
    const distance = viewer.camera.position.distanceTo(viewer.controls.target);
    viewer.camera.near = Math.max(distance / 10000, 0.00001);
    viewer.camera.far = Math.max(distance * 100, 1000);
    viewer.camera.updateProjectionMatrix();
    const expected = pixels();
    return {
      before,
      reference: snapshot(),
      difference: difference(actual, expected),
    };
  },
  clear() {
    cad.cancel();
    viewer.clearModel();
    if (model) disposeDocument(model);
    model = undefined;
    viewer.draw();
    return snapshot();
  },
};
