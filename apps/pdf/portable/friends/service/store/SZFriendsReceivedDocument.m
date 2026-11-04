// A document sent with what belongs to it (PROTOCOL.md § Intents, Documents): the archive's reader, and placing the
// document's folder where received files go (SZFriendsTransfers.h).
//
// The archive is a plain stored .zip, which every unzip tool opens, so a helper that does not know documents still
// gives the person something whole. Only stored entries are read, so an entry is never more bytes than the archive
// holds, and the entries together may not be either: a hostile archive cannot grow on the way out.

#import <fcntl.h>
#import <stdlib.h>
#import <sys/stat.h>
#import <unistd.h>

#import "service/store/SZFriendsStoreInternal.h"

NS_ASSUME_NONNULL_BEGIN

const NSUInteger SZFriendsDocumentEntryLimit = 10000;

static const uint32_t SZFDLocalSignature = 0x04034b50, SZFDCentralSignature = 0x02014b50, SZFDEndSignature = 0x06054b50;
static const size_t SZFDChunk = 1 << 20;

#pragma mark - Names and counts

NSString *SZFriendsDocumentArchiveName(NSString *documentName) {
    NSString *stem = documentName.stringByDeletingPathExtension;
    return [(stem.length ? stem : documentName) stringByAppendingPathExtension:@"zip"];
}

static NSArray<NSString *> *SZFDCountKeys(void) { return @[ @"comments", @"pictures", @"files" ]; }

NSDictionary<NSString *, NSNumber *> *_Nullable SZFriendsDocumentCounts(id _Nullable object) {
    if (![object isKindOfClass:[NSDictionary class]]) return nil;
    NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
    for (NSString *key in SZFDCountKeys()) {
        id value = object[key];
        if (value == nil || value == [NSNull null]) {
            counts[key] = @0;
            continue;
        }
        // Whole numbers only: a JSON true is an NSNumber too, and 2.5 pictures is nothing a sender means.
        if (![value isKindOfClass:[NSNumber class]] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() ||
            [value doubleValue] != (double)[value longLongValue] || [value longLongValue] < 0 ||
            [value unsignedLongLongValue] > SZFriendsDocumentEntryLimit) {
            return nil;
        }
        counts[key] = @([value unsignedIntegerValue]);
    }
    return counts;
}

NSString *_Nullable SZFriendsDocumentJSON(NSDictionary<NSString *, NSNumber *> *_Nullable document) {
    NSDictionary *counts = SZFriendsDocumentCounts(document);
    if (counts == nil) return nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:counts options:NSJSONWritingSortedKeys error:NULL];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

NSDictionary<NSString *, NSNumber *> *_Nullable SZFriendsDocumentFromJSON(NSString *_Nullable json) {
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    id object = data.length && data.length < 4096 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]
                                                  : nil;
    return SZFriendsDocumentCounts(object);
}

#pragma mark - Reading the archive

@interface SZFDEntry : NSObject
@property(nonatomic, copy) NSString *name; // folders end with "/"
@property(nonatomic) uint32_t size;
@property(nonatomic) uint32_t crc;
@property(nonatomic) uint32_t headerOffset;
@end
@implementation SZFDEntry
@end

static uint16_t SZFDGet16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t SZFDGet32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static BOOL SZFDReadAt(int fd, void *bytes, size_t length, uint64_t offset) {
    uint8_t *cursor = bytes;
    while (length) {
        ssize_t got = pread(fd, cursor, length, (off_t)offset);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) return NO;
        cursor += got;
        length -= (size_t)got;
        offset += (uint64_t)got;
    }
    return YES;
}

static BOOL SZFDWriteAll(int fd, const void *bytes, size_t length) {
    const uint8_t *cursor = bytes;
    while (length) {
        ssize_t written = write(fd, cursor, length);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return NO;
        cursor += written;
        length -= (size_t)written;
    }
    return YES;
}

