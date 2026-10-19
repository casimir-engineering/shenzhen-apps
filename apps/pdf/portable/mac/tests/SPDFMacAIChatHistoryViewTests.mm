#import "../SPDFMacAIChatHistoryView.h"
@interface SPDFMacAIChatHistoryView (Tests)
- (NSMenu*)menuForRow:(NSInteger)row;
- (void)activateRow:(NSInteger)row;
@end
@interface ChatDropInfo : NSObject
@property NSPasteboard* draggingPasteboard;
@end
@implementation ChatDropInfo @end
static NSUInteger failures=0;
static void Check(BOOL value,NSString* message){if(!value){fprintf(stderr,"FAIL %s\n",message.UTF8String);failures++;}}
static NSArray<NSTextField*>* Labels(NSView* view){NSMutableArray* labels=[NSMutableArray array];for(NSView* child in view.subviews){if([child isKindOfClass:NSTextField.class])[labels addObject:child];[labels addObjectsFromArray:Labels(child)];}return labels;}
int main(void){@autoreleasepool{
    [NSApplication sharedApplication];
    NSWindow* window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,300,600) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    SPDFMacAIChatHistoryView* view=[[SPDFMacAIChatHistoryView alloc] initWithFrame:window.contentView.bounds];window.contentView=view;view.wantsLayer=YES;
    __block NSString* action=nil;view.action=^(NSString* value){action=value;};
    [view displayFolders:@[@{@"id":@"folder-a",@"name":@"Main board",@"collapsed":@NO},@{@"id":@"folder-b",@"name":@"Reference",@"collapsed":@YES}]];
    NSTimeInterval now=NSDate.date.timeIntervalSince1970;
    NSArray* chats=@[@{@"id":@"first",@"title":@"Power supply requirements",@"folder":@"folder-a",@"updated":@(now)},@{@"id":@"second",@"title":@"Compare revision changes",@"folder":@"folder-b",@"updated":@(now-86400)},@{@"id":@"third",@"title":@"English chapter titles",@"updated":@(now-172800)}];
    [view displayChats:chats selectedID:@"first"];[view layoutSubtreeIfNeeded];
    NSTableView* table=[view valueForKey:@"table"];
    Check(table.numberOfRows==5,@"folder order, collapsed contents, and General are represented");
    Check(table.selectedRow==3,@"selected chat remains selected within its folder");
    [view viewDidChangeEffectiveAppearance];Check(table.selectedRow==3,@"appearance refresh preserves selected chat for Return");
    [table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    Check(table.selectedRow==0,@"folder headers support keyboard selection");
    [view activateRow:2];Check([action isEqual:@"toggleFolder:folder-a"] && table.numberOfRows==4,@"folder click toggles immediately without opening a chat");
    [view activateRow:2];Check(table.numberOfRows==5,@"second click expands immediately");
    NSMenu* menu=[view menuForRow:3];Check([menu.itemArray.firstObject.title isEqual:@"Rename chat…"],@"chat context starts with Rename");
    NSMenu* destinations=menu.itemArray[1].submenu;Check(destinations.numberOfItems==3,@"Move menu contains General and every folder");
    Check([destinations.itemArray[2].representedObject isEqual:@"move:first:folder-b"],@"move command identifies chat and destination");
    Check([[[view menuForRow:2] itemAtIndex:1].representedObject isEqual:@"deleteFolder:folder-a"],@"folder removal is distinct from deleting chats");
    Check([[[view menuForRow:0] itemAtIndex:0].title isEqual:@"New folder…"],@"General cannot be renamed or removed");
    __block NSString* renamed=nil;view.renameItem=^(NSString* identifier,BOOL folder,NSString* name){(void)identifier;(void)folder;renamed=name;};
    [view beginRenamingItem:@"first" folder:NO];
    NSTextField* editor=[view valueForKey:@"editor"];
    Check(editor && [editor.stringValue isEqual:@"Power supply requirements"] && editor.currentEditor!=nil,@"Rename immediately edits the existing row title");
    [view layoutSubtreeIfNeeded];
    NSBitmapImageRep* editing=[view bitmapImageRepForCachingDisplayInRect:view.bounds];[view cacheDisplayInRect:view.bounds toBitmapImageRep:editing];
    [[editing representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@"/tmp/sz-chat-inline-rename.png" atomically:YES];
    editor.stringValue=@"Edited title";
    [view control:editor textView:(NSTextView*)editor.currentEditor doCommandBySelector:@selector(insertNewline:)];
    Check([renamed isEqual:@"Edited title"] && ![view valueForKey:@"editor"],@"Return commits inline rename");
    [view beginRenamingItem:@"folder-a" folder:YES];editor=[view valueForKey:@"editor"];renamed=nil;
    [view control:editor textView:(NSTextView*)editor.currentEditor doCommandBySelector:@selector(cancelOperation:)];
    Check(!renamed && ![view valueForKey:@"editor"],@"Escape cancels inline folder rename");
    id<NSPasteboardWriting> writer=[view tableView:table pasteboardWriterForRow:3];
    Check(writer!=nil && [view tableView:table pasteboardWriterForRow:2]==nil,@"only chats are draggable");
    ChatDropInfo* drop=[ChatDropInfo new];drop.draggingPasteboard=[NSPasteboard pasteboardWithUniqueName];
    [drop.draggingPasteboard writeObjects:@[writer]];
    Check([view tableView:table validateDrop:(id)drop proposedRow:4 proposedDropOperation:NSTableViewDropOn]==NSDragOperationMove,@"chat can hover a collapsed destination folder");
    action=nil;Check([view tableView:table acceptDrop:(id)drop row:4 dropOperation:NSTableViewDropOn] && [action isEqual:@"move:first:folder-b"],@"drop sends exact chat and destination without changing current chat");
    action=nil;Check([view tableView:table acceptDrop:(id)drop row:0 dropOperation:NSTableViewDropOn] && [action isEqual:@"move:first:"],@"chats can be dropped back into General");
    Check([view tableView:table validateDrop:(id)drop proposedRow:-1 proposedDropOperation:NSTableViewDropAbove]==NSDragOperationNone,@"invalid drop target rejected");
    [drop.draggingPasteboard releaseGlobally];
    view.search.stringValue=@"voltage";
    [view displayChats:@[@{@"id":@"second",@"title":@"Compare revision changes",@"folder":@"folder-b",@"updated":@(now),@"query":@"voltage",@"snippet":@"The regulator voltage changed from 3.3 V to 5 V in the latest revision."}] selectedID:@"second"];
    Check(table.numberOfRows==2 && table.selectedRow==1,@"search expands a collapsed folder to reveal its matching chat");
    NSView* cell=[view tableView:table viewForTableColumn:table.tableColumns.firstObject row:1];
    NSArray<NSTextField*>* labels=Labels(cell);Check(labels.count==3,@"message matches include title, timestamp, and context");
    __block BOOL highlighted=NO;[labels.lastObject.attributedStringValue enumerateAttribute:NSBackgroundColorAttributeName inRange:NSMakeRange(0,labels.lastObject.attributedStringValue.length) options:0 usingBlock:^(id value,NSRange range,BOOL* stop){(void)range;(void)stop;if(value)highlighted=YES;}];
    Check(highlighted,@"matched search term is highlighted inside contextual excerpt");
    window.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];[view layoutSubtreeIfNeeded];
    NSBitmapImageRep* searchBitmap=[view bitmapImageRepForCachingDisplayInRect:view.bounds];[view cacheDisplayInRect:view.bounds toBitmapImageRep:searchBitmap];
    [[searchBitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@"/tmp/sz-chat-history-search.png" atomically:YES];
    view.search.stringValue=@"";[view displayChats:chats selectedID:@"first"];
    Check(table.numberOfRows==5,@"clearing search restores saved folder collapse state");
    for(NSString* appearance in @[NSAppearanceNameDarkAqua,NSAppearanceNameAqua]) {
        window.appearance=[NSAppearance appearanceNamed:appearance];[view layoutSubtreeIfNeeded];
        NSBitmapImageRep* bitmap=[view bitmapImageRepForCachingDisplayInRect:view.bounds];[view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
        [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[NSString stringWithFormat:@"/tmp/sz-chat-history-%@.png",appearance] atomically:YES];
    }
    [view setFrameSize:NSMakeSize(240,600)];[view layoutSubtreeIfNeeded];Check(view.search.frame.size.width>=155,@"search remains usable at sidebar minimum width");
    [view displayChats:@[@{@"id":@"long",@"title":@"Compare the main board power supply changes across every hardware revision and summarize their design implications",@"folder":@"folder-a",@"updated":@(now),@"snippet":@"The voltage requirements changed across multiple revisions; compare the input rating and output limits before choosing a regulator."}] selectedID:@"long"];
    [view layoutSubtreeIfNeeded];[table layoutSubtreeIfNeeded];
    NSView* narrowCell=[table viewAtColumn:0 row:2 makeIfNecessary:YES];[narrowCell layoutSubtreeIfNeeded];
    NSArray<NSTextField*>* narrowLabels=Labels(narrowCell);
    Check(narrowLabels.count==3,@"narrow row exposes title, timestamp, and context");
    if(narrowLabels.count==3) {
        NSTextField* title=narrowLabels[0];NSTextField* date=narrowLabels[1];NSTextField* snippet=narrowLabels[2];
        Check(title.frame.size.height<=16 && title.cell.usesSingleLineMode && title.maximumNumberOfLines==1,@"long title stays on one truncated line at minimum sidebar width");
        Check(date.frame.size.height==14 && NSContainsRect(narrowCell.bounds,date.frame),@"timestamp remains fully within narrow row");
        Check(!NSIntersectsRect(title.frame,date.frame) && !NSIntersectsRect(date.frame,snippet.frame),@"title, timestamp, and excerpt never overlap");
        Check(!snippet.cell.usesSingleLineMode && snippet.maximumNumberOfLines==2 && NSContainsRect(narrowCell.bounds,snippet.frame),@"excerpt retains two visible lines below timestamp");
    }
    NSBitmapImageRep* narrowBitmap=[view bitmapImageRepForCachingDisplayInRect:view.bounds];[view cacheDisplayInRect:view.bounds toBitmapImageRep:narrowBitmap];
    [[narrowBitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@"/tmp/sz-chat-history-narrow.png" atomically:YES];
    view.search.stringValue=@"電圧";
    [view displayChats:@[@{@"id":@"cjk",@"title":@"回路基板の変更点",@"folder":@"folder-a",@"updated":@(now),@"query":@"電圧",@"snippet":@"これは以前の回路基板から新しい回路基板までの変更について詳細を説明する長い文章です。入力電圧は五ボルトであり、電源の仕様を確認してください。"}] selectedID:@"cjk"];
    [view layoutSubtreeIfNeeded];[table layoutSubtreeIfNeeded];
    NSView* cjkCell=[table viewAtColumn:0 row:1 makeIfNecessary:YES];[cjkCell layoutSubtreeIfNeeded];
    NSTextField* cjkSnippet=Labels(cjkCell).lastObject;NSRange hit=[cjkSnippet.stringValue rangeOfString:@"電圧"];
    NSTextStorage* storage=[[NSTextStorage alloc] initWithAttributedString:cjkSnippet.attributedStringValue];NSLayoutManager* layout=[NSLayoutManager new];
    NSTextContainer* container=[[NSTextContainer alloc] initWithSize:cjkSnippet.frame.size];container.lineFragmentPadding=0;container.maximumNumberOfLines=2;
    [layout addTextContainer:container];[storage addLayoutManager:layout];[layout ensureLayoutForTextContainer:container];
    NSRange visibleCharacters=[layout characterRangeForGlyphRange:[layout glyphRangeForTextContainer:container] actualGlyphRange:NULL];
    Check(hit.location!=NSNotFound && NSMaxRange(hit)<=NSMaxRange(visibleCharacters),@"CJK match remains within two laid-out context lines at minimum width");
    Check(hit.location<15,@"wide leading context is trimmed by measured width before the match");
    NSBitmapImageRep* cjkBitmap=[view bitmapImageRepForCachingDisplayInRect:view.bounds];[view cacheDisplayInRect:view.bounds toBitmapImageRep:cjkBitmap];
    [[cjkBitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@"/tmp/sz-chat-history-cjk.png" atomically:YES];
    Check(!window.visible,@"headless fixture never orders its window");
    printf("Chat history: %lu failures\n",(unsigned long)failures);return failures ? 1 : 0;
}}
