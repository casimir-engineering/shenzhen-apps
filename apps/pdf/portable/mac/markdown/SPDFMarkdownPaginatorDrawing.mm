#import "SPDFMarkdownPaginator.h"
#import "SPDFMarkdownImageRecolor.h"

#import <CoreText/CoreText.h>

#import "SPDFMarkdownDiagramBand.h"
#import "SPDFMarkdownTableDecorations.h"

// Concrete-palette drawing of a planned page into any Core Graphics context
// (screen page canvas, print, PDF export, copy-page). Kept beside the
// paginator: it consumes exactly the fragments and decoration geometry the
// plan produced, so every consumer stays page-for-page identical.

typedef struct {
    CGFloat ascent;
    CGFloat descent;
    CGFloat width;
} SPDFAttachmentRunMetrics;

static void SPDFAttachmentRunDealloc(void* metrics) { free(metrics); }
static CGFloat SPDFAttachmentRunAscent(void* metrics) { return ((SPDFAttachmentRunMetrics*)metrics)->ascent; }
static CGFloat SPDFAttachmentRunDescent(void* metrics) { return ((SPDFAttachmentRunMetrics*)metrics)->descent; }
static CGFloat SPDFAttachmentRunWidth(void* metrics) { return ((SPDFAttachmentRunMetrics*)metrics)->width; }

// See SPDFMarkdownPaginator.h: the one shared CTLine constructor for fragment
// substrings. NSTextAttachment runs get a CTRunDelegate mirroring their bounds
// so CoreText advances agree with the NSLayoutManager measurement pass.
CTLineRef SPDFMarkdownCreateFragmentLine(NSAttributedString* lineString) {
    __block NSMutableAttributedString* adjusted = nil;
    [lineString enumerateAttribute:NSAttachmentAttributeName
                           inRange:NSMakeRange(0, lineString.length)
                           options:0
                        usingBlock:^(NSTextAttachment* attachment, NSRange range, BOOL* stop) {
                          (void)stop;
                          if (!attachment) return;
                          NSRect bounds = attachment.bounds;
                          if (bounds.size.width <= 0 || bounds.size.height <= 0) bounds.size = attachment.image.size;
                          if (bounds.size.width <= 0 || bounds.size.height <= 0) return;
                          SPDFAttachmentRunMetrics* metrics =
                              (SPDFAttachmentRunMetrics*)malloc(sizeof(SPDFAttachmentRunMetrics));
                          if (!metrics) return;
                          metrics->ascent = MAX(0.0, NSMaxY(bounds));
                          metrics->descent = MAX(0.0, -NSMinY(bounds));
                          metrics->width = bounds.size.width;
                          CTRunDelegateCallbacks callbacks = {
                              .version = kCTRunDelegateVersion1,
                              .dealloc = SPDFAttachmentRunDealloc,
                              .getAscent = SPDFAttachmentRunAscent,
                              .getDescent = SPDFAttachmentRunDescent,
                              .getWidth = SPDFAttachmentRunWidth,
                          };
                          CTRunDelegateRef delegate = CTRunDelegateCreate(&callbacks, metrics);
                          if (!delegate) {
                              free(metrics);
                              return;
                          }
                          if (!adjusted) adjusted = [lineString mutableCopy];
                          // The attributed string retains the delegate; the
                          // delegate frees its metrics on its own dealloc.
                          [adjusted addAttribute:(__bridge NSAttributedStringKey)kCTRunDelegateAttributeName
                                           value:(__bridge id)delegate
                                           range:range];
                          CFRelease(delegate);
                        }];
    return CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)(adjusted ?: lineString));
}

