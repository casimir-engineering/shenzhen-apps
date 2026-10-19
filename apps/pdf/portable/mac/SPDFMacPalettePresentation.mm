#import "SPDFMacAIIntegration.h"
#import "SPDFMacPalettePresentation.h"
#import "SPDFMacCollectionPalette.h"
#import "SPDFMacCollectionStyle.h"
#import "SPDFMacPaletteAppearance.h"
#import "SPDFMacPaletteResults.h"
#import "SPDFMacSidebarPresentation.h"
static CGFloat Clamp(CGFloat value, CGFloat low, CGFloat high) { return MIN(MAX(value,low),high); }

@implementation ShenzhenMacDelegate (SPDFMacPalettePresentation)
- (void)showPaletteWithTitle:(NSString*)title {
    [self preparePaletteForSearch];
    if (!_palettePanel) {
        _palettePanel = [[NSPanel alloc]
            initWithContentRect:NSMakeRect(0, 0, 650, 390)
                      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskFullSizeContentView
                        backing:NSBackingStoreBuffered
                          defer:NO];
        _palettePanel.titleVisibility = NSWindowTitleHidden; _palettePanel.titlebarAppearsTransparent = YES;
        _palettePanel.floatingPanel = YES;
        _palettePanel.hidesOnDeactivate = YES;
        _palettePanel.releasedWhenClosed = NO;

        _paletteSearchField = [[SPDFPaletteSearchField alloc] init];
        ((SPDFPaletteSearchField*)_paletteSearchField).reader = self;
        _paletteSearchField.delegate = self;
        _paletteTable = [[NSTableView alloc] init];
        _paletteTable.headerView = nil;
        _paletteTable.rowHeight = 42.0;
        _paletteTable.intercellSpacing = NSMakeSize(0, 0);
        _paletteTable.backgroundColor = NSColor.clearColor;
        _paletteTable.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
        _paletteTable.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
        _paletteTable.allowsEmptySelection = NO;
        _paletteTable.dataSource = self;
        _paletteTable.delegate = self;
        _paletteTable.target = self;
        _paletteTable.action = @selector(activatePaletteSelection:);
        _paletteTable.doubleAction = @selector(activatePaletteSelection:);
        NSTableColumn* column = [[NSTableColumn alloc] initWithIdentifier:@"result"];
        column.width = 620;
        column.resizingMask = NSTableColumnAutoresizingMask;
        [_paletteTable addTableColumn:column];
        _palettePanel.contentView = SPDFPaletteContentView(_paletteSearchField,_paletteTable,self);

    }

    _palettePanel.title = title;
    _paletteSearchField.stringValue = @"";
    _paletteSearchField.placeholderString = @"Search documents, groups and commands";
    _paletteAllDocsCheckbox.hidden = YES;
    _paletteFavoritePendingDelete = nil;
    _paletteMenuCommandCandidates = [self paletteMenuCommandCandidates];
    [self refreshPaletteResults];
    [self updatePalettePanelFramePreservingTop:NO];
    [_palettePanel makeKeyAndOrderFront:nil];
    [self installPaletteEventMonitor];
    [_palettePanel makeFirstResponder:_paletteSearchField];
}

- (BOOL)isSelectablePaletteResult:(NSDictionary*)result { return spdf_palette_row_is_selectable(result); }

- (void)scrollPaletteRowToVisibleWithHeader:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)_paletteResults.count) return;
    NSInteger visibleRow = row;
    if (row > 0 && [_paletteResults[(NSUInteger)row - 1][@"kind"] isEqualToString:@"header"]) visibleRow = row - 1;
    [_paletteTable scrollRowToVisible:visibleRow];
    [_paletteTable scrollRowToVisible:row];
}

- (void)selectFirstPaletteResult {
    for (NSInteger i = 0; i < (NSInteger)_paletteResults.count; ++i) {
        if ([self isSelectablePaletteResult:_paletteResults[(NSUInteger)i]]) {
            [_paletteTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)i] byExtendingSelection:NO];
            [self scrollPaletteRowToVisibleWithHeader:i];
            return;
        }
    }
    [_paletteTable deselectAll:nil];
}

