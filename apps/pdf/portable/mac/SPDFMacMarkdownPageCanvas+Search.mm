#import "SPDFMacMarkdownPageCanvasPrivate.h"

#import <CoreText/CoreText.h>

#import "markdown/SPDFMarkdown.h"

#include <algorithm>
#include <vector>

// Search geometry and the active-match overlay for the paginated Markdown
// canvas. SPDFMarkdownSearchGeometry is the single CTLine range-to-rect mapping
// shared by highlight drawing (drawRanges:... in SPDFMacMarkdownPageCanvas.mm),
// the active-match outline, the page-local rect API consumed by the minimap
// markers, and the session's background search, which maps its matches while
// it searches. SPDFMarkdownRangeIndex keeps that mapping proportional to the
// fragments drawn: a huge document can hold 100,000 matches of a one-letter
// query, and testing each fragment against every match froze the app.

@implementation SPDFMarkdownRangeIndex {
    std::vector<NSRange> _ranges;          // sorted by location
    std::vector<NSUInteger> _positions;    // index in the caller's array
    std::vector<NSUInteger> _runningMaxEnd;
}

- (instancetype)initWithRanges:(NSArray<NSValue*>*)ranges {
    std::vector<NSRange> buffer;
    buffer.reserve(ranges.count);
    for (NSValue* value in ranges) buffer.push_back(value.rangeValue);
    return [self initWithRangeBuffer:buffer.data() count:buffer.size()];
}

- (instancetype)initWithRangeBuffer:(const NSRange*)ranges count:(NSUInteger)count {
    self = [super init];
    if (!self) return nil;
    _positions.resize(count);
    for (NSUInteger i = 0; i < count; ++i) _positions[i] = i;
    BOOL sorted = YES;
    for (NSUInteger i = 1; i < count && sorted; ++i) sorted = ranges[i - 1].location <= ranges[i].location;
    if (!sorted)
        std::stable_sort(_positions.begin(), _positions.end(),
                         [&](NSUInteger a, NSUInteger b) { return ranges[a].location < ranges[b].location; });
    _ranges.reserve(count);
    _runningMaxEnd.reserve(count);
    NSUInteger maxEnd = 0;
    for (NSUInteger position : _positions) {
        _ranges.push_back(ranges[position]);
        maxEnd = std::max(maxEnd, NSMaxRange(ranges[position]));
        _runningMaxEnd.push_back(maxEnd);
    }
    return self;
}

- (NSUInteger)count {
    return _ranges.size();
}

// Every indexed range overlapping `target`, in text order.
- (void)enumerateRangesIntersecting:(NSRange)target
                         usingBlock:(void (^)(NSUInteger position, NSRange intersection))block {
    if (!target.length || _ranges.empty()) return;
    auto first = std::upper_bound(_runningMaxEnd.begin(), _runningMaxEnd.end(), target.location);
    for (NSUInteger i = (NSUInteger)(first - _runningMaxEnd.begin()); i < _ranges.size(); ++i) {
        if (_ranges[i].location >= NSMaxRange(target)) break;
        NSRange intersection = NSIntersectionRange(target, _ranges[i]);
        if (intersection.length) block(_positions[i], intersection);
    }
}
@end

@implementation SPDFMarkdownSearchGeometry

- (instancetype)initWithPaginationPlan:(SPDFMarkdownPaginationPlan*)plan
                      attributedString:(NSAttributedString*)attributedString {
    self = [super init];
    if (!self) return nil;
    _plan = plan;
    _attributedString = [attributedString copy];
    return self;
}

- (void)enumerateRectsForRanges:(SPDFMarkdownRangeIndex*)ranges
                  onPageAtIndex:(NSUInteger)pageIndex
                     usingBlock:(void (^)(NSUInteger rangeIndex, NSRect rect))block {
    if (!ranges.count || pageIndex >= _plan.pages.count) return;
    SPDFMarkdownPage* page = _plan.pages[pageIndex];
    NSRect printable = _plan.configuration.printableRect;
    CGFloat topContentInset = _plan.configuration.topContentInset;
    NSAttributedString* attributedString = _attributedString;
    for (SPDFMarkdownPageFragment* fragment in page.fragments) {
        if (!fragment.attributedRange.length || NSMaxRange(fragment.attributedRange) > attributedString.length)
            continue;
        __block CTLineRef line = NULL;
        __block CGFloat glyphTop = 0.0;
        __block CGFloat glyphHeight = fragment.height;
        [ranges enumerateRangesIntersecting:fragment.attributedRange
                                 usingBlock:^(NSUInteger position, NSRange intersection) {
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
          block(position, NSMakeRect(NSMinX(printable) + fragment.xOffset + MIN(x0, x1),
                                     topContentInset + fragment.pageYOffset + glyphTop, MAX(2.0, fabs(x1 - x0)),
                                     glyphHeight));
        }];
        if (line) CFRelease(line);
    }
}
@end

static NSUInteger SPDFMarkdownPagePosition(SPDFMarkdownPaginationPlan* plan, SPDFMarkdownPage* page) {
    NSArray<SPDFMarkdownPage*>* pages = plan.pages;
    if (page.pageIndex < pages.count && pages[page.pageIndex] == page) return page.pageIndex;
    return [pages indexOfObjectIdenticalTo:page];
}

@implementation SPDFMacMarkdownPageCanvas (Search)

- (SPDFMarkdownSearchGeometry*)searchGeometry {
    // Cheap: the plan is shared and the text is immutable, so nothing is copied.
    return [[SPDFMarkdownSearchGeometry alloc] initWithPaginationPlan:self.plan attributedString:self.attributedString];
}

- (void)enumeratePageLocalRectsForRanges:(NSArray<NSValue*>*)ranges
                                  onPage:(SPDFMarkdownPage*)page
                              usingBlock:(void (^)(NSRect rect))block {
    if (!ranges.count) return;
    // The search highlights are drawn on every repaint: their index is built
    // once when they change (setSearchRanges:), not per page per frame.
    SPDFMarkdownRangeIndex* index =
        ranges == self.searchRanges ? self.searchRangeIndex : [[SPDFMarkdownRangeIndex alloc] initWithRanges:ranges];
    [self.searchGeometry enumerateRectsForRanges:index
                                         onPageAtIndex:SPDFMarkdownPagePosition(self.plan, page)
                                            usingBlock:^(NSUInteger rangeIndex, NSRect rect) {
                                              (void)rangeIndex;
                                              block(rect);
                                            }];
}

- (NSDictionary<NSNumber*, NSArray<NSValue*>*>*)pageLocalRectsForRanges:(NSArray<NSValue*>*)ranges {
    NSMutableDictionary<NSNumber*, NSArray<NSValue*>*>* rectsByPage = [NSMutableDictionary dictionary];
    if (!ranges.count) return rectsByPage;
    SPDFMarkdownRangeIndex* index = [[SPDFMarkdownRangeIndex alloc] initWithRanges:ranges];
    SPDFMarkdownSearchGeometry* geometry = self.searchGeometry;
    NSArray<SPDFMarkdownPage*>* pages = self.plan.pages;
    for (NSUInteger position = 0; position < pages.count; ++position) {
        NSMutableArray<NSValue*>* rects = [NSMutableArray array];
        [geometry enumerateRectsForRanges:index
                            onPageAtIndex:position
                               usingBlock:^(NSUInteger rangeIndex, NSRect rect) {
                                 (void)rangeIndex;
                                 [rects addObject:[NSValue valueWithRect:rect]];
                               }];
        if (rects.count) rectsByPage[@(pages[position].pageIndex)] = rects;
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
