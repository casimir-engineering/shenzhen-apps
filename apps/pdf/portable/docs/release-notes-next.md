# Release notes

User-facing notes for changes merged since the last release (26.11.3 build 1).

Release notes are tracked in `portable/docs/releases/`. Prepare the next release
with `./portable/cut-release.sh --prepare-only ["summary"]`; publish the
validated metadata from master with `./portable/cut-release.sh --publish`.

How to write them: [docs/RELEASE-NOTES.md](../../../../docs/RELEASE-NOTES.md). Only list what someone on the last
published release will notice; never a fix for a bug that was never released.

## Next release

- Friends no longer stays on "Starting Friends…": it starts by itself, or says it couldn’t start with Try Again.
- Clicking a friend opens your chat at once, with the latest messages already there.
- A Markdown document you send to a friend takes its comments and pictures with it.

### Friends (Beta)

- When Friends couldn’t start, it no longer shows "Starting Friends…" above an empty search field and list for as
  long as the app is open. It shows that it is starting, starts by itself in most cases, and otherwise says
  "Friends couldn’t start." with a Try Again button.
- Clicking a friend in the list opens your chat with them at once, with the latest messages showing. Before, it
  took about a quarter of a second, longer with a long history.
- A Markdown document you send to a friend now goes with its comments and the pictures and files it links to, as one
  .zip named after it ("Report (with comments).zip"). In this version of ShenzhenPDF, Open on it opens the document
  with its comments and pictures; in Finder or any other app the .zip opens into a "Report" folder holding them all.
  Sending only a comments file still sends just that file.
