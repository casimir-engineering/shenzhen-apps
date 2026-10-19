#import "SPDFMacCollectionPaletteModel.h"
#import "SPDFMacPaletteDocumentNames.h"
#import <float.h>

static NSString* Text(id value) { return [value isKindOfClass:NSString.class] ? value : @""; }
static NSNumber* Number(id value) { return [value isKindOfClass:NSNumber.class] ? value : @0; }
static NSString* PathKey(NSString* path) {
    NSString* key = path.stringByStandardizingPath;
    return key.length ? key : (path ?: @"");
}
// Name matches outrank path context; every query word must occur, in any order.
// Pure string matching keeps this on the immediate, disk-free palette path.
static NSInteger MatchRank(NSString* query, NSString* title, NSString* path) {
    NSArray* words = [[query componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString* word, NSDictionary* _) {
            (void)_; return word.length > 0;
        }]];
    if (!words.count) return 0;
    NSString* phrase = [words componentsJoinedByString:@" "];
    NSStringCompareOptions folded = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;
    NSInteger best = NSNotFound;
    // A title is matched whole ("A/B testing"); one that is itself a path, from
    // an older saved window, by its last component.
    NSString* name = [title hasPrefix:@"/"] ? title.lastPathComponent : title;
    for (NSString* value in @[name ?: @"", path.lastPathComponent ?: @""]) {
        NSString* stem = value.stringByDeletingPathExtension;
        if ([value compare:phrase options:folded] == NSOrderedSame ||
            [stem compare:phrase options:folded] == NSOrderedSame) return 0;
        NSRange range = [value rangeOfString:phrase options:folded];
        if (range.location != NSNotFound) best = MIN(best,range.location == 0 ? 1 : 2);
        BOOL all = YES;
        for (NSString* word in words)
            if ([value rangeOfString:word options:folded].location == NSNotFound) { all = NO; break; }
        if (all) best = MIN(best,3);
    }
    if (best != NSNotFound) return best;
    NSString* context = [NSString stringWithFormat:@"%@ %@",title ?: @"",path ?: @""];
    for (NSString* word in words)
        if ([context rangeOfString:word options:folded].location == NSNotFound) return NSNotFound;
    return 4;
}
static NSComparisonResult RankRows(NSDictionary* left, NSDictionary* right) {
    NSComparisonResult rank = [Number(left[@"_rank"]) compare:Number(right[@"_rank"])];
    if (rank != NSOrderedSame) return rank;
    NSComparisonResult viewed = [Number(right[@"_viewedAt"]) compare:Number(left[@"_viewedAt"])];
    if (viewed != NSOrderedSame) return viewed;
    NSComparisonResult recent = [Number(right[@"focusedAt"]) compare:Number(left[@"focusedAt"])];
    if (recent != NSOrderedSame) return recent;
    NSComparisonResult order = [Number(left[@"_order"]) compare:Number(right[@"_order"])];
    if (order != NSOrderedSame) return order;
    return [Text(left[@"title"]) localizedCaseInsensitiveCompare:Text(right[@"title"])];
}

NSDictionary* spdf_collection_palette_query(NSString* rawQuery) {
    NSString* raw = [Text(rawQuery) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    BOOL scoped = [raw.lowercaseString hasPrefix:@"col:"];
    NSString* query = scoped ? [raw substringFromIndex:4] : raw;
    query = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return @{@"collectionOnly":@(scoped), @"query":query};
}

NSString* spdf_collection_palette_single_line(NSString* text) {
    NSArray* words = [Text(text) componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [[words filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString* word, NSDictionary* _) {
      (void)_; return word.length > 0;
    }]] componentsJoinedByString:@" "];
}

static NSArray<NSDictionary*>* SessionCandidates(id sessionObject) {
    if (![sessionObject isKindOfClass:NSDictionary.class]) return @[];
    NSArray* windows = [sessionObject[@"windows"] isKindOfClass:NSArray.class] ? sessionObject[@"windows"] : @[];
    NSMutableArray* results = [NSMutableArray array];
    NSUInteger order = 0;
    for (NSDictionary* window in windows) {
        if (![window isKindOfClass:NSDictionary.class]) continue;
        NSNumber* focusedAt = Number(window[@"focusedAt"]);
        NSArray* tabs = [window[@"tabs"] isKindOfClass:NSArray.class] ? window[@"tabs"] : @[];
        for (NSDictionary* tab in tabs) {
            if (![tab isKindOfClass:NSDictionary.class]) continue;
            NSString* path = Text(tab[@"path"]); if (!path.length) continue;
            // A saved title that is a path predates clean tab titles; name the file instead.
            NSString* saved = [Text(tab[@"title"]) containsString:@"/"] ? @"" : Text(tab[@"title"]);
            NSString* label = Text(tab[@"collectionVersionLabel"]);
            NSMutableDictionary* row = [@{@"path":path,
                @"title":label.length || !saved.length ? spdf_palette_document_title(path, label, nil) : saved,
                @"focusedAt":focusedAt, @"lastViewedAt":Number(tab[@"lastViewedAt"]), @"_order":@(order++),
                @"markdownLandscape":@([tab[@"markdownLandscape"] boolValue])} mutableCopy];
            if ([tab[@"group"] isKindOfClass:NSDictionary.class]) row[@"group"] = tab[@"group"];
            for (NSString* key in @[@"collectionVersionLabel", @"collectionHistoryID"])
                if (Text(tab[key]).length) row[key] = tab[key];
            [results addObject:row];
        }
    }
    return results;
}

