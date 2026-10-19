import * as T from 'three';
import { Viewer } from '/src/core/viewer.ts';
import { createDemo } from '/src/core/demo.ts';
import { createNavigationLods } from '/src/core/navigation-lod.ts';

const host = document.querySelector('#viewer');
const viewer = new Viewer(host);
const checks = [];
const check = (condition, message, details) => {
  if (!condition) throw new Error(`${message}: ${JSON.stringify(details ?? null)}`);
  checks.push({ message, ...(details === undefined ? {} : { details }) });
};
const raf = () => new Promise(resolve => requestAnimationFrame(resolve));
const options = change => viewer.applyOptions({ ...viewer.options, ...change });
const sources = () => [...viewer.batches.values()];

function documentFor(entries) {
  const geometries = new Map();
  const parts = [];
  for (const { id, geometry, materials, transforms = [new T.Matrix4()] } of entries) {
    geometries.set(id, { id, geometry, materials });
    transforms.forEach((matrix, i) => parts.push({ id: `${id}-${i}`, name: `${id} ${i}`, geometryId: id, matrix: matrix.toArray(), parentId: 'root', path: ['root', id] }));
  }
  return { name: 'Rendering regression fixture', format: 'test', geometries, parts,
    roots: [{ id: 'root', name: 'Fixture', partIds: parts.map(part => part.id), children: [] }],
    unit: 'mm', sourceUnit: 'mm', warnings: [], importMs: 0, bytes: 0, is2D: false };
}

function visualFixture() {
  const grouped = new T.BoxGeometry(2, 2, 1);
  grouped.groups.forEach((group, i) => { group.materialIndex = i % 2; });
  const vertexColored = new T.SphereGeometry(1.1, 24, 16);
  const position = vertexColored.getAttribute('position');
  const colors = new Float32Array(position.count * 3);
  for (let i = 0; i < position.count; i++) {
    colors[i * 3] = (position.getX(i) + 1.1) / 2.2;
    colors[i * 3 + 1] = (position.getY(i) + 1.1) / 2.2;
    colors[i * 3 + 2] = 0.75;
  }
  vertexColored.setAttribute('color', new T.BufferAttribute(colors, 3));
  const texture = new T.DataTexture(new Uint8Array([
    255, 255, 255, 255, 245, 90, 35, 255,
    35, 140, 245, 255, 40, 220, 115, 255,
  ]), 2, 2);
  texture.colorSpace = T.SRGBColorSpace;
  texture.magFilter = T.NearestFilter;
  texture.needsUpdate = true;
  const shaded = new T.MeshStandardMaterial({ color: 0xcdbb8a, roughness: 0.35, metalness: 0.2 });
  const shadedGeometry = new T.SphereGeometry(1, 32, 24);
  const shadedTransform = new T.Matrix4().compose(new T.Vector3(3, -5, 0), new T.Quaternion().setFromEuler(new T.Euler(0.3, 0.5, 0.2)), new T.Vector3(1.3, 0.6, 0.8));
  const uniqueGrouped = new T.BoxGeometry(2, 2, 1);
  uniqueGrouped.groups.forEach((group, i) => { group.materialIndex = i % 2; });
  const uniquePalette = [new T.MeshBasicMaterial({ color: 0xe77599 }), new T.MeshBasicMaterial({ color: 0x8888ff })];
  const translate = (x, y, z = 0) => new T.Matrix4().makeTranslation(x, y, z);
  return documentFor([
    { id: 'grouped', geometry: grouped, materials: [new T.MeshBasicMaterial({ color: 0xffbb22 }), new T.MeshBasicMaterial({ color: 0x22bbdd })], transforms: [translate(-3, 2), translate(0, 2)] },
    { id: 'textured', geometry: new T.BoxGeometry(2, 2, 1), materials: [new T.MeshBasicMaterial({ map: texture })], transforms: [translate(3, 2)] },
    { id: 'vertex-colored', geometry: vertexColored, materials: [new T.MeshBasicMaterial({ vertexColors: true })], transforms: [translate(-3, -2)] },
    { id: 'transparent-back', geometry: new T.BoxGeometry(2, 2, 0.2), materials: [new T.MeshBasicMaterial({ color: 0x33ff99, opacity: 0.55, transparent: true })], transforms: [translate(1.5, -2, -0.3)] },
    { id: 'transparent-front', geometry: new T.BoxGeometry(2, 2, 0.2), materials: [new T.MeshBasicMaterial({ color: 0x8844ff, opacity: 0.6, transparent: true })], transforms: [translate(1.8, -2, 0.3)] },
    { id: 'shaded-normal-a', geometry: shadedGeometry, materials: [shaded], transforms: [translate(0, -5)] },
    { id: 'shaded-normal-b', geometry: shadedGeometry.clone(), materials: [shaded], transforms: [shadedTransform] },
    { id: 'unique-grouped-a', geometry: uniqueGrouped, materials: uniquePalette, transforms: [translate(-3, -8)] },
    { id: 'unique-grouped-b', geometry: uniqueGrouped.clone(), materials: uniquePalette, transforms: [translate(0, -8)] },
  ]);
}

