#import <Cocoa/Cocoa.h>

// Restoring a window exactly where it was left, including on a display that is
// not the main one.
//
// The saved value is a WINDOW frame (NSWindow.frame). -initWithContentRect:
// wants a CONTENT rect, and handing it a window frame made the window one
// titlebar taller than it was saved -- and an oversized window is then
// repositioned by AppKit, which is how a window left on a second display came
// back on the main one (measured: saved y 1319, restored y 487).
//
// The style mask here must match the one buildWindow creates the window with;
// it is the mask that decides how much taller a frame is than its content.
NSRect spdf_window_content_rect_for_saved_frame(NSRect frame);

// Everything the document window needs once it exists: the reader it routes
// events to, its delegate, title and minimum size, and the saved frame applied
// AFTER the style mask is final (AppKit repositions during
// -initWithContentRect:, which is how a window left on a second display came
// back on the main one). Grouped here because they are one step -- "make this
// window the app's document window, placed where it was left" -- and because
// losing any one of them silently breaks event routing or resize handling.
void spdf_window_configure_document_window(NSWindow* window, id reader, NSSize minimumSize, NSRect savedFrame,
                                           BOOL hasSavedFrame);

// Which frame to write to the session: the one the reader left, exactly.
//
// The window is not always where the reader left it, and the system's moves
// must never be saved over their choice:
// - a saved frame whose display is not attached at launch is shown somewhere
//   visible (a window remembered on an external display, launched once while
//   only the built-in screen was attached, came back clamped to the built-in
//   screen -- and saving that clamp destroyed the remembered position for good);
// - macOS may move a window it has just shown or activated, onto the display in
//   use, and the next quit saved that as if the reader had put it there;
// - a display that goes away (unplugged, asleep) takes its windows with it.
// Only the reader's own changes (a drag, an edge, a menu command or shortcut;
// a window manager while the displays stay as they are) replace the frame to
// remember, and they are written within half a second, so no quit path, crash
// or update can lose them. A move nobody asked for during the first seconds of
// a launch is undone; a window moved off a display is put back when the display
// returns. A full-screen window is remembered by its frame before full screen.
NSRect spdf_window_frame_to_persist(NSWindow* window, NSRect liveFrame);

// Whether a frame change comes from the reader: the event being handled is
// their input, or a mouse button is down (dragging the title bar or an edge).
// Pure, for the test.
BOOL spdf_window_event_is_the_readers(NSEvent* event, BOOL mouseButtonDown);

// Whether `frame` overlaps any of `visibleFrames` by enough to be usable. Pure,
// so the fallback rule can be tested without displays to plug in.
BOOL spdf_window_frame_is_usable_on_screens(NSRect frame, NSArray<NSValue*>* visibleFrames);

// Brings back the windows this process is not restoring itself.
//
// A multi-window session comes back as one process per window: this one
// restores the window the reader left focused (spdf_session_focused_window_index)
// and activates, and each remaining window is relaunched with
// --restore-window <id> so it comes up behind the focused one. `skipWindowID`
// is this process's own window, which must never be spawned twice.
//
// Called as soon as the session names those windows -- before this process
// builds its own window -- so the launches overlap. Started after the first
// paint instead, a second window arrived a whole launch late: this process
// finished painting, and only then did the next one begin loading its
// documents. The spawning itself runs off the main thread; the caller is in the
// middle of assembling its first frame.
void spdf_spawn_restored_window_processes(NSArray<NSString*>* windowIDs, NSString* skipWindowID);
