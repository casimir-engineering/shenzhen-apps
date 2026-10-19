#import "SPDFMacPaletteResults.h"

#import <AppKit/AppKit.h>

static NSString* spdf_palette_standardized_path(NSString* path) {
    NSString* standardized = path.stringByStandardizingPath;
    return standardized.length ? standardized : (path ?: @"");
}

BOOL spdf_palette_open_document_matches_query(NSString* query, NSString* title, NSString* path) {
    if (query.length == 0) return YES;
    NSStringCompareOptions options = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;
    if (title.length && [title rangeOfString:query options:options].location != NSNotFound) return YES;
    NSString* fileName = path.lastPathComponent;
    return fileName.length && [fileName rangeOfString:query options:options].location != NSNotFound;
}

NSArray<NSDictionary*>* spdf_palette_open_document_results(NSArray<NSDictionary*>* candidates, NSString* query) {
    NSMutableArray<NSDictionary*>* results = [NSMutableArray array];
    NSMutableSet<NSString*>* seenPaths = [NSMutableSet set];
    for (NSDictionary* candidate in candidates ?: @[]) {
        NSString* path = [candidate[@"path"] isKindOfClass:NSString.class] ? candidate[@"path"] : @"";
        if (!path.length) continue;
        NSString* key = spdf_palette_standardized_path(path);
        if ([seenPaths containsObject:key]) continue;
        NSString* title = [candidate[@"title"] isKindOfClass:NSString.class] ? candidate[@"title"] : @"";
        if (!spdf_palette_open_document_matches_query(query, title, path)) continue;
        [seenPaths addObject:key];
        [results addObject:candidate];
    }
    return results;
}

// Display name for the key itself (without modifiers): special keys map to
// their conventional macOS symbols, everything else is shown uppercased.
static NSString* spdf_palette_key_equivalent_key_name(unichar key, NSString* keyEquivalent) {
    switch (key) {
        case NSUpArrowFunctionKey:
            return @"\u2191";  // ↑
        case NSDownArrowFunctionKey:
            return @"\u2193";  // ↓
        case NSLeftArrowFunctionKey:
            return @"\u2190";  // ←
        case NSRightArrowFunctionKey:
            return @"\u2192";  // →
        case NSHomeFunctionKey:
            return @"\u2196";  // ↖
        case NSEndFunctionKey:
            return @"\u2198";  // ↘
        case NSPageUpFunctionKey:
            return @"\u21DE";  // ⇞
        case NSPageDownFunctionKey:
            return @"\u21DF";  // ⇟
        case NSDeleteFunctionKey:
            return @"\u2326";  // ⌦
        case NSBackspaceCharacter:
        case NSDeleteCharacter:
            return @"\u232B";  // ⌫
        case NSCarriageReturnCharacter:
        case NSNewlineCharacter:
            return @"\u21A9";  // ↩
        case NSEnterCharacter:
            return @"\u2305";  // ⌅
        case NSTabCharacter:
            return @"\u21E5";  // ⇥
        case 0x1B:
            return @"\u238B";  // ⎋
        case ' ':
            return @"Space";
        default:
            break;
    }
    if (key >= NSF1FunctionKey && key <= NSF35FunctionKey)
        return [NSString stringWithFormat:@"F%d", (int)(key - NSF1FunctionKey) + 1];
    return keyEquivalent.uppercaseString;
}

