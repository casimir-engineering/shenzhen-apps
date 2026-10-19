#import "SPDFMacChatMarkdownParts.h"

#include <time.h>

// What a render may spend and what it keeps. A Friends conversation lays out every message on the main thread at once,
// so each render is bounded on its own (0.4 s) and, through a shared allowance, all of them together; laid-out blocks
// are kept so that rendering the same block again (reopening the conversation) costs nothing.

// The most one render may take, parse to finish: the security review timed a friend's 32 KB message of small tables
// at 0.46 s against the earlier 0.4 s that counted drawn blocks only.
static const NSTimeInterval kChatRenderTime = 0.4;
static NSTimeInterval gRenderTime = kChatRenderTime;
// Drawn blocks start only in the first 55% of a render's time, and the walk over the message's blocks stops at 70%:
// the engine then sets the walked part's text in the rest (measured: 30 ms for a 32 KB message of 2,000 small
// tables, 60 ms for a 128 KB one).
static const double kChatDrawShare = 0.55;
static const double kChatWalkShare = 0.7;
static NSTimeInterval gExtraLayoutTime;
static NSTimeInterval gTestClockOffset;

const NSTimeInterval SPDFMacChatMarkdownPassTotal = 1.0;

@implementation SPDFMacChatMarkdownAllowance
- (instancetype)initWithTotal:(NSTimeInterval)total {
    if (!(self = [super init])) return nil;
    _total = MAX(0, total);
    _remaining = _total;
    return self;
}
- (BOOL)isSpent { return _remaining <= 0; }
- (void)spend:(NSTimeInterval)seconds { _remaining = MAX(0, _remaining - MAX(0, seconds)); }
@end

SPDFMacChatMarkdownAllowance* SPDFMacChatMarkdownCurrentPassAllowance(NSTimeInterval total) {
    static SPDFMacChatMarkdownAllowance* current;
    if (current) return current;
    current = [[SPDFMacChatMarkdownAllowance alloc] initWithTotal:total];
    // The pass ends when the main thread finishes what it is doing now: a conversation's layout pass, which asks for
    // every message's rendering in one go, is over by then.
    dispatch_async(dispatch_get_main_queue(), ^{
      current = nil;
    });
    return current;
}

NSTimeInterval SPDFMacChatNow(void) {
    // Monotonic: a clock change while a conversation lays out must not stretch or cut its renders.
    return (double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / NSEC_PER_SEC + gTestClockOffset;
}

SPDFMacChatClock SPDFMacChatStartClock(SPDFMacChatMarkdownAllowance* allowance) {
    SPDFMacChatClock clock;
    clock.start = SPDFMacChatNow();
    clock.budget = allowance ? MIN(gRenderTime, allowance.remaining) : gRenderTime;
    clock.drawUntil = clock.start + clock.budget * kChatDrawShare;
    clock.walkUntil = clock.start + clock.budget * kChatWalkShare;
    return clock;
}

void SPDFMacChatStopClock(SPDFMacChatClock clock, SPDFMacChatMarkdownAllowance* allowance) {
    [allowance spend:SPDFMacChatNow() - clock.start];
}

NSTimeInterval SPDFMacChatLayoutTime(void) { return gRenderTime; }
void SPDFMacChatSetLayoutTime(NSTimeInterval seconds) { gRenderTime = seconds > 0 ? seconds : kChatRenderTime; }
void SPDFMacChatSetExtraLayoutTime(NSTimeInterval seconds) { gExtraLayoutTime = MAX(0, seconds); }

void SPDFMacChatPassExtraLayoutTime(void) { gTestClockOffset += gExtraLayoutTime; }

#pragma mark - Kept blocks

// Every laid-out block, whichever message it came from: the key covers all a layout depends on, so equal keys draw
// the same, and Friends gets reuse across reopenings without keeping anything itself. Bounded by an estimate of the
// memory a layout holds (its text, attributes and line fragments: taken as 4 KB plus 64 bytes per source character),
// which keeps a few thousand ordinary tables and code blocks.
static NSCache<NSString*, SPDFMacChatBlock*>* KeptBlocks(void) {
    static NSCache* cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      cache = [NSCache new];
      cache.totalCostLimit = 24 * 1024 * 1024;
    });
    return cache;
}

static void AppendField(NSMutableString* key, NSString* field) {
    // Length-prefixed, so no text inside a cell can make two different tables share a key.
    [key appendFormat:@"%lu:%@", (unsigned long)field.length, field ?: @""];
}

static void AppendBlock(NSMutableString* key, SPDFMarkdownBlock* block) {
    [key appendFormat:@"[%ld,%ld,%ld,%lu,%ld,", (long)block.kind, (long)block.tableAlignment,
                      (long)block.blockAlignment, (unsigned long)block.tableColumnCount, (long)block.taskState];
    AppendField(key, block.codeLanguage);
    AppendField(key, block.codeInfo);
    for (SPDFMarkdownInlineRun* run in block.runs) {
        [key appendFormat:@"(%lu,", (unsigned long)run.traits];
        AppendField(key, run.destination);
        AppendField(key, run.text);
    }
    for (SPDFMarkdownBlock* child in block.children) AppendBlock(key, child);
    [key appendString:@"]"];
}

static NSString* ColorKey(NSColor* color) {
    NSColor* rgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    return [NSString stringWithFormat:@"%.4f,%.4f,%.4f,%.4f", rgb.redComponent, rgb.greenComponent, rgb.blueComponent,
                                      rgb.alphaComponent];
}

