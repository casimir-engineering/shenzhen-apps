# Mesh and vector format validation

Validated 16 October 2026 with Node 26, Vitest 5 and headless Chromium via Playwright. Fixtures in `tests/fixtures/formats` were authored for this project, are small and deterministic, and exercise practical baseline support rather than comprehensive vendor compatibility.

Reproduce with:

```sh
npx vitest run tests/formats.test.ts
node tests/formats-browser.mjs
node scripts/license-audit.mjs
```

The Node suite passes 9 tests: ASCII STL, colored ASCII PLY, OFF polygon triangulation, ASCII FBX material and placement, FBX unit metadata and collapsed root-group transforms, companion-only/empty-file rejection, and instances with shared geometry and distinct materials. Indexed geometry, finite normals, model bounds, unit warnings and per-vertex colors are checked where applicable.

The Chromium integration passes 9 fixture variants: OBJ with an MTL and an actually decoded PNG companion, embedded glTF, glTF with external BIN, GLB, 3MF, VRML, Collada, SVG and ASCII FBX. It imports through the application's `importFiles` entry point, checks world bounds and material alpha, and writes details to `artifacts/formats-validation.json`.

| Behavior | Verified result |
| --- | --- |
| glTF / GLB / VRML | Meter units, translated triangle, 40% opacity with transparent rendering |
| OBJ + MTL + PNG | Quad triangulation, UV texture decoded at 1 × 1 pixels, material opacity 0.4, companions resolved |
| 3MF | Inch unit metadata, build-item transform, base-material alpha 0.4 with transparent rendering enabled |
| Collada | Millimeter source coordinates normalized to meters by the loader, Z-up conversion, transparent effect |
| SVG | Physical millimeter dimensions plus viewBox produce 100 × 50 mm geometry; alpha preserved and `stroke="none"` creates no outline |
| FBX | Centimeters-per-source-unit metadata scales geometry and transforms before measurement; `UnitScaleFactor=100` makes one source unit measure 1000 mm |

Three.js 0.186 exposes SVG `data.xml` as an Element despite the installed type declaration describing an XMLDocument. The importer uses the actual runtime result. Its 3MF loader supplies material opacity without setting the transparency flag for this fixture; the importer enables that flag. FBX without valid unit metadata still requires a user scale check and explicitly warns that centimeters were assumed.

These checks do not establish support for every syntax or extension: binary FBX, compressed glTF/meshopt decoder execution, skins, animation, embedded 3MF textures, SVG text/images/gradients and vendor-specific extensions are not covered. SVG measurements use sampled geometry; CAD exact topology is validated separately. The browser check verifies import/material objects and texture decoding, not GPU pixel appearance or native-device behavior.
