#import "SPDFMarkdownDiagramInternal.h"

#import <CoreText/CoreText.h>

// Shared diagram model objects, the per-variant palette, and the small text /
// text utilities every parser and shape emitter builds on.

@implementation SPDFMarkdownDiagramNode
- (instancetype)init {
    self = [super init];
    if (self) {
        _identifier = @"";
        _label = @"";
    }
    return self;
}
@end

@implementation SPDFMarkdownDiagramEdge
- (instancetype)init {
    self = [super init];
    if (self) {
        _fromIdentifier = @"";
        _toIdentifier = @"";
        _head = SPDFMarkdownDiagramArrowHeadArrow;
    }
    return self;
}
@end

@implementation SPDFMarkdownDiagramGraph {
    NSMutableDictionary<NSString*, SPDFMarkdownDiagramNode*>* _byIdentifier;
}
- (instancetype)init {
    self = [super init];
    if (self) {
        _vertical = YES;
        _nodes = [NSMutableArray array];
        _edges = [NSMutableArray array];
        _byIdentifier = [NSMutableDictionary dictionary];
        _classStyles = [NSMutableDictionary dictionary];
        _classNamesByIdentifier = [NSMutableDictionary dictionary];
    }
    return self;
}
- (SPDFMarkdownDiagramNode*)nodeForIdentifier:(NSString*)identifier createWithLabel:(NSString*)label {
    SPDFMarkdownDiagramNode* node = _byIdentifier[identifier];
    if (node) {
        // A later statement can attach the shaped label to a node first seen bare.
        if (label.length) node.label = label;
        return node;
    }
    node = [SPDFMarkdownDiagramNode new];
    node.identifier = identifier;
    node.label = label.length ? label : identifier;
    [_nodes addObject:node];
    _byIdentifier[identifier] = node;
    return node;
}
- (SPDFMarkdownDiagramNode*)existingNodeForIdentifier:(NSString*)identifier { return _byIdentifier[identifier]; }
- (SPDFMarkdownDiagramNodeStyle*)styleForNode:(SPDFMarkdownDiagramNode*)node {
    // `classDef default ...` is mermaid's catch-all; a node with its own class
    // never falls back to it.
    SPDFMarkdownDiagramNodeStyle* own = node.className.length ? _classStyles[node.className] : nil;
    return own ?: _classStyles[@"default"];
}
- (void)applyDeferredClassNames {
    if (!_classNamesByIdentifier.count) return;
    for (SPDFMarkdownDiagramNode* node in _nodes) {
        // A `:::name` written on the node itself wins over a later `class`
        // statement, so the closer declaration is the one that shows.
        if (node.className.length) continue;
        NSString* name = _classNamesByIdentifier[node.identifier];
        if (name.length) node.className = name;
    }
}
@end

@implementation SPDFMarkdownDiagramSequenceEvent
@end

@implementation SPDFMarkdownDiagramSequence
- (instancetype)init {
    self = [super init];
    if (self) {
        _actorIdentifiers = [NSMutableArray array];
        _actorLabels = [NSMutableDictionary dictionary];
        _events = [NSMutableArray array];
    }
    return self;
}
- (NSString*)actorForToken:(NSString*)token {
    NSString* identifier = SPDFMarkdownDiagramTrim(token);
    if (!identifier.length) return identifier;
    if (!self.actorLabels[identifier]) {
        [self.actorIdentifiers addObject:identifier];
        self.actorLabels[identifier] = identifier;
    }
    return identifier;
}
@end

@implementation SPDFMarkdownDiagramPieSlice
@end

@implementation SPDFMarkdownDiagramPie
- (instancetype)init {
    self = [super init];
    if (self) _slices = [NSMutableArray array];
    return self;
}
@end

@implementation SPDFMarkdownDiagramGanttTask
@end

@implementation SPDFMarkdownDiagramGanttSection
- (instancetype)init {
    self = [super init];
    if (self) _tasks = [NSMutableArray array];
    return self;
}
@end

