import * as T from "three";

const source =
  new URLSearchParams(location.search).get("source") === "baseline"
    ? "/artifacts/perf/baseline-src/src/core"
    : "/src/core";
const { Viewer } = await import(/* @vite-ignore */ `${source}/viewer.ts`);
const { importFiles } = await import(
  /* @vite-ignore */ `${source}/importers.ts`
);
const host = document.querySelector("#viewer");
const viewer = new Viewer(host);
const gl = viewer.renderer.getContext();
const debug = gl.getExtension("WEBGL_debug_renderer_info");
const timerExtension = gl.getExtension("EXT_disjoint_timer_query_webgl2");
const timer =
  new URLSearchParams(location.search).get("timer") === "0"
    ? null
    : timerExtension;
const raf = () => new Promise((resolve) => requestAnimationFrame(resolve));
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
function summary(values) {
  if (!values.length) return { count: 0, p50: null, p95: null, max: null };
  const ordered = values.slice().sort((a, b) => a - b);
  return {
    count: values.length,
    p50: ordered[Math.floor((ordered.length - 1) * 0.5)],
    p95: ordered[Math.floor((ordered.length - 1) * 0.95)],
    max: ordered.at(-1),
  };
}
const metric = () => ({
  cpu: [],
  drawCpu: [],
  pollCpu: [],
  gpu: [],
  renderTimes: [],
  calls: [],
  triangles: [],
  bufferWidths: [],
  bufferHeights: [],
});
let active;
let currentDoc;
const pending = [];
const originalRender = viewer.renderer.render.bind(viewer.renderer);
viewer.renderer.render = (...args) => {
  const target = active;
  let query;
  if (target && timer) {
    query = gl.createQuery();
    gl.beginQuery(timer.TIME_ELAPSED_EXT, query);
  }
  const start = performance.now();
  const result = originalRender(...args);
  const end = performance.now();
  if (query) {
    gl.endQuery(timer.TIME_ELAPSED_EXT);
    pending.push({ query, target });
  }
  if (target) {
    target.cpu.push(end - start);
    target.renderTimes.push(start);
    target.calls.push(viewer.renderer.info.render.calls);
    target.triangles.push(viewer.renderer.info.render.triangles);
    target.bufferWidths.push(viewer.renderer.domElement.width);
    target.bufferHeights.push(viewer.renderer.domElement.height);
  }
  return result;
};
const originalDraw = viewer.draw.bind(viewer);
viewer.draw = (...args) => {
  const target = active;
  const start = performance.now();
  const result = originalDraw(...args);
  if (target) target.drawCpu.push(performance.now() - start);
  return result;
};
function pollQueries() {
  const start = performance.now();
  for (let i = pending.length - 1; i >= 0; i--) {
    const { query, target } = pending[i];
    if (!gl.getQueryParameter(query, gl.QUERY_RESULT_AVAILABLE)) continue;
    if (!gl.getParameter(timer.GPU_DISJOINT_EXT))
      target.gpu.push(gl.getQueryParameter(query, gl.QUERY_RESULT) / 1e6);
    gl.deleteQuery(query);
    pending.splice(i, 1);
  }
  if (active) active.pollCpu.push(performance.now() - start);
}
function replicate(base, copies, unique = false) {
  const geometries = new Map(base.geometries),
    parts = [],
    roots = [];
  const bounds = new T.Box3();
  for (const p of base.parts) {
    const g = base.geometries.get(p.geometryId).geometry;
    g.computeBoundingBox();
    bounds.union(
      g.boundingBox.clone().applyMatrix4(new T.Matrix4().fromArray(p.matrix)),
    );
  }
  const size = bounds.getSize(new T.Vector3());
  const columns = Math.ceil(Math.sqrt(copies));
  for (let c = 0; c < copies; c++) {
    const translation = new T.Matrix4().makeTranslation(
      (c % columns) * Math.max(size.x * 1.15, 1),
      Math.floor(c / columns) * Math.max(size.y * 1.15, 1),
      0,
    );
    for (const p of base.parts) {
      let geometryId = p.geometryId;
      if (unique) {
        geometryId = `${p.geometryId}:copy${c}:part${p.id}`;
        const original = base.geometries.get(p.geometryId);
        geometries.set(geometryId, {
          ...original,
          id: geometryId,
          geometry: original.geometry.clone(),
        });
      }
      parts.push({
        ...p,
        id: `${p.id}:copy${c}`,
        geometryId,
        matrix: translation
          .clone()
          .multiply(new T.Matrix4().fromArray(p.matrix))
          .toArray(),
      });
    }
  }
  if (unique) for (const key of base.geometries.keys()) geometries.delete(key);
  roots.push({
    id: "replicated",
    name: `Sample ×${copies}`,
    partIds: parts.map((p) => p.id),
    children: [],
  });
  return {
    ...base,
    name: `Sample ×${copies}${unique ? " unique" : ""}`,
    geometries,
    parts,
    roots,
  };
}
function describe(doc) {
  return {
    parts: doc.parts.length,
    uniqueGeometries: doc.geometries.size,
    uniqueTriangles: [...doc.geometries.values()].reduce(
      (s, g) =>
        s +
        (g.geometry.index?.count ?? g.geometry.attributes.position.count) / 3,
      0,
    ),
    logicalTriangles: doc.parts.reduce((s, p) => {
      const g = doc.geometries.get(p.geometryId).geometry;
      return s + (g.index?.count ?? g.attributes.position.count) / 3;
    }, 0),
  };
}
async function orbit(ms, measure) {
  const samples = metric(),
    rafTimes = [],
    start = performance.now(),
    offset = viewer.camera.position.clone().sub(viewer.controls.target),
    axis = new T.Vector3(0, 0, 1);
  if (measure) active = samples;
  while (performance.now() - start < ms) {
    rafTimes.push(await raf());
    viewer.camera.position
      .copy(
        offset
          .clone()
          .applyAxisAngle(axis, (performance.now() - start) * 0.0002),
      )
      .add(viewer.controls.target);
    viewer.controls.update();
    viewer.invalidate();
    if (timer) pollQueries();
  }
  await raf();
  active = undefined;
  for (let i = 0; i < 5 && pending.length; i++) {
    await raf();
    pollQueries();
  }
  const intervals = samples.renderTimes
    .slice(1)
    .map((t, i) => t - samples.renderTimes[i]);
  const rafIntervals = rafTimes.slice(1).map((t, i) => t - rafTimes[i]);
  return {
    animationRafIntervalMs: summary(rafIntervals),
    observedAnimationRafFps: rafIntervals.length
      ? (1000 * rafIntervals.length) / (rafTimes.at(-1) - rafTimes[0])
      : null,
    renderIntervalMs: summary(intervals),
    renderBufferWidth: summary(samples.bufferWidths),
    renderBufferHeight: summary(samples.bufferHeights),
    cpuViewerDrawMs: summary(samples.drawCpu),
    cpuQueryPollMs: summary(samples.pollCpu),
    cpuRenderMs: summary(samples.cpu),
    gpuRenderMs: summary(samples.gpu),
    observedRenderFps: intervals.length
      ? (1000 * intervals.length) /
        (samples.renderTimes.at(-1) - samples.renderTimes[0])
      : null,
    drawCalls: summary(samples.calls),
    submittedTriangles: summary(samples.triangles),
    framesOver12_5ms: intervals.filter((t) => t > 12.5).length,
    framesOver25ms: intervals.filter((t) => t > 25).length,
  };
}
async function hover() {
  const cpu = [],
    dispatch = [],
    latency = [];
  let sent,
    hits = 0;
  const old = viewer.pick.bind(viewer);
  viewer.pick = (...args) => {
    const start = performance.now();
    const result = old(...args);
    const end = performance.now();
    if (result) hits++;
    cpu.push(end - start);
    if (sent !== undefined) {
      latency.push(end - sent);
      sent = undefined;
    }
    return result;
  };
  const rect = viewer.renderer.domElement.getBoundingClientRect();
  const modelPoints = currentDoc.parts
    .filter(
      (_, i) => i % Math.max(1, Math.floor(currentDoc.parts.length / 60)) === 0,
    )
    .slice(0, 60)
    .map((part) => {
      const geometry = currentDoc.geometries.get(part.geometryId).geometry;
      return geometry.boundingBox
        .getCenter(new T.Vector3())
        .applyMatrix4(new T.Matrix4().fromArray(part.matrix))
        .project(viewer.camera);
    });
  for (let i = 0; i < 120; i++) {
    const point = i < 60 ? modelPoints[i] : undefined;
    await raf();
    sent = performance.now();
    const start = sent;
    viewer.renderer.domElement.dispatchEvent(
      new PointerEvent("pointermove", {
        clientX:
          rect.left +
          rect.width *
            (point ? (point.x + 1) / 2 : 0.1 + (0.8 * (i % 12)) / 11),
        clientY:
          rect.top +
          rect.height *
            (point
              ? (-point.y + 1) / 2
              : 0.1 + (0.8 * Math.floor((i - 60) / 12)) / 4),
        pointerType: "mouse",
        buttons: 0,
        bubbles: true,
      }),
    );
    dispatch.push(performance.now() - start);
    await raf();
  }
  viewer.pick = old;
  return {
    hits,
    pickCpuMs: summary(cpu),
    pointerDispatchCpuMs: summary(dispatch),
    pointerToPickCompleteMs: summary(latency),
    method:
      "60 projected part bounding-box centers plus 60 viewport-grid pointermove events, one per two rAF callbacks; latency includes scheduled pick delay",
  };
}
window.bench = {
  async info() {
    const times = [];
    for (let i = 0; i < 121; i++) times.push(await raf());
    const intervals = times.slice(1).map((t, i) => t - times[i]);
    return {
      userAgent: navigator.userAgent,
      renderer: debug
        ? gl.getParameter(debug.UNMASKED_RENDERER_WEBGL)
        : gl.getParameter(gl.RENDERER),
      vendor: debug
        ? gl.getParameter(debug.UNMASKED_VENDOR_WEBGL)
        : gl.getParameter(gl.VENDOR),
      version: gl.getParameter(gl.VERSION),
      timerQuerySupported: !!timerExtension,
      timerQueryEnabled: !!timer,
      multiDrawSupported: !!gl.getExtension("WEBGL_multi_draw"),
      viewport: {
        width: host.clientWidth,
        height: host.clientHeight,
        dpr: devicePixelRatio,
        bufferWidth: viewer.renderer.domElement.width,
        bufferHeight: viewer.renderer.domElement.height,
      },
      idleRafIntervalMs: summary(intervals),
      idleRafFps: (1000 * intervals.length) / (times.at(-1) - times[0]),
      visibility: document.visibilityState,
    };
  },
  async load() {
    const blob = await (await fetch("/fixtures/sample-assembly.step")).blob();
    window.baseDoc = await importFiles(
      [new File([blob], "sample-assembly.step")],
      "balanced",
      () => {},
    );
    return { importMs: window.baseDoc.importMs, ...describe(window.baseDoc) };
  },
  async run({
    copies = 1,
    unique = false,
    warmupMs = 2000,
    durationMs = 8000,
    edges = false,
  } = {}) {
    const doc = replicate(window.baseDoc, copies, unique);
    const start = performance.now();
    viewer.setModel(doc);
    currentDoc = doc;
    viewer.applyOptions({ ...viewer.options, edges, grid: true });
    const setModelMs = performance.now() - start;
    const prepareStart = performance.now();
    await viewer.whenReady;
    const lodPreparationMs = performance.now() - prepareStart;
    const lods = [...(viewer.navigationLods?.values() || [])];
    const lodPreparation = {
      milliseconds: lodPreparationMs,
      geometries: lods.length,
      originalInstancedTriangles: lods.reduce(
        (sum, lod) => sum + lod.originalTriangleCount * lod.source.count,
        0,
      ),
      lodInstancedTriangles: lods.reduce(
        (sum, lod) => sum + lod.triangleCount * lod.source.count,
        0,
      ),
      maxRelativeError: Math.max(0, ...lods.map((lod) => lod.relativeError)),
    };
    await orbit(warmupMs, false);
    const result = await orbit(durationMs, true);
    const picks = await hover();
    return {
      copies,
      unique,
      edges,
      ...describe(doc),
      setModelMs,
      lodPreparation,
      renderBatches: viewer.renderBatches?.stats,
      warmupMs,
      durationMs,
      ...result,
      hover: picks,
    };
  },
};
