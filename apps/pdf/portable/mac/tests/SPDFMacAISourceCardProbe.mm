// Citations of a document whose tab has closed, driven through the real reader, chat and Collection, offscreen.
//
// The reported answer cited a saved revision the assistant had read from History: an editable copy inside
// Collection. By the time it was clicked that tab had closed, the link resolved against open tabs, the Collection
// rows' source paths and recent files only, and said "Can't find this document" although the file was there. Here
// the same setup is built in a private state folder (never the user's own data, Keychain or windows): a Collection
// document with two revisions, the earlier one opened from History as an editable copy, read by the assistant, then
// closed. Clicking the answer's inline citation, and its source card, must open that copy at the cited page; a
// citation of a document deleted since must be plain text; and the assistant must be told about the deleted one.
#define SPDF_WORKSPACE_PROBE_REUSE
#import "SPDFMacWorkspaceProbe.mm"
#import "SPDFMacAIIntegration.h"
#import "SPDFMacAIChatSession.h"
#import "SPDFMacAIChatStore.h"
#import "SPDFMacAIChatView.h"
#import "SPDFMacAITools.h"
#import "SPDFMacAIReaderControls.h"
#import "SPDFMacAIDocumentAvailability.h"
#import "SPDFMacAISourceCardView.h"
#import "SPDFMacSearchFileCache.h"

@interface ShenzhenMacDelegate (AISourceCardAccess)
- (id)readerAIState;
- (void)showAIChat:(id)sender;
- (NSInteger)indexOfTabForPath:(NSString*)path;
- (void)closeTabAtIndex:(NSInteger)index;
@end

// The reader brings its window forward when it opens a document; the probe's window must stay offscreen.
@interface SourceCardReader : WorkspaceReaderProbe
@property(nonatomic) NSUInteger activations;
@end
@implementation SourceCardReader
- (void)activateWindowForExternalOpen { self.activations++; }
// A probe binary has no bundle identifier, so it cannot ask which other ShenzhenPDF windows (processes) are running;
// none of them is the probe's.
- (NSArray<NSRunningApplication*>*)otherRunningShenzhenApplications { return @[]; }
@end

static void TwoPagePDF(NSString* path, NSString* heading) {
    NSMutableData* data = [NSMutableData data]; CGRect paper = CGRectMake(0, 0, 595, 842);
    CGDataConsumerRef consumer = CGDataConsumerCreateWithCFData((__bridge CFMutableDataRef)data);
    CGContextRef context = CGPDFContextCreate(consumer, &paper, NULL); CGDataConsumerRelease(consumer);
    for (int page = 1; page <= 2; page++) {
        CGPDFContextBeginPage(context, NULL);
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:context flipped:NO];
        [NSColor.whiteColor setFill]; NSRectFill(NSRectFromCGRect(paper));
        [(page == 1 ? [NSColor colorWithSRGBRed:.16 green:.2 blue:.3 alpha:1] : [NSColor colorWithSRGBRed:.55 green:.16 blue:.12 alpha:1]) setFill];
        NSRectFill(NSMakeRect(40, 520, 515, 260));
        NSDictionary* big = @{NSFontAttributeName : [NSFont boldSystemFontOfSize:30], NSForegroundColorAttributeName : NSColor.whiteColor};
        [[NSString stringWithFormat:@"%@ · page %d", heading, page] drawAtPoint:NSMakePoint(60, 640) withAttributes:big];
        [(page == 2 ? @"IR at 100%; filter fitted" : @"Earlier frame") drawAtPoint:NSMakePoint(60, 440)
            withAttributes:@{NSFontAttributeName : [NSFont systemFontOfSize:22]}];
        [NSGraphicsContext restoreGraphicsState]; CGPDFContextEndPage(context);
    }
    CGPDFContextClose(context); CGContextRelease(context);
    // In place, as an app saving a file does: a new inode would make Collection start a separate document.
    Check([data writeToFile:path atomically:NO], @"fixture PDF written");
}

