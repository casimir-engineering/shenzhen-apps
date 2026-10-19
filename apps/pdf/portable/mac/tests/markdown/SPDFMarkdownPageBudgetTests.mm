#import "SPDFMarkdownTestSupport.h"

#import "../../markdown/SPDFMarkdownDiagram.h"
#import "../../markdown/SPDFMarkdownDocument.h"
#import "../../markdown/SPDFMarkdownTableDecorations.h"

// The page-budget contract: when a render carries the destination page's
// printable box (SPDFMarkdownRenderOptions.pageContentSize), image display
// sizes, the pending remote placeholder box, image-row fitting and the table
// renderer's provisional column distribution are all budgeted by that box —
// so turning the paper re-fits them, exactly like diagram figures. A render
// with no page attached (NSZeroSize) keeps the constant
// maximumImageWidth/maximumImageHeight caps byte for byte.

static void SPDFWritePNG(NSString* path, NSInteger width, NSInteger height) {
    NSBitmapImageRep* bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                        pixelsWide:width pixelsHigh:height
                                                                     bitsPerSample:8
                                                                   samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                                                                    colorSpaceName:NSCalibratedRGBColorSpace
                                                                       bytesPerRow:0 bitsPerPixel:0];
    memset(bitmap.bitmapData, 0x7f, bitmap.bytesPerRow * bitmap.pixelsHigh);
    NSData* PNG = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    [PNG writeToFile:path atomically:YES];
}

// The fixture folder, removed by exact path when the process exits, so a failed check (which only counts and
// carries on) still leaves nothing in the temporary folder.
static NSString* SPDFBudgetDirectory;
static void SPDFRemoveBudgetDirectory(void) {
    if (SPDFBudgetDirectory) [[NSFileManager defaultManager] removeItemAtPath:SPDFBudgetDirectory error:nil];
}

static NSURL* SPDFCreateBudgetDocument(void) {
    NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES
                                                attributes:nil error:nil];
    SPDFBudgetDirectory = directory;
    atexit(SPDFRemoveBudgetDirectory);
    SPDFWritePNG([directory stringByAppendingPathComponent:@"wide.png"], 1600, 600);
    SPDFWritePNG([directory stringByAppendingPathComponent:@"tall.png"], 600, 1600);
    NSString* source =
        @"# Page budget\n\n"
         "![Wide art](wide.png)\n\n"
         "![Tall art](tall.png)\n\n"
         "![Pair one](wide.png) ![Pair two](wide.png)\n\n"
         "![Pending badge](https://images.example/badge.png)\n\n"
         "| Alpha | Beta |\n"
         "| --- | --- |\n"
         "| A very long alpha cell that keeps talking well past any page budget "
         "| An equally long beta cell that keeps talking well past any page budget |\n";
    [source writeToFile:[directory stringByAppendingPathComponent:@"budget.md"]
             atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"budget.md"]];
}

// The document's attachments in canonical order: wide figure, tall figure,
// the two row images, then the pending remote placeholder box.
static NSArray<NSTextAttachment*>* SPDFAttachments(SPDFMarkdownDocument* document) {
    NSMutableArray<NSTextAttachment*>* attachments = [NSMutableArray array];
    NSAttributedString* text = document.renderedDocument.attributedString;
    [text enumerateAttribute:NSAttachmentAttributeName
                     inRange:NSMakeRange(0, text.length)
                     options:0
                  usingBlock:^(NSTextAttachment* attachment, NSRange range, BOOL* stop) {
                    (void)stop;
                    if (attachment && range.length == 1) [attachments addObject:attachment];
                  }];
    return attachments;
}

static CGFloat SPDFLastTableBoundary(SPDFMarkdownDocument* document) {
    for (SPDFMarkdownRenderedBlock* block in document.renderedDocument.renderedBlocks) {
        if (block.tableRowInfo.columnBoundaries.count)
            return block.tableRowInfo.columnBoundaries.lastObject.doubleValue;
    }
    return -1;
}

