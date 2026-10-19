#import "SPDFMacTabGroupNamePrompt.h"
#import "SPDFMacGroupManagement.h"
#import "SPDFMacTabGroups.h"

#import "SPDFMacGroupManagementTable.h"
#import "SPDFMacGroupSearchControls.h"
@interface SPDFGroupSearchField : NSSearchField
@end
@implementation SPDFGroupSearchField
+ (Class)cellClass { return SPDFPanelSearchCell.class; }
- (void)setFrameSize:(NSSize)size { [super setFrameSize:size]; SPDFUpdateGroupSearchPlaceholder(self); }
- (NSRect)focusRingMaskBounds { return NSInsetRect(self.bounds,.5,.5); }
- (void)drawFocusRingMask {
    [[NSBezierPath bezierPathWithRoundedRect:self.focusRingMaskBounds xRadius:MIN(14,NSHeight(self.bounds)/2)
        yRadius:MIN(14,NSHeight(self.bounds)/2)] fill];
}
@end
@interface SPDFGroupManagementRow : NSTableRowView
@property(nonatomic, weak) NSTableView* ownerTable;
@property(nonatomic) NSInteger nextSectionRow;
@property(nonatomic, strong) NSColor* groupAccent;
@end
@implementation SPDFGroupManagementRow
- (NSRect)sectionConstrainedFrame:(NSRect)frame {
    // Native floating rows otherwise overlap the next heading. Clamp each
    // placement at its section boundary, including AppKit's scroll updates.
    if (!self.groupRowStyle || !self.superview || !self.ownerTable || self.nextSectionRow < 0) return frame;
    NSRect inTable = [self.superview convertRect:frame toView:self.ownerTable];
    CGFloat limit = NSMinY([self.ownerTable rectOfRow:self.nextSectionRow])-NSHeight(inTable);
    if (NSMinY(inTable) > limit) {
        inTable.origin.y = limit;
        frame = [self.superview convertRect:inTable fromView:self.ownerTable];
    }
    return frame;
}
- (void)setFrame:(NSRect)frame { [super setFrame:[self sectionConstrainedFrame:frame]]; }
- (void)setFrameOrigin:(NSPoint)origin {
    NSRect frame = self.frame; frame.origin = origin;
    [super setFrameOrigin:[self sectionConstrainedFrame:frame].origin];
}
- (void)drawBackgroundInRect:(NSRect)dirtyRect {
    // A floating section must cover documents scrolling beneath its controls.
    if (self.groupRowStyle) {
        [NSColor.windowBackgroundColor setFill]; NSRectFill(dirtyRect);
        [[self.groupAccent colorWithAlphaComponent:.16] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,3,1) xRadius:4 yRadius:4] fill];
    }
    else [super drawBackgroundInRect:dirtyRect];
}
- (void)drawSelectionInRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSRect rect = NSInsetRect(self.bounds,3,1);
    NSClipView* clip = self.enclosingScrollView.contentView;
    if (clip) {
        NSRect viewport = [self convertRect:clip.bounds fromView:clip];
        CGFloat right = MIN(NSMaxX(rect),NSMaxX(viewport)-3);
        rect.origin.x = MAX(rect.origin.x,NSMinX(viewport)+3); rect.size.width = MAX(0,right-NSMinX(rect));
    }
    [[NSColor.controlAccentColor colorWithAlphaComponent:.14] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:7 yRadius:7] fill];
}
@end
#import "SPDFMacGroupActionButton.h"

static NSTextField* Label(NSString* text, CGFloat size, BOOL secondary) {
    NSTextField* label = [NSTextField labelWithString:text ?: @""];
    label.font = [NSFont systemFontOfSize:size];
    label.textColor = secondary ? NSColor.secondaryLabelColor : NSColor.labelColor;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}
