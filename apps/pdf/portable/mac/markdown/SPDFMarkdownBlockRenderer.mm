#import "SPDFMarkdownDecorations.h"
#import "SPDFMarkdownMathTypesetter.h"
#import "SPDFMarkdownRenderInternal.h"
#import "SPDFMarkdownTableDecorations.h"
#import "SPDFMarkdownTableLayout.h"

@implementation SPDFMarkdownRenderContext
@end

static NSMutableParagraphStyle* SPDFStyle(SPDFMarkdownRenderContext* context, NSUInteger depth) {
    NSMutableParagraphStyle* style = [NSMutableParagraphStyle new];
    style.lineSpacing = context.options.lineSpacing * SPDFMarkdownRenderScale(context);
    style.paragraphSpacing = context.options.paragraphSpacing * SPDFMarkdownRenderScale(context);
    style.headIndent = depth * 22;
    style.firstLineHeadIndent = depth * 22;
    return style;
}

// Syntax token roles come from the render's theme variant, so highlighted
// code follows the active reading theme like every other palette role.
static NSColor* SPDFTokenColor(SPDFMarkdownSyntaxTokenKind kind, SPDFMarkdownTheme* theme) {
    switch (kind) {
        case SPDFMarkdownSyntaxTokenComment: return theme.syntaxCommentColor;
        case SPDFMarkdownSyntaxTokenString: return theme.syntaxStringColor;
        case SPDFMarkdownSyntaxTokenNumber: return theme.syntaxNumberColor;
        case SPDFMarkdownSyntaxTokenKey: return theme.syntaxKeyColor;
        case SPDFMarkdownSyntaxTokenMarkup: return theme.syntaxMarkupColor;
        case SPDFMarkdownSyntaxTokenKeyword: return theme.syntaxKeywordColor;
    }
}

static void SPDFApplyCodeTokens(SPDFMarkdownRenderContext* context, NSRange range,
                                SPDFMarkdownLanguage* language) {
    NSString* code = [context.output.string substringWithRange:range];
    NSArray<SPDFMarkdownSyntaxToken*>* tokens =
        [context.highlighter tokensForCode:code language:language cancellationToken:context.cancellationToken];
    SPDFMarkdownTheme* theme = [SPDFMarkdownTheme themeForVariant:context.options.themeVariant];
    for (SPDFMarkdownSyntaxToken* token in tokens) {
        [context.output addAttribute:NSForegroundColorAttributeName
                               value:SPDFTokenColor(token.kind, theme)
                               range:NSMakeRange(range.location + token.range.location, token.range.length)];
    }
}

static void SPDFRecordWithTableRow(SPDFMarkdownRenderContext* context, SPDFMarkdownBlock* block, NSRange range,
                                   NSUInteger depth, SPDFMarkdownTableRowInfo* tableRowInfo) {
    if (!range.length && block.kind != SPDFMarkdownBlockKindPageBreak) return;
    [context.output addAttribute:SPDFMarkdownBlockIndexAttribute value:@(block.blockIndex) range:range];
    [context.output addAttribute:SPDFMarkdownBlockKindAttribute value:@(block.kind) range:range];
    [context.blocks addObject:[[SPDFMarkdownRenderedBlock alloc] initWithBlockIndex:block.blockIndex
                                                                                kind:block.kind
                                                                     attributedRange:range
                                                                               level:block.level
                                                                               depth:depth
                                                                        tableRowInfo:tableRowInfo]];
}

static void SPDFRecord(SPDFMarkdownRenderContext* context, SPDFMarkdownBlock* block, NSRange range,
                       NSUInteger depth) {
    SPDFRecordWithTableRow(context, block, range, depth, nil);
}

static void SPDFRenderBlock(SPDFMarkdownRenderContext* context, SPDFMarkdownBlock* block, NSUInteger depth,
                            BOOL record);