@implementation SPDFMarkdownDiagramGantt
- (instancetype)init {
    self = [super init];
    if (self) _sections = [NSMutableArray array];
    return self;
}
- (NSUInteger)taskCount {
    NSUInteger count = 0;
    for (SPDFMarkdownDiagramGanttSection* section in self.sections) count += section.tasks.count;
    return count;
}
@end

// The categorical ramp starts from the theme accent and rotates through five
// fixed hue offsets, with saturation/brightness retuned per variant so slices
// and bars stay readable on both papers without ever leaving the theme family.
static NSArray<NSColor*>* SPDFDiagramAccentRamp(NSColor* accent, SPDFMarkdownThemeVariant variant) {
    NSColor* base = [accent colorUsingColorSpace:NSColorSpace.sRGBColorSpace] ?: accent;
    CGFloat hue = 0, saturation = 0, brightness = 0, alpha = 0;
    [base getHue:&hue saturation:&saturation brightness:&brightness alpha:&alpha];
    static const CGFloat offsets[] = {0.0, 0.45, 0.12, 0.62, 0.27, 0.82};
    BOOL dark = variant == SPDFMarkdownThemeVariantDark;
    NSMutableArray* ramp = [NSMutableArray arrayWithCapacity:6];
    for (NSUInteger index = 0; index < 6; ++index) {
        CGFloat rotated = fmod(hue + offsets[index], 1.0);
        [ramp addObject:[NSColor colorWithColorSpace:NSColorSpace.sRGBColorSpace
                                                 hue:rotated
                                          saturation:MIN(1.0, saturation * (dark ? 0.62 : 0.85))
                                          brightness:dark ? MIN(1.0, brightness * 1.05) : MIN(0.78, brightness)
                                               alpha:1.0]];
    }
    return ramp;
}

@implementation SPDFMarkdownDiagramPalette
+ (instancetype)paletteForVariant:(SPDFMarkdownThemeVariant)variant {
    static SPDFMarkdownDiagramPalette* palettes[2];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      for (NSInteger raw = 0; raw < 2; ++raw) {
          SPDFMarkdownTheme* theme = [SPDFMarkdownTheme themeForVariant:(SPDFMarkdownThemeVariant)raw];
          SPDFMarkdownDiagramPalette* palette = [SPDFMarkdownDiagramPalette new];
          palette->_paperColor = theme.paperColor;
          palette->_nodeFillColor = theme.codeBoxFillColor;
          palette->_nodeStrokeColor = theme.codeBoxStrokeColor;
          palette->_textColor = theme.bodyTextColor;
          palette->_secondaryColor = theme.secondaryTextColor;
          palette->_accentColor = theme.linkColor;
          palette->_criticalColor = raw == SPDFMarkdownThemeVariantDark
              ? [NSColor colorWithSRGBRed:0.90 green:0.33 blue:0.29 alpha:1.0]   // #E5544A
              : [NSColor colorWithSRGBRed:0.82 green:0.14 blue:0.18 alpha:1.0];  // #D1242F
          palette->_accentRamp = SPDFDiagramAccentRamp(theme.linkColor, (SPDFMarkdownThemeVariant)raw);
          palettes[raw] = palette;
      }
    });
    return palettes[variant == SPDFMarkdownThemeVariantDark ? 1 : 0];
}
@end

