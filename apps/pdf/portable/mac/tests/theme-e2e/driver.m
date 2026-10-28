// driver.m: inserted (DYLD_INSERT_LIBRARIES, after tools/updater-e2e/szut.m, which keeps every window off screen)
// into a test copy of ShenzhenPDF.app by run_e2e.py. It sets up a working reader the way a person would have it:
// documents in several named, coloured tab groups, one group open with three tabs, the sidebar's outline, an
// assistant chat with an answer, the tab-hover label, Settings and the Collection. Then it pictures every window in
// light and dark, so the chrome's colours can be compared with a reference by eye and measured.
//
// SPDF_E2E_PLAN: {"documents": [...], "groups": [{"name", "color", "documents": [...]}], "open_group", "question"};
// SPDF_E2E_OUT: pictures and result.json.
#include "../tab-hover-e2e/hover_harness.h"

static NSString* StubKey(id self, SEL _cmd, BOOL authorize, NSError** error) {
    (void)self, (void)_cmd, (void)authorize;
    if (error) *error = nil;
    return @"sk-or-v1-e2e-stub-key-not-real-0000000000";
}

static NSView* FindIn(NSString* className) {
    for (NSWindow* window in NSApp.windows) {
        NSView* root = window.contentView.superview ?: window.contentView;
        NSView* found = root ? FindView(root, className) : nil;
        if (found) return found;
    }
    return nil;
}
static id ReaderAI(void) { return ((id (*)(id, SEL))objc_msgSend)(Delegate(), NSSelectorFromString(@"readerAIState")); }
static id ChatSession(void) { return [ReaderAI() valueForKey:@"session"]; }

static void Ask(NSString* text) {
    Main(^id {
        NSTextView* composer = [FindIn(@"SPDFMacAIChatView") valueForKey:@"composer"];
        [composer.window makeFirstResponder:composer];
        [composer insertText:text replacementRange:NSMakeRange(NSNotFound, 0)];
        NSEvent* enter = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0
            timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:composer.window.windowNumber context:nil
            characters:@"\r" charactersIgnoringModifiers:@"\r" isARepeat:NO keyCode:36];
        [composer keyDown:enter];
        return nil;
    });
    BOOL started = WaitFor(10, ^BOOL { return [[ChatSession() valueForKey:@"running"] boolValue]; });
    BOOL ended = WaitFor(60, ^BOOL { return ![[ChatSession() valueForKey:@"running"] boolValue]; });
    Log([NSString stringWithFormat:@"chat request started %d ended %d", started, ended]);
}

static NSBitmapImageRep* Snapshot(NSView* view) {
    [view layoutSubtreeIfNeeded];
    [view displayIfNeeded];
    NSBitmapImageRep* rep = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
    return rep;
}

static void Save(NSImage* image, NSString* name) {
    NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithData:image.TIFFRepresentation];
    NSString* file = [gOut stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"png"]];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:file atomically:YES];
    [gResult[@"pictures"] addObject:file];
}

// A whole window as the window server would show it, with its child windows (the tab-hover label, popovers)
// drawn where the app placed them.
static void ShotWindow(NSWindow* window, NSString* name) {
    Main(^id {
        NSView* frameView = window.contentView.superview ?: window.contentView;
        NSSize size = frameView.bounds.size;
        if (size.width < 40 || size.height < 40) return nil;
        NSBitmapImageRep* rep = Snapshot(frameView);
        NSImage* image = [[NSImage alloc] initWithSize:size];
        [image lockFocus];
        [window.effectiveAppearance performAsCurrentDrawingAppearance:^{
            // The frame view leaves the window's own background (the title bar's colour) to the window server.
            [(window.backgroundColor ?: NSColor.windowBackgroundColor) setFill];
            NSRectFill(NSMakeRect(0, 0, size.width, size.height));
            [rep drawInRect:NSMakeRect(0, 0, size.width, size.height) fromRect:NSZeroRect
                  operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
            for (NSWindow* child in window.childWindows) {
                NSView* content = child.contentView;
                if (!content || child.alphaValue < 0.05) continue;
                NSRect frame = NSOffsetRect(child.frame, -NSMinX(window.frame), -NSMinY(window.frame));
                NSShadow* shadow = [NSShadow new];
                shadow.shadowBlurRadius = 12; shadow.shadowOffset = NSMakeSize(0, -4);
                shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.3];
                for (NSView* part in content.subviews.count ? content.subviews : @[ content ]) {
                    if (part.hidden || NSIsEmptyRect(part.frame)) continue;
                    NSRect rect = NSOffsetRect([part convertRect:part.bounds toView:nil], NSMinX(frame), NSMinY(frame));
                    NSBezierPath* shape = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:8 yRadius:8];
                    [NSGraphicsContext saveGraphicsState];
                    [shadow set];
                    [[NSColor colorWithWhite:0.5 alpha:0.01] setFill];
                    [shape fill];
                    [NSGraphicsContext restoreGraphicsState];
                    [NSGraphicsContext saveGraphicsState];
                    [shape addClip];
                    [Snapshot(part) drawInRect:rect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
                                     fraction:1 respectFlipped:YES hints:nil];
                    [NSGraphicsContext restoreGraphicsState];
                }
            }
        }];
        [image unlockFocus];
        Save(image, name);
        return nil;
    });
}

