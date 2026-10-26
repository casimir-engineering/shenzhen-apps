// hover_harness.h: what driver.m does to the app, one step at a time: find the tab bar, move the pointer over it
// through its own event handlers, open, page, group and click, and read back and picture the hover label. Included
// by driver.m only.
#pragma once

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>
#import <malloc/malloc.h>
#import <sys/resource.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSDictionary* gPlan;
static NSString* gOut;
static NSMutableDictionary* gResult;

static id Main(id (^block)(void)) {
    if (NSThread.isMainThread) return block();
    __block id value = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{ value = block(); });
    return value;
}

static void Log(NSString* text) {
    fprintf(stderr, "[e2e] %s\n", text.UTF8String);
    Main(^id { [gResult[@"log"] addObject:text]; return nil; });
}

static double NowMs(void) { return CACurrentMediaTime() * 1000.0; }

static double FootprintMB(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return -1;
    return info.phys_footprint / (1024.0 * 1024.0);
}

static NSView* FindView(NSView* root, NSString* className) {
    if ([NSStringFromClass(root.class) isEqual:className]) return root;
    for (NSView* sub in root.subviews) { NSView* found = FindView(sub, className); if (found) return found; }
    return nil;
}

static id Delegate(void) { return NSApp.delegate; }
static NSView* Strip(void) {
    for (NSWindow* window in NSApp.windows) {
        NSView* root = window.contentView.superview ?: window.contentView;
        NSView* strip = root ? FindView(root, @"SPDFTabStripView") : nil;
        if (strip) return strip;
    }
    return nil;
}
static NSArray* Tabs(void) { return [Strip() valueForKey:@"tabs"]; }
static NSPanel* Panel(void) { return [Strip() valueForKey:@"hoverPanel"]; }
static BOOL PanelShown(void) { return Panel().parentWindow != nil && Panel().parentWindow == Strip().window; }
// nil in an earlier build, measured for comparison, that has no page thumbnails.
static id StripIvar(NSString* name) {
    NSView* strip = Strip();
    return class_getInstanceVariable(strip.class, [@"_" stringByAppendingString:name].UTF8String)
        ? [strip valueForKey:name] : nil;
}
static NSView* Card(void) { return StripIvar(@"hoverCard"); }
static CGImageRef Thumbnail(void) {
    NSView* view = StripIvar(@"hoverThumbnail");
    return (__bridge CGImageRef)view.layer.contents;
}
static BOOL CardShown(void) { return Card() && !Card().hidden && Thumbnail(); }

static void Wait(NSTimeInterval seconds) { [NSThread sleepForTimeInterval:seconds]; }
static BOOL WaitFor(NSTimeInterval seconds, BOOL (^done)(void)) {
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (deadline.timeIntervalSinceNow > 0) {
        if ([Main(^id { return @(done()); }) boolValue]) return YES;
        Wait(0.005);
    }
    return NO;
}

