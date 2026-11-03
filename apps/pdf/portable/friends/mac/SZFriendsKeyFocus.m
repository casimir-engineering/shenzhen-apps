// Tab and Shift-Tab inside the dropdown (SZFriendsKeyFocus.h).

#import "mac/SZFriendsKeyFocus.h"

#import "mac/SZFriendsDropdownInternal.h"

@implementation SZFriendsPage (FocusScope)
- (NSArray<NSView *> *)keyFocusStops {
    return SZFriendsFocusStops(self);
}
@end

@interface SZFriendsConfirmView (FocusScope) <SZFriendsFocusScope>
@end

@implementation SZFriendsConfirmView (FocusScope)
- (NSArray<NSView *> *)keyFocusStops {
    return SZFriendsFocusStops(self);
}
@end

#pragma mark - Stops

static BOOL SZFInSight(NSView *view) {
    return !view.isHiddenOrHasHiddenAncestor && view.alphaValue > 0 && !NSIsEmptyRect(view.visibleRect);
}

static void SZFCollectStops(NSView *view, NSMutableArray<NSView *> *stops) {
    if (view.isHidden || view.alphaValue <= 0) return;
    if ([view isKindOfClass:SZFriendsRowView.class]) return; // the list's own stop stands for its rows
    if ([view isKindOfClass:NSTextField.class]) {
        NSTextField *field = (NSTextField *)view;
        if (field.isEditable && field.isEnabled && SZFInSight(field)) [stops addObject:field];
        return; // a field's insides (its field editor while editing) are the field
    }
    if ([view isKindOfClass:NSTextView.class]) {
        NSTextView *text = (NSTextView *)view;
        if (text.isEditable && !text.isFieldEditor && SZFInSight(text)) [stops addObject:text];
        return;
    }
    if ([view isKindOfClass:SZFriendsListKeyView.class]) return; // placed by the list page itself
    if ([view isKindOfClass:NSButton.class]) {
        NSButton *button = (NSButton *)view;
        if (button.isEnabled && SZFInSight(button)) [stops addObject:button];
        return;
    }
    for (NSView *subview in view.subviews) SZFCollectStops(subview, stops);
}

NSArray<NSView *> *SZFriendsFocusStops(NSView *root) {
    NSMutableArray<NSView *> *stops = [NSMutableArray array];
    for (NSView *subview in root.subviews) SZFCollectStops(subview, stops);
    // Reading order: by top edge into lines (a stop starting above the middle of the line's first stop joins it),
    // then left to right within each line.
    NSMutableArray<NSValue *> *frames = [NSMutableArray array];
    for (NSView *stop in stops) [frames addObject:[NSValue valueWithRect:[stop convertRect:stop.bounds toView:root]]];
    BOOL flipped = root.isFlipped;
    CGFloat (^top)(NSRect) = ^CGFloat(NSRect frame) { return flipped ? NSMinY(frame) : -NSMaxY(frame); };
    NSMutableArray<NSNumber *> *order = [NSMutableArray array];
    for (NSUInteger index = 0; index < stops.count; index++) [order addObject:@(index)];
    [order sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        CGFloat ta = top(frames[a.unsignedIntegerValue].rectValue), tb = top(frames[b.unsignedIntegerValue].rectValue);
        return ta < tb ? NSOrderedAscending : ta > tb ? NSOrderedDescending : [a compare:b];
    }];
    NSMutableArray<NSView *> *sorted = [NSMutableArray array];
    NSUInteger lineStart = 0;
    while (lineStart < order.count) {
        NSRect first = frames[order[lineStart].unsignedIntegerValue].rectValue;
        CGFloat limit = top(first) + NSHeight(first) / 2;
        NSUInteger lineEnd = lineStart + 1;
        while (lineEnd < order.count && top(frames[order[lineEnd].unsignedIntegerValue].rectValue) < limit) lineEnd++;
        NSArray<NSNumber *> *line = [[order subarrayWithRange:NSMakeRange(lineStart, lineEnd - lineStart)]
            sortedArrayUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
                CGFloat xa = NSMinX(frames[a.unsignedIntegerValue].rectValue);
                CGFloat xb = NSMinX(frames[b.unsignedIntegerValue].rectValue);
                return xa < xb ? NSOrderedAscending : xa > xb ? NSOrderedDescending : [a compare:b];
            }];
        for (NSNumber *index in line) [sorted addObject:stops[index.unsignedIntegerValue]];
        lineStart = lineEnd;
    }
    return sorted;
}

#pragma mark - Moving