int main(void) {
    @autoreleasepool {
        NSURL* url = SPDFCreateBudgetDocument();
        NSError* error = nil;

        // Landscape-ish page: 720 pt printable width, 473 pt printable height.
        // The figure air is 2 x paragraphSpacing (12), so the height budget is
        // 473 - 24 = 449.
        SPDFMarkdownRenderOptions* landscape = SPDFMarkdownRenderOptions.defaultOptions;
        landscape.pageContentSize = NSMakeSize(720, 473);
        SPDFMarkdownDocument* document = [SPDFMarkdownDocument documentWithURL:url options:landscape error:&error];
        SPDFExpect(document != nil && error == nil, @"page-budget document loads and renders");
        NSArray<NSTextAttachment*>* attachments = SPDFAttachments(document);
        SPDFExpect(attachments.count == 5, @"wide + tall + two row images + pending placeholder render");
        if (attachments.count == 5) {
            NSSize wide = attachments[0].bounds.size;
            SPDFExpect(fabs(wide.width - 720) < 0.01 && fabs(wide.height - 270) < 0.01,
                       @"a wide image fills the page's printable width, not the constant cap");
            NSSize tall = attachments[1].bounds.size;
            SPDFExpect(fabs(tall.height - 449) < 0.01,
                       @"a tall image caps at the printable height net of the figure air");
            NSSize pairOne = attachments[2].bounds.size;
            NSSize pairTwo = attachments[3].bounds.size;
            SPDFExpect(fabs(pairOne.width - pairTwo.width) < 0.01 && pairOne.width + pairTwo.width <= 720.01 &&
                           pairOne.width + pairTwo.width > 700,
                       @"an image row fits the printable width by one common factor");
            NSSize pending = attachments[4].bounds.size;
            SPDFExpect(fabs(pending.width - 720) < 0.01 && fabs(pending.height - 150) < 0.01,
                       @"the pending remote placeholder box reserves the printable width");
        }
        SPDFExpect(fabs(SPDFLastTableBoundary(document) - 720) < 0.01,
                   @"an over-wide table's provisional columns distribute at the printable width");

        // Turning the paper re-budgets: the same document rendered for the
        // portrait page comes out narrower.
        SPDFMarkdownRenderOptions* portrait = SPDFMarkdownRenderOptions.defaultOptions;
        portrait.pageContentSize = NSMakeSize(473, 720);
        SPDFMarkdownDocument* portraitDocument = [SPDFMarkdownDocument documentWithURL:url
                                                                               options:portrait error:&error];
        NSArray<NSTextAttachment*>* portraitAttachments = SPDFAttachments(portraitDocument);
        SPDFExpect(portraitAttachments.count == 5 && fabs(portraitAttachments[0].bounds.size.width - 473) < 0.01,
                   @"the portrait page budgets the same image to its own printable width");
        SPDFExpect(fabs(SPDFLastTableBoundary(portraitDocument) - 473) < 0.01,
                   @"the portrait page budgets the table to its own printable width");

        // The NSZeroSize fallback contract: a render with no page attached
        // keeps the old constant budgets (440 x 320 by default) everywhere.
        SPDFMarkdownDocument* pageless = [SPDFMarkdownDocument documentWithURL:url
                                                                       options:SPDFMarkdownRenderOptions.defaultOptions
                                                                         error:&error];
        NSArray<NSTextAttachment*>* pagelessAttachments = SPDFAttachments(pageless);
        SPDFExpect(pagelessAttachments.count == 5, @"the page-less render keeps the same attachments");
        if (pagelessAttachments.count == 5) {
            NSSize wide = pagelessAttachments[0].bounds.size;
            SPDFExpect(fabs(wide.width - 440) < 0.01 && fabs(wide.height - 165) < 0.01,
                       @"a page-less render keeps the constant maximumImageWidth cap");
            NSSize tall = pagelessAttachments[1].bounds.size;
            SPDFExpect(fabs(tall.height - 320) < 0.01,
                       @"a page-less render keeps the constant maximumImageHeight cap");
            SPDFExpect(fabs(pagelessAttachments[4].bounds.size.width - 440) < 0.01,
                       @"a page-less pending placeholder keeps the constant width");
        }
        SPDFExpect(fabs(SPDFLastTableBoundary(pageless) - 440) < 0.01,
                   @"a page-less table keeps the constant provisional width budget");
    }
    // --- A chart figure uses the page it is given ------------------------
    // Diagram geometry is fitted to the page box, but the fit factor only ever
    // SHRINKS an oversized figure; it never grows a small one. So any chart
    // that sized itself from a constant stayed that size on a wider sheet. The
    // gantt did: its chart column was capped at 520pt, and a 60-day chart --
    // which wants 1560pt at its natural 26pt/day -- sat at the cap with the
    // rest of a landscape page left empty.
    {
        NSString* gantt = @"gantt\n"
                           "    title Engine\n"
                           "    dateFormat YYYY-MM-DD\n"
                           "    section Parsing\n"
                           "        Grammar        : done, grammar, 2026-01-05, 12d\n"
                           "        Error handling : done, after grammar, 6d\n"
                           "    section Layout\n"
                           "        Ranking        : active, ranking, 2026-01-26, 2w\n"
                           "        Ordering       : after ranking, 8d\n"
                           "    section Shapes\n"
                           "        Drawing        : crit, 2026-02-20, 2026-03-06\n";
        NSSize portrait = {440, 0};
        NSSize landscape = {780, 0};
        SPDFMarkdownDiagramLayout* narrow = SPDFMarkdownDiagramRender(@"mermaid", gantt, portrait, 1.0, nil);
        SPDFMarkdownDiagramLayout* wide = SPDFMarkdownDiagramRender(@"mermaid", gantt, landscape, 1.0, nil);
        SPDFExpect(narrow != nil && wide != nil, @"the gantt renders into both page boxes");
        if (narrow && wide) {
            printf("Gantt page-box width: portrait %.0f of %.0f, landscape %.0f of %.0f\n",
                   narrow.size.width, portrait.width, wide.size.width, landscape.width);
            // Each stays inside its own page...
            SPDFExpect(narrow.size.width <= portrait.width + 0.5 && wide.size.width <= landscape.width + 0.5,
                       @"the gantt stays inside the page box it was given");
            // ...and the wider page actually buys width, rather than the chart
            // keeping its portrait size with the extra page left blank.
            SPDFExpect(wide.size.width > narrow.size.width + 1.0,
                       @"a wider page makes the gantt wider");
            SPDFExpect(wide.size.width >= landscape.width * 0.9,
                       @"the gantt uses the width the landscape page offers");
        }
    }
    return SPDFFinishTests(@"SPDFMarkdownPageBudgetTests");
}
