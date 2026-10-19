# Renderer performance on Apple M5 Max

The optimized renderer sustained approximately **120 render submissions and animation callbacks per second** in all five measured Chromium workloads, including 376,000 logical parts / 98.30 million logical triangles and 37,600 independently identified mesh geometries / 9.83 million triangles. These are observed browser scheduling/render-invocation rates, not direct measurements of physical display presentation.

Measurements were collected consecutively on this Mac: Apple M5 Max, 40 GPU cores, 64 GiB memory, macOS 26.5.1, Chromium 156.0.8078.4, ANGLE Metal (`Apple M5 Max`). Every case used a 1440×900 CSS viewport, DPR 2 and a **2880×1800 drawing buffer**. The idle browser schedule was approximately 120 Hz. Software rendering was rejected by the runner.

The comparison uses baseline application source `7937fa8` and optimized renderer source `515e088`. The JSON records the viewer SHA-256 as well as the Git revision; no application source changed during the measured orbit windows. Baseline and current source used the same installed Three.js and the same browser.

| Workload                                     | Logical parts | Logical triangles | Baseline render fps | Optimized render fps | Draw calls, before → after |
| -------------------------------------------- | ------------: | ----------------: | ------------------: | -------------------: | -------------------------: |
| Earlier sample assembly                         |             — |                 — |              120.00 |               120.01 |                 1,600 → 43 |
| Sample ×10                                      |        37,600 |         9,829,620 |              120.00 |               120.02 |                 1,600 → 42 |
| Sample ×50                                      |       188,000 |        49,148,100 |              120.01 |               120.01 |                 1,600 → 47 |
| Sample ×100                                     |       376,000 |        98,296,200 |              101.03 |               120.02 |                 1,600 → 51 |
| Sample ×10, separate geometry identity per part |        37,600 |         9,829,620 |                1.85 |               120.00 |               931,891 → 37 |

The last workload improved approximately 64.7×. Initial multi-draw batching reached about 77 fps there; merging eligible single-occurrence geometries into actual shared GPU draws removed the remaining draw-command overhead. Repeated geometry stays on hardware instancing.

| Workload                              | CPU render p95, before → after (ms) | GPU timer p95, before → after (ms) | Hover pick CPU p95, before → after (ms) |
| ------------------------------------- | ----------------------------------: | ---------------------------------: | --------------------------------------: |
| Earlier sample assembly                  |                         1.00 → 0.30 |                        1.40 → 1.22 |                             1.30 → 0.40 |
| Sample ×10                               |                         0.90 → 0.30 |                        4.70 → 4.02 |                             8.70 → 0.30 |
| Sample ×50                               |                         1.00 → 0.30 |                        5.38 → 5.18 |                            44.40 → 0.30 |
| Sample ×100                              |                         1.00 → 0.30 |                       10.46 → 6.92 |                            92.40 → 0.30 |
| Sample ×10, separate geometry identities |                       559.10 → 0.30 |                       47.99 → 4.15 |                             5.50 → 0.40 |

Optimized Chromium render intervals had p50 8.30 ms and p95 9.20 ms in every case. No optimized measured interval exceeded 12.5 ms. Each orbit ran for eight seconds after a two-second warm-up; sample counts and maxima are retained in the JSON. This establishes the measured target for these scenes and this machine, rather than an unlimited model-size guarantee.

## Detail, picking and workload scope

Navigation LOD is index-only and runs in a worker. Original coordinates, topology, source triangle indices and measurement geometry remain intact. Material boundaries are locked during simplification; normals, UVs and vertex colors participate in the simplifier's error metric. Its relative error limit is 0.002. At draw time, the estimated error must project to at most 0.75 physical pixel using conservative nearest-batch depth and transform-scale bounds. This is meshoptimizer's reported metric, not a formal Hausdorff-distance guarantee. Full detail returns after navigation stops, and the user can select full detail throughout.

The ×10, ×50 and ×100 navigation runs actually submitted **8,673,700**, **43,209,300** and **86,368,600** triangles per frame, respectively. The 98.30 million figure describes the complete logical model; it is not a claim that all original triangles were submitted during the 120 fps orbit. The single sample-assembly and separate-geometry workload submitted all of their triangles. Drawing-buffer resolution remained constant throughout.

These measurements used an earlier, larger sample assembly that is no longer in the repository. The benchmark now imports the generated `fixtures/sample-assembly.step` (3,154 parts, 153,720 triangles) at balanced quality; run `npm run benchmark:gpu` to measure it on your machine. Replicated assemblies are translated into a grid. The separate-geometry case assigns each part its own geometry identity while cloning the same source mesh content; it stresses many mesh objects and material groups but is not a genuinely heterogeneous assembly with 37,600 different shapes.

Picking uses original geometry. Hover requests are coalesced to an animation callback: CPU pick work is much smaller, while pointer-dispatch-to-pick completion p95 is approximately 9.2–9.4 ms, including that scheduled delay. The test sends sixty projected part centers and sixty viewport-grid positions, so it includes hits and misses. It measures programmatic event delivery rather than operating-system input latency.

