#import "SPDFMacMarkdownPageCanvasPrivate.h"

#import "SPDFMacUIHelpers.h" /* SPDFMacUIReader: documentTypeToSearchKeyDown: */

// Focus and key entry for the Markdown canvas, split from the main
// implementation to keep it inside the size ratchet. Both methods answer the
// same question -- does typing reach the document? -- which is why they live
// together.

@implementation SPDFMacMarkdownPageCanvas (Focus)

// Focus follows the document onto the screen, whichever path put it there. The
// activation completion is not enough: a reopen can early-return before
// activation (-ensureActiveMarkdownTabHasContent's backstop), leaving the canvas
// on screen with NOBODY holding first responder -- the window held it and typing
// went nowhere. Claiming here covers every install path by construction, and
// only when the window itself (or nothing) holds it, so the find and page fields
// keep the keys.
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (!self.window || !self.acceptsFirstResponder) return;
    // Next runloop turn, not now: at install time the OUTGOING view often still
    // holds first responder, so an immediate check sees a legitimate holder and
    // stands off -- and only afterwards does that view go away and AppKit drop
    // first responder to the window, stranding the keys with nobody. By the next
    // turn the hierarchy has settled and the question has its real answer.
    __weak SPDFMacMarkdownPageCanvas* weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
      SPDFMacMarkdownPageCanvas* canvas = weakSelf;
      NSWindow* window = canvas.window;
      if (!window) return;
      // Stand off ONLY for a live text edit. Anything else holding the keys
      // when a document appears -- the chapters outline, a toolbar control, the
      // outgoing view -- swallows typing silently, which is the whole bug: a
      // displayed document must be searchable without a click.
      if ([window.firstResponder isKindOfClass:NSText.class]) return;
      [window makeFirstResponder:canvas];
    });
}

- (void)keyDown:(NSEvent*)event {
    // Type-to-search parity with the PDF page view (SPDFMacDocumentView
    // keyDown): a printable key starts a find instead of doing nothing. This
    // MUST come before the scroll-view forward below, which consumes the event
    // for scrolling and is why typing in a Markdown document was silently
    // dead. The reader rejects modified/control/function keys itself, so
    // Escape and Cmd shortcuts keep their behavior.
    if (self.reader && [self.reader documentTypeToSearchKeyDown:event]) return;
    NSScrollView* scrollView = self.enclosingScrollView;
    if (scrollView) {
        [scrollView keyDown:event];
        return;
    }
    [super keyDown:event];
}
@end