static NSEvent* MouseEvent(NSEventType type, NSPoint stripPoint) {
    NSView* strip = Strip();
    NSPoint point = [strip convertPoint:stripPoint toView:nil];
    if (type == NSEventTypeMouseEntered || type == NSEventTypeMouseExited)
        return [NSEvent enterExitEventWithType:type location:point modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime
                                  windowNumber:strip.window.windowNumber context:nil eventNumber:0 trackingNumber:0 userData:NULL];
    return [NSEvent mouseEventWithType:type location:point modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime
                          windowNumber:strip.window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
}

static NSRect TabRect(NSInteger index) {
    NSRect rect = NSZeroRect;
    NSView* strip = Strip();
    NSMethodSignature* signature = [strip methodSignatureForSelector:NSSelectorFromString(@"rectForTabAtIndex:")];
    NSInvocation* call = [NSInvocation invocationWithMethodSignature:signature];
    call.selector = NSSelectorFromString(@"rectForTabAtIndex:");
    [call setArgument:&index atIndex:2];
    [call invokeWithTarget:strip];
    [call getReturnValue:&rect];
    return rect;
}

static NSRect GroupHeader(NSString* name) {
    for (id layout in [Strip() valueForKey:@"groupLayouts"])
        if ([[[layout valueForKey:@"group"] valueForKey:@"displayName"] isEqual:name])
            return [[layout valueForKey:@"header"] rectValue];
    return NSZeroRect;
}

static NSInteger TabIndexForName(NSString* name) {
    NSArray* tabs = Tabs();
    for (NSUInteger i = 0; i < tabs.count; i++)
        if ([[[tabs[i] valueForKey:@"path"] lastPathComponent] isEqual:name]) return (NSInteger)i;
    return -1;
}

static BOOL gCardAtLastHover, gShownAtLastHover;
// The pointer arrives at `point` in the strip; returns the main thread's time from the event to the label drawn.
// What the label held when drawn is in gShownAtLastHover and gCardAtLastHover.
static double Hover(NSPoint point, BOOL entering) {
    return [Main(^id {
        NSView* strip = Strip();
        double start = NowMs();
        if (entering) [strip mouseEntered:MouseEvent(NSEventTypeMouseEntered, point)];
        else [strip mouseMoved:MouseEvent(NSEventTypeMouseMoved, point)];
        NSPanel* panel = Panel();
        if (panel.parentWindow) {
            [panel.contentView layoutSubtreeIfNeeded];
            [panel display];
        }
        [CATransaction flush];
        double elapsed = NowMs() - start;
        gShownAtLastHover = PanelShown();
        gCardAtLastHover = CardShown();
        return @(elapsed);
    }) doubleValue];
}

static void Leave(void) {
    Main(^id { [Strip() mouseExited:MouseEvent(NSEventTypeMouseExited, NSMakePoint(1, 1))]; return nil; });
}

static NSBitmapImageRep* Capture(NSView* view) {
    [view layoutSubtreeIfNeeded];
    NSBitmapImageRep* rep = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
    return rep;
}

// The top of the window, and the hover label drawn where the app put it (it is a child window, so the window's
// own picture does not hold it).
static NSDictionary* Shot(NSString* name) {
    return Main(^id {
        NSView* strip = Strip();
        NSWindow* window = strip.window;
        NSView* frameView = window.contentView.superview;
        NSBitmapImageRep* windowRep = Capture(frameView);
        NSPanel* panel = Panel();
        BOOL shown = PanelShown();
        NSRect panelFrame = shown ? panel.frame : NSZeroRect;
        CGFloat height = 360;
        NSSize size = NSMakeSize(NSWidth(frameView.bounds), height);
        NSImage* image = [[NSImage alloc] initWithSize:size];
        NSRect top = NSMakeRect(0, NSHeight(frameView.bounds) - height, size.width, height);
        [image lockFocus];
        [window.effectiveAppearance performAsCurrentDrawingAppearance:^{
            // Materials that blend with what is behind the window have nothing behind them off screen: they get
            // the colours the window server would show through them.
            [NSColor.windowBackgroundColor setFill];
            NSRectFill(NSMakeRect(0, 0, size.width, height));
            [windowRep drawInRect:NSMakeRect(0, 0, size.width, height) fromRect:top
                        operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
            if (!shown) return;
            NSPoint origin = NSMakePoint(NSMinX(panelFrame) - NSMinX(window.frame),
                                         NSMinY(panelFrame) - NSMinY(window.frame) - NSMinY(top));
            for (NSView* part in @[ (StripIvar(@"hoverBubble") ?: panel.contentView), Card() ?: NSNull.null ]) {
                if (![part isKindOfClass:NSView.class] || part.hidden) continue;
                NSRect rect = NSOffsetRect(part.frame, origin.x, origin.y);
                NSBezierPath* shape = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:8 yRadius:8];
                // The panel's shadow, as the window server draws it around a borderless panel's opaque parts.
                NSShadow* shadow = [NSShadow new];
                shadow.shadowBlurRadius = 12;
                shadow.shadowOffset = NSMakeSize(0, -4);
                shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.3];
                [NSGraphicsContext saveGraphicsState];
                [shadow set];
                [[NSColor.windowBackgroundColor blendedColorWithFraction:0.15 ofColor:NSColor.textBackgroundColor]
                    setFill];
                [shape fill];
                [NSGraphicsContext restoreGraphicsState];
                [NSGraphicsContext saveGraphicsState];
                [shape addClip];
                [Capture(part) drawInRect:rect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
                                 fraction:1 respectFlipped:YES hints:nil];
                [NSGraphicsContext restoreGraphicsState];
            }
        }];
        [image unlockFocus];
        NSBitmapImageRep* out = [[NSBitmapImageRep alloc] initWithData:image.TIFFRepresentation];
        NSString* file = [gOut stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"png"]];
        [[out representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:file atomically:YES];
        NSTextField* label = [strip valueForKey:@"hoverLabel"];
        NSMutableDictionary* state = [@{@"picture" : file, @"shown" : @(shown),
                                        @"label" : shown ? label.stringValue ?: @"" : @"",
                                        @"card" : @(shown && CardShown())} mutableCopy];
        if (shown) {
            NSView* bubble = (StripIvar(@"hoverBubble") ?: panel.contentView);
            NSRect bubbleScreen = [panel convertRectToScreen:[bubble convertRect:bubble.bounds toView:nil]];
            state[@"title_top_offset"] = @(NSMaxY(bubbleScreen));
            state[@"title_mid_x"] = @(NSMidX(bubbleScreen));
            state[@"font"] = label.font.description ?: @"";
            [label.superview layoutSubtreeIfNeeded];
            // The whole name is drawn, not cut short with an ellipsis.
            state[@"label_whole"] = @(ceil(label.attributedStringValue.size.width) <= NSWidth(label.frame) + 1);
        }
        if (shown && CardShown()) {
            CGImageRef thumbnail = Thumbnail();
            state[@"thumbnail_px"] = @[ @(CGImageGetWidth(thumbnail)), @(CGImageGetHeight(thumbnail)) ];
            state[@"card_pt"] = @[ @(NSWidth(Card().frame)), @(NSHeight(Card().frame)) ];
        }
        return state;
    });
}

