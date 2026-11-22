// The overlay's drags, its menu on placed items and its keys (Tab, Space, X and V, Delete, arrows, Escape, Command-Z).
#import "SPDFMacFillOverlayViewPrivate.h"

#import "SPDFMacDocumentView.h"
#import "SPDFMacFillController.h"

@implementation SPDFMacFillOverlayView (Interaction)

- (void)rightMouseDown:(NSEvent*)event {
    NSInteger index;
    NSPoint p;
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    SPDFFillItem* item = [self locateViewPoint:point page:&index pagePoint:&p] ? [self itemAt:p page:index] : nil;
    if (!item) {
        [[self documentView] rightMouseDown:event];
        return;
    }
    self.selectedItem = item;
    self.needsDisplay = YES;
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@""];
    if (item.isMark) {
        NSMenuItem* check = [menu addItemWithTitle:@"Check" action:@selector(menuCheck:) keyEquivalent:@""];
        check.state = item.kind == SPDF_FILL_CHECK ? NSControlStateValueOn : NSControlStateValueOff;
        NSMenuItem* cross = [menu addItemWithTitle:@"Cross" action:@selector(menuCross:) keyEquivalent:@""];
        cross.state = item.kind == SPDF_FILL_CROSS ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem:[NSMenuItem separatorItem]];
    } else if (item.text) {
        [menu addItemWithTitle:@"Edit" action:@selector(menuEdit:) keyEquivalent:@""];
    }
    [menu addItemWithTitle:@"Remove" action:@selector(menuRemove:) keyEquivalent:@""];
    for (NSMenuItem* entry in menu.itemArray) entry.target = self;
    [NSMenu popUpContextMenu:menu withEvent:event forView:self];
}

- (void)menuCheck:(id)sender { (void)sender; [self.controller setItem:self.selectedItem cross:NO]; }
- (void)menuCross:(id)sender { (void)sender; [self.controller setItem:self.selectedItem cross:YES]; }
- (void)menuEdit:(id)sender { (void)sender; [self.controller openEditorForItem:self.selectedItem]; }
- (void)menuRemove:(id)sender {
    (void)sender;
    [self.controller deleteItem:self.selectedItem];
    self.selectedItem = nil;
}

- (void)trackItem:(SPDFFillItem*)item page:(NSInteger)index from:(NSPoint)start event:(NSEvent*)event {
    NSRect viewRect = NSInsetRect([self viewRectForPageRect:item.rect page:index], -2, -2);
    BOOL resizing = [self.selectedItem.nm isEqual:item.nm] && !item.text &&
                    NSPointInRect(start, NSInsetRect([self resizeHandleForViewRect:viewRect], -3, -3));
    CGFloat zoom = [self zoom];
    BOOL moved = NO;
    for (;;) {
        NSEvent* next = [self.window nextEventMatchingMask:NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp
                                                 untilDate:NSDate.distantFuture
                                                    inMode:NSEventTrackingRunLoopMode
                                                   dequeue:YES];
        if (!next) break;
        NSPoint now = [self convertPoint:next.locationInWindow fromView:nil];
        CGFloat dx = (now.x - start.x) / zoom, dy = (now.y - start.y) / zoom;
        if (!moved && item.cell < 0 && hypot(now.x - start.x, now.y - start.y) > 3) {
            moved = YES;
            self.dragItem = item;
            [NSCursor.closedHandCursor set];
        }
        if (moved) {
            NSRect r = item.rect;
            if (resizing) {
                CGFloat aspect = NSWidth(r) / MAX(0.1, NSHeight(r));
                CGFloat width = MAX(6.0, NSWidth(r) + dx);
                r.size = NSMakeSize(width, width / MAX(0.1, aspect));
            } else {
                r = NSOffsetRect(r, dx, dy);
            }
            self.dragRect = r;
            self.needsDisplay = YES;
        }
        if (next.type == NSEventTypeLeftMouseUp) break;
    }
    self.dragItem = nil;
    if (!moved) {
        // A click: a mark comes off like a checkbox, text opens for editing, a signature is selected.
        if (item.isMark) {
            [self.controller deleteItem:item];
            self.selectedItem = nil;
        } else if (item.text) {
            [self.controller openEditorForItem:item];
        } else {
            self.selectedItem = item;
        }
        self.needsDisplay = YES;
        return;
    }
    NSRect target = self.dragRect;
    if (item.text && !(event.modifierFlags & NSEventModifierFlagCommand)) {
        // Dropped text snaps again, onto the line or into the box under its start.
        spdf_snap_result snap;
        NSPoint anchor = NSMakePoint(NSMinX(target) + 1, spdf_fill_text_baseline(SPDFFillRectToCore(target),
                                                                                  (float)item.fontSize));
        if ([self resolveAt:anchor page:index purpose:SPDF_SNAP_FOR_TEXT aspect:1 snapping:YES result:&snap] !=
                SPDF_SNAP_NONE &&
            snap.kind != SPDF_SNAP_FIELD && !snap.place_mark && !snap.cells)
            target.origin = SPDFFillRectFromCore(snap.place).origin;
    }
    target.origin.x = MAX(0, target.origin.x);
    target.origin.y = MAX(0, target.origin.y);
    self.selectedItem = item;
    [self.controller updateItem:item rect:target];
    self.needsDisplay = YES;
}