static void SPDFDrawAttachments(NSAttributedString* lineString, CTLineRef line, CGContextRef context, CGFloat lineX,
                                CGFloat baselineY, CGFloat lineHeight, CGFloat baselineOffset,
                                BOOL recolorsImages) {
    [lineString enumerateAttribute:NSAttachmentAttributeName
                           inRange:NSMakeRange(0, lineString.length)
                           options:0
                        usingBlock:^(id value, NSRange range, BOOL* stop) {
                          (void)stop;
                          NSTextAttachment* attachment = value;
                          NSImage* image = attachment.image;
                          if (!image || range.length == 0) return;
                          NSRect bounds = attachment.bounds;
                          if (bounds.size.width <= 0 || bounds.size.height <= 0) {
                              bounds.size = image.size;
                          }
                          if (bounds.size.width <= 0 || bounds.size.height <= 0) return;
                          NSRect proposed = NSMakeRect(0, 0, bounds.size.width, bounds.size.height);
                          CGImageRef CGImage = [image CGImageForProposedRect:&proposed context:nil hints:nil];
                          if (!CGImage) return;
                          if (recolorsImages) {
                              // A Markdown page never passes through the core's
                              // render tail, where a PDF's images are recolored,
                              // so the same luma remap is applied here.
                              CGImageRef darkened =
                                  SPDFMarkdownDarkRecoloredImageForAttachment(attachment, CGImage);
                              if (darkened) CGImage = darkened;
                          }
                          CGFloat offset = CTLineGetOffsetForStringIndex(line, (CFIndex)range.location, NULL);
                          CGFloat fragmentBottom = baselineY + baselineOffset - lineHeight;
                          CGFloat fragmentTop = baselineY + baselineOffset;
                          CGFloat drawHeight = MIN(bounds.size.height, lineHeight);
                          CGFloat drawWidth = bounds.size.width * drawHeight / bounds.size.height;
                          CGFloat desiredBottom = baselineY + bounds.origin.y;
                          CGFloat attachmentBottom = MIN(MAX(desiredBottom, fragmentBottom), fragmentTop - drawHeight);
                          CGRect destination =
                              CGRectMake(lineX + offset + bounds.origin.x, attachmentBottom, drawWidth, drawHeight);
                          CGContextSaveGState(context);
                          CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
                          CGContextDrawImage(context, destination, CGImage);
                          CGContextRestoreGState(context);
                        }];
}

// Resolves one attributed-string color to a concrete sRGB value safe on the
// theme's paper. The luminance guard protects the export from an
// appearance-dynamic color sneaking in: on light paper anything resolving
// near-white falls back to the theme role; on dark paper anything resolving
// near-black does.
static NSColor* SPDFConcretePrintColor(NSColor* color, NSColor* fallback, SPDFMarkdownThemeVariant variant) {
    __block NSColor* converted = nil;
    NSAppearance* appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    [appearance performAsCurrentDrawingAppearance:^{
      converted = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    }];
    if (!converted) return fallback;
    CGFloat red = converted.redComponent;
    CGFloat green = converted.greenComponent;
    CGFloat blue = converted.blueComponent;
    CGFloat luminance = red * 0.2126 + green * 0.7152 + blue * 0.0722;
    if (variant == SPDFMarkdownThemeVariantDark ? luminance < 0.1 : luminance > 0.85) return fallback;
    return [NSColor colorWithSRGBRed:red green:green blue:blue alpha:converted.alphaComponent];
}

static NSAttributedString* SPDFPrintableLine(NSAttributedString* source, SPDFMarkdownTheme* theme) {
    NSMutableAttributedString* result = [source mutableCopy];
    NSRange all = NSMakeRange(0, result.length);
    [result enumerateAttribute:NSForegroundColorAttributeName
                       inRange:all
                       options:0
                    usingBlock:^(NSColor* color, NSRange range, BOOL* stop) {
                      (void)stop;
                      NSColor* concrete = SPDFConcretePrintColor(color ?: theme.bodyTextColor, theme.bodyTextColor,
                                                                 theme.variant);
                      [result addAttribute:NSForegroundColorAttributeName value:concrete range:range];
                    }];
    [result enumerateAttribute:NSBackgroundColorAttributeName
                       inRange:all
                       options:0
                    usingBlock:^(NSColor* color, NSRange range, BOOL* stop) {
                      (void)stop;
                      if (!color) return;
                      NSColor* concrete = SPDFConcretePrintColor(color, theme.inlineCodeChipColor, theme.variant);
                      [result addAttribute:NSBackgroundColorAttributeName value:concrete range:range];
                    }];
    return result;
}

