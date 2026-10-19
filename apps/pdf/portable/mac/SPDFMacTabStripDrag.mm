#import "SPDFMacTabStripViewPrivate.h"
#import "SPDFMacDocumentFormats.h"
#import "SPDFMacTabDragSignature.h"

static NSString* spdf_tab_strip_json_string_from_object(id object) {
    NSData* data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

static NSDictionary* spdf_tab_strip_json_dictionary_from_string(NSString* string) {
    NSData* data = [string dataUsingEncoding:NSUTF8StringEncoding];
    id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

@implementation SPDFTabStripView (Drag)
- (void)startTabDragSessionWithEvent:(NSEvent*)event {
    if (_draggedTabIndex < 0 || _draggedTabIndex >= (NSInteger)self.tabs.count) return;
    SPDFDocumentTab* snapshot = [self.reader tabSnapshotForDragAtIndex:_draggedTabIndex];
    if (!snapshot.path.length) return;

    NSDictionary* payload = spdf_dictionary_from_tab(snapshot, self.window.windowNumber);
    NSString* json = spdf_tab_strip_json_string_from_object(payload);
    if (!json.length) return;

    // Signed, so Friends can tell this drag from another app writing the same type (SPDFMacTabDragSignature.h).
    NSPasteboardItem* item = SPDFMacTabDragPasteboardItem(json, SPDFMacTabDragKey(), NSDate.date);
    NSDraggingItem* dragItem = [[NSDraggingItem alloc] initWithPasteboardWriter:item];
    NSRect tabRect = [self rectForTabAtIndex:_draggedTabIndex];
    NSImage* image = [[NSImage alloc] initWithSize:tabRect.size];
    [image lockFocus];
    [[NSColor.controlAccentColor colorWithAlphaComponent:0.22] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0, 0, NSWidth(tabRect), NSHeight(tabRect)) xRadius:7
                                     yRadius:7] fill];
    NSString* title = [self titleForTabAtIndex:_draggedTabIndex];
    NSMutableParagraphStyle* style = [[NSMutableParagraphStyle alloc] init];
    style.alignment = NSTextAlignmentCenter;
    style.lineBreakMode = NSLineBreakByTruncatingMiddle;
    NSDictionary* attrs = @{
        NSFontAttributeName : [NSFont systemFontOfSize:12 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName : NSColor.labelColor,
        NSParagraphStyleAttributeName : style
    };
    [title drawWithRect:NSInsetRect(NSMakeRect(0, 0, NSWidth(tabRect), NSHeight(tabRect)), 18, 7)
                options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
             attributes:attrs];
    [image unlockFocus];
    [dragItem setDraggingFrame:tabRect contents:image];

    _dragSessionTabIndex = _draggedTabIndex;
    _sameWindowTabDropHandled = NO;
    _detachedTabDrag = YES;
    [self setNeedsDisplay:YES];
    NSDraggingSession* session = [self beginDraggingSessionWithItems:@[ dragItem ] event:event source:self];
    // No slide-back animation on cancel/fail: a failed drop detaches into a new
    // window at the drop point (animating the image back first would contradict
    // that), and -draggingSession:endedAtPoint:operation: then runs at the
    // instant of an Escape cancel, while the key/button state that identifies
    // the cancellation (see -tabDragSessionEndedByCancellation) is still live.
    session.animatesToStartingPositionsOnCancelOrFail = NO;
}

- (void)startGroupDragSessionWithEvent:(NSEvent*)event {
    if (!_pressedGroup) return;
    NSArray* tabs = [self.groupReader snapshotTabGroup:_pressedGroup];
    if (!tabs.count) return;
    NSDictionary* payload = @{@"groupTabs": tabs, @"sourcePID": @(NSProcessInfo.processInfo.processIdentifier),
                              @"sourceWindow": @(self.window.windowNumber)};
    NSString* json = spdf_tab_strip_json_string_from_object(payload);
    NSPasteboardItem* item = SPDFMacTabDragPasteboardItem(json, SPDFMacTabDragKey(), NSDate.date);
    NSDraggingItem* dragItem = [[NSDraggingItem alloc] initWithPasteboardWriter:item];
    NSString* title = [NSString stringWithFormat:@"%@ · %lu tabs", _pressedGroup.displayName, (unsigned long)tabs.count];
    NSColor* accent = spdf_tab_group_accent(_pressedGroup.colorName);
    NSImage* image = [NSImage imageWithSize:NSMakeSize(180, 34) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [accent setFill];
        [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:12 yRadius:12] fill];
        [title drawAtPoint:NSMakePoint(12, 10) withAttributes:@{NSFontAttributeName: [NSFont systemFontOfSize:12],
            NSForegroundColorAttributeName: spdf_tab_group_selected_fill(nil, NO)}];
        return YES;
    }];
    [dragItem setDraggingFrame:NSMakeRect(_dragStartPoint.x - 14, 4, 180, 34) contents:image];
    _dragSessionGroup = _pressedGroup;
    _dragSessionTabIndex = -1;
    _sameWindowTabDropHandled = NO;
    NSDraggingSession* session = [self beginDraggingSessionWithItems:@[dragItem] event:event source:self];
    session.animatesToStartingPositionsOnCancelOrFail = NO;
}

