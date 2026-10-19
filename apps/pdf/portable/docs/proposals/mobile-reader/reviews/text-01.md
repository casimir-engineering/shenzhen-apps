# Independent review — text round 1

Reviewed 2026-09-24: `spec.md` and `director-notes.md`. This is a review of the proposed design, not certification of an implemented mobile reader. No browser mockups or native application were inspected in this round.

## Score: 8.37 / 10

| Dimension | Weight | Score | Weighted contribution |
|---|---:|---:|---:|
| Product clarity | 25% | 8.2 | 2.05 |
| Technical feasibility | 25% | 8.4 | 2.10 |
| AI development and feedback | 20% | 9.0 | 1.80 |
| Storage efficiency and reliability | 20% | 7.7 | 1.54 |
| Accessibility | 10% | 8.8 | 0.88 |
| **Total** | **100%** | | **8.37** |

The mainstream stack, explicit browser/native evidence split, ordinary switcher alternative, separate Groups, and honest distinction between a first page and a saved revision are strong. The proposal is much better than an attractive interface with an unspecified storage backend. It does not yet meet its own standard that Gate 0 can begin without inventing navigation or data ownership. The principal gaps are concrete enough to fix in text. Native implementation evidence is not required to score the *specification* highly; credible, unambiguous acceptance procedures are.

## Blockers

None that prevents continued design work. Engine licensing and integration remain correctly labeled implementation gates, rather than accomplished facts.

## Major findings

### M1 — Two competing product contracts

**Locations:** spec §§2–4 and director notes “A page with room to breathe,” “Groups are the desk,” and wheel section.

The notes put More in the header and position/Switch below; the spec puts Contents/Find/Switch/More below. Notes expand groups inline; spec opens a dedicated list. Notes define Close as removal from the working set and allow closing a deleted group's documents; spec only exposes Remove from group, which moves to General. Notes make the current wheel slot neutral and define a neutral travel corridor; spec does neither. Neither specification text clearly names the ordinary reader-to-organizer/global-search entry point. These are observable behavior disagreements, not harmless visual details.

**Required change:** choose one canonical navigation/control table and update both documents (or explicitly mark notes superseded and list superseded decisions). State how Reader reaches Groups, Collection and global search; how organizer Back behaves after cold resume/external open; whether group rows expand or navigate; and the exact difference between Close, Remove, Move and archive deletion. State membership of archived-only/closed documents. Carry current-slot neutrality, travel corridor, and zero/one-alternative wheel cases into the canonical contract. Do not leave a mockup implementer to choose which document wins.

### M2 — Storage ownership is explicitly deferred, contradicting specification success

**Location:** spec §7, SQLite ownership paragraph and contracts table; §5 crash protocol.

“It is acceptable to host this repository natively” and “Define that ownership in the first spike” leave the key system boundary undecided. ArchiveIO owns GC but JS may own manifest transactions; the shared mutation lease has no owner, lifetime or cancellation semantics. SourceAccess stages streams while ArchiveIO stages archive blocks, without a stated shared staged-file lease. This can grow into the bespoke cross-runtime framework the brief wants to avoid.

**Required change:** select the v1 SQLite writer/runtime, transaction API, job scheduler owner and lease owner now. A simple foreground-only v1 is acceptable if capture/index pause on background and resume safely. Alternatively use a single native durable repository. Specify the sequence source lease → first-content → capture/stage → commit → release, plus who owns cleanup after JS reload/process death. Make leases opaque native handles and keep pure product decisions reusable in fixture tests. State that browser fake and native repository run the same contract suite; do not claim a fake repository alone validates production semantics. Include block data/directory durability and SQLite durability configuration in the native storage acceptance checklist, rather than equating flush/close/rename with power-loss durability.

### M3 — “Genuinely smaller” has only an alignment-friendly acceptance test

**Locations:** spec §5 “smaller by construction” and §9 storage corpus gate.

The exact 100 MiB source plus exact 1 MiB appends is the optimal case for fixed 1 MiB blocks. It demonstrates an algorithmic property, but neither arbitrary-boundary appends nor the expected PDF/EPUB/Markdown workload. Rewrite-heavy results need only be published; no numeric gate determines whether the Collection meets its main product requirement. Physical metadata, index, materialization and engine extraction overhead are absent from the savings gate. Escalating to CDC is not guaranteed to recover reuse from compressed EPUB rewrites.

**Required change:** define a preregistered representative mixed corpus with non-aligned sizes, small Markdown edits/assets, real PDF incremental saves and full rewrites, EPUB rewrites, identical-but-distinct documents, and unrelated documents. Specify a numeric aggregate net-space target against exact full-file revision storage, plus a maximum overhead for a no-reuse corpus. Report retained bytes and peak/steady total app-owned bytes separately. Define what happens if fixed blocks fail: benchmark CDC and its complexity/CPU/restore cost, then change the storage choice or narrow the promise explicitly. Do not require native measurements now; require a falsifiable future gate.

### M4 — Search promises exact destinations but indexes different bytes

**Locations:** spec §5 Collection/latest resolution/global search, §6 Latest, §7 states.

Only retained bytes are indexed, yet Collection results always resolve the current original when available. After an external edit, a snippet from the saved revision can point into different current bytes. Open-document text results are also promised when Collection is off, although capture/indexing is disabled. The spec correctly separates identities but not search content identity.

**Required change:** bind each text hit to document ID, content/revision identity and locator. Define whether a stale hit opens the matching retained revision with a dated explanation, revalidates/remaps into current bytes, or is marked stale until refreshed. Separate live in-reader Find/ephemeral open-document search from the persistent Collection index; explicitly state behavior with Collection disabled and encrypted documents locked. Add a fixture where the original changes after indexing and a match is selected.

