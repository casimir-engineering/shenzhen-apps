#import "SPDFMacChatMarkdownParts.h"
#import "SPDFMacCollectionStyle.h"

#import "markdown/SPDFMarkdownDiagram.h"
#import "markdown/SPDFMarkdownMathTypesetter.h"
#import "markdown/SPDFMarkdownResources.h"

// The pipeline: parse with the engine's budgets; walk the blocks, taking out what a text view cannot draw (tables,
// code, diagrams, rules, remote images) and leaving an unguessable token where each goes; render the rest with
// the engine at chat scale; then swap each token for its attachment. The tokens keep the engine's own paragraph
// styles, so a table inside a list item sits at the item's indent. One clock (SPDFMacChatMarkdownBudget.mm) runs from
// before parsing: blocks are drawn while it allows, and the walk hands what it has not reached to one plain-text
// token, so the engine's part after the walk stays small.

// Longer messages show their first 128 KB: the Friends protocol caps a message at 32 KiB, and an assistant reply
// past this is not read in a chat bubble.
static const NSUInteger kMaximumCharacters = 128 * 1024;
// The engine indents nested blocks 22 pt per level (SPDFMarkdownBlockRenderer.mm).
static const CGFloat kDepthIndent = 22;
// The engine links only http, https and mailto; a document or Friends citation travels under an https alias.
static NSString* const kAliasPrefix = @"https://spdf-chat.invalid/";

@implementation SPDFMacChatMarkdownOptions
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _width = 320;
    _keepsWideBlocks = YES;
    self.dark = NO;
    return self;
}
// The reader's chrome palette (SPDFMacCollectionStyle.mm "text", "secondary", "accent"), as concrete sRGB: the
// engine bakes colours into the text it lays out.
static NSColor* RGB(unsigned value) {
    return [NSColor colorWithSRGBRed:((value >> 16) & 0xff) / 255.0 green:((value >> 8) & 0xff) / 255.0
                                blue:(value & 0xff) / 255.0 alpha:1];
}
- (void)setDark:(BOOL)dark {
    _dark = dark;
    unsigned text = 0, secondary = 0, link = 0;
    SPDFChromeHex(@"text", dark, &text); SPDFChromeHex(@"secondary", dark, &secondary); SPDFChromeHex(@"accent", dark, &link);
    self.textColor = RGB(text);
    self.secondaryTextColor = RGB(secondary);
    self.linkColor = RGB(link);
}
- (id)copyWithZone:(NSZone*)zone {
    SPDFMacChatMarkdownOptions* copy = [[SPDFMacChatMarkdownOptions allocWithZone:zone] init];
    copy.width = _width;
    copy.dark = _dark;
    copy.links = _links;
    copy.keepsWideBlocks = _keepsWideBlocks;
    copy.textColor = _textColor;
    copy.secondaryTextColor = _secondaryTextColor;
    copy.linkColor = _linkColor;
    copy.messageKey = _messageKey;
    copy.fetchImage = _fetchImage;
    copy.imageFinished = _imageFinished;
    copy.linkHandler = _linkHandler;
    copy.openLink = _openLink;
    copy.pasteboard = _pasteboard;
    copy.bareLink = _bareLink;
    copy.diagramCache = _diagramCache;
    copy.allowance = _allowance;  // shared, not copied: renders spend from the same one
    return copy;
}
@end

BOOL SPDFMacChatMarkdownLinkAllowed(NSURL* URL, SPDFMacChatMarkdownLinks links) {
    NSString* scheme = URL.scheme.lowercaseString;
    BOOL credentialFree = URL.host.length && !URL.user.length && !URL.password.length;
    BOOL web = [scheme isEqualToString:@"https"] && credentialFree;
    if (links == SPDFMacChatMarkdownLinksFriends) return web;
    return web || ([scheme isEqualToString:@"http"] && credentialFree) ||
           ([scheme isEqualToString:@"spdf-ai"] &&
            ([URL.host isEqualToString:@"document"] || [URL.host isEqualToString:@"web-document"])) ||
           ([scheme isEqualToString:@"shenzhenpdf-friends"] && [URL.host isEqualToString:@"message"]);
}

