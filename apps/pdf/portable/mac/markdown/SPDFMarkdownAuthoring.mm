#import "SPDFMarkdownAuthoring.h"
#import "SPDFMarkdownParser.h"

BOOL SPDFMarkdownHasAuthorPageConfiguration(NSDictionary<NSString*, NSString*>* values) {
    return values[@"paper-size"] || values[@"paper-orientation"] || values[@"paper-margin"] ||
        values[@"paper-margin-top"] || values[@"paper-margin-right"] ||
        values[@"paper-margin-bottom"] || values[@"paper-margin-left"];
}

static SPDFMarkdownPageConfiguration* SPDFInvalidPaper(NSString* message, NSError** error) {
    if (error) *error = [NSError errorWithDomain:SPDFMarkdownErrorDomain code:SPDFMarkdownErrorParseFailed
        userInfo:@{NSLocalizedDescriptionKey:message}];
    return nil;
}

SPDFMarkdownPageConfiguration* SPDFMarkdownPageConfigurationByOrienting(
    SPDFMarkdownPageConfiguration* configuration, SPDFMarkdownPageOrientation orientation) {
    if (configuration.orientation == orientation) return configuration;
    CGFloat top = configuration.topContentInset;
    CGFloat left = NSMinX(configuration.printableRect);
    CGFloat bottom = NSMinY(configuration.printableRect);
    CGFloat right = configuration.paperSize.width - NSMaxX(configuration.printableRect);
    SPDFMarkdownPageConfiguration* result = [configuration copy];
    result.paperSize = NSMakeSize(configuration.paperSize.height, configuration.paperSize.width);
    result.printableRect = NSMakeRect(left, bottom, result.paperSize.width - left - right,
        result.paperSize.height - top - bottom);
    return result;
}

SPDFMarkdownPageConfiguration* SPDFMarkdownPageConfigurationForFrontMatter(
    NSDictionary<NSString*, NSString*>* values, SPDFMarkdownPageConfiguration* fallback, NSError** error) {
    if (!SPDFMarkdownHasAuthorPageConfiguration(values)) return fallback;
    for (NSString* key in @[@"paper-size", @"paper-orientation", @"paper-margin", @"paper-margin-top",
        @"paper-margin-right", @"paper-margin-bottom", @"paper-margin-left"])
        if (values[key] && ![values[key] isKindOfClass:NSString.class])
            return SPDFInvalidPaper([NSString stringWithFormat:@"%@ must be a string.", key], error);
    NSSize paper = fallback.paperSize;
    NSString* name = [values[@"paper-size"] lowercaseString];
    if (name) {
        if ([name isEqualToString:@"a4"]) paper = NSMakeSize(595.2756, 841.8898);
        else if ([name isEqualToString:@"a3"]) paper = NSMakeSize(841.8898, 1190.5512);
        else if ([name isEqualToString:@"a5"]) paper = NSMakeSize(419.5276, 595.2756);
        else if ([name isEqualToString:@"letter"]) paper = NSMakeSize(612, 792);
        else if ([name isEqualToString:@"legal"]) paper = NSMakeSize(612, 1008);
        else return SPDFInvalidPaper(@"paper-size must be A3, A4, A5, Letter, or Legal.", error);
    }
    SPDFMarkdownPageOrientation orientation = fallback.orientation;
    NSString* direction = values[@"paper-orientation"];
    if (direction) {
        if ([direction.lowercaseString isEqualToString:@"landscape"]) orientation = SPDFMarkdownPageOrientationLandscape;
        else if ([direction.lowercaseString isEqualToString:@"portrait"]) orientation = SPDFMarkdownPageOrientationPortrait;
        else return SPDFInvalidPaper(@"paper-orientation must be portrait or landscape.", error);
    }
    CGFloat shortSide = MIN(paper.width, paper.height), longSide = MAX(paper.width, paper.height);
    paper = orientation == SPDFMarkdownPageOrientationLandscape
        ? NSMakeSize(longSide, shortSide) : NSMakeSize(shortSide, longSide);
    CGFloat margins[] = {fallback.topContentInset,
        fallback.paperSize.width - NSMaxX(fallback.printableRect),
        NSMinY(fallback.printableRect), NSMinX(fallback.printableRect)};
    NSArray* keys = @[@"paper-margin", @"paper-margin-top", @"paper-margin-right",
        @"paper-margin-bottom", @"paper-margin-left"];
    for (NSUInteger i = 0; i < keys.count; ++i) {
        NSString* value = values[keys[i]];
        if (!value) continue;
        NSScanner* scanner = [NSScanner scannerWithString:value];
        scanner.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        double points = 0;
        if (![scanner scanDouble:&points] || !scanner.isAtEnd || !isfinite(points) || points < 0)
            return SPDFInvalidPaper([NSString stringWithFormat:@"%@ must be a nonnegative number of points.", keys[i]], error);
        if (!i) for (NSUInteger side = 0; side < 4; ++side) margins[side] = points;
        else margins[i - 1] = points;
    }
    NSRect printable = NSMakeRect(margins[3], margins[2], paper.width - margins[1] - margins[3],
        paper.height - margins[0] - margins[2]);
    if (NSWidth(printable) < 72 || NSHeight(printable) < 72)
        return SPDFInvalidPaper(@"Paper margins must leave at least 72 points of printable width and height.", error);
    SPDFMarkdownPageConfiguration* result = [fallback copy];
    result.paperSize = paper;
    result.printableRect = printable;
    return result;
}
