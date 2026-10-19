# Release notes archive

Each published release has one tracked `YY.M.DD-BUILD.md` file in this
directory. Keep concise markdown bullets above exactly one standalone `---`
divider and detailed notes below it. The updater displays the first section
through the same formatter used by `make -C portable release-notes-preview`.

Do not move release notes into `dist/`: that directory is ignored build output
and cannot reproduce a published release from a clean checkout.

## The archive starts at 26.7.17-1

The rule above is the rule going forward. It was not followed from the
beginning, and **five earlier releases have no file here** — the oldest tracked
notes are `26.7.17-1.md`. For those five the release notes exist only in the
**body of the tagged release commit**, so `git show <tag>` (or
`git log -1 <commit>`) is the archive:

| release | where its notes live |
|---|---|
| 26.6.17-1 | tag `26.6.17-1` → `7bfbd7312` ("Bump version to 26.6.17 (build 1) for TestFlight") |
| 26.6.25-1 | **no tag**; commit `6eefdb145` "Release 26.6.25 (build 1): mac reader fixes and UI polish" |
| 26.6.27-1 | tag `26.6.27-1` (annotated) → `8cbe03d10` "ship the auto-updater" |
| 26.6.27-2 | tag `26.6.27-2` (annotated) → `023dda616` "read-only shadow copy + minimap drag fix" |
| 26.7.9-1 | tag `26.7.9-1` → `56dfef026` "Cmd+K commands + properties panel + smarter search + translation fixes" |

That last one is worth naming: **the 26.7.9-1 commit body is the sole record**
of the document properties panel, the nearest-match search jump and middle-click
tab close. Anyone auditing when a feature shipped will not find them in this
directory.

Two further gaps, so a reader does not mistake this directory for a complete
release ledger:

- **Not every release is tagged.** 26.6.25-1, 26.8.27-1, 26.8.28-1/-2 and
  26.8.30-1 have `Release …` commits and no tag. `git log --grep='^Release '`
  finds them; `git tag` does not.
- **Not every file has a matching tag, and one release's history was
  rewritten.** `26.8.28-1.md` and `26.8.29-2.md` describe overlapping Markdown
  feature sets whose release-commit titles were changed after the fact (see
  `portable/docs/windows-feature-matrix.md` §(c) item 4), so which build shipped
  which pagination behaviour is not recoverable from the notes alone.

If you are reconstructing a release's contents, use the commit range between the
two release commits rather than either the file or the tag on its own.
