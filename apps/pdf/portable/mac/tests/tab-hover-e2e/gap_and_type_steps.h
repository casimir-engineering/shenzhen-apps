// gap_and_type_steps.h: the hover steps for every kind of document and every gap in the tab bar. Included by
// driver.m after hover_harness.h.
//
// Types: a Markdown file, an image and a plain text file hovered next to a PDF, shown since launch (their pages in
// memory) and, in the restored phase, never shown (laid out from the file). Gaps: the pointer moves from a tab to
// each kind of empty place in the tab bar and the label must go at once. Layout changes: a tab moved or closed under
// a pointer that stays put, the tab bar scrolled half under a "+N" badge, and a narrower window.
#pragma once

static NSRect StripRectFor(NSString* selector, NSInteger argument, BOOL hasArgument) {
    NSRect rect = NSZeroRect;
    NSView* strip = Strip();
    SEL sel = NSSelectorFromString(selector);
    NSInvocation* call = [NSInvocation invocationWithMethodSignature:[strip methodSignatureForSelector:sel]];
    call.selector = sel;
    if (hasArgument) {
        if ([selector isEqual:@"tabScrollIndicatorRectOnLeft:"]) {
            BOOL left = argument != 0;
            [call setArgument:&left atIndex:2];
        } else {
            [call setArgument:&argument atIndex:2];
        }
    }
    [call invokeWithTarget:strip];
    [call getReturnValue:&rect];
    return rect;
}
static NSRect VisibleTabRect(NSInteger index) { return StripRectFor(@"visibleRectForTabAtIndex:", index, YES); }
static NSInteger HiddenCount(BOOL left) {
    return ((NSInteger (*)(id, SEL, BOOL))objc_msgSend)(Strip(), NSSelectorFromString(@"tabScrollHiddenCountOnLeft:"), left);
}
static NSRect Badge(BOOL left) { return HiddenCount(left) > 0 ? StripRectFor(@"tabScrollIndicatorRectOnLeft:", left, YES) : NSZeroRect; }
static NSString* FullTitle(NSInteger index) {
    return ((id (*)(id, SEL, NSInteger))objc_msgSend)(Strip(), NSSelectorFromString(@"fullTitleForTabAtIndex:"), index);
}
static CGFloat LeftInset(void) { return ((CGFloat (*)(id, SEL))objc_msgSend)(Strip(), NSSelectorFromString(@"leftInset")); }
static CGFloat LaneRight(void) {
    return ((CGFloat (*)(id, SEL, BOOL))objc_msgSend)(Strip(), NSSelectorFromString(@"tabAreaRightWithOverflow:"), YES);
}
static NSString* LabelText(void) { return PanelShown() ? [[Strip() valueForKey:@"hoverLabel"] stringValue] ?: @"" : @""; }

static NSString* GroupOfTab(NSInteger index) {
    return Main(^id { return [[Tabs()[(NSUInteger)index] valueForKey:@"group"] valueForKey:@"displayName"]; });
}

// A tab fully in view (index >= 0), or -1.
static NSInteger FirstWholeTab(NSInteger from, NSInteger step) {
    return [Main(^id {
        for (NSInteger i = from; i >= 0 && i < (NSInteger)Tabs().count; i += step) {
            NSRect r = TabRect(i), v = VisibleTabRect(i);
            if (!NSIsEmptyRect(r) && NSEqualRects(r, v)) return @(i);
        }
        return @-1;
    }) integerValue];
}

