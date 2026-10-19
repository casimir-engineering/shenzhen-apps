#import "SPDFMacSearchFileCache.h"

#if defined(SPDF_SEARCH_CACHE_TESTING)
static NSUInteger creationCount;
NSUInteger SPDFSearchFileCacheCreationCount(void) { return creationCount; }
#endif

NSCache* SPDFSharedSearchFileCache(void) {
    static NSCache* cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        cache.totalCostLimit = 64 * 1024 * 1024;
        cache.countLimit = 256;
#if defined(SPDF_SEARCH_CACHE_TESTING)
        creationCount++;
#endif
    });
    return cache;
}
