#import "SPDFMacMarkdownPageCanvasPrivate.h"

#import <CoreText/CoreText.h>

#import "SPDFMacMarkdownView.h"
#import "markdown/SPDFMarkdown.h"

// GitHub-style code-box chrome row anchored inside the code box header band:
// the copy button on the LEFT and the language control on the RIGHT, sharing
// one line (the band the paginator reserves for it, see
// SPDFMarkdownPageConfiguration.includesCodeLanguageControlSpacing). Both are
// canvas chrome: nothing here is drawn by the plan, so print, Save as PDF and
// Copy Page — which paint a plan and never the canvas — exclude them both.
static const CGFloat kSPDFMarkdownCodeControlHeight = 20.0;
static const CGFloat kSPDFMarkdownCodeControlCornerRadius = 5.0;
static const CGFloat kSPDFMarkdownCodeControlSideInset = 10.0;
static const CGFloat kSPDFMarkdownCodeControlHorizontalPadding = 9.0;
static const CGFloat kSPDFMarkdownCodeControlHitSlop = 7.0;
// Minimum air between the copy button and the language pill; below it the
// header band is too narrow for two controls and the copy button stands down.
static const CGFloat kSPDFMarkdownCodeControlMinimumGap = 6.0;
// How long the copy button reads "Copied" after a successful copy.
static const NSTimeInterval kSPDFMarkdownCodeCopyFeedbackDuration = 1.2;
static NSString* const kSPDFMarkdownCodeCopyTitle = @"Copy";
static NSString* const kSPDFMarkdownCodeCopiedTitle = @"Copied";