CPU renderer time wraps `WebGLRenderer.render`; whole `Viewer.draw` and GPU-query-poll CPU times are recorded separately. GPU time uses asynchronous `EXT_disjoint_timer_query_webgl2` queries, with disjoint samples discarded. CPU and GPU work overlap and must not be summed. The renderer harness excludes React and other application UI work; import and model setup are reported separately.

## Browser, native WebKit and Electron

A standalone probe using **the installed macOS system WKWebView** reported Apple GPU / WebGL 2 and approximately **60.30 Hz idle rAF** at the same viewport and DPR. It supported multi-draw but did not expose GPU timer queries. This is the operating-system WebKit engine, not Playwright's patched WebKit, and the probe is not the Tauri release app. An eight-second **active sample-assembly orbit** also stayed near 60 Hz: 59.74 render invocations/s, p95 interval 17 ms, maximum 33 ms, full triangle count. CPU renderer p95 was 1 ms; GPU elapsed time was unavailable. Its active and idle schedules are separate evidence from Chromium's 120 Hz results.

The **actual Electron desktop shell** was also measured through `electron/main.cjs` and its development-only benchmark URL, using Electron 44.7.2 / Chromium 152.0.7977.149 with its normal default Metal backend. The real content area was 1440×900 at the display's DPR 2. Renderer and shell source hashes and Git revision `45d1343` are recorded. This measures the actual desktop runtime with the isolated viewer harness; it does not include the production React UI or constitute a packaged-release presentation test.

| Actual Electron workload              | Observed render fps | Render interval p95 (ms) | CPU render p95 (ms) | GPU timer p95 (ms) |
| ------------------------------------- | ------------------: | -----------------------: | ------------------: | -----------------: |
| Earlier sample assembly                  |              120.01 |                     8.90 |                0.30 |               1.11 |
| Sample ×100                              |              120.00 |                     8.80 |                0.30 |               8.32 |
| Sample ×10, separate geometry identities |              120.00 |                     9.30 |                0.30 |               4.03 |

The separate-geometry Electron run had one 24.3 ms render-invocation interval outlier; its average remained 120 fps and p95 was 9.3 ms. These results establish the measured 120 fps target, rather than a zero-jitter guarantee. Actual navigation triangle totals match the Chromium runs above.

## Rendering-feature regression (0.1.2)

After adding the optional ray tracer and an alpha-enabled raster overlay canvas, a separate hardware regression at source `44761a8` repeated the two largest workloads. Ray tracing was disabled; its worker and GPU context were not created. Viewport, DPR, drawing-buffer size, orbit duration and Metal timer-query method matched the earlier browser runs.

| Workload | Observed render fps | Observed rAF fps | Interval p95 (ms) | CPU render p95 (ms) | GPU timer p95 (ms) |
| --- | ---: | ---: | ---: | ---: | ---: |
| Sample ×100 / 98.30M logical triangles | 120.00 | 120.00 | 8.80 | 0.30 | 6.69 |
| Sample ×10 / 37,600 separate geometries | 120.00 | 119.99 | 9.10 | 0.70 | 4.31 |

The ×100 case still submitted 86,368,600 navigation triangles in 51 draws; the separate-geometry case submitted all 9,829,620 triangles in 37 draws. Every recorded drawing buffer remained 2880×1800. One ×100 interval reached 16.1 ms; no interval exceeded 25 ms. The raw record is [0.1.2 rendering regression](../tests/perf/results/apple-m5-max-rendering-0.1.2.json). These are raster navigation timings; progressive ray-tracing preparation, convergence and display/export pixel parity are documented separately in [RENDERING.md](RENDERING.md).

## Reproduction and evidence

Start `npm run dev`, then run:

```sh
node scripts/perf/browser-benchmark.mjs --baseline --output=artifacts/perf/baseline-paired.json
node scripts/perf/browser-benchmark.mjs --output=artifacts/perf/current-paired.json
```

For the actual desktop shell, run `node scripts/perf/electron-benchmark.mjs` after installing dependencies. Leave the measured window visible and avoid other GPU or heavy CPU work. See [the benchmark protocol](../tests/perf/README.md) for scene construction, instrumentation, adjustable durations, resolution checks and timer-free diagnostics. Functional GPU checks additionally compare original and optimized render pixels and verify picking, clipping, hiding, explode, textures, normals, edges and idle detail restoration; those checks do not substitute for hardware timing.

Durable raw measurements:

- [Original renderer](../tests/perf/results/apple-m5-max-baseline.json)
- [Optimized Chromium renderer](../tests/perf/results/apple-m5-max-chromium.json)
- [Actual Electron desktop runtime](../tests/perf/results/apple-m5-max-electron.json)
- [Standalone system WKWebView capabilities and idle cadence](../tests/perf/results/apple-m5-max-system-webkit-info.json)
- [Standalone system WKWebView active sample-assembly orbit](../tests/perf/results/apple-m5-max-system-webkit-active.json)

The WKWebView probe is reproducible without changing production code:

```sh
mkdir -p artifacts/perf
swiftc scripts/perf/native-webkit-benchmark.swift -o artifacts/perf/native-webkit-benchmark
artifacts/perf/native-webkit-benchmark
```

