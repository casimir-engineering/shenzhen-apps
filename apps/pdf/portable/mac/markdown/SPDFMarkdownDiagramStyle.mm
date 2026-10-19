#import "SPDFMarkdownDiagramInternal.h"

#import "spdf_recolor.h"

// mermaid per-node styling: the `classDef name key:value,...` declarations, the
// two ways a node claims one (`A[...]:::name` and `class A,B name`), and the
// resolution of an author color for the theme the page is drawn with.
//
// Author colors are the one place a diagram carries color that did NOT come
// from the reading theme, so the dark-theme policy lives here. It is stated
// once, in full, above SPDFMarkdownDiagramAuthorColor in SPDFMarkdownDiagram.h:
// the light theme keeps the author's bytes, and the dark theme puts them
// through the SAME luma remap (spdf_recolor.h, paper #1E1E1E / ink #DCDDDE)
// that already recolors PDF pages and embedded Markdown images, so a diagram
// agrees with the rest of the reader instead of inventing a third answer.

@implementation SPDFMarkdownDiagramNodeStyle
@end

// --- Color values --------------------------------------------------------

static BOOL SPDFStyleHexDigit(unichar character, int* outValue) {
    if (character >= '0' && character <= '9') {
        *outValue = character - '0';
        return YES;
    }
    if (character >= 'a' && character <= 'f') {
        *outValue = character - 'a' + 10;
        return YES;
    }
    if (character >= 'A' && character <= 'F') {
        *outValue = character - 'A' + 10;
        return YES;
    }
    return NO;
}

// `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`, plus `none`/`transparent`. Anything
// else (a CSS name, an rgb() call, a gradient) returns nil, which the caller
// treats as "this key said nothing" -- the node keeps its theme role.
static NSColor* SPDFStyleParseColor(NSString* rawValue) {
    NSString* value = SPDFMarkdownDiagramTrim(rawValue).lowercaseString;
    if (!value.length) return nil;
    if ([value isEqualToString:@"none"] || [value isEqualToString:@"transparent"])
        return [NSColor colorWithSRGBRed:0 green:0 blue:0 alpha:0];
    if (![value hasPrefix:@"#"]) return nil;
    NSString* digits = [value substringFromIndex:1];
    if (digits.length != 3 && digits.length != 4 && digits.length != 6 && digits.length != 8) return nil;
    int nibbles[8] = {0};
    for (NSUInteger index = 0; index < digits.length; ++index)
        if (!SPDFStyleHexDigit([digits characterAtIndex:index], &nibbles[index])) return nil;
    CGFloat channels[4] = {0, 0, 0, 1};
    BOOL shorthand = digits.length <= 4;
    NSUInteger count = shorthand ? digits.length : digits.length / 2;
    for (NSUInteger index = 0; index < count; ++index) {
        int byte = shorthand ? nibbles[index] * 17 : nibbles[index * 2] * 16 + nibbles[index * 2 + 1];
        channels[index] = byte / 255.0;
    }
    return [NSColor colorWithSRGBRed:channels[0] green:channels[1] blue:channels[2] alpha:channels[3]];
}

NSColor* SPDFMarkdownDiagramAuthorColor(NSColor* authored, SPDFMarkdownThemeVariant variant) {
    NSColor* color = [authored colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!color) return authored;
    if (variant != SPDFMarkdownThemeVariantDark) return color;
    // One table per process; the dark endpoints are fixed. Reusing the core's
    // own span primitive (rather than restating the arithmetic) is what makes
    // "a diagram is recolored exactly like a page" a fact instead of a claim.
    static spdf_recolor_table table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      spdf_recolor_table_init(&table, SPDF_RECOLOR_LUMA_REMAP, spdf_recolor_default_dark_theme());
    });
    unsigned char pixel[4] = {
        (unsigned char)lround(MAX(0.0, MIN(1.0, color.redComponent)) * 255),
        (unsigned char)lround(MAX(0.0, MIN(1.0, color.greenComponent)) * 255),
        (unsigned char)lround(MAX(0.0, MIN(1.0, color.blueComponent)) * 255),
        255,
    };
    spdf_recolor_rgba_span(pixel, 0, 1, &table);
    return [NSColor colorWithSRGBRed:pixel[0] / 255.0
                               green:pixel[1] / 255.0
                                blue:pixel[2] / 255.0
                               alpha:color.alphaComponent];
}

