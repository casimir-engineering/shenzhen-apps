#import "SPDFMacTranslateLanguagePopover.h"
#import "SPDFMacAILanguage.h"

static NSString* const RecentKey=@"SPDFTranslateRecentLanguages";
static NSString* const EngineKey=@"SPDFTranslateEngine";  // "this-mac" or "ai"; "this-mac" until AI is chosen

NSArray<NSString*>* SPDFMacTranslateRecentLanguages(void) {
    NSArray* stored=[NSUserDefaults.standardUserDefaults arrayForKey:RecentKey];
    NSMutableArray* recent=[NSMutableArray array];
    for (id name in stored) if ([name isKindOfClass:NSString.class] && [name length] && recent.count<5) [recent addObject:name];
    return recent;
}
void SPDFMacTranslateRememberLanguage(NSString* language) {
    if (!language.length) return;
    NSMutableArray* recent=[SPDFMacTranslateRecentLanguages() mutableCopy];
    [recent removeObject:language]; [recent insertObject:language atIndex:0];
    while (recent.count>5) [recent removeLastObject];
    [NSUserDefaults.standardUserDefaults setObject:recent forKey:RecentKey];
}

// The highlighted language is drawn in the accent colour although the field, not the list, has the keyboard.
@interface SPDFMacTranslateLanguageRow : NSTableRowView
@end
@implementation SPDFMacTranslateLanguageRow
- (BOOL)isEmphasized { return YES; }
- (void)drawSelectionInRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [NSColor.selectedContentBackgroundColor setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,4,0) xRadius:5 yRadius:5] fill];
}
@end

@interface SPDFMacTranslateLanguagePopover () <NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSPopoverDelegate>
@end
@implementation SPDFMacTranslateLanguagePopover {
    void (^_translate)(NSString*, NSString*);
    NSArray<NSDictionary*>* _languages; // the engine's: {language: "French", title: "French · Français", code}
    NSArray<NSDictionary*>* _localLanguages, *_aiLanguages;
    id _keyMonitor;                     // ⌘1 and ⌘2 while the picker is open
    NSArray<NSDictionary*>* _rows;      // languages, and {header: "Recent"} between them when nothing is typed
    NSTableView* _table; NSTextField* _hint;
    NSString* _chosen;                  // set by Return on a typed search: the next Return translates into it
    BOOL _settingField;
}
static SPDFMacTranslateLanguagePopover* gShown;  // the popover on screen keeps its controller

