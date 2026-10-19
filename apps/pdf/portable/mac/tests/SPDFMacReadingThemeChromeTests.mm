// Reading-theme chrome: the gutter role both frontends read, the PDF page's
// border-instead-of-shadow decision, the single-segment toolbar pill, and where
// the Translate entry points are allowed to act.
#import <AppKit/AppKit.h>

#import "SPDFMacDocumentView.h"
#import "SPDFMacSupport.h"
#import "SPDFMacEmptyDocumentView.h"
#import "SPDFMacTranslationPolicy.h"
#import "markdown/SPDFMarkdownDecorations.h"

#include <assert.h>
#include <stdio.h>

static void Expect(const char* label, BOOL condition) {
    if (condition) return;
    fprintf(stderr, "FAIL %s\n", label);
    exit(1);
}

// The 8-bit channel value of an opaque grey role, for stating a contrast gap in
// the units the palette is written in.
static int SPDFRedByte(NSColor* color) {
    NSColor* rgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    return (int)lround(rgb.redComponent * 255.0);
}

static BOOL ColorMatchesHex(NSColor* color, unsigned int hex) {
    NSColor* rgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!rgb) return NO;
    unsigned int red = (unsigned int)lround(rgb.redComponent * 255.0);
    unsigned int green = (unsigned int)lround(rgb.greenComponent * 255.0);
    unsigned int blue = (unsigned int)lround(rgb.blueComponent * 255.0);
    return ((red << 16) | (green << 8) | blue) == hex;
}

static CGFloat Luminance(NSColor* color) {
    NSColor* rgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!rgb) return -1.0;
    return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent;
}

static SPDFRenderedPage* MakePage(void) {
    SPDFRenderedPage* page = [[SPDFRenderedPage alloc] init];
    page.pageIndex = 0;
    page.pageWidth = 200.0;
    page.pageHeight = 260.0;
    return page;
}

static NSBitmapImageRep* RasterizeView(NSView* view) {
    NSBitmapImageRep* rep = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    assert(rep);
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
    return rep;
}

// Samples a VIEW-SPACE point. The cached rep is backing-scaled (2x on this
// hardware), and the document view is flipped, so a row is scale * y.
static NSColor* SampleAt(NSBitmapImageRep* rep, NSView* view, CGFloat x, CGFloat y) {
    CGFloat scale = (CGFloat)rep.pixelsWide / MAX((CGFloat)1, NSWidth(view.bounds));
    NSInteger column = (NSInteger)MIN((CGFloat)rep.pixelsWide - 1, MAX((CGFloat)0, floor(x * scale)));
    NSInteger row = (NSInteger)MIN((CGFloat)rep.pixelsHigh - 1, MAX((CGFloat)0, floor(y * scale)));
    return [rep colorAtX:column y:row];
}

@interface WelcomeCanvas : NSView
@end
@implementation WelcomeCanvas
- (void)drawRect:(NSRect)rect { [NSColor.windowBackgroundColor setFill]; NSRectFill(rect); }
@end
@interface ClickProbe : NSObject
@property NSInteger calls;
@property NSInteger segment;
@end
@implementation ClickProbe
- (void)clicked:(NSSegmentedControl*)sender { self.calls++; self.segment=sender.selectedSegment; }
- (void)newTabRequested:(id)sender { (void)sender; self.calls++; }
@end