static uint32_t SZFDCRC(uint32_t crc, const uint8_t *bytes, size_t length) {
    static uint32_t table[256];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      for (uint32_t n = 0; n < 256; n++) {
          uint32_t c = n;
          for (int k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
          table[n] = c;
      }
    });
    crc = ~crc;
    for (size_t i = 0; i < length; i++) crc = table[(crc ^ bytes[i]) & 0xff] ^ (crc >> 8);
    return ~crc;
}

// Plain components only: nothing absolute, no "\\", NUL or ":", no empty, "." or ".." component, nothing hidden.
static BOOL SZFDSafeName(NSString *name) {
    if (name.length == 0 || name.length > 1024 || [name hasPrefix:@"/"] || [name containsString:@"\\"] ||
        [name containsString:@":"] || [name rangeOfString:@"\0"].location != NSNotFound) {
        return NO;
    }
    NSString *body = [name hasSuffix:@"/"] ? [name substringToIndex:name.length - 1] : name;
    for (NSString *component in [body componentsSeparatedByString:@"/"]) {
        if (component.length == 0 || [component hasPrefix:@"."]) return NO;
    }
    return YES;
}

static NSArray<SZFDEntry *> *_Nullable SZFDReadEntries(int fd, uint64_t *archiveSize) {
    struct stat info;
    if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size < 22 || info.st_size > 0xffffffffLL) return nil;
    uint64_t fileSize = (uint64_t)info.st_size;
    *archiveSize = fileSize;
    size_t tailLength = (size_t)MIN(fileSize, 22ULL + 0xffff);
    NSMutableData *tail = [NSMutableData dataWithLength:tailLength];
    if (!SZFDReadAt(fd, tail.mutableBytes, tailLength, fileSize - tailLength)) return nil;
    const uint8_t *bytes = tail.bytes, *end = NULL;
    for (size_t at = tailLength - 22 + 1; at-- > 0;) {
        if (SZFDGet32(bytes + at) == SZFDEndSignature && at + 22 + SZFDGet16(bytes + at + 20) == tailLength) {
            end = bytes + at;
            break;
        }
    }
    // One disk, every entry in this directory.
    if (end == NULL || SZFDGet16(end + 4) || SZFDGet16(end + 6) || SZFDGet16(end + 8) != SZFDGet16(end + 10)) {
        return nil;
    }
    NSUInteger count = SZFDGet16(end + 10);
    uint64_t centralSize = SZFDGet32(end + 12), centralOffset = SZFDGet32(end + 16);
    uint64_t endOffset = fileSize - tailLength + (uint64_t)(end - bytes);
    if (count == 0 || count > SZFriendsDocumentEntryLimit || centralOffset + centralSize > endOffset) return nil;
    NSMutableData *central = [NSMutableData dataWithLength:(NSUInteger)centralSize];
    if (!SZFDReadAt(fd, central.mutableBytes, (size_t)centralSize, centralOffset)) return nil;
    const uint8_t *p = central.bytes, *limit = p + centralSize;
    NSMutableArray<SZFDEntry *> *entries = [NSMutableArray arrayWithCapacity:count];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    uint64_t total = 0;
    for (NSUInteger i = 0; i < count; i++) {
        if (limit - p < 46 || SZFDGet32(p) != SZFDCentralSignature) return nil;
        uint16_t madeBy = SZFDGet16(p + 4), flags = SZFDGet16(p + 8), method = SZFDGet16(p + 10);
        uint32_t crc = SZFDGet32(p + 16), packed = SZFDGet32(p + 20), size = SZFDGet32(p + 24);
        uint32_t offset = SZFDGet32(p + 42), mode = SZFDGet32(p + 38) >> 16;
        size_t nameLength = SZFDGet16(p + 28), extra = SZFDGet16(p + 30), comment = SZFDGet16(p + 32);
        if ((size_t)(limit - p) < 46 + nameLength + extra + comment) return nil;
        // Stored, unencrypted, no zip64, and nothing the Mac that made it calls a link.
        if (method != 0 || (flags & 1) || packed != size || size == 0xffffffffu || offset == 0xffffffffu) return nil;
        if ((madeBy >> 8) == 3 && (S_ISLNK(mode) || (mode && !S_ISREG(mode) && !S_ISDIR(mode)))) return nil;
        NSString *name = [[NSString alloc] initWithBytes:p + 46 length:nameLength encoding:NSUTF8StringEncoding];
        if (!SZFDSafeName(name) || ([name hasSuffix:@"/"] && size) || offset >= centralOffset) return nil;
        // Twice under one name, as the volume compares names (case folded), is never two files.
        NSString *key = [name.precomposedStringWithCanonicalMapping.lowercaseString
            stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
        if ([seen containsObject:key]) return nil;
        [seen addObject:key];
        total += size;
        if (total > fileSize) return nil;
        SZFDEntry *entry = [[SZFDEntry alloc] init];
        entry.name = name;
        entry.size = size;
        entry.crc = crc;
        entry.headerOffset = offset;
        [entries addObject:entry];
        p += 46 + nameLength + extra + comment;
    }
    return entries;
}

