#pragma once
#import <Foundation/Foundation.h>
#import <sys/stat.h>

// Metadata only: these checks never read a protected source's contents.
static inline NSDictionary* SPDFReadOnlyFileFingerprint(NSString* path) {
    struct stat st = {};
    if (!path.length || stat(path.fileSystemRepresentation, &st) || !S_ISREG(st.st_mode)) return @{};
    return @{@"device":@((unsigned long long)st.st_dev), @"inode":@((unsigned long long)st.st_ino),
        @"size":@((unsigned long long)st.st_size), @"mtime":@((long long)st.st_mtimespec.tv_sec),
        @"mtimeNS":@(st.st_mtimespec.tv_nsec), @"ctime":@((long long)st.st_ctimespec.tv_sec),
        @"ctimeNS":@(st.st_ctimespec.tv_nsec)};
}
static inline BOOL SPDFReadOnlyCopyBindingMatches(NSDictionary* binding, NSString* source, NSString* copy) {
    return [binding isKindOfClass:NSDictionary.class] &&
        [binding[@"source"] isKindOfClass:NSDictionary.class] && [binding[@"copy"] isKindOfClass:NSDictionary.class] &&
        [binding[@"source"] count] && [binding[@"copy"] count] &&
        [binding[@"source"] isEqual:SPDFReadOnlyFileFingerprint(source)] &&
        [binding[@"copy"] isEqual:SPDFReadOnlyFileFingerprint(copy)];
}
// The binding is handed back to the main thread; worker resolution never mutates a tab.
typedef struct SPDFReadOnlyCopyResolution {
    NSString* workingPath;
    unsigned long long fileSize;
    NSDate* modificationDate;
    BOOL hasCopyBinding;
    NSDictionary* fingerprintBinding;
} SPDFReadOnlyCopyResolution;
SPDFReadOnlyCopyResolution SPDFResolveReadOnlyCopy(
    NSString* sourcePath, NSString* copyPath, NSDictionary* existingBinding, void (^authorizeRead)(void));
SPDFReadOnlyCopyResolution SPDFResolveReadOnlyCopyWithError(
    NSString* sourcePath, NSString* copyPath, NSDictionary* existingBinding,
    void (^authorizeRead)(void), NSError** error);
// Legacy caches stay usable at startup/speculative preload without migrating
// metadata or requesting source access. Explicit consultation returns NO.
static inline BOOL SPDFReuseLegacyReadOnlyCopy(NSString* copyPath, unsigned long long size, NSDate* modified,
                                              NSDictionary* attributes, BOOL deferRenewal) {
    return deferRenewal && size == [attributes[NSFileSize] unsignedLongLongValue] &&
        [modified isEqual:attributes[NSFileModificationDate]] &&
        [NSFileManager.defaultManager fileExistsAtPath:copyPath];
}