Set `PERF_CASES=1,100` to measure model scenarios in the standalone WebKit probe; the default captures capabilities and idle callback cadence only.

## Large STEP assemblies

STEP files of 16 MB or more are read product by product. The reference case is a large KiCad assembly (about 100 MB). Measurements below are on the same Apple M5 Max, Chromium 156 (Playwright, Metal) and Electron 44.7.2, 1440×1000 at DPR 2. Memory is the macOS physical footprint per process (`proc_pid_rusage`), which is what Activity Monitor reports; workers run inside the renderer process.

### Why the file could not open

The vendored kernel is a 32-bit WebAssembly build whose memory cannot grow past **2 GB** (`getHeapMax` = 2,147,483,648; a 4 GB build would need a rebuild of OpenCascade). Reading the whole file at once exhausts it while the STEP records are transferred into shapes, before any meshing: the kernel stops with "memory access out of bounds" after 14.4 s in Node, 20.5 s in Chromium and 28.6 s in Electron. The page's JavaScript heap stays at 6 MB, and the renderer peaks at 2,317 MB (Chromium) and 2,260 MB (Electron). Mesh precision does not matter: a 1 mm deflection fails the same way. Reading the 100 MB into JavaScript and handing it to the worker costs one 100 MB buffer and is not the problem.

One product alone, a module's silkscreen written as tens of thousands of curve sets (about half of the file), needs 987 MB of kernel memory and produces no displayable geometry. With it removed, a whole-file read just fits in 2,048 MB of kernel memory and takes 31–43 s, with a 2,477 MB renderer.

### What happens now

1. A planning worker indexes the file as bytes (0.5–1.0 s; no string copy), reads the product/occurrence structure, and cuts each distinct product into a small standalone STEP file with its colours, sub-shape names and properties. Each piece becomes a Blob, the worker closes and the 100 MB source is freed. Curve-only products are not read; they appear as empty tree entries, exactly as before.
2. Up to four short-lived kernel workers (two on phones and tablets, or with 4 GB of device memory or less) read the pieces in parallel. The largest pieces start first, one worker takes the smallest first so the board appears early, and a piece only starts while the workers' combined kernel memory stays within 640 MB. A worker that grew past 160 MB is replaced, and all of them close when loading ends.
3. Results move to the page without copying and are joined into the same tree, node ids, names, single-precision placements, geometry order and colours that a whole-file read produces. Each distinct product is one geometry; its repeats are GPU instances.
4. A first view appears about one second after reading starts and is refreshed every three seconds without moving the camera.
5. Exact feature queries read a product's exact geometry the first time one of its faces, edges or vertices is queried, and keep it until the model closes. Measurements across two products use the kernel's cross-model queries. Almost every product reads in under 1 s; the slowest, a connector modelled as one large solid, takes about 9 s on first use.

| Large KiCad assembly (about 100 MB) | Before | After |
| --- | ---: | ---: |
| Result | fails after 20.5 s | opens |
| First view (Chromium) | — | 1.7 s (2.5 s median under load) |
| Fully loaded (Chromium) | — | 9.3 s (15.3 s median under load) |
| Renderer peak, Chromium | 2,317 MB | 945–1,008 MB |
| Renderer after loading, Chromium | — | 486–495 MB |
| Renderer peak / after loading, Electron | 2,260 MB / — | 916 MB / 341 MB |
| Largest single kernel worker | 2,048 MB (limit) | 311 MB |
| Zoom render rate, p95 interval | — | 120 fps, 9.1 ms |

"Under load" is three consecutive runs while other work shared the machine; the quiet run is listed first. The model holds about 16 MB of mesh data; most of the renderer memory after loading is the viewer's picking, batching and edge structures. Electron timings include Playwright handing 100 MB to the page and are not comparable with Chromium's.

| Other files | Before | After |
| --- | --- | --- |
| Generated 42.5 MB assembly (80 products, 646 parts) | fails after 19.5 s, 2,237 MB | 8.5 s, 719 MB peak, 365 MB after |
| Large KiCad assembly without the curve-only product | 31.5 s, 2,477 MB peak, 2,355 MB after | 14.3 s under load, 1,021 MB peak, 496 MB after |
| Earlier sample assembly (read whole, unchanged path) | 433 MB peak, 120 fps | 433 MB peak, 120 fps |

Startup is unchanged: browser cold first contentful paint 128 → 112 ms and critical JavaScript 92,987 → 93,670 gzip bytes (median of three); Electron Open-ready 327 → 322 ms (median of five). The large-file code loads only when such a file is opened.

`tests/step-split.test.ts` generates an assembly and requires that the part-by-part read stays within 64 MB of kernel memory while a whole read of the same file uses more than three times as much, that every repeat shares its product's geometry, and that the tree, placements, colours and exact face and cross-product measurements match a whole-file read. `npm run test:cad` checks the same equivalence on the sample fixture, and `tests/e2e-large-step.spec.ts` opens a generated 18 MB assembly in the app and runs exact face and distance queries.
