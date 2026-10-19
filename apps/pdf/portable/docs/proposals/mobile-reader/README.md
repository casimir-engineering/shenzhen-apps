# Shenzhen Reader mobile proposal

Start with **index.html** for the complete illustrated document and interactive mockups, or **spec.md** for the canonical implementation specification. This folder is a design deliverable; no Android/iPhone app or native performance result is implied. It changes no desktop reader code.

**Revision notice:** the user corrected the wheel brief: it must contain reader controls, never document/group switching. `index.html` now presents the corrected controls study. Previous 9.57 reviews are historical and do not validate this revision. See `control-wheel-study.md` and the new control-wheel reviews/evidence.

## Open the document

From this folder run `python3 -m http.server 61206 --bind 127.0.0.1`, then open `http://127.0.0.1:61206/`. Any free local port works. The finished HTML and prototype use local assets/system fonts; no install or build is needed to view them.

To regenerate the study, run `node build-control-study.cjs`. To regenerate the architecture appendix from spec.md, run `node build-doc.cjs`. Run both with `marked` available through Node's module search path. This run used marked 17.0.5 from the Codex bundled workspace runtime. Generated HTML is included so this dependency is not required for reading.

## Authority and evidence

- `spec.md`: final product, architecture, storage and acceptance contracts.
- `director-notes.md`: independent creative direction, kept as historical input; its opening notice explains superseded choices.
- `command-wheel*.html/css/js`: current controls-only prototype and pure gesture tests.
- `control-wheel-study.md` and `control-wheel-comparables.md`: current interaction contract and primary-source research.
- `prototype*.html/css/js`: historical design mockups, with simulated documents and in-memory state. This HTML prototype is not the proposed React Native implementation or proof that a native engine works.
- `prototype-readme.md`: interactions and validation limits.
- `reviews/`: new `control-wheel*` reports cover the corrected brief; previous scored text/visual reviews are historical; ranked findings remain available even after correction.
- `journal.md`: decisions, revisions and evidence boundaries.
- `control-wheel-evidence/`: current browser observations, complete sequences, pure tests and source fingerprints.
- `prototype-evidence/`: initial rendered evidence and fixture test results. Later screenshots may be superseded by source corrections; see the journal and reviews.

The proposed 1 GiB mobile archive limit, SQLite live authority and YAML interchange are deliberate mobile recommendations, not desktop setting changes. PDF/EPUB engine integration, licensing, native accessibility, real-device opening times and actual storage savings remain Gate 0/implementation tests.
