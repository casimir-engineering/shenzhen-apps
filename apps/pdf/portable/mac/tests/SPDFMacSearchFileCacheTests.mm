#import "SPDFMacSearchFileCache.h"

id SPDFSearchFileCachePeerRead(NSString*, id (^)(void));
NSCache* SPDFSearchFileCachePeerIdentity(void);
static void Expect(BOOL value, const char* message) {
    if (!value) { fprintf(stderr,"FAIL: %s\n",message); exit(1); }
}
int main(void) {
    @autoreleasepool {
        Expect(SPDFSearchFileCacheCreationCount()==0,"linking cache implementation allocates nothing");
        NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        __block NSUInteger loads=0;
        id (^load)(void)=^id {
            loads++;
            return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        };
        Expect(SPDFSearchCachedFile(path,@"cross-tu",128,load)==nil && loads==0,
            "missing file neither loads nor creates cached content");
        Expect(SPDFSearchFileCacheCreationCount()==0,"missing file does not allocate cache");
        [@"first" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        id first=SPDFSearchCachedFile(path,@"cross-tu",128,load);
        id peer=SPDFSearchFileCachePeerRead(path,load);
        Expect(first==peer && loads==1,"two translation units reuse one immutable snapshot and one extraction");
        NSCache* cache=SPDFSharedSearchFileCache();
        Expect(cache==SPDFSearchFileCachePeerIdentity() && SPDFSearchFileCacheCreationCount()==1,
            "exactly one cache object exists across translation units");
        Expect(cache.totalCostLimit==64*1024*1024 && cache.countLimit==256,"existing shared limits preserved");
        [@"other" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        Expect([SPDFSearchFileCachePeerRead(path,load) isEqual:@"other"] && loads==2,
            "replacement invalidates through peer translation unit");
        Expect([SPDFSearchCachedFile(path,@"cross-tu",128,load) isEqual:@"other"] && loads==2,
            "replacement snapshot immediately shared by original translation unit");
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        Expect(SPDFSearchCachedFile(path,@"cross-tu",128,load)==nil,"deletion cannot return retained data");
        puts("Search cache: 2 translation units, 1 cache, 1 initial extraction; zero allocations before search");
        puts("SPDFMacSearchFileCacheTests passed");
    }
    return 0;
}