NSArray<NSDictionary*>* spdf_collection_palette_open_candidates(NSArray<NSDictionary*>* liveCandidates,
                                                                 id sessionObject) {
    NSMutableArray* results = [NSMutableArray array];
    NSMutableDictionary<NSString*, NSNumber*>* indices = [NSMutableDictionary dictionary];
    NSArray* sources = @[@{ @"items":liveCandidates ?: @[], @"live":@YES },
                         @{ @"items":SessionCandidates(sessionObject), @"live":@NO }];
    NSUInteger order = 0;
    for (NSDictionary* source in sources) for (NSDictionary* raw in source[@"items"]) {
        if (![raw isKindOfClass:NSDictionary.class]) continue;
        NSString* path = Text(raw[@"path"]); if (!path.length) continue;
        NSString* key = PathKey(path); NSNumber* existing = indices[key];
        if (existing) {
            NSMutableDictionary* row = [results[existing.unsignedIntegerValue] mutableCopy];
            for (NSString* field in @[@"group", @"markdownLandscape", @"focusedAt", @"lastViewedAt", @"_current"])
                if (!row[field] && raw[field]) row[field] = raw[field];
            if ([Number(raw[@"focusedAt"]) doubleValue] > [Number(row[@"focusedAt"]) doubleValue])
                row[@"focusedAt"] = raw[@"focusedAt"];
            results[existing.unsignedIntegerValue] = row;
            continue;
        }
        NSMutableDictionary* row = [raw mutableCopy];
        row[@"path"] = path; row[@"_order"] = @(order++);
        if (!Text(row[@"title"]).length) row[@"title"] = spdf_palette_document_title(path, nil, nil);
        if ([source[@"live"] boolValue]) { row[@"focusedAt"] = @(DBL_MAX); row[@"_live"] = @YES; }
        indices[key] = @(results.count); [results addObject:row];
    }
    return results;
}

NSSet<NSString*>* spdf_collection_palette_open_paths(NSArray<NSDictionary*>* candidates) {
    NSMutableSet* paths = [NSMutableSet set];
    for (NSDictionary* candidate in candidates ?: @[]) {
        NSString* path = Text(candidate[@"path"]); if (path.length) [paths addObject:PathKey(path)];
        if (Text(candidate[@"originalPath"]).length) [paths addObject:PathKey(candidate[@"originalPath"])];
        NSArray* merged = [candidate[@"mergedPaths"] isKindOfClass:NSArray.class] ? candidate[@"mergedPaths"] : @[];
        for (NSString* other in merged) if (Text(other).length) [paths addObject:PathKey(other)];
    }
    return paths;
}

NSArray<NSDictionary*>* spdf_collection_palette_open_name_rows(NSArray<NSDictionary*>* candidates,
                                                                NSString* query) {
    NSMutableArray* ranked = [NSMutableArray array];
    for (NSDictionary* candidate in candidates ?: @[]) {
        NSString* path = Text(candidate[@"path"]), *title = Text(candidate[@"title"]);
        // With nothing typed the list is for switching; the document already in
        // front is not somewhere to switch to.
        if (!query.length && [candidate[@"_current"] boolValue]) continue;
        NSInteger rank = MatchRank(query, title, path); if (rank == NSNotFound) continue;
        NSMutableDictionary* row = [candidate mutableCopy];
        row[@"kind"] = @"openDoc"; row[@"title"] = title.length ? title : spdf_palette_document_title(path, nil, nil);
        row[@"_rank"] = @(rank); row[@"_viewedAt"] = query.length ? @0 : Number(candidate[@"lastViewedAt"]);
        [ranked addObject:row];
    }
    [ranked sortUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) { return RankRows(a, b); }];
    return ranked;
}