// YES when the dragging session that just ended was cancelled (Escape or
// Cmd-.) rather than concluded by a drop: a release ends the drag BECAUSE the
// left button went up, so at cancel time the button is still physically down.
// The Escape key state is checked as well in case the button-up races the
// ended callback. Both are point-in-time state queries (no event tap, no
// Accessibility/Input Monitoring permission). Sessions are created with
// animatesToStartingPositionsOnCancelOrFail = NO, so this runs at the moment
// of cancellation while that state is still current.
- (BOOL)tabDragSessionEndedByCancellation {
    if ((NSEvent.pressedMouseButtons & 0x1) != 0) return YES;
    return CGEventSourceKeyState(kCGEventSourceStateCombinedSessionState, 53 /* kVK_Escape */);
}

- (void)draggingSession:(NSDraggingSession*)session
           endedAtPoint:(NSPoint)screenPoint
              operation:(NSDragOperation)operation {
    (void)session;
    (void)screenPoint;
    SPDFTabGroup* group = _dragSessionGroup;
    _dragSessionGroup = nil;
    _pressedGroup = nil;
    NSInteger index = _dragSessionTabIndex;
    BOOL sameWindowDropHandled = _sameWindowTabDropHandled;
    _dragSessionTabIndex = -1;
    _sameWindowTabDropHandled = NO;
    [self resetTabDragTracking];
    if (sameWindowDropHandled) return;
    if (group) {
        if (operation == NSDragOperationMove) [self.groupReader closeTabGroup:group];
        else if (operation == NSDragOperationNone && ![self tabDragSessionEndedByCancellation])
            [self.groupReader detachTabGroup:group atScreenPoint:screenPoint];
        return;
    }
    if (index < 0) return;
    if (operation == NSDragOperationMove) {
        [self.reader closeTabAtIndex:index];
        return;
    }
    if (operation != NSDragOperationNone) return;
    if ([self tabDragSessionEndedByCancellation]) return;
    [self.reader detachTabAtIndex:index];
}

// YES when the dragged tab originated from THIS strip (same process and same
// window number in the pasteboard payload): the drop is then handled as an
// in-process move of the live tab instead of a pasteboard-copy insert.
- (BOOL)isSameWindowTabDragFromSender:(id<NSDraggingInfo>)sender {
    NSString* json = [sender.draggingPasteboard stringForType:SPDFTabDragPasteboardType];
    NSDictionary* payload = spdf_tab_strip_json_dictionary_from_string(json);
    NSNumber* sourcePID = [payload[@"sourcePID"] isKindOfClass:NSNumber.class] ? payload[@"sourcePID"] : nil;
    NSNumber* sourceWindow = [payload[@"sourceWindow"] isKindOfClass:NSNumber.class] ? payload[@"sourceWindow"] : nil;
    if (!sourceWindow) return NO;
    if (sourcePID && sourcePID.integerValue != NSProcessInfo.processInfo.processIdentifier) return NO;
    return sourceWindow.integerValue == self.window.windowNumber;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    // Same-window drags are accepted too: a tab torn off this strip and (still
    // held) dragged back in reinserts in place — the continuous-gesture
    // counterpart of the cross-window reattach, with the same indicator.
    NSDragOperation operation = NSDragOperationNone;
    if ([sender.draggingPasteboard availableTypeFromArray:@[ SPDFTabDragPasteboardType ]]) {
        operation = NSDragOperationMove;
    }
    // Browser-style insertion indicator: while a detached tab hovers over this
    // strip, mark the gap it would insert into; the drop below uses the same
    // -dropIndexForPoint: geometry, so indicator and drop always agree.
    if (operation == NSDragOperationMove) {
        NSPoint point = [self convertPoint:sender.draggingLocation fromView:nil];
        [self updateDropIndicatorForPoint:point];
        NSDictionary* payload = spdf_tab_strip_json_dictionary_from_string(
            [sender.draggingPasteboard stringForType:SPDFTabDragPasteboardType]);
        if ([payload[@"groupTabs"] isKindOfClass:NSArray.class] && [self hasTabGroups]) {
            _dropIndicatorSlot = -1;
            _groupDropBoundaryX = [self groupInsertionBoundaryForPoint:point];
            id first = [payload[@"groupTabs"] firstObject];
            _groupPreviewColor = [first isKindOfClass:NSDictionary.class]
                ? [SPDFTabGroup fromDictionary:first[@"group"]].colorName : nil;
            [self setNeedsDisplay:YES];
        } else if (!payload[@"groupTabs"])
            [self updateGroupDropForPoint:point sourceIndex:[self isSameWindowTabDragFromSender:sender]
                ? _dragSessionTabIndex : -1];
    } else {
        [self clearDropIndicator];
    }
    if (operation == NSDragOperationNone && SPDFDocumentPathsFromPasteboard(sender.draggingPasteboard).count)
        operation = NSDragOperationCopy;
    return operation;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
    return [self draggingEntered:sender];
}

