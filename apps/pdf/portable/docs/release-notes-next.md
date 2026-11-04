# Release notes

User-facing notes for changes merged since the last release (26.11.3 build 2).

Release notes are tracked in `portable/docs/releases/`. Prepare the next release
with `./portable/cut-release.sh --prepare-only ["summary"]`; publish the
validated metadata from master with `./portable/cut-release.sh --publish`.

How to write them: [docs/RELEASE-NOTES.md](../../../../docs/RELEASE-NOTES.md). Only list what someone on the last
published release will notice; never a fix for a bug that was never released.

## Next release

- Friends (Beta): a Markdown document you send arrives as a folder with its comments and pictures, and Open shows it
  all.
- Collection keeps a Markdown document's comments and the files it links to, as well as its pictures.

### Friends (Beta)

- **A Markdown document arrives as a folder.** When you send a Markdown document that has comments, or pictures and
  files from its own folder, your friend gets a folder named after it, such as "Report", holding the document, its
  comments and its pictures. Both chats show the document, "Report.md", and what comes with it ("With comments and 3
  pictures"). **Open** opens the document with its comments and pictures; **Show in Finder** shows the folder. The
  same document sent again arrives as "Report (2)".
- **Friends on an older version** get "Report.zip", which opens into the same folder in Finder.

### Collection

- **Comments and linked files are kept.** Collection keeps a Markdown document's comments and the files it links to,
  such as a PDF, with the document, as it already kept its pictures. Opened from Collection, for example after the
  original was moved or deleted, the document shows its comments and pictures, and comments you add there are kept.
  A document already in Collection picks up its comments and linked files the next time you open it, if they are
  still beside the original.
