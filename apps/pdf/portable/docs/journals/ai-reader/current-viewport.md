# Current document viewport — 2026-10-10

`current_view` is an explicit chat tool for questions about what the reader is
looking at. It captures the document's visible content, not a desktop screenshot:
the current zoom, scroll, reading appearance, selection and highlights remain
visible. It does not activate a window, navigate, or capture another application.

The main-thread capture is bounded to 1600 pixels on its longest edge, preserving
aspect ratio. Encoding and source checks run on the existing lazy tool worker.
Private temporary images follow the page-preview storage and cancellation path.
The result includes selected text, reader controls, normalized visible page
regions, and exact opaque source/page/revision citations. Markdown citations
also carry the live pagination identity. The model receives the actual image
through the existing multimodal request projection; a `viewport` label makes its
partial coverage explicit. No model, credential, privacy setting, startup path,
document-opening path or updater setting changes.

Headless production-linked checks cover crop position, orientation, aspect ratio,
empty viewports, unchanged scroll, PDF and real Markdown views, pagination
identity, cancellation, private image persistence and image delivery. Constructor
checks prove that no capture or worker starts without an explicit request.
Replacing the tool dispatch with the preceding commit fails the new current-view
assertion (exit 2); restored production passes. The running application was not
launched, quit or captured.
