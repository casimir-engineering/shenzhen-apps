import * as T from "three";
import { Viewer } from "/src/core/viewer.ts";
const rotationListeners = new Set();
window.shenzhenScroll = {
  source: () => null,
  subscribeRotate(listener) {
    rotationListeners.add(listener);
    return () => rotationListeners.delete(listener);
  },
};
const viewer = new Viewer(document.querySelector("#viewer"));
const geometry = new T.BoxGeometry(10, 10, 10);
const documentFor = (is2D) => ({
  name: "Navigation fixture",
  format: "test",
  geometries: new Map([
    [
      "box",
      {
        id: "box",
        geometry,
        materials: [new T.MeshStandardMaterial({ color: 0xaaaaaa })],
      },
    ],
  ]),
  parts: [
    {
      id: "box",
      name: "Box",
      geometryId: "box",
      matrix: new T.Matrix4().toArray(),
      parentId: "root",
      path: ["Box"],
    },
  ],
  roots: [],
  unit: "mm",
  sourceUnit: "mm",
  warnings: [],
  importMs: 0,
  bytes: 0,
  is2D,
});
let picks = 0;
let wheelSample;
document.addEventListener(
  "wheel",
  (event) => {
    wheelSample = {
      deltaX: event.deltaX,
      deltaY: event.deltaY,
      deltaMode: event.deltaMode,
      ctrlKey: event.ctrlKey,
      wheelDeltaX: event.wheelDeltaX,
      wheelDeltaY: event.wheelDeltaY,
      devicePixelRatio: window.devicePixelRatio,
    };
  },
  true,
);
viewer.onPick = () => picks++;
const snapshot = () => ({
  position: viewer.camera.position.toArray(),
  quaternion: viewer.camera.quaternion.toArray(),
  up: viewer.camera.up.toArray(),
  target: viewer.controls.target.toArray(),
  zoom: viewer.camera.zoom,
  distance: viewer.camera.position.distanceTo(viewer.controls.target),
  orthographic: viewer.camera.isOrthographicCamera === true,
  navigationStyle: viewer.options.navigationStyle,
  reverseWheelZoom: viewer.options.reverseWheelZoom,
  picks,
});
const configure = (options) => {
  viewer.applyOptions({ ...viewer.options, ...options });
  return snapshot();
};
const replaceModel = (is2D) => {
  viewer.setModel(documentFor(is2D));
  picks = 0;
  return snapshot();
};
const reset = (is2D = false, orthographic = false, options = {}) => {
  viewer.setModel(documentFor(is2D));
  viewer.setProjection(orthographic);
  viewer.preset(is2D ? "top" : "iso");
  configure({
    navigation: "auto",
    navigationStyle: "onshape",
    reverseWheelZoom: false,
    grid: false,
    theme: "dark",
    ...options,
  });
  picks = 0;
  wheelSample = undefined;
  return snapshot();
};
const restore = (state) => {
  viewer.camera.position.fromArray(state.position);
  viewer.camera.quaternion.fromArray(state.quaternion);
  if (state.up) viewer.camera.up.fromArray(state.up);
  viewer.camera.zoom = state.zoom;
  viewer.camera.updateProjectionMatrix();
  viewer.controls.target.fromArray(state.target);
  viewer.controls.update();
};
reset();
window.measurementNavigation = {
  viewer,
  snapshot,
  reset,
  restore,
  configure,
  replaceModel,
  wheelSample: () => wheelSample,
  rotationSubscribers: () => rotationListeners.size,
  emitRotation: (payload) => {
    for (const listener of rotationListeners) listener(payload);
    return snapshot();
  },
};
