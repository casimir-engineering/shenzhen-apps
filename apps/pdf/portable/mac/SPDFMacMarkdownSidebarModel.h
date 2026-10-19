#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@class SPDFMarkdownPaginationPlan;
@class SPDFMarkdownRenderedDocument;
@class SPDFMarkdownSearchMatch;

@interface SPDFMacMarkdownSidebarModel : NSObject

@property(nonatomic, readonly, copy) NSArray<NSDictionary<NSString*, id>*>* chapterItems;

- (instancetype)initWithRenderedDocument:(SPDFMarkdownRenderedDocument*)renderedDocument
                          paginationPlan:(SPDFMarkdownPaginationPlan*)paginationPlan NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (NSArray<NSDictionary<NSString*, id>*>*)chapterItemsMatchingQuery:(NSString*)query;
// Canonical attributed-text location takes precedence. Pass NSNotFound to select by page instead.
- (nullable NSDictionary<NSString*, id>*)chapterItemPrecedingAttributedLocation:(NSUInteger)location
                                                              fallbackPageIndex:(NSInteger)pageIndex;
- (NSArray<NSDictionary<NSString*, id>*>*)searchSidebarItemsForMatches:(NSArray<SPDFMarkdownSearchMatch*>*)matches
                                                                 query:(NSString*)query
                                                             searching:(BOOL)searching;
// Plan page rendering the range (intersection first, nearest preceding
// fragment as the fallback); -1 when the plan is empty. Shared by the sidebar
// items and the find-match metadata.
- (NSInteger)pageIndexForRange:(NSRange)range;

@end

NS_ASSUME_NONNULL_END