NSString* SPDFMarkdownDiagramTrim(NSString* string) {
    return [string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

// Splits source into trimmed lines, dropping blanks, `%%` comment lines
// (including `%%{init: ...}%%` directives) and js-sequence `#` comments.
NSArray<NSString*>* SPDFMarkdownDiagramSignificantLines(NSString* source) {
    NSMutableArray* lines = [NSMutableArray array];
    for (NSString* raw in [source componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString* line = SPDFMarkdownDiagramTrim(raw);
        if (!line.length || [line hasPrefix:@"%%"] || [line hasPrefix:@"#"]) continue;
        [lines addObject:line];
    }
    return lines;
}

// The five entities mermaid labels actually carry. `&amp;` is decoded LAST so
// `&amp;lt;` comes out as the text `&lt;` rather than as a `<`.
static NSString* SPDFDiagramDecodeEntities(NSString* text) {
    if ([text rangeOfString:@"&"].location == NSNotFound) return text;
    static NSArray<NSArray<NSString*>*>* replacements;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      replacements = @[
          @[ @"&lt;", @"<" ], @[ @"&gt;", @">" ], @[ @"&quot;", @"\"" ], @[ @"&#39;", @"'" ],
          @[ @"&apos;", @"'" ], @[ @"&nbsp;", @" " ], @[ @"&amp;", @"&" ]
      ];
    });
    NSString* decoded = text;
    for (NSArray<NSString*>* replacement in replacements)
        decoded = [decoded stringByReplacingOccurrencesOfString:replacement[0]
                                                     withString:replacement[1]];
    return decoded;
}

// Collapses every whitespace run in one line of a label to a single space.
static NSString* SPDFDiagramCollapseSpaces(NSString* text) {
    NSMutableArray* kept = [NSMutableArray array];
    for (NSString* part in [text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet])
        if (part.length) [kept addObject:part];
    return [kept componentsJoinedByString:@" "];
}

// Normalizes a node/edge/message label: turns the <br> variants into REAL line
// breaks, strips wrapping quotes and backticks, decodes HTML entities, and
// collapses whitespace runs inside each line. A label is therefore a
// newline-separated list of lines, and the wrap/measure pair below is the only
// place that has to know it.
//
// Order matters twice: <br> becomes a newline before the quote strip (the
// quotes are still at the ends), and entities are decoded AFTER it, so a
// `&quot;`-quoted label keeps its quotes as text instead of losing them to the
// syntactic-quote strip.
NSString* SPDFMarkdownDiagramCleanLabel(NSString* label) {
    NSString* text = SPDFMarkdownDiagramTrim(label);
    for (NSString* br in @[ @"<br/>", @"<br />", @"<br>" ]) {
        text = [text stringByReplacingOccurrencesOfString:br withString:@"\n"
                                                  options:NSCaseInsensitiveSearch
                                                    range:NSMakeRange(0, text.length)];
    }
    if (text.length >= 2) {
        unichar first = [text characterAtIndex:0];
        unichar last = [text characterAtIndex:text.length - 1];
        if ((first == '"' && last == '"') || (first == '`' && last == '`'))
            text = [text substringWithRange:NSMakeRange(1, text.length - 2)];
    }
    text = SPDFDiagramDecodeEntities(text);
    if ([text rangeOfString:@"\n"].location == NSNotFound) return SPDFDiagramCollapseSpaces(text);
    NSMutableArray<NSString*>* lines = [NSMutableArray array];
    for (NSString* line in [text componentsSeparatedByString:@"\n"]) {
        NSString* collapsed = SPDFDiagramCollapseSpaces(line);
        if (collapsed.length) [lines addObject:collapsed];
    }
    return [lines componentsJoinedByString:@"\n"];
}

// --- Inline label markup -------------------------------------------------------

// mermaid renders a node/edge label as HTML, so `<b>USB-C VBUS</b> 5 V` means
// a BOLD RUN inside the line. This renderer used to draw the markup itself:
// the tags reached the canvas as ordinary characters, which both printed them
// and made every node wide enough to hold them.
//
// Weight and slant change the FONT a span is measured and drawn in; underline
// and strikethrough do not, so they ride along as span flags the emitter turns
// into text attributes on the label's canonical text (SPDFMarkdownDiagramBlock).
// Everything else stays literal: `<code>`, `<mark>`, an unknown tag, or the
// bare `<` that a `&lt;` in the source decodes to.
typedef NS_OPTIONS(NSUInteger, SPDFDiagramLabelTraits) {
    SPDFDiagramLabelTraitBold = 1 << 0,
    SPDFDiagramLabelTraitItalic = 1 << 1,
    SPDFDiagramLabelTraitUnderline = 1 << 2,
    SPDFDiagramLabelTraitStrikethrough = 1 << 3,
};

// Carried alongside the font on a wrapped line so the canvas can hand the page
// the SPANS rather than have to infer them back out of font objects.
static NSString* const kSPDFDiagramTraitsAttribute = @"SPDFMarkdownDiagramLabelTraits";

// Pathological nesting keeps its outermost tags and draws the rest literally;
// the unmatched closers are then no-ops (a close tag matches by search).
static const NSUInteger kSPDFDiagramMaximumOpenTags = 64;

static SPDFDiagramLabelTraits SPDFDiagramTraitsForTag(NSString* name) {
    if ([name isEqualToString:@"b"] || [name isEqualToString:@"strong"]) return SPDFDiagramLabelTraitBold;
    if ([name isEqualToString:@"i"] || [name isEqualToString:@"em"]) return SPDFDiagramLabelTraitItalic;
    if ([name isEqualToString:@"u"] || [name isEqualToString:@"ins"]) return SPDFDiagramLabelTraitUnderline;
    if ([name isEqualToString:@"s"] || [name isEqualToString:@"strike"] || [name isEqualToString:@"del"])
        return SPDFDiagramLabelTraitStrikethrough;
    return 0;
}

NSFont* SPDFMarkdownDiagramEmphasizedFont(NSFont* font, BOOL bold, BOOL italic) {
    NSFont* result = font;
    if (bold) result = [NSFont systemFontOfSize:font.pointSize weight:NSFontWeightSemibold];
    if (italic) result = [NSFontManager.sharedFontManager convertFont:result toHaveTrait:NSItalicFontMask];
    return result ?: font;
}

static NSFont* SPDFDiagramTraitFont(NSFont* font, SPDFDiagramLabelTraits traits) {
    if (!traits) return font;
    return SPDFMarkdownDiagramEmphasizedFont(font, (traits & SPDFDiagramLabelTraitBold) != 0,
                                             (traits & SPDFDiagramLabelTraitItalic) != 0);
}

static SPDFDiagramLabelTraits SPDFDiagramOpenTraits(NSArray<NSNumber*>* open) {
    SPDFDiagramLabelTraits traits = 0;
    for (NSNumber* value in open) traits |= (SPDFDiagramLabelTraits)value.unsignedIntegerValue;
    return traits;
}

static void SPDFDiagramAppendSpan(NSMutableAttributedString* built, NSString* text, NSFont* font,
                                  SPDFDiagramLabelTraits traits) {
    if (!text.length) return;
    NSMutableDictionary* attributes =
        [@{NSFontAttributeName: SPDFDiagramTraitFont(font, traits)} mutableCopy];
    if (traits) attributes[kSPDFDiagramTraitsAttribute] = @(traits);
    [built appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:attributes]];
}

