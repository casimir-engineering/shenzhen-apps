# Release notes

User-facing notes for changes merged since the last release (26.11.4 build 2).

Release notes are tracked in `portable/docs/releases/`. Prepare the next release
with `./portable/cut-release.sh --prepare-only ["summary"]`; publish the
validated metadata from master with `./portable/cut-release.sh --publish`.

How to write them: [docs/RELEASE-NOTES.md](../../../../docs/RELEASE-NOTES.md). Only list what someone on the last
published release will notice; never a fix for a bug that was never released.

## Next release

- Translate on this Mac asks which language a document is in when it can't tell from the text, instead of guessing.
- Scrolling no longer leaves faint horizontal lines on the pages or on the dark background beside them, most often
  seen in Markdown documents at zooms such as Fit Page.

### Translate

When you translate on this Mac and the document's language can't be recognised (it is mostly numbers or part codes, or
very short), ShenzhenPDF asks which language it is in, with the one you chose last time selected. Cancel stops the
translation.