static void SPDFSetContextColor(CGContextRef context, NSColor* color, BOOL stroke) {
    NSColor* sRGB = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace] ?: NSColor.blackColor;
    if (stroke) {
        CGContextSetRGBStrokeColor(context, sRGB.redComponent, sRGB.greenComponent, sRGB.blueComponent,
                                   sRGB.alphaComponent);
    } else {
        CGContextSetRGBFillColor(context, sRGB.redComponent, sRGB.greenComponent, sRGB.blueComponent,
                                 sRGB.alphaComponent);
    }
}

@implementation SPDFMarkdownPaginationPlan (SPDFDrawing)

// Every consumer paints the plan's concrete theme palette (the
// configuration's themeVariant): rounded code boxes and heading/thematic-break
// rules, drawn beneath the planned text lines. Light stays byte-identical to
// the historical #F6F8FA/#D0D7DE boxes and #D1D9E0 rules.
- (void)spdf_drawDecorationsForPageIndex:(NSUInteger)pageIndex inContext:(CGContextRef)context {
    SPDFMarkdownTheme* theme = [SPDFMarkdownTheme themeForVariant:self.configuration.themeVariant];
    CGFloat printableLeft = NSMinX(self.configuration.printableRect);
    CGFloat printableTop = self.configuration.paperSize.height - self.configuration.topContentInset;
    for (SPDFMarkdownPageDecoration* decoration in [self decorationsForPageIndex:pageIndex]) {
        CGRect rect = CGRectMake(printableLeft + NSMinX(decoration.rect), printableTop - NSMaxY(decoration.rect),
                                 NSWidth(decoration.rect), NSHeight(decoration.rect));
        if (decoration.type == SPDFMarkdownPageDecorationTypeCodeBox) {
            CGRect boxRect = CGRectInset(rect, 0.5, 0.5);
            if (boxRect.size.width <= 0 || boxRect.size.height <= 0) continue;
            CGFloat radius = MIN(6, MIN(boxRect.size.width, boxRect.size.height) / 2);
            CGPathRef path = CGPathCreateWithRoundedRect(boxRect, radius, radius, NULL);
            SPDFSetContextColor(context, theme.codeBoxFillColor, NO);
            CGContextAddPath(context, path);
            CGContextFillPath(context);
            SPDFSetContextColor(context, theme.codeBoxStrokeColor, YES);
            CGContextSetLineWidth(context, 1);
            CGContextAddPath(context, path);
            CGContextStrokePath(context);
            CGPathRelease(path);
        } else if (decoration.type == SPDFMarkdownPageDecorationTypeDiagram) {
            // Native diagram artwork: pure vector paths in the plan's palette,
            // crisp at any zoom and vector in the PDF. Its labels are ordinary
            // canonical text and are painted by the text pass below.
            SPDFMarkdownDrawDiagramShapes(context, decoration.diagramLayout, rect, theme.variant);
        } else if (decoration.type == SPDFMarkdownPageDecorationTypeTableHeaderBand ||
                   decoration.type == SPDFMarkdownPageDecorationTypeTableStripe ||
                   decoration.type == SPDFMarkdownPageDecorationTypeTableGridLine) {
            SPDFMarkdownDrawTableDecoration(context, decoration.type, rect, theme);
        } else {
            NSColor* ruleColor = decoration.type == SPDFMarkdownPageDecorationTypeThematicBreakRule
                                     ? theme.thematicBreakRuleColor
                                     : theme.headingRuleColor;
            SPDFSetContextColor(context, ruleColor, NO);
            CGContextFillRect(context, rect);
        }
    }
}

NSString* SPDFMarkdownPageFooterText(NSUInteger pageIndex, NSUInteger pageCount) {
    return [NSString stringWithFormat:@"Page %lu of %lu", (unsigned long)pageIndex + 1, (unsigned long)pageCount];
}

