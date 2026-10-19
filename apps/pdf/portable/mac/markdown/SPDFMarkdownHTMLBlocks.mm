#import "SPDFMarkdownHTMLInternal.h"

// Block half of the HTML whitelist: classifies each MD_BLOCK_HTML island and
// translates its Gumbo DOM into ordinary model builders. Container-only
// islands (`<div align="center">` … markdown … `</div>`) become pushes/pops on
// the parser's block-format stack instead of DOM content, so an island pair
// that brackets several markdown blocks aligns all of them.

typedef struct {
    NSUInteger* nextIndex;
    NSUInteger* nodeCount;
} SPDFHTMLCounters;

static const NSUInteger kSPDFHTMLMaximumDepth = 40;

static SPDFMarkdownBlockBuilder* SPDFHTMLNewBuilder(SPDFMarkdownBlockKind kind,
                                                    SPDFMarkdownTableAlignment alignment,
                                                    SPDFHTMLCounters counters) {
    SPDFMarkdownBlockBuilder* builder = [SPDFMarkdownBlockBuilder new];
    builder.kind = kind;
    builder.index = (*counters.nextIndex)++;
    builder.blockAlignment = alignment;
    ++(*counters.nodeCount);
    return builder;
}

// HTML source whitespace (indentation, newlines between tags) collapses to
// single spaces, exactly like a browser's normal flow.
static NSString* SPDFHTMLCollapseWhitespace(const char* bytes) {
    NSString* text = bytes ? @(bytes) : @"";
    if (!text.length) return @"";
    NSCharacterSet* whitespace = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    NSMutableString* collapsed = [NSMutableString stringWithCapacity:text.length];
    BOOL pendingSpace = NO;
    for (NSUInteger i = 0; i < text.length; ++i) {
        unichar character = [text characterAtIndex:i];
        if ([whitespace characterIsMember:character]) {
            pendingSpace = collapsed.length > 0 || pendingSpace;
            continue;
        }
        if (pendingSpace) [collapsed appendString:@" "];
        pendingSpace = NO;
        [collapsed appendFormat:@"%C", character];
    }
    return collapsed;
}

static void SPDFHTMLAppendRun(SPDFMarkdownBlockBuilder* block, NSString* text,
                              SPDFMarkdownInlineTraits traits, NSString* destination,
                              NSString* title) {
    if (!text.length) return;
    [block.runs addObject:[[SPDFMarkdownInlineRun alloc] initWithText:text
                                                               traits:traits
                                                          destination:destination
                                                                title:title]];
}

// Drops leading/trailing whitespace runs so implicit paragraphs built from
// pretty-printed HTML do not start with stray spaces.
static void SPDFHTMLTrimRuns(SPDFMarkdownBlockBuilder* block) {
    NSCharacterSet* whitespace = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    while (block.runs.count) {
        SPDFMarkdownInlineRun* first = block.runs.firstObject;
        if (first.traits & SPDFMarkdownInlineTraitImage) break;
        NSString* trimmed = [first.text stringByTrimmingCharactersInSet:whitespace];
        if (trimmed.length == first.text.length) break;
        [block.runs removeObjectAtIndex:0];
        if (trimmed.length || (first.traits & SPDFMarkdownInlineTraitImage)) {
            NSString* stripped = first.text;
            while (stripped.length && [whitespace characterIsMember:[stripped characterAtIndex:0]])
                stripped = [stripped substringFromIndex:1];
            [block.runs insertObject:[[SPDFMarkdownInlineRun alloc] initWithText:stripped
                                                                          traits:first.traits
                                                                     destination:first.destination
                                                                           title:first.title]
                             atIndex:0];
            break;
        }
    }
    while (block.runs.count) {
        SPDFMarkdownInlineRun* last = block.runs.lastObject;
        if (last.traits & SPDFMarkdownInlineTraitImage) break;
        NSString* trimmed = [last.text stringByTrimmingCharactersInSet:whitespace];
        if (trimmed.length == last.text.length) break;
        [block.runs removeLastObject];
        if (trimmed.length) {
            NSString* stripped = last.text;
            while (stripped.length &&
                   [whitespace characterIsMember:[stripped characterAtIndex:stripped.length - 1]])
                stripped = [stripped substringToIndex:stripped.length - 1];
            [block.runs addObject:[[SPDFMarkdownInlineRun alloc] initWithText:stripped
                                                                       traits:last.traits
                                                                  destination:last.destination
                                                                        title:last.title]];
            break;
        }
    }
}