@interface SPDFMacChatWalk : NSObject
@property(nonatomic, strong) SPDFMacChatMarkdownOptions* options;
@property(nonatomic, strong) SPDFMarkdownDiagramCache* cache;
// The render's clock: blocks are drawn before clock.drawUntil, shown as text after it (SPDFMacChatMarkdownBudget.mm).
@property(nonatomic) SPDFMacChatClock clock;
@property(nonatomic) BOOL notedAsText;
@property(nonatomic, copy) NSString* nonce;
@property(nonatomic) NSUInteger count;
@property(nonatomic, strong) NSMutableDictionary<NSString*, NSAttributedString*>* replacements;
// The engine links only http, https and mailto; a document or Friends citation travels under an https alias.
@property(nonatomic, strong) NSMutableDictionary<NSString*, NSURL*>* aliases;
// Formulas copy as their LaTeX: inline ones by marker, display ones in order of appearance.
@property(nonatomic, strong) NSMutableDictionary<NSString*, NSString*>* inlineMath;
@property(nonatomic, strong) NSMutableArray<NSString*>* displayMath;
@end
@implementation SPDFMacChatWalk
@end

static NSString* Token(SPDFMacChatWalk* walk, NSAttributedString* replacement) {
    NSString* token = [NSString stringWithFormat:@"\uE000%@%lu\uE001", walk.nonce, (unsigned long)walk.count++];
    walk.replacements[token] = replacement;
    return token;
}

SPDFMarkdownBlock* SPDFMacChatRebuiltBlock(SPDFMarkdownBlock* block, NSArray<SPDFMarkdownInlineRun*>* runs,
                                           NSArray<SPDFMarkdownBlock*>* children) {
    return [[SPDFMarkdownBlock alloc] initWithKind:block.kind blockIndex:block.blockIndex level:block.level
                                      orderedStart:block.orderedStart taskState:block.taskState
                                    tableAlignment:block.tableAlignment blockAlignment:block.blockAlignment
                                  tableColumnCount:block.tableColumnCount runs:runs children:children
                                      codeLanguage:block.codeLanguage codeInfo:block.codeInfo
                                       calloutKind:block.calloutKind calloutTitle:block.calloutTitle];
}

static SPDFMarkdownBlock* TokenParagraph(SPDFMarkdownBlock* original, NSString* token) {
    SPDFMarkdownInlineRun* run = [[SPDFMarkdownInlineRun alloc] initWithText:token traits:0 destination:nil];
    return [[SPDFMarkdownBlock alloc] initWithKind:SPDFMarkdownBlockKindParagraph blockIndex:original.blockIndex
                                             level:0 orderedStart:0 taskState:-1
                                    tableAlignment:SPDFMarkdownTableAlignmentDefault
                                    blockAlignment:SPDFMarkdownTableAlignmentDefault tableColumnCount:0
                                              runs:@[ run ] children:@[] codeLanguage:nil codeInfo:nil
                                       calloutKind:nil calloutTitle:nil];
}

