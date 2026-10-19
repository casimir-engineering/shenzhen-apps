# Rendering and progressive ray tracing

Raster modes include shaded surfaces, shaded surfaces with crease edges, triangle wireframe and hidden-line drawing. Wireframe and hidden-line modes first render depth-only surfaces, then draw visible edges with normal depth testing and occluded edges with reversed depth testing and a screen-space dash pattern. Edge buffers are cached and instance transforms remain shared. Section clipping, hidden parts and explode transforms apply to both edge passes. They do not change the original topology used by measurements.

The directional light moves by azimuth and elevation around the model; its intensity is adjustable. An optional uniform ambient fill has its own intensity control. These controls change presentation without changing measurements. The original default shaded pixels, material groups, colors, textures, transparency, nonuniform normals, clipping, hidden parts and exploded parts retain exact source-versus-batched parity in the headed Metal shader check.

Style checks: `node tests/render-styles-browser.mjs`, `node scripts/perf/check-viewer-correctness.mjs`, and `npx vitest run tests/render-styles.test.ts`. Shader correctness checks using software rendering are not performance evidence.

## Progressive GPU ray tracing

The optional ray-tracing mode uses the WebGPU compute backend of `three-gpu-pathtracer` **0.0.27**, pinned with Three.js **0.186.1** and `three-mesh-bvh` **0.9.16**. It traces rays against a two-level BVH and accumulates actual per-pixel samples. It is a still-view renderer; the measured 120 Hz navigation figures in [PERFORMANCE.md](PERFORMANCE.md) apply to raster rendering.

A dedicated module worker owns its WebGPU renderer, OffscreenCanvas, scene, acceleration structures and GPU resources. Preparation copies each distinct geometry and its material bindings once, then copies instance transforms instead of expanding assembly triangles. The original geometry, topology, textures, camera and picking objects remain available to the raster viewer. BVH construction and shader compilation run in the worker. Cancellation terminates that worker, including pending preparation, and removes its canvas. Enabling this feature is the first action that creates a worker or WebGPU context.

Camera movement immediately hides and pauses the traced view. After 180 ms without movement, accumulation restarts with a private camera. The target is 32, 128 or 512 samples per pixel at half or full drawing-buffer resolution. Progress comes from the backend's GPU sample counters; no time-based sample count is synthesized. The canvas accepts no pointer events. Measurement and selection overlays are composited above it by the viewer. PNG export uses the same display output transform (exposure, tone mapping and sRGB encoding), reads the accumulated GPU render target and removes WebGPU's 256-byte row padding.

## Lighting and exposure

The trace uses the raster view's lights and output transform (ACES filmic, exposure 1.35, sRGB), so a converged trace has the raster view's brightness. Three's hemisphere and uniform fill lights are irradiance: a surface receives `intensity × colour` and reflects `albedo / π` of it. The worker therefore converts them into an environment light whose radiance is irradiance / π. A sky/ground split at the hemisphere light's horizon reproduces Three's hemisphere blend exactly, and the uniform fill adds a constant term. The key and rim lights remain directional lights with unchanged intensities and colours. Raster draws its background colour without tone mapping, so the traced background is pre-inverted through the tone curve and is displayed at the same colour. The conversion lives in `src/core/ray-tracing-lighting.ts`, which only the worker loads.

Earlier builds used the fill intensity directly as environment radiance, π times too bright, and omitted the rim light. The trace was blown out: on the sample model, mean model luma was 153% of raster, with nearly every model pixel in the top histogram bin.

Measured on the Apple Metal WebGPU adapter at 480 × 320 / 128 samples. Ratios are traced to raster mean model luma:

| Sample model | Before | After |
| --- | --- | --- |
| As shipped (metallic) | 1.53 | 1.17 |
| Matte materials | 1.22 | 1.015 |
| Matte, uniform fill on | 1.11 | 1.00 |
| Background difference (8-bit levels) | 17 | 0 |

Matte surfaces isolate the lighting conversion: their luma histograms differ from raster by 0.8% (0.97 before). The shipped sample stays brighter because traced metals reflect the environment and neighbouring parts, while raster renders no environment reflections or interreflection. Occluded areas are darker in the trace because raster has no shadows from fill light. The mean changes by less than 0.1% between 32 and 128 samples.

## Capability and resource limits

WebGPU with compute support and worker OffscreenCanvas is required. There is no WebGL substitute labeled ray tracing. Unsupported APIs, material features, GPU storage limits, preparation failures or device loss leave raster rendering available and report a reason.

