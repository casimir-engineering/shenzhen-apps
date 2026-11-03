// szpdf's parts that need no window (SPDFMacSzpdfInternal.h): the command table against the parser and the help, the
// heading matcher, the documents laid out in the tool's process (headings, find, pictures, PDF export, new comments),
// check, features held to the renderer, version blocks, comment changes and the event-driven wait. Headless; runs in
// about a second (make mac-szpdf-tests).
#import "SPDFMacAgentComments.h"
#import "SPDFMacMarkdownComments.h"
#import "SPDFMacSzpdf.h"
#import "SPDFMacSzpdfHeadingMatch.h"
#import "SPDFMacSzpdfInternal.h"
#import "markdown/SPDFMarkdownDiagram.h"
#import "markdown/SPDFMarkdownHTMLInternal.h"
#import "markdown/SPDFMarkdownLanguage.h"
#import "markdown/SPDFMarkdownParser.h"
#import "markdown/SPDFMarkdownRenderer.h"

#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>

static int gFailures;

static void Expect(BOOL condition, NSString* message) {
    if (condition) return;
    gFailures++;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
}

#pragma mark - Commands, help and parsing

static void TestCommandTable(void) {
    // One good command line per command; each must parse, and each has full help.
    NSDictionary<NSString*, NSArray*>* samples = @{
        @"open" : @[ @"open", @"a.md", @"--heading", @"Power", @"--reload", @"--json" ],
        @"reload" : @[ @"reload", @"a.md" ], @"close" : @[ @"close", @"42" ], @"state" : @[ @"state" ],
        @"headings" : @[ @"headings", @"a.md" ], @"outline" : @[ @"outline", @"a.pdf" ],
        @"find" : @[ @"find", @"a.md", @"4.7 kΩ", @"--limit", @"3" ],
        @"screenshot" : @[ @"screenshot", @"a.md", @"p.png", @"--page", @"2", @"--region", @"0,0,100,50", @"--scale", @"1" ],
        @"export-page" : @[ @"export-page", @"a.pdf", @"3", @"p.png" ],
        @"export-pdf" : @[ @"export-pdf", @"a.md", @"a.pdf" ],
        @"comments" : @[ @"comments", @"a.md", @"--wait-new", @"--since", @"2026-11-03T05:40:28+08:00", @"--timeout", @"5" ],
        @"comment add" : @[ @"comment", @"add", @"a.md", @"--quote", @"two pull-ups", @"Why two?" ],
        @"comment reply" : @[ @"comment", @"reply", @"a.md", @"m1", @"Done." ],
        @"comment resolve" : @[ @"comment", @"resolve", @"a.md", @"m1" ],
        @"version new" : @[ @"version", @"new", @"a.md", @"--carry", @"all" ],
        @"version list" : @[ @"version", @"list", @"a.md" ],
        @"version compare" : @[ @"version", @"compare", @"a.md", @"1", @"2", @"--wait" ],
        @"check" : @[ @"check", @"a.md" ], @"features" : @[ @"features", @"--format", @"md" ],
        @"schema" : @[ @"schema", @"open" ], @"help" : @[ @"help", @"comment", @"add" ],
    };
    for (NSDictionary* entry in SPDFMacSzpdfCommandTable()) {
        NSString* name = entry[@"name"];
        NSArray* sample = samples[name];
        Expect(sample != nil, [@"a sample command line for " stringByAppendingString:name]);
        NSError* error = nil;
        NSDictionary* parsed = sample ? SPDFMacSzpdfParseArguments(sample, @"/work", &error) : nil;
        Expect(parsed != nil, [NSString stringWithFormat:@"%@ parses: %@", name, error.localizedDescription]);
        NSString* help = SPDFMacSzpdfHelpText(name);
        Expect([help containsString:@"Usage: szpdf "] && [help containsString:@"Example:"],
               [@"help with usage and example: " stringByAppendingString:name]);
        if (!entry[@"alias"] && ![@[ @"help", @"schema", @"export-page" ] containsObject:name])
            Expect([help containsString:@"JSON fields:"] && [help containsString:@"ok "],
                   [@"help lists the fields: " stringByAppendingString:name]);
        NSDictionary* asHelp = SPDFMacSzpdfParseArguments([sample arrayByAddingObject:@"--help"], @"/work", nil);
        if (![name isEqual:@"help"])
            Expect([asHelp[@"command"] isEqual:@"help"] && [asHelp[@"topic"] isEqual:name], [@"--help on " stringByAppendingString:name]);
    }
    NSDictionary* add = SPDFMacSzpdfParseArguments(samples[@"comment add"], @"/work", nil);
    Expect([add[@"command"] isEqual:@"comment-add"] && [add[@"quote"] isEqual:@"two pull-ups"] &&
               [add[@"text"] isEqual:@"Why two?"] && [add[@"path"] isEqual:@"/work/a.md"],
           @"comment add fields");
    NSDictionary* shot = SPDFMacSzpdfParseArguments(samples[@"screenshot"], @"/work", nil);
    Expect([shot[@"region"] isEqual:(@[ @0, @0, @100, @50 ])] && [shot[@"page"] isEqual:@2] && [shot[@"scale"] isEqual:@1],
           @"screenshot of a page");
    Expect([SPDFMacSzpdfParseArguments(@[ @"--version" ], @"/", nil)[@"command"] isEqual:@"version-info"], @"--version");
    Expect([SPDFMacSzpdfParseArguments(@[ @"--help" ], @"/", nil)[@"command"] isEqual:@"help"], @"--help alone");
    NSArray* wrong = @[
        @[ @"comment", @"add", @"a.md", @"x" ], @[ @"comment", @"add", @"a.md", @"--line", @"2", @"--quote", @"q", @"x" ],
        @[ @"comment", @"add", @"a.md", @"--line", @"0", @"x" ], @[ @"screenshot", @"a.md", @"p.png" ],
        @[ @"screenshot", @"4", @"p.png", @"--scale", @"2" ], @[ @"screenshot", @"4", @"p.png", @"--page", @"1", @"--region", @"1,2" ],
        @[ @"export-page", @"a.pdf", @"0", @"p.png" ], @[ @"export-pdf", @"a.md", @"a.png" ], @[ @"find", @"a.md" ],
        @[ @"comments", @"a.md", @"--since", @"2026-11-03T05:40:28Z" ], @[ @"comments", @"a.md", @"--wait-new", @"--since", @"soon" ],
        @[ @"features", @"--format", @"docx" ], @[ @"close" ], @[ @"nope" ], @[ @"comment", @"delete", @"a.md" ],
    ];
    for (NSArray* arguments in wrong) {
        NSError* error = nil;
        Expect(!SPDFMacSzpdfParseArguments(arguments, @"/", &error) && error.code == 2,
               [NSString stringWithFormat:@"refused: %@", arguments]);
    }
    NSError* error = nil;
    SPDFMacSzpdfParseArguments(@[ @"open" ], @"/", &error);
    Expect([error.localizedDescription isEqual:@"szpdf open needs <file>."] &&
               [SPDFMacSzpdfUsageText(error.userInfo[SPDFMacSzpdfUsageCommandKey]) containsString:@"Run \"szpdf help open\""],
           [@"open with no file: " stringByAppendingString:error.localizedDescription ?: @""]);
    NSDictionary* schema = SPDFMacSzpdfSchema(nil);
    Expect([schema[@"commands"] count] == SPDFMacSzpdfCommandTable().count && schema[@"errorCodes"][@"heading-ambiguous"],
           @"schema lists every command and the codes");
    Expect([NSJSONSerialization isValidJSONObject:schema], @"schema is JSON");
    NSDictionary* normal = SPDFMacSzpdfNormalized(@{@"error" : @"No.", @"errorCode" : @"not-open", @"x" : @1});
    Expect([normal[@"ok"] isEqual:@NO] && [normal[@"error"][@"code"] isEqual:@"not-open"] && !normal[@"errorCode"],
           @"a reader's error becomes {code, message}");
    Expect([SPDFMacSzpdfNormalized(@{@"x" : @1})[@"ok"] isEqual:@YES], @"ok when there is no error");
}

