#import "SPDFMarkdownAuthoring.h"
#import "SPDFMarkdownTableDecorations.h"

static NSDictionary* SPDFRangeJSON(NSRange range) {
    return @{@"location":@(range.location), @"length":@(range.length)};
}
static NSRange SPDFReadRange(NSDictionary* value) {
    return NSMakeRange([value[@"location"] unsignedIntegerValue], [value[@"length"] unsignedIntegerValue]);
}
static NSDictionary* SPDFRectJSON(NSRect rect) {
    return @{@"x":@(NSMinX(rect)), @"y":@(NSMinY(rect)), @"width":@(NSWidth(rect)), @"height":@(NSHeight(rect))};
}
static NSString* SPDFKindName(SPDFMarkdownBlockKind kind) {
    switch (kind) {
        case SPDFMarkdownBlockKindHeading: return @"heading";
        case SPDFMarkdownBlockKindCode: return @"code";
        case SPDFMarkdownBlockKindTableRow: return @"table-row";
        case SPDFMarkdownBlockKindPageBreak: return @"page-break";
        case SPDFMarkdownBlockKindListItem: return @"list-item";
        case SPDFMarkdownBlockKindCallout: return @"callout";
        case SPDFMarkdownBlockKindThematicBreak: return @"thematic-break";
        default: return @"paragraph";
    }
}

