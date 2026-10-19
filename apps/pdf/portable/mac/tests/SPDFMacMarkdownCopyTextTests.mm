// Copying from a Markdown document has to read like the document: paragraphs
// apart, list items and table rows on consecutive lines, cells tab-separated,
// code kept line for line. Before this the PDF-style collapse-whitespace
// transform ran over the whole selection and everything came out as one line.

#import <Cocoa/Cocoa.h>

#import "../SPDFMacMarkdownCopyText.h"
#import "../markdown/SPDFMarkdown.h"

static int gFailures;

static void Expect(BOOL condition, NSString* what, NSString* got) {
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n  got: %s\n", what.UTF8String, [got stringByReplacingOccurrencesOfString:@"\n"
                                                                                               withString:@"\\n"]
                                                                     .UTF8String);
    ++gFailures;
}

// The PDF copy transform, as the reader passes it when the preference is on.
static NSString* Collapse(NSString* text) {
    NSString* trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [trimmed stringByReplacingOccurrencesOfString:@"[\\s\\u00a0]+"
                                              withString:@" "
                                                 options:NSRegularExpressionSearch
                                                   range:NSMakeRange(0, trimmed.length)];
}

int main(void) {
    @autoreleasepool {
        NSString* source = @"# Title\n\n"
                           @"First    paragraph.\n\n"
                           @"Second paragraph.\n\n"
                           @"- one\n- two\n\n"
                           @"| H1 | H2 |\n| --- | --- |\n| a | b |\n| c | d |\n\n"
                           @"```\ncode line 1\ncode line 2\n```\n";
        SPDFMarkdownDocumentModel* model = [[SPDFMarkdownParser new] parseString:source sourceURL:nil error:nil];
        SPDFMarkdownRenderedDocument* rendered =
            [[SPDFMarkdownRenderer new] renderModel:model
                                            options:[SPDFMarkdownRenderOptions defaultOptions]
                                  languageOverrides:nil];
        NSAttributedString* canonical = rendered.attributedString;
        NSString* text = SPDFMacMarkdownCopyText(canonical, NSMakeRange(0, canonical.length), ^NSString*(NSString* t) {
          return Collapse(t);
        });
        NSArray<NSString*>* lines = [text componentsSeparatedByString:@"\n"];

        // The whole selection is many lines, not one.
        Expect(lines.count >= 12, @"the copy keeps its line structure", text);
        // Blocks are separated by exactly one blank line.
        NSUInteger first = [lines indexOfObject:@"First paragraph."];
        Expect(first != NSNotFound, @"the transform still tidies runs of spaces inside a paragraph", text);
        Expect(first != NSNotFound && first + 2 < lines.count && lines[first + 1].length == 0 &&
                   [lines[first + 2] isEqualToString:@"Second paragraph."],
               @"paragraphs are separated by one blank line", text);
        Expect(lines.count > 1 && [lines[0] isEqualToString:@"Title"] && lines[1].length == 0,
               @"a heading stands on its own line, then a blank", text);
        // List items follow one another.
        NSUInteger one = NSNotFound;
        for (NSUInteger i = 0; i < lines.count; ++i)
            if ([lines[i] hasSuffix:@"one"]) one = i;
        Expect(one != NSNotFound && one + 1 < lines.count && [lines[one + 1] hasSuffix:@"two"],
               @"list items are consecutive lines", text);
        // Table rows: cells joined by tabs, no leading tab, rows consecutive, blank line before the table.
        NSUInteger header = [lines indexOfObject:@"H1\tH2"];
        Expect(header != NSNotFound, @"a table row is its cells joined by tabs with no leading tab", text);
        Expect(header != NSNotFound && header + 2 < lines.count && [lines[header + 1] isEqualToString:@"a\tb"] &&
                   [lines[header + 2] isEqualToString:@"c\td"],
               @"table rows are consecutive lines", text);
        Expect(header != NSNotFound && header > 0 && lines[header - 1].length == 0,
               @"a blank line separates the table from the list before it", text);
        // Code keeps its own lines.
        NSUInteger code = [lines indexOfObject:@"code line 1"];
        Expect(code != NSNotFound && code + 1 < lines.count && [lines[code + 1] isEqualToString:@"code line 2"],
               @"a code block keeps its lines", text);
        Expect([text hasSuffix:@"code line 2\n"], @"a selection ending on a line break keeps exactly one", text);

        // Without a transform the structure is the same and inner spacing is kept.
        NSString* raw = SPDFMacMarkdownCopyText(canonical, NSMakeRange(0, canonical.length), nil);
        Expect([raw containsString:@"First    paragraph."], @"without the preference, spacing is left alone", raw);
        Expect([raw containsString:@"\n\nSecond paragraph."], @"blocks are still separated without the preference",
               raw);

        // A partial selection inside one paragraph is just that text.
        NSRange word = [canonical.string rangeOfString:@"Second"];
        Expect([SPDFMacMarkdownCopyText(canonical, word, nil) isEqualToString:@"Second"],
               @"a selection inside a paragraph copies just its text", text);

        if (gFailures == 0) puts("SPDFMacMarkdownCopyTextTests passed");
    }
    return gFailures == 0 ? 0 : 1;
}
