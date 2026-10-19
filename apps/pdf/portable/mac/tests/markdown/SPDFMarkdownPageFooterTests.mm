// The sheet footer: "Page 2 of 10", right-aligned in the bottom margin of
// every drawn Markdown page. It is drawn with the page rather than typeset into
// the canonical string, so the only way to see it is to look at the paper --
// these tests rasterize sheets and count ink.

#import <Cocoa/Cocoa.h>

#import "SPDFMarkdownPaginator.h"
#import "SPDFMarkdownTestSupport.h"

// A paragraph of `count` lines, each `height` tall. Two lines of three-quarters
// of a page each land on two pages; one over-tall line would be scaled onto
// one sheet instead of split, which is not the fixture wanted here.
static SPDFMarkdownPaginationItem* SPDFParagraphOfLines(NSUInteger count, CGFloat height) {
    NSMutableArray<SPDFMarkdownTextLine*>* lines = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; ++i) {
        [lines addObject:[[SPDFMarkdownTextLine alloc] initWithAttributedRange:NSMakeRange(i, 1)
                                                                        height:height
                                                                       xOffset:0
                                                                baselineOffset:height * 0.8]];
    }
    return [[SPDFMarkdownPaginationItem alloc] initWithBlockIndex:1
                                                             kind:SPDFMarkdownBlockKindParagraph
                                                     headingLevel:0
                                                            lines:lines];
}

// Counts the pixels inside `region` (bitmap coordinates, origin top-left) that
// are not the paper colour. The attributed string is empty, so no fragment can
// draw: whatever ink appears is the footer's.
static NSUInteger SPDFInkedPixels(SPDFMarkdownPaginationPlan* plan, NSUInteger pageIndex, NSRect region) {
    size_t width = (size_t)plan.configuration.paperSize.width;
    size_t height = (size_t)plan.configuration.paperSize.height;
    unsigned char* pixels = (unsigned char*)calloc(width * height, 4);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context =
        CGBitmapContextCreate(pixels, width, height, 8, width * 4, space, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    NSUInteger inked = 0;
    if (context) {
        [plan drawPageAtIndex:pageIndex
             attributedString:[[NSAttributedString alloc] initWithString:@""]
                    inContext:context];
        unsigned char* paper = pixels;  // the top-left corner is never written on
        for (size_t y = (size_t)NSMinY(region); y < (size_t)NSMaxY(region) && y < height; ++y) {
            for (size_t x = (size_t)NSMinX(region); x < (size_t)NSMaxX(region) && x < width; ++x) {
                unsigned char* p = pixels + (y * width + x) * 4;
                if (p[0] != paper[0] || p[1] != paper[1] || p[2] != paper[2]) ++inked;
            }
        }
        CGContextRelease(context);
    }
    free(pixels);
    return inked;
}

int main(void) {
    @autoreleasepool {
        SPDFExpect([SPDFMarkdownPageFooterText(1, 10) isEqualToString:@"Page 2 of 10"],
                   @"the footer counts pages the way a reader does");
        SPDFExpect([SPDFMarkdownPageFooterText(0, 1) isEqualToString:@"Page 1 of 1"],
                   @"a single sheet still says which page it is");

        // Two A4 sheets carrying nothing but the footer, in both themes: ink in
        // the bottom-right of the margin, none along the bottom-left, none past
        // the printable edge (right-aligned means it ends there), on every page.
        SPDFMarkdownPaginator* paginator = [SPDFMarkdownPaginator new];
        for (NSNumber* variant in @[ @(SPDFMarkdownThemeVariantLight), @(SPDFMarkdownThemeVariantDark) ]) {
            SPDFMarkdownPageConfiguration* a4 = SPDFMarkdownPageConfiguration.A4PortraitConfiguration;
            a4.themeVariant = (SPDFMarkdownThemeVariant)variant.integerValue;
            SPDFMarkdownPaginationPlan* twoPages =
                [paginator paginateItems:@[ SPDFParagraphOfLines(2, NSHeight(a4.printableRect) * 0.75) ]
                           configuration:a4];
            SPDFExpect(twoPages.pages.count == 2, @"the fixture paginates onto two sheets");
            CGFloat paperW = a4.paperSize.width;
            CGFloat marginHeight = NSMinY(a4.printableRect);
            CGFloat marginTop = a4.paperSize.height - marginHeight;  // first bitmap row of the bottom margin
            NSRect right = NSMakeRect(paperW / 2.0, marginTop, NSMaxX(a4.printableRect) - paperW / 2.0, marginHeight);
            NSRect left = NSMakeRect(0, marginTop, paperW / 2.0, marginHeight);
            NSRect beyond = NSMakeRect(NSMaxX(a4.printableRect) + 1, marginTop,
                                       paperW - NSMaxX(a4.printableRect) - 1, marginHeight);
            for (NSUInteger page = 0; page < twoPages.pages.count; ++page) {
                SPDFExpect(SPDFInkedPixels(twoPages, page, right) > 40,
                           @"the footer is drawn in the bottom-right of the margin");
                SPDFExpect(SPDFInkedPixels(twoPages, page, left) == 0, @"nothing is drawn along the bottom-left");
                SPDFExpect(SPDFInkedPixels(twoPages, page, beyond) == 0, @"the footer stops at the printable edge");
            }
            // The two pages say different things: their ink cannot be identical.
            SPDFExpect(SPDFInkedPixels(twoPages, 0, right) != SPDFInkedPixels(twoPages, 1, right),
                       @"page 1 and page 2 carry different footers");
        }

        // A page too short to have a margin (the paginator's own 100x100 test
        // page) gets no footer rather than one drawn over the content.
        SPDFMarkdownPageConfiguration* tiny =
            [SPDFMarkdownPageConfiguration configurationForPaperSize:NSMakeSize(100, 100)
                                                       printableRect:NSMakeRect(0, 0, 100, 100)];
        SPDFMarkdownPaginationPlan* one = [paginator paginateItems:@[ SPDFParagraphOfLines(1, 20) ]
                                                     configuration:tiny];
        SPDFExpect(SPDFInkedPixels(one, 0, NSMakeRect(0, 0, 100, 100)) == 0, @"no margin, no footer");
    }
    return SPDFFinishTests(@"SPDFMarkdownPageFooterTests");
}
