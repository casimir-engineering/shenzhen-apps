#import "SPDFMacMarkdownCopyText.h"

#import "markdown/SPDFMarkdown.h"

// What one line of the canonical string is, for the purpose of deciding whether
// a blank line separates it from its neighbour.
typedef struct {
    NSInteger blockIndex;   // -1 when the line carries no block attribute
    BOOL tableRow;          // a table row: cells joined by tabs
    BOOL listItem;          // a list item (the renderer records each item as one block of kind ListItem)
} SPDFCopyLineKind;

static SPDFCopyLineKind SPDFCopyLineKindAt(NSAttributedString* canonical, NSUInteger location) {
    SPDFCopyLineKind kind = {-1, NO, NO};
    if (location >= canonical.length) return kind;
    NSDictionary* attributes = [canonical attributesAtIndex:location effectiveRange:NULL];
    NSNumber* block = attributes[SPDFMarkdownBlockIndexAttribute];
    NSNumber* blockKind = attributes[SPDFMarkdownBlockKindAttribute];
    kind.blockIndex = block ? block.integerValue : -1;
    kind.tableRow = blockKind && blockKind.integerValue == SPDFMarkdownBlockKindTableRow;
    kind.listItem = blockKind && blockKind.integerValue == SPDFMarkdownBlockKindListItem;
    return kind;
}

// Blank line between two consecutive lines? Only across a block boundary, and
// not between the rows of one table or the items of one list.
static BOOL SPDFCopyBlankLineBetween(SPDFCopyLineKind previous, SPDFCopyLineKind next) {
    if (previous.blockIndex == next.blockIndex) return NO;
    if (previous.tableRow && next.tableRow) return NO;
    if (previous.listItem && next.listItem) return NO;
    return YES;
}

static NSString* SPDFCopyTrimTrailing(NSString* text) {
    NSUInteger end = text.length;
    while (end > 0 && [NSCharacterSet.whitespaceCharacterSet characterIsMember:[text characterAtIndex:end - 1]]) --end;
    return [text substringToIndex:end];
}

NSString* SPDFMacMarkdownCopyText(NSAttributedString* canonical, NSRange range,
                                  NSString* (^transform)(NSString* text)) {
    if (!canonical.length || NSMaxRange(range) > canonical.length || !range.length) return @"";
    NSString* whole = canonical.string;
    NSMutableString* out = [NSMutableString string];
    SPDFCopyLineKind previous = {-1, NO, NO};
    BOOL first = YES;
    NSUInteger cursor = range.location;
    NSUInteger end = NSMaxRange(range);
    while (cursor < end) {
        NSRange newline = [whole rangeOfString:@"\n" options:0 range:NSMakeRange(cursor, end - cursor)];
        NSUInteger lineEnd = newline.location == NSNotFound ? end : newline.location;
        NSString* line = [whole substringWithRange:NSMakeRange(cursor, lineEnd - cursor)];
        // Where the line's own attributes are read: its first non-tab character,
        // so a table row is judged by a cell and not by the separator before it.
        NSUInteger probe = cursor;
        while (probe < lineEnd && [whole characterAtIndex:probe] == '\t') ++probe;
        SPDFCopyLineKind kind = SPDFCopyLineKindAt(canonical, MIN(probe, lineEnd > cursor ? lineEnd - 1 : cursor));
        if (kind.tableRow && [line hasPrefix:@"\t"]) line = [line substringFromIndex:1];
        // The transform tidies INSIDE a cell (or a line), never across a tab or
        // a line break, which is what made the whole selection one line before.
        NSArray<NSString*>* cells = [line componentsSeparatedByString:@"\t"];
        NSMutableArray<NSString*>* tidy = [NSMutableArray arrayWithCapacity:cells.count];
        for (NSString* cell in cells)
            [tidy addObject:SPDFCopyTrimTrailing(transform ? (transform(cell) ?: cell) : cell)];
        line = [tidy componentsJoinedByString:@"\t"];
        if (!first) {
            [out appendString:@"\n"];
            if (SPDFCopyBlankLineBetween(previous, kind) && line.length) [out appendString:@"\n"];
        }
        [out appendString:line];
        first = NO;
        // A blank line of its own (a thematic break's reserved line) must not
        // also earn a separator: it keeps the previous block's identity.
        if (line.length) previous = kind;
        cursor = newline.location == NSNotFound ? end : lineEnd + 1;
    }
    // A selection that ends on a line break copies exactly one, as any text
    // view does; one that stops mid-line copies none.
    if ([whole characterAtIndex:end - 1] == '\n') [out appendString:@"\n"];
    return out;
}