static void SPDFRenderList(SPDFMarkdownRenderContext* context, SPDFMarkdownBlock* list, NSUInteger depth,
                           BOOL record) {
    NSInteger number = list.orderedStart;
    for (SPDFMarkdownBlock* item in list.children) {
        if (context.cancellationToken.isCancelled) return;
        NSUInteger itemStart = context.output.length;
        NSString* marker = list.kind == SPDFMarkdownBlockKindOrderedList
            ? [NSString stringWithFormat:@"%ld. ", (long)number++] : @"• ";
        if (item.taskState >= 0) marker = item.taskState ? @"☑ " : @"☐ ";
        NSMutableDictionary* markerAttributes = [@{
            NSFontAttributeName: context.bodyFont,
            NSForegroundColorAttributeName: context.options.secondaryTextColor,
            NSParagraphStyleAttributeName: SPDFStyle(context, depth),
        } mutableCopy];
        SPDFMarkdownAppend(context, marker, markerAttributes);

        BOOL recordedFirstContent = NO;
        if (item.runs.count) {
            SPDFMarkdownRenderInlineRuns(context, item);
            SPDFMarkdownAppend(context, @"\n", @{});
            if (record) SPDFRecord(context, item, NSMakeRange(itemStart, context.output.length - itemStart), depth);
            recordedFirstContent = YES;
        }

        for (SPDFMarkdownBlock* child in item.children) {
            BOOL nestedList = child.kind == SPDFMarkdownBlockKindUnorderedList ||
                              child.kind == SPDFMarkdownBlockKindOrderedList;
            if (nestedList) {
                SPDFRenderList(context, child, depth + 1, record);
                continue;
            }
            NSUInteger childStart = context.output.length;
            SPDFRenderBlock(context, child, depth + 1, record && recordedFirstContent);
            if (!recordedFirstContent) {
                if (record) {
                    SPDFRecord(context, item, NSMakeRange(itemStart, context.output.length - itemStart), depth);
                }
                recordedFirstContent = YES;
            } else if (context.output.length == childStart) {
                continue;
            }
        }
        if (!recordedFirstContent) {
            SPDFMarkdownAppend(context, @"\n", @{});
            if (record) SPDFRecord(context, item, NSMakeRange(itemStart, context.output.length - itemStart), depth);
        }
    }
}

static NSTextAlignment SPDFTextAlignment(SPDFMarkdownTableAlignment alignment) {
    if (alignment == SPDFMarkdownTableAlignmentCenter) return NSTextAlignmentCenter;
    if (alignment == SPDFMarkdownTableAlignmentRight) return NSTextAlignmentRight;
    return NSTextAlignmentLeft;
}

// A tab stop kept strictly inside its column by the cell inset: a stop at
// exactly the paragraph origin (a left-aligned first column at location 0)
// would never satisfy TextKit's "next tab stop" rule in the flowing-text
// fallback view, shifting every cell one stop over.
static CGFloat SPDFTabLocation(CGFloat left, CGFloat width, NSTextAlignment alignment) {
    if (alignment == NSTextAlignmentCenter) return left + width / 2;
    if (alignment == NSTextAlignmentRight) return left + width - SPDFMarkdownTableCellInset;
    return left + SPDFMarkdownTableCellInset;
}

// Symmetric vertical padding reserved inside every table row so the drawn grid
// hairlines never touch glyphs. Scaled by fontScale like all vertical spacing.
static const CGFloat kSPDFMarkdownTableRowPadding = 6.0;

// Widest single line of the cell's rendered text (attachment-aware).
static CGFloat SPDFCellNaturalWidth(SPDFMarkdownRenderContext* context, NSRange range) {
    if (!range.length) return 0;
    NSAttributedString* cell = [context.output attributedSubstringFromRange:range];
    NSRect bounds = [cell boundingRectWithSize:NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX)
                                       options:NSStringDrawingUsesLineFragmentOrigin
                                       context:nil];
    return ceil(NSWidth(bounds));
}

