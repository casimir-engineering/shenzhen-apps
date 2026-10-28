#import "SPDFMarkdownPlanLocationIndex.h"

#include <algorithm>
#include <vector>

// One fragment of the plan, flattened in plan order for the location lookups.
struct SPDFMarkdownPlanFragment {
    NSUInteger location;
    NSUInteger end;
    NSUInteger pagePosition;
    NSUInteger fragmentPosition;
};

@implementation SPDFMarkdownPlanLocationIndex {
    NSArray<SPDFMarkdownPage*>* _pages;
    // Plan order, with running maxima so "the first fragment that ..." is a
    // binary search even where fragments are not in text order (table cells).
    std::vector<SPDFMarkdownPlanFragment> _fragments;
    std::vector<NSUInteger> _runningMaxEnd;
    std::vector<NSUInteger> _runningMaxLocation;
    // Positions into _fragments sorted by location, with running maxima of
    // their ends, for the overlap lookup.
    std::vector<NSUInteger> _byLocation;
    std::vector<NSUInteger> _byLocationMaxEnd;
}
- (instancetype)initWithPages:(NSArray<SPDFMarkdownPage*>*)pages {
    self = [super init];
    if (!self) return nil;
    _pages = pages;
    NSUInteger pagePosition = 0;
    for (SPDFMarkdownPage* page in _pages) {
        NSUInteger fragmentPosition = 0;
        for (SPDFMarkdownPageFragment* fragment in page.fragments) {
            NSRange range = fragment.attributedRange;
            _fragments.push_back({range.location, NSMaxRange(range), pagePosition, fragmentPosition++});
        }
        ++pagePosition;
    }
    NSUInteger maxEnd = 0, maxLocation = 0;
    for (const SPDFMarkdownPlanFragment& fragment : _fragments) {
        maxEnd = std::max(maxEnd, fragment.end);
        maxLocation = std::max(maxLocation, fragment.location);
        _runningMaxEnd.push_back(maxEnd);
        _runningMaxLocation.push_back(maxLocation);
    }
    _byLocation.resize(_fragments.size());
    for (NSUInteger i = 0; i < _fragments.size(); ++i) _byLocation[i] = i;
    std::stable_sort(_byLocation.begin(), _byLocation.end(), [&](NSUInteger a, NSUInteger b) {
        return _fragments[a].location < _fragments[b].location;
    });
    maxEnd = 0;
    for (NSUInteger position : _byLocation) {
        maxEnd = std::max(maxEnd, _fragments[position].end);
        _byLocationMaxEnd.push_back(maxEnd);
    }
    return self;
}

- (SPDFMarkdownPage*)pageForAttributedLocation:(NSUInteger)location fragment:(SPDFMarkdownPageFragment**)outFragment {
    // First i where some fragment up to i ends after `location` or starts at or
    // after it: monotone in i through the running maxima.
    NSUInteger low = 0, high = _fragments.size();
    while (low < high) {
        NSUInteger middle = low + (high - low) / 2;
        if (_runningMaxEnd[middle] > location || _runningMaxLocation[middle] >= location) high = middle;
        else low = middle + 1;
    }
    if (low == _fragments.size()) return nil;
    const SPDFMarkdownPlanFragment& found = _fragments[low];
    SPDFMarkdownPage* page = _pages[found.pagePosition];
    if (outFragment) *outFragment = page.fragments[found.fragmentPosition];
    return page;
}

- (NSInteger)firstPageIndexIntersectingRange:(NSRange)range {
    BOOL empty = range.length == 0;
    NSUInteger limit = empty ? range.location : NSMaxRange(range);
    // Candidates start where the running maximum end first reaches the range
    // and stop at the first fragment starting past it.
    auto first = std::lower_bound(_byLocationMaxEnd.begin(), _byLocationMaxEnd.end(), range.location,
                                  [&](NSUInteger maxEnd, NSUInteger value) {
                                      return empty ? maxEnd < value : maxEnd <= value;
                                  });
    NSUInteger best = NSNotFound;
    for (NSUInteger i = (NSUInteger)(first - _byLocationMaxEnd.begin()); i < _byLocation.size(); ++i) {
        NSUInteger position = _byLocation[i];
        const SPDFMarkdownPlanFragment& fragment = _fragments[position];
        if (empty ? fragment.location > limit : fragment.location >= limit) break;
        BOOL hit = empty ? range.location >= fragment.location && range.location <= fragment.end
                         : fragment.end > fragment.location && fragment.end > range.location;
        if (hit && position < best) best = position;
    }
    return best == NSNotFound ? -1 : (NSInteger)_pages[_fragments[best].pagePosition].pageIndex;
}

@end
