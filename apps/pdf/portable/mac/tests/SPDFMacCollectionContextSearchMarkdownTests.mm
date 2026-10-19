#import "SPDFMacCollectionStoreContextSearch.h"
#import "SPDFMacCollectionStorePrivate.h"
#import "markdown/SPDFMarkdownDocument.h"

static int failures;
static void Expect(NSString* name, BOOL pass) {
    if (!pass) { fprintf(stderr,"FAIL: %s\n",name.UTF8String); failures++; }
}
int main(void) {
    @autoreleasepool {
        Expect(@"real Markdown engine is linked",NSClassFromString(@"SPDFMarkdownDocument") != nil);
        NSURL* folder = [NSURL fileURLWithPath:
            [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
        [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES
            attributes:nil error:nil];
        NSURL* URL = [folder URLByAppendingPathComponent:@"Paged.md"];
        SPDFMacCollectionStore* store = [[SPDFMacCollectionStore alloc] initWithRootURL:
            [folder URLByAppendingPathComponent:@"Collection"]];
        [store updateSettings:@{@"choice":@"enabled"} error:nil];
        NSString* old = @"---\npaper-size: A5\n---\n# Introduction\nFirst page.\n\n<!-- pagebreak -->\n\n"
            @"# Results\nHistorical Café result preserved here.\n";
        NSString* current = @"---\npaper-size: A5\n---\n# Introduction\nFirst page.\n\n<!-- pagebreak -->\n\n"
            @"# Inspection\nAn inserted page.\n\n<!-- pagebreak -->\n\n# Results\nCurrent Café result approved here.\n";
        [old writeToURL:URL atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSDictionary* first = [store capturePath:URL.path reason:@"Opened" error:nil];
        [current writeToURL:URL atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSDictionary* last = [store capturePath:URL.path reason:@"Edited" continuingDocumentID:first[@"id"] error:nil];
        Expect(@"two rendered Markdown versions were indexed",[last[@"versions"] count] == 2);
        // Search uses captured pages and canonical offsets, even when the live
        // Markdown has since been replaced with unrelated unindexed content.
        [@"# Unrelated live replacement\n" writeToURL:URL atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSArray* groups = [store searchGroups:@"cafe" allVersions:YES];
        NSArray* rows = groups.firstObject[@"versions"];
        Expect(@"Markdown history stays grouped with two matching revisions",groups.count == 1 && rows.count == 2);
        for (NSUInteger index = 0; index < rows.count; index++) {
            NSDictionary* row = rows[index];
            NSArray* matches = row[@"matches"];
            NSDictionary* context = matches.firstObject;
            Expect(@"Markdown matches map to each revision's actual rendered page",matches.count == 1 &&
                [context[@"page"] integerValue] == (index ? 2 : 3));
            NSURL* archived = [store materializeVersionID:row[@"version"][@"id"] documentID:first[@"id"] error:nil];
            SPDFMarkdownDocument* document = [SPDFMarkdownDocument documentWithURL:archived options:nil error:nil];
            NSString* canonical = document.renderedDocument.attributedString.string;
            NSRange location = [context[@"canonicalRanges"][0] rangeValue];
            NSRange expected = [canonical rangeOfString:@"Café"];
            Expect(@"canonical range opens the exact query in archived rendered text",document &&
                NSEqualRanges(location,expected));
            NSRange display = [context[@"ranges"][0] rangeValue];
            Expect(@"Markdown context retains complete highlighted word",[[context[@"snippet"]
                substringWithRange:display] isEqual:@"Café"]);
        }
        NSArray* latest = [store searchGroups:@"cafe" allVersions:NO].firstObject[@"versions"];
        Expect(@"latest-only Markdown search returns current saved page",latest.count == 1 &&
            [latest.firstObject[@"matches"][0][@"page"] integerValue] == 3);
        Expect(@"search never reports content from uncaptured live replacement",
            [store searchGroups:@"Unrelated live replacement" allVersions:YES].count == 0);
        [NSFileManager.defaultManager removeItemAtURL:folder error:nil];
        if (!failures) puts("SPDFMacCollectionContextSearchMarkdownTests passed");
    }
    return failures ? 1 : 0;
}
