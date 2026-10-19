#import <AppKit/AppKit.h>

#import "../SPDFMacMarkdownPageCanvasPrivate.h"
#import "../SPDFMacMarkdownPagedView.h"
#import "../SPDFMacMarkdownPrinting.h"
#import "../SPDFMacMarkdownSession.h"
#import "../markdown/SPDFMarkdown.h"

#include <assert.h>
#include <stdio.h>

// The chrome row shared by every fenced code box: the COPY button on the left
// and the language selector on the right, one line, one reserved band.
// Covered here:
// - the two controls sit on the same row, at opposite ends, without overlap;
// - hit-testing is disjoint (a click on one is never the other) and the copy
//   button reads its own hit slop;
// - clicking copies the block's RAW fence source and arms a brief "Copied"
//   title whose width never moves the button;
// - both controls take the theme's code-control palette, in LIGHT and DARK;
// - neither is drawn by the pagination plan, so print / Save as PDF / Copy
//   Page (which paint a plan, never the canvas) exclude them.

static void Expect(const char* what, BOOL condition) {
    if (condition) return;
    fprintf(stderr, "SPDFMacMarkdownCodeControlsTests: %s\n", what);
    abort();
}

static NSBitmapImageRep* RasterizeView(NSView* view) {
    NSBitmapImageRep* rep = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    assert(rep);
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
    return rep;
}

// Samples a VIEW-SPACE point of a cached rep (backing-scaled, and the canvas
// is flipped, so a row is scale * y).
static NSColor* SampleView(NSBitmapImageRep* rep, NSView* view, CGFloat x, CGFloat y) {
    CGFloat scale = (CGFloat)rep.pixelsWide / MAX((CGFloat)1, NSWidth(view.bounds));
    NSInteger column = (NSInteger)MIN((CGFloat)rep.pixelsWide - 1, MAX((CGFloat)0, floor(x * scale)));
    NSInteger row = (NSInteger)MIN((CGFloat)rep.pixelsHigh - 1, MAX((CGFloat)0, floor(y * scale)));
    return [rep colorAtX:column y:row];
}

