# Analysis cache repair validation — 2026-10-09

The analysis service now consumes the reader’s exact document candidate. Its SHA-256 cache key includes source content, the selected model, an explicit prompt version, and actual Markdown layout identity. The latter covers canonical text, fonts, page geometry, fragment positions/ranges, bounded local image content, and already loaded remote image snapshots. Resource inspection follows the renderer’s document-folder boundary and never fetches images.

A per-key `flock` descriptor spans cache lookup, request, validation and atomic save. A second window waits and then reads the first window’s result. Cancellation interrupts the wait, cancels the request and releases the descriptor; process termination releases the OS lock. Cache results are revalidated after waiting. Hashes and live dependency/layout identity are checked again before persistence. No lock file is unlinked while another process might hold its inode.

Installation and subsequent sidebar reads compare the captured source revision, read path, orientation and live rendered-document/pagination-plan objects. Opt-out clears installed results and rejects already queued callbacks. Authored outlines remain authoritative. Generated content stays in cache metadata, never in the source file.

Validation completed headlessly:

- `make -C portable -f Makefile -f mac/tests/ai-reader-tests.mk mac-ai-reader-tests`: exit 0. Production document context, analysis service and chat view suites all passed. Log: `/tmp/ai-analysis-repair-tests.log`.
- Analysis tests spawn two independent executable processes against one cache and assert exactly one fake paid-request marker. They also verify disabled service has no worker, hash/context/key calls or directory creation; disabled production document-open gathers no candidates; model/layout changes miss the cache; changed local and preloaded remote images invalidate identity; changed page geometry invalidates identity even when page boundaries are unchanged; stale pagination and opt-out callbacks cannot install generated chapters; bounded excerpt coverage, authored outlines, bad chapters, cancellation and session budget remain covered.
- `./tools/check-file-sizes.sh`: exit 0. Log: `/tmp/ai-analysis-file-sizes.log`.

No user app was launched, quit or screenshotted. No real credential or live provider request was used. The cross-process test validates concurrent deduplication, not provider billing behavior after a process crashes following request acceptance. Invalidated layout results stay hidden until an existing document-open/settings event requests fresh analysis; this repair does not add analysis to every typography adjustment.