static SPDFGroupActionButton* Icon(NSString* symbol, NSString* help, id target, SEL action) {
    SPDFGroupActionButton* button = [SPDFGroupActionButton new];
    button.ignoresMultiClick = NO; button.bordered = NO; button.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:help];
    button.target = target; button.action = action; button.toolTip = help;
    [button setAccessibilityLabel:help];
    [button.widthAnchor constraintEqualToConstant:26].active = YES;
    [button.heightAnchor constraintEqualToConstant:26].active = YES;
    return button;
}
@implementation SPDFGroupManagementController {
    NSSearchField* _search;
    NSButton* _expandAll;
    NSButton* _jumpCurrent;
    BOOL _searchCollapsed;
    NSTextField* _summary;
    NSTextField* _empty;
    NSTableView* _table;
    NSScrollView* _scroll;
    NSArray<NSDictionary*>* _groups;
    NSArray<NSDictionary*>* _rows;
    NSMutableSet<NSString*>* _expanded;
    BOOL _restoring;
    CGFloat _savedScroll;
    BOOL _pendingScrollRestore;
    BOOL _hasSnapshot;
    BOOL _pendingSelectedReveal;
    NSString* _activatingPath;
    NSString* _activatingGroup;
    NSDictionary* _draggedDocument;
    NSString* _dragToken;
    NSString* _dropGroup;
    BOOL _draggingDocuments;
    CGFloat _dragScroll;

}
- (void)loadView {
    self.view = [NSView new];
    _summary = Label(@"",11,YES);
    _search = [SPDFGroupSearchField new]; _search.placeholderString = @"Search groups and documents"; _search.toolTip = @"Search group names and document names.";
    NSSearchFieldCell* searchCell=(id)_search.cell;
    searchCell.usesSingleLineMode=YES; searchCell.scrollable=YES;
    searchCell.wraps=NO; searchCell.lineBreakMode=NSLineBreakByClipping;
    SPDFConfigurePanelSearchField(_search); _search.delegate = self; _search.sendsSearchStringImmediately = YES;
    [_search setAccessibilityLabel:@"Search group and document names"];
    _search.focusRingType = NSFocusRingTypeExterior;
    _expandAll = Icon(@"rectangle.expand.vertical",@"Expand all groups",self,@selector(toggleAllGroups:));
    _jumpCurrent = Icon(@"scope",@"Jump to current document",self,@selector(jumpToCurrentDocument:));
    _table = [SPDFGroupManagementTable new]; _table.headerView = nil; _table.dataSource = self; _table.delegate = self;
    _table.backgroundColor = NSColor.clearColor; _table.style = NSTableViewStylePlain; _table.intercellSpacing = NSMakeSize(0,2);
    _table.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
    _table.floatsGroupRows = YES;
    [_table registerForDraggedTypes:@[@"com.shenzhenpdf.group-document"]];
    [_table setDraggingSourceOperationMask:NSDragOperationMove forLocal:YES];
    [_table setDraggingSourceOperationMask:NSDragOperationNone forLocal:NO];
    _table.target = self; _table.action = @selector(activateRow:);
    NSTableColumn* column = [[NSTableColumn alloc] initWithIdentifier:@"group"];
    [_table addTableColumn:column]; _table.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    [_table setAccessibilityLabel:@"Groups and documents"];
    [_table setAccessibilityHelp:@"Select with the arrow keys, then press Return to open a group or document."];
    NSMenu* menu = [NSMenu new]; menu.delegate = self; _table.menu = menu;
    _scroll = [NSScrollView new]; _scroll.documentView = _table; _scroll.hasVerticalScroller = YES;
    // Floating headers live outside the clip view; section push-off must still
    // clip at the list edge instead of painting across its search field.
    _scroll.wantsLayer = YES; _scroll.layer.masksToBounds = YES;
    _scroll.drawsBackground = NO; _scroll.automaticallyAdjustsContentInsets = NO; _scroll.contentInsets = NSEdgeInsetsZero; _scroll.contentView.postsBoundsChangedNotifications = YES;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(scrolled:)
        name:NSViewBoundsDidChangeNotification object:_scroll.contentView];
    _empty = [NSTextField wrappingLabelWithString:@""]; _empty.textColor = NSColor.secondaryLabelColor;
    _empty.alignment = NSTextAlignmentCenter; _empty.hidden = YES;
    NSString* help = @"Hidden groups stay open. Hiding removes their tabs from the tab bar without closing documents.";
    _summary.toolTip = help; [_summary setAccessibilityHelp:help];
    NSImageView* info = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"info.circle" accessibilityDescription:help]];
    info.contentTintColor = NSColor.secondaryLabelColor; info.toolTip = help;
    [info.widthAnchor constraintEqualToConstant:12].active = YES;
    [_summary setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView* footer = [NSStackView stackViewWithViews:@[_summary,info]]; footer.spacing = 6;
    for (NSView* child in @[_search,_expandAll,_jumpCurrent,_scroll,_empty,footer]) { child.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:child]; }
    [NSLayoutConstraint activateConstraints:@[
        [_search.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:4],
        [_search.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [_search.trailingAnchor constraintEqualToAnchor:_expandAll.leadingAnchor constant:-4],
        [_expandAll.trailingAnchor constraintEqualToAnchor:_jumpCurrent.leadingAnchor constant:-2],
        [_jumpCurrent.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],
        [_jumpCurrent.centerYAnchor constraintEqualToAnchor:_search.centerYAnchor],
        [_expandAll.centerYAnchor constraintEqualToAnchor:_search.centerYAnchor],
        [_search.heightAnchor constraintEqualToConstant:30],
        [_scroll.topAnchor constraintEqualToAnchor:_search.bottomAnchor constant:8],
        [_scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:4],
        [_scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-4],
        [_scroll.bottomAnchor constraintEqualToAnchor:footer.topAnchor],
        [footer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [footer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],
        [footer.heightAnchor constraintEqualToConstant:22],
        [footer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_empty.topAnchor constraintEqualToAnchor:_scroll.topAnchor constant:20],
        [_empty.leadingAnchor constraintEqualToAnchor:_search.leadingAnchor],
        [_empty.trailingAnchor constraintEqualToAnchor:_search.trailingAnchor]]];
    _expanded = [NSMutableSet set]; _groups = @[]; _rows = @[];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (NSDictionary*)viewState {
    return @{@"groupQuery":_search.stringValue ?: @"",@"expandedGroups":[_expanded.allObjects sortedArrayUsingSelector:@selector(compare:)],
             @"groupSearchCollapsed":@(_searchCollapsed),@"groupScroll":@(MAX(0,_savedScroll))};
}
- (void)publishState { if (!_restoring && self.stateHandler) self.stateHandler(self.viewState); }
- (void)updateGroups:(NSArray<NSDictionary*>*)groups state:(NSDictionary*)state {
    (void)self.view;
    NSString* query = [state[@"groupQuery"] isKindOfClass:NSString.class] ? state[@"groupQuery"] : @"";
    NSMutableSet* expanded = [NSMutableSet set];
    for (id identifier in [state[@"expandedGroups"] isKindOfClass:NSArray.class] ? state[@"expandedGroups"] : @[])
        if ([identifier isKindOfClass:NSString.class]) [expanded addObject:identifier];
    CGFloat scroll = [state[@"groupScroll"] respondsToSelector:@selector(doubleValue)] ? MAX(0,[state[@"groupScroll"] doubleValue]) : 0;
    if (!isfinite(scroll)) scroll = 0;
    if (_hasSnapshot && [_groups isEqualToArray:groups ?: @[]] && [_search.stringValue isEqual:query] &&
        [_expanded isEqualToSet:expanded] && _searchCollapsed==[state[@"groupSearchCollapsed"] boolValue] && fabs(_savedScroll-scroll)<.5) return;
    _restoring = YES; _hasSnapshot = YES; _groups = groups.copy ?: @[];
    if (![_search.stringValue isEqual:query]) _search.stringValue = query;
    _searchCollapsed = [state[@"groupSearchCollapsed"] boolValue];
    _expanded = expanded; _savedScroll = scroll; _pendingScrollRestore = YES;
    [self rebuildRows]; [self.view layoutSubtreeIfNeeded];
    [self restoreScrollIfReady];
    _restoring = NO;
}
- (void)rebuildRows {
    NSMutableArray* rows = [NSMutableArray array]; NSUInteger hidden = 0, matched = 0;
    NSString* query = [_search.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    for (NSDictionary* group in _groups) {
        hidden += [group[@"hidden"] boolValue];
        BOOL nameMatches = !query.length || [group[@"name"] rangeOfString:query
            options:NSCaseInsensitiveSearch|NSDiacriticInsensitiveSearch].location != NSNotFound;
        NSArray* documents = group[@"documents"] ?: @[];
        if (query.length && !nameMatches) {
            NSMutableArray* matches = [NSMutableArray array];
            for (NSDictionary* document in documents) {
                NSString* filename = [document[@"path"] lastPathComponent] ?: @"";
                if ([(document[@"title"] ?: @"") rangeOfString:query options:NSCaseInsensitiveSearch|NSDiacriticInsensitiveSearch].location != NSNotFound ||
                    [filename rangeOfString:query options:NSCaseInsensitiveSearch|NSDiacriticInsensitiveSearch].location != NSNotFound)
                    [matches addObject:document];
            }
            documents = matches;
        }
        if (!nameMatches && !documents.count) continue;
        ++matched; [rows addObject:@{@"group":group}];
        // Search reveals matching documents without changing saved expansion.
        if ((query.length && !_searchCollapsed) || [_expanded containsObject:group[@"id"]])
            for (NSDictionary* document in documents) [rows addObject:@{@"group":group,@"document":document}];
    }
    _rows = rows;
    BOOL anyExpanded = NO;
    for (NSDictionary* row in rows) if (row[@"document"]) { anyExpanded = YES; break; }
    NSString* help = anyExpanded ? @"Collapse all groups" : @"Expand all groups";
    _expandAll.image = SPDFGroupExpansionImage(anyExpanded);
    _expandAll.toolTip = help; _expandAll.accessibilityLabel = help; _expandAll.enabled = rows.count > 0;
    _summary.stringValue = _search.stringValue.length ? [NSString stringWithFormat:@"%lu of %lu groups",matched,_groups.count] :
        [NSString stringWithFormat:@"%lu %@ · %lu hidden",_groups.count,_groups.count==1 ? @"group" : @"groups",hidden];
    _empty.stringValue = _groups.count ? @"No matching groups or documents.\nTry another name." : @"Open a document to start organizing your groups.";
    _empty.hidden = rows.count > 0;
    _jumpCurrent.enabled = NO;
    for (NSDictionary* group in _groups) for (NSDictionary* document in group[@"documents"])
        if ([document[@"selected"] boolValue]) _jumpCurrent.enabled = YES;
    [_table reloadData];
    NSInteger selected = -1;
    for (NSUInteger index=0;index<rows.count;index++) {
        NSDictionary* row = rows[index];
        if (_activatingPath ? ([row[@"document"][@"path"] isEqual:_activatingPath] && [row[@"group"][@"id"] isEqual:_activatingGroup]) : [row[@"document"][@"selected"] boolValue]) { selected = index; break; }
        if (!row[@"document"] && [row[@"group"][@"selected"] boolValue]) selected = index;
    }
    [_table selectRowIndexes:selected >= 0 ? [NSIndexSet indexSetWithIndex:selected] : [NSIndexSet indexSet] byExtendingSelection:NO];
}
- (void)jumpToCurrentDocument:(id)sender {
    (void)sender;
    _search.stringValue = @""; _searchCollapsed = NO;
    [self rebuildRows]; [self revealSelectedDocument]; [self publishState];
}
- (void)revealSelectedDocument {
    (void)self.view;
    for (NSDictionary* group in _groups) {
        if (![group[@"selected"] boolValue]) continue;
        if (![_expanded containsObject:group[@"id"]]) {
            [_expanded addObject:group[@"id"]]; [self rebuildRows];
            [self publishState]; // Persist before a layout-triggered snapshot can restore stale collapse state.
        }
        break;
    }
    _pendingSelectedReveal = YES;
    [self.view layoutSubtreeIfNeeded]; [self restoreScrollIfReady];
}
- (void)viewDidLayout {
    [super viewDidLayout];
    SPDFUpdateGroupSearchPlaceholder(_search);
    CGFloat width = NSWidth(_scroll.contentView.bounds);
    if (width > 0) {
        _table.tableColumns.firstObject.width = width;
        [_table setFrameSize:NSMakeSize(width,NSHeight(_table.frame))];
    }
    [self restoreScrollIfReady];
}
- (void)restoreScrollIfReady {
    if ((!_pendingScrollRestore && !_pendingSelectedReveal) || !self.view.window || NSHeight(_scroll.contentView.bounds) <= 1 || NSWidth(_scroll.contentView.bounds) <= 1) return;
    BOOL wasRestoring = _restoring; _restoring = YES;
    NSRect bounds = _scroll.contentView.bounds; bounds.origin = NSMakePoint(0,_savedScroll);
    if (_pendingSelectedReveal && _table.selectedRow >= 0) {
        // Center the active document below its floating header. Do not re-center
        // during ordinary model refreshes, which would fight manual scrolling.
        NSRect row = [_table rectOfRow:_table.selectedRow];
        bounds.origin.y = MAX(0,NSMidY(row)-(NSHeight(bounds)+38)/2);
    }
    bounds = [_scroll.contentView constrainBoundsRect:bounds];
    [_scroll.contentView scrollToPoint:bounds.origin]; [_scroll reflectScrolledClipView:_scroll.contentView];
    _savedScroll = MAX(0,bounds.origin.y); _pendingScrollRestore = NO;
    BOOL revealed = _pendingSelectedReveal; _pendingSelectedReveal = NO; _restoring = wasRestoring;
    if (revealed) [self publishState];
}
- (BOOL)tableView:(NSTableView*)table isGroupRow:(NSInteger)row {
    (void)table; return !_rows[row][@"document"];
}
- (BOOL)tableView:(NSTableView*)table shouldSelectRow:(NSInteger)row {
    (void)table; (void)row; return YES;
}
- (NSTableRowView*)tableView:(NSTableView*)table rowViewForRow:(NSInteger)row {
    SPDFGroupManagementRow* view = [SPDFGroupManagementRow new];
    view.ownerTable = table; view.nextSectionRow = -1;
    view.groupAccent = spdf_tab_group_accent(_rows[row][@"group"][@"color"]);
    if (!_rows[row][@"document"]) for (NSUInteger index=row+1;index<_rows.count;index++) {
        if (!_rows[index][@"document"]) { view.nextSectionRow = index; break; }
    }
    return view;
}
// A private, per-drag token keeps this operation local to its source workspace.
- (id<NSPasteboardWriting>)tableView:(NSTableView*)table pasteboardWriterForRow:(NSInteger)row {
    (void)table;
    if (row < 0 || row >= (NSInteger)_rows.count || !_rows[row][@"document"]) return nil;
    _draggedDocument = _rows[row]; _dragToken = NSUUID.UUID.UUIDString;
    NSPasteboardItem* item = [NSPasteboardItem new];
    [item setString:_dragToken forType:@"com.shenzhenpdf.group-document"]; return item;
}
- (void)tableView:(NSTableView*)table draggingSession:(NSDraggingSession*)session
    willBeginAtPoint:(NSPoint)point forRowIndexes:(NSIndexSet*)indexes {
    (void)table; (void)session; (void)point; (void)indexes;
    if (!_draggedDocument) return;
    _dragScroll = _savedScroll; _draggingDocuments = YES; _dropGroup = nil;
    ((SPDFGroupManagementTable*)_table).draggedDuringPress=YES;
    [(SPDFGroupManagementTable*)_table beginDocumentDragScrolling];
}
- (BOOL)acceptsGroupDrag:(id<NSDraggingInfo>)info row:(NSInteger)row {
    return _draggingDocuments && info.draggingSource == _table && row >= 0 && row <= (NSInteger)_rows.count &&
        [[info.draggingPasteboard stringForType:@"com.shenzhenpdf.group-document"] isEqual:_dragToken];
}
- (NSDragOperation)tableView:(NSTableView*)table validateDrop:(id<NSDraggingInfo>)info
    proposedRow:(NSInteger)row proposedDropOperation:(NSTableViewDropOperation)operation {
    (void)operation;
    if (![self acceptsGroupDrag:info row:row]) return NSDragOperationNone;
    [table setDropRow:row dropOperation:(row==(NSInteger)_rows.count || _rows[row][@"document"]) ? NSTableViewDropAbove : NSTableViewDropOn];
    return NSDragOperationMove;
}
- (BOOL)tableView:(NSTableView*)table acceptDrop:(id<NSDraggingInfo>)info
    row:(NSInteger)row dropOperation:(NSTableViewDropOperation)operation {
    (void)table; (void)operation;
    if (![self acceptsGroupDrag:info row:row] || !self.actionHandler) return NO;
    NSDictionary* destination=row<(NSInteger)_rows.count ? _rows[row] : _rows.lastObject;
    _dropGroup = destination[@"group"][@"id"];
    // Include source identity so duplicate paths cannot move the wrong group's tab.
    NSData* data = [NSJSONSerialization dataWithJSONObject:@{
        @"source":_draggedDocument[@"group"][@"id"], @"path":_draggedDocument[@"document"][@"path"],
        @"before":row<(NSInteger)_rows.count ? (destination[@"document"][@"path"] ?: @"") : @""}
        options:0 error:nil];
    self.actionHandler(@"move-document",_dropGroup,[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
    return YES;
}
- (void)tableView:(NSTableView*)table draggingSession:(NSDraggingSession*)session
    endedAtPoint:(NSPoint)point operation:(NSDragOperation)operation {
    (void)table; (void)session; (void)point;
    [(SPDFGroupManagementTable*)_table endDocumentDragScrolling];
    _draggingDocuments = NO; _draggedDocument = nil; _dragToken = nil;
    if (operation == NSDragOperationMove && _dropGroup) [_expanded addObject:_dropGroup];
    _pendingScrollRestore = NO;
    [self rebuildRows]; [self restoreScrollIfReady]; [self publishState]; _dropGroup = nil;
}
- (NSInteger)numberOfRowsInTableView:(NSTableView*)table { (void)table; return _rows.count; }
- (CGFloat)tableView:(NSTableView*)table heightOfRow:(NSInteger)row { (void)table; return _rows[row][@"document"] ? 26 : 36; }
- (NSView*)tableView:(NSTableView*)table viewForTableColumn:(NSTableColumn*)column row:(NSInteger)row {
    (void)table; (void)column; NSDictionary* item = _rows[row], *group = item[@"group"], *document = item[@"document"];
    NSView* container = [NSView new];
    NSStackView* contents;
    if (document) {
        NSView* badge=SPDFGroupDocumentBadge(document[@"path"]);
        NSString* title=document[@"title"] ?: [document[@"path"] lastPathComponent];
        if(title.pathExtension.length && [title.pathExtension.lowercaseString isEqual:[document[@"path"] pathExtension].lowercaseString])
            title=title.stringByDeletingPathExtension;
        NSTextField* label=Label(title,12,NO); label.toolTip=document[@"path"];
        [label setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
        contents=[NSStackView stackViewWithViews:@[badge,label]]; contents.spacing=7;
    } else {
        BOOL searching = [_search.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length > 0;
        BOOL expanded = (searching && !_searchCollapsed) || [_expanded containsObject:group[@"id"]];
        SPDFGroupActionButton* disclosure = Icon(expanded ? @"chevron.down" : @"chevron.right",
            [NSString stringWithFormat:@"%@ %@ documents",expanded ? @"Collapse" : @"Expand",group[@"name"]],self,@selector(disclose:)); disclosure.groupID = group[@"id"];
        disclosure.enabled = !searching;
        if (searching) disclosure.toolTip = @"Matching documents are shown while searching";
        BOOL backups=[group[@"id"] isEqual:@"collection-backups"];
        NSImageView* swatch = [NSImageView imageViewWithImage:backups ? [NSImage imageWithSystemSymbolName:@"books.vertical" accessibilityDescription:@"Collection Backups"] : spdf_tab_group_swatch_image(group[@"color"])];
        [swatch.widthAnchor constraintEqualToConstant:backups ? 14 : 8].active = YES;
        NSTextField* name = Label(group[@"name"],12,NO);
        [name setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal]; name.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
        name.toolTip = group[@"name"];
        NSUInteger count = [group[@"documents"] count];
        NSString* status = [NSString stringWithFormat:@"%lu%@%@%@",count,
            [group[@"hidden"] boolValue] || [group[@"selected"] boolValue] ? @"" : (count==1 ? @" document" : @" documents"),
            [group[@"hidden"] boolValue] ? @" · Hidden" : @"",[group[@"selected"] boolValue] ? @" · Active" : @""];
        BOOL hiddenAndActive = [group[@"hidden"] boolValue] && [group[@"selected"] boolValue];
        if (hiddenAndActive) name.stringValue = [NSString stringWithFormat:@"%@ (%lu)",group[@"name"],count];
        NSTextField* statusLabel = Label(hiddenAndActive ? @"Hidden · Active" : status,11,YES); statusLabel.toolTip = status;
        [statusLabel setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
        NSStackView* labels = [NSStackView stackViewWithViews:@[name,statusLabel]];
        [labels setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
        labels.orientation = NSUserInterfaceLayoutOrientationVertical; labels.alignment = NSLayoutAttributeLeading; labels.spacing = 1;
        BOOL hidden = [group[@"hidden"] boolValue];
        SPDFGroupActionButton* visibility = Icon(hidden ? @"eye.slash" : @"eye",[NSString stringWithFormat:@"%@ %@ %@ tab bar",hidden ? @"Show" : @"Hide",group[@"name"],hidden ? @"in" : @"from"],self,@selector(visibility:));
        visibility.groupID = group[@"id"];
        [labels setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
        BOOL collapsed=[group[@"collapsed"] boolValue];
        SPDFGroupActionButton* collapse=Icon(collapsed ? @"arrow.left.and.right" : @"arrow.right.and.line.vertical.and.arrow.left",
            [NSString stringWithFormat:@"%@ %@ in tab bar",collapsed ? @"Expand" : @"Collapse",group[@"name"]],self,@selector(collapseGroup:));
        collapse.groupID=group[@"id"];
        contents = [NSStackView stackViewWithViews:@[disclosure,swatch,labels,collapse,visibility]]; contents.spacing = 5;
        container.toolTip = [NSString stringWithFormat:@"Open %@. Right-click for group actions.",group[@"name"]];
    }
    contents.distribution = NSStackViewDistributionFill; contents.alignment = NSLayoutAttributeCenterY;
    contents.translatesAutoresizingMaskIntoConstraints = NO; [container addSubview:contents];
    [NSLayoutConstraint activateConstraints:@[
        [contents.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:document ? 28 : 2],
        [contents.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-6],
        [contents.centerYAnchor constraintEqualToAnchor:container.centerYAnchor]]];
    return container;
}
- (void)activateRow:(id)sender {
    (void)sender; [self activateIndex:_table.clickedRow >= 0 ? _table.clickedRow : _table.selectedRow];
}
- (void)activateSelectedRow:(id)sender { (void)sender; [self activateIndex:_table.selectedRow]; }
- (void)activateIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_rows.count || !self.actionHandler) return;
    NSDictionary* row = _rows[index];
    _activatingPath=row[@"document"][@"path"]; _activatingGroup=row[@"group"][@"id"];
    self.actionHandler(row[@"document"] ? @"document" : @"jump",row[@"group"][@"id"],row[@"document"][@"path"] ?: @"");
    _activatingPath=nil; _activatingGroup=nil;
}
- (void)toggleAllGroups:(id)sender {
    (void)sender;
    BOOL collapse = NO;
    for (NSDictionary* row in _rows) if (row[@"document"]) { collapse = YES; break; }
    [_expanded removeAllObjects];
    if (!collapse) for (NSDictionary* group in _groups) [_expanded addObject:group[@"id"]];
    _searchCollapsed = collapse; _savedScroll = 0;
    [self rebuildRows]; [_scroll.contentView scrollToPoint:NSZeroPoint]; [self publishState];
}
- (void)disclose:(SPDFGroupActionButton*)sender {
    if ([_expanded containsObject:sender.groupID]) [_expanded removeObject:sender.groupID]; else [_expanded addObject:sender.groupID];
    [self publishState]; [self rebuildRows];
}
- (void)collapseGroup:(SPDFGroupActionButton*)sender {
    if (self.actionHandler) self.actionHandler(@"collapse",sender.groupID,@"");
}
- (void)visibility:(SPDFGroupActionButton*)sender {
    if (self.actionHandler) self.actionHandler(@"visibility",sender.groupID,@"");
}
- (void)controlTextDidChange:(NSNotification*)notification {
    if (notification.object != _search) return;
    SPDFUpdateGroupSearchPlaceholder(_search);
    _searchCollapsed = NO; _savedScroll = 0; [self rebuildRows]; [_scroll.contentView scrollToPoint:NSZeroPoint]; [self publishState];
}
- (BOOL)control:(NSControl*)control textView:(NSTextView*)textView doCommandBySelector:(SEL)command {
    (void)textView;
    if (control!=_search || command!=@selector(cancelOperation:)) return NO;
    [_search abortEditing]; _search.stringValue=@"";
    [self controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:_search]];
    if (self.actionHandler) self.actionHandler(@"end-search",@"",@"");
    return YES;
}
- (void)scrolled:(NSNotification*)notification {
    (void)notification; if (_restoring) return;
    _savedScroll = MAX(0,_scroll.contentView.bounds.origin.y); [self publishState];
}
- (void)menuNeedsUpdate:(NSMenu*)menu {
    [menu removeAllItems]; NSInteger row = _table.clickedRow >= 0 ? _table.clickedRow : _table.selectedRow;
    if (row < 0 || row >= (NSInteger)_rows.count) return;
    NSDictionary* document=_rows[row][@"document"];
    if(document && self.documentMenuProvider) {
        NSMenu* documentMenu=self.documentMenuProvider(document[@"path"],_rows[row][@"group"][@"id"]);
        for(NSMenuItem* item in documentMenu.itemArray.copy) { [documentMenu removeItem:item]; [menu addItem:item]; }
        return;
    }
    NSDictionary* group = _rows[row][@"group"];
    for (NSString* title in @[@"Jump to Group",[group[@"hidden"] boolValue] ? @"Show Group" : @"Hide Group",@"Rename…",@"Close Group…"]) {
        NSMenuItem* item = [menu addItemWithTitle:title action:@selector(menuAction:) keyEquivalent:@""];
        item.target = self; item.representedObject = group;
    }
}
- (void)menuAction:(NSMenuItem*)sender {
    NSDictionary* group = sender.representedObject; if (!self.actionHandler) return;
    if ([sender.title isEqual:@"Rename…"]) {
        NSInteger row=_table.clickedRow >= 0 ? _table.clickedRow : _table.selectedRow;
        NSRect rect=row >= 0 ? [_table rectOfRow:row] : _table.visibleRect;
        __weak SPDFGroupManagementController* weakSelf=self;
        SPDFPresentGroupNamePrompt(_table,rect,group[@"name"],NO,^(NSString* name) {
            if (weakSelf.actionHandler) weakSelf.actionHandler(@"rename",group[@"id"],name);
        });
    } else if ([sender.title isEqual:@"Close Group…"]) self.actionHandler(@"close",group[@"id"],@"");
    else self.actionHandler([sender.title isEqual:@"Jump to Group"] ? @"jump" : @"visibility",group[@"id"],@"");
}
@end
