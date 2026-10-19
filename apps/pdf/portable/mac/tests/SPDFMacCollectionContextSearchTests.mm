#import "SPDFMacCollectionStoreContextSearch.h"
#import "SPDFMacCollectionStorePrivate.h"
#import <Cocoa/Cocoa.h>
#import <CoreText/CoreText.h>
#import <PDFKit/PDFKit.h>

static int failures;
static void Expect(NSString* name, BOOL pass) {
    if (!pass) { fprintf(stderr,"FAIL: %s\n",name.UTF8String); failures++; }
}
@interface SearchFixtureStore : SPDFMacCollectionStore
@property(nonatomic) NSUInteger documentReads;
@property(nonatomic, strong) NSMutableArray* indexReads;
@property(nonatomic, copy) NSArray* fixtureDocuments;
@property(nonatomic, copy) NSDictionary* fixtureIndexes;
@end
@implementation SearchFixtureStore
- (NSArray*)documents { self.documentReads++; return self.fixtureDocuments ?: @[]; }
- (NSDictionary*)textIndexForVersion:(NSDictionary*)version {
    [self.indexReads addObject:version[@"id"]];
    return self.fixtureIndexes[version[@"id"]] ?: @{};
}
@end
static NSArray* VersionRows(NSArray* groups) {
    NSMutableArray* rows = [NSMutableArray array];
    for (NSDictionary* group in groups) [rows addObjectsFromArray:group[@"versions"]];
    return rows;
}
static NSDictionary* Version(NSString* identifier, NSString* filename) {
    return @{@"id":identifier,@"filename":filename};
}
static NSDictionary* Page(NSString* text, NSUInteger number) { return @{@"text":text,@"page":@(number)}; }
static void CheckRanges(NSDictionary* context, NSString* pageText, NSString* query, NSNumber* canonicalOrigin) {
    NSArray* ranges = context[@"ranges"];
    NSArray* pageRanges = context[@"pageRanges"];
    NSString* snippet = context[@"snippet"];
    Expect(@"each context has matching display and indexed ranges",ranges.count && ranges.count == pageRanges.count);
    for (NSUInteger index = 0; index < ranges.count; index++) {
        NSRange display = [ranges[index] rangeValue], original = [pageRanges[index] rangeValue];
        Expect(@"query highlight is within the displayed context",NSMaxRange(display) <= snippet.length);
        Expect(@"query location is within the exact indexed page",NSMaxRange(original) <= pageText.length);
        if (NSMaxRange(display) > snippet.length || NSMaxRange(original) > pageText.length) continue;
        NSString* match = [pageText substringWithRange:original];
        Expect(@"display and indexed range identify the same text",
            [[snippet substringWithRange:display] isEqual:match]);
        Expect(@"highlight covers the actual folded match length",[match compare:query options:
            NSCaseInsensitiveSearch|NSDiacriticInsensitiveSearch] == NSOrderedSame);
        if (canonicalOrigin) {
            NSRange canonical = [context[@"canonicalRanges"][index] rangeValue];
            Expect(@"canonical highlight preserves exact source offset",
                canonical.location == canonicalOrigin.unsignedIntegerValue+original.location &&
                canonical.length == original.length);
        }
    }
}
static void TestIndexContract(NSURL* root) {
    SearchFixtureStore* store = [[SearchFixtureStore alloc] initWithRootURL:root];
    store.indexReads = [NSMutableArray array];
    NSDictionary* older = Version(@"old",@"Retired plan.pdf");
    NSDictionary* latest = Version(@"new",@"Current plan.pdf");
    store.fixtureDocuments = @[@{@"id":@"document",@"title":@"Current plan.pdf",@"versions":@[older,latest]}];
    NSString* gap = [@"surrounding fullword " stringByPaddingToLength:380
        withString:@"surrounding fullword " startingAtIndex:0];
    NSString* text = [NSString stringWithFormat:@"%@Cafe\u0301 near CAFÉ.\n%@One last café with context.",gap,gap];
    store.fixtureIndexes = @{@"old":@{@"textPages":@[@{@"text":text,@"page":@7,@"canonicalLocation":@1200}]},
                             @"new":@{@"textPages":@[Page(@"Current text has no historical term.",2)]}};
    Expect(@"blank query avoids even manifest reads",[store searchGroups:@" \n " allVersions:YES].count == 0 &&
        store.documentReads == 0 && store.indexReads.count == 0);
    Expect(@"latest scope omits content present only in an older version",
        [store searchGroups:@"cafe" allVersions:NO].count == 0);
    Expect(@"latest scope never reads older indexes",[store.indexReads isEqual:@[@"new"]]);
    NSArray* groups = [store searchGroups:@"cafe" allVersions:YES];
    NSArray* rows = VersionRows(groups); NSDictionary* row = rows.firstObject;
    Expect(@"historical content stays grouped under its document",groups.count == 1 && rows.count == 1 &&
        [row[@"version"] isEqual:older] && ![row[@"latest"] boolValue]);
    Expect(@"near matches share context and distant matches retain separate context",
        [row[@"matches"] count] == 2 && [row[@"matchCount"] integerValue] == 3 && ![row[@"truncated"] boolValue]);
    for (NSDictionary* context in row[@"matches"]) {
        Expect(@"retained page numbers are used directly",[context[@"page"] integerValue] == 7);
        CheckRanges(context,text,@"cafe",@1200);
        NSRange slice = [context[@"snippetRange"] rangeValue];
        BOOL startBoundary = !slice.location || ![NSCharacterSet.alphanumericCharacterSet
            characterIsMember:[text characterAtIndex:slice.location-1]] ||
            ![NSCharacterSet.alphanumericCharacterSet characterIsMember:[text characterAtIndex:slice.location]];
        BOOL endBoundary = NSMaxRange(slice) == text.length || ![NSCharacterSet.alphanumericCharacterSet
            characterIsMember:[text characterAtIndex:NSMaxRange(slice)-1]] ||
            ![NSCharacterSet.alphanumericCharacterSet characterIsMember:[text characterAtIndex:NSMaxRange(slice)]];
        Expect(@"context boundaries retain complete words",startBoundary && endBoundary);
    }
    rows = VersionRows([store searchGroups:@"retired" allVersions:YES]);
    Expect(@"historical filename produces an honest title-only match",rows.count == 1 &&
        [rows.firstObject[@"titleMatch"] boolValue] && [rows.firstObject[@"matches"] count] == 0 &&
        [rows.firstObject[@"matchCount"] integerValue] == 0);
    Expect(@"historical filename is not attached to latest version",
        [store searchGroups:@"retired" allVersions:NO].count == 0);
    rows = VersionRows([store searchGroups:@"plan" allVersions:YES]);
    Expect(@"matching versions stay newest first with accurate latest flags",rows.count == 2 &&
        [rows[0][@"version"] isEqual:latest] && [rows[0][@"latest"] boolValue] && ![rows[1][@"latest"] boolValue]);
    NSDictionary* encrypted = @{@"id":@"locked",@"filename":@"Locked archive.pdf",@"encrypted":@YES};
    NSDictionary* missing = Version(@"missing",@"Missing archive.pdf");
    store.fixtureDocuments = @[@{@"id":@"locked-doc",@"versions":@[encrypted]},
                              @{@"id":@"missing-doc",@"versions":@[missing]}];
    store.fixtureIndexes = @{@"locked":@{@"textPages":@[Page(@"secret content",1)]}};
    [store.indexReads removeAllObjects]; rows = VersionRows([store searchGroups:@"archive" allVersions:YES]);
    Expect(@"encrypted index is never requested",![store.indexReads containsObject:@"locked"]);
    Expect(@"missing and encrypted indexes allow titles without fabricated hits",rows.count == 2 &&
        ![rows[0][@"textAvailable"] boolValue] && ![rows[1][@"textAvailable"] boolValue] &&
        ![rows[0][@"matches"] count] && ![rows[1][@"matches"] count]);
    Expect(@"encrypted content remains unsearchable",[store searchGroups:@"secret" allVersions:YES].count == 0);
    store.fixtureDocuments = @[@{@"id":@"many",@"versions":@[latest]}];
    NSMutableArray* pages = [NSMutableArray array];
    for (NSUInteger i = 1; i <= 40; i++) [pages addObject:Page(@"Exact needle in retained text",i)];
    store.fixtureIndexes = @{@"new":@{@"textPages":pages}};
    row = VersionRows([store searchGroups:@"needle" allVersions:NO]).firstObject;
    Expect(@"context cap reports total indexed matches honestly",[row[@"matches"] count] == 32 &&
        [row[@"matchCount"] integerValue] == 40 && [row[@"truncated"] boolValue]);
    Expect(@"read-only search creates no storage directory",![NSFileManager.defaultManager fileExistsAtPath:root.path]);
}
static void WritePDF(NSURL* URL, NSArray<NSString*>* pages) {
    NSMutableData* bytes = [NSMutableData data];
    CGDataConsumerRef consumer = CGDataConsumerCreateWithCFData((__bridge CFMutableDataRef)bytes);
    CGRect box = CGRectMake(0,0,420,595);
    CGContextRef context = CGPDFContextCreate(consumer,&box,NULL); CGDataConsumerRelease(consumer);
    for (NSString* text in pages) {
        CGPDFContextBeginPage(context,NULL);
        NSAttributedString* string = [[NSAttributedString alloc] initWithString:text
            attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:16]}];
        CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)string);
        CGContextSetTextPosition(context,30,500); CTLineDraw(line,context); CFRelease(line);
        CGPDFContextEndPage(context);
    }
    CGPDFContextClose(context); CGContextRelease(context); [bytes writeToURL:URL atomically:YES];
}
static void TestCapturedPDF(NSURL* root) {
    SPDFMacCollectionStore* store = [[SPDFMacCollectionStore alloc] initWithRootURL:root];
    Expect(@"searching absent real storage remains lazy",![store searchGroups:@"needle" allVersions:YES].count &&
        ![NSFileManager.defaultManager fileExistsAtPath:root.path]);
    [store updateSettings:@{@"choice":@"enabled"} error:nil];
    NSURL* URL = [root.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"Atlas.pdf"];
    WritePDF(URL,@[@"First page",@"The ancient needle is retained."]);
    NSDictionary* first = [store capturePath:URL.path reason:@"Opened" error:nil];
    NSString* documentID = first[@"id"];
    WritePDF(URL,@[@"Current needle on page one",@"Another needle on page two"]);
    NSDictionary* second = [store capturePath:URL.path reason:@"Edited" continuingDocumentID:documentID error:nil];
    Expect(@"fixture captures real PDF versions",first && second && [second[@"versions"] count] == 2);
    NSArray* rows = VersionRows([store searchGroups:@"needle" allVersions:YES]);
    Expect(@"real PDF matches retain version identity and each exact page",rows.count == 2 &&
        [rows[0][@"matches"] count] == 2 && [rows[1][@"matches"] count] == 1 &&
        [rows[1][@"matches"][0][@"page"] integerValue] == 2);
    for (NSDictionary* row in rows) {
        NSDictionary* index = [store textIndexForVersion:row[@"version"]];
        for (NSDictionary* context in row[@"matches"]) {
            NSString* text = nil;
            for (NSDictionary* page in index[@"textPages"])
                if ([page[@"page"] isEqual:context[@"page"]]) text = page[@"text"];
            CheckRanges(context,text,@"needle",nil);
        }
    }
    NSArray* palette = [store search:@"needle" titlesOnly:NO excludingPaths:NSSet.set limit:1];
    Expect(@"palette still returns latest first-page hit with original flat contract",palette.count == 1 &&
        [palette.firstObject[@"page"] integerValue] == 1 && palette.firstObject[@"snippet"] &&
        [palette.firstObject[@"id"] isEqual:documentID] && !palette.firstObject[@"versions"][0][@"matches"]);
    NSArray* latest = VersionRows([store searchGroups:@"ancient" allVersions:NO]);
    Expect(@"latest search does not leak historical PDF content",latest.count == 0);
    NSURL* txt = [root.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"Plain.txt"];
    [@"A needle without rendered pagination" writeToURL:txt atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [store capturePath:txt.path reason:@"Opened" error:nil];
    Expect(@"cached palette manifest sees newly captured document immediately",
        [store search:@"Plain" titlesOnly:YES excludingPaths:NSSet.set limit:5].count == 1);
    Expect(@"newly captured text is searchable after warming old index",
        [store search:@"without rendered" titlesOnly:NO excludingPaths:NSSet.set limit:5].count == 1);
    for (NSString* extension in @[@"html",@"py",@"json"]) {
        NSURL* source=[root.URLByDeletingLastPathComponent URLByAppendingPathComponent:
            [@"Literal" stringByAppendingPathExtension:extension]];
        [@"<h1>sourceNeedle</h1>\n![image](missing.png)" writeToURL:source atomically:YES
            encoding:NSUTF8StringEncoding error:nil];
        NSDictionary* captured=[store capturePath:source.path reason:@"Opened" error:nil];
        NSDictionary* version=[captured[@"versions"] lastObject];
        NSDictionary* index=[store textIndexForVersion:version];
        Expect(@"storage-only source indexing preserves literal content without inventing pages",
            captured && [index[@"textPages"][0][@"text"] containsString:@"<h1>sourceNeedle</h1>"] &&
            [index[@"textPages"][0][@"page"] integerValue]==0);
        Expect(@"source image examples never archive assets or generate missing-asset warnings",
            [version[@"assets"] count]==0 && [version[@"assetWarnings"] count]==0);
        NSString* identifier=version[@"id"];
        NSURL* indexURL=[[root URLByAppendingPathComponent:@"indexes"] URLByAppendingPathComponent:version[@"indexFile"]];
        [store transaction:^BOOL(NSMutableDictionary* manifest,NSError** error) {
            NSMutableDictionary* legacy=[manifest[@"documents"][captured[@"id"]][@"versions"] lastObject];
            [legacy removeObjectForKey:@"sourceIndexProfile"];
            return SPDFCollectionAtomicData([NSJSONSerialization dataWithJSONObject:@{@"textPages":@[],@"encrypted":@NO}
                options:0 error:error],indexURL,0400,error);
        } error:nil];
        Expect(@"legacy source fixture initially has no indexed content",
            [[store textIndexForVersion:version][@"textPages"] count]==0);
        NSDictionary* migrated=[store capturePath:source.path reason:@"Opened" error:nil];
        NSDictionary* repaired=[migrated[@"versions"] lastObject];
        Expect(@"reopen lazily restores source index without creating a history version",
            [migrated[@"versions"] count]==1 && [repaired[@"id"] isEqual:identifier] &&
            [repaired[@"hash"] isEqual:version[@"hash"]] &&
            [repaired[@"sourceIndexProfile"] isEqual:@"source-v1-raw"] &&
            [store textIndexForVersion:repaired][@"textPages"][0][@"text"]);
        NSDictionary* indexStamp=SPDFCollectionFingerprint(indexURL.path);
        [store capturePath:source.path reason:@"Opened" error:nil];
        Expect(@"repeated unchanged reopen does not rewrite the completed source index",
            [indexStamp isEqual:SPDFCollectionFingerprint(indexURL.path)]);
    }
    NSURL* unicode=[root.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"Unicode.txt"];
    [[@"Unicode source needle 中文" dataUsingEncoding:NSUTF16StringEncoding] writeToURL:unicode atomically:YES];
    NSDictionary* unicodeDoc=[store capturePath:unicode.path reason:@"Opened" error:nil];
    NSDictionary* unicodeIndex=[store textIndexForVersion:[unicodeDoc[@"versions"] lastObject]];
    Expect(@"storage-only source index shares reader Unicode decoding",
        [unicodeIndex[@"textPages"][0][@"text"] containsString:@"Unicode source needle 中文"]);
    NSProgress* cancelled = [NSProgress progressWithTotalUnitCount:1]; [cancelled cancel];
    Expect(@"cancelled Collection query returns no stale hits",
        [store search:@"needle" titlesOnly:NO excludingPaths:NSSet.set limit:5 progress:cancelled].count == 0);
    rows = VersionRows([store searchGroups:@"without rendered" allVersions:YES]);
    Expect(@"plain-text index does not invent a page number",rows.count == 1 &&
        [rows.firstObject[@"matches"][0][@"page"] integerValue] == 0);
}
int main(void) {
    @autoreleasepool {
        NSURL* folder = [NSURL fileURLWithPath:
            [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
        [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES
            attributes:nil error:nil];
        TestIndexContract([folder URLByAppendingPathComponent:@"Unused"]);
        TestCapturedPDF([folder URLByAppendingPathComponent:@"Collection"]);
        [NSFileManager.defaultManager removeItemAtURL:folder error:nil];
        if (!failures) puts("SPDFMacCollectionContextSearchTests passed");
    }
    return failures ? 1 : 0;
}