+ (instancetype)shownPicker { return gShown; }
+ (instancetype)showRelativeToView:(NSView*)anchor localLanguages:(NSArray<NSDictionary<NSString*,NSString*>*>*)localLanguages
                         translate:(void (^)(NSString*, NSString*))translate {
    [gShown close];
    SPDFMacTranslateLanguagePopover* picker=[[self alloc] initWithLocalLanguages:localLanguages translate:translate];
    gShown=picker;
    [picker.popover showRelativeToRect:anchor.bounds ofView:anchor preferredEdge:NSRectEdgeMaxY];
    [picker.field.window makeFirstResponder:picker.field];
    __weak SPDFMacTranslateLanguagePopover* weakPicker=picker;
    picker->_keyMonitor=[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent*(NSEvent* event) {
        SPDFMacTranslateLanguagePopover* shown=weakPicker;
        NSEventModifierFlags flags=event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
        if (!shown || gShown!=shown || flags!=NSEventModifierFlagCommand) return event;
        if ([event.charactersIgnoringModifiers isEqual:@"1"]) { [shown chooseOnThisMac:YES]; return nil; }
        if ([event.charactersIgnoringModifiers isEqual:@"2"]) { [shown chooseOnThisMac:NO]; return nil; }
        return event;
    }];
    return picker;
}
// "French · Français" for a language the Mac's translator has; Chinese is the simplified script it writes.
static NSArray<NSDictionary*>* LocalRows(NSArray<NSDictionary<NSString*,NSString*>*>* languages) {
    NSMutableArray* rows=[NSMutableArray array]; NSDictionary* names=SPDFMacAILanguageNames();
    for (NSDictionary* language in languages) {
        NSString* code=language[@"code"]; if (!code.length) continue;
        NSString* locale=[code isEqual:@"zh"] ? @"zh-Hans" : code;
        NSString* english=names[locale] ?: language[@"name"] ?: code;
        NSString* native=[[[NSLocale alloc] initWithLocaleIdentifier:locale] localizedStringForLocaleIdentifier:locale];
        NSString* title=native.length && ![native isEqual:english] ? [NSString stringWithFormat:@"%@ · %@",english,native] : english;
        [rows addObject:@{@"language":english,@"title":title,@"code":code}];
    }
    return [rows sortedArrayUsingComparator:^NSComparisonResult(NSDictionary* a,NSDictionary* b){return [a[@"title"] compare:b[@"title"]];}];
}
- (instancetype)initWithLocalLanguages:(NSArray<NSDictionary<NSString*,NSString*>*>*)localLanguages
                             translate:(void (^)(NSString*, NSString*))translate {
    if (!(self=[super init])) return nil;
    _translate=[translate copy];
    NSMutableArray* languages=[NSMutableArray array];
    for (NSDictionary* choice in SPDFMacAILanguageChoices())
        [languages addObject:@{@"language":SPDFMacAILanguageName(choice[@"id"]),@"title":choice[@"name"],@"code":choice[@"id"]}];
    _aiLanguages=languages;
    _localLanguages=LocalRows(localLanguages);
    _onThisMac=![[NSUserDefaults.standardUserDefaults stringForKey:EngineKey] isEqual:@"ai"];
    _languages=_onThisMac ? _localLanguages : _aiLanguages;

    NSView* content=[[NSView alloc] initWithFrame:NSMakeRect(0,0,280,360)];
    _engine=[NSSegmentedControl segmentedControlWithLabels:@[@"On this Mac",@"AI"] trackingMode:NSSegmentSwitchTrackingSelectOne
        target:self action:@selector(engineClicked:)];
    _engine.segmentDistribution=NSSegmentDistributionFillEqually; _engine.refusesFirstResponder=YES;
    _engine.accessibilityLabel=@"Translate with";
    [_engine setToolTip:@"Translated on this Mac, offline (Tab or ⌘1)" forSegment:0];
    [_engine setToolTip:@"Translated by the assistant, with OpenRouter (Tab or ⌘2)" forSegment:1];
    _engine.selectedSegment=_onThisMac ? 0 : 1;
    _field=[NSSearchField new]; _field.placeholderString=@"Type a language"; _field.delegate=self;
    _field.accessibilityLabel=@"Translate into"; _field.sendsSearchStringImmediately=YES;
    _hint=[NSTextField labelWithString:@""]; _hint.lineBreakMode=NSLineBreakByTruncatingTail;
    NSScrollView* scroll=[NSScrollView new]; scroll.hasVerticalScroller=YES; scroll.drawsBackground=NO;
    _table=[NSTableView new]; _table.headerView=nil; _table.rowHeight=22; _table.intercellSpacing=NSMakeSize(0,2);
    _table.backgroundColor=NSColor.clearColor; _table.style=NSTableViewStyleSourceList;
    _table.floatsGroupRows=NO;  // "Recent" and "All languages" scroll with their rows
    [_table addTableColumn:[[NSTableColumn alloc] initWithIdentifier:@"language"]];
    _table.dataSource=self; _table.delegate=self; _table.target=self; _table.action=@selector(clicked:);
    _table.refusesFirstResponder=YES; _table.accessibilityLabel=@"Languages";
    scroll.documentView=_table;
    for (NSView* view in @[_engine,_field,_hint,scroll]) { view.translatesAutoresizingMaskIntoConstraints=NO; [content addSubview:view]; }
    [NSLayoutConstraint activateConstraints:@[
        [_engine.topAnchor constraintEqualToAnchor:content.topAnchor constant:12],
        [_engine.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:12],
        [_engine.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-12],
        [_field.topAnchor constraintEqualToAnchor:_engine.bottomAnchor constant:10],
        [_field.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:12],
        [_field.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-12],
        [_hint.topAnchor constraintEqualToAnchor:_field.bottomAnchor constant:7],
        [_hint.leadingAnchor constraintEqualToAnchor:_field.leadingAnchor constant:2],
        [_hint.trailingAnchor constraintEqualToAnchor:_field.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:_hint.bottomAnchor constant:6],
        [scroll.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:4],
        [scroll.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-4],
        [scroll.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-6]]];
    NSViewController* controller=[NSViewController new]; controller.view=content;
    _popover=[NSPopover new]; _popover.behavior=NSPopoverBehaviorTransient; _popover.contentViewController=controller;
    _popover.delegate=self;
    [self refresh];
    return self;
}
- (void)stopKeys { if (_keyMonitor) [NSEvent removeMonitor:_keyMonitor]; _keyMonitor=nil; }
- (void)close { [_popover close]; [self stopKeys]; if (gShown==self) gShown=nil; }
- (void)popoverDidClose:(NSNotification*)note { (void)note; [self stopKeys]; if (gShown==self) gShown=nil; }

