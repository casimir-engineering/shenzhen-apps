#define SPDF_TEXT_DOCUMENT_FORMAT_TESTING 1
#import "SPDFMarkdownTestSupport.h"
#import "../../markdown/SPDFMarkdownDocument.h"
#import "../../markdown/SPDFTextDocumentFormats.h"

static NSURL* SourceURL(NSString* extension) {
    return [NSURL fileURLWithPath:[@"/tmp/sz-source-tests/source." stringByAppendingString:extension]];
}

static SPDFMarkdownDocumentModel* ParseSource(NSData* data, NSString* extension, NSError** error) {
    return [[SPDFMarkdownParser new] parseData:data sourceURL:SourceURL(extension) error:error];
}

static void WriteSourceEvidence(NSString* source, NSString* extension) {
    NSString* directory = NSProcessInfo.processInfo.environment[@"SPDF_SOURCE_DOCUMENT_EVIDENCE_DIR"];
    if (!directory.length) return;
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    SPDFMarkdownDocumentModel* model = [[SPDFMarkdownParser new] parseString:source sourceURL:SourceURL(extension) error:nil];
    SPDFMarkdownDocument* document = [[SPDFMarkdownDocument alloc] initWithModel:model options:SPDFMarkdownRenderOptions.defaultOptions];
    SPDFMarkdownPaginationPlan* plan = [document paginationPlanForConfiguration:SPDFMarkdownPageConfiguration.A4PortraitConfiguration];
    CGSize size = plan.configuration.paperSize;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(NULL, ceil(size.width), ceil(size.height), 8, 0, space, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    CGContextSetRGBFillColor(context, 1, 1, 1, 1);
    CGContextFillRect(context, CGRectMake(0, 0, size.width, size.height));
    SPDFExpect([plan drawPageAtIndex:0 attributedString:document.renderedDocument.attributedString inContext:context],
        @"native source page drawing succeeds");
    CGImageRef image = CGBitmapContextCreateImage(context);
    NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithCGImage:image];
    NSData* png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    SPDFExpect([png writeToFile:[directory stringByAppendingPathComponent:[@"source." stringByAppendingFormat:@"%@.png", extension]]
        atomically:YES], @"source page evidence saved");
    CGImageRelease(image);
    CGContextRelease(context);
}

