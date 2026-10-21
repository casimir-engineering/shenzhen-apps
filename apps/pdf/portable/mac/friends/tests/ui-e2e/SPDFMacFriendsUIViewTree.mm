// friends-ui-e2e's driver (SPDFMacFriendsUIE2E.h): the live view tree, and the real events that click, scroll and type.

#import "SPDFMacFriendsUIDriverInternal.h"

#pragma mark - The view tree

NSArray<NSView*>* UIAllViews(NSView* root) {
    NSMutableArray* views = [NSMutableArray arrayWithObject:root];
    for (NSView* subview in root.subviews) [views addObjectsFromArray:UIAllViews(subview)];
    return views;
}

BOOL UIVisible(NSView* view) {
    if (!view.window || NSWidth(view.bounds) < 1 || NSHeight(view.bounds) < 1) return NO;
    NSRect visible = view.bounds;
    for (NSView* v = view; v; v = v.superview) {
        if (v.hidden || v.alphaValue < 0.01) return NO;
        if (v != view && [v isKindOfClass:NSClipView.class]) {
            NSRect clip = [v convertRect:v.bounds toView:view];
            visible = NSIntersectionRect(visible, clip);
            if (NSIsEmptyRect(visible)) return NO;
        }
    }
    return YES;
}

static NSString* UIWords(NSView* view) {
    if ([view isKindOfClass:NSTextField.class]) {
        NSTextField* field = (NSTextField*)view;
        return field.stringValue.length ? field.stringValue : nil;
    }
    if ([view isKindOfClass:NSTextView.class]) return ((NSTextView*)view).string;
    if ([view isKindOfClass:NSButton.class]) {
        NSButton* button = (NSButton*)view;
        if (button.title.length) return button.title;
    }
    NSString* label = view.accessibilityLabel;
    return label.length ? label : nil;
}

NSView* UIFindText(NSView* root, NSString* text) {
    for (NSView* view in UIAllViews(root)) {
        NSString* words = UIWords(view);
        // Rows speak in lower case ("Kenji, request sent") what they draw as a capitalised subtitle.
        if (words && [words rangeOfString:text options:NSCaseInsensitiveSearch].location != NSNotFound && UIVisible(view))
            return view;
    }
    return nil;
}

NSButton* UIFindButton(NSView* root, NSString* title) {
    for (NSView* view in UIAllViews(root)) {
        if (![view isKindOfClass:NSButton.class]) continue;
        NSButton* button = (NSButton*)view;
        if (([button.title isEqualToString:title] || [button.accessibilityLabel isEqualToString:title]) &&
            UIVisible(button))
            return button;
    }
    return nil;
}

NSString* UIDescribe(NSView* root) {
    NSMutableArray* lines = [NSMutableArray array];
    for (NSView* view in UIAllViews(root)) {
        NSString* words = UIWords(view);
        if (!words.length || !UIVisible(view)) continue;
        NSString* kind = [view isKindOfClass:NSButton.class]
                             ? (((NSButton*)view).enabled ? @"button" : @"button (disabled)")
                             : NSStringFromClass(view.class);
        [lines addObject:[NSString stringWithFormat:@"    %@: %@", kind,
                                   [words stringByReplacingOccurrencesOfString:@"\n" withString:@" / "]]];
    }
    return [lines componentsJoinedByString:@"\n"];
}

// Views of `view` (inclusive) lying outside `area` in `root`'s coordinates; a scroll view's document may extend past
// it (it scrolls), and controls are checked as a whole.
static void UIOutside(NSView* view, NSView* root, NSRect area, NSMutableArray* problems) {
    if (view.hidden || view.alphaValue < 0.01) return;
    NSRect frame = [view convertRect:view.bounds toView:root];
    if (NSWidth(frame) > 0 && NSHeight(frame) > 0 && !NSContainsRect(NSInsetRect(area, -0.5, -0.5), frame))
        [problems addObject:[NSString stringWithFormat:@"%@ \"%@\" lies outside the popover: %@ not in %@",
                                                       view.className, UIWords(view) ?: @"",
                                                       NSStringFromRect(frame), NSStringFromRect(area)]];
    if ([view isKindOfClass:NSScrollView.class] || [view isKindOfClass:NSControl.class]) return;
    for (NSView* subview in view.subviews) UIOutside(subview, root, area, problems);
}