static void SPDFHTMLAppendInlineNode(const GumboNode* node, SPDFMarkdownBlockBuilder* block,
                                     SPDFMarkdownInlineTraits traits, NSString* destination,
                                     NSString* title, NSUInteger depth) {
    if (depth > kSPDFHTMLMaximumDepth) return;
    if (node->type == GUMBO_NODE_TEXT || node->type == GUMBO_NODE_WHITESPACE ||
        node->type == GUMBO_NODE_CDATA) {
        SPDFHTMLAppendRun(block, SPDFHTMLCollapseWhitespace(node->v.text.text), traits, destination, title);
        return;
    }
    if (node->type != GUMBO_NODE_ELEMENT) return;
    const GumboElement* element = &node->v.element;
    NSString* name = SPDFMarkdownHTMLElementName(element);
    switch (SPDFMarkdownHTMLClassifyTag(name)) {
        case SPDFMarkdownHTMLTagClassDropWithContent:
        case SPDFMarkdownHTMLTagClassDropVoid:
            return;
        case SPDFMarkdownHTMLTagClassLineBreak:
            SPDFHTMLAppendRun(block, @"\n", traits, destination, title);
            return;
        case SPDFMarkdownHTMLTagClassImage:
            SPDFMarkdownHTMLAppendImageRun(block, element, traits);
            return;
        case SPDFMarkdownHTMLTagClassAnchor: {
            NSString* href =
                SPDFMarkdownHTMLSanitizedLinkDestination(SPDFMarkdownHTMLAttribute(element, "href"));
            NSString* linkTitle = SPDFMarkdownHTMLAttribute(element, "title");
            SPDFMarkdownInlineTraits linkTraits =
                href ? traits | SPDFMarkdownInlineTraitLink : traits;
            for (unsigned int i = 0; i < element->children.length; ++i) {
                SPDFHTMLAppendInlineNode((const GumboNode*)element->children.data[i], block, linkTraits,
                                         href ?: destination, href && linkTitle.length ? linkTitle : title,
                                         depth + 1);
            }
            return;
        }
        case SPDFMarkdownHTMLTagClassInlineTrait:
        case SPDFMarkdownHTMLTagClassPassThrough:
            break;
    }
    SPDFMarkdownInlineTraits merged = traits | SPDFMarkdownHTMLTraitForTag(name);
    for (unsigned int i = 0; i < element->children.length; ++i) {
        SPDFHTMLAppendInlineNode((const GumboNode*)element->children.data[i], block, merged, destination,
                                 title, depth + 1);
    }
}

static void SPDFHTMLAppendInlineChildren(const GumboElement* element, SPDFMarkdownBlockBuilder* block,
                                         SPDFMarkdownInlineTraits traits, NSUInteger depth) {
    for (unsigned int i = 0; i < element->children.length; ++i)
        SPDFHTMLAppendInlineNode((const GumboNode*)element->children.data[i], block, traits, nil, nil, depth);
}

// Raw text of a <pre> subtree, whitespace preserved.
static void SPDFHTMLAppendRawText(const GumboNode* node, NSMutableString* out, NSUInteger depth) {
    if (depth > kSPDFHTMLMaximumDepth) return;
    if (node->type == GUMBO_NODE_TEXT || node->type == GUMBO_NODE_WHITESPACE ||
        node->type == GUMBO_NODE_CDATA) {
        if (node->v.text.text) [out appendString:@(node->v.text.text)];
        return;
    }
    if (node->type != GUMBO_NODE_ELEMENT) return;
    for (unsigned int i = 0; i < node->v.element.children.length; ++i)
        SPDFHTMLAppendRawText((const GumboNode*)node->v.element.children.data[i], out, depth + 1);
}

