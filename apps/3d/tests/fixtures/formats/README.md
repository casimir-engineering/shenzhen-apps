These tiny synthetic fixtures were authored for Shenzhen 3D; they contain no third-party models.

- STL: one 10 × 20 unit triangle, ASCII.
- PLY: the same triangle with red, green and blue vertices, ASCII.
- OFF: one 10 × 20 unit quad with a comment and polygon triangulation.
- OBJ + MTL + PNG: one quad with UV coordinates, a 40% opaque material and a 1 × 1 texture companion.
- glTF (embedded/external) and GLB: one triangle in meters, translated (2, 3, 4), with a 40% opaque blue PBR material. `panel.bin` is the external glTF buffer.
- 3MF: zipped OPC package, inch units, base material with alpha, transformed build item.
- VRML: meters, transformed triangle and 40% opaque material.
- Collada: millimeter asset units, Z up, transformed triangle and transparent material.
- SVG: millimeter dimensions plus viewBox, transparent fill with no stroke and a separate red stroke.
- FBX: ASCII 7.4, centimeter units, transformed triangle and 40% opaque material.

The fixtures exercise useful baseline format behavior, not every feature of these formats. Animations, FBX binary variants, glTF compression, embedded 3MF textures, skins and CAD topology need separate representative datasets.
