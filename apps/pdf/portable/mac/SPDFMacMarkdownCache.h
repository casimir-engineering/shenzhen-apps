#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

NSString* _Nullable spdf_mac_markdown_file_identity(NSString* path);
BOOL spdf_mac_markdown_cache_matches(NSDate* cachedModificationDate,
                                     unsigned long long cachedFileSize,
                                     NSString* _Nullable cachedFileIdentity,
                                     NSDictionary<NSFileAttributeKey, id>* currentAttributes,
                                     NSString* _Nullable currentFileIdentity);

// On-disk raw-bytes cache for remote Markdown images, keyed by the SHA-256 of
// the image URL. Lives in ~/Library/Caches/ShenzhenPDF/markdown-images/ and is
// trimmed least-recently-used (read hits bump the modification date) to the
// spdf_mac_markdown_image_cache_maximum_bytes() cap (~100 MB).
NSURL* _Nullable spdf_mac_markdown_image_cache_directory(void);
unsigned long long spdf_mac_markdown_image_cache_maximum_bytes(void);
NSString* spdf_mac_markdown_image_cache_file_name(NSString* urlString);
NSData* _Nullable spdf_mac_markdown_image_cache_read(NSURL* _Nullable directory, NSString* urlString);
BOOL spdf_mac_markdown_image_cache_write(NSURL* _Nullable directory, NSString* urlString, NSData* data);
void spdf_mac_markdown_image_cache_trim(NSURL* _Nullable directory, unsigned long long maximumTotalBytes);

NS_ASSUME_NONNULL_END
