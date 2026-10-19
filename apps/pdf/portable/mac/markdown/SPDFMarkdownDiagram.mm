#import "SPDFMarkdownDiagramInternal.h"

#import <stdatomic.h>

// Entry seam, budgets, work counter and the per-document layout cache.

const NSUInteger SPDFMarkdownDiagramMaximumNodes = 200;
const NSUInteger SPDFMarkdownDiagramMaximumEdges = 400;
const NSTimeInterval SPDFMarkdownDiagramLayoutDeadline = 0.050;

NSTimeInterval SPDFMarkdownDiagramLayoutBudget(void) {
    static NSTimeInterval budget;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        budget = SPDFMarkdownDiagramLayoutDeadline;
        const char* override = getenv("SPDF_DIAGRAM_LAYOUT_DEADLINE");
        if (override) {
            double seconds = atof(override);
            if (seconds > 0.0) budget = (NSTimeInterval)seconds;
        }
    });
    return budget;
}
const CGFloat SPDFMarkdownDiagramMaximumDimension = 2048;
const CGFloat SPDFMarkdownDiagramLegibleLabelSize = 7;

static _Atomic NSUInteger sSPDFDiagramWorkCount = 0;

NSUInteger SPDFMarkdownDiagramWorkCount(void) {
    return atomic_load(&sSPDFDiagramWorkCount);
}

void SPDFMarkdownDiagramResetWorkCount(void) {
    atomic_store(&sSPDFDiagramWorkCount, (NSUInteger)0);
}

// --- Cache -------------------------------------------------------------------

// One cached outcome; `source` is kept so a hash collision can never serve the
// wrong diagram. A nil `layout` records a failed parse (negative caching).
@interface SPDFMarkdownDiagramCacheEntry : NSObject
@property(nonatomic, copy) NSString* source;
@property(nonatomic, strong, nullable) SPDFMarkdownDiagramLayout* layout;
@end
@implementation SPDFMarkdownDiagramCacheEntry
@end

@implementation SPDFMarkdownDiagramCache {
    NSMutableDictionary<NSString*, SPDFMarkdownDiagramCacheEntry*>* _entries;
}
- (instancetype)init {
    self = [super init];
    if (self) _entries = [NSMutableDictionary dictionary];
    return self;
}
- (NSUInteger)count {
    @synchronized(self) {
        return _entries.count;
    }
}
- (void)removeAllEntries {
    @synchronized(self) {
        [_entries removeAllObjects];
    }
}
- (SPDFMarkdownDiagramCacheEntry*)entryForKey:(NSString*)key source:(NSString*)source {
    @synchronized(self) {
        SPDFMarkdownDiagramCacheEntry* entry = _entries[key];
        return [entry.source isEqualToString:source] ? entry : nil;
    }
}
- (void)storeLayout:(SPDFMarkdownDiagramLayout*)layout forKey:(NSString*)key source:(NSString*)source {
    SPDFMarkdownDiagramCacheEntry* entry = [SPDFMarkdownDiagramCacheEntry new];
    entry.source = source;
    entry.layout = layout;
    @synchronized(self) {
        // Simple bound: a runaway document drops the whole map instead of
        // growing without limit (rerenders repopulate what is still visible).
        if (_entries.count >= 128) [_entries removeAllObjects];
        _entries[key] = entry;
    }
}
@end

// --- Dispatch ------------------------------------------------------------------

BOOL SPDFMarkdownDiagramIsDiagramLanguage(NSString* fenceIdentifier) {
    if (!fenceIdentifier.length) return NO;
    NSString* token = [[SPDFMarkdownDiagramTrim(fenceIdentifier)
        componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet] firstObject]
                          .lowercaseString;
    return [token isEqualToString:@"mermaid"] || [token isEqualToString:@"sequence"] ||
           [token isEqualToString:@"flow"];
}

// The mermaid sub-type is the first significant line's first word.
static NSString* SPDFDiagramMermaidKeyword(NSString* source) {
    NSString* first = SPDFMarkdownDiagramSignificantLines(source).firstObject ?: @"";
    return [[first componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet] firstObject]
        .lowercaseString;
}

