// Finding a comment's words in the rendered document and in the Markdown source (SPDFMacMarkdownComments.h).
//
// The renderer keeps no map from rendered characters back to source lines, so both texts are reduced to the same
// "normal form" -- markup characters dropped (* _ ` ~ # > | - \ and list bullets), link targets and HTML tags
// removed from the source, whitespace runs collapsed -- with a map from each normal-form character back to where it
// came from. A quote is searched for in normal form. When it occurs more than once, the k-th rendered occurrence is
// taken to be the k-th source occurrence (the two texts list the same prose in the same order), and the stored line
// and heading path pick the right one after the document has been edited.

#import "SPDFMacMarkdownComments.h"

#include <algorithm>
#include <float.h>
#include <limits.h>
#include <vector>

namespace {
struct Normal {
    NSString* text = @"";
    std::vector<NSUInteger> map;  // normal-form index -> index in the original string
};

BOOL Dropped(unichar c) {
    switch (c) {
        case '*': case '_': case '`': case '~': case '#': case '>': case '|': case '-': case '\\': case '[': case ']':
        case 0xFFFC: case 0x200B: case 0x2022: case 0x25E6: case 0x25AA: case 0x2013: case 0x2014:
            return YES;
        default:
            return NO;
    }
}

BOOL Space(unichar c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == 0xA0 || c == 0x2028 || c == 0x2029;
}

// `keep`, when given, marks the characters of `text` that take part (the source hides link targets and tags).
Normal Normalize(NSString* text, const std::vector<bool>* keep) {
    Normal normal;
    NSMutableString* out = [NSMutableString stringWithCapacity:text.length];
    BOOL pendingSpace = NO;
    NSUInteger spaceAt = 0;
    for (NSUInteger i = 0; i < text.length; i++) {
        if (keep && !(*keep)[i]) continue;
        unichar c = [text characterAtIndex:i];
        if (Space(c)) {
            if (!pendingSpace) spaceAt = i;
            pendingSpace = out.length > 0;
            continue;
        }
        if (Dropped(c)) continue;
        if (pendingSpace) {
            [out appendString:@" "];
            normal.map.push_back(spaceAt);
            pendingSpace = NO;
        }
        [out appendFormat:@"%C", c];
        normal.map.push_back(i);
    }
    normal.text = out;
    return normal;
}

NSString* NormalQuote(NSString* quote) {
    return Normalize(quote, nullptr).text;
}

std::vector<NSUInteger> Occurrences(NSString* haystack, NSString* needle) {
    std::vector<NSUInteger> found;
    if (!needle.length) return found;
    NSRange search = NSMakeRange(0, haystack.length);
    while (search.length >= needle.length) {
        NSRange hit = [haystack rangeOfString:needle options:NSLiteralSearch range:search];
        if (hit.location == NSNotFound) break;
        found.push_back(hit.location);
        search = NSMakeRange(hit.location + 1, haystack.length - hit.location - 1);
    }
    return found;
}

NSString* Collapsed(NSString* text) {
    NSMutableString* out = [NSMutableString string];
    BOOL space = NO;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c == 0xFFFC || c == 0x200B) continue;
        if (Space(c)) { space = out.length > 0; continue; }
        if (space) [out appendString:@" "];
        space = NO;
        [out appendFormat:@"%C", c];
    }
    return out;
}

// Heading text without its inline markup, as the path shows it.
NSString* CleanHeading(NSString* title) {
    static NSRegularExpression* link;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ link = [NSRegularExpression regularExpressionWithPattern:@"!?\\[([^\\]]*)\\]\\([^)]*\\)"
                                                                            options:0 error:nil]; });
    title = [link stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length)
                                      withTemplate:@"$1"];
    NSCharacterSet* markup = [NSCharacterSet characterSetWithCharactersInString:@"*_`~"];
    title = [[title componentsSeparatedByCharactersInSet:markup] componentsJoinedByString:@""];
    return [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}
}  // namespace

@implementation SPDFMarkdownCommentAnchors {
    NSString* _rendered;
    Normal _renderedNormal;
    Normal _sourceNormal;
    std::vector<NSUInteger> _lineStarts;         // source offset of each line
    std::vector<NSInteger> _headingLines;        // 1-based
    NSMutableArray<NSString*>* _headingTitles;   // "## Title"
    std::vector<NSInteger> _headingLevels;
}

- (instancetype)initWithSource:(NSString*)source rendered:(NSString*)rendered {
    if (!(self = [super init])) return nil;
    _rendered = [rendered copy] ?: @"";
    _renderedNormal = Normalize(_rendered, nullptr);
    _headingTitles = [NSMutableArray array];
    [self indexSource:source ?: @""];
    return self;
}