NSString* spdf_palette_key_equivalent_display_string(NSString* keyEquivalent, NSUInteger modifierMask) {
    if (keyEquivalent.length == 0) return @"";
    unichar key = [keyEquivalent characterAtIndex:0];
    BOOL shift = (modifierMask & NSEventModifierFlagShift) != 0;
    // An uppercase-letter key equivalent means Shift, exactly as menus treat it.
    if (!shift && keyEquivalent.length == 1 && ![keyEquivalent isEqualToString:keyEquivalent.lowercaseString])
        shift = YES;
    NSMutableString* display = [NSMutableString string];
    if (modifierMask & NSEventModifierFlagControl) [display appendString:@"\u2303"];  // ⌃
    if (modifierMask & NSEventModifierFlagOption) [display appendString:@"\u2325"];   // ⌥
    if (shift) [display appendString:@"\u21E7"];                                      // ⇧
    if (modifierMask & NSEventModifierFlagCommand) [display appendString:@"\u2318"];  // ⌘
    [display appendString:spdf_palette_key_equivalent_key_name(key, keyEquivalent)];
    return display;
}

NSString* spdf_palette_menu_breadcrumb(NSArray<NSString*>* menuTitles, NSString* itemTitle) {
    NSMutableArray<NSString*>* components = [NSMutableArray array];
    for (NSString* title in menuTitles ?: @[]) {
        if (title.length) [components addObject:title];
    }
    if (itemTitle.length) [components addObject:itemTitle];
    return [components componentsJoinedByString:@" \u25B8 "];  // ▸
}

BOOL spdf_palette_menu_command_matches_query(NSString* query, NSString* title, NSString* breadcrumb) {
    if (query.length == 0) return YES;
    NSStringCompareOptions options = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;
    if (title.length && [title rangeOfString:query options:options].location != NSNotFound) return YES;
    return breadcrumb.length && [breadcrumb rangeOfString:query options:options].location != NSNotFound;
}

NSArray<NSDictionary*>* spdf_palette_menu_commands_excluding_selectors(NSArray<NSDictionary*>* menuCommands,
                                                                       NSSet<NSString*>* excludedSelectors) {
    if (excludedSelectors.count == 0) return menuCommands ?: @[];
    NSMutableArray<NSDictionary*>* results = [NSMutableArray array];
    for (NSDictionary* command in menuCommands ?: @[]) {
        NSString* selector = [command[@"selector"] isKindOfClass:NSString.class] ? command[@"selector"] : @"";
        if (selector.length && [excludedSelectors containsObject:selector]) continue;
        [results addObject:command];
    }
    return results;
}

BOOL spdf_palette_query_reveals_all_favorites(NSString* query) {
    NSString* trimmed = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length < 3) return NO;
    NSRange range = [@"favorites" rangeOfString:trimmed
                                        options:NSCaseInsensitiveSearch | NSAnchoredSearch];
    return range.location == 0;
}

NSArray<NSDictionary*>* spdf_palette_favorites_without_open_documents(NSArray<NSDictionary*>* favoriteResults,
                                                                      NSSet<NSString*>* openStandardizedPaths) {
    if (openStandardizedPaths.count == 0) return favoriteResults ?: @[];
    NSMutableArray<NSDictionary*>* results = [NSMutableArray array];
    for (NSDictionary* result in favoriteResults ?: @[]) {
        NSDictionary* favorite = [result[@"favorite"] isKindOfClass:NSDictionary.class] ? result[@"favorite"] : nil;
        BOOL documentLevel = [favorite[@"type"] isKindOfClass:NSString.class] &&
                             [favorite[@"type"] isEqualToString:@"document"];
        NSString* path = [result[@"path"] isKindOfClass:NSString.class] ? result[@"path"] : @"";
        if (documentLevel && path.length &&
            [openStandardizedPaths containsObject:spdf_palette_standardized_path(path)])
            continue;
        [results addObject:result];
    }
    return results;
}

BOOL spdf_palette_row_is_selectable(NSDictionary* row) {
    if (![row isKindOfClass:NSDictionary.class]) return NO;
    NSString* kind = [row[@"kind"] isKindOfClass:NSString.class] ? row[@"kind"] : @"";
    return ![kind isEqualToString:@"header"] && ![kind isEqualToString:@"separator"] &&
           ![kind isEqualToString:@"status"];
}

