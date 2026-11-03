// A plain .zip of a few files, written and read back without compression, for sending a Markdown document with what
// belongs to it as one file (SPDFMacFriendsMarkdownBundle.h).
//
// Stored (method 0) entries only, no zip64: every unzip tool opens them (Finder, Shenzhen Files, phones), and reading
// one back costs nothing but a copy, so a hostile archive cannot inflate past its own size. The reader refuses
// anything else: compressed or encrypted entries, links, absolute names, "." or ".." components, more than
// SPDFMacFriendsZipEntryLimit entries, or an entry whose bytes do not match its CRC.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT const NSUInteger SPDFMacFriendsZipEntryLimit;     // 10000
FOUNDATION_EXPORT const unsigned long long SPDFMacFriendsZipByteLimit; // 3 GiB, under the format's 4 GiB offsets

// One entry to write: a folder ("Report/img/", trailing slash, no contents), or a file from `data` or from `path`
// (opened without following links; it must be a plain file).
@interface SPDFMacFriendsZipSource : NSObject
@property(nonatomic, copy) NSString* name;
@property(nonatomic, copy, nullable) NSData* data;
@property(nonatomic, copy, nullable) NSString* path;
+ (instancetype)folder:(NSString*)name;
+ (instancetype)file:(NSString*)name data:(NSData*)data;
+ (instancetype)file:(NSString*)name path:(NSString*)path;
@end

// Writes the entries, in order, to a new file at `zipPath` (never replacing one). NO, with nothing left behind, when a
// source cannot be read or the archive would pass SPDFMacFriendsZipByteLimit.
BOOL SPDFMacFriendsZipWrite(NSString* zipPath, NSArray<SPDFMacFriendsZipSource*>* entries);

// One entry of an archive, as its central directory says.
@interface SPDFMacFriendsZipEntry : NSObject
@property(nonatomic, readonly, copy) NSString* name;     // folders end with "/"
@property(nonatomic, readonly) BOOL folder;
@property(nonatomic, readonly) unsigned long long size;
@property(nonatomic, readonly) uint32_t crc;
@property(nonatomic, readonly) unsigned long long headerOffset;
@end

// The entries of a stored archive this reader accepts; nil for anything else (see above).
NSArray<SPDFMacFriendsZipEntry*>* _Nullable SPDFMacFriendsZipEntries(NSString* zipPath);

// Writes every entry under `directory` (which must exist and be the caller's own, fresh folder): folders 0755, files
// 0644, created exclusively. NO when one cannot be written or its bytes fail their CRC; what was written stays for the
// caller to remove.
BOOL SPDFMacFriendsZipExtract(NSString* zipPath, NSArray<SPDFMacFriendsZipEntry*>* entries, NSString* directory);

NS_ASSUME_NONNULL_END
