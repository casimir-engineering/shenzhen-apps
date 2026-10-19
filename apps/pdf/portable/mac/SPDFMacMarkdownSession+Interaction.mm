#import "SPDFMacMarkdownSessionPrivate.h"

#import "SPDFMacMarkdownLanguagePicker.h"
#import "SPDFMacMarkdownRouting.h"

// The interaction half of the session: heading anchors, link activation, the
// code-language picker, and the viewport forwarding onto the paged view.
// Split from SPDFMacMarkdownSession.mm, which keeps the activation/loading/
// rendering lifecycle.
NSString* SPDFMacMarkdownCodeSourceForBlock(SPDFMarkdownDocumentModel* model, NSUInteger blockIndex) {
    for (SPDFMarkdownCodeFence* fence in model.codeFences)
        if (fence.blockIndex == blockIndex) return fence.code;
    return nil;
}

BOOL SPDFMacMarkdownCopyCodeSource(SPDFMarkdownDocumentModel* model, NSUInteger blockIndex,
                                   NSPasteboard* pasteboard) {
    NSString* code = SPDFMacMarkdownCodeSourceForBlock(model, blockIndex);
    if (!code.length || !pasteboard) return NO;
    [pasteboard clearContents];
    return [pasteboard setString:code forType:NSPasteboardTypeString];
}

@implementation SPDFMacMarkdownSession (Interaction)

- (BOOL)scrollToHeadingAnchor:(NSString*)anchor {
    NSString* slug = spdf_mac_markdown_heading_slug(anchor);
    for (SPDFMarkdownRenderedHeading* heading in self.renderedDocument.headings) {
        if ([spdf_mac_markdown_heading_slug(heading.title) isEqualToString:slug]) {
            [_pagedView revealRange:heading.attributedRange];
            return YES;
        }
    }
    return NO;
}

- (void)navigateToAnchorWhenReady:(NSString*)anchor {
    _pendingAnchor = [anchor copy];
    if (_active && self.state == SPDFMacMarkdownSessionReady && [self scrollToHeadingAnchor:_pendingAnchor])
        _pendingAnchor = nil;
}

- (void)activateDestination:(NSString*)destination wikiLink:(BOOL)wikiLink {
    SPDFMacMarkdownLinkResolution* resolution = spdf_mac_resolve_markdown_link(destination, self.documentURL, wikiLink);
    if (resolution.kind == SPDFMacMarkdownLinkExternal) {
        if (self.openExternalURLHandler) self.openExternalURLHandler(resolution.URL);
    } else if (resolution.kind == SPDFMacMarkdownLinkDocument) {
        if (self.openDocumentHandler) self.openDocumentHandler(resolution.URL, resolution.anchor);
    } else if (resolution.kind == SPDFMacMarkdownLinkAnchor) {
        if (![self scrollToHeadingAnchor:resolution.anchor] && self.statusHandler)
            self.statusHandler(@"Heading not found.");
    } else if (self.statusHandler)
        self.statusHandler(@"Blocked unsafe or unsupported Markdown link.");
}

- (void)showLanguagePickerForCodeBlock:(NSUInteger)blockIndex parentWindow:(NSWindow*)window {
    if (!window || ![self.document.model blockWithIndex:blockIndex]) return;
    if (!_languagePicker) _languagePicker = [SPDFMacMarkdownLanguagePickerController new];
    NSRect anchor = [_pagedView codeLanguageControlFrameInViewForBlockIndex:blockIndex];
    if (NSIsEmptyRect(anchor)) {
        // Scrolled away or invoked from the context menu: reveal the block's
        // page so its language control can anchor the popover.
        SPDFMarkdownRenderedBlock* block = [self.renderedDocument renderedBlockWithIndex:blockIndex];
        if (block) [_pagedView revealRange:block.attributedRange];
        anchor = [_pagedView codeLanguageControlFrameInViewForBlockIndex:blockIndex];
    }
    if (NSIsEmptyRect(anchor))
        anchor = NSMakeRect(NSMidX(_pagedView.bounds) - 4.0, NSMinY(_pagedView.bounds) + 4.0, 8.0, 8.0);
    __weak SPDFMacMarkdownSession* weakSelf = self;
    [_languagePicker presentFromView:_pagedView
                          anchorRect:anchor
                          completion:^(SPDFMarkdownLanguage* language) {
                            SPDFMacMarkdownSession* strongSelf = weakSelf;
                            if (!strongSelf || !language || !strongSelf->_active) return;
                            [strongSelf applyLanguageIdentifier:language.identifier toCodeBlock:blockIndex];
                          }];
}

