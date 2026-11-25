// The overlay's drags, its menu on placed items and its keys (Tab, Space, X and V, Delete, arrows, Escape, Command-Z,
// Shift-Command-Z and Command-Y; the drawing tools' keys are in +Drawing.mm).
#import "SPDFMacFillDrawingState.h"

#import "SPDFMacDocumentView.h"
#import "SPDFMacFillController.h"

@implementation SPDFMacFillOverlayView (Interaction)

- (void)rightMouseDown:(NSEvent*)event {
    if ([self annotateTakeMouseDown:event] || [self drawingRightMouseDown:event]) return;
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
    [self.window makeFirstResponder:self];
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
    if ((mods & NSEventModifierFlagCommand) && (key == 'z' || key == 'y')) {
        [self.controller flushPendingChanges];  // lines still waiting are written, then undone like any change
        [self cancelDrawingGesture];
        if (key == 'y' || (mods & NSEventModifierFlagShift)) [self.controller redo];
        else [self.controller undo];
        return;
    }
    if (mods & NSEventModifierFlagCommand) {
        [super keyDown:event];
        return;
    }
    if ([self drawingKeyDown:event]) return;
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
    BOOL typing = self.controller.editor || self.focusedField || !NSIsEmptyRect(self.focusedTargetRect);
    if (!typing && (key == 'p' || key == 'a' || key == 'e' || key == 's' || key == 't')) return YES;  // tool keys
    if (key == ' ') return mark || self.focusedField || !NSIsEmptyRect(self.focusedTargetRect);
    return (key == 'x' || key == 'v') && mark;
}

- (void)takeKeysFromPages {
    NSResponder* current = self.window.firstResponder;
    if (!self.hidden && self.window && (current == self.window || current == [self documentView]))
        [self.window makeFirstResponder:self];
}

@end

// The drawing tools' keys: tool letters, Escape, Delete, nudges with the arrow keys, Command-A.
@implementation SPDFMacFillOverlayView (DrawingKeys)

- (void)selectAll:(id)sender {
    if ([self.controller session].tool != SPDFFillToolSelect) {
        [self.nextResponder tryToPerform:@selector(selectAll:) with:sender];
        return;
    }
    NSInteger page = [self documentView].currentPageIndex;
    NSMutableArray* all = [NSMutableArray array];
    for (SPDFFillItem* item in [self.controller itemsOnPage:page])
        if (item.cell < 0) [all addObject:item];
    [self.controller selectItems:all page:page];
}

- (void)commitNudge {
    SPDFFillDrawingState* state = [self drawingState];
    if (!state.nudging) return;
    NSArray* items = state.moving;
    NSSize delta = state.delta;
    state.nudging = NO;
    state.moving = nil;
    state.delta = NSZeroSize;
    [self.controller moveItems:items by:delta];
}

- (void)keyUp:(NSEvent*)event {
    unichar key = event.charactersIgnoringModifiers.length ? [event.charactersIgnoringModifiers characterAtIndex:0] : 0;
    if (key == NSLeftArrowFunctionKey || key == NSRightArrowFunctionKey || key == NSUpArrowFunctionKey ||
        key == NSDownArrowFunctionKey)
        [self commitNudge];
    [super keyUp:event];
}

// P, A, E, S and T pick a tool, but only while nothing is being typed into and no field is focused with Tab.
- (SPDFFillTool)toolForKey:(NSEvent*)event {
    if (self.controller.editor || self.focusedField || !NSIsEmptyRect(self.focusedTargetRect)) return (SPDFFillTool)-1;
    if (event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask &
        (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption))
        return (SPDFFillTool)-1;
    NSString* chars = event.charactersIgnoringModifiers.lowercaseString ?: @"";
    NSDictionary* tools = @{@"p" : @(SPDFFillToolPen), @"a" : @(SPDFFillToolArrow), @"e" : @(SPDFFillToolEraser),
                            @"s" : @(SPDFFillToolSelect), @"t" : @(SPDFFillToolText)};
    NSNumber* tool = chars.length == 1 ? tools[chars] : nil;
    return tool ? (SPDFFillTool)tool.integerValue : (SPDFFillTool)-1;
}

- (BOOL)drawingKeyDown:(NSEvent*)event {
    SPDFFillTool letter = [self toolForKey:event];
    if (letter >= 0) {
        [self.controller chooseTool:letter];
        return YES;
    }
    SPDFFillTool tool = [self.controller session].tool;
    if (!SPDFFillToolDraws(tool)) return NO;
    unichar key = event.charactersIgnoringModifiers.length ? [event.charactersIgnoringModifiers characterAtIndex:0] : 0;
    NSArray* selected = tool == SPDFFillToolSelect ? [self.controller selectedItems] : @[];
    if (key == 27) {  // Escape: the selection first, then back to Text
        if (selected.count) [self.controller selectItems:@[] page:[self.controller session].selectionPage];
        else [self.controller chooseTool:SPDFFillToolText];
        return YES;
    }
    if (!selected.count) return NO;
    if (key == 127 || key == NSDeleteFunctionKey) {
        [self commitNudge];
        [self.controller removeItems:selected];
        return YES;
    }
    if (key == NSLeftArrowFunctionKey || key == NSRightArrowFunctionKey || key == NSUpArrowFunctionKey ||
        key == NSDownArrowFunctionKey) {
        // A run of presses moves the drawing at once and is written as one change when the key comes up.
        SPDFFillDrawingState* state = [self drawingState];
        CGFloat step = (event.modifierFlags & NSEventModifierFlagShift) ? 10 : 1;
        NSSize delta = state.nudging ? state.delta : NSZeroSize;
        delta.width += key == NSLeftArrowFunctionKey ? -step : key == NSRightArrowFunctionKey ? step : 0;
        delta.height += key == NSUpArrowFunctionKey ? -step : key == NSDownArrowFunctionKey ? step : 0;
        if (!state.nudging) state.moving = selected;
        state.nudging = YES;
        state.delta = delta;
        self.needsDisplay = YES;
        return YES;
    }
    return NO;
}

@end
