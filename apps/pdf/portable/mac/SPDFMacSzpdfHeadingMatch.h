#pragma once
// Which heading `szpdf open --heading` (and `comment add --heading`) means. Foundation only; shared by the reader
// (SPDFMacAgentServerCommands.mm) and the tool (SPDFMacSzpdf.mm), tested in mac/tests/SPDFMacSzpdfTests.mm.
//
// The text is compared with each heading's title, in tiers; the first tier with any match decides:
//   1. the title exactly,
//   2. the title ignoring case,
//   3. the start of the title, ignoring case ("4. DisplayPort AUX" for '4. DisplayPort AUX (nets "SBU1"/"SBU2")'),
//   4. any part of the title, ignoring case,
//   5. the heading's link slug ("pull-ups" for "Pull-ups", as #fragments in links name it).
// Text with " › " or " > " in it is a path, "Wiring › Pull-ups", matched against the end of each heading's path (the
// headings it is under, then itself) the same way: that is how to name one of two headings with the same title.
// One match is the answer; two or more in the deciding tier are an error that lists them; none lists the five
// closest headings.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// `headings` holds one dictionary per heading, in document order: "title" (NSString) and "path" (NSArray of the
// titles from the outermost down to this one); anything else in them (page, line, level) is copied into the answer.
// Returns {"index": n, "match": exact|case|prefix|substring|slug} or
// {"errorCode": "heading-ambiguous"|"heading-not-found", "error": message, "matches"|"closest": [headings]}.
FOUNDATION_EXPORT NSDictionary* SPDFMacSzpdfMatchHeading(NSArray<NSDictionary*>* headings, NSString* wanted);

// The path dictionaries above, from titles and levels in document order.
FOUNDATION_EXPORT NSArray<NSDictionary*>* SPDFMacSzpdfHeadingRows(NSArray<NSString*>* titles,
                                                                 NSArray<NSNumber*>* levels);

NS_ASSUME_NONNULL_END
