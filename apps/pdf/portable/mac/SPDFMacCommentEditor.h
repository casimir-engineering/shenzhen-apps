#pragma once
// The comment editor: a small box drawn in the app's own palette, placed at the passage being commented, shown at
// once (no sheet, no fade). The text has focus; ⌘↩ or Add saves, Return starts a new line, Esc or Cancel discards.
// A click anywhere outside closes it too, keeping what was typed as a draft (an empty box just closes). Used for
// adding and editing comments on PDFs and Markdown documents alike.
//
// One box serves a window: it is built ahead of use (-warmUp) and only hidden when it closes, so opening it again
// sets its words and shows it, with nothing to build, lay out or draw from scratch before the next frame.
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface SPDFMacCommentEditorView : NSView
// `title` heads the box ("Add Comment"), `button` names the save button ("Add"), `author` is shown small.
- (instancetype)initWithTitle:(NSString*)title button:(NSString*)button author:(NSString*)author text:(NSString*)text;
// Sets the box up for its next use; it must be closed.
- (void)resetWithTitle:(NSString*)title button:(NSString*)button author:(NSString*)author text:(NSString*)text;
// Lays out and draws the box once off screen, so its first showing finds the text system and fonts ready.
- (void)warmUp;
@property(nonatomic, readonly, getter=isOpen) BOOL open;
// Called once, after the box has left its host: `saved` with the trimmed text (never empty); not saved with the
// draft to keep after a click outside, or nil after Esc, Cancel or an empty box.
@property(nonatomic, copy, nullable) void (^finished)(NSString* _Nullable text, BOOL saved);
@property(nonatomic, readonly) NSTextView* textView;
// Shows the box in `host` near `point` (host coordinates), inside its bounds, and focuses the text.
- (void)showInView:(NSView*)host near:(NSPoint)point;
- (void)save;
- (void)cancel;
// A click outside: closes, keeping the typed text as a draft.
- (void)closeKeepingDraft;
@end

// Where a box anchored at `anchor` goes in a host of `bounds` (flipped or not, `flipped` says): below the point when
// it fits, else above it, always inside the bounds with a margin. Pure, for tests.
NSRect SPDFCommentEditorFrame(NSSize size, NSPoint anchor, NSRect bounds, BOOL flipped);

NS_ASSUME_NONNULL_END
