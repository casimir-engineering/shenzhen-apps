#import "SPDFMacMarkdownPageCanvasPrivate.h"

#import "SPDFMacUIHelpers.h"
#import <objc/runtime.h>

@class SPDFMarkdownPage;

@interface SPDFMacMarkdownPageCanvas (CommentsDrawing)
- (void)drawRanges:(NSArray<NSValue*>*)ranges
             color:(NSColor*)color
           rounded:(BOOL)rounded
            onPage:(SPDFMarkdownPage*)page
         pageFrame:(NSRect)pageFrame;
@end

@implementation SPDFMacMarkdownPageCanvas (Comments)
static char kHoveredCommentKey;

- (void)setCommentHighlights:(NSArray<NSDictionary*>*)highlights {
    objc_setAssociatedObject(self, @selector(commentHighlights), [highlights copy], OBJC_ASSOCIATION_COPY_NONATOMIC);
    [self setNeedsDisplay:YES];
}

- (NSArray<NSDictionary*>*)commentHighlights {
    return objc_getAssociatedObject(self, @selector(commentHighlights));
}

// The yellow of a PDF highlight comment, lighter than the search highlight so a match inside a comment still shows.
- (void)drawCommentHighlightsOnPage:(SPDFMarkdownPage*)page pageFrame:(NSRect)pageFrame {
    NSArray<NSDictionary*>* highlights = self.commentHighlights;
    if (!highlights.count) return;
    NSMutableArray<NSValue*>* ranges = [NSMutableArray arrayWithCapacity:highlights.count];
    for (NSDictionary* highlight in highlights)
        if ([highlight[@"range"] isKindOfClass:NSValue.class]) [ranges addObject:highlight[@"range"]];
    [self drawRanges:ranges
               color:[NSColor colorWithSRGBRed:1.0 green:0.93 blue:0.2 alpha:0.32]
             rounded:NO
              onPage:page
           pageFrame:pageFrame];
}

- (void)updateCommentHoverAtWindowPoint:(NSPoint)windowPoint {
    NSArray<NSDictionary*>* highlights = self.commentHighlights;
    BOOL hovering = [objc_getAssociatedObject(self, &kHoveredCommentKey) boolValue];
    if (!highlights.count && !hovering) return;
    NSDictionary* hit = nil;
    NSUInteger index = [self characterIndexAtPoint:[self convertPoint:windowPoint fromView:nil]];
    if (index != NSNotFound)
        for (NSDictionary* highlight in highlights) {
            NSRange range = [highlight[@"range"] rangeValue];
            if (index >= range.location && index < NSMaxRange(range)) { hit = highlight; break; }
        }
    objc_setAssociatedObject(self, &kHoveredCommentKey, @(hit != nil), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (hit) [self.reader documentViewHoverComment:hit atWindowPoint:windowPoint];
    else if (hovering) [self.reader documentViewEndHoverComment];
}
@end