- (NSString*)codeSourceForCodeBlock:(NSUInteger)blockIndex {
    return SPDFMacMarkdownCodeSourceForBlock(self.document.model, blockIndex);
}

- (BOOL)copyCodeBlock:(NSUInteger)blockIndex {
    if (!SPDFMacMarkdownCopyCodeSource(self.document.model, blockIndex, NSPasteboard.generalPasteboard)) return NO;
    if (self.statusHandler) self.statusHandler(@"Code copied.");
    return YES;
}

- (void)applyLanguageIdentifier:(NSString*)identifier toCodeBlock:(NSUInteger)blockIndex {
    if (!identifier.length || ![self.document.model blockWithIndex:blockIndex]) return;
    _languageOverrides[@(blockIndex)] = identifier;
    [self rerenderDocumentWithStatus:@"Code language updated."];
}

- (void)goToPageAtIndex:(NSInteger)pageIndex {
    [_pagedView goToPageAtIndex:pageIndex alignTop:YES];
}
- (void)zoomByFactor:(CGFloat)factor {
    [_pagedView zoomByFactor:factor];
}
- (void)setZoom:(CGFloat)zoom {
    NSRect visible = _pagedView.documentVisibleRect;
    [_pagedView setZoom:zoom centeredAtPoint:NSMakePoint(NSMidX(visible), NSMidY(visible))];
}
- (void)applyFitMode:(SPDFMacMarkdownPageFitMode)fitMode {
    [_pagedView applyFitMode:fitMode];
}
- (void)setPresentationMode:(BOOL)presentationMode {
    _pagedView.presentationMode = presentationMode;
}
- (NSUInteger)pageIndexForRange:(NSRange)range {
    return [_pagedView pageIndexForRange:range];
}
- (void)revealRange:(NSRange)range {
    [_pagedView revealRange:range];
}
- (void)centerAtDocumentPoint:(NSPoint)point {
    [_pagedView centerAtDocumentPoint:point];
}
- (void)centerOnPageAtIndex:(NSInteger)pageIndex xFraction:(CGFloat)xFraction yFraction:(CGFloat)yFraction {
    [_pagedView centerOnPageAtIndex:pageIndex xFraction:xFraction yFraction:yFraction];
}
- (void)scrollByDocumentDeltaX:(CGFloat)deltaX deltaY:(CGFloat)deltaY {
    [_pagedView scrollByDocumentDeltaX:deltaX deltaY:deltaY];
}
- (void)forwardScrollWheelEvent:(NSEvent*)event {
    [_pagedView forwardScrollWheelEvent:event];
}
- (void)magnifyByDelta:(CGFloat)delta {
    [_pagedView magnifyByDelta:delta];
}
- (BOOL)zoomWithScrollWheelEvent:(NSEvent*)event centeredAtWindowPoint:(NSPoint)windowPoint {
    return [_pagedView zoomWithScrollWheelEvent:event centeredAtWindowPoint:windowPoint];
}
- (void)magnifyByDelta:(CGFloat)delta centeredAtWindowPoint:(NSPoint)windowPoint {
    [_pagedView magnifyByDelta:delta centeredAtWindowPoint:windowPoint];
}
- (void)magnifyByDelta:(CGFloat)delta centeredAtDocumentPoint:(NSPoint)documentPoint {
    [_pagedView magnifyByDelta:delta centeredAtDocumentPoint:documentPoint];
}
- (void)noteExternalScrollPositionChanged {
    [_pagedView noteExternalScrollPositionChanged];
}

@end