// --- Statements ----------------------------------------------------------

// `classDef aon fill:#e1f5ee,stroke:#0f6e56,color:#04342c`, one or more
// comma-separated class names. Unknown keys (stroke-width, stroke-dasharray,
// font-*) are DROPPED rather than rejected: they change nothing this renderer
// can express, and failing on them would cost the whole diagram.
BOOL SPDFMarkdownDiagramParseClassDef(NSString* statement, SPDFMarkdownDiagramGraph* graph) {
    NSString* trimmed = SPDFMarkdownDiagramTrim(statement);
    if (trimmed.length < 9 || ![[trimmed substringToIndex:9].lowercaseString isEqualToString:@"classdef "])
        return NO;
    NSString* body = SPDFMarkdownDiagramTrim([trimmed substringFromIndex:9]);
    NSRange split = [body rangeOfCharacterFromSet:NSCharacterSet.whitespaceCharacterSet];
    if (split.location == NSNotFound) return NO;
    NSArray<NSString*>* names =
        [[body substringToIndex:split.location] componentsSeparatedByString:@","];
    SPDFMarkdownDiagramNodeStyle* style = [SPDFMarkdownDiagramNodeStyle new];
    BOOL usable = NO;
    for (NSString* pair in [[body substringFromIndex:split.location] componentsSeparatedByString:@","]) {
        NSRange colon = [pair rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        NSString* key = SPDFMarkdownDiagramTrim([pair substringToIndex:colon.location]).lowercaseString;
        NSColor* color = SPDFStyleParseColor([pair substringFromIndex:NSMaxRange(colon)]);
        if (!color) continue;
        if ([key isEqualToString:@"fill"]) {
            style.fillColor = color;
        } else if ([key isEqualToString:@"stroke"]) {
            style.strokeColor = color;
        } else if ([key isEqualToString:@"color"]) {
            style.textColor = color;
        } else {
            continue;
        }
        usable = YES;
    }
    if (!usable) return NO;
    for (NSString* rawName in names) {
        NSString* name = SPDFMarkdownDiagramTrim(rawName);
        if (name.length) graph.classStyles[name] = style;
    }
    return YES;
}

// `class A,B aon` / `class A aon;` -- recorded by identifier and folded onto
// the nodes once parsing finishes, so an assignment may precede its nodes.
BOOL SPDFMarkdownDiagramParseClassAssignment(NSString* statement, SPDFMarkdownDiagramGraph* graph) {
    NSString* trimmed = SPDFMarkdownDiagramTrim(statement);
    if (trimmed.length < 6 || ![[trimmed substringToIndex:6].lowercaseString isEqualToString:@"class "])
        return NO;
    NSString* body = SPDFMarkdownDiagramTrim([trimmed substringFromIndex:6]);
    NSRange split = [body rangeOfCharacterFromSet:NSCharacterSet.whitespaceCharacterSet
                                          options:NSBackwardsSearch];
    if (split.location == NSNotFound) return NO;
    NSString* name = SPDFMarkdownDiagramTrim([body substringFromIndex:NSMaxRange(split)]);
    if (!name.length) return NO;
    BOOL assigned = NO;
    for (NSString* rawIdentifier in
         [[body substringToIndex:split.location] componentsSeparatedByString:@","]) {
        NSString* identifier = SPDFMarkdownDiagramTrim(rawIdentifier);
        if (!identifier.length) continue;
        graph.classNamesByIdentifier[identifier] = name;
        assigned = YES;
    }
    return assigned;
}