// Links kept only where the policy allows; wikilinks become text; images become a placeholder or, where a
// placeholder cannot be clicked (inside a drawn table), their alt text.
static NSArray<SPDFMarkdownInlineRun*>* SafeRuns(NSArray<SPDFMarkdownInlineRun*>* runs, CGFloat column,
                                                 SPDFMacChatWalk* walk, BOOL drawn) {
    NSMutableArray* safe = [NSMutableArray arrayWithCapacity:runs.count];
    for (SPDFMarkdownInlineRun* run in runs) {
        SPDFMarkdownInlineTraits traits = run.traits & ~SPDFMarkdownInlineTraitWikiLink;
        NSString* destination = run.destination;
        if (traits & SPDFMarkdownInlineTraitImage) {
            NSString* key = SPDFMarkdownRemoteImageKeyForTarget(destination ?: @"");
            NSURL* URL = key ? [NSURL URLWithString:key] : nil;
            NSString* alt = run.text.length ? [NSString stringWithFormat:@"[Image: %@]", run.text] : @"[Image]";
            NSString* text =
                URL && !drawn ? Token(walk, SPDFMacChatImageAttachment(URL, run.text, column, walk.options)) : alt;
            [safe addObject:[[SPDFMarkdownInlineRun alloc] initWithText:text traits:0 destination:nil]];
            continue;
        }
        if ((traits & SPDFMarkdownInlineTraitMath) && !drawn) {
            if (traits & SPDFMarkdownInlineTraitDisplayMath) {
                [walk.displayMath addObject:[NSString stringWithFormat:@"$$%@$$", run.text]];
                [safe addObject:run];
                continue;
            }
            // Text markers around the formula find its typeset range after rendering; they are removed then. A
            // display formula is its own paragraph, where a marker would leave an empty line behind.
            NSString* key = [NSString stringWithFormat:@"%@%lu", walk.nonce, (unsigned long)walk.count++];
            walk.inlineMath[key] = [NSString stringWithFormat:@"$%@$", run.text];
            NSString* open = [NSString stringWithFormat:@"\uE002%@\uE003", key];
            [safe addObject:[[SPDFMarkdownInlineRun alloc] initWithText:open traits:0 destination:nil]];
            [safe addObject:run];
            [safe addObject:[[SPDFMarkdownInlineRun alloc] initWithText:@"\uE004" traits:0 destination:nil]];
            continue;
        }
        if (traits & SPDFMarkdownInlineTraitLink) {
            NSURL* URL = [NSURL URLWithString:destination ?: @""];
            if (!URL.scheme.length && destination.length && walk.options.bareLink) {
                URL = walk.options.bareLink(destination);
                destination = URL.absoluteString;
            }
            NSString* scheme = URL.scheme.lowercaseString;
            if (!SPDFMacChatMarkdownLinkAllowed(URL, walk.options.links)) {
                traits &= ~SPDFMarkdownInlineTraitLink;
                destination = nil;
            } else if (![scheme isEqualToString:@"https"] && ![scheme isEqualToString:@"http"]) {
                destination = [kAliasPrefix stringByAppendingString:NSUUID.UUID.UUIDString];
                walk.aliases[destination] = URL;
            }
        }
        [safe addObject:[[SPDFMarkdownInlineRun alloc] initWithText:run.text ?: @"" traits:traits
                                                        destination:destination]];
    }
    return safe;
}

static SPDFMarkdownBlock* SafeTable(SPDFMarkdownBlock* block, SPDFMacChatWalk* walk) {
    NSMutableArray* children = [NSMutableArray arrayWithCapacity:block.children.count];
    for (SPDFMarkdownBlock* child in block.children) [children addObject:SafeTable(child, walk)];
    return SPDFMacChatRebuiltBlock(block, SafeRuns(block.runs, 0, walk, YES), children);
}

static BOOL Drawing(SPDFMacChatWalk* walk) { return SPDFMacChatNow() < walk.clock.drawUntil; }

static NSAttributedString* Drawn(SPDFMarkdownBlock* block, SPDFMacChatBlockKind kind, CGFloat column,
                                 SPDFMacChatWalk* walk) {
    NSString* key = SPDFMacChatBlockKey(block, kind, column, walk.options);
    SPDFMacChatBlock* laid = SPDFMacChatKeptBlock(key);
    if (!laid) {
        NSTimeInterval left = walk.clock.drawUntil - SPDFMacChatNow();
        laid = SPDFMacChatLayOutBlock(block, kind, column, walk.options, walk.cache, &left);
        if (!laid) return nil;
        laid.aliases = walk.aliases;
        // A citation's alias is new each render, so a block holding one would never be asked for again.
        if (![key containsString:kAliasPrefix]) SPDFMacChatKeepBlock(key, laid);
    }
    CGFloat scale = walk.options.keepsWideBlocks ? 1 : MIN(1, MAX(40, column) / NSWidth(laid.contentRect));
    return SPDFMacChatBlockAttachment(laid, scale, walk.options);
}

