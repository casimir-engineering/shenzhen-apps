// driver.m: inserted (DYLD_INSERT_LIBRARIES, after tools/updater-e2e/szut.m, which keeps every window off screen,
// refuses the Keychain and sends the model's requests to model_stub.py) into a test copy of ShenzhenPDF.app by
// run_e2e.py. It drives the assistant chat the way a person does: opens the chat from its menu action, types into
// the composer and presses Return, drops files and a folder on the chat window, clicks New chat, and saves a picture
// of the chat after each step. The model's key is a stand-in the stub accepts; nothing reads the Keychain.
//
// Environment: SPDF_E2E_PLAN, a JSON file {"document": path, "questions": {...}, "attach": {"files": [...],
// "folder": path, "sibling": path}}; SPDF_E2E_OUT, the folder for screenshots and result.json.
#import <AppKit/AppKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSDictionary* gPlan;
static NSString* gOut;
static NSMutableDictionary* gResult;

static NSString* StubKey(id self, SEL _cmd, BOOL authorize, NSError** error) {
    (void)self, (void)_cmd, (void)authorize;
    if (error) *error = nil;
    return @"sk-or-v1-e2e-stub-key-not-real-0000000000";
}

static id Main(id (^block)(void)) {
    if (NSThread.isMainThread) return block();
    __block id value = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{ value = block(); });
    return value;
}

static void Log(NSString* text) {
    fprintf(stderr, "[e2e] %s\n", text.UTF8String);
    [gResult[@"log"] addObject:text];
}

static NSView* FindView(NSView* root, NSString* className) {
    if ([NSStringFromClass(root.class) isEqual:className]) return root;
    for (NSView* sub in root.subviews) { NSView* found = FindView(sub, className); if (found) return found; }
    return nil;
}

static NSView* ChatView(void) {
    return Main(^id {
        for (NSWindow* window in NSApp.windows) {
            NSView* found = window.contentView ? FindView(window.contentView.superview ?: window.contentView,
                                                          @"SPDFMacAIChatView") : nil;
            if (found) return found;
        }
        return nil;
    });
}

static id State(void) { return ((id (*)(id, SEL))objc_msgSend)(NSApp.delegate, NSSelectorFromString(@"readerAIState")); }
static id Session(void) { return [State() valueForKey:@"session"]; }

static BOOL WaitFor(NSTimeInterval seconds, BOOL (^done)(void)) {
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (deadline.timeIntervalSinceNow > 0) {
        if ([Main(^id { return @(done()); }) boolValue]) return YES;
        [NSThread sleepForTimeInterval:0.2];
    }
    return NO;
}

static void Shot(NSString* name) {
    Main(^id {
        NSView* chat = ChatView();
        NSView* root = chat.window.contentView ?: chat;
        for (NSView* view in @[ root, chat ]) {
            [view layoutSubtreeIfNeeded];
            NSBitmapImageRep* rep = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
            [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
            NSString* file = [gOut stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@.png", name,
                                                                  view == chat ? @"chat" : @"window"]];
            [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:file atomically:YES];
        }
        return nil;
    });
}

// Types `text` into the composer and presses Return, as the keyboard would.
static void Ask(NSString* text) {
    Log([@"ask: " stringByAppendingString:text]);
    Main(^id {
        NSTextView* composer = [ChatView() valueForKey:@"composer"];
        [composer.window makeFirstResponder:composer];
        [composer insertText:text replacementRange:NSMakeRange(NSNotFound, 0)];
        NSEvent* enter = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0
            timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:composer.window.windowNumber context:nil
            characters:@"\r" charactersIgnoringModifiers:@"\r" isARepeat:NO keyCode:36];
        [composer keyDown:enter];
        return nil;
    });
    BOOL started = WaitFor(10, ^BOOL { return [[Session() valueForKey:@"running"] boolValue]; });
    BOOL ended = WaitFor(240, ^BOOL { return ![[Session() valueForKey:@"running"] boolValue]; });
    Log([NSString stringWithFormat:@"request started %d ended %d", started, ended]);
}