// One pass over the source lines: line starts, headings (ATX and setext, outside fences), and which characters
// count as prose (not fences, front matter, link targets or tags).
- (void)indexSource:(NSString*)source {
    std::vector<bool> keep(source.length, true);
    NSArray<NSString*>* lines = [source componentsSeparatedByString:@"\n"];
    static NSRegularExpression *atx, *hidden, *setext, *tableRule;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      atx = [NSRegularExpression regularExpressionWithPattern:@"^ {0,3}(#{1,6})(?:[ \\t]+(.*?))?(?:[ \\t]+#+)?[ \\t]*$"
                                                      options:0 error:nil];
      hidden = [NSRegularExpression regularExpressionWithPattern:@"\\]\\([^)]*\\)|<[^>\\s][^>]*>" options:0 error:nil];
      setext = [NSRegularExpression regularExpressionWithPattern:@"^ {0,3}(=+|-+)[ \\t]*$" options:0 error:nil];
      tableRule = [NSRegularExpression regularExpressionWithPattern:@"^[ \\t|:-]*-[ \\t|:-]*$" options:0 error:nil];
    });
    NSUInteger offset = 0;
    BOOL fenced = NO, frontMatter = [source hasPrefix:@"---\n"];
    NSString* previous = nil;
    for (NSUInteger index = 0; index < lines.count; index++) {
        NSString* line = lines[index];
        _lineStarts.push_back(offset);
        NSRange whole = NSMakeRange(0, line.length);
        NSString* trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        BOOL fence = [trimmed hasPrefix:@"```"] || [trimmed hasPrefix:@"~~~"];
        BOOL hide = fence || frontMatter;
        if (frontMatter && index > 0 && [trimmed isEqualToString:@"---"]) frontMatter = NO;
        if (fence) fenced = !fenced;
        if (!hide && !fenced) {
            NSTextCheckingResult* heading = [atx firstMatchInString:line options:0 range:whole];
            if (heading) {
                NSRange title = [heading rangeAtIndex:2];
                [self addHeadingLevel:(NSInteger)[heading rangeAtIndex:1].length
                                title:title.location == NSNotFound ? @"" : [line substringWithRange:title]
                                 line:(NSInteger)index + 1];
            } else if (previous.length && [setext firstMatchInString:line options:0 range:whole] &&
                       ![previous hasPrefix:@"#"] && ![previous hasPrefix:@"- "] && ![previous hasPrefix:@"* "]) {
                [self addHeadingLevel:[trimmed hasPrefix:@"="] ? 1 : 2 title:previous line:(NSInteger)index];
                hide = YES;
            } else if ([tableRule firstMatchInString:line options:0 range:whole]) {
                hide = YES;
            }
            for (NSTextCheckingResult* match in [hidden matchesInString:line options:0 range:whole])
                for (NSUInteger i = match.range.location; i < NSMaxRange(match.range); i++) keep[offset + i] = false;
        }
        if (hide) for (NSUInteger i = 0; i < line.length; i++) keep[offset + i] = false;
        previous = hide || fenced ? nil : trimmed;
        offset += line.length + 1;
    }
    _sourceNormal = Normalize(source, &keep);
}

- (void)addHeadingLevel:(NSInteger)level title:(NSString*)title line:(NSInteger)line {
    NSString* clean = CleanHeading(title);
    if (!clean.length) return;
    _headingLines.push_back(line);
    _headingLevels.push_back(level);
    [_headingTitles addObject:[NSString stringWithFormat:@"%@ %@", [@"" stringByPaddingToLength:(NSUInteger)level
                                                                                     withString:@"#" startingAtIndex:0],
                                                         clean]];
}

- (NSInteger)lineForSourceOffset:(NSUInteger)offset {
    auto it = std::upper_bound(_lineStarts.begin(), _lineStarts.end(), offset);
    return (NSInteger)(it - _lineStarts.begin());
}

- (NSArray<NSString*>*)headingPathAtLine:(NSInteger)line {
    NSMutableArray<NSString*>* path = [NSMutableArray array];
    std::vector<NSInteger> levels;
    for (size_t i = 0; i < _headingLines.size() && _headingLines[i] <= line; i++) {
        while (!levels.empty() && levels.back() >= _headingLevels[i]) {
            levels.pop_back();
            [path removeLastObject];
        }
        levels.push_back(_headingLevels[i]);
        [path addObject:_headingTitles[i]];
    }
    return path;
}