// Past the message's layout time every later table, code block and diagram is text; the first one says why.
static NSString* TextToken(SPDFMacChatWalk* walk, NSString* shown, NSString* copied) {
    NSString* note = walk.notedAsText ? nil
                                      : @"This message is large, so from here on its tables, code and diagrams "
                                         "appear as plain text.";
    walk.notedAsText = YES;
    return Token(walk, SPDFMacChatTextBlock(shown, copied, note, walk.options));
}

static SPDFMarkdownBlock* WalkTable(SPDFMarkdownBlock* block, CGFloat column, SPDFMacChatWalk* walk) {
    if (!Drawing(walk)) {
        NSString* whole = SPDFMacChatTableSource(SafeTable(block, walk));
        return TokenParagraph(block, TextToken(walk, whole, whole));
    }
    NSUInteger rows = 0;
    NSString* rest = nil;
    SPDFMarkdownBlock* safe = SafeTable(SPDFMacChatCapTable(block, &rows, &rest), walk);
    NSAttributedString* drawn = Drawn(safe, SPDFMacChatBlockTable, column, walk);
    if (!drawn) return safe;
    if (!rest) return TokenParagraph(block, Token(walk, drawn));
    // The rows past the cap follow the drawn ones as text; copying the two gives the whole table's Markdown.
    NSMutableAttributedString* both = [drawn mutableCopy];
    [both appendAttributedString:[[NSAttributedString alloc] initWithString:@"\u2028" attributes:@{
              SPDFMacChatMarkdownSourceAttribute : @"\n"}]];
    NSString* note = [NSString stringWithFormat:@"Only the first %lu rows are shown as a table; the rest follow as "
                                                 "text.", (unsigned long)rows];
    [both appendAttributedString:SPDFMacChatTextBlock(rest, rest, note, walk.options)];
    return TokenParagraph(block, Token(walk, both));
}

static SPDFMarkdownBlock* WalkCode(SPDFMarkdownBlock* block, CGFloat column, SPDFMacChatWalk* walk) {
    BOOL diagram = SPDFMarkdownDiagramIsDiagramLanguage(block.codeLanguage);
    if (diagram && Drawing(walk)) {
        NSMutableAttributedString* drawn = [Drawn(block, SPDFMacChatBlockDiagram, column, walk) mutableCopy];
        [drawn addAttribute:SPDFMacChatTightBlockAttribute value:@YES range:NSMakeRange(0, drawn.length)];
        if (drawn) return TokenParagraph(block, Token(walk, drawn));
    }
    // A diagram the engine cannot draw shows its source as code.
    if (Drawing(walk)) {
        NSAttributedString* drawn = Drawn(block, SPDFMacChatBlockCode, column, walk);
        return drawn ? TokenParagraph(block, Token(walk, drawn)) : block;
    }
    NSString* code = [block.plainText stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet] ?: @"";
    NSString* copied = diagram ? [NSString stringWithFormat:@"```%@\n%@\n```", block.codeLanguage, code] : code;
    return TokenParagraph(block, TextToken(walk, code, copied));
}

