// driver.m: inserted (DYLD_INSERT_LIBRARIES, after tools/updater-e2e/szut.m, which keeps every window off screen)
// into a test copy of ShenzhenPDF.app by run_e2e.py. It hovers the tab bar the way a pointer does: the strip gets
// mouseEntered: and mouseMoved: events at the tabs' own positions, mouseExited: when the pointer leaves, and
// mouseDown:/mouseUp: to collapse a group. Documents are opened, paged, turned and grouped through the reader's own
// actions and menus. After each step it saves a picture of the top of the window with the hover label where the
// app placed it, and records what the label held.
//
// SPDF_E2E_PLAN: {"phase": "first" | "restored" | "memory-...", "documents": [...], "group": name}; SPDF_E2E_OUT:
// pictures and result.json. The steps themselves are in hover_harness.h.
#include "hover_harness.h"
#include "gap_and_type_steps.h"

#import <malloc/malloc.h>
#import <sys/resource.h>

static void RunFirst(void) {
    NSArray* documents = gPlan[@"documents"];
    NSString* rotation = documents[0], *longName = documents[1], *group = gPlan[@"group"];
    Open(rotation);
    for (int i = 0; i < 4; i++) { Action(@"nextPage:"); Wait(0.3); }
    Action(@"rotateClockwise:");
    Wait(1.5);
    gResult[@"rotation_page"] = Main(^id { return [Delegate() valueForKey:@"pageIndex"]; }) ?: @-1;
    Open(longName);
    Wait(1.0);
    NSInteger rotationTab = TabIndexForName(rotation.lastPathComponent);
    NSInteger longTab = TabIndexForName(longName.lastPathComponent);

    // A document tab, then the group's title tab, expanded and collapsed: same label, same place.
    for (NSString* look in @[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]) {
        BOOL dark = [look isEqual:NSAppearanceNameDarkAqua];
        NSString* suffix = dark ? @"dark" : @"light";
        Appearance(look);
        if (!dark) {
            GroupTab(TabIndexForName(longName.lastPathComponent), group);
            // The other document went into General: open either group that came collapsed.
            Wait(0.5);
            Expand(@"General");
            Expand(group);
            gResult[@"groups"] = Main(^id {
                NSMutableArray* names = [NSMutableArray array];
                for (id layout in [Strip() valueForKey:@"groupLayouts"])
                    [names addObject:[[layout valueForKey:@"group"] valueForKey:@"displayName"] ?: @""];
                return names;
            });
        }
        // One group is open at a time in the tab bar: open the one whose tab is hovered next.
        Expand(@"General");
        rotationTab = TabIndexForName(rotation.lastPathComponent);
        longTab = TabIndexForName(longName.lastPathComponent);
        double rotationMs = Hover(Centre(TabRect(rotationTab)), YES);
        NSMutableDictionary* rotated = [Shot([@"1-rotated-page5-" stringByAppendingString:suffix]) mutableCopy];
        rotated[@"placement"] = Placement(rotated, TabRect(rotationTab));
        rotated[@"orientation"] = Orientation();
        rotated[@"first_hover_ms"] = @(rotationMs);
        gResult[[@"rotated_" stringByAppendingString:suffix]] = rotated;

        Expand(group);
        Hover(Centre(TabRect(longTab)), NO);
        NSMutableDictionary* document = [Shot([@"2-document-tab-" stringByAppendingString:suffix]) mutableCopy];
        document[@"placement"] = Placement(document, TabRect(longTab));
        gResult[[@"document_" stringByAppendingString:suffix]] = document;

        NSRect header = GroupHeader(group);
        Hover(Centre(header), NO);
        NSMutableDictionary* expanded = [Shot([@"3-group-expanded-" stringByAppendingString:suffix]) mutableCopy];
        expanded[@"placement"] = Placement(expanded, header);
        expanded[@"header_width"] = @(NSWidth(header));
        gResult[[@"group_expanded_" stringByAppendingString:suffix]] = expanded;

        Click(Centre(header));
        header = GroupHeader(group);
        Hover(NSMakePoint(NSMidX(header) - 3, NSMidY(header)), NO);
        Hover(Centre(header), NO);
        NSMutableDictionary* collapsed = [Shot([@"4-group-collapsed-" stringByAppendingString:suffix]) mutableCopy];
        collapsed[@"placement"] = Placement(collapsed, header);
        collapsed[@"collapsed"] = @YES;
        gResult[[@"group_collapsed_" stringByAppendingString:suffix]] = collapsed;
        Click(Centre(header));

        // Away from the title tab onto empty tab bar, then out of the tab bar.
        NSRect last = TabRect((NSInteger)Tabs().count - 1);
        Hover(Centre(GroupHeader(group)), NO);
        Hover(NSMakePoint(NSMaxX(last) + 60, NSMidY(last)), NO);
        gResult[[@"away_empty_" stringByAppendingString:suffix]] = Shot([@"5-hover-away-" stringByAppendingString:suffix]);
        Hover(Centre(GroupHeader(group)), NO);
        Leave();
        gResult[[@"away_out_" stringByAppendingString:suffix]] = @{@"shown" : @(PanelShown())};
    }
    Appearance(NSAppearanceNameAqua);

    // A Markdown file, an image and a text file, each shown once, hovered next to the turned PDF.
    NSArray* extras = gPlan[@"extras"];
    for (NSString* path in extras) Open(path);
    for (NSString* look in @[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]) {
        BOOL dark = [look isEqual:NSAppearanceNameDarkAqua];
        Appearance(look);
        gResult[dark ? @"types_dark" : @"types_light"] = HoverTypes(extras, rotation, dark ? @"8-dark" : @"8-light", 3);
    }
    Appearance(NSAppearanceNameAqua);

    // Thirty tabs, each shown once: memory once their thumbnails are made.
    gResult[@"memory_before_more_tabs"] = CacheStats();
    for (NSUInteger i = 2; i < documents.count; i++) Open(documents[i]);
    Select(TabIndexForName(longName.lastPathComponent));
    Hover(Centre(TabRect(0)), YES);
    WaitFor(15, ^BOOL { return [CacheStats()[@"entries"] integerValue] >= (NSInteger)Tabs().count - 1; });
    Wait(1.0);
    gResult[@"memory_30_tabs"] = CacheStats();
    gResult[@"tab_count"] = @(Tabs().count);
    Expand(@"General");
    rotationTab = TabIndexForName(rotation.lastPathComponent);
    Reveal(rotationTab);
    gResult[@"cached_latency"] = HoverLatency(rotationTab, VisibleNeighbour(rotationTab), 30);
    gResult[@"cached_orientation"] = Orientation();

    // Every empty place in a full tab bar, in light and dark; a tab half under the "+N" badge; tabs moved, closed
    // and the window narrowed under a pointer that stays put.
    for (NSString* look in @[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]) {
        BOOL dark = [look isEqual:NSAppearanceNameDarkAqua];
        Appearance(look);
        gResult[dark ? @"gaps_dark" : @"gaps_light"] = HoverGaps(dark ? @"dark" : @"light");
    }
    Appearance(NSAppearanceNameAqua);
    gResult[@"partly_hidden"] = HoverPartlyHiddenTab();
    gResult[@"layout_changes"] = LayoutChanges();
    Leave();
    // The session is restored with General open, as the restored phase expects.
    Expand(@"General");
    Main(^id { ((void (*)(id, SEL))objc_msgSend)(Delegate(), NSSelectorFromString(@"savePersistentState")); return nil; });
    Wait(1.0);
}

