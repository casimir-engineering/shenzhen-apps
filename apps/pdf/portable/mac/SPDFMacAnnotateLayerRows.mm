// What the Layers panel lists and what a dropped row asks for (SPDFMacAnnotateLayerRows.h).
#import "SPDFMacAnnotateLayerRows.h"

static double SPDFLayerRowOpacity(NSDictionary* entry) {
    return [entry[@"opacity"] respondsToSelector:@selector(doubleValue)] ? [entry[@"opacity"] doubleValue] : 100;
}

NSArray<NSDictionary*>* SPDFAnnotateLayerRows(NSDictionary* state, NSSet<NSNumber*>* folded) {
    NSMutableArray* rows = [NSMutableArray array];
    BOOL pdf = [state[@"kind"] isEqual:@"pdf"];
    for (NSDictionary* layer in [[state[@"layers"] isKindOfClass:[NSArray class]] ? state[@"layers"] : @[] reverseObjectEnumerator]) {
        if (![layer isKindOfClass:[NSDictionary class]] || ![layer[@"id"] isKindOfClass:[NSNumber class]]) continue;
        BOOL base = [layer[@"kind"] isEqual:@"background"];
        NSArray* objects = [layer[@"objects"] isKindOfClass:[NSArray class]] ? layer[@"objects"] : @[];
        BOOL fold = [folded containsObject:layer[@"id"]];
        [rows addObject:@{
            @"id" : layer[@"id"], @"base" : @(base), @"object" : @NO, @"count" : @(objects.count), @"folded" : @(fold),
            @"name" : [layer[@"name"] isKindOfClass:[NSString class]] ? layer[@"name"] : @"",
            @"visible" : @(layer[@"visible"] ? [layer[@"visible"] boolValue] : YES), @"opacity" : @(SPDFLayerRowOpacity(layer)),
            @"locked" : @([layer[@"locked"] boolValue]), @"page" : @(base && pdf),
            @"canvas" : @(base && [state[@"kind"] isEqual:@"canvas"]),
        }];
        if (fold) continue;
        for (NSDictionary* object in objects.reverseObjectEnumerator) {
            if (![object isKindOfClass:[NSDictionary class]] || ![object[@"id"] isKindOfClass:[NSNumber class]]) continue;
            [rows addObject:@{
                @"id" : object[@"id"], @"base" : @NO, @"object" : @YES, @"layer" : layer[@"id"], @"count" : @0,
                @"name" : [object[@"name"] isKindOfClass:[NSString class]] ? object[@"name"] : @"",
                @"visible" : @(object[@"visible"] ? [object[@"visible"] boolValue] : YES),
                @"opacity" : @(SPDFLayerRowOpacity(object)), @"locked" : @([object[@"locked"] boolValue]), @"page" : @NO,
            }];
        }
    }
    return rows;
}

NSIndexSet* SPDFAnnotateRowsLeft(NSArray<NSDictionary*>* from, NSArray<NSDictionary*>* to) {
    if (to.count > from.count) return nil;
    NSMutableIndexSet* left = [NSMutableIndexSet indexSet];
    NSUInteger j = 0;
    for (NSUInteger i = 0; i < from.count; ++i) {
        BOOL same = j < to.count && [from[i][@"id"] isEqual:to[j][@"id"]] && [from[i][@"object"] isEqual:to[j][@"object"]];
        if (same) j++;
        else [left addIndex:i];
    }
    return j == to.count ? left : nil;
}

NSDictionary* SPDFAnnotateLayerDrop(NSArray<NSDictionary*>* rows, NSInteger from, NSInteger row) {
    NSInteger count = (NSInteger)rows.count;
    if (from < 0 || from >= count || row < 0 || row > count || row == from || row == from + 1) return nil;
    NSDictionary* moved = rows[from];
    NSInteger below = 0;  // rows of the same kind under the drop point: the new position, counted from the bottom
    if (![moved[@"object"] boolValue]) {
        for (NSInteger i = row; i < count; ++i)
            if (i != from && ![rows[i][@"object"] boolValue] && ![rows[i][@"base"] boolValue]) below++;
        return @{@"op" : @"layer.order", @"id" : moved[@"id"], @"to" : @(below)};
    }
    NSDictionary* into = nil;  // the layer whose row is nearest above the drop point, else the top layer
    for (NSInteger i = row - 1; i >= 0 && !into; --i)
        if (![rows[i][@"object"] boolValue]) into = rows[i];
    for (NSInteger i = 0; !into && i < count; ++i)
        if (![rows[i][@"object"] boolValue]) into = rows[i];
    if (!into || [into[@"base"] boolValue] || [into[@"locked"] boolValue]) return nil;
    for (NSInteger i = row; i < count && [rows[i][@"object"] boolValue]; ++i)
        if (i != from && [rows[i][@"layer"] isEqual:into[@"id"]]) below++;
    return @{@"op" : @"object.layer", @"ids" : @[ moved[@"id"] ], @"layer" : into[@"id"], @"position" : @(below)};
}
