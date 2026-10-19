#import "SPDFMacPaletteActivation.h"
#import "SPDFMacAIIntegration.h"
#import "SPDFMacCollectionPalette.h"
#import "SPDFMacCollectionPaletteModel.h"
#import "SPDFMacDocumentOpening.h"
#import "SPDFMacPalettePresentation.h"
#import "SPDFMacPaletteResults.h"
#import <objc/runtime.h>

@interface ShenzhenMacDelegate (SPDFMacPaletteActivationHost)
- (NSInteger)indexOfTabForPath:(NSString*)path;
- (void)favoriteCurrentPage:(id)sender;
- (void)favoriteCurrentDocument:(id)sender;
- (void)startFindForCurrentQuery;
- (void)savePersistentState;
@end

static const void* kPaletteHighlightMoved = &kPaletteHighlightMoved;

enum : unsigned short {
    kPaletteKeyReturn = 36, kPaletteKeyEnter = 76, kPaletteKeyEscape = 53, kPaletteKeyDown = 125, kPaletteKeyUp = 126,
    kPaletteKeyHome = 115, kPaletteKeyEnd = 119, kPaletteKeyPageUp = 116, kPaletteKeyPageDown = 121,
};

@implementation ShenzhenMacDelegate (SPDFMacPaletteActivation)

- (BOOL)paletteHandleKeyEvent:(NSEvent*)event {
    // Pinyin and other input methods use Return, Escape and the arrows to pick
    // and commit what is being composed; those keys belong to them meanwhile.
    id editor = _paletteSearchField.currentEditor;
    if ([editor conformsToProtocol:@protocol(NSTextInputClient)] && [editor hasMarkedText]) return NO;
    BOOL command = (event.modifierFlags & NSEventModifierFlagCommand) != 0;
    switch (event.keyCode) {
        case kPaletteKeyEscape: [self closePalette:nil]; return YES;
        case kPaletteKeyDown: [self paletteMoveSelection:1]; return YES;
        case kPaletteKeyUp: [self paletteMoveSelection:-1]; return YES;
        case kPaletteKeyHome: [self paletteSelectBoundary:NO]; return YES;
        case kPaletteKeyEnd: [self paletteSelectBoundary:YES]; return YES;
        case kPaletteKeyPageUp:
        case kPaletteKeyPageDown: [self paletteMovePage:event.keyCode == kPaletteKeyPageDown ? 1 : -1]; return YES;
        case kPaletteKeyReturn:
        case kPaletteKeyEnter:
            if (command) [self paletteStartChat];
            else [self activatePaletteSelection:nil];
            return YES;
        default: return NO;
    }
}

- (BOOL)paletteHighlightMovedByPerson { return [objc_getAssociatedObject(self, kPaletteHighlightMoved) boolValue]; }

