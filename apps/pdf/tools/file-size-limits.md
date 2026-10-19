# File-size ratchet

Run `tools/check-file-sizes.sh` from any directory in the worktree. It checks
tracked files and non-ignored untracked files, so new code is covered before it
is staged.

- Maintained first-party source defaults to a maximum of 500 source lines,
  including a final line without a trailing newline.
- Source-extension matching is case-insensitive and includes maintained build
  sources such as Lua, not only compiled application code.
- A cohesive 501-1000-line file needs an exact `exception` entry in
  `tools/file-size-limits.tsv` with a concrete justification.
- Existing files above 1000 lines have exact `legacy` caps. They may shrink but
  may not grow; after a reduction, lower the cap in the same change.
- Remove an entry when its file reaches 500 lines. Never raise a cap merely to
  make the check pass.

The TSV format is `path`, `cap`, `kind`, and `justification`, separated by real
tab characters. Paths are relative to the repository root.

The checker excludes vendored dependency trees, ignored build/package outputs,
fully generated checked-in files, and machine-like regression data. Files that
mix generated and maintained sections remain covered as a whole until those
sections are split into dedicated generated files. The source extension list
and path exclusions live in the checker and are covered by
`tools/test-file-size-ratchet.sh`.

Run the self-test with:

```sh
tools/test-file-size-ratchet.sh
```
