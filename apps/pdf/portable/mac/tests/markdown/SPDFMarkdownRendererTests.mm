#import "SPDFMarkdownTestSupport.h"

#import "../../markdown/SPDFMarkdownDocument.h"
#import "../../markdown/SPDFMarkdownTableDecorations.h"
#import "../../markdown/SPDFMarkdownTableLayout.h"

#include "spdf_recolor.h"

static BOOL SPDFColorMatchesHex(NSColor* color, unsigned int hex) {
    NSColor* sRGB = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!sRGB) return NO;
    return fabs(sRGB.redComponent - ((hex >> 16) & 0xff) / 255.0) < 0.002 &&
           fabs(sRGB.greenComponent - ((hex >> 8) & 0xff) / 255.0) < 0.002 &&
           fabs(sRGB.blueComponent - (hex & 0xff) / 255.0) < 0.002;
}

static CGFloat SPDFLuminance(NSColor* color) {
    NSColor* sRGB = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!sRGB) return -1.0;
    return 0.2126 * sRGB.redComponent + 0.7152 * sRGB.greenComponent + 0.0722 * sRGB.blueComponent;
}

static void SPDFExpectSearchCorrespondence(SPDFMarkdownDocument* document, NSString* query) {
    NSArray* matches = [document searchForQuery:query caseSensitive:YES];
    SPDFExpect(matches.count > 0, [@"search finds " stringByAppendingString:query]);
    for (SPDFMarkdownSearchMatch* match in matches) {
        NSString* selected = [document.renderedDocument.attributedString.string substringWithRange:match.range];
        SPDFExpect([selected isEqualToString:query], [@"search range exactly selects " stringByAppendingString:query]);
    }
}

