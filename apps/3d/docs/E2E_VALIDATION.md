# Browser interaction validation

Playwright exercises the running application in Chromium at 1440 × 1000 and an iPhone 13 viewport with touch enabled. The suite uses the existing `@playwright/test` dependency and Chromium installation.

## Run

```sh
npm run test:e2e
```

The configuration reuses a local Vite development server on port 1420, or starts one when needed. CI serves the production build with Vite preview on port 1420, so run `npm run build` before the suite in CI. `E2E_BASE_URL` points tests at an alternative running application and disables automatic server startup. Traces and screenshots are retained on failure under `test-results/`; the HTML report is written to `playwright-report/`.

While application source is being edited, use a static copy of a successful build to prevent Vite hot reload from clearing the active model during a test. The validation run used `artifacts/e2e-build` served on port 1423:

```sh
E2E_BASE_URL=http://127.0.0.1:1423 npm run test:e2e
```

To check test/config types independently from the application build:

```sh
npx tsc --ignoreConfig --noEmit --skipLibCheck --target es2022 --module esnext --moduleResolution bundler --types node --lib es2022,dom tests/e2e.spec.ts playwright.config.ts
```

## Coverage

| Workflow | Desktop | Mobile |
| --- | --- | --- |
| Import `fixtures/sample-assembly.step` through the real file input | Yes | Yes |
| Pick two rendered model locations and read distance | Mouse | Touch |
| Convert mm to cm; override source to inches and apply a custom scale | Yes | Yes |
| Save, restore and delete measurements | Yes | Yes |
| Download JSON and CSV and validate units and numeric data | Yes | Yes |
| CAD face area query and exact minimum distance between faces | Yes | Yes |
| Exact center/centroid distance between two CAD faces | Yes | Yes |
| Mesh fastener cap diameter and merged coplanar area | Yes | Yes |
| Assembly search, hide, show, isolate and show all | Yes | Yes |
| Three-point angle on the sample geometry | Yes | Yes |
| Orthographic projection and section position/axis controls | Toolbar | Settings |
| Edges, ground grid, PNG screenshot download | Yes | — |
| Opacity and assembly explode through settings | — | Yes |
| Point, feature and whole-part notes; edit, resolve and portable project reopen | Yes | Yes |
| Sample STEP face annotation and exact saved measurement round-trip in `.sz3d` | Yes | Yes |
| Render-style and movable/uniform-light settings | Yes | Yes |
| WebGPU capability failure retains the raster viewer | Yes | Yes |
| Uncaught exceptions and browser console errors | Checked after every test | Checked after every test |
| Production service worker installation, offline reload and local STEP import | Yes | Yes |

Model picks come from WebGL pixel readback after selecting top view and fitting the model. The tests confirm candidate points hit geometry through the visible hover status before clicking. This permits the sample assembly to be measured without hardcoded screen coordinates or private application state. Exact queries use the real CAD worker. Export checks read browser downloads and compare converted values with the saved raw measurement. The mesh cap test verifies a 10 mm fitted diameter and the 78.036 mm² area of its 32-segment polygon. It also checks that a touch pick opens the Measure tab without activating a control in the newly appeared bottom sheet.

The offline test waits for service worker installation and control, checks the application shell and WebAssembly are cached, then disables the browser context's network. It reloads the production app and imports the local STEP fixture while offline. This test skips on the Vite development server because its offline cache is generated only by production builds.

## Scope

These are functional browser interaction tests. They do not certify visual design, native file dialogs, signed application bundles, physical phone behavior, OS clipboard integration, or every supported import format. Chromium uses SwiftShader in headless runs, so timing is not a hardware performance benchmark. The sample fixture imports 3,154 instances and 16 geometries.

## Recorded result

On 2026-10-16, the 0.1.2 production run against Vite preview on port 1424 completed with **18 passed and 2 intentionally skipped** in 1.8 minutes. Each project skips the control test specific to the other viewport; all workflows listed above ran in their applicable project. Exact center/centroid distances, mesh cap properties, the mobile sheet interaction regression, and offline reload plus STEP import passed in both viewports. Portable project tests also retained point/feature/part notes, note edits and resolved state, original STEP files, source/display units, custom scale and exact saved measurements. Render/light controls and explicit unsupported-WebGPU recovery passed on desktop and mobile. No uncaught application exceptions or browser console errors occurred. The independent test/config TypeScript check also passed.

The final build with license notices was also checked using a fixed snapshot served by **Vite preview on port 1425**, which sends `Vary: Origin` for assets. This exposed a cache variant mismatch: service worker installation cached requests without `Origin`, while browser module and stylesheet requests included it. The worker now matches bundled same-origin assets with `ignoreVary: true`. The desktop and mobile offline-only tests then both passed in 13.4 seconds, including a fresh offline reload and local STEP import, with no application or console errors. Results are under `artifacts/e2e-offline-vary-results/`.

A separate headed hardware check (`node scripts/perf/check-app-ray-tracing.mjs`) exercised the production WebGPU worker on the Apple Metal adapter: 32-sample convergence, live measurement labels and numbered comment pins, pin pointer targeting above the rendering canvases, PNG export, and worker removal when switching to hidden-line mode. Source measurements remained unchanged and no application errors occurred. This hardware check is separate from the software-rendered interaction suite and is not an FPS benchmark.

The standalone `E2E_BASE_URL=http://127.0.0.1:1424 node tests/mobile-review-scroll.mjs` check sends touch-start/move/end events in mobile Chromium. The review panel scrolled from 0 to 142 px and fully exposed Save. It does not establish native iOS simulator gesture behavior.