static void TestHeadingMatch(void) {
    NSArray* titles = @[ @"Overview", @"4. DisplayPort AUX (nets \"SBU1\"/\"SBU2\")", @"Wiring", @"Pull-ups", @"Power",
                         @"Pull-ups", @"Power rails" ];
    NSArray* rows = SPDFMacSzpdfHeadingRows(titles, @[ @1, @2, @2, @3, @2, @3, @2 ]);
    Expect([rows[3][@"path"] isEqual:(@[ @"Overview", @"Wiring", @"Pull-ups" ])], @"heading paths");
    Expect([SPDFMacSzpdfMatchHeading(rows, @"4. DisplayPort AUX")[@"index"] isEqual:@1], @"a prefix finds the long heading");
    Expect([SPDFMacSzpdfMatchHeading(rows, @"displayport aux")[@"index"] isEqual:@1], @"any part, any case");
    Expect([SPDFMacSzpdfMatchHeading(rows, @"Power")[@"index"] isEqual:@4], @"exact wins over a prefix");
    NSDictionary* two = SPDFMacSzpdfMatchHeading(rows, @"Pull-ups");
    Expect([two[@"errorCode"] isEqual:@"heading-ambiguous"] && [two[@"matches"] count] == 2, @"two headings: ambiguous");
    Expect([SPDFMacSzpdfMatchHeading(rows, @"Wiring › Pull-ups")[@"index"] isEqual:@3] &&
               [SPDFMacSzpdfMatchHeading(rows, @"power > pull")[@"index"] isEqual:@5],
           @"a path picks one of them");
    Expect([SPDFMacSzpdfMatchHeading(rows, @"power-rails")[@"index"] isEqual:@6], @"the link slug");
    NSDictionary* miss = SPDFMacSzpdfMatchHeading(rows, @"Wirng");
    Expect([miss[@"errorCode"] isEqual:@"heading-not-found"] && [miss[@"closest"] count] == 5 &&
               [miss[@"closest"][0][@"title"] isEqual:@"Wiring"],
           [NSString stringWithFormat:@"a miss lists the closest: %@", miss[@"closest"]]);
}

