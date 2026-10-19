#import "SPDFMacFriendsPalette.h"
#import "mac/SZFriendsHost.h"

NSString* const SPDFMacFriendsPaletteKind = @"friendsMessage";
const NSUInteger SPDFMacFriendsPaletteLimit = 5;

static NSString* OneLine(NSString* text) {
    NSArray* words = [text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [[words filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]]
        componentsJoinedByString:@" "];
}

NSArray<NSDictionary*>* SPDFMacFriendsPaletteRows(NSArray<SZFriendsSearchResult*>* results) {
    NSMutableArray* rows = [NSMutableArray array];
    for (SZFriendsSearchResult* result in results) {
        if (rows.count > SPDFMacFriendsPaletteLimit) break;  // the header plus the limit
        if (!result.conversationID.length || !result.messageID.length) continue;
        NSMutableString* excerpt = [NSMutableString string];
        // Segments are plain text from other people: joined as text, never interpreted as markup.
        for (NSDictionary* segment in result.excerpt)
            if ([segment[@"text"] isKindOfClass:NSString.class]) [excerpt appendString:segment[@"text"]];
        NSString* context = OneLine(excerpt);
        NSString* sender = result.senderLabel.length ? result.senderLabel : nil;
        NSString* title = result.timeLabel.length
            ? [NSString stringWithFormat:@"%@ · %@", result.conversationTitle ?: @"", result.timeLabel]
            : (result.conversationTitle ?: @"");
        // A section header first, like the palette's other tiers (SPDFMacCollectionPaletteModel.mm AddSection).
        if (!rows.count) [rows addObject:@{@"kind" : @"header", @"title" : @"Friends messages", @"subtitle" : @""}];
        [rows addObject:@{@"kind" : SPDFMacFriendsPaletteKind, @"title" : title,
                          @"subtitle" : sender ? [NSString stringWithFormat:@"%@: %@", sender, context] : context,
                          @"conversationID" : result.conversationID, @"messageID" : result.messageID}];
    }
    return rows;
}

NSArray<NSDictionary*>* SPDFMacFriendsPaletteMergeRows(NSArray<NSDictionary*>* rows,
                                                      NSArray<NSDictionary*>* friendsRows) {
    if (!friendsRows.count) return rows;
    NSMutableArray* merged = [rows mutableCopy] ?: [NSMutableArray array];
    NSUInteger askAI = [merged indexOfObjectPassingTest:^BOOL(NSDictionary* row, NSUInteger index, BOOL* stop) {
        (void)index; (void)stop;
        return [row isKindOfClass:NSDictionary.class] && [row[@"kind"] isEqual:@"askAI"];
    }];
    if (askAI == NSNotFound) [merged addObjectsFromArray:friendsRows];
    else [merged insertObjects:friendsRows
                     atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(askAI, friendsRows.count)]];
    return merged;
}

BOOL SPDFMacFriendsPaletteRowIsFriends(NSDictionary* row) {
    return [row isKindOfClass:NSDictionary.class] && [row[@"kind"] isEqual:SPDFMacFriendsPaletteKind] &&
        [row[@"conversationID"] isKindOfClass:NSString.class] && [row[@"messageID"] isKindOfClass:NSString.class];
}
