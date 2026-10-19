#import "SPDFMacAIChatHistoryView.h"
#import "SPDFMacPanelSearchField.h"
#import "SPDFMacGroupActionButton.h"
#import "SPDFMacCollectionStyle.h"
@interface SPDFChatHistoryTable : NSTableView
@property(copy) void (^openSelection)(NSInteger);
@property(copy) NSMenu* (^contextMenu)(NSInteger);
@end
@implementation SPDFChatHistoryTable
- (void)keyDown:(NSEvent*)event {
    if((event.keyCode==36 || event.keyCode==76) && self.selectedRow>=0) {if(self.openSelection)self.openSelection(self.selectedRow);return;}
    [super keyDown:event];
}
- (NSMenu*)menuForEvent:(NSEvent*)event {
    NSInteger row=[self rowAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    return self.contextMenu ? self.contextMenu(row) : [super menuForEvent:event];
}
@end
static NSAttributedString* HistoryText(NSString* text, NSString* query, NSFont* font, NSColor* color) {
    NSMutableParagraphStyle* paragraph=[NSMutableParagraphStyle new];paragraph.lineBreakMode=NSLineBreakByTruncatingTail;
    NSMutableAttributedString* result=[[NSMutableAttributedString alloc] initWithString:text ?: @"" attributes:@{NSFontAttributeName:font,NSForegroundColorAttributeName:color,NSParagraphStyleAttributeName:paragraph}];
    if(query.length) {
        NSRange remaining=NSMakeRange(0,result.length);
        while(remaining.length) {
            NSRange match=[result.string rangeOfString:query options:NSCaseInsensitiveSearch|NSDiacriticInsensitiveSearch range:remaining];
            if(match.location==NSNotFound)break;
            [result addAttributes:@{NSBackgroundColorAttributeName:[NSColor.controlAccentColor colorWithAlphaComponent:.25],NSForegroundColorAttributeName:SPDFCollectionColor(@"text")} range:match];
            remaining=NSMakeRange(NSMaxRange(match),result.length-NSMaxRange(match));
        }
    }
    return result;
}
// Preserve nearby context without spending both visible lines before the hit.
static NSString* HistorySnippet(NSString* text,NSString* query,CGFloat width,NSFont* font) {
    NSRange match=query.length ? [text rangeOfString:query options:NSCaseInsensitiveSearch|NSDiacriticInsensitiveSearch] : NSMakeRange(NSNotFound,0);
    if(match.location==NSNotFound || match.location==0)return text;
    NSUInteger start=match.location;CGFloat budget=MAX(12,MIN(70,width*.35));
    while(start>0) {
        NSRange previous=[text rangeOfComposedCharacterSequenceAtIndex:start-1];
        NSString* prefix=[text substringWithRange:NSMakeRange(previous.location,match.location-previous.location)];
        if([prefix sizeWithAttributes:@{NSFontAttributeName:font}].width>budget)break;
        start=previous.location;
    }
    return start ? [@"…" stringByAppendingString:[text substringFromIndex:start]] : text;
}
@interface SPDFChatHistoryRow : NSTableRowView
@end
@implementation SPDFChatHistoryRow
- (NSBackgroundStyle)interiorBackgroundStyle {return NSBackgroundStyleNormal;}
- (void)drawBackgroundInRect:(NSRect)dirty {[SPDFCollectionColor(@"window") setFill];NSRectFill(dirty);}
- (void)drawSelectionInRect:(NSRect)dirty {
    (void)dirty;[SPDFCollectionColor(@"selected") setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,3,1) xRadius:6 yRadius:6] fill];
}
@end
@implementation SPDFMacAIChatHistoryView {
    NSSearchField* _search; NSTableView* _table; NSArray* _chats; NSArray* _folders; NSArray* _rows;
    NSTextField* _editor; NSString* _editingID; BOOL _editingFolder;
    NSTextField* _empty; NSString* _selectedID; NSDateFormatter* _dateFormatter;
}
- (BOOL)isFlipped {return YES;}
- (void)drawRect:(NSRect)dirty {(void)dirty;[SPDFCollectionColor(@"window") setFill];NSRectFill(self.bounds);}
- (void)viewDidChangeEffectiveAppearance {[super viewDidChangeEffectiveAppearance];self.needsDisplay=YES;[self rebuildRows];}
- (NSSearchField*)search {return _search;}
- (void)setFrameSize:(NSSize)size {BOOL changed=fabs(self.frame.size.width-size.width)>1;[super setFrameSize:size];if(changed && _table)[self rebuildRows];}
- (NSButton*)headerButton:(NSString*)symbol label:(NSString*)label action:(SEL)action {
    NSButton* button=[SPDFGroupActionButton buttonWithImage:[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil] target:self action:action];
    button.bordered=NO;button.imageScaling=NSImageScaleProportionallyDown;button.toolTip=label;button.accessibilityLabel=label;
    button.translatesAutoresizingMaskIntoConstraints=NO;[self addSubview:button];return button;
}
- (instancetype)initWithFrame:(NSRect)frame {
    if(!(self=[super initWithFrame:frame]))return nil;
    _chats=@[];_folders=@[];_rows=@[];
    _dateFormatter=[NSDateFormatter new];_dateFormatter.dateStyle=NSDateFormatterMediumStyle;
    _dateFormatter.timeStyle=NSDateFormatterShortStyle;_dateFormatter.doesRelativeDateFormatting=YES;
    _search=[NSSearchField new];SPDFConfigurePanelSearchField(_search);_search.placeholderString=@"Search chats";
    _search.accessibilityLabel=@"Search previous chats";_search.delegate=self;_search.translatesAutoresizingMaskIntoConstraints=NO;[self addSubview:_search];
    NSButton* folder=[self headerButton:@"folder.badge.plus" label:@"New folder" action:@selector(newFolder:)];
    NSButton* add=[self headerButton:@"square.and.pencil" label:@"New chat" action:@selector(newChat:)];
    NSScrollView* scroll=[NSScrollView new];scroll.hasVerticalScroller=YES;scroll.autohidesScrollers=YES;scroll.drawsBackground=NO;
    scroll.translatesAutoresizingMaskIntoConstraints=NO;[self addSubview:scroll];
    _table=[SPDFChatHistoryTable new];_table.headerView=nil;_table.backgroundColor=NSColor.clearColor;
    _table.intercellSpacing=NSMakeSize(0,2);_table.style=NSTableViewStylePlain;
    NSTableColumn* column=[[NSTableColumn alloc] initWithIdentifier:@"chat"];column.resizingMask=NSTableColumnAutoresizingMask;
    [_table addTableColumn:column];_table.columnAutoresizingStyle=NSTableViewUniformColumnAutoresizingStyle;
    [_table registerForDraggedTypes:@[@"com.intuition.shenzhenpdf.chat"]];
    [_table setDraggingSourceOperationMask:NSDragOperationMove forLocal:YES];
    _table.dataSource=self;_table.delegate=self;_table.target=self;_table.action=@selector(openChat:);scroll.documentView=_table;
    __weak SPDFMacAIChatHistoryView* owner=self;
    ((SPDFChatHistoryTable*)_table).openSelection=^(NSInteger row){[owner activateRow:row];};
    ((SPDFChatHistoryTable*)_table).contextMenu=^NSMenu*(NSInteger row){return [owner menuForRow:row];};
    _empty=SPDFCollectionText(@"No chats yet. Start one with New chat or ⌘K, then Return.",12,NSFontWeightRegular,YES);
    _empty.translatesAutoresizingMaskIntoConstraints=NO;[self addSubview:_empty];
    [NSLayoutConstraint activateConstraints:@[
        [_search.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:8],[_search.topAnchor constraintEqualToAnchor:self.topAnchor constant:8],
        [_search.heightAnchor constraintEqualToConstant:30],[_search.trailingAnchor constraintEqualToAnchor:folder.leadingAnchor constant:-4],
        [folder.trailingAnchor constraintEqualToAnchor:add.leadingAnchor constant:-2],[folder.centerYAnchor constraintEqualToAnchor:_search.centerYAnchor],
        [folder.widthAnchor constraintEqualToConstant:28],[folder.heightAnchor constraintEqualToConstant:28],
        [add.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8],[add.centerYAnchor constraintEqualToAnchor:_search.centerYAnchor],
        [add.widthAnchor constraintEqualToConstant:28],[add.heightAnchor constraintEqualToConstant:28],
        [scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:4],[scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-4],
        [scroll.topAnchor constraintEqualToAnchor:_search.bottomAnchor constant:8],[scroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_empty.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],[_empty.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        [_empty.topAnchor constraintEqualToAnchor:_search.bottomAnchor constant:24]]];return self;
}
- (void)rebuildRows {
    if(!_chats || _editor)return;
    NSMutableArray* rows=[NSMutableArray array];BOOL searching=_search.stringValue.length>0;
    NSMutableArray* groups=[_folders mutableCopy];
    BOOL hasGeneral=NO;for(NSDictionary* group in groups)if(![group[@"id"] length])hasGeneral=YES;
    if(!hasGeneral)[groups insertObject:@{@"id":@"",@"name":@"General",@"collapsed":@NO} atIndex:0];
    NSSet* known=[NSSet setWithArray:[groups valueForKey:@"id"]];
    for(NSDictionary* group in groups) {
        NSString* identifier=group[@"id"];NSMutableArray* contents=[NSMutableArray array];
        for(NSDictionary* chat in _chats) {
            NSString* folder=chat[@"folder"] ?: @"";
            if(![known containsObject:folder])folder=@"";
            if([folder isEqual:identifier])[contents addObject:chat];
        }
        if(!contents.count && searching)continue;
        [rows addObject:@{@"folderHeader":@YES,@"id":identifier,@"name":group[@"name"] ?: @"Folder",
            @"collapsed":@(searching ? NO : [group[@"collapsed"] boolValue]),@"count":@(contents.count)}];
        if(searching || ![group[@"collapsed"] boolValue])[rows addObjectsFromArray:contents];
    }
    _rows=rows;[_table reloadData];[_table deselectAll:nil];_empty.hidden=_rows.count>0;
    _empty.stringValue=searching ? @"No matching chats" : @"No chats yet. Start one with New chat or ⌘K, then Return.";
    for(NSUInteger i=0;i<_rows.count;i++)if(![_rows[i][@"folderHeader"] boolValue] && [_rows[i][@"id"] isEqual:_selectedID])
        [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];
}
- (void)displayFolders:(NSArray*)folders {_folders=[folders copy] ?: @[];[self rebuildRows];}
- (void)displayChats:(NSArray*)chats selectedID:(NSString*)identifier {_chats=[chats copy] ?: @[];_selectedID=[identifier copy];[self rebuildRows];}
- (NSInteger)numberOfRowsInTableView:(NSTableView*)table {(void)table;return _rows.count;}
- (CGFloat)tableView:(NSTableView*)table heightOfRow:(NSInteger)row {
    (void)table;NSDictionary* item=_rows[(NSUInteger)row];return [item[@"folderHeader"] boolValue] ? 32 : ([item[@"snippet"] length] ? 88 : 50);
}
- (NSTableRowView*)tableView:(NSTableView*)table rowViewForRow:(NSInteger)row {(void)table;(void)row;return [SPDFChatHistoryRow new];}
- (NSTextField*)label:(NSString*)text size:(CGFloat)size weight:(NSFontWeight)weight secondary:(BOOL)secondary in:(NSView*)view {
    NSTextField* field=[NSTextField labelWithString:text ?: @""];field.font=[NSFont systemFontOfSize:size weight:weight];
    field.textColor=secondary ? SPDFCollectionColor(@"secondary") : SPDFCollectionColor(@"text");field.lineBreakMode=NSLineBreakByTruncatingTail;
    field.cell.usesSingleLineMode=YES;field.maximumNumberOfLines=1;
    field.translatesAutoresizingMaskIntoConstraints=NO;[view addSubview:field];return field;
}
- (NSView*)tableView:(NSTableView*)table viewForTableColumn:(NSTableColumn*)column row:(NSInteger)row {
    (void)table;(void)column;NSDictionary* item=_rows[(NSUInteger)row];NSTableCellView* cell=[NSTableCellView new];
    if([item[@"folderHeader"] boolValue]) {
        BOOL collapsed=[item[@"collapsed"] boolValue];
        NSImageView* chevron=[NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:collapsed ? @"chevron.right" : @"chevron.down" accessibilityDescription:nil]];

        NSImageView* folder=[NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"folder" accessibilityDescription:nil]];
        for(NSImageView* icon in @[chevron,folder]){icon.translatesAutoresizingMaskIntoConstraints=NO;icon.imageScaling=NSImageScaleProportionallyDown;icon.contentTintColor=SPDFCollectionColor(@"secondary");[cell addSubview:icon];}
        NSTextField* title=[self label:item[@"name"] size:12 weight:NSFontWeightSemibold secondary:NO in:cell];
        NSTextField* count=[self label:[item[@"count"] stringValue] size:11 weight:NSFontWeightRegular secondary:YES in:cell];
        [count setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
        cell.textField=title;cell.accessibilityLabel=[NSString stringWithFormat:@"%@, %@ chats%@",item[@"name"],item[@"count"],[item[@"id"] length] ? (collapsed ? @", collapsed" : @", expanded") : @""];
        [NSLayoutConstraint activateConstraints:@[
            [chevron.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:4],[chevron.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],[chevron.widthAnchor constraintEqualToConstant:10],[chevron.heightAnchor constraintEqualToConstant:10],
            [folder.leadingAnchor constraintEqualToAnchor:chevron.trailingAnchor constant:6],[folder.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],[folder.widthAnchor constraintEqualToConstant:14],[folder.heightAnchor constraintEqualToConstant:14],
            [title.leadingAnchor constraintEqualToAnchor:folder.trailingAnchor constant:6],[title.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],[title.trailingAnchor constraintLessThanOrEqualToAnchor:count.leadingAnchor constant:-8],[title.heightAnchor constraintEqualToConstant:16],
            [count.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-8],[count.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],[count.heightAnchor constraintEqualToConstant:14]]];return cell;
    }
    NSString* query=item[@"query"] ?: _search.stringValue;
    NSTextField* title=[self label:item[@"title"] ?: @"New chat" size:13 weight:NSFontWeightMedium secondary:NO in:cell];
    title.attributedStringValue=HistoryText(title.stringValue,query,title.font,title.textColor);title.toolTip=title.stringValue;cell.textField=title;
    NSTimeInterval updated=[item[@"updated"] doubleValue];
    NSTextField* date=[self label:updated>0 ? [_dateFormatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:updated]] : @"Not saved yet" size:11 weight:NSFontWeightRegular secondary:YES in:cell];
    CGFloat inset=22;
    [NSLayoutConstraint activateConstraints:@[[title.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:inset],[title.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-8],[title.topAnchor constraintEqualToAnchor:cell.topAnchor constant:6],[title.heightAnchor constraintEqualToConstant:16],
        [date.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],[date.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],[date.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:3],[date.heightAnchor constraintEqualToConstant:14]]];
    if([item[@"snippet"] length]) {
        NSTextField* snippet=[self label:item[@"snippet"] size:12 weight:NSFontWeightRegular secondary:YES in:cell];snippet.cell.usesSingleLineMode=NO;snippet.maximumNumberOfLines=2;
        snippet.cell.wraps=YES;NSString* context=HistorySnippet(snippet.stringValue,query,MAX(80,MIN(NSWidth(self.bounds),NSWidth(table.bounds))-inset-16),snippet.font);
        NSMutableAttributedString* excerpt=[HistoryText(context,query,snippet.font,snippet.textColor) mutableCopy];
        NSMutableParagraphStyle* wrapping=[NSMutableParagraphStyle new];wrapping.lineBreakMode=NSLineBreakByWordWrapping;
        [excerpt addAttribute:NSParagraphStyleAttributeName value:wrapping range:NSMakeRange(0,excerpt.length)];snippet.attributedStringValue=excerpt;
        [NSLayoutConstraint activateConstraints:@[[snippet.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],[snippet.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],[snippet.topAnchor constraintEqualToAnchor:date.bottomAnchor constant:4],[snippet.heightAnchor constraintEqualToConstant:30]]];
    }
    cell.accessibilityLabel=[NSString stringWithFormat:@"%@, %@%@",title.stringValue,date.stringValue,[item[@"snippet"] length] ? [@", " stringByAppendingString:item[@"snippet"]] : @""];return cell;
}
- (void)addMenuItem:(NSMenu*)menu title:(NSString*)title command:(NSString*)command {
    NSMenuItem* item=[menu addItemWithTitle:title action:@selector(menuAction:) keyEquivalent:@""];item.target=self;item.representedObject=command;
}
- (NSMenu*)menuForRow:(NSInteger)row {
    NSMenu* menu=[NSMenu new];NSDictionary* item=row>=0 && row<(NSInteger)_rows.count ? _rows[(NSUInteger)row] : nil;
    NSString* identifier=item[@"id"];
    if([item[@"folderHeader"] boolValue] && identifier.length) {
        [self addMenuItem:menu title:@"Rename folder…" command:[@"renameFolder:" stringByAppendingString:identifier]];
        [self addMenuItem:menu title:@"Remove folder (keep chats)" command:[@"deleteFolder:" stringByAppendingString:identifier]];
        [menu addItem:NSMenuItem.separatorItem];
    } else if(item && ![item[@"folderHeader"] boolValue]) {
        [self addMenuItem:menu title:@"Rename chat…" command:[@"rename:" stringByAppendingString:identifier]];
        NSMenuItem* move=[menu addItemWithTitle:@"Move to folder" action:nil keyEquivalent:@""];NSMenu* destinations=[NSMenu new];move.submenu=destinations;
        NSMutableArray* groups=[NSMutableArray arrayWithObject:@{@"id":@"",@"name":@"General"}];
        for(NSDictionary* folder in _folders)if([folder[@"id"] length])[groups addObject:folder];
        for(NSDictionary* folder in groups) {
            [self addMenuItem:destinations title:folder[@"name"] command:[NSString stringWithFormat:@"move:%@:%@",identifier,folder[@"id"]]];
            if([(item[@"folder"] ?: @"") isEqual:folder[@"id"]])destinations.itemArray.lastObject.state=NSControlStateValueOn;
        }
        [menu addItem:NSMenuItem.separatorItem];[self addMenuItem:menu title:@"Delete chat…" command:[@"delete:" stringByAppendingString:identifier]];
        [menu addItem:NSMenuItem.separatorItem];
    }
    [self addMenuItem:menu title:@"New folder…" command:@"newFolder"];
    if(_chats.count){[menu addItem:NSMenuItem.separatorItem];[self addMenuItem:menu title:@"Delete all chats…" command:@"deleteAll"];}return menu;
}
- (void)menuAction:(NSMenuItem*)sender {
    NSString* command=sender.representedObject;
    if([command hasPrefix:@"rename:"] || [command hasPrefix:@"renameFolder:"]) {
        BOOL folder=[command hasPrefix:@"renameFolder:"];
        [self beginRenamingItem:[command substringFromIndex:folder ? 13 : 7] folder:folder];return;
    }
    if(self.action)self.action(command);
}
- (void)controlTextDidChange:(NSNotification*)note {if(note.object==_search && self.searchChanged)self.searchChanged(_search.stringValue);}
- (void)newChat:(id)sender {(void)sender;if(self.action)self.action(@"new");}
- (void)newFolder:(id)sender {(void)sender;if(self.action)self.action(@"newFolder");}
- (void)activateRow:(NSInteger)row {
    if(row<0 || row>=(NSInteger)_rows.count)return;NSDictionary* item=_rows[(NSUInteger)row];
    if([item[@"folderHeader"] boolValue]) {
        if(_search.stringValue.length)return;
        NSMutableArray* changed=[NSMutableArray array];
        for(NSDictionary* folder in _folders){NSMutableDictionary* copy=[folder mutableCopy];if([copy[@"id"] isEqual:item[@"id"]])copy[@"collapsed"]=@(![copy[@"collapsed"] boolValue]);[changed addObject:copy];}
        if(![item[@"id"] length] && ![[changed valueForKey:@"id"] containsObject:@""])
            [changed insertObject:@{@"id":@"",@"name":@"General",@"collapsed":@(![item[@"collapsed"] boolValue])} atIndex:0];
        _folders=changed;[self rebuildRows];if(self.action)self.action([@"toggleFolder:" stringByAppendingString:item[@"id"]]);
    } else if(self.action)self.action([@"load:" stringByAppendingString:item[@"id"]]);
}
- (void)openChat:(id)sender {if(_editor)return;(void)sender;[self activateRow:_table.clickedRow>=0 ? _table.clickedRow : _table.selectedRow];}