#pragma mark - Documents

static NSString* gFolder;

static NSString* Write(NSString* name, NSString* text) {
    NSString* path = [gFolder stringByAppendingPathComponent:name];
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return path;
}

// A one-colour PNG of the given size (compresses to almost nothing; its decoded size is what counts).
static void WritePicture(NSString* name, size_t width, size_t height) {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceGray();
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, 0, space, kCGImageAlphaNone);
    CGImageRef image = CGBitmapContextCreateImage(context);
    NSURL* url = [NSURL fileURLWithPath:[gFolder stringByAppendingPathComponent:name]];
    [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent withIntermediateDirectories:YES
                                            attributes:nil error:nil];
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(destination, image, NULL);
    CGImageDestinationFinalize(destination);
    CFRelease(destination);
    CGImageRelease(image);
    CGContextRelease(context);
    CGColorSpaceRelease(space);
}

static NSString* const kReport =
    @"# Board\n\nThe board needs two pull-ups on SDA before power-on.\n\n## Wiring\n\nUse 4.7 kΩ on SDA and SCL.\n\n"
    @"![ok](img/small.png)\n\n![big](img/huge.png)\n\n![gone](img/missing.png)\n\n<script>alert(1)</script>\n\n"
    @"<span style=\"color:red\">red?</span>\n\nSee [power](#power) and [nowhere](#nowhere) and [other](other.md).[^1]\n\n"
    @"## Power\n\nTwo pull-ups on SDA here too.\n\n```mermaid\nmindmap\n  root\n```\n\n## Wiring\n\nAgain.\n";

