#import "SPDFMarkdownTestSupport.h"

#import "../../markdown/SPDFMarkdownDocument.h"

// Local-image layout by paragraph shape: a single-image paragraph renders as
// a centered figure with a centered caption line below the artwork — the
// markdown title when present, the alt text otherwise; a paragraph of several
// images keeps them inline, CommonMark-style, flowing side by side in one
// center-aligned paragraph, and each row image captions below itself with its
// caption centered under that image's own x-span; and images mixed into
// sentence text keep plain inline flow, caption-free.

static void SPDFExpectSearchCorrespondence(SPDFMarkdownDocument* document, NSString* query) {
    NSArray* matches = [document searchForQuery:query caseSensitive:YES];
    SPDFExpect(matches.count > 0, [@"search finds " stringByAppendingString:query]);
    for (SPDFMarkdownSearchMatch* match in matches) {
        NSString* selected = [document.renderedDocument.attributedString.string substringWithRange:match.range];
        SPDFExpect([selected isEqualToString:query], [@"search range exactly selects " stringByAppendingString:query]);
    }
}

static void SPDFWritePNG(NSString* path, NSInteger width, NSInteger height) {
    NSBitmapImageRep* bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                      pixelsWide:width pixelsHigh:height
                                                                    bitsPerSample:8
                                                                    samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                                                                    colorSpaceName:NSCalibratedRGBColorSpace
                                                                       bytesPerRow:0 bitsPerPixel:0];
    memset(bitmap.bitmapData, 0x7f, bitmap.bytesPerRow * bitmap.pixelsHigh);
    NSData* PNG = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    [PNG writeToFile:path atomically:YES];
}

// Every fixture folder this run made, removed by exact path when the process exits, so a failed check (which only
// counts and carries on) or an early return still leaves nothing in the temporary folder.
static NSMutableArray<NSString*>* SPDFFixtureDirectories;
static void SPDFRemoveFixtureDirectories(void) {
    for (NSString* directory in SPDFFixtureDirectories)
        [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
}

static NSString* SPDFCreateFixtureDirectory(void) {
    NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    if (!SPDFFixtureDirectories) {
        SPDFFixtureDirectories = [NSMutableArray array];
        atexit(SPDFRemoveFixtureDirectories);
    }
    [SPDFFixtureDirectories addObject:directory];
    return directory;
}

static SPDFMarkdownPageFragment* SPDFFragmentForIndex(SPDFMarkdownPaginationPlan* plan, NSUInteger characterIndex) {
    for (SPDFMarkdownPage* page in plan.pages) {
        for (SPDFMarkdownPageFragment* fragment in page.fragments) {
            if (fragment.attributedRange.length && NSLocationInRange(characterIndex, fragment.attributedRange))
                return fragment;
        }
    }
    return nil;
}

// Center x (page-content coordinates) of the attachment character at
// characterIndex inside its pagination fragment's line.
static CGFloat SPDFImageCenterX(NSAttributedString* text, SPDFMarkdownPageFragment* fragment,
                                NSUInteger characterIndex) {
    CTLineRef line = SPDFMarkdownCreateFragmentLine([text attributedSubstringFromRange:fragment.attributedRange]);
    CFIndex local = (CFIndex)(characterIndex - fragment.attributedRange.location);
    CGFloat x0 = CTLineGetOffsetForStringIndex(line, local, NULL);
    CGFloat x1 = CTLineGetOffsetForStringIndex(line, local + 1, NULL);
    CFRelease(line);
    return fragment.xOffset + (x0 + x1) / 2;
}

// Center x of a caption fragment, from the same typographic width the
// drawing pass uses.
static CGFloat SPDFCaptionCenterX(NSAttributedString* text, SPDFMarkdownPageFragment* fragment) {
    CTLineRef line = SPDFMarkdownCreateFragmentLine([text attributedSubstringFromRange:fragment.attributedRange]);
    CGFloat width = (CGFloat)CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    CFRelease(line);
    return fragment.xOffset + width / 2;
}

static NSURL* SPDFCreateImageDocument(void) {
    NSString* directory = SPDFCreateFixtureDirectory();
    SPDFWritePNG([directory stringByAppendingPathComponent:@"local.png"], 4, 2);
    SPDFWritePNG([directory stringByAppendingPathComponent:@"second.png"], 4, 2);
    NSMutableString* source = [NSMutableString stringWithString:@"# Image\n\n"];
    for (NSUInteger index = 0; index < 200; ++index)
        [source appendString:@"![Local pixels](local.png)\n\n"];
    [source appendString:@"![AltOnly](local.png \"Titled figure caption\")\n\n"];
    [source appendString:@"![Budgeted out](second.png)\n\n"];
    [source appendString:@"![Badge one](local.png)\n![Badge two](local.png)\n\n"];
    [source appendString:@"Inline sentence with ![Inline art](local.png) image continues.\n"];
    [source writeToFile:[directory stringByAppendingPathComponent:@"image.md"]
             atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"image.md"]];
}