static NSDictionary<NSAttributedStringKey, id>* SPDFCodeControlTitleAttributes(SPDFMarkdownTheme* theme) {
    return @{
        NSFontAttributeName : [NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName : theme.codeControlTextColor,
    };
}

@implementation SPDFMacMarkdownPageCanvas (Decorations)

// The plan's theme variant is the single source of the page chrome palette,
// so canvas chrome always matches the page content drawn from the same plan.
- (SPDFMarkdownTheme*)pageTheme {
    return [SPDFMarkdownTheme themeForVariant:self.plan.configuration.themeVariant];
}

// Paper presentation: light paper keeps the classic white sheet with a soft
// drop shadow; dark paper is the theme's #1E1E1E sheet separated from the
// canvas gutter by a subtle 1px #333333 border instead of a shadow (a dark
// shadow reads as mud on dark gutters). Split into fill/shadow decisions so a
// headless test can probe the choice without rasterizing.
- (NSColor*)paperFillColor {
    return self.pageTheme.paperColor;
}

- (BOOL)drawsPaperShadow {
    return self.pageTheme.drawsPaperShadow;
}

// The gutter behind the sheets. Dark takes the theme's #121212 so the #1E1E1E
// paper edge always reads; light keeps windowBackgroundColor exactly as before.
- (NSColor*)viewportBackgroundColor {
    return self.pageTheme.viewportBackgroundColor ?: NSColor.windowBackgroundColor;
}

- (void)drawPaperBackgroundInFrame:(NSRect)pageFrame {
    [NSGraphicsContext saveGraphicsState];
    if (self.drawsPaperShadow) {
        NSShadow* shadow = [NSShadow new];
        shadow.shadowColor = [NSColor.blackColor colorWithAlphaComponent:0.22];
        shadow.shadowBlurRadius = 4.0;
        shadow.shadowOffset = NSMakeSize(0, -1);
        [shadow set];
    }
    [self.paperFillColor setFill];
    NSRectFill(pageFrame);
    [NSGraphicsContext restoreGraphicsState];
}

// Drawn after the page content so the hairline stays crisp at the page edge.
- (void)drawPaperBorderInFrame:(NSRect)pageFrame {
    if (self.drawsPaperShadow) return;
    [self.pageTheme.paperBorderColor setStroke];
    NSBezierPath* border = [NSBezierPath bezierPathWithRect:NSInsetRect(pageFrame, 0.5, 0.5)];
    border.lineWidth = 1.0;
    [border stroke];
}

- (NSString*)codeLanguageLabelForBlockIndex:(NSUInteger)blockIndex {
    for (SPDFMarkdownPage* page in self.plan.pages) {
        for (SPDFMarkdownPageFragment* fragment in page.fragments) {
            if (fragment.blockIndex != blockIndex || !fragment.attributedRange.length ||
                NSMaxRange(fragment.attributedRange) > self.attributedString.length)
                continue;
            NSString* identifier = [self.attributedString attribute:SPDFMarkdownCodeLanguageAttribute
                                                            atIndex:fragment.attributedRange.location
                                                     effectiveRange:NULL];
            SPDFMarkdownLanguage* language =
                [SPDFMarkdownLanguageCatalog.sharedCatalog languageForFenceIdentifier:identifier];
            return language.displayName ?: (identifier.length ? identifier : @"Plain Text");
        }
    }
    return @"Plain Text";
}

- (NSString*)codeLanguageControlTitleForBlockIndex:(NSUInteger)blockIndex {
    return [[self codeLanguageLabelForBlockIndex:blockIndex] stringByAppendingString:@" ▾"];
}

- (SPDFMarkdownPageFragment*)codeControlFragmentOnPage:(SPDFMarkdownPage*)page blockIndex:(NSUInteger)blockIndex {
    for (SPDFMarkdownPageFragment* fragment in page.fragments) {
        if (fragment.blockIndex != blockIndex || fragment.itemIndex >= self.plan.items.count) continue;
        SPDFMarkdownPaginationItem* item = self.plan.items[fragment.itemIndex];
        if (item.kind == SPDFMarkdownBlockKindCode && !fragment.isContinuation) return fragment;
    }
    return nil;
}

// The copy button's title is stable in width across its two states, so the
// transient "Copied" feedback never resizes or shifts the button.
- (NSString*)copyCodeControlTitleForBlockIndex:(NSUInteger)blockIndex {
    return [self.copiedCodeBlockIndex isEqualToNumber:@(blockIndex)] ? kSPDFMarkdownCodeCopiedTitle
                                                                    : kSPDFMarkdownCodeCopyTitle;
}

// The non-continuation fragment of a code item is its reserved leading band
// (see SPDFItemsForConfiguration), so the chrome row centers vertically in the
// header band the layout actually reserved. The row spans the box; the two
// controls anchor to its edges.
- (NSRect)codeControlRowRectForFragment:(SPDFMarkdownPageFragment*)fragment pageFrame:(NSRect)pageFrame {
    NSRect printable = self.plan.configuration.printableRect;
    // The leading band starts with the unpainted outer margin above the box;
    // the row centers in the in-box header portion below it.
    CGFloat outerMargin = MIN(SPDFMarkdownCodeBoxOuterMargin * fragment.scale, fragment.height);
    CGFloat bandTop =
        NSMinY(pageFrame) + self.plan.configuration.topContentInset + fragment.pageYOffset + outerMargin;
    CGFloat y = round(bandTop + (fragment.height - outerMargin - kSPDFMarkdownCodeControlHeight) * 0.5);
    return NSMakeRect(NSMinX(pageFrame) + NSMinX(printable), y, NSWidth(printable),
                      kSPDFMarkdownCodeControlHeight);
}

- (CGFloat)codeControlWidthForTitle:(NSString*)title {
    NSRect printable = self.plan.configuration.printableRect;
    CGFloat width = ceil([title sizeWithAttributes:SPDFCodeControlTitleAttributes(self.pageTheme)].width) +
                    kSPDFMarkdownCodeControlHorizontalPadding * 2.0;
    return MIN(width,
               MAX(kSPDFMarkdownCodeControlHeight, NSWidth(printable) - kSPDFMarkdownCodeControlSideInset * 2.0));
}

- (NSRect)codeLanguageControlRectForFragment:(SPDFMarkdownPageFragment*)fragment pageFrame:(NSRect)pageFrame {
    NSRect row = [self codeControlRowRectForFragment:fragment pageFrame:pageFrame];
    CGFloat width = [self codeControlWidthForTitle:[self codeLanguageControlTitleForBlockIndex:fragment.blockIndex]];
    return NSMakeRect(NSMaxX(row) - kSPDFMarkdownCodeControlSideInset - width, NSMinY(row), width, NSHeight(row));
}

// Left end of the same row. NSZeroRect when the header band is too narrow for
// both controls: the language selector keeps the row and the copy button
// stands down rather than overlapping it.
- (NSRect)copyCodeControlRectForFragment:(SPDFMarkdownPageFragment*)fragment pageFrame:(NSRect)pageFrame {
    NSRect row = [self codeControlRowRectForFragment:fragment pageFrame:pageFrame];
    CGFloat width = [self codeControlWidthForTitle:kSPDFMarkdownCodeCopiedTitle];
    NSRect copyRect = NSMakeRect(NSMinX(row) + kSPDFMarkdownCodeControlSideInset, NSMinY(row), width, NSHeight(row));
    NSRect languageRect = [self codeLanguageControlRectForFragment:fragment pageFrame:pageFrame];
    if (NSMaxX(copyRect) + kSPDFMarkdownCodeControlMinimumGap > NSMinX(languageRect)) return NSZeroRect;
    return copyRect;
}

static NSRect SPDFCodeControlHitRect(NSRect controlRect) {
    if (NSIsEmptyRect(controlRect)) return NSZeroRect;
    return NSInsetRect(controlRect, -kSPDFMarkdownCodeControlHitSlop, -kSPDFMarkdownCodeControlHitSlop);
}

- (NSRect)codeLanguageControlHitRectForFragment:(SPDFMarkdownPageFragment*)fragment pageFrame:(NSRect)pageFrame {
    return SPDFCodeControlHitRect([self codeLanguageControlRectForFragment:fragment pageFrame:pageFrame]);
}

- (NSRect)copyCodeControlHitRectForFragment:(SPDFMarkdownPageFragment*)fragment pageFrame:(NSRect)pageFrame {
    return SPDFCodeControlHitRect([self copyCodeControlRectForFragment:fragment pageFrame:pageFrame]);
}

- (NSRect)codeControlFrameForBlockIndex:(NSUInteger)blockIndex copyButton:(BOOL)copyButton {
    for (SPDFMarkdownPage* page in self.plan.pages) {
        SPDFMarkdownPageFragment* fragment = [self codeControlFragmentOnPage:page blockIndex:blockIndex];
        if (!fragment) continue;
        NSRect pageFrame = [self frameForPageAtIndex:page.pageIndex];
        return copyButton ? [self copyCodeControlRectForFragment:fragment pageFrame:pageFrame]
                          : [self codeLanguageControlRectForFragment:fragment pageFrame:pageFrame];
    }
    return NSZeroRect;
}

- (NSRect)codeLanguageControlFrameForBlockIndex:(NSUInteger)blockIndex {
    return [self codeControlFrameForBlockIndex:blockIndex copyButton:NO];
}

- (NSRect)copyCodeControlFrameForBlockIndex:(NSUInteger)blockIndex {
    return [self codeControlFrameForBlockIndex:blockIndex copyButton:YES];
}

- (NSNumber*)codeControlBlockAtPoint:(NSPoint)point copyButton:(BOOL)copyButton {
    NSInteger pageIndex = [self pageIndexForVisibleRect:NSMakeRect(point.x, point.y, 1, 1)];
    if (pageIndex < 0 || pageIndex >= (NSInteger)self.pageCount) return nil;
    SPDFMarkdownPage* page = self.plan.pages[(NSUInteger)pageIndex];
    NSRect pageFrame = [self frameForPageAtIndex:(NSUInteger)pageIndex];
    for (SPDFMarkdownPageFragment* fragment in page.fragments) {
        if (fragment.itemIndex >= self.plan.items.count) continue;
        SPDFMarkdownPaginationItem* item = self.plan.items[fragment.itemIndex];
        if (item.kind != SPDFMarkdownBlockKindCode || fragment.isContinuation) continue;
        NSRect hitRect = copyButton ? [self copyCodeControlHitRectForFragment:fragment pageFrame:pageFrame]
                                    : [self codeLanguageControlHitRectForFragment:fragment pageFrame:pageFrame];
        if (!NSIsEmptyRect(hitRect) && NSPointInRect(point, hitRect)) return @(fragment.blockIndex);
    }
    return nil;
}

- (NSNumber*)codeLanguageBlockAtPoint:(NSPoint)point {
    return [self codeControlBlockAtPoint:point copyButton:NO];
}

- (NSNumber*)copyCodeBlockAtPoint:(NSPoint)point {
    return [self codeControlBlockAtPoint:point copyButton:YES];
}

// Click handler for the copy button. The reader owns the pasteboard write —
// it holds the parsed document, so the RAW fence source is copied, never the
// syntax-highlighted rendition — and a successful write arms the transient
// "Copied" title on that one button.
- (void)handleCopyCodeBlock:(NSUInteger)blockIndex {
    if (!self.copyCodeBlockHandler || !self.copyCodeBlockHandler(blockIndex)) {
        NSBeep();
        return;
    }
    self.copiedCodeBlockIndex = @(blockIndex);
    NSUInteger generation = self.copiedCodeGeneration + 1;
    self.copiedCodeGeneration = generation;
    [self setNeedsDisplay:YES];
    __weak SPDFMacMarkdownPageCanvas* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSPDFMarkdownCodeCopyFeedbackDuration * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                     SPDFMacMarkdownPageCanvas* strongSelf = weakSelf;
                     // A later copy owns the state; only the newest generation
                     // clears it (no timer to retain or invalidate).
                     if (!strongSelf || strongSelf.copiedCodeGeneration != generation) return;
                     strongSelf.copiedCodeBlockIndex = nil;
                     [strongSelf setNeedsDisplay:YES];
                   });
}

