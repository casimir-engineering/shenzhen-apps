#import "SPDFMarkdownImageRowBand.h"

#import <CoreText/CoreText.h>

#import "SPDFMarkdownPaginator.h"
#import "SPDFMarkdownRenderInternal.h"

// Image rows caption each image below itself. The renderer keeps the captions
// canonical — one trailing caption paragraph, each caption's text exactly
// once, image and caption spans linked by SPDFMarkdownImageRowIndexAttribute
// — and this pass turns that paragraph into custom-positioned lines: the
// default centered caption line(s) are replaced by one line per caption whose
// center x matches its image's measured x-span, emitted right below the image
// line the image actually landed on (wrapped rows get one caption band per
// wrapped image line). The whole row becomes one atomic band so the captions
// keep riding their images across page breaks. Returns nil when the block
// carries no row captions.
SPDFMarkdownPaginationItem* SPDFMarkdownImageRowBandItem(SPDFMarkdownRenderedBlock* block,
                                                                NSAttributedString* text, NSLayoutManager* layout,
                                                                NSTextContainer* container,
                                                                NSArray<SPDFMarkdownTextLine*>* lines) {
    if (block.kind != SPDFMarkdownBlockKindParagraph) return nil;
    NSMutableDictionary<NSNumber*, NSValue*>* captionRanges = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber*, NSValue*>* imageRanges = [NSMutableDictionary dictionary];
    [text enumerateAttribute:SPDFMarkdownImageRowIndexAttribute
                     inRange:block.attributedRange
                     options:0
                  usingBlock:^(NSNumber* ordinal, NSRange range, BOOL* stop) {
                    (void)stop;
                    if (!ordinal || !range.length) return;
                    NSNumber* role = [text attribute:SPDFMarkdownImageLayoutAttribute
                                             atIndex:range.location
                                      effectiveRange:NULL];
                    if (role.integerValue == SPDFMarkdownImageLayoutRoleCaption)
                        captionRanges[ordinal] = [NSValue valueWithRange:range];
                    else
                        imageRanges[ordinal] = [NSValue valueWithRange:range];
                  }];
    if (!captionRanges.count) return nil;
    NSRange captionParagraph =
        [text.string paragraphRangeForRange:[captionRanges.allValues.firstObject rangeValue]];

    // Every caption shares one style, so the default-measured caption line
    // supplies the band height and baseline for all of them.
    CGFloat captionHeight = 0;
    CGFloat captionBaseline = 0;
    for (SPDFMarkdownTextLine* line in lines) {
        if (!NSLocationInRange(line.attributedRange.location, captionParagraph)) continue;
        captionHeight = line.height;
        captionBaseline = line.baselineOffset;
        break;
    }
    if (captionHeight <= 0) return nil;

    NSArray<NSNumber*>* ordinals = [captionRanges.allKeys sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray<SPDFMarkdownTextLine*>* bandLines = [NSMutableArray arrayWithCapacity:lines.count];
    CGFloat y = 0;
    for (SPDFMarkdownTextLine* line in lines) {
        if (NSLocationInRange(line.attributedRange.location, captionParagraph)) continue;
        [bandLines addObject:[[SPDFMarkdownTextLine alloc] initWithAttributedRange:line.attributedRange
                                                                            height:line.height
                                                                           xOffset:line.xOffset
                                                                    baselineOffset:line.baselineOffset
                                                                   rowLocalYOffset:y]];
        BOOL captionsBelow = NO;
        for (NSNumber* ordinal in ordinals) {
            NSValue* imageValue = imageRanges[ordinal];
            if (!imageValue || !NSLocationInRange(imageValue.rangeValue.location, line.attributedRange)) continue;
            NSRange captionRange = captionRanges[ordinal].rangeValue;
            NSRange imageGlyphs = [layout glyphRangeForCharacterRange:imageValue.rangeValue
                                                 actualCharacterRange:NULL];
            NSRect imageRect = [layout boundingRectForGlyphRange:imageGlyphs inTextContainer:container];
            // The caption draws as one CTLine at an explicit x, so its center
            // comes from the same typographic width the drawing pass will use.
            CTLineRef captionLine =
                SPDFMarkdownCreateFragmentLine([text attributedSubstringFromRange:captionRange]);
            CGFloat captionWidth = (CGFloat)CTLineGetTypographicBounds(captionLine, NULL, NULL, NULL);
            CFRelease(captionLine);
            [bandLines addObject:[[SPDFMarkdownTextLine alloc]
                                     initWithAttributedRange:captionRange
                                                      height:captionHeight
                                                     xOffset:NSMidX(imageRect) - captionWidth / 2
                                              baselineOffset:captionBaseline
                                             rowLocalYOffset:y + line.height]];
            captionsBelow = YES;
        }
        y += line.height;
        if (captionsBelow) y += captionHeight;
    }
    if (!bandLines.count) return nil;
    return [[SPDFMarkdownPaginationItem alloc] initWithBlockIndex:block.blockIndex
                                                             kind:block.kind
                                                     headingLevel:block.level
                                                     tableRowInfo:nil
                                                       bandLayout:YES
                                                            lines:bandLines];
}
