#import "SPDFMacAIIntegration.h"
#import "SPDFMacSidebarChapters.h"
#import "SPDFMacMarkdownDelegatePrivate.h"

#import "SPDFMacSidebarModeControl.h"
#import "SPDFMacSidebarOutline.h"
#import "SPDFMacGroupActionButton.h"
#import "SPDFMacPanelExpansionImage.h"
#import "SPDFMacCollectionStyle.h"
#import "SPDFMacMarkdownSidebarModel.h"
#import "markdown/SPDFTextDocumentFormats.h"

// Chapter nesting, end to end.
//
// The sidebar is a flat NSTableView shared by chapters, comments and search
// results, so nesting is modelled on the ROWS rather than by swapping in an
// NSOutlineView: the builders produce every row, and this half hides the ones
// under a collapsed parent before the table reloads. That keeps one row view,
// one selection path and one activation path for all three modes.
//
// Collapse state lives in the per-document store (documents.yaml), keyed the
// same way page geometry is, so it is remembered per file across launches
// without a new preference or a new ivar. Absent state means expanded, which is
// the default for a document nobody has touched.

static const CGFloat kSPDFChapterIndentPerLevel = 13.0;
static const CGFloat kSPDFChapterTriangleWidth = 14.0;
static NSString* const kSPDFCollapsedChaptersKey = @"collapsedChapters";

@implementation ShenzhenMacDelegate (SPDFMacSidebarChapters)

#pragma mark - Per-document collapse state

- (NSString*)collapsedChaptersStateKey {
    NSString* path = [self selectedTab].path;
    return path.length ? [self documentStateKeyForPath:path] : nil;
}

- (NSSet<NSString*>*)collapsedChapterKeys {
    NSString* key = [self collapsedChaptersStateKey];
    if (!key.length) return [NSSet set];
    id stored = _documentStates[key][kSPDFCollapsedChaptersKey];
    if (![stored isKindOfClass:NSArray.class]) return [NSSet set];
    NSMutableSet<NSString*>* keys = [NSMutableSet set];
    for (id entry in (NSArray*)stored) {
        if ([entry isKindOfClass:NSString.class]) [keys addObject:entry];
    }
    return keys;
}

- (void)setCollapsedChapterKeys:(NSSet<NSString*>*)keys {
    NSString* key = [self collapsedChaptersStateKey];
    if (!key.length) return;
    NSMutableDictionary* state = _documentStates[key];
    if (![state isKindOfClass:NSMutableDictionary.class]) state = [state mutableCopy] ?: [NSMutableDictionary dictionary];
    if (keys.count)
        // Sorted so the file does not churn between launches on set ordering.
        state[kSPDFCollapsedChaptersKey] = [keys.allObjects sortedArrayUsingSelector:@selector(compare:)];
    else
        [state removeObjectForKey:kSPDFCollapsedChaptersKey];
    state[@"path"] = [self selectedTab].path ?: state[@"path"] ?: @"";
    _documentStates[key] = state;
    [self savePersistentState];
}

#pragma mark - The mode control's segments

// Chapters / Comments / Search, the last present only while a search is. This
// lives beside the nesting rather than with the rest of the sidebar
// coordinator because the nesting is what a lost selection destroys: the
// projection below answers nil for any mode but Chapters, so a control left
// with nothing selected -- which is what AppKit does when a search ends while
// the reader is in its results -- rebuilds the chapters flat and takes the
// expand/collapse button away with them.
- (void)syncSidebarModeControlSegmentsForSearchAvailability:(BOOL)hasSearch {
    spdf_sidebar_mode_control_configure_history(_sidebarModeControl, ![self isMarkdownActive], hasSearch,
        [self selectedTab].collectionHistoryDocumentID.length > 0);
    [self normalizeSidebarModeControlWidths];
}

#pragma mark - Projection