// Content-aware table rendering. Pass 1 appends every row as tab-separated
// cells (one contiguous, searchable range per cell) and measures each column's
// natural width. The measured widths are then distributed (compact when they
// fit, capped at the width budget when they do not — see
// SPDFMarkdownTableColumnWidths) and pass 2 applies row spacing plus tab stops
// at the computed columns (the flowing NSTextView fallback keeps aligned
// columns) and records the full cell geometry on each row's
// SPDFMarkdownTableRowInfo. The paginator re-distributes the same natural
// widths at the real printable width and wraps cells inside their columns.
static void SPDFRenderTable(SPDFMarkdownRenderContext* context, SPDFMarkdownBlock* table, NSUInteger depth,
                            BOOL record) {
    NSUInteger columnCount = MAX((NSUInteger)1, table.tableColumnCount);
    CGFloat depthIndent = depth * 22;
    CGFloat rowPadding = kSPDFMarkdownTableRowPadding * SPDFMarkdownRenderScale(context);
    NSMutableArray<NSNumber*>* naturalWidths = [NSMutableArray arrayWithCapacity:columnCount];
    for (NSUInteger i = 0; i < columnCount; ++i) [naturalWidths addObject:@(SPDFMarkdownTableMinimumColumnWidth)];

    NSMutableArray<SPDFMarkdownBlock*>* rowBlocks = [NSMutableArray array];
    NSMutableArray<NSValue*>* rowRanges = [NSMutableArray array];
    NSMutableArray<NSArray<NSValue*>*>* rowCellRanges = [NSMutableArray array];
    NSMutableArray<NSArray<NSNumber*>*>* rowAlignments = [NSMutableArray array];
    NSMutableArray<NSNumber*>* rowHeaderFlags = [NSMutableArray array];
    for (SPDFMarkdownBlock* section in table.children) {
        BOOL headerSection = section.kind == SPDFMarkdownBlockKindTableHead;
        for (SPDFMarkdownBlock* row in section.children) {
            if (context.cancellationToken.isCancelled) return;
            NSUInteger start = context.output.length;
            NSMutableArray<NSValue*>* cellRanges = [NSMutableArray arrayWithCapacity:row.children.count];
            NSMutableArray<NSNumber*>* alignments = [NSMutableArray arrayWithCapacity:row.children.count];
            for (NSUInteger i = 0; i < row.children.count; ++i) {
                SPDFMarkdownAppend(context, @"\t", @{});
                NSUInteger cellStart = context.output.length;
                SPDFMarkdownBlock* cell = row.children[i];
                SPDFMarkdownRenderInlineRuns(context, cell);
                NSRange cellRange = NSMakeRange(cellStart, context.output.length - cellStart);
                if (cell.kind == SPDFMarkdownBlockKindTableHeaderCell) {
                    [context.output addAttribute:NSFontAttributeName
                                           value:SPDFMarkdownFontWithTraits(context.bodyFont, NSBoldFontMask)
                                           range:cellRange];
                }
                [cellRanges addObject:[NSValue valueWithRange:cellRange]];
                [alignments addObject:@(SPDFTextAlignment(cell.tableAlignment))];
                if (i < columnCount) {
                    CGFloat natural = SPDFCellNaturalWidth(context, cellRange) + 2 * SPDFMarkdownTableCellInset;
                    if (natural > naturalWidths[i].doubleValue) naturalWidths[i] = @(natural);
                }
            }
            SPDFMarkdownAppend(context, @"\n", @{});
            [rowBlocks addObject:row];
            [rowRanges addObject:[NSValue valueWithRange:NSMakeRange(start, context.output.length - start)]];
            [rowCellRanges addObject:cellRanges];
            [rowAlignments addObject:alignments];
            [rowHeaderFlags addObject:@(headerSection)];
        }
    }
    if (!rowBlocks.count) return;

    // Provisional distribution at the destination page's printable width when
    // the render carries one — the very formula the paginator rebinds with, so
    // the two distributions agree — at the constant image budget otherwise.
    CGFloat available =
        MAX(SPDFMarkdownTableMinimumColumnWidth,
            SPDFMarkdownContentWidthBudget(context, depthIndent, context.options.maximumImageWidth));
    NSArray<NSNumber*>* widths = SPDFMarkdownTableColumnWidths(naturalWidths, available);
    NSArray<NSNumber*>* boundaries = SPDFMarkdownTableColumnBoundaries(widths, depthIndent);

    NSUInteger bodyRowIndex = 0;
    for (NSUInteger rowIndex = 0; rowIndex < rowBlocks.count; ++rowIndex) {
        BOOL headerRow = rowHeaderFlags[rowIndex].boolValue;
        BOOL lastRow = rowIndex + 1 == rowBlocks.count;
        NSRange range = rowRanges[rowIndex].rangeValue;
        NSArray<NSNumber*>* alignments = rowAlignments[rowIndex];
        NSMutableParagraphStyle* style = SPDFStyle(context, depth);
        style.alignment = NSTextAlignmentLeft;
        // The table's first and last rows also reserve the outer margin the
        // decoration grid insets away from (unpainted page around the closed
        // grid).
        style.paragraphSpacingBefore = rowPadding + (rowIndex == 0 ? SPDFMarkdownTableOuterMargin : 0);
        style.paragraphSpacing = rowPadding + (lastRow ? SPDFMarkdownTableOuterMargin : 0);
        NSMutableArray<NSTextTab*>* tabs = [NSMutableArray array];
        for (NSUInteger i = 0; i < alignments.count && i < widths.count; ++i) {
            NSTextAlignment alignment = (NSTextAlignment)alignments[i].integerValue;
            [tabs addObject:[[NSTextTab alloc]
                                initWithTextAlignment:alignment
                                             location:SPDFTabLocation(boundaries[i].doubleValue,
                                                                      widths[i].doubleValue, alignment)
                                              options:@{}]];
        }
        style.tabStops = tabs;
        [context.output addAttribute:NSParagraphStyleAttributeName value:style range:range];
        if (record) {
            SPDFMarkdownTableRowInfo* info =
                [[SPDFMarkdownTableRowInfo alloc] initWithTableBlockIndex:table.blockIndex
                                                                headerRow:headerRow
                                                                  lastRow:lastRow
                                                             bodyRowIndex:headerRow ? 0 : bodyRowIndex
                                                         columnBoundaries:boundaries
                                                               cellRanges:rowCellRanges[rowIndex]
                                                           cellAlignments:alignments
                                                      naturalColumnWidths:naturalWidths
                                                          verticalPadding:rowPadding
                                                              depthIndent:depthIndent];
            SPDFRecordWithTableRow(context, rowBlocks[rowIndex], range, depth, info);
        }
        if (!headerRow) ++bodyRowIndex;
    }
}