// The details/summary v1 contract: the summary renders as a distinct bold line
// prefixed with a disclosure triangle, and the details content always renders
// expanded below it (documented limitation).
static void SPDFHTMLAppendSummary(const GumboElement* element, NSMutableArray* out,
                                  SPDFMarkdownTableAlignment alignment, SPDFHTMLCounters counters,
                                  NSUInteger depth) {
    SPDFMarkdownBlockBuilder* summary =
        SPDFHTMLNewBuilder(SPDFMarkdownBlockKindParagraph, alignment, counters);
    SPDFHTMLAppendInlineChildren(element, summary, SPDFMarkdownInlineTraitStrong, depth + 1);
    SPDFHTMLTrimRuns(summary);
    [summary.runs insertObject:[[SPDFMarkdownInlineRun alloc]
                                   initWithText:@"▸ "
                                        traits:SPDFMarkdownInlineTraitStrong
                                   destination:nil]
                       atIndex:0];
    [out addObject:summary];
}

static void SPDFHTMLTranslateChildren(const GumboVector* children, NSMutableArray* out,
                                      SPDFMarkdownTableAlignment alignment, SPDFHTMLCounters counters,
                                      NSUInteger depth);

static BOOL SPDFHTMLCellSpans(const GumboElement* cell) {
    NSString* colspan = SPDFMarkdownHTMLAttribute(cell, "colspan");
    NSString* rowspan = SPDFMarkdownHTMLAttribute(cell, "rowspan");
    return (colspan.length && colspan.integerValue > 1) || (rowspan.length && rowspan.integerValue > 1);
}

// Collects (row element, header?) pairs from table/thead/tbody/tfoot children.
static void SPDFHTMLCollectRows(const GumboElement* table, NSMutableArray<NSValue*>* rows,
                                NSMutableArray<NSNumber*>* headerFlags) {
    for (unsigned int i = 0; i < table->children.length; ++i) {
        const GumboNode* child = (const GumboNode*)table->children.data[i];
        if (child->type != GUMBO_NODE_ELEMENT) continue;
        NSString* name = SPDFMarkdownHTMLElementName(&child->v.element);
        if ([name isEqualToString:@"tr"]) {
            [rows addObject:[NSValue valueWithPointer:&child->v.element]];
            [headerFlags addObject:@NO];
        } else if ([name isEqualToString:@"thead"] || [name isEqualToString:@"tbody"] ||
                   [name isEqualToString:@"tfoot"]) {
            BOOL head = [name isEqualToString:@"thead"];
            for (unsigned int j = 0; j < child->v.element.children.length; ++j) {
                const GumboNode* row = (const GumboNode*)child->v.element.children.data[j];
                if (row->type != GUMBO_NODE_ELEMENT ||
                    ![SPDFMarkdownHTMLElementName(&row->v.element) isEqualToString:@"tr"])
                    continue;
                [rows addObject:[NSValue valueWithPointer:&row->v.element]];
                [headerFlags addObject:@(head)];
            }
        }
    }
}

static NSArray<NSValue*>* SPDFHTMLRowCells(const GumboElement* row) {
    NSMutableArray* cells = [NSMutableArray array];
    for (unsigned int i = 0; i < row->children.length; ++i) {
        const GumboNode* child = (const GumboNode*)row->children.data[i];
        if (child->type != GUMBO_NODE_ELEMENT) continue;
        NSString* name = SPDFMarkdownHTMLElementName(&child->v.element);
        if ([name isEqualToString:@"td"] || [name isEqualToString:@"th"])
            [cells addObject:[NSValue valueWithPointer:&child->v.element]];
    }
    return cells;
}