NSInteger spdf_palette_boundary_row(NSArray<NSDictionary*>* rows, BOOL last) {
    NSInteger count = (NSInteger)rows.count;
    for (NSInteger step = 0; step < count; ++step) {
        NSInteger row = last ? count - 1 - step : step;
        if (spdf_palette_row_is_selectable(rows[(NSUInteger)row])) return row;
    }
    return -1;
}

NSInteger spdf_palette_row_after_move(NSArray<NSDictionary*>* rows, NSInteger current, NSInteger delta, BOOL wrap) {
    NSInteger count = (NSInteger)rows.count;
    if (delta == 0 || spdf_palette_boundary_row(rows, NO) < 0) return -1;
    BOOL highlighted = current >= 0 && current < count;
    if (wrap) {
        NSInteger row = highlighted ? current : (delta > 0 ? -1 : count);
        for (NSInteger step = 0; step < count; ++step) {
            row = ((row + delta) % count + count) % count;
            if (spdf_palette_row_is_selectable(rows[(NSUInteger)row])) return row;
        }
        return -1;
    }
    NSInteger target = MIN(MAX((highlighted ? current : -1) + delta, 0), count - 1);
    NSInteger direction = delta > 0 ? 1 : -1;
    // Land on the first row at or past the target; at the end, the last row.
    for (NSInteger row = target; row >= 0 && row < count; row += direction)
        if (spdf_palette_row_is_selectable(rows[(NSUInteger)row])) return row;
    for (NSInteger row = target; row >= 0 && row < count; row -= direction)
        if (spdf_palette_row_is_selectable(rows[(NSUInteger)row])) return row;
    return -1;
}

static NSString* spdf_palette_row_text(NSDictionary* row, NSString* key) {
    id value = row[key];
    return [value isKindOfClass:NSString.class] ? value : ([value respondsToSelector:@selector(stringValue)]
                                                               ? [value stringValue] : @"");
}

// A row with a document is the same row while it shows the same place in it;
// other rows are known by their titles.
static NSString* spdf_palette_row_key(NSDictionary* row) {
    NSString* path = spdf_palette_row_text(row, @"path");
    NSString* place = path.length ? [NSString stringWithFormat:@"%@|%@|%@", spdf_palette_standardized_path(path),
                                                               spdf_palette_row_text(row, @"page"),
                                                               spdf_palette_row_text(row, @"query")]
                                  : spdf_palette_row_text(row, @"title");
    return [NSString stringWithFormat:@"%@|%@", spdf_palette_row_text(row, @"kind"), place];
}

NSInteger spdf_palette_row_to_highlight(NSArray<NSDictionary*>* rows, NSDictionary* highlighted, BOOL movedByPerson) {
    NSInteger first = spdf_palette_boundary_row(rows, NO);
    if (!movedByPerson || ![highlighted isKindOfClass:NSDictionary.class]) return first;
    NSString* key = spdf_palette_row_key(highlighted);
    NSString* path = spdf_palette_standardized_path(spdf_palette_row_text(highlighted, @"path"));
    NSString* kind = spdf_palette_row_text(highlighted, @"kind");
    NSInteger merged = -1;
    for (NSInteger index = 0; index < (NSInteger)rows.count; ++index) {
        NSDictionary* row = rows[(NSUInteger)index];
        if (!spdf_palette_row_is_selectable(row)) continue;
        if ([spdf_palette_row_key(row) isEqualToString:key]) return index;
        NSArray* folded = [row[@"mergedPaths"] isKindOfClass:NSArray.class] ? row[@"mergedPaths"] : @[];
        if (merged >= 0 || !path.length || ![spdf_palette_row_text(row, @"kind") isEqualToString:kind]) continue;
        for (id other in folded)
            if ([other isKindOfClass:NSString.class] && [spdf_palette_standardized_path(other) isEqualToString:path])
                merged = index;
    }
    return merged >= 0 ? merged : first;
}