// Fragments are sorted once in canonical order; each query then seeks directly
// to its range. Section nesting is bounded by Markdown's six heading levels.
static NSDictionary* SPDFPortions(NSRange range, NSArray<NSDictionary*>* fragments) {
    NSUInteger low = 0, high = fragments.count;
    while (low < high) {
        NSUInteger middle = low + (high - low) / 2;
        NSRange candidate = SPDFReadRange(fragments[middle][@"range"]);
        if (NSMaxRange(candidate) <= range.location) low = middle + 1;
        else high = middle;
    }
    NSMutableDictionary<NSNumber*, NSNumber*>* counts = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber*, NSValue*>* rects = [NSMutableDictionary dictionary];
    NSUInteger total = 0;
    for (NSUInteger i = low; i < fragments.count; ++i) {
        NSDictionary* fragment = fragments[i];
        NSRange candidate = SPDFReadRange(fragment[@"range"]);
        if (candidate.location >= NSMaxRange(range)) break;
        NSUInteger count = NSIntersectionRange(candidate, range).length;
        if (!count) continue;
        NSNumber* page = fragment[@"page"];
        counts[page] = @(counts[page].unsignedIntegerValue + count);
        total += count;
        NSDictionary* box = fragment[@"rect"];
        NSRect rect = NSMakeRect([box[@"x"] doubleValue], [box[@"y"] doubleValue],
            [box[@"width"] doubleValue], [box[@"height"] doubleValue]);
        rects[page] = [NSValue valueWithRect:rects[page] ? NSUnionRect(rects[page].rectValue, rect) : rect];
    }
    NSArray<NSNumber*>* pages = [counts.allKeys sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray* portions = [NSMutableArray array];
    for (NSNumber* page in pages)
        [portions addObject:@{@"page":page, @"characters":counts[page],
            @"fraction":@(total ? counts[page].doubleValue / total : 0), @"rect":SPDFRectJSON(rects[page].rectValue)}];
    return @{@"range":SPDFRangeJSON(range), @"pages":pages, @"portions":portions,
        @"split":@(pages.count > 1), @"sourceRange":NSNull.null};
}

NSDictionary* SPDFMarkdownLayoutReport(SPDFMarkdownDocumentModel* model,
    SPDFMarkdownRenderedDocument* rendered, SPDFMarkdownPaginationPlan* plan) {
    NSMutableArray* pages = [NSMutableArray array];
    NSMutableArray* allFragments = [NSMutableArray array];
    NSMutableArray* diagnostics = [NSMutableArray array];
    NSMutableSet* scaledBlocks = [NSMutableSet set];
    CGFloat contentWidth = NSWidth(plan.configuration.printableRect);
    CGFloat contentHeight = NSHeight(plan.configuration.printableRect);
    for (SPDFMarkdownPage* page in plan.pages) {
        NSMutableArray* fragments = [NSMutableArray array];
        for (SPDFMarkdownPageFragment* fragment in page.fragments) {
            if (!fragment.attributedRange.length || NSMaxRange(fragment.attributedRange) > rendered.attributedString.length)
                continue;
            CTLineRef line = SPDFMarkdownCreateFragmentLine(
                [rendered.attributedString attributedSubstringFromRange:fragment.attributedRange]);
            CGFloat width = MAX(0, CTLineGetTypographicBounds(line, NULL, NULL, NULL) - CTLineGetTrailingWhitespaceWidth(line));
            CFRelease(line);
            NSRect rect = NSMakeRect(fragment.xOffset, fragment.pageYOffset, width * fragment.scale, fragment.height);
            NSDictionary* entry = @{@"block":@(fragment.blockIndex), @"range":SPDFRangeJSON(fragment.attributedRange),
                @"rect":SPDFRectJSON(rect), @"scale":@(fragment.scale), @"page":@(page.pageIndex + 1)};
            [fragments addObject:entry];
            [allFragments addObject:entry];
            if (NSMaxX(rect) > contentWidth + 1 || NSMaxY(rect) > contentHeight + 1)
                [diagnostics addObject:@{@"kind":@"overflow", @"block":@(fragment.blockIndex),
                    @"page":@(page.pageIndex + 1), @"rect":SPDFRectJSON(rect)}];
            NSNumber* block = @(fragment.blockIndex);
            if (fragment.scale < 0.999 && ![scaledBlocks containsObject:block]) {
                [scaledBlocks addObject:block];
                [diagnostics addObject:@{@"kind":@"scaled-block", @"block":block,
                    @"page":@(page.pageIndex + 1), @"scale":@(fragment.scale)}];
            }
        }
        [pages addObject:@{@"page":@(page.pageIndex + 1), @"usedHeight":@(page.usedHeight), @"fragments":fragments}];
    }
    [allFragments sortUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
        return [a[@"range"][@"location"] compare:b[@"range"][@"location"]];
    }];
    NSMutableArray* blocks = [NSMutableArray array];
    NSMutableArray* headings = [NSMutableArray array];
    NSMutableDictionary<NSNumber*, NSValue*>* tableRanges = [NSMutableDictionary dictionary];
    for (SPDFMarkdownRenderedBlock* block in rendered.renderedBlocks) {
        NSMutableDictionary* entry = [SPDFPortions(block.attributedRange, allFragments) mutableCopy];
        entry[@"block"] = @(block.blockIndex);
        entry[@"kind"] = SPDFKindName(block.kind);
        if (block.diagramInfo) entry[@"kind"] = @"diagram";
        [blocks addObject:entry];
        if (block.kind == SPDFMarkdownBlockKindHeading) [headings addObject:block];
        if (block.kind == SPDFMarkdownBlockKindCode && [entry[@"split"] boolValue])
            [diagnostics addObject:@{@"kind":@"split-code", @"block":@(block.blockIndex), @"pages":entry[@"pages"]}];
        if (block.tableRowInfo) {
            NSNumber* key = @(block.tableRowInfo.tableBlockIndex);
            NSRange range = tableRanges[key] ? NSUnionRange(tableRanges[key].rangeValue, block.attributedRange) : block.attributedRange;
            tableRanges[key] = [NSValue valueWithRange:range];
        }
    }
    NSMutableArray* tables = [NSMutableArray array];
    for (NSNumber* key in [tableRanges.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSMutableDictionary* entry = [SPDFPortions(tableRanges[key].rangeValue, allFragments) mutableCopy];
        entry[@"block"] = key;
        [tables addObject:entry];
        if ([entry[@"split"] boolValue])
            [diagnostics addObject:@{@"kind":@"split-table", @"block":key, @"pages":entry[@"pages"]}];
    }
    NSMutableArray* sections = [NSMutableArray array];
    // Six-level reverse stack computes each section's end in O(headings).
    NSUInteger ends[7];
    for (NSUInteger level = 0; level < 7; ++level) ends[level] = rendered.attributedString.length;
    for (SPDFMarkdownRenderedBlock* heading in headings.reverseObjectEnumerator) {
        NSUInteger level = MIN((NSUInteger)6, MAX((NSUInteger)1, heading.level));
        NSUInteger end = ends[level];
        for (NSUInteger depth = level; depth < 7; ++depth) ends[depth] = heading.attributedRange.location;
        NSMutableDictionary* entry = [SPDFPortions(NSMakeRange(heading.attributedRange.location,
            end - heading.attributedRange.location), allFragments) mutableCopy];
        entry[@"block"] = @(heading.blockIndex);
        entry[@"level"] = @(level);
        entry[@"title"] = [model blockWithIndex:heading.blockIndex].plainText ?: @"";
        [sections addObject:entry];
    }
    SPDFMarkdownPageConfiguration* configuration = plan.configuration;
    return @{@"schemaVersion":@1, @"coordinateSpace":@"canonical-utf16", @"geometrySpace":@"printable-top-left-points",
        @"fractionBasis":@"visible-canonical-utf16-units", @"sourceOffsetsAvailable":@NO,
        @"sourcePath":model.sourceURL.path ?: NSNull.null, @"canonicalText":rendered.attributedString.string,
        @"paper":@{@"width":@(configuration.paperSize.width), @"height":@(configuration.paperSize.height),
            @"printableRect":SPDFRectJSON(configuration.printableRect), @"topContentInset":@(configuration.topContentInset)},
        @"pageCount":@(pages.count), @"pages":pages, @"blocks":blocks, @"tables":tables,
        @"sections":sections.reverseObjectEnumerator.allObjects, @"diagnostics":diagnostics};
}