// Simple tables map onto the existing table model (alignment from `align`
// attributes); a table using colspan/rowspan degrades to plain text rows so
// content is never dropped.
static void SPDFHTMLTranslateTable(const GumboElement* table, NSMutableArray* out,
                                   SPDFMarkdownTableAlignment alignment, SPDFHTMLCounters counters,
                                   NSUInteger depth) {
    NSMutableArray<NSValue*>* rows = [NSMutableArray array];
    NSMutableArray<NSNumber*>* headerFlags = [NSMutableArray array];
    SPDFHTMLCollectRows(table, rows, headerFlags);
    if (!rows.count) return;

    BOOL degrade = NO;
    NSUInteger columnCount = 1;
    for (NSValue* value in rows) {
        NSArray<NSValue*>* cells = SPDFHTMLRowCells((const GumboElement*)value.pointerValue);
        columnCount = MAX(columnCount, cells.count);
        for (NSValue* cell in cells)
            if (SPDFHTMLCellSpans((const GumboElement*)cell.pointerValue)) degrade = YES;
    }
    if (degrade) {
        for (NSValue* value in rows) {
            SPDFMarkdownBlockBuilder* paragraph =
                SPDFHTMLNewBuilder(SPDFMarkdownBlockKindParagraph, alignment, counters);
            NSArray<NSValue*>* cells = SPDFHTMLRowCells((const GumboElement*)value.pointerValue);
            for (NSValue* cell in cells) {
                if (paragraph.runs.count) SPDFHTMLAppendRun(paragraph, @" ", 0, nil, nil);
                SPDFHTMLAppendInlineChildren((const GumboElement*)cell.pointerValue, paragraph, 0, depth + 1);
            }
            SPDFHTMLTrimRuns(paragraph);
            if (paragraph.runs.count) [out addObject:paragraph];
        }
        return;
    }

    // Header rows: an explicit <thead>, or the leading all-<th> rows.
    NSMutableArray<NSNumber*>* isHeader = [headerFlags mutableCopy];
    if (![headerFlags containsObject:@YES]) {
        for (NSUInteger i = 0; i < rows.count; ++i) {
            NSArray<NSValue*>* cells = SPDFHTMLRowCells((const GumboElement*)rows[i].pointerValue);
            BOOL allHeader = cells.count > 0;
            for (NSValue* cell in cells)
                if (![SPDFMarkdownHTMLElementName((const GumboElement*)cell.pointerValue)
                        isEqualToString:@"th"])
                    allHeader = NO;
            if (!allHeader) break;
            isHeader[i] = @YES;
        }
    }

    SPDFMarkdownBlockBuilder* tableBuilder =
        SPDFHTMLNewBuilder(SPDFMarkdownBlockKindTable, alignment, counters);
    tableBuilder.tableColumnCount = columnCount;
    SPDFMarkdownBlockBuilder* head = nil;
    SPDFMarkdownBlockBuilder* body = nil;
    for (NSUInteger i = 0; i < rows.count; ++i) {
        BOOL header = isHeader[i].boolValue;
        SPDFMarkdownBlockBuilder* section = header ? head : body;
        if (!section) {
            section = SPDFHTMLNewBuilder(header ? SPDFMarkdownBlockKindTableHead
                                                : SPDFMarkdownBlockKindTableBody,
                                         SPDFMarkdownTableAlignmentDefault, counters);
            if (header) head = section; else body = section;
        }
        SPDFMarkdownBlockBuilder* rowBuilder = SPDFHTMLNewBuilder(SPDFMarkdownBlockKindTableRow,
                                                                  SPDFMarkdownTableAlignmentDefault, counters);
        for (NSValue* value in SPDFHTMLRowCells((const GumboElement*)rows[i].pointerValue)) {
            const GumboElement* cell = (const GumboElement*)value.pointerValue;
            BOOL headerCell = [SPDFMarkdownHTMLElementName(cell) isEqualToString:@"th"];
            SPDFMarkdownBlockBuilder* cellBuilder =
                SPDFHTMLNewBuilder(headerCell ? SPDFMarkdownBlockKindTableHeaderCell
                                              : SPDFMarkdownBlockKindTableCell,
                                   SPDFMarkdownTableAlignmentDefault, counters);
            cellBuilder.tableAlignment = SPDFMarkdownHTMLElementAlignment(
                cell, headerCell ? @"th" : @"td", SPDFMarkdownTableAlignmentDefault);
            SPDFHTMLAppendInlineChildren(cell, cellBuilder, 0, depth + 1);
            SPDFHTMLTrimRuns(cellBuilder);
            [rowBuilder.children addObject:cellBuilder];
        }
        [section.children addObject:rowBuilder];
    }
    if (head) [tableBuilder.children addObject:head];
    if (body) [tableBuilder.children addObject:body];
    [out addObject:tableBuilder];
}

