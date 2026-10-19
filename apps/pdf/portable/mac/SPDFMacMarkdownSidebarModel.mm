#import "SPDFMacMarkdownSidebarModel.h"
#import "SPDFSearchSnippet.h"

#import "markdown/SPDFMarkdownPaginator.h"

static NSDictionary<NSString*, id>* SPDFMarkdownSidebarItem(NSString* kind, NSString* title, NSString* subtitle,
                                                            NSString* query, NSInteger page, NSInteger findIndex,
                                                            NSUInteger level, NSRange range) {
    return @{
        @"kind" : kind,
        @"title" : title,
        @"subtitle" : subtitle,
        @"query" : query,
        @"page" : @(page),
        @"findIndex" : @(findIndex),
        @"level" : @(level),
        @"range" : [NSValue valueWithRange:range],
    };
}

@interface SPDFMacMarkdownSidebarModel ()
@property(nonatomic, readonly, strong) SPDFMarkdownRenderedDocument* renderedDocument;
@property(nonatomic, readonly, strong) SPDFMarkdownPaginationPlan* paginationPlan;
@end

@implementation SPDFMacMarkdownSidebarModel

- (instancetype)initWithRenderedDocument:(SPDFMarkdownRenderedDocument*)renderedDocument
                          paginationPlan:(SPDFMarkdownPaginationPlan*)paginationPlan {
    self = [super init];
    if (!self) return nil;
    _renderedDocument = renderedDocument;
    _paginationPlan = paginationPlan;

    NSMutableArray<NSDictionary<NSString*, id>*>* chapters = [NSMutableArray array];
    for (SPDFMarkdownRenderedHeading* heading in renderedDocument.headings) {
        if (heading.level < 1 || heading.level > 3) continue;
        NSInteger page = [self pageIndexForRange:heading.attributedRange];
        [chapters addObject:SPDFMarkdownSidebarItem(@"chapter", heading.title, @"", @"", page, -1, heading.level - 1,
                                                    heading.attributedRange)];
    }
    _chapterItems = [chapters copy];
    return self;
}

- (NSArray<NSDictionary<NSString*, id>*>*)chapterItemsMatchingQuery:(NSString*)query {
    if (query.length == 0) return self.chapterItems;
    NSStringCompareOptions options = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;
    NSPredicate* predicate = [NSPredicate
        predicateWithBlock:^BOOL(NSDictionary<NSString*, id>* item, NSDictionary<NSString*, id>* bindings) {
          (void)bindings;
          return [item[@"title"] rangeOfString:query options:options].location != NSNotFound;
        }];
    return [self.chapterItems filteredArrayUsingPredicate:predicate];
}

- (NSArray<NSDictionary<NSString*, id>*>*)searchSidebarItemsForMatches:(NSArray<SPDFMarkdownSearchMatch*>*)matches
                                                                 query:(NSString*)query
                                                             searching:(BOOL)searching {
    if (matches.count == 0) {
        NSString* title = nil;
        if (searching) {
            title = [NSString stringWithFormat:@"Searching for \"%@\"...", query];
        } else {
            title = query.length ? [NSString stringWithFormat:@"No matches for \"%@\"", query] : @"No search results";
        }
        return @[ SPDFMarkdownSidebarItem(@"findStatus", title, @"", query, -1, -1, 0, NSMakeRange(NSNotFound, 0)) ];
    }

    NSMutableArray<NSDictionary<NSString*, id>*>* items = [NSMutableArray array];
    NSDictionary<NSString*, id>* previousChapter = nil;
    for (NSUInteger index = 0; index < matches.count; ++index) {
        SPDFMarkdownSearchMatch* match = matches[index];
        NSInteger matchPage = [self pageIndexForRange:match.range];
        NSDictionary<NSString*, id>* chapter = [self chapterItemPrecedingAttributedLocation:match.range.location
                                                                          fallbackPageIndex:matchPage];
        if (chapter != previousChapter) {
            NSString* title = chapter ? chapter[@"title"] : @"Document";
            NSInteger page = chapter ? [chapter[@"page"] integerValue] : -1;
            NSUInteger level = chapter ? [chapter[@"level"] unsignedIntegerValue] : 0;
            NSRange range = chapter ? [chapter[@"range"] rangeValue] : NSMakeRange(NSNotFound, 0);
            [items addObject:SPDFMarkdownSidebarItem(@"findDivider", title, @"", query, page, -1, level, range)];
            previousChapter = chapter;
        }

        NSDictionary* snippet=SPDFSearchSnippet(self.renderedDocument.attributedString.string,match.range,24,72);
        NSString* context = snippet[@"title"];
        NSString* subtitle = [NSString stringWithFormat:@"Page %ld - match %lu of %lu", (long)matchPage + 1,
                                                        (unsigned long)index + 1, (unsigned long)matches.count];
        NSMutableDictionary* result=[SPDFMarkdownSidebarItem(@"findResult",context,subtitle,query,matchPage,
            (NSInteger)index,0,match.range) mutableCopy];
        result[@"matchRanges"]=snippet[@"matchRanges"]; [items addObject:result];
    }
    return [items copy];
}

- (NSDictionary<NSString*, id>*)chapterItemPrecedingAttributedLocation:(NSUInteger)location
                                                     fallbackPageIndex:(NSInteger)pageIndex {
    if (location == NSNotFound || location > self.renderedDocument.attributedString.length) {
        if (pageIndex < 0) return nil;

        NSDictionary<NSString*, id>* nearestChapter = nil;
        for (NSDictionary<NSString*, id>* chapter in self.chapterItems) {
            NSInteger chapterPage = [chapter[@"page"] integerValue];
            if (chapterPage > pageIndex) break;
            if (chapterPage == pageIndex) return chapter;
            nearestChapter = chapter;
        }
        return nearestChapter;
    }

    NSUInteger low = 0;
    NSUInteger high = self.chapterItems.count;
    while (low < high) {
        NSUInteger middle = low + (high - low) / 2;
        NSRange range = [self.chapterItems[middle][@"range"] rangeValue];
        if (range.location <= location)
            low = middle + 1;
        else
            high = middle;
    }
    return low == 0 ? nil : self.chapterItems[low - 1];
}

- (NSInteger)pageIndexForRange:(NSRange)range {
    for (SPDFMarkdownPage* page in self.paginationPlan.pages) {
        for (SPDFMarkdownPageFragment* fragment in page.fragments) {
            NSRange fragmentRange = fragment.attributedRange;
            if ((range.length > 0 && NSIntersectionRange(range, fragmentRange).length > 0) ||
                (range.length == 0 && range.location >= fragmentRange.location &&
                 range.location <= NSMaxRange(fragmentRange))) {
                return (NSInteger)page.pageIndex;
            }
        }
    }

    NSInteger nearestPage = -1;
    NSUInteger nearestLocation = 0;
    for (SPDFMarkdownPage* page in self.paginationPlan.pages) {
        for (SPDFMarkdownPageFragment* fragment in page.fragments) {
            if (fragment.attributedRange.location > range.location) continue;
            if (nearestPage < 0 || fragment.attributedRange.location >= nearestLocation) {
                nearestPage = (NSInteger)page.pageIndex;
                nearestLocation = fragment.attributedRange.location;
            }
        }
    }
    return nearestPage;
}

@end