// The source line of the k-th rendered occurrence: the k-th source occurrence when both texts have the same number,
// else the source occurrence at the same relative place in the document.
- (NSInteger)lineForRenderedOccurrence:(size_t)k
                           occurrences:(const std::vector<NSUInteger>&)rendered
                                source:(const std::vector<NSUInteger>&)source {
    if (source.empty() || _sourceNormal.map.empty()) return 0;
    size_t index = k;
    if (source.size() != rendered.size()) {
        double fraction = _renderedNormal.text.length ? (double)rendered[k] / _renderedNormal.text.length : 0;
        double best = DBL_MAX;
        for (size_t i = 0; i < source.size(); i++) {
            double distance = fabs((double)source[i] / _sourceNormal.text.length - fraction);
            if (distance < best) { best = distance; index = i; }
        }
    }
    return [self lineForSourceOffset:_sourceNormal.map[source[index]]];
}

// The rendered block around a range, cut to a readable length, as the context written to the file.
- (void)setContextOf:(SPDFMarkdownComment*)comment range:(NSRange)range {
    NSString* text = _rendered;
    NSUInteger start = [text rangeOfString:@"\n" options:NSBackwardsSearch range:NSMakeRange(0, range.location)].location;
    start = start == NSNotFound ? 0 : start + 1;
    NSUInteger end = [text rangeOfString:@"\n" options:0
                                   range:NSMakeRange(NSMaxRange(range), text.length - NSMaxRange(range))].location;
    if (end == NSNotFound) end = text.length;
    NSString* before = Collapsed([text substringWithRange:NSMakeRange(start, range.location - start)]);
    // A list item's bullet is drawn, not written: the quote reads as the item's words.
    if ([before hasPrefix:@"• "]) before = [before substringFromIndex:2];
    NSString* after = Collapsed([text substringWithRange:NSMakeRange(NSMaxRange(range), end - NSMaxRange(range))]);
    const NSUInteger limit = 160;
    if (before.length > limit) {
        NSString* cut = [before substringFromIndex:before.length - limit];
        NSRange space = [cut rangeOfString:@" "];
        before = [@"…" stringByAppendingString:space.location != NSNotFound ? [cut substringFromIndex:space.location + 1]
                                                                             : cut];
    }
    if (after.length > limit) {
        NSString* cut = [after substringToIndex:limit];
        NSRange space = [cut rangeOfString:@" " options:NSBackwardsSearch];
        after = [(space.location != NSNotFound ? [cut substringToIndex:space.location] : cut) stringByAppendingString:@"…"];
    }
    // Keep the space between the passage and the quote: Collapsed() trims the ends.
    if (before.length && range.location > start && Space([text characterAtIndex:range.location - 1]))
        before = [before stringByAppendingString:@" "];
    if (after.length && NSMaxRange(range) < end && Space([text characterAtIndex:NSMaxRange(range)]))
        after = [@" " stringByAppendingString:after];
    comment.contextBefore = before;
    comment.contextAfter = after;
}

- (NSRange)renderedRangeForNormalStart:(NSUInteger)start length:(NSUInteger)length {
    NSUInteger first = _renderedNormal.map[start];
    NSUInteger last = _renderedNormal.map[start + length - 1];
    return NSMakeRange(first, last + 1 - first);
}

- (BOOL)anchorComment:(SPDFMarkdownComment*)comment toRenderedRange:(NSRange)range {
    if (range.location == NSNotFound || NSMaxRange(range) > _rendered.length) return NO;
    NSString* quote = Collapsed([_rendered substringWithRange:range]);
    NSString* normal = NormalQuote(quote);
    if (!normal.length) return NO;
    std::vector<NSUInteger> rendered = Occurrences(_renderedNormal.text, normal);
    std::vector<NSUInteger> source = Occurrences(_sourceNormal.text, normal);
    // The occurrence the selection is: the one starting closest to it.
    size_t k = 0;
    NSUInteger bestDistance = NSUIntegerMax;
    for (size_t i = 0; i < rendered.size(); i++) {
        NSUInteger at = _renderedNormal.map[rendered[i]];
        NSUInteger distance = at > range.location ? at - range.location : range.location - at;
        if (distance < bestDistance) { bestDistance = distance; k = i; }
    }
    comment.quote = quote;
    comment.renderedRange = rendered.empty() ? range : [self renderedRangeForNormalStart:rendered[k] length:normal.length];
    comment.line = rendered.empty() ? 0 : [self lineForRenderedOccurrence:k occurrences:rendered source:source];
    comment.headingPath = comment.line > 0 ? [self headingPathAtLine:comment.line] : @[];
    [self setContextOf:comment range:comment.renderedRange];
    return YES;
}

