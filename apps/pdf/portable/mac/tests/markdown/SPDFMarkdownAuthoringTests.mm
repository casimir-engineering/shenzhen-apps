#import "SPDFMarkdownTestSupport.h"
#import "../../markdown/SPDFMarkdown.h"

static SPDFMarkdownDocument* SPDFDocument(NSString* source, SPDFMarkdownPageConfiguration* paper) {
    NSError* error = nil;
    SPDFMarkdownDocumentModel* model = [[SPDFMarkdownParser new] parseString:source sourceURL:nil error:&error];
    SPDFExpect(model && !error, @"authoring fixture parses");
    SPDFMarkdownRenderOptions* options = SPDFMarkdownRenderOptions.defaultOptions;
    options.pageContentSize = paper.printableRect.size;
    return [[SPDFMarkdownDocument alloc] initWithModel:model options:options];
}

int main(void) {
    @autoreleasepool {
        SPDFMarkdownPageConfiguration* A4 = SPDFMarkdownPageConfiguration.A4PortraitConfiguration;
        NSError* error = nil;
        SPDFExpect(SPDFMarkdownPageConfigurationForFrontMatter(@{}, A4, &error) == A4,
            @"ordinary documents allocate no author configuration");
        SPDFExpect(SPDFMarkdownPageConfigurationForFrontMatter(@{@"title":@"Notes"}, A4, &error) == A4,
            @"unrelated metadata adds no author configuration work");
        SPDFMarkdownPageConfiguration* paper = SPDFMarkdownPageConfigurationForFrontMatter(
            @{@"paper-size":@"Letter", @"paper-orientation":@"landscape", @"paper-margin":@"36",
              @"paper-margin-top":@"48", @"paper-margin-left":@"24"}, A4, &error);
        SPDFExpect(paper && !error && NSEqualSizes(paper.paperSize, NSMakeSize(792, 612)) &&
            NSEqualRects(paper.printableRect, NSMakeRect(24, 36, 732, 528)),
            @"named paper, orientation and asymmetric margins resolve in points");
        SPDFMarkdownPageConfiguration* rotated = SPDFMarkdownPageConfigurationByOrienting(paper, SPDFMarkdownPageOrientationPortrait);
        SPDFExpect(NSEqualSizes(rotated.paperSize, NSMakeSize(612, 792)) &&
            rotated.topContentInset == 48 && NSMinX(rotated.printableRect) == 24,
            @"manual rotation preserves authored side-specific margins");
        for (NSDictionary* invalid in @[
            @{@"paper-size":@"A99"}, @{@"paper-orientation":@"diagonal"},
            @{@"paper-margin":@"-1"}, @{@"paper-margin":@"nan"}, @{@"paper-margin":@"30mm"},
            @{@"paper-margin":@"999"}, @{@"paper-margin":@"12oops"}, @{@"paper-margin":@12}]) {
            error = nil;
            SPDFExpect(!SPDFMarkdownPageConfigurationForFrontMatter(invalid, A4, &error) && error.localizedDescription.length,
                @"invalid page options return actionable errors");
        }
        for (NSString* size in @[@"A3", @"A4", @"A5", @"Letter", @"Legal"]) {
            error = nil;
            SPDFExpect(SPDFMarkdownPageConfigurationForFrontMatter(@{@"paper-size":size}, A4, &error) && !error,
                @"every documented paper size resolves");
        }
        NSString* source = @"<!-- pagebreak -->\n\n# First\n\nAlpha.\n\n<!-- pagebreak -->\n\n"
            @"<!-- pagebreak -->\n\n# Second\n\nBeta.\n\n<!-- pagebreak -->\n";
        SPDFMarkdownDocument* document = SPDFDocument(source, A4);
        SPDFMarkdownPaginationPlan* plan = [document paginationPlanForConfiguration:A4];
        SPDFExpect(plan.pages.count == 2, @"explicit breaks force pages without leading, trailing or repeated empty sheets");
        SPDFExpect([document.renderedDocument.attributedString.string isEqualToString:@"First\nAlpha.\nSecond\nBeta.\n"],
            @"page directives emit no visible text and do not shift canonical coordinates");
        NSRange beta = [document.renderedDocument.attributedString.string rangeOfString:@"Beta"];
        BOOL betaOnSecond = NO;
        for (SPDFMarkdownPageFragment* fragment in plan.pages.lastObject.fragments)
            if (NSIntersectionRange(beta, fragment.attributedRange).length) betaOnSecond = YES;
        SPDFExpect(betaOnSecond, @"following text starts on the requested page");
        SPDFMarkdownDocument* literal = SPDFDocument(@"`<!-- pagebreak -->`\n\n```html\n<!-- pagebreak -->\n```\n", A4);
        SPDFExpect([literal paginationPlanForConfiguration:A4].pages.count == 1 &&
            [literal.renderedDocument.attributedString.string containsString:@"<!-- pagebreak -->"],
            @"code examples remain text and never execute page directives");
        SPDFMarkdownDocument* ordinary = SPDFDocument(@"# Same\n\nPlain content.\n", A4);
        SPDFMarkdownDocument* comments = SPDFDocument(@"# Same\n\n<!-- ordinary comment -->\n\nPlain content.\n", A4);
        SPDFExpect(!ordinary.authoredPageConfiguration, @"ordinary documents have no authored paper object");
        SPDFExpect([ordinary.renderedDocument.attributedString.string isEqualToString:comments.renderedDocument.attributedString.string],
            @"non-directive comments remain invisible");

        SPDFMarkdownPageConfiguration* shortPaper = [SPDFMarkdownPageConfiguration configurationForPaperSize:NSMakeSize(350, 210)
            printableRect:NSMakeRect(36, 36, 278, 138)];
        NSMutableString* content = [@"# Section\n\n| ID | Choice | Reason |\n| --- | --- | --- |\n" mutableCopy];
        for (NSUInteger i = 0; i < 12; ++i) [content appendFormat:@"| %lu | Approved | A readable row. |\n", (unsigned long)i];
        [content appendString:@"\n```text\n"];
        for (NSUInteger i = 0; i < 30; ++i) [content appendFormat:@"code line %lu\n", (unsigned long)i];
        [content appendString:@"```\n\n## Child\n\nEnd.\n\n# Next\n\nNew section.\n"];
        SPDFMarkdownDocument* longDocument = SPDFDocument(content, shortPaper);
        SPDFMarkdownPaginationPlan* longPlan = [longDocument paginationPlanForConfiguration:shortPaper];
        NSDictionary* report = SPDFMarkdownLayoutReport(longDocument.model, longDocument.renderedDocument, longPlan);
        SPDFExpect([NSJSONSerialization isValidJSONObject:report], @"layout report is ready for JSON transport");
        SPDFExpect([report[@"pageCount"] unsignedIntegerValue] == longPlan.pages.count &&
            [report[@"coordinateSpace"] isEqual:@"canonical-utf16"], @"report identifies its exact canonical contract");
        BOOL splitTable = NO, splitCode = NO;
        for (NSDictionary* diagnostic in report[@"diagnostics"]) {
            if ([diagnostic[@"kind"] isEqual:@"split-table"]) splitTable = YES;
            if ([diagnostic[@"kind"] isEqual:@"split-code"]) splitCode = YES;
        }
        SPDFExpect(splitTable && splitCode, @"report identifies tables and code fences crossing pages");
        for (NSDictionary* section in report[@"sections"]) {
            double fraction = 0;
            for (NSDictionary* portion in section[@"portions"]) fraction += [portion[@"fraction"] doubleValue];
            SPDFExpect(fabs(fraction - 1) < 0.00001, @"each section's per-page fractions sum to one");
        }
        NSArray* sections = report[@"sections"];
        SPDFExpect(sections.count == 3 && [sections[0][@"title"] isEqual:@"Section"] &&
            [sections[1][@"title"] isEqual:@"Child"] && [sections[2][@"title"] isEqual:@"Next"],
            @"section report follows heading order and nesting");
        NSUInteger firstEnd = [sections[0][@"range"][@"location"] unsignedIntegerValue] +
            [sections[0][@"range"][@"length"] unsignedIntegerValue];
        SPDFExpect(firstEnd == [sections[2][@"range"][@"location"] unsignedIntegerValue],
            @"parent sections include descendants and end before the next peer heading");
        NSDictionary* repeated = SPDFMarkdownLayoutReport(longDocument.model, longDocument.renderedDocument, longPlan);
        SPDFExpect([report isEqual:repeated], @"inspection is deterministic for the same render and plan");
    }
    return SPDFFinishTests(@"SPDFMarkdownAuthoringTests");
}