NSArray<NSDictionary*>* spdf_collection_palette_group_rows(id sessionObject, NSString* query) {
    NSMutableDictionary<NSString*, NSMutableDictionary*>* groups = [NSMutableDictionary dictionary];
    NSUInteger order = 0;
    for (NSDictionary* candidate in SessionCandidates(sessionObject)) {
        NSDictionary* group = [candidate[@"group"] isKindOfClass:NSDictionary.class] ? candidate[@"group"] : nil;
        NSString* identifier = Text(group[@"id"]); if (!identifier.length) continue;
        NSMutableDictionary* row = groups[identifier];
        if (!row) {
            NSString* name = Text(group[@"name"]), *color = Text(group[@"color"]);
            NSString* title = name.length ? name : [identifier isEqual:@"general"] ? @"General" : color;
            NSInteger rank = MatchRank(query, title, @""); if (rank == NSNotFound) continue;
            row = [@{@"kind":@"collectionGroup", @"title":title.length ? title : @"Group",
                @"color":color.length ? color : @"Gray", @"path":Text(group[@"lastUsedPath"]),
                @"focusedAt":Number(candidate[@"focusedAt"]), @"count":@0,
                @"_rank":@(rank), @"_order":@(order++)} mutableCopy];
            groups[identifier] = row;
        }
        row[@"count"] = @([row[@"count"] unsignedIntegerValue] + 1);
        if (!Text(row[@"path"]).length) row[@"path"] = candidate[@"path"];
        if ([Number(candidate[@"focusedAt"]) doubleValue] > [Number(row[@"focusedAt"]) doubleValue])
            row[@"focusedAt"] = candidate[@"focusedAt"];
    }
    NSMutableArray* rows = [groups.allValues mutableCopy];
    for (NSMutableDictionary* row in rows)
        row[@"subtitle"] = [NSString stringWithFormat:@"%@ group · %@ tabs", row[@"color"], row[@"count"]];
    [rows sortUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) { return RankRows(a, b); }];
    return rows;
}

static NSArray* FirstFive(NSArray* rows) { return rows.count > 5 ? [rows subarrayWithRange:NSMakeRange(0, 5)] : rows; }
static NSString* PageKey(NSDictionary* hit) {
    NSString* path = Text(hit[@"path"]);
    return path.length ? [NSString stringWithFormat:@"%@|%@", PathKey(path), hit[@"page"] ?: @""] : @"";
}
static void AddSection(NSMutableArray* rows, NSString* name, NSArray* content) {
    if (!content.count) return;
    [rows addObject:@{@"kind":@"header", @"title":name, @"subtitle":@""}];
    [rows addObjectsFromArray:content];
}
NSArray<NSDictionary*>* spdf_collection_palette_rows(BOOL collectionOnly, NSString* query,
                                                      NSArray<NSDictionary*>* openNames,
                                                      NSArray<NSDictionary*>* groups,
                                                      NSArray<NSDictionary*>* openText,
                                                      NSArray<NSDictionary*>* collectionNames,
                                                      NSArray<NSDictionary*>* collectionText,
                                                      BOOL showAll) {
    NSMutableArray* rows = [NSMutableArray array];
    if (!collectionOnly) {
        AddSection(rows, @"Open documents", openNames);
        AddSection(rows, @"Tab groups", groups);
        AddSection(rows, @"Text in open documents", FirstFive(openText));
    }
    AddSection(rows, @"Collection documents", FirstFive(collectionNames));
    // A page already listed from the open document is not listed again from the Collection.
    NSMutableSet* openPages = [NSMutableSet set];
    for (NSDictionary* hit in collectionOnly ? @[] : openText ?: @[])
        if (PageKey(hit).length) [openPages addObject:PageKey(hit)];
    NSMutableArray* savedText = [NSMutableArray array];
    for (NSDictionary* hit in collectionText ?: @[])
        if (![openPages containsObject:PageKey(hit)]) [savedText addObject:hit];
    AddSection(rows, @"Text in Collection", FirstFive(savedText));
    if (collectionOnly && showAll)
        [rows addObject:@{@"kind":@"collectionShowAll", @"title":@"Show all in Collection…",
                          @"subtitle":query ?: @"", @"query":query ?: @""}];
    return rows;
}

NSDictionary* spdf_collection_palette_chat_row(NSString* query) {
    NSString* text = spdf_collection_palette_single_line(query);
    NSString* title = text.length ? [NSString stringWithFormat:@"Ask AI about \u201C%@\u201D\u2026", text]
                                  : @"Chat with your documents";
    return @{@"kind":@"askAI", @"title":title, @"shortcut":@"\u2318\u21A9"};
}

BOOL spdf_collection_palette_can_publish(NSProgress* progress, NSUInteger generation,
                                         NSUInteger currentGeneration, BOOL visible) {
    return !progress.cancelled && generation == currentGeneration && visible;
}
