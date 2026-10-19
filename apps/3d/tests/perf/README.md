# Apple GPU renderer benchmark

Run from the repository root with the Vite development server running (`npm run dev`):

```sh
node scripts/perf/browser-benchmark.mjs --baseline
node scripts/perf/browser-benchmark.mjs
```

The recorded baseline comes from git revision `7937fa8` of `casimir-engineering/shenzhen-3D`. The Shenzhen repository starts from one commit and does not have that revision: check it out from `shenzhen-3D` and pass the checkout with `--baseline-src=<dir>`. `--baseline-ref=<revision>` takes a revision of the repository the benchmark runs in instead. The runner creates an ignored source snapshot at `artifacts/perf/baseline-src` and verifies the viewer source hash against the baseline. Remove an existing snapshot before choosing another baseline. The baseline imports its own original renderer and CAD importer; current imports `src/core`.

The runner opens **headed Chromium** using ANGLE Metal and rejects software rendering. It does not read the Playwright E2E configuration, which deliberately uses SwiftShader for functional tests. Bring the browser to the foreground and leave it there throughout a run. A visible browser and high-refresh-rate display are required to measure a 120 Hz schedule. Browser version, GPU renderer, display cadence, CSS size, drawing-buffer size, DPR, source hash, OS and RAM are recorded in each JSON result.

Default scenarios import `fixtures/sample-assembly.step` at balanced quality, then render 1×, 10×, 50× and 100× assemblies and a 10× assembly with every part given its own geometry identity. Replicas are translated into a grid; triangles are neither simplified nor removed. The last scenario tests many independently imported meshes and CAD face material groups. It intentionally defeats instancing by geometry ID, but retains identical mesh content, so it is not evidence about geometrically distinct models.

Each scenario awaits optional worker LOD preparation, then has a two-second orbit warm-up followed by eight seconds of sustained orbit. The harness drives the public camera/controls and normal invalidation scheduler. It measures:

- **Animation rAF intervals** and **render invocation intervals** separately. FPS is computed from elapsed callback time and number of intervals, never from inverse CPU render time. These measure browser scheduling/submission cadence; they do not prove physical display presentation of every submitted frame.
- **CPU renderer duration**, wrapping only `WebGLRenderer.render`. It excludes CAD import, React, and other application work. Whole `Viewer.draw` CPU duration and GPU-query polling CPU duration are also recorded separately.
- **GPU elapsed time** through `EXT_disjoint_timer_query_webgl2`, when supported. Query results are polled asynchronously; disjoint samples are discarded. CPU and GPU time overlap and must not be summed.
- **Hover pick CPU time**, synchronous pointer-event dispatch time, and dispatch-to-pick completion latency. Sixty projected part centers plus sixty viewport-grid positions exercise hits and misses. Events occur once per two rAF callbacks; deferred picking is included in completion latency. This is programmatic event delivery, rather than an operating-system input-latency test.
- Model setup and LOD preparation time, logical parts/triangles, unique geometry/triangle counts, actual renderer draw calls, drawing-buffer dimensions and submitted triangle counts. Current navigation LOD can reduce submitted triangles while orbiting; its reported relative error metric and preparation reduction are recorded. This metric is not a formal Hausdorff distance guarantee.

The timer wrapper adds some overhead. All summary percentiles use the observed sample at sorted index `floor((n-1)*p)`; raw JSON includes sample counts and maxima. The benchmark isolates the viewer and is not a production end-to-end application benchmark. Import timing includes worker and WASM startup.

Override scenarios, sample duration, edges and output path with:

```sh
PERF_CASES=1,10,100 PERF_DURATION_MS=15000 node scripts/perf/browser-benchmark.mjs --output=artifacts/perf/long-current.json
PERF_GPU_TIMER=0 PERF_CASES=unique10 node scripts/perf/browser-benchmark.mjs --output=artifacts/perf/no-timer-current.json
PERF_DPR=1 PERF_CASES=100 node scripts/perf/browser-benchmark.mjs --output=artifacts/perf/dpr1-current.json
PERF_CASES=1,10 PERF_EDGES=1 node scripts/perf/browser-benchmark.mjs --output=artifacts/perf/edges-current.json
```

`PERF_BASE_URL` overrides the local server URL. The default viewport is 1440×900 CSS pixels at DPR 2; `PERF_DPR` changes device scale for a resolution sensitivity check. The screenshot next to each JSON shows the final scenario. Durable measured results are stored in `tests/perf/results/`; ignored snapshots and transient captures remain in `artifacts/perf/`.

## Desktop engine probes

With Electron installed, the same viewer workload can run through the actual desktop shell's development-only loopback URL:

```sh
node scripts/perf/electron-benchmark.mjs
```

This launches `electron/main.cjs` with the normal backend, verifies the Apple hardware renderer, and uses a 1440×900 content area at the display's real DPR. The default cases are 1×, 100× and separate-geometry 10×. It records Electron/Chromium versions and the shell source hash. `PERF_READY_ONLY=1` checks initialization and CAD import without measuring cases. The benchmark URL is ignored by packaged releases.

The standalone system-WebKit Swift probe is separate from the Tauri app and from Playwright WebKit:

```sh
swiftc scripts/perf/native-webkit-benchmark.swift -o artifacts/perf/native-webkit-benchmark
PERF_CASES=1 artifacts/perf/native-webkit-benchmark
```

Without `PERF_CASES`, it records capabilities and idle rAF cadence only. GPU timer queries may be unavailable on WebKit.
