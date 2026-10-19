#import "SPDFMacMarkdownCache.h"

#include <CommonCrypto/CommonDigest.h>
#include <sys/stat.h>

NSString* spdf_mac_markdown_file_identity(NSString* path) {
    if (!path.length) return nil;
    struct stat info;
    if (lstat(path.fileSystemRepresentation, &info) != 0 || !S_ISREG(info.st_mode)) return nil;
    return [NSString stringWithFormat:@"%llu:%llu",
                                      (unsigned long long)info.st_dev,
                                      (unsigned long long)info.st_ino];
}

BOOL spdf_mac_markdown_cache_matches(NSDate* cachedModificationDate,
                                     unsigned long long cachedFileSize,
                                     NSString* cachedFileIdentity,
                                     NSDictionary<NSFileAttributeKey, id>* currentAttributes,
                                     NSString* currentFileIdentity) {
    if (!cachedModificationDate || !cachedFileIdentity.length || !currentAttributes ||
        !currentFileIdentity.length)
        return NO;
    NSDate* currentModificationDate = currentAttributes[NSFileModificationDate];
    unsigned long long currentFileSize = [currentAttributes[NSFileSize] unsignedLongLongValue];
    return currentModificationDate && [currentModificationDate isEqualToDate:cachedModificationDate] &&
           currentFileSize == cachedFileSize && [currentFileIdentity isEqualToString:cachedFileIdentity];
}

unsigned long long spdf_mac_markdown_image_cache_maximum_bytes(void) {
    return 100ull * 1024 * 1024;
}

NSURL* spdf_mac_markdown_image_cache_directory(void) {
    NSURL* caches = [NSFileManager.defaultManager URLForDirectory:NSCachesDirectory
                                                         inDomain:NSUserDomainMask
                                                appropriateForURL:nil
                                                           create:YES
                                                            error:nil];
    if (!caches) return nil;
    return [[caches URLByAppendingPathComponent:@"ShenzhenPDF" isDirectory:YES]
        URLByAppendingPathComponent:@"markdown-images" isDirectory:YES];
}

NSString* spdf_mac_markdown_image_cache_file_name(NSString* urlString) {
    NSData* bytes = [urlString dataUsingEncoding:NSUTF8StringEncoding] ?: NSData.data;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, digest);
    NSMutableString* name = [NSMutableString stringWithCapacity:2 * CC_SHA256_DIGEST_LENGTH];
    for (size_t index = 0; index < CC_SHA256_DIGEST_LENGTH; ++index)
        [name appendFormat:@"%02x", digest[index]];
    return name;
}

static NSURL* spdf_mac_markdown_image_cache_file_url(NSURL* directory, NSString* urlString) {
    if (!directory || !urlString.length) return nil;
    return [directory URLByAppendingPathComponent:spdf_mac_markdown_image_cache_file_name(urlString)
                                      isDirectory:NO];
}

NSData* spdf_mac_markdown_image_cache_read(NSURL* directory, NSString* urlString) {
    NSURL* file = spdf_mac_markdown_image_cache_file_url(directory, urlString);
    if (!file) return nil;
    NSData* data = [NSData dataWithContentsOfURL:file options:0 error:nil];
    // A hit refreshes the modification date so the LRU trim spares it.
    if (data)
        [NSFileManager.defaultManager setAttributes:@{NSFileModificationDate: NSDate.date}
                                       ofItemAtPath:file.path
                                              error:nil];
    return data;
}

BOOL spdf_mac_markdown_image_cache_write(NSURL* directory, NSString* urlString, NSData* data) {
    NSURL* file = spdf_mac_markdown_image_cache_file_url(directory, urlString);
    if (!file || !data.length) return NO;
    if (![NSFileManager.defaultManager createDirectoryAtURL:directory
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:nil])
        return NO;
    return [data writeToURL:file options:NSDataWritingAtomic error:nil];
}

void spdf_mac_markdown_image_cache_trim(NSURL* directory, unsigned long long maximumTotalBytes) {
    if (!directory) return;
    NSArray<NSURL*>* files =
        [NSFileManager.defaultManager contentsOfDirectoryAtURL:directory
                                    includingPropertiesForKeys:@[ NSURLFileSizeKey, NSURLContentModificationDateKey ]
                                                       options:NSDirectoryEnumerationSkipsHiddenFiles
                                                         error:nil];
    if (!files.count) return;
    unsigned long long total = 0;
    NSMutableArray<NSDictionary*>* entries = [NSMutableArray arrayWithCapacity:files.count];
    for (NSURL* file in files) {
        NSNumber* size = nil;
        NSDate* modified = nil;
        [file getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        [file getResourceValue:&modified forKey:NSURLContentModificationDateKey error:nil];
        total += size.unsignedLongLongValue;
        [entries addObject:@{@"url": file, @"size": size ?: @0, @"date": modified ?: NSDate.distantPast}];
    }
    if (total <= maximumTotalBytes) return;
    [entries sortUsingComparator:^NSComparisonResult(NSDictionary* left, NSDictionary* right) {
        return [left[@"date"] compare:right[@"date"]];
    }];
    for (NSDictionary* entry in entries) {
        if (total <= maximumTotalBytes) break;
        if ([NSFileManager.defaultManager removeItemAtURL:entry[@"url"] error:nil])
            total -= [entry[@"size"] unsignedLongLongValue];
    }
}
