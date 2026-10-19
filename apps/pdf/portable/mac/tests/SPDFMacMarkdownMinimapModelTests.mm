#import <AppKit/AppKit.h>

#import "../SPDFMacMarkdownMinimapModel.h"

#include <assert.h>
#include <stdio.h>

@interface SPDFMacMarkdownMinimapModel (SPDFTestRendering)
- (NSImage*)renderThumbnailForPageIndex:(NSUInteger)pageIndex pixelSize:(NSSize)pixelSize;
@end

@interface SPDFTestMarkdownMinimapModel : SPDFMacMarkdownMinimapModel
@property(atomic) BOOL renderedOffMainThread;
@end

@implementation SPDFTestMarkdownMinimapModel
- (NSImage*)renderThumbnailForPageIndex:(NSUInteger)pageIndex pixelSize:(NSSize)pixelSize {
    self.renderedOffMainThread = !NSThread.isMainThread;
    return [super renderThumbnailForPageIndex:pageIndex pixelSize:pixelSize];
}
@end

static SPDFMarkdownPaginationPlan* SPDFCreatePlan(NSAttributedString** attributedString) {
    NSMutableAttributedString* text = [NSMutableAttributedString new];
    NSMutableArray<SPDFMarkdownPaginationItem*>* items = [NSMutableArray array];
    NSDictionary* attributes =
        @{NSFontAttributeName : [NSFont systemFontOfSize:14], NSForegroundColorAttributeName : NSColor.textColor};
    for (NSUInteger index = 0; index < 130; ++index) {
        NSString* line = [NSString stringWithFormat:@"Vector minimap line %lu\n", (unsigned long)index];
        NSRange range = NSMakeRange(text.length, line.length);
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:line attributes:attributes]];
        SPDFMarkdownTextLine* measured = [[SPDFMarkdownTextLine alloc] initWithAttributedRange:range
                                                                                        height:18
                                                                                       xOffset:0
                                                                                baselineOffset:14];
        [items addObject:[[SPDFMarkdownPaginationItem alloc] initWithBlockIndex:index
                                                                           kind:SPDFMarkdownBlockKindParagraph
                                                                   headingLevel:0
                                                                          lines:@[ measured ]]];
    }
    *attributedString = text;
    return [[SPDFMarkdownPaginator new] paginateItems:items
                                        configuration:SPDFMarkdownPageConfiguration.A4PortraitConfiguration];
}

