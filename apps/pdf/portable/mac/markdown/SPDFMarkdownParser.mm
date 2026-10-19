#import "SPDFMarkdownParser.h"
#import "SPDFTextDocumentParser.h"
#import "SPDFMarkdownHTML.h"
#import "SPDFMarkdownParserInternal.h"
#include "../../../ext/md4c/md4c.h"
NSErrorDomain const SPDFMarkdownErrorDomain = @"com.intuition.shenzhenpdf.markdown";
@implementation SPDFMarkdownBlockBuilder
- (instancetype)init {
    self = [super init];
    if (self) {
        _orderedStart = 1;
        _taskState = -1;
        _runs = [NSMutableArray array];
        _children = [NSMutableArray array];
    }
    return self;
}
@end
@interface SPDFMarkdownSpanFrame : NSObject
@property(nonatomic) SPDFMarkdownInlineTraits previousTraits;
@property(nonatomic, copy, nullable) NSString* previousDestination;
@property(nonatomic, copy, nullable) NSString* previousTitle;
@property(nonatomic, weak) SPDFMarkdownBlockBuilder* block;
@property(nonatomic) NSUInteger firstRun;
@property(nonatomic, copy, nullable) NSString* wikiAlias;
@end
@implementation SPDFMarkdownSpanFrame
@end
@interface SPDFMarkdownParseContext : NSObject
@property(nonatomic) SPDFMarkdownBlockBuilder* root;
@property(nonatomic) NSMutableArray<SPDFMarkdownBlockBuilder*>* stack;
@property(nonatomic) NSMutableArray<SPDFMarkdownSpanFrame*>* spans;
@property(nonatomic) SPDFMarkdownInlineTraits traits;
@property(nonatomic, copy, nullable) NSString* destination;
@property(nonatomic, copy, nullable) NSString* title;
@property(nonatomic) NSUInteger nextIndex;
@property(nonatomic) NSUInteger nodeCount;
@property(nonatomic) NSUInteger maximumNodeCount;
@property(nonatomic) NSUInteger maximumNestingDepth;
@property(nonatomic) SPDFMarkdownHTMLState* html;
@property(nonatomic) SPDFMarkdownErrorCode failureCode;
@property(nonatomic, copy, nullable) NSString* debugMessage;
@end
@implementation SPDFMarkdownParseContext
- (instancetype)init {
    self = [super init];
    if (self) {
        _root = [SPDFMarkdownBlockBuilder new];
        _root.kind = SPDFMarkdownBlockKindDocument;
        _stack = [NSMutableArray arrayWithObject:_root];
        _spans = [NSMutableArray array];
        _html = [SPDFMarkdownHTMLState new];
        _nextIndex = 1;
    }
    return self;
}
@end
static NSString* SPDFString(const char* bytes, NSUInteger length) {
    if (!bytes || length == 0) return @"";
    NSString* value = [[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding];
    return value ?: @"\uFFFD";
}

static NSString* SPDFAttributeString(MD_ATTRIBUTE attribute) {
    return SPDFString(attribute.text, attribute.size);
}

static SPDFMarkdownBlockKind SPDFBlockKind(MD_BLOCKTYPE type) {
    switch (type) {
        case MD_BLOCK_DOC: return SPDFMarkdownBlockKindDocument;
        case MD_BLOCK_QUOTE: return SPDFMarkdownBlockKindBlockQuote;
        case MD_BLOCK_UL: return SPDFMarkdownBlockKindUnorderedList;
        case MD_BLOCK_OL: return SPDFMarkdownBlockKindOrderedList;
        case MD_BLOCK_LI: return SPDFMarkdownBlockKindListItem;
        case MD_BLOCK_HR: return SPDFMarkdownBlockKindThematicBreak;
        case MD_BLOCK_H: return SPDFMarkdownBlockKindHeading;
        case MD_BLOCK_CODE: return SPDFMarkdownBlockKindCode;
        case MD_BLOCK_P: return SPDFMarkdownBlockKindParagraph;
        case MD_BLOCK_TABLE: return SPDFMarkdownBlockKindTable;
        case MD_BLOCK_THEAD: return SPDFMarkdownBlockKindTableHead;
        case MD_BLOCK_TBODY: return SPDFMarkdownBlockKindTableBody;
        case MD_BLOCK_TR: return SPDFMarkdownBlockKindTableRow;
        case MD_BLOCK_TH: return SPDFMarkdownBlockKindTableHeaderCell;
        case MD_BLOCK_TD: return SPDFMarkdownBlockKindTableCell;
        case MD_BLOCK_HTML: return SPDFMarkdownBlockKindParagraph;
    }
    return SPDFMarkdownBlockKindParagraph;
}

static SPDFMarkdownTableAlignment SPDFTableAlignment(MD_ALIGN alignment) {
    switch (alignment) {
        case MD_ALIGN_LEFT: return SPDFMarkdownTableAlignmentLeft;
        case MD_ALIGN_CENTER: return SPDFMarkdownTableAlignmentCenter;
        case MD_ALIGN_RIGHT: return SPDFMarkdownTableAlignmentRight;
        default: return SPDFMarkdownTableAlignmentDefault;
    }
}

static int SPDFFailBudget(SPDFMarkdownParseContext* context, NSString* message) {
    context.failureCode = SPDFMarkdownErrorBudgetExceeded;
    context.debugMessage = message;
    return 1;
}

static int SPDFEnterBlock(MD_BLOCKTYPE type, void* detail, void* opaque) {
    SPDFMarkdownParseContext* context = (__bridge SPDFMarkdownParseContext*)opaque;
    if (type == MD_BLOCK_DOC) return 0;
    if (++context.nodeCount > context.maximumNodeCount)
        return SPDFFailBudget(context, @"Markdown contains too many structural nodes.");
    if (context.stack.count >= context.maximumNestingDepth)
        return SPDFFailBudget(context, @"Markdown nesting is too deep.");
    SPDFMarkdownBlockBuilder* block = [SPDFMarkdownBlockBuilder new];
    block.kind = SPDFBlockKind(type);
    block.index = context.nextIndex++;
    if (type == MD_BLOCK_H) block.level = ((MD_BLOCK_H_DETAIL*)detail)->level;
    if (type == MD_BLOCK_OL) block.orderedStart = ((MD_BLOCK_OL_DETAIL*)detail)->start;
    if (type == MD_BLOCK_LI) {
        MD_BLOCK_LI_DETAIL* list = (MD_BLOCK_LI_DETAIL*)detail;
        if (list->is_task) block.taskState = list->task_mark == ' ' ? 0 : 1;
    }
    if (type == MD_BLOCK_CODE) {
        MD_BLOCK_CODE_DETAIL* code = (MD_BLOCK_CODE_DETAIL*)detail;
        NSString* language = SPDFAttributeString(code->lang);
        NSString* info = SPDFAttributeString(code->info);
        block.codeLanguage = language.length ? language.lowercaseString : nil;
        block.codeInfo = info.length ? info : nil;
    }
    if (type == MD_BLOCK_TABLE) block.tableColumnCount = ((MD_BLOCK_TABLE_DETAIL*)detail)->col_count;
    if (type == MD_BLOCK_TH || type == MD_BLOCK_TD)
        block.tableAlignment = SPDFTableAlignment(((MD_BLOCK_TD_DETAIL*)detail)->align);
    if (type == MD_BLOCK_HTML) {
        // A raw HTML island: accumulate its text and translate it through the
        // sanitizing whitelist when the island closes (SPDFLeaveBlock).
        block.htmlIsland = YES;
        block.htmlText = [NSMutableString string];
    }
    [context.html resetInlineState];
    if ((type == MD_BLOCK_P || type == MD_BLOCK_H) &&
        context.html.currentAlignment != SPDFMarkdownTableAlignmentDefault)
        block.blockAlignment = context.html.currentAlignment;
    [context.stack.lastObject.children addObject:block];
    [context.stack addObject:block];
    return 0;
}

static int SPDFLeaveBlock(MD_BLOCKTYPE type, void* detail, void* opaque) {
    (void)detail;
    SPDFMarkdownParseContext* context = (__bridge SPDFMarkdownParseContext*)opaque;
    if (type == MD_BLOCK_DOC || context.stack.count <= 1) return 0;
    SPDFMarkdownBlockBuilder* block = context.stack.lastObject;
    [context.stack removeLastObject];
    if (type != MD_BLOCK_HTML || !block.htmlIsland) return 0;
    // A standalone directive stays structural; fenced/inline examples do not.
    if ([[block.htmlText stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
            isEqualToString:@"<!-- pagebreak -->"]) {
        block.kind = SPDFMarkdownBlockKindPageBreak;
        return 0;
    }
    [context.stack.lastObject.children removeObjectIdenticalTo:block];
    NSUInteger nextIndex = context.nextIndex;
    NSUInteger nodeCount = context.nodeCount;
    NSArray<SPDFMarkdownBlockBuilder*>* replacements =
        SPDFMarkdownHTMLProcessBlockIsland(context.html, block.htmlText ?: @"", &nextIndex, &nodeCount);
    context.nextIndex = nextIndex;
    context.nodeCount = nodeCount;
    if (context.nodeCount > context.maximumNodeCount)
        return SPDFFailBudget(context, @"Markdown contains too many structural nodes.");
    [context.stack.lastObject.children addObjectsFromArray:replacements];
    return 0;
}

static SPDFMarkdownInlineTraits SPDFSpanTrait(MD_SPANTYPE type) {
    switch (type) {
        case MD_SPAN_EM: return SPDFMarkdownInlineTraitEmphasis;
        case MD_SPAN_STRONG: return SPDFMarkdownInlineTraitStrong;
        case MD_SPAN_A: return SPDFMarkdownInlineTraitLink;
        case MD_SPAN_IMG: return SPDFMarkdownInlineTraitImage;
        case MD_SPAN_CODE: return SPDFMarkdownInlineTraitCode;
        case MD_SPAN_DEL: return SPDFMarkdownInlineTraitStrikethrough;
        case MD_SPAN_WIKILINK: return SPDFMarkdownInlineTraitWikiLink;
        case MD_SPAN_LATEXMATH: return SPDFMarkdownInlineTraitMath;
        case MD_SPAN_LATEXMATH_DISPLAY:
            return SPDFMarkdownInlineTraitMath | SPDFMarkdownInlineTraitDisplayMath;
        default: return SPDFMarkdownInlineTraitNone;
    }
}

static int SPDFEnterSpan(MD_SPANTYPE type, void* detail, void* opaque) {
    SPDFMarkdownParseContext* context = (__bridge SPDFMarkdownParseContext*)opaque;
    if (++context.nodeCount > context.maximumNodeCount)
        return SPDFFailBudget(context, @"Markdown contains too many inline nodes.");
    if (context.spans.count >= context.maximumNestingDepth)
        return SPDFFailBudget(context, @"Markdown inline nesting is too deep.");
    SPDFMarkdownSpanFrame* frame = [SPDFMarkdownSpanFrame new];
    frame.previousTraits = context.traits;
    frame.previousDestination = context.destination;
    frame.previousTitle = context.title;
    frame.block = context.stack.lastObject;
    frame.firstRun = frame.block.runs.count;
    context.traits |= SPDFSpanTrait(type);
    if (type == MD_SPAN_A) {
        context.destination = SPDFAttributeString(((MD_SPAN_A_DETAIL*)detail)->href);
        NSString* title = SPDFAttributeString(((MD_SPAN_A_DETAIL*)detail)->title);
        context.title = title.length ? title : nil;
    } else if (type == MD_SPAN_IMG) {
        context.destination = SPDFAttributeString(((MD_SPAN_IMG_DETAIL*)detail)->src);
        NSString* title = SPDFAttributeString(((MD_SPAN_IMG_DETAIL*)detail)->title);
        context.title = title.length ? title : nil;
    } else if (type == MD_SPAN_WIKILINK) {
        context.title = nil;
        NSString* raw = SPDFAttributeString(((MD_SPAN_WIKILINK_DETAIL*)detail)->target);
        NSRange pipe = [raw rangeOfString:@"|" options:NSBackwardsSearch];
        if (pipe.location != NSNotFound) {
            frame.wikiAlias = [raw substringFromIndex:NSMaxRange(pipe)];
            raw = [raw substringToIndex:pipe.location];
        }
        context.destination = raw;
    }
    [context.spans addObject:frame];
    return 0;
}

static int SPDFLeaveSpan(MD_SPANTYPE type, void* detail, void* opaque) {
    (void)detail;
    SPDFMarkdownParseContext* context = (__bridge SPDFMarkdownParseContext*)opaque;
    SPDFMarkdownSpanFrame* frame = context.spans.lastObject;
    if (type == MD_SPAN_IMG && !context.html.suppressing && frame.block &&
        frame.block.runs.count == frame.firstRun) {
        // `![](src)` carries no alt text, so no text callback fired inside the
        // span and no run exists yet — but the image itself must still render:
        // synthesize the image run with empty text.
        [frame.block.runs addObject:[[SPDFMarkdownInlineRun alloc] initWithText:@""
                                                                         traits:context.traits
                                                                    destination:context.destination
                                                                          title:context.title]];
    }
    if (frame.wikiAlias.length && !context.html.suppressing && frame.block &&
        frame.firstRun <= frame.block.runs.count) {
        NSRange runs = NSMakeRange(frame.firstRun, frame.block.runs.count - frame.firstRun);
        [frame.block.runs removeObjectsInRange:runs];
        [frame.block.runs addObject:[[SPDFMarkdownInlineRun alloc]
                                       initWithText:frame.wikiAlias
                                            traits:context.traits
                                       destination:context.destination]];
    }
    context.traits = frame.previousTraits;
    context.destination = frame.previousDestination;
    context.title = frame.previousTitle;
    if (frame) [context.spans removeLastObject];
    return 0;
}

static int SPDFText(MD_TEXTTYPE type, const MD_CHAR* bytes, MD_SIZE size, void* opaque) {
    SPDFMarkdownParseContext* context = (__bridge SPDFMarkdownParseContext*)opaque;
    SPDFMarkdownBlockBuilder* block = context.stack.lastObject;
    NSString* text = SPDFString(bytes, size);
    if (type == MD_TEXT_HTML) {
        // Raw HTML never becomes visible text. A block island accumulates for
        // whole-island translation; an inline segment is a single tag event.
        if (block.htmlIsland) [block.htmlText appendString:text];
        else SPDFMarkdownHTMLHandleInlineSegment(context.html, text, block, context.traits);
        return 0;
    }
    if (context.html.suppressing) return 0;  // Inside a dropped element (<script>...).
    if (type == MD_TEXT_NULLCHAR) text = @"\uFFFD";
    else if (type == MD_TEXT_BR) text = @"\n";
    else if (type == MD_TEXT_SOFTBR) text = @"\u001e";
    else if (type == MD_TEXT_ENTITY) text = SPDFMarkdownDecodeEntity(text);
    if (text.length == 0) return 0;
    SPDFMarkdownInlineTraits traits = context.traits | context.html.overlayTraits;
    NSString* destination = context.destination ?: context.html.overlayDestination;
    NSString* title = context.title ?: context.html.overlayTitle;
    SPDFMarkdownInlineRun* last = block.runs.lastObject;
    if (last && last.traits == traits &&
        ((last.destination == nil && destination == nil) || [last.destination isEqualToString:destination]) &&
        ((last.title == nil && title == nil) || [last.title isEqualToString:title])) {
        SPDFMarkdownInlineRun* merged = [[SPDFMarkdownInlineRun alloc]
              initWithText:[last.text stringByAppendingString:text]
                    traits:last.traits
               destination:last.destination
                     title:last.title
       preferredImageWidth:last.preferredImageWidth
      preferredImageHeight:last.preferredImageHeight];
        [block.runs removeLastObject];
        [block.runs addObject:merged];
    } else {
        [block.runs addObject:[[SPDFMarkdownInlineRun alloc] initWithText:text
                                                                  traits:traits
                                                             destination:destination
                                                                   title:title]];
    }
    return 0;
}

static void SPDFDebugLog(const char* message, void* opaque) {
    SPDFMarkdownParseContext* context = (__bridge SPDFMarkdownParseContext*)opaque;
    if (!context.debugMessage) context.debugMessage = SPDFString(message, strlen(message));
}

static void SPDFStripRunPrefix(SPDFMarkdownBlockBuilder* block, NSUInteger count) {
    while (count > 0 && block.runs.count > 0) {
        SPDFMarkdownInlineRun* run = block.runs.firstObject;
        if (run.text.length <= count) {
            count -= run.text.length;
            [block.runs removeObjectAtIndex:0];
        } else {
            NSString* remainder = [run.text substringFromIndex:count];
            block.runs[0] = [[SPDFMarkdownInlineRun alloc] initWithText:remainder
                                                               traits:run.traits
                                                          destination:run.destination
                                                                  title:run.title];
            count = 0;
        }
    }
}

static void SPDFRecognizeCallouts(SPDFMarkdownBlockBuilder* block) {
    for (SPDFMarkdownBlockBuilder* child in block.children) SPDFRecognizeCallouts(child);
    if (block.kind != SPDFMarkdownBlockKindBlockQuote || block.children.count == 0) return;
    SPDFMarkdownBlockBuilder* first = block.children.firstObject;
    if (first.kind != SPDFMarkdownBlockKindParagraph) return;
    NSMutableString* text = [NSMutableString string];
    for (SPDFMarkdownInlineRun* run in first.runs) [text appendString:run.text];
    NSRegularExpression* regex = [NSRegularExpression regularExpressionWithPattern:@"^\\[!([A-Za-z0-9_-]+)\\][+-]?(?:[ \\t]+([^\\n\\u001e]+))?"
                                                                            options:0
                                                                              error:nil];
    NSTextCheckingResult* match = [regex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (!match) return;
    block.kind = SPDFMarkdownBlockKindCallout;
    block.calloutKind = [[text substringWithRange:[match rangeAtIndex:1]] uppercaseString];
    NSRange titleRange = [match rangeAtIndex:2];
    block.calloutTitle = titleRange.location == NSNotFound ? block.calloutKind.capitalizedString
                                                           : [text substringWithRange:titleRange];
    SPDFStripRunPrefix(first, NSMaxRange(match.range));
    if (first.runs.firstObject.text.length &&
        ([first.runs.firstObject.text hasPrefix:@"\n"] || [first.runs.firstObject.text hasPrefix:@"\u001e"]))
        SPDFStripRunPrefix(first, 1);
}

static SPDFMarkdownBlock* SPDFFreezeBlock(SPDFMarkdownBlockBuilder* source) {
    NSMutableArray* children = [NSMutableArray arrayWithCapacity:source.children.count];
    for (SPDFMarkdownBlockBuilder* child in source.children) [children addObject:SPDFFreezeBlock(child)];
    NSMutableArray* runs = [NSMutableArray arrayWithCapacity:source.runs.count];
    for (SPDFMarkdownInlineRun* run in source.runs) {
        NSString* normalized = [run.text stringByReplacingOccurrencesOfString:@"\u001e" withString:@" "];
        [runs addObject:[[SPDFMarkdownInlineRun alloc] initWithText:normalized
                                                             traits:run.traits
                                                        destination:run.destination
                                                              title:run.title
                                                preferredImageWidth:run.preferredImageWidth
                                               preferredImageHeight:run.preferredImageHeight]];
    }
    return [[SPDFMarkdownBlock alloc] initWithKind:source.kind
                                       blockIndex:source.index
                                             level:source.level
                                     orderedStart:source.orderedStart
                                        taskState:source.taskState
                                   tableAlignment:source.tableAlignment
                                   blockAlignment:source.blockAlignment
                                 tableColumnCount:source.tableColumnCount
                                             runs:runs
                                         children:children
                                     codeLanguage:source.codeLanguage
                                         codeInfo:source.codeInfo
                                      calloutKind:source.calloutKind
                                     calloutTitle:source.calloutTitle];
}

static NSString* SPDFExtractFrontMatter(NSString* input, NSDictionary** metadata, NSString** raw) {
    *metadata = @{};
    *raw = nil;
    NSArray<NSString*>* lines = [input componentsSeparatedByString:@"\n"];
    if (lines.count < 3 || ![[lines[0] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                               isEqualToString:@"---"]) return input;
    NSUInteger closing = NSNotFound;
    for (NSUInteger i = 1; i < lines.count; ++i) {
        NSString* trimmed = [lines[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([trimmed isEqualToString:@"---"] || [trimmed isEqualToString:@"..."]) {
            closing = i;
            break;
        }
    }
    if (closing == NSNotFound) return input;
    NSArray* yamlLines = [lines subarrayWithRange:NSMakeRange(1, closing - 1)];
    *raw = [yamlLines componentsJoinedByString:@"\n"];
    NSMutableDictionary* values = [NSMutableDictionary dictionary];
    for (NSString* line in yamlLines) {
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        NSString* key = [[line substringToIndex:colon.location]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString* value = [[line substringFromIndex:NSMaxRange(colon)]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (key.length) values[key] = value;
    }
    *metadata = values;
    return [[lines subarrayWithRange:NSMakeRange(closing + 1, lines.count - closing - 1)]
        componentsJoinedByString:@"\n"];
}

@implementation SPDFMarkdownParser

- (instancetype)init {
    self = [super init];
    if (self) {
        _maximumInputBytes = 64 * 1024 * 1024;
        _maximumNodeCount = 100000;
        _maximumNestingDepth = 128;
    }
    return self;
}

- (SPDFMarkdownDocumentModel*)loadURL:(NSURL*)url error:(NSError**)error {
    if (!url.isFileURL) {
        if (error) *error = [NSError errorWithDomain:SPDFMarkdownErrorDomain
                                               code:SPDFMarkdownErrorNonFileURL
                                           userInfo:@{NSLocalizedDescriptionKey: @"Markdown can only be loaded from local files."}];
        return nil;
    }
    NSNumber* size = nil;
    [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    if (size.unsignedLongLongValue > self.maximumInputBytes) {
        if (error) *error = [NSError errorWithDomain:SPDFMarkdownErrorDomain
                                               code:SPDFMarkdownErrorTooLarge
                                           userInfo:@{NSLocalizedDescriptionKey: @"Markdown document is too large."}];
        return nil;
    }
    NSData* data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:error];
    if (!data) return nil;
    return [self parseData:data sourceURL:url error:error];
}

- (SPDFMarkdownDocumentModel*)parseData:(NSData*)data sourceURL:(NSURL*)sourceURL error:(NSError**)error {
    if (data.length > self.maximumInputBytes) {
        if (error) *error = [NSError errorWithDomain:SPDFMarkdownErrorDomain
                                               code:SPDFMarkdownErrorTooLarge
                                           userInfo:@{NSLocalizedDescriptionKey: @"Markdown document is too large."}];
        return nil;
    }
    NSString* language = SPDFSourceLanguageForPath(sourceURL.path);
    if (language) {
        NSString* source = SPDFDecodeSourceDocument(data, error);
        return source ? SPDFSourceDocumentModel(source, sourceURL, language) : nil;
    }
    NSString* input = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!input) {
        if (error) *error = [NSError errorWithDomain:SPDFMarkdownErrorDomain
                                               code:SPDFMarkdownErrorInvalidUTF8
                                           userInfo:@{NSLocalizedDescriptionKey: @"Markdown must use valid UTF-8."}];
        return nil;
    }
    if ([input hasPrefix:@"\uFEFF"]) input = [input substringFromIndex:1];
    return [self parseString:input sourceURL:sourceURL error:error];
}

- (SPDFMarkdownDocumentModel*)parseString:(NSString*)markdown sourceURL:(NSURL*)sourceURL error:(NSError**)error {
    if ([markdown lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > self.maximumInputBytes) {
        if (error) *error = [NSError errorWithDomain:SPDFMarkdownErrorDomain
                                               code:SPDFMarkdownErrorTooLarge
                                           userInfo:@{NSLocalizedDescriptionKey: @"Markdown document is too large."}];
        return nil;
    }
    NSString* language = SPDFSourceLanguageForPath(sourceURL.path);
    if (language) return SPDFSourceDocumentModel(markdown, sourceURL, language);
    if ([markdown hasPrefix:@"\uFEFF"]) markdown = [markdown substringFromIndex:1];
    markdown = [markdown stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
    markdown = [markdown stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    NSDictionary* frontMatter = nil;
    NSString* rawFrontMatter = nil;
    NSString* body = SPDFExtractFrontMatter(markdown, &frontMatter, &rawFrontMatter);
    NSData* utf8 = [body dataUsingEncoding:NSUTF8StringEncoding];
    SPDFMarkdownParseContext* context = [SPDFMarkdownParseContext new];
    context.maximumNodeCount = self.maximumNodeCount;
    context.maximumNestingDepth = self.maximumNestingDepth;
    MD_PARSER parser = {};
    parser.abi_version = 0;
    // HTML islands pass through the native sanitizing whitelist.
    parser.flags = MD_DIALECT_GITHUB | MD_FLAG_WIKILINKS | MD_FLAG_LATEXMATHSPANS;
    parser.enter_block = SPDFEnterBlock;
    parser.leave_block = SPDFLeaveBlock;
    parser.enter_span = SPDFEnterSpan;
    parser.leave_span = SPDFLeaveSpan;
    parser.text = SPDFText;
    parser.debug_log = SPDFDebugLog;
    int result = md_parse((const MD_CHAR*)utf8.bytes, (MD_SIZE)utf8.length, &parser, (__bridge void*)context);
    if (result != 0) {
        if (error) *error = [NSError errorWithDomain:SPDFMarkdownErrorDomain
                                               code:context.failureCode ?: SPDFMarkdownErrorParseFailed
                                           userInfo:@{NSLocalizedDescriptionKey: context.debugMessage ?: @"Could not parse Markdown."}];
        return nil;
    }
    SPDFRecognizeCallouts(context.root);
    SPDFMarkdownBlock* root = SPDFFreezeBlock(context.root);
    return [[SPDFMarkdownDocumentModel alloc] initWithSourceURL:sourceURL
                                                   frontMatter:frontMatter
                                                rawFrontMatter:rawFrontMatter
                                                        blocks:root.children];
}

@end
