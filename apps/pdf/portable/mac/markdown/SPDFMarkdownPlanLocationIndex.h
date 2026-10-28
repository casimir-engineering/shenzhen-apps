#pragma once

#import "SPDFMarkdownPaginator.h"

NS_ASSUME_NONNULL_BEGIN

// The pagination plan's location lookups in O(log n) (see the plan's
// pageForAttributedLocation:fragment: and firstPageIndexIntersectingRange:).
// A search over a large document asks them once per match. Immutable.
@interface SPDFMarkdownPlanLocationIndex : NSObject
- (instancetype)initWithPages:(NSArray<SPDFMarkdownPage*>*)pages NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (nullable SPDFMarkdownPage*)pageForAttributedLocation:(NSUInteger)location
                                               fragment:(SPDFMarkdownPageFragment* _Nullable* _Nullable)fragment;
- (NSInteger)firstPageIndexIntersectingRange:(NSRange)range;
@end

NS_ASSUME_NONNULL_END
