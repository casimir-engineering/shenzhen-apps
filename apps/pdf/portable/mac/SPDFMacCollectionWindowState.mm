#import "SPDFMacCollectionWindowPrivate.h"
static NSString* RowIdentity(NSDictionary* row) {
    return [NSString stringWithFormat:@"%@/%@",row[@"document"][@"id"] ?: @"",row[@"version"][@"id"] ?: @""];
}
@implementation SPDFMacCollectionWindow (BrowsingState)
- (NSDictionary*)captureBrowseState {
    if (!self.hasLoadedResults) return self.initialBrowseState ?: @{};
    NSMutableArray* selection = [NSMutableArray array];
    NSMutableArray* documents = [NSMutableArray array];
    [self.table.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger index,BOOL* stop) {
        (void)stop; if (index < self.rows.count) {
            [selection addObject:RowIdentity(self.rows[index])];
            NSString* identifier = self.rows[index][@"document"][@"id"];
            if (identifier) [documents addObject:identifier];
        }
    }];
    NSMutableDictionary* matches = [NSMutableDictionary dictionary];
    for (NSDictionary* row in self.rows) if (row[@"selectedPage"]) {
        NSUInteger matchIndex = [row[@"selectedMatchIndex"] unsignedIntegerValue];
        if (!row[@"selectedMatchIndex"] && row[@"selectedMatch"])
            matchIndex = [row[@"matches"] indexOfObject:row[@"selectedMatch"]];
        matches[RowIdentity(row)] = @{@"page":row[@"selectedPage"],@"index":@(matchIndex)};
    }
    NSPoint list = self.listScroll.contentView.bounds.origin;
    return @{@"query":self.resultQuery ?: self.search.stringValue,@"selection":selection,@"selectedDocuments":documents,@"matches":matches,
        @"expanded":self.expandedResults.allObjects,@"listX":@(list.x),@"listY":@(list.y)};
}
- (void)restoreBrowseState:(NSDictionary*)state toRows:(NSMutableArray*)rows query:(NSString*)query {
    // Match indices only describe the same query and immutable archived version.
    // A changed query must never reuse an unrelated hit just because its index matches.
    if (![state[@"query"] isEqual:query]) return;
    NSDictionary* contexts = [state[@"matches"] isKindOfClass:NSDictionary.class] ? state[@"matches"] : @{};
    for (NSUInteger i=0;i<rows.count;i++) {
        NSDictionary* saved = contexts[RowIdentity(rows[i])]; if (![saved isKindOfClass:NSDictionary.class]) continue;
        NSMutableDictionary* row = [rows[i] mutableCopy];
        NSArray* matches = row[@"matches"] ?: @[]; NSUInteger index = [saved[@"index"] unsignedIntegerValue];
        if (index < matches.count) {
            row[@"selectedMatchIndex"] = @(index); row[@"selectedMatch"] = matches[index];
            row[@"selectedPage"] = matches[index][@"page"] ?: @0;
        } else if (!query.length && saved[@"page"]) row[@"selectedPage"] = saved[@"page"];
        rows[i] = row;
    }
}
- (void)restoreBrowseSelectionAndScroll:(NSDictionary*)state {
    NSArray* selection = [state[@"selection"] isKindOfClass:NSArray.class] ? state[@"selection"] : @[];
    NSMutableIndexSet* selected = [NSMutableIndexSet indexSet];
    NSArray* documents = [state[@"selectedDocuments"] isKindOfClass:NSArray.class] ? state[@"selectedDocuments"] : @[];
    NSMutableSet* matchedDocuments = [NSMutableSet set];
    for (NSUInteger i=0;i<self.rows.count;i++) if ([selection containsObject:RowIdentity(self.rows[i])]) {
        [selected addIndex:i];
        NSString* identifier = self.rows[i][@"document"][@"id"];
        if (identifier) [matchedDocuments addObject:identifier];
    }
    // Fall back to the document only when its exact saved version disappeared.
    for (NSUInteger i=0;i<self.rows.count;i++) {
        NSString* identifier = self.rows[i][@"document"][@"id"];
        if ([documents containsObject:identifier] && ![matchedDocuments containsObject:identifier]) {
            [selected addIndex:i]; [matchedDocuments addObject:identifier];
        }
    }
    [self.table selectRowIndexes:selected byExtendingSelection:NO];
    [self.window.contentView layoutSubtreeIfNeeded];
    // scrollToPoint does not constrain its input. A saved position may now be
    // beyond the final row after cleanup, filtering, or a smaller result set.
    // Use row geometry rather than a temporarily oversized NSTableView frame.
    NSClipView* clip = self.listScroll.contentView;
    NSPoint requested = NSZeroPoint;
    if ([state[@"query"] isEqual:self.search.stringValue])
        requested = NSMakePoint([state[@"listX"] doubleValue],[state[@"listY"] doubleValue]);
    CGFloat bottom = self.rows.count ? NSMaxY([self.table rectOfRow:(NSInteger)self.rows.count-1]) : 0;
    CGFloat maxY = MAX(0,bottom-NSHeight(clip.bounds));
    CGFloat maxX = MAX(0,NSWidth(self.table.bounds)-NSWidth(clip.bounds));
    requested.x = isfinite(requested.x) ? MAX(0,MIN(requested.x,maxX)) : 0;
    requested.y = isfinite(requested.y) ? MAX(0,MIN(requested.y,maxY)) : 0;
    NSRect bounds = clip.bounds; bounds.origin = requested;
    [clip scrollToPoint:[clip constrainBoundsRect:bounds].origin];
    [self.listScroll reflectScrolledClipView:clip];
}
@end