// The chapter rows' levels, or nil when this is not a nestable chapter list.
- (NSArray<NSNumber*>*)chapterLevelsForCurrentSidebar {
    if (_sidebarModeControl.spdf_selectedSidebarMode != SPDFSidebarModeChapters) return nil;
    // A filter already answers "show me these": nesting a filtered list would
    // hide matches under parents that did not match.
    if (_sidebarFilterField.stringValue.length) return nil;
    NSMutableArray<NSNumber*>* levels = [NSMutableArray arrayWithCapacity:_sidebarItems.count];
    for (NSDictionary* item in _sidebarItems) {
        if (![item[@"kind"] isEqualToString:@"chapter"]) return nil;
        id level = item[@"level"];
        [levels addObject:@([level respondsToSelector:@selector(integerValue)] ? [level integerValue] : 0)];
    }
    return levels;
}

- (void)applyChapterNestingAndReload {
    NSArray<NSNumber*>* levels = [self chapterLevelsForCurrentSidebar];
    NSSet<NSString*>* collapsible = levels ? spdf_sidebar_outline_collapsible_keys(levels) : nil;
    [self updateChapterOutlineToggleForCollapsible:collapsible];
    if (levels.count) {
        NSSet<NSString*>* collapsed = [self collapsedChapterKeys];
        NSIndexSet* visible = spdf_sidebar_outline_visible_indexes(levels, collapsed);
        NSMutableArray<NSDictionary*>* rows = [NSMutableArray arrayWithCapacity:visible.count];
        [visible enumerateIndexesUsingBlock:^(NSUInteger i, BOOL* stop) {
          (void)stop;
          NSMutableDictionary* row = [_sidebarItems[i] mutableCopy];
          NSString* outlineKey = spdf_sidebar_outline_key(levels, i);
          row[@"outlineKey"] = outlineKey;
          row[@"hasChildren"] = @(spdf_sidebar_outline_has_children(levels, i));
          row[@"collapsed"] = @([collapsed containsObject:outlineKey]);
          [rows addObject:row];
        }];
        [_sidebarItems setArray:rows];
    }
    [_sidebarTable reloadData];
}

- (void)toggleChapterAtSidebarRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)_sidebarItems.count) return;
    NSDictionary* item = _sidebarItems[(NSUInteger)row];
    NSString* outlineKey = item[@"outlineKey"];
    if (![outlineKey isKindOfClass:NSString.class] || !outlineKey.length) return;
    NSMutableSet<NSString*>* keys = [[self collapsedChapterKeys] mutableCopy];
    if ([keys containsObject:outlineKey])
        [keys removeObject:outlineKey];
    else
        [keys addObject:outlineKey];
    [self setCollapsedChapterKeys:keys];
    // The row set changes under the table, so re-derive it from the builders
    // rather than patching rows here.
    [self rebuildSidebar];
}

- (void)disclosureTriangleClicked:(NSButton*)sender {
    NSInteger row = [_sidebarTable rowForView:sender];
    if (row < 0) {
        // A reused cell can be off-screen mid-reload; fall back to its tag.
        row = sender.tag;
    }
    [self toggleChapterAtSidebarRow:row];
}

#pragma mark - Expand / collapse all

- (void)expandAllChapters:(id)sender {
    (void)sender;
    [self setCollapsedChapterKeys:[NSSet set]];
    [self rebuildSidebar];
}

- (void)toggleAllChapters:(id)sender {
    NSArray<NSNumber*>* levels = [self chapterLevelsForCurrentSidebar];
    NSMutableSet<NSString*>* open =
        levels.count ? [spdf_sidebar_outline_collapsible_keys(levels) mutableCopy] : [NSMutableSet set];
    [open minusSet:[self collapsedChapterKeys]];
    if (open.count)
        [self collapseAllChapters:sender];
    else
        [self expandAllChapters:sender];
}

- (void)collapseAllChapters:(id)sender {
    (void)sender;
    NSArray<NSNumber*>* levels = [self chapterLevelsForCurrentSidebar];
    if (!levels.count) return;
    [self setCollapsedChapterKeys:spdf_sidebar_outline_collapsible_keys(levels)];
    [self rebuildSidebar];
}