// The sheet's footer: "Page 2 of 10", right-aligned to the printable edge and
// centred in the bottom margin, in the muted caption tint. Drawn here, with the
// page, so the screen, Print, Save as PDF and Copy Page all carry the same
// footer -- and drawn, not typeset into the canonical string, so it is neither
// searchable nor selectable and cannot shift a page break.
static void SPDFDrawPageFooter(SPDFMarkdownPageConfiguration* configuration, SPDFMarkdownTheme* theme,
                               NSUInteger pageIndex, NSUInteger pageCount, CGContextRef context) {
    NSRect printable = configuration.printableRect;
    CGFloat bottomMargin = NSMinY(printable);
    if (bottomMargin < 12.0) return;  // no margin to write in (test-sized pages)
    CGFloat fontSize = 9.0;
    NSAttributedString* text = [[NSAttributedString alloc]
        initWithString:SPDFMarkdownPageFooterText(pageIndex, pageCount)
            attributes:@{
                NSFontAttributeName : [NSFont systemFontOfSize:fontSize],
                NSForegroundColorAttributeName : theme.secondaryTextColor
            }];
    CTLineRef line = CTLineCreateWithAttributedString((CFAttributedStringRef)text);
    CGFloat ascent = 0, descent = 0;
    double width = CTLineGetTypographicBounds(line, &ascent, &descent, NULL);
    CGContextSaveGState(context);
    CGContextSetTextMatrix(context, CGAffineTransformIdentity);
    // Centre the glyph box (ascent above, descent below) on the margin's midline.
    CGContextSetTextPosition(context, NSMaxX(printable) - width, bottomMargin / 2.0 - (ascent - descent) / 2.0);
    CTLineDraw(line, context);
    CGContextRestoreGState(context);
    CFRelease(line);
}

- (BOOL)drawPageAtIndex:(NSUInteger)pageIndex
       attributedString:(NSAttributedString*)attributedString
              inContext:(CGContextRef)context {
    if (pageIndex >= self.pages.count || !context) return NO;
    SPDFMarkdownPage* page = self.pages[pageIndex];
    SPDFMarkdownTheme* theme = [SPDFMarkdownTheme themeForVariant:self.configuration.themeVariant];
    // Dark paper recolors embedded images unless the reader asked to keep their
    // colors. Light plans -- print, export, copy-page -- never recolor.
    BOOL recolorsImages = self.configuration.themeVariant == SPDFMarkdownThemeVariantDark &&
                          !self.configuration.preservesImageColors;
    CGFloat paperHeight = self.configuration.paperSize.height;
    CGFloat printableTop = paperHeight - self.configuration.topContentInset;
    CGContextSaveGState(context);
    SPDFSetContextColor(context, theme.paperColor, NO);
    CGContextFillRect(context, CGRectMake(0, 0, self.configuration.paperSize.width, paperHeight));
    [self spdf_drawDecorationsForPageIndex:pageIndex inContext:context];
    SPDFDrawPageFooter(self.configuration, theme, pageIndex, self.pages.count, context);
    CGContextSetTextMatrix(context, CGAffineTransformIdentity);
    for (SPDFMarkdownPageFragment* fragment in page.fragments) {
        if (NSMaxRange(fragment.attributedRange) > attributedString.length) continue;
        NSAttributedString* substring =
            SPDFPrintableLine([attributedString attributedSubstringFromRange:fragment.attributedRange], theme);
        CTLineRef line = SPDFMarkdownCreateFragmentLine(substring);
        CGFloat x = NSMinX(self.configuration.printableRect) + fragment.xOffset;
        CGFloat y = printableTop - fragment.pageYOffset - fragment.baselineOffset;
        CGContextSaveGState(context);
        CGContextTranslateCTM(context, x, y);
        CGContextScaleCTM(context, fragment.scale, fragment.scale);
        CGContextSetTextPosition(context, 0, 0);
        CTLineDraw(line, context);
        CGFloat localScale = MAX(fragment.scale, 0.001);
        SPDFDrawAttachments(substring, line, context, 0, 0, fragment.height / localScale,
                            fragment.baselineOffset / localScale, recolorsImages);
        CGContextRestoreGState(context);
        CFRelease(line);
    }
    CGContextRestoreGState(context);
    return YES;
}
@end
