#import "SPDFMacMarkdownSessionPrivate.h"

#import "SPDFMacMarkdownSidebarModel.h"
#import "SPDFMacMarkdownView.h"

// Putting a freshly rendered document on screen without showing the work.
//
// -installRenderedDocument: builds a new paged view, and its zoom, fit mode and
// scroll origin are restored a runloop turn later (the layout pass has to run
// before a fit can be computed). The old view used to be removed the moment the
// new one was built, so that gap was visible: the document appeared at its
// default zoom and scrolled to the top, then snapped to where the reader
// actually was. On an auto-reload firing on every save, that reads as the
// render happening in front of you.
//
// So the incoming view is built transparent and the outgoing one keeps drawing
// the last good frame until the restore has finished. This does the handover in
// a single pass, with implicit animation off so the two never cross-fade -- the
// first frame the reader sees of the new document is already correct.

@implementation SPDFMacMarkdownSession (ViewSwap)

- (void)installRenderedDocument:(SPDFMarkdownRenderedDocument*)rendered
                 paginationPlan:(SPDFMarkdownPaginationPlan*)plan
              interactiveString:(NSAttributedString*)interactive
           preserveCurrentState:(BOOL)preserve {
    if (!_active || !rendered || !plan || !interactive) return;
    NSPoint origin = preserve && _pagedView ? self.scrollOrigin : _pendingScrollOrigin;
    NSRange selection = preserve && _pagedView ? self.selectedRange : _pendingSelectedRange;
    NSInteger page = preserve && _pagedView ? self.currentPageIndex : _pendingPageIndex;
    CGFloat zoom = preserve && _pagedView ? self.zoom : _pendingZoom;
    SPDFMacMarkdownPageFitMode fit = preserve && _pagedView ? self.fitMode : _pendingFitMode;
    // Read the orientation switch's re-anchor target NOW: it belongs to this
    // install, not to whichever one happens to run its viewport block next.
    NSUInteger reanchor = preserve && _pagedView ? _pendingReanchorLocation : NSNotFound;
    _pendingReanchorLocation = NSNotFound;
    [self clearMatchFlash]; // the flash timer must not drive the outgoing view
    // Kept on screen until the incoming view is configured; see
    // -revealPagedView:replacing:.
    NSView* outgoingPagedView = _pagedView;
    _pagedView = [[SPDFMacMarkdownPagedView alloc] initWithPaginationPlan:plan attributedString:interactive];
    // Transparent rather than hidden: a HIDDEN scroll view does not scroll into
    // position, so the re-anchor below silently did nothing and the reader
    // landed on the wrong page after a rotate. Alpha keeps the view fully laid
    // out and scrollable while it is invisible.
    _pagedView.alphaValue = 0.0;
    _pagedView.reader = _reader;
    _minimapModel = [[SPDFMacMarkdownMinimapModel alloc] initWithPaginationPlan:plan attributedString:interactive];
    _sidebarModel = [[SPDFMacMarkdownSidebarModel alloc] initWithRenderedDocument:rendered paginationPlan:plan];
    _pagedView.translatesAutoresizingMaskIntoConstraints = NO;
    __weak SPDFMacMarkdownSession* weakSelf = self;
    _pagedView.viewportChangedHandler = ^(NSInteger pageIndex, CGFloat currentZoom) {
      SPDFMacMarkdownSession* strongSelf = weakSelf;
      if (strongSelf.viewportUpdateHandler)
          strongSelf.viewportUpdateHandler(pageIndex, currentZoom, strongSelf->_pagedView.fitMode);
    };
    _pagedView.activateDestinationHandler = ^(NSString* destination, BOOL wikiLink) {
      [weakSelf activateDestination:destination wikiLink:wikiLink];
    };
    _pagedView.chooseCodeLanguageHandler = ^(NSUInteger blockIndex) {
      SPDFMacMarkdownSession* strongSelf = weakSelf;
      [strongSelf showLanguagePickerForCodeBlock:blockIndex parentWindow:strongSelf->_pagedView.window];
    };
    _pagedView.copyCodeBlockHandler = ^BOOL(NSUInteger blockIndex) {
      return [weakSelf copyCodeBlock:blockIndex];
    };
    [_rootView addSubview:_pagedView];
    [NSLayoutConstraint activateConstraints:@[
        [_pagedView.topAnchor constraintEqualToAnchor:_rootView.topAnchor],
        [_pagedView.leadingAnchor constraintEqualToAnchor:_rootView.leadingAnchor],
        [_pagedView.trailingAnchor constraintEqualToAnchor:_rootView.trailingAnchor],
        [_pagedView.bottomAnchor constraintEqualToAnchor:_rootView.bottomAnchor],
    ]];
    _placeholder.hidden = YES;
    if (_searchMatches.count) [self applySearchHighlights];
    // Every install of an active render is the lazy-load trigger for any
    // remote images the document references (idempotent for known targets).
    [self startRemoteImageFetchesIfNeeded];
    _pagedView.selectedRange = selection;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!self->_active || !self->_pagedView.superview) {
          [self revealPagedView:self->_pagedView replacing:outgoingPagedView];
          return;
      }
      [self->_rootView layoutSubtreeIfNeeded];
      // Restore the zoom / fit mode first so a pending anchor scrolls within
      // the restored viewport instead of silently discarding it.
      if (fit == SPDFMacMarkdownPageFitCustom)
          [self->_pagedView setZoom:zoom centeredAtPoint:NSZeroPoint];
      else
          [self->_pagedView applyFitMode:fit];
      if (self->_pendingAnchor.length) {
          [self scrollToHeadingAnchor:self->_pendingAnchor];
          self->_pendingAnchor = nil;
      } else if (reanchor != NSNotFound) {
          // Re-flowed onto different paper: the outgoing scroll origin points
          // at unrelated content now, so land on the page that holds whatever
          // was at the top of the viewport.
          NSRange target = NSMakeRange(reanchor, 0);
          [self->_pagedView goToPageAtIndex:(NSInteger)[self->_pagedView pageIndexForRange:target] alignTop:YES];
      } else if (preserve) {
          // An in-place rerender (language choice, font scale) captured the
          // live origin: restore it exactly for every fit mode so the viewport
          // does not drift to a page boundary. The bounds-change notification
          // re-derives the current page index.
          [self->_pagedView.contentView scrollToPoint:origin];
          [self->_pagedView reflectScrolledClipView:self->_pagedView.contentView];
      } else {
          [self->_pagedView goToPageAtIndex:page alignTop:NO];
          if (fit == SPDFMacMarkdownPageFitCustom) {
              [self->_pagedView.contentView scrollToPoint:origin];
              [self->_pagedView reflectScrolledClipView:self->_pagedView.contentView];
          }
      }
      // Only now is the incoming view showing what the reader was looking at.
      [self revealPagedView:self->_pagedView replacing:outgoingPagedView];
    });
}

- (void)revealPagedView:(NSView*)incoming replacing:(NSView*)outgoing {
    if (incoming == outgoing) return;
    if (incoming.alphaValue >= 1.0) {
        [outgoing removeFromSuperview];
        return;
    }
    [NSAnimationContext beginGrouping];
    NSAnimationContext.currentContext.duration = 0;
    incoming.alphaValue = 1.0;
    [outgoing removeFromSuperview];
    [NSAnimationContext endGrouping];
}

@end
