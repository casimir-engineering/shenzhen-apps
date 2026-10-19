#import "SPDFMacMarkdownPageCanvasPrivate.h"

#import <CoreText/CoreText.h>

#import "markdown/SPDFMarkdown.h"

// Search geometry and the active-match overlay for the paginated Markdown
// canvas. enumeratePageLocalRectsForRanges:onPage:usingBlock: is the single
// CTLine range-to-rect mapping shared by highlight drawing (drawRanges:... in
// SPDFMacMarkdownPageCanvas.mm), the active-match outline, and the page-local
// rect API consumed by the minimap markers.
@implementation SPDFMacMarkdownPageCanvas (Search)

- (void)enumeratePageLocalRectsForRanges:(NSArray<NSValue*>*)ranges
                                  onPage:(SPDFMarkdownPage*)page
                              usingBlock:(void (^)(NSRect rect))block {
    if (!ranges.count) return;
    NSRect printable = self.plan.configuration.printableRect;
    CGFloat topContentInset = self.plan.configuration.topContentInset;
    NSAttributedString* attributedString = self.attributedString;
    for (SPDFMarkdownPageFragment* fragment in page.fragments) {
        if (!fragment.attributedRange.length || NSMaxRange(fragment.attributedRange) > attributedString.length)
            continue;
        CTLineRef line = NULL;
        CGFloat glyphTop = 0.0;
        CGFloat glyphHeight = fragment.height;
        for (NSValue* value in ranges) {
            NSRange intersection = NSIntersectionRange(fragment.attributedRange, value.rangeValue);
            if (!intersection.length) continue;
            if (!line) {
                NSAttributedString* lineString =
                    [attributedString attributedSubstringFromRange:fragment.attributedRange];
                // The shared constructor keeps inline-attachment advances in
                // sync with the NSLayoutManager measurement pass, so text
                // after an image x-maps at the image's real width.
                line = SPDFMarkdownCreateFragmentLine(lineString);
                // The fragment band (fragment.height) includes line and
                // paragraph spacing, so band-tall rects looked vertically
                // oversized next to the PDF view's glyph-hugging highlights.
                // Use the line's typographic extent around the baseline (1pt
                // breathing room), clamped within the fragment band.
                CGFloat ascent = 0.0, descent = 0.0;
                CTLineGetTypographicBounds(line, &ascent, &descent, NULL);
                CGFloat scale = MAX(fragment.scale, 0.001);
                CGFloat top = MAX(0.0, fragment.baselineOffset - ascent * scale - 1.0);
                CGFloat bottom = MIN(fragment.height, fragment.baselineOffset + descent * scale + 1.0);
                if (ascent + descent > 0.0 && bottom > top) {
                    glyphTop = top;
                    glyphHeight = bottom - top;
                }
            }
            CFIndex start = (CFIndex)(intersection.location - fragment.attributedRange.location);
            CFIndex end = (CFIndex)(NSMaxRange(intersection) - fragment.attributedRange.location);
            CGFloat x0 = CTLineGetOffsetForStringIndex(line, start, NULL) * fragment.scale;
            CGFloat x1 = CTLineGetOffsetForStringIndex(line, end, NULL) * fragment.scale;
            block(NSMakeRect(NSMinX(printable) + fragment.xOffset + MIN(x0, x1),
                             topContentInset + fragment.pageYOffset + glyphTop, MAX(2.0, fabs(x1 - x0)),
                             glyphHeight));
        }
        if (line) CFRelease(line);
    }
}

- (NSDictionary<NSNumber*, NSArray<NSValue*>*>*)pageLocalRectsForRanges:(NSArray<NSValue*>*)ranges {
    NSMutableDictionary<NSNumber*, NSArray<NSValue*>*>* rectsByPage = [NSMutableDictionary dictionary];
    if (!ranges.count) return rectsByPage;
    for (SPDFMarkdownPage* page in self.plan.pages) {
        NSMutableArray<NSValue*>* rects = [NSMutableArray array];
        [self enumeratePageLocalRectsForRanges:ranges
                                        onPage:page
                                    usingBlock:^(NSRect rect) {
                                      [rects addObject:[NSValue valueWithRect:rect]];
                                    }];
        if (rects.count) rectsByPage[@(page.pageIndex)] = rects;
    }
    return rectsByPage;
}

// PDF parity: the current find match is an animated red outline — the match
// rect inset by (-2, -2), stroked rgb(0.94, 0.03, 0.02) at the animated alpha
// with a 1.2pt line (see SPDFDocumentView's activeFind drawing).
- (void)drawActiveSearchOnPage:(SPDFMarkdownPage*)page pageFrame:(NSRect)pageFrame {
    NSRange range = self.activeSearchRange;
    CGFloat alpha = self.activeSearchAlpha;
    if (!range.length || alpha <= 0.0) return;
    NSColor* stroke = [NSColor colorWithCalibratedRed:0.94 green:0.03 blue:0.02 alpha:alpha];
    [self enumeratePageLocalRectsForRanges:@[ [NSValue valueWithRange:range] ]
                                    onPage:page
                                usingBlock:^(NSRect rect) {
                                  NSRect outline = NSInsetRect(
                                      NSOffsetRect(rect, NSMinX(pageFrame), NSMinY(pageFrame)), -2.0, -2.0);
                                  [stroke setStroke];
                                  NSBezierPath* path = [NSBezierPath bezierPathWithRect:outline];
                                  path.lineWidth = 1.2;
                                  [path stroke];
                                }];
}

@end
