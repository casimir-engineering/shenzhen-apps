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

// Which frame to write to the session.
//
// A saved frame whose display is not attached at launch has to be put SOMEWHERE
// visible, and that fallback must never be persisted over the reader's real
// choice: a window remembered on an external display, launched once while only
// the built-in screen was attached, came back clamped to the built-in screen's
// visible frame -- and saving that clamp destroyed the remembered position for
// good. So the fallback is display-only. Until the reader actually moves or
// resizes the window, the frame they left is what gets saved.
NSRect spdf_window_frame_to_persist(NSWindow* window, NSRect liveFrame);

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