The preflight currently permits up to 400,000 instances, 128 MiB of estimated unique geometry/BVH storage, 2,048 distinct serialized materials, 64 textures and 64 MiB of estimated texture storage. Textures are limited to 4,096 pixels per side. A frame is limited to 6 million pixels. The combined working estimate must remain below 512 MiB: scene storage, 64 bytes per pixel for accumulation/output/readback, and a 64 MiB wavefront working reserve. Compute dispatches are capped at 65,536 path slots. The worker also checks the device's storage-buffer binding limits before constructing its private scene. These are conservative eligibility estimates, **not a measured bound on total browser/process peak memory**; drivers and compilation allocate additional resources. A large resolution may require half resolution even when the model itself qualifies.

Standard and physical materials preserve diffuse/vertex/instance colors, supported image and data textures, roughness, metalness, opacity, alpha cutouts and physical transmission settings. Raster and traced images can differ: the trace adds shadows, reflections and interreflection, and handles transparency differently (see [Lighting and exposure](#lighting-and-exposure)). The current backend uses four surface bounces and eight alpha-transparency crossings. Custom shaders, section clipping, animated/morphed/skinned meshes, partial draw ranges and compressed/video/cube material textures are explicitly unavailable. Single-material meshes ignore face material groups as Three's raster renderer does; multi-material groups retain their bindings and are compacted by material for the BVH. No model simplification is applied to traced geometry.

## Reproduce the hardware checks

CI runners have no hardware WebGPU adapter, so run these on a Mac before each release. `check-ray-tracing.mjs` and the exposure check start their own Vite dev server on a free loopback port and stop it afterwards; set `PERF_BASE_URL` (for example `http://127.0.0.1:1420`) to use a server that is already running.

```sh
node scripts/perf/check-ray-tracing.mjs
node scripts/perf/check-ray-tracing.mjs --sample
npx vitest run tests/ray-tracing-scene.test.ts tests/progressive-ray-tracer.test.ts tests/ray-tracing-lighting.test.ts
node tests/ray-tracing-exposure-browser.mjs --save=artifacts/perf/exposure
```

`tests/ray-tracing-lighting.test.ts` models the tracer's first-bounce estimator on the CPU: one light or the environment is chosen by the tracer's weights, the environment is sampled from the same CDF builder, and a cosine-sampled BSDF ray is combined by the power heuristic. With a fixed seed it reproduces Three's raster diffuse shading within 1% for five surface orientations, and the old radiance mapping comes out π times too bright. The exposure check renders the sample model as shipped, with matte materials, and with matte materials plus the uniform fill. It fails when mean model luma, luma histogram, clipping, background or 32-to-128-sample convergence leave their limits.

The headed Chromium probe requires a nonfallback WebGPU adapter. It checks 32-sample convergence, nonuniform visible PNG pixels, source immutability, immediate navigation pause and subsequent convergence. Its material fixture includes textured, colored instances and a transparent physical material. The hardware record used an earlier, larger sample assembly that is no longer in the repository; it shares geometry across its repeated instances. It converged at **480 × 300 / 32 samples** on the Apple Metal WebGPU adapter with zero shader-validation errors. The full-assembly export is not a detailed material-quality assessment. The records are [ray-tracing-sample.json](../tests/perf/results/ray-tracing-sample.json) and [ray-tracing-materials.json](../tests/perf/results/ray-tracing-materials.json). Displayed trace and PNG export matched exactly in both hardware probes: zero channel differences across 480 × 300 sample-assembly and 256 × 192 material-fixture images. Each probe writes its JSON and PNG captures in ignored `artifacts/perf/`.

The unit checks cover geometry sharing, budgets, copied material texture transforms, unchanged raster data, hidden/singular transforms, unsupported features, camera isolation, nonaligned readback rows, worker lifetime, external cancellation after preparation, navigation idle timing and GPU-error export rejection. Software rendering is not used as hardware evidence.

Upstream references: [WebGPUPathTracer API](https://gkjohnson.github.io/tools/docs/three-gpu-pathtracer/webgpu/WebGPUPathTracer/), [project source and license](https://github.com/gkjohnson/three-gpu-pathtracer), [Three WebGPURenderer](https://threejs.org/docs/pages/WebGPURenderer.html), and [Three OffscreenCanvas workers](https://threejs.org/manual/pages/offscreencanvas.html).

Selected parts are drawn with a light jade tint and a crease outline, using the same cached edge buffers as the edge display. Outline segments covered by other parts are dashed. A ring marks a selected part smaller than about 24 pixels on screen. The tint and outline only add pixels over the selected parts; the rest of the frame is identical with or without a selection.

The camera's near and far planes are recalculated from the current view on every frame, not only when the view is fitted. Zooming out after zooming to a small part therefore renders the assembly exactly as it looked before, with no missing or see-through faces.