NSAttributedString* SPDFMarkdownDiagramAttributedLabel(NSString* text, NSFont* font) {
    NSDictionary* plain = @{NSFontAttributeName: font};
    // The overwhelmingly common label has no markup at all, and this runs once
    // per node per rung of the reflow ladder: leave that case untouched.
    if (!text.length || [text rangeOfString:@"<"].location == NSNotFound)
        return [[NSAttributedString alloc] initWithString:text ?: @"" attributes:plain];
    NSMutableAttributedString* built = [NSMutableAttributedString new];
    NSMutableArray<NSNumber*>* open = [NSMutableArray array];
    NSCharacterSet* letters = NSCharacterSet.alphanumericCharacterSet;
    NSUInteger length = text.length, cursor = 0, pending = 0;
    while (cursor < length) {
        if ([text characterAtIndex:cursor] != '<') {
            ++cursor;
            continue;
        }
        NSUInteger scan = cursor + 1;
        BOOL closing = scan < length && [text characterAtIndex:scan] == '/';
        if (closing) ++scan;
        NSUInteger nameStart = scan;
        while (scan < length && [letters characterIsMember:[text characterAtIndex:scan]]) ++scan;
        NSUInteger nameEnd = scan;
        // Tolerate `<b >` and the self-closing `<b/>` spelling, nothing more:
        // a tag carrying attributes is not one of ours and stays literal.
        while (scan < length &&
               ([text characterAtIndex:scan] == ' ' || [text characterAtIndex:scan] == '/'))
            ++scan;
        if (nameEnd == nameStart || scan >= length || [text characterAtIndex:scan] != '>') {
            ++cursor;
            continue;
        }
        NSString* name = [text substringWithRange:NSMakeRange(nameStart, nameEnd - nameStart)].lowercaseString;
        SPDFDiagramLabelTraits traits = SPDFDiagramTraitsForTag(name);
        if (!traits || (!closing && open.count >= kSPDFDiagramMaximumOpenTags)) {
            ++cursor;
            continue;
        }
        SPDFDiagramAppendSpan(built, [text substringWithRange:NSMakeRange(pending, cursor - pending)], font,
                              SPDFDiagramOpenTraits(open));
        if (!closing) {
            [open addObject:@(traits)];
        } else {
            // Close the innermost tag of the same kind, dropping whatever it
            // still had open: an unbalanced `</b>` can never unbold a label it
            // never opened, and `<b><i></b>` closes both rather than leaking.
            for (NSUInteger candidate = open.count; candidate > 0; --candidate) {
                if (![open[candidate - 1] isEqualToNumber:@(traits)]) continue;
                [open removeObjectsInRange:NSMakeRange(candidate - 1, open.count - candidate + 1)];
                break;
            }
        }
        cursor = scan + 1;
        pending = cursor;
    }
    SPDFDiagramAppendSpan(built, [text substringFromIndex:pending], font, SPDFDiagramOpenTraits(open));
    return built;
}

