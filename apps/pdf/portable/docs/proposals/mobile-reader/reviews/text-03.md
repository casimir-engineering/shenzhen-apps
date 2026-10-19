# Independent review — text round 3

Reviewed 2026-09-24: revised `spec.md`, focusing on the recovery-pointer table, conditional publication, handover accounting and their interaction with existing cleanup rules. No visual or native review in this round.

## Score: 9.44 / 10

| Dimension | Weight | Score | Weighted contribution |
|---|---:|---:|---:|
| Product clarity | 25% | 9.6 | 2.40 |
| Technical feasibility | 25% | 9.4 | 2.35 |
| AI development and feedback | 20% | 9.6 | 1.92 |
| Storage efficiency and reliability | 20% | 9.1 | 1.82 |
| Accessibility | 10% | 9.5 | 0.95 |
| **Total** | **100%** | | **9.44** |

## Resolved

**D4 resolved:** newest durable capture and preferred verified recovery have independent identities. The four-case table governs Collection, History and conditional commits; unverified captures no longer acquire a misleading Latest badge or silently replace a verified fallback.

**D5 resolved:** active and incoming staging/extraction have explicit numeric bounds, each category contributes to peak accounting, reserve checks continue during allocation, and failed handover preserves the old reader. Idle cleanup and lease-aware expiry are defined. The fixed-layout EPUB launch capability now has an explicit Gate 0 fixture.

## Blocker / major findings

None. The design is close to ready for visual review. One medium interaction remains.

## Medium — D6: cleanup can delete the last verified recovery target

**Locations:** §2 preferredRecoveryRevisionID; §5 cleanup priority and protection rules.

Given missing original + verified V1 + newer unverified U2, the recovery table correctly opens V1. However, cleanup removes oldest unkept historical revisions before latest, protecting only the *sole retained copy*. V1 is older and not sole, so it can be deleted while U2 survives. That turns a document with a verified fallback into one requiring an unverified-recovery choice and potentially leaves a dangling preferred pointer. This directly undermines the newly introduced recovery rule.

**Required change:** when original availability is unavailable/unknown/unverified, automatically protect the last verified recovery target as well as a sole retained copy. It may be replaced only when another verified coherent revision is durably available; newer unverified captures do not qualify. For deliberate deletion of a protected recovery target, explain that the action removes the last verified recovery copy and require the user to choose that explicit scope. Recompute or clear newestCaptureID and preferredRecoveryRevisionID in the same transaction as authorized revision removal; do not repoint preferredRecoveryRevisionID to an unverified capture.

Add one named cleanup scenario: missing original, older unkept verified V1, newer unverified U2, exceeded cap. Automatic cleanup preserves V1, may remove U2 if eligible, and pauses capture if no sufficient reclaimable data remains. Verify pointer integrity after both automatic and explicit deletion.

This is a direct cross-section consequence of the new state model, not a request for a new feature. No other material text issue was found.

## Status

Text phase remains open for D6. No new external factual claim required research; this finding follows from the document's own rules. Round count: **3 of 8**. Browser visual review has not started.