static void SPDFHTMLTranslateList(const GumboElement* list, NSMutableArray* out, BOOL ordered,
                                  SPDFMarkdownTableAlignment alignment, SPDFHTMLCounters counters,
                                  NSUInteger depth) {
    SPDFMarkdownBlockBuilder* listBuilder =
        SPDFHTMLNewBuilder(ordered ? SPDFMarkdownBlockKindOrderedList : SPDFMarkdownBlockKindUnorderedList,
                           SPDFMarkdownTableAlignmentDefault, counters);
    NSString* start = SPDFMarkdownHTMLAttribute(list, "start");
    if (ordered && start.length && start.integerValue > 0) listBuilder.orderedStart = start.integerValue;
    for (unsigned int i = 0; i < list->children.length; ++i) {
        const GumboNode* child = (const GumboNode*)list->children.data[i];
        if (child->type != GUMBO_NODE_ELEMENT ||
            ![SPDFMarkdownHTMLElementName(&child->v.element) isEqualToString:@"li"])
            continue;
        SPDFMarkdownBlockBuilder* item =
            SPDFHTMLNewBuilder(SPDFMarkdownBlockKindListItem, SPDFMarkdownTableAlignmentDefault, counters);
        NSMutableArray* itemBlocks = [NSMutableArray array];
        SPDFHTMLTranslateChildren(&child->v.element.children, itemBlocks, alignment, counters, depth + 1);
        // Mirror md4c's tight-list shape: the item's first paragraph becomes
        // its direct runs; anything else stays a child block.
        if ([itemBlocks.firstObject isKindOfClass:SPDFMarkdownBlockBuilder.class] &&
            ((SPDFMarkdownBlockBuilder*)itemBlocks.firstObject).kind == SPDFMarkdownBlockKindParagraph &&
            ((SPDFMarkdownBlockBuilder*)itemBlocks.firstObject).children.count == 0) {
            item.runs = ((SPDFMarkdownBlockBuilder*)itemBlocks.firstObject).runs;
            [itemBlocks removeObjectAtIndex:0];
        }
        [item.children addObjectsFromArray:itemBlocks];
        [listBuilder.children addObject:item];
    }
    if (listBuilder.children.count) [out addObject:listBuilder];
}

static void SPDFHTMLTranslateElement(const GumboElement* element, NSString* name, NSMutableArray* out,
                                     SPDFMarkdownTableAlignment alignment, SPDFHTMLCounters counters,
                                     NSUInteger depth) {
    SPDFMarkdownTableAlignment own = SPDFMarkdownHTMLElementAlignment(element, name, alignment);
    unichar first = name.length ? [name characterAtIndex:0] : 0;
    if (name.length == 2 && first == 'h' && [name characterAtIndex:1] >= '1' &&
        [name characterAtIndex:1] <= '6') {
        SPDFMarkdownBlockBuilder* heading =
            SPDFHTMLNewBuilder(SPDFMarkdownBlockKindHeading, own, counters);
        heading.level = (NSUInteger)([name characterAtIndex:1] - '0');
        SPDFHTMLAppendInlineChildren(element, heading, 0, depth + 1);
        SPDFHTMLTrimRuns(heading);
        [out addObject:heading];
    } else if ([name isEqualToString:@"p"] || [name isEqualToString:@"figcaption"] ||
               [name isEqualToString:@"summary"] || [name isEqualToString:@"dt"] ||
               [name isEqualToString:@"dd"] || [name isEqualToString:@"li"] ||
               [name isEqualToString:@"caption"]) {
        if ([name isEqualToString:@"summary"])
            return SPDFHTMLAppendSummary(element, out, own, counters, depth);
        SPDFMarkdownBlockBuilder* paragraph =
            SPDFHTMLNewBuilder(SPDFMarkdownBlockKindParagraph, own, counters);
        SPDFHTMLAppendInlineChildren(element, paragraph, 0, depth + 1);
        SPDFHTMLTrimRuns(paragraph);
        if (paragraph.runs.count) [out addObject:paragraph];
    } else if ([name isEqualToString:@"hr"]) {
        [out addObject:SPDFHTMLNewBuilder(SPDFMarkdownBlockKindThematicBreak,
                                          SPDFMarkdownTableAlignmentDefault, counters)];
    } else if ([name isEqualToString:@"blockquote"]) {
        SPDFMarkdownBlockBuilder* quote =
            SPDFHTMLNewBuilder(SPDFMarkdownBlockKindBlockQuote, SPDFMarkdownTableAlignmentDefault, counters);
        NSMutableArray* quoteChildren = [NSMutableArray array];
        SPDFHTMLTranslateChildren(&element->children, quoteChildren, own, counters, depth + 1);
        [quote.children addObjectsFromArray:quoteChildren];
        if (quote.children.count) [out addObject:quote];
    } else if ([name isEqualToString:@"ul"] || [name isEqualToString:@"ol"]) {
        SPDFHTMLTranslateList(element, out, [name isEqualToString:@"ol"], own, counters, depth);
    } else if ([name isEqualToString:@"pre"]) {
        SPDFMarkdownBlockBuilder* code =
            SPDFHTMLNewBuilder(SPDFMarkdownBlockKindCode, SPDFMarkdownTableAlignmentDefault, counters);
        NSMutableString* raw = [NSMutableString string];
        for (unsigned int i = 0; i < element->children.length; ++i)
            SPDFHTMLAppendRawText((const GumboNode*)element->children.data[i], raw, depth + 1);
        while ([raw hasPrefix:@"\n"]) [raw deleteCharactersInRange:NSMakeRange(0, 1)];
        SPDFHTMLAppendRun(code, raw, 0, nil, nil);
        [out addObject:code];
    } else if ([name isEqualToString:@"table"]) {
        SPDFHTMLTranslateTable(element, out, own, counters, depth);
    } else if ([name isEqualToString:@"details"]) {
        NSMutableArray* content = [NSMutableArray array];
        SPDFHTMLTranslateChildren(&element->children, content, own, counters, depth + 1);
        [out addObjectsFromArray:content];  // Summary first (translated above), always expanded.
    } else {
        // div/center/section/figure/main/article/... and unknown containers:
        // recurse with the element's alignment; children pass through.
        SPDFHTMLTranslateChildren(&element->children, out, own, counters, depth + 1);
    }
}

