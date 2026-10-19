# One calm start, one place to return

## Experience brief

The reader has just opened a document, often a technical PDF from another app.
They want to read immediately, then optionally connect useful intelligence and
protect their work. Setup should feel like arranging a familiar reading desk,
not enrolling in a service. No blocking tour and no procession of alerts.

Current prompt inventory: the default PDF reader alert, a permissions wizard
(Accessibility and Full Disk Access), shortcut help, and Collection consent on
first successful document open. These become one reopenable Settings window.
The first document remains visible and readable behind it. System permission
panels open only after an explicit click; reconnect and permission errors stay
inline where possible. Existing granted permissions and Collection decisions
are preserved.

An experience-version integer, independently from application version, shows this
new Settings window once to existing users. Only the primary process presents it,
after first paint. Persist the new marker before presentation so a restored
window cannot create a duplicate. “Show Settings when ShenzhenPDF starts” is a
separate preference; the upgrade introduction must not erase a user's settings.

## Native design direction

- Domain: reading desk, source document, saved copy, chapter, margin note, evidence.
- Color world: paper white, graphite, quiet gray, the reader's blue selection,
  pastel document groups. Existing Collection chrome supplies semantic colors.
- Signature: setup speaks in the reader's real tasks and includes its keyboard
  path: **⌘K → Return → ask documents**. Model credentials and local history are
  explained as different choices, with originals remaining central.
- Avoid: a fullscreen marketing welcome, compulsory stepper, decorative gradients,
  and permission alerts on top of another setup alert.

The 760 × 612 native resizable window has 24-point outside margins, 28-point
buttons and four compact sections across the top: Start here, AI & documents,
Collection, Reading & access. A minimum size of 650 × 540 keeps action labels
readable; content scrolls at small heights. Sections share the existing reader /
Collection surfaces, 13-point body and 12-point secondary text; only the opening
heading uses 24-point semibold. Close is always available. The persistent footer
has the launch preference and Start reading.

Start here contains three practical choices: connect AI, keep local history,
and make ShenzhenPDF the default reader. AI settings contain browser connection,
model ID, explicit chat enablement, and a separate automatic preparation opt-in.
The API-key fallback is a secure field; submission clears the field immediately.
No credential belongs in the settings snapshot, YAML or conversation history.
Automatic analysis explains cloud transfer and account usage before enablement.
Connection alone never enables automatic document upload.

Collection repeats the consent in plain language and links to the existing
storage/location controls. Reading & access contains original image colors,
default reader, optional permissions and shortcuts. Startup shortcut promotion
is incorporated here rather than opening another panel.

## Control contract

`SPDFMacUnifiedSettingsController` is UI-only: no store, network or Keychain
operations during construction. The host supplies a state dictionary and owns
persistence. State keys: `connected`, `connecting`, `connectionStatus`, `model`,
`aiEnabled`, `autoAnalyze`, `collectionEnabled`, `keepImageColors`,
`showSettingsOnLaunch`. Unknown keys are preserved by the host.

- `settingsChanged(changes)` saves only changed preferences.
- `actionHandler(action)` receives `connect`, `disconnect`, `defaultReader`,
  `accessibility`, `fullDiskAccess`, `collectionSettings`, `collection`,
  `shortcuts`, `done`, `dismissed`. Only Start reading emits `done`; closing the window does not imply consent.
- `credentialHandler(secret)` hands the one submitted secret straight to secure
  storage/connection handling, independently from any preferences callback.
- `updateState` refreshes asynchronous connection status; never pass a secret.

Production buttons use the existing full-bounds first-click tracking control;
no transparent overlays or manually clipped icon hit targets. All text-only
controls have accessible labels, native focus behavior, and default Return
activation. Light and dark appearances use existing semantic Collection colors.

## Verification and critic checklist

Headless checks cover versioned presentation (primary vs detached/restored),
all sections at minimum/default sizes, clickable corners and centers of action
buttons, state callbacks, disabled connecting state, and secure-field clearing.
Render the real native content offscreen in both appearances for critique.
The parent validates first-run integration: one panel only, existing decisions
preserved, no cloud request before explicit opt-in, no new work before first
paint, and no store initialization when this panel is unused.

Critics should rank findings: P0 data loss/security, P1 broken primary action,
P2 confusing flow/contrast/clipping, P3 polish. Address P0–P2 before grading the
experience acceptable; target at least 9/10 within four review loops.


## Chat refinement evidence

The native chat shares the reader palette and 13-point controls, presents newest
messages first, keeps a draft when connection setup prevents sending, and keeps
Stop available while browsing history. Return sends; Shift Return inserts a line.
Rich Markdown supports headings, lists, code and clickable page citations. Model
images are removed from the parsed Markdown model before rendering, so even
absolute local paths cannot cause a file read. Trusted page previews are separate
local-only messages restricted to resolved PNG paths under the chat asset folder.

Headless tests cover first-click corners/centers, unconfigured-send draft retention,
resize/reflow through a native layout tick, safe/unsafe links, rejected Markdown
images, stored page previews, and rejected external preview paths. The native dark
and light renders are `/tmp/sz-ai-chat-NSAppearanceNameDarkAqua.png` and
`/tmp/sz-ai-chat-NSAppearanceNameAqua.png`; these are offscreen renders, never app
screenshots. Test binary reports zero failures. A separate critic reviews the
composed experience after integration, rather than grading an isolated mockup.