function pixels() {
  // Read synchronously inside the same turn as rendering. This intentionally
  // works with a discarded drawing buffer; it does not change renderer options.
  viewer.draw();
  const gl = viewer.renderer.getContext();
  const data = new Uint8Array(gl.drawingBufferWidth * gl.drawingBufferHeight * 4);
  gl.readPixels(0, 0, gl.drawingBufferWidth, gl.drawingBufferHeight, gl.RGBA, gl.UNSIGNED_BYTE, data);
  return data;
}

function difference(a, b, tolerance = 3) {
  let changed = 0, maximum = 0;
  for (let i = 0; i < a.length; i += 4) {
    const delta = Math.max(Math.abs(a[i] - b[i]), Math.abs(a[i + 1] - b[i + 1]), Math.abs(a[i + 2] - b[i + 2]));
    maximum = Math.max(maximum, delta);
    if (delta > tolerance) changed++;
  }
  return { changed, fraction: changed / (a.length / 4), maximum };
}

function referencePixels() {
  const rendered = viewer.renderBatches.objects;
  const original = sources();
  for (const object of rendered) viewer.content.remove(object);
  viewer.content.add(...original);
  try { return pixels(); }
  finally {
    for (const object of original) viewer.content.remove(object);
    viewer.content.add(...rendered);
  }
}

function pickSignatures(doc) {
  viewer.setSelectionMode('point', 'auto', false);
  const rect = viewer.renderer.domElement.getBoundingClientRect();
  return doc.parts.slice(0, 12).map(part => {
    const geometry = doc.geometries.get(part.geometryId).geometry;
    const center = geometry.boundingBox.getCenter(new T.Vector3()).add(new T.Vector3(0.13, 0.07, 0));
    const projected = center.applyMatrix4(new T.Matrix4().fromArray(part.matrix)).project(viewer.camera);
    const event = new MouseEvent('pointermove', { clientX: rect.left + (projected.x + 1) * rect.width / 2, clientY: rect.top + (1 - projected.y) * rect.height / 2 });
    const hit = viewer.pick(event);
    return hit && { partId: hit.partId, triangleIndex: hit.triangleIndex, localPoint: hit.localPoint };
  });
}

function samePicks(a, b) {
  return a.length === b.length && a.every((hit, i) => hit && b[i] && hit.partId === b[i].partId && hit.triangleIndex === b[i].triangleIndex && hit.localPoint.every((v, axis) => Math.abs(v - b[i].localPoint[axis]) < 1e-8));
}