- (BOOL)placeComment:(SPDFMarkdownComment*)comment {
    NSString* normal = NormalQuote(comment.quote);
    std::vector<NSUInteger> rendered = Occurrences(_renderedNormal.text, normal);
    std::vector<NSUInteger> source = Occurrences(_sourceNormal.text, normal);
    BOOL wasPlaced = comment.placed;
    if (rendered.empty()) {
        comment.renderedRange = NSMakeRange(NSNotFound, 0);
        return wasPlaced;
    }
    // Same heading path first, then nearest to the line it was on.
    size_t best = 0;
    long bestScore = LONG_MAX;
    for (size_t i = 0; i < rendered.size(); i++) {
        NSInteger line = [self lineForRenderedOccurrence:i occurrences:rendered source:source];
        long score = labs((long)(line - comment.line));
        if (![[self headingPathAtLine:line] isEqualToArray:comment.headingPath]) score += 1000000;
        if (score < bestScore) { bestScore = score; best = i; }
    }
    NSInteger line = [self lineForRenderedOccurrence:best occurrences:rendered source:source];
    NSArray* path = line > 0 ? [self headingPathAtLine:line] : comment.headingPath;
    NSString *before = comment.contextBefore, *after = comment.contextAfter;
    comment.renderedRange = [self renderedRangeForNormalStart:rendered[best] length:normal.length];
    [self setContextOf:comment range:comment.renderedRange];
    BOOL changed = !wasPlaced || (line > 0 && line != comment.line) || ![path isEqualToArray:comment.headingPath] ||
                   ![before isEqualToString:comment.contextBefore] || ![after isEqualToString:comment.contextAfter];
    if (line > 0) comment.line = line;
    comment.headingPath = path;
    return changed;
}

- (NSArray<NSDictionary*>*)sourceHeadings {
    NSMutableArray* headings = [NSMutableArray array];
    for (size_t i = 0; i < _headingLines.size(); i++) {
        NSString* title = _headingTitles[i];
        NSRange space = [title rangeOfString:@" "];
        [headings addObject:@{@"level" : @(_headingLevels[i]), @"line" : @(_headingLines[i]),
                              @"title" : space.location == NSNotFound ? title : [title substringFromIndex:NSMaxRange(space)]}];
    }
    return headings;
}

- (NSRange)renderedRangeForSourceLine:(NSInteger)line {
    NSRange none = NSMakeRange(NSNotFound, 0);
    if (line < 1 || (size_t)line > _lineStarts.size()) return none;
    NSUInteger start = _lineStarts[(size_t)line - 1];
    NSUInteger end = (size_t)line < _lineStarts.size() ? _lineStarts[(size_t)line] : NSUIntegerMax;
    size_t first = SIZE_MAX, last = 0;
    for (size_t i = 0; i < _sourceNormal.map.size(); i++) {
        NSUInteger at = _sourceNormal.map[i];
        if (at >= end) break;
        if (at < start || [_sourceNormal.text characterAtIndex:i] == ' ') continue;
        if (first == SIZE_MAX) first = i;
        last = i;
    }
    if (first == SIZE_MAX) return none;
    NSString* words = [_sourceNormal.text substringWithRange:NSMakeRange(first, last + 1 - first)];
    std::vector<NSUInteger> rendered = Occurrences(_renderedNormal.text, words);
    std::vector<NSUInteger> source = Occurrences(_sourceNormal.text, words);
    if (rendered.empty() || source.empty()) return none;
    size_t k = 0;
    while (k < source.size() && source[k] != first) k++;
    if (k == source.size()) return none;
    size_t pick = k;
    if (source.size() != rendered.size()) {
        double fraction = (double)first / MAX((NSUInteger)1, _sourceNormal.text.length), best = DBL_MAX;
        for (size_t i = 0; i < rendered.size(); i++) {
            double distance = fabs((double)rendered[i] / MAX((NSUInteger)1, _renderedNormal.text.length) - fraction);
            if (distance < best) { best = distance; pick = i; }
        }
    }
    return [self renderedRangeForNormalStart:rendered[pick] length:words.length];
}

- (NSRange)blockRangeAtRenderedLocation:(NSUInteger)location {
    NSString* text = _rendered;
    if (location > text.length) return NSMakeRange(NSNotFound, 0);
    NSUInteger start = [text rangeOfString:@"\n" options:NSBackwardsSearch range:NSMakeRange(0, location)].location;
    start = start == NSNotFound ? 0 : start + 1;
    NSUInteger end = [text rangeOfString:@"\n" options:0 range:NSMakeRange(location, text.length - location)].location;
    if (end == NSNotFound) end = text.length;
    NSRange block = NSMakeRange(start, end - start);
    // Trim whitespace and attachment characters so the quote is the block's words.
    while (block.length && (Space([text characterAtIndex:block.location]) || [text characterAtIndex:block.location] == 0xFFFC ||
                            [text characterAtIndex:block.location] == 0x2022))
        block = NSMakeRange(block.location + 1, block.length - 1);
    while (block.length && (Space([text characterAtIndex:NSMaxRange(block) - 1]) ||
                            [text characterAtIndex:NSMaxRange(block) - 1] == 0xFFFC))
        block.length--;
    return block;
}
@end