static SPDFMarkdownDiagramLayout* SPDFDiagramRenderUncached(NSString* language, NSString* source,
                                                            NSSize contentBox, CGFloat fontScale) {
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + SPDFMarkdownDiagramLayoutBudget();
    if ([language isEqualToString:@"sequence"]) {
        SPDFMarkdownDiagramSequence* sequence = SPDFMarkdownDiagramParseSequence(source, NO);
        return sequence ? SPDFMarkdownDiagramLayOutSequence(sequence, contentBox, fontScale) : nil;
    }
    if ([language isEqualToString:@"flow"]) {
        SPDFMarkdownDiagramGraph* graph = SPDFMarkdownDiagramParseFlowFence(source);
        return graph ? SPDFMarkdownDiagramLayOutGraph(graph, contentBox, fontScale, deadline) : nil;
    }
    // mermaid sub-types.
    NSString* keyword = SPDFDiagramMermaidKeyword(source);
    if ([keyword isEqualToString:@"graph"] || [keyword isEqualToString:@"flowchart"]) {
        SPDFMarkdownDiagramGraph* graph = SPDFMarkdownDiagramParseMermaidFlowchart(source);
        return graph ? SPDFMarkdownDiagramLayOutGraph(graph, contentBox, fontScale, deadline) : nil;
    }
    if ([keyword isEqualToString:@"sequencediagram"]) {
        SPDFMarkdownDiagramSequence* sequence = SPDFMarkdownDiagramParseSequence(source, YES);
        return sequence ? SPDFMarkdownDiagramLayOutSequence(sequence, contentBox, fontScale) : nil;
    }
    if ([keyword isEqualToString:@"pie"]) {
        SPDFMarkdownDiagramPie* pie = SPDFMarkdownDiagramParsePie(source);
        return pie ? SPDFMarkdownDiagramLayOutPie(pie, contentBox, fontScale) : nil;
    }
    if ([keyword isEqualToString:@"statediagram"] || [keyword isEqualToString:@"statediagram-v2"]) {
        SPDFMarkdownDiagramGraph* graph = SPDFMarkdownDiagramParseMermaidState(source);
        return graph ? SPDFMarkdownDiagramLayOutGraph(graph, contentBox, fontScale, deadline) : nil;
    }
    if ([keyword isEqualToString:@"classdiagram"]) {
        SPDFMarkdownDiagramGraph* graph = SPDFMarkdownDiagramParseMermaidClass(source);
        return graph ? SPDFMarkdownDiagramLayOutGraph(graph, contentBox, fontScale, deadline) : nil;
    }
    if ([keyword isEqualToString:@"gantt"]) {
        SPDFMarkdownDiagramGantt* gantt = SPDFMarkdownDiagramParseGantt(source);
        return gantt ? SPDFMarkdownDiagramLayOutGantt(gantt, contentBox, fontScale) : nil;
    }
    return nil;  // unknown mermaid sub-type degrades to the code box
}

SPDFMarkdownDiagramLayout* SPDFMarkdownDiagramRender(NSString* fenceIdentifier, NSString* source,
                                                     NSSize contentBox, CGFloat fontScale,
                                                     SPDFMarkdownDiagramCache* cache) {
    if (!SPDFMarkdownDiagramIsDiagramLanguage(fenceIdentifier) || !source.length) return nil;
    if (contentBox.width <= 0) return nil;
    NSString* language = [[SPDFMarkdownDiagramTrim(fenceIdentifier)
        componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet] firstObject]
                             .lowercaseString;
    // No theme variant in the key: a resolved layout carries color ROLES, so a
    // reading-theme switch reuses every cached diagram outright.
    NSString* key = [NSString stringWithFormat:@"%@|%.4f|%.1f|%.1f|%lu|%lu", language, fontScale,
                                               contentBox.width, contentBox.height,
                                               (unsigned long)source.hash, (unsigned long)source.length];
    SPDFMarkdownDiagramCacheEntry* cached = [cache entryForKey:key source:source];
    if (cached) return cached.layout;
    atomic_fetch_add(&sSPDFDiagramWorkCount, (NSUInteger)1);
    SPDFMarkdownDiagramLayout* layout = SPDFDiagramRenderUncached(language, source, contentBox, fontScale);
    [cache storeLayout:layout forKey:key source:source];
    return layout;
}
