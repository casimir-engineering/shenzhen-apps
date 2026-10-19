// Where a link in a table can be clicked. The hover hand always used the exact
// link rects; the click mapped the point to the horizontally nearest fragment
// in the row band and read the destination there, so the empty part of the
// left cell -- from past its text to the link cell -- opened the link. Hand and
// click must agree: on the link text, and nowhere else in the row.

#import <Cocoa/Cocoa.h>

#import "../SPDFMacMarkdownPageCanvasPrivate.h"
#import "../SPDFMacMarkdownView.h"
#import "../markdown/SPDFMarkdown.h"

static int gFailures;
static void Expect(BOOL condition, const char* what) {
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", what);
    ++gFailures;
}

int main(void) {
    @autoreleasepool {
        (void)NSApplication.sharedApplication;
        NSString* source = @"# T\n\n| Where | Link |\n| --- | --- |\n"
                           @"| In a cell with some words | [table link](https://example.com) |\n";
        SPDFMarkdownDocumentModel* model = [[SPDFMarkdownParser new] parseString:source sourceURL:nil error:nil];
        SPDFMarkdownRenderedDocument* rendered =
            [[SPDFMarkdownRenderer new] renderModel:model
                                            options:[SPDFMarkdownRenderOptions defaultOptions]
                                  languageOverrides:nil];
        NSAttributedString* interactive = SPDFMacMarkdownInteractiveString(model, rendered);
        SPDFMarkdownPageConfiguration* configuration = [SPDFMarkdownPageConfiguration A4PortraitConfiguration];
        SPDFMarkdownPaginator* paginator = [SPDFMarkdownPaginator new];
        SPDFMarkdownPaginationPlan* plan =
            [paginator paginateItems:[paginator measureRenderedDocument:rendered
                                                         containerWidth:NSWidth(configuration.printableRect)]
                       configuration:configuration];
        SPDFMacMarkdownPageCanvas* canvas =
            [[SPDFMacMarkdownPageCanvas alloc] initWithPaginationPlan:plan attributedString:interactive];
        [canvas resizeForWidth:800];
        NSRect pageFrame = [canvas frameForPageAtIndex:0];
        NSArray<NSValue*>* links = [canvas linkRectsForPage:plan.pages.firstObject pageFrame:pageFrame];
        Expect(links.count == 1, "the row has exactly one link rect");
        NSRect link = links.firstObject.rectValue;

        // The left cell's fragment: its text, and the empty run after it.
        SPDFMarkdownPageFragment* leftCell = nil;
        for (SPDFMarkdownPageFragment* fragment in plan.pages.firstObject.fragments)
            if ([[interactive.string substringWithRange:fragment.attributedRange] hasPrefix:@"In a cell"])
                leftCell = fragment;
        Expect(leftCell != nil, "the left cell is laid out as its own fragment");
        CGFloat rowMidY = NSMidY(link);
        CGFloat leftTextStartX = NSMinX(pageFrame) + NSMinX(configuration.printableRect) + leftCell.xOffset;

        // On the link text: a link.
        Expect([canvas pointIsOnLink:NSMakePoint(NSMidX(link), rowMidY)], "the middle of the link text is a link");
        // Just left of the link, in the gap before the link cell's text: not a link.
        Expect(![canvas pointIsOnLink:NSMakePoint(NSMinX(link) - 12.0, rowMidY)],
               "the space just left of the link is not a link");
        // Halfway between the left cell's text and the link -- the region the
        // nearest-fragment click used to hand to the link: not a link.
        Expect(![canvas pointIsOnLink:NSMakePoint((leftTextStartX + NSMinX(link)) / 2.0 + 30.0, rowMidY)],
               "the empty part of the left cell is not a link");
        // Inside the left cell's own words: not a link.
        Expect(![canvas pointIsOnLink:NSMakePoint(leftTextStartX + 10.0, rowMidY)],
               "the left cell's text is not a link");
        // Empty space nearer the link cell than the left cell's text: not a link
        // either -- yet the nearest-fragment index resolves it to the link's first
        // character, which is exactly why the click has to check the rect first.
        Expect(![canvas pointIsOnLink:NSMakePoint(NSMinX(link) - 3.0, rowMidY)],
               "the empty space just before the link cell is not a link");
        NSUInteger reach = [canvas characterIndexAtPoint:NSMakePoint(NSMinX(link) - 3.0, rowMidY)];
        Expect(reach != NSNotFound &&
                   [interactive attribute:SPDFMacMarkdownDestinationAttribute atIndex:reach effectiveRange:NULL] != nil,
               "the nearest-fragment index alone would have reached the link (the bug this guards)");

        if (gFailures == 0) puts("SPDFMacMarkdownLinkHitTests passed");
    }
    return gFailures == 0 ? 0 : 1;
}
