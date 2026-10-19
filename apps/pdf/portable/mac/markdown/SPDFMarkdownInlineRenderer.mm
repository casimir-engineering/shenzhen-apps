#import "SPDFMarkdownDecorations.h"
#import "SPDFMarkdownMathTypesetter.h"
#import "SPDFMarkdownRenderInternal.h"

// Inline-run rendering: styled text runs, links, and image attachments with
// their alt-text captions. Block structure (headings, lists, tables, quotes)
// stays in SPDFMarkdownBlockRenderer.mm; this file owns everything that flows
// inside a single block's runs.

NSAttributedStringKey const SPDFMarkdownImageLayoutAttribute = @"SPDFMarkdownImageLayout";
NSAttributedStringKey const SPDFMarkdownImageRowIndexAttribute = @"SPDFMarkdownImageRowIndex";

NSFont* SPDFMarkdownFontWithTraits(NSFont* font, NSFontTraitMask traits) {
    return [NSFontManager.sharedFontManager convertFont:font toHaveTrait:traits] ?: font;
}

void SPDFMarkdownAppend(SPDFMarkdownRenderContext* context, NSString* string,
                        NSDictionary<NSAttributedStringKey, id>* attributes) {
    if (string.length) {
        [context.output appendAttributedString:[[NSAttributedString alloc] initWithString:string
                                                                               attributes:attributes]];
    }
}

CGFloat SPDFMarkdownRenderScale(SPDFMarkdownRenderContext* context) {
    CGFloat scale = context.options.fontScale;
    return scale > 0 ? scale : 1;
}

// Page-sized content — an image figure, a pending placeholder box, an image
// row, a table's provisional columns, a diagram — budgets against the
// printable page box when the render carries one, so turning the paper really
// re-fits it. Without a page (NSZeroSize) the caller's fallback stands
// unchanged; that fallback is the old constant budget at every call site.
CGFloat SPDFMarkdownContentWidthBudget(SPDFMarkdownRenderContext* context, CGFloat depthIndent,
                                       CGFloat pagelessFallback) {
    CGFloat pageWidth = context.options.pageContentSize.width;
    return pageWidth > 0 ? pageWidth - depthIndent : pagelessFallback;
}

CGFloat SPDFMarkdownContentHeightBudget(SPDFMarkdownRenderContext* context, CGFloat pagelessFallback) {
    CGFloat pageHeight = context.options.pageContentSize.height;
    if (pageHeight <= 0) return pagelessFallback;
    CGFloat margin = context.options.paragraphSpacing * SPDFMarkdownRenderScale(context);
    return MAX(64.0, pageHeight - 2 * margin);
}

