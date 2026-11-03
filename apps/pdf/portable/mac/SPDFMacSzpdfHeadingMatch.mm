// Which heading a --heading names (SPDFMacSzpdfHeadingMatch.h).
#import "SPDFMacSzpdfHeadingMatch.h"

#include <vector>

#include "spdf_link.h"

static NSString* const kPathSeparator = @" › ";

static NSString* Collapsed(NSString* text) {
    NSArray* words = [text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [[words filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]]
        componentsJoinedByString:@" "];
}

NSArray<NSDictionary*>* SPDFMacSzpdfHeadingRows(NSArray<NSString*>* titles, NSArray<NSNumber*>* levels) {
    NSMutableArray* rows = [NSMutableArray array];
    NSMutableArray<NSString*>* path = [NSMutableArray array];
    std::vector<NSInteger> stack;
    for (NSUInteger i = 0; i < titles.count; i++) {
        NSInteger level = i < levels.count ? levels[i].integerValue : 1;
        while (!stack.empty() && stack.back() >= level) {
            stack.pop_back();
            [path removeLastObject];
        }
        stack.push_back(level);
        [path addObject:titles[i]];
        [rows addObject:@{@"title" : titles[i], @"level" : @(level), @"path" : [path copy]}];
    }
    return rows;
}

// Edit distance between two short strings, for "did you mean".
static NSUInteger Distance(NSString* a, NSString* b) {
    NSUInteger n = MIN(a.length, (NSUInteger)200), m = MIN(b.length, (NSUInteger)200);
    std::vector<NSUInteger> previous(m + 1), current(m + 1);
    for (NSUInteger j = 0; j <= m; j++) previous[j] = j;
    for (NSUInteger i = 1; i <= n; i++) {
        current[0] = i;
        unichar x = [a characterAtIndex:i - 1];
        for (NSUInteger j = 1; j <= m; j++) {
            NSUInteger cost = x == [b characterAtIndex:j - 1] ? 0 : 1;
            current[j] = MIN(MIN(previous[j] + 1, current[j - 1] + 1), previous[j - 1] + cost);
        }
        previous.swap(current);
    }
    return previous[m];
}

typedef BOOL (^Test)(NSString* candidate, NSString* wanted);

static NSDictionary* Row(NSArray<NSDictionary*>* headings, NSUInteger index) {
    NSMutableDictionary* row = [headings[index] mutableCopy];
    row[@"index"] = @(index);
    return row;
}

NSDictionary* SPDFMacSzpdfMatchHeading(NSArray<NSDictionary*>* headings, NSString* wanted) {
    NSString* text = Collapsed([wanted stringByReplacingOccurrencesOfString:@" > " withString:kPathSeparator]);
    BOOL byPath = [text containsString:kPathSeparator];
    NSMutableArray<NSString*>* candidates = [NSMutableArray array];
    for (NSDictionary* heading in headings) {
        NSArray* path = heading[@"path"] ?: @[ heading[@"title"] ?: @"" ];
        NSUInteger depth = byPath ? [text componentsSeparatedByString:kPathSeparator].count : 1;
        NSArray* tail = [path subarrayWithRange:NSMakeRange(path.count - MIN(depth, path.count), MIN(depth, path.count))];
        NSMutableArray* parts = [NSMutableArray array];
        for (NSString* part in tail) [parts addObject:Collapsed(part)];
        [candidates addObject:[parts componentsJoinedByString:kPathSeparator]];
    }
    NSArray<NSArray*>* tiers = @[
        @[ @"exact", ^BOOL(NSString* c, NSString* w) { return [c isEqualToString:w]; } ],
        @[ @"case", ^BOOL(NSString* c, NSString* w) { return [c caseInsensitiveCompare:w] == NSOrderedSame; } ],
        @[ @"prefix", ^BOOL(NSString* c, NSString* w) {
             return [c rangeOfString:w options:NSCaseInsensitiveSearch | NSAnchoredSearch].location != NSNotFound;
         } ],
        @[ @"substring", ^BOOL(NSString* c, NSString* w) {
             return [c rangeOfString:w options:NSCaseInsensitiveSearch].location != NSNotFound;
         } ],
    ];
    for (NSArray* tier in text.length ? tiers : @[]) {
        Test test = tier[1];
        NSMutableIndexSet* found = [NSMutableIndexSet indexSet];
        for (NSUInteger i = 0; i < candidates.count; i++)
            if (test(candidates[i], text)) [found addIndex:i];
        if (found.count == 1) return @{@"index" : @(found.firstIndex), @"match" : tier[0]};
        if (found.count > 1) {
            NSMutableArray* matches = [NSMutableArray array];
            [found enumerateIndexesUsingBlock:^(NSUInteger i, BOOL* stop) {
              (void)stop;
              [matches addObject:Row(headings, i)];
            }];
            NSString* message = [NSString
                stringWithFormat:@"“%@” matches %lu headings. Give more of the heading, or its path "
                                 @"(\"Parent › Heading\"); `szpdf headings` lists them.",
                                 wanted, (unsigned long)found.count];
            return @{@"errorCode" : @"heading-ambiguous", @"error" : message, @"matches" : matches};
        }
    }
    // The link slug ("pull-ups", "intro-1" for the second "Intro"), as szpdf: links and #fragments name headings.
    if (!byPath && text.length) {
        std::vector<const char*> titles;
        for (NSDictionary* heading in headings) titles.push_back([heading[@"title"] ?: @"" UTF8String]);
        int found = spdf_link_match_title(text.UTF8String, titles.data(), (int)titles.size());
        if (found >= 0) return @{@"index" : @(found), @"match" : @"slug"};
    }
    NSMutableArray<NSNumber*>* order = [NSMutableArray array];
    std::vector<NSUInteger> distances;
    NSString* lower = text.lowercaseString;
    for (NSUInteger i = 0; i < candidates.count; i++) {
        NSString* candidate = candidates[i].lowercaseString;
        // A heading that starts like the text, or the text like the heading, counts by its common length.
        NSString* start = candidate.length > lower.length ? [candidate substringToIndex:lower.length] : candidate;
        distances.push_back(MIN(Distance(lower, candidate), Distance(lower, start) + 1));
        [order addObject:@(i)];
    }
    [order sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSNumber* a, NSNumber* b) {
      NSUInteger x = distances[a.unsignedIntegerValue], y = distances[b.unsignedIntegerValue];
      return x < y ? NSOrderedAscending : x > y ? NSOrderedDescending : NSOrderedSame;
    }];
    NSMutableArray* closest = [NSMutableArray array];
    for (NSNumber* index in [order subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)5, order.count))])
        [closest addObject:Row(headings, index.unsignedIntegerValue)];
    NSString* message = headings.count
                            ? [NSString stringWithFormat:@"No heading matches “%@”. The closest are listed in "
                                                         @"\"closest\"; `szpdf headings` lists them all.", wanted]
                            : [NSString stringWithFormat:@"No heading matches “%@”: this document has no headings.",
                                                         wanted];
    return @{@"errorCode" : @"heading-not-found", @"error" : message, @"closest" : closest};
}
