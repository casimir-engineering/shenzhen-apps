#import "../SPDFSearchSnippet.h"
#import "SPDFMarkdownRenderer.h"

#import "SPDFMarkdownDecorations.h"
#import "SPDFMarkdownRenderInternal.h"

NSAttributedStringKey const SPDFMarkdownBlockIndexAttribute = @"SPDFMarkdownBlockIndex";
NSAttributedStringKey const SPDFMarkdownBlockKindAttribute = @"SPDFMarkdownBlockKind";
NSAttributedStringKey const SPDFMarkdownWikiLinkAttribute = @"SPDFMarkdownWikiLink";
NSAttributedStringKey const SPDFMarkdownImageTargetAttribute = @"SPDFMarkdownImageTarget";
NSAttributedStringKey const SPDFMarkdownCodeLanguageAttribute = @"SPDFMarkdownCodeLanguage";

@implementation SPDFMarkdownRenderOptions
- (instancetype)init {
    self = [super init];
    if (self) _fontScale = 1.0;
    return self;
}
- (void)setFontScale:(CGFloat)fontScale { _fontScale = MAX(0.5, MIN(3.0, fontScale)); }
// The one theme knob: assigning the variant re-derives every palette role
// color, so the rendered output is deterministic per (options.themeVariant).
// Custom color overrides go on top, AFTER the variant.
- (void)setThemeVariant:(SPDFMarkdownThemeVariant)themeVariant {
    _themeVariant = themeVariant;
    SPDFMarkdownTheme* theme = [SPDFMarkdownTheme themeForVariant:themeVariant];
    self.textColor = theme.bodyTextColor;
    self.secondaryTextColor = theme.secondaryTextColor;
    self.linkColor = theme.linkColor;
    self.codeBackgroundColor = theme.inlineCodeChipColor;
    self.markHighlightColor = theme.markHighlightColor;
    self.quoteColor = theme.secondaryTextColor;
}
// The reading palette lives in SPDFMarkdownTheme: body text is a softened
// near-black on the default light theme's white paper, secondary roles share
// one muted gray, and all values are concrete sRGB so screen, print and
// export match exactly. Body metrics follow GitHub's reader: ~1.45
// line-height and a paragraph gap of roughly 0.8em.
+ (instancetype)defaultOptions {
    SPDFMarkdownRenderOptions* options = [SPDFMarkdownRenderOptions new];
    options.textSize = 15;
    options.codeSize = 13;
    options.lineSpacing = 4;
    options.paragraphSpacing = 12;
    options.fontScale = 1.0;
    options.contentInset = 24;
    options.maximumImageWidth = 440;
    options.maximumImageHeight = 320;
    options.maximumResourceBytes = 64 * 1024 * 1024;
    options.maximumDecodedImagePixels = 32 * 1024 * 1024;
    options.remoteImagePlaceholderHeight = 150;
    options.themeVariant = SPDFMarkdownThemeVariantLight;  // derives the palette roles
    return options;
}
+ (instancetype)defaultOptionsForThemeVariant:(SPDFMarkdownThemeVariant)variant {
    SPDFMarkdownRenderOptions* options = [self defaultOptions];
    options.themeVariant = variant;
    return options;
}
// Print parity is the point of the concrete palettes: the exported page uses
// exactly the colors the screen shows (the live plan carries the active
// variant to the export drawing).
+ (instancetype)printOptions {
    return self.defaultOptions;
}
- (id)copyWithZone:(NSZone*)zone {
    SPDFMarkdownRenderOptions* copy = [[[self class] allocWithZone:zone] init];
    // The variant first (it rewrites the palette roles), then every explicit
    // color, so custom overrides survive the copy.
    copy.themeVariant = self.themeVariant;
    copy.textSize = self.textSize;
    copy.codeSize = self.codeSize;
    copy.lineSpacing = self.lineSpacing;
    copy.paragraphSpacing = self.paragraphSpacing;
    copy.fontScale = self.fontScale;
    copy.contentInset = self.contentInset;
    copy.pageContentSize = self.pageContentSize;
    copy.maximumImageWidth = self.maximumImageWidth;
    copy.maximumImageHeight = self.maximumImageHeight;
    copy.maximumResourceBytes = self.maximumResourceBytes;
    copy.maximumDecodedImagePixels = self.maximumDecodedImagePixels;
    copy.remoteImageData = self.remoteImageData;
    copy.failedRemoteImageTargets = self.failedRemoteImageTargets;
    copy.remoteImagesWithheld = self.remoteImagesWithheld;
    copy.remoteImagePlaceholderHeight = self.remoteImagePlaceholderHeight;
    // By reference on purpose: the diagram cache is a shared thread-safe store
    // whose whole value is being hit by the copies a rerender makes.
    copy.diagramCache = self.diagramCache;
    copy.textColor = self.textColor;
    copy.secondaryTextColor = self.secondaryTextColor;
    copy.linkColor = self.linkColor;
    copy.codeBackgroundColor = self.codeBackgroundColor;
    copy.markHighlightColor = self.markHighlightColor;
    copy.quoteColor = self.quoteColor;
    return copy;
}
@end