static NSDictionary* SPDFRunAttributes(SPDFMarkdownRenderContext* context, SPDFMarkdownInlineRun* run) {
    BOOL mono = (run.traits & (SPDFMarkdownInlineTraitCode | SPDFMarkdownInlineTraitKeyboard)) != 0;
    NSFont* font = mono ? context.codeFont : context.bodyFont;
    if (run.traits & SPDFMarkdownInlineTraitStrong) font = SPDFMarkdownFontWithTraits(font, NSBoldFontMask);
    if (run.traits & SPDFMarkdownInlineTraitEmphasis) font = SPDFMarkdownFontWithTraits(font, NSItalicFontMask);
    CGFloat baseSize = font.pointSize;
    NSMutableDictionary* attributes = [NSMutableDictionary dictionary];
    if (run.traits & (SPDFMarkdownInlineTraitSubscript | SPDFMarkdownInlineTraitSuperscript)) {
        // <sub>/<sup> mirror the math typesetter's scripts: one visible step
        // smaller, shifted off the baseline.
        font = [NSFontManager.sharedFontManager convertFont:font toSize:MAX(6.0, baseSize * 0.75)] ?: font;
        BOOL superscript = (run.traits & SPDFMarkdownInlineTraitSuperscript) != 0;
        attributes[NSBaselineOffsetAttributeName] = @((superscript ? 0.35 : -0.18) * baseSize);
    } else if (run.traits & SPDFMarkdownInlineTraitKeyboard) {
        // <kbd> renders as a key-cap chip: slightly smaller mono type on the
        // inline-code background (v1; no drawn border).
        font = [NSFontManager.sharedFontManager convertFont:font toSize:MAX(6.0, baseSize * 0.85)] ?: font;
    }
    attributes[NSFontAttributeName] = font;
    attributes[NSForegroundColorAttributeName] = context.options.textColor;
    if (run.traits & SPDFMarkdownInlineTraitStrikethrough) attributes[NSStrikethroughStyleAttributeName] = @1;
    if (run.traits & SPDFMarkdownInlineTraitUnderline)
        attributes[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
    if (run.traits & (SPDFMarkdownInlineTraitCode | SPDFMarkdownInlineTraitKeyboard)) {
        attributes[NSBackgroundColorAttributeName] = context.options.codeBackgroundColor;
    }
    if (run.traits & SPDFMarkdownInlineTraitLink) {
        NSURL* URL = [NSURL URLWithString:run.destination ?: @""];
        NSString* scheme = URL.scheme.lowercaseString;
        attributes[NSForegroundColorAttributeName] = context.options.linkColor;
        attributes[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
        if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"] ||
            [scheme isEqualToString:@"mailto"]) {
            attributes[NSLinkAttributeName] = URL;
        }
    }
    if (run.traits & SPDFMarkdownInlineTraitWikiLink) {
        attributes[SPDFMarkdownWikiLinkAttribute] = run.destination ?: @"";
    }
    // Last, so <mark> wins over the quieter inline-code chip when both apply and
    // a marked link keeps its own color while gaining the highlight.
    if (run.traits & SPDFMarkdownInlineTraitHighlight)
        attributes[NSBackgroundColorAttributeName] = context.options.markHighlightColor;
    if (run.title.length) attributes[NSToolTipAttributeName] = run.title;
    return attributes;
}

// A remote image whose bytes have not arrived yet renders as a fixed-size
// theme-gray box carrying the alt text, so the download landing later only
// swaps the attachment instead of reflowing the whole document from nothing.
// The box is drawn with the active theme's concrete placeholder-role colors
// (like print decoration colors) via a deferred drawing handler; the concrete
// NSColors are captured up front, keeping render passes thread-safe.
static NSTextAttachment* SPDFPendingRemoteImageAttachment(SPDFMarkdownRenderContext* context, NSString* altText) {
    CGFloat width = MAX(64.0, SPDFMarkdownContentWidthBudget(context, 0, context.options.maximumImageWidth));
    CGFloat height = MAX(48.0, context.options.remoteImagePlaceholderHeight);
    NSString* caption = altText.length ? altText : @"Loading image";
    NSFont* font = context.bodyFont;
    SPDFMarkdownTheme* theme = [SPDFMarkdownTheme themeForVariant:context.options.themeVariant];
    NSColor* boxFill = theme.imagePlaceholderFillColor;
    NSColor* boxStroke = theme.imagePlaceholderStrokeColor;
    NSColor* captionColor = theme.secondaryTextColor;
    NSImage* image = [NSImage
         imageWithSize:NSMakeSize(width, height)
               flipped:NO
        drawingHandler:^BOOL(NSRect rect) {
          NSBezierPath* box = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(rect, 0.5, 0.5)
                                                              xRadius:6
                                                              yRadius:6];
          [boxFill setFill];
          [box fill];
          [boxStroke setStroke];
          [box stroke];
          NSMutableParagraphStyle* style = [NSMutableParagraphStyle new];
          style.alignment = NSTextAlignmentCenter;
          style.lineBreakMode = NSLineBreakByTruncatingTail;
          NSDictionary* attributes = @{
              NSFontAttributeName: font,
              NSForegroundColorAttributeName: captionColor,
              NSParagraphStyleAttributeName: style,
          };
          CGFloat lineHeight = ceil(font.ascender - font.descender + font.leading);
          NSRect textRect = NSInsetRect(rect, 12, 0);
          textRect.origin.y = NSMidY(rect) - lineHeight / 2;
          textRect.size.height = lineHeight;
          [caption drawWithRect:textRect options:NSStringDrawingUsesLineFragmentOrigin attributes:attributes context:nil];
          return YES;
        }];
    NSTextAttachment* attachment = [NSTextAttachment new];
    attachment.image = image;
    attachment.bounds = NSMakeRect(0, 0, width, height);
    return attachment;
}

// An image's visible caption is its markdown TITLE (`![alt](src "title")`)
// when one is present — matching how the title reads as the author's display
// caption — falling back to the alt text. The title stays a tooltip as well.
static NSString* SPDFImageCaptionText(SPDFMarkdownInlineRun* run) {
    return run.title.length ? run.title : run.text;
}