async function screenshotPixels(blob) {
  const image = await createImageBitmap(blob);
  const canvas = document.createElement('canvas');
  canvas.width = image.width;
  canvas.height = image.height;
  const context = canvas.getContext('2d');
  context.drawImage(image, 0, 0);
  const data = context.getImageData(0, 0, canvas.width, canvas.height).data;
  image.close();
  // PNG rows face downward; WebGL rows face upward.
  const flipped = new Uint8Array(data.length);
  const stride = canvas.width * 4;
  for (let y = 0; y < canvas.height; y++) flipped.set(data.subarray(y * stride, (y + 1) * stride), (canvas.height - 1 - y) * stride);
  return flipped;
}

function plateFixture() {
  // A long diagonal plate carrying many small parts, like a populated strip.
  const turn = new T.Quaternion().setFromEuler(new T.Euler(0, 0, 0.6));
  const at = (x, y, z) => new T.Matrix4().compose(new T.Vector3(x, y, z).applyQuaternion(turn), turn, new T.Vector3(1, 1, 1));
  const material = color => new T.MeshStandardMaterial({ color, metalness: 0.4, roughness: 0.4 });
  const boxes = [], pins = [];
  for (let i = 0; i < 80; i++) {
    const x = -940 + i * 23.5, y = ((i % 5) - 2) * 20;
    boxes.push(at(x, y, 5));
    pins.push(at(x + 6, y + 10, 7));
  }
  return documentFor([
    { id: 'plate', geometry: new T.BoxGeometry(2000, 120, 4), materials: [material(0xd8c06a)], transforms: [at(0, 0, 0)] },
    { id: 'box', geometry: new T.BoxGeometry(8, 8, 6), materials: [material(0xeeeeee)], transforms: boxes },
    { id: 'pin', geometry: new T.CylinderGeometry(3, 3, 10, 24), materials: [material(0x888888)], transforms: pins },
  ]);
}

async function checkPartFitDepth() {
  const doc = plateFixture();
  viewer.setModel(doc);
  options({ hidden: new Set(), explode: 0, section: false, edges: false, grid: true, opacity: 1, navigationDetail: 'full', theme: 'dark' });
  for (const orthographic of [false, true]) {
    viewer.setProjection(orthographic);
    viewer.preset('iso');
    viewer.fit();
    const camera = viewer.camera;
    const pose = { position: camera.position.clone(), target: viewer.controls.target.clone(), frustum: orthographic ? [camera.left, camera.right, camera.top, camera.bottom, camera.zoom] : [] };
    const assembly = pixels();
    viewer.fit(['box-40']);
    // Return to the assembly framing, as a viewer does by zooming back out.
    // An orthographic view keeps the camera distance the part fit chose.
    const distance = orthographic ? viewer.camera.position.distanceTo(viewer.controls.target) : pose.position.distanceTo(pose.target);
    const direction = pose.position.clone().sub(pose.target).normalize();
    viewer.controls.target.copy(pose.target);
    viewer.camera.position.copy(pose.target).addScaledVector(direction, distance);
    if (orthographic) {
      [viewer.camera.left, viewer.camera.right, viewer.camera.top, viewer.camera.bottom, viewer.camera.zoom] = pose.frustum;
      viewer.camera.updateProjectionMatrix();
    }
    viewer.controls.update();
    const returned = difference(assembly, pixels());
    check(returned.fraction < 0.002, 'Fitting a part and returning to the assembly view renders the assembly unchanged', { orthographic, near: viewer.camera.near, far: viewer.camera.far, ...returned });
  }
  viewer.setProjection(false);
  return doc;
}