### M5 — Temporary copies and mutable originals lack a complete lifecycle

**Locations:** spec §2 source table, §5 consent/cleanup, §7 SourceAccess.

Temporary shared copies are permitted before consent, but their deletion/resume lifetime is unspecified. A no-Collection user can either lose a shared document silently after process death or accumulate unbounded “temporary” imports, depending on an implementer's choice. Hashing a mutable provider stream proves which bytes were copied, not that they form one coherent revision. Sole-copy protection depends on source availability, yet cleanup has no rule for stale or unknown provider status.

**Required change:** state where a temporary working copy lives, its quota/lifetime, behavior on close/background/process death and the visible Save locally option. Bound work when an unknown-length stream exceeds free space. Capture under a stable source capability where possible; otherwise detect revision/metadata change across capture, retry boundedly and label a best-effort captured stream honestly where a provider cannot guarantee consistency. Before evicting a latest copy, unknown/offline/permission-unverified originals must be treated conservatively. Add fixtures for opting out then reopening a temporary share, and for a provider disappearing before cleanup.

## Medium findings

### D1 — Performance protocol excludes part of the “cold” experience

**Location:** spec §§8–9.

Timing from an in-app receipt with valid access can omit process/JS startup, despite cold launch being a core product promise. “Cold” does not distinguish cold process, cold renderer and warm OS filesystem cache. A p95 from five ordinary edits is too weak to present as a repeatable workflow gate.

**Required change:** separate external cold-start end-to-end timing from source-ready-to-first-content; name exact start/end events and how a native trace/instrumentation verifies actual readable interaction. Define cache/process resets that can be reproduced on an ordinary test phone. Keep provider-network/password/user time separately reported. Repeat each of the five edit tasks sufficiently to report meaningful distributions, or call five observations a smoke sample and report individual/max values. State whether the memory target includes associated WebView renderer processes and measure engine temporary extraction as app-owned space.

### D2 — Format/security profile is still a promise to write a profile

**Locations:** spec §§2,6–7; director notes MVP format-limit requirement.

Markdown's named plugins are a useful start, but raw HTML, math, diagrams, remote images and missing local siblings need explicit readable fallbacks. A picked Markdown file does not imply permission to read its sibling assets. “Scripts disabled” alongside a message bridge needs to distinguish untrusted publication scripts from trusted app-owned bridge code. Password-protected source bytes do not protect plaintext search snippets, previews or extracted caches.

**Required change:** add a small supported/degrade/reject table for PDF, EPUB and Markdown, with a minimum supported Android/API range selected provisionally for the spike. Define a deliberate folder/asset grant flow; never infer sibling access from a file URI. Require bounded decompression/image/resource budgets and clear failure states. State an allowed local-resource origin and message schema, block untrusted frames/navigation/script and privileged file access, and define whether locked-document derived artifacts persist (conservative default: no persistent plaintext index/preview). These are finite adapter policies, not a request to build a general browser sandbox.

### D3 — Consent wording and page taps are ambiguous

**Locations:** spec §2 chrome hiding and §5 consent; notes first use/accessibility.

“Keep enabled / Turn off” implies already-enabled capture even though no consent has occurred. “Tapping the page” can consume links, text-selection or zoom gestures, and hiding every exit control makes discoverability depend on a hidden gesture. Notes are better: unlinked whitespace only, native gestures win, focus restores to invoker.

**Required change:** use affirmative “Keep copies” / “Not now” (or an equally clear pair) and specify where to enable it later. Define chrome tap precedence, a discoverable accessible way to restore/exit, focus restoration and screen-reader announcements when a switch fails or a saved copy replaces an unavailable original. Fold these requirements into canonical spec and named scenarios.

## Minor findings

- Explain whether a renamed General remains the default by stable ID or genuinely creates another group. The proposed latter behavior is unusual; if retained, handle duplicate visible “General” names and moving/removing a document already in General without looping.
- Define document Rename as an app display-name edit unless a provider write/rename operation is explicitly intended. This avoids surprising changes to originals in a reader.
- Replace ambiguous “1/5 GiB” with “1 GiB or 5 GiB.”

## Sources checked

The current primary docs support the existing licensing/platform cautions. No source was used to assert that the proposed native implementation already performs well.

- [MuPDF license](https://mupdf.readthedocs.io/en/latest/license.html): AGPL and commercial paths exist. Keeping a distribution decision as Gate 0 is appropriate; the design must not assume a free iPhone-compatible license.
- [Readium Kotlin toolkit](https://github.com/readium/kotlin-toolkit): it is a Kotlin toolkit, not a supplied React Native integration. The planned bridge is project work.
- [Expo SQLite](https://docs.expo.dev/versions/latest/sdk/sqlite/): web support is described as alpha; browser fixture storage should not be called a native parity test.
- [Android SAF](https://developer.android.com/training/data-storage/shared/documents-files): granted URI access and persistence must be handled explicitly; a file selection is not blanket filesystem authorization.
- [Android WebView bridges](https://developer.android.com/privacy-and-security/risks/insecure-webview-native-bridges): origin/frame and message-validation concerns support D2's explicit resource/bridge policy.
- [Android AtomicFile](https://developer.android.com/reference/android/util/AtomicFile): atomic file replacement and application locking are separate concerns, supporting an explicit mutation owner and durability gate.

## Next review

Resolve M1–M5 before browser visual assessment. Then this same critic should inspect actual rendered browser states and transitions, including small screens, large text, wheel pointer cancellation, search, history and modeled failures. No visual score is assigned from source code or textual descriptions. Round count: **1 of 8**.