NSArray<NSString*>* UILayoutProblems(UIRig* rig) {
    NSMutableArray* problems = [NSMutableArray array];
    SZFriendsDropdownContent* content = rig.content;
    NSView* frameView = content.superview;
    if (!frameView) return @[ @"the dropdown is in no popover" ];
    [content layoutSubtreeIfNeeded];
    // The content keeps the place the popover gave it (the 2026-10-20 report: shifted down and left, cropped).
    if (!NSContainsRect(NSInsetRect(frameView.bounds, -0.5, -0.5), content.frame))
        [problems addObject:[NSString stringWithFormat:@"the dropdown %@ leaves the popover %@",
                                                       NSStringFromRect(content.frame),
                                                       NSStringFromRect(frameView.bounds)]];
    UIOutside(content, frameView, content.frame, problems);
    for (NSView* view in UIAllViews(content)) {
        if (!UIVisible(view)) continue;
        if ([view isKindOfClass:NSTextField.class]) {
            NSTextField* label = (NSTextField*)view;
            if (label.editable || !label.stringValue.length || label.cell.lineBreakMode == NSLineBreakByTruncatingTail)
                continue;
            CGFloat needed = [label.cell cellSizeForBounds:NSMakeRect(0, 0, NSWidth(label.frame), CGFLOAT_MAX)].height;
            if (NSHeight(label.frame) + 0.5 < needed)
                [problems addObject:[NSString stringWithFormat:@"\"%@\" is cut: %.0f pt of %.0f", label.stringValue,
                                                               NSHeight(label.frame), needed]];
        } else if ([view isKindOfClass:SZFriendsButton.class]) {
            SZFriendsButton* button = (SZFriendsButton*)view;
            if (!button.title.length || button.style == SZFriendsButtonStylePlain) continue;
            if ([button fittingWidth] > NSWidth(button.frame) + 0.5)
                [problems addObject:[NSString stringWithFormat:@"button \"%@\" is cut: %.0f pt of %.0f", button.title,
                                                               NSWidth(button.frame), [button fittingWidth]]];
        }
    }
    return problems;
}

#pragma mark - Events

static NSInteger UIEventNumber = 1;
static BOOL UIWhollyShown(NSView* view);

// A press and release at the middle of `view`, through its window, as the window server would deliver them: the
// release is queued first, so a control's tracking loop finds it. The point must reach `view` by hit testing, so a
// control drawn under another view fails here as it would for a person.
BOOL UIClick(NSView* view, NSString** why) {
    // Out of sight in a scroll view, a person scrolls to it first.
    if (view.window && !UIWhollyShown(view)) UIScrollIntoView(view);
    NSWindow* window = view.window;
    if (!window || !UIVisible(view)) {
        if (why) *why = [NSString stringWithFormat:@"%@ \"%@\" is not on screen", view.className, UIWords(view) ?: @""];
        return NO;
    }
    [window layoutIfNeeded];
    NSRect bounds = view.bounds;
    NSPoint point = [view convertPoint:NSMakePoint(NSMidX(bounds), NSMidY(bounds)) toView:nil];
    NSView* top = window.contentView.superview ?: window.contentView;
    NSView* hit = [top hitTest:point];
    if (!(hit == view || [hit isDescendantOf:view])) {
        if (why) *why = [NSString stringWithFormat:@"a click on %@ \"%@\" lands on %@", view.className,
                                                   UIWords(view) ?: @"", hit.className];
        return NO;
    }
    if ([view isKindOfClass:NSControl.class] && !((NSControl*)view).enabled) {
        if (why) *why = [NSString stringWithFormat:@"%@ \"%@\" is disabled", view.className, UIWords(view) ?: @""];
        return NO;
    }
    // Key first, as the person's first click on a window makes it: the click itself then reaches the control.
    if (!window.isKeyWindow) {
        if (window.sheetParent && !window.sheetParent.isKeyWindow) [window.sheetParent makeKeyWindow];
        [window makeKeyWindow];
    }
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    NSEvent* down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:point modifierFlags:0 timestamp:now
                                   windowNumber:window.windowNumber context:nil eventNumber:UIEventNumber++
                                     clickCount:1 pressure:1];
    NSEvent* up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:point modifierFlags:0
                                    timestamp:now + 0.05 windowNumber:window.windowNumber context:nil
                                  eventNumber:UIEventNumber++ clickCount:1 pressure:0];
    [NSApp postEvent:up atStart:NO];
    // A person's click makes their app active and the window key before it lands. This run never activates (the
    // person's own app keeps focus), and in an inactive app the window server takes key status back at any moment,
    // so for the length of the press AppKit is told the app is active and this window key: otherwise it drops a
    // click on a destructive button, such as the Reset Friends sheet's "Reset Friends" (the verifier's failures of
    // 2026-10-20, and one run in three after the app alone was made to read as active).
    UIClickMakesActive = YES;
    UIClickWindow = window;
    [window sendEvent:down];
    // A view that does not track the press leaves the release queued: deliver it as the window server would.
    NSEvent* left = [NSApp nextEventMatchingMask:NSEventMaskLeftMouseUp untilDate:nil inMode:NSDefaultRunLoopMode
                                         dequeue:YES];
    if (left) [left.window ?: window sendEvent:left];
    UIClickMakesActive = NO;
    UISpin(0.05);
    return YES;
}

