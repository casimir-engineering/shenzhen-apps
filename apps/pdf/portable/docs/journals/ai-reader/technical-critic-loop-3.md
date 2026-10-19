# Technical critic — loop 3

Focused follow-up on paged workspace discovery and `document_metadata`, 2026-10-10. **Final technical grade: 9/10. No remaining blocker found in this delta.** The critic changed no implementation, launched no app and made no provider calls.

## Ranked findings

1. **P2 — A shortlisted metadata read still inspected every open file — fixed.** `SPDFMacAIAnalysisIntegration.mm:16` previously obtained one candidate by constructing all candidates, which statted every tab. The original test overrode `aiAnalysisForPath` and missed this production route. The adapter now calls `aiDocumentCandidateForPath:` (`SPDFMacAIToolsReader.mm:113`), which gathers a snapshot only for the selected tab. The replacement test installs a real cached metadata entry, calls the production implementation, and asserts exactly one candidate snapshot, one metadata lookup and no whole-workspace candidate pass in a 1,000-tab workspace.

2. **P3 — One oversized Unicode grapheme could escape the label/response budget — fixed.** `SPDFMacAIToolsReader.mm:10` previously rounded a truncation range outward to a complete composed sequence. A very long combining sequence could therefore exceed the intended label limit, including the first row exempted from the aggregate byte check. Truncation now stops at a composed boundary at or before the limit, using an ellipsis when the first cluster alone is too large. A 120,000-character combining-sequence fixture stays within both label and total response limits.

3. **P2 — Browser Deny left Settings stuck connecting — fixed and checked within this round.** The parent observed the real browser return to the randomized callback URL with no query. `SPDFMacAIOpenRouterAuth.mm:91` now recognizes only an exact pending callback path with an empty query as cancellation. That branch finishes before code exchange or credential persistence; successful authorization still requires the matching state and code, while an unrelated path or forged state remains invalid. `SPDFMacAISettingsIntegration.mm:126` clears the connecting state and presents a normal cancellation message without an error sheet. The first unrelated-path regression exposed a relative-URL fixture issue, which the parent corrected to send an absolute URL to the actual listener.

## Verification

- Re-read the final schemas, ID mapping, independent document/group continuations, group filtering, byte limits, selected-path freshness validation and production tests. Normal continuation preserves order; the metadata tool does not trigger analysis. Listing reaches neither the candidate/stat pass nor analysis lookup.
- Reran the rebuilt `SPDFMacAIDocumentContextTests`: exit 0. Its 1,000-tab listing reports **16,964 bytes, zero candidate passes and zero analysis lookups**. Production cached-entry and Unicode regression checks also pass. Log: `/tmp/spdf-ai-loop3-context-final.log`.
- Reran the rebuilt `SPDFMacAIAnalysisServiceTests`: exit 0. Log: `/tmp/spdf-ai-loop3-analysis-final.log`.
- Reran the rebuilt `SPDFMacAITransportTests` after the Deny fix and fixture correction: exit 0. The loopback tests assert an unrelated empty request cannot cancel, real empty callback immediately completes cancellation, and Deny issues no exchange request or credential operation. Existing forged-state and successful-code checks remain. Log: `/tmp/spdf-ai-loop3-oauth.log`; parent build/run log: `/tmp/ai-oauth-denial-tests.log`.

The parent reports successful production OpenRouter chat/tool-loop and analysis/cache checks using synthetic text only. This is additional parent-run evidence, not a paid call or independent authentication test performed by this critic. The bounded shared Markdown provenance cost and supported-human-action limits documented in loop 2 remain; the new evidence does not justify claiming literal zero new parsing work or universal native-action parity.
