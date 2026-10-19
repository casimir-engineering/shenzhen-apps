#import "SPDFMacCollectionStorePrivate.h"
#import "markdown/SPDFMarkdownParser.h"
#import <objc/runtime.h>

static int failures;
static NSUInteger parseCalls;
static BOOL pureParsing = YES;
static SPDFMarkdownDocumentModel* (*originalParse)(id, SEL, NSData*, NSURL*, NSError**);

static void Expect(NSString* name, BOOL success) {
    if (!success) { fprintf(stderr,"FAIL %s\n",name.UTF8String); ++failures; }
}

static SPDFMarkdownDocumentModel* TrackParse(id parser, SEL selector, NSData* data, NSURL* URL, NSError** error) {
    ++parseCalls;
    SPDFMarkdownDocumentModel* model = originalParse(parser, selector, data, URL, error);
    pureParsing = pureParsing && URL == nil && model.resourceStore == nil;
    return model;
}

static void ExpectReferences(NSString* name, NSString* path, NSString* source, NSArray<NSString*>* expected) {
    NSDictionary* result = SPDFCollectionAssets(path, [source dataUsingEncoding:NSUTF8StringEncoding]);
    NSArray* actual = [result[@"entries"] valueForKey:@"relativePath"];
    Expect([name stringByAppendingFormat:@" (references: %@)",actual],
           [[NSSet setWithArray:actual] isEqual:[NSSet setWithArray:expected]] && actual.count == expected.count);
    Expect([name stringByAppendingFormat:@" (warnings: %@)",result[@"warnings"]], [result[@"warnings"] count] == 0);
}