// The thumbnail: its shape, how much of it is ink rather than paper, and its edges (as Orientation()).
static NSDictionary* PageStats(void) {
    NSMutableDictionary* stats = [Orientation() mutableCopy];
    NSDictionary* ink = Main(^id {
        CGImageRef image = PanelShown() && CardShown() ? Thumbnail() : NULL;
        if (!image) return @{};
        NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithCGImage:image];
        NSInteger w = rep.pixelsWide, h = rep.pixelsHigh, marked = 0, total = 0;
        NSColor* paper = [[rep colorAtX:2 y:2] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        CGFloat paperLuma = 0.3 * paper.redComponent + 0.59 * paper.greenComponent + 0.11 * paper.blueComponent;
        for (NSInteger y = 0; y < h; y += 2)
            for (NSInteger x = 0; x < w; x += 2) {
                NSColor* c = [[rep colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
                CGFloat luma = 0.3 * c.redComponent + 0.59 * c.greenComponent + 0.11 * c.blueComponent;
                marked += fabs(luma - paperLuma) > 0.25;
                total++;
            }
        return @{@"ink" : @(total ? (double)marked / total : 0), @"paper_luma" : @(paperLuma),
                 @"aspect" : @(h ? (double)w / h : 0)};
    });
    [stats addEntriesFromDictionary:ink];
    return stats;
}

// Hovers the tab named `name` (opening its group and scrolling it into view) and waits for its page.
static NSDictionary* HoverDocument(NSString* name, NSString* picture, NSTimeInterval wait) {
    NSInteger index = TabIndexForName(name);
    if (index < 0) return @{@"missing" : @YES};
    Expand(GroupOfTab(index));
    index = TabIndexForName(name);
    Reveal(index);
    double start = NowMs();
    Hover(Centre(TabRect(index)), NO);
    BOOL atHover = gCardAtLastHover;
    BOOL arrived = atHover || WaitFor(wait, ^BOOL { return CardShown(); });
    double ms = NowMs() - start;
    Wait(0.2);
    NSMutableDictionary* shot = [Shot(picture) mutableCopy];
    shot[@"card_at_hover"] = @(atHover);
    shot[@"card_ms"] = @(arrived ? ms : -1);
    shot[@"page"] = PageStats();
    return shot;
}

static NSDictionary* HoverTypes(NSArray* extras, NSString* rotation, NSString* prefix, NSTimeInterval wait) {
    NSMutableDictionary* types = [NSMutableDictionary dictionary];
    NSArray* kinds = @[ @"markdown", @"image", @"text" ];
    for (NSUInteger i = 0; i < extras.count && i < kinds.count; i++)
        types[kinds[i]] = HoverDocument([extras[i] lastPathComponent],
                                        [NSString stringWithFormat:@"%@-%@", prefix, kinds[i]], wait);
    if (rotation) types[@"pdf"] = HoverDocument(rotation.lastPathComponent, [prefix stringByAppendingString:@"-pdf"], wait);
    return types;
}

// From a tab (label showing) onto `point`: is a label still there, and whose.
static NSDictionary* GapCheck(NSString* name, NSPoint point, NSInteger fromTab) {
    if (fromTab >= 0) Hover(Centre(VisibleTabRect(fromTab)), NO);
    BOOL before = PanelShown();
    Hover(point, NO);
    return Main(^id {
        NSRect bounds = Strip().bounds;
        return @{@"gap" : name, @"point" : @[ @(point.x), @(point.y) ], @"inside_strip" : @(NSPointInRect(point, bounds)),
                 @"shown_before" : @(before), @"shown" : @(PanelShown()), @"label" : LabelText()};
    });
}

// Opens the long-named group, which holds most of the documents, and scrolls its documents until some are hidden
// on both sides: a "+N" badge at either end of them.
static void FullTabBar(void) {
    Expand(gPlan[@"group"]);
    for (int i = 0; i < 30 && !(HiddenCount(YES) > 0 && HiddenCount(NO) > 0); i++)
        Main(^id {
            ((void (*)(id, SEL, CGFloat))objc_msgSend)(Strip(), NSSelectorFromString(@"scrollTabStripBy:"), 150);
            return nil;
        });
}

// Every kind of empty place in the tab bar, from a tab whose label is showing.
static NSArray* HoverGaps(NSString* suffix) {
    NSMutableArray* gaps = [NSMutableArray array];
    FullTabBar();
    NSInteger a = FirstWholeTab(0, 1);
    if (a < 0) return @[ @{@"gap" : @"no tab in view"} ];
    NSRect ra = TabRect(a);
    NSInteger b = a + 1 < (NSInteger)Tabs().count && NSMinX(TabRect(a + 1)) > NSMaxX(ra) ? a + 1 : -1;
    if (b >= 0) [gaps addObject:GapCheck(@"between two tabs", NSMakePoint((NSMaxX(ra) + NSMinX(TabRect(b))) / 2, NSMidY(ra)), a)];
    [gaps addObject:GapCheck(@"above a tab", NSMakePoint(NSMidX(ra), NSMaxY(ra) + 2), a)];
    [gaps addObject:GapCheck(@"below a tab", NSMakePoint(NSMidX(ra), NSMinY(ra) - 2), a)];
    [gaps addObject:GapCheck(@"left of the tab bar", NSMakePoint(LeftInset() - 20, NSMidY(ra)), a)];
    [gaps addObject:GapCheck(@"right of the tab lane", NSMakePoint(LaneRight() + 3, NSMidY(ra)), a)];
    NSArray* layouts = Main(^id { return [Strip() valueForKey:@"groupLayouts"]; });
    for (NSUInteger i = 0; i < layouts.count; i++) {
        NSRect header = [[layouts[i] valueForKey:@"header"] rectValue], frame = [[layouts[i] valueForKey:@"frame"] rectValue];
        NSString* group = [[layouts[i] valueForKey:@"group"] valueForKey:@"displayName"];
        if (NSMaxX(header) < LeftInset() || NSMinX(header) > LaneRight()) continue;
        if ([[[layouts[i] valueForKey:@"tabRects"] allKeys] count] && i + 1 < layouts.count)
            [gaps addObject:GapCheck([@"between groups after " stringByAppendingString:group],
                                     NSMakePoint(NSMaxX(frame) + 4, NSMidY(header)), a)];
        if ([[[layouts[i] valueForKey:@"tabRects"] allKeys] count])
            [gaps addObject:GapCheck([@"between the title tab and the first tab of " stringByAppendingString:group],
                                     NSMakePoint(NSMaxX(header) + 5, NSMidY(header)), a)];
    }
    NSRect left = Badge(YES);
    if (!NSIsEmptyRect(left)) {
        // The owner's report: the pointer between a title tab and the "+N" badge, over a tab scrolled under it.
        NSRect header = NSZeroRect;
        for (id layout in layouts) {
            NSRect h = [[layout valueForKey:@"header"] rectValue];
            if (NSMaxX(h) <= NSMinX(left) + 0.5 && NSMaxX(h) > NSMaxX(header)) header = h;
        }
        if (!NSIsEmptyRect(header))
            [gaps addObject:GapCheck(@"between a title tab and the +N badge", NSMakePoint((NSMaxX(header) + NSMinX(left)) / 2,
                                                                                      NSMidY(left)), a)];
        [gaps addObject:GapCheck(@"on the left +N badge", Centre(left), a)];
    }
    NSRect right = Badge(NO);
    if (!NSIsEmptyRect(right)) [gaps addObject:GapCheck(@"on the right +N badge", Centre(right), a)];
    Shot([@"10-gap-last-" stringByAppendingString:suffix]);
    return gaps;
}

// Scrolls the expanded group's tabs until one is cut by the left "+N" badge, then hovers the part of it that shows.
static NSDictionary* HoverPartlyHiddenTab(void) {
    FullTabBar();
    for (int i = 0; i < 80; i++) {
        NSDictionary* found = Main(^id {
            NSRect badge = Badge(YES);
            if (NSIsEmptyRect(badge)) return nil;
            for (NSInteger t = 0; t < (NSInteger)Tabs().count; t++) {
                NSRect r = TabRect(t), v = VisibleTabRect(t);
                if (NSMinX(r) < NSMinX(badge) - 8 && NSWidth(v) >= 60 && NSWidth(v) < NSWidth(r) - 8)
                    return @{@"index" : @(t), @"rect" : [NSValue valueWithRect:r], @"visible" : [NSValue valueWithRect:v],
                             @"badge" : [NSValue valueWithRect:badge]};
            }
            return nil;
        });
        if (found) {
            NSInteger t = [found[@"index"] integerValue];
            NSRect v = [found[@"visible"] rectValue], r = [found[@"rect"] rectValue], badge = [found[@"badge"] rectValue];
            NSDictionary* hidden = GapCheck(@"the hidden part of a tab, under the badge", NSMakePoint(NSMinX(badge) - 4, NSMidY(r)), -1);
            Hover(NSMakePoint(NSMidX(v), NSMidY(v)), NO);
            NSMutableDictionary* shot = [Shot(@"11-partly-hidden-tab") mutableCopy];
            shot[@"expected"] = FullTitle(t);
            shot[@"placement"] = Placement(shot, v);
            shot[@"hidden_part"] = hidden;
            shot[@"tab_rect"] = @[ @(NSMinX(r)), @(NSWidth(r)) ];
            shot[@"visible_rect"] = @[ @(NSMinX(v)), @(NSWidth(v)) ];
            return shot;
        }
        Main(^id {
            ((void (*)(id, SEL, CGFloat))objc_msgSend)(Strip(), NSSelectorFromString(@"scrollTabStripBy:"), 37);
            return nil;
        });
    }
    return @{@"found" : @NO};
}

// The label after the tabs change under a pointer that has not moved, and after the pointer moves again.
// Hovered: a supplier sheet in full view after another supplier sheet, so moving or closing either asks nothing.
static NSInteger SheetToHover(void) {
    return [Main(^id {
        NSArray* tabs = Tabs();
        for (NSInteger i = 1; i + 2 < (NSInteger)tabs.count; i++) {
            NSString* name = [[tabs[(NSUInteger)i] valueForKey:@"path"] lastPathComponent];
            NSString* previous = [[tabs[(NSUInteger)i - 1] valueForKey:@"path"] lastPathComponent];
            NSRect r = TabRect(i);
            if ([name hasPrefix:@"Supplier sheet"] && [previous hasPrefix:@"Supplier sheet"] && !NSIsEmptyRect(r) &&
                NSEqualRects(r, VisibleTabRect(i)))
                return @(i);
        }
        return @-1;
    }) integerValue];
}

static NSDictionary* AfterLayoutChange(NSString* what, void (^change)(NSInteger hovered)) {
    NSInteger index = SheetToHover();
    for (int i = 0; i < 20 && index < 0; i++) {
        Main(^id {
            ((void (*)(id, SEL, CGFloat))objc_msgSend)(Strip(), NSSelectorFromString(@"scrollTabStripBy:"), 120);
            return nil;
        });
        index = SheetToHover();
    }
    if (index < 0) return @{@"change" : what, @"skipped" : @"no supplier sheet in view"};
    NSPoint point = Centre(TabRect(index));
    Hover(point, NO);
    NSString* before = LabelText();
    change(index);
    Wait(0.5);
    NSDictionary* state = Main(^id {
        NSInteger under = ((NSInteger (*)(id, SEL, NSPoint))objc_msgSend)(Strip(), NSSelectorFromString(@"hoverTabIndexAtPoint:"), point);
        return @{@"shown" : @(PanelShown()), @"label" : LabelText(), @"under" : under >= 0 ? FullTitle(under) : @""};
    });
    Hover(NSMakePoint(point.x + 1, point.y), NO);
    NSDictionary* rehover = Main(^id {
        NSInteger under = ((NSInteger (*)(id, SEL, NSPoint))objc_msgSend)(Strip(), NSSelectorFromString(@"hoverTabIndexAtPoint:"),
                                                                          NSMakePoint(point.x + 1, point.y));
        return @{@"shown" : @(PanelShown()), @"label" : LabelText(), @"under" : under >= 0 ? FullTitle(under) : @""};
    });
    return @{@"change" : what, @"before" : before, @"after" : state, @"rehover" : rehover};
}

static NSArray* LayoutChanges(void) {
    NSMutableArray* results = [NSMutableArray array];
    FullTabBar();
    [results addObject:AfterLayoutChange(@"the hovered tab moved two places right", ^(NSInteger hovered) {
        Main(^id {
            ((void (*)(id, SEL, NSInteger, NSInteger))objc_msgSend)(Delegate(), NSSelectorFromString(@"moveTabFromIndex:toIndex:"),
                                                                     hovered, hovered + 2);
            return nil;
        });
    })];
    [results addObject:AfterLayoutChange(@"the tab before the hovered one closed", ^(NSInteger hovered) {
        Main(^id {
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(Delegate(), NSSelectorFromString(@"closeTabAtIndex:"), hovered - 1);
            return nil;
        });
    })];
    [results addObject:AfterLayoutChange(@"the hovered tab closed", ^(NSInteger hovered) {
        Main(^id {
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(Delegate(), NSSelectorFromString(@"closeTabAtIndex:"), hovered);
            return nil;
        });
    })];
    __block NSRect wide = [Main(^id { return [NSValue valueWithRect:Strip().window.frame]; }) rectValue];
    [results addObject:AfterLayoutChange(@"the window got narrower", ^(NSInteger hovered) {
        (void)hovered;
        Main(^id {
            NSWindow* window = Strip().window;
            NSRect frame = window.frame;
            frame.size.width = MAX(720, frame.size.width * 0.6);
            [window setFrame:frame display:YES];
            return nil;
        });
    })];
    NSMutableDictionary* narrow = [@{@"gaps" : HoverGaps(@"narrow")} mutableCopy];
    Main(^id { [Strip().window setFrame:wide display:YES]; return nil; });
    Wait(0.3);
    [results addObject:narrow];
    return results;
}
