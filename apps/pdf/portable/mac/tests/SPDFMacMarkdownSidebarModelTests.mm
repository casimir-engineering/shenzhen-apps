#import <AppKit/AppKit.h>

#import "../SPDFMacMarkdownSidebarModel.h"
#import "../markdown/SPDFMarkdownDocument.h"

#include <assert.h>
#include <stdio.h>

static NSDictionary<NSString*, id>* SPDFItemOfKind(NSArray<NSDictionary<NSString*, id>*>* items, NSString* kind,
                                                   NSUInteger occurrence) {
    for (NSDictionary<NSString*, id>* item in items) {
        if (![item[@"kind"] isEqualToString:kind]) continue;
        if (occurrence == 0) return item;
        --occurrence;
    }
    return nil;
}

static SPDFMarkdownDocument* SPDFTestDocument(SPDFMarkdownPaginationPlan** plan) {
    NSString* source = @"# Resume\n\n"
                        "Intro needle text.\n\n"
                        "## Details\n\n"
                        "Details needle text.\n\n"
                        "### Deep Dive\n\n"
                        "Deep needle text.\n\n"
                        "#### Ignored Heading\n\n"
                        "Ignored-level needle text.\n\n"
                        "```\n"
                        "# Code Is Not A Heading\n"
                        "## Nor Is This\n"
                        "needle in one multi-line code block\n"
                        "```\n\n"
                        "# Ending\n\n"
                        "Ending needle text.\n";
    NSError* error = nil;
    SPDFMarkdownDocumentModel* parsed = [[SPDFMarkdownParser new] parseString:source sourceURL:nil error:&error];
    assert(parsed != nil && error == nil);
    SPDFMarkdownDocument* document =
        [[SPDFMarkdownDocument alloc] initWithModel:parsed options:SPDFMarkdownRenderOptions.defaultOptions];
    SPDFMarkdownPaginator* paginator = [SPDFMarkdownPaginator new];
    NSArray<SPDFMarkdownPaginationItem*>* measured = [paginator measureRenderedDocument:document.renderedDocument
                                                                         containerWidth:220];
    SPDFMarkdownPageConfiguration* configuration =
        [SPDFMarkdownPageConfiguration configurationForPaperSize:NSMakeSize(260, 110)
                                                   printableRect:NSMakeRect(20, 10, 220, 90)];
    *plan = [paginator paginateItems:measured configuration:configuration];
    return document;
}

static void SPDFAssertStandardKeys(NSDictionary<NSString*, id>* item) {
    for (NSString* key in @[ @"kind", @"title", @"subtitle", @"query", @"page", @"findIndex", @"level", @"range" ])
        assert(item[key] != nil);
}

static SPDFMacMarkdownSidebarModel* SPDFSamePageChapterModel(SPDFMarkdownDocument** documentOut) {
    NSString* source = @"Preamble before any chapter.\n\n"
                        "# Alpha\n\n"
                        "Alpha body.\n\n"
                        "## Beta\n\n"
                        "Beta body.\n\n"
                        "### Gamma\n\n"
                        "Gamma body.\n\n"
                        "#### Ignored\n\n"
                        "Ignored body.\n";
    NSError* error = nil;
    SPDFMarkdownDocumentModel* parsed = [[SPDFMarkdownParser new] parseString:source sourceURL:nil error:&error];
    assert(parsed != nil && error == nil);
    SPDFMarkdownDocument* document =
        [[SPDFMarkdownDocument alloc] initWithModel:parsed options:SPDFMarkdownRenderOptions.defaultOptions];
    SPDFMarkdownPaginator* paginator = [SPDFMarkdownPaginator new];
    NSArray<SPDFMarkdownPaginationItem*>* measured = [paginator measureRenderedDocument:document.renderedDocument
                                                                         containerWidth:500];
    SPDFMarkdownPageConfiguration* configuration =
        [SPDFMarkdownPageConfiguration configurationForPaperSize:NSMakeSize(540, 800)
                                                   printableRect:NSMakeRect(20, 20, 500, 760)];
    SPDFMarkdownPaginationPlan* plan = [paginator paginateItems:measured configuration:configuration];
    assert(plan.pages.count == 1);
    if (documentOut) *documentOut = document;
    return [[SPDFMacMarkdownSidebarModel alloc] initWithRenderedDocument:document.renderedDocument paginationPlan:plan];
}