// A restored session: no tab but the selected one has been shown since launch.
static void RunRestored(void) {
    NSArray* documents = gPlan[@"documents"];
    WaitFor(20, ^BOOL { return Tabs().count >= documents.count && !NSIsEmptyRect(TabRect(0)); });
    gResult[@"tab_count"] = @(Tabs().count);
    gResult[@"memory_at_launch"] = CacheStats();
    NSInteger cold = TabIndexForName([documents[0] lastPathComponent]);
    Reveal(cold);
    gResult[@"cold_had_page_in_memory"] = Main(^id {
        NSArray* pages = [Tabs()[(NSUInteger)cold] valueForKey:@"cachedRenderedPages"];
        for (id page in pages) if ([page valueForKey:@"image"] || [page valueForKey:@"baseImage"]) return @YES;
        return @NO;
    });
    double start = NowMs();
    double titleMs = Hover(Centre(TabRect(cold)), YES);
    NSMutableDictionary* first = [@{@"title_ms" : @(titleMs), @"title_shown_at_hover" : @(gShownAtLastHover),
                                    @"card_at_hover" : @(gCardAtLastHover)} mutableCopy];
    // Polled every 5 ms with nothing else on the main thread, so the time is the render's, not a picture's.
    BOOL arrived = !gCardAtLastHover && WaitFor(5, ^BOOL { return CardShown(); });
    first[@"thumbnail_ms"] = @(arrived ? NowMs() - start : -1);
    gResult[@"cold"] = first;
    Wait(0.3);
    gResult[@"cold_after"] = Shot(@"6-cold-thumbnail-faded-in");
    gResult[@"cold_orientation"] = Orientation();
    // Text documents not shown since launch: laid out from their files.
    gResult[@"cold_types"] = HoverTypes(gPlan[@"extras"], nil, @"9-not-shown", 3);
    Leave();
    // Left alone, the rest are made from the reader's preload of inactive tabs, after the idle start.
    Wait(10);
    gResult[@"memory_restored_warm"] = CacheStats();
    NSInteger other = VisibleNeighbour(cold);
    gResult[@"restored_cached_latency"] = HoverLatency(other, VisibleNeighbour(other), 20);
    Shot(@"7-restored-warm-tab");
    Leave();
}