// Where the label sits relative to what was hovered: the title's top under the item's bottom, and its centre.
static NSDictionary* Placement(NSDictionary* shot, NSRect itemInStrip) {
    return Main(^id {
        NSView* strip = Strip();
        NSRect screen = [strip.window convertRectToScreen:[strip convertRect:itemInStrip toView:nil]];
        if (![shot[@"shown"] boolValue]) return @{};
        return @{@"gap_below_item" : @(NSMinY(screen) - [shot[@"title_top_offset"] doubleValue]),
                 @"centre_offset" : @([shot[@"title_mid_x"] doubleValue] - NSMidX(screen))};
    });
}

// The thumbnail's pixels: which edge the red band of page 5 is on, and where the corner square is.
static NSDictionary* Orientation(void) {
    return Main(^id {
        CGImageRef image = PanelShown() && CardShown() ? Thumbnail() : NULL;
        if (!image) return @{};
        NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithCGImage:image];
        NSInteger w = rep.pixelsWide, h = rep.pixelsHigh;
        NSString* (^name)(NSInteger, NSInteger) = ^NSString*(NSInteger x, NSInteger y) {
            NSColor* c = [[rep colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
            if (c.redComponent > 0.7 && c.greenComponent < 0.3 && c.blueComponent < 0.3) return @"red";
            if (c.redComponent < 0.25 && c.greenComponent < 0.25 && c.blueComponent < 0.25) return @"dark";
            return c.redComponent > 0.9 && c.greenComponent > 0.9 && c.blueComponent > 0.9 ? @"white" : @"other";
        };
        // y counts from the top of the picture.
        return @{@"size" : @[ @(w), @(h) ], @"right_edge" : name(w - 3, h / 2), @"left_edge" : name(2, h / 2),
                 @"top_edge" : name(w / 2, 2), @"bottom_edge" : name(w / 2, h - 3),
                 @"top_left" : name(w * 12 / 100, h * 10 / 100), @"bottom_left" : name(w * 12 / 100, h * 92 / 100)};
    });
}

static void Action(NSString* selector) {
    Main(^id { [NSApp sendAction:NSSelectorFromString(selector) to:nil from:nil]; return nil; });
}

static void Open(NSString* path) {
    Main(^id { ((void (*)(id, SEL, id))objc_msgSend)(Delegate(), NSSelectorFromString(@"openPath:"), path); return nil; });
    WaitFor(10, ^BOOL { return TabIndexForName(path.lastPathComponent) >= 0; });
    Wait(0.6);
}

static void Select(NSInteger index) {
    Main(^id {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(Delegate(), NSSelectorFromString(@"selectTabAtIndex:"), index);
        return nil;
    });
    Wait(0.8);
}

// "Add to New Group" from the tab's menu, then the name typed into the prompt and Return.
static NSPopover* gLastPopover;
static void (*gShowPopover)(id, SEL, NSRect, NSView*, NSRectEdge);
static void RecordPopover(NSPopover* self, SEL _cmd, NSRect rect, NSView* view, NSRectEdge edge) {
    gLastPopover = self;
    gShowPopover(self, _cmd, rect, view, edge);
}

static NSView* FindIdentifier(NSView* root, NSString* identifier) {
    if ([root.identifier isEqual:identifier]) return root;
    for (NSView* sub in root.subviews) { NSView* found = FindIdentifier(sub, identifier); if (found) return found; }
    return nil;
}

static void GroupTab(NSInteger index, NSString* name) {
    Main(^id {
        NSView* strip = Strip();
        NSMenu* menu = ((id (*)(id, SEL, NSInteger))objc_msgSend)(strip, NSSelectorFromString(@"contextMenuForTabAtIndex:"), index);
        NSMenuItem* item = [menu itemWithTitle:@"Add to New Group"];
        [NSApp sendAction:item.action to:item.target from:item];
        return nil;
    });
    // The prompt is a popover over the new group's title tab; off screen its window never shows, so the name
    // goes into its field and its Done button is pressed.
    WaitFor(5, ^BOOL { return gLastPopover.contentViewController.view != nil; });
    Main(^id {
        NSView* content = gLastPopover.contentViewController.view;
        NSTextField* field = (NSTextField*)FindIdentifier(content, @"GroupNameField");
        NSButton* done = nil;
        for (NSView* view in content.subviews)
            if ([view isKindOfClass:NSButton.class] && [[(NSButton*)view title] isEqual:@"Done"]) done = (NSButton*)view;
        if (!field || !done) { Log(@"no group name prompt"); return nil; }
        field.stringValue = name;
        [done performClick:nil];
        return nil;
    });
    Wait(0.6);
}

static void Click(NSPoint point) {
    Main(^id {
        [Strip() mouseDown:MouseEvent(NSEventTypeLeftMouseDown, point)];
        [Strip() mouseUp:MouseEvent(NSEventTypeLeftMouseUp, point)];
        return nil;
    });
    Wait(0.5);
}

static NSPoint Centre(NSRect rect) { return NSMakePoint(NSMidX(rect), NSMidY(rect)); }

static NSRect Viewport(void) {
    NSRect rect = NSZeroRect;
    NSView* strip = Strip();
    NSMethodSignature* signature = [strip methodSignatureForSelector:NSSelectorFromString(@"tabViewportRect")];
    NSInvocation* call = [NSInvocation invocationWithMethodSignature:signature];
    call.selector = NSSelectorFromString(@"tabViewportRect");
    [call invokeWithTarget:strip];
    [call getReturnValue:&rect];
    return rect;
}

// Scrolls the tab bar, as a two-finger swipe over it does, until the tab is in view.
static void Reveal(NSInteger index) {
    for (int i = 0; i < 60; i++) {
        BOOL visible = [Main(^id {
            NSRect tab = TabRect(index), viewport = Viewport();
            if (!NSIsEmptyRect(tab) && NSMinX(tab) >= NSMinX(viewport) && NSMaxX(tab) <= NSMaxX(viewport)) return @YES;
            CGFloat delta = NSIsEmptyRect(tab) || NSMinX(tab) < NSMinX(viewport) ? -120 : 120;
            ((void (*)(id, SEL, CGFloat))objc_msgSend)(Strip(), NSSelectorFromString(@"scrollTabStripBy:"), delta);
            return @NO;
        }) boolValue];
        if (visible) return;
    }
    Log([NSString stringWithFormat:@"tab %ld never came into view", (long)index]);
}

// A tab in view other than `except`, nearest to it.
static NSInteger VisibleNeighbour(NSInteger except) {
    return [Main(^id {
        NSRect viewport = Viewport();
        NSInteger best = -1, count = (NSInteger)Tabs().count;
        for (NSInteger d = 1; d < count && best < 0; d++)
            for (int side = 0; side < 2; side++) {
                NSInteger i = side ? except + d : except - d;
                if (i < 0 || i >= count) continue;
                NSRect r = TabRect(i);
                if (!NSIsEmptyRect(r) && NSMinX(r) >= NSMinX(viewport) && NSMaxX(r) <= NSMaxX(viewport)) { best = i; break; }
            }
        return @(best);
    }) integerValue];
}

// Opens a collapsed group by clicking its title tab, so the tab is in the tab bar.
static void Expand(NSString* group) {
    BOOL collapsed = [Main(^id {
        for (id layout in [Strip() valueForKey:@"groupLayouts"])
            if ([[[layout valueForKey:@"group"] valueForKey:@"displayName"] isEqual:group])
                return [[layout valueForKey:@"group"] valueForKey:@"collapsed"];
        return @NO;
    }) boolValue];
    if (collapsed) {
        NSRect header = GroupHeader(group);
        Main(^id {
            [Strip() mouseDown:MouseEvent(NSEventTypeLeftMouseDown, Centre(header))];
            [Strip() mouseUp:MouseEvent(NSEventTypeLeftMouseUp, Centre(header))];
            return nil;
        });
        Wait(0.5);
    }
}

static NSDictionary* CacheStats(void) {
    return Main(^id {
        SEL selector = NSSelectorFromString(@"spdf_tabPreviewCache");
        // An earlier build, measured for comparison, has no thumbnails.
        id cache = [Delegate() respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(Delegate(), selector) : nil;
        return @{@"entries" : [cache valueForKey:@"count"] ?: @0,
                 @"bytes" : [cache valueForKey:@"byteCount"] ?: @0, @"footprint_mb" : @(FootprintMB())};
    });
}

static double Median(NSArray<NSNumber*>* values) {
    NSArray* sorted = [values sortedArrayUsingSelector:@selector(compare:)];
    return sorted.count ? [sorted[sorted.count / 2] doubleValue] : -1;
}

// Hovers between two tabs `rounds` times; the label's time on arriving at `index` each time.
static NSDictionary* HoverLatency(NSInteger index, NSInteger other, NSInteger rounds) {
    NSMutableArray* times = [NSMutableArray array];
    for (NSInteger i = 0; i < rounds; i++) {
        Hover(Centre(TabRect(other)), NO);
        Wait(0.03);
        [times addObject:@(Hover(Centre(TabRect(index)), NO))];
        Wait(0.03);
    }
    return @{@"median_ms" : @(Median(times)), @"max_ms" : [times valueForKeyPath:@"@max.self"] ?: @0,
             @"card" : @(CardShown())};
}

static void Appearance(NSString* name) {
    Main(^id { NSApp.appearance = [NSAppearance appearanceNamed:name]; return nil; });
    Wait(0.3);
}