NSString* SPDFMacChatBlockKey(SPDFMarkdownBlock* block, SPDFMacChatBlockKind kind, CGFloat column,
                              SPDFMacChatMarkdownOptions* options) {
    NSMutableString* key = [NSMutableString stringWithFormat:@"%ld|%.1f|%d|%d|%@|%@|%@|", (long)kind, floor(column),
                                                             options.dark, options.keepsWideBlocks,
                                                             ColorKey(options.textColor),
                                                             ColorKey(options.secondaryTextColor),
                                                             ColorKey(options.linkColor)];
    AppendBlock(key, block);
    return key;
}

SPDFMacChatBlock* SPDFMacChatKeptBlock(NSString* key) { return [KeptBlocks() objectForKey:key]; }
void SPDFMacChatKeepBlock(NSString* key, SPDFMacChatBlock* block) {
    [KeptBlocks() setObject:block forKey:key cost:key.length * 64 + 4096];
}
void SPDFMacChatForgetKeptBlocks(void) { [KeptBlocks() removeAllObjects]; }

#pragma mark - The plain rest

// `marker` goes before a list item's own words ("- ", or "3. " in an ordered list).
static void AppendPlain(SPDFMarkdownBlock* block, NSString* prefix, NSString* marker, NSMutableArray<NSString*>* out) {
    NSString* code = [block.plainText stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet] ?: @"";
    switch (block.kind) {
        case SPDFMarkdownBlockKindPageBreak:
            return;
        case SPDFMarkdownBlockKindThematicBreak:
            [out addObject:@"---"];
            return;
        case SPDFMarkdownBlockKindTable:
            [out addObject:SPDFMacChatTableSource(block)];
            return;
        case SPDFMarkdownBlockKindCode:
            [out addObject:SPDFMarkdownDiagramIsDiagramLanguage(block.codeLanguage)
                               ? [NSString stringWithFormat:@"```%@\n%@\n```", block.codeLanguage, code]
                               : code];
            return;
        default:
            break;
    }
    BOOL item = block.kind == SPDFMarkdownBlockKindListItem;
    BOOL quote = block.kind == SPDFMarkdownBlockKindBlockQuote || block.kind == SPDFMarkdownBlockKindCallout;
    if (block.plainText.length)
        [out addObject:[NSString stringWithFormat:@"%@%@%@", prefix, item ? marker : @"", block.plainText]];
    NSString* inner = quote ? [prefix stringByAppendingString:@"> "]
                      : item ? [prefix stringByAppendingString:@"  "]
                             : prefix;
    BOOL ordered = block.kind == SPDFMarkdownBlockKindOrderedList;
    for (NSUInteger index = 0; index < block.children.count; index++) {
        NSString* childMarker = ordered ? [NSString stringWithFormat:@"%ld. ", (long)(block.orderedStart + index)]
                                        : @"- ";
        AppendPlain(block.children[index], inner, childMarker, out);
    }
}

NSAttributedString* SPDFMacChatPlainRest(NSArray<SPDFMarkdownBlock*>* blocks, NSString* note,
                                         SPDFMacChatMarkdownOptions* options) {
    // One part per block: a list's items stay on consecutive lines, and blocks are a blank line apart.
    NSMutableArray<NSString*>* parts = [NSMutableArray arrayWithCapacity:blocks.count];
    for (SPDFMarkdownBlock* block in blocks) {
        NSMutableArray<NSString*>* lines = [NSMutableArray array];
        AppendPlain(block, @"", @"- ", lines);
        if (lines.count) [parts addObject:[lines componentsJoinedByString:@"\n"]];
    }
    // One paragraph, its lines broken with U+2028 and its blocks a blank line apart: the rest of a long message can be
    // thousands of blocks, and every paragraph costs the passes after the walk (block spacing, token replacement).
    NSMutableString* shown = [NSMutableString string];
    NSMutableArray<NSValue*>* ranges = [NSMutableArray arrayWithCapacity:parts.count];
    for (NSString* part in parts) {
        if (shown.length) [shown appendString:@"\u2028\u2028"];
        [ranges addObject:[NSValue valueWithRange:NSMakeRange(shown.length, part.length)]];
        [shown appendString:[part stringByReplacingOccurrencesOfString:@"\n" withString:@"\u2028"]];
    }
    NSMutableAttributedString* text = [[NSMutableAttributedString alloc] initWithString:shown attributes:@{
        NSFontAttributeName : [NSFont systemFontOfSize:13], NSForegroundColorAttributeName : options.textColor,
        SPDFMacChatMarkdownSourceAttribute : @"\n\n"}];
    // Copying gives each block with ordinary line breaks, and a blank line between blocks.
    for (NSUInteger index = 0; index < parts.count; index++)
        [text addAttribute:SPDFMacChatMarkdownSourceAttribute value:parts[index] range:ranges[index].rangeValue];
    if (note.length) {
        NSFont* italic = [NSFontManager.sharedFontManager convertFont:[NSFont systemFontOfSize:12]
                                                          toHaveTrait:NSItalicFontMask];
        NSDictionary* noted = @{NSFontAttributeName : italic, SPDFMacChatMarkdownSourceAttribute : @"",
                                NSForegroundColorAttributeName : options.secondaryTextColor};
        NSString* line = [note stringByAppendingString:@"\u2028"];
        [text insertAttributedString:[[NSAttributedString alloc] initWithString:line attributes:noted] atIndex:0];
    }
    return text;
}