// Every entry in "<stem>/", the document itself among them as "<stem>/<documentName>"; returns the stem.
static NSString *_Nullable SZFDDocumentFolder(NSArray<SZFDEntry *> *entries, NSString *documentName) {
    NSString *stem = documentName.stringByDeletingPathExtension;
    if (stem.length == 0 || ![SZFriendsSanitizedFileName(documentName) isEqualToString:documentName]) return nil;
    NSString *prefix = [stem stringByAppendingString:@"/"];
    NSString *document = [prefix stringByAppendingString:documentName];
    BOOL found = NO;
    for (SZFDEntry *entry in entries) {
        if (![entry.name hasPrefix:prefix] && ![entry.name isEqualToString:prefix]) return nil;
        if ([entry.name isEqualToString:document]) found = YES;
    }
    return found ? stem : nil;
}

static NSArray<SZFDEntry *> *_Nullable SZFDArchiveEntries(NSString *archive, NSString *documentName,
                                                         uint64_t *archiveSize) {
    int fd = open(archive.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return nil;
    NSArray<SZFDEntry *> *entries = SZFDReadEntries(fd, archiveSize);
    close(fd);
    return entries && SZFDDocumentFolder(entries, documentName) ? entries : nil;
}

BOOL SZFriendsDocumentArchiveIsValid(NSString *archive, NSString *documentName) {
    uint64_t size = 0;
    return SZFDArchiveEntries(archive, documentName, &size) != nil;
}

#pragma mark - Unpacking

// mkdir -p below `directory`, never through a link; each new folder quarantined as its files are.
static BOOL SZFDMakeFolders(NSString *directory, NSArray<NSString *> *components) {
    NSString *path = directory;
    for (NSString *component in components) {
        path = [path stringByAppendingPathComponent:component];
        if (mkdir(path.fileSystemRepresentation, 0755) == 0) {
            if (!SZFriendsSetQuarantine(path, NULL)) return NO;
            continue;
        }
        struct stat info;
        if (errno != EEXIST || lstat(path.fileSystemRepresentation, &info) != 0 || !S_ISDIR(info.st_mode)) return NO;
    }
    return YES;
}

static BOOL SZFDExtractFile(int zip, SZFDEntry *entry, NSString *path, uint64_t archiveSize) {
    uint8_t header[30];
    if (!SZFDReadAt(zip, header, sizeof header, entry.headerOffset) || SZFDGet32(header) != SZFDLocalSignature ||
        SZFDGet16(header + 8) != 0) {
        return NO;
    }
    uint64_t start = (uint64_t)entry.headerOffset + 30 + SZFDGet16(header + 26) + SZFDGet16(header + 28);
    if (start + entry.size > archiveSize) return NO;
    int out = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
    if (out < 0) return NO;
    uint8_t *buffer = malloc(SZFDChunk);
    uint32_t crc = 0;
    BOOL ok = buffer != NULL;
    for (uint64_t done = 0; ok && done < entry.size;) {
        size_t length = (size_t)MIN((uint64_t)SZFDChunk, entry.size - done);
        ok = SZFDReadAt(zip, buffer, length, start + done) && SZFDWriteAll(out, buffer, length);
        crc = SZFDCRC(crc, buffer, length);
        done += length;
    }
    free(buffer);
    ok = ok && crc == entry.crc && SZFriendsMakeDurable(out);
    ok = close(out) == 0 && ok;
    // Quarantined as the archive would have been: Gatekeeper asks before opening any of it, and readers that honour
    // the mark (ShenzhenPDF withholds a Markdown document's remote pictures) treat it as from elsewhere.
    return ok && SZFriendsSetQuarantine(path, NULL);
}

static BOOL SZFDExtract(NSString *archive, NSArray<SZFDEntry *> *entries, NSString *directory) {
    int zip = open(archive.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (zip < 0) return NO;
    struct stat info;
    uint64_t archiveSize = fstat(zip, &info) == 0 ? (uint64_t)info.st_size : 0;
    BOOL ok = YES;
    for (SZFDEntry *entry in entries) {
        BOOL folder = [entry.name hasSuffix:@"/"];
        NSString *body = folder ? [entry.name substringToIndex:entry.name.length - 1] : entry.name;
        NSArray<NSString *> *components = [body componentsSeparatedByString:@"/"];
        NSArray<NSString *> *folders =
            folder ? components : [components subarrayWithRange:NSMakeRange(0, components.count - 1)];
        ok = SZFDMakeFolders(directory, folders) &&
             (folder || SZFDExtractFile(zip, entry, [directory stringByAppendingPathComponent:body], archiveSize));
        if (!ok) break;
    }
    close(zip);
    return ok;
}

static void SZFDSyncDirectory(NSString *directory) {
    int fd = open(directory.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (fd >= 0) {
        fsync(fd);
        close(fd);
    }
}

// The folders received files go to, in SZFriendsPublishReceivedFile's order: the chosen one, Downloads, received/.
static NSArray<NSString *> *SZFDFolders(NSString *stateDirectory) {
    NSMutableArray<NSString *> *folders = [NSMutableArray array];
    struct stat info;
    NSString *chosen = SZFriendsChosenReceivedFolder(stateDirectory);
    if (chosen && stat(chosen.fileSystemRepresentation, &info) == 0 && S_ISDIR(info.st_mode)) {
        [folders addObject:chosen];
    }
    NSString *downloads = SZFriendsDefaultReceivedFolder(stateDirectory);
    if (stat(downloads.fileSystemRepresentation, &info) != 0 && errno == ENOENT) {
        [NSFileManager.defaultManager createDirectoryAtPath:downloads withIntermediateDirectories:YES attributes:nil
                                                      error:NULL];
    }
    if (stat(downloads.fileSystemRepresentation, &info) == 0 && S_ISDIR(info.st_mode) &&
        ![folders containsObject:downloads]) {
        [folders addObject:downloads];
    }
    NSString *own = [stateDirectory stringByAppendingPathComponent:@"received"];
    if (SZFriendsEnsurePrivateDirectory(own, NULL)) [folders addObject:own];
    return folders;
}

NSString *_Nullable SZFriendsPublishReceivedDocument(NSString *staged, NSString *documentName,
                                                     NSString *stateDirectory,
                                                     BOOL (^_Nullable willPublish)(NSString *finalPath,
                                                                                  NSError **error),
                                                     BOOL *notADocument, NSError **error) {
    *notADocument = NO;
    uint64_t archiveSize = 0;
    NSArray<SZFDEntry *> *entries = SZFDArchiveEntries(staged, documentName, &archiveSize);
    if (entries == nil) {
        *notADocument = YES;
        return nil;
    }
    NSString *stem = documentName.stringByDeletingPathExtension;
    for (NSString *folder in SZFDFolders(stateDirectory)) {
        // Unpacked out of sight beside its final place, on the same volume, so taking that place is one rename.
        NSString *pattern = [folder stringByAppendingPathComponent:@".Shenzhen Friends document.XXXXXX"];
        char temporary[PATH_MAX];
        if (strlcpy(temporary, pattern.fileSystemRepresentation, sizeof temporary) >= sizeof temporary ||
            mkdtemp(temporary) == NULL) {
            continue; // a folder that takes nothing: the next one
        }
        NSString *hidden = [NSFileManager.defaultManager stringWithFileSystemRepresentation:temporary
                                                                                     length:strlen(temporary)];
        NSString *unpacked = [hidden stringByAppendingPathComponent:stem];
        BOOL extracted = SZFDExtract(staged, entries, hidden);
        NSString *placed = nil;
        for (int attempt = 0; extracted && attempt < 16 && placed == nil; attempt++) {
            NSString *destination = SZFriendsUniqueDestination(folder, stem);
            NSString *document = [destination stringByAppendingPathComponent:documentName];
            if (willPublish && !willPublish(document, error)) {
                [NSFileManager.defaultManager removeItemAtPath:hidden error:NULL];
                return nil;
            }
            if (renamex_np(unpacked.fileSystemRepresentation, destination.fileSystemRepresentation, RENAME_EXCL) == 0) {
                SZFDSyncDirectory(folder);
                placed = document;
            } else if (errno != EEXIST) {
                break;
            }
        }
        [NSFileManager.defaultManager removeItemAtPath:hidden error:NULL];
        if (placed) {
            unlink(staged.fileSystemRepresentation);
            return placed;
        }
    }
    SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorDatabase, @"no folder takes the document"));
    return nil;
}

NSString *_Nullable SZFriendsDocumentCopyOut(NSString *archive, NSString *documentName, NSString *directory) {
    uint64_t archiveSize = 0;
    NSArray<SZFDEntry *> *entries = SZFDArchiveEntries(archive, documentName, &archiveSize);
    NSString *name = [[documentName.stringByDeletingPathExtension stringByAppendingString:@"/"]
        stringByAppendingString:documentName];
    SZFDEntry *document = nil;
    for (SZFDEntry *entry in entries) if ([entry.name isEqualToString:name]) document = entry;
    if (document == nil || !SZFriendsEnsurePrivateDirectory(directory, NULL)) return nil;
    NSString *pattern = [directory stringByAppendingPathComponent:@".document.XXXXXX"];
    char temporary[PATH_MAX];
    if (strlcpy(temporary, pattern.fileSystemRepresentation, sizeof temporary) >= sizeof temporary ||
        mkdtemp(temporary) == NULL) {
        return nil;
    }
    NSString *folder = [NSFileManager.defaultManager stringWithFileSystemRepresentation:temporary
                                                                                 length:strlen(temporary)];
    NSString *path = [folder stringByAppendingPathComponent:documentName];
    int zip = open(archive.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    BOOL ok = zip >= 0 && SZFDExtractFile(zip, document, path, archiveSize);
    if (zip >= 0) close(zip);
    if (!ok) [NSFileManager.defaultManager removeItemAtPath:folder error:NULL];
    return ok ? path : nil;
}

BOOL SZFriendsReceivedDocumentIsHere(NSString *_Nullable documentPath) {
    struct stat info;
    return documentPath.length && lstat(documentPath.fileSystemRepresentation, &info) == 0 && S_ISREG(info.st_mode);
}

NS_ASSUME_NONNULL_END
