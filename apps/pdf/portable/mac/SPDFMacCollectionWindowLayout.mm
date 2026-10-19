#import "SPDFMacCollectionWindowPrivate.h"
#import "SPDFMacCollectionStyle.h"

static NSTextField* Label(NSString* text, CGFloat size, NSFontWeight weight) {
    NSTextField* field = [NSTextField wrappingLabelWithString:text];
    field.font = [NSFont systemFontOfSize:size weight:weight]; return field;
}
static NSStackView* Stack(BOOL horizontal) {
    NSStackView* stack = [NSStackView stackViewWithViews:@[]];
    stack.orientation = horizontal ? NSUserInterfaceLayoutOrientationHorizontal : NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = horizontal ? NSLayoutAttributeCenterY : NSLayoutAttributeLeading;
    stack.distribution = NSStackViewDistributionFill;
    stack.spacing = 10; return stack;
}
static void Fill(NSView* child, NSView* parent) {
    child.translatesAutoresizingMaskIntoConstraints = NO; [parent addSubview:child];
    [NSLayoutConstraint activateConstraints:@[
        [child.leadingAnchor constraintEqualToAnchor:parent.leadingAnchor],
        [child.trailingAnchor constraintEqualToAnchor:parent.trailingAnchor],
        [child.topAnchor constraintEqualToAnchor:parent.topAnchor],
        [child.bottomAnchor constraintEqualToAnchor:parent.bottomAnchor]]];
}
@implementation SPDFMacCollectionWindow (Layout)
- (void)buildManagerLayout {
    NSDictionary* preferences = self.store.settings;
    self.window.backgroundColor = SPDFCollectionColor(@"window");
    NSView* root = SPDFCollectionSurface(@"window"); Fill(root,self.window.contentView);
    NSView* header = SPDFCollectionSurface(@"window"); header.translatesAutoresizingMaskIntoConstraints = NO;
    header.identifier = @"CollectionHeader"; [root addSubview:header];
    NSImageView* library = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"books.vertical" accessibilityDescription:nil]];
    library.translatesAutoresizingMaskIntoConstraints = NO; [header addSubview:library];
    NSTextField* heading = SPDFCollectionText(@"Collection",13,NSFontWeightSemibold,NO);
    heading.translatesAutoresizingMaskIntoConstraints = NO; [header addSubview:heading];
    NSButton* back = SPDFCollectionButton(@"Return to reader",self,@selector(returnToReader:),@"quiet");
    back.image = [NSImage imageWithSystemSymbolName:@"arrow.uturn.backward" accessibilityDescription:nil];
    back.translatesAutoresizingMaskIntoConstraints = NO; [header addSubview:back];
    NSButton* options = SPDFCollectionButton(@"",self,@selector(showViewOptions:),@"quiet");
    options.image = [NSImage imageWithSystemSymbolName:@"slider.horizontal.3" accessibilityDescription:nil];
    options.toolTip = @"Collection view options"; options.accessibilityLabel = options.toolTip;
    options.translatesAutoresizingMaskIntoConstraints = NO; [header addSubview:options];
    NSView* headerLine = SPDFCollectionDivider(); headerLine.translatesAutoresizingMaskIntoConstraints = NO; [header addSubview:headerLine];
    [NSLayoutConstraint activateConstraints:@[
        [header.leadingAnchor constraintEqualToAnchor:root.leadingAnchor], [header.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [header.topAnchor constraintEqualToAnchor:root.topAnchor], [header.heightAnchor constraintEqualToConstant:48],
        [library.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:78], [library.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [library.widthAnchor constraintEqualToConstant:16], [library.heightAnchor constraintEqualToConstant:16],
        [heading.leadingAnchor constraintEqualToAnchor:library.trailingAnchor constant:8], [heading.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [back.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-14], [back.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [options.trailingAnchor constraintEqualToAnchor:back.leadingAnchor constant:-8], [options.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [options.widthAnchor constraintEqualToConstant:30],
        [headerLine.leadingAnchor constraintEqualToAnchor:header.leadingAnchor], [headerLine.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
        [headerLine.bottomAnchor constraintEqualToAnchor:header.bottomAnchor]]];
    NSView* sidebar = SPDFCollectionSurface(@"sidebar"); sidebar.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:sidebar];
    [NSLayoutConstraint activateConstraints:@[[sidebar.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [sidebar.topAnchor constraintEqualToAnchor:header.bottomAnchor],[sidebar.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [sidebar.widthAnchor constraintEqualToConstant:125]]];
    NSStackView* navigation = Stack(NO); navigation.spacing = 4; navigation.translatesAutoresizingMaskIntoConstraints = NO;
    [sidebar addSubview:navigation];
    [NSLayoutConstraint activateConstraints:@[[navigation.leadingAnchor constraintEqualToAnchor:sidebar.leadingAnchor constant:8],
        [navigation.trailingAnchor constraintEqualToAnchor:sidebar.trailingAnchor constant:-8],
        [navigation.topAnchor constraintEqualToAnchor:sidebar.topAnchor constant:10]]];
    self.documentsButton = SPDFCollectionButton(@"Documents",self,@selector(navigate:),@"nav");
    self.settingsButton = SPDFCollectionButton(@"Settings",self,@selector(navigate:),@"nav");
    self.documentsButton.image = [NSImage imageWithSystemSymbolName:@"doc.on.doc" accessibilityDescription:nil];
    self.settingsButton.image = [NSImage imageWithSystemSymbolName:@"gearshape" accessibilityDescription:nil];
    self.documentsButton.accessibilityLabel = @"Documents"; self.settingsButton.accessibilityLabel = @"Settings";
    for (NSButton* button in @[self.documentsButton,self.settingsButton]) {
        button.buttonType = NSButtonTypePushOnPushOff; [navigation addArrangedSubview:button];
        [button.widthAnchor constraintEqualToAnchor:navigation.widthAnchor].active = YES;
        [button.heightAnchor constraintEqualToConstant:30].active = YES;
    }
    NSView* sidebarLine = SPDFCollectionSurface(@"line"); sidebarLine.translatesAutoresizingMaskIntoConstraints = NO;
    [sidebar addSubview:sidebarLine]; [NSLayoutConstraint activateConstraints:@[
        [sidebarLine.trailingAnchor constraintEqualToAnchor:sidebar.trailingAnchor], [sidebarLine.topAnchor constraintEqualToAnchor:sidebar.topAnchor],
        [sidebarLine.bottomAnchor constraintEqualToAnchor:sidebar.bottomAnchor],[sidebarLine.widthAnchor constraintEqualToConstant:1]]];
    self.contentHost = [NSView new]; self.contentHost.translatesAutoresizingMaskIntoConstraints = NO; [root addSubview:self.contentHost];
    [NSLayoutConstraint activateConstraints:@[[self.contentHost.leadingAnchor constraintEqualToAnchor:sidebar.trailingAnchor],
        [self.contentHost.trailingAnchor constraintEqualToAnchor:root.trailingAnchor], [self.contentHost.topAnchor constraintEqualToAnchor:header.bottomAnchor],
        [self.contentHost.bottomAnchor constraintEqualToAnchor:root.bottomAnchor]]];
    NSStackView* documents = Stack(NO); documents.spacing = 0; self.documentsPane = documents; Fill(documents,self.contentHost);
    NSStackView* toolbar = Stack(NO); toolbar.spacing = 10; toolbar.edgeInsets = NSEdgeInsetsMake(14,14,13,14);
    [documents addArrangedSubview:toolbar]; [toolbar.widthAnchor constraintEqualToAnchor:documents.widthAnchor].active = YES;
    self.search = SPDFCollectionSearchField(); self.search.placeholderString = @"Search Collection titles and text";
    self.search.stringValue = [preferences[@"managerQuery"] isKindOfClass:NSString.class] ? preferences[@"managerQuery"] : @"";
    self.search.target = self; self.search.action = @selector(reload:); self.search.sendsSearchStringImmediately = YES;
    [toolbar addArrangedSubview:self.search]; [self.search.widthAnchor constraintEqualToAnchor:toolbar.widthAnchor constant:-28].active = YES;
    [self.search.heightAnchor constraintEqualToConstant:31].active = YES;
    self.viewPicker = SPDFCollectionPopUp();
    [self.viewPicker addItemsWithTitles:@[@"All Documents",@"Originals Unavailable",@"Kept histories",@"Saving paused"]];
    NSArray<NSNumber*>* filterTags = @[@0,@2,@3,@4];
    for (NSUInteger index=0;index<filterTags.count;index++) [self.viewPicker itemAtIndex:index].tag = filterTags[index].integerValue;
    NSInteger restoredFilter = [preferences[@"managerView"] integerValue];
    if (![filterTags containsObject:@(restoredFilter)]) restoredFilter = 0;
    [self.viewPicker selectItemWithTag:restoredFilter];
    self.viewPicker.target = self; self.viewPicker.action = @selector(reload:);
    // View controls remain persisted and accessible from the compact header menu.
    self.resultSummary = SPDFCollectionText(@"",11,NSFontWeightRegular,YES);
    self.resultSummary.hidden = YES;
    self.sortPicker = SPDFCollectionPopUp(); [self.sortPicker addItemsWithTitles:@[@"Newest first",@"Oldest first",@"Name"]];
    [self.sortPicker selectItemAtIndex:MIN(2,MAX(0,[preferences[@"managerSort"] integerValue]))];
    self.listScroll = [NSScrollView new]; self.listScroll.hasVerticalScroller = YES; self.listScroll.borderType = NSNoBorder;
    self.listScroll.drawsBackground = NO;
    self.table = [NSTableView new]; self.table.style = NSTableViewStylePlain;
    self.table.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle; self.table.headerView = nil; self.table.rowHeight = 116;
    self.table.backgroundColor = SPDFCollectionColor(@"window"); self.table.intercellSpacing = NSMakeSize(0,0);
    self.table.allowsMultipleSelection = YES; self.table.dataSource = self; self.table.delegate = self;
    self.table.target = self; self.table.doubleAction = @selector(preview:);
    NSTableColumn* column = [[NSTableColumn alloc] initWithIdentifier:@"document"]; column.width = 650; column.resizingMask = NSTableColumnAutoresizingMask;
    [self.table addTableColumn:column]; self.listScroll.documentView = self.table;
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Document actions"]; menu.delegate = (id)self; self.table.menu = menu;
    NSView* results = [NSView new]; [documents addArrangedSubview:results]; Fill(self.listScroll,results);
    [self initializeThumbnails];
    self.resultSummary.translatesAutoresizingMaskIntoConstraints = NO; [results addSubview:self.resultSummary];
    [NSLayoutConstraint activateConstraints:@[[self.resultSummary.leadingAnchor constraintEqualToAnchor:results.leadingAnchor constant:14],
        [self.resultSummary.topAnchor constraintEqualToAnchor:results.topAnchor constant:14]]];
    [results.widthAnchor constraintEqualToAnchor:documents.widthAnchor].active = YES;
    [results.bottomAnchor constraintEqualToAnchor:documents.bottomAnchor].active = YES;
    // Existing command availability remains shared by the accessible contextual menu.
    self.details = Label(@"Select a document or version.",12,NSFontWeightRegular);
    self.selectionButtons = [NSMutableArray array];
    NSArray* titles = @[@"Open Original",@"Open Collection Copy",@"History",@"Compare with Previous",
        @"Locate Original…",@"Save a Copy…",@"Keep forever",@"Delete all previous backups…"];
    NSArray* actions = @[@"openOriginal:",@"preview:",@"history:",@"comparePrevious:",@"locate:",
        @"exportCopy:",@"keep:",@"deleteSelected:"];
    for (NSUInteger i=0;i<titles.count;i++) [self.selectionButtons addObject:SPDFCollectionButton(titles[i],self,NSSelectorFromString(actions[i]),@"normal")];
    [self buildSettingsPane];
    [self showDestination:[preferences[@"managerDestination"] isEqual:@"Settings"] ? @"Settings" : @"Documents"];
}
- (void)returnToReader:(id)sender {
    (void)sender;
    if (self.returnHandler) self.returnHandler(); else [self.window orderBack:nil];
}
- (NSMenu*)collectionViewOptionsMenu {
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Collection view options"];
    NSArray* pickers = @[self.viewPicker,self.sortPicker];
    NSArray* headings = @[@"Show",@"Sort"];
    for (NSUInteger group=0;group<pickers.count;group++) {
        NSMenuItem* heading = [[NSMenuItem alloc] initWithTitle:headings[group] action:nil keyEquivalent:@""];
        NSMenu* submenu = [[NSMenu alloc] initWithTitle:headings[group]];
        NSPopUpButton* picker = pickers[group];
        for (NSInteger index=0;index<picker.numberOfItems;index++) {
            NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:[picker itemTitleAtIndex:index]
                action:@selector(changeViewOption:) keyEquivalent:@""];
            item.target = self; item.representedObject = @[@(group),@(index)];
            item.state = picker.indexOfSelectedItem == index ? NSControlStateValueOn : NSControlStateValueOff;
            [submenu addItem:item];
        }
        heading.submenu = submenu; [menu addItem:heading];
    }
    return menu;
}
- (void)showViewOptions:(NSControl*)sender {
    [[self collectionViewOptionsMenu] popUpMenuPositioningItem:nil atLocation:NSMakePoint(0,NSHeight(sender.bounds)) inView:sender];
}
- (void)changeViewOption:(NSMenuItem*)sender {
    NSArray* value = sender.representedObject;
    NSPopUpButton* picker = @[self.viewPicker,self.sortPicker][[value[0] unsignedIntegerValue]];
    [picker selectItemAtIndex:[value[1] integerValue]]; [self reload:picker];
}
- (void)navigate:(id)sender {
    [self showDestination:sender == self.settingsButton ? @"Settings" : @"Documents"];
    [self persistManagerPreferences];
}
- (void)showDestination:(NSString*)destination {
    self.destination = destination;
    self.documentsPane.hidden = ![destination isEqual:@"Documents"];
    self.settingsPane.hidden = ![destination isEqual:@"Settings"];
    self.historyPane.hidden = ![destination isEqual:@"History"];
    self.documentsButton.state = [destination isEqual:@"Settings"] ? NSControlStateValueOff : NSControlStateValueOn;
    self.settingsButton.state = [destination isEqual:@"Settings"] ? NSControlStateValueOn : NSControlStateValueOff;
}
- (void)persistManagerPreferences {
    NSDictionary* preferences = @{@"managerView":@(self.viewPicker.selectedItem.tag),
        @"managerSort":@(self.sortPicker.indexOfSelectedItem),
        @"managerDestination":self.destination ?: @"Documents", @"managerQuery":self.search.stringValue,
        @"managerSearchScope":@0, @"managerBrowseState":[self captureBrowseState]};
    dispatch_async(self.preferenceQueue, ^{
        NSError* error = nil; [self.store updateSettings:preferences error:&error];
        if (error) dispatch_async(dispatch_get_main_queue(),^{ [self showError:error]; });
    });
}
@end
