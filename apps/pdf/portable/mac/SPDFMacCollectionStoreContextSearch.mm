#import "SPDFMacCollectionStoreContextSearch.h"
#import "SPDFMacCollectionStorePrivate.h"

static const NSStringCompareOptions MatchOptions = NSCaseInsensitiveSearch|NSDiacriticInsensitiveSearch;
static const NSUInteger ContextLimit = 32;

static BOOL WordCharacter(unichar value) {
    return [NSCharacterSet.alphanumericCharacterSet characterIsMember:value] ||
           [NSCharacterSet.nonBaseCharacterSet characterIsMember:value] || value == '_';
}
static NSRange ContextRange(NSString* text, NSRange hit, NSUInteger after) {
    NSUInteger start = hit.location > 80 ? hit.location-80 : 0;
    NSUInteger end = MIN(text.length,NSMaxRange(hit)+100);
    // Keep normal words whole. A pathological unbroken identifier must not turn
    // one search result into the entire 2 MB index; its clipped ends get ellipses.
    NSUInteger floor = hit.location > 2048 ? hit.location-2048 : 0;
    NSUInteger ceiling = MIN(text.length,NSMaxRange(hit)+2048);
    while (start > floor && WordCharacter([text characterAtIndex:start-1]) &&
           WordCharacter([text characterAtIndex:start])) start--;
    while (end < ceiling && WordCharacter([text characterAtIndex:end-1]) &&
           WordCharacter([text characterAtIndex:end])) end++;
    start = MAX(start,MIN(after,hit.location));
    return [text rangeOfComposedCharacterSequencesForRange:NSMakeRange(start,end-start)];
}
static NSDictionary* Context(NSDictionary* page, NSString* text, NSString* query, NSRange window) {
    NSString* prefix = window.location ? @"… " : @"";
    NSString* suffix = NSMaxRange(window) < text.length ? @" …" : @"";
    NSMutableString* snippet = [[text substringWithRange:window] mutableCopy];
    // Replace one UTF-16 unit with one space so highlights keep exact offsets.
    for (NSUInteger i = 0; i < snippet.length; i++)
        if ([NSCharacterSet.newlineCharacterSet characterIsMember:[snippet characterAtIndex:i]])
            [snippet replaceCharactersInRange:NSMakeRange(i,1) withString:@" "];
    NSMutableArray* ranges = [NSMutableArray array];
    NSMutableArray* pageRanges = [NSMutableArray array];
    NSMutableArray* canonicalRanges = [NSMutableArray array];
    NSUInteger cursor = window.location;
    while (cursor < NSMaxRange(window)) {
        NSRange hit = [text rangeOfString:query options:MatchOptions
            range:NSMakeRange(cursor,NSMaxRange(window)-cursor)];
        if (hit.location == NSNotFound || !hit.length) break;
        [ranges addObject:[NSValue valueWithRange:NSMakeRange(prefix.length+hit.location-window.location,hit.length)]];
        [pageRanges addObject:[NSValue valueWithRange:hit]];
        if ([page[@"canonicalLocation"] isKindOfClass:NSNumber.class]) {
            NSUInteger origin = [page[@"canonicalLocation"] unsignedIntegerValue];
            if (origin <= NSUIntegerMax-NSMaxRange(hit))
                [canonicalRanges addObject:[NSValue valueWithRange:NSMakeRange(origin+hit.location,hit.length)]];
        }
        cursor = NSMaxRange(hit);
    }
    NSNumber* pageNumber = [page[@"page"] isKindOfClass:NSNumber.class] ? page[@"page"] : @0;
    NSMutableDictionary* result = [@{@"page":@(MAX(0,pageNumber.integerValue)),@"query":query,
        @"snippet":[NSString stringWithFormat:@"%@%@%@",prefix,snippet,suffix],@"ranges":ranges,
        @"pageRanges":pageRanges,@"snippetRange":[NSValue valueWithRange:window]} mutableCopy];
    if (canonicalRanges.count == pageRanges.count && canonicalRanges.count)
        result[@"canonicalRanges"] = canonicalRanges;
    return result;
}
static NSDictionary* SearchVersion(NSDictionary* index, NSDictionary* version, NSString* query) {
    NSMutableArray* contexts = [NSMutableArray array];
    NSUInteger count = 0;
    BOOL truncated = NO, available = NO;
    NSArray* pages = [index[@"textPages"] isKindOfClass:NSArray.class] ? index[@"textPages"] : @[];
    for (id value in pages) {
        if (![value isKindOfClass:NSDictionary.class]) continue;
        NSDictionary* page = value;
        NSString* text = page[@"text"];
        if (![text isKindOfClass:NSString.class] || !text.length) continue;
        available = YES;
        NSMutableArray<NSValue*>* windows = [NSMutableArray array];
        NSUInteger cursor = 0, coveredUntil = 0;
        while (cursor < text.length) {
            NSRange hit = [text rangeOfString:query options:MatchOptions range:NSMakeRange(cursor,text.length-cursor)];
            if (hit.location == NSNotFound || !hit.length) break;
            count++;
            if (NSMaxRange(hit) > coveredUntil) {
                if (contexts.count+windows.count < ContextLimit) {
                    NSRange window = ContextRange(text,hit,coveredUntil);
                    [windows addObject:[NSValue valueWithRange:window]];
                    coveredUntil = NSMaxRange(window);
                } else truncated = YES;
            }
            cursor = NSMaxRange(hit);
        }
        for (NSValue* window in windows) [contexts addObject:Context(page,text,query,window.rangeValue)];
    }
    return @{@"version":version,@"matches":contexts,@"matchCount":@(count),
             @"truncated":@(truncated),@"textAvailable":@(available)};
}
@implementation SPDFMacCollectionStore (ContextSearch)
- (NSArray<NSDictionary*>*)searchGroups:(NSString*)query allVersions:(BOOL)allVersions {
    query = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!query.length) return @[];
    NSMutableArray* groups = [NSMutableArray array];
    for (NSDictionary* document in [self documents]) {
        NSArray* versions = document[@"versions"];
        if (![versions isKindOfClass:NSArray.class] || !versions.count) continue;
        NSMutableArray* results = [NSMutableArray array];
        NSUInteger newest = versions.count-1;
        for (NSUInteger index = versions.count; index > 0; index--) {
            NSDictionary* version = versions[index-1];
            if (![version isKindOfClass:NSDictionary.class]) continue;
            NSString* title = [version[@"filename"] isKindOfClass:NSString.class]
                ? version[@"filename"] : document[@"title"];
            BOOL titleMatch = [title isKindOfClass:NSString.class] &&
                [title rangeOfString:query options:MatchOptions].location != NSNotFound;
            // Use retained indexes only: searching cannot materialize archives,
            // open source PDFs, invoke Markdown rendering or create directories.
            NSDictionary* text = [version[@"encrypted"] boolValue] ? @{} : [self textIndexForVersion:version];
            NSMutableDictionary* result = [SearchVersion(text,version,query) mutableCopy];
            if (titleMatch || [result[@"matchCount"] unsignedIntegerValue]) {
                result[@"titleMatch"] = @(titleMatch);
                result[@"latest"] = @(index-1 == newest);
                [results addObject:result];
            }
            if (!allVersions) break;
        }
        if (results.count) [groups addObject:@{@"document":document,@"versions":results}];
    }
    return groups;
}
@end
