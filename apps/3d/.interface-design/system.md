# Shenzhen 3D workbench

Intent: engineers inspect supplier geometry, measure fit and leave fabrication feedback. Geometry is the focal surface; the right inspector explains the current operation. Review pins connect each comment to an actual part, point or feature.

Domain: datum planes, calipers, part trees, snapped vertices, cut faces, dimension witnesses, revision notes, inspection marks.
Color world: graphite instruments, anodized aluminum, pale drafting paper, jade soldermask, copper traces, restrained XYZ colors.
Signature: the four-component distance readout, A/B witnesses and numbered review pins on the same model.
Avoid generic dashboard cards, an icon-only wall and detached comment feeds. Use compact labeled tools, contextual measurements and notes tied to geometry.

Use existing semantic CSS tokens: --bench, --surface, --raised, --inset, --line, --ink, --secondary, --muted, --jade. Fine borders with quiet surface shifts; no independent card palette. Native system UI text, --mono/tabular numbers. Existing 12/14/17/24 px scale. Four-pixel spacing base; 12–16px panels, 32px desktop controls, 44px touch targets.

Review: third inspector tab alongside Measure and Saved. Numbered jade pins connect list entries to model anchors. Inline note editor keeps the model visible. Show target kind and part name above the note. Resolve, edit and delete use native buttons. Sharing saves a portable project containing source files, annotations and measurements; no implicit upload.

Appearance: one labeled render-style selector and a lighting disclosure. Shaded remains the default; drawing modes expose hidden-line intent in their labels. Progressive ray tracing is opt-in with sample progress, cancellation and a clear device/model capability reason. Navigation continues using the fast raster renderer.

Copy: use descriptive control labels and necessary status or measurement information. No slogans, promotional headings, reassurance badges or decorative numbers. The empty workspace shows file actions and recent files; model tools appear only with a document. Avoid instructions that merely repeat a nearby control.
