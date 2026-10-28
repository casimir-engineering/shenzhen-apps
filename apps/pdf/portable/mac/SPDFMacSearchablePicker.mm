#import "SPDFMacSearchablePicker.h"
#import "SPDFMacCollectionStyle.h"
@interface SPDFMacSearchablePicker () <NSTableViewDataSource,NSTableViewDelegate,NSTextFieldDelegate,NSSearchFieldDelegate>
@property(nonatomic) NSPopover* popover;
@property(nonatomic) NSSearchField* search;
@property(nonatomic) NSTableView* table;
@property(nonatomic) NSArray<NSDictionary*>* filtered;
@end
@implementation SPDFMacSearchablePicker
- (instancetype)initWithFrame:(NSRect)frame {
    if((self=[super initWithFrame:frame])) {
        self.bezelStyle=NSBezelStyleRounded; self.target=self; self.action=@selector(openPicker:);
        self.font=[NSFont systemFontOfSize:13]; self.alignment=NSTextAlignmentLeft;
        self.image=[NSImage imageWithSystemSymbolName:@"chevron.down" accessibilityDescription:nil];
        self.imagePosition=NSImageTrailing; self.imageScaling=NSImageScaleProportionallyDown;
        self.itemName=@"models"; self.accessibilityLabel=@"Choose model";
    } return self;
}
- (void)setSelectedID:(NSString*)value {
    _selectedID=[value copy]; NSString* title=value;
    for(NSDictionary* choice in self.choices) if([choice[@"id"] isEqual:value]) title=choice[@"name"] ?: value;
    self.title=title.length ? title : @"Choose model…";
    self.toolTip=value; self.cell.lineBreakMode=NSLineBreakByTruncatingMiddle;
}
- (void)openPicker:(id)sender {
    (void)sender;
    if(self.popover.shown) { [self.popover close]; return; }
    NSViewController* content=[NSViewController new]; content.view=[[NSView alloc] initWithFrame:NSMakeRect(0,0,410,330)];
    self.search=[[NSSearchField alloc] initWithFrame:NSMakeRect(12,290,386,28)];
    self.search.placeholderString=[@"Search " stringByAppendingString:self.itemName]; self.search.delegate=self;
    self.search.accessibilityLabel=[@"Search " stringByAppendingString:self.itemName];
    [content.view addSubview:self.search];
    NSScrollView* scroll=[[NSScrollView alloc] initWithFrame:NSMakeRect(8,8,394,274)]; scroll.hasVerticalScroller=YES;
    self.table=[[NSTableView alloc] initWithFrame:scroll.bounds];
    NSTableColumn* column=[[NSTableColumn alloc] initWithIdentifier:@"model"]; column.width=374;
    [self.table addTableColumn:column]; self.table.headerView=nil; self.table.rowHeight=44;
    self.table.dataSource=self; self.table.delegate=self; self.table.target=self; self.table.action=@selector(choose:);
    self.table.accessibilityLabel=[@"Available " stringByAppendingString:self.itemName]; scroll.documentView=self.table; [content.view addSubview:scroll];
    self.popover=[NSPopover new]; self.popover.behavior=NSPopoverBehaviorTransient; self.popover.contentViewController=content;
    [self refreshChoices]; [self.popover showRelativeToRect:self.bounds ofView:self preferredEdge:NSRectEdgeMaxY];
    [self.search.window makeFirstResponder:self.search]; if(self.opened) self.opened();
}
- (void)refreshChoices {
    NSString* query=self.search.stringValue.lowercaseString ?: @"";
    NSMutableArray* matches=[NSMutableArray array];
    for(NSDictionary* choice in self.choices) {
        NSString* words=[NSString stringWithFormat:@"%@ %@",choice[@"id"],choice[@"name"]];
        if(!query.length || [words localizedCaseInsensitiveContainsString:query]) [matches addObject:choice];
    }
    self.filtered=matches; [self.table reloadData];
    if(matches.count) {
        NSUInteger selected=0;
        if(!query.length) for(NSUInteger i=0;i<matches.count;i++)
            if([matches[i][@"id"] isEqual:self.selectedID]) { selected=i; break; }
        [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:selected] byExtendingSelection:NO];
        [self.table scrollRowToVisible:(NSInteger)selected];
    }
    [self setSelectedID:self.selectedID];
}
- (NSInteger)numberOfRowsInTableView:(NSTableView*)table { (void)table; return MAX((NSUInteger)1,self.filtered.count); }
- (NSView*)tableView:(NSTableView*)table viewForTableColumn:(NSTableColumn*)column row:(NSInteger)row {
    (void)table; (void)column;
    NSTextField* label=[NSTextField wrappingLabelWithString:@""];
    if(!self.filtered.count) {
        // A typed query must not disguise a loading/failed catalogue as a search miss.
        label.stringValue=self.choices.count && self.search.stringValue.length ? [@"No matching " stringByAppendingString:self.itemName] :
            (self.emptyMessage ?: [NSString stringWithFormat:@"No %@ available",self.itemName]);
        label.textColor=SPDFCollectionColor(@"secondary"); return label;
    }
    NSDictionary* choice=self.filtered[(NSUInteger)row];
    NSString* name=choice[@"name"] ?: choice[@"id"];
    NSMutableAttributedString* text=[[NSMutableAttributedString alloc] initWithString:name attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:13 weight:NSFontWeightMedium]}];
    [text appendAttributedString:[[NSAttributedString alloc] initWithString:[@"\n" stringByAppendingString:choice[@"id"]]
        attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:11],NSForegroundColorAttributeName:SPDFCollectionColor(@"secondary")}]];
    label.attributedStringValue=text; label.lineBreakMode=NSLineBreakByTruncatingTail; label.maximumNumberOfLines=2; return label;
}
- (void)controlTextDidChange:(NSNotification*)note { (void)note; [self refreshChoices]; }
- (BOOL)control:(NSControl*)control textView:(NSTextView*)textView doCommandBySelector:(SEL)command {
    (void)control; (void)textView;
    if(command==@selector(cancelOperation:)) { [self.popover close]; return YES; }
    if(command==@selector(insertNewline:)) { [self choose:nil]; return YES; }
    if(command==@selector(moveDown:) || command==@selector(moveUp:)) {
        NSInteger row=self.table.selectedRow+(command==@selector(moveDown:) ? 1 : -1);
        row=MAX(0,MIN((NSInteger)self.filtered.count-1,row));
        if(self.filtered.count) { [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO]; [self.table scrollRowToVisible:row]; }
        return YES;
    } return NO;
}
- (void)choose:(id)sender {
    (void)sender; NSInteger row=self.table.selectedRow;
    if(row<0 || row>=(NSInteger)self.filtered.count) return;
    NSString* identifier=self.filtered[(NSUInteger)row][@"id"];
    self.selectedID=identifier; [self.popover close]; if(self.selected) self.selected(identifier);
}
@end