@implementation SPDFMarkdownRenderedBlock
- (instancetype)initWithBlockIndex:(NSUInteger)blockIndex
                              kind:(SPDFMarkdownBlockKind)kind
                   attributedRange:(NSRange)attributedRange
                             level:(NSUInteger)level
                             depth:(NSUInteger)depth
                      tableRowInfo:(SPDFMarkdownTableRowInfo*)tableRowInfo
                       diagramInfo:(SPDFMarkdownDiagramBlockInfo*)diagramInfo {
    self = [super init];
    if (self) {
        _blockIndex = blockIndex;
        _kind = kind;
        _attributedRange = attributedRange;
        _level = level;
        _depth = depth;
        _tableRowInfo = tableRowInfo;
        _diagramInfo = diagramInfo;
    }
    return self;
}
- (instancetype)initWithBlockIndex:(NSUInteger)blockIndex
                              kind:(SPDFMarkdownBlockKind)kind
                   attributedRange:(NSRange)attributedRange
                             level:(NSUInteger)level
                             depth:(NSUInteger)depth
                      tableRowInfo:(SPDFMarkdownTableRowInfo*)tableRowInfo {
    return [self initWithBlockIndex:blockIndex
                               kind:kind
                    attributedRange:attributedRange
                              level:level
                              depth:depth
                       tableRowInfo:tableRowInfo
                        diagramInfo:nil];
}
- (instancetype)initWithBlockIndex:(NSUInteger)blockIndex
                              kind:(SPDFMarkdownBlockKind)kind
                   attributedRange:(NSRange)attributedRange
                             level:(NSUInteger)level
                             depth:(NSUInteger)depth {
    return [self initWithBlockIndex:blockIndex
                               kind:kind
                    attributedRange:attributedRange
                              level:level
                              depth:depth
                       tableRowInfo:nil];
}
@end

@interface SPDFMarkdownRenderedHeading ()
- (instancetype)initWithBlockIndex:(NSUInteger)blockIndex
                              level:(NSUInteger)level
                              title:(NSString*)title
                    attributedRange:(NSRange)attributedRange;
@end

@implementation SPDFMarkdownRenderedHeading
- (instancetype)initWithBlockIndex:(NSUInteger)blockIndex
                              level:(NSUInteger)level
                              title:(NSString*)title
                    attributedRange:(NSRange)attributedRange {
    self = [super init];
    if (self) {
        _blockIndex = blockIndex;
        _level = level;
        _title = [title copy];
        _attributedRange = attributedRange;
    }
    return self;
}
@end

@interface SPDFMarkdownRenderedDocument ()
- (instancetype)initWithString:(NSAttributedString*)string blocks:(NSArray<SPDFMarkdownRenderedBlock*>*)blocks;
@end