// A click puts the insertion point in an answer, and the system's text-input cursor helper then opens and closes a
// window of its own (TUINSWindow). It is not the reader's; every other window stays under the probe's guard.
static IMP AppKitWindowOrder, ProbeWindowGuard;
static void TextInputAwareGuard(id window, SEL action, NSInteger place, NSInteger other) {
    IMP next = [NSStringFromClass([window class]) hasPrefix:@"TUI"] ? AppKitWindowOrder : ProbeWindowGuard;
    ((void (*)(id, SEL, NSInteger, NSInteger))next)(window, action, place, other);
}
static void InstallWindowGuard(void) {
    Method order = class_getInstanceMethod(NSWindow.class, @selector(orderWindow:relativeTo:));
    AppKitWindowOrder = method_getImplementation(order);
    spdf_sidebar_probe_install_order_guard();
    ProbeWindowGuard = method_setImplementation(order, (IMP)TextInputAwareGuard);
}

static NSString* JSON(id value) {
    return [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:value options:0 error:nil]
                                 encoding:NSUTF8StringEncoding];
}

static void Wait(BOOL (^done)(void), NSTimeInterval seconds) {
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!done() && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
}

static void Find(NSView* view, Class kind, NSMutableArray* found) {
    if ([view isKindOfClass:kind]) [found addObject:view];
    for (NSView* child in view.subviews) Find(child, kind, found);
}

// Unordered windows discard sendEvent, so clicks need the window realized: fully transparent, 10,000 points off
// screen, ordered without activating, and treated as key in an active app so the click is not an activation click
// (as SPDFMacSidebarHitProbe.mm does). Methods are swapped, never the window's class.
static BOOL Yes(id object, SEL selector) { (void)object; (void)selector; return YES; }
static NSRect Unconstrained(id object, SEL selector, NSRect frame, NSScreen* screen) {
    (void)object; (void)selector; (void)screen; return frame;
}
// The probe's app may never become active, so AppKit would take every first click as the one that activates the
// window (the real app makes the window key before dispatching, spdf_window_activate_for_click_event).
static BOOL AcceptsFirstMouse(id object, SEL selector, NSEvent* event) { (void)object; (void)selector; (void)event; return YES; }
static void Realize(NSWindow* window, BOOL realize) {
    static IMP key, active, constrain, viewFirst, textFirst; static NSRect frame;
    Method viewFirstMethod = class_getInstanceMethod(NSView.class, @selector(acceptsFirstMouse:));
    Method textFirstMethod = class_getInstanceMethod(NSTextView.class, @selector(acceptsFirstMouse:));
    Method keyMethod = class_getInstanceMethod(NSWindow.class, @selector(isKeyWindow));
    Method activeMethod = class_getInstanceMethod(NSApplication.class, @selector(isActive));
    Method constrainMethod = class_getInstanceMethod(NSWindow.class, @selector(constrainFrameRect:toScreen:));
    if (realize) {
        frame = window.frame;
        key = method_setImplementation(keyMethod, (IMP)Yes); active = method_setImplementation(activeMethod, (IMP)Yes);
        constrain = method_setImplementation(constrainMethod, (IMP)Unconstrained);
        viewFirst = method_setImplementation(viewFirstMethod, (IMP)AcceptsFirstMouse);
        textFirst = method_setImplementation(textFirstMethod, (IMP)AcceptsFirstMouse);
        window.alphaValue = 0; [window setFrameOrigin:NSMakePoint(-10000, -10000)];
        Check(window.alphaValue == 0 && NSMaxX(window.frame) < -1000, @"click fixture is transparent and offscreen");
        ((void (*)(id, SEL, NSInteger, NSInteger))AppKitWindowOrder)(window, @selector(orderWindow:relativeTo:), NSWindowBelow, 0);
    } else {
        ((void (*)(id, SEL, NSInteger, NSInteger))AppKitWindowOrder)(window, @selector(orderWindow:relativeTo:), NSWindowOut, 0);
        method_setImplementation(keyMethod, key); method_setImplementation(activeMethod, active);
        method_setImplementation(constrainMethod, constrain);
        method_setImplementation(viewFirstMethod, viewFirst); method_setImplementation(textFirstMethod, textFirst);
        [window setFrame:frame display:NO]; window.alphaValue = 1;
    }
}

