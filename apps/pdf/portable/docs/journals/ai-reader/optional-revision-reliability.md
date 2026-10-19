# Empty optional revisions — 2026-10-11

The frozen model benchmark exposed avoidable retrieval failures: some providers
send `revision: ""` for an omitted optional argument. The shared read/navigation
guard treated the empty string as a stale revision, rejecting `read_pages`,
`render_page` and `show_document` before they could run.

The guard now checks a revision only when its validated string is nonempty.
These three tools therefore handle an empty optional revision like omission.
Nonempty mismatches, including whitespace, still fail. JSON null, numbers and
arrays still fail schema validation; they are not coerced into omitted values.

Required write guards are separate and unchanged: rename, document jobs, metadata
updates, comment edits and PDF rotation must still match the source revision.
Candidate provenance, cancellation and post-read/navigation race checks remain
intact. No prompt, model, image delivery or inference setting changed.

## Verification

- `make -C portable build/SPDFMacAIDocumentContextTests`: exit 0.
- Production-linked context acceptance binary: exit 0. New tests exercise actual
  text retrieval, generated page pixels and reader navigation with omitted, empty
  and exact revisions. Each also rejects stale/whitespace and invalid typed values
  before allocating a worker. Initialization allocates no worker. Empty write
  revisions cannot rename or rotate the source; its file stamp stays unchanged.
- Negative test: linked the same new test object against the previous
  `SPDFMacAITools.mm` in a separate temporary binary. Build exit 0; test exits
  with SIGABRT (-6) at the empty-revision success assertion. Production and test
  sources were not swapped in the worktree.
- File-size ratchet: exit 0; no cap changes.

Logs: `/tmp/sz-optional-revision-build.log`,
`/tmp/sz-optional-revision-test.log`,
`/tmp/sz-optional-revision-negative-build.log`,
`/tmp/sz-optional-revision-negative-test.log` and
`/tmp/sz-optional-revision-sizes.log`.

This removes a demonstrated tool compatibility failure. It does not address the
model's independent mistakes interpreting technical drawings, and the earlier
benchmark results remain unchanged.
