# Setup rewrite refinement — loop 2

Date: 2026-10-10.

## Independent result

The separate technical reviewer inspected the refreshed native renders and current
source and reran the Settings suite. Its final scores are **9.0/10 beauty** and
**9.0/10 usability**, with no remaining P2 finding in the reviewed scope.

This agent implemented the changes below and does not present its own verification
as independent criticism. The separate reviewer reported:

> Compact header/footers and secondary key link resolve the identified craft
> issues; no clipping, model/detail still legible, disclosure fits, clear primary
> action. Source connection transition repair correct.

The scores cover saved native renders, source and headless tests. The parent owns
live application, popover and physical keyboard validation; those results remain
separately attributed rather than assumed from these tests.

## Changes

- Wizard content defaults to 760×520 instead of 760×612. Its minimum content area
  can reach 650×478. Every step retains the same window/footer position; advancing
  does not reset a size chosen by the user.
- Wizard content starts 24 points from the top, removing space reserved for the
  hidden regular-Settings navigation. Regular Settings retains its prior size and
  navigation layout.
- Browser Connect uses the existing restrained primary fill. The API-key fallback
  is a smaller, unfilled accent action grouped beneath it, retaining a full
  28-point click target and native keyboard behavior.
- A real connected/disconnected transition rebuilds the credential controls:
  successful key entry removes its form, and Disconnect immediately restores the
  API-key alternative. Unrelated model/status updates continue preserving drafts
  and their field editors.

## Evidence

- `/tmp/sz-wizard-{0,1,2,3}.png`: refreshed default-width dark native views.
- `/tmp/sz-wizard-loop2-narrow-{0,1,2,3}.png`: refreshed minimum-width light views.
- `/tmp/sz-settings-loop2-tests.log`: freshly compiled Settings suite, exit 0,
  zero failures. New assertions cover compact size, removed top gap and complete
  credential-connection transitions. Existing focus/draft preservation, search,
  validation, hit-target and wizard completion checks continue passing.
- The independent reviewer separately reran the latest suite with exit 0.
- Parent reports the earlier apparent live launch hang was a transient initial
  accessibility timeout and that all four steps were traversed in the isolated
  application. No app interaction was performed by this implementation agent.

## Live follow-up: reentrant storage callback

After the design review, the parent found a production interaction defect:
switching Static to Dynamic and quickly continuing could leave the Collection
content visible under the Step 3 footer. The storage-mode handler called the host
and then unconditionally repainted Collection. The host could process Continue
before that callback returned, so the old handler overwrote the newly shown AI
step.

A new headless regression invokes Continue inside the synchronous settings-change
callback. It reproduces the mismatch against the old handler: one failure,
`/tmp/sz-settings-reentrant-before.log`. The handler now captures its section
generation and refreshes only if navigation has not changed while the host ran.
The same suite then passes with zero failures and exit 0:
`/tmp/sz-settings-reentrant-after.log`. This fixes the reproduced callback ordering;
the parent will repeat the rapid path in the rebuilt isolated application.