int main(void) {
    @autoreleasepool {
        SPDFExpect(!SPDFSourceLanguageForPath(@"/tmp/doc.pdf") && !SPDFSourceLanguageForPath(@"/tmp/image.png") &&
            !SPDFSourceLanguageForPath(nil), @"native files and empty startup paths skip source catalog");
        SPDFExpect([SPDFSourceLanguageForPath(@"/tmp/source.py") isEqualToString:@"python"] &&
            SPDFSourceDocumentCatalogBuildCount == 0, @"format lookup initializes no catalog, even for source files");
        NSDictionary* formats = SPDFSourceDocumentLanguageMap();
        SPDFExpect(SPDFSourceDocumentCatalogBuildCount == 1, @"extension catalog materializes only on explicit request");
        NSSet* languages = [NSSet setWithArray:formats.allValues];
        for (SPDFMarkdownLanguage* language in SPDFMarkdownLanguageCatalog.sharedCatalog.languages) {
            if ([language.identifier isEqualToString:@"markdown"]) continue;
            SPDFExpect([languages containsObject:language.identifier],
                [@"source extension exists for code lexer: " stringByAppendingString:language.identifier]);
        }
        for (NSString* extension in SPDFSourceDocumentExtensions()) {
            NSString* language = SPDFSourceLanguageForPath(SourceURL(extension.uppercaseString).path);
            SPDFExpect([SPDFMarkdownLanguageCatalog.sharedCatalog languageForFenceIdentifier:language] != nil,
                [@"advertised extension maps to supported lexer: " stringByAppendingString:extension]);
        }
        SPDFExpect(SPDFSourceDocumentExtensions() == SPDFSourceDocumentExtensions(), @"extension list cached after first use");
        SPDFExpect(!SPDFIsSourceDocumentPath(@"/tmp/image.svg"), @"SVG remains image");
        SPDFExpect(!SPDFIsRenderedTextDocumentPath(@"/tmp/report.pdf"), @"PDF remains native core document");
        SPDFExpect(!SPDFIsSourceDocumentPath(@"/tmp/app.bin"), @"arbitrary binary extension not admitted");
        SPDFExpect(SPDFIsRenderedTextDocumentPath(@"/tmp/README.mdown"), @"mdown is rendered Markdown");
        SPDFExpect(!SPDFIsSourceDocumentPath(@"/tmp/README.md"), @"Markdown does not become source code");

        NSString* literal = @"---\r\npaper-size: bogus\r\n---\r\n```swift\nlet text = `literal`;\n```\n"
            @"<script>alert('never run')</script><img src='https://example.invalid/private.png'>\n# heading\n"
            @"[link](https://example.invalid)\t🙂 café\n";
        SPDFMarkdownParser* parser = [SPDFMarkdownParser new];
        NSError* error = nil;
        for (NSString* extension in @[@"txt", @"html", @"htm", @"xhtml", @"yaml", @"swift"]) {
            SPDFMarkdownDocumentModel* model = [parser parseString:literal sourceURL:SourceURL(extension) error:&error];
            SPDFExpect(model && !error && model.blocks.count == 1, @"source parses directly into one literal code block");
            SPDFExpect([model.blocks.firstObject.plainText isEqualToString:literal], @"source AST round trips exactly incl CRLF/fences/HTML");
            SPDFExpect(model.headings.count == 0 && model.frontMatter.count == 0, @"source is never Markdown/front matter");
            SPDFMarkdownDocument* document = [[SPDFMarkdownDocument alloc] initWithModel:model
                options:SPDFMarkdownRenderOptions.defaultOptions];
            NSAttributedString* rendered = document.renderedDocument.attributedString;
            SPDFExpect([rendered.string isEqualToString:literal], @"literal source renders without Markdown or HTML interpretation");
            __block BOOL activeContent = NO;
            [rendered enumerateAttributesInRange:NSMakeRange(0, rendered.length) options:0
                usingBlock:^(NSDictionary* attributes, NSRange range, BOOL* stop) {
                    (void)range; (void)stop;
                    if (attributes[NSAttachmentAttributeName] || attributes[NSLinkAttributeName]) activeContent = YES;
                }];
            SPDFExpect(!activeContent, @"HTML/source has no active links or image attachments");
            SPDFExpect([document searchForQuery:@"never run" caseSensitive:YES].count == 1, @"source is searchable at literal positions");
        }
        for (NSNumber* encoding in @[@(NSUTF8StringEncoding), @(NSUTF16StringEncoding), @(NSUTF32StringEncoding)]) {
            NSData* bytes = [literal dataUsingEncoding:encoding.unsignedIntegerValue];
            SPDFMarkdownDocumentModel* model = ParseSource(bytes, @"txt", &error);
            SPDFExpect([model.blocks.firstObject.plainText isEqualToString:literal], @"UTF-8 and BOM Unicode encodings decode exactly");
        }
        SPDFMarkdownDocumentModel* empty = ParseSource([NSData data], @"txt", &error);
        SPDFExpect(empty && empty.blocks.firstObject.plainText.length == 0, @"empty text is valid");
        const unsigned char binary[] = {'b', 'p', 'l', 'i', 's', 't', '0', '0', 0, 1, 2};
        error = nil;
        SPDFExpect(!ParseSource([NSData dataWithBytes:binary length:sizeof(binary)], @"plist", &error) && error,
            @"binary plist is rejected instead of rendered as corrupt source");
        const unsigned char invalid[] = {0xff, 0x81};
        error = nil;
        SPDFExpect(!ParseSource([NSData dataWithBytes:invalid length:sizeof(invalid)], @"txt", &error) && error,
            @"invalid unmarked encoding reports actionable error");
        parser.maximumInputBytes = 4;
        error = nil;
        SPDFExpect(![parser parseData:[@"12345" dataUsingEncoding:NSUTF8StringEncoding] sourceURL:SourceURL(@"txt") error:&error]
            && error.code == SPDFMarkdownErrorTooLarge, @"source path respects input budget before decoding");

        NSString* swift = @"let answer = 42\n// Comment\n";
        SPDFMarkdownDocumentModel* model = [[SPDFMarkdownParser new] parseString:swift sourceURL:SourceURL(@"swift") error:nil];
        SPDFMarkdownRenderOptions* options = SPDFMarkdownRenderOptions.defaultOptions;
        SPDFMarkdownDocument* document = [[SPDFMarkdownDocument alloc] initWithModel:model options:options];
        NSAttributedString* normal = document.renderedDocument.attributedString;
        SPDFExpect([[normal attribute:SPDFMarkdownCodeLanguageAttribute atIndex:0 effectiveRange:nil] isEqualToString:@"swift"],
            @"source carries existing code-block language attributes");
        SPDFExpect(![[normal attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:nil] isEqual:options.textColor],
            @"source uses actual Swift keyword highlighting");
        options.fontScale = 1.5;
        NSAttributedString* larger = [document renderedDocumentWithOptions:options languageOverrides:nil].attributedString;
        NSFont* firstFont = [normal attribute:NSFontAttributeName atIndex:0 effectiveRange:nil];
        NSFont* largerFont = [larger attribute:NSFontAttributeName atIndex:0 effectiveRange:nil];
        SPDFExpect(fabs(largerFont.pointSize / firstFont.pointSize - 1.5) < 0.01, @"A+ scales source through existing render options");
        SPDFExpect([larger.string isEqualToString:normal.string], @"text sizing leaves source/search coordinates unchanged");

        NSMutableString* longSource = [NSMutableString string];
        for (NSUInteger i = 0; i < 250; ++i) [longSource appendFormat:@"let line%lu = %lu\n", i, i];
        model = [[SPDFMarkdownParser new] parseString:longSource sourceURL:SourceURL(@"swift") error:nil];
        document = [[SPDFMarkdownDocument alloc] initWithModel:model options:SPDFMarkdownRenderOptions.defaultOptions];
        SPDFMarkdownPaginationPlan* plan = [document paginationPlanForConfiguration:SPDFMarkdownPageConfiguration.A4PortraitConfiguration];
        SPDFExpect(plan.pages.count > 1, @"long source flows through existing page paginator");
        SPDFMarkdownDocumentModel* markdown = [[SPDFMarkdownParser new] parseString:@"# Real heading\n**Bold**"
            sourceURL:SourceURL(@"md") error:nil];
        SPDFExpect(markdown.headings.count == 1, @"ordinary Markdown still uses original parser");
        WriteSourceEvidence(@"<!doctype html>\n<html lang=\"en\">\n<head>\n  <title>Source document preview</title>\n  <style>body { color: #334155; }</style>\n</head>\n<body>\n  <!-- HTML stays literal source -->\n  <h1>Hello, Shenzhen PDF</h1>\n  <p>Text is searchable and selectable.</p>\n  <script>\n    const message = \"Displayed as code, never run\";\n    console.log(message);\n  </script>\n</body>\n</html>\n", @"html");
        WriteSourceEvidence(@"from pathlib import Path\n\n# Read a document without changing its original.\ndef count_words(path: Path) -> int:\n    text = path.read_text(encoding=\"utf-8\")\n    return len(text.split())\n\nif __name__ == \"__main__\":\n    total = count_words(Path(\"notes.txt\"))\n    print(f\"Words: {total}\")\n", @"py");
    }
    return SPDFFinishTests(@"SPDFTextDocumentTests");
}