static const NSSet<NSString*>* SPDFHTMLBlockTags(void) {
    static NSSet* tags;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      tags = [NSSet setWithArray:@[
          @"h1", @"h2", @"h3", @"h4", @"h5", @"h6", @"p", @"div", @"center", @"blockquote",
          @"ul", @"ol", @"li", @"hr", @"table", @"pre", @"details", @"summary", @"section",
          @"article", @"main", @"figure", @"figcaption", @"aside", @"header", @"footer",
          @"nav", @"dl", @"dt", @"dd", @"caption",
      ]];
    });
    return tags;
}

static void SPDFHTMLTranslateChildren(const GumboVector* children, NSMutableArray* out,
                                      SPDFMarkdownTableAlignment alignment, SPDFHTMLCounters counters,
                                      NSUInteger depth) {
    if (depth > kSPDFHTMLMaximumDepth) return;
    SPDFMarkdownBlockBuilder* pending = nil;
    for (unsigned int i = 0; i < children->length; ++i) {
        const GumboNode* child = (const GumboNode*)children->data[i];
        BOOL isBlock = NO;
        NSString* name = nil;
        if (child->type == GUMBO_NODE_ELEMENT) {
            name = SPDFMarkdownHTMLElementName(&child->v.element);
            SPDFMarkdownHTMLTagClass tagClass = SPDFMarkdownHTMLClassifyTag(name);
            if (tagClass == SPDFMarkdownHTMLTagClassDropWithContent ||
                tagClass == SPDFMarkdownHTMLTagClassDropVoid)
                continue;
            isBlock = [SPDFHTMLBlockTags() containsObject:name];
        } else if (child->type == GUMBO_NODE_WHITESPACE && !pending) {
            continue;
        } else if (child->type != GUMBO_NODE_TEXT && child->type != GUMBO_NODE_WHITESPACE &&
                   child->type != GUMBO_NODE_CDATA) {
            continue;  // Comments and other non-content nodes.
        }
        if (isBlock) {
            if (pending) {
                SPDFHTMLTrimRuns(pending);
                if (pending.runs.count) [out addObject:pending];
                pending = nil;
            }
            SPDFHTMLTranslateElement(&child->v.element, name, out, alignment, counters, depth);
            continue;
        }
        // Inline content between block elements gathers into an implicit
        // paragraph, browser-style.
        if (!pending) pending = SPDFHTMLNewBuilder(SPDFMarkdownBlockKindParagraph, alignment, counters);
        SPDFHTMLAppendInlineNode(child, pending, 0, nil, nil, depth + 1);
    }
    if (pending) {
        SPDFHTMLTrimRuns(pending);
        if (pending.runs.count) [out addObject:pending];
    }
}

// Container tags whose lone opening (or closing) tags in an island act as
// block-format pushes (pops) spanning subsequent markdown blocks.
static const NSSet<NSString*>* SPDFHTMLContainerTags(void) {
    static NSSet* tags;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      tags = [NSSet setWithArray:@[
          @"div", @"center", @"p", @"details", @"section", @"article", @"main", @"figure",
          @"aside", @"header", @"footer", @"nav",
      ]];
    });
    return tags;
}

