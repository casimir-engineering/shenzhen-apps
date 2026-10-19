# Independent review — text round 2

Reviewed 2026-09-24: revised `spec.md` and the new canonical-status notice in `director-notes.md`. Text only; no native implementation or browser visuals are certified.

## Score: 9.24 / 10

| Dimension | Weight | Score | Weighted contribution |
|---|---:|---:|---:|
| Product clarity | 25% | 9.3 | 2.325 |
| Technical feasibility | 25% | 9.2 | 2.300 |
| AI development and feedback | 20% | 9.5 | 1.900 |
| Storage efficiency and reliability | 20% | 8.8 | 1.760 |
| Accessibility | 10% | 9.5 | 0.950 |
| **Total** | **100%** | | **9.235 → 9.24** |

The revision resolves the original architectural uncertainty without multiplying native services. Its explicit TypeScript writer, foreground job scope, shared contract tests, reproducible timing spans and meaningful whole-file-CAS storage baseline support the brief well. Canonical navigation now exists, source and archive states are separated, and the temporary-copy behavior is honest. The higher score reflects specification quality, not presumed native success.

## Previous findings

- **M1 resolved:** navigation, Close versus Move/Remove, archived-only membership and wheel arming are canonical; exploratory notes are explicitly superseded.
- **M2 resolved:** SQLite, jobs, mutation order and opaque byte leases have named owners. SQL/filesystem durability and process generations have appropriate native gates.
- **M3 resolved:** preregistered mixed corpus, whole-file-CAS baseline, net-space target, no-reuse overhead limit and CDC failure branch make the storage claim falsifiable.
- **M4 resolved:** hits bind to content identity and stale matches open a dated saved version; live search is distinct from archival indexing.
- **M5 substantially resolved:** temporary-copy lifecycle, rolling import checks and conservative provider availability are now specified. Two cross-section inconsistencies remain below.
- **D1–D3 resolved:** cold startup is separately measured; editing samples are defined; format and bridge limits are explicit; consent and gesture/accessibility precedence are clear.
- **Original minor findings resolved:** Rename scope, General role/disambiguation and quota labels are specified.

## Blocker / major findings

None remaining. The implementation gates are appropriately conditional. Two medium findings prevent closing the text phase at 9.5.

## Medium findings

### D4 — The newest captured copy and the verified fallback still compete for “Latest”

**Locations:** §2 source consistency; §5 first Collection paragraph and crash publication; §6 History; final named scenarios.

The final scenario says an unverified capture never replaces verified latest. But Collection “always” resolves latest original or latest retained revision, and History says only the latest version gets Latest. A newer unverified capture is a retained revision and may precede the older verified copy chronologically. The commit sequence also unconditionally updates the latest pointer. This leaves source-loss recovery and Latest badges dependent on an implementer's interpretation.

**Required change:** define separate durable meanings for newest capture and preferred recovery revision, or an equivalent single unambiguous model. Add a small resolution table covering:

1. Available original, older verified snapshot and newer unverified capture.
2. Missing original with both verified and newer unverified captures.
3. Missing original with only an unverified capture.
4. A detected failed/torn stream.

Specify which revision Collection opens automatically, which receives a dated warning or requires an explicit selection, whether incomplete/torn data ever becomes a visible revision, and which pointer a capture commit may advance. History may remain chronological, but its label must not claim a newer unverified row is the verified recovery target. An unverified copy can still truthfully be durably Saved; source consistency and storage integrity should remain distinct. Update the existing three “latest” passages to refer to this rule.

### D5 — Staging a second large document exceeds the stated working-file budget

**Locations:** §2 temporary imports/failed switching, §5 accounting, §6 extraction limits, §9 peak-space acceptance.

The reader preserves the old readable document until the incoming one succeeds. With an active 200 MiB temporary shared PDF and an incoming 200 MiB stream, both staged files must coexist during the switch. One active source file plus 128 MiB cache cannot cover that case. The 512 MiB extraction allowance also needs a defined relationship to the active exception and 128 MiB idle cap. Finally, “rolling byte limit” is not an actual limit yet, and a 24-hour maximum must not expire a file underneath an active lease.

**Required change:** state one consistent temporary-storage budget table or formula. Give a numeric/default limit for unknown-length staging, say whether a bounded second pending document is allowed during handover, and define the fallback when preflight cannot preserve the old document. Count archive staging/materialization and active EPUB extraction explicitly, including their peak handover cost; do not hide extraction outside total accounting. State when extraction is dropped to satisfy the idle cap and that expiry becomes eligible only after active leases release. Adjust the peak-space gate to the selected policy. Add a scenario for large temporary A → large incoming B with insufficient reserve: B fails/cancels predictably and A remains readable.

This can be a simple bounded policy. It does not require a new scheduler or storage subsystem.

## Minor observation

The format table newly admits fixed-layout EPUB subject to validated capability. That is a reasonable conditional choice, but the Gate 0 corpus should include one if it remains a launch promise. The old director notes deliberately exclude complex fixed-layout EPUB and are now historical, so this is not a canonical contradiction.

## Scope and next step

No new external claim required source research in this round; the prior primary-source checks still support the platform cautions. The remaining issues are internal state/budget contradictions. Resolve D4 and D5, then regrade the text before visual assessment. No unbuilt performance, storage saving or accessibility behavior is being claimed as measured.

Round count: **2 of 8**. Text phase **not complete**. Browser visual review **not started**.