static void TestDocument(void) {
    WritePicture(@"img/small.png", 40, 30);
    WritePicture(@"img/huge.png", 6000, 6000);
    NSString* path = Write(@"report.md", kReport);
    NSDictionary* failure = nil;
    SPDFMacSzpdfDocument* document = [SPDFMacSzpdfDocument documentAtPath:path failure:&failure];
    Expect(document != nil && document.markdown && document.pageCount >= 1, @"a Markdown document lays out");
    NSArray* headings = document.headings;
    Expect(headings.count == 4 && [headings[1][@"line"] isEqual:@5] && [headings[3][@"line"] isEqual:@30] &&
               [headings[1][@"duplicate"] boolValue] && [headings[1][@"page"] isEqual:@1] &&
               [headings[2][@"path"] isEqual:(@[ @"Board", @"Power" ])],
           [NSString stringWithFormat:@"headings with lines, pages, paths: %@", headings]);
    NSDictionary* found = [document find:@"pull-ups on sda" caseSensitive:NO limit:10];
    Expect([found[@"count"] isEqual:@2] && [found[@"matches"][1][@"line"] isEqual:@23] &&
               [found[@"matches"][1][@"headingPath"] isEqual:(@[ @"Board", @"Power" ])],
           [NSString stringWithFormat:@"find: %@", found]);
    Expect([[document find:@"pull-ups on sda" caseSensitive:YES limit:10][@"count"] isEqual:@0], @"find --case");

    SPDFMarkdownComment* atLine = [document commentAt:@{@"line" : @7} failure:&failure];
    Expect([atLine.quote isEqual:@"Use 4.7 kΩ on SDA and SCL."] && atLine.line == 7, @"a comment on a line takes its block");
    Expect(![document commentAt:@{@"line" : @2} failure:&failure] &&
               [failure[@"error"][@"code"] isEqual:@"line-out-of-range"],
           @"a blank line is refused");
    Expect(![document commentAt:@{@"quote" : @"pull-ups on SDA"} failure:&failure] &&
               [failure[@"error"][@"code"] isEqual:@"quote-ambiguous"] && [failure[@"matches"] count] == 2,
           @"a quote that occurs twice lists where");
    Expect(![document commentAt:@{@"heading" : @"Wiring"} failure:&failure] &&
               [failure[@"error"][@"code"] isEqual:@"heading-ambiguous"],
           @"a duplicate heading is ambiguous");
    SPDFMarkdownComment* power = [document commentAt:@{@"heading" : @"Board › Power"} failure:&failure];
    Expect([power.quote isEqual:@"Power"] && power.line == 21, [NSString stringWithFormat:@"a heading by path: %@", power.quote]);
    power.author = @"Claude";
    power.text = @"Check the rails.";
    power.date = NSDate.date;
    NSError* error = nil;
    NSDictionary* added = SPDFMacAgentAddMarkdownComment(path, power, &error);
    NSDictionary* listing = SPDFMacAgentListComments(path, nil);
    Expect(added && [listing[@"comments"][0][@"id"] isEqual:added[@"id"]] &&
               [listing[@"comments"][0][@"text"] isEqual:@"Check the rails."],
           [NSString stringWithFormat:@"the added comment lists with the same id: %@ %@", added, error]);

    NSString* page = [gFolder stringByAppendingPathComponent:@"p1.png"];
    NSDictionary* picture = [document writePage:1 toPNG:page scale:1 region:@[ @0, @0, @200, @100 ]];
    Expect([picture[@"width"] isEqual:@200] && [picture[@"height"] isEqual:@100], @"a region of a page");
    Expect([[document writePage:99 toPNG:page scale:1 region:nil][@"error"][@"code"] isEqual:@"page-out-of-range"],
           @"a page past the end");
    NSString* pdfPath = [gFolder stringByAppendingPathComponent:@"report.pdf"];
    Expect([[document writePDF:pdfPath][@"pageCount"] isEqual:@(document.pageCount)], @"export-pdf");
    SPDFMacSzpdfDocument* pdf = [SPDFMacSzpdfDocument documentAtPath:pdfPath failure:nil];
    Expect(pdf.pageCount == document.pageCount && [[pdf find:@"4.7" caseSensitive:NO limit:5][@"count"] intValue] == 1,
           @"the PDF reads back, its text searchable");
    NSDictionary* note = SPDFMacAgentAddPDFComment(pdfPath, @{@"page" : @1}, @"A note.", @"Claude", &error);
    Expect([note[@"date"] isKindOfClass:NSString.class] && [note[@"page"] isEqual:@1] && [note[@"id"] hasPrefix:@"p"],
           [NSString stringWithFormat:@"a PDF note carries its date: %@ %@", note, error]);
    NSDictionary* mark = SPDFMacAgentAddPDFComment(pdfPath, @{@"quote" : @"before power-on"}, @"Hm.", @"Claude", &error);
    Expect([mark[@"type"] isEqual:@"Highlight"] && [mark[@"quote"] containsString:@"power-on"],
           [NSString stringWithFormat:@"a highlight on a quote: %@ %@", mark, error]);
    Expect(!SPDFMacAgentAddPDFComment(pdfPath, @{@"quote" : @"SDA"}, @"x", @"y", &error) &&
               [error.userInfo[SPDFMacAgentCommentsErrorCodeKey] isEqual:@"quote-ambiguous"],
           @"a PDF quote that occurs twice");

    // check: what the reader will do with it.
    Write(@"report - comments.md", [NSString stringWithContentsOfFile:SPDFMarkdownCommentsFilePath(path)
                                                             encoding:NSUTF8StringEncoding error:nil]);
    Write(@"report.md", [kReport stringByReplacingOccurrencesOfString:@"## Power\n" withString:@"## Supply\n"]);
    NSDictionary* report = SPDFMacSzpdfCheck([SPDFMacSzpdfDocument documentAtPath:path failure:nil]);
    NSMutableDictionary* lines = [NSMutableDictionary dictionary];
    for (NSDictionary* issue in report[@"issues"]) lines[issue[@"code"]] = issue[@"line"];
    NSDictionary* expected = @{@"image-missing" : @13, @"html-dropped" : @15,
                               @"html-ignored" : @17, @"broken-anchor" : @19, @"broken-link" : @19, @"footnote" : @19,
                               @"diagram-as-code" : @25, @"duplicate-heading" : @30, @"comment-unplaced" : @21};
    for (NSString* code in expected)
        Expect([lines[code] isEqual:expected[code]], [NSString stringWithFormat:@"check %@ at line %@: %@", code,
                                                                                expected[code], report[@"issues"]]);
    Expect([report[@"errors"] intValue] >= 4, @"errors counted");
}