// What the person sees of the last exchange: the answer, the steps and cards since the question.
static NSDictionary* Exchange(NSString* name) {
    return Main(^id {
        id session = Session();
        NSArray* messages = [session valueForKey:@"chat"][@"messages"];
        NSMutableArray* tools = [NSMutableArray array];
        NSString* answer = @"";
        for (NSDictionary* message in messages.reverseObjectEnumerator) {
            if ([message[@"role"] isEqual:@"user"]) break;
            if ([message[@"role"] isEqual:@"tool"]) [tools insertObject:message[@"content"] ?: @"" atIndex:0];
            if ([message[@"role"] isEqual:@"assistant"] && [message[@"content"] length] && !answer.length)
                answer = message[@"content"];
        }
        NSMutableArray* cards = [NSMutableArray array];
        for (NSDictionary* entry in [[session valueForKey:@"activity"] valueForKey:@"entries"])
            [cards addObject:@{@"kind" : entry[@"kind"] ?: @"", @"cardKind" : entry[@"cardKind"] ?: @"",
                               @"title" : entry[@"title"] ?: @"", @"status" : entry[@"status"] ?: @"",
                               @"attachments" : entry[@"attachments"] ?: @[], @"output" : entry[@"output"] ?: @"",
                               @"caption" : [entry[@"image"] isKindOfClass:NSDictionary.class]
                                   ? entry[@"image"][@"caption"] ?: @"" : @""}];
        NSDictionary* exchange = @{@"answer" : answer, @"tools" : tools, @"activity" : cards,
                                   @"status" : [session valueForKey:@"status"] ?: @"",
                                   @"grants" : [session valueForKey:@"grants"] ?: @[]};
        gResult[name] = exchange;
        return exchange;
    });
}

// A drag of `paths` from Finder released over the chat: the view AppKit would deliver it to (the one under the point
// that registered for file URLs) gets the destination calls, in order.
@interface E2EDrag : NSObject
@property NSPasteboard* draggingPasteboard;
@property NSPoint draggingLocation;
@property NSWindow* draggingDestinationWindow;
@end
@implementation E2EDrag
- (NSDragOperation)draggingSourceOperationMask { return NSDragOperationCopy | NSDragOperationGeneric; }
- (id)draggingSource { return nil; }
- (NSInteger)draggingSequenceNumber { return 1; }
- (NSImage*)draggedImage { return nil; }
- (NSPoint)draggedImageLocation { return self.draggingLocation; }
- (BOOL)animatesToDestination { return NO; }
- (void)setAnimatesToDestination:(BOOL)value { (void)value; }
- (NSInteger)numberOfValidItemsForDrop { return 1; }
- (void)setNumberOfValidItemsForDrop:(NSInteger)value { (void)value; }
- (NSDraggingFormation)draggingFormation { return NSDraggingFormationDefault; }
- (void)setDraggingFormation:(NSDraggingFormation)value { (void)value; }
- (void)slideDraggedImageTo:(NSPoint)point { (void)point; }
- (NSSpringLoadingHighlight)springLoadingHighlight { return NSSpringLoadingHighlightNone; }
- (void)resetSpringLoading {}
- (void)enumerateDraggingItemsWithOptions:(NSDraggingItemEnumerationOptions)options forView:(NSView*)view
    classes:(NSArray*)classes searchOptions:(NSDictionary*)search usingBlock:(void (^)(NSDraggingItem*, NSInteger, BOOL*))block {
    (void)options, (void)view, (void)classes, (void)search, (void)block;
}
@end

static void Drop(NSArray<NSString*>* paths, NSString* over) {
    Log([NSString stringWithFormat:@"drop on %@: %@", over, [paths valueForKey:@"lastPathComponent"]]);
    Main(^id {
        NSView* chat = ChatView();
        NSView* target = [over isEqual:@"composer"] ? [chat valueForKey:@"composer"] : [chat valueForKey:@"scroll"];
        NSPoint local = NSMakePoint(NSMidX(target.bounds), NSMidY(target.bounds));
        NSPoint point = [target convertPoint:local toView:nil];
        NSView* root = chat.window.contentView;
        NSView* hit = [root hitTest:[root.superview ?: root convertPoint:point fromView:nil]];
        while (hit && ![hit.registeredDraggedTypes containsObject:NSPasteboardTypeFileURL]) hit = hit.superview;
        E2EDrag* drag = [E2EDrag new];
        drag.draggingPasteboard = [NSPasteboard pasteboardWithUniqueName];
        [drag.draggingPasteboard clearContents];
        NSMutableArray* URLs = [NSMutableArray array];
        for (NSString* path in paths) [URLs addObject:[NSURL fileURLWithPath:path]];
        [drag.draggingPasteboard writeObjects:URLs];
        drag.draggingLocation = point;
        drag.draggingDestinationWindow = chat.window;
        id<NSDraggingDestination> destination = (id)hit;
        NSDragOperation operation = [destination draggingEntered:(id)drag];
        BOOL accepted = operation != NSDragOperationNone &&
            (![destination respondsToSelector:@selector(prepareForDragOperation:)] ||
             [destination prepareForDragOperation:(id)drag]) && [destination performDragOperation:(id)drag];
        Log([NSString stringWithFormat:@"drop delivered to %@, accepted %d", NSStringFromClass(hit.class), accepted]);
        return nil;
    });
    [NSThread sleepForTimeInterval:0.5];
}

