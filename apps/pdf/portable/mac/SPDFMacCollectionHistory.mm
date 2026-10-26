#import "SPDFMacCollectionSavePanel.h"
#import "SPDFMacCollectionAvailability.h"
#import "SPDFMacCollectionHistory.h"
#import "SPDFMacCollectionStore.h"
#import "SPDFMacCollectionCompare.h"
#import "SPDFMacCollectionCompareLatest.h"
#import "SPDFMacCollectionStyle.h"
#import "SPDFMacFileExplorerPreference.h"

@interface SPDFHistoryContentView : NSView
@end
@implementation SPDFHistoryContentView
- (BOOL)isFlipped { return YES; }
@end


@interface SPDFHistoryVersionRow : NSTableRowView
@end
@implementation SPDFHistoryVersionRow
- (void)drawSelectionInRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [SPDFCollectionColor(@"selected") setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,2,1) xRadius:6 yRadius:6] fill];
}
@end

@implementation SPDFMacCollectionHistoryController {
    SPDFMacCollectionStore* _store;
    NSString* _documentID;
    SPDFCollectionOpenHandler _open;
    NSDictionary* _document;
    NSArray<NSDictionary*>* _versions;
    NSTableView* _table;
    NSTextField* _title;
    NSTextField* _status;
    NSButton* _compareButton;
    NSButton* _keepButton;
    NSPopUpButton* _actionsMenu;
    NSUInteger _generation;
    NSUInteger _previewGeneration;
    BOOL _restoringSelection;
    NSStackView* _recoveryActions;
    BOOL _showsDocumentTitle;
    BOOL _storageLimited;
    BOOL _deletionPending;
    BOOL _missingSource;
}
@synthesize showsDocumentTitle = _showsDocumentTitle;
- (void)setShowsDocumentTitle:(BOOL)value { _showsDocumentTitle = value; _title.hidden = !value; }
- (instancetype)initWithStore:(SPDFMacCollectionStore*)store documentID:(NSString*)documentID
                         open:(SPDFCollectionOpenHandler)open {
    if (!(self = [super initWithNibName:nil bundle:nil])) return nil;
    _store = store; _documentID = documentID.copy; _open = [open copy]; _versions = @[]; _showsDocumentTitle = YES;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(collectionSettingsChanged:)
        name:@"SPDFCollectionSettingsChanged" object:nil];
    return self;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)collectionSettingsChanged:(NSNotification*)note { (void)note; if (self.isViewLoaded) [self reload]; }
- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0,0,280,650)];
    _title = [NSTextField labelWithString:@"Loading…"];
    _title.identifier = @"HistoryDocumentTitle";
    _title.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
    _title.lineBreakMode = NSLineBreakByTruncatingMiddle; _title.hidden = !_showsDocumentTitle;
    _status = [NSTextField wrappingLabelWithString:@"Open a version to read or edit it."];
    _status.font = [NSFont systemFontOfSize:11];
    _status.textColor = NSColor.secondaryLabelColor;
    _table = [NSTableView new]; _table.headerView = nil; _table.rowHeight = 56;
    _table.dataSource = self; _table.delegate = self;
    _table.style = NSTableViewStylePlain; _table.backgroundColor = NSColor.clearColor;
    _table.intercellSpacing = NSMakeSize(0,2);
    _table.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    [_table setAccessibilityLabel:@"Saved document versions"];
    _table.menu = [[NSMenu alloc] initWithTitle:@"Version"]; _table.menu.delegate = self;
    [_table addTableColumn:[[NSTableColumn alloc] initWithIdentifier:@"version"]];
    NSScrollView* scroll = [NSScrollView new]; scroll.documentView = _table;
    scroll.hasVerticalScroller = YES; scroll.autohidesScrollers = YES; scroll.drawsBackground = NO;
    scroll.identifier = @"HistoryVersionsViewport";
    _compareButton = SPDFCollectionButton(@"Compare with Latest",self,@selector(compareCurrent:),@"normal");
    _keepButton = SPDFCollectionButton(@"Keep forever",self,@selector(keep:),@"quiet");
    _keepButton.buttonType = NSButtonTypePushOnPushOff;
    _keepButton.hidden = YES; // Reveal only after the applied cap has been loaded.
    _keepButton.identifier = @"HistoryKeepForever";
    _keepButton.toolTip = @"Keeping any version protects this document’s entire history from automatic storage cleanup. "
        @"Removing all Keep forever marks allows cleanup; it does not delete anything immediately. Manual deletion is still available.";
    _actionsMenu = SPDFCollectionPopUp(); _actionsMenu.pullsDown = YES;
    _actionsMenu.identifier = @"HistoryVersionActions";
    _actionsMenu.controlSize = NSControlSizeSmall; _actionsMenu.font = [NSFont systemFontOfSize:11];
    _actionsMenu.accessibilityLabel = @"Version actions";
    _actionsMenu.menu.autoenablesItems = NO;
    [_actionsMenu addItemWithTitle:@"Actions"];
    NSArray* titles = @[@"Compare with Previous",@"Save a Copy…",@"Manage Collection…"];
    NSArray* selectors = @[@"comparePrevious:",@"saveCopy:",@"manage:"];
    for (NSUInteger i = 0; i < titles.count; i++) {
        NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:titles[i]
            action:NSSelectorFromString(selectors[i]) keyEquivalent:@""];
        item.target = self; [_actionsMenu.menu addItem:item];
    }
    NSView* flexible = [NSView new];
    NSStackView* secondary = [NSStackView stackViewWithViews:@[flexible,_actionsMenu]];
    secondary.orientation = NSUserInterfaceLayoutOrientationHorizontal; secondary.spacing = 6;
    NSStackView* actions = [NSStackView stackViewWithViews:@[_compareButton,_keepButton,secondary]];
    actions.orientation = NSUserInterfaceLayoutOrientationVertical;
    actions.alignment = NSLayoutAttributeLeading; actions.spacing = 4;
    NSButton* find = [NSButton buttonWithTitle:@"Find Document…" target:self action:@selector(findDocument:)];
    NSButton* save = [NSButton buttonWithTitle:@"Save New Copy As…" target:self action:@selector(saveLatestAs:)];
    for (NSButton* button in @[find,save]) {
        button.bordered = NO; button.alignment = NSTextAlignmentLeft;
        button.contentTintColor = NSColor.controlAccentColor;
        button.font = [NSFont systemFontOfSize:11];
        [button.heightAnchor constraintEqualToConstant:24].active = YES;
    }
    _recoveryActions = [NSStackView stackViewWithViews:@[find,save]];
    _recoveryActions.orientation = NSUserInterfaceLayoutOrientationVertical;
    _recoveryActions.alignment = NSLayoutAttributeLeading; _recoveryActions.spacing = 4;
    _recoveryActions.hidden = YES;
    // Show versions before the recovery/actions area: a short panel must still
    // answer the user's history question before presenting administrative controls.
    NSStackView* stack = [NSStackView stackViewWithViews:@[_title,_status,scroll,_recoveryActions,actions]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical; stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 6; stack.translatesAutoresizingMaskIntoConstraints = NO;
    NSScrollView* viewport = [NSScrollView new];
    viewport.identifier = @"HistoryContentViewport";
    viewport.hasVerticalScroller = YES; viewport.autohidesScrollers = YES; viewport.drawsBackground = NO;
    viewport.translatesAutoresizingMaskIntoConstraints = NO;
    NSView* content = [SPDFHistoryContentView new];
    content.translatesAutoresizingMaskIntoConstraints = NO; viewport.documentView = content;
    [content addSubview:stack]; [self.view addSubview:viewport];
    NSLayoutConstraint* fill = [content.heightAnchor constraintEqualToAnchor:viewport.contentView.heightAnchor];
    fill.priority = NSLayoutPriorityDefaultLow - 1;
    [NSLayoutConstraint activateConstraints:@[
        [viewport.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [viewport.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [viewport.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [viewport.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [content.widthAnchor constraintEqualToAnchor:viewport.contentView.widthAnchor],
        [content.heightAnchor constraintGreaterThanOrEqualToAnchor:viewport.contentView.heightAnchor], fill,
        [stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:10],
        [stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-10],
        [stack.topAnchor constraintEqualToAnchor:content.topAnchor constant:8],
        [stack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-8],
        [_title.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [_status.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [scroll.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [scroll.heightAnchor constraintGreaterThanOrEqualToConstant:112],
        [actions.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [_compareButton.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [_keepButton.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [secondary.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [_recoveryActions.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [find.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [save.widthAnchor constraintEqualToAnchor:stack.widthAnchor]]];
    [self reload];
}
- (void)viewDidLayout {
    [super viewDidLayout];
    // Last-column autoresizing alone retains a stale width after sidebar resizing.
    CGFloat width = NSWidth(_table.enclosingScrollView.contentView.bounds);
    if (width > 0) {
        _table.tableColumns.firstObject.width = width;
        [_table setFrameSize:NSMakeSize(width,NSHeight(_table.frame))];
    }
}
- (void)cancelPendingPreviews { ++_previewGeneration; }
- (void)reload {
    NSUInteger generation = ++_generation;
    NSString* identifier = _documentID;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        NSDictionary* found = nil;
        for (NSDictionary* doc in [self->_store documents]) if ([doc[@"id"] isEqual:identifier]) { found = doc; break; }
        NSArray* versions = [[found[@"versions"] reverseObjectEnumerator] allObjects] ?: @[];
        BOOL storageLimited = [self->_store isStorageLimited];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_generation) return;
            NSString* selected = [self selectedVersion][@"id"];
            self->_document = found; self->_versions = versions; self->_storageLimited = storageLimited;
            self->_title.stringValue = SPDFCollectionDocumentTitle(found) ?: @"No protected history";
            self->_title.toolTip = found[@"path"];
            BOOL available = SPDFCollectionOriginalAvailable(found);
            self->_missingSource = found != nil && !available;
            self->_recoveryActions.hidden = available || !versions.count;
            self->_status.stringValue = !versions.count ? @"No saved versions yet" :
                available ? @"Original available · edits retain version history" :
                @"Original missing · saved versions available";
            self->_restoringSelection = YES;
            [self->_table reloadData];
            if (selected) for (NSUInteger i = 0; i < versions.count; i++) if ([versions[i][@"id"] isEqual:selected])
                [self->_table selectRowIndexes:[NSIndexSet indexSetWithIndex:i+(self->_missingSource ? 1 : 0)] byExtendingSelection:NO];
            self->_restoringSelection = NO;
            [self updateActions];
        });
    });
}
- (NSInteger)numberOfRowsInTableView:(NSTableView*)table { (void)table; return _versions.count+(_missingSource ? 1 : 0); }
- (NSTableRowView*)tableView:(NSTableView*)table rowViewForRow:(NSInteger)row {
    (void)table; (void)row; return [SPDFHistoryVersionRow new];
}
- (NSView*)tableView:(NSTableView*)table viewForTableColumn:(NSTableColumn*)column row:(NSInteger)row {
    (void)table; (void)column;
    BOOL missing = _missingSource && row==0;
    NSDictionary* version = missing ? nil : _versions[row-(_missingSource ? 1 : 0)];
    NSDate* captured = [NSDate dateWithTimeIntervalSince1970:[version[@"capturedAt"] doubleValue]];
    NSString* date = [NSDateFormatter localizedStringFromDate:captured
        dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterNoStyle];
    NSString* time = [NSDateFormatter localizedStringFromDate:captured
        dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterShortStyle];
    NSString* size = [NSByteCountFormatter stringFromByteCount:[version[@"size"] longLongValue]
        countStyle:NSByteCountFormatterCountStyleFile];
    NSTextField* label = [NSTextField labelWithString:missing ? @"Missing document" : date];
    if (missing) label.textColor=NSColor.systemRedColor;
    label.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.identifier = @"HistoryVersionDate";
    NSTextField* clock = [NSTextField labelWithString:missing ? @"Original source unavailable" : time];
    clock.font = [NSFont systemFontOfSize:11]; clock.textColor = NSColor.secondaryLabelColor;
    NSView* spacer = [NSView new];
    // Dates retain a whole line even with always-visible scrollbars at 176pt.
    NSStackView* title = [NSStackView stackViewWithViews:!missing && SPDFCollectionVersionIsLatest(_document,version)
        ? @[clock,spacer,_missingSource ? SPDFCollectionLatestCopyBadge() : SPDFCollectionLatestBadge()] : @[clock,spacer]];
    title.orientation = NSUserInterfaceLayoutOrientationHorizontal; title.spacing = 5;
    NSTextField* detail = [NSTextField labelWithString:[NSString stringWithFormat:@"%@%@ · %@",
        [version[@"keep"] boolValue] ? @"★ " : @"",version[@"reason"] ?: @"Saved version",size]];
    if (missing) detail.stringValue=@"Locate document to reconnect";
    detail.font = [NSFont systemFontOfSize:10]; detail.textColor = NSColor.secondaryLabelColor;
    detail.lineBreakMode = NSLineBreakByTruncatingTail;
    NSStackView* lines = [NSStackView stackViewWithViews:@[label,title,detail]];
    lines.orientation = NSUserInterfaceLayoutOrientationVertical;
    lines.alignment = NSLayoutAttributeLeading; lines.spacing = 1;
    NSTableCellView* cell = [NSTableCellView new]; lines.translatesAutoresizingMaskIntoConstraints = NO;
    [cell addSubview:lines];
    cell.toolTip = missing ? @"Missing document · Original source unavailable" : [NSString stringWithFormat:@"%@ · %@ · %@",date,time,detail.stringValue];
    cell.accessibilityLabel = cell.toolTip;
    [NSLayoutConstraint activateConstraints:@[
        [lines.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:5],
        [lines.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-5],
        [lines.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        [label.widthAnchor constraintEqualToAnchor:lines.widthAnchor],
        [title.widthAnchor constraintEqualToAnchor:lines.widthAnchor],
        [detail.widthAnchor constraintEqualToAnchor:lines.widthAnchor]]];
    return cell;
}
- (NSDictionary*)selectedVersion {
    NSInteger row = _table.selectedRow-(_missingSource ? 1 : 0);
    return row >= 0 && row < (NSInteger)_versions.count ? _versions[row] : nil;
}
- (void)updateActions {
    NSDictionary* version = [self selectedVersion];
    BOOL encrypted = [version[@"encrypted"] boolValue];
    BOOL latest = version && SPDFCollectionVersionIsLatest(_document,version);
    _compareButton.enabled = version != nil && !latest && !encrypted;
    _compareButton.toolTip = !version ? @"Select a saved version to compare." : encrypted ?
        @"Comparison is unavailable for an encrypted saved version." : latest ?
        @"Select an earlier version to compare with Latest. Compare with Previous is in Actions." :
        @"Compare this version with the latest document.";
    _keepButton.hidden = !_storageLimited;
    _keepButton.enabled = version != nil && _storageLimited;
    _keepButton.title = [version[@"keep"] boolValue] ? @"Stop keep forever" : @"Keep forever";
    _keepButton.accessibilityLabel = _keepButton.title;
    _keepButton.state = [version[@"keep"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    [_actionsMenu itemAtIndex:1].enabled = version != nil && !encrypted && _table.selectedRow-(_missingSource ? 1 : 0)+1 < (NSInteger)_versions.count;
    [_actionsMenu itemAtIndex:2].enabled = version != nil;
    [_actionsMenu itemAtIndex:3].enabled = YES;
}
- (void)tableViewSelectionDidChange:(NSNotification*)note {
    (void)note; [self updateActions];
    NSDictionary* version = [self selectedVersion]; if (!version || _restoringSelection) return;
    NSUInteger generation = ++_previewGeneration;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        NSDictionary* current = [self currentDocument];
        BOOL original = SPDFCollectionVersionIsLatest(current,version) && SPDFCollectionOriginalAvailable(current);
        NSError* error = nil;
        NSURL* URL = original ? [NSURL fileURLWithPath:current[@"path"]] :
            [self->_store editableVersionID:version[@"id"] documentID:self->_documentID error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_previewGeneration) return;
            self->_document = current; self->_recoveryActions.hidden = SPDFCollectionOriginalAvailable(current);
            self->_status.stringValue = error.localizedDescription ?: (SPDFCollectionOriginalAvailable(current) ?
                @"Original available · edits retain version history" : @"Original missing · saved versions available");
            if (self->_missingSource == SPDFCollectionOriginalAvailable(current)) [self reload];
            if (URL) self->_open(URL.path,!original);
        });
    });
}
- (void)materialize:(NSDictionary*)version completion:(void (^)(NSURL*))completion {
    _status.stringValue = @"Opening Collection document…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        NSError* error = nil;
        NSURL* URL = [self->_store materializeVersionID:version[@"id"] documentID:self->_documentID error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_status.stringValue = error.localizedDescription ?: @"Collection document";
            if (URL) completion(URL);
        });
    });
}
- (void)compareVersion:(NSDictionary*)selected previous:(BOOL)previous {
    if (!selected) return;
    NSInteger row = [_versions indexOfObject:selected];
    if (row == NSNotFound) return;
    if (previous && row+1 >= (NSInteger)_versions.count) return;
    NSDictionary* oldVersion = previous ? _versions[row+1] : selected;
    NSString* title = SPDFCollectionDocumentTitle(_document) ?: @"Document";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        NSError* error = nil;
        NSURL* oldURL = [self->_store materializeVersionID:oldVersion[@"id"] documentID:self->_documentID error:&error];
        NSDictionary* latest = !previous && oldURL ? SPDFCollectionResolveLatestComparison(self->_store,self->_documentID,&error) : nil;
        NSURL* newURL = previous && oldURL ? [self->_store materializeVersionID:selected[@"id"] documentID:self->_documentID error:&error] : latest[@"URL"];
        NSString* (^label)(NSDictionary*) = ^NSString*(NSDictionary* version) {
            NSString* date = [NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:
                [version[@"capturedAt"] doubleValue]] dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterShortStyle];
            return [NSString stringWithFormat:@"%@ · %@",title,date];
        };
        dispatch_async(dispatch_get_main_queue(), ^{
            if (oldURL && newURL) SPDFMacShowCollectionComparison(oldURL,newURL,label(oldVersion),
                previous ? label(selected) : latest[@"label"],self.view.window);
            else self->_status.stringValue = error.localizedDescription ?: @"Comparison unavailable";
        });
    });
}
- (void)compareCurrent:(id)sender { (void)sender; [self compareVersion:[self selectedVersion] previous:NO]; }
- (void)comparePrevious:(id)sender { (void)sender; [self compareVersion:[self selectedVersion] previous:YES]; }
- (void)saveCopy:(id)sender {
    (void)sender; NSDictionary* version = [self selectedVersion]; if (!version) return;
    [self saveVersion:version restoreLink:NO];
}
- (void)saveVersion:(NSDictionary*)version restoreLink:(BOOL)restore {
    NSSavePanel* panel = [NSSavePanel savePanel]; SPDFCollectionConfigureSavePanel(panel, _document[@"path"]);
    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK) return;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
            NSError* error = nil;
            BOOL saved = [self->_store exportVersionID:version[@"id"] documentID:self->_documentID toURL:panel.URL error:&error];
            if (saved && restore) [self->_store linkDocumentID:self->_documentID toPath:panel.URL.path allowMismatch:NO error:&error];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (error) [self.view.window presentError:error]; else if (restore) [self didRestorePath:panel.URL.path];
                else { [self reload]; self->_open(panel.URL.path,NO); }
            });
        });
    }];
}
- (void)keep:(id)sender {
    if (!_storageLimited || ![_store isStorageLimited]) return;
    (void)sender; NSDictionary* version = [self selectedVersion]; if (!version) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        NSError* error = nil;
        [self->_store setKeep:![version[@"keep"] boolValue] versionID:version[@"id"] documentID:self->_documentID error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{ if (error) [self.view.window presentError:error]; [self reload]; });
    });
}
- (NSDictionary*)currentDocument {
    for (NSDictionary* doc in [_store documents]) if ([doc[@"id"] isEqual:_documentID]) return doc;
    return _document;
}
- (void)findDocument:(id)sender {
    (void)sender;
    SPDFMacLocateCollectionOriginal(_store,_documentID,self.view.window, ^(NSString* path) {
        self->_open(path,NO);
    }, ^(NSString* path) {
        [self didRestorePath:path];
    });
}
- (void)didRestorePath:(NSString*)path {
    if (self.restoreLinkHandler) self.restoreLinkHandler(_document[@"path"],path);
    else _open(path,NO);
    [self reload];
}
- (void)saveLatestAs:(id)sender {
    (void)sender;
    NSDictionary* latest = _versions.firstObject;
    for (NSDictionary* version in _versions)
        if (SPDFCollectionVersionIsLatest(_document,version)) { latest = version; break; }
    if (latest) [self saveVersion:latest restoreLink:YES];
}
- (void)menuNeedsUpdate:(NSMenu*)menu {
    [menu removeAllItems];
    NSInteger row = _table.clickedRow >= 0 ? _table.clickedRow : _table.selectedRow;
    if (_missingSource && row==0) {
        NSMenuItem* locate=[menu addItemWithTitle:@"Locate document…" action:@selector(findDocument:) keyEquivalent:@""];
        locate.target=self; return;
    }
    row-=(_missingSource ? 1 : 0);
    if (row < 0 || row >= (NSInteger)_versions.count) return;
    NSMenuItem* reveal = [[NSMenuItem alloc] initWithTitle:@"Show in Explorer" action:@selector(showVersionInExplorer:) keyEquivalent:@""];
    reveal.target = self; reveal.representedObject = _versions[row]; [menu addItem:reveal];
    NSDictionary* version=_versions[row];
    BOOL latest=SPDFCollectionVersionIsLatest(_document,version);
    BOOL original=latest && SPDFCollectionOriginalAvailable(_document);
    if (!latest) {
        NSMenuItem* compare=[[NSMenuItem alloc] initWithTitle:@"Compare with Latest"
            action:@selector(compareHistoryVersionWithLatest:) keyEquivalent:@""];
        compare.target=self; compare.representedObject=version;
        compare.enabled=![version[@"encrypted"] boolValue]; [menu addItem:compare];
    }
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem* remove=[[NSMenuItem alloc] initWithTitle:original ? @"Delete all previous backups…" : @"Delete version…"
        action:@selector(deleteHistoryItem:) keyEquivalent:@""];
    remove.target=self; remove.representedObject=@{@"version":version,@"previousBackups":@(original)};
    remove.enabled=!_deletionPending && (!original || _versions.count>1);
    menu.autoenablesItems=NO; [menu addItem:remove];
}
- (void)compareHistoryVersionWithLatest:(NSMenuItem*)sender {
    // Menu identity owns the action; the row selected behind the menu may differ.
    [self compareVersion:sender.representedObject previous:NO];
}
- (void)confirmDeletionOfVersion:(NSDictionary*)version previousBackups:(BOOL)previous
                     completion:(void (^)(BOOL))completion {
    NSAlert* alert=[NSAlert new];
    alert.messageText=previous ? @"Delete all previous backups?" : @"Delete this saved version?";
    NSString* date=[NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:
        [version[@"capturedAt"] doubleValue]] dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterShortStyle];
    alert.informativeText=previous ?
        @"Older saved versions, including Keep forever versions, will be permanently deleted. The original and latest saved copy are kept." :
        [NSString stringWithFormat:@"The saved version from %@ will be permanently deleted. The original document is kept. This cannot be undone.",date];
    [alert addButtonWithTitle:@"Cancel"];
    [alert addButtonWithTitle:previous ? @"Delete Previous Backups" : @"Delete Version"];
    [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse result) {
        completion(result==NSAlertSecondButtonReturn);
    }];
}
- (void)deleteHistoryItem:(NSMenuItem*)sender {
    NSDictionary* intent=sender.representedObject; NSDictionary* version=intent[@"version"];
    if (_deletionPending || !version[@"id"]) return;
    NSString* documentID=_documentID; NSString* versionID=version[@"id"];
    BOOL previous=[intent[@"previousBackups"] boolValue];
    _deletionPending=YES;
    [self confirmDeletionOfVersion:version previousBackups:previous completion:^(BOOL confirmed) {
        if (!confirmed) { self->_deletionPending=NO; return; }
        [self cancelPendingPreviews];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
            NSError* error=nil;
            if (previous) [self->_store deletePreviousBackupsForDocumentID:documentID error:&error];
            else [self->_store deleteDocumentID:documentID versionID:versionID error:&error];
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_deletionPending=NO;
                if(error) [self.view.window presentError:error];
                [self reload];
            });
        });
    }];
}
- (void)showVersionInExplorer:(NSMenuItem*)sender {
    NSDictionary* version = sender.representedObject; if (!version) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        NSDictionary* doc = [self currentDocument]; NSError* error = nil;
        NSURL* URL = SPDFCollectionVersionIsLatest(doc,version) && SPDFCollectionOriginalAvailable(doc) ?
            [NSURL fileURLWithPath:doc[@"path"]] :
            [self->_store materializeVersionID:version[@"id"] documentID:self->_documentID error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (URL) [self revealPath:URL.path]; else self->_status.stringValue = error.localizedDescription ?: @"Copy unavailable";
        });
    });
}
- (void)revealPath:(NSString*)path { SPDFMacRevealPath(path,SPDFMacCurrentFileExplorerPreference()); }
- (void)manage:(id)sender {
    (void)sender;
    if (self.manageHandler) self.manageHandler(_documentID);
}
@end
