# Performance baselines (Phase 4.1)

Baseline measurements for the Nautilus macOS port, recorded **2026-07-09**
with the harness in `bench/`. No optimizations have been applied yet; these
are the "before" numbers for Phase 4 tasks 4.2–4.4.

## Machine

| | |
|---|---|
| Chip | Apple M5 Max (18 cores) |
| RAM | 64 GB |
| macOS | 26.5.1 (build 25F80) |
| Build | `debugoptimized` (no LTO), Homebrew GTK 4.22.4 / GLib 2.88.2 |

## What was measured (binary provenance)

Because another agent may rebuild `build/` concurrently, the harness
measures a **frozen snapshot**: `bench/snapshot-install/` is a copy of
`install/` taken at benchmark time, launched via `bench/run-snapshot.sh`
(adapted from `run-nautilus.sh`; uses `DYLD_LIBRARY_PATH` to redirect the
absolute `libnautilus-extension` install name to the snapshot copy, and
bench-local `XDG_{CACHE,CONFIG,DATA}_HOME` under `bench/xdg/`).

* Benchmarked binary: `bench/snapshot-install/bin/nautilus`
  sha256 `0813cd0038691aa970a1ce03e62823288aa615d99b43c308f60edcf2fe111eb7`
* This is the `meson install`-ed copy of `build/src/nautilus`
  (sha256 `58f9d908…` — bytes differ only because install rewrites the
  dylib install name; a copy is kept at
  `bench/snapshot-install/bin/nautilus-build-copy`).
* Every result row in `bench/results/*.jsonl` embeds `binary_sha256`,
  `host`, and a UTC `timestamp`, so later runs are directly comparable.

## Harness

All scripts are re-runnable, `set -euo pipefail`, and write one JSON object
per trial to `bench/results/<bench>-<stamp>.jsonl`.

| File | Purpose |
|---|---|
| `bench/run-snapshot.sh` | Launch wrapper for the frozen snapshot (no-bus mode, isolated XDG dirs) |
| `bench/tools/benchtool.swift` | Swift measurement tool (compile: `swiftc -O -o bench/tools/benchtool bench/tools/benchtool.swift`) |
| `bench/gen-data.sh` | Generates `bench/data/files-{1k,10k,50k}` and `bench/data/images-500` (idempotent) |
| `bench/bench-startup.sh` | Cold-ish/warm start → first window (n=5 each) |
| `bench/bench-listing.sh` | Directory listing, Nautilus vs Finder, 1k/10k/50k (n=3 each) |
| `bench/bench-thumbnails.sh` | Thumbnail throughput on 500 images (backend currently stubbed) |

Full re-run (≈2 min of measuring):

```bash
bench/gen-data.sh
bench/bench-startup.sh
bench/bench-listing.sh
bench/bench-thumbnails.sh
```

### Window detection (technique (a) from the task list)

`benchtool time` records t0 (monotonic, `DispatchTime`) immediately before
`posix_spawn` of the launch command, then polls
`CGWindowListCopyWindowInfo(.optionOnScreenOnly)` every **10 ms** until the
target pid owns more layer-0 windows of ≥50×50 pt than it did at t0.
`t_window_ms` therefore means "compositor shows an app window", within
+10 ms polling error. GTK frame-clock instrumentation (technique (b)) was
not needed. For Nautilus the target is the spawned process itself; for
Finder the tool watches the pre-existing Finder pid (`--watch-pid`) against
a pre-spawn window-count baseline while spawning `/usr/bin/open <dir>`.

### Quiesce detection ("fully populated" proxy)

Neither app exposes an external "listing complete" signal, so both get the
same proxy: cumulative CPU time of the target process
(`proc_pid_rusage`, `RUSAGE_INFO_V2`, user+system) sampled every **50 ms**;
`t_quiesce_ms` is the start of the first streak with **<5% CPU sustained
for ≥1 s**. This upper-bounds time-to-populated: the app has stopped
enumerating, sorting, and rendering by then. Resolution is one 50 ms
sample; the 1 s confirmation window is *not* included in the reported time.

### Datasets

* `files-{1k,10k,50k}`: N top-level plain files with a mix of 10 extensions
  plus extensionless, plus 10 subdirs of 10 files each. On APFS, freshly
  generated.