static SPDFMarkdownBlock* Walk(SPDFMarkdownBlock* block, NSUInteger depth, SPDFMacChatWalk* walk) {
    CGFloat column = walk.options.width - depth * kDepthIndent;
    switch (block.kind) {
        case SPDFMarkdownBlockKindPageBreak:
            return nil;
        case SPDFMarkdownBlockKindThematicBreak:
            return TokenParagraph(block, Token(walk, SPDFMacChatRuleAttachment(column, walk.options)));
        case SPDFMarkdownBlockKindTable:
            return WalkTable(block, column, walk);
        case SPDFMarkdownBlockKindCode:
            return WalkCode(block, column, walk);
        default:
            break;
    }
    // The renderer's depths: a list item's own text sits at the list's depth, its blocks one deeper, as are a
    // quote's and a callout's.
    BOOL container = block.kind == SPDFMarkdownBlockKindBlockQuote || block.kind == SPDFMarkdownBlockKindCallout ||
                     block.kind == SPDFMarkdownBlockKindListItem;
    BOOL list = block.kind == SPDFMarkdownBlockKindUnorderedList || block.kind == SPDFMarkdownBlockKindOrderedList;
    NSMutableArray* children = [NSMutableArray arrayWithCapacity:block.children.count];
    for (SPDFMarkdownBlock* child in block.children) {
        SPDFMarkdownBlock* walked = Walk(child, list ? depth : container ? depth + 1 : depth, walk);
        if (walked) [children addObject:walked];
    }
    // A list item's text starts after its marker, about one indent in.
    CGFloat textColumn = column - (block.kind == SPDFMarkdownBlockKindListItem ? kDepthIndent : 0);
    return SPDFMacChatRebuiltBlock(block, SafeRuns(block.runs, textColumn, walk, NO), children);
}

// Aliased citations get their own URL back; every web link shows where it goes when the pointer rests on it.
static void ChatLinks(NSMutableAttributedString* text, SPDFMacChatWalk* walk) {
    [text enumerateAttribute:NSLinkAttributeName inRange:NSMakeRange(0, text.length) options:0
                  usingBlock:^(id value, NSRange range, BOOL* stop) {
                    (void)stop;
                    if (!value) return;
                    NSURL* URL = [value isKindOfClass:NSURL.class] ? value : [NSURL URLWithString:[value description]];
                    NSURL* original = walk.aliases[URL.absoluteString];
                    if (original) URL = original;
                    if (!SPDFMacChatMarkdownLinkAllowed(URL, walk.options.links)) {
                        [text removeAttribute:NSLinkAttributeName range:range];
                        return;
                    }
                    [text addAttribute:NSLinkAttributeName value:URL range:range];
                    if (!original) [text addAttribute:NSToolTipAttributeName value:URL.absoluteString range:range];
                    else [text removeAttribute:NSToolTipAttributeName range:range];
                  }];
}

// Each display formula's paragraph, in order, copies as the formula's LaTeX.
static void MarkDisplayMath(NSMutableAttributedString* text, SPDFMacChatWalk* walk) {
    NSMutableArray<NSValue*>* paragraphs = [NSMutableArray array];
    [text enumerateAttribute:SPDFMarkdownMathLayoutAttribute inRange:NSMakeRange(0, text.length) options:0
                  usingBlock:^(id role, NSRange range, BOOL* stop) {
                    (void)stop;
                    if (!role) return;
                    NSStringEnumerationOptions each = NSStringEnumerationByParagraphs;
                    [text.string enumerateSubstringsInRange:range options:each
                                                 usingBlock:^(NSString* part, NSRange inner, NSRange whole, BOOL* end) {
                                                   (void)whole, (void)end;
                                                   if (!part.length) return;
                                                   [paragraphs addObject:[NSValue valueWithRange:inner]];
                                                 }];
                  }];
    // A count that does not match (a formula the typesetter dropped) marks nothing rather than the wrong formula.
    if (paragraphs.count != walk.displayMath.count) return;
    for (NSUInteger index = 0; index < paragraphs.count; index++)
        [text addAttribute:SPDFMacChatMarkdownSourceAttribute value:walk.displayMath[index]
                     range:paragraphs[index].rangeValue];
}