int main(void) {
    @autoreleasepool {
        NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        Expect(@"create fixture directory", [NSFileManager.defaultManager createDirectoryAtPath:directory
               withIntermediateDirectories:YES attributes:nil error:nil]);
        NSString* path = [directory stringByAppendingPathComponent:@"example.md"];
        NSArray* files = @[@"private.txt",@"direct.svg",@"full.svg",@"collapsed.svg",@"shortcut.svg",
                           @"inline.svg",@"block.svg",@"space image.svg",@"nested(name).svg",@"a&b.svg"];
        for (NSString* file in files)
            Expect(@"write adjacent fixture", [@"adjacent document data" writeToFile:
                [directory stringByAppendingPathComponent:file] atomically:YES encoding:NSUTF8StringEncoding error:nil]);

        Method parse = class_getInstanceMethod(SPDFMarkdownParser.class, @selector(parseData:sourceURL:error:));
        originalParse = (decltype(originalParse))method_setImplementation(parse, (IMP)TrackParse);
        NSData* imageSyntax = [@"![Example](private.txt)" dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary* unrelated = SPDFCollectionAssets([directory stringByAppendingPathComponent:@"example.pdf"], imageSyntax);
        Expect(@"non-Markdown capture never constructs or invokes a parser", parseCalls == 0 &&
               [unrelated[@"entries"] count] == 0 && [unrelated[@"warnings"] count] == 0);

        NSArray<NSArray<NSString*>*>* literals = @[
            @[@"fenced code", @"```markdown\n![Example](private.txt)\n<img src='private.txt'>\n```\n"],
            @[@"tilde fenced code", @"~~~\n![Example](private.txt)\n~~~\n"],
            @[@"indented code", @"    ![Example](private.txt)\n    <img src='private.txt'>\n"],
            @[@"inline code", @"`![Example](private.txt)` and `<img src='private.txt'>`\n"],
            @[@"HTML comment block", @"<!--\n![Example](private.txt)\n<img src='private.txt'>\n-->\n"],
            @[@"inline HTML comment", @"Before <!-- <img src='private.txt'> --> after\n"],
            @[@"escaped image syntax", @"\\![Example](private.txt)\n\\![Example][target]\n\n[target]: private.txt\n"],
            @[@"unused definition", @"[unused]: private.txt\n\nOrdinary prose.\n"],
            @[@"literal reference syntax", @"`![secret]`\n\n[secret]: private.txt\n"],
            @[@"fenced reference definition", @"![secret]\n\n```\n[secret]: private.txt\n```\n"],
            @[@"undefined image references", @"![secret][missing]\n![missing][]\n![missing]\n"],
            @[@"front matter", @"---\nexample: '![Example](private.txt)'\n---\nBody\n"],
            @[@"ordinary links", @"[Document](private.txt) and <a href='private.txt'>Document</a>\n"],
            @[@"arbitrary HTML attributes", @"<div src='private.txt'>Text</div>\n"],
            @[@"suppressed HTML", @"<script><img src='private.txt'></script>\n"],
            @[@"HTML preformatted code", @"<pre><code>&lt;img src='private.txt'&gt;</code></pre>\n"]
        ];
        for (NSArray<NSString*>* fixture in literals)
            ExpectReferences(fixture[0], path, fixture[1], @[]);

        ExpectReferences(@"all real image reference forms", path,
            @"![Direct](direct.svg)\n![Full][full]\n![collapsed][]\n![shortcut]\n\n"
             "[full]: full.svg\n[collapsed]: collapsed.svg\n[shortcut]: shortcut.svg\n",
            @[@"direct.svg",@"full.svg",@"collapsed.svg",@"shortcut.svg"]);
        ExpectReferences(@"reference labels use parser normalization", path,
            @"![Shown][ Mixed   Case ]\n\n[mixed case]: full.svg\n", @[@"full.svg"]);
        ExpectReferences(@"first duplicate definition wins", path,
            @"![same]\n\n[same]: full.svg\n[same]: private.txt\n", @[@"full.svg"]);
        ExpectReferences(@"empty and formatted image captions", path,
            @"![](direct.svg) ![**bold** caption](full.svg)\n", @[@"direct.svg",@"full.svg"]);
        ExpectReferences(@"parenthesized and spaced destinations", path,
            @"![A](nested(name).svg)\n![B](<space image.svg> \"Caption\")\n",
            @[@"nested(name).svg",@"space image.svg"]);
        ExpectReferences(@"nested image and ordinary link", path,
            @"[![Logo](direct.svg)](private.txt)\n", @[@"direct.svg"]);
        ExpectReferences(@"real inline HTML image", path,
            @"Before <img src=inline.svg alt='Logo'> after\n", @[@"inline.svg"]);
        ExpectReferences(@"real block HTML images", path,
            @"<div><img src='block.svg'><img src=\"a&amp;b.svg\"></div>\n",
            @[@"block.svg",@"a&b.svg"]);
        ExpectReferences(@"real and literal adjacent images", path,
            @"![Actual](direct.svg) `![Example](private.txt)`\n\n"
             "```\n![Example](private.txt)\n```\n\n<img src='inline.svg'>\n",
            @[@"direct.svg",@"inline.svg"]);
        ExpectReferences(@"duplicate image use captures once", path,
            @"![One](direct.svg) ![Two](direct.svg)\n", @[@"direct.svg"]);

        NSDictionary* unavailable = SPDFCollectionAssets(path,
            [@"![Remote](https://example.org/remote.png) ![Missing](absent.png)" dataUsingEncoding:NSUTF8StringEncoding]);
        Expect(@"real unavailable images retain actionable warnings", [unavailable[@"entries"] count] == 0 &&
               [unavailable[@"warnings"] count] == 2);
        const unsigned char invalidUTF8[] = {0xff};
        NSDictionary* invalid = SPDFCollectionAssets(path, [NSData dataWithBytes:invalidUTF8 length:1]);
        Expect(@"parse failures do not silently claim complete dependency capture", [invalid[@"entries"] count] == 0 &&
               [invalid[@"warnings"] count] == 1);
        Expect(@"asset parsing never opens the source or creates a resource store", pureParsing && parseCalls > 0);
        method_setImplementation(parse, (IMP)originalParse);

        NSString* privatePath = [directory stringByAppendingPathComponent:@"private.txt"];
        Expect(@"write unique private contents", [@"private bytes must never enter Collection" writeToFile:privatePath
               atomically:YES encoding:NSUTF8StringEncoding error:nil]);
        NSString* privateHash = SPDFCollectionHashURL([NSURL fileURLWithPath:privatePath], nil);
        NSURL* root = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"Collection"]];
        SPDFMacCollectionStore* store = [[SPDFMacCollectionStore alloc] initWithRootURL:root];
        Expect(@"enable archive fixture", [store updateSettings:@{@"choice":@"enabled"} error:nil]);
        Expect(@"write literal-only document", [literals.firstObject[1] writeToFile:path atomically:YES
               encoding:NSUTF8StringEncoding error:nil]);
        NSDictionary* document = [store capturePath:path reason:@"Opened" error:nil];
        NSDictionary* version = [store versionsForDocumentID:document[@"id"]].lastObject;
        NSArray* objects = [NSFileManager.defaultManager contentsOfDirectoryAtPath:
                           [root URLByAppendingPathComponent:@"objects"].path error:nil];
        Expect(@"literal example archives only the source object", document != nil &&
               [version[@"assets"] count] == 0 && objects.count == 1 && ![objects containsObject:privateHash]);
        Expect(@"write mixed actual and literal document", [@"![Actual](direct.svg) `![Example](private.txt)`"
               writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]);
        document = [store capturePath:path reason:@"Saved" continuingDocumentID:document[@"id"] error:nil];
        version = [store versionsForDocumentID:document[@"id"]].lastObject;
        objects = [NSFileManager.defaultManager contentsOfDirectoryAtPath:
                   [root URLByAppendingPathComponent:@"objects"].path error:nil];
        Expect(@"real image reaches object store while adjacent private file never does", document != nil &&
               [version[@"assets"] count] == 1 && ![objects containsObject:privateHash]);
        [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
    }
    if (!failures) puts("SPDFMacCollectionAssetTests passed");
    return failures ? 1 : 0;
}
