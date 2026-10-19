// Markdown paper orientation: what the rotate commands do to a Markdown
// document.
//
// A PDF page rotation turns rendered pixels. A Markdown document has no pixels
// of its own — it is text poured onto A4 — so the same command turns the PAPER
// and the document RE-FLOWS onto it, every glyph still upright. These tests
// pin that distinction at three levels: the page configuration's geometry, the
// session's re-pagination contract, and the exports, which follow the
// orientation only because it travels on the pagination plan they all consume.

#import <AppKit/AppKit.h>
#import <PDFKit/PDFKit.h>

#import "../SPDFMacMarkdownPrinting.h"
#import "../SPDFMacMarkdownSession.h"
#import "../markdown/SPDFMarkdown.h"

#include <assert.h>
#include <stdio.h>

static BOOL SpinUntil(BOOL (^condition)(void), NSTimeInterval timeout) {
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!condition() && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    return condition();
}

static NSString* WriteLongMarkdown(void) {
    NSMutableString* text = [NSMutableString stringWithString:@"# Orientation\n\n"];
    for (int paragraph = 1; paragraph <= 60; ++paragraph)
        [text appendFormat:@"Paragraph %d runs the width of the sheet and carries the document onward toward the "
                           @"next page break.\n\n",
                           paragraph];
    NSString* path = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"md"]];
    assert([text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    return path;
}

// Where each sheet ends, as an attributed location. This is the sequence that
// changes when a document RE-FLOWS onto different paper. Page COUNT alone is a
// weak signal: wider lines and a shorter page pull against each other and can
// land on the same total by coincidence.
static NSArray<NSNumber*>* PageBreakLocations(SPDFMarkdownPaginationPlan* plan) {
    NSMutableArray<NSNumber*>* breaks = [NSMutableArray array];
    for (SPDFMarkdownPage* page in plan.pages) {
        NSUInteger end = 0;
        for (SPDFMarkdownPageFragment* fragment in page.fragments)
            end = MAX(end, NSMaxRange(fragment.attributedRange));
        [breaks addObject:@(end)];
    }
    return breaks;
}

// ------------------------------------------------------- page configuration

static void TestConfigurationGeometry(NSString* path) {
    SPDFMarkdownPageConfiguration* portrait = SPDFMarkdownPageConfiguration.A4PortraitConfiguration;
    SPDFMarkdownPageConfiguration* landscape = SPDFMarkdownPageConfiguration.A4LandscapeConfiguration;

    // Turning the paper swaps the two EDGES and leaves the four MARGINS alone.
    // Transposing a margin with an edge is the classic way to end up with a
    // page that looks rotated instead of re-flowed.
    assert(fabs(landscape.paperSize.width - portrait.paperSize.height) < 0.001 &&
           fabs(landscape.paperSize.height - portrait.paperSize.width) < 0.001);
    assert(fabs(NSMinX(landscape.printableRect) - NSMinX(portrait.printableRect)) < 0.001);
    assert(fabs(NSMinY(landscape.printableRect) - NSMinY(portrait.printableRect)) < 0.001);
    assert(fabs(landscape.topContentInset - portrait.topContentInset) < 0.001);
    assert(fabs(landscape.paperSize.width - NSMaxX(landscape.printableRect) - NSMinX(landscape.printableRect)) <
           0.001);
    assert(NSWidth(landscape.printableRect) > NSWidth(portrait.printableRect));
    assert(NSHeight(landscape.printableRect) < NSHeight(portrait.printableRect));

    // Orientation is DERIVED from the paper, so no configuration — and no copy
    // of one — can disagree with the sheet it actually carries.
    assert(portrait.orientation == SPDFMarkdownPageOrientationPortrait);
    assert(landscape.orientation == SPDFMarkdownPageOrientationLandscape);
    SPDFMarkdownPageConfiguration* landscapeCopy = [landscape copy];
    assert(landscapeCopy.orientation == SPDFMarkdownPageOrientationLandscape);
    assert(fabs(landscapeCopy.paperSize.width - landscape.paperSize.width) < 0.001);
    // Everything else about the two sheets is the same page.
    assert(landscape.headingKeepThreshold == portrait.headingKeepThreshold);
    assert(landscape.includesCodeLanguageControlSpacing == portrait.includesCodeLanguageControlSpacing);
    // Both A4 factories route through the orientation one.
    assert(fabs([SPDFMarkdownPageConfiguration A4ConfigurationForOrientation:SPDFMarkdownPageOrientationLandscape]
                    .paperSize.width -
                landscape.paperSize.width) < 0.001);

    // A real document breaks in different places on the two sheets. Measured
    // at each orientation's printable width and paginated onto its paper: this
    // is a re-flow, which no canvas transform could produce.
    SPDFMarkdownDocument* document = [SPDFMarkdownDocument documentWithURL:[NSURL fileURLWithPath:path]
                                                                   options:nil
                                                                     error:nil];
    assert(document);
    SPDFMarkdownPaginator* paginator = [SPDFMarkdownPaginator new];
    SPDFMarkdownPaginationPlan* portraitPlan =
        [paginator paginateItems:[paginator measureRenderedDocument:document.renderedDocument
                                                     containerWidth:NSWidth(portrait.printableRect)]
                   configuration:portrait];
    SPDFMarkdownPaginationPlan* landscapePlan =
        [paginator paginateItems:[paginator measureRenderedDocument:document.renderedDocument
                                                     containerWidth:NSWidth(landscape.printableRect)]
                   configuration:landscape];
    assert(portraitPlan.pages.count > 1 && landscapePlan.pages.count > 1);
    assert(![PageBreakLocations(landscapePlan) isEqualToArray:PageBreakLocations(portraitPlan)]);
    assert(landscapePlan.configuration.orientation == SPDFMarkdownPageOrientationLandscape);
    assert(fabs(landscapePlan.configuration.paperSize.width - landscape.paperSize.width) < 0.001);
}

// ------------------------------------------------------- session lifecycle

static void ActivateSession(SPDFMacMarkdownSession* session, NSView* host, dispatch_queue_t queue, CGFloat zoom,
                            SPDFMacMarkdownPageFitMode fit) {
    __block BOOL activated = NO;
    [session activateInHostView:host
                      workQueue:queue
                   scrollOrigin:NSZeroPoint
                  selectedRange:NSMakeRange(0, 0)
                      pageIndex:0
                           zoom:zoom
                        fitMode:fit
                         anchor:nil
                     completion:^(BOOL success, NSError* error) {
                       assert(success && !error);
                       activated = YES;
                     }];
    assert(SpinUntil(
        ^BOOL {
          return activated && session.paginationPlan != nil;
        },
        15.0));
}

// applyPageOrientation: is the third member of the applyFontScale: /
// applyThemeVariant: family: one viewport-preserving re-pagination for an
// active session, a no-op on an equal value, and a silent catch-up on
// activation when the paper changed while the session was inactive.
static void TestSessionContract(NSString* path, NSView* host, dispatch_queue_t queue) {
    SPDFMacMarkdownSession* session =
        [[SPDFMacMarkdownSession alloc] initWithDocumentURL:[NSURL fileURLWithPath:path]];
    ActivateSession(session, host, queue, 1.6, SPDFMacMarkdownPageFitCustom);

    __block NSUInteger paperRenders = 0;
    session.statusHandler = ^(NSString* status) {
      if ([status hasPrefix:@"Text pages are now "]) paperRenders++;
    };
    assert(session.pageOrientation == SPDFMarkdownPageOrientationPortrait);
    assert(session.paginationPlan.configuration.orientation == SPDFMarkdownPageOrientationPortrait);
    NSSize uprightPaper = session.paginationPlan.configuration.paperSize;

    [session applyPageOrientation:SPDFMarkdownPageOrientationLandscape];
    assert(session.pageOrientation == SPDFMarkdownPageOrientationLandscape);
    assert(SpinUntil(
        ^BOOL {
          return paperRenders == 1 &&
                 session.paginationPlan.configuration.orientation == SPDFMarkdownPageOrientationLandscape;
        },
        10.0));
    assert(fabs(session.paginationPlan.configuration.paperSize.width - uprightPaper.height) < 0.01 &&
           fabs(session.paginationPlan.configuration.paperSize.height - uprightPaper.width) < 0.01);
    // Orientation is independent of the theme: a light session stays light on
    // turned paper.
    assert(session.paginationPlan.configuration.themeVariant == SPDFMarkdownThemeVariantLight);
    // Fit mode and custom zoom survive the re-flow, like every other
    // viewport-preserving rerender.
    assert(SpinUntil(
        ^BOOL {
          return session.fitMode == SPDFMacMarkdownPageFitCustom && fabs(session.zoom - 1.6) < 0.01;
        },
        10.0));

    SPDFMarkdownRenderedDocument* turnedBeforeNoop = session.renderedDocument;
    [session applyPageOrientation:SPDFMarkdownPageOrientationLandscape]; // equal value: no rerender
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
    assert(paperRenders == 1 && session.renderedDocument == turnedBeforeNoop);

    // Turned back while DEACTIVATED: adopted silently, re-paginated on the next
    // activation, and the catch-up reports no status of its own.
    [session deactivate];
    [session applyPageOrientation:SPDFMarkdownPageOrientationPortrait];
    assert(session.pageOrientation == SPDFMarkdownPageOrientationPortrait);
    assert(session.renderedDocument == turnedBeforeNoop); // nothing rendered while inactive
    assert(session.paginationPlan.configuration.orientation == SPDFMarkdownPageOrientationLandscape);
    ActivateSession(session, host, queue, 1.6, SPDFMacMarkdownPageFitCustom);
    assert(SpinUntil(
        ^BOOL {
          return session.paginationPlan.configuration.orientation == SPDFMarkdownPageOrientationPortrait;
        },
        10.0));
    assert(paperRenders == 1);
    [session deactivate];
}

// Turning the paper re-anchors on CONTENT, not on a scroll offset: the document
// re-flows onto differently shaped pages, so the outgoing Y offset points at
// unrelated text. The install lands on whichever page now holds whatever was at
// the top of the viewport.
static void TestViewportReanchor(NSString* path, NSView* host, dispatch_queue_t queue) {
    SPDFMacMarkdownSession* session =
        [[SPDFMacMarkdownSession alloc] initWithDocumentURL:[NSURL fileURLWithPath:path]];
    ActivateSession(session, host, queue, 1.0, SPDFMacMarkdownPageFitWidth);
    assert(session.pageCount > 2);

    NSRange deepMatch = [session.renderedDocument.attributedString.string rangeOfString:@"Paragraph 45"];
    assert(deepMatch.location != NSNotFound);
    [session revealRange:deepMatch];
    assert(session.currentPageIndex > 0);
    NSUInteger anchorLocation = session.visibleAttributedLocation;
    assert(anchorLocation != NSNotFound && anchorLocation > 0);

    [session applyPageOrientation:SPDFMarkdownPageOrientationLandscape];
    // The plan is published before the viewport block that re-anchors it runs,
    // so wait on the viewport rather than on the plan.
    assert(SpinUntil(
        ^BOOL {
          return session.paginationPlan.configuration.orientation == SPDFMarkdownPageOrientationLandscape &&
                 session.currentPageIndex > 0 &&
                 session.currentPageIndex == (NSInteger)[session pageIndexForRange:NSMakeRange(anchorLocation, 0)];
        },
        15.0));
    assert(session.fitMode == SPDFMacMarkdownPageFitWidth);
    [session deactivate];
}

// ------------------------------------------------------------- the exports

// Screen, print, Save as PDF, Copy Page and Copy Page Image all read their
// paper off the plan that the single SPDFMacMarkdownPlanForRendition seam
// builds, so a landscape document comes out landscape everywhere without any
// of them knowing orientation exists.
static void TestExportsFollowThePaper(NSString* path, NSView* host, dispatch_queue_t queue) {
    SPDFMacMarkdownSession* session =
        [[SPDFMacMarkdownSession alloc] initWithDocumentURL:[NSURL fileURLWithPath:path]];
    ActivateSession(session, host, queue, 1.0, SPDFMacMarkdownPageFitPage);

    NSSize portraitPaper = session.paginationPlan.configuration.paperSize;
    NSArray<NSNumber*>* portraitBreaks = PageBreakLocations(session.paginationPlan);
    assert(portraitBreaks.count > 1);

    [session applyPageOrientation:SPDFMarkdownPageOrientationLandscape];
    assert(SpinUntil(
        ^BOOL {
          return session.paginationPlan.configuration.orientation == SPDFMarkdownPageOrientationLandscape;
        },
        10.0));
    SPDFMarkdownPaginationPlan* landscapePlan = session.paginationPlan;
    NSSize landscapePaper = landscapePlan.configuration.paperSize;
    assert(fabs(landscapePaper.width - portraitPaper.height) < 0.01 &&
           fabs(landscapePaper.height - portraitPaper.width) < 0.01);
    assert(![PageBreakLocations(landscapePlan) isEqualToArray:portraitBreaks]);

    // Export plans are LIGHT plans, built independently of the theme; while the
    // session is light the export plan is the live plan itself, so the turned
    // paper arrives without a second render.
    assert(session.themeVariant == SPDFMarkdownThemeVariantLight);
    assert(session.exportPaginationPlan == landscapePlan);
    assert(session.exportPaginationPlan.configuration.orientation == SPDFMarkdownPageOrientationLandscape);

    // Save as PDF / Copy Page write pages at the plan's paper.
    NSData* pageData = [SPDFMacMarkdownPrintAdapter PDFDataForPageAtIndex:0
                                                           paginationPlan:session.exportPaginationPlan
                                                         attributedString:session.exportAttributedString];
    PDFDocument* pagePDF = [[PDFDocument alloc] initWithData:pageData];
    NSRect mediaBox = [[pagePDF pageAtIndex:0] boundsForBox:kPDFDisplayBoxMediaBox];
    assert(NSWidth(mediaBox) > NSHeight(mediaBox));
    assert(fabs(NSWidth(mediaBox) - landscapePaper.width) < 1.0 &&
           fabs(NSHeight(mediaBox) - landscapePaper.height) < 1.0);

    // The whole-document write is the same sheet, page for page.
    NSString* output = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"pdf"]];
    assert([SPDFMacMarkdownPrintAdapter writePaginationPlan:session.exportPaginationPlan
                                           attributedString:session.exportAttributedString
                                                      toURL:[NSURL fileURLWithPath:output]
                                                      error:nil]);
    PDFDocument* wholePDF = [[PDFDocument alloc] initWithURL:[NSURL fileURLWithPath:output]];
    assert(wholePDF.pageCount == landscapePlan.pages.count);
    NSRect wholeBox = [[wholePDF pageAtIndex:wholePDF.pageCount - 1] boundsForBox:kPDFDisplayBoxMediaBox];
    assert(NSWidth(wholeBox) > NSHeight(wholeBox));
    [NSFileManager.defaultManager removeItemAtPath:output error:nil];

    // Copy Page Image rasters the same turned sheet.
    NSBitmapImageRep* rep = [SPDFMacMarkdownPrintAdapter imageRepForPageAtIndex:0
                                                                 paginationPlan:session.exportPaginationPlan
                                                               attributedString:session.exportAttributedString
                                                                          scale:1.0];
    assert(rep != nil && rep.pixelsWide > rep.pixelsHigh);

    // Print opens on landscape paper instead of shrinking the sheet onto a
    // portrait one.
    NSPrintOperation* landscapeOperation =
        [SPDFMacMarkdownPrintAdapter printOperationForPaginationPlan:session.exportPaginationPlan
                                                    attributedString:session.exportAttributedString
                                                           printInfo:[NSPrintInfo.sharedPrintInfo copy]];
    assert(landscapeOperation.printInfo.orientation == NSPaperOrientationLandscape);

    // A DARK session still exports light, and still exports the turned paper:
    // the two choices are independent.
    [session applyThemeVariant:SPDFMarkdownThemeVariantDark];
    assert(SpinUntil(
        ^BOOL {
          return session.paginationPlan.configuration.themeVariant == SPDFMarkdownThemeVariantDark;
        },
        10.0));
    assert(session.paginationPlan.configuration.orientation == SPDFMarkdownPageOrientationLandscape);
    SPDFMarkdownPaginationPlan* darkExportPlan = session.exportPaginationPlan;
    assert(darkExportPlan != session.paginationPlan);
    assert(darkExportPlan.configuration.themeVariant == SPDFMarkdownThemeVariantLight);
    assert(darkExportPlan.configuration.orientation == SPDFMarkdownPageOrientationLandscape);
    assert(darkExportPlan.pages.count == session.paginationPlan.pages.count);

    // Turning back restores the portrait paper and the portrait page breaks.
    [session applyPageOrientation:SPDFMarkdownPageOrientationPortrait];
    assert(SpinUntil(
        ^BOOL {
          return session.paginationPlan.configuration.orientation == SPDFMarkdownPageOrientationPortrait;
        },
        10.0));
    assert([PageBreakLocations(session.paginationPlan) isEqualToArray:portraitBreaks]);
    assert(session.exportPaginationPlan.configuration.orientation == SPDFMarkdownPageOrientationPortrait);
    NSPrintOperation* portraitOperation =
        [SPDFMacMarkdownPrintAdapter printOperationForPaginationPlan:session.exportPaginationPlan
                                                    attributedString:session.exportAttributedString
                                                           printInfo:[NSPrintInfo.sharedPrintInfo copy]];
    assert(portraitOperation.printInfo.orientation == NSPaperOrientationPortrait);
    [session deactivate];
}

