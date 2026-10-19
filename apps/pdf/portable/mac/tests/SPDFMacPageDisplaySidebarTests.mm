// Sidebar rebuilds after an open (part of mac-page-display-tests).
//
// The failure it guards: an open that loaded the outline and comments before its
// first frame -- at launch, or with the window not on screen yet -- rebuilt the
// sidebar with them, and its metadata warm stage ~100 ms later reloaded both
// from the tab's cache and rebuilt the sidebar twice more (2 x ~20-27 ms on the
// main thread for a 5-page schematic) with nothing changed. A mid-session open
// loads them in the background; those late lists must still reach the sidebar.
#import "SPDFMacPageDisplayTestSupport.h"
#import <PDFKit/PDFKit.h>
#import <objc/runtime.h>

// A sheet set with three chapters and one comment, written by PDFKit.
static NSString* WriteOutlinedDocument(NSString* dir, NSString* name) {
    NSString* plain = PageDisplayWriteDrawingSet(dir, [@"plain-" stringByAppendingString:name], 4, 200);
    PDFDocument* document = [[PDFDocument alloc] initWithURL:[NSURL fileURLWithPath:plain]];
    PDFOutline* root = [PDFOutline new];
    for (NSUInteger i = 0; i < 3; i++) {
        PDFOutline* item = [PDFOutline new];
        item.label = [NSString stringWithFormat:@"Sheet %lu wiring", (unsigned long)i + 1];
        item.destination = [[PDFDestination alloc] initWithPage:[document pageAtIndex:i] atPoint:NSMakePoint(0, 800)];
        [root insertChild:item atIndex:i];
    }
    document.outlineRoot = root;
    PDFAnnotation* note = [[PDFAnnotation alloc] initWithBounds:NSMakeRect(100, 100, 20, 20)
                                                        forType:PDFAnnotationSubtypeText
                                                 withProperties:nil];
    note.contents = @"Check the ground pour";
    [[document pageAtIndex:1] addAnnotation:note];
    NSString* path = [dir stringByAppendingPathComponent:name];
    [document writeToFile:path];
    return path;
}

// Stands in for the window being on screen, which is what makes a mid-session
// open load its outline and comments in the background.
static IMP gOriginalIsVisible;
static __weak NSWindow* gVisibleWindow;
static BOOL ForcedVisible(NSWindow* window, SEL _cmd) {
    if (window == gVisibleWindow) return YES;
    return ((BOOL (*)(id, SEL))gOriginalIsVisible)(window, _cmd);
}

static NSUInteger ChapterRows(PageDisplayReader* reader) {
    NSUInteger rows = 0;
    for (NSDictionary* item in reader.sidebarItemsCopy)
        if ([item[@"kind"] isEqualToString:@"chapter"] && [item[@"title"] hasSuffix:@" wiring"]) rows++;
    return rows;
}
static NSUInteger CommentRows(PageDisplayReader* reader) {
    NSUInteger rows = 0;
    for (NSDictionary* item in reader.sidebarItemsCopy)
        if ([item[@"kind"] isEqualToString:@"comment"]) rows++;
    return rows;
}
// Both lists adopted, and the sidebar rebuilt from them: it lists the three
// chapters, or -- when the comment landed first and the sidebar switched to
// comments, as it always has -- the one comment.
static BOOL ShowsLateLists(PageDisplayReader* reader) {
    return reader.activeOutlineCount == 3 && reader.activeCommentCount == 1 &&
           (ChapterRows(reader) == 3 || CommentRows(reader) == 1);
}