- (void)paletteForgetHighlightMove {
    objc_setAssociatedObject(self, kPaletteHighlightMoved, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)paletteNoteClickAt:(NSPoint)locationInWindow {
    // A press on a row highlights it; later results must not take it away before the click lands.
    NSInteger row = [_paletteTable rowAtPoint:[_paletteTable convertPoint:locationInWindow fromView:nil]];
    BOOL onRow = row >= 0 && row < (NSInteger)_paletteResults.count;
    if (onRow && spdf_palette_row_is_selectable(_paletteResults[(NSUInteger)row]))
        objc_setAssociatedObject(self, kPaletteHighlightMoved, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)paletteNoteMouseDown:(NSEvent*)event {
    // Only a left click chooses a row; a right or other button press leaves the highlight alone.
    if (event.type == NSEventTypeLeftMouseDown) [self paletteNoteClickAt:event.locationInWindow];
}

- (void)applyPaletteRows:(NSArray<NSDictionary*>*)rows {
    NSInteger selected = _paletteTable.selectedRow;
    NSDictionary* highlighted = selected >= 0 && selected < (NSInteger)_paletteResults.count
        ? _paletteResults[(NSUInteger)selected] : nil;
    [_paletteResults setArray:rows.count ? rows : @[@{@"kind":@"status", @"title":@"No matches",
        @"subtitle":@"Try a document name, group, or col: followed by text."}]];
    [_paletteTable reloadData]; [self updatePalettePanelFramePreservingTop:YES];
    NSInteger row = spdf_palette_row_to_highlight(_paletteResults, highlighted, [self paletteHighlightMovedByPerson]);
    if (row < 0) { [_paletteTable deselectAll:nil]; return; }
    [_paletteTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
    [self scrollPaletteRowToVisibleWithHeader:row];
}

- (void)paletteHighlightRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)_paletteResults.count) return;
    objc_setAssociatedObject(self, kPaletteHighlightMoved, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [_paletteTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
    [self scrollPaletteRowToVisibleWithHeader:row];
}

- (void)paletteMoveSelection:(NSInteger)delta {
    [self paletteHighlightRow:spdf_palette_row_after_move(_paletteResults, _paletteTable.selectedRow, delta, YES)];
}

- (void)paletteSelectBoundary:(BOOL)last {
    [self paletteHighlightRow:spdf_palette_boundary_row(_paletteResults, last)];
}

- (void)paletteMovePage:(NSInteger)direction {
    // A page is as many rows as fit in view beside the highlighted one, by their own heights.
    CGFloat visible = NSHeight(_paletteTable.enclosingScrollView.contentView.bounds);
    NSInteger count = (NSInteger)_paletteResults.count, current = _paletteTable.selectedRow, fitting = 0;
    BOOL highlighted = current >= 0 && current < count;
    NSInteger row = highlighted ? current : (direction > 0 ? -1 : count);
    CGFloat used = highlighted ? [self paletteHeightForRow:current] : 0;
    for (NSInteger next = row + direction; next >= 0 && next < count; next += direction) {
        used += [self paletteHeightForRow:next];
        if (used > visible) break;
        ++fitting;
    }
    NSInteger page = MAX((NSInteger)1, fitting);
    [self paletteHighlightRow:spdf_palette_row_after_move(_paletteResults, current, direction * page, NO)];
}

- (void)activatePaletteSelection:(id)sender {
    // A click chooses the row under the pointer; Return the highlighted row.
    BOOL clicked = sender != nil && sender == _paletteTable;
    NSInteger row = clicked ? _paletteTable.clickedRow : _paletteTable.selectedRow;
    NSDictionary* result = row >= 0 && row < (NSInteger)_paletteResults.count ? _paletteResults[(NSUInteger)row] : nil;
    // A click on a heading or below the rows, or Return while the list only
    // says "Searching…" or "No matches", chooses nothing. Cmd+Return still
    // opens the chat.
    if (!spdf_palette_row_is_selectable(result)) return;
    if ([result[@"kind"] isEqual:@"askAI"]) {
        [self paletteStartChat];
        return;
    }
    [self closePalette:nil];
    [self openPaletteResult:result];
}

- (void)paletteStartChat {
    // The chat starts from the typed words alone, never from the rows under them.
    [self showAIChatForQuery:_paletteSearchField.stringValue];
}

- (void)focusOpenDocumentTabForPath:(NSString*)path {
    if (!path.length) return;
    ShenzhenMacDelegate* owner = [self indexOfTabForPath:path] >= 0 ? self : nil;
    for (ShenzhenMacDelegate* controller in SPDFMacAllWindowControllers()) {
        if (owner) break;
        if ([controller indexOfTabForPath:path] >= 0) owner = controller;
    }
    // A window of another process that shows it is found by the shared path too.
    [owner ?: self showDocumentsAtPaths:@[ path ]];
}

- (void)openPaletteResult:(NSDictionary*)result {
    NSString* kind = result[@"kind"];
    if (!spdf_palette_row_is_selectable(result)) return;
    if ([self openCollectionPaletteResult:result]) return;
    if ([kind isEqualToString:@"addPage"]) {
        [self favoriteCurrentPage:nil];
        return;
    }
    if ([kind isEqualToString:@"addDoc"]) {
        [self favoriteCurrentDocument:nil];
        return;
    }
    if ([kind isEqualToString:@"menuCommand"]) {
        NSMenuItem* item = [result[@"menuItem"] isKindOfClass:NSMenuItem.class] ? result[@"menuItem"] : nil;
        if (!item || !item.action) return;
        // Defer one runloop turn so key-window restoration after the panel
        // closes has settled, then dispatch exactly as the menu would:
        // through the responder chain with the menu item as sender (handlers
        // like openRecentDocument: read the sender's representedObject).
        dispatch_async(dispatch_get_main_queue(), ^{
          if (item.action) [NSApp sendAction:item.action to:item.target from:item];
        });
        return;
    }
    NSString* path = result[@"path"];
    if ([kind isEqualToString:@"openDoc"]) {
        [self focusOpenDocumentTabForPath:path];
        return;
    }
    NSInteger page = [result[@"page"] integerValue];
    if (!path.length) return;
    [self openPath:path];
    if (!_doc || ![_path.stringByStandardizingPath isEqualToString:path.stringByStandardizingPath]) return;
    _pageIndex = MAX(0, MIN(page, spdf_page_count(_doc) - 1));
    _pageView.currentPageIndex = _pageIndex;
    if ([kind isEqualToString:@"find"]) {
        NSString* query = result[@"query"] ?: _paletteSearchField.stringValue;
        _searchField.stringValue = query ?: @"";
        _findRegexCheckbox.state = NSControlStateValueOff;
        _findRegexMultiline = YES;
        _pendingFindPreferredPage = _pageIndex;
        [self startFindForCurrentQuery];
    } else {
        [self renderDocumentAndScrollToPage:_pageIndex alignTop:YES];
    }
}

- (void)installPaletteEventMonitor {
    if (_paletteEventMonitor) return;
    __weak ShenzhenMacDelegate* weakSelf = self;
    NSEventMask mask = NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown | NSEventMaskOtherMouseDown |
                       NSEventMaskKeyDown;
    _paletteEventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:mask handler:^NSEvent*(NSEvent* event) {
      ShenzhenMacDelegate* strongSelf = weakSelf;
      if (!strongSelf || !strongSelf->_palettePanel.visible) return event;
      BOOL key = event.type == NSEventTypeKeyDown;
      if (key && event.window == strongSelf->_palettePanel && [strongSelf paletteHandleKeyEvent:event]) return nil;
      if (!key && event.window != strongSelf->_palettePanel) [strongSelf closePalette:nil];
      else if (!key) [strongSelf paletteNoteMouseDown:event];
      return event;
    }];
}

- (void)closePalette:(id)sender {
    [self cancelCollectionPaletteSearch];
    (void)sender;
    if (_paletteEventMonitor) {
        [NSEvent removeMonitor:_paletteEventMonitor];
        _paletteEventMonitor = nil;
    }
    _paletteFavoritePendingDelete = nil;
    [_palettePanel orderOut:nil];
    // Drop the menu-command snapshot and its rows: captured NSMenuItems
    // retain their targets, so keeping them past close would pin window
    // controllers. Reopening rebuilds both from the live menu tree anyway.
    _paletteMenuCommandCandidates = nil;
    [_paletteResults removeAllObjects];
    [_paletteTable reloadData];
}

- (void)paletteFavoriteDeleteClicked:(id)sender {
    NSInteger row = [_paletteTable rowForView:(NSView*)sender];
    if (row < 0 || row >= (NSInteger)_paletteResults.count) return;

    NSDictionary* result = _paletteResults[(NSUInteger)row];
    if (![result[@"kind"] isEqualToString:@"favorite"]) return;
    NSDictionary* favorite = result[@"favorite"];
    if (!favorite) return;

    if (_paletteFavoritePendingDelete != favorite) {
        _paletteFavoritePendingDelete = favorite;
        [_paletteTable reloadData];
        [_paletteTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
        return;
    }

    NSUInteger index = [_favorites indexOfObjectIdenticalTo:favorite];
    if (index == NSNotFound) {
        _paletteFavoritePendingDelete = nil;
        [self refreshPaletteResults];
        return;
    }

    [_favorites removeObjectAtIndex:index];
    _paletteFavoritePendingDelete = nil;
    [self savePersistentState];
    [self refreshPaletteResults];
    _statusLabel.stringValue = @"Favorite deleted.";
}

@end