static NSWindow* ReaderWindow(void) { return Strip().window; }

static void ShotAll(NSString* look) {
    ShotWindow(ReaderWindow(), [@"reader-" stringByAppendingString:look]);
    NSArray* windows = Main(^id { return NSApp.windows; });
    NSUInteger n = 0;
    for (NSWindow* window in windows) {
        if (window == ReaderWindow() || window.parentWindow || !window.contentView) continue;
        NSString* kind = Main(^id {
            if (FindView(window.contentView.superview ?: window.contentView, @"SPDFMacAIChatView")) return @"assistant";
            return window.title.length ? window.title : NSStringFromClass(window.class);
        });
        if ([kind hasPrefix:@"NS"] || [kind hasPrefix:@"_"]) continue;
        kind = [[kind componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet]
                   componentsJoinedByString:@"-"].lowercaseString;
        ShotWindow(window, [NSString stringWithFormat:@"%@-%lu-%@", kind, (unsigned long)n++, look]);
    }
}

static id GroupOfTab(NSInteger index) { return index >= 0 ? [Tabs()[(NSUInteger)index] valueForKey:@"group"] : nil; }

static void MakeGroups(void) {
    for (NSDictionary* spec in gPlan[@"groups"]) {
        NSArray* docs = spec[@"documents"];
        Main(^id {
            NSInteger first = TabIndexForName([docs[0] lastPathComponent]);
            NSInteger second = docs.count > 1 ? TabIndexForName([docs[1] lastPathComponent]) : -1;
            ((void (*)(id, SEL, NSInteger, NSInteger, id))objc_msgSend)(Delegate(),
                NSSelectorFromString(@"createGroupForTabAtIndex:withTabAtIndex:color:"), first, second, spec[@"color"]);
            id group = GroupOfTab(TabIndexForName([docs[0] lastPathComponent]));
            ((void (*)(id, SEL, id, id))objc_msgSend)(Delegate(), NSSelectorFromString(@"renameTabGroup:name:"), group,
                                                       spec[@"name"]);
            for (NSUInteger i = 2; i < docs.count; i++) {
                NSInteger index = TabIndexForName([docs[i] lastPathComponent]);
                NSArray* members = Tabs();
                NSInteger destination = 0;
                for (NSUInteger t = 0; t < members.count; t++) if ([members[t] valueForKey:@"group"] == group) destination++;
                ((void (*)(id, SEL, NSInteger, id, NSInteger))objc_msgSend)(Delegate(),
                    NSSelectorFromString(@"moveTabAtIndex:toGroup:atIndex:"), index, group, destination);
            }
            return nil;
        });
        Wait(0.4);
    }
}