#pragma mark - The row view

// Tags let the reused cell (and the sidebar container) find their pieces again
// without a bespoke NSTableCellView subclass.
static const NSInteger kSPDFTriangleTag = 8800;
static const NSInteger kSPDFOutlineToggleTag = 8801;
static const NSInteger kSPDFChapterPageTag = 8802;
static NSString* const kSPDFIndentConstraintID = @"SPDFChapterIndent";
static NSString* const kSPDFFilterTrailingConstraintID = @"SPDFSidebarFilterTrailing";

// The traditional disclosure pair: pointing right when collapsed, down when
// open. Drawn small and in the secondary tint so it reads as chrome.
static NSImage* SPDFChapterTriangleImage(BOOL collapsed) {
    NSString* symbol = collapsed ? @"chevron.right" : @"chevron.down";
    NSImage* image = [NSImage imageWithSystemSymbolName:symbol
                               accessibilityDescription:collapsed ? @"Expand" : @"Collapse"];
    NSImageSymbolConfiguration* configuration =
        [NSImageSymbolConfiguration configurationWithPointSize:9 weight:NSFontWeightSemibold];
    return [image imageWithSymbolConfiguration:configuration] ?: image;
}

static NSLayoutConstraint* SPDFIndentConstraint(NSView* cell) {
    for (NSLayoutConstraint* constraint in cell.constraints) {
        if ([constraint.identifier isEqualToString:kSPDFIndentConstraintID]) return constraint;
    }
    return nil;
}