// --------------------------------------------------------------- the figures

// A diagram is a FIGURE: it is sized against the printable box of the paper the
// plan is about to use, not against the inline-image budget. So turning the
// paper does not merely re-flow the text around the drawing — it re-fits the
// drawing itself, and every output reads the one geometry.
static NSRect DiagramRectInPlan(SPDFMarkdownPaginationPlan* plan) {
    for (NSUInteger index = 0; index < plan.pages.count; ++index)
        for (SPDFMarkdownPageDecoration* decoration in [plan decorationsForPageIndex:index])
            if (decoration.type == SPDFMarkdownPageDecorationTypeDiagram) return decoration.rect;
    return NSZeroRect;
}

static void TestFiguresFollowThePaper(NSView* host, dispatch_queue_t queue) {
    NSMutableString* text = [NSMutableString stringWithString:@"# Figure\n\n```mermaid\nflowchart LR\n"];
    // Short labels on a long chain: wide enough that any A4 column fits it, and
    // narrow enough that no label re-wrap is involved, so the width the plan
    // ends up with is purely the paper's.
    for (int step = 0; step < 11; ++step)
        [text appendFormat:@"  n%d[\"Stage %d\"] --> n%d[\"Stage %d\"]\n", step, step, step + 1, step + 1];
    [text appendString:@"```\n\nAfter the figure.\n"];
    NSString* path = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"md"]];
    assert([text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]);

    SPDFMacMarkdownSession* session =
        [[SPDFMacMarkdownSession alloc] initWithDocumentURL:[NSURL fileURLWithPath:path]];
    ActivateSession(session, host, queue, 1.0, SPDFMacMarkdownPageFitPage);
    NSRect portraitFigure = DiagramRectInPlan(session.paginationPlan);
    CGFloat portraitColumn = NSWidth(session.paginationPlan.configuration.printableRect);
    // Wide enough to be fitted, and fitted to the COLUMN rather than to some
    // constant well inside it.
    assert(NSWidth(portraitFigure) > portraitColumn * 0.9);
    assert(NSWidth(portraitFigure) <= portraitColumn + 0.5);

    [session applyPageOrientation:SPDFMarkdownPageOrientationLandscape];
    assert(SpinUntil(
        ^BOOL {
          return session.paginationPlan.configuration.orientation == SPDFMarkdownPageOrientationLandscape &&
                 NSWidth(DiagramRectInPlan(session.paginationPlan)) > NSWidth(portraitFigure) + 1;
        },
        10.0));
    NSRect landscapeFigure = DiagramRectInPlan(session.paginationPlan);
    CGFloat landscapeColumn = NSWidth(session.paginationPlan.configuration.printableRect);
    assert(NSWidth(landscapeFigure) <= landscapeColumn + 0.5);
    // Turning the paper really did re-RENDER the figure larger, not just move it.
    assert(NSWidth(landscapeFigure) > NSWidth(portraitFigure) * 1.3);

    // Print / Save as PDF / Copy Page read the same plan, so they see the same
    // figure; a dark session's independently built light rendition too.
    assert(NSEqualRects(DiagramRectInPlan(session.exportPaginationPlan), landscapeFigure));
    [session applyThemeVariant:SPDFMarkdownThemeVariantDark];
    assert(SpinUntil(
        ^BOOL {
          return session.paginationPlan.configuration.themeVariant == SPDFMarkdownThemeVariantDark;
        },
        10.0));
    NSRect exportFigure = DiagramRectInPlan(session.exportPaginationPlan);
    assert(fabs(NSWidth(exportFigure) - NSWidth(landscapeFigure)) < 0.5);
    [session deactivate];
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
}