// Is `view` wholly inside its scroll view's visible part (or in none)?
static BOOL UIWhollyShown(NSView* view) {
    NSScrollView* scroll = view.enclosingScrollView;
    if (!scroll) return UIVisible(view);
    NSRect inClip = [view convertRect:view.bounds toView:scroll.contentView];
    return NSContainsRect(NSInsetRect(scroll.contentView.bounds, -0.5, -0.5), inClip);
}

BOOL UIScrollIntoView(NSView* view) {
    NSScrollView* scroll = view.enclosingScrollView;
    for (int attempt = 0; scroll && !UIWhollyShown(view) && attempt < 80; attempt++) {
        NSRect inClip = [view convertRect:view.bounds toView:scroll.contentView];
        NSRect shown = scroll.contentView.bounds;
        BOOL below = scroll.contentView.isFlipped ? NSMaxY(inClip) > NSMaxY(shown) : NSMinY(inClip) < NSMinY(shown);
        // A wheel turn of 30 points, as a trackpad without momentum sends it, to the scroll view under the pointer.
        CGEventRef wheel = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 1, below ? -30 : 30);
        NSEvent* event = wheel ? [NSEvent eventWithCGEvent:wheel] : nil;
        if (wheel) CFRelease(wheel);
        if (!event) return NO;
        [scroll scrollWheel:event];
        UISpin(0.02);
    }
    return UIWhollyShown(view);
}

NSView* UIReveal(NSView* root, NSString* text) {
    for (NSView* view in UIAllViews(root)) {
        NSString* words = UIWords(view);
        if (!words || [words rangeOfString:text options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        BOOL shown = YES;
        for (NSView* v = view; v && v != root.superview; v = v.superview)
            if (v.hidden || v.alphaValue < 0.01) shown = NO;
        if (shown && UIScrollIntoView(view) && UIVisible(view)) return view;
    }
    return nil;
}

static NSTextView* UIEditor(NSWindow* window) {
    NSResponder* responder = window.firstResponder;
    return [responder isKindOfClass:NSTextView.class] ? (NSTextView*)responder : nil;
}

BOOL UIType(NSWindow* window, NSString* text) {
    NSTextView* editor = UIEditor(window);
    if (!editor) return NO;
    for (NSUInteger i = 0; i < text.length; i++) {
        NSRange range = [text rangeOfComposedCharacterSequenceAtIndex:i];
        [editor insertText:[text substringWithRange:range] replacementRange:NSMakeRange(NSNotFound, 0)];
        i = NSMaxRange(range) - 1;
    }
    UISpin(0.02);
    return YES;
}

BOOL UIClearField(NSWindow* window) {
    NSTextView* editor = UIEditor(window);
    if (!editor) return NO;
    [editor selectAll:nil];
    [editor deleteBackward:nil];
    UISpin(0.02);
    return YES;
}

void UIKey(NSWindow* window, unsigned short keyCode, NSString* characters) {
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    const NSEventType types[] = {NSEventTypeKeyDown, NSEventTypeKeyUp};
    for (NSEventType type : types) {
        NSEvent* event = [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:0 timestamp:now
                                      windowNumber:window.windowNumber context:nil characters:characters
                                 charactersIgnoringModifiers:characters isARepeat:NO keyCode:keyCode];
        [window sendEvent:event];
    }
    UISpin(0.05);
}

void UIPressReturn(NSWindow* window) { UIKey(window, 36, @"\r"); }
void UIPressEscape(NSWindow* window) { UIKey(window, 53, @"\x1b"); }