// PDF parity: links show the pointing-hand cursor on hover. Returns one rect
// per link run portion inside each of the page's line fragments, using the
// same CTLine offset mapping the highlight drawing uses; the tracking-area
// cursor path (SPDFMacMarkdownPageCanvas+Cursor.mm) hit-tests these.
- (NSArray<NSValue*>*)linkRectsForPage:(SPDFMarkdownPage*)page pageFrame:(NSRect)pageFrame {
    NSMutableArray<NSValue*>* linkRects = [NSMutableArray array];
    NSRect printable = self.plan.configuration.printableRect;
    NSAttributedString* attributedString = self.attributedString;
    for (SPDFMarkdownPageFragment* fragment in page.fragments) {
        if (!fragment.attributedRange.length || NSMaxRange(fragment.attributedRange) > attributedString.length)
            continue;
        CTLineRef line = NULL;
        NSUInteger cursor = fragment.attributedRange.location;
        while (cursor < NSMaxRange(fragment.attributedRange)) {
            NSRange effective = NSMakeRange(0, 0);
            NSDictionary* attributes = [attributedString attributesAtIndex:cursor
                                                      longestEffectiveRange:&effective
                                                                    inRange:fragment.attributedRange];
            if (attributes[SPDFMacMarkdownDestinationAttribute] ||
                attributes[SPDFMacMarkdownWikiDestinationAttribute]) {
                if (!line) {
                    NSAttributedString* lineString =
                        [attributedString attributedSubstringFromRange:fragment.attributedRange];
                    line = SPDFMarkdownCreateFragmentLine(lineString);
                }
                CFIndex start = (CFIndex)(effective.location - fragment.attributedRange.location);
                CFIndex end = (CFIndex)(NSMaxRange(effective) - fragment.attributedRange.location);
                CGFloat x0 = CTLineGetOffsetForStringIndex(line, start, NULL) * fragment.scale;
                CGFloat x1 = CTLineGetOffsetForStringIndex(line, end, NULL) * fragment.scale;
                NSRect linkRect =
                    NSMakeRect(NSMinX(pageFrame) + NSMinX(printable) + fragment.xOffset + MIN(x0, x1),
                               NSMinY(pageFrame) + self.plan.configuration.topContentInset + fragment.pageYOffset,
                               fabs(x1 - x0), fragment.height);
                if (!NSIsEmptyRect(linkRect)) [linkRects addObject:[NSValue valueWithRect:linkRect]];
            }
            cursor = NSMaxRange(effective);
        }
        if (line) CFRelease(line);
    }
    return linkRects;
}