#pragma mark - Features against the renderer

static NSString* Shown(NSString* markdown) {
    SPDFMarkdownDocumentModel* model = [[SPDFMarkdownParser new] parseString:markdown sourceURL:nil error:nil];
    NSMutableString* text = [NSMutableString string];
    for (SPDFMarkdownBlock* block in model.blocks) [text appendString:block.plainText ?: @""];
    return text;
}

static void TestFeatures(void) {
    NSDictionary* all = SPDFMacSzpdfFeatures(@"all");
    Expect([NSJSONSerialization isValidJSONObject:all], @"features is JSON");
    NSUInteger md = 0, pdf = 0;
    for (NSDictionary* feature in all[@"features"]) {
        md += [feature[@"format"] isEqual:@"md"];
        pdf += [feature[@"format"] isEqual:@"pdf"];
        Expect([@[ @"yes", @"partial", @"no" ] containsObject:feature[@"support"]] && [feature[@"notes"] isKindOfClass:NSString.class],
               [NSString stringWithFormat:@"a feature row: %@", feature]);
        NSString* name = feature[@"name"];
        if ([feature[@"area"] isEqual:@"html"] && [name hasPrefix:@"<"]) {
            NSString* tag = [name substringWithRange:NSMakeRange(1, name.length - 2)];
            if ([@[ @"img", @"br" ] containsObject:tag]) continue;
            if ([feature[@"notes"] isEqual:@"removed"]) {  // void tags: nothing of them shows
                Expect([Shown([NSString stringWithFormat:@"a <%@ name=\"x\"> b\n", tag]) isEqual:@"a  b"] ||
                           ![Shown([NSString stringWithFormat:@"a <%@ name=\"x\"> b\n", tag]) containsString:@"<"],
                       [@"a void tag is removed: " stringByAppendingString:tag]);
                continue;
            }
            NSString* shown = Shown([NSString stringWithFormat:@"a <%@>inside</%@> b\n", tag, tag]);
            BOOL kept = [shown containsString:@"inside"];
            Expect(kept == ![feature[@"support"] isEqual:@"no"] && ![shown containsString:@"<"],
                   [NSString stringWithFormat:@"<%@> is %@ and renders as \"%@\"", tag, feature[@"support"], shown]);
        }
        if ([feature[@"area"] isEqual:@"code"] && ![name isEqual:@"other languages"])
            Expect([SPDFMarkdownLanguageCatalog.sharedCatalog languageForFenceIdentifier:name] != nil,
                   [@"a listed language highlights: " stringByAppendingString:name]);
        if ([feature[@"area"] isEqual:@"diagrams"] && [feature[@"example"] hasPrefix:@"```"]) {
            NSArray* fence = [feature[@"example"] componentsSeparatedByString:@"\n"];
            NSString* body = [[fence subarrayWithRange:NSMakeRange(1, fence.count - 2)] componentsJoinedByString:@"\n"];
            Expect(SPDFMarkdownDiagramRender([fence[0] substringFromIndex:3], body, NSMakeSize(470, 600), 1, nil) != nil,
                   [@"the example draws as a diagram: " stringByAppendingString:name]);
        }
    }
    Expect(md > 80 && pdf >= 4 && [SPDFMacSzpdfFeatures(@"pdf")[@"features"] count] == pdf, @"both formats, and the filter");
    Expect([all[@"limits"][@"imageFileBytes"] isEqual:@(SPDFMarkdownRenderOptions.defaultOptions.maximumResourceBytes)] &&
               all[@"limits"][@"decodedImagePixels"] == nil,
           @"the picture limit is the renderer's, and there is no pixel budget");
    Expect([Shown(@"Text[^1]\n")containsString:@"[^1]"], @"footnotes show as written, as listed");
}