function partScreenBox(doc, id, margin) {
  const part = doc.parts.find(item => item.id === id);
  const box = doc.geometries.get(part.geometryId).geometry.boundingBox.clone().applyMatrix4(new T.Matrix4().fromArray(part.matrix));
  const gl = viewer.renderer.getContext(), screen = new T.Box2();
  for (const x of [box.min.x, box.max.x]) for (const y of [box.min.y, box.max.y]) for (const z of [box.min.z, box.max.z]) {
    const p = new T.Vector3(x, y, z).project(viewer.camera);
    screen.expandByPoint(new T.Vector2((p.x + 1) / 2 * gl.drawingBufferWidth, (p.y + 1) / 2 * gl.drawingBufferHeight));
  }
  return { center: box.getCenter(new T.Vector3()), screen: screen.expandByScalar(margin), width: gl.drawingBufferWidth };
}

function changedOutside(a, b, screen, width) {
  let outside = 0;
  for (let i = 0; i < a.length; i += 4) {
    const delta = Math.max(Math.abs(a[i] - b[i]), Math.abs(a[i + 1] - b[i + 1]), Math.abs(a[i + 2] - b[i + 2]));
    const pixel = i / 4, point = new T.Vector2(pixel % width, Math.floor(pixel / width));
    if (delta > 3 && !screen.containsPoint(point)) outside++;
  }
  return outside;
}

async function checkPartSelection(doc) {
  viewer.setProjection(false);
  viewer.preset('iso');
  viewer.fit();
  const id = 'box-40';
  const distance = viewer.camera.position.distanceTo(viewer.controls.target);
  const quaternion = viewer.camera.quaternion.clone();
  viewer.centerOnParts([id], false);
  const { center } = partScreenBox(doc, id, 0);
  const projected = center.clone().project(viewer.camera);
  check(viewer.controls.target.distanceTo(center) < 1e-6 && Math.abs(projected.x) < 1e-6 && Math.abs(projected.y) < 1e-6, 'Centering puts the part center at the view center', { projected: projected.toArray() });
  check(Math.abs(viewer.camera.position.distanceTo(viewer.controls.target) - distance) < 1e-6 && viewer.camera.quaternion.angleTo(quaternion) < 1e-9, 'Centering keeps the zoom distance and orientation');
  const marker = host.querySelector('.selection-marker');
  viewer.selectParts([id]);
  pixels();
  check(!marker.hidden, 'A part too small to see at assembly zoom is marked on screen');
  viewer.selectParts([]);
  pixels();
  check(marker.hidden, 'The marker disappears with the selection');
  viewer.zoom(40);
  for (const theme of ['dark', 'light']) {
    options({ theme });
    const plain = pixels();
    viewer.selectParts([id]);
    const selected = pixels();
    const { screen, width } = partScreenBox(doc, id, 3);
    const visible = difference(plain, selected, 12);
    check(visible.changed > 40, 'Selected part is visibly emphasized', { theme, ...visible });
    check(changedOutside(plain, selected, screen, width) === 0, 'Selection emphasis leaves every other part and the background untouched', { theme });
    viewer.selectParts([]);
    check(difference(plain, pixels()).changed === 0, 'Clearing the selection restores the original frame', { theme });
  }
  check(marker.hidden, 'Parts large enough to see need no marker');
  viewer.zoom(1 / 40);
  options({ theme: 'dark' });
  const before = viewer.controls.target.clone();
  viewer.centerOnParts(['box-0']);
  await raf();
  const moving = viewer.controls.target.clone();
  await new Promise(resolve => setTimeout(resolve, 400));
  await raf();
  const goal = partScreenBox(doc, 'box-0', 0).center;
  check(!moving.equals(goal) && viewer.controls.target.distanceTo(goal) < 1e-6 && Math.abs(viewer.camera.position.distanceTo(viewer.controls.target) - distance) < 1e-6, 'Centering glides to the part without changing zoom', { from: before.toArray(), to: goal.toArray() });
}

