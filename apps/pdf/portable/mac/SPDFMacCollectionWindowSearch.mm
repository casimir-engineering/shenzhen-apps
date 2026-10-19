#import "SPDFMacCollectionWindowPrivate.h"
#import "SPDFMacCollectionAvailability.h"
#import "SPDFMacCollectionStyle.h"
static NSString* RowKey(NSDictionary* row) {
    return [NSString stringWithFormat:@"%@/%@",row[@"document"][@"id"],row[@"version"][@"id"] ?: @""];
}
static NSString* DateLabel(NSDictionary* version) {
    return version[@"capturedAt"] ? [NSDateFormatter localizedStringFromDate:
        [NSDate dateWithTimeIntervalSince1970:[version[@"capturedAt"] doubleValue]]
        dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterShortStyle] : @"No saved copy";
}
// Outline the actual page, not the aspect-fit container, so white previews
// remain legible against the light window without adding a native photo bezel.
@interface SPDFCollectionPagePreview : NSImageView
@end
@implementation SPDFCollectionPagePreview
- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    NSSize size = self.image.size;
    if (self.image.isTemplate || size.width<=0 || size.height<=0) return;
    CGFloat scale = MIN(NSWidth(self.bounds)/size.width,NSHeight(self.bounds)/size.height);
    NSRect page = NSMakeRect(NSMidX(self.bounds)-size.width*scale/2,NSMidY(self.bounds)-size.height*scale/2,
        size.width*scale,size.height*scale);
    [SPDFCollectionColor(@"line") setStroke];
    NSBezierPath* outline = [NSBezierPath bezierPathWithRect:NSInsetRect(page,.5,.5)];
    outline.lineWidth = 1; [outline stroke];
}
- (void)viewDidChangeEffectiveAppearance { [super viewDidChangeEffectiveAppearance]; self.needsDisplay = YES; }
@end
@interface SPDFCollectionResultRow : NSTableRowView
@end
@implementation SPDFCollectionResultRow
- (void)drawSelectionInRect:(NSRect)dirtyRect {
    (void)dirtyRect; [SPDFCollectionColor(@"selected") setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,10,2) xRadius:5 yRadius:5] fill];
}
@end
@implementation SPDFMacCollectionWindow (SearchResults)
- (NSTableRowView*)tableView:(NSTableView*)tableView rowViewForRow:(NSInteger)row {
    (void)tableView; (void)row; return [SPDFCollectionResultRow new];
}
- (CGFloat)tableView:(NSTableView*)tableView heightOfRow:(NSInteger)index {
    (void)tableView;
    if (index < 0 || index >= (NSInteger)self.rows.count) return 100;
    NSDictionary* row = self.rows[(NSUInteger)index];
    NSUInteger count = [row[@"matches"] count];
    NSUInteger visible = [self.expandedResults containsObject:RowKey(row)] ? count : MIN(3,count);
    return 28 + MAX(88,74 + visible*60) + (count>3 ? 30 : 0) + ([row[@"truncated"] boolValue] ? 36 : 0);
}
- (NSView*)resultCellForRow:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.rows.count) return [NSView new];
    NSDictionary* row = self.rows[(NSUInteger)index], *doc = row[@"document"], *version = row[@"version"];
    NSView* cell = [NSView new]; cell.identifier = @"CollectionDocumentRow";
    NSTextField* title = SPDFCollectionText(version[@"filename"] ?: doc[@"title"] ?: @"Document",12,NSFontWeightSemibold,NO);
    title.identifier = @"CollectionResultTitle";
    title.lineBreakMode = NSLineBreakByTruncatingMiddle; title.maximumNumberOfLines = 1; title.toolTip = doc[@"path"];
    title.translatesAutoresizingMaskIntoConstraints = NO; [cell addSubview:title];
    NSButton* history = SPDFCollectionButton(@"History",self,@selector(historyForRow:),@"normal"); history.tag = index;
    history.accessibilityLabel = [@"History for " stringByAppendingString:doc[@"title"] ?: @"document"];
    history.translatesAutoresizingMaskIntoConstraints = NO; [cell addSubview:history];
    NSButton* more = SPDFCollectionButton(@"…",self,@selector(showDocumentMenu:),@"quiet"); more.tag = index;
    more.accessibilityLabel = [@"More actions for " stringByAppendingString:doc[@"title"] ?: @"document"];
    more.translatesAutoresizingMaskIntoConstraints = NO; [cell addSubview:more];
    NSTextField* metadata = SPDFCollectionText([NSString stringWithFormat:@"%@ · %@%@",
        SPDFCollectionOriginalAvailable(doc) ? @"Original available" : @"Original unavailable", DateLabel(version),
        [version[@"keep"] boolValue] ? @" · Kept" : @""],11,NSFontWeightRegular,YES);
    metadata.maximumNumberOfLines = 1; metadata.lineBreakMode = NSLineBreakByTruncatingMiddle;
    NSStackView* meta = [NSStackView stackViewWithViews:@[metadata]]; meta.spacing = 8;
    meta.alignment = NSLayoutAttributeCenterY;
    meta.translatesAutoresizingMaskIntoConstraints = NO; [cell addSubview:meta];
    NSImageView* image = [SPDFCollectionPagePreview new]; image.translatesAutoresizingMaskIntoConstraints = NO;
    image.imageScaling = NSImageScaleProportionallyUpOrDown;
    NSInteger page = [row[@"selectedPage"] integerValue];
    if (!page && [row[@"matches"] count]) page = [row[@"matches"][0][@"page"] integerValue];
    NSString* key = [RowKey(row) stringByAppendingFormat:@"/%ld",(long)page];
    // Originals are mutable; revalidate only consulted rows after a refresh.
    if (!version[@"id"]) key = [key stringByAppendingFormat:@"/original-%lu",(unsigned long)self.generation];
    image.identifier = key; image.image = [self.thumbnailCache objectForKey:key] ?: [NSImage imageWithSystemSymbolName:
        @"doc" accessibilityDescription:@"Saved page preview"];
    image.accessibilityLabel = page>0 ? [NSString stringWithFormat:@"Page %ld preview",(long)page] :
        version[@"id"] ? @"Saved copy preview" : @"Original document preview";
    if (!version[@"id"]) image.toolTip = @"Preview of the original document; no saved copy yet.";
    [cell addSubview:image];
    if (version[@"id"] || ([doc[@"path"] length] && ![doc[@"sourceReplaced"] boolValue] && ![doc[@"originalUnavailable"] boolValue])) {
        NSMutableDictionary* thumbnailRow = [row mutableCopy]; thumbnailRow[@"selectedPage"] = @(page);
        [self requestThumbnail:thumbnailRow key:key];
    }
    NSStackView* text = [NSStackView stackViewWithViews:@[]]; text.translatesAutoresizingMaskIntoConstraints = NO;
    text.orientation = NSUserInterfaceLayoutOrientationVertical; text.alignment = NSLayoutAttributeLeading; text.spacing = 6;
    [cell addSubview:text];
    NSArray* matches = row[@"matches"] ?: @[];
    NSUInteger visible = [self.expandedResults containsObject:RowKey(row)] ? matches.count : MIN(3,matches.count);
    for (NSUInteger i=0;i<visible;i++) {
        NSDictionary* match = matches[i]; NSString* snippet = match[@"snippet"] ?: @"";
        NSString* prefix = [match[@"page"] integerValue]>0 ? [NSString stringWithFormat:@"p. %@\t",match[@"page"]] : @"Text\t";
        NSMutableAttributedString* caption = [[NSMutableAttributedString alloc] initWithString:[prefix stringByAppendingString:snippet]
            attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:12],NSForegroundColorAttributeName:SPDFCollectionColor(@"text")}];
        [caption addAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:11],NSForegroundColorAttributeName:SPDFCollectionColor(@"secondary")}
            range:NSMakeRange(0,prefix.length)];
        for (NSValue* value in match[@"ranges"]) {
            NSRange range = value.rangeValue; range.location += prefix.length;
            if (NSMaxRange(range)<=caption.length) [caption addAttributes:@{NSBackgroundColorAttributeName:SPDFCollectionColor(@"highlight"),
                NSFontAttributeName:[NSFont systemFontOfSize:12 weight:NSFontWeightSemibold]} range:range];
        }
        NSButton* hit = SPDFCollectionButton(@"",self,@selector(selectSearchMatch:),@"match");
        hit.alignment = NSTextAlignmentLeft; hit.attributedTitle = caption; hit.cell.wraps = YES;
        hit.cell.lineBreakMode = NSLineBreakByWordWrapping; hit.tag = index; hit.identifier = [NSString stringWithFormat:@"%lu",(unsigned long)i];
        hit.toolTip = [prefix stringByAppendingString:snippet];
        hit.state = row[@"selectedMatchIndex"] && [row[@"selectedMatchIndex"] unsignedIntegerValue]==i ? NSControlStateValueOn : NSControlStateValueOff;
        [hit.heightAnchor constraintEqualToConstant:54].active = YES; [text addArrangedSubview:hit];
        [hit.widthAnchor constraintEqualToAnchor:text.widthAnchor].active = YES;
        [hit setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    }
    if (!matches.count && self.search.stringValue.length) {
        NSString* status = [row[@"textAvailable"] boolValue] ? @"Title match · no matching saved text" : @"Title match · saved text is not indexed";
        [text addArrangedSubview:SPDFCollectionText(status,11,NSFontWeightRegular,YES)];
    }
    NSButton* preview = SPDFCollectionButton(@"Open collection copy",self,@selector(previewForRow:),@"normal");
    preview.tag = index; preview.enabled = [version[@"id"] length]>0;
    NSMutableArray* rowActions = [NSMutableArray array];
    if (SPDFCollectionOriginalAvailable(doc)) {
        NSButton* original = SPDFCollectionButton(@"Open original",self,@selector(openOriginalForRow:),@"normal");
        original.tag = index; [rowActions addObject:original];
    }
    [rowActions addObjectsFromArray:@[preview,history]];
    NSStackView* actions = [NSStackView stackViewWithViews:rowActions]; actions.spacing = 6;
    actions.translatesAutoresizingMaskIntoConstraints = NO; [cell addSubview:actions];
    if (matches.count>3) {
        BOOL expanded = [self.expandedResults containsObject:RowKey(row)];
        NSButton* expand = SPDFCollectionButton(expanded ? @"Show fewer matches" :
            [NSString stringWithFormat:@"Show %lu more matches",(unsigned long)matches.count-3],self,@selector(toggleMatches:),@"link");
        expand.tag = index; [text addArrangedSubview:expand];
    }
    if ([row[@"truncated"] boolValue]) [text addArrangedSubview:SPDFCollectionText([NSString stringWithFormat:
        @"Showing %lu contexts from %@ text matches. Refine your search to narrow results.",(unsigned long)matches.count,
        row[@"matchCount"] ?: @(matches.count)],12,NSFontWeightRegular,YES)];
    NSView* divider = SPDFCollectionDivider(); divider.translatesAutoresizingMaskIntoConstraints = NO; [cell addSubview:divider];
    [NSLayoutConstraint activateConstraints:@[
        [image.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:14],
        [image.topAnchor constraintEqualToAnchor:cell.topAnchor constant:14],
        [image.widthAnchor constraintEqualToConstant:65],[image.heightAnchor constraintEqualToConstant:88],
        [title.leadingAnchor constraintEqualToAnchor:image.trailingAnchor constant:14],
        [title.topAnchor constraintEqualToAnchor:image.topAnchor],
        [title.trailingAnchor constraintLessThanOrEqualToAnchor:more.leadingAnchor constant:-8],
        [more.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-14],
        [more.topAnchor constraintEqualToAnchor:cell.topAnchor constant:8], [more.widthAnchor constraintEqualToConstant:26],
        [meta.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],[meta.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:5],
        [meta.trailingAnchor constraintLessThanOrEqualToAnchor:cell.trailingAnchor constant:-14],
        [text.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],[text.topAnchor constraintEqualToAnchor:meta.bottomAnchor constant:5],
        [text.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-14],
        [actions.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [actions.topAnchor constraintEqualToAnchor:text.bottomAnchor constant:6],
        [divider.leadingAnchor constraintEqualToAnchor:image.leadingAnchor],[divider.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-14],
        [divider.bottomAnchor constraintEqualToAnchor:cell.bottomAnchor constant:-1]]];
    return cell;
}
- (void)openOriginalForRow:(NSControl*)sender {
    NSInteger index = sender.tag; if (index<0 || index>=(NSInteger)self.rows.count) return;
    [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:index] byExtendingSelection:NO]; [self openOriginal:nil];
}
- (void)previewForRow:(NSControl*)sender {
    NSInteger index = sender.tag; if (index<0 || index>=(NSInteger)self.rows.count) return;
    [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:index] byExtendingSelection:NO]; [self preview:nil];
}
- (void)showDocumentMenu:(NSControl*)sender {
    if (sender.tag>=0 && sender.tag<(NSInteger)self.rows.count)
        [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:sender.tag] byExtendingSelection:NO];
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Document actions"]; [self populateDocumentMenu:menu];
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0,NSHeight(sender.bounds)) inView:sender];
}
- (void)menuNeedsUpdate:(NSMenu*)menu {
    NSInteger index = self.table.clickedRow;
    if (index>=0 && ![self.table.selectedRowIndexes containsIndex:index])
        [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:index] byExtendingSelection:NO];
    [self populateDocumentMenu:menu];
}
- (void)populateDocumentMenu:(NSMenu*)menu {
    [self updateDetails]; [menu removeAllItems]; menu.autoenablesItems = NO;
    for (NSButton* command in self.selectionButtons) {
        if (command.hidden) continue;
        NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:command.title action:command.action keyEquivalent:@""];
        item.target = self; item.enabled = command.enabled; item.toolTip = command.toolTip; [menu addItem:item];
    }
}
- (void)historyForRow:(NSControl*)sender {
    NSInteger index = sender.tag; if (index < 0 || index >= (NSInteger)self.rows.count) return;
    [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:index] byExtendingSelection:NO]; [self history:nil];
}
- (void)toggleMatches:(NSControl*)sender {
    NSInteger index = sender.tag; if (index < 0 || index >= (NSInteger)self.rows.count) return;
    NSString* key = RowKey(self.rows[(NSUInteger)index]);
    if ([self.expandedResults containsObject:key]) [self.expandedResults removeObject:key]; else [self.expandedResults addObject:key];
    NSIndexSet* indexes = [NSIndexSet indexSetWithIndex:index]; [self.table noteHeightOfRowsWithIndexesChanged:indexes];
    [self.table reloadDataForRowIndexes:indexes columnIndexes:[NSIndexSet indexSetWithIndex:0]];
    [self persistManagerPreferences];
}
- (void)selectSearchMatch:(NSControl*)sender {
    NSInteger index = sender.tag, matchIndex = sender.identifier.integerValue;
    if (index < 0 || index >= (NSInteger)self.rows.count) return;
    NSMutableDictionary* row = [self.rows[(NSUInteger)index] mutableCopy]; NSArray* matches = row[@"matches"];
    if (matchIndex < 0 || matchIndex >= (NSInteger)matches.count) return;
    row[@"selectedPage"] = matches[(NSUInteger)matchIndex][@"page"] ?: @0;
    row[@"selectedMatch"] = matches[(NSUInteger)matchIndex];
    row[@"selectedMatchIndex"] = @(matchIndex);
    NSMutableArray* rows = [self.rows mutableCopy]; rows[(NSUInteger)index] = row; self.rows = rows;
    [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:index] byExtendingSelection:NO];
    [self.table reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:index] columnIndexes:[NSIndexSet indexSetWithIndex:0]];
    [self persistManagerPreferences];
    if (self.navigateHandler) self.navigateHandler(row[@"document"],row[@"version"],
        [row[@"selectedPage"] unsignedIntegerValue],self.search.stringValue,NO);
    else [self preview:nil];
}
@end
