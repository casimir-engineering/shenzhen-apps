#import <Foundation/Foundation.h>
#import <sys/stat.h>

// Shared across all search translation units in this process, allocated only
// when an existing file is first searched.
NSCache* SPDFSharedSearchFileCache(void);
#if defined(SPDF_SEARCH_CACHE_TESTING)
NSUInteger SPDFSearchFileCacheCreationCount(void);
#endif

// Read-only search snapshots: allocate on first search, never on app launch.
// File identity and nanosecond timestamps invalidate replacements and external edits.
// Values must be immutable; writes continue through the store's locked transaction.
static inline NSString* SPDFSearchFileStamp(NSString* path) {
    struct stat value = {};
    if (stat(path.fileSystemRepresentation, &value) != 0) return nil;
    return [NSString stringWithFormat:@"%llu:%llu:%lld:%lld:%ld:%lld:%ld",
        (unsigned long long)value.st_dev, (unsigned long long)value.st_ino, (long long)value.st_size,
        (long long)value.st_mtimespec.tv_sec, value.st_mtimespec.tv_nsec,
        (long long)value.st_ctimespec.tv_sec, value.st_ctimespec.tv_nsec];
}
static inline id SPDFSearchCachedFileValidated(NSString* path, NSString* variant, NSUInteger cost,
                                              BOOL (^valid)(id), id (^load)(void)) {
    NSString* stamp = SPDFSearchFileStamp(path);
    if (!stamp) return nil;
    NSCache* cache = SPDFSharedSearchFileCache();
    NSString* key = [NSString stringWithFormat:@"%@|%@", path, variant ?: @""];
    NSDictionary* entry = [cache objectForKey:key];
    if ([entry[@"stamp"] isEqual:stamp] && (!valid || valid(entry[@"value"]))) return entry[@"value"];
    id value = load();
    // Never retain a torn snapshot or return it as the current document.
    if (![stamp isEqual:SPDFSearchFileStamp(path)] || (value && valid && !valid(value))) return nil;
    if (value) [cache setObject:@{@"stamp":stamp, @"value":value} forKey:key cost:MAX(cost,(NSUInteger)1)];
    return value;
}
static inline id SPDFSearchCachedFile(NSString* path, NSString* variant, NSUInteger cost, id (^load)(void)) {
    return SPDFSearchCachedFileValidated(path,variant,cost,nil,load);
}
static inline NSDictionary* SPDFSearchCachedJSON(NSString* path) {
    struct stat value = {}; stat(path.fileSystemRepresentation, &value);
    return SPDFSearchCachedFile(path,@"json",(NSUInteger)MAX((off_t)1,value.st_size)*3, ^id {
        NSData* bytes = [NSData dataWithContentsOfFile:path];
        id decoded = bytes ? [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil] : nil;
        return [decoded isKindOfClass:NSDictionary.class] ? decoded : nil;
    });
}