static double CpuMs(void) {
    struct rusage usage;
    getrusage(RUSAGE_SELF, &usage);
    return (usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000.0 +
           (usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000.0;
}

// Memory and CPU of a restored session left alone: at launch, and 16 s later (past the reader's preload of inactive
// tabs and the 5 s idle start of the thumbnails), for this build and the one before it.
static void RunMemory(void) {
    NSArray* documents = gPlan[@"documents"];
    WaitFor(20, ^BOOL { return Tabs().count >= documents.count; });
    gResult[@"tab_count"] = @(Tabs().count);
    gResult[@"launch"] = @{@"footprint_mb" : @(FootprintMB()), @"cpu_ms" : @(CpuMs())};
    NSMutableArray* timeline = [NSMutableArray array];
    for (int i = 0; i < 32; i++) {
        Wait(0.5);
        NSDictionary* stats = CacheStats();
        [timeline addObject:@[ @((i + 1) * 0.5), stats[@"footprint_mb"], stats[@"entries"] ?: @0 ]];
    }
    gResult[@"timeline"] = timeline;
    gResult[@"after_16s"] = @{@"footprint_mb" : @(FootprintMB()), @"cpu_ms" : @(CpuMs())};
    Main(^id { malloc_zone_pressure_relief(NULL, 0); return nil; });
    gResult[@"after_relief"] = @{@"footprint_mb" : @(FootprintMB())};
    gResult[@"previews"] = CacheStats();
}

__attribute__((constructor)) static void E2EInit(void) {
    const char* plan = getenv("SPDF_E2E_PLAN"), *out = getenv("SPDF_E2E_OUT");
    // Only in the reader: its helpers (the Collection window, Friends) inherit DYLD_INSERT_LIBRARIES too.
    if (!plan || !out || strcmp(getprogname(), "ShenzhenPDF") != 0) return;
    gPlan = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(plan)] options:0 error:nil];
    gOut = @(out);
    gResult = [@{@"log" : [NSMutableArray array]} mutableCopy];
    Method show = class_getInstanceMethod(NSPopover.class, @selector(showRelativeToRect:ofView:preferredEdge:));
    gShowPopover = (void (*)(id, SEL, NSRect, NSView*, NSRectEdge))method_setImplementation(show, (IMP)RecordPopover);
    [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil
                                                     queue:nil usingBlock:^(NSNotification* note) {
        (void)note;
        [NSThread detachNewThreadWithBlock:^{
            // A restored session is hovered as soon as its tab bar is laid out: before the reader's preload of
            // inactive tabs, so the hovered tab has no page in memory yet.
            Wait([gPlan[@"phase"] hasPrefix:@"restored"] ? 0.0 : 1.5);
            @try {
                if ([gPlan[@"phase"] hasPrefix:@"restored"]) RunRestored();
                else if ([gPlan[@"phase"] hasPrefix:@"memory"]) RunMemory();
                else RunFirst();
            } @catch (NSException* exception) {
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