async function run() {
  const gl = viewer.renderer.getContext();
  const debug = gl.getExtension('WEBGL_debug_renderer_info');
  const info = { renderer: debug ? gl.getParameter(debug.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER), multiDraw: viewer.renderer.extensions.has('WEBGL_multi_draw') };
  check(gl.getContextAttributes().preserveDrawingBuffer === false, 'Drawing buffer preservation stays disabled');
  const doc = visualFixture();
  viewer.setModel(doc);
  await viewer.whenReady;
  options({ grid: false, navigationDetail: 'full' });
  viewer.setProjection(true);
  viewer.preset('top');
  viewer.fit();
  viewer.draw();
  const indices = new Map([...doc.geometries].map(([id, data]) => [id, { reference: data.geometry.index, values: Array.from(data.geometry.index.array) }]));
  const beforePicks = pickSignatures(doc);
  check(beforePicks.every(Boolean), 'Fixture sample rays hit source triangles', beforePicks.map(hit => hit?.triangleIndex));
  check(viewer.renderBatches.stats.regroupedSourceCount + viewer.renderBatches.stats.batchedSourceCount > 0, 'Render batching/regrouping path is exercised', viewer.renderBatches.stats);
  const merged = viewer.renderBatches.objects.filter(object => object.geometry?.hasAttribute('mergedPartId'));
  const mergedIds = merged.map(object => object.geometry.getAttribute('mergedPartId'));
  check(merged.length > 0 && merged.every(object => object.visible), 'Opaque unique-geometry chunks use the merged shader path', { chunks: merged.length });
  const parity = [];
  for (const state of [{ opacity: 1, section: false }, { opacity: 0.65, section: false }, { opacity: 1, section: true, sectionAxis: 'x', sectionPosition: 0.65 }]) {
    options(state);
    check(merged.every(object => object.visible === (state.opacity === 1)), 'Dynamic opacity selects opaque merged or sorted transparency fallback', { opacity: state.opacity });
    const delta = difference(pixels(), referencePixels());
    check(delta.fraction < 0.002, 'Merged material groups, colors, UV texture, normals, alpha and clipping match source rendering', { state, ...delta });
    parity.push(delta);
  }
  options({ opacity: 1, section: false });

  let rebuilds = 0;
  const rebuild = viewer.pickingIndex.setObjects.bind(viewer.pickingIndex);
  viewer.pickingIndex.setObjects = (...args) => { rebuilds++; return rebuild(...args); };
  const versions = sources().map(mesh => mesh.instanceMatrix.version);
  for (const state of [{}, {}, { theme: 'light' }, { theme: 'dark' }, { grid: true }, { grid: false }, { opacity: 0.65 }, { opacity: 1 }, { section: true }, { sectionPosition: 0.2 }, { sectionPosition: 0.8 }, { section: false }, { edges: true }, { edges: false }, { edges: true }]) options(state);
  check(rebuilds === 0, 'Display-only option changes never rebuild the picking index', { rebuilds });
  check(sources().every((mesh, i) => mesh.instanceMatrix.version === versions[i]), 'Display-only option changes never upload instance matrices', { versions });
  const edges = viewer.edgeObjects.map(edge => ({ edge, position: edge.geometry.getAttribute('position'), matrix: edge.geometry.getAttribute('instanceMatrix') }));
  const withEdges = pixels();
  options({ edges: false });
  check(difference(withEdges, pixels(), 12).changed > 20, 'Instanced edges produce visible rendered pixels');
  options({ edges: true, hidden: new Set([doc.parts[0].id]), explode: 0.25 });
  check(rebuilds === 1, 'Hide/explode rebuild the picking index once', { rebuilds });
  check(edges.every(({ edge, position, matrix }, i) => viewer.edgeObjects[i] === edge && edge.geometry.getAttribute('position') === position && edge.geometry.getAttribute('instanceMatrix') === matrix && matrix === edge.source.instanceMatrix), 'Edges retain borrowed matrices and cached positions across hide/explode');
  check(merged.every((object, i) => object.geometry.getAttribute('mergedPartId') === mergedIds[i] && mergedIds[i].version === 0), 'Hide/explode and display updates retain immutable merged vertex identifiers');
  const hiddenExplodedParity = difference(pixels(), referencePixels());
  check(hiddenExplodedParity.fraction < 0.002, 'Hidden and exploded meshes/edges match source rendering', hiddenExplodedParity);
  options({ hidden: new Set(), explode: 0, edges: false });
  check(samePicks(beforePicks, pickSignatures(doc)), 'Original triangle picks survive regrouping, visibility and explode');
  const screenshot = await screenshotPixels(await viewer.screenshot());
  check(difference(pixels(), screenshot, 3).fraction < 0.002, 'PNG export captures the full rendered frame without buffer preservation');
  for (const [id, data] of doc.geometries) check(data.geometry.index === indices.get(id).reference && indices.get(id).values.every((value, i) => data.geometry.index.array[i] === value), 'Source triangle indices remain unchanged', { id });

  const dense = new T.SphereGeometry(1, 64, 32);
  const lodDoc = documentFor([{ id: 'lod-spheres', geometry: dense, materials: [new T.MeshBasicMaterial({ color: 0x66ccaa })], transforms: Array.from({ length: 129 }, (_, i) => new T.Matrix4().makeTranslation((i % 13) * 2.4, Math.floor(i / 13) * 2.4, 0)) }]);
  viewer.setModel(lodDoc);
  options({ navigationDetail: 'auto', edges: false });
  viewer.setProjection(true);
  viewer.preset('top');
  viewer.fit();
  await viewer.whenReady;
  const rendered = [...viewer.renderBatches.renderedInstances.values()];
  // Small fixtures do not cross production's 5M triangle worker threshold.
  // Prepare the same worker result explicitly to exercise switching cheaply.
  viewer.navigationLods = await createNavigationLods(rendered);
  for (const object of rendered) viewer.fullGeometries.set(object, object.geometry);
  check(viewer.navigationLods.size > 0, 'Real worker produces a navigation LOD');
  check([...viewer.navigationLods.values()].every(lod => lod.geometry.getAttribute('position') === lod.source.geometry.getAttribute('position')), 'Navigation LOD borrows the original vertex buffer');
  const sourceIndex = dense.index;
  const sourceValues = Array.from(sourceIndex.array);
  viewer.navigationUntil = 0;
  const fullFrame = pixels();
  const fullTriangles = viewer.renderer.info.render.triangles;
  const fullPicks = pickSignatures(lodDoc);
  viewer.navigationUntil = performance.now() + 10_000;
  pixels();
  check(viewer.usingNavigationDetail, 'Navigation activates the prepared render-only LOD');
  check(viewer.renderer.info.render.triangles < fullTriangles, 'Navigation actually submits fewer triangles', { full: fullTriangles, navigation: viewer.renderer.info.render.triangles });
  check(samePicks(fullPicks, pickSignatures(lodDoc)), 'LOD rendering leaves original triangle picks unchanged');
  check(dense.index === sourceIndex && sourceValues.every((value, i) => dense.index.array[i] === value), 'LOD never mutates original geometry indices');
  const fullExport = await screenshotPixels(await viewer.screenshot());
  check(!viewer.usingNavigationDetail && difference(fullFrame, fullExport, 3).fraction < 0.002, 'Screenshot restores full-detail geometry during navigation');
  viewer.controls.dispatchEvent({ type: 'change' });
  pixels();
  check(viewer.usingNavigationDetail, 'Actual control changes activate navigation detail');
  await new Promise(resolve => setTimeout(resolve, 240));
  await raf();
  check(!viewer.usingNavigationDetail, 'Full-detail geometry restores automatically after navigation settles');
  viewer.navigationUntil = performance.now() + 10_000;
  options({ navigationDetail: 'full' });
  pixels();
  check(!viewer.usingNavigationDetail, 'Full-detail override disables navigation LOD');

  // Off-axis Euclidean distance must not substitute for camera-space depth.
  // Inject only the conservative bounds/error metadata, then exercise the real
  // Viewer decision without rendering an offscreen half-million-triangle model.
  const [original, lodRendered] = [...viewer.renderBatches.renderedInstances][0];
  const lod = viewer.navigationLods.get(lodRendered);
  const originalBounds = original.boundingSphere;
  const originalError = lod.error;
  const originalScale = original.userData.maxInstanceScale;
  original.userData.maxInstanceScale = 1;
  lod.error = 0.01;
  viewer.setProjection(false);
  viewer.camera.position.set(0, 0, 0);
  viewer.camera.up.set(0, 1, 0);
  viewer.camera.lookAt(0, 0, -1);
  options({ navigationDetail: 'auto' });
  viewer.navigationUntil = performance.now() + 10_000;
  original.boundingSphere = new T.Sphere(new T.Vector3(1000, 0, -0.2), 0.1);
  viewer.updateNavigationDetail();
  check(!viewer.usingNavigationDetail, 'Shallow-depth off-axis bounds conservatively reject navigation LOD');
  original.boundingSphere = new T.Sphere(new T.Vector3(0, 0, -1000), 0.1);
  viewer.updateNavigationDetail();
  check(viewer.usingNavigationDetail, 'Distant camera-space bounds permit the same navigation error');
  original.boundingSphere = originalBounds;
  original.userData.maxInstanceScale = originalScale;
  lod.error = originalError;

  const boundsGeometry = new T.BoxGeometry(2, 2, 2);
  const shear = new T.Matrix4().set(1, 3, 0, 1000, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1);
  const boundsDoc = documentFor([{ id: 'bounds-box', geometry: boundsGeometry, materials: [new T.MeshBasicMaterial()], transforms: [shear, new T.Matrix4().makeTranslation(-1000, 0, 0)] }]);
  viewer.setModel(boundsDoc);
  options({ hidden: new Set(['bounds-box-1']), navigationDetail: 'full', edges: false });
  const boundsSource = viewer.batches.get('bounds-box');
  const boundsPosition = boundsGeometry.getAttribute('position');
  const point = new T.Vector3();
  let encloses = true;
  for (let i = 0; i < boundsPosition.count; i++) {
    point.fromBufferAttribute(boundsPosition, i).applyMatrix4(shear);
    encloses &&= boundsSource.boundingSphere.distanceToPoint(point) <= 1e-8;
  }
  check(encloses, 'Conservative sheared occurrence bounds enclose every transformed corner');
  check(boundsSource.boundingSphere.center.x > 990 && boundsSource.boundingSphere.radius < 10, 'Hidden distant occurrences do not expand the visible navigation bounds', { center: boundsSource.boundingSphere.center.toArray(), radius: boundsSource.boundingSphere.radius });
  const directionalStretch = new T.Vector3(Math.SQRT1_2, Math.SQRT1_2, 0).applyMatrix3(new T.Matrix3().setFromMatrix4(shear)).length();
  check(boundsSource.userData.maxInstanceScale >= directionalStretch, 'Shear error scale bounds actual directional stretch', { bound: boundsSource.userData.maxInstanceScale, directionalStretch });

  await checkPartSelection(await checkPartFitDepth());

  // Compile the actual sample-model edge/clipping shader on this GPU too.
  viewer.setModel(createDemo());
  options({ hidden: new Set(), navigationDetail: 'full', edges: true, explode: 0.2, section: true, sectionPosition: 0.7 });
  pixels();
  check(viewer.renderer.info.render.lines > 0, 'Sample model renders edge primitives with clipping and explode', { lines: viewer.renderer.info.render.lines });
  await raf();
  await raf();
  check(gl.getError() === gl.NO_ERROR, 'Renderer leaves no WebGL error');
  return { ...info, checks, visualParity: parity, renderBatchStats: viewer.renderBatches.stats };
}

window.viewerCorrectness = { run, viewer };
