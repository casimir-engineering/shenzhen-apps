# Collection preview performance — 24 September 2026

A thumbnail request was opening a metadata write transaction even though it only
creates or repairs a private preview file. Every request decoded the full manifest
twice, serialized it again, replaced it and synchronized it to disk. This made a
large library slow to browse and unnecessarily held the cross-process write lock.

Materialization now uses the same exclusive lock and metadata validation without
writing the manifest. Both read and write transactions use their validated decode
rather than reading and parsing it again. Blob hashes are still verified, previews
remain independent read-only copies, and modified previews are repaired. No new
startup work, cache lifetime or background task is introduced.

## Headless measurement

Generated fixture: 501 documents, 5,001 version entries, approximately 2.2 MB of
metadata. Each sample materializes the same small retained document twenty times.
Each test creates and deletes its own temporary Collection; no user data is read.
The benchmark isolates metadata/materialization cost rather than PDF rendering.

| Implementation | Sample 1 | Sample 2 | Sample 3 | Median |
|---|---:|---:|---:|---:|
| Previous | 533.52 ms | 536.96 ms | 523.12 ms | 533.52 ms |
| Updated | 171.44 ms | 178.17 ms | 172.55 ms | 172.55 ms |

Median elapsed time fell by **68%**, about **3.09× faster** for this fixture.
Generated capture timestamps cause small serialized-size differences between
samples (2.19–2.20 MB). These are local warm-filesystem measurements, not a claim
about end-to-end application launch or every PDF.

## Regression evidence

`make -C portable mac-collection-store-tests` passes the Store, Integrity and
Cleanup suites. The added fixture checks that repeated materialization leaves the
manifest's file identity, modification date and bytes unchanged. It also verifies
that preview tampering is repaired and a corrupted manifest is rejected without
being overwritten. Compiling the tests against the preceding Store and Access
implementations fails the new manifest-write assertion on all three runs.

Normal writes still persist through the existing atomic write and synchronization
path. A future optimization could investigate manifest reads during capture/history
refresh; that separate behavior was not changed here.
