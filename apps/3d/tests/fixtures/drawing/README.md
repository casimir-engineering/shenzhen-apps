# Drawing fixtures

`engineering.dxf` is an original test fixture for Shenzhen 3D. It contains a 30 × 40 line, a radius-5 circle, a wraparound arc, a semicircular polyline bulge, a rotated/scaled block, an ellipse, and an unsupported hatch.

`arc-2000.dwg` and `polyline-2000.dwg` come from the LibreDWG Web upstream test suite (GPL-3.0):

- https://github.com/mlightcad/libredwg-web/blob/master/test/test-data/2000/Arc.dwg
- https://github.com/mlightcad/libredwg-web/blob/master/test/test-data/2000/Polyline.dwg

They exercise actual binary DWG decoding, rather than only mocking the parser's intermediate database.