- (void)restorePaletteSelectionAfterReloadFromRow:(NSInteger)previousRow {
    NSInteger row = previousRow;
    if (row >= 0 && row < (NSInteger)_paletteResults.count &&
        [self isSelectablePaletteResult:_paletteResults[(NSUInteger)row]]) {
        [_paletteTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
        [self scrollPaletteRowToVisibleWithHeader:row];
        return;
    }
    if (_paletteTable.selectedRow >= 0 && _paletteTable.selectedRow < (NSInteger)_paletteResults.count &&
        [self isSelectablePaletteResult:_paletteResults[(NSUInteger)_paletteTable.selectedRow]]) {
        [self scrollPaletteRowToVisibleWithHeader:_paletteTable.selectedRow];
        return;
    }
    [self selectFirstPaletteResult];
}

- (CGFloat)paletteHeightForRow:(NSInteger)row {
    return row >= 0 && row < (NSInteger)_paletteResults.count ? SPDFPaletteResultHeight(_paletteResults[(NSUInteger)row]) : 30;
}

- (CGFloat)paletteRowsHeight {
    CGFloat height = 0.0;
    for (NSInteger i = 0; i < (NSInteger)_paletteResults.count; ++i) height += [self paletteHeightForRow:i];
    return height;
}

- (void)updatePalettePanelFramePreservingTop:(BOOL)preserveTop {
    if (!_palettePanel || !_window) return;
    CGFloat contentWidth = MIN(550.0,MAX(320.0,NSWidth(_window.frame)-48));
    CGFloat chromeHeight = 54.0 + 12.0 + 12.0;
    CGFloat rowsHeight = [self paletteRowsHeight];
    CGFloat tablePadding = 0.0;
    CGFloat idealContentHeight = chromeHeight + rowsHeight + tablePadding;
    CGFloat minContentHeight = chromeHeight + 42.0;
    NSScreen* screen = _window.screen ?: NSScreen.mainScreen;
    NSRect visibleFrame = screen.visibleFrame;
    CGFloat maxFrameHeight = floor(NSHeight(visibleFrame) * 0.60);
    NSRect maxContentRect = [_palettePanel contentRectForFrameRect:NSMakeRect(0, 0, contentWidth, maxFrameHeight)];
    CGFloat maxContentHeight = NSHeight(maxContentRect);
    CGFloat contentHeight = idealContentHeight;
    contentHeight = ceil(Clamp(contentHeight, minContentHeight, MAX(minContentHeight, maxContentHeight)));
    NSScrollView* scrollView = _paletteTable.enclosingScrollView;
    if (scrollView) scrollView.hasVerticalScroller = idealContentHeight > maxContentHeight + 0.5;

    NSRect frame = [_palettePanel frameRectForContentRect:NSMakeRect(0, 0, contentWidth, contentHeight)];
    NSRect windowFrame = _window.frame;
    CGFloat topY = preserveTop && _palettePanel.visible ? NSMaxY(_palettePanel.frame) : NSMaxY(windowFrame) - 88.0;
    CGFloat minY = NSMinY(visibleFrame) + 24.0;
    CGFloat maxY = NSMaxY(visibleFrame) - 24.0;
    topY = MIN(topY, maxY);
    if (topY - NSHeight(frame) < minY) topY = MIN(maxY, minY + NSHeight(frame));
    if (topY - NSHeight(frame) < minY) frame.size.height = MAX(160.0, topY - minY);
    frame.origin.x = floor(NSMidX(windowFrame) - NSWidth(frame) / 2.0);
    frame.origin.x =
        Clamp(frame.origin.x, NSMinX(visibleFrame) + 24.0, NSMaxX(visibleFrame) - NSWidth(frame) - 24.0);
    frame.origin.y = floor(topY - NSHeight(frame));
    [_palettePanel setFrame:frame display:_palettePanel.visible animate:NO];
}

- (NSView*)workspacePaletteViewForRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)_paletteResults.count) return nil;
    NSTableView* tableView = _paletteTable;
    NSDictionary* result = _paletteResults[(NSUInteger)row]; NSString* kind = result[@"kind"];
        if ([kind isEqualToString:@"favorite"]) {
            NSTableCellView* cell = [tableView makeViewWithIdentifier:@"PaletteFavoriteCell" owner:self];
            NSButton* deleteButton = nil;
            NSTextField* subtitle = nil;
            NSLayoutConstraint* deleteWidth = nil;
            if (!cell) {
                cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 620, 44)];
                cell.identifier = @"PaletteFavoriteCell";

                deleteButton = [NSButton buttonWithTitle:@""
                                                  target:self
                                                  action:@selector(paletteFavoriteDeleteClicked:)];
                deleteButton.translatesAutoresizingMaskIntoConstraints = NO;
                deleteButton.identifier = @"favoriteDelete";
                deleteButton.bezelStyle = NSBezelStyleRounded;
                deleteButton.bordered = YES;
                deleteButton.controlSize = NSControlSizeSmall;
                deleteButton.focusRingType = NSFocusRingTypeNone;
                deleteButton.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
                deleteButton.toolTip = @"Delete favorite";
                [cell addSubview:deleteButton];

                NSTextField* title = [NSTextField labelWithString:@""];
                title.translatesAutoresizingMaskIntoConstraints = NO;
                title.lineBreakMode = NSLineBreakByTruncatingMiddle;
                title.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
                cell.textField = title;
                [cell addSubview:title];

                subtitle = [NSTextField labelWithString:@""];
                subtitle.translatesAutoresizingMaskIntoConstraints = NO;
                subtitle.identifier = @"subtitle";
                subtitle.lineBreakMode = NSLineBreakByTruncatingMiddle;
                subtitle.font = [NSFont systemFontOfSize:11];
                subtitle.textColor = NSColor.secondaryLabelColor;
                [cell addSubview:subtitle];

                deleteWidth = [deleteButton.widthAnchor constraintEqualToConstant:28];
                deleteWidth.identifier = @"favoriteDeleteWidth";
                [NSLayoutConstraint activateConstraints:@[
                    [deleteButton.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:8],
                    [deleteButton.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
                    [deleteButton.heightAnchor constraintEqualToConstant:26], deleteWidth,
                    [title.leadingAnchor constraintEqualToAnchor:deleteButton.trailingAnchor constant:8],
                    [title.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-10],
                    [title.topAnchor constraintEqualToAnchor:cell.topAnchor constant:6],
                    [subtitle.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
                    [subtitle.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
                    [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:2]
                ]];
            }

            for (NSView* subview in cell.subviews) {
                if ([subview.identifier isEqualToString:@"favoriteDelete"]) deleteButton = (NSButton*)subview;
                if ([subview.identifier isEqualToString:@"subtitle"]) subtitle = (NSTextField*)subview;
            }
            for (NSLayoutConstraint* constraint in deleteButton.constraints) {
                if ([constraint.identifier isEqualToString:@"favoriteDeleteWidth"]) deleteWidth = constraint;
            }

            BOOL armed = _paletteFavoritePendingDelete == result[@"favorite"];
            deleteWidth.constant = armed ? 116.0 : 28.0;
            NSString* deleteTitle = armed ? @"Confirm Delete" : @"\u00D7";
            NSDictionary* attributes = @{
                NSForegroundColorAttributeName : armed ? NSColor.systemRedColor : NSColor.secondaryLabelColor,
                NSFontAttributeName : [NSFont systemFontOfSize:armed ? 11.0 : 17.0
                                                        weight:armed ? NSFontWeightSemibold : NSFontWeightRegular]
            };
            deleteButton.attributedTitle = [[NSAttributedString alloc] initWithString:deleteTitle
                                                                           attributes:attributes];
            deleteButton.bordered = YES;
            deleteButton.bezelStyle = NSBezelStyleRounded;
            deleteButton.toolTip = armed ? @"Click again to delete this favorite" : @"Delete favorite";

            cell.textField.stringValue = result[@"title"] ?: @"";
            cell.textField.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
            cell.textField.textColor = NSColor.labelColor;
            subtitle.stringValue = result[@"subtitle"] ?: @"";
            subtitle.textColor = NSColor.secondaryLabelColor;
            return cell;
        }

    return SPDFPaletteResultView(result);
}
- (NSTableRowView*)tableView:(NSTableView*)tableView rowViewForRow:(NSInteger)row {
    (void)row;
    if (tableView == _paletteTable) return SPDFPaletteRowView();
    return tableView == _sidebarTable ? SPDFSidebarRowView() : nil;
}
@end
