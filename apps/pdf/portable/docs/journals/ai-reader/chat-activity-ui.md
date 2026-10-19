# Chat activity and question visibility

2026-10-10. Implementation verification, not an independent review of my own changes.

The chat view now shows a semibold activity heading and a separate current-tool or
error detail. It consumes the session's typed Thinking, Working, Completed, Error,
Stopped and Idle states. Completed says “Complete · Ready for your reply”; this
does not infer an outstanding question from punctuation. An active task also has
a native progress indicator, while Stop remains available.

The latest user question stays in a selectable, height-limited context strip
above the newest-first transcript. Its full text remains in the transcript and
hover description. Same-count message replacements invalidate the view's cache,
so correcting a transcript cannot leave stale text onscreen.

Two native symbol buttons send `pinApp` and `pinAll`. The host applies mutually
exclusive modes through `setPinMode:` (0 normal, 1 above ShenzhenPDF windows,
2 above all windows). Selected fill/outline and mode-specific hover explanations
make the state visible. Explicit symbol palette colors preserve dark-mode contrast;
aspect fitting retains the vector symbols' native width-to-height ratio.

Validation: `make -C portable build/SPDFMacAIChatViewTests` followed by
`portable/build/SPDFMacAIChatViewTests` exits zero. The suite checks native button
corner hit targets and mouse down/up dispatch, pin selection, activity states,
latest-question visibility, same-count transcript replacement, exact citation
URLs, native citation glyph hit testing and text-view delegate routing. It also
checks transcript/composer geometry at the standalone window minimum of 520×400.

Saved native render evidence is regenerated under `/tmp/sz-ai-chat-` with names
`question`, `thinking`, `error`, `pin-app`, `pin-all`, `NSAppearanceNameAqua` and
`NSAppearanceNameDarkAqua`. I inspected these for clipping and contrast. The
window stays offscreen; this verification makes no network request and launches
no user app. Session persistence and actual window-level behavior belong to the
parallel session and standalone-window acceptance work.

## Compact message follow-up

Independent review initially scored visual craft 8.8/10 because a short answer
left about 60 points before the next role label. Native measurement found the
renderer-added final newline created a blank paragraph, on top of chat's own
bottom padding and row spacing. The view now removes terminal renderer newlines,
measures the actual last text line and uses a 16-point row gap. Internal paragraph
formatting remains unchanged. Tests check short-row height, 16–20 point measured
separation and the intact final glyph of long wrapped prose.

The minimum-size authorization fixture now uses the production blocked-Keychain
message and proves that the preserved draft and recovery button remain reachable.
The session-error heading says “Error · Review the details”, avoiding a misleading
retry promise when recovery requires reopening a chat.

The standalone-window agent independently reviewed refreshed light/dark and
520×400 question, error and authorization renders: visual 9.0/10, usability
9.1/10, no major or medium findings. Remaining low-priority observations were
the extra toolbar Close control and repeated authorization explanation near the
composer. These scores cover saved native renders and the checked user paths;
they do not claim a live network conversation was exercised.