static void SPDFRenderLeaf(SPDFMarkdownRenderContext* context, SPDFMarkdownBlock* block, NSUInteger depth,
                           BOOL record) {
    // A diagram fence takes over the whole code branch below: it emits a
    // centered figure attachment instead of the fence text, so the hook has to
    // run BEFORE any of that text reaches the output. Non-diagram languages
    // cost one O(1) identifier check and nothing else; a diagram that fails to
    // parse also returns NO and falls straight through to the code box.
    if (block.kind == SPDFMarkdownBlockKindCode &&
        SPDFMarkdownRenderDiagramBlock(context, block, depth, record)) {
        return;
    }
    NSUInteger start = context.output.length;
    if (block.kind == SPDFMarkdownBlockKindThematicBreak) {
        // The break contributes an invisible blank line that reserves layout
        // space; the visible hairline is a page decoration
        // (SPDFMarkdownPageDecorationTypeThematicBreakRule), so it prints as a
        // real rule instead of a run of box-drawing characters.
        SPDFMarkdownAppend(context, @"\n",
                           @{
                               NSFontAttributeName: context.bodyFont,
                               NSForegroundColorAttributeName: context.options.secondaryTextColor,
                           });
    } else {
        SPDFMarkdownRenderInlineRuns(context, block);
        if (![context.output.string hasSuffix:@"\n"]) SPDFMarkdownAppend(context, @"\n", @{});
    }
    NSRange range = NSMakeRange(start, context.output.length - start);
    NSMutableParagraphStyle* style = SPDFStyle(context, depth);
    // Alignment requested by whitelisted HTML (`align` attributes, <center>,
    // and container islands spanning markdown blocks).
    if (block.blockAlignment == SPDFMarkdownTableAlignmentCenter) style.alignment = NSTextAlignmentCenter;
    else if (block.blockAlignment == SPDFMarkdownTableAlignmentRight) style.alignment = NSTextAlignmentRight;
    else if (block.blockAlignment == SPDFMarkdownTableAlignmentLeft) style.alignment = NSTextAlignmentLeft;
    if (block.kind == SPDFMarkdownBlockKindHeading) {
        // GitHub-style em ladder on the body size, set in semibold — full bold
        // reads heavy at display sizes. H6 drops below body and goes muted,
        // Primer's caption-like smallest heading.
        static const CGFloat ratios[] = {1.75, 1.5, 1.25, 1.1, 1.0, 0.9};
        NSUInteger level = MIN(MAX(block.level, (NSUInteger)1), (NSUInteger)6);
        CGFloat size = context.options.textSize * ratios[level - 1] * SPDFMarkdownRenderScale(context);
        [context.output addAttribute:NSFontAttributeName
                               value:[NSFont systemFontOfSize:size weight:NSFontWeightSemibold]
                               range:range];
        if (level == 6) {
            [context.output addAttribute:NSForegroundColorAttributeName
                                   value:context.options.secondaryTextColor
                                   range:range];
        }
        style.paragraphSpacingBefore = (level <= 2 ? 22 : 16) * SPDFMarkdownRenderScale(context);
        // H1/H2 carry the underline rule inside their line box, anchored to the
        // baseline — the extra after-spacing is the air below the rule.
        style.paragraphSpacing = (level <= 2 ? 12 : 8) * SPDFMarkdownRenderScale(context);
    } else if (block.kind == SPDFMarkdownBlockKindCode) {
        // Fenced code flows as one continuous block: tight line spacing, no
        // inter-line paragraph gaps, and a 12pt inset so the text sits inside
        // the unified code box drawn behind it. The box background itself is a
        // page decoration, not a per-character attribute.
        [context.output addAttribute:NSFontAttributeName value:context.codeFont range:range];
        style.lineSpacing = 2 * SPDFMarkdownRenderScale(context);
        style.paragraphSpacing = 0;
        style.paragraphSpacingBefore = 0;
        style.firstLineHeadIndent = depth * 22 + 12;
        style.headIndent = depth * 22 + 12;
        style.tailIndent = -12;
        NSString* identifier = context.overrides[@(block.blockIndex)] ?: block.codeLanguage;
        SPDFMarkdownLanguage* language = [context.catalog languageForFenceIdentifier:identifier];
        if (language) {
            [context.output addAttribute:SPDFMarkdownCodeLanguageAttribute value:language.identifier range:range];
            SPDFApplyCodeTokens(context, range, language);
        }
    }
    [context.output addAttribute:NSParagraphStyleAttributeName value:style range:range];
    SPDFMarkdownApplyImageBlockStyles(context, range, style);
    SPDFMarkdownApplyMathBlockStyles(context, range, style);
    if (record) SPDFRecord(context, block, range, depth);
}