#pragma mark - Changes

static void TestChanges(void) {
    NSArray* blocks = SPDFMacSzpdfDiffLines(@[ @"a", @"b", @"c", @"d" ], @[ @"a", @"B", @"c", @"d", @"e" ]);
    Expect(blocks.count == 2 && [blocks[0][@"kind"] isEqual:@"changed"] && [blocks[0][@"old"][@"from"] isEqual:@2] &&
               [blocks[0][@"before"] isEqual:@"b"] && [blocks[0][@"after"] isEqual:@"B"] &&
               [blocks[1][@"kind"] isEqual:@"added"] && [blocks[1][@"new"][@"from"] isEqual:@5] &&
               [blocks[1][@"old"][@"count"] isEqual:@0],
           [NSString stringWithFormat:@"diff blocks: %@", blocks]);
    Expect([SPDFMacSzpdfDiffLines(@[ @"x", @"y" ], @[ @"x" ])[0][@"kind"] isEqual:@"removed"], @"removed lines");
    Expect(SPDFMacSzpdfDiffLines(@[ @"x" ], @[ @"x" ]).count == 0, @"no change, no block");

    NSDictionary* comment = @{@"id" : @"m1", @"text" : @"Why?", @"status" : @"open", @"date" : @"2026-11-03T05:40:28+08:00",
                              @"replies" : @[]};
    NSMutableDictionary* answered = [comment mutableCopy];
    answered[@"replies"] = @[ @{@"author" : @"Raph", @"text" : @"Because.", @"date" : @"2026-11-03T06:00:00+08:00"} ];
    answered[@"status"] = @"resolved";
    NSArray* changes = SPDFMacSzpdfCommentChanges(@[ comment ], @[ answered ], nil);
    Expect(changes.count == 2 && [changes[0][@"kind"] isEqual:@"resolved"] && [changes[1][@"kind"] isEqual:@"reply"] &&
               [changes[1][@"reply"][@"text"] isEqual:@"Because."],
           [NSString stringWithFormat:@"resolved and answered: %@", changes]);
    Expect([SPDFMacSzpdfCommentChanges(@[ comment ], @[], nil)[0][@"kind"] isEqual:@"removed"], @"removed");
    NSDate* since = SPDFMacSzpdfParseISODate(@"2026-11-03T05:50:00+08:00");
    Expect(SPDFMacSzpdfCommentChanges(@[ answered ], @[ answered ], since).count == 1, @"--since: the later reply counts");
}