int main(void) {
    @autoreleasepool {
        NSError* error = nil;
        SPDFMarkdownRenderOptions* imageOptions = SPDFMarkdownRenderOptions.defaultOptions;
        imageOptions.maximumDecodedImagePixels = 8;
        SPDFMarkdownDocument* imageDocument = [SPDFMarkdownDocument documentWithURL:SPDFCreateImageDocument()
                                                                             options:imageOptions error:&error];
        SPDFExpect(imageDocument != nil && error == nil, @"local-image document loads and renders");
        __block NSImage* sharedImage = nil;
        __block NSUInteger attachmentCount = 0;
        __block BOOL allAttachmentsShared = YES;
        [imageDocument.renderedDocument.attributedString enumerateAttribute:NSAttachmentAttributeName
                                                                     inRange:NSMakeRange(0, imageDocument.renderedDocument.attributedString.length)
                                                                     options:0
                                                                  usingBlock:^(id value, NSRange range, BOOL* stop) {
            (void)stop;
            NSTextAttachment* attachment = value;
            if (attachment && range.length == 1) {
                ++attachmentCount;
                if (!sharedImage) sharedImage = attachment.image;
                else if (sharedImage != attachment.image) allAttachmentsShared = NO;
                SPDFExpect(attachment.bounds.size.width <= 440 && attachment.bounds.size.height <= 320,
                           @"each cached image remains constrained to render bounds");
            }
        }];
        // 200 repeated figures + the titled figure + the two row images + the
        // inline image all reference local.png and share one decoded NSImage.
        SPDFExpect(attachmentCount == 204 && allAttachmentsShared,
                   @"repeated image references reuse one decoded image rather than multiplying memory");
        SPDFExpect([imageDocument.renderedDocument.attributedString.string containsString:@"[Image: Budgeted out]"],
                   @"an image beyond the aggregate pixel budget becomes a graceful placeholder");
        SPDFExpectSearchCorrespondence(imageDocument, @"Local pixels");

        // Standalone images render as GitHub-style figures: the alt text is a
        // muted caption on its own centered line below the artwork (never
        // beside it), and the attachment paragraph centers within the page.
        NSAttributedString* figureString = imageDocument.renderedDocument.attributedString;
        NSRange figureRange = [figureString.string rangeOfString:@"\uFFFC\nLocal pixels"];
        SPDFExpect(figureRange.location != NSNotFound,
                   @"a standalone image's alt text renders on its own line below the attachment");
        SPDFExpect((NSUInteger)[figureString.string componentsSeparatedByString:@"Local pixels"].count == 201,
                   @"alt text still appears exactly once per image");
        NSUInteger captionIndex = figureRange.location + 2;
        NSFont* captionFont = [figureString attribute:NSFontAttributeName atIndex:captionIndex effectiveRange:nil];
        NSColor* captionColor = [figureString attribute:NSForegroundColorAttributeName
                                                atIndex:captionIndex
                                         effectiveRange:nil];
        SPDFExpect(fabs(captionFont.pointSize - 13.5) < 0.01 &&
                       [captionColor isEqual:imageOptions.secondaryTextColor],
                   @"figure captions drop below body size and go muted, caption-style");
        NSParagraphStyle* figureStyle = [figureString attribute:NSParagraphStyleAttributeName
                                                        atIndex:figureRange.location
                                                 effectiveRange:nil];
        NSParagraphStyle* captionStyle = [figureString attribute:NSParagraphStyleAttributeName
                                                         atIndex:captionIndex
                                                  effectiveRange:nil];
        SPDFExpect(figureStyle.alignment == NSTextAlignmentCenter && captionStyle.alignment == NSTextAlignmentCenter,
                   @"figure and caption paragraphs are center-aligned");
        SPDFMarkdownPageConfiguration* figureConfiguration = SPDFMarkdownPageConfiguration.A4PortraitConfiguration;
        SPDFMarkdownPaginationPlan* figurePlan = [imageDocument paginationPlanForConfiguration:figureConfiguration];
        SPDFMarkdownPageFragment* attachmentFragment = nil;
        SPDFMarkdownPageFragment* captionFragment = nil;
        for (SPDFMarkdownPageFragment* fragment in figurePlan.pages.firstObject.fragments) {
            if (!fragment.attributedRange.length) continue;
            if (NSLocationInRange(figureRange.location, fragment.attributedRange)) attachmentFragment = fragment;
            if (NSLocationInRange(captionIndex, fragment.attributedRange) &&
                !NSLocationInRange(figureRange.location, fragment.attributedRange))
                captionFragment = fragment;
            if (attachmentFragment && captionFragment) break;
        }
        SPDFExpect(attachmentFragment != nil && captionFragment != nil,
                   @"the attachment and its caption paginate as two separate fragments");
        SPDFExpect(attachmentFragment && captionFragment &&
                       captionFragment.pageYOffset >
                           attachmentFragment.pageYOffset + attachmentFragment.height - 0.5,
                   @"the caption fragment sits strictly below the attachment fragment");
        NSTextAttachment* figureAttachment = [figureString attribute:NSAttachmentAttributeName
                                                             atIndex:figureRange.location
                                                      effectiveRange:nil];
        CGFloat printableWidth = NSWidth(figureConfiguration.printableRect);
        SPDFExpect(attachmentFragment &&
                       fabs(attachmentFragment.xOffset -
                            (printableWidth - figureAttachment.bounds.size.width) / 2) < 1.0,
                   @"a standalone image centers within the printable width");
        NSAttributedString* captionText = [figureString
            attributedSubstringFromRange:NSMakeRange(captionIndex, [@"Local pixels" length])];
        CGFloat captionWidth = NSWidth([captionText boundingRectWithSize:NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX)
                                                                  options:NSStringDrawingUsesLineFragmentOrigin
                                                                  context:nil]);
        SPDFExpect(captionFragment && captionFragment.xOffset > 8.0 &&
                       fabs(captionFragment.xOffset + captionWidth / 2 - printableWidth / 2) < 2.0,
                   @"the caption centers within the printable width instead of hanging at the image's right");

        // The caption text prefers the markdown title: a titled figure
        // captions with the title, the alt survives only as tooltip/metadata,
        // and untitled figures (the 200 above) keep captioning with the alt.
        NSRange titledRange = [figureString.string rangeOfString:@"\uFFFC\nTitled figure caption"];
        SPDFExpect(titledRange.location != NSNotFound,
                   @"a figure with a markdown title uses the title as its caption");
        SPDFExpect(![figureString.string containsString:@"AltOnly"],
                   @"the alt text stays out of the visible text when the title captions the figure");
        if (titledRange.location != NSNotFound) {
            SPDFExpect([[figureString attribute:NSToolTipAttributeName
                                        atIndex:titledRange.location
                                 effectiveRange:nil] isEqualToString:@"Titled figure caption"],
                       @"the titled figure keeps its title tooltip on the attachment");
        }

        // A paragraph containing several images (with nothing but whitespace/
        // soft breaks between them) keeps them inline, CommonMark-style: the
        // images flow side by side in one paragraph -- the soft break renders
        // as a plain space -- the row paragraph center-aligns as a group, and
        // each image's title-or-alt caption renders once, in a caption line
        // below the row.
        NSRange rowRange = [figureString.string rangeOfString:@"\uFFFC \uFFFC"];
        SPDFExpect(rowRange.location != NSNotFound,
                   @"a multi-image paragraph flows its images side by side separated by a space");
        SPDFExpect([figureString.string containsString:@"\uFFFC \uFFFC\nBadge one Badge two"],
                   @"row images caption below the row, each caption exactly once, in image order");
        SPDFExpect((NSUInteger)[figureString.string componentsSeparatedByString:@"Badge one"].count == 2,
                   @"a row caption appears exactly once in the canonical text");
        SPDFExpectSearchCorrespondence(imageDocument, @"Badge one");
        if (rowRange.location != NSNotFound) {
            NSUInteger firstImageIndex = rowRange.location;
            NSUInteger secondImageIndex = rowRange.location + 2;
            for (NSNumber* index in @[ @(firstImageIndex), @(secondImageIndex) ]) {
                NSParagraphStyle* rowStyle = [figureString attribute:NSParagraphStyleAttributeName
                                                             atIndex:index.unsignedIntegerValue
                                                      effectiveRange:nil];
                SPDFExpect(rowStyle.alignment == NSTextAlignmentCenter,
                           @"the multi-image row paragraph is center-aligned");
            }
            SPDFExpect([[figureString attribute:SPDFMarkdownImageTargetAttribute
                                        atIndex:secondImageIndex
                                 effectiveRange:nil] hasSuffix:@"local.png"],
                       @"row images keep their target metadata");
            SPDFMarkdownPageFragment* firstRowFragment = SPDFFragmentForIndex(figurePlan, firstImageIndex);
            SPDFMarkdownPageFragment* secondRowFragment = SPDFFragmentForIndex(figurePlan, secondImageIndex);
            SPDFExpect(firstRowFragment != nil && secondRowFragment != nil,
                       @"both row images land in pagination fragments");
            SPDFExpect(firstRowFragment && secondRowFragment && firstRowFragment == secondRowFragment,
                       @"both row images share one line fragment band");
            if (firstRowFragment && firstRowFragment == secondRowFragment) {
                NSAttributedString* rowLine =
                    [figureString attributedSubstringFromRange:firstRowFragment.attributedRange];
                CTLineRef line = SPDFMarkdownCreateFragmentLine(rowLine);
                CGFloat lineWidth = (CGFloat)CTLineGetTypographicBounds(line, NULL, NULL, NULL) -
                                    (CGFloat)CTLineGetTrailingWhitespaceWidth(line);
                CGFloat firstX = CTLineGetOffsetForStringIndex(
                    line, (CFIndex)(firstImageIndex - firstRowFragment.attributedRange.location), NULL);
                CGFloat secondX = CTLineGetOffsetForStringIndex(
                    line, (CFIndex)(secondImageIndex - firstRowFragment.attributedRange.location), NULL);
                CFRelease(line);
                NSTextAttachment* rowAttachment = [figureString attribute:NSAttachmentAttributeName
                                                                  atIndex:firstImageIndex
                                                           effectiveRange:nil];
                SPDFExpect(rowAttachment != nil && firstX < 0.5 &&
                               secondX > firstX + rowAttachment.bounds.size.width + 0.5,
                           @"the second image sits to the first image's right, past its width plus the space");
                SPDFExpect(fabs(firstRowFragment.xOffset + lineWidth / 2 - printableWidth / 2) < 2.0,
                           @"the image row centers as a group within the printable width");
            }
            // The row captions style like figure captions (muted, 0.9x body)
            // and paginate as their own fragments strictly below the image
            // line.
            NSUInteger badgeCaptionIndex = [figureString.string rangeOfString:@"Badge one"].location;
            NSFont* rowCaptionFont = [figureString attribute:NSFontAttributeName
                                                     atIndex:badgeCaptionIndex
                                              effectiveRange:nil];
            NSColor* rowCaptionColor = [figureString attribute:NSForegroundColorAttributeName
                                                       atIndex:badgeCaptionIndex
                                                effectiveRange:nil];
            SPDFExpect(fabs(rowCaptionFont.pointSize - 13.5) < 0.01 &&
                           [rowCaptionColor isEqual:imageOptions.secondaryTextColor],
                       @"row captions drop below body size and go muted like figure captions");
            SPDFMarkdownPageFragment* badgeCaptionFragment = SPDFFragmentForIndex(figurePlan, badgeCaptionIndex);
            SPDFExpect(badgeCaptionFragment != nil && firstRowFragment &&
                           badgeCaptionFragment != firstRowFragment &&
                           badgeCaptionFragment.pageYOffset >
                               firstRowFragment.pageYOffset + firstRowFragment.height - 0.5,
                       @"a row caption paginates as its own fragment strictly below the image line");
        }

        // An image genuinely mixed into sentence text keeps inline flow and
        // emits no visible alt-text caption (GitHub shows nothing); the alt
        // survives only as the attachment's target/tooltip metadata.
        SPDFExpect(![figureString.string containsString:@"Inline art"],
                   @"an inline image emits no visible alt-text caption");
        NSRange inlineSentence =
            [figureString.string rangeOfString:@"Inline sentence with \uFFFC image continues."];
        SPDFExpect(inlineSentence.location != NSNotFound,
                   @"an inline image flows inside its sentence without extra line breaks");
        if (inlineSentence.location != NSNotFound) {
            NSUInteger inlineAttachmentIndex = inlineSentence.location + [@"Inline sentence with " length];
            NSParagraphStyle* inlineStyle = [figureString attribute:NSParagraphStyleAttributeName
                                                            atIndex:inlineAttachmentIndex
                                                     effectiveRange:nil];
            SPDFExpect(inlineStyle.alignment != NSTextAlignmentCenter,
                       @"an inline image's paragraph keeps the block's own alignment");
            NSString* inlineTarget = [figureString attribute:SPDFMarkdownImageTargetAttribute
                                                     atIndex:inlineAttachmentIndex
                                              effectiveRange:nil];
            SPDFExpect([inlineTarget hasSuffix:@"local.png"],
                       @"the inline image keeps its target metadata");
        }

        // Row width fitting. Two images at the default per-image caps (440
        // wide each after capping) cannot sit side by side within the row
        // budget, so the row scales both attachments down by ONE common
        // factor until the line fits; a badge strip of small images already
        // fits and keeps its natural sizes; a row that would need less than
        // the 0.45x floor keeps the floor and wraps instead.
        NSString* fitDirectory = SPDFCreateFixtureDirectory();
        SPDFWritePNG([fitDirectory stringByAppendingPathComponent:@"wide.png"], 960, 320);
        SPDFWritePNG([fitDirectory stringByAppendingPathComponent:@"badge.png"], 60, 20);
        NSMutableString* fitSource = [NSMutableString string];
        [fitSource appendString:@"![Wide left](wide.png \"Left title\")\n"
                                 "![Wide right](wide.png \"Right title\")\n\n"];
        [fitSource appendString:@"![B1](badge.png) ![B2](badge.png) ![B3](badge.png) "
                                 "![B4](badge.png) ![B5](badge.png)\n\n"];
        [fitSource appendString:@"![Cap A](badge.png \"First badge caption\") ![](badge.png) "
                                 "![Cap C](badge.png \"Third badge caption\")\n\n"];
        for (NSUInteger index = 0; index < 6; ++index)
            [fitSource appendFormat:@"![Wall %lu](wide.png)\n", (unsigned long)index];
        NSString* fitPath = [fitDirectory stringByAppendingPathComponent:@"fit.md"];
        [fitSource writeToFile:fitPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        error = nil;
        SPDFMarkdownRenderOptions* fitOptions = SPDFMarkdownRenderOptions.defaultOptions;
        SPDFMarkdownDocument* fitDocument =
            [SPDFMarkdownDocument documentWithURL:[NSURL fileURLWithPath:fitPath]
                                          options:fitOptions error:&error];
        SPDFExpect(fitDocument != nil && error == nil, @"row-fit document loads and renders");
        NSAttributedString* fitString = fitDocument.renderedDocument.attributedString;
        SPDFMarkdownPaginationPlan* fitPlan = [fitDocument paginationPlanForConfiguration:figureConfiguration];

        NSRange pairRow = [fitString.string rangeOfString:@"\uFFFC \uFFFC"];
        SPDFExpect(pairRow.location != NSNotFound, @"the two-image row keeps its side-by-side shape");
        if (pairRow.location != NSNotFound) {
            NSTextAttachment* pairLeft = [fitString attribute:NSAttachmentAttributeName
                                                      atIndex:pairRow.location
                                               effectiveRange:nil];
            NSTextAttachment* pairRight = [fitString attribute:NSAttachmentAttributeName
                                                       atIndex:pairRow.location + 2
                                                effectiveRange:nil];
            CGFloat pairFactor = pairLeft.bounds.size.width / 440.0;
            SPDFExpect(pairLeft != nil && pairRight != nil && pairFactor < 1.0 && pairFactor >= 0.45,
                       @"two cap-width row images scale below the cap but never below the 0.45x floor");
            SPDFExpect(pairLeft && pairRight &&
                           fabs(pairRight.bounds.size.width - pairLeft.bounds.size.width) < 0.001 &&
                           fabs(pairLeft.bounds.size.height - (440.0 / 3.0) * pairFactor) < 0.01 &&
                           fabs(pairRight.bounds.size.height - (440.0 / 3.0) * pairFactor) < 0.01,
                       @"both row attachments shrink by one common factor and keep their aspect ratio");
            CGFloat pairSpaceWidth =
                [[fitString attributedSubstringFromRange:NSMakeRange(pairRow.location + 1, 1)] size].width;
            SPDFExpect(pairLeft && pairRight &&
                           pairLeft.bounds.size.width + pairSpaceWidth + pairRight.bounds.size.width <=
                               440.0 + 0.5,
                       @"the fitted row's total width stays within the row budget");
            SPDFMarkdownPageFragment* pairFragment = SPDFFragmentForIndex(fitPlan, pairRow.location);
            SPDFMarkdownPageFragment* pairSecondFragment = SPDFFragmentForIndex(fitPlan, pairRow.location + 2);
            SPDFExpect(pairFragment != nil && pairFragment == pairSecondFragment,
                       @"the fitted pair shares one line fragment band instead of stacking");
            if (pairFragment && pairFragment == pairSecondFragment) {
                NSAttributedString* pairLine =
                    [fitString attributedSubstringFromRange:pairFragment.attributedRange];
                CTLineRef pairCTLine = SPDFMarkdownCreateFragmentLine(pairLine);
                CGFloat pairLineWidth = (CGFloat)CTLineGetTypographicBounds(pairCTLine, NULL, NULL, NULL) -
                                        (CGFloat)CTLineGetTrailingWhitespaceWidth(pairCTLine);
                CFRelease(pairCTLine);
                SPDFExpect(fabs(pairFragment.xOffset + pairLineWidth / 2 - printableWidth / 2) < 2.0,
                           @"the fitted pair still centers as a group within the printable width");
            }
            SPDFExpect(![fitString.string containsString:@"Wide left"] &&
                           ![fitString.string containsString:@"Wide right"],
                       @"a titled row image keeps its alt text out of the visible string");
            // The titled pair captions below itself: one image line, then one
            // caption line whose fragments each center under their own image.
            SPDFExpect([fitString.string containsString:@"￼ ￼\nLeft title Right title"],
                       @"a titled two-image row renders one image line then one caption line, titles preferred");
            NSRange leftCaption = [fitString.string rangeOfString:@"Left title"];
            NSRange rightCaption = [fitString.string rangeOfString:@"Right title"];
            SPDFMarkdownPageFragment* leftCaptionFragment =
                leftCaption.location != NSNotFound ? SPDFFragmentForIndex(fitPlan, leftCaption.location) : nil;
            SPDFMarkdownPageFragment* rightCaptionFragment =
                rightCaption.location != NSNotFound ? SPDFFragmentForIndex(fitPlan, rightCaption.location) : nil;
            SPDFExpect(leftCaptionFragment != nil && rightCaptionFragment != nil &&
                           leftCaptionFragment != rightCaptionFragment,
                       @"each row caption paginates as its own custom-positioned fragment");
            if (pairFragment && leftCaptionFragment && rightCaptionFragment) {
                SPDFExpect(fabs(leftCaptionFragment.pageYOffset - rightCaptionFragment.pageYOffset) < 0.001 &&
                               leftCaptionFragment.pageYOffset >
                                   pairFragment.pageYOffset + pairFragment.height - 0.5,
                           @"both captions share one caption line strictly below the image line");
                CGFloat leftImageCenter = SPDFImageCenterX(fitString, pairFragment, pairRow.location);
                CGFloat rightImageCenter = SPDFImageCenterX(fitString, pairFragment, pairRow.location + 2);
                SPDFExpect(fabs(SPDFCaptionCenterX(fitString, leftCaptionFragment) - leftImageCenter) < 2.0,
                           @"the left caption centers under the left image's x-span");
                SPDFExpect(fabs(SPDFCaptionCenterX(fitString, rightCaptionFragment) - rightImageCenter) < 2.0,
                           @"the right caption centers under the right image's x-span");
                NSFont* pairCaptionFont = [fitString attribute:NSFontAttributeName
                                                       atIndex:leftCaption.location
                                                effectiveRange:nil];
                NSColor* pairCaptionColor = [fitString attribute:NSForegroundColorAttributeName
                                                         atIndex:leftCaption.location
                                                  effectiveRange:nil];
                SPDFExpect(fabs(pairCaptionFont.pointSize - 13.5) < 0.01 &&
                               [pairCaptionColor isEqual:fitOptions.secondaryTextColor],
                           @"row captions render muted at 0.9x body size");
            }
        }

        // An image with neither title nor alt contributes no caption; its
        // neighbors keep theirs, still centered under their own images.
        NSRange mixedRow =
            [fitString.string rangeOfString:@"￼ ￼ ￼\nFirst badge caption Third badge caption"];
        SPDFExpect(mixedRow.location != NSNotFound,
                   @"a caption-less image drops out of the caption line without disturbing its neighbors");
        if (mixedRow.location != NSNotFound) {
            SPDFMarkdownPageFragment* mixedImages = SPDFFragmentForIndex(fitPlan, mixedRow.location);
            NSRange firstCaption = [fitString.string rangeOfString:@"First badge caption"];
            NSRange thirdCaption = [fitString.string rangeOfString:@"Third badge caption"];
            SPDFMarkdownPageFragment* firstCaptionFragment = SPDFFragmentForIndex(fitPlan, firstCaption.location);
            SPDFMarkdownPageFragment* thirdCaptionFragment = SPDFFragmentForIndex(fitPlan, thirdCaption.location);
            SPDFExpect(mixedImages != nil && firstCaptionFragment != nil && thirdCaptionFragment != nil,
                       @"the mixed row's images and captions all paginate");
            if (mixedImages && firstCaptionFragment && thirdCaptionFragment) {
                CGFloat firstCenter = SPDFImageCenterX(fitString, mixedImages, mixedRow.location);
                CGFloat thirdCenter = SPDFImageCenterX(fitString, mixedImages, mixedRow.location + 4);
                SPDFExpect(fabs(SPDFCaptionCenterX(fitString, firstCaptionFragment) - firstCenter) < 2.0 &&
                               fabs(SPDFCaptionCenterX(fitString, thirdCaptionFragment) - thirdCenter) < 2.0,
                           @"captions still center under their own images around the caption-less neighbor");
            }
        }

        NSRange badgeRow = [fitString.string rangeOfString:@"\uFFFC \uFFFC \uFFFC \uFFFC \uFFFC"];
        SPDFExpect(badgeRow.location != NSNotFound, @"the five-badge row keeps its side-by-side shape");
        if (badgeRow.location != NSNotFound) {
            for (NSUInteger offset = 0; offset < 9; offset += 2) {
                NSTextAttachment* badge = [fitString attribute:NSAttachmentAttributeName
                                                       atIndex:badgeRow.location + offset
                                                effectiveRange:nil];
                SPDFExpect(badge != nil && fabs(badge.bounds.size.width - 60.0) < 0.001 &&
                               fabs(badge.bounds.size.height - 20.0) < 0.001,
                           @"a badge strip already under the budget keeps its natural sizes");
            }
        }

        NSRange wallRow = [fitString.string rangeOfString:@"\uFFFC \uFFFC \uFFFC \uFFFC \uFFFC \uFFFC"];
        SPDFExpect(wallRow.location != NSNotFound, @"the six-image row renders as one row paragraph");
        if (wallRow.location != NSNotFound) {
            for (NSUInteger offset = 0; offset < 11; offset += 2) {
                NSTextAttachment* wall = [fitString attribute:NSAttachmentAttributeName
                                                      atIndex:wallRow.location + offset
                                               effectiveRange:nil];
                SPDFExpect(wall != nil && fabs(wall.bounds.size.width - 440.0 * 0.45) < 0.01 &&
                               fabs(wall.bounds.size.height - (440.0 / 3.0) * 0.45) < 0.01,
                           @"a row that cannot fit even at the floor stops shrinking at 0.45x");
            }
            SPDFMarkdownPageFragment* wallFirst = SPDFFragmentForIndex(fitPlan, wallRow.location);
            SPDFMarkdownPageFragment* wallLast = SPDFFragmentForIndex(fitPlan, wallRow.location + 10);
            SPDFExpect(wallFirst != nil && wallLast != nil && wallFirst != wallLast,
                       @"a floored row wraps onto further lines instead of overflowing the page");
            // A wrapped row captions per wrapped image line: the first line's
            // captions sit below it and above the later image lines, each
            // still centered under its own image.
            NSRange wallCaption = [fitString.string rangeOfString:@"Wall 0"];
            SPDFMarkdownPageFragment* wallCaptionFragment =
                wallCaption.location != NSNotFound ? SPDFFragmentForIndex(fitPlan, wallCaption.location) : nil;
            SPDFExpect(wallFirst && wallLast && wallCaptionFragment != nil &&
                           wallCaptionFragment.pageYOffset >
                               wallFirst.pageYOffset + wallFirst.height - 0.5 &&
                           wallCaptionFragment.pageYOffset < wallLast.pageYOffset + 0.5,
                       @"a wrapped row's captions follow their own image line instead of collecting at the bottom");
            if (wallFirst && wallCaptionFragment) {
                CGFloat wallImageCenter = SPDFImageCenterX(fitString, wallFirst, wallRow.location);
                SPDFExpect(fabs(SPDFCaptionCenterX(fitString, wallCaptionFragment) - wallImageCenter) < 2.0,
                           @"a wrapped row's caption still centers under its own image");
            }
        }
    }
    return SPDFFinishTests(@"SPDFMarkdownImageFigureTests");
}