#pragma mark - Keys

- (void)keyDown:(NSEvent*)event {
    NSString* chars = event.charactersIgnoringModifiers.lowercaseString ?: @"";
    unichar key = chars.length ? [chars characterAtIndex:0] : 0;
    NSEventModifierFlags mods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    SPDFFillItem* markTarget = self.selectedItem.isMark ? self.selectedItem : self.hoverItem.isMark ? self.hoverItem : nil;
    if ((mods & NSEventModifierFlagCommand) && key == 'z') {
        if (mods & NSEventModifierFlagShift) [self.controller redo];
        else [self.controller undo];
        return;
    }
    if (mods & NSEventModifierFlagCommand) {
        [super keyDown:event];
        return;
    }
    switch (key) {
        case '\t':
        case 25:  // back tab
            [self.controller moveFocusForward:!(mods & NSEventModifierFlagShift) && key != 25];
            return;
        case ' ':
            if (markTarget) [self.controller setItem:markTarget cross:markTarget.kind != SPDF_FILL_CROSS];
            else if (self.focusedField || !NSIsEmptyRect(self.focusedTargetRect)) [self.controller toggleFocusedField];
            else break;
            return;
        case 'x':
        case 'v':
            if (!markTarget) break;
            [self.controller setItem:markTarget cross:key == 'x'];
            return;
        case '\r':
        case 3:
            if (self.focusedField.type == SPDF_FIELD_TEXT) [self.controller openEditorForField:self.focusedField];
            else if (self.focusedField) [self.controller toggleFocusedField];
            else if (!NSIsEmptyRect(self.focusedTargetRect)) [self.controller toggleFocusedField];
            else break;
            return;
        case 127:
        case NSDeleteFunctionKey:
            if (!self.selectedItem) break;
            [self.controller deleteItem:self.selectedItem];
            self.selectedItem = nil;
            return;
        case 27:
            if (self.selectedItem || self.focusedField || !NSIsEmptyRect(self.focusedTargetRect)) {
                [self clearTransientState];
            } else if ([self.controller session].tool == SPDFFillToolSignature) {
                [self.controller endInteraction];
                [self.controller refreshChrome];
            } else {
                break;
            }
            return;
        default: break;
    }
    unichar raw = event.charactersIgnoringModifiers.length ? [event.charactersIgnoringModifiers characterAtIndex:0] : 0;
    if (raw == NSDownArrowFunctionKey && (mods & NSEventModifierFlagOption) && self.focusedField &&
        (self.focusedField.type == SPDF_FIELD_COMBO || self.focusedField.type == SPDF_FIELD_LIST)) {
        [self.controller showChoiceMenuForField:self.focusedField];
        return;
    }
    if (self.selectedItem && (raw == NSLeftArrowFunctionKey || raw == NSRightArrowFunctionKey ||
                              raw == NSUpArrowFunctionKey || raw == NSDownArrowFunctionKey)) {
        CGFloat step = (mods & NSEventModifierFlagShift) ? 10 : 1;
        NSRect r = self.selectedItem.rect;
        r.origin.x += raw == NSLeftArrowFunctionKey ? -step : raw == NSRightArrowFunctionKey ? step : 0;
        r.origin.y += raw == NSUpArrowFunctionKey ? -step : raw == NSDownArrowFunctionKey ? step : 0;
        [self.controller updateItem:self.selectedItem rect:r];
        return;
    }
    // Everything else scrolls and pages as it does without Fill & Sign.
    [[self documentView] keyDown:event];
}

@end

@implementation SPDFMacFillOverlayView (Keys)

- (BOOL)handlesTypedKey:(NSEvent*)event {
    if (self.hidden || (event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask &
                        (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption)))
        return NO;
    NSString* chars = event.charactersIgnoringModifiers.lowercaseString ?: @"";
    unichar key = chars.length == 1 ? [chars characterAtIndex:0] : 0;
    BOOL mark = self.selectedItem.isMark || self.hoverItem.isMark;
    if (key == ' ') return mark || self.focusedField || !NSIsEmptyRect(self.focusedTargetRect);
    return (key == 'x' || key == 'v') && mark;
}

@end