void PageDisplaySidebarChecks(PageDisplayReader* reader, NSString* root) {
    NSString* outlined = WriteOutlinedDocument(root, @"Outlined set.pdf");
    NSString* late = WriteOutlinedDocument(root, @"Outlined late.pdf");

    // Window not on screen: the open loads the outline and comments before its
    // first frame and rebuilds the sidebar with them, once.
    PageDisplayCheck(!reader.testWindow.visible, @"sidebar: the test window is not on screen");
    NSInteger tab = PageDisplayAddTab(reader, outlined, 1);
    reader.sidebarRebuilds = 0;
    [reader selectTabAtIndex:tab];
    NSUInteger duringOpen = reader.sidebarRebuilds;
    PageDisplayCheck(ChapterRows(reader) == 3 && reader.activeCommentCount == 1,
                     [NSString stringWithFormat:@"sidebar: the open shows the 3 chapters and 1 comment before its "
                                                @"first frame (%lu chapters, %d comments)",
                                                (unsigned long)ChapterRows(reader), reader.activeCommentCount]);
    PageDisplayCheck(PageDisplayRunUntil(30.0, ^{ return reader.allQueuesIdle; }), @"sidebar: the open settles");
    PageDisplayRunFor(1.0); // past every warm stage
    PageDisplayCheck(reader.sidebarRebuilds == duringOpen,
                     [NSString stringWithFormat:@"sidebar: an open with its outline and comments already loaded "
                                                @"rebuilds the sidebar once with them, not again in its warm stages "
                                                @"(%lu more rebuilds)",
                                                (unsigned long)(reader.sidebarRebuilds - duringOpen)]);

    // Switching back to a tab already open: its lists are cached, so the warm
    // stages have nothing to add either.
    NSInteger other = PageDisplayAddTab(reader, PageDisplayWriteDrawingSet(root, @"Other.pdf", 2, 200), 1);
    [reader selectTabAtIndex:other];
    PageDisplayRunUntil(30.0, ^{ return reader.allQueuesIdle; });
    PageDisplayRunFor(1.0);
    reader.sidebarRebuilds = 0;
    [reader selectTabAtIndex:tab];
    duringOpen = reader.sidebarRebuilds;
    PageDisplayRunUntil(30.0, ^{ return reader.allQueuesIdle; });
    PageDisplayRunFor(1.0);
    PageDisplayCheck(ChapterRows(reader) == 3 && reader.sidebarRebuilds == duringOpen,
                     [NSString stringWithFormat:@"sidebar: switching back to an open tab shows its chapters and "
                                                @"does not rebuild again after the switch (%lu chapters, %lu more)",
                                                (unsigned long)ChapterRows(reader),
                                                (unsigned long)(reader.sidebarRebuilds - duringOpen)]);

    // Mid-session, window on screen: the open shows the document at once and the
    // lists arrive from the background; they must still reach the sidebar.
    gOriginalIsVisible = method_setImplementation(class_getInstanceMethod(NSWindow.class, @selector(isVisible)),
                                                  (IMP)ForcedVisible);
    gVisibleWindow = reader.testWindow;
    NSInteger lateTab = PageDisplayAddTab(reader, late, 1);
    reader.sidebarRebuilds = 0;
    [reader selectTabAtIndex:lateTab];
    NSUInteger atOpen = reader.sidebarRebuilds;
    PageDisplayCheck(ChapterRows(reader) == 0,
                     @"sidebar: a mid-session open leaves the outline to the background load");
    PageDisplayCheck(PageDisplayRunUntil(5.0, ^{ return ShowsLateLists(reader); }),
                     [NSString stringWithFormat:@"sidebar: the outline and comment loaded in the background reach the "
                                                @"sidebar (%d/%d adopted, %lu chapter rows, %lu comment rows)",
                                                reader.activeOutlineCount, reader.activeCommentCount,
                                                (unsigned long)ChapterRows(reader), (unsigned long)CommentRows(reader)]);
    PageDisplayCheck(reader.sidebarRebuilds >= atOpen + 2,
                     @"sidebar: each late list rebuilds the sidebar when it lands");
    gVisibleWindow = nil;
    method_setImplementation(class_getInstanceMethod(NSWindow.class, @selector(isVisible)), gOriginalIsVisible);
    PageDisplayRunUntil(30.0, ^{ return reader.allQueuesIdle; });
}
