#import "SPDFMacChatMarkdownParts.h"

#import "markdown/SPDFMarkdownMathTypesetter.h"

// How a message's text differs from a page's once the engine has rendered it: smaller headings, tighter lists,
// display math at the text size, diagrams and formulas closer to their neighbours, and blocks shown as text.

NSAttributedStringKey const SPDFMacChatTightBlockAttribute = @"SPDFMacChatTightBlock";

// Chat headings: H1 17 pt, H2 15, H3 to H5 13 semibold, H6 12; less air than a page's headings.
static void Headings(NSMutableAttributedString* text, SPDFMarkdownRenderedDocument* rendered) {
    for (SPDFMarkdownRenderedBlock* block in rendered.renderedBlocks) {
        if (block.kind != SPDFMarkdownBlockKindHeading || NSMaxRange(block.attributedRange) > text.length) continue;
        NSUInteger level = MIN(MAX(block.level, (NSUInteger)1), (NSUInteger)6);
        CGFloat size = level == 1 ? 17 : level == 2 ? 15 : level == 6 ? 12 : 13;
        [text addAttribute:NSFontAttributeName value:[NSFont systemFontOfSize:size weight:NSFontWeightSemibold]
                     range:block.attributedRange];
        NSParagraphStyle* style = [text attribute:NSParagraphStyleAttributeName atIndex:block.attributedRange.location
                                   effectiveRange:NULL];
        NSMutableParagraphStyle* chat = [style mutableCopy] ?: [NSMutableParagraphStyle new];
        chat.paragraphSpacingBefore = level <= 2 ? 10 : 8;
        chat.paragraphSpacing = 4;
        [text addAttribute:NSParagraphStyleAttributeName value:chat range:block.attributedRange];
    }
}

// A list reads as one block in a bubble: 2 pt between its items instead of a paragraph's 8, which stays after its
// last item.
static void Lists(NSMutableAttributedString* text, SPDFMarkdownRenderedDocument* rendered) {
    NSArray<SPDFMarkdownRenderedBlock*>* blocks = rendered.renderedBlocks;
    for (NSUInteger index = 0; index + 1 < blocks.count; index++) {
        SPDFMarkdownRenderedBlock* block = blocks[index];
        if (block.kind != SPDFMarkdownBlockKindListItem || blocks[index + 1].kind != SPDFMarkdownBlockKindListItem ||
            !block.attributedRange.length || NSMaxRange(block.attributedRange) > text.length)
            continue;
        [text enumerateAttribute:NSParagraphStyleAttributeName inRange:block.attributedRange options:0
                      usingBlock:^(NSParagraphStyle* style, NSRange range, BOOL* stop) {
                        (void)stop;
                        NSMutableParagraphStyle* tight = [style mutableCopy] ?: [NSMutableParagraphStyle new];
                        tight.paragraphSpacing = 2;
                        [text addAttribute:NSParagraphStyleAttributeName value:tight range:range];
                      }];
    }
}

// Display math at the text size: the engine sets it 1.15 times larger for a page.
static void DisplayMath(NSMutableAttributedString* text) {
    [text enumerateAttribute:SPDFMarkdownMathLayoutAttribute inRange:NSMakeRange(0, text.length) options:0
                  usingBlock:^(id role, NSRange range, BOOL* stop) {
                    (void)stop;
                    if (!role) return;
                    [text enumerateAttribute:NSFontAttributeName inRange:range options:0
                                  usingBlock:^(NSFont* font, NSRange part, BOOL* inner) {
                                    (void)inner;
                                    NSFont* smaller = [NSFontManager.sharedFontManager
                                        convertFont:font toSize:MAX(6, font.pointSize / 1.15)];
                                    if (smaller) [text addAttribute:NSFontAttributeName value:smaller range:part];
                                  }];
                  }];
}

void SPDFMacChatScaleText(NSMutableAttributedString* text, SPDFMarkdownRenderedDocument* rendered) {
    Headings(text, rendered);
    Lists(text, rendered);
    DisplayMath(text);
}

