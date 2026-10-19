#import "SPDFMacMarkdownPageCanvasPrivate.h"

#import "markdown/SPDFMarkdown.h"

// Range-to-page navigation for the paginated Markdown canvas: mapping
// attributed-string locations to plan pages and revealing a range with a
// deterministic, top-aligned scroll.
@implementation SPDFMacMarkdownPageCanvas (Navigation)

// Find the page that renders the fragment containing `location`. Rendered block
// ranges are contiguous, so the predicate must be exclusive at the fragment end:
// a heading starting at location L would otherwise match the last fragment of
// the preceding block (whose NSMaxRange == L), which pagination usually places
// on the previous page. Zero-length fragments (code-control spacer lines) and
// end-of-document locations fall back to the first fragment at or past the
// location, then to the last page.
- (SPDFMarkdownPage*)pageContainingAttributedLocation:(NSUInteger)location
                                             fragment:(SPDFMarkdownPageFragment**)outFragment {
    for (SPDFMarkdownPage* page in self.plan.pages) {
        for (SPDFMarkdownPageFragment* fragment in page.fragments) {
            if (location < NSMaxRange(fragment.attributedRange) || fragment.attributedRange.location >= location) {
                if (outFragment) *outFragment = fragment;
                return page;
            }
        }
    }
    SPDFMarkdownPage* last = self.plan.pages.lastObject;
    if (outFragment) *outFragment = last.fragments.lastObject;
    return last;
}

- (NSUInteger)pageIndexForRange:(NSRange)range {
    NSUInteger location = range.location == NSNotFound ? 0 : MIN(range.location, self.attributedString.length);
    SPDFMarkdownPage* page = [self pageContainingAttributedLocation:location fragment:NULL];
    return page ? page.pageIndex : 0;
}

- (NSRect)firstRectForRange:(NSRange)range {
    if (!self.pageCount || range.location == NSNotFound) return NSZeroRect;
    NSUInteger location = MIN(range.location, self.attributedString.length);
    SPDFMarkdownPageFragment* fragment = nil;
    SPDFMarkdownPage* page = [self pageContainingAttributedLocation:location fragment:&fragment];
    if (!page || !fragment) return NSZeroRect;
    NSRect pageFrame = [self frameForPageAtIndex:page.pageIndex];
    NSRect printable = self.plan.configuration.printableRect;
    if (range.length) {
        // Narrow to the range's first glyph run so centering targets the match
        // itself (the same CTLine mapping the highlight drawing uses).
        __block NSRect glyphRect = NSZeroRect;
        [self enumeratePageLocalRectsForRanges:@[ [NSValue valueWithRange:range] ]
                                        onPage:page
                                    usingBlock:^(NSRect rect) {
                                      if (NSIsEmptyRect(glyphRect)) glyphRect = rect;
                                    }];
        if (!NSIsEmptyRect(glyphRect)) return NSOffsetRect(glyphRect, NSMinX(pageFrame), NSMinY(pageFrame));
    }
    // Zero-length anchors (and spacer fragments) fall back to the fragment's
    // full line band.
    return NSMakeRect(NSMinX(pageFrame) + NSMinX(printable) + fragment.xOffset,
                      NSMinY(pageFrame) + self.plan.configuration.topContentInset + fragment.pageYOffset,
                      MAX(2.0, NSWidth(printable) - fragment.xOffset), MAX(1.0, fragment.height));
}

- (BOOL)scrollRangeToVisible:(NSRange)range {
    if (!self.pageCount || range.location == NSNotFound) return NO;
    NSUInteger location = MIN(range.location, self.attributedString.length);
    SPDFMarkdownPageFragment* fragment = nil;
    SPDFMarkdownPage* page = [self pageContainingAttributedLocation:location fragment:&fragment];
    if (!page || !fragment) return NO;
    NSRect pageFrame = [self frameForPageAtIndex:page.pageIndex];
    CGFloat fragmentTop = NSMinY(pageFrame) + self.plan.configuration.topContentInset + fragment.pageYOffset;
    NSScrollView* scrollView = self.enclosingScrollView;
    NSClipView* clipView = scrollView.contentView;
    if (!clipView) {
        [self scrollRectToVisible:NSMakeRect(NSMinX(pageFrame), fragmentTop, NSWidth(pageFrame), fragment.height)];
        return YES;
    }
    // Deterministic, top-aligned reveal (the PDF path's scrollToPage:alignTop:
    // uses the same 12pt breathing room). scrollRectToVisible: would perform the
    // minimum scroll — doing nothing when the target is already visible and
    // parking revealed headings at the bottom edge of the viewport.
    NSRect visible = clipView.bounds; // canvas/magnified coordinates
    NSPoint origin = visible.origin;
    origin.y = fragmentTop - 12.0;
    if (NSWidth(pageFrame) <= NSWidth(visible) + 0.5)
        origin.x = NSMidX(pageFrame) - NSWidth(visible) * 0.5;
    else
        origin.x = MAX(NSMinX(pageFrame), MIN(origin.x, NSMaxX(pageFrame) - NSWidth(visible)));
    origin.x = MAX(0.0, MIN(origin.x, MAX(0.0, NSWidth(self.bounds) - NSWidth(visible))));
    origin.y = MAX(0.0, MIN(origin.y, MAX(0.0, NSHeight(self.bounds) - NSHeight(visible))));
    [clipView scrollToPoint:origin];
    [scrollView reflectScrolledClipView:clipView];
    return YES;
}

@end
