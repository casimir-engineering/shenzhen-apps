# Startup measurements

The lazy-loading candidate reduces the initial JavaScript entry from **1,099,391 to 297,107 bytes** (73.0%). With the benchmark server's gzip level 9, critical JavaScript falls from **301,622 to 91,009 bytes** (69.8%). The welcome page does not construct the renderer until the user opens a file or chooses the sample. Format importers, CAD/drawing workers, project ZIP operations and GPU ray tracing load when needed.

This comparison uses the frozen 0.1.2 frontend at source `44761a8` (`index-dpyKHpus.js`) and candidate `index-BnASxyly.js`. Their exact built entry hashes and raw observations are retained in [baseline-0.1.2.json](../tests/startup-results/baseline-0.1.2.json) and [lazy-candidate.json](../tests/startup-results/lazy-candidate.json). The optimized record identifies its exact built asset hash; that build was measured before its source commit.

## Measured behavior

Three consecutive repetitions per build ran on the same Apple M5 Max Mac with headed Chromium 156 and ANGLE Metal, at 1440 × 1000 CSS pixels / DPR 2. Values below are medians. Every repetition started a fresh browser process and empty browser context. OS filesystem caches were not flushed. A local HTTP server served precompressed gzip responses; these are localhost startup timings, not measurements over a slow network.

| Metric | Frozen 0.1.2 | Lazy candidate |
| --- | ---: | ---: |
| Cold first contentful paint | 120 ms | 96 ms |
| Cold welcome DOM ready | 66.4 ms | 60.6 ms |
| Cold welcome DOM + two animation callbacks | 115.5 ms | 67.1 ms |
| Critical page JavaScript, gzip response bodies | 301,622 B | 91,009 B |
| All JavaScript requested before first intent, including SW prefetch | 1,462,612 B | 91,009 B |
| Cold sample click → model DOM + two animation callbacks | 28.3 ms | 42.0 ms |
| Cold first pointer intent → same model marker | 28.9 ms | 42.5 ms |
| Warm online first contentful paint | 64 ms | 48 ms |
| Previously used, offline first contentful paint | 56 ms | 32 ms |
| Warm sample click → model marker | 15.9 ms | 32.4 ms |
| Previously used, offline sample click → model marker | 17.3 ms | 25.1 ms |

The first-use sample cost increases by approximately 14 ms locally because its renderer and model runtime now load on intent. On a slower connection, this deferred download can make the first model take longer even though the welcome page appears sooner. Warm interaction still pays the asynchronous runtime setup. These timings do not measure physical display presentation: the model marker requires the four-part badge and canvas, then waits two animation callbacks. First contentful paint is the browser's recorded paint timing. The runner waits for that timing entry before taking its startup snapshot.

## Offline installation and background requests

The baseline service worker immediately prefetched the complete offline asset set. By the first input in this probe it had already requested approximately **11.22 MB** of gzip HTTP response bodies, including CAD/DWG WASM and the ray tracer. The candidate requested approximately **98.8 KB** before first input. Critical-page Resource Timing and server-wide requests are recorded separately because page Resource Timing omits service-worker background fetches.

The complete offline warmup remains approximately **11.2 MB**; it moves out of the startup path rather than disappearing. In the first recorded repetition, the baseline cache was ready at approximately 0.50 seconds with 78 files, and the candidate at approximately 4.50 seconds with 82 files after the sample was used. Online warm reload and offline reload/sample checks both passed. The offline scenario follows a successful sample load and completed installation; it does not claim offline operation before the first install finishes.

## Actual Electron desktop shell

A separate five-pair run launched the same Electron 44.7.2 shell with the frozen and optimized assets through its production `app://local/` protocol. Launch order alternated, and each launch used a fresh profile. Median launch-to-enabled-Open improved from **321.2 to 264.1 ms** (17.8%). The subsequent two-animation-callback welcome marker improved from **347.4 to 282.7 ms**. The initial canvas count changed from one to zero. The sampled JavaScript heap was approximately 7.89 MB versus 4.96 MB; this excludes native/GPU memory and is not a peak-memory measurement.

These launches used the development Electron executable with the production protocol and assets, rather than a newly packaged installer or first Gatekeeper launch. OS/asset caches were warm across repetitions. Electron's two-callback marker is not first contentful paint or a physical-presentation measurement. Raw records are [electron-startup.json](../tests/startup-results/electron-startup.json) and [electron-smoke.json](../tests/startup-results/electron-smoke.json). The accompanying 20-check actual-shell smoke passed native STEP import, project ZIP roundtrip, measurements/notes, delayed PNG export, WebGPU convergence, style teardown and lazy startup. This is separate from browser startup timing.

Reproduce it with `node electron/startup.mjs --baseline=artifacts/releases-0.1.2/frontend-dist --candidate=dist --runs=5 --report=artifacts/startup/electron.json`.

## Reproduce and guard the change

```sh
node tests/startup-browser.mjs --dist=artifacts/releases-0.1.2/frontend-dist --label=baseline --port=1436 --source=44761a8
node tests/startup-browser.mjs --dist=dist --label=current --port=1437 --expect-lazy
```

The script owns and closes its static server and browsers. `--runs=3` is the default; `--output=...` selects a record path, and `--screenshot=artifacts/startup/welcome.png` captures the welcome page after all timing checkpoints. Use a quiet CPU/GPU window with visible browser windows. Responses use gzip level 9 and an empty browser HTTP/SW cache for each cold repetition. Warm and offline cases retain the previous installation. Browser paint, ready markers, resource sizes, all HTTP requests and cache contents remain separate in the JSON.

`--expect-lazy` rejects an initial page graph above 350,000 decoded JavaScript bytes or 120,000 gzip JavaScript bytes, any preinteraction WASM request, or an eagerly created canvas. Both builds must successfully load the real four-part sample using the hardware renderer and complete warm/offline sample checks. The script checks functionality and budgets without imposing brittle millisecond pass/fail thresholds. This work changes startup loading; it does not repeat or redefine the navigation frame-rate results in [PERFORMANCE.md](PERFORMANCE.md).

## Shenzhen Friends

Friends adds nothing to the launch path: the main process and the renderer load it a second after the first paint.
The interleaved comparison with 0.1.9, with Friends on and off, is in [Shenzhen Friends § Startup](FRIENDS.md#startup)
and [friends-startup.json](../tests/startup-results/friends-startup.json). `electron/startup.mjs` takes
`--baseline-electron` and `--candidate-electron` to compare each variant's own main-process code.