#pragma mark Engine
- (void)chooseOnThisMac:(BOOL)onThisMac {
    _engine.selectedSegment=onThisMac ? 0 : 1;
    if (_onThisMac==onThisMac) return;
    _onThisMac=onThisMac; _languages=onThisMac ? _localLanguages : _aiLanguages;
    [NSUserDefaults.standardUserDefaults setObject:onThisMac ? @"this-mac" : @"ai" forKey:EngineKey];
    // A language chosen that this engine can't do is chosen no longer.
    if (_chosen && onThisMac && ![self rowForLanguage:_chosen]) _chosen=nil;
    [self refresh];
}
- (void)switchEngine { [self chooseOnThisMac:!_onThisMac]; }
- (void)engineClicked:(id)sender {
    (void)sender; [self chooseOnThisMac:_engine.selectedSegment==0];
    [_field.window makeFirstResponder:_field];
}

#pragma mark Rows
- (NSString*)query {
    return [_field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}
// The engine's row for a language; one made of the name for AI, nil when this Mac doesn't have it.
- (NSDictionary*)rowForLanguage:(NSString*)language {
    for (NSDictionary* row in _languages) if ([row[@"language"] isEqual:language]) return row;
    return _onThisMac ? nil : @{@"language":language,@"title":language};
}
// 0 for a name starting with the query, 1 for a word in it starting with it, 2 for the query anywhere, NSNotFound none.
static NSUInteger Match(NSDictionary* row, NSString* query) {
    NSStringCompareOptions options=NSCaseInsensitiveSearch|NSDiacriticInsensitiveSearch;
    if ([row[@"language"] rangeOfString:query options:options|NSAnchoredSearch].location!=NSNotFound ||
        [row[@"code"] ?: @"" compare:query options:options]==NSOrderedSame) return 0;
    for (NSString* word in [row[@"title"] componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet])
        if ([word rangeOfString:query options:options|NSAnchoredSearch].location!=NSNotFound) return 1;
    return [row[@"title"] rangeOfString:query options:options].location!=NSNotFound ? 2 : NSNotFound;
}
- (void)refresh {
    NSString* query=[self query]; NSMutableArray* rows=[NSMutableArray array];
    NSMutableArray* recent=[NSMutableArray array];
    for (NSString* language in SPDFMacTranslateRecentLanguages()) { NSDictionary* row=[self rowForLanguage:language]; if (row) [recent addObject:row]; }
    NSInteger highlighted=-1;
    if (!query.length) {
        if (recent.count) { [rows addObject:@{@"header":@"Recent"}]; [rows addObjectsFromArray:recent];
            [rows addObject:@{@"header":@"All languages"}]; }
        [rows addObjectsFromArray:_languages];
        // English unless something else was chosen: Return straight away translates into it.
        NSString* wanted=_chosen ?: @"English";
        for (NSUInteger i=0;i<rows.count;i++) if ([rows[i][@"language"] isEqual:wanted]) { highlighted=(NSInteger)i; break; }
    } else {
        NSMutableArray* tiers=[NSMutableArray arrayWithObjects:[NSMutableArray array],[NSMutableArray array],[NSMutableArray array],nil];
        NSMutableSet* seen=[NSMutableSet set];
        for (NSDictionary* row in [recent arrayByAddingObjectsFromArray:_languages]) {
            NSUInteger tier=Match(row,query);
            if (tier==NSNotFound || [seen containsObject:row[@"language"]]) continue;
            [seen addObject:row[@"language"]]; [tiers[tier] addObject:row];
        }
        for (NSArray* tier in tiers) [rows addObjectsFromArray:tier];
        // Nothing in the list: the name as typed, so any language can be asked for.
        if (!rows.count && !_onThisMac) [rows addObject:@{@"language":query,@"title":[NSString stringWithFormat:@"Use “%@”",query],@"typed":@YES}];
        highlighted=rows.count ? 0 : -1;
        if (_chosen) for (NSUInteger i=0;i<rows.count;i++) if ([rows[i][@"language"] isEqual:_chosen]) { highlighted=(NSInteger)i; break; }
    }
    _rows=rows; [_table reloadData];
    if (highlighted>=0) {
        [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)highlighted] byExtendingSelection:NO];
        [_table scrollRowToVisible:highlighted];
    }
    [self showHint];
}
- (NSDictionary*)highlighted {
    NSInteger row=_table.selectedRow;
    return row>=0 && row<(NSInteger)_rows.count && !_rows[(NSUInteger)row][@"header"] ? _rows[(NSUInteger)row] : nil;
}
// What Return does now: translate when nothing is typed or a language was just chosen, otherwise choose.
- (BOOL)returnTranslates { return ![self query].length || _chosen!=nil; }
- (void)showHint {
    NSString* language=[self highlighted][@"language"];
    NSFont* font=[NSFont systemFontOfSize:12];
    NSMutableAttributedString* hint=[[NSMutableAttributedString alloc] initWithString:@"⏎ " attributes:@{
        NSFontAttributeName:font,NSForegroundColorAttributeName:NSColor.secondaryLabelColor}];
    if (!language) {
        // Typed a language this Mac's translator doesn't have.
        if (_onThisMac && [self query].length) [hint appendAttributedString:[[NSAttributedString alloc] initWithString:
            @"Not on this Mac. Tab translates with AI." attributes:@{NSFontAttributeName:font,
            NSForegroundColorAttributeName:NSColor.secondaryLabelColor}]];
        _hint.attributedStringValue=hint; return;
    }
    BOOL translates=[self returnTranslates];
    [hint appendAttributedString:[[NSAttributedString alloc] initWithString:translates ? @"translates into " : @"chooses "
        attributes:@{NSFontAttributeName:font,NSForegroundColorAttributeName:NSColor.secondaryLabelColor}]];
    [hint appendAttributedString:[[NSAttributedString alloc] initWithString:language attributes:@{
        NSFontAttributeName:[NSFont systemFontOfSize:12 weight:translates ? NSFontWeightSemibold : NSFontWeightRegular],
        NSForegroundColorAttributeName:NSColor.labelColor}]];
    _hint.attributedStringValue=hint;
}