int main(void) {
    @autoreleasepool {
        SPDFMarkdownPaginationPlan* plan = nil;
        SPDFMarkdownDocument* document = SPDFTestDocument(&plan);
        SPDFMacMarkdownSidebarModel* model =
            [[SPDFMacMarkdownSidebarModel alloc] initWithRenderedDocument:document.renderedDocument
                                                           paginationPlan:plan];

        NSArray<NSDictionary<NSString*, id>*>* chapters = model.chapterItems;
        assert(chapters.count == 4);
        assert([chapters[0][@"title"] isEqualToString:@"Resume"] && [chapters[0][@"level"] integerValue] == 0);
        assert([chapters[1][@"title"] isEqualToString:@"Details"] && [chapters[1][@"level"] integerValue] == 1);
        assert([chapters[2][@"title"] isEqualToString:@"Deep Dive"] && [chapters[2][@"level"] integerValue] == 2);
        assert([chapters[3][@"title"] isEqualToString:@"Ending"] && [chapters[3][@"level"] integerValue] == 0);
        for (NSDictionary<NSString*, id>* chapter in chapters) {
            SPDFAssertStandardKeys(chapter);
            assert([chapter[@"kind"] isEqualToString:@"chapter"]);
            assert([chapter[@"page"] integerValue] >= 0);
            NSRange range = [chapter[@"range"] rangeValue];
            NSString* canonicalTitle = [[document.renderedDocument.attributedString.string substringWithRange:range]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            assert([canonicalTitle isEqualToString:chapter[@"title"]]);
        }
        assert([chapters[0][@"page"] integerValue] <= [chapters[1][@"page"] integerValue]);
        assert([chapters[1][@"page"] integerValue] <= [chapters[2][@"page"] integerValue]);
        assert([chapters[2][@"page"] integerValue] <= [chapters[3][@"page"] integerValue]);

        assert([model chapterItemsMatchingQuery:@"resume"].count == 1);
        assert([model chapterItemsMatchingQuery:@"RESUME"].count == 1);
        assert([model chapterItemsMatchingQuery:@"résumé"].count == 1);
        assert([model chapterItemsMatchingQuery:@""].count == chapters.count);

        NSArray<SPDFMarkdownSearchMatch*>* matches = [document.renderedDocument searchForQuery:@"needle"
                                                                                 caseSensitive:NO];
        assert(matches.count == 6);
        NSArray<NSDictionary<NSString*, id>*>* search = [model searchSidebarItemsForMatches:matches
                                                                                      query:@"needle"
                                                                                  searching:NO];
        NSMutableArray<NSString*>* dividerTitles = [NSMutableArray array];
        NSUInteger resultCount = 0;
        for (NSDictionary<NSString*, id>* item in search) {
            SPDFAssertStandardKeys(item);
            if ([item[@"kind"] isEqualToString:@"findDivider"]) [dividerTitles addObject:item[@"title"]];
            if (![item[@"kind"] isEqualToString:@"findResult"]) continue;
            SPDFMarkdownSearchMatch* match = matches[resultCount];
            assert([item[@"findIndex"] unsignedIntegerValue] == resultCount);
            assert(NSEqualRanges([item[@"range"] rangeValue], match.range));
            assert([item[@"title"] isEqualToString:match.context]);
            NSArray* exact=item[@"matchRanges"];
            assert(exact.count==1);
            assert([[item[@"title"] substringWithRange:[exact[0] rangeValue]] isEqualToString:@"needle"]);
            assert([item[@"page"] integerValue] >= 0);
            ++resultCount;
        }
        assert(resultCount == matches.count);
        NSArray<NSString*>* expectedDividers = @[ @"Resume", @"Details", @"Deep Dive", @"Ending" ];
        assert([dividerTitles isEqualToArray:expectedDividers]);

        NSDictionary<NSString*, id>* searching =
            SPDFItemOfKind([model searchSidebarItemsForMatches:@[] query:@"needle" searching:YES], @"findStatus", 0);
        assert([searching[@"title"] isEqualToString:@"Searching for \"needle\"..."]);
        SPDFAssertStandardKeys(searching);
        NSDictionary<NSString*, id>* noMatches =
            SPDFItemOfKind([model searchSidebarItemsForMatches:@[] query:@"missing" searching:NO], @"findStatus", 0);
        assert([noMatches[@"title"] isEqualToString:@"No matches for \"missing\""]);
        SPDFAssertStandardKeys(noMatches);

        NSRange codeRange =
            [document.renderedDocument.attributedString.string rangeOfString:@"# Code Is Not A Heading"];
        assert(codeRange.location != NSNotFound);
        for (NSDictionary<NSString*, id>* chapter in chapters)
            assert(!NSLocationInRange(codeRange.location, [chapter[@"range"] rangeValue]));

        SPDFMarkdownDocument* samePageDocument = nil;
        SPDFMacMarkdownSidebarModel* samePageModel = SPDFSamePageChapterModel(&samePageDocument);
        NSArray<NSDictionary<NSString*, id>*>* samePageChapters = samePageModel.chapterItems;
        assert(samePageChapters.count == 3);
        assert([samePageChapters[0][@"page"] integerValue] == 0);
        assert([samePageChapters[1][@"page"] integerValue] == 0);
        assert([samePageChapters[2][@"page"] integerValue] == 0);

        NSRange alphaRange = [samePageChapters[0][@"range"] rangeValue];
        NSRange betaRange = [samePageChapters[1][@"range"] rangeValue];
        NSRange gammaRange = [samePageChapters[2][@"range"] rangeValue];
        assert(alphaRange.location > 0);
        assert([samePageModel chapterItemPrecedingAttributedLocation:alphaRange.location - 1
                                                   fallbackPageIndex:0] == nil);
        assert([samePageModel chapterItemPrecedingAttributedLocation:alphaRange.location
                                                   fallbackPageIndex:0] == samePageChapters[0]);
        assert([samePageModel chapterItemPrecedingAttributedLocation:betaRange.location - 1
                                                   fallbackPageIndex:0] == samePageChapters[0]);
        assert([samePageModel chapterItemPrecedingAttributedLocation:betaRange.location
                                                   fallbackPageIndex:0] == samePageChapters[1]);
        assert([samePageModel chapterItemPrecedingAttributedLocation:NSMaxRange(betaRange)
                                                   fallbackPageIndex:0] == samePageChapters[1]);
        assert([samePageModel chapterItemPrecedingAttributedLocation:gammaRange.location
                                                   fallbackPageIndex:0] == samePageChapters[2]);
        assert([samePageModel
                   chapterItemPrecedingAttributedLocation:samePageDocument.renderedDocument.attributedString.length
                                        fallbackPageIndex:0] == samePageChapters[2]);

        assert([samePageModel chapterItemPrecedingAttributedLocation:NSNotFound fallbackPageIndex:-1] == nil);
        assert([samePageModel chapterItemPrecedingAttributedLocation:NSNotFound
                                                   fallbackPageIndex:0] == samePageChapters[0]);
        assert([samePageModel
                   chapterItemPrecedingAttributedLocation:samePageDocument.renderedDocument.attributedString.length + 1
                                        fallbackPageIndex:0] == samePageChapters[0]);
        assert([samePageModel chapterItemPrecedingAttributedLocation:NSNotFound
                                                   fallbackPageIndex:1] == samePageChapters[2]);

        NSRange ignoredRange =
            [samePageDocument.renderedDocument.attributedString.string rangeOfString:@"Ignored body."];
        assert(ignoredRange.location != NSNotFound);
        assert([samePageModel chapterItemPrecedingAttributedLocation:ignoredRange.location
                                                   fallbackPageIndex:0] == samePageChapters[2]);

        puts("SPDFMacMarkdownSidebarModelTests passed");
    }
    return 0;
}