- (void)draggingExited:(id<NSDraggingInfo>)sender {
    (void)sender;
    [self clearDropIndicator];
}

- (void)draggingEnded:(id<NSDraggingInfo>)sender {
    (void)sender;
    [self clearDropIndicator];
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    if (![sender.draggingPasteboard availableTypeFromArray:@[SPDFTabDragPasteboardType]]) {
        [self clearDropIndicator];
        return [self.reader openFilesFromPasteboard:sender.draggingPasteboard];
    }
    NSString* json = [sender.draggingPasteboard stringForType:SPDFTabDragPasteboardType];
    NSDictionary* payload = spdf_tab_strip_json_dictionary_from_string(json);
    NSArray* groupTabs = payload[@"groupTabs"];
    if ([groupTabs isKindOfClass:NSArray.class] && groupTabs.count) {
        NSPoint point = [self convertPoint:sender.draggingLocation fromView:nil];
        if ([self isSameWindowTabDragFromSender:sender]) {
            _sameWindowTabDropHandled = YES;
            [self.groupReader moveTabGroup:_dragSessionGroup toIndex:[self groupInsertionIndexForPoint:point]];
        } else [self.groupReader insertDraggedGroup:groupTabs atIndex:[self hasTabGroups]
            ? [self groupInsertionIndexForPoint:point] : [self dropIndexForPoint:point]];
        [self clearDropIndicator];
        return YES;
    }
    SPDFDocumentTab* tab = spdf_tab_from_dictionary(payload);
    if (!tab.path.length) return NO;
    NSPoint point = [self convertPoint:sender.draggingLocation fromView:nil];
    NSInteger insertionIndex = [self dropIndexForPoint:point];
    BOOL sameWindow = [self isSameWindowTabDragFromSender:sender];
    if ([self performGroupDropWithTab:tab sourceIndex:sameWindow ? _dragSessionTabIndex : -1 atPoint:point]) {
        if (sameWindow) _sameWindowTabDropHandled = YES;
        [self clearDropIndicator];
        return YES;
    }
    [self clearDropIndicator];
    if ([self isSameWindowTabDragFromSender:sender]) {
        // Continuous same-window gesture: the tab never left this window, so
        // move the LIVE tab (no reload, no process spawn) instead of round-
        // tripping through the pasteboard copy. The insertion index was
        // computed with the dragged tab still occupying its slot; map it to
        // the post-removal index. Always report the drop handled: the flag
        // stops the session-ended callback from closing or detaching, and the
        // downstream operation for a NO here would be ambiguous.
        _sameWindowTabDropHandled = YES;
        NSInteger count = (NSInteger)self.tabs.count;
        NSInteger sourceIndex = _dragSessionTabIndex;
        if (sourceIndex < 0 || sourceIndex >= count ||
            ![(self.tabs[(NSUInteger)sourceIndex].path ?: @"") isEqualToString:tab.path]) {
            // Tabs changed under the drag (async strip refresh): relocate the
            // live tab by path so the right one moves.
            sourceIndex = -1;
            for (NSInteger i = 0; i < count; ++i) {
                if ([(self.tabs[(NSUInteger)i].path ?: @"") isEqualToString:tab.path]) {
                    sourceIndex = i;
                    break;
                }
            }
        }
        if (sourceIndex < 0) {
            // The live tab vanished mid-drag; fall back to inserting the
            // pasteboard snapshot so the drop still lands.
            tab.group = [self tabDropGroupAtPoint:point];
            if (!tab.group && [self hasTabGroups])
                insertionIndex = spdf_tab_group_prepare_gap_drop(self.tabs, tab, insertionIndex);
            [self.reader insertDraggedTab:tab atIndex:insertionIndex];
            return YES;
        }
        if ([self hasTabGroups]) {
            [self.groupReader moveTabAtIndex:sourceIndex toGroup:[self tabDropGroupAtPoint:point]
                                    atIndex:insertionIndex];
            return YES;
        }
        NSInteger targetIndex = spdf_tab_strip_same_window_move_index(insertionIndex, sourceIndex, count);
        if (targetIndex != sourceIndex) [self.reader moveTabFromIndex:sourceIndex toIndex:targetIndex];
        return YES;
    }
    tab.group = [self tabDropGroupAtPoint:point];
    if (!tab.group && [self hasTabGroups])
        insertionIndex = spdf_tab_group_prepare_gap_drop(self.tabs, tab, insertionIndex);
    [self.reader insertDraggedTab:tab atIndex:insertionIndex];
    return YES;
}

@end
