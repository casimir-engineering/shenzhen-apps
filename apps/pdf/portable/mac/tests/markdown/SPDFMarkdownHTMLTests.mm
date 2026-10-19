#import "SPDFMarkdownTestSupport.h"

#import "../../markdown/SPDFMarkdownDocument.h"
#import "../../markdown/SPDFMarkdownParser.h"
#import "../../markdown/SPDFMarkdownRenderer.h"

// HTML-island whitelist tests: raw tags never reach the canonical text,
// container islands align the markdown blocks they span, <img> size hints
// survive, <kbd>/<sub>/<sup> style, dropped elements vanish with their
// content, and simple HTML tables map onto the table model.

static void SPDFHTMLCollect(NSArray<SPDFMarkdownBlock*>* blocks, NSMutableArray<SPDFMarkdownBlock*>* out) {
    for (SPDFMarkdownBlock* block in blocks) {
        [out addObject:block];
        SPDFHTMLCollect(block.children, out);
    }
}

static NSArray<SPDFMarkdownBlock*>* SPDFHTMLAllBlocks(SPDFMarkdownDocumentModel* model) {
    NSMutableArray* out = [NSMutableArray array];
    SPDFHTMLCollect(model.blocks, out);
    return out;
}

static SPDFMarkdownInlineRun* SPDFHTMLFindRun(SPDFMarkdownDocumentModel* model,
                                              BOOL (^predicate)(SPDFMarkdownInlineRun*)) {
    for (SPDFMarkdownBlock* block in SPDFHTMLAllBlocks(model))
        for (SPDFMarkdownInlineRun* run in block.runs)
            if (predicate(run)) return run;
    return nil;
}

static NSTextAlignment SPDFHTMLAlignmentAt(NSAttributedString* rendered, NSString* needle) {
    NSRange range = [rendered.string rangeOfString:needle];
    if (range.location == NSNotFound) return (NSTextAlignment)-1;
    NSParagraphStyle* style = [rendered attribute:NSParagraphStyleAttributeName
                                          atIndex:range.location
                                   effectiveRange:NULL];
    return style ? style.alignment : NSTextAlignmentNatural;
}

