#pragma once
#import <Foundation/Foundation.h>

// Context is anchored to the actual occurrence, never to the first occurrence
// of the query in a neighboring line. All ranges use canonical UTF-16 offsets.
static inline NSDictionary* SPDFSearchSnippet(NSString* text, NSRange hit,
                                             NSUInteger before, NSUInteger after) {
    if (!text.length || hit.location == NSNotFound || !hit.length ||
        hit.location > text.length || hit.length > text.length-hit.location)
        return @{@"title":text ?: @"", @"matchRanges":@[]};
    NSUInteger start = hit.location-MIN(before,hit.location);
    NSUInteger end = NSMaxRange(hit)+MIN(after,text.length-NSMaxRange(hit));
    NSRange window = [text rangeOfComposedCharacterSequencesForRange:NSMakeRange(start,end-start)];
    NSMutableString* result = [NSMutableString string];
    __block NSUInteger matchStart = NSNotFound, matchEnd = 0;
    NSCharacterSet* spaces = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    if (window.location) [result appendString:@"…"];
    [text enumerateSubstringsInRange:window options:NSStringEnumerationByComposedCharacterSequences
        usingBlock:^(NSString* value, NSRange range, NSRange enclosing, BOOL* stop) {
            (void)enclosing; (void)stop;
            BOOL whitespace = [spaces characterIsMember:[value characterAtIndex:0]] || [value isEqual:@"\ufffc"];
            NSUInteger offset = result.length;
            if (!whitespace) [result appendString:value];
            else if (result.length && ![result hasSuffix:@" "]) [result appendString:@" "];
            if (NSIntersectionRange(range,hit).length) {
                if (matchStart == NSNotFound) matchStart = offset;
                matchEnd = result.length;
            }
        }];
    while ([result hasSuffix:@" "]) [result deleteCharactersInRange:NSMakeRange(result.length-1,1)];
    matchEnd = MIN(matchEnd,result.length);
    if (NSMaxRange(window)<text.length) [result appendString:@"…"];
    NSArray* ranges = matchStart != NSNotFound && matchEnd>matchStart
        ? @[[NSValue valueWithRange:NSMakeRange(matchStart,matchEnd-matchStart)]] : @[];
    return @{@"title":result, @"matchRanges":ranges};
}

static inline NSArray<NSValue*>* SPDFSearchTextRanges(NSString* text, NSString* query, BOOL regex, BOOL multiline) {
    if (!text.length || !query.length) return @[];
    NSMutableArray* ranges = [NSMutableArray array];
    if (regex) {
        NSRegularExpressionOptions options = NSRegularExpressionCaseInsensitive | NSRegularExpressionAnchorsMatchLines;
        if (multiline) options |= NSRegularExpressionDotMatchesLineSeparators;
        NSRegularExpression* expression = [NSRegularExpression regularExpressionWithPattern:query options:options error:nil];
        [expression enumerateMatchesInString:text options:0 range:NSMakeRange(0,text.length)
            usingBlock:^(NSTextCheckingResult* match, NSMatchingFlags flags, BOOL* stop) {
                (void)flags; (void)stop;
                if (match.range.length) [ranges addObject:[NSValue valueWithRange:match.range]];
            }];
    } else {
        NSUInteger offset = 0;
        while (offset<text.length) {
            NSRange hit = [text rangeOfString:query options:NSCaseInsensitiveSearch|NSDiacriticInsensitiveSearch
                range:NSMakeRange(offset,text.length-offset)];
            if (hit.location == NSNotFound || !hit.length) break;
            [ranges addObject:[NSValue valueWithRange:hit]]; offset=NSMaxRange(hit);
        }
    }
    return ranges;
}