// Figure captions read like GitHub's smallest heading role: below body size
// and muted, but regular weight.
static NSDictionary* SPDFCaptionAttributes(SPDFMarkdownRenderContext* context) {
    CGFloat size = context.options.textSize * 0.9 * SPDFMarkdownRenderScale(context);
    return @{
        NSFontAttributeName: [NSFont systemFontOfSize:size],
        NSForegroundColorAttributeName: context.options.secondaryTextColor,
        SPDFMarkdownImageLayoutAttribute: @(SPDFMarkdownImageLayoutRoleCaption),
    };
}

// How a paragraph's images flow, decided by the paragraph's shape. A
// paragraph whose only meaningful content is ONE image is a centered figure
// with the title-or-alt text as a caption line below the artwork. A paragraph
// whose only meaningful content is TWO OR MORE images keeps them inline
// (CommonMark images are inline elements): they flow side by side in one
// center-aligned paragraph, separated by the source's spaces/soft breaks and
// wrapping when the printable width runs out — badge rows depend on this.
// Each row image captions below itself: the row's captions render once, as a
// trailing caption paragraph whose spans the paginator re-positions under
// their images (see SPDFAppendImageRowCaptions). Images mixed into sentence
// text keep plain inline flow, caption-free.
typedef NS_ENUM(NSInteger, SPDFMarkdownImageFlow) {
    SPDFMarkdownImageFlowInline = 0,
    SPDFMarkdownImageFlowFigure,
    SPDFMarkdownImageFlowRow,
};

static NSNumber* SPDFImageLayoutRoleForFlow(SPDFMarkdownImageFlow flow) {
    if (flow == SPDFMarkdownImageFlowFigure) return @(SPDFMarkdownImageLayoutRoleFigure);
    if (flow == SPDFMarkdownImageFlowRow) return @(SPDFMarkdownImageLayoutRoleImageRow);
    return nil;
}

static void SPDFAppendImageAttachment(SPDFMarkdownRenderContext* context, SPDFMarkdownInlineRun* run,
                                      NSTextAttachment* attachment, NSString* target,
                                      SPDFMarkdownImageFlow flow) {
    NSMutableAttributedString* attached = [[NSMutableAttributedString alloc]
        initWithAttributedString:[NSAttributedString attributedStringWithAttachment:attachment]];
    [attached addAttribute:SPDFMarkdownImageTargetAttribute value:target range:NSMakeRange(0, 1)];
    if (run.title.length) [attached addAttribute:NSToolTipAttributeName value:run.title range:NSMakeRange(0, 1)];
    NSNumber* role = SPDFImageLayoutRoleForFlow(flow);
    if (role) [attached addAttribute:SPDFMarkdownImageLayoutAttribute value:role range:NSMakeRange(0, 1)];
    [context.output appendAttributedString:attached];
    NSString* caption = SPDFImageCaptionText(run);
    if (flow == SPDFMarkdownImageFlowFigure && caption.length) {
        // GitHub renders figure images with a real caption on its own line
        // below the artwork instead of flowing to the artwork's right —
        // title-preferred, alt as the fallback. Row images caption via
        // SPDFAppendImageRowCaptions; genuinely inline images show no visible
        // caption at all, GitHub-style: alt and title survive as the
        // attachment's tooltip/target metadata only.
        SPDFMarkdownAppend(context, @"\n",
                           @{SPDFMarkdownImageLayoutAttribute: @(SPDFMarkdownImageLayoutRoleFigure)});
        SPDFMarkdownAppend(context, caption, SPDFCaptionAttributes(context));
    }
}