static void TestWait(void) {
    NSString* path = Write(@"wait/notes.md", @"# Notes\n\nCheck the rails.\n");
    SPDFMarkdownComment* comment = [SPDFMarkdownComment new];
    comment.quote = @"Check the rails.";
    comment.text = @"Which rails?";
    comment.author = @"Raph";
    comment.date = NSDate.date;
    comment.line = 3;
    NSDictionary* added = SPDFMacAgentAddMarkdownComment(path, comment, nil);
    __block NSDictionary* answer = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSDate* start = NSDate.date;
    SPDFMacSzpdfWatchComments(path, nil, 10, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(NSDictionary* result) {
      answer = result;
      dispatch_semaphore_signal(done);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
      SPDFMacAgentReplyToComment(path, added[@"id"], @"The 3.3 V ones.", @"Claude", nil);
    });
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    Expect([answer[@"changes"] count] == 1 && [answer[@"changes"][0][@"kind"] isEqual:@"reply"] &&
               ![answer[@"timedOut"] boolValue] && [NSDate.date timeIntervalSinceDate:start] < 2,
           [NSString stringWithFormat:@"the wait wakes on a reply: %@", answer]);
    answer = nil;
    SPDFMacSzpdfWatchComments(path, nil, 0.3, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(NSDictionary* result) {
      answer = result;
      dispatch_semaphore_signal(done);
    });
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
    Expect([answer[@"timedOut"] boolValue] && [answer[@"changes"] count] == 0, @"and times out quietly");
}

int main(void) {
    @autoreleasepool {
        gFolder = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"szpdf-tests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        [NSFileManager.defaultManager createDirectoryAtPath:gFolder withIntermediateDirectories:YES attributes:nil error:nil];
        gFolder = gFolder.stringByResolvingSymlinksInPath;
        TestCommandTable();
        TestHeadingMatch();
        TestDocument();
        TestFeatures();
        TestChanges();
        TestWait();
        [NSFileManager.defaultManager removeItemAtPath:gFolder error:nil];
    }
    if (gFailures) {
        fprintf(stderr, "SPDFMacSzpdfTests failed: %d\n", gFailures);
        return 1;
    }
    printf("SPDFMacSzpdfTests passed\n");
    return 0;
}
