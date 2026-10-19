#import "SPDFMacSearchFileCache.h"

static void CheckPaletteSearchCache(void) {
    NSString* root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSFileManager* fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    NSString* path = [root stringByAppendingPathComponent:@"text.txt"];
    [@"first" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    __block NSUInteger loads = 0;
    id (^load)(void) = ^id { loads++; return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil]; };
    Expect(@"search cache construction does no work",loads == 0);
    Expect(@"first lookup extracts text",[SPDFSearchCachedFile(path,@"portrait",32,load) isEqual:@"first"] && loads == 1);
    SPDFSearchCachedFile(path,@"portrait",32,load);
    Expect(@"warm query does not extract again",loads == 1);
    SPDFSearchCachedFile(path,@"landscape",32,load);
    Expect(@"page layout variants have independent text maps",loads == 2);
    [@"other" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    Expect(@"same-size atomic replacement invalidates immediately",
        [SPDFSearchCachedFile(path,@"portrait",32,load) isEqual:@"other"] && loads == 3);
    [@"edits" writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
    Expect(@"in-place edit invalidates immediately",
        [SPDFSearchCachedFile(path,@"portrait",32,load) isEqual:@"edits"] && loads == 4);
    id torn = SPDFSearchCachedFile(path,@"torn",32,^id {
        [@"newer" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]; return @"edits";
    });
    Expect(@"edit during extraction never publishes torn text",torn == nil);
    __block NSUInteger dependency = 1, dependencyLoads = 0;
    BOOL (^valid)(id) = ^BOOL(id value) { return [value unsignedIntegerValue] == dependency; };
    id (^dependentLoad)(void) = ^id { dependencyLoads++; return @(dependency); };
    SPDFSearchCachedFileValidated(path,@"dependencies",32,valid,dependentLoad);
    SPDFSearchCachedFileValidated(path,@"dependencies",32,valid,dependentLoad);
    Expect(@"unchanged dependencies reuse the text map",dependencyLoads == 1);
    dependency++;
    Expect(@"asset-only change rebuilds Markdown page map",
        [SPDFSearchCachedFileValidated(path,@"dependencies",32,valid,dependentLoad) isEqual:@2] && dependencyLoads == 2);
    [fm removeItemAtPath:path error:nil];
    Expect(@"deleted source cannot return cached content",SPDFSearchCachedFile(path,@"portrait",32,load) == nil);
    NSProgress* progress = [NSProgress progressWithTotalUnitCount:1];
    Expect(@"current visible query can publish",spdf_collection_palette_can_publish(progress,3,3,YES));
    Expect(@"stale query cannot replace newer results",!spdf_collection_palette_can_publish(progress,2,3,YES));
    Expect(@"closed palette cannot receive delayed rows",!spdf_collection_palette_can_publish(progress,3,3,NO));
    [progress cancel];
    Expect(@"cancelled work cannot publish",!spdf_collection_palette_can_publish(progress,3,3,YES));

    // 128 documents / 8 MiB of searchable text: retained JSON is the actual
    // Collection index format. Report cold/warm cost without timing-sensitive gates.
    NSString* page = [@"Context for finding a document. " stringByPaddingToLength:65536 withString:@"more context " startingAtIndex:0];
    NSData* bytes = [NSJSONSerialization dataWithJSONObject:@{@"textPages":@[@{@"page":@1,@"text":page}]} options:0 error:nil];
    NSMutableArray* paths = [NSMutableArray array];
    for (NSUInteger i=0;i<128;i++) {
        NSString* fixture = [root stringByAppendingPathComponent:[NSString stringWithFormat:@"%lu.json",(unsigned long)i]];
        [bytes writeToFile:fixture atomically:YES]; [paths addObject:fixture];
    }
    double cold = 0, warm = 0;
    for (NSUInteger pass=0;pass<2;pass++) {
        CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
        NSUInteger found = 0;
        for (NSString* fixture in paths) {
            NSDictionary* index = SPDFSearchCachedJSON(fixture);
            for (NSDictionary* entry in index[@"textPages"])
                if ([entry[@"text"] rangeOfString:@"document" options:NSCaseInsensitiveSearch].location != NSNotFound) found++;
        }
        double elapsed = (CFAbsoluteTimeGetCurrent()-start)*1000;
        if (pass) warm = elapsed; else cold = elapsed;
        Expect(@"large index search retains all matches",found == 128);
    }
    CFAbsoluteTime missStart = CFAbsoluteTimeGetCurrent();
    NSUInteger misses = 0;
    for (NSString* fixture in paths)
        for (NSDictionary* entry in SPDFSearchCachedJSON(fixture)[@"textPages"])
            if ([entry[@"text"] rangeOfString:@"missingneedle" options:NSCaseInsensitiveSearch |
                NSDiacriticInsensitiveSearch].location == NSNotFound) misses++;
    Expect(@"warm no-match search scans complete retained text",misses == 128);
    printf("Palette index benchmark: 128 documents / 8 MiB, cold %.2f ms, warm %.2f ms, full miss %.2f ms\n",
        cold,warm,(CFAbsoluteTimeGetCurrent()-missStart)*1000);
    [fm removeItemAtPath:root error:nil];
}