// Number of pops for an island that is nothing but closing container tags.
static NSUInteger SPDFHTMLPureCloseCount(NSString* island) {
    static NSRegularExpression* closeTag;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      closeTag = [NSRegularExpression
          regularExpressionWithPattern:@"</\\s*([a-zA-Z][a-zA-Z0-9]*)\\s*>|\\S"
                               options:0
                                 error:nil];
    });
    NSUInteger pops = 0;
    NSArray<NSTextCheckingResult*>* matches =
        [closeTag matchesInString:island options:0 range:NSMakeRange(0, island.length)];
    for (NSTextCheckingResult* match in matches) {
        if ([match rangeAtIndex:1].location == NSNotFound) return 0;  // Non-close content.
        NSString* name = [island substringWithRange:[match rangeAtIndex:1]].lowercaseString;
        if (![SPDFHTMLContainerTags() containsObject:name]) return 0;
        ++pops;
    }
    return pops;
}

// A push island consists only of unclosed container tags (nested), optional
// whitespace, and — inside <details> — one complete <summary> element. Commits
// the pushes and emits summary builders; returns NO to fall back to content
// translation. The GitHub pattern this serves: `<div align="center">` opened
// in one island, several markdown paragraphs, `</div>` in a later island.
static BOOL SPDFHTMLCollectPushes(const GumboVector* children, SPDFMarkdownHTMLState* state,
                                  NSMutableArray<NSNumber*>* pushes, NSMutableArray* summaries,
                                  SPDFHTMLCounters counters, NSUInteger depth) {
    if (depth > kSPDFHTMLMaximumDepth) return NO;
    for (unsigned int i = 0; i < children->length; ++i) {
        const GumboNode* child = (const GumboNode*)children->data[i];
        if (child->type == GUMBO_NODE_WHITESPACE || child->type == GUMBO_NODE_COMMENT) continue;
        if (child->type != GUMBO_NODE_ELEMENT) return NO;
        const GumboElement* element = &child->v.element;
        NSString* name = SPDFMarkdownHTMLElementName(element);
        if ([name isEqualToString:@"summary"] && element->original_end_tag.length > 0) {
            SPDFHTMLAppendSummary(element, summaries, SPDFMarkdownTableAlignmentDefault, counters, depth);
            continue;
        }
        if (![SPDFHTMLContainerTags() containsObject:name]) return NO;
        if (element->original_end_tag.length > 0) return NO;  // Complete container: content island.
        [pushes addObject:@(SPDFMarkdownHTMLElementAlignment(element, name,
                                                             SPDFMarkdownTableAlignmentDefault))];
        if (!SPDFHTMLCollectPushes(&element->children, state, pushes, summaries, counters, depth + 1))
            return NO;
    }
    return YES;
}

NSArray<SPDFMarkdownBlockBuilder*>* SPDFMarkdownHTMLProcessBlockIsland(
    SPDFMarkdownHTMLState* state, NSString* island, NSUInteger* nextIndex, NSUInteger* nodeCount) {
    NSString* trimmed =
        [island stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) return @[];
    NSUInteger pops = SPDFHTMLPureCloseCount(trimmed);
    if (pops) {
        while (pops--) [state popContainer];
        return @[];
    }
    SPDFHTMLCounters counters = {nextIndex, nodeCount};
    NSMutableArray* result = [NSMutableArray array];
    GumboOutput* output = gumbo_parse(trimmed.UTF8String);
    const GumboElement* body = SPDFMarkdownHTMLFindElement(output->root, @"body");
    if (body) {
        NSMutableArray<NSNumber*>* pushes = [NSMutableArray array];
        NSMutableArray* summaries = [NSMutableArray array];
        if (SPDFHTMLCollectPushes(&body->children, state, pushes, summaries, counters, 0) &&
            pushes.count) {
            [result addObjectsFromArray:summaries];
            for (NSNumber* alignment in pushes)
                [state pushContainerWithAlignment:(SPDFMarkdownTableAlignment)alignment.integerValue];
        } else {
            SPDFHTMLTranslateChildren(&body->children, result, state.currentAlignment, counters, 0);
        }
    }
    gumbo_destroy_output(&kGumboDefaultOptions, output);
    return result;
}
