#import "SPDFMarkdownTestSupport.h"

#import "../../markdown/SPDFMarkdownDocument.h"

@interface SPDFMarkdownRenderedDocument (PerformanceFixture)
- (instancetype)initWithString:(NSAttributedString*)string blocks:(NSArray<SPDFMarkdownRenderedBlock*>*)blocks;
@end

static SPDFMarkdownRenderedDocument* SPDFRenderedSearchFixture(NSUInteger blockCount) {
    NSMutableString* source = [NSMutableString stringWithCapacity:blockCount * 20];
    for (NSUInteger index = 0; index < blockCount; ++index) {
        [source appendFormat:@"needle %lu\n\n", (unsigned long)index];
    }
    SPDFMarkdownParser* parser = [SPDFMarkdownParser new];
    parser.maximumNodeCount = blockCount + 100;
    NSError* error = nil;
    SPDFMarkdownDocumentModel* model = [parser parseString:source sourceURL:nil error:&error];
    SPDFExpect(model != nil && error == nil, @"performance search fixture parses");
    return [[SPDFMarkdownRenderer new] renderModel:model
                                           options:SPDFMarkdownRenderOptions.defaultOptions
                                 languageOverrides:nil];
}

static double SPDFMeasureSearch(NSUInteger blockCount) {
    SPDFMarkdownRenderedDocument* document = SPDFRenderedSearchFixture(blockCount);
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    NSArray* matches = [document searchForQuery:@"needle" caseSensitive:YES];
    double elapsed = CFAbsoluteTimeGetCurrent() - start;
    SPDFExpect(matches.count == blockCount, @"performance search returns every expected match");
    return elapsed;
}

static double SPDFMeasureHighlight(NSUInteger tokenCount) {
    NSMutableString* code = [NSMutableString stringWithCapacity:tokenCount * 2];
    for (NSUInteger index = 0; index < tokenCount; ++index) [code appendString:@"1 "];
    SPDFMarkdownLanguage* JavaScript =
        [SPDFMarkdownLanguageCatalog.sharedCatalog languageForFenceIdentifier:@"javascript"];
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    NSArray* tokens = [[SPDFMarkdownHighlighter new] tokensForCode:code language:JavaScript];
    double elapsed = CFAbsoluteTimeGetCurrent() - start;
    SPDFExpect(tokens.count == tokenCount, @"performance lexer returns every expected token");
    return elapsed;
}

static SPDFMarkdownRenderedDocument* SPDFRawRenderedDocument(NSString* string) {
    return [[SPDFMarkdownRenderedDocument alloc]
        initWithString:[[NSAttributedString alloc] initWithString:string] blocks:@[]];
}

static void SPDFTestSearchChunkBoundaryAndCancellation(void) {
    NSMutableString* boundary = [NSMutableString stringWithCapacity:66 * 1024];
    [boundary appendString:[@"a" stringByPaddingToLength:64 * 1024 - 3 withString:@"a" startingAtIndex:0]];
    [boundary appendString:@"needle tail"];
    NSArray* boundaryMatches = [SPDFRawRenderedDocument(boundary) searchForQuery:@"needle" caseSensitive:YES];
    SPDFExpect(boundaryMatches.count == 1 && [boundaryMatches.firstObject range].location == 64 * 1024 - 3,
               @"chunked search finds a match spanning an internal cancellation boundary");

    NSMutableString* large = [NSMutableString stringWithCapacity:24 * 1024 * 1024];
    NSString* megabyte = [@"a" stringByPaddingToLength:1024 * 1024 withString:@"a" startingAtIndex:0];
    for (NSUInteger index = 0; index < 24; ++index) [large appendString:megabyte];
    SPDFMarkdownRenderedDocument* document = SPDFRawRenderedDocument(large);
    SPDFMarkdownCancellationToken* token = [SPDFMarkdownCancellationToken new];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSArray* result = nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        result = [document searchForQuery:@"definitely absent" caseSensitive:YES cancellationToken:token];
        dispatch_semaphore_signal(done);
    });
    [NSThread sleepForTimeInterval:0.01];
    CFAbsoluteTime cancellationStart = CFAbsoluteTimeGetCurrent();
    [token cancel];
    long waitResult = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    double cancellationLatency = CFAbsoluteTimeGetCurrent() - cancellationStart;
    printf("Markdown cancelled search: %.6fs\n", cancellationLatency);
    SPDFExpect(waitResult == 0 && result.count == 0 && cancellationLatency < 0.20,
               @"cancellation interrupts a single very large no-match search promptly");

    NSMutableString* pathological = [NSMutableString stringWithCapacity:8 * 1024 * 1024];
    for (NSUInteger index = 0; index < 8; ++index) [pathological appendString:megabyte];
    NSMutableString* impracticalQuery = [[@"a" stringByPaddingToLength:64 * 1024
                                                              withString:@"a"
                                                         startingAtIndex:0] mutableCopy];
    [impracticalQuery replaceCharactersInRange:NSMakeRange(impracticalQuery.length - 1, 1)
                                     withString:@"b"];
    CFAbsoluteTime pathologicalStart = CFAbsoluteTimeGetCurrent();
    NSArray* pathologicalResult = [SPDFRawRenderedDocument(pathological)
        searchForQuery:impracticalQuery caseSensitive:YES cancellationToken:nil];
    double pathologicalElapsed = CFAbsoluteTimeGetCurrent() - pathologicalStart;
    printf("Markdown impractical query rejection: %.6fs\n", pathologicalElapsed);
    SPDFExpect(pathologicalResult.count == 0 && pathologicalElapsed < 0.20,
               @"an 8 MiB repeated document with a 64 KiB near-match query is rejected in bounded time");
}

int main(void) {
    @autoreleasepool {
        double smallSearch = SPDFMeasureSearch(8000);
        double largeSearch = SPDFMeasureSearch(32000);
        printf("Markdown search: 8k %.6fs, 32k %.6fs\n", smallSearch, largeSearch);
        SPDFExpect(largeSearch < 2.0 && largeSearch < smallSearch * 8.0 + 0.25,
                   @"search scales near-linearly rather than by matches times blocks");

        double smallHighlight = SPDFMeasureHighlight(20000);
        double largeHighlight = SPDFMeasureHighlight(80000);
        printf("Markdown highlight: 20k %.6fs, 80k %.6fs\n", smallHighlight, largeHighlight);
        SPDFExpect(largeHighlight < 2.0 && largeHighlight < smallHighlight * 8.0 + 0.25,
                   @"syntax highlighting scales near-linearly without token collision scans");
        SPDFTestSearchChunkBoundaryAndCancellation();
    }
    return SPDFFinishTests(@"SPDFMarkdownPerformanceTests");
}