static void MarkInlineMath(NSMutableAttributedString* text, SPDFMacChatWalk* walk) {
    NSString* string = text.string;
    NSUInteger end = string.length;
    while (end > 0) {
        NSRange open = [string rangeOfString:@"\uE002" options:NSBackwardsSearch range:NSMakeRange(0, end)];
        if (open.location == NSNotFound) break;
        end = open.location;
        NSRange rest = NSMakeRange(NSMaxRange(open), string.length - NSMaxRange(open));
        NSRange keyEnd = [string rangeOfString:@"\uE003" options:0 range:rest];
        NSRange close = keyEnd.location == NSNotFound ? keyEnd
            : [string rangeOfString:@"\uE004" options:0
                              range:NSMakeRange(NSMaxRange(keyEnd), string.length - NSMaxRange(keyEnd))];
        if (close.location == NSNotFound) continue;
        NSString* key = [string substringWithRange:NSMakeRange(NSMaxRange(open), keyEnd.location - NSMaxRange(open))];
        NSString* source = walk.inlineMath[key];
        if (!source) continue;
        [text deleteCharactersInRange:close];
        NSRange formula = NSMakeRange(NSMaxRange(keyEnd), close.location - NSMaxRange(keyEnd));
        [text addAttribute:SPDFMacChatMarkdownSourceAttribute value:source range:formula];
        [text deleteCharactersInRange:NSMakeRange(open.location, NSMaxRange(keyEnd) - open.location)];
    }
}

// One pass: a message of 8,000 small tables spent 0.1 s here when each token was replaced in place.
static NSMutableAttributedString* ReplaceTokens(NSMutableAttributedString* text, SPDFMacChatWalk* walk) {
    NSString* string = text.string;
    NSMutableAttributedString* result = [NSMutableAttributedString new];
    NSUInteger copied = 0, length = string.length;
    while (copied < length) {
        NSRange open = [string rangeOfString:@"\uE000" options:NSLiteralSearch
                                       range:NSMakeRange(copied, length - copied)];
        NSRange close = open.location == NSNotFound ? open
            : [string rangeOfString:@"\uE001" options:NSLiteralSearch
                              range:NSMakeRange(NSMaxRange(open), length - NSMaxRange(open))];
        NSRange token = close.location == NSNotFound ? NSMakeRange(length, 0)
                                                     : NSMakeRange(open.location, NSMaxRange(close) - open.location);
        NSAttributedString* replacement = token.length ? walk.replacements[[string substringWithRange:token]] : nil;
        // Text up to the token, or through it when it is not one of this render's (a message may contain the marks).
        NSUInteger stop = replacement ? token.location : token.length ? NSMaxRange(token) : length;
        if (stop > copied)
            [result appendAttributedString:[text attributedSubstringFromRange:NSMakeRange(copied, stop - copied)]];
        copied = stop;
        if (!replacement) continue;
        NSMutableAttributedString* placed = [replacement mutableCopy];
        NSParagraphStyle* style = [text attribute:NSParagraphStyleAttributeName atIndex:token.location
                                   effectiveRange:NULL];
        if (style) [placed addAttribute:NSParagraphStyleAttributeName value:style range:NSMakeRange(0, placed.length)];
        [result appendAttributedString:placed];
        copied = NSMaxRange(token);
    }
    return result;
}

static NSAttributedString* PlainText(NSString* text, SPDFMacChatMarkdownOptions* options) {
    return [[NSAttributedString alloc] initWithString:text ?: @"" attributes:@{
        NSFontAttributeName : [NSFont systemFontOfSize:13], NSForegroundColorAttributeName : options.textColor}];
}

