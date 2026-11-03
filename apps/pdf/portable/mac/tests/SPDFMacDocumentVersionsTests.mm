// Versions of a document (SPDFMacDocumentVersions.h): how they are stored beside it, that each keeps the comments
// made on it, which comments follow to the new version, and how those find their place again in rewritten text.

#import <Foundation/Foundation.h>

#import "SPDFMacDocumentVersions.h"
#import "SPDFMacMarkdownComments.h"

#include "shenzhen_pdf_core.h"

static int gFailures;

static void Expect(BOOL condition, NSString* message) {
    if (condition) return;
    ++gFailures;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
}

static NSString* TempDirectory(void) {
    NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    return path;
}

static NSString* Read(NSString* path) {
    return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
}

static void Write(NSString* text, NSString* path) {
    [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static NSDate* Modified(NSString* path) {
    return [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil][NSFileModificationDate];
}

static NSString* const kSource = @"# Board\n\n## Setup\n\nThe board needs two pull-ups on SDA before power-on.\n\n"
                                 @"## Power\n\nUse a 3.3 V regulator.\n";
static NSString* const kRendered = @"Board\nSetup\nThe board needs two pull-ups on SDA before power-on.\nPower\n"
                                   @"Use a 3.3 V regulator.\n";

static SPDFMarkdownComment* NewComment(SPDFMarkdownCommentAnchors* anchors, NSString* words, NSString* text) {
    SPDFMarkdownComment* comment = [SPDFMarkdownComment new];
    comment.author = @"Raph";
    comment.text = text;
    comment.date = [NSDate dateWithTimeIntervalSince1970:1761984000];
    [anchors anchorComment:comment toRenderedRange:[kRendered rangeOfString:words]];
    return comment;
}

// Report.md with three comments: one open, one resolved, one whose passage was already gone (listed as Unplaced).
static NSString* MakeCommentedMarkdown(NSString* directory) {
    NSString* path = [directory stringByAppendingPathComponent:@"Report.md"];
    Write(kSource, path);
    NSDate* written = [NSDate dateWithTimeIntervalSince1970:1761900000];
    [NSFileManager.defaultManager setAttributes:@{NSFileModificationDate : written} ofItemAtPath:path error:nil];
    SPDFMarkdownCommentAnchors* anchors =
        [[SPDFMarkdownCommentAnchors alloc] initWithSource:kSource rendered:kRendered];
    SPDFMarkdownComment* open = NewComment(anchors, @"two pull-ups on SDA", @"Which value?");
    SPDFMarkdownComment* done = NewComment(anchors, @"3.3 V regulator", @"Name the part.");
    done.resolved = YES;
    SPDFMarkdownComment* lost = NewComment(anchors, @"Use a 3.3 V", @"Old remark.");
    lost.quote = @"a passage that was removed";
    lost.renderedRange = NSMakeRange(NSNotFound, 0);
    Write(SPDFMarkdownCommentsFileText(@"Report.md", @[ open, done, lost ]), SPDFMarkdownCommentsFilePath(path));
    return path;
}

static void TestNamesAndList(void) {
    NSString* directory = TempDirectory();
    NSString* path = MakeCommentedMarkdown(directory);
    Write(@"x", [directory stringByAppendingPathComponent:@"Reports v1.md"]);   // another document's version
    Write(@"x", [directory stringByAppendingPathComponent:@"Report v1.pdf"]);   // another kind of document
    NSArray<SPDFDocumentVersion*>* versions = SPDFDocumentVersionsList(path);
    Expect(versions.count == 1 && versions[0].current && versions[0].number == 1, @"a document alone is its v1");
    Expect([versions[0].commentsPath isEqualToString:SPDFMarkdownCommentsFilePath(path)], @"its comments file");

    NSError* error = nil;
    SPDFDocumentVersion* v1 = SPDFDocumentVersionsCreate(path, SPDFDocumentVersionCarryOpen, &error);
    Expect(v1 != nil, error.localizedDescription ?: @"create v1");
    NSString* v1Path = [directory stringByAppendingPathComponent:@"Report v1.md"];
    Expect([v1.path isEqualToString:v1Path] && v1.number == 1 && !v1.current, v1.path ?: @"v1 path");
    Expect([Read(v1Path) isEqualToString:kSource] && [Read(path) isEqualToString:kSource], @"same content, both files");
    Expect([Modified(v1Path) isEqualToDate:Modified(path)], @"v1 is dated when its content was written");
    Expect([SPDFDocumentVersionsCurrentPath(v1Path) isEqualToString:path.stringByStandardizingPath],
           @"v1's current file");
    Expect(SPDFDocumentVersionsIsFrozenPath(v1Path) && !SPDFDocumentVersionsIsFrozenPath(path), @"which one is frozen");

    versions = SPDFDocumentVersionsList(v1Path);
    Expect(versions.count == 2 && versions[0].number == 1 && versions[1].number == 2 && versions[1].current,
           [NSString stringWithFormat:@"list from v1: %@", [versions valueForKey:@"name"]]);
    NSDictionary* json = versions[1].dictionaryRepresentation;
    Expect([json[@"name"] isEqualToString:@"v2"] && [json[@"current"] boolValue] && [json[@"date"] length] > 0,
           json.description);
    Expect([NSJSONSerialization isValidJSONObject:json], @"a version is JSON");

    SPDFDocumentVersion* v2 = SPDFDocumentVersionsCreate(v1Path, SPDFDocumentVersionCarryOpen, &error);
    Expect(v2.number == 2 && [v2.path.lastPathComponent isEqualToString:@"Report v2.md"],
           @"New Version from an old version freezes the current file");
    Expect(SPDFDocumentVersionsList(path).lastObject.number == 3, @"then the current file is v3");
    Expect(!SPDFDocumentVersionsSupportsPath(SPDFMarkdownCommentsFilePath(path)), @"a comments file has no versions");
}

// v1 keeps every comment, with its file naming v1; the open ones follow to the current file, Unplaced kept.
static void TestCommentsStayOnTheirVersion(void) {
    NSString* directory = TempDirectory();
    NSString* path = MakeCommentedMarkdown(directory);
    NSUInteger open = 0;
    Expect(SPDFDocumentVersionsCommentCount(path, &open) == 3 && open == 2, @"three comments, two open");
    NSString* before = Read(SPDFMarkdownCommentsFilePath(path));
    NSError* error = nil;
    SPDFDocumentVersion* v1 = SPDFDocumentVersionsCreate(path, SPDFDocumentVersionCarryOpen, &error);
    NSString* v1Comments = Read(v1.commentsPath ?: @"/nonexistent");
    Expect([v1Comments hasPrefix:@"# Comments on Report v1.md\n"], v1Comments ?: @"v1 comments file");
    Expect([[v1Comments substringFromIndex:[v1Comments rangeOfString:@"\n"].location]
               isEqualToString:[before substringFromIndex:[before rangeOfString:@"\n"].location]],
           @"v1's comments are exactly the ones made on it");

    NSString* now = Read(SPDFMarkdownCommentsFilePath(path));
    Expect([now hasPrefix:@"# Comments on Report.md\n"], now ?: @"current comments file");
    Expect([now containsString:@"Which value?"] && ![now containsString:@"Name the part."],
           @"only open comments follow");
    NSRange unplaced = [now rangeOfString:@"## Unplaced"];
    Expect(unplaced.location != NSNotFound && [now rangeOfString:@"Which value?"].location < unplaced.location &&
               [now rangeOfString:@"Old remark."].location > unplaced.location,
           [@"placed stays placed, unplaced stays unplaced:\n" stringByAppendingString:now]);

    // Carrying nothing leaves the new version without a comments file.
    SPDFDocumentVersionsCreate(path, SPDFDocumentVersionCarryNone, &error);
    Expect(![NSFileManager.defaultManager fileExistsAtPath:SPDFMarkdownCommentsFilePath(path)], @"carry none");
    Expect([Read([directory stringByAppendingPathComponent:@"Report v2 - comments.md"]) containsString:@"Which value?"],
           @"v2 keeps the comments it had");
}

// An agent rewrote the document: the previous content becomes the last version with its comments, and the carried
// comments find their words and heading in the new text, or are listed as Unplaced.
static void TestKeepPreviousAndReanchor(void) {
    NSString* directory = TempDirectory();
    NSString* path = MakeCommentedMarkdown(directory);
    NSString* snapshot = [TempDirectory() stringByAppendingPathComponent:@"previous"];
    [NSFileManager.defaultManager copyItemAtPath:path toPath:snapshot error:nil];
    NSDate* previousDate = Modified(path);
    NSString* rewritten = @"# Board\n\n## Intro\n\nNew opening paragraph.\n\n## Setup\n\n"
                          @"First, solder the header.\n\n"
                          @"The board needs two pull-ups on SDA before power-on.\n\n"
                          @"## Power\n\nUse a buck converter.\n";
    Write(rewritten, path);

    NSError* error = nil;
    SPDFDocumentVersion* v1 =
        SPDFDocumentVersionsKeepPrevious(path, snapshot, previousDate, SPDFDocumentVersionCarryOpen, &error);
    Expect(v1 != nil, error.localizedDescription ?: @"keep previous");
    Expect([Read(v1.path) isEqualToString:kSource] && [v1.date isEqualToDate:previousDate], @"v1 holds the old text");
    Expect([Read(path) isEqualToString:rewritten], @"the document holds the new text");
    Expect([Read(v1.commentsPath ?: @"/nonexistent") containsString:@"Name the part."], @"v1 keeps the resolved one");

    // What the reader does after a render: place each carried comment on the new text.
    NSString* rendered = @"Board\nIntro\nNew opening paragraph.\nSetup\nFirst, solder the header.\n"
                         @"The board needs two pull-ups on SDA before power-on.\nPower\nUse a buck converter.\n";
    SPDFMarkdownCommentAnchors* anchors =
        [[SPDFMarkdownCommentAnchors alloc] initWithSource:rewritten rendered:rendered];
    NSArray<SPDFMarkdownComment*>* carried = SPDFMarkdownCommentsParseFile(Read(SPDFMarkdownCommentsFilePath(path)));
    Expect(carried.count == 2, [NSString stringWithFormat:@"%lu carried", (unsigned long)carried.count]);
    for (SPDFMarkdownComment* comment in carried) [anchors placeComment:comment];
    SPDFMarkdownComment* pullUps = carried.firstObject;
    Expect(pullUps.placed && pullUps.line == 11 &&
               [pullUps.headingPath isEqualToArray:(@[ @"# Board", @"## Setup" ])],
           [NSString stringWithFormat:@"moved with its heading: line %ld %@", (long)pullUps.line, pullUps.headingPath]);
    Expect([[rendered substringWithRange:pullUps.renderedRange] isEqualToString:@"two pull-ups on SDA"], @"its words");
    Expect(!carried.lastObject.placed, @"a comment whose words are gone stays unplaced");
    NSString* file = SPDFMarkdownCommentsFileText(@"Report.md", carried);
    Expect([file rangeOfString:@"Old remark."].location > [file rangeOfString:@"## Unplaced"].location, file);
}

// A one-page PDF, enough for MuPDF to open and annotate.
static NSString* MakePDF(NSString* path) {
    NSString* stream = @"BT /F1 18 Tf 72 760 Td (Version one) Tj ET";
    NSArray* objects = @[
        @"<< /Type /Catalog /Pages 2 0 R >>", @"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        (@"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R "
         @"/Resources << /Font << /F1 5 0 R >> >> >>"),
        [NSString stringWithFormat:@"<< /Length %lu >>\nstream\n%@\nendstream", (unsigned long)stream.length, stream],
        @"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
    ];
    NSMutableString* pdf = [NSMutableString stringWithString:@"%PDF-1.7\n"];
    NSMutableArray* offsets = [NSMutableArray array];
    for (NSUInteger i = 0; i < objects.count; i++) {
        [offsets addObject:@(pdf.length)];
        [pdf appendFormat:@"%lu 0 obj\n%@\nendobj\n", (unsigned long)i + 1, objects[i]];
    }
    NSUInteger xref = pdf.length;
    [pdf appendFormat:@"xref\n0 %lu\n0000000000 65535 f \n", (unsigned long)objects.count + 1];
    for (NSNumber* offset in offsets) [pdf appendFormat:@"%010lu 00000 n \n", offset.unsignedLongValue];
    [pdf appendFormat:@"trailer\n<< /Size %lu /Root 1 0 R >>\nstartxref\n%lu\n%%%%EOF\n",
                      (unsigned long)objects.count + 1, (unsigned long)xref];
    Write(pdf, path);
    return path;
}

static void TestPDF(void) {
    NSString* path = MakePDF([TempDirectory() stringByAppendingPathComponent:@"Drawing.pdf"]);
    char err[256] = {0};
    spdf_document* doc = spdf_open(path.fileSystemRepresentation, err, sizeof(err));
    Expect(doc && spdf_add_text_comment(doc, 0, 100, 700, "Open remark", "Raph", err, sizeof(err)) &&
               spdf_add_text_comment(doc, 0, 100, 600, "Done remark", "Raph", err, sizeof(err)) &&
               spdf_set_comment_resolved(doc, 1, 1, "Raph", err, sizeof(err)) &&
               spdf_save_document(doc, path.fileSystemRepresentation, err, sizeof(err)),
           [NSString stringWithFormat:@"annotate the PDF: %s", err]);
    if (doc) spdf_close(doc);
    NSUInteger open = 0;
    Expect(SPDFDocumentVersionsCommentCount(path, &open) == 2 && open == 1, @"PDF: two comments, one open");

    NSError* error = nil;
    SPDFDocumentVersion* v1 = SPDFDocumentVersionsCreate(path, SPDFDocumentVersionCarryOpen, &error);
    Expect(v1 && [v1.path.lastPathComponent isEqualToString:@"Drawing v1.pdf"],
           error.localizedDescription ?: @"PDF v1");
    Expect(SPDFDocumentVersionsCommentCount(v1.path, &open) == 2 && open == 1, @"PDF v1 keeps both comments");
    Expect(SPDFDocumentVersionsCommentCount(path, &open) == 1 && open == 1, @"the open one follows to v2");
    SPDFDocumentVersionsCreate(path, SPDFDocumentVersionCarryNone, &error);
    Expect(SPDFDocumentVersionsCommentCount(path, NULL) == 0, @"PDF carry none");
    Expect(SPDFDocumentVersionsList(path).count == 3, @"PDF v1, v2 and the current v3");
}

int main(void) {
    @autoreleasepool {
        TestNamesAndList();
        TestCommentsStayOnTheirVersion();
        TestKeepPreviousAndReanchor();
        TestPDF();
    }
    if (gFailures) {
        fprintf(stderr, "SPDFMacDocumentVersionsTests failed: %d\n", gFailures);
        return 1;
    }
    printf("SPDFMacDocumentVersionsTests passed\n");
    return 0;
}