static void Restyle(NSMutableAttributedString* text, NSRange range, void (^change)(NSMutableParagraphStyle* style)) {
    [text enumerateAttribute:NSParagraphStyleAttributeName inRange:range options:0
                  usingBlock:^(NSParagraphStyle* style, NSRange part, BOOL* stop) {
                    (void)stop;
                    NSMutableParagraphStyle* changed = [style mutableCopy] ?: [NSMutableParagraphStyle new];
                    change(changed);
                    [text addAttribute:NSParagraphStyleAttributeName value:changed range:part];
                  }];
}

// Diagrams and display formulas sit closer to the text around them than a page sets them: nothing above of their
// own, 6 pt below, and the paragraph before them ends 4 pt sooner, which leaves 8 to 12 pt of blank on either side
// at 1x. With the page's spacing a formula stood 25 pt below its sentence and a diagram 30 pt, where body
// paragraphs are 10 pt apart.
void SPDFMacChatSpaceBlocks(NSMutableAttributedString* text) {
    NSMutableArray<NSValue*>* paragraphs = [NSMutableArray array];
    NSStringEnumerationOptions each = NSStringEnumerationByParagraphs | NSStringEnumerationSubstringNotRequired;
    [text.string enumerateSubstringsInRange:NSMakeRange(0, text.length) options:each
                                 usingBlock:^(NSString* part, NSRange range, NSRange whole, BOOL* stop) {
                                   (void)part, (void)range, (void)stop;
                                   if (whole.length) [paragraphs addObject:[NSValue valueWithRange:whole]];
                                 }];
    BOOL previousTight = NO;
    for (NSUInteger index = 0; index < paragraphs.count; index++) {
        NSRange paragraph = paragraphs[index].rangeValue;
        BOOL tight = [text attribute:SPDFMacChatTightBlockAttribute atIndex:paragraph.location effectiveRange:NULL] ||
                     [text attribute:SPDFMarkdownMathLayoutAttribute atIndex:paragraph.location effectiveRange:NULL];
        if (tight) {
            Restyle(text, paragraph, ^(NSMutableParagraphStyle* style) {
              style.paragraphSpacingBefore = 0;
              style.paragraphSpacing = MIN(style.paragraphSpacing, 6);
              style.lineSpacing = 0;
            });
            // Two such blocks in a row keep the 6 pt between them.
            if (index && !previousTight)
                Restyle(text, paragraphs[index - 1].rangeValue, ^(NSMutableParagraphStyle* style) {
                  style.paragraphSpacing = MIN(style.paragraphSpacing, 4);
                });
        }
        previousTight = tight;
    }
    [text removeAttribute:SPDFMacChatTightBlockAttribute range:NSMakeRange(0, text.length)];
}

NSAttributedString* SPDFMacChatTextBlock(NSString* shown, NSString* copied, NSString* note,
                                         SPDFMacChatMarkdownOptions* options) {
    NSMutableAttributedString* text = [NSMutableAttributedString new];
    if (note.length) {
        NSFont* italic = [NSFontManager.sharedFontManager convertFont:[NSFont systemFontOfSize:12]
                                                          toHaveTrait:NSItalicFontMask];
        [text appendAttributedString:[[NSAttributedString alloc]
                                         initWithString:[note stringByAppendingString:@"\u2028"] attributes:@{
                                             NSFontAttributeName : italic, SPDFMacChatMarkdownSourceAttribute : @"",
                                             NSForegroundColorAttributeName : options.secondaryTextColor}]];
    }
    NSString* lines = [shown stringByReplacingOccurrencesOfString:@"\n" withString:@"\u2028"];
    [text appendAttributedString:[[NSAttributedString alloc] initWithString:lines attributes:@{
              NSFontAttributeName : [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular],
              NSForegroundColorAttributeName : options.textColor, SPDFMacChatMarkdownSourceAttribute : copied}]];
    return text;
}