static void TestAuthorPaper(NSView* host, dispatch_queue_t queue) {
    NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"md"]];
    NSString* source = @"---\npaper-size: Letter\npaper-orientation: landscape\npaper-margin: 36\n"
        @"paper-margin-top: 48\n---\n# First\n\nBefore.\n\n<!-- pagebreak -->\n\n# Second\n\nAfter.\n";
    assert([source writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    SPDFMacMarkdownSession* session = [[SPDFMacMarkdownSession alloc] initWithDocumentURL:[NSURL fileURLWithPath:path]];
    ActivateSession(session, host, queue, 1, SPDFMacMarkdownPageFitPage);
    assert(NSEqualSizes(session.paginationPlan.configuration.paperSize, NSMakeSize(792, 612)));
    assert(session.pageOrientation == SPDFMarkdownPageOrientationLandscape);
    assert(session.pageCount == 2 && session.paginationPlan.configuration.topContentInset == 48);
    assert(NSEqualSizes(session.document.renderOptions.pageContentSize, session.paginationPlan.configuration.printableRect.size));
    assert(session.exportPaginationPlan == session.paginationPlan);
    [session applyThemeVariant:SPDFMarkdownThemeVariantDark];
    assert(SpinUntil(^BOOL { return session.paginationPlan.configuration.themeVariant == SPDFMarkdownThemeVariantDark; }, 10));
    SPDFMarkdownPaginationPlan* exported = session.exportPaginationPlan;
    assert(NSEqualSizes(exported.configuration.paperSize, NSMakeSize(792, 612)));
    assert([PageBreakLocations(exported) isEqual:PageBreakLocations(session.paginationPlan)]);
    NSData* data = [SPDFMacMarkdownPrintAdapter PDFDataForPageAtIndex:0 paginationPlan:exported
        attributedString:session.exportAttributedString];
    NSRect media = [[[[PDFDocument alloc] initWithData:data] pageAtIndex:0] boundsForBox:kPDFDisplayBoxMediaBox];
    assert(fabs(NSWidth(media) - 792) < 1 && fabs(NSHeight(media) - 612) < 1);
    [session applyPageOrientation:SPDFMarkdownPageOrientationPortrait];
    assert(SpinUntil(^BOOL { return session.paginationPlan.configuration.orientation == SPDFMarkdownPageOrientationPortrait; }, 10));
    assert(NSEqualSizes(session.paginationPlan.configuration.paperSize, NSMakeSize(612, 792)));
    assert(session.paginationPlan.configuration.topContentInset == 48);
    SPDFMarkdownRenderedDocument* previous = session.renderedDocument;
    [session reloadFromDiskWithStatus:nil];
    assert(SpinUntil(^BOOL { return session.renderedDocument != previous; }, 10));
    assert(session.paginationPlan.configuration.orientation == SPDFMarkdownPageOrientationPortrait);
    NSString* edited = [source stringByReplacingOccurrencesOfString:@"paper-size: Letter" withString:@"paper-size: A5"];
    assert([edited writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    previous = session.renderedDocument;
    [session reloadFromDiskWithStatus:nil];
    assert(SpinUntil(^BOOL { return session.renderedDocument != previous; }, 10));
    assert(fabs(session.paginationPlan.configuration.paperSize.width - 419.5276) < 0.01);
    assert(session.paginationPlan.configuration.orientation == SPDFMarkdownPageOrientationPortrait);
    assert([@"# Default paper\n\nRestored.\n" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    previous = session.renderedDocument;
    [session reloadFromDiskWithStatus:nil];
    assert(SpinUntil(^BOOL { return session.renderedDocument != previous; }, 10));
    assert(!session.document.authoredPageConfiguration);
    assert(fabs(session.paginationPlan.configuration.paperSize.width - 595.2756) < 0.01);
    assert(NSEqualSizes(session.document.renderOptions.pageContentSize, session.paginationPlan.configuration.printableRect.size));
    [session deactivate];
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
}

int main(void) {
    @autoreleasepool {
        (void)NSApplication.sharedApplication;
        NSString* path = WriteLongMarkdown();
        NSView* host = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 640, 480)];
        dispatch_queue_t queue = dispatch_queue_create("markdown.orientation.test", DISPATCH_QUEUE_CONCURRENT);

        TestConfigurationGeometry(path);
        TestSessionContract(path, host, queue);
        TestViewportReanchor(path, host, queue);
        TestExportsFollowThePaper(path, host, queue);
        TestFiguresFollowThePaper(host, queue);
        TestAuthorPaper(host, queue);

        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        puts("SPDFMacMarkdownOrientationTests passed");
    }
    return 0;
}