* `images-500`: 500 synthetic images (PNG/JPEG alternating, 256–1024 px,
  gradients + shapes) drawn by `benchtool genimages`.

## Baseline table

### Startup (start → first window, n=5)

| Variant | min | median |
|---|---:|---:|
| Cold-ish | 475 ms | **481 ms** |
| Warm | 262 ms | **275 ms** |

“Cold-ish” caveat: `purge` needs sudo and was not used. Each cold trial
executes a **fresh copy** of the binary (new inode → cold page cache for the
main executable), but the ~100 GTK/GLib dylibs and the dyld cache stay warm
from prior runs. A true cold boot would be slower; treat the cold number as
a lower bound on cold and an upper bound on warm. (The very first launch of
the session, before any warm-up, was 649 ms.)

### Directory listing (medians of n=3)

| Dataset | Nautilus window | Nautilus quiesce | Finder window | Finder quiesce | Nautilus/Finder (quiesce) |
|---|---:|---:|---:|---:|---:|
| 1k files | 277 ms | **982 ms** | 250 ms | 1860 ms | 0.53× |
| 10k files | 270 ms | **1175 ms** | 238 ms | 1894 ms | 0.62× |
| 50k files | 273 ms | **2358 ms** | 279 ms | 9103 ms | 0.26× |

Nautilus CPU cost scales cleanly (0.78 s / 1.10 s / 2.49 s of CPU for
1k/10k/50k). Finder's 50k trials showed high variance (3.0 s, 9.4 s, 9.1 s
quiesce) — Finder does extra per-folder work (icon previews, `.DS_Store`,
layout) and is a long-lived process, so any background Finder activity
inflates its quiesce number. The comparison is directional, not exact.

### Thumbnails (images-500) — backend STUBBED

| Metric | Value |
|---|---:|
| Window | 287 ms |
| Quiesce | 822 ms |
| Thumbnails generated | **0 / 500** (stub returns "no thumbnail") |
| Throughput | 0 thumbs/s |

This is the deliberate no-op baseline: the Phase-1 thumbnail shim returns
nothing, so quiesce here is just the listing cost of a 500-file dir. When
the QuickLook backend lands (Phase 3 task 5), re-running
`bench/bench-thumbnails.sh` unchanged will report real throughput — it
counts entries appearing under the bench-local cache
(`bench/xdg/cache/thumbnails/`) and divides by time-to-quiesce.

## Phase 4 acceptance targets — current status

| Target (PLAN.md §5 Phase 4) | Baseline | Status |
|---|---|---|
| Cold start < 1.5 s | 481 ms median (cold-ish) | **PASS** (with cold-ish caveat) |
| Warm start < 0.5 s | 275 ms median | **PASS** |
| 10k dir listed within 1.5× Finder | 1175 ms vs Finder 1894 ms = 0.62× | **PASS** (by the quiesce proxy) |
| Thumbnail grid scrolls at 60 fps | not measurable — backend stubbed, no fps harness | **N/A yet** |

## Known limitations

1. **Quiesce ≠ pixels on screen.** CPU-idle is a proxy; an app could idle
   with an unpainted viewport (not observed here, but unverified frame-by-
   frame). GTK frame-clock or screenshot-diff instrumentation would be the
   upgrade path.
2. **Finder numbers are noisy** (whole-process CPU of a long-lived app;
   background activity counts against it; view style/session state can
   change what Finder does per open). n=3 medians only.
3. **Cold is cold-ish** — see startup caveat above; no `purge`, shared
   dylib/dyld state stays warm.
4. **No-bus launch mode**: benchmarks run without the dev session bus so
   each trial is an independent process (`G_APPLICATION_NON_UNIQUE`
   fallback). A bus-routed `--new-window` on a running instance is a
   different (faster) path not measured here.
5. **Wrapper overhead**: t0 precedes the shell wrapper (Nautilus) /
   `/usr/bin/open` (Finder) spawn; both sides carry a few ms of launcher
   overhead, roughly symmetric.
6. **Window detection needs Screen Recording-adjacent permissions** to see
   window names in some configurations; we only read pid/layer/bounds via
   `CGWindowListCopyWindowInfo`, which worked without extra grants in this
   GUI session.