static void SPDFWaitUntil(BOOL (^condition)(void)) {
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
    while (!condition() && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    assert(condition());
}

int main(void) {
    @autoreleasepool {
        (void)NSApplication.sharedApplication;
        NSAttributedString* string = nil;
        SPDFMarkdownPaginationPlan* plan = SPDFCreatePlan(&string);
        assert(plan.pages.count >= 3);
        SPDFTestMarkdownMinimapModel* model = [[SPDFTestMarkdownMinimapModel alloc] initWithPaginationPlan:plan
                                                                                          attributedString:string
                                                                            maximumThumbnailPixelDimension:160];

        assert(model.pages.count == plan.pages.count);
        assert(model.a4PageRects.count == plan.pages.count);
        NSSize paper = plan.configuration.paperSize;
        for (NSUInteger index = 0; index < model.pages.count; ++index) {
            SPDFRenderedPage* page = model.pages[index];
            NSRect rect = model.a4PageRects[index].rectValue;
            assert(page.pageIndex == (NSInteger)index);
            assert(NSEqualSizes(NSMakeSize(page.pageWidth, page.pageHeight), paper));
            assert(NSEqualRects(rect, NSMakeRect(0, index * paper.height, paper.width, paper.height)));
        }

        NSMutableArray<NSValue*>* supplied = [model.a4PageRects mutableCopy];
        supplied[0] = [NSValue valueWithRect:NSMakeRect(12, 20, 300, 420)];
        NSRect visible = NSMakeRect(10, 30, 280, 200);
        [model updateViewportPageRects:supplied
                           visibleRect:visible
                          documentSize:NSMakeSize(620, 1800)
                         documentScale:0.5];
        supplied[0] = [NSValue valueWithRect:NSZeroRect];
        assert(NSEqualRects(model.documentPageRects[0].rectValue, NSMakeRect(12, 20, 300, 420)));
        assert(NSEqualRects(model.documentVisibleRect, visible));
        assert(NSEqualSizes(model.documentSize, NSMakeSize(620, 1800)));
        assert(fabs(model.documentScale - 0.5) < 0.001);

        __block NSUInteger completionCount = 0;
        __block BOOL completionsOnMain = YES;
        __block NSImage* firstImage = nil;
        void (^completion)(SPDFRenderedPage*, NSImage*) = ^(SPDFRenderedPage* page, NSImage* image) {
          completionsOnMain = completionsOnMain && NSThread.isMainThread;
          assert(page.pageIndex == 0);
          assert(image != nil);
          if (!firstImage)
              firstImage = image;
          else
              assert(firstImage == image);
          ++completionCount;
        };
        [model requestThumbnailForPageIndex:0 targetPixelSize:NSMakeSize(4000, 4000) completion:completion];
        [model requestThumbnailForPageIndex:0 targetPixelSize:NSMakeSize(4000, 4000) completion:completion];
        assert(model.pendingThumbnailRequestCount == 1);
        SPDFWaitUntil(^BOOL {
          return completionCount == 2;
        });
        assert(model.renderedOffMainThread);
        assert(completionsOnMain);
        NSRect proposedRect = NSMakeRect(0, 0, firstImage.size.width, firstImage.size.height);
        CGImageRef thumbnailCGImage = [firstImage CGImageForProposedRect:&proposedRect context:nil hints:nil];
        assert(thumbnailCGImage != NULL);
        assert(CGImageGetWidth(thumbnailCGImage) <= 160 && CGImageGetHeight(thumbnailCGImage) <= 160);
        assert(model.pages[0].minimapImage == firstImage);

        __block BOOL cancelledCompletionCalled = NO;
        [model requestThumbnailForPageIndex:1
                            targetPixelSize:NSMakeSize(160, 160)
                                 completion:^(SPDFRenderedPage* page, NSImage* image) {
                                   (void)page;
                                   (void)image;
                                   cancelledCompletionCalled = YES;
                                 }];
        [model cancelThumbnailRequestForPageIndex:1];
        NSDate* cancellationDeadline = [NSDate dateWithTimeIntervalSinceNow:0.2];
        while (cancellationDeadline.timeIntervalSinceNow > 0)
            [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        assert(!cancelledCompletionCalled);
        assert(model.pendingThumbnailRequestCount == 0);

        // Search highlights publish per page in page-local points, and `pages`
        // is republished as a FRESH array of the same proxies so the minimap
        // strip cache (keyed on the pages array identity) invalidates.
        NSArray<SPDFRenderedPage*>* pagesBeforeHighlights = model.pages;
        NSRect firstRect = NSMakeRect(72, 90, 120, 16);
        NSRect thirdRect = NSMakeRect(60, 200, 80, 14);
        [model updateSearchHighlightRects:@{
            @0 : @[ [NSValue valueWithRect:firstRect] ],
            @2 : @[ [NSValue valueWithRect:thirdRect] ],
        }];
        assert(model.pages != pagesBeforeHighlights);
        assert(model.pages.count == pagesBeforeHighlights.count);
        for (NSUInteger index = 0; index < model.pages.count; ++index)
            assert(model.pages[index] == pagesBeforeHighlights[index]);
        assert(model.pages[0].highlights.count == 1 &&
               NSEqualRects(model.pages[0].highlights.firstObject.rectValue, firstRect));
        assert(model.pages[1].highlights.count == 0);
        assert(model.pages[2].highlights.count == 1 &&
               NSEqualRects(model.pages[2].highlights.firstObject.rectValue, thirdRect));
        assert(model.pages[0].minimapImage == firstImage); // proxies (and thumbnails) survive republication
        NSArray<SPDFRenderedPage*>* pagesWithHighlights = model.pages;
        [model updateSearchHighlightRects:nil];
        assert(model.pages != pagesWithHighlights);
        for (SPDFRenderedPage* page in model.pages) assert(page.highlights.count == 0);
        puts("SPDFMacMarkdownMinimapModelTests passed");
    }
    return 0;
}
