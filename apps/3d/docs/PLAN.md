# Shenzhen 3D implementation plan

Started 2026-10-16 (Asia/Shanghai). Requested delivery window: under nine hours.

## Product
A local-first engineering viewer for inspecting supplied parts, checking fit, and communicating dimensions. The model dominates the screen. A compact assembly tree sits left; a measurement inspector sits right. On touch devices, panels become sheets. File content stays on the device.

## Milestones and verification gates
1. Foundation: a private repository, reproducible dependencies, CAD worker, STEP assembly benchmark. Verify a sample STEP assembly imports with topology, colors, transforms, and units.
2. Viewer: GPU rendering, BVH selection, camera presets, orthographic/perspective, trackpad/mouse/touch controls, assembly visibility/isolation, section plane, exploded view, transparency. Verify browser desktop/mobile layouts and real rendered geometry.
3. Measurement: point snapping, signed XYZ deltas and straight-line minimum distance, face/edge selection, CAD feature metrics and exact minimum distance where the kernel supports it, mesh approximations clearly identified, angles, surface paths, unit override, saved/exported measurements. Test against analytic fixtures and the sample STEP model.
4. Formats: STEP/STP, IGES/IGS, BREP, STL, OBJ/MTL, GLTF/GLB, 3MF, PLY, OFF, FBX, DAE, KiCad WRL/VRML, DXF, SVG, DWG. Preserve colors/materials/textures as provided. Report format/entity limitations rather than silently claiming full fidelity.
5. Applications: web/PWA, Tauri macOS/Windows/Linux/Android/iOS. Run platform builds locally where supported and CI on host-specific runners. Distinguish a configured build from a tested binary. Signing/store distribution is separate from compilation.
6. Final acceptance: import regression suite, measurement tests, browser interactions, performance report, application builds, documentation and private repository sync.

Commit each verified milestone. Keep evidence and unresolved gaps in docs/VALIDATION.md.

## Performance design
Worker-isolated CAD and DWG parsing; transferable typed buffers; shared instance geometry; lazy-loaded format engines; BVH raycasting; render on demand; bounded device pixel ratio; cancelable import; explicit geometry/material/worker disposal. Benchmark cold and warm imports; do not make universal speed claims from one fixture.

## Measurement contract
Coordinates have a known internal unit, independently converted to display units. Source overrides rescale all length/area/volume results consistently. Point-to-point defaults to ΔX, ΔY, ΔZ and Euclidean shortest distance. Feature minimum distance is distinct from a surface-constrained path. Mesh and tessellated curve results must be labeled approximate. Measurements reference original model coordinates and must not change with explode display offsets.

## 120 Hz performance follow-up

Requested after the first private preview delivery. Measure on the local Apple M5 Max GPU in headed Chromium/Metal at 1440×900 CSS pixels and DPR 2, separately recording browser cadence, CPU submission, GPU elapsed time and hover latency. Keep the original renderer as a reproducible baseline.

1. Remove interaction stalls: add an assembly spatial index above geometry BVHs, coalesce hover events per frame, avoid unchanged transform uploads and shader rebuilds, and instance edge outlines on the GPU. Verify native raycast equivalence, actual edge pixels, selection, clipping, screenshots and mobile interactions.
2. Reduce draw calls: consolidate material groups in render-only geometry and batch compatible independent meshes. Preserve original topology, triangle identifiers, textures, colors and transparent materials. Verify material groups and geometry ownership before hardware comparison.
3. Address vertex throughput: use error-bounded render detail during navigation when geometry is too large for the 8.33 ms frame budget. Restore full detail at rest and retain original geometry for picking and measurements. Report submitted triangle counts and quality behavior with performance numbers.
4. Run paired hardware benchmarks, full functional checks, update the local app, and push verified commits to both private repositories. Treat 120 fps as a measured target for specified workloads, not an unlimited model-size guarantee.

## Design brief
Domain: datum planes, calipers, part trees, snapped vertices, cut faces, dimension witnesses.
Color world: graphite instrument housings, anodized aluminum, pale drafting paper, jade PCB soldermask, copper traces, restrained XYZ axis colors.
Signature: a four-component measurement readout paired with A/B picks and dimension witnesses directly on the model.
Avoid generic dashboard cards, oversized empty hero pages, and a wall of unexplained CAD icons. Use a dominant viewport, compact labeled tool groups, contextual feature properties, and progressive disclosure.
Intent: an engineer checks a supplier model before fabrication; precise, calm, discoverable.
Hierarchy: geometry first, active dimension second, tools third.
Palette/depth: cool graphite neutrals and jade selection, fine separators, quiet surface shifts.
Typography: native system UI for platform legibility; tabular monospace values for measurements; 12/14/17/24 px scale.
Spacing: 4 px base, 12–16 px panel padding; compact desktop controls, 44 px touch targets.

## Review and rendering follow-up

1. Portable review projects: bundle original files and companions, point/part/feature annotations, saved measurements and unit settings. Rebind anchors on re-import using verified structural identities, never stale runtime handles. Validate archive limits and malformed manifests; test CAD and random-ID mesh round trips.
2. Review interface: numbered model pins, inline notes, edit/resolve/delete, focus-on-anchor, desktop/mobile inspector and explicit project save/share. Test real feature selection, reload, units and companion assets.
3. Display: shaded, shaded edges, wireframe and dashed hidden lines; adjustable key direction/intensity and uniform fill. Preserve original measurement geometry and optimized default rendering. Verify pixels, clipping, hide/explode and disposal.
4. Progressive GPU ray tracing: capability-gated backend with asynchronous preparation, explicit progress and memory limits, fast raster navigation and recovery. Verify actual traced output rather than relabeling raster shading.
5. Package the verified update across all targets and publish private commits/releases. Preserve the completed 0.1.1 performance checkpoint and its measured evidence.


## Review/rendering delivery complete

Private `preview-0.1.2` packages are published in both repositories from frozen source `44761a8`, preserving the earlier previews. The update includes portable annotated files, anchored notes, four raster styles, lighting controls and genuine progressive WebGPU tracing. All 16 assets in each release were checked against their local SHA-256; Windows/Linux CI and all local packages use the same 79-file frontend.

Validation: 115 unit tests, 12 exact-CAD checks, 18 production browser workflows (two expected viewport skips), 19 packaged Electron checks and all nine CI jobs in both repositories. Hardware raster regression retained approximately 120 fps for the two largest M5 Max workloads. Native runtime coverage and unverified iOS note-saving/touch-gesture behavior are explicit in [platform evidence](PLATFORMS.md). See [delivery](DELIVERY.md), [review files](REVIEW.md) and [rendering limits](RENDERING.md).