// Whether a click at `point` (canvas coordinates) is ON a link: inside one of
// the link rects above, with the same 2pt slop the hover hand uses. The click
// path used to map the point to the horizontally NEAREST fragment in its band
// and read the destination at that character -- fine in running text, but a
// table row's cells share one band, so a click in the empty part of the left
// cell resolved to the link cell's first character and opened the link from
// half a row away. Hand and click now agree on where a link is.
- (BOOL)pointIsOnLink:(NSPoint)point {
    NSInteger pageIndex = [self pageIndexForVisibleRect:NSMakeRect(point.x, point.y, 1.0, 1.0)];
    if (pageIndex < 0 || pageIndex >= (NSInteger)self.pageCount) return NO;
    NSRect pageFrame = [self frameForPageAtIndex:(NSUInteger)pageIndex];
    for (NSValue* value in [self linkRectsForPage:self.plan.pages[(NSUInteger)pageIndex] pageFrame:pageFrame]) {
        if (NSPointInRect(point, NSInsetRect(value.rectValue, -2.0, -2.0))) return YES;
    }
    return NO;
}

// One pill of the chrome row: the theme's quiet code-control fill, hairline
// stroke and muted text, so both controls read as the same control in both
// reading themes. Skips an empty rect (a header band too narrow for two).
- (void)drawCodeControlTitle:(NSString*)title inRect:(NSRect)controlRect theme:(SPDFMarkdownTheme*)theme {
    if (NSIsEmptyRect(controlRect)) return;
    NSBezierPath* path = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(controlRect, 0.5, 0.5)
                                                        xRadius:kSPDFMarkdownCodeControlCornerRadius
                                                        yRadius:kSPDFMarkdownCodeControlCornerRadius];
    [theme.codeControlFillColor setFill];
    [path fill];
    [theme.codeControlStrokeColor setStroke];
    path.lineWidth = 1.0;
    [path stroke];
    NSDictionary* attributes = SPDFCodeControlTitleAttributes(theme);
    NSSize titleSize = [title sizeWithAttributes:attributes];
    [title drawAtPoint:NSMakePoint(round(NSMidX(controlRect) - titleSize.width * 0.5),
                                   round(NSMidY(controlRect) - titleSize.height * 0.5))
        withAttributes:attributes];
}

- (void)drawCodeBoxControlsOnPage:(SPDFMarkdownPage*)page pageFrame:(NSRect)pageFrame {
    SPDFMarkdownTheme* theme = self.pageTheme;
    for (SPDFMarkdownPageFragment* fragment in page.fragments) {
        if (fragment.itemIndex >= self.plan.items.count) continue;
        SPDFMarkdownPaginationItem* item = self.plan.items[fragment.itemIndex];
        if (item.kind != SPDFMarkdownBlockKindCode || fragment.isContinuation) continue;
        [self drawCodeControlTitle:[self copyCodeControlTitleForBlockIndex:fragment.blockIndex]
                            inRect:[self copyCodeControlRectForFragment:fragment pageFrame:pageFrame]
                             theme:theme];
        [self drawCodeControlTitle:[self codeLanguageControlTitleForBlockIndex:fragment.blockIndex]
                            inRect:[self codeLanguageControlRectForFragment:fragment pageFrame:pageFrame]
                             theme:theme];
    }
}

@end