static void Run(void) {
    // The test profile's Collection is on, so the Collection window has something to show.
    Main(^id {
        id store = ((id (*)(id, SEL))objc_msgSend)(NSClassFromString(@"SPDFMacCollectionStore"),
                                                  NSSelectorFromString(@"defaultStore"));
        NSError* error = nil;
        ((BOOL (*)(id, SEL, id, NSError**))objc_msgSend)(store, NSSelectorFromString(@"updateSettings:error:"),
                                                          @{@"choice" : @"enabled"}, &error);
        return nil;
    });
    Main(^id {
        NSWindow* window = ReaderWindow();
        [window setFrame:NSMakeRect(0, 0, 1440, 900) display:YES];
        return nil;
    });
    for (NSString* path in gPlan[@"documents"]) Open(path);
    MakeGroups();
    Expand(gPlan[@"open_group"]);
    NSString* selected = [gPlan[@"selected"] lastPathComponent];
    Select(TabIndexForName(selected));
    gResult[@"groups"] = Main(^id {
        NSMutableArray* names = [NSMutableArray array];
        for (id layout in [Strip() valueForKey:@"groupLayouts"]) {
            id group = [layout valueForKey:@"group"];
            [names addObject:@{@"name" : [group valueForKey:@"displayName"] ?: @"",
                               @"color" : [group valueForKey:@"colorName"] ?: @"",
                               @"header" : NSStringFromRect([[layout valueForKey:@"header"] rectValue]),
                               @"collapsed" : [group valueForKey:@"collapsed"] ?: @NO}];
        }
        return names;
    });
    Main(^id { [NSApp sendAction:NSSelectorFromString(@"showAIChat:") to:nil from:nil]; return nil; });
    if (WaitFor(20, ^BOOL { return FindIn(@"SPDFMacAIChatView") != nil; })) {
        Wait(1);
        Ask(gPlan[@"question"]);
        Wait(1.5);
    } else Log(@"no chat view");
    Main(^id { [NSApp sendAction:NSSelectorFromString(@"showUnifiedSettings:") to:nil from:nil]; return nil; });
    Wait(1.5);
    Main(^id { [NSApp sendAction:NSSelectorFromString(@"showCollectionManager:") to:nil from:nil]; return nil; });
    Wait(2.5);
    NSInteger hovered = TabIndexForName([gPlan[@"hovered"] lastPathComponent]);
    for (NSString* look in @[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]) {
        NSString* suffix = [look isEqual:NSAppearanceNameDarkAqua] ? @"dark" : @"light";
        Appearance(look);
        Wait(0.8);
        ShotAll(suffix);
        // The tab-hover label and page card, over the same window.
        Hover(Centre(TabRect(hovered)), YES);
        Wait(0.8);
        Hover(Centre(TabRect(hovered)), NO);
        ShotWindow(ReaderWindow(), [@"reader-hover-" stringByAppendingString:suffix]);
        Leave();
    }
}

__attribute__((constructor)) static void E2EInit(void) {
    const char* plan = getenv("SPDF_E2E_PLAN"), *out = getenv("SPDF_E2E_OUT");
    // Only in the reader: its helpers (the Collection window, Friends) inherit DYLD_INSERT_LIBRARIES too.
    if (!plan || !out || strcmp(getprogname(), "ShenzhenPDF") != 0) return;
    gPlan = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(plan)] options:0 error:nil];
    gOut = @(out);
    gResult = [@{@"log" : [NSMutableArray array], @"pictures" : [NSMutableArray array]} mutableCopy];
    [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil
                                                     queue:nil usingBlock:^(NSNotification* note) {
        (void)note;
        Class credentials = NSClassFromString(@"SPDFMacAICredentials");
        Method read = class_getInstanceMethod(credentials, NSSelectorFromString(@"readAPIKeyWithAuthorization:error:"));
        if (read) method_setImplementation(read, (IMP)StubKey);
        [NSThread detachNewThreadWithBlock:^{
            Wait(2.0);
            @try { Run(); } @catch (NSException* exception) {
                Log([@"exception: " stringByAppendingString:exception.reason ?: @"?"]);
            }
            NSData* json = Main(^id {
                return [NSJSONSerialization dataWithJSONObject:gResult options:NSJSONWritingPrettyPrinted error:nil];
            });
            [json writeToFile:[gOut stringByAppendingPathComponent:@"result.json"] atomically:YES];
            Log(@"done");
            dispatch_async(dispatch_get_main_queue(), ^{ exit(0); });
        }];
    }];
}