@implementation SPDFMarkdownRenderedDocument {
    NSDictionary<NSNumber*, SPDFMarkdownRenderedBlock*>* _byIndex;
    NSArray<SPDFMarkdownRenderedBlock*>* _sortedBlocks;
}
- (instancetype)initWithString:(NSAttributedString*)string blocks:(NSArray<SPDFMarkdownRenderedBlock*>*)blocks {
    self = [super init];
    if (!self) return nil;
    _attributedString = [string copy];
    _renderedBlocks = [blocks copy];
    NSMutableDictionary* byIndex = [NSMutableDictionary dictionary];
    NSMutableArray* headings = [NSMutableArray array];
    for (SPDFMarkdownRenderedBlock* block in blocks) {
        if (!byIndex[@(block.blockIndex)]) byIndex[@(block.blockIndex)] = block;
        if (block.kind != SPDFMarkdownBlockKindHeading) continue;
        NSString* title = [[string.string substringWithRange:block.attributedRange]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        SPDFMarkdownRenderedHeading* heading = [[SPDFMarkdownRenderedHeading alloc]
            initWithBlockIndex:block.blockIndex level:block.level title:title attributedRange:block.attributedRange];
        [headings addObject:heading];
    }
    _byIndex = [byIndex copy];
    _sortedBlocks = [blocks sortedArrayUsingComparator:^NSComparisonResult(SPDFMarkdownRenderedBlock* left,
                                                                           SPDFMarkdownRenderedBlock* right) {
        if (left.attributedRange.location != right.attributedRange.location) {
            return left.attributedRange.location < right.attributedRange.location ? NSOrderedAscending
                                                                                   : NSOrderedDescending;
        }
        if (left.attributedRange.length == right.attributedRange.length) return NSOrderedSame;
        return left.attributedRange.length > right.attributedRange.length ? NSOrderedAscending : NSOrderedDescending;
    }];
    _headings = [headings copy];
    return self;
}
- (SPDFMarkdownRenderedBlock*)renderedBlockWithIndex:(NSUInteger)blockIndex { return _byIndex[@(blockIndex)]; }

- (SPDFMarkdownRenderedBlock*)blockContainingLocation:(NSUInteger)location {
    NSUInteger low = 0;
    NSUInteger high = _sortedBlocks.count;
    while (low < high) {
        NSUInteger middle = low + (high - low) / 2;
        if (_sortedBlocks[middle].attributedRange.location <= location) low = middle + 1;
        else high = middle;
    }
    if (low == 0) return nil;
    SPDFMarkdownRenderedBlock* candidate = _sortedBlocks[low - 1];
    return NSLocationInRange(location, candidate.attributedRange) ? candidate : nil;
}

- (NSInteger)headingIndexAtLocation:(NSUInteger)location {
    NSUInteger low = 0;
    NSUInteger high = self.headings.count;
    while (low < high) {
        NSUInteger middle = low + (high - low) / 2;
        if (self.headings[middle].attributedRange.location <= location) low = middle + 1;
        else high = middle;
    }
    return low == 0 ? -1 : (NSInteger)low - 1;
}

- (void)appendSearchMatch:(NSRange)found
                canonical:(NSString*)canonical
                   matches:(NSMutableArray<SPDFMarkdownSearchMatch*>*)matches {
    SPDFMarkdownRenderedBlock* owner = [self blockContainingLocation:found.location];
    NSInteger headingIndex = [self headingIndexAtLocation:found.location];
    NSString* context = SPDFSearchSnippet(canonical,found,24,72)[@"title"];
    [matches addObject:[[SPDFMarkdownSearchMatch alloc] initWithRange:found
                                                           blockIndex:owner ? owner.blockIndex : NSNotFound
                                                         headingIndex:headingIndex
                                                              context:context]];
}

- (NSArray<SPDFMarkdownSearchMatch*>*)exactSearchForQuery:(NSString*)query
                                                canonical:(NSString*)canonical
                                        cancellationToken:(SPDFMarkdownCancellationToken*)cancellationToken {
    NSUInteger* prefix = (NSUInteger*)calloc(query.length, sizeof(NSUInteger));
    if (!prefix) return @[];
    for (NSUInteger index = 1, matched = 0; index < query.length; ++index) {
        unichar value = [query characterAtIndex:index];
        while (matched && value != [query characterAtIndex:matched]) matched = prefix[matched - 1];
        if (value == [query characterAtIndex:matched]) ++matched;
        prefix[index] = matched;
    }
    NSMutableArray* matches = [NSMutableArray array];
    for (NSUInteger index = 0, matched = 0; index < canonical.length; ++index) {
        if ((index & 0xfff) == 0 && cancellationToken.isCancelled) {
            free(prefix);
            return @[];
        }
        unichar value = [canonical characterAtIndex:index];
        while (matched && value != [query characterAtIndex:matched]) matched = prefix[matched - 1];
        if (value == [query characterAtIndex:matched]) ++matched;
        if (matched == query.length) {
            NSRange found = NSMakeRange(index + 1 - matched, matched);
            [self appendSearchMatch:found canonical:canonical matches:matches];
            matched = 0;  // Preserve the existing non-overlapping match semantics.
        }
    }
    free(prefix);
    return cancellationToken.isCancelled ? @[] : matches;
}

// NSRegularExpression over the canonical text. NSMatchingReportProgress gives
// the block periodic control between matches, so cancellation is honored at a
// cadence comparable to the plain path's per-chunk checks.
- (NSArray<SPDFMarkdownSearchMatch*>*)regexSearchForQuery:(NSString*)query
                                            caseSensitive:(BOOL)caseSensitive
                                                canonical:(NSString*)canonical
                                        cancellationToken:(SPDFMarkdownCancellationToken*)cancellationToken
                                                    error:(NSError**)error {
    NSRegularExpressionOptions options = caseSensitive ? 0 : NSRegularExpressionCaseInsensitive;
    NSRegularExpression* expression = [NSRegularExpression regularExpressionWithPattern:query
                                                                                 options:options
                                                                                   error:error];
    if (!expression) return nil;
    NSMutableArray<SPDFMarkdownSearchMatch*>* matches = [NSMutableArray array];
    [expression enumerateMatchesInString:canonical
                                 options:NSMatchingReportProgress
                                   range:NSMakeRange(0, canonical.length)
                              usingBlock:^(NSTextCheckingResult* result, NSMatchingFlags flags, BOOL* stop) {
                                (void)flags;
                                if (cancellationToken.isCancelled) {
                                    *stop = YES;
                                    return;
                                }
                                if (result.range.length == 0) return;
                                [self appendSearchMatch:result.range canonical:canonical matches:matches];
                              }];
    return cancellationToken.isCancelled ? @[] : matches;
}

- (NSArray<SPDFMarkdownSearchMatch*>*)searchForQuery:(NSString*)query caseSensitive:(BOOL)caseSensitive {
    return [self searchForQuery:query caseSensitive:caseSensitive cancellationToken:nil];
}
- (NSArray<SPDFMarkdownSearchMatch*>*)searchForQuery:(NSString*)query
                                       caseSensitive:(BOOL)caseSensitive
                                               regex:(BOOL)regex
                                   cancellationToken:(SPDFMarkdownCancellationToken*)cancellationToken
                                               error:(NSError**)error {
    if (error) *error = nil;
    if (!regex) return [self searchForQuery:query caseSensitive:caseSensitive cancellationToken:cancellationToken];
    static const NSUInteger maximumInteractiveQueryLength = 4096;
    if (query.length == 0 || query.length > maximumInteractiveQueryLength) return @[];
    return [self regexSearchForQuery:query
                       caseSensitive:caseSensitive
                           canonical:self.attributedString.string
                   cancellationToken:cancellationToken
                               error:error];
}
- (NSArray<SPDFMarkdownSearchMatch*>*)searchForQuery:(NSString*)query
                                       caseSensitive:(BOOL)caseSensitive
                                   cancellationToken:(SPDFMarkdownCancellationToken*)cancellationToken {
    static const NSUInteger maximumInteractiveQueryLength = 4096;
    if (query.length == 0 || query.length > maximumInteractiveQueryLength) return @[];
    NSString* canonical = self.attributedString.string;
    if (caseSensitive) {
        return [self exactSearchForQuery:query canonical:canonical cancellationToken:cancellationToken];
    }
    NSStringCompareOptions options = caseSensitive ? 0 : NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;
    NSMutableArray* matches = [NSMutableArray array];
    static const NSUInteger chunkLength = 64 * 1024;
    NSUInteger chunkStart = 0;
    while (chunkStart < canonical.length) {
        if (cancellationToken.isCancelled) return @[];
        NSUInteger ownedEnd = chunkStart + MIN(chunkLength, canonical.length - chunkStart);
        if (ownedEnd < canonical.length) {
            ownedEnd = NSMaxRange([canonical rangeOfComposedCharacterSequenceAtIndex:ownedEnd]);
        }
        NSUInteger overlap = MIN(query.length - 1, canonical.length - ownedEnd);
        NSRange remaining = NSMakeRange(chunkStart, ownedEnd + overlap - chunkStart);
        while (remaining.length) {
            if (cancellationToken.isCancelled) return @[];
            NSRange found = [canonical rangeOfString:query options:options range:remaining];
            if (found.location == NSNotFound || found.location >= ownedEnd) break;
            [self appendSearchMatch:found canonical:canonical matches:matches];
            NSUInteger next = MAX(NSMaxRange(found), found.location + 1);
            NSUInteger searchEnd = NSMaxRange(remaining);
            remaining = NSMakeRange(next, searchEnd - next);
        }
        chunkStart = ownedEnd;
    }
    return matches;
}
@end

@implementation SPDFMarkdownRenderer
- (instancetype)init { return [self initWithLanguageCatalog:SPDFMarkdownLanguageCatalog.sharedCatalog]; }
- (instancetype)initWithLanguageCatalog:(SPDFMarkdownLanguageCatalog*)languageCatalog {
    self = [super init];
    if (self) _languageCatalog = languageCatalog;
    return self;
}
- (SPDFMarkdownRenderedDocument*)renderModel:(SPDFMarkdownDocumentModel*)model
                                     options:(SPDFMarkdownRenderOptions*)options
                           languageOverrides:(NSDictionary<NSNumber*, NSString*>*)languageOverrides {
    return [self renderModel:model options:options languageOverrides:languageOverrides cancellationToken:nil];
}
- (SPDFMarkdownRenderedDocument*)renderModel:(SPDFMarkdownDocumentModel*)model
                                      options:(SPDFMarkdownRenderOptions*)options
                            languageOverrides:(NSDictionary<NSNumber*, NSString*>*)languageOverrides
                            cancellationToken:(SPDFMarkdownCancellationToken*)cancellationToken {
    SPDFMarkdownRenderContext* context = [SPDFMarkdownRenderContext new];
    context.output = [NSMutableAttributedString new];
    context.blocks = [NSMutableArray array];
    context.options = options;
    context.catalog = self.languageCatalog;
    context.highlighter = [SPDFMarkdownHighlighter new];
    context.cancellationToken = cancellationToken;
    context.overrides = languageOverrides ?: @{};
    context.sourceURL = model.sourceURL;
    context.resourceStore = model.resourceStore
        ? [model.resourceStore storeWithMaximumResourceBytes:options.maximumResourceBytes
                                   maximumDecodedImagePixels:options.maximumDecodedImagePixels]
        : [SPDFMarkdownResourceStore
              remoteOnlyStoreWithMaximumResourceBytes:options.maximumResourceBytes
                            maximumDecodedImagePixels:options.maximumDecodedImagePixels];
    context.resourceStore.remoteImageData = options.remoteImageData;
    CGFloat fontScale = options.fontScale > 0 ? options.fontScale : 1;
    context.bodyFont = [NSFont systemFontOfSize:options.textSize * fontScale];
    context.codeFont = [NSFont monospacedSystemFontOfSize:options.codeSize * fontScale weight:NSFontWeightRegular];
    SPDFRenderMarkdownBlocks(context, model.blocks);
    if (cancellationToken.isCancelled) return nil;
    return [[SPDFMarkdownRenderedDocument alloc] initWithString:context.output blocks:context.blocks];
}
- (NSTextView*)newSelectableTextViewForRenderedDocument:(SPDFMarkdownRenderedDocument*)document
                                                 options:(SPDFMarkdownRenderOptions*)options {
    NSTextView* view = [[NSTextView alloc] initWithFrame:NSZeroRect];
    view.editable = NO;
    view.selectable = YES;
    view.richText = YES;
    view.importsGraphics = YES;
    view.drawsBackground = NO;
    view.textContainerInset = NSMakeSize(options.contentInset, options.contentInset);
    view.textContainer.widthTracksTextView = YES;
    [view.textStorage setAttributedString:document.attributedString];
    return view;
}
@end