static void Click(NSString* identifier) {
    Main(^id {
        NSView* chat = ChatView();
        for (NSView* sub in chat.subviews)
            for (NSView* view in [sub isKindOfClass:NSStackView.class] ? [(NSStackView*)sub views] : @[ sub ])
                if ([view isKindOfClass:NSButton.class] && [view.identifier isEqual:identifier]) {
                    [(NSButton*)view performClick:nil];
                    return nil;
                }
        Log([@"no button " stringByAppendingString:identifier]);
        return nil;
    });
    [NSThread sleepForTimeInterval:0.5];
}

#include "driver_long.h"

static void Run(void) {
    NSDictionary* questions = gPlan[@"questions"];
    // The test profile's Collection: on, holding the report the way it would after the person kept it.
    Main(^id {
        id store = ((id (*)(id, SEL))objc_msgSend)(NSClassFromString(@"SPDFMacCollectionStore"),
                                                  NSSelectorFromString(@"defaultStore"));
        NSError* error = nil;
        ((BOOL (*)(id, SEL, id, NSError**))objc_msgSend)(store, NSSelectorFromString(@"updateSettings:error:"),
                                                          @{@"choice" : @"enabled"}, &error);
        id captured = ((id (*)(id, SEL, id, id, NSError**))objc_msgSend)(store,
            NSSelectorFromString(@"capturePath:reason:error:"), gPlan[@"document"], @"Opened", &error);
        Log([NSString stringWithFormat:@"collection on, document kept: %d %@", captured != nil,
                                       error.localizedDescription ?: @""]);
        ((void (*)(id, SEL, id))objc_msgSend)(NSApp.delegate, NSSelectorFromString(@"openPath:"), gPlan[@"document"]);
        return nil;
    });
    [NSThread sleepForTimeInterval:3];
    Main(^id { [NSApp sendAction:NSSelectorFromString(@"showAIChat:") to:nil from:nil]; return nil; });
    if (!WaitFor(20, ^BOOL { return ChatView() != nil; })) { Log(@"no chat view"); return; }
    [NSThread sleepForTimeInterval:1];
    Shot(@"0-open");

    Ask(questions[@"gray"]);
    Exchange(@"gray");
    Shot(@"1-gray");
    Ask(questions[@"files"]);
    Exchange(@"files");
    Shot(@"2-files");

    // Chat A: files and a folder dropped on the chat window.
    Click(@"new");
    NSDictionary* attach = gPlan[@"attach"];
    Drop(attach[@"files"], @"transcript");
    Drop(@[ attach[@"folder"] ], @"composer");
    Exchange(@"chips");
    Shot(@"3-chips");
    Ask([NSString stringWithFormat:questions[@"attached"], attach[@"sibling"]]);
    Exchange(@"attached");
    Shot(@"4-attached");
    Ask(questions[@"parts"]);
    Exchange(@"parts");
    Shot(@"5-parts");
    NSString* folderID = nil;
    for (NSDictionary* grant in gResult[@"parts"][@"grants"])
        if ([grant[@"kind"] isEqual:@"folder"]) folderID = grant[@"id"];
    gResult[@"folder_id"] = folderID ?: @"";

    // Chat B, in the same window: it asks for chat A's folder by its id.
    Click(@"new");
    Ask([NSString stringWithFormat:questions[@"other"], folderID ?: @"attachment:none"]);
    Exchange(@"other");
    Shot(@"6-other-chat");
}

__attribute__((constructor)) static void E2EInit(void) {
    const char* plan = getenv("SPDF_E2E_PLAN"), *out = getenv("SPDF_E2E_OUT");
    if (!plan || !out) return;
    gPlan = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(plan)] options:0 error:nil];
    gOut = @(out);
    gResult = [@{@"log" : [NSMutableArray array]} mutableCopy];
    [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil
                                                     queue:nil usingBlock:^(NSNotification* note) {
        (void)note;
        Class credentials = NSClassFromString(@"SPDFMacAICredentials");
        Method read = class_getInstanceMethod(credentials, NSSelectorFromString(@"readAPIKeyWithAuthorization:error:"));
        if (read) method_setImplementation(read, (IMP)StubKey);
        [NSThread detachNewThreadWithBlock:^{
            [NSThread sleepForTimeInterval:2];
            @try { if ([gPlan[@"scenario"] isEqual:@"long"]) RunLong(); else Run(); } @catch (NSException* exception) { Log([@"exception: " stringByAppendingString:exception.reason]); }
            NSData* json = [NSJSONSerialization dataWithJSONObject:gResult options:NSJSONWritingPrettyPrinted error:nil];
            [json writeToFile:[gOut stringByAppendingPathComponent:@"result.json"] atomically:YES];
            Log(@"done");
            dispatch_async(dispatch_get_main_queue(), ^{ exit(0); });
        }];
    }];
}
