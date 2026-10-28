// palette_driver.m: inserted (DYLD_INSERT_LIBRARIES, after tools/updater-e2e/szut.m, which keeps every window off
// screen) into a test copy of ShenzhenPDF.app by palette_reel.py. It sets up one reader window the way a person would
// have it: named groups of every colour in hue order, one open with its documents, a PDF page in the reader and the
// sidebar open. Then, for each palette, it picks the palette in Settings › Appearance › Tab group colors, as a person
// would, and pictures the reader window at 2x in light and dark.
//
// SPDF_E2E_PLAN: {"documents", "groups": [{"name", "color", "documents"}], "open_group", "selected", "palettes",
// "width", "height"}; SPDF_E2E_OUT: pictures and result.json.
#include "../tab-hover-e2e/hover_harness.h"

static NSWindow* ReaderWindow(void) { return Strip().window; }

// The window's frame view at twice its size in points, over the window's own background, whatever screen it is on.
static void ShotWindow(NSWindow* window, NSString* name) {
    Main(^id {
        NSView* frameView = window.contentView.superview ?: window.contentView;
        [frameView layoutSubtreeIfNeeded];
        [frameView displayIfNeeded];
        NSSize size = frameView.bounds.size;
        NSInteger w = (NSInteger)lround(size.width * 2), h = (NSInteger)lround(size.height * 2);
        NSBitmapImageRep* (^canvas)(void) = ^NSBitmapImageRep* {
            NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:w pixelsHigh:h
                bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace
                bytesPerRow:0 bitsPerPixel:0];
            rep.size = size;
            // Drawn into sRGB, so a pixel's value is the colour the app asked for.
            return [rep bitmapImageRepByRetaggingWithColorSpace:NSColorSpace.sRGBColorSpace];
        };
        NSBitmapImageRep* view = canvas();
        [frameView cacheDisplayInRect:frameView.bounds toBitmapImageRep:view];
        NSBitmapImageRep* out = canvas();
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:out];
        [window.effectiveAppearance performAsCurrentDrawingAppearance:^{
            [(window.backgroundColor ?: NSColor.windowBackgroundColor) setFill];
            NSRectFill(NSMakeRect(0, 0, size.width, size.height));
            [view drawInRect:NSMakeRect(0, 0, size.width, size.height) fromRect:NSZeroRect
                   operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
        }];
        [NSGraphicsContext restoreGraphicsState];
        NSString* file = [gOut stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"png"]];
        [[out representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:file atomically:YES];
        [gResult[@"pictures"] addObject:file];
        return nil;
    });
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

static NSWindow* SettingsWindow(void) {
    for (NSWindow* window in NSApp.windows)
        if ([window.title isEqual:@"ShenzhenPDF Settings"]) return window;
    return nil;
}

// Settings › Appearance › Tab group colors, chosen as a click on the menu item would.
static BOOL ChoosePalette(NSString* palette) {
    return [Main(^id {
        NSWindow* settings = SettingsWindow();
        NSView* root = settings.contentView;
        NSPopUpButton* popup = (NSPopUpButton*)FindIdentifier(root, @"tabGroupPalette");
        if (![popup isKindOfClass:NSPopUpButton.class] || ![popup itemWithTitle:palette]) return @NO;
        [popup selectItemWithTitle:palette];
        [popup sendAction:popup.action to:popup.target];
        return @YES;
    }) boolValue];
}

static NSArray* GroupHeaders(void) {
    return Main(^id {
        NSMutableArray* headers = [NSMutableArray array];
        NSView* strip = Strip();
        for (id layout in [strip valueForKey:@"groupLayouts"]) {
            id group = [layout valueForKey:@"group"];
            NSRect header = [[layout valueForKey:@"header"] rectValue];
            NSRect inWindow = [strip convertRect:header toView:nil];
            [headers addObject:@{@"name" : [group valueForKey:@"displayName"] ?: @"",
                                 @"color" : [group valueForKey:@"colorName"] ?: @"",
                                 @"rect" : @[@(NSMinX(inWindow)), @(NSMinY(inWindow)), @(NSWidth(inWindow)),
                                             @(NSHeight(inWindow))]}];
        }
        return headers;
    });
}

static void Run(void) {
    Main(^id {
        [ReaderWindow() setFrame:NSMakeRect(0, 0, [gPlan[@"width"] doubleValue], [gPlan[@"height"] doubleValue])
                         display:YES];
        return nil;
    });
    for (NSString* path in gPlan[@"documents"]) Open(path);
    MakeGroups();
    Expand(gPlan[@"open_group"]);
    Select(TabIndexForName([gPlan[@"selected"] lastPathComponent]));
    Main(^id { [NSApp sendAction:NSSelectorFromString(@"showUnifiedSettings:") to:nil from:nil]; return nil; });
    if (!WaitFor(10, ^BOOL { return SettingsWindow() != nil; })) { Log(@"no Settings window"); return; }
    Main(^id {
        ((void (*)(id, SEL, id))objc_msgSend)(SettingsWindow().windowController, NSSelectorFromString(@"selectSection:"),
                                               @"appearance");
        return nil;
    });
    Wait(1);
    gResult[@"frame"] = Main(^id {
        NSView* frame = ReaderWindow().contentView.superview;
        return @[@(NSWidth(frame.bounds)), @(NSHeight(frame.bounds))];
    });
    gResult[@"palettes"] = [NSMutableArray array];
    NSArray* looks = @[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ];
    for (NSString* palette in gPlan[@"palettes"]) {
        BOOL chosen = ChoosePalette(palette);
        Wait(0.6);
        NSMutableDictionary* entry = [@{@"name" : palette, @"chosen" : @(chosen), @"headers" : GroupHeaders()}
                                         mutableCopy];
        NSString* slug = [[palette.lowercaseString componentsSeparatedByString:@" "] componentsJoinedByString:@"-"];
        for (NSString* look in looks) {
            NSString* suffix = [look isEqual:NSAppearanceNameDarkAqua] ? @"dark" : @"light";
            Appearance(look);
            Wait(0.6);
            ShotWindow(ReaderWindow(), [NSString stringWithFormat:@"%@-%@", slug, suffix]);
            entry[suffix] = [gResult[@"pictures"] lastObject];
            if (palette == [gPlan[@"palettes"] firstObject])
                ShotWindow(SettingsWindow(), [@"settings-appearance-" stringByAppendingString:suffix]);
        }
        [gResult[@"palettes"] addObject:entry];
        Log([NSString stringWithFormat:@"%@ chosen %d", palette, chosen]);
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