int main(void) {
    @autoreleasepool {
        NSError* error = nil;
        SPDFMarkdownDocument* document = [SPDFMarkdownDocument documentWithURL:SPDFFixtureURL(@"html-readme.md")
                                                                        options:nil error:&error];
        SPDFExpect(document != nil && error == nil, @"HTML-heavy fixture parses and renders");
        SPDFMarkdownDocumentModel* model = document.model;
        NSString* canonical = document.renderedDocument.attributedString.string;
        NSAttributedString* rendered = document.renderedDocument.attributedString;

        // Canonical-coordinate contract: raw tag text must never be visible.
        for (NSString* fragment in @[ @"<div", @"</", @"<img", @"<kbd", @"<sub", @"<script",
                                      @"<h1", @"align=", @"onerror", @"alert(" ]) {
            SPDFExpect(![canonical containsString:fragment],
                       [@"canonical text contains no raw HTML: " stringByAppendingString:fragment]);
        }
        SPDFExpect([canonical containsString:@"FixtureApp"], @"HTML heading text is canonical");
        SPDFExpect([canonical containsString:@"Latest 1.2.3 · Apple Silicon"],
                   @"inline HTML text flows as plain canonical text");

        // <h1 align="center"> becomes a real, navigable level-1 heading.
        SPDFMarkdownHeading* heading = model.headings.firstObject;
        SPDFExpect(heading.level == 1 && [heading.title isEqualToString:@"FixtureApp"],
                   @"HTML h1 lands in the heading index");
        SPDFExpect(SPDFHTMLAlignmentAt(rendered, @"FixtureApp") == NSTextAlignmentCenter,
                   @"h1 align=center renders centered");

        // The centered div island spans several markdown blocks until </div>.
        SPDFExpect(SPDFHTMLAlignmentAt(rendered, @"Latest") == NSTextAlignmentCenter,
                   @"paragraph inside the centered div island renders centered");
        SPDFExpect(SPDFHTMLAlignmentAt(rendered, @"Regular paragraph after") != NSTextAlignmentCenter,
                   @"the closing </div> island pops the centered context");

        // <img> runs carry display-size hints; caps remain maxima elsewhere.
        SPDFMarkdownInlineRun* badge = SPDFHTMLFindRun(model, ^BOOL(SPDFMarkdownInlineRun* run) {
            return [run.destination isEqualToString:@"https://img.example.com/badge.svg"];
        });
        SPDFExpect((badge.traits & SPDFMarkdownInlineTraitImage) != 0 &&
                       fabs(badge.preferredImageHeight - 46) < 0.001 && badge.preferredImageWidth == 0 &&
                       [badge.text isEqualToString:@"Download badge"],
                   @"badge <img> becomes an image run with a height hint and alt text");
        SPDFMarkdownInlineRun* hero = SPDFHTMLFindRun(model, ^BOOL(SPDFMarkdownInlineRun* run) {
            return [run.destination isEqualToString:@"docs/hero.png"];
        });
        SPDFExpect(fabs(hero.preferredImageWidth - 880) < 0.001,
                   @"hero <img> keeps its width=880 display hint");
        for (SPDFMarkdownBlock* block in SPDFHTMLAllBlocks(model)) {
            if (![block.runs containsObject:hero]) continue;
            SPDFExpect(block.blockAlignment == SPDFMarkdownTableAlignmentCenter,
                       @"<p align=center><img></p> carries center alignment");
        }

        // Inline link whitelist: #anchor and https survive, javascript: dies.
        SPDFMarkdownInlineRun* anchor = SPDFHTMLFindRun(model, ^BOOL(SPDFMarkdownInlineRun* run) {
            return [run.text isEqualToString:@"Reading"];
        });
        SPDFExpect((anchor.traits & SPDFMarkdownInlineTraitLink) != 0 &&
                       (anchor.traits & SPDFMarkdownInlineTraitSubscript) != 0 &&
                       [anchor.destination isEqualToString:@"#reading"],
                   @"<sub><a href=#anchor> yields a subscripted link run");
        SPDFMarkdownInlineRun* evil = SPDFHTMLFindRun(model, ^BOOL(SPDFMarkdownInlineRun* run) {
            return [run.text containsString:@"evil"];
        });
        SPDFExpect(evil != nil && (evil.traits & SPDFMarkdownInlineTraitLink) == 0 && evil.destination == nil,
                   @"javascript: href is dropped but its text survives unstyled");

        // <kbd> chip: smaller mono type on the inline-code background.
        NSRange press = [canonical rangeOfString:@"Press "];
        NSRange kbd = [canonical rangeOfString:@"Cmd+K"];
        SPDFExpect(press.location != NSNotFound && kbd.location != NSNotFound, @"kbd sentence is canonical");
        NSFont* bodyFont = [rendered attribute:NSFontAttributeName atIndex:press.location effectiveRange:NULL];
        NSFont* kbdFont = [rendered attribute:NSFontAttributeName atIndex:kbd.location effectiveRange:NULL];
        SPDFExpect(kbdFont.pointSize < bodyFont.pointSize &&
                       [rendered attribute:NSBackgroundColorAttributeName atIndex:kbd.location
                             effectiveRange:NULL] != nil,
                   @"<kbd> renders as a smaller chip with a background");

        // <sub>/<sup>: smaller, baseline-shifted runs like the math scripts.
        NSRange water = [canonical rangeOfString:@"H2O"];
        NSRange energy = [canonical rangeOfString:@"mc2"];
        SPDFExpect(water.location != NSNotFound && energy.location != NSNotFound,
                   @"sub/sup text flows as plain canonical characters");
        NSNumber* subOffset = [rendered attribute:NSBaselineOffsetAttributeName
                                          atIndex:water.location + 1 effectiveRange:NULL];
        NSNumber* supOffset = [rendered attribute:NSBaselineOffsetAttributeName
                                          atIndex:energy.location + 2 effectiveRange:NULL];
        NSFont* subFont = [rendered attribute:NSFontAttributeName atIndex:water.location + 1 effectiveRange:NULL];
        SPDFExpect(subOffset.doubleValue < 0 && supOffset.doubleValue > 0 &&
                       subFont.pointSize < bodyFont.pointSize,
                   @"<sub> lowers and <sup> raises smaller runs");

        // Dropped elements vanish with their content, inline and block alike.
        SPDFExpect([canonical containsString:@"Inline  stays clean"] ||
                       [canonical containsString:@"Inline stays clean"],
                   @"inline <script> island disappears with its content");

        // Details render expanded: bold summary line + the fenced code inside.
        SPDFExpect([canonical containsString:@"▸ Build from source"],
                   @"summary renders as a disclosure-prefixed line");
        SPDFExpect(model.codeFences.count == 1 &&
                       [model.codeFences.firstObject.code containsString:@"make -C portable mac-app"] &&
                       [model.codeFences.firstObject.declaredLanguage isEqualToString:@"sh"],
                   @"markdown inside <details> renders expanded");
        NSRange summary = [canonical rangeOfString:@"▸ Build from source"];
        NSFont* summaryFont = [rendered attribute:NSFontAttributeName atIndex:summary.location effectiveRange:NULL];
        SPDFExpect((NSFontManager.sharedFontManager.availableFontFamilies != nil) &&
                       ([NSFontManager.sharedFontManager traitsOfFont:summaryFont] & NSBoldFontMask) != 0,
                   @"summary line is bold");

        // Simple HTML tables map onto the table model with cell alignment.
        NSMutableArray<SPDFMarkdownBlock*>* tables = [NSMutableArray array];
        for (SPDFMarkdownBlock* block in SPDFHTMLAllBlocks(model))
            if (block.kind == SPDFMarkdownBlockKindTable) [tables addObject:block];
        SPDFExpect(tables.count == 1, @"exactly one HTML table maps onto the table model");
        SPDFMarkdownBlock* table = tables.firstObject;
        SPDFExpect(table.tableColumnCount == 2, @"HTML table retains its column count");
        SPDFMarkdownBlock* headSection = table.children.firstObject;
        SPDFMarkdownBlock* headRow = headSection.children.firstObject;
        SPDFExpect(headSection.kind == SPDFMarkdownBlockKindTableHead &&
                       headRow.children.count == 2 &&
                       headRow.children[0].kind == SPDFMarkdownBlockKindTableHeaderCell &&
                       headRow.children[0].tableAlignment == SPDFMarkdownTableAlignmentLeft &&
                       headRow.children[1].tableAlignment == SPDFMarkdownTableAlignmentCenter,
                   @"th cells keep their align attributes in a header section");
        SPDFExpect([canonical containsString:@"\tKey\tAction"], @"table cells render tab-separated");

        // colspan/rowspan tables degrade to plain text rows, never dropped.
        SPDFExpect([canonical containsString:@"Spanning cell"] &&
                       [canonical containsString:@"left right"],
                   @"a colspan table degrades to plain text rows");

        // Unsafe fixture: enabling HTML must not leak script content either.
        SPDFMarkdownDocumentModel* unsafe = [[SPDFMarkdownParser new] loadURL:SPDFFixtureURL(@"unsafe.md")
                                                                        error:&error];
        SPDFMarkdownRenderedDocument* unsafeRendered =
            [[SPDFMarkdownRenderer new] renderModel:unsafe
                                            options:SPDFMarkdownRenderOptions.defaultOptions
                                  languageOverrides:nil];
        SPDFExpect(![unsafeRendered.attributedString.string containsString:@"alert"] &&
                       ![unsafeRendered.attributedString.string containsString:@"attacker.invalid\""],
                   @"unsafe fixture scripts and event handlers never render");
    }
    return SPDFFinishTests(@"SPDFMarkdownHTMLTests");
}