// Native field editing stays at the row's title, with no sheet, popover or animation.
- (void)beginRenamingItem:(NSString*)identifier folder:(BOOL)folder {
    if(_editor)[self finishRenaming:NO];
    NSInteger row=[_rows indexOfObjectPassingTest:^BOOL(NSDictionary* item,NSUInteger i,BOOL* stop){
        (void)i;(void)stop;return [item[@"id"] isEqual:identifier] && [item[@"folderHeader"] boolValue]==folder;
    }];
    if(row==NSNotFound || (folder && !identifier.length))return;
    [_table scrollRowToVisible:row];[_table layoutSubtreeIfNeeded];
    NSTableCellView* cell=[_table viewAtColumn:0 row:row makeIfNecessary:YES];[cell layoutSubtreeIfNeeded];
    NSTextField* title=cell.textField;if(!title)return;
    _editingID=[identifier copy];_editingFolder=folder;
    _editor=[[NSTextField alloc] initWithFrame:NSInsetRect(title.frame,0,-3)];_editor.font=title.font;
    _editor.stringValue=_rows[row][folder ? @"name" : @"title"] ?: @"";
    _editor.delegate=self;_editor.focusRingType=NSFocusRingTypeExterior;_editor.cell.usesSingleLineMode=YES;
    _editor.cell.scrollable=YES;_editor.accessibilityLabel=folder ? @"Rename folder" : @"Rename chat";
    _editor.autoresizingMask=NSViewWidthSizable;[cell addSubview:_editor];title.hidden=YES;
    [_editor selectText:nil];
}
- (void)finishRenaming:(BOOL)commit {
    if(!_editor)return;
    NSString* identifier=_editingID;BOOL folder=_editingFolder;NSString* name=[_editor.stringValue copy];
    NSTextField* editor=_editor;_editor=nil;_editingID=nil;[editor removeFromSuperview];
    [self rebuildRows];
    if(commit && self.renameItem)self.renameItem(identifier,folder,name);
}
- (BOOL)control:(NSControl*)control textView:(NSTextView*)textView doCommandBySelector:(SEL)command {
    (void)textView;if(control!=_editor)return NO;
    if(command==@selector(cancelOperation:)){[self finishRenaming:NO];[self.window makeFirstResponder:_table];return YES;}
    if(command==@selector(insertNewline:)){[self finishRenaming:YES];[self.window makeFirstResponder:_table];return YES;}return NO;
}
- (void)controlTextDidEndEditing:(NSNotification*)note {if(note.object==_editor)[self finishRenaming:YES];}
- (id<NSPasteboardWriting>)tableView:(NSTableView*)table pasteboardWriterForRow:(NSInteger)row {
    (void)table;NSDictionary* item=_rows[row];if([item[@"folderHeader"] boolValue] || _editor)return nil;
    NSPasteboardItem* pasteboard=[NSPasteboardItem new];
    [pasteboard setString:item[@"id"] forType:@"com.intuition.shenzhenpdf.chat"];return pasteboard;
}
- (NSString*)dropFolderAtRow:(NSInteger)row {
    if(row<0 || row>=(NSInteger)_rows.count)return nil;
    NSDictionary* item=_rows[row];return [item[@"folderHeader"] boolValue] ? item[@"id"] : item[@"folder"] ?: @"";
}
- (NSDragOperation)tableView:(NSTableView*)table validateDrop:(id<NSDraggingInfo>)info
    proposedRow:(NSInteger)row proposedDropOperation:(NSTableViewDropOperation)operation {
    (void)operation;
    NSString* chat=[info.draggingPasteboard stringForType:@"com.intuition.shenzhenpdf.chat"];
    if(!chat.length || ![self dropFolderAtRow:row] || _editor)return NSDragOperationNone;
    // Highlight the actual folder header even when hovering one of its chat rows.
    NSString* folder=[self dropFolderAtRow:row];
    for(NSUInteger i=0;i<_rows.count;i++)if([_rows[i][@"folderHeader"] boolValue] && [_rows[i][@"id"] isEqual:folder]) {
        [table setDropRow:i dropOperation:NSTableViewDropOn];break;
    }
    return NSDragOperationMove;
}
- (BOOL)tableView:(NSTableView*)table acceptDrop:(id<NSDraggingInfo>)info row:(NSInteger)row dropOperation:(NSTableViewDropOperation)operation {
    (void)table;(void)operation;NSString* folder=[self dropFolderAtRow:row];
    NSString* chat=[info.draggingPasteboard stringForType:@"com.intuition.shenzhenpdf.chat"];
    if(!folder || !chat.length || !self.action)return NO;
    self.action([NSString stringWithFormat:@"move:%@:%@",chat,folder]);return YES;
}
@end