int main(void) {
    @autoreleasepool {
        (void)NSApplication.sharedApplication;

        ClickProbe* clicks=[ClickProbe new];
        NSWindow* host=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,700,500) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        NSSegmentedControl* pair=spdf_paired_toolbar_segments(clicks,@selector(clicked:),[NSImage imageWithSystemSymbolName:@"minus" accessibilityDescription:nil],[NSImage imageWithSystemSymbolName:@"plus" accessibilityDescription:nil]);
        pair.frame=NSMakeRect(10,10,56,28); [host.contentView addSubview:pair];
        for (NSInteger repeat=0;repeat<3;repeat++) for (NSInteger segment=0;segment<2;segment++)
            for (NSNumber* x in @[@2,@25]) for (NSNumber* y in @[@2,@25]) {
                NSPoint point=[pair convertPoint:NSMakePoint(segment*28+x.doubleValue,y.doubleValue) toView:nil];
                NSEvent* event=[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:point modifierFlags:0 timestamp:0 windowNumber:host.windowNumber context:nil eventNumber:1 clickCount:repeat+1 pressure:1];
                NSInteger before=clicks.calls; [pair mouseDown:event];
                if(clicks.calls!=before+1 || clicks.segment!=segment) fprintf(stderr,"click %ld actual %ld calls %ld before %ld frame %s\n",(long)segment,(long)clicks.segment,(long)clicks.calls,(long)before,NSStringFromRect(pair.frame).UTF8String);
                Expect("each repeated edge click dispatches exactly once",clicks.calls==before+1 && clicks.segment==segment);
                Expect("momentary segments do not retain selection",pair.selectedSegment==-1);
            }
        NSView* empty=[[WelcomeCanvas alloc] initWithFrame:NSMakeRect(0,0,700,500)];
        [host.contentView addSubview:empty];
        SPDFHideEmptyDocumentView(empty); Expect("nonempty documents allocate no welcome view",empty.subviews.count==0);
        SPDFShowEmptyDocumentView(empty,@"Open a document",clicks);
        NSView* welcome=empty.subviews.firstObject; NSButton* open=nil;
        for(NSView* child in welcome.subviews) if([child isKindOfClass:NSButton.class]) open=(NSButton*)child;
        Expect("welcome action is centered",open && fabs(NSMidX(open.frame)-350)<1);
        NSInteger before=clicks.calls; [open performClick:nil]; Expect("welcome opens a document",clicks.calls==before+1);
        for (NSString* appearance in @[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]) {
            empty.appearance=[NSAppearance appearanceNamed:appearance];
            NSBitmapImageRep* preview=RasterizeView(empty);
            [[preview representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[@"/tmp/sz-welcome-" stringByAppendingFormat:@"%@.png",appearance] atomically:YES];
        }
        SPDFHideEmptyDocumentView(empty); Expect("welcome hides after document opens",welcome.hidden);

        // --- The gutter role, per variant --------------------------------
        SPDFMarkdownTheme* light = [SPDFMarkdownTheme themeForVariant:SPDFMarkdownThemeVariantLight];
        SPDFMarkdownTheme* dark = [SPDFMarkdownTheme themeForVariant:SPDFMarkdownThemeVariantDark];
        // Light names no gutter: every surface keeps the system background it
        // already used, unchanged by the theme work.
        Expect("light gutter role is unset", light.viewportBackgroundColor == nil);
        Expect("light keeps the paper drop shadow", light.drawsPaperShadow);
        Expect("dark gutter is #0A0A0A", ColorMatchesHex(dark.viewportBackgroundColor, 0x0A0A0A));
        Expect("dark drops the paper shadow", !dark.drawsPaperShadow);
        // The whole point: the gutter must read as clearly darker than the
        // paper, or a page edge disappears into it.
        Expect("dark gutter is darker than dark paper",
               Luminance(dark.viewportBackgroundColor) < Luminance(dark.paperColor) - 0.01);
        // A separation that exists but cannot be seen is the bug this guards:
        // #121212 under #1E1E1E was 12 of 255 levels and read as no edge at all
        // on a blank page margin. Hold the gap wide enough to be visible.
        Expect("the gutter/paper gap is visible, not merely nonzero",
               SPDFRedByte(dark.paperColor) - SPDFRedByte(dark.viewportBackgroundColor) >= 16);
        Expect("the paper border clears the paper it frames",
               SPDFRedByte(dark.paperBorderColor) - SPDFRedByte(dark.paperColor) >= 24);
        Expect("dark paper border is #3D3D3D", ColorMatchesHex(dark.paperBorderColor, 0x3D3D3D));

        // --- The document view's page-separation seam --------------------
        SPDFDocumentView* view = [[SPDFDocumentView alloc] initWithFrame:NSMakeRect(0, 0, 320, 380)];
        view.zoom = 1.0;
        view.backingScale = 1.0;
        view.pages = @[ MakePage() ];

        Expect("light document view defaults to the shadow", view.drawsPageShadow);
        Expect("light document view draws no page border", view.pageBorderColor == nil);
        Expect("light page underlay is white", ColorMatchesHex(view.pageFillColor, 0xFFFFFF));
        Expect("light gutter keeps the system canvas background",
               view.viewportBackgroundColor != nil &&
                   !ColorMatchesHex(view.viewportBackgroundColor, 0x0A0A0A));

        view.themeVariant = SPDFMarkdownThemeVariantDark;
        Expect("dark document view drops the shadow", !view.drawsPageShadow);
        Expect("dark document view draws the theme page border",
               ColorMatchesHex(view.pageBorderColor, 0x3D3D3D));
        Expect("dark document view takes the theme gutter",
               ColorMatchesHex(view.viewportBackgroundColor, 0x0A0A0A));
        // A white underlay showed through as a bright edge wherever a page's
        // bitmap fell a fraction of a point short of its page rect.
        Expect("dark page underlay is the theme paper, never white",
               ColorMatchesHex(view.pageFillColor, 0x1E1E1E));
        Expect("dark page underlay sits below its own border",
               Luminance(view.pageFillColor) < Luminance(view.pageBorderColor));

        // --- The border actually lands on all four sides -----------------
        NSRect pageRect = [view rectForPageAtIndex:0];
        Expect("page rect is real", NSWidth(pageRect) > 10 && NSHeight(pageRect) > 10);
        NSBitmapImageRep* darkRaster = RasterizeView(view);
        struct {
            const char* label;
            NSPoint point;
        } edges[] = {
            // The stroke is inset by half a point, so its centerline — and the
            // pixel it covers at 1x and 2x alike — sits half a point inside the
            // page rect on each of the four sides.
            {"top border", NSMakePoint(NSMidX(pageRect), NSMinY(pageRect) + 0.5)},
            {"bottom border", NSMakePoint(NSMidX(pageRect), NSMaxY(pageRect) - 0.5)},
            {"left border", NSMakePoint(NSMinX(pageRect) + 0.5, NSMidY(pageRect))},
            {"right border", NSMakePoint(NSMaxX(pageRect) - 0.5, NSMidY(pageRect))},
        };
        // One point inside the frame is bare sheet: the theme's #1E1E1E paper.
        // This used to read white, because the underlay beneath a page's bitmap
        // was hardcoded white -- which is exactly what leaked out as a bright
        // edge wherever the bitmap fell a fraction of a point short.
        NSColor* sheet = SampleAt(darkRaster, view, NSMidX(pageRect), NSMinY(pageRect) + 2.0);
        Expect("dark sheet is the theme paper, not white", ColorMatchesHex(sheet, 0x1E1E1E));
        for (size_t i = 0; i < sizeof(edges) / sizeof(edges[0]); ++i) {
            NSColor* sample = SampleAt(darkRaster, view, edges[i].point.x, edges[i].point.y);
            // #3D3D3D on #1E1E1E paper: every edge must read against the sheet
            // it frames, on all four sides, and none may be brighter than
            // another -- an asymmetric edge is the artifact this guards.
            Expect(edges[i].label, Luminance(sample) > Luminance(sheet) + 0.01);
            NSColor* opposite = SampleAt(darkRaster, view, edges[(i + 2) % 4].point.x, edges[(i + 2) % 4].point.y);
            Expect("opposite borders match", fabs(Luminance(sample) - Luminance(opposite)) < 0.02);
        }
        NSColor* gutter = SampleAt(darkRaster, view, 2, 2);
        Expect("dark gutter is painted around the page", ColorMatchesHex(gutter, 0x0A0A0A));
        Expect("gutter sits below the sheet", Luminance(gutter) < Luminance(sheet));

        // --- Every document view the app installs carries the theme ------
        // The gap that let a real bug ship: SPDFDocumentView is well covered
        // GIVEN a variant, but nothing asserted the app hands it one. A tab
        // switch builds a fresh view (-replaceDocumentViewForTabSwitch), and a
        // fresh view defaults to Light -- so while the page bitmap was recolored
        // dark by the core, the viewport's gutter fell back to the system canvas
        // colour (#1C1C1C, two levels off the #1E1E1E paper: no visible edge)
        // and pageBorderColor was nil, dropping the border that stands in for
        // the drop shadow in dark. First: the hazard is real.
        SPDFDocumentView* fresh = [[SPDFDocumentView alloc] initWithFrame:NSMakeRect(0, 0, 120, 160)];
        Expect("a fresh document view defaults to light", fresh.themeVariant == SPDFMarkdownThemeVariantLight);
        Expect("so its gutter is not the dark gutter", !ColorMatchesHex(fresh.viewportBackgroundColor, 0x0A0A0A));
        Expect("and it draws no page border", fresh.pageBorderColor == nil);
        // Second: the construction site closes it. Source contract, in the style
        // of SPDFMacTabLifecycleTests -- the wiring is a plain assignment in the
        // delegate, which this suite cannot instantiate.
        NSString* testPath = @(__FILE__);
        NSString* dir = testPath.stringByDeletingLastPathComponent;
        NSError* readError = nil;
        NSString* viewState = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"../SPDFMacTabViewState.mm"]
                                                       encoding:NSUTF8StringEncoding
                                                          error:&readError];
        Expect("the tab view-state source is readable", viewState != nil);
        Expect("the document view a tab switch installs is given the live reading theme",
               [viewState containsString:@"view.themeVariant = self.markdownThemeVariant"]);
        NSString* coordinator = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"../ShenzhenPDFMac.mm"]
                                                         encoding:NSUTF8StringEncoding
                                                            error:&readError];
        Expect("the coordinator source is readable", coordinator != nil);
        // The minimap is constructed after -applyReadingThemeToDocumentViewport
        // runs, so that call set the variant on nil; it is seeded at creation.
        Expect("the minimap strip is seeded with the reading theme where it is created",
               [coordinator containsString:@"_minimapView.themeVariant = self.markdownThemeVariant"]);

        // Light keeps the sheet edge-to-edge white: no border stroke on it.
        view.themeVariant = SPDFMarkdownThemeVariantLight;
        NSBitmapImageRep* lightRaster = RasterizeView(view);
        for (size_t i = 0; i < sizeof(edges) / sizeof(edges[0]); ++i) {
            NSColor* sample = SampleAt(lightRaster, view, edges[i].point.x, edges[i].point.y);
            Expect("light page edge stays white", Luminance(sample) > 0.9);
        }

        // Presentation mode is pure black in both, with no border frame.
        view.presentationMode = YES;
        view.themeVariant = SPDFMarkdownThemeVariantDark;
        NSBitmapImageRep* presentationRaster = RasterizeView(view);
        NSRect presentationRect = [view rectForPageAtIndex:0];
        Expect("presentation gutter is black", Luminance(SampleAt(presentationRaster, view, 1, 1)) < 0.02);
        // No frame in presentation: the edge pixel is the same sheet as the
        // interior. Comparing the two is what proves the border is absent --
        // asserting a fixed brightness would only re-state the sheet color.
        NSColor* presentationEdge = SampleAt(presentationRaster, view, NSMidX(presentationRect),
                                             NSMinY(presentationRect) + 0.5);
        NSColor* presentationSheet = SampleAt(presentationRaster, view, NSMidX(presentationRect),
                                              NSMinY(presentationRect) + 2.0);
        Expect("presentation draws no page border",
               fabs(Luminance(presentationEdge) - Luminance(presentationSheet)) < 0.02);
        view.presentationMode = NO;

        // --- The single-segment toolbar pill -----------------------------
        NSImage* icon = [NSImage imageWithSystemSymbolName:@"moon.stars" accessibilityDescription:@"Dark"];
        NSSegmentedControl* single = spdf_single_toolbar_segment(nil, @selector(description), icon);
        NSSegmentedControl* paired = spdf_paired_toolbar_segments(nil, @selector(description), icon, icon);
        Expect("single pill has one segment", single.segmentCount == 1);
        Expect("single pill matches the paired pill's style", single.segmentStyle == paired.segmentStyle &&
                                                                  single.segmentStyle == NSSegmentStyleRounded);
        Expect("single pill tracks momentarily", single.trackingMode == NSSegmentSwitchTrackingMomentary &&
                                                     single.trackingMode == paired.trackingMode);
        Expect("single pill carries its image", [single imageForSegment:0] == icon);
        Expect("single pill is autolayout-ready", !single.translatesAutoresizingMaskIntoConstraints);
        Expect("single pill hugs its content",
               [single contentHuggingPriorityForOrientation:NSLayoutConstraintOrientationHorizontal] ==
                   [paired contentHuggingPriorityForOrientation:NSLayoutConstraintOrientationHorizontal]);

        // --- Where Translate may act -------------------------------------
        spdf_translation_context pdfNoSelection = {};
        pdfNoSelection.pdfDocumentOpen = true;
        Expect("PDF without a selection still offers whole-document translation",
               spdf_translation_command_enabled(pdfNoSelection));
        Expect("PDF without a selection has no selection translation",
               !spdf_translation_selection_enabled(pdfNoSelection));

        spdf_translation_context pdfSelection = pdfNoSelection;
        pdfSelection.hasSelection = true;
        Expect("PDF selection translates", spdf_translation_selection_enabled(pdfSelection));

        spdf_translation_context busyPDF = pdfSelection;
        busyPDF.translationRunning = true;
        Expect("a running translation blocks a second one", !spdf_translation_command_enabled(busyPDF));
        busyPDF.translationRunning = false;
        busyPDF.translationInstallRunning = true;
        Expect("a running installer blocks translation", !spdf_translation_command_enabled(busyPDF));

        // Markdown: text is all selection translation needs, and a whole
        // document is reached by rendering it to a PDF first, so neither is
        // blocked.
        spdf_translation_context markdownNoSelection = {};
        markdownNoSelection.markdownActive = true;
        Expect("Markdown without a selection translates as a whole document",
               spdf_translation_command_enabled(markdownNoSelection));
        Expect("whole-document translation reaches Markdown through its PDF rendition",
               spdf_translation_whole_document_available(markdownNoSelection));
        spdf_translation_context busyMarkdownWhole = markdownNoSelection;
        busyMarkdownWhole.translationRunning = true;
        Expect("but not while one is already running",
               !spdf_translation_command_enabled(busyMarkdownWhole));

        spdf_translation_context markdownSelection = markdownNoSelection;
        markdownSelection.hasSelection = true;
        Expect("Markdown selection translates", spdf_translation_selection_enabled(markdownSelection));
        Expect("Markdown selection enables the Translate command",
               spdf_translation_command_enabled(markdownSelection));

        spdf_translation_context busyMarkdown = markdownSelection;
        busyMarkdown.translationRunning = true;
        Expect("a running translation blocks Markdown too",
               !spdf_translation_command_enabled(busyMarkdown));

        printf("SPDFMacReadingThemeChromeTests passed\n");
    }
    return 0;
}
