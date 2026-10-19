#import "SPDFMarkdownTestSupport.h"

#import <AppKit/AppKit.h>

#import "../../markdown/SPDFMarkdownDocument.h"
#import "../../markdown/SPDFMarkdownResources.h"

static NSData* SPDFMakePNG(NSUInteger width, NSUInteger height) {
    NSBitmapImageRep* bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                       pixelsWide:(NSInteger)width
                                                                       pixelsHigh:(NSInteger)height
                                                                    bitsPerSample:8
                                                                  samplesPerPixel:4
                                                                         hasAlpha:YES
                                                                         isPlanar:NO
                                                                   colorSpaceName:NSCalibratedRGBColorSpace
                                                                      bytesPerRow:0
                                                                     bitsPerPixel:0];
    memset(bitmap.bitmapData, 0x55, bitmap.bytesPerRow * bitmap.pixelsHigh);
    return [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

static NSTextAttachment* SPDFAttachmentForTarget(NSAttributedString* string, NSString* target) {
    __block NSTextAttachment* found = nil;
    [string enumerateAttribute:SPDFMarkdownImageTargetAttribute
                       inRange:NSMakeRange(0, string.length)
                       options:0
                    usingBlock:^(id value, NSRange range, BOOL* stop) {
                      if (![value isEqual:target]) return;
                      NSTextAttachment* attachment = [string attribute:NSAttachmentAttributeName
                                                               atIndex:range.location
                                                        effectiveRange:nil];
                      if (attachment) {
                          found = attachment;
                          *stop = YES;
                      }
                    }];
    return found;
}

int main(void) {
    @autoreleasepool {
        // Scheme classification: https is the only remote scheme with a key.
        SPDFExpect([SPDFMarkdownRemoteImageKeyForTarget(@"https://example.test/a.png")
                       isEqualToString:@"https://example.test/a.png"],
                   @"a well-formed https target maps to its absolute URL key");
        SPDFExpect(SPDFMarkdownRemoteImageKeyForTarget(@"http://example.test/a.png") == nil,
                   @"http targets stay rejected");
        SPDFExpect(SPDFMarkdownRemoteImageKeyForTarget(@"data:image/png;base64,AAAA") == nil,
                   @"data: targets stay rejected");
        SPDFExpect(SPDFMarkdownRemoteImageKeyForTarget(@"file:///etc/hosts") == nil,
                   @"file: targets stay rejected");
        SPDFExpect(SPDFMarkdownRemoteImageKeyForTarget(@"images/local.png") == nil &&
                       SPDFMarkdownRemoteImageKeyForTarget(@"") == nil &&
                       SPDFMarkdownRemoteImageKeyForTarget(@"https://") == nil,
                   @"relative, empty, and hostless targets have no remote key");

        NSString* source = @"# Remote\n\n"
                            "![Minion](https://example.test/images/minion.png \"The Minion\")\n\n"
                            "![Dojo][id]\n\n"
                            "![Insecure](http://example.test/images/no.png)\n\n"
                            "![Inline data](data:image/png;base64,AAAA)\n\n"
                            "[safe link](https://example.test/page \"Link tip\")\n\n"
                            "![Pair one](https://example.test/images/one.png)\n"
                            "![Pair two](https://example.test/images/two.png)\n\n"
                            "[id]: https://example.test/images/dojocat.jpg \"The Dojocat\"\n";
        NSError* error = nil;
        SPDFMarkdownParser* parser = [SPDFMarkdownParser new];
        SPDFMarkdownDocumentModel* model = [parser parseString:source sourceURL:nil error:&error];
        SPDFExpect(model != nil && error == nil, @"remote-image document parses");

        // Pass 1: nothing fetched yet. Remote https images render as pending
        // placeholder boxes that reserve fixed layout space; http/data images
        // keep the stable text placeholder.
        SPDFMarkdownRenderOptions* options = SPDFMarkdownRenderOptions.defaultOptions;
        SPDFMarkdownRenderer* renderer = [SPDFMarkdownRenderer new];
        SPDFMarkdownRenderedDocument* pending = [renderer renderModel:model options:options languageOverrides:nil];
        NSString* pendingText = pending.attributedString.string;
        NSTextAttachment* minionPending =
            SPDFAttachmentForTarget(pending.attributedString, @"https://example.test/images/minion.png");
        SPDFExpect(minionPending != nil, @"an unfetched https image renders as an attachment placeholder");
        SPDFExpect(fabs(minionPending.bounds.size.width - options.maximumImageWidth) < 0.001 &&
                       fabs(minionPending.bounds.size.height - options.remoteImagePlaceholderHeight) < 0.001,
                   @"the pending placeholder reserves maximumImageWidth x placeholder-height layout space");
        NSTextAttachment* dojoPending =
            SPDFAttachmentForTarget(pending.attributedString, @"https://example.test/images/dojocat.jpg");
        SPDFExpect(dojoPending != nil,
                   @"a reference-style image resolves its definition and gets the same pending treatment");
        SPDFExpect([pendingText containsString:@"[Image: Insecure]"],
                   @"http images keep the stable text placeholder");
        SPDFExpect([pendingText containsString:@"[Image: Inline data]"],
                   @"data: images keep the stable text placeholder");
        SPDFExpect(![pendingText containsString:@"[Image: Minion]"] && ![pendingText containsString:@"[Image: Dojo]"],
                   @"pending https images are boxes, not text placeholders");

        // The pending placeholder is a standalone figure with its caption on
        // its own centered line below the box \u2014 the markdown title when
        // present, the alt otherwise \u2014 so the layout matches the fetched
        // image's figure and never jumps when the download lands.
        NSRange minionRange = [pending.attributedString.string rangeOfString:@"\uFFFC\nThe Minion"];
        SPDFExpect(minionRange.location != NSNotFound &&
                       [pendingText rangeOfString:@"\uFFFC\nMinion"].location == NSNotFound,
                   @"a titled pending figure captions with the title, not the alt");
        if (minionRange.location != NSNotFound) {
            NSParagraphStyle* pendingStyle = [pending.attributedString attribute:NSParagraphStyleAttributeName
                                                                         atIndex:minionRange.location
                                                                  effectiveRange:nil];
            SPDFExpect(pendingStyle.alignment == NSTextAlignmentCenter,
                       @"a pending placeholder centers like the real image will");
        }

        // A paragraph of several pending remote images follows the same shape
        // rules as decoded images: CommonMark images are inline, so the
        // placeholder boxes flow side by side in one center-aligned paragraph
        // (the soft break renders as a space), and each box captions below
        // itself with its title-or-alt \u2014 the caption is known at parse time,
        // so nothing changes when the download lands.
        NSRange pairRange = [pendingText rangeOfString:@"\uFFFC \uFFFC"];
        SPDFExpect(pairRange.location != NSNotFound,
                   @"multiple pending images in one paragraph flow side by side, separated by a space");
        SPDFExpect([pendingText containsString:@"\uFFFC \uFFFC\nPair one Pair two"],
                   @"a pending image row captions each box below the row, each caption exactly once");
        if (pairRange.location != NSNotFound) {
            NSParagraphStyle* firstBoxStyle = [pending.attributedString attribute:NSParagraphStyleAttributeName
                                                                          atIndex:pairRange.location
                                                                   effectiveRange:nil];
            NSParagraphStyle* secondBoxStyle = [pending.attributedString attribute:NSParagraphStyleAttributeName
                                                                           atIndex:pairRange.location + 2
                                                                    effectiveRange:nil];
            SPDFExpect(firstBoxStyle.alignment == NSTextAlignmentCenter &&
                           secondBoxStyle.alignment == NSTextAlignmentCenter,
                       @"a pending placeholder row center-aligns like a real image row");
            SPDFExpect([[pending.attributedString attribute:SPDFMarkdownImageTargetAttribute
                                                    atIndex:pairRange.location + 2
                                             effectiveRange:nil] isEqual:@"https://example.test/images/two.png"],
                       @"row placeholders keep their target metadata");
            // Pending boxes participate in the row-width fit at their
            // placeholder size: two maximumImageWidth boxes cannot share one
            // line, so both scale down by one common factor to fit the row
            // budget — the layout holds steady while the downloads land, and
            // the rerender re-fits from the decoded, capped sizes.
            NSTextAttachment* pairOneBox = [pending.attributedString attribute:NSAttachmentAttributeName
                                                                        atIndex:pairRange.location
                                                                 effectiveRange:nil];
            NSTextAttachment* pairTwoBox = [pending.attributedString attribute:NSAttachmentAttributeName
                                                                        atIndex:pairRange.location + 2
                                                                 effectiveRange:nil];
            CGFloat boxFactor = pairOneBox.bounds.size.width / options.maximumImageWidth;
            SPDFExpect(pairOneBox != nil && pairTwoBox != nil && boxFactor < 1.0 && boxFactor >= 0.45,
                       @"a pending placeholder row scales below the placeholder width, never below the floor");
            SPDFExpect(pairOneBox && pairTwoBox &&
                           fabs(pairTwoBox.bounds.size.width - pairOneBox.bounds.size.width) < 0.001 &&
                           fabs(pairOneBox.bounds.size.height -
                                options.remoteImagePlaceholderHeight * boxFactor) < 0.01 &&
                           fabs(pairTwoBox.bounds.size.height -
                                options.remoteImagePlaceholderHeight * boxFactor) < 0.01,
                       @"both pending boxes shrink by one common factor from their placeholder size");
            CGFloat boxSpaceWidth =
                [[pending.attributedString attributedSubstringFromRange:NSMakeRange(pairRange.location + 1, 1)]
                    size].width;
            SPDFExpect(pairOneBox && pairTwoBox &&
                           pairOneBox.bounds.size.width + boxSpaceWidth + pairTwoBox.bounds.size.width <=
                               options.maximumImageWidth + 0.5,
                       @"the fitted placeholder row's total width stays within the row budget");
            // The pending row's captions already lay out exactly like the
            // decoded row's will: one caption line below the boxes, each
            // caption's fragment centered under its own box's x-span.
            SPDFMarkdownPaginator* pendingPaginator = [SPDFMarkdownPaginator new];
            SPDFMarkdownPageConfiguration* pendingConfiguration =
                SPDFMarkdownPageConfiguration.A4PortraitConfiguration;
            NSArray<SPDFMarkdownPaginationItem*>* pendingItems =
                [pendingPaginator measureRenderedDocument:pending
                                           containerWidth:NSWidth(pendingConfiguration.printableRect)];
            SPDFMarkdownPaginationPlan* pendingPlan = [pendingPaginator paginateItems:pendingItems
                                                                        configuration:pendingConfiguration];
            SPDFMarkdownPageFragment* boxLineFragment = nil;
            SPDFMarkdownPageFragment* pairOneCaptionFragment = nil;
            NSRange pairOneCaption = [pendingText rangeOfString:@"Pair one"];
            for (SPDFMarkdownPage* page in pendingPlan.pages) {
                for (SPDFMarkdownPageFragment* fragment in page.fragments) {
                    if (!fragment.attributedRange.length) continue;
                    if (NSLocationInRange(pairRange.location, fragment.attributedRange)) boxLineFragment = fragment;
                    if (NSLocationInRange(pairOneCaption.location, fragment.attributedRange))
                        pairOneCaptionFragment = fragment;
                }
            }
            SPDFExpect(boxLineFragment != nil && pairOneCaptionFragment != nil &&
                           boxLineFragment != pairOneCaptionFragment &&
                           pairOneCaptionFragment.pageYOffset >
                               boxLineFragment.pageYOffset + boxLineFragment.height - 0.5,
                       @"a pending row's caption paginates on its own line strictly below the boxes");
            if (boxLineFragment && pairOneCaptionFragment && pairOneBox) {
                CTLineRef boxLine = SPDFMarkdownCreateFragmentLine(
                    [pending.attributedString attributedSubstringFromRange:boxLineFragment.attributedRange]);
                CFIndex local = (CFIndex)(pairRange.location - boxLineFragment.attributedRange.location);
                CGFloat x0 = CTLineGetOffsetForStringIndex(boxLine, local, NULL);
                CGFloat x1 = CTLineGetOffsetForStringIndex(boxLine, local + 1, NULL);
                CFRelease(boxLine);
                CGFloat boxCenter = boxLineFragment.xOffset + (x0 + x1) / 2;
                CTLineRef captionLine = SPDFMarkdownCreateFragmentLine([pending.attributedString
                    attributedSubstringFromRange:pairOneCaptionFragment.attributedRange]);
                CGFloat captionWidth = (CGFloat)CTLineGetTypographicBounds(captionLine, NULL, NULL, NULL);
                CFRelease(captionLine);
                SPDFExpect(fabs(pairOneCaptionFragment.xOffset + captionWidth / 2 - boxCenter) < 2.0,
                           @"a pending box's caption centers under the box's x-span before the download lands");
            }
            NSFont* pendingCaptionFont = [pending.attributedString attribute:NSFontAttributeName
                                                                     atIndex:pairOneCaption.location
                                                              effectiveRange:nil];
            NSColor* pendingCaptionColor = [pending.attributedString attribute:NSForegroundColorAttributeName
                                                                       atIndex:pairOneCaption.location
                                                                effectiveRange:nil];
            SPDFExpect(fabs(pendingCaptionFont.pointSize - options.textSize * 0.9) < 0.01 &&
                           [pendingCaptionColor isEqual:options.secondaryTextColor],
                       @"pending row captions style like figure captions, muted at 0.9x body");
        }

        // Title attributes surface as tooltips on the attachment and on links.
        __block BOOL attachmentTooltip = NO;
        [pending.attributedString enumerateAttribute:NSToolTipAttributeName
                                             inRange:NSMakeRange(0, pending.attributedString.length)
                                             options:0
                                          usingBlock:^(id value, NSRange range, BOOL* stop) {
                                            (void)range;
                                            if ([value isEqual:@"The Minion"]) {
                                                attachmentTooltip = YES;
                                                *stop = YES;
                                            }
                                          }];
        SPDFExpect(attachmentTooltip && minionRange.location != NSNotFound,
                   @"an image title renders as a tooltip attribute");
        NSRange linkRange = [pendingText rangeOfString:@"safe link"];
        NSString* linkTooltip = [pending.attributedString attribute:NSToolTipAttributeName
                                                            atIndex:linkRange.location
                                                     effectiveRange:nil];
        SPDFExpect([linkTooltip isEqualToString:@"Link tip"], @"a link title renders as a tooltip attribute");

        // Pass 2: the session fed bytes for one image; the other stays pending.
        NSData* PNG = SPDFMakePNG(4, 2);
        options.remoteImageData = @{@"https://example.test/images/minion.png": PNG};
        SPDFMarkdownRenderedDocument* fetched = [renderer renderModel:model options:options languageOverrides:nil];
        NSTextAttachment* minionFetched =
            SPDFAttachmentForTarget(fetched.attributedString, @"https://example.test/images/minion.png");
        SPDFExpect(minionFetched != nil && minionFetched.image != nil &&
                       fabs(minionFetched.bounds.size.width - 4) < 0.001 &&
                       fabs(minionFetched.bounds.size.height - 2) < 0.001,
                   @"fed-in https bytes decode into a real attachment at natural size");
        SPDFExpect(SPDFAttachmentForTarget(fetched.attributedString, @"https://example.test/images/dojocat.jpg") != nil,
                   @"images without bytes keep their pending placeholder");
        SPDFExpect([fetched.attributedString.string containsString:@"￼ ￼\nPair one Pair two"],
                   @"the row's canonical caption line is byte-identical across download passes");

        // Oversized decoded images stay constrained by the render caps.
        NSData* widePNG = SPDFMakePNG(2000, 400);
        options.remoteImageData = @{@"https://example.test/images/minion.png": widePNG};
        SPDFMarkdownRenderedDocument* capped = [renderer renderModel:model options:options languageOverrides:nil];
        NSTextAttachment* minionCapped =
            SPDFAttachmentForTarget(capped.attributedString, @"https://example.test/images/minion.png");
        SPDFExpect(minionCapped != nil && minionCapped.image != nil &&
                       minionCapped.bounds.size.width <= options.maximumImageWidth + 0.001 &&
                       minionCapped.bounds.size.height <= options.maximumImageHeight + 0.001,
                   @"a large remote image scales into the maximum image bounds");

        // Failure states are stable text placeholders: a fetch the session
        // marked failed, bytes that do not decode, and bytes over budget.
        options.remoteImageData = @{};
        options.failedRemoteImageTargets = [NSSet setWithObject:@"https://example.test/images/minion.png"];
        SPDFMarkdownRenderedDocument* failed = [renderer renderModel:model options:options languageOverrides:nil];
        SPDFExpect([failed.attributedString.string containsString:@"[Image: Minion]"],
                   @"a failed fetch renders the stable text placeholder");
        options.failedRemoteImageTargets = nil;
        options.remoteImageData =
            @{@"https://example.test/images/minion.png": [@"not an image" dataUsingEncoding:NSUTF8StringEncoding]};
        SPDFMarkdownRenderedDocument* undecodable = [renderer renderModel:model options:options languageOverrides:nil];
        SPDFExpect([undecodable.attributedString.string containsString:@"[Image: Minion]"],
                   @"undecodable fetched bytes render the stable text placeholder");
        options.remoteImageData = @{@"https://example.test/images/minion.png": PNG};
        options.maximumResourceBytes = 4;  // smaller than any real PNG
        SPDFMarkdownRenderedDocument* overBudget = [renderer renderModel:model options:options languageOverrides:nil];
        SPDFExpect([overBudget.attributedString.string containsString:@"[Image: Minion]"],
                   @"remote bytes over the resource budget render the stable text placeholder");
        options.maximumResourceBytes = 64 * 1024 * 1024;

        // The decoded-pixel budget is shared with local images: a second remote
        // image beyond the remaining pixel budget degrades gracefully.
        options.remoteImageData = @{
            @"https://example.test/images/minion.png": PNG,
            @"https://example.test/images/dojocat.jpg": SPDFMakePNG(8, 8),
        };
        options.maximumDecodedImagePixels = 10;  // fits the 4x2, not the 8x8
        SPDFMarkdownRenderedDocument* pixelBudget = [renderer renderModel:model options:options languageOverrides:nil];
        SPDFExpect(SPDFAttachmentForTarget(pixelBudget.attributedString,
                                           @"https://example.test/images/minion.png") != nil &&
                       [pixelBudget.attributedString.string containsString:@"[Image: Dojo]"],
                   @"remote decodes share the aggregate pixel budget with graceful placeholders");

        // The engine never invents bytes for non-https keys even if a caller
        // tries to feed them through the seam.
        options = SPDFMarkdownRenderOptions.defaultOptions;
        options.remoteImageData = @{@"http://example.test/images/no.png": PNG};
        SPDFMarkdownRenderedDocument* insecure = [renderer renderModel:model options:options languageOverrides:nil];
        SPDFExpect([insecure.attributedString.string containsString:@"[Image: Insecure]"],
                   @"bytes keyed by a non-https URL are never consulted");

        // Search correspondence holds across the pending placeholder boxes.
        NSArray* matches = [pending searchForQuery:@"safe link" caseSensitive:YES];
        SPDFExpect(matches.count == 1 &&
                       [[pendingText substringWithRange:[matches.firstObject range]] isEqualToString:@"safe link"],
                   @"canonical search ranges stay exact in a document with pending remote images");
    }
    return SPDFFinishTests(@"SPDFMarkdownRemoteImageTests");
}