#pragma mark Keyboard and clicks
- (void)pressReturn {
    NSDictionary* row=[self highlighted]; if (!row) { NSBeep(); return; }
    if ([self returnTranslates]) { [self translateInto:row]; return; }
    _chosen=row[@"language"];
    _settingField=YES; _field.stringValue=_chosen; _settingField=NO;
    [[_field currentEditor] setSelectedRange:NSMakeRange(_field.stringValue.length,0)];
    [self refresh];
}
- (void)moveSelection:(NSInteger)delta {
    NSInteger row=_table.selectedRow;
    for (NSInteger next=row+delta;next>=0 && next<(NSInteger)_rows.count;next+=delta)
        if (!_rows[(NSUInteger)next][@"header"]) { row=next; break; }
    if (row<0) return;
    // A language moved away from is no longer the chosen one: Return chooses again.
    if (_chosen && [self query].length) _chosen=nil;
    [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
    [_table scrollRowToVisible:row]; [self showHint];
}
- (void)clicked:(id)sender {
    (void)sender; NSInteger row=_table.clickedRow;
    if (row<0 || row>=(NSInteger)_rows.count || _rows[(NSUInteger)row][@"header"]) return;
    [self translateInto:_rows[(NSUInteger)row]];
}
- (void)translateInto:(NSDictionary*)row {
    void (^translate)(NSString*, NSString*)=_translate; _translate=nil;
    SPDFMacTranslateLanguagePopover* keep=self; [self close];
    SPDFMacTranslateRememberLanguage(row[@"language"]);
    if (translate) translate(row[@"language"],_onThisMac ? row[@"code"] : nil);
    (void)keep;
}
- (void)controlTextDidChange:(NSNotification*)note {
    (void)note; if (_settingField) return;
    _chosen=nil; [self refresh];
}
- (BOOL)control:(NSControl*)control textView:(NSTextView*)textView doCommandBySelector:(SEL)command {
    (void)control; (void)textView;
    if (command==@selector(insertNewline:)) { [self pressReturn]; return YES; }
    if (command==@selector(cancelOperation:)) { [self close]; return YES; }
    if (command==@selector(moveDown:)) { [self moveSelection:1]; return YES; }
    if (command==@selector(moveUp:)) { [self moveSelection:-1]; return YES; }
    if (command==@selector(insertTab:) || command==@selector(insertBacktab:)) { [self switchEngine]; return YES; }
    return NO;
}

#pragma mark Table
- (NSInteger)numberOfRowsInTableView:(NSTableView*)table { (void)table; return (NSInteger)_rows.count; }
- (BOOL)tableView:(NSTableView*)table isGroupRow:(NSInteger)row { (void)table; return _rows[(NSUInteger)row][@"header"]!=nil; }
- (BOOL)tableView:(NSTableView*)table shouldSelectRow:(NSInteger)row { (void)table; return !_rows[(NSUInteger)row][@"header"]; }
- (NSTableRowView*)tableView:(NSTableView*)table rowViewForRow:(NSInteger)row {
    (void)table; (void)row; return [SPDFMacTranslateLanguageRow new];
}
- (NSView*)tableView:(NSTableView*)table viewForTableColumn:(NSTableColumn*)column row:(NSInteger)index {
    (void)table; (void)column; NSDictionary* row=_rows[(NSUInteger)index];
    NSTextField* label=[NSTextField labelWithString:row[@"header"] ?: row[@"title"]];
    label.lineBreakMode=NSLineBreakByTruncatingTail;
    label.font=row[@"header"] ? [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold] : [NSFont systemFontOfSize:13];
    if (row[@"header"]) label.textColor=NSColor.secondaryLabelColor;
    NSTableCellView* cell=[NSTableCellView new]; cell.textField=label;
    label.translatesAutoresizingMaskIntoConstraints=NO; [cell addSubview:label];
    [NSLayoutConstraint activateConstraints:@[[label.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:6],
        [label.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-6],
        [label.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor]]];
    return cell;
}
- (void)tableViewSelectionDidChange:(NSNotification*)note { (void)note; [self showHint]; }
@end