int main(void) {
    @autoreleasepool {
        NSError* error = nil;
        SPDFMarkdownDocument* document = [SPDFMarkdownDocument documentWithURL:SPDFFixtureURL(@"commonmark-gfm.md")
                                                                        options:nil error:&error];
        SPDFExpect(document != nil && error == nil, @"document facade loads and renders");
        NSString* canonical = document.renderedDocument.attributedString.string;
        SPDFExpect([canonical containsString:@"☑ Finished task"], @"canonical text includes task markers");
        SPDFExpect([canonical containsString:@"Alpha\t42"], @"canonical text includes table separators");
        SPDFExpect([canonical containsString:@"[Image: Local diagram]"], @"missing image has canonical placeholder");
        SPDFExpectSearchCorrespondence(document, @"Finished task");
        SPDFExpectSearchCorrespondence(document, @"Alpha");
        SPDFExpectSearchCorrespondence(document, @"Local diagram");

        NSError* regexError = nil;
        NSArray<SPDFMarkdownSearchMatch*>* regexMatches = [document.renderedDocument searchForQuery:@"fin\\w+ task"
                                                                                      caseSensitive:NO
                                                                                              regex:YES
                                                                                  cancellationToken:nil
                                                                                              error:&regexError];
        SPDFExpect(regexError == nil && regexMatches.count > 0, @"regex search matches case-insensitively");
        for (SPDFMarkdownSearchMatch* match in regexMatches)
            SPDFExpect([[canonical substringWithRange:match.range] isEqualToString:@"Finished task"],
                       @"regex match ranges exactly select the canonical text");
        SPDFExpect([document.renderedDocument searchForQuery:@"fin\\w+ task"
                                               caseSensitive:YES
                                                       regex:YES
                                           cancellationToken:nil
                                                       error:&regexError].count == 0 && regexError == nil,
                   @"case-sensitive regex search respects case like the plain path");
        SPDFExpect([document.renderedDocument searchForQuery:@"Alpha"
                                               caseSensitive:NO
                                                       regex:NO
                                           cancellationToken:nil
                                                       error:&regexError].count ==
                       [document.renderedDocument searchForQuery:@"Alpha" caseSensitive:NO].count,
                   @"regex:NO passes through to the plain search");
        SPDFMarkdownCancellationToken* cancelledToken = [SPDFMarkdownCancellationToken new];
        [cancelledToken cancel];
        NSArray* cancelledMatches = [document.renderedDocument searchForQuery:@"fin\\w+"
                                                                caseSensitive:NO
                                                                        regex:YES
                                                            cancellationToken:cancelledToken
                                                                        error:&regexError];
        SPDFExpect(cancelledMatches != nil && cancelledMatches.count == 0 && regexError == nil,
                   @"a cancelled regex search returns no matches, matching the plain contract");
        SPDFExpect([document.renderedDocument searchForQuery:@"(["
                                               caseSensitive:NO
                                                       regex:YES
                                           cancellationToken:nil
                                                       error:&regexError] == nil && regexError != nil,
                   @"an invalid regex pattern returns nil and reports the parse error");
        regexError = nil;
        NSString* oversizedQuery = [@"" stringByPaddingToLength:4097 withString:@"a" startingAtIndex:0];
        SPDFExpect([document.renderedDocument searchForQuery:oversizedQuery
                                               caseSensitive:NO
                                                       regex:YES
                                           cancellationToken:nil
                                                       error:&regexError].count == 0 && regexError == nil,
                   @"regex keeps the 4096-code-unit interactive query rejection");
        NSRange tableText = [canonical rangeOfString:@"Alpha\t42"];
        NSParagraphStyle* tableStyle = [document.renderedDocument.attributedString
            attribute:NSParagraphStyleAttributeName atIndex:tableText.location effectiveRange:nil];
        SPDFExpect(tableStyle.tabStops.count == 2 && tableStyle.tabStops.firstObject.alignment == NSTextAlignmentLeft &&
                       tableStyle.tabStops.lastObject.alignment == NSTextAlignmentRight,
                   @"rendered table gives every column an explicit alignment tab");
        // "Alpha | 42" is the fixture table's only (hence last) body row: it
        // carries the 6pt row padding plus the table's 10pt outer margin after.
        SPDFExpect(fabs(tableStyle.paragraphSpacingBefore - 6) < 0.001 &&
                       fabs(tableStyle.paragraphSpacing - (6 + SPDFMarkdownTableOuterMargin)) < 0.001,
                   @"table rows reserve row padding, and the last row adds the table outer margin");
        SPDFMarkdownRenderedBlock* headerRowBlock = nil;
        SPDFMarkdownRenderedBlock* bodyRowBlock = nil;
        for (SPDFMarkdownRenderedBlock* block in document.renderedDocument.renderedBlocks) {
            if (block.kind != SPDFMarkdownBlockKindTableRow) continue;
            if (block.tableRowInfo.isHeaderRow && !headerRowBlock) headerRowBlock = block;
            if (!block.tableRowInfo.isHeaderRow && !bodyRowBlock) bodyRowBlock = block;
        }
        SPDFExpect(headerRowBlock.tableRowInfo != nil && bodyRowBlock.tableRowInfo != nil &&
                       bodyRowBlock.tableRowInfo.bodyRowIndex == 0 &&
                       headerRowBlock.tableRowInfo.tableBlockIndex == bodyRowBlock.tableRowInfo.tableBlockIndex,
                   @"table rows record their role and shared table identity for the grid decoration");
        // Content-aware columns: short cells produce compact natural widths
        // (never the old fixed 240pt splits), every column keeps at least the
        // minimum width, and the widest cell of each column fits its box.
        NSArray<NSNumber*>* rowBoundaries = headerRowBlock.tableRowInfo.columnBoundaries;
        SPDFExpect(rowBoundaries.count == 3 && fabs(rowBoundaries[0].doubleValue) < 0.001 &&
                       rowBoundaries[1].doubleValue > rowBoundaries[0].doubleValue &&
                       rowBoundaries[2].doubleValue > rowBoundaries[1].doubleValue &&
                       rowBoundaries[2].doubleValue < 300,
                   @"a two-column table of short cells records compact ascending column boundaries");
        NSArray<NSNumber*>* naturalWidths = headerRowBlock.tableRowInfo.naturalColumnWidths;
        SPDFExpect(naturalWidths.count == 2 &&
                       naturalWidths[0].doubleValue >= SPDFMarkdownTableMinimumColumnWidth - 0.001 &&
                       fabs(rowBoundaries[1].doubleValue - naturalWidths[0].doubleValue) < 0.001 &&
                       fabs(rowBoundaries[2].doubleValue -
                            (naturalWidths[0].doubleValue + naturalWidths[1].doubleValue)) < 0.001,
                   @"a table narrower than the width budget keeps its measured natural column widths");
        NSArray<NSValue*>* bodyCellRanges = bodyRowBlock.tableRowInfo.cellRanges;
        SPDFExpect(bodyCellRanges.count == 2 &&
                       [[canonical substringWithRange:bodyCellRanges[0].rangeValue] isEqualToString:@"Alpha"] &&
                       [[canonical substringWithRange:bodyCellRanges[1].rangeValue] isEqualToString:@"42"] &&
                       bodyRowBlock.tableRowInfo.cellAlignments.count == 2 &&
                       bodyRowBlock.tableRowInfo.cellAlignments[1].integerValue == NSTextAlignmentRight,
                   @"row info records each cell's exact canonical range and its column alignment");
        for (SPDFMarkdownRenderedHeading* heading in document.renderedDocument.headings) {
            NSString* selected = [[canonical substringWithRange:heading.attributedRange]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            SPDFExpect([selected isEqualToString:heading.title], @"heading index uses canonical coordinates");
        }

        SPDFMarkdownDocument* obsidian = [SPDFMarkdownDocument documentWithURL:SPDFFixtureURL(@"obsidian.md")
                                                                        options:nil error:&error];
        SPDFExpectSearchCorrespondence(obsidian, @"Release gate");
        SPDFExpect([[obsidian.renderedDocument.attributedString.string
                        componentsSeparatedByString:@"Release gate"] count] == 2,
                   @"callout title is rendered exactly once");
        BOOL calloutRecorded = NO;
        for (SPDFMarkdownRenderedBlock* block in obsidian.renderedDocument.renderedBlocks)
            if (block.kind == SPDFMarkdownBlockKindCallout) calloutRecorded = YES;
        SPDFExpect(calloutRecorded, @"callout title participates in layout and pagination");

        NSRange fencedCode = [canonical rangeOfString:@"let greeting"];
        SPDFExpect([document.renderedDocument.attributedString attribute:NSBackgroundColorAttributeName
                                                                 atIndex:fencedCode.location
                                                          effectiveRange:nil] == nil,
                   @"fenced code paints no per-character background; the code box is a page decoration");
        NSParagraphStyle* codeStyle = [document.renderedDocument.attributedString
            attribute:NSParagraphStyleAttributeName atIndex:fencedCode.location effectiveRange:nil];
        SPDFExpect(codeStyle.paragraphSpacing == 0 && codeStyle.paragraphSpacingBefore == 0 &&
                       fabs(codeStyle.lineSpacing - 2) < 0.001,
                   @"fenced code lines flow as one continuous block without inter-line gaps");
        SPDFExpect(fabs(codeStyle.firstLineHeadIndent - 12) < 0.001 && fabs(codeStyle.headIndent - 12) < 0.001 &&
                       fabs(codeStyle.tailIndent - -12) < 0.001,
                   @"fenced code text is inset 12pt within its box");
        NSRange inlineCode = [canonical rangeOfString:@"inline code"];
        SPDFExpect([document.renderedDocument.attributedString attribute:NSBackgroundColorAttributeName
                                                                 atIndex:inlineCode.location
                                                          effectiveRange:nil] != nil,
                   @"inline code spans keep their subtle chip background");
        NSRange h2 = [canonical rangeOfString:@"Lists and tables"];
        NSParagraphStyle* h2Style = [document.renderedDocument.attributedString
            attribute:NSParagraphStyleAttributeName atIndex:h2.location effectiveRange:nil];
        SPDFExpect(fabs(h2Style.paragraphSpacingBefore - 22) < 0.001 && fabs(h2Style.paragraphSpacing - 12) < 0.001,
                   @"H1/H2 headings get 22pt leading and 12pt trailing space below the underline");
        NSFont* h2Font = [document.renderedDocument.attributedString attribute:NSFontAttributeName
                                                                        atIndex:h2.location
                                                                 effectiveRange:nil];
        SPDFExpect(fabs(h2Font.pointSize - 22.5) < 0.01 &&
                       [h2Font isEqual:[NSFont systemFontOfSize:h2Font.pointSize weight:NSFontWeightSemibold]],
                   @"H2 renders at 1.5em in semibold rather than full bold");
        NSRange h1 = [canonical rangeOfString:@"Shenzhen PDF Markdown"];
        NSFont* h1Font = [document.renderedDocument.attributedString attribute:NSFontAttributeName
                                                                        atIndex:h1.location
                                                                 effectiveRange:nil];
        SPDFExpect(fabs(h1Font.pointSize - 26.25) < 0.01, @"H1 renders at 1.75em of the body size");

        NSRange bodyRun = [canonical rangeOfString:@"This is"];
        NSColor* bodyColor = [document.renderedDocument.attributedString attribute:NSForegroundColorAttributeName
                                                                            atIndex:bodyRun.location
                                                                     effectiveRange:nil];
        SPDFExpect(SPDFColorMatchesHex(bodyColor, 0x1F2328),
                   @"body text uses the concrete near-black reading color, never pure black");
        NSColor* h2Color = [document.renderedDocument.attributedString attribute:NSForegroundColorAttributeName
                                                                          atIndex:h2.location
                                                                   effectiveRange:nil];
        SPDFExpect(SPDFColorMatchesHex(h2Color, 0x1F2328), @"heading text shares the body near-black");
        NSRange linkRun = [canonical rangeOfString:@"safe link"];
        NSColor* linkColor = [document.renderedDocument.attributedString attribute:NSForegroundColorAttributeName
                                                                            atIndex:linkRun.location
                                                                     effectiveRange:nil];
        SPDFExpect(SPDFColorMatchesHex(linkColor, 0x0969DA), @"links use the concrete accent blue");
        NSString* obsidianText = obsidian.renderedDocument.attributedString.string;
        NSRange quoteRun = [obsidianText rangeOfString:@"A normal block quote"];
        NSColor* quoteTextColor = [obsidian.renderedDocument.attributedString
            attribute:NSForegroundColorAttributeName atIndex:quoteRun.location effectiveRange:nil];
        SPDFExpect(SPDFColorMatchesHex(quoteTextColor, 0x59636E),
                   @"block quote prose reads in the muted secondary color");

        NSUInteger unknownBlock = document.model.codeFences.lastObject.blockIndex;
        [document setLanguageIdentifier:@"python" forCodeBlock:unknownBlock];
        SPDFMarkdownRenderedBlock* unknown = [document.renderedDocument renderedBlockWithIndex:unknownBlock];
        NSString* language = [document.renderedDocument.attributedString
            attribute:SPDFMarkdownCodeLanguageAttribute atIndex:unknown.attributedRange.location effectiveRange:nil];
        SPDFExpect([language isEqualToString:@"python"], @"picker override re-renders an untagged fence");

        // Local-image layout (standalone figures, side-by-side multi-image
        // rows, inline images) is covered by SPDFMarkdownImageFigureTests.

        SPDFMarkdownParser* parser = [SPDFMarkdownParser new];
        SPDFMarkdownDocumentModel* centeredTableModel =
            [parser parseString:@"| center | right |\n| :---: | ---: |\n| alpha | beta |\n"
                      sourceURL:nil error:&error];
        SPDFMarkdownDocument* centeredTable = [[SPDFMarkdownDocument alloc]
            initWithModel:centeredTableModel options:SPDFMarkdownRenderOptions.defaultOptions];
        NSRange centeredRow = [centeredTable.renderedDocument.attributedString.string rangeOfString:@"\talpha\tbeta"];
        NSParagraphStyle* centeredStyle = [centeredTable.renderedDocument.attributedString
            attribute:NSParagraphStyleAttributeName atIndex:centeredRow.location effectiveRange:nil];
        SPDFExpect(centeredStyle.alignment == NSTextAlignmentLeft && centeredStyle.tabStops.count == 2 &&
                       centeredStyle.tabStops.firstObject.alignment == NSTextAlignmentCenter &&
                       centeredStyle.tabStops.lastObject.alignment == NSTextAlignmentRight,
                   @"first-column alignment is scoped to its own tab instead of the whole row");

        SPDFMarkdownDocumentModel* breakModel =
            [parser parseString:@"Above\n\n***\n\nBelow\n\n###### Tiny heading\n" sourceURL:nil error:&error];
        SPDFMarkdownDocument* breakDocument = [[SPDFMarkdownDocument alloc]
            initWithModel:breakModel options:SPDFMarkdownRenderOptions.defaultOptions];
        NSString* breakText = breakDocument.renderedDocument.attributedString.string;
        SPDFExpect(![breakText containsString:@"─"],
                   @"a thematic break reserves a blank line; the visible rule is a page decoration");
        SPDFMarkdownRenderedBlock* breakBlock = nil;
        for (SPDFMarkdownRenderedBlock* block in breakDocument.renderedDocument.renderedBlocks)
            if (block.kind == SPDFMarkdownBlockKindThematicBreak) breakBlock = block;
        SPDFExpect(breakBlock != nil && breakBlock.attributedRange.length == 1,
                   @"the thematic break stays a recorded block so pagination can place its rule");
        NSRange h6 = [breakText rangeOfString:@"Tiny heading"];
        NSFont* h6Font = [breakDocument.renderedDocument.attributedString attribute:NSFontAttributeName
                                                                             atIndex:h6.location
                                                                      effectiveRange:nil];
        NSColor* h6Color = [breakDocument.renderedDocument.attributedString
            attribute:NSForegroundColorAttributeName atIndex:h6.location effectiveRange:nil];
        SPDFExpect(fabs(h6Font.pointSize - 13.5) < 0.01 && SPDFColorMatchesHex(h6Color, 0x59636E),
                   @"H6 drops below body size and goes muted, caption-style");

        NSString* listSource = @"- first paragraph\n\n  - nested before\n\n  after nested\n\n  ```swift\n  let x = 1\n  ```\n";
        SPDFMarkdownDocumentModel* nestedModel = [parser parseString:listSource sourceURL:nil error:&error];
        SPDFMarkdownDocument* nested = [[SPDFMarkdownDocument alloc] initWithModel:nestedModel
                                                                            options:SPDFMarkdownRenderOptions.defaultOptions];
        NSString* nestedText = nested.renderedDocument.attributedString.string;
        NSRange firstParagraph = [nestedText rangeOfString:@"first paragraph"];
        NSRange nestedItem = [nestedText rangeOfString:@"nested before"];
        NSRange afterNested = [nestedText rangeOfString:@"after nested"];
        NSRange nestedCode = [nestedText rangeOfString:@"let x = 1"];
        SPDFExpect(firstParagraph.location < nestedItem.location && nestedItem.location < afterNested.location &&
                       afterNested.location < nestedCode.location,
                   @"interleaved list paragraphs, nested lists, following paragraphs, and code preserve source order");
        SPDFExpect([nestedText containsString:@"• nested before"], @"nested list content remains recursively rendered");
        NSRange secondParagraph = afterNested;
        NSParagraphStyle* secondParagraphStyle = [nested.renderedDocument.attributedString
            attribute:NSParagraphStyleAttributeName atIndex:secondParagraph.location effectiveRange:nil];
        SPDFExpect(secondParagraphStyle.headIndent >= 22,
                   @"continuation paragraphs align inside the list item rather than under its marker");
        NSString* nestedLanguage = [nested.renderedDocument.attributedString
            attribute:SPDFMarkdownCodeLanguageAttribute atIndex:nestedCode.location effectiveRange:nil];
        SPDFExpect([nestedLanguage isEqualToString:@"swift"], @"fenced code inside a list keeps code styling");
        NSMutableSet* depths = [NSMutableSet set];
        NSMutableDictionary<NSNumber*, NSNumber*>* indents = [NSMutableDictionary dictionary];
        for (SPDFMarkdownRenderedBlock* block in nested.renderedDocument.renderedBlocks)
            if (block.kind == SPDFMarkdownBlockKindListItem) {
                [depths addObject:@(block.depth)];
                NSParagraphStyle* style = [nested.renderedDocument.attributedString
                    attribute:NSParagraphStyleAttributeName atIndex:block.attributedRange.location effectiveRange:nil];
                indents[@(block.depth)] = @(style.headIndent);
            }
        SPDFExpect([depths containsObject:@0] && [depths containsObject:@1], @"nested list indentation is stable");
        SPDFExpect([indents[@1] doubleValue] > [indents[@0] doubleValue],
                   @"nested list paragraph indentation increases by depth");

        SPDFMarkdownRenderOptions* scaledOptions = SPDFMarkdownRenderOptions.defaultOptions;
        scaledOptions.fontScale = 1.5;
        SPDFMarkdownDocument* scaled = [SPDFMarkdownDocument documentWithURL:SPDFFixtureURL(@"commonmark-gfm.md")
                                                                     options:scaledOptions
                                                                       error:&error];
        NSString* scaledText = scaled.renderedDocument.attributedString.string;
        NSRange scaledBody = [scaledText rangeOfString:@"First item"];
        NSFont* scaledBodyFont = [scaled.renderedDocument.attributedString attribute:NSFontAttributeName
                                                                             atIndex:scaledBody.location
                                                                      effectiveRange:nil];
        NSRange scaledCode = [scaledText rangeOfString:@"let greeting"];
        NSFont* scaledCodeFont = [scaled.renderedDocument.attributedString attribute:NSFontAttributeName
                                                                             atIndex:scaledCode.location
                                                                      effectiveRange:nil];
        SPDFExpect(fabs(scaledBodyFont.pointSize - 22.5) < 0.01 && fabs(scaledCodeFont.pointSize - 19.5) < 0.01,
                   @"fontScale multiplies body and code font sizes in the attributed output");
        NSRange scaledParagraph = [scaledText rangeOfString:@"This is"];
        NSParagraphStyle* scaledBodyStyle = [scaled.renderedDocument.attributedString
            attribute:NSParagraphStyleAttributeName atIndex:scaledParagraph.location effectiveRange:nil];
        SPDFExpect(fabs(scaledBodyStyle.lineSpacing - 6) < 0.01 && fabs(scaledBodyStyle.paragraphSpacing - 18) < 0.01,
                   @"fontScale multiplies line and paragraph spacing");
        NSParagraphStyle* scaledCodeStyle = [scaled.renderedDocument.attributedString
            attribute:NSParagraphStyleAttributeName atIndex:scaledCode.location effectiveRange:nil];
        SPDFExpect(fabs(scaledCodeStyle.firstLineHeadIndent - 12) < 0.001,
                   @"indent constants stay unscaled under fontScale");
        scaledOptions.fontScale = 99;
        SPDFExpect(fabs(scaledOptions.fontScale - 3.0) < 0.001, @"fontScale clamps to at most 3.0");
        scaledOptions.fontScale = 0.1;
        SPDFExpect(fabs(scaledOptions.fontScale - 0.5) < 0.001, @"fontScale clamps to at least 0.5");
        scaledOptions.fontScale = 1.5;
        SPDFMarkdownRenderOptions* copiedOptions = [scaledOptions copy];
        SPDFExpect(fabs(copiedOptions.fontScale - 1.5) < 0.001, @"copyWithZone preserves fontScale");
        SPDFExpect(fabs(SPDFMarkdownRenderOptions.defaultOptions.fontScale - 1.0) < 0.001 &&
                       fabs([SPDFMarkdownRenderOptions new].fontScale - 1.0) < 0.001,
                   @"fontScale defaults to 1.0");

        // Reading themes: the default stays byte-identical Light (the class
        // accessors alias the Light instance), the Dark instance exposes the
        // Obsidian palette, and options.themeVariant re-derives the palette
        // roles, copies with the options, and drives the rendered colors.
        SPDFMarkdownTheme* lightTheme = [SPDFMarkdownTheme themeForVariant:SPDFMarkdownThemeVariantLight];
        SPDFMarkdownTheme* darkTheme = [SPDFMarkdownTheme themeForVariant:SPDFMarkdownThemeVariantDark];
        SPDFExpect(SPDFMarkdownRenderOptions.defaultOptions.themeVariant == SPDFMarkdownThemeVariantLight &&
                       [SPDFMarkdownRenderOptions.defaultOptions.textColor isEqual:lightTheme.bodyTextColor] &&
                       [SPDFMarkdownTheme.bodyTextColor isEqual:lightTheme.bodyTextColor] &&
                       SPDFColorMatchesHex(lightTheme.paperColor, 0xFFFFFF) &&
                       SPDFColorMatchesHex(lightTheme.bodyTextColor, 0x1F2328),
                   @"default options render the Light theme and the class accessors alias it");
        // The viewport gutter: light names none (every surface keeps the
        // system background it already used), dark names one that is clearly
        // BELOW the paper so a page edge always reads against it. Paper
        // presentation follows the same role: shadow in light, 1px border in
        // dark.
        SPDFExpect(lightTheme.viewportBackgroundColor == nil && lightTheme.drawsPaperShadow,
                   @"the light theme names no gutter and keeps the paper drop shadow");
        SPDFExpect(SPDFColorMatchesHex(darkTheme.viewportBackgroundColor, 0x0A0A0A) && !darkTheme.drawsPaperShadow &&
                       SPDFColorMatchesHex(darkTheme.paperBorderColor, 0x3D3D3D),
                   @"the dark theme names a #0A0A0A gutter and swaps the shadow for a #3D3D3D border");
        SPDFExpect(SPDFLuminance(darkTheme.viewportBackgroundColor) < SPDFLuminance(darkTheme.paperColor) - 0.01,
                   @"the dark gutter reads darker than the dark paper");
        SPDFExpect(SPDFColorMatchesHex(darkTheme.paperColor, 0x1E1E1E) &&
                       SPDFColorMatchesHex(darkTheme.bodyTextColor, 0xDCDDDE) &&
                       SPDFColorMatchesHex(darkTheme.secondaryTextColor, 0x999999) &&
                       SPDFColorMatchesHex(darkTheme.linkColor, 0x7F6DF2) &&
                       SPDFColorMatchesHex(darkTheme.codeBoxFillColor, 0x262626) &&
                       SPDFColorMatchesHex(darkTheme.codeBoxStrokeColor, 0x363636) &&
                       SPDFColorMatchesHex(darkTheme.inlineCodeChipColor, 0x2A2A2A) &&
                       SPDFColorMatchesHex(darkTheme.headingRuleColor, 0x333333) &&
                       SPDFColorMatchesHex(darkTheme.tableHeaderFillColor, 0x262626) &&
                       SPDFColorMatchesHex(darkTheme.tableStripeFillColor, 0x232323) &&
                       SPDFColorMatchesHex(darkTheme.syntaxKeywordColor, 0xC678DD) &&
                       SPDFColorMatchesHex(darkTheme.syntaxStringColor, 0x98C379) &&
                       SPDFColorMatchesHex(darkTheme.syntaxNumberColor, 0xD19A66) &&
                       SPDFColorMatchesHex(darkTheme.syntaxCommentColor, 0x7F848E) &&
                       SPDFColorMatchesHex(darkTheme.imagePlaceholderFillColor, 0x262626),
                   @"the Dark theme exposes the Obsidian palette across all roles");
        SPDFMarkdownRenderOptions* darkOptions =
            [SPDFMarkdownRenderOptions defaultOptionsForThemeVariant:SPDFMarkdownThemeVariantDark];
        SPDFMarkdownRenderOptions* darkCopy = [darkOptions copy];
        SPDFExpect(darkCopy.themeVariant == SPDFMarkdownThemeVariantDark &&
                       [darkCopy.textColor isEqual:darkTheme.bodyTextColor] &&
                       [darkCopy.linkColor isEqual:darkTheme.linkColor] &&
                       [darkCopy.codeBackgroundColor isEqual:darkTheme.inlineCodeChipColor],
                   @"themeVariant re-derives the palette roles and survives copyWithZone");
        SPDFMarkdownDocumentModel* darkModel =
            [parser parseString:@"Dark body [link](https://example.com) and `chip`\n\n```swift\nlet x = 1 // note\n```\n"
                      sourceURL:nil
                          error:&error];
        SPDFMarkdownDocument* darkDocument = [[SPDFMarkdownDocument alloc] initWithModel:darkModel
                                                                                  options:darkOptions];
        NSString* darkText = darkDocument.renderedDocument.attributedString.string;
        NSRange darkBody = [darkText rangeOfString:@"Dark body"];
        NSRange darkLink = [darkText rangeOfString:@"link"];
        NSRange darkKeyword = [darkText rangeOfString:@"let"];
        SPDFExpect(SPDFColorMatchesHex([darkDocument.renderedDocument.attributedString
                                           attribute:NSForegroundColorAttributeName
                                             atIndex:darkBody.location
                                      effectiveRange:nil],
                                       0xDCDDDE),
                   @"Dark render paints body text in the Obsidian near-white");
        SPDFExpect(SPDFColorMatchesHex([darkDocument.renderedDocument.attributedString
                                           attribute:NSForegroundColorAttributeName
                                             atIndex:darkLink.location
                                      effectiveRange:nil],
                                       0x7F6DF2),
                   @"Dark render paints links in the Obsidian purple accent");
        SPDFExpect(SPDFColorMatchesHex([darkDocument.renderedDocument.attributedString
                                           attribute:NSForegroundColorAttributeName
                                             atIndex:darkKeyword.location
                                      effectiveRange:nil],
                                       0xC678DD),
                   @"Dark render paints syntax keywords from the dark token set");

        // The portable C core cannot import SPDFMarkdownTheme, so it carries its
        // own copy of the dark endpoints. Recolored PDF pages and dark Markdown
        // pages are only the same product while these agree, so assert it here
        // rather than trusting two hand-kept constants not to drift.
        SPDFMarkdownTheme* darkPalette = [SPDFMarkdownTheme themeForVariant:SPDFMarkdownThemeVariantDark];
        spdf_recolor_theme coreTheme = spdf_recolor_default_dark_theme();
        SPDFExpect(SPDFColorMatchesHex(darkPalette.paperColor, coreTheme.paper_rgb),
                   @"core recolor paper matches the dark theme paperColor");
        SPDFExpect(SPDFColorMatchesHex(darkPalette.bodyTextColor, coreTheme.ink_rgb),
                   @"core recolor ink matches the dark theme bodyTextColor");
        SPDFExpect(coreTheme.paper_rgb != 0x000000u, @"dark paper is not pure black");

        NSTextView* view = [document newSelectableTextView];
        SPDFExpect(view.isSelectable && !view.isEditable && view.importsGraphics,
                   @"native view is selectable, read-only, and attachment-capable");
    }
    return SPDFFinishTests(@"SPDFMarkdownRendererTests");
}
