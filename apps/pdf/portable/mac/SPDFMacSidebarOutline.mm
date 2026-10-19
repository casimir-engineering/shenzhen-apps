#import "SPDFMacSidebarOutline.h"

// A level below the first row's would make that row a child of nothing; the
// list is normalised against the shallowest level present so a document whose
// outline starts at, say, level 2 still nests from its own root.
static NSInteger SPDFOutlineLevelAt(NSArray<NSNumber*>* levels, NSUInteger index) {
    if (index >= levels.count) return 0;
    return levels[index].integerValue;
}

BOOL spdf_sidebar_outline_has_children(NSArray<NSNumber*>* levels, NSUInteger index) {
    if (index + 1 >= levels.count) return NO;
    return SPDFOutlineLevelAt(levels, index + 1) > SPDFOutlineLevelAt(levels, index);
}

NSString* spdf_sidebar_outline_key(NSArray<NSNumber*>* levels, NSUInteger index) {
    if (index >= levels.count) return @"";
    // Walk forward keeping one ordinal per depth: each row increments the
    // ordinal at its own depth and drops anything deeper.
    NSMutableArray<NSNumber*>* ordinals = [NSMutableArray array];
    NSMutableArray<NSNumber*>* depths = [NSMutableArray array];
    for (NSUInteger i = 0; i <= index; ++i) {
        NSInteger level = SPDFOutlineLevelAt(levels, i);
        while (depths.count > 0 && depths.lastObject.integerValue > level) {
            [depths removeLastObject];
            [ordinals removeLastObject];
        }
        if (depths.count > 0 && depths.lastObject.integerValue == level) {
            ordinals[ordinals.count - 1] = @(ordinals.lastObject.integerValue + 1);
        } else {
            [depths addObject:@(level)];
            [ordinals addObject:@0];
        }
    }
    NSMutableString* key = [NSMutableString string];
    for (NSNumber* ordinal in ordinals) {
        if (key.length) [key appendString:@"."];
        [key appendFormat:@"%ld", (long)ordinal.integerValue];
    }
    return key;
}

NSIndexSet* spdf_sidebar_outline_visible_indexes(NSArray<NSNumber*>* levels, NSSet<NSString*>* collapsedKeys) {
    NSMutableIndexSet* visible = [NSMutableIndexSet indexSet];
    // The level of the shallowest collapsed ancestor currently hiding rows.
    // Anything deeper than it stays hidden until a row at or above it appears.
    BOOL hiding = NO;
    NSInteger hidingLevel = 0;
    for (NSUInteger i = 0; i < levels.count; ++i) {
        NSInteger level = SPDFOutlineLevelAt(levels, i);
        if (hiding && level <= hidingLevel) hiding = NO;
        if (!hiding) {
            [visible addIndex:i];
            if (collapsedKeys.count > 0 && spdf_sidebar_outline_has_children(levels, i) &&
                [collapsedKeys containsObject:spdf_sidebar_outline_key(levels, i)]) {
                hiding = YES;
                hidingLevel = level;
            }
        }
    }
    return visible;
}

NSSet<NSString*>* spdf_sidebar_outline_collapsible_keys(NSArray<NSNumber*>* levels) {
    NSMutableSet<NSString*>* keys = [NSMutableSet set];
    for (NSUInteger i = 0; i < levels.count; ++i) {
        if (spdf_sidebar_outline_has_children(levels, i)) [keys addObject:spdf_sidebar_outline_key(levels, i)];
    }
    return keys;
}
