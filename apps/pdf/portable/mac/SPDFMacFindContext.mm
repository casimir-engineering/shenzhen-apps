#import "SPDFMacFindContext.h"
#import "SPDFSearchSnippet.h"
#include "spdf_search_regex.h"

static NSString* CollapsedSpaces(NSString* value) {
    NSMutableString* normalized=[NSMutableString string];
    NSCharacterSet* spaces=NSCharacterSet.whitespaceAndNewlineCharacterSet;
    for (NSUInteger i=0;i<value.length;i++) {
        unichar c=[value characterAtIndex:i];
        if ([spaces characterIsMember:c]) { if (![normalized hasSuffix:@" "]) [normalized appendString:@" "]; }
        else [normalized appendFormat:@"%C",c];
    }
    return normalized;
}


@implementation SPDFMacFindContext {
    NSArray<NSDictionary*>* _candidates;
}
- (instancetype)initWithLines:(const spdf_text_lines*)lines query:(NSString*)query
                        regex:(BOOL)regex multiline:(BOOL)multiline {
    self = [super init]; if (!self) return nil;
    NSMutableString* text = [NSMutableString string]; NSMutableArray* sourceLines = [NSMutableArray array];
    for (int index=0;lines && index<lines->count;index++) {
        spdf_text_line line = lines->items[index];
        NSString* value = line.text ? [NSString stringWithUTF8String:line.text] : nil;
        if (!regex) value=[CollapsedSpaces(value) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!value.length) continue;
        if (text.length) [text appendString:regex ? @"\n" : @" "];
        NSRange range=NSMakeRange(text.length,value.length); [text appendString:value];
        NSRect rect=NSMakeRect(line.bounds.x0,line.bounds.y0,line.bounds.x1-line.bounds.x0,line.bounds.y1-line.bounds.y0);
        [sourceLines addObject:@{@"range":[NSValue valueWithRange:range], @"rect":[NSValue valueWithRect:rect]}];
    }
    NSMutableArray* candidates=[NSMutableArray array];
    NSString* pattern=query;
    if (!regex) pattern=CollapsedSpaces(query);
    else if (multiline) {
        char* rewritten=copy_multiline_regex_pattern(query.UTF8String);
        if (rewritten) {
            // MuPDF's JavaScript regexp spells any character [^]; ICU uses [\\s\\S].
            pattern=[[NSString stringWithUTF8String:rewritten] stringByReplacingOccurrencesOfString:@"[^]" withString:@"[\\s\\S]"];
            free(rewritten);
        }
    }
    for (NSValue* value in SPDFSearchTextRanges(text,pattern,regex,multiline)) {
        NSRange hit=value.rangeValue; NSRect bounds=NSZeroRect; BOOL haveBounds=NO;
        for (NSDictionary* line in sourceLines) {
            NSRange range=[line[@"range"] rangeValue], overlap=NSIntersectionRange(range,hit);
            if (!overlap.length) continue;
            NSRect rect=[line[@"rect"] rectValue];
            // Approximate the horizontal span to distinguish repeated hits on
            // one line; vertical geometry remains exact, including PDF columns.
            CGFloat unit=NSWidth(rect)/MAX(1,range.length);
            rect.origin.x+=(overlap.location-range.location)*unit; rect.size.width=MAX(1,overlap.length*unit);
            bounds=haveBounds ? NSUnionRect(bounds,rect) : rect; haveBounds=YES;
        }
        if (haveBounds) [candidates addObject:@{@"rect":[NSValue valueWithRect:bounds],
            @"snippet":SPDFSearchSnippet(text,hit,24,72)}];
    }
    _candidates=candidates;
    return self;
}
- (NSDictionary*)contextForMatchRect:(NSRect)rect {
    NSDictionary* best=nil; CGFloat bestScore=CGFLOAT_MAX;
    for (NSDictionary* item in _candidates) {
        NSRect candidate=[item[@"rect"] rectValue];
        CGFloat dx=MAX(0,MAX(NSMinX(candidate)-NSMaxX(rect),NSMinX(rect)-NSMaxX(candidate)));
        CGFloat dy=MAX(0,MAX(NSMinY(candidate)-NSMaxY(rect),NSMinY(rect)-NSMaxY(candidate)));
        CGFloat centerY=NSMidY(candidate)-NSMidY(rect), centerX=NSMidX(candidate)-NSMidX(rect);
        CGFloat score=dx*dx+dy*dy+centerY*centerY+.001*centerX*centerX;
        if (score<bestScore) { bestScore=score; best=item[@"snippet"]; }
    }
    return best ?: @{@"title":@"", @"matchRanges":@[]};
}
@end