NSArray<SPDFMarkdownDiagramLabelSpan*>* SPDFMarkdownDiagramLabelSpans(NSAttributedString* line) {
    NSMutableArray<SPDFMarkdownDiagramLabelSpan*>* spans = [NSMutableArray array];
    [line enumerateAttribute:kSPDFDiagramTraitsAttribute
                     inRange:NSMakeRange(0, line.length)
                     options:0
                  usingBlock:^(NSNumber* value, NSRange range, BOOL* stop) {
                    (void)stop;
                    SPDFDiagramLabelTraits traits = (SPDFDiagramLabelTraits)value.unsignedIntegerValue;
                    if (!traits || !range.length) return;
                    SPDFMarkdownDiagramLabelSpan* span = [SPDFMarkdownDiagramLabelSpan new];
                    span.range = range;
                    span.bold = (traits & SPDFDiagramLabelTraitBold) != 0;
                    span.italic = (traits & SPDFDiagramLabelTraitItalic) != 0;
                    span.underline = (traits & SPDFDiagramLabelTraitUnderline) != 0;
                    span.strikethrough = (traits & SPDFDiagramLabelTraitStrikethrough) != 0;
                    [spans addObject:span];
                  }];
    return spans;
}

// --- Wrapping and measurement --------------------------------------------------

// A diagram label is always ONE line of canonical text at an explicit
// position, so wrapping is done here, up front, by the same CoreText
// typesetter the drawing pass uses — never by an implicit drawWithRect: pass.

static NSAttributedString* SPDFDiagramTrimmedLine(NSAttributedString* line) {
    NSCharacterSet* white = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    NSString* plain = line.string;
    NSUInteger start = 0, end = plain.length;
    while (start < end && [white characterIsMember:[plain characterAtIndex:start]]) ++start;
    while (end > start && [white characterIsMember:[plain characterAtIndex:end - 1]]) --end;
    return [line attributedSubstringFromRange:NSMakeRange(start, end - start)];
}