- (NSTableCellView*)sidebarCellForTableView:(NSTableView*)tableView {
    NSTableCellView* cell = [tableView makeViewWithIdentifier:@"SidebarCell" owner:self];
    if (cell) return cell;
    cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 230, 25)];
    cell.identifier = @"SidebarCell";

    // Borderless so the triangle reads as a disclosure control rather than a
    // button, and small so it sits inside a 25pt row.
    NSButton* triangle = [SPDFGroupActionButton new];
    triangle.image=SPDFChapterTriangleImage(YES); triangle.target=self;
    triangle.action=@selector(disclosureTriangleClicked:);
    triangle.bezelStyle = NSBezelStyleInline;
    triangle.bordered = NO;
    triangle.imagePosition = NSImageOnly;
    triangle.tag = kSPDFTriangleTag;
    triangle.translatesAutoresizingMaskIntoConstraints = NO;
    [triangle.widthAnchor constraintEqualToConstant:kSPDFChapterTriangleWidth].active = YES;
    [triangle.heightAnchor constraintEqualToConstant:20].active = YES;
    [cell addSubview:triangle];

    NSTextField* field = [NSTextField labelWithString:@""];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    field.lineBreakMode = NSLineBreakByTruncatingTail;
    cell.textField = field;
    [cell addSubview:field];

    NSTextField* page = [NSTextField labelWithString:@""];
    page.tag = kSPDFChapterPageTag; page.translatesAutoresizingMaskIntoConstraints = NO;
    page.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    page.textColor = SPDFCollectionColor(@"secondary"); page.alignment = NSTextAlignmentRight;
    [page setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [page setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [cell addSubview:page];

    // The triangle's leading is the indent: it moves with the heading's depth
    // and the text follows it, so a nested chapter lines up under its parent's
    // title rather than under the parent's triangle.
    NSLayoutConstraint* indent = [triangle.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2];
    indent.identifier = kSPDFIndentConstraintID;
    [NSLayoutConstraint activateConstraints:@[
        indent,
        [triangle.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        [field.leadingAnchor constraintEqualToAnchor:triangle.trailingAnchor constant:2],
        [field.trailingAnchor constraintEqualToAnchor:page.leadingAnchor constant:-8],
        [page.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-16],
        [page.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        [field.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor]
    ]];
    return cell;
}

- (void)styleSidebarCell:(NSTableCellView*)cell item:(NSDictionary*)item {
    id levelValue = item[@"level"];
    NSInteger level = [levelValue respondsToSelector:@selector(integerValue)] ? [levelValue integerValue] : 0;
    level = MAX(0, MIN(level, 16));
    id titleValue = item[@"title"];
    NSString* title = [titleValue isKindOfClass:NSString.class] ? titleValue : @"";
    id pageValue = item[@"page"];
    NSInteger page = [pageValue respondsToSelector:@selector(integerValue)] ? [pageValue integerValue] : -1;

    NSButton* triangle = [cell viewWithTag:kSPDFTriangleTag];
    BOOL hasChildren = [item[@"hasChildren"] boolValue];
    BOOL collapsed = [item[@"collapsed"] boolValue];
    // A childless row keeps the triangle's WIDTH -- hidden, not removed -- so
    // titles at the same depth align whether or not they have children.
    triangle.hidden = !hasChildren;
    triangle.enabled = hasChildren;
    triangle.image = SPDFChapterTriangleImage(collapsed);
    triangle.toolTip = collapsed ? @"Expand" : @"Collapse";
    triangle.tag = kSPDFTriangleTag;
    SPDFIndentConstraint(cell).constant = 2 + level * kSPDFChapterIndentPerLevel;

    cell.textField.stringValue = title ?: @"";
    BOOL chapter = [item[@"kind"] isEqual:@"chapter"];
    cell.textField.font = [NSFont systemFontOfSize:chapter ? 12 : 13 weight:NSFontWeightRegular];
    cell.textField.textColor = SPDFCollectionColor(page >= 0 ? @"text" : @"secondary");
    NSTextField* pageLabel = [cell viewWithTag:kSPDFChapterPageTag];
    pageLabel.stringValue = chapter && page >= 0 ? [NSString stringWithFormat:@"%ld",(long)page+1] : @"";
    pageLabel.accessibilityLabel = pageLabel.stringValue.length
        ? [@"Page " stringByAppendingString:pageLabel.stringValue] : @"";
    cell.toolTip = title;
}

- (NSString*)sidebarOutlineSummary {
    NSUInteger generated=[self aiGeneratedChapterRows].count;
    if (generated) return [NSString stringWithFormat:@"AI chapters · %lu%@",(unsigned long)generated,
        [[self aiAnalysisForPath:_path][@"partial"] boolValue] ? @" · partial document" : @""];
    if (SPDFIsSourceDocumentPath(_path)) return @"No chapters";
    NSUInteger count = [self isMarkdownActive] ? [self activeMarkdownSession].sidebarModel.chapterItems.count
        : (NSUInteger)MAX(0,_outline.count);
    return [NSString stringWithFormat:@"%@ · %lu %@",[self isMarkdownActive] ? @"Markdown headings" : @"PDF outline",
        (unsigned long)count,count == 1 ? @"chapter" : @"chapters"];
}

#pragma mark - The expand / collapse all control

// One button, on the filter field's own row at the trailing edge, showing the
// action it performs: arrows drawing in when there is something to collapse,
// arrows opening out when everything is already collapsed. A single control
// beats a labelled pair here -- it costs the list no height at all, and the
// state it would otherwise spell out is already visible in the rows.
static const CGFloat kSPDFOutlineToggleWidth = 26.0;
static const CGFloat kSPDFOutlineToggleGap = 4.0;
static const CGFloat kSPDFSidebarEdgeInset = 8.0;

static NSButton* SPDFOutlineToggleControl(ShenzhenMacDelegate* self, SEL action) {
    NSButton* button = [SPDFGroupActionButton new];
    button.image=SPDFGroupExpansionImage(YES); button.target=self; button.action=action;
    button.bordered = NO; button.ignoresMultiClick = NO;
    button.showsBorderOnlyWhileMouseInside = YES;
    button.controlSize = NSControlSizeSmall;
    button.imagePosition = NSImageOnly;
    button.contentTintColor = SPDFCollectionColor(@"secondary");
    button.toolTip = @"Collapse All";
    button.tag = kSPDFOutlineToggleTag;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    return button;
}

static NSLayoutConstraint* SPDFFilterTrailingConstraint(NSView* container) {
    for (NSLayoutConstraint* constraint in container.constraints) {
        if ([constraint.identifier isEqualToString:kSPDFFilterTrailingConstraintID]) return constraint;
    }
    return nil;
}

- (void)installChapterOutlineControls {
    if ([_sidebarContainer viewWithTag:kSPDFOutlineToggleTag]) return;
    NSScrollView* scroll = _sidebarTable.enclosingScrollView;
    if (!_sidebarContainer || !_sidebarFilterField || !scroll) return;
    // AppKit had already applied a safe-area content inset to the list, which
    // is why the gap under the buttons measured ~13pt while the constraint said
    // 1: the inset sat on top of it. Turning the automatic behaviour off does
    // not clear an inset already set, so zero it too -- then the constants
    // below are the gaps that appear.
    scroll.automaticallyAdjustsContentInsets = NO;
    scroll.contentInsets = NSEdgeInsetsZero;
    // The list's own top padding, not this margin, was most of the gap under
    // the buttons: -rectOfRow:0 started at y=10 under the default (inset)
    // table style. Pulling the list up with a negative constant only hid the
    // first row behind the buttons, so drop the padding at its source.
    if (@available(macOS 11.0, *)) _sidebarTable.style = NSTableViewStyleFullWidth;

    NSButton* toggle = SPDFOutlineToggleControl(self, @selector(toggleAllChapters:));
    [_sidebarContainer addSubview:toggle];

    // The filter field's trailing edge is owned here rather than by the
    // coordinator, because it is what makes room for the button: it stops short
    // of the panel edge while the button is up, and reclaims the width when a
    // flat outline (or Comments, or search results) takes the button away.
    NSLayoutConstraint* filterTrailing =
        [_sidebarFilterField.trailingAnchor constraintEqualToAnchor:_sidebarContainer.trailingAnchor
                                                          constant:-kSPDFSidebarEdgeInset];
    filterTrailing.identifier = kSPDFFilterTrailingConstraintID;
    [NSLayoutConstraint activateConstraints:@[
        filterTrailing,
        [toggle.trailingAnchor constraintEqualToAnchor:_sidebarContainer.trailingAnchor
                                              constant:-kSPDFSidebarEdgeInset],
        [toggle.centerYAnchor constraintEqualToAnchor:_sidebarFilterField.centerYAnchor],
        [toggle.widthAnchor constraintEqualToConstant:kSPDFOutlineToggleWidth],
        [toggle.heightAnchor constraintEqualToConstant:26]
    ]];
}

- (void)updateChapterOutlineToggleForCollapsible:(NSSet<NSString*>*)collapsible {
    NSButton* toggle = [_sidebarContainer viewWithTag:kSPDFOutlineToggleTag];
    if (!toggle) return;
    // Nothing nestable (a flat outline, comments, search results): the button
    // would be inert, so it goes away and the filter takes the width back.
    BOOL visible = collapsible.count > 0;
    toggle.hidden = !visible;
    SPDFFilterTrailingConstraint(_sidebarContainer).constant =
        visible ? -(kSPDFSidebarEdgeInset + kSPDFOutlineToggleWidth + kSPDFOutlineToggleGap) : -kSPDFSidebarEdgeInset;
    if (!visible) return;
    // Collapse while anything is still open, expand once nothing is.
    NSMutableSet<NSString*>* open = [collapsible mutableCopy];
    [open minusSet:[self collapsedChapterKeys]];
    BOOL collapses = open.count > 0;
    toggle.image = SPDFGroupExpansionImage(collapses);
    toggle.toolTip = collapses ? @"Collapse All" : @"Expand All";
}

@end