static CGFloat ColorDistance(NSColor* left, NSColor* right) {
    NSColor* a = [left colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    NSColor* b = [right colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!a || !b) return CGFLOAT_MAX;
    return fabs(a.redComponent - b.redComponent) + fabs(a.greenComponent - b.greenComponent) +
           fabs(a.blueComponent - b.blueComponent);
}

static BOOL ColorsMatch(NSColor* left, NSColor* right, CGFloat tolerance) {
    NSColor* a = [left colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    NSColor* b = [right colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!a || !b) return NO;
    return fabs(a.redComponent - b.redComponent) <= tolerance &&
           fabs(a.greenComponent - b.greenComponent) <= tolerance &&
           fabs(a.blueComponent - b.blueComponent) <= tolerance;
}

static SPDFMarkdownPaginationPlan* PlanForVariant(SPDFMarkdownThemeVariant variant, NSString* markdown,
                                                  NSAttributedString** outString, NSUInteger* outBlockIndex) {
    SPDFMarkdownDocumentModel* model = [[SPDFMarkdownParser new] parseString:markdown sourceURL:nil error:nil];
    assert(model);
    SPDFMarkdownRenderOptions* options = [SPDFMarkdownRenderOptions defaultOptions];
    options.themeVariant = variant;
    SPDFMarkdownRenderedDocument* rendered = [[SPDFMarkdownRenderer new] renderModel:model
                                                                            options:options
                                                                  languageOverrides:nil];
    SPDFMarkdownPageConfiguration* configuration = [SPDFMarkdownPageConfiguration A4PortraitConfiguration];
    configuration.includesCodeLanguageControlSpacing = YES;  // the row's reserved band
    configuration.themeVariant = variant;
    SPDFMarkdownPaginator* paginator = [SPDFMarkdownPaginator new];
    NSArray* items = [paginator measureRenderedDocument:rendered
                                         containerWidth:NSWidth(configuration.printableRect)];
    if (outString) *outString = rendered.attributedString;
    if (outBlockIndex) *outBlockIndex = model.codeFences.firstObject.blockIndex;
    return [paginator paginateItems:items configuration:configuration];
}

int main(void) {
    @autoreleasepool {
        (void)NSApplication.sharedApplication;
        // Leading indentation, a blank line and a trailing newline: the copied
        // text must be the source verbatim, not a re-typeset rendition of it.
        NSString* markdown = @"# Demo\n\n"
                             @"```python\n"
                             @"def total(rows):\n"
                             @"    return sum(rows)\n"
                             @"\n"
                             @"print(total([1, 2]))\n"
                             @"```\n";

        // --- The copied string is the block's RAW source -------------------
        SPDFMarkdownDocumentModel* model = [[SPDFMarkdownParser new] parseString:markdown sourceURL:nil error:nil];
        assert(model && model.codeFences.count == 1);
        SPDFMarkdownCodeFence* fence = model.codeFences.firstObject;
        NSUInteger blockIndex = fence.blockIndex;
        NSPasteboard* pasteboard = [NSPasteboard pasteboardWithUniqueName];
        Expect("copying a code block reports success", SPDFMacMarkdownCopyCodeSource(model, blockIndex, pasteboard));
        NSString* copied = [pasteboard stringForType:NSPasteboardTypeString];
        Expect("the copied string is the fence source", [copied isEqualToString:fence.code]);
        Expect("the source indentation survives the copy", [copied containsString:@"\n    return sum(rows)\n"]);
        Expect("the blank line survives the copy", [copied containsString:@"\n\nprint"]);
        Expect("the fence markers are not copied", ![copied containsString:@"```"]);
        Expect("the language label is not copied", ![copied containsString:@"python"]);
        Expect("the copy helper matches the source lookup",
               [SPDFMacMarkdownCodeSourceForBlock(model, blockIndex) isEqualToString:fence.code]);
        // A non-code block has no source and writes nothing.
        NSPasteboard* headingPasteboard = [NSPasteboard pasteboardWithUniqueName];
        Expect("a heading block has no code source", SPDFMacMarkdownCodeSourceForBlock(model, 0) == nil);
        Expect("copying a heading block reports failure",
               !SPDFMacMarkdownCopyCodeSource(model, 0, headingPasteboard));
        Expect("copying a heading block writes nothing",
               [headingPasteboard stringForType:NSPasteboardTypeString] == nil);
        Expect("a missing block index reports failure",
               !SPDFMacMarkdownCopyCodeSource(model, blockIndex + 999, headingPasteboard));

        // --- Geometry: one row, opposite ends, no overlap ------------------
        NSAttributedString* lightString = nil;
        NSUInteger lightBlockIndex = 0;
        SPDFMarkdownPaginationPlan* lightPlan =
            PlanForVariant(SPDFMarkdownThemeVariantLight, markdown, &lightString, &lightBlockIndex);
        assert(lightPlan.pages.count >= 1 && lightBlockIndex == blockIndex);
        SPDFMacMarkdownPageCanvas* canvas =
            [[SPDFMacMarkdownPageCanvas alloc] initWithPaginationPlan:lightPlan attributedString:lightString];
        [canvas resizeForWidth:800];
        NSRect pageFrame = [canvas frameForPageAtIndex:0];
        NSRect printable = lightPlan.configuration.printableRect;
        CGFloat boxLeft = NSMinX(pageFrame) + NSMinX(printable);
        NSRect copyFrame = [canvas copyCodeControlFrameForBlockIndex:blockIndex];
        NSRect languageFrame = [canvas codeLanguageControlFrameForBlockIndex:blockIndex];
        Expect("the copy button has a frame", !NSIsEmptyRect(copyFrame));
        Expect("the language selector has a frame", !NSIsEmptyRect(languageFrame));
        Expect("the copy button is 10pt off the box's left edge", fabs(NSMinX(copyFrame) - (boxLeft + 10.0)) < 0.001);
        Expect("the copy button shares the selector's line", fabs(NSMinY(copyFrame) - NSMinY(languageFrame)) < 0.001);
        Expect("the copy button shares the selector's height",
               fabs(NSHeight(copyFrame) - NSHeight(languageFrame)) < 0.001);
        Expect("the copy button is 20pt tall", fabs(NSHeight(copyFrame) - 20.0) < 0.001);
        Expect("the copy button stays left of the selector", NSMaxX(copyFrame) + 6.0 <= NSMinX(languageFrame));
        Expect("the two controls never overlap", !NSIntersectsRect(copyFrame, languageFrame));
        Expect("the copy button sits inside the code box", NSMinX(copyFrame) > boxLeft);
        // Non-code blocks and unknown indices expose no copy button.
        Expect("a heading block has no copy button", NSIsEmptyRect([canvas copyCodeControlFrameForBlockIndex:0]));
        Expect("an unknown block has no copy button",
               NSIsEmptyRect([canvas copyCodeControlFrameForBlockIndex:blockIndex + 999]));

        // --- Hit-testing: disjoint, with the control's own slop ------------
        NSPoint onCopy = NSMakePoint(NSMidX(copyFrame), NSMidY(copyFrame));
        NSPoint onLanguage = NSMakePoint(NSMidX(languageFrame), NSMidY(languageFrame));
        NSPoint betweenControls = NSMakePoint((NSMaxX(copyFrame) + NSMinX(languageFrame)) * 0.5, NSMidY(copyFrame));
        Expect("the copy button hit-tests to its block",
               [[canvas copyCodeBlockAtPoint:onCopy] unsignedIntegerValue] == blockIndex);
        Expect("the copy button is not the language selector", [canvas codeLanguageBlockAtPoint:onCopy] == nil);
        Expect("the language selector still hit-tests to its block",
               [[canvas codeLanguageBlockAtPoint:onLanguage] unsignedIntegerValue] == blockIndex);
        Expect("the language selector is not the copy button", [canvas copyCodeBlockAtPoint:onLanguage] == nil);
        // Its own 7pt slop, and nothing beyond it.
        Expect("the copy button carries its hit slop",
               [canvas copyCodeBlockAtPoint:NSMakePoint(NSMinX(copyFrame) - 4.0, NSMidY(copyFrame))] != nil);
        Expect("the copy button's hit rect ends with the slop",
               [canvas copyCodeBlockAtPoint:NSMakePoint(NSMinX(copyFrame) - 12.0, NSMidY(copyFrame))] == nil);
        Expect("the row's middle belongs to neither control",
               [canvas copyCodeBlockAtPoint:betweenControls] == nil &&
                   [canvas codeLanguageBlockAtPoint:betweenControls] == nil);
        // Both controls are pointer affordances, like a link.
        Expect("the copy button shows the hand cursor",
               [canvas cursorRegionAtPoint:onCopy] == SPDFCursorRegionLink);

        // --- Click behavior and the "Copied" feedback ----------------------
        Expect("the button starts out reading Copy",
               [[canvas copyCodeControlTitleForBlockIndex:blockIndex] isEqualToString:@"Copy"]);
        __block NSUInteger requests = 0;
        __block NSUInteger requestedBlock = NSNotFound;
        canvas.copyCodeBlockHandler = ^BOOL(NSUInteger requested) {
          requests++;
          requestedBlock = requested;
          return YES;
        };
        [canvas handleCopyCodeBlock:blockIndex];
        Expect("clicking asks the reader to copy exactly once", requests == 1 && requestedBlock == blockIndex);
        Expect("a successful copy arms the Copied title",
               [[canvas copyCodeControlTitleForBlockIndex:blockIndex] isEqualToString:@"Copied"]);
        // The feedback must not move or resize the button under the pointer.
        Expect("the Copied state keeps the button's frame",
               NSEqualRects(copyFrame, [canvas copyCodeControlFrameForBlockIndex:blockIndex]));
        Expect("the feedback is scoped to the copied block",
               [[canvas copyCodeControlTitleForBlockIndex:blockIndex + 1] isEqualToString:@"Copy"]);
        // The state clears itself on the main queue, with no timer to leak.
        NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
        while (canvas.copiedCodeBlockIndex != nil && deadline.timeIntervalSinceNow > 0)
            [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                                   beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        Expect("the Copied title clears itself", canvas.copiedCodeBlockIndex == nil);
        Expect("the button reads Copy again",
               [[canvas copyCodeControlTitleForBlockIndex:blockIndex] isEqualToString:@"Copy"]);
        // A reader that cannot copy leaves the button alone.
        canvas.copyCodeBlockHandler = ^BOOL(NSUInteger requested) {
          (void)requested;
          return NO;
        };
        [canvas handleCopyCodeBlock:blockIndex];
        Expect("a failed copy shows no feedback",
               [[canvas copyCodeControlTitleForBlockIndex:blockIndex] isEqualToString:@"Copy"]);

        // --- The theme palette, in both reading themes --------------------
        SPDFMarkdownThemeVariant variants[2] = {SPDFMarkdownThemeVariantLight, SPDFMarkdownThemeVariantDark};
        for (NSUInteger i = 0; i < 2; ++i) {
            SPDFMarkdownTheme* theme = [SPDFMarkdownTheme themeForVariant:variants[i]];
            NSAttributedString* string = nil;
            SPDFMarkdownPaginationPlan* plan = PlanForVariant(variants[i], markdown, &string, NULL);
            SPDFMacMarkdownPageCanvas* themed =
                [[SPDFMacMarkdownPageCanvas alloc] initWithPaginationPlan:plan attributedString:string];
            [themed resizeForWidth:800];
            NSRect themedCopy = [themed copyCodeControlFrameForBlockIndex:blockIndex];
            Expect("the themed canvas draws a copy button", !NSIsEmptyRect(themedCopy));
            NSBitmapImageRep* rep = RasterizeView(themed);
            // Inside the pill, clear of its 1px stroke and its centered label.
            NSColor* fill = SampleView(rep, themed, NSMinX(themedCopy) + 3.0, NSMidY(themedCopy));
            Expect("the copy button takes the theme's code-control fill",
                   ColorsMatch(fill, theme.codeControlFillColor, 0.02));
            // The same sample inside the language pill: one shared look.
            NSRect themedLanguage = [themed codeLanguageControlFrameForBlockIndex:blockIndex];
            NSColor* languageFill = SampleView(rep, themed, NSMinX(themedLanguage) + 3.0, NSMidY(themedLanguage));
            Expect("both controls share one fill", ColorsMatch(languageFill, theme.codeControlFillColor, 0.02));
            // The dark palette's control and box fills are only 4/255 apart,
            // so match the NEARER role rather than trusting a tolerance: the
            // pill must read as control chrome, not as bare code box.
            Expect("the copy button is filled as a control, not as bare box",
                   ColorDistance(fill, theme.codeControlFillColor) < ColorDistance(fill, theme.codeBoxFillColor));
        }

        // --- Print / export / Copy Page exclude both controls --------------
        // The plan is what print, Save as PDF and Copy Page paint. Neither
        // control may appear in it: the code box's header band stays flat
        // code-box fill from edge to edge.
        // The export palette is always LIGHT, where a control's fill stands
        // 12/255 off the box fill: the probes below really can see chrome.
        Expect("the export palette tells a control apart from the box fill",
               !ColorsMatch(SPDFMarkdownTheme.codeControlFillColor, SPDFMarkdownTheme.codeBoxFillColor, 0.02));
        NSBitmapImageRep* exported = [SPDFMacMarkdownPrintAdapter imageRepForPageAtIndex:0
                                                                         paginationPlan:lightPlan
                                                                       attributedString:lightString
                                                                                  scale:1.0];
        Expect("the export page rasterizes", exported != nil);
        NSRect copyOnPaper = NSOffsetRect(copyFrame, -NSMinX(pageFrame), -NSMinY(pageFrame));
        NSRect languageOnPaper = NSOffsetRect(languageFrame, -NSMinX(pageFrame), -NSMinY(pageFrame));
        // Reference: the untouched middle of the same row, between the two
        // controls, which is plain code-box fill in every rendition.
        NSColor* bandFill = [exported colorAtX:(NSInteger)round(NSMidX(NSMakeRect(
                                                   NSMaxX(copyOnPaper), NSMinY(copyOnPaper),
                                                   NSMinX(languageOnPaper) - NSMaxX(copyOnPaper), 1)))
                                             y:(NSInteger)round(NSMidY(copyOnPaper))];
        // Pins the page-local mapping: a mis-aimed rect would land on paper
        // white instead, and the probes below would pass vacuously.
        Expect("the exported header band reads as code-box fill",
               ColorsMatch(bandFill, SPDFMarkdownTheme.codeBoxFillColor, 0.02));
        NSRect probes[2] = {copyOnPaper, languageOnPaper};
        for (NSUInteger i = 0; i < 2; ++i) {
            for (NSInteger y = (NSInteger)ceil(NSMinY(probes[i])); y < (NSInteger)floor(NSMaxY(probes[i])); ++y)
                for (NSInteger x = (NSInteger)ceil(NSMinX(probes[i])); x < (NSInteger)floor(NSMaxX(probes[i])); ++x)
                    Expect("no control chrome is baked into the exported page",
                           ColorsMatch([exported colorAtX:x y:y], bandFill, 0.02));
        }

        [pasteboard releaseGlobally];
        [headingPasteboard releaseGlobally];
        puts("SPDFMacMarkdownCodeControlsTests passed");
    }
    return 0;
}