// One <br>-free segment, appended as one line per soft wrap. The segment is
// already attributed, so a wrap inside a `<b>` run splits the run with it and
// each line keeps the faces it is measured and drawn in.
static void SPDFDiagramAppendWrappedSegment(NSMutableArray<NSAttributedString*>* lines,
                                            NSAttributedString* text, CGFloat maximumWidth) {
    CTTypesetterRef typesetter =
        CTTypesetterCreateWithAttributedString((__bridge CFAttributedStringRef)text);
    if (!typesetter) {
        if (text.length) [lines addObject:text];
        return;
    }
    CFIndex start = 0;
    CFIndex length = (CFIndex)text.length;
    while (start < length) {
        CFIndex count = CTTypesetterSuggestLineBreak(typesetter, start, maximumWidth);
        if (count <= 0) count = length - start;  // a single glyph wider than the box
        NSAttributedString* line = SPDFDiagramTrimmedLine([text
            attributedSubstringFromRange:NSMakeRange((NSUInteger)start, (NSUInteger)count)]);
        if (line.length) [lines addObject:line];
        start += count;
    }
    CFRelease(typesetter);
}

NSArray<NSAttributedString*>* SPDFMarkdownDiagramWrapAttributedText(NSAttributedString* text,
                                                                    CGFloat maximumWidth) {
    if (!text.length) return @[];
    NSMutableArray<NSAttributedString*>* lines = [NSMutableArray array];
    // A `<br/>` in the source is a HARD break: each segment wraps on its own,
    // so an authored break is never undone by the soft wrapper.
    NSString* plain = text.string;
    NSUInteger start = 0;
    while (start <= plain.length) {
        NSRange search = NSMakeRange(start, plain.length - start);
        NSRange split = [plain rangeOfString:@"\n" options:0 range:search];
        NSUInteger end = split.location == NSNotFound ? plain.length : split.location;
        NSAttributedString* segment = [text attributedSubstringFromRange:NSMakeRange(start, end - start)];
        if (maximumWidth <= 0) {
            [lines addObject:segment];
        } else {
            SPDFDiagramAppendWrappedSegment(lines, segment, maximumWidth);
        }
        if (split.location == NSNotFound) break;
        start = NSMaxRange(split);
    }
    return lines.count ? lines : @[ text ];
}

NSArray<NSString*>* SPDFMarkdownDiagramWrapText(NSString* text, NSFont* font, CGFloat maximumWidth) {
    if (!text.length) return @[];
    NSMutableArray<NSString*>* lines = [NSMutableArray array];
    for (NSAttributedString* line in SPDFMarkdownDiagramWrapAttributedText(
             SPDFMarkdownDiagramAttributedLabel(text, font), maximumWidth))
        [lines addObject:line.string];
    return lines;
}

CGFloat SPDFMarkdownDiagramLineHeight(NSFont* font) {
    return ceil(font.ascender - font.descender + font.leading);
}

// The box a wrapped string occupies: the widest line by the widest line's
// typographic width, and one line height per wrapped line — exactly what the
// emitted labels will take up.
NSSize SPDFMarkdownDiagramMeasureText(NSString* text, NSFont* font, CGFloat maximumWidth) {
    if (!text.length) return NSZeroSize;
    NSArray<NSAttributedString*>* lines = SPDFMarkdownDiagramWrapAttributedText(
        SPDFMarkdownDiagramAttributedLabel(text, font), maximumWidth);
    CGFloat width = 0;
    for (NSAttributedString* line in lines) width = MAX(width, line.size.width);
    return NSMakeSize(ceil(width), ceil(lines.count * SPDFMarkdownDiagramLineHeight(font)));
}