// A real left click: the mouse-up is queued first, so NSTextView's own click tracking ends on it.
static void Click(NSView* view, NSPoint point) {
    NSWindow* window = view.window; NSPoint location = [view convertPoint:point toView:nil];
    NSEvent* (^event)(NSEventType) = ^NSEvent*(NSEventType type) {
        return [NSEvent mouseEventWithType:type location:location modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime
                              windowNumber:window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
    };
    [NSApp postEvent:event(NSEventTypeLeftMouseUp) atStart:YES];
    [window sendEvent:event(NSEventTypeLeftMouseDown)];
    NSEvent* left = [NSApp nextEventMatchingMask:NSEventMaskLeftMouseUp untilDate:[NSDate distantPast]
                                          inMode:NSDefaultRunLoopMode dequeue:YES];
    if (left) [window sendEvent:left];
}

static void Snapshot(NSView* view, NSString* path) {
    [view.window.contentView layoutSubtreeIfNeeded];
    NSBitmapImageRep* bitmap = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
    Check([[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES],
          [@"wrote " stringByAppendingString:path.lastPathComponent]);
}

int main(int argc, const char* argv[]) { @autoreleasepool {
    if (argc != 2) return 2;
    NSString* output = [NSString stringWithUTF8String:argv[1]];
    NSString* root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSFileManager* fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:[root stringByAppendingPathComponent:@"source"] withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:output withIntermediateDirectories:YES attributes:nil error:nil];
    setenv("SPDF_STATE_DIR", root.UTF8String, 1); setenv("SPDF_NO_WINDOW_FIRST", "1", 1);
    setenv("SZFRIENDS_STATE_DIR", root.UTF8String, 1);
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    InstallWindowGuard();

    // A Collection document with two revisions; History opens the earlier one as an editable copy.
    NSString* source = [root stringByAppendingPathComponent:@"source/OV50X_Before_vs_IR_On_4_Images.pdf"];
    TwoPagePDF(source, @"Earlier revision");
    SPDFMacCollectionStore* store = SPDFMacCollectionStore.defaultStore; NSError* error = nil;
    Check([store updateSettings:@{@"choice" : @"enabled"} error:&error], @"Collection enabled in the probe's state");
    NSDictionary* first = [store capturePath:source reason:@"Opened" error:&error];
    [NSThread sleepForTimeInterval:1.1];
    TwoPagePDF(source, @"Latest revision");
    NSDictionary* second = [store capturePath:source reason:@"Opened" error:&error];
    NSString* documentID = second[@"id"] ?: first[@"id"];
    NSArray* versions = [store versionsForDocumentID:documentID ?: @""];
    Check(versions.count == 2, [NSString stringWithFormat:@"two saved revisions (%lu)", (unsigned long)versions.count]);
    NSString* copy = [store editableVersionID:[versions.firstObject objectForKey:@"id"] documentID:documentID ?: @""
                                        error:&error].path;
    Check(copy.length && [copy containsString:@"/Collection/editable/"], @"History opened the earlier revision as an editable copy");

    // A second document the assistant read, deleted before the answer is looked at.
    NSString* deleted = [root stringByAppendingPathComponent:@"source/Deleted notes.pdf"];
    TwoPagePDF(deleted, @"Deleted");

    NSString* fixture = [root stringByAppendingPathComponent:@"source/Interface specification.pdf"];
    TwoPagePDF(fixture, @"Interface specification");
    SourceCardReader* reader = [SourceCardReader new];
    [reader prepare:[NSURL fileURLWithPath:fixture] width:1420 dark:NO];

    // The assistant read page 2 of the editable copy (its tab was open then) and the other document.
    NSMutableArray* messages = [NSMutableArray arrayWithObject:@{@"role" : @"user", @"content" : @"find the one with ir at 100%"}];
    NSMutableArray* citations = [NSMutableArray array];
    for (NSString* path in @[ copy ?: @"", deleted ]) {
        NSString* identifier = SPDFAIDocumentIdentifier(path);
        NSString* citation = [NSString stringWithFormat:@"spdf-ai://document?path=%@&page=2&revision=%@", identifier,
                              SPDFSearchFileStamp(path)];
        [citations addObject:citation];
        NSString* call = [NSString stringWithFormat:@"read-%lu", (unsigned long)citations.count];
        [messages addObject:@{@"role" : @"assistant", @"content" : @"", @"tool_calls" : @[ @{@"id" : call, @"type" : @"function",
            @"function" : @{@"name" : @"read_pages", @"arguments" : JSON(@{@"path" : identifier, @"page" : @2, @"count" : @1})}} ]}];
        [messages addObject:@{@"role" : @"tool", @"tool_call_id" : call, @"content" : JSON(@{@"revision" : SPDFSearchFileStamp(path),
            @"pages" : @[ @{@"page" : @2, @"citation" : citation, @"text" : @"IR at 100%; filter fitted"} ]})}];
        // As after a relaunch, the window does not remember handing out the copy's ID: only Collection can find it.
        if (path == deleted) [reader aiNoteDocumentIdentifier:identifier path:path];
    }
    // The reported answer, word for word, with this probe's document ID and revision in its link.
    NSString* answer = [NSString stringWithFormat:@"The \"IR at 100%%\" figure appears only in **`OV50X_Before_vs_IR_On_4_Images.pdf`** — "
        @"2 pages (\"8K – earlier vs IR on\" and \"Binned – earlier vs IR on\"), where the new frame notes \"IR at 100%%; "
        @"filter fitted\" [OV50X_Before_vs_IR_On_4_Images · p. 2](%@). Note it is a filter/IR-blocking test (earlier vs IR "
        @"on), not a controlled IR-off/IR-on measurement; the OV50Q40 doc uses 4 kHz PWM at 10%% duty instead.", citations[0]];
    [messages addObject:@{@"role" : @"assistant", @"content" : answer}];
    [messages addObject:@{@"role" : @"user", @"content" : @"and the notes?"}];
    [messages addObject:@{@"role" : @"assistant", @"content" :
        [NSString stringWithFormat:@"They are in [Deleted notes · p. 2](%@).", citations[1]]}];
    Check([fm removeItemAtPath:deleted error:nil], @"second document deleted");

    // The assistant is told, once, that the deleted document is gone, and why a closed one cannot be read.
    NSDictionary* noted = [reader aiResultNotingUnavailableDocuments:@{@"pages" : @[]}];
    Check([noted[@"documentsNoLongerAvailable"][@"documents"] isEqual:@[ SPDFAIDocumentIdentifier(deleted) ]],
          @"the next tool result names the deleted document, and only it");
    Check([[reader aiClosedDocumentMessage:SPDFAIDocumentIdentifier(deleted)] containsString:@"Do not cite it"],
          @"a tool given the deleted document's ID says it is gone");
    Check([reader aiResultNotingUnavailableDocuments:@{}] == nil, @"each deleted document is reported once");

    id state = [reader readerAIState]; SPDFMacAIChatStore* chats = [state valueForKey:@"store"];
    NSString* chatID = NSUUID.UUID.UUIDString;
    Check([chats saveChat:@{@"id" : chatID, @"title" : @"IR at 100%", @"updated" : @(NSDate.date.timeIntervalSince1970),
        @"messages" : messages} error:nil], @"chat saved in the probe's state");
    SPDFMacAIChatView* view = [state valueForKey:@"view"];
    [[state valueForKey:@"session"] loadChat:[chats chatWithID:chatID]];
    [reader showAIChat:nil];
    // The first draw links everything; the document index then redraws without the deleted document's link.
    Wait(^BOOL { NSMutableArray* cards = [NSMutableArray array]; Find(view, SPDFMacAISourceCardView.class, cards);
        return [[cards.lastObject thumbnail] isKindOfClass:NSImage.class] && [view.subviews count]; }, 8);
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.5]];

    NSMutableArray<NSTextView*>* texts = [NSMutableArray array]; Find(view, NSTextView.class, texts);
    NSTextView* cited = nil, *stale = nil;
    for (NSTextView* text in texts) {
        if ([text.string containsString:@"filter/IR-blocking"]) cited = text;
        if ([text.string containsString:@"They are in"]) stale = text;
    }
    __block NSURL* inlineLink = nil; __block NSRange inlineRange = {NSNotFound, 0};
    [cited.textStorage enumerateAttribute:NSLinkAttributeName inRange:NSMakeRange(0, cited.textStorage.length) options:0
                               usingBlock:^(id value, NSRange range, BOOL* stop) {
        if (value) { inlineLink = value; inlineRange = range; *stop = YES; }
    }];
    Check([inlineLink.absoluteString isEqual:citations[0]], @"the citation of the closed editable copy stays a link");
    __block BOOL staleLinked = NO;
    [stale.textStorage enumerateAttribute:NSLinkAttributeName inRange:NSMakeRange(0, stale.textStorage.length) options:0
                               usingBlock:^(id value, NSRange range, BOOL* stop) { (void)range; (void)stop; if (value) staleLinked = YES; }];
    Check(stale && [stale.string containsString:@"Deleted notes · p. 2"] && !staleLinked,
          @"the deleted document's citation is plain text");

    NSMutableArray<SPDFMacAISourceCardView*>* cards = [NSMutableArray array]; Find(view, SPDFMacAISourceCardView.class, cards);
    Check(cards.count == 1, [NSString stringWithFormat:@"only the answer citing an available document has a card (%lu)",
          (unsigned long)cards.count]);
    SPDFMacAISourceCardView* card = cards.firstObject;
    for (SPDFMacAISourceCardView* candidate in cards) if ([candidate.link.absoluteString isEqual:citations[0]]) card = candidate;
    Check([card.title isEqual:@"OV50X_Before_vs_IR_On_4_Images"] && card.page == 2 && card.thumbnail,
          @"the card shows the document's title, page 2 and that page's thumbnail");
    [reader capture:[output stringByAppendingPathComponent:@"ai-source-card-reader.png"] width:1420 sidebar:YES map:NO];
    Snapshot(view, [output stringByAppendingPathComponent:@"ai-source-card-chat.png"]);
    Check([reader indexOfTabForPath:copy] < 0, @"the editable copy is not open before the click");

    Realize(view.window, YES);
    __block NSMutableArray<NSURL*>* opened = [NSMutableArray array];
    void (^forward)(NSURL*) = view.openLink;
    view.openLink = ^(NSURL* URL) { [opened addObject:URL]; forward(URL); };
    // Click the inline citation where it is drawn.
    [cited.layoutManager ensureLayoutForTextContainer:cited.textContainer];
    NSRange glyphs = [cited.layoutManager glyphRangeForCharacterRange:inlineRange actualCharacterRange:NULL];
    NSRect box = [cited.layoutManager boundingRectForGlyphRange:glyphs inTextContainer:cited.textContainer];
    box = NSOffsetRect(box, cited.textContainerOrigin.x, cited.textContainerOrigin.y);
    [cited scrollRectToVisible:box];
    Click(cited, NSMakePoint(NSMinX(box) + 6, NSMidY(box)));
    Wait(^BOOL { return [[reader aiReaderControls][@"path"] isEqual:copy] && [[reader valueForKey:@"pageIndex"] integerValue] == 1; }, 8);
    Check(opened.count == 1 && [opened.firstObject.absoluteString isEqual:citations[0]], @"the click reached the citation's link");
    Check([[reader aiReaderControls][@"path"] isEqual:copy], @"the inline citation opens the editable copy it cited");
    Check([[reader valueForKey:@"pageIndex"] integerValue] == 1, @"the inline citation opens it at page 2");
    Snapshot(view.window.contentView, [output stringByAppendingPathComponent:@"ai-source-card-after-inline-click.png"]);

    // Close it again, then click the card.
    [reader closeTabAtIndex:[reader indexOfTabForPath:copy]];
    Check([reader indexOfTabForPath:copy] < 0, @"the editable copy is closed again");
    [card scrollRectToVisible:card.bounds];
    Click(card, NSMakePoint(NSMidX(card.bounds), NSMidY(card.bounds)));
    Wait(^BOOL { return [[reader aiReaderControls][@"path"] isEqual:copy] && [[reader valueForKey:@"pageIndex"] integerValue] == 1; }, 8);
    Check([[reader aiReaderControls][@"path"] isEqual:copy] && [[reader valueForKey:@"pageIndex"] integerValue] == 1,
          @"the source card opens the cited copy at page 2");
    Snapshot(view.window.contentView, [output stringByAppendingPathComponent:@"ai-source-card-after-card-click.png"]);

    Realize(view.window, NO);
    [reader closeTabAtIndex:[reader indexOfTabForPath:copy]];
    [reader aiNoteDocumentIdentifier:SPDFAIDocumentIdentifier(copy) path:copy];
    Check([[reader aiClosedDocumentMessage:SPDFAIDocumentIdentifier(copy)] containsString:@"no longer open"],
          @"a tool given a closed document's ID says it is closed, not gone");
    for (NSWindow* window in NSApp.windows) Check(!window.visible, @"no window was shown");
    [fm removeItemAtPath:root error:nil];
    fprintf(stderr, "AI source card probe: %lu failures\n", (unsigned long)failures);
    return failures ? 1 : 0;
}}
