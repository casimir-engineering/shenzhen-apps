#import "SPDFMacCollectionCompareLatest.h"
#import "SPDFMacCollectionStore.h"

static int failures;
static void Expect(NSString* name, BOOL pass) {
    if (!pass) { fprintf(stderr,"FAIL: %s\n",name.UTF8String); failures++; }
}
int main(void) {
    @autoreleasepool {
        NSURL* root = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
        [NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:nil];
        SPDFMacCollectionStore* store = [[SPDFMacCollectionStore alloc] initWithRootURL:[root URLByAppendingPathComponent:@"Collection"]];
        [store updateSettings:@{@"choice":@"enabled"} error:nil];
        NSURL* source = [root URLByAppendingPathComponent:@"draft.md"];
        [@"# First revision\n" writeToURL:source atomically:NO encoding:NSUTF8StringEncoding error:nil];
        NSDictionary* first = [store capturePath:source.path reason:@"Opened" error:nil];
        NSString* identifier = first[@"id"];
        NSString* firstVersion = first[@"latestVersionID"];
        [@"# Latest protected revision\n" writeToURL:source atomically:NO encoding:NSUTF8StringEncoding error:nil];
        NSDictionary* second = [store capturePath:source.path reason:@"Edited" continuingDocumentID:identifier error:nil];
        NSString* latestVersion = second[@"latestVersionID"];
        Expect(@"fixture has distinct archived revisions",identifier.length && ![firstVersion isEqual:latestVersion]);
        NSURL* oldPreview = [store materializeVersionID:firstVersion documentID:identifier error:nil];
        [@"# Newest unsnapshotted live edit\n" writeToURL:source atomically:NO encoding:NSUTF8StringEncoding error:nil];
        NSDictionary* latest = SPDFCollectionResolveLatestComparison(store,identifier,nil);
        Expect(@"latest comparison uses live source, never the viewed old archive",[latest[@"URL"] isEqual:source] &&
            ![latest[@"URL"] isEqual:oldPreview] && ![latest[@"archived"] boolValue]);
        Expect(@"latest original includes changes newer than its protected version",[[NSString stringWithContentsOfURL:
            latest[@"URL"] encoding:NSUTF8StringEncoding error:nil] containsString:@"Newest unsnapshotted"]);
        [@"# Latest protected revision\n" writeToURL:source atomically:NO encoding:NSUTF8StringEncoding error:nil];
        NSURL* relocated = [root URLByAppendingPathComponent:@"linked-original.md"];
        [NSFileManager.defaultManager moveItemAtURL:source toURL:relocated error:nil];
        Expect(@"fixture relinks the stable document identity",[store linkDocumentID:identifier toPath:relocated.path allowMismatch:NO error:nil]);
        latest = SPDFCollectionResolveLatestComparison(store,identifier,nil);
        Expect(@"latest lookup re-reads a newly linked source path",[latest[@"URL"] isEqual:relocated] &&
            ![latest[@"document"][@"path"] isEqual:first[@"path"]]);
        [NSFileManager.defaultManager removeItemAtURL:relocated error:nil];
        latest = SPDFCollectionResolveLatestComparison(store,identifier,nil);
        Expect(@"unavailable original falls back to newest protected revision",[latest[@"archived"] boolValue] &&
            [latest[@"version"][@"id"] isEqual:latestVersion] && [latest[@"label"] containsString:@"Latest saved version"]);
        [@"# Unrelated replacement\n" writeToURL:relocated atomically:NO encoding:NSUTF8StringEncoding error:nil];
        latest = SPDFCollectionResolveLatestComparison(store,identifier,nil);
        Expect(@"an unrelated file at the old location is not the latest original",[latest[@"archived"] boolValue] &&
            ![latest[@"URL"] isEqual:relocated]);
        NSError* error = nil;
        Expect(@"missing history produces an explicit error",!SPDFCollectionResolveLatestComparison(store,@"missing",&error) && error);
        [NSFileManager.defaultManager removeItemAtURL:root error:nil];
        if (!failures) puts("SPDFMacCollectionCompareLatestTests passed");
    }
    return failures ? 1 : 0;
}