// The parsed blocks, walked while the clock allows; past clock.walkUntil the rest is plain text. nil when the walk
// could not take even the first block (the whole message is then plain text).
static NSArray<SPDFMarkdownBlock*>* WalkBlocks(NSArray<SPDFMarkdownBlock*>* parsed, SPDFMacChatWalk* walk) {
    NSMutableArray* blocks = [NSMutableArray arrayWithCapacity:parsed.count];
    NSUInteger index = 0;
    for (; index < parsed.count && SPDFMacChatNow() < walk.clock.walkUntil; index++) {
        SPDFMarkdownBlock* walked = Walk(parsed[index], 0, walk);
        if (walked) [blocks addObject:walked];
    }
    if (index == parsed.count) return blocks;
    if (index == 0) return nil;
    NSString* note = walk.notedAsText ? nil : @"This message is large, so from here on it appears as plain text.";
    NSArray* rest = [parsed subarrayWithRange:NSMakeRange(index, parsed.count - index)];
    [blocks addObject:TokenParagraph(parsed[index], Token(walk, SPDFMacChatPlainRest(rest, note, walk.options)))];
    return blocks;
}

static NSAttributedString* Render(NSString* markdown, SPDFMacChatMarkdownOptions* given, SPDFMacChatClock clock) {
    SPDFMacChatMarkdownOptions* options = [given copy];
    options.width = MAX(120, floor(options.width));
    if (!options.messageKey) options.messageKey = markdown ?: @"";
    NSString* text = markdown ?: @"";
    if (text.length > kMaximumCharacters) {
        NSRange cut = [text rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, kMaximumCharacters)];
        text = [[text substringWithRange:cut]
            stringByAppendingString:@"\n\n*Only the start of this message is shown.*"];
    }
    // Nothing left of a shared allowance: the message's own words, at once.
    if (clock.budget <= 0) return PlainText(text, options);
    SPDFMarkdownParser* parser = [SPDFMarkdownParser new];
    parser.maximumInputBytes = 512 * 1024;
    SPDFMarkdownDocumentModel* parsed = [parser parseString:text sourceURL:nil error:nil];
    if (!parsed) return PlainText(text, options);
    SPDFMacChatWalk* walk = [SPDFMacChatWalk new];
    walk.options = options;
    walk.cache = options.diagramCache ?: [SPDFMarkdownDiagramCache new];
    walk.clock = clock;
    walk.nonce = [NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""];
    walk.replacements = [NSMutableDictionary dictionary];
    walk.aliases = [NSMutableDictionary dictionary];
    walk.inlineMath = [NSMutableDictionary dictionary];
    walk.displayMath = [NSMutableArray array];
    NSArray<SPDFMarkdownBlock*>* blocks = WalkBlocks(parsed.blocks, walk);
    if (!blocks) return PlainText(text, options);
    SPDFMarkdownDocumentModel* model = [[SPDFMarkdownDocumentModel alloc] initWithSourceURL:nil frontMatter:@{}
                                                                             rawFrontMatter:nil blocks:blocks];
    SPDFMarkdownRenderOptions* render = SPDFMacChatRenderOptions(options);
    render.pageContentSize = NSMakeSize(options.width, 0);
    SPDFMarkdownRenderedDocument* rendered = [[SPDFMarkdownRenderer new] renderModel:model options:render
                                                                    languageOverrides:nil];
    if (!rendered) return PlainText(text, options);
    NSMutableAttributedString* result = [rendered.attributedString mutableCopy];
    SPDFMacChatScaleText(result, rendered);
    MarkDisplayMath(result, walk);
    ChatLinks(result, walk);
    MarkInlineMath(result, walk);
    result = ReplaceTokens(result, walk);
    SPDFMacChatSpaceBlocks(result);
    // Blocks end with a newline; the bubble already owns the space after a message.
    while (result.length &&
           [NSCharacterSet.newlineCharacterSet characterIsMember:[result.string characterAtIndex:result.length - 1]])
        [result deleteCharactersInRange:NSMakeRange(result.length - 1, 1)];
    return result;
}

NSAttributedString* SPDFMacChatMarkdownRender(NSString* markdown, SPDFMacChatMarkdownOptions* options) {
    SPDFMacChatClock clock = SPDFMacChatStartClock(options.allowance);
    NSAttributedString* result = Render(markdown, options, clock);
    SPDFMacChatStopClock(clock, options.allowance);
    return result;
}