static void SPDFRenderBlock(SPDFMarkdownRenderContext* context, SPDFMarkdownBlock* block, NSUInteger depth,
                            BOOL record) {
    if (context.cancellationToken.isCancelled) return;
    if (block.kind == SPDFMarkdownBlockKindPageBreak) {
        if (record) SPDFRecord(context, block, NSMakeRange(context.output.length, 0), depth);
    } else if (block.kind == SPDFMarkdownBlockKindUnorderedList || block.kind == SPDFMarkdownBlockKindOrderedList) {
        SPDFRenderList(context, block, depth, record);
    } else if (block.kind == SPDFMarkdownBlockKindTable) {
        SPDFRenderTable(context, block, depth, record);
    } else if (block.kind == SPDFMarkdownBlockKindBlockQuote) {
        // Quoted prose reads muted, GitHub-style. Only runs still in the plain
        // body color are recolored, so links, inline code chips, and syntax
        // tokens inside the quote keep their own roles.
        NSUInteger start = context.output.length;
        for (SPDFMarkdownBlock* child in block.children) SPDFRenderBlock(context, child, depth + 1, record);
        NSRange quoteRange = NSMakeRange(start, context.output.length - start);
        NSMutableArray<NSValue*>* bodyRanges = [NSMutableArray array];
        [context.output enumerateAttribute:NSForegroundColorAttributeName
                                   inRange:quoteRange
                                   options:0
                                usingBlock:^(NSColor* color, NSRange colorRange, BOOL* stop) {
                                  (void)stop;
                                  if ([color isEqual:context.options.textColor])
                                      [bodyRanges addObject:[NSValue valueWithRange:colorRange]];
                                }];
        for (NSValue* value in bodyRanges) {
            [context.output addAttribute:NSForegroundColorAttributeName
                                   value:context.options.quoteColor
                                   range:value.rangeValue];
        }
    } else if (block.kind == SPDFMarkdownBlockKindCallout) {
        NSUInteger start = context.output.length;
        SPDFMarkdownAppend(context,
                           [(block.calloutTitle ?: block.calloutKind ?: @"Note") stringByAppendingString:@"\n"],
                   @{
                       NSFontAttributeName: SPDFMarkdownFontWithTraits(context.bodyFont, NSBoldFontMask),
                       NSForegroundColorAttributeName: context.options.quoteColor,
                   });
        NSRange titleRange = NSMakeRange(start, context.output.length - start);
        [context.output addAttribute:NSParagraphStyleAttributeName value:SPDFStyle(context, depth) range:titleRange];
        if (record) SPDFRecord(context, block, titleRange, depth);
        for (SPDFMarkdownBlock* child in block.children) SPDFRenderBlock(context, child, depth + 1, record);
    } else {
        SPDFRenderLeaf(context, block, depth, record);
    }
}

void SPDFRenderMarkdownBlocks(SPDFMarkdownRenderContext* context, NSArray<SPDFMarkdownBlock*>* blocks) {
    for (SPDFMarkdownBlock* block in blocks) SPDFRenderBlock(context, block, 0, YES);
}