static BOOL SPDFIsWhitespaceRun(SPDFMarkdownInlineRun* run) {
    return [run.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length == 0;
}

// Classifies a paragraph by its image shape: images-only paragraphs (nothing
// but images and whitespace/soft breaks) become a single-image figure or a
// multi-image inline row; anything else keeps plain inline flow.
static SPDFMarkdownImageFlow SPDFBlockImageFlow(SPDFMarkdownBlock* block) {
    if (block.kind != SPDFMarkdownBlockKindParagraph) return SPDFMarkdownImageFlowInline;
    NSUInteger imageRuns = 0;
    for (SPDFMarkdownInlineRun* run in block.runs) {
        if (run.traits & SPDFMarkdownInlineTraitImage) ++imageRuns;
        else if (!SPDFIsWhitespaceRun(run)) return SPDFMarkdownImageFlowInline;
    }
    if (imageRuns == 0) return SPDFMarkdownImageFlowInline;
    return imageRuns == 1 ? SPDFMarkdownImageFlowFigure : SPDFMarkdownImageFlowRow;
}

static void SPDFRenderImageRun(SPDFMarkdownRenderContext* context, SPDFMarkdownInlineRun* run,
                               SPDFMarkdownImageFlow flow) {
    NSString* destination = run.destination ?: @"";
    NSURL* resolvedURL = nil;
    NSString* remoteKey = SPDFMarkdownRemoteImageKeyForTarget(destination);
    // A withheld document's remote images are never drawn, even from bytes another render left in the map.
    BOOL withheld = remoteKey != nil && context.options.remoteImagesWithheld;
    NSImage* image = withheld ? nil : [context.resourceStore imageForTarget:destination resolvedURL:&resolvedURL];
    if (!image || image.size.width <= 0 || image.size.height <= 0) {
        // A well-formed https target with no fetched bytes yet is pending:
        // reserve real layout space for the asynchronous download. Fetched
        // bytes that fail to decode, session-reported fetch failures, withheld
        // documents and every non-https remote scheme keep the stable text
        // placeholder.
        BOOL pending = remoteKey != nil && !withheld && context.resourceStore.remoteImageData[remoteKey] == nil &&
                       ![context.options.failedRemoteImageTargets containsObject:remoteKey];
        if (pending) {
            SPDFAppendImageAttachment(context, run, SPDFPendingRemoteImageAttachment(context, run.text),
                                      destination, flow);
            return;
        }
        NSMutableDictionary* attributes = [@{
            NSFontAttributeName: context.bodyFont,
            NSForegroundColorAttributeName: context.options.secondaryTextColor,
            SPDFMarkdownImageTargetAttribute: destination,
        } mutableCopy];
        if (run.title.length) attributes[NSToolTipAttributeName] = run.title;
        // The text placeholder follows the same layout rules as the artwork it
        // stands in for: centered inside a figure or row, inline flow
        // otherwise.
        attributes[SPDFMarkdownImageLayoutAttribute] = SPDFImageLayoutRoleForFlow(flow);
        SPDFMarkdownAppend(context,
                           [NSString stringWithFormat:@"[Image: %@]", run.text.length ? run.text : @"untitled"],
                           attributes);
        return;
    }
    // HTML width/height attributes are display-size hints: they set the
    // preferred display size (proportional when only one is given), and the
    // image budgets stay the maxima: the destination page's printable box when
    // the render carries one, the constant caps otherwise.
    CGFloat displayWidth = image.size.width;
    CGFloat displayHeight = image.size.height;
    if (run.preferredImageWidth > 0 && run.preferredImageHeight > 0) {
        displayWidth = run.preferredImageWidth;
        displayHeight = run.preferredImageHeight;
    } else if (run.preferredImageWidth > 0) {
        displayHeight *= run.preferredImageWidth / displayWidth;
        displayWidth = run.preferredImageWidth;
    } else if (run.preferredImageHeight > 0) {
        displayWidth *= run.preferredImageHeight / displayHeight;
        displayHeight = run.preferredImageHeight;
    }
    CGFloat widthBudget = SPDFMarkdownContentWidthBudget(context, 0, context.options.maximumImageWidth);
    CGFloat heightBudget = SPDFMarkdownContentHeightBudget(context, context.options.maximumImageHeight);
    CGFloat scale = MIN(1.0, MIN(widthBudget / displayWidth, heightBudget / displayHeight));
    NSTextAttachment* attachment = [NSTextAttachment new];
    attachment.image = image;
    attachment.bounds = NSMakeRect(0, 0, displayWidth * scale, displayHeight * scale);
    NSString* target = resolvedURL.isFileURL ? resolvedURL.path : (resolvedURL.absoluteString ?: destination);
    SPDFAppendImageAttachment(context, run, attachment, target, flow);
}

// A row only reads side by side when it actually fits one line, but two
// typical images at the per-image caps (440 x 320 by default) already exceed
// any realistic page width and would wrap into a vertical stack. So after the
// per-image caps, a row whose total width (attachments plus the spaces between
// them, one space ~ the body font's space advance) exceeds the row budget
// scales ALL of its images down by one COMMON factor until the row fits —
// never below 0.45x of the capped size: a row that would need less (six large
// images) keeps the floor and wraps instead. Badge strips of small images
// stay untouched because their total is already under the budget. Pending
// remote placeholder boxes participate with their placeholder size, so the
// layout doesn't jump while downloads land (a rerender re-fits from the
// decoded, capped sizes). The budget is the destination page's printable
// width when the render carries one (pageContentSize) — the width the
// paginator will actually lay the row out at — and otherwise the constant
// maximumImageWidth, which sits safely inside every supported page.
static const CGFloat SPDFImageRowMinimumFitFactor = 0.45;

static void SPDFFitImageRowToBudget(SPDFMarkdownRenderContext* context, NSRange range) {
    CGFloat budget = SPDFMarkdownContentWidthBudget(context, 0, context.options.maximumImageWidth);
    if (budget <= 0 || range.length == 0) return;
    NSMutableArray<NSTextAttachment*>* attachments = [NSMutableArray array];
    __block CGFloat imagesWidth = 0;
    [context.output enumerateAttribute:NSAttachmentAttributeName
                               inRange:range
                               options:0
                            usingBlock:^(NSTextAttachment* attachment, NSRange attachmentRange, BOOL* stop) {
                              (void)attachmentRange;
                              (void)stop;
                              if (!attachment) return;
                              [attachments addObject:attachment];
                              imagesWidth += attachment.bounds.size.width;
                            }];
    if (imagesWidth <= 0) return;
    CGFloat spaceAdvance = [@" " sizeWithAttributes:@{NSFontAttributeName: context.bodyFont}].width;
    CGFloat gapsWidth = (range.length - attachments.count) * spaceAdvance;
    if (imagesWidth + gapsWidth <= budget) return;
    CGFloat factor = MAX(SPDFImageRowMinimumFitFactor, (budget - gapsWidth) / imagesWidth);
    if (factor >= 1) return;
    for (NSTextAttachment* attachment in attachments) {
        NSSize size = attachment.bounds.size;
        attachment.bounds = NSMakeRect(0, 0, size.width * factor, size.height * factor);
    }
}

// The row's caption paragraph: one "\n" ending the image line, then each
// captioned image's title-or-alt text exactly once, in image order, separated
// by plain spaces — so the canonical string stays searchable with exact
// ranges. Every caption span carries the caption style plus the
// SPDFMarkdownImageRowIndexAttribute ordinal of its image; the paginator's
// measurement pass replaces the default centered caption line with one
// custom-positioned line per caption, centered under its image's x-span.
// Images that rendered as text placeholders (or with neither title nor alt)
// contribute no caption, and their neighbors keep theirs.
static void SPDFAppendImageRowCaptions(SPDFMarkdownRenderContext* context, NSArray<NSNumber*>* ordinals,
                                       NSArray<NSString*>* captions) {
    if (!ordinals.count) return;
    NSDictionary* captionAttributes = SPDFCaptionAttributes(context);
    // The newline ends the image paragraph carrying the row role, so the
    // style re-derivation can spot "row followed by captions" and keep only a
    // small gap above the caption band, exactly like figures.
    SPDFMarkdownAppend(context, @"\n", @{SPDFMarkdownImageLayoutAttribute: @(SPDFMarkdownImageLayoutRoleImageRow)});
    NSMutableDictionary* separatorAttributes = [captionAttributes mutableCopy];
    [separatorAttributes removeObjectForKey:SPDFMarkdownImageLayoutAttribute];
    for (NSUInteger i = 0; i < ordinals.count; ++i) {
        if (i > 0) SPDFMarkdownAppend(context, @" ", separatorAttributes);
        NSMutableDictionary* attributes = [captionAttributes mutableCopy];
        attributes[SPDFMarkdownImageRowIndexAttribute] = ordinals[i];
        SPDFMarkdownAppend(context, captions[i], attributes);
    }
}

void SPDFMarkdownRenderInlineRuns(SPDFMarkdownRenderContext* context, SPDFMarkdownBlock* block) {
    SPDFMarkdownImageFlow flow = SPDFBlockImageFlow(block);
    NSUInteger rowStart = context.output.length;
    NSUInteger imageOrdinal = 0;
    NSMutableArray<NSNumber*>* captionOrdinals = [NSMutableArray array];
    NSMutableArray<NSString*>* captionTexts = [NSMutableArray array];
    for (SPDFMarkdownInlineRun* run in block.runs) {
        if (context.cancellationToken.isCancelled) return;
        if (!(run.traits & SPDFMarkdownInlineTraitImage)) {
            if (run.traits & SPDFMarkdownInlineTraitMath) {
                // LaTeX math spans go through the native subset typesetter
                // (SPDFMarkdownMathTypesetter.mm); inline math flows in the
                // paragraph, display math becomes its own centered line.
                SPDFMarkdownRenderMathRun(context, run);
                continue;
            }
            // Whitespace padding around a figure image would keep the figure
            // paragraph from starting at its attachment (and carry the
            // uncentered base style), so figures drop it. Rows keep the
            // source's spaces/soft breaks (a soft break is already a space by
            // now) so their images flow side by side, exactly like words.
            if (flow != SPDFMarkdownImageFlowFigure)
                SPDFMarkdownAppend(context, run.text, SPDFRunAttributes(context, run));
            continue;
        }
        NSUInteger imageStart = context.output.length;
        SPDFRenderImageRun(context, run, flow);
        if (flow == SPDFMarkdownImageFlowRow && context.output.length > imageStart) {
            // Stamp the image's rendered span with its row ordinal so the
            // caption span emitted below can be matched back to this image's
            // measured x-span. Only attachment-rendered images (real artwork
            // or pending placeholder boxes) caption; the `[Image: alt]` text
            // placeholder already shows its text and captions nothing.
            NSNumber* ordinal = @(imageOrdinal++);
            NSRange imageRange = NSMakeRange(imageStart, context.output.length - imageStart);
            [context.output addAttribute:SPDFMarkdownImageRowIndexAttribute value:ordinal range:imageRange];
            NSString* caption = SPDFImageCaptionText(run);
            if (caption.length && [context.output attribute:NSAttachmentAttributeName
                                                    atIndex:imageStart
                                             effectiveRange:NULL]) {
                [captionOrdinals addObject:ordinal];
                [captionTexts addObject:caption];
            }
        }
        // A figure ends its own paragraph so the caption line's spacing rules
        // apply below it; rows stay one paragraph and wrap naturally.
        if (flow == SPDFMarkdownImageFlowFigure) SPDFMarkdownAppend(context, @"\n", @{});
    }
    if (flow == SPDFMarkdownImageFlowRow) {
        // Fit first, captions after: the fit walks the row range counting only
        // attachments and the spaces between them.
        SPDFFitImageRowToBudget(context, NSMakeRange(rowStart, context.output.length - rowStart));
        SPDFAppendImageRowCaptions(context, captionOrdinals, captionTexts);
    }
}

// Re-derives the centered figure/caption/row paragraph styles after the leaf
// renderer has applied the block's base style across its whole range. The
// figure or row image paragraph keeps only a small gap above its caption; the
// caption paragraph keeps the block's own spacing below the artwork; a
// caption-less row paragraph simply centers.
void SPDFMarkdownApplyImageBlockStyles(SPDFMarkdownRenderContext* context, NSRange range,
                                       NSParagraphStyle* baseStyle) {
    [context.output
        enumerateAttribute:SPDFMarkdownImageLayoutAttribute
                   inRange:range
                   options:0
                usingBlock:^(NSNumber* role, NSRange markedRange, BOOL* stop) {
                  (void)stop;
                  if (!role) return;
                  NSMutableParagraphStyle* style = [baseStyle mutableCopy];
                  style.alignment = NSTextAlignmentCenter;
                  if ((role.integerValue == SPDFMarkdownImageLayoutRoleFigure ||
                       role.integerValue == SPDFMarkdownImageLayoutRoleImageRow) &&
                      NSMaxRange(markedRange) < context.output.length) {
                      NSNumber* next = [context.output attribute:SPDFMarkdownImageLayoutAttribute
                                                         atIndex:NSMaxRange(markedRange)
                                                  effectiveRange:NULL];
                      if (next.integerValue == SPDFMarkdownImageLayoutRoleCaption)
                          style.paragraphSpacing = 4 * SPDFMarkdownRenderScale(context);
                  }
                  NSRange paragraphRange = [context.output.string paragraphRangeForRange:markedRange];
                  [context.output addAttribute:NSParagraphStyleAttributeName
                                         value:style
                                         range:NSIntersectionRange(paragraphRange, range)];
                }];
}