BOOL SZFriendsFocus(NSView *view) {
    NSWindow *window = view.window;
    if (!window || view.isHiddenOrHasHiddenAncestor) return NO;
    if ([view isKindOfClass:SZFriendsButton.class]) return [(SZFriendsButton *)view takeKeyFocus];
    if (![window makeFirstResponder:view]) return NO;
    NSResponder *responder = window.firstResponder;
    if (responder == view) return YES;
    // A field hands its editing to the window's field editor.
    return [responder isKindOfClass:NSTextView.class] && ((NSTextView *)responder).isFieldEditor &&
           [(NSView *)responder isDescendantOf:view];
}

static id<SZFriendsFocusScope> SZFScopeFor(NSView *from) {
    id<SZFriendsFocusScope> nearest = nil;
    for (NSView *view = from; view; view = view.superview) {
        if ([view isKindOfClass:SZFriendsDropdownContent.class]) {
            SZFriendsDropdownContent *content = (SZFriendsDropdownContent *)view;
            return (id<SZFriendsFocusScope>)content.confirmation ?: content.topPage;
        }
        if (!nearest && [view conformsToProtocol:@protocol(SZFriendsFocusScope)])
            nearest = (id<SZFriendsFocusScope>)view;
    }
    return nearest;
}

BOOL SZFriendsInFocusScope(NSView *view) {
    return SZFScopeFor(view) != nil;
}

static BOOL SZFMoveFocusIn(id<SZFriendsFocusScope> scope, NSView *_Nullable from, BOOL backward) {
    NSArray<NSView *> *stops = [scope keyFocusStops];
    NSInteger count = (NSInteger)stops.count, current = -1;
    for (NSInteger index = 0; from && index < count; index++)
        if (from == stops[index] || [from isDescendantOf:stops[index]]) current = index;
    NSInteger step = backward ? -1 : 1;
    NSInteger next = current < 0 ? (backward ? count - 1 : 0) : current + step;
    // One round at most, past stops that refuse the focus (a control AppKit keeps for Full Keyboard Access).
    for (NSInteger tried = 0; tried < count; tried++, next += step) {
        NSView *stop = stops[(NSUInteger)(((next % count) + count) % count)];
        if (stop == from || SZFriendsFocus(stop)) return YES;
    }
    return YES;
}

BOOL SZFriendsMoveFocus(NSView *from, BOOL backward) {
    id<SZFriendsFocusScope> scope = SZFScopeFor(from);
    if (!scope) return NO;
    // A stop hidden under the scope (the composer of a page left by Back) counts as no stop.
    BOOL inScope = [scope isKindOfClass:NSView.class] && [from isDescendantOf:(NSView *)scope];
    return SZFMoveFocusIn(scope, inScope ? from : nil, backward);
}

BOOL SZFriendsFocusCommand(NSView *from, SEL command) {
    if (command == @selector(insertTab:)) return SZFriendsMoveFocus(from, NO);
    if (command == @selector(insertBacktab:)) return SZFriendsMoveFocus(from, YES);
    return NO;
}

static BOOL SZFPlainKey(NSEvent *event) {
    NSEventModifierFlags flags = event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagOption |
                                                        NSEventModifierFlagControl);
    return flags == 0;
}

BOOL SZFriendsIsTabKey(NSEvent *event) {
    return event.keyCode == 48 && SZFPlainKey(event);
}

BOOL SZFriendsIsReturnKey(NSEvent *event) {
    return (event.keyCode == 36 || event.keyCode == 76) && SZFPlainKey(event) &&
           !(event.modifierFlags & NSEventModifierFlagShift);
}

BOOL SZFriendsHandleUnfocusedKey(id<SZFriendsFocusScope> scope, NSEvent *event) {
    if (!scope) return NO;
    if (SZFriendsIsTabKey(event))
        return SZFMoveFocusIn(scope, nil, (event.modifierFlags & NSEventModifierFlagShift) != 0);
    if (!SZFriendsIsReturnKey(event)) return NO;
    for (NSView *stop in [scope keyFocusStops]) {
        if (![stop isKindOfClass:SZFriendsButton.class]) continue;
        SZFriendsButton *button = (SZFriendsButton *)stop;
        if (button.style != SZFriendsButtonStylePrimary) continue;
        [button performClick:nil];
        return YES;
    }
    return NO;
}

#pragma mark - The list's stop

@implementation SZFriendsListKeyView

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (BOOL)becomeFirstResponder {
    _focused = YES;
    if (self.onFocusChange) self.onFocusChange(YES);
    return YES;
}

- (BOOL)resignFirstResponder {
    _focused = NO;
    if (self.onFocusChange) self.onFocusChange(NO);
    return YES;
}

- (NSView *)hitTest:(NSPoint)point {
    (void)point;
    return nil;
}

- (void)keyDown:(NSEvent *)event {
    if (self.onKey && self.onKey(event)) return;
    [super keyDown:event];
}

@end
