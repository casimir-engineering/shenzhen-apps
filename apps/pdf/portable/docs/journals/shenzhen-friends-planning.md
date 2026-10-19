# Shenzhen Friends planning — 2026-10-12

User requested a project-manager-ready prompt and resource allocation for Friends,
plus a separate Local/AI translation implementation. Friends has not been implemented
or deployed; no public service or new networking dependency was installed.

Deliverable: [implementation brief](../plans/shenzhen-friends.md).

- PM/UX agent organized the picker, shared conversation panel, inbox, # attachments,
  slash-agent commands and phased four-slot allocation.
- Architecture/security agent checked primary Apple, WebRTC/IETF, native transport,
  encryption and compression documentation. Mac Bluetooth needs a separate adapter;
  direct-only transfers cannot provide universal reachability.
- Independent critic scored the initial brief 8.9/10 and identified lifecycle,
  authorization, dependency ownership, panel coexistence and test-resource gaps.
- Revised brief scores: completeness 9.5, executability 9.2, UX clarity 9.4; overall
  9.4/10. Added explicit Send/Return submission for slash-command authorization.
- Security review added peer-bound transport fingerprints, a concrete E2E dependency
  ADR gate, two hidden friends reconnecting over Bluetooth without stranger exposure,
  bounded offers and pre-acceptance chunk rejection. Unrequested read receipts removed.
- User questions pending: encrypted relay fallback and reception activation policy.
  These are decisions, not assumed approvals. Hardware/network test access, protocol
  selection and production endpoint ownership/budget remain implementation gates.

Verified the brief has no broken local links and no whitespace errors. No app launch,
user-data transfer, production service deployment or provider spending was involved
in Friends planning. Translation implementation and its evidence are documented
separately by its implementation agent.
