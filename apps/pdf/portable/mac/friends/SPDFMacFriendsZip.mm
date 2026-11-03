#import "SPDFMacFriendsZip.h"

#include <fcntl.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

const NSUInteger SPDFMacFriendsZipEntryLimit = 10000;
const unsigned long long SPDFMacFriendsZipByteLimit = 3ULL << 30;

static const uint32_t kLocalSignature = 0x04034b50, kCentralSignature = 0x02014b50, kEndSignature = 0x06054b50;
static const uint16_t kUTF8Names = 0x0800;
static const size_t kChunk = 1 << 20;

#pragma mark - CRC-32

static uint32_t CRCUpdate(uint32_t crc, const uint8_t* bytes, size_t length) {
    static uint32_t table[256];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (uint32_t n = 0; n < 256; n++) {
            uint32_t c = n;
            for (int k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            table[n] = c;
        }
    });
    crc = ~crc;
    for (size_t i = 0; i < length; i++) crc = table[(crc ^ bytes[i]) & 0xff] ^ (crc >> 8);
    return ~crc;
}

#pragma mark - Writing

@implementation SPDFMacFriendsZipSource
+ (instancetype)folder:(NSString*)name {
    SPDFMacFriendsZipSource* source = [self new];
    source.name = [name hasSuffix:@"/"] ? name : [name stringByAppendingString:@"/"];
    return source;
}
+ (instancetype)file:(NSString*)name data:(NSData*)data {
    SPDFMacFriendsZipSource* source = [self new];
    source.name = name;
    source.data = data;
    return source;
}
+ (instancetype)file:(NSString*)name path:(NSString*)path {
    SPDFMacFriendsZipSource* source = [self new];
    source.name = name;
    source.path = path;
    return source;
}
@end

static void Put16(NSMutableData* data, uint16_t value) {
    uint8_t bytes[2] = {(uint8_t)value, (uint8_t)(value >> 8)};
    [data appendBytes:bytes length:2];
}

static void Put32(NSMutableData* data, uint32_t value) {
    uint8_t bytes[4] = {(uint8_t)value, (uint8_t)(value >> 8), (uint8_t)(value >> 16), (uint8_t)(value >> 24)};
    [data appendBytes:bytes length:4];
}

static BOOL WriteAll(int fd, const void* bytes, size_t length) {
    const uint8_t* cursor = (const uint8_t*)bytes;
    while (length) {
        ssize_t written = write(fd, cursor, length);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return NO;
        cursor += written;
        length -= (size_t)written;
    }
    return YES;
}

// MS-DOS date and time, local, as unzip tools show them; 1980-01-01 for anything earlier.
static void DOSTime(time_t seconds, uint16_t* dosTime, uint16_t* dosDate) {
    struct tm parts = {};
    localtime_r(&seconds, &parts);
    if (parts.tm_year < 80) {
        *dosTime = 0;
        *dosDate = (1 << 5) | 1;
        return;
    }
    *dosTime = (uint16_t)((parts.tm_hour << 11) | (parts.tm_min << 5) | (parts.tm_sec / 2));
    *dosDate = (uint16_t)(((parts.tm_year - 80) << 9) | ((parts.tm_mon + 1) << 5) | parts.tm_mday);
}

// Copies one source into the archive at the current offset; the CRC is patched into its header afterwards.
static BOOL WriteEntryBytes(int fd, SPDFMacFriendsZipSource* source, uint32_t* crc, unsigned long long* size) {
    *crc = 0;
    *size = 0;
    if (source.data) {
        *crc = CRCUpdate(0, (const uint8_t*)source.data.bytes, source.data.length);
        *size = source.data.length;
        return WriteAll(fd, source.data.bytes, source.data.length);
    }
    int in = open(source.path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (in < 0) return NO;
    struct stat info = {};
    BOOL ok = fstat(in, &info) == 0 && S_ISREG(info.st_mode);
    NSMutableData* buffer = [NSMutableData dataWithLength:kChunk];
    while (ok) {
        ssize_t got = read(in, buffer.mutableBytes, kChunk);
        if (got < 0 && errno == EINTR) continue;
        if (got < 0) ok = NO;
        if (got <= 0) break;
        *crc = CRCUpdate(*crc, (const uint8_t*)buffer.bytes, (size_t)got);
        *size += (unsigned long long)got;
        ok = *size <= SPDFMacFriendsZipByteLimit && WriteAll(fd, buffer.bytes, (size_t)got);
    }
    close(in);
    return ok;
}

static BOOL WriteArchive(int fd, NSArray<SPDFMacFriendsZipSource*>* entries) {
    NSMutableData* central = [NSMutableData data];
    unsigned long long offset = 0;
    time_t now = time(NULL);
    for (SPDFMacFriendsZipSource* source in entries) {
        NSData* name = [source.name dataUsingEncoding:NSUTF8StringEncoding];
        BOOL folder = [source.name hasSuffix:@"/"];
        if (!name.length || name.length > 0xffff || (!folder && !source.data && !source.path)) return NO;
        struct stat info = {};
        time_t modified = source.path && lstat(source.path.fileSystemRepresentation, &info) == 0
            ? info.st_mtimespec.tv_sec : now;
        uint16_t dosTime = 0, dosDate = 0;
        DOSTime(modified, &dosTime, &dosDate);
        NSMutableData* header = [NSMutableData data];
        Put32(header, kLocalSignature);
        Put16(header, 20);
        Put16(header, kUTF8Names);
        Put16(header, 0); // stored
        Put16(header, dosTime);
        Put16(header, dosDate);
        Put32(header, 0); // CRC, patched below
        Put32(header, 0); // sizes, patched below
        Put32(header, 0);
        Put16(header, (uint16_t)name.length);
        Put16(header, 0);
        [header appendData:name];
        if (!WriteAll(fd, header.bytes, header.length)) return NO;
        uint32_t crc = 0;
        unsigned long long size = 0;
        if (!folder && !WriteEntryBytes(fd, source, &crc, &size)) return NO;
        NSMutableData* patch = [NSMutableData data];
        Put32(patch, crc);
        Put32(patch, (uint32_t)size);
        Put32(patch, (uint32_t)size);
        if (pwrite(fd, patch.bytes, patch.length, (off_t)offset + 14) != (ssize_t)patch.length) return NO;
        Put32(central, kCentralSignature);
        Put16(central, (3 << 8) | 30); // made on Unix, zip 3.0
        Put16(central, 20);
        Put16(central, kUTF8Names);
        Put16(central, 0);
        Put16(central, dosTime);
        Put16(central, dosDate);
        Put32(central, crc);
        Put32(central, (uint32_t)size);
        Put32(central, (uint32_t)size);
        Put16(central, (uint16_t)name.length);
        Put16(central, 0);
        Put16(central, 0);
        Put16(central, 0);
        Put16(central, 0);
        Put32(central, folder ? ((uint32_t)(S_IFDIR | 0755) << 16) | 0x10 : (uint32_t)(S_IFREG | 0644) << 16);
        Put32(central, (uint32_t)offset);
        [central appendData:name];
        offset += header.length + size;
        if (offset + central.length > SPDFMacFriendsZipByteLimit) return NO;
    }
    NSMutableData* end = [NSMutableData data];
    Put32(end, kEndSignature);
    Put16(end, 0);
    Put16(end, 0);
    Put16(end, (uint16_t)entries.count);
    Put16(end, (uint16_t)entries.count);
    Put32(end, (uint32_t)central.length);
    Put32(end, (uint32_t)offset);
    Put16(end, 0);
    return WriteAll(fd, central.bytes, central.length) && WriteAll(fd, end.bytes, end.length);
}

BOOL SPDFMacFriendsZipWrite(NSString* zipPath, NSArray<SPDFMacFriendsZipSource*>* entries) {
    if (!entries.count || entries.count > SPDFMacFriendsZipEntryLimit) return NO;
    int fd = open(zipPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
    if (fd < 0) return NO;
    BOOL ok = WriteArchive(fd, entries);
    ok = close(fd) == 0 && ok;
    if (!ok) unlink(zipPath.fileSystemRepresentation);
    return ok;
}

#pragma mark - Reading

@implementation SPDFMacFriendsZipEntry
- (instancetype)initWithName:(NSString*)name size:(unsigned long long)size crc:(uint32_t)crc
                      offset:(unsigned long long)offset {
    if (!(self = [super init])) return nil;
    _name = [name copy];
    _folder = [name hasSuffix:@"/"];
    _size = size;
    _crc = crc;
    _headerOffset = offset;
    return self;
}
@end

static uint16_t Get16(const uint8_t* p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t Get32(const uint8_t* p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static BOOL ReadAt(int fd, void* bytes, size_t length, unsigned long long offset) {
    uint8_t* cursor = (uint8_t*)bytes;
    while (length) {
        ssize_t got = pread(fd, cursor, length, (off_t)offset);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) return NO;
        cursor += got;
        length -= (size_t)got;
        offset += (unsigned long long)got;
    }
    return YES;
}

// A relative name of plain components: no "/" at the start, no "\", NUL, empty, "." or ".." component.
static BOOL SafeName(NSString* name) {
    if (!name.length || name.length > 1024 || [name hasPrefix:@"/"] || [name containsString:@"\\"] ||
        [name containsString:@"//"] || [name rangeOfString:@"\0"].location != NSNotFound)
        return NO;
    NSString* body = [name hasSuffix:@"/"] ? [name substringToIndex:name.length - 1] : name;
    for (NSString* component in [body componentsSeparatedByString:@"/"])
        if (!component.length || [component isEqualToString:@"."] || [component isEqualToString:@".."]) return NO;
    return YES;
}

static NSArray<SPDFMacFriendsZipEntry*>* ReadEntries(int fd) {
    struct stat info = {};
    if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size < 22) return nil;
    unsigned long long fileSize = (unsigned long long)info.st_size;
    size_t tailLength = (size_t)MIN(fileSize, 22ULL + 0xffff);
    NSMutableData* tail = [NSMutableData dataWithLength:tailLength];
    if (!ReadAt(fd, tail.mutableBytes, tailLength, fileSize - tailLength)) return nil;
    const uint8_t* bytes = (const uint8_t*)tail.bytes;
    const uint8_t* end = NULL;
    for (size_t at = tailLength - 22 + 1; at-- > 0;) {
        if (Get32(bytes + at) == kEndSignature && at + 22 + Get16(bytes + at + 20) == tailLength) {
            end = bytes + at;
            break;
        }
    }
    if (!end || Get16(end + 4) || Get16(end + 6) || Get16(end + 8) != Get16(end + 10)) return nil;
    NSUInteger count = Get16(end + 10);
    unsigned long long centralSize = Get32(end + 12), centralOffset = Get32(end + 16);
    unsigned long long endOffset = fileSize - tailLength + (unsigned long long)(end - bytes);
    if (!count || count > SPDFMacFriendsZipEntryLimit || centralOffset + centralSize > endOffset) return nil;
    NSMutableData* central = [NSMutableData dataWithLength:(NSUInteger)centralSize];
    if (!ReadAt(fd, central.mutableBytes, (size_t)centralSize, centralOffset)) return nil;
    const uint8_t* p = (const uint8_t*)central.bytes;
    const uint8_t* limit = p + centralSize;
    NSMutableArray* entries = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) {
        if (limit - p < 46 || Get32(p) != kCentralSignature) return nil;
        uint16_t flags = Get16(p + 8), method = Get16(p + 10);
        uint32_t crc = Get32(p + 16), packed = Get32(p + 20), size = Get32(p + 24), offset = Get32(p + 42);
        size_t nameLength = Get16(p + 28), extra = Get16(p + 30), comment = Get16(p + 32);
        uint32_t mode = Get32(p + 38) >> 16;
        if ((size_t)(limit - p) < 46 + nameLength + extra + comment) return nil;
        // Stored, unencrypted, no zip64 sizes, and nothing that is a link on the Mac that made it.
        if (method != 0 || (flags & 1) || packed != size || size == 0xffffffffu || offset == 0xffffffffu) return nil;
        if ((Get16(p + 4) >> 8) == 3 && S_ISLNK(mode)) return nil;
        NSString* name = [[NSString alloc] initWithBytes:p + 46 length:nameLength encoding:NSUTF8StringEncoding];
        if (!SafeName(name) || ([name hasSuffix:@"/"] && size) || offset >= centralOffset) return nil;
        [entries addObject:[[SPDFMacFriendsZipEntry alloc] initWithName:name size:size crc:crc offset:offset]];
        p += 46 + nameLength + extra + comment;
    }
    return entries;
}

NSArray<SPDFMacFriendsZipEntry*>* SPDFMacFriendsZipEntries(NSString* zipPath) {
    int fd = open(zipPath.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return nil;
    NSArray* entries = ReadEntries(fd);
    close(fd);
    return entries;
}

#pragma mark - Extracting

// mkdir -p below `directory`, never through a link.
static BOOL MakeFolders(NSString* directory, NSArray<NSString*>* components) {
    NSString* path = directory;
    for (NSString* component in components) {
        path = [path stringByAppendingPathComponent:component];
        if (mkdir(path.fileSystemRepresentation, 0755) == 0) continue;
        struct stat info = {};
        if (errno != EEXIST || lstat(path.fileSystemRepresentation, &info) != 0 || !S_ISDIR(info.st_mode)) return NO;
    }
    return YES;
}

static BOOL ExtractFile(int zip, SPDFMacFriendsZipEntry* entry, NSString* path, unsigned long long dataLimit) {
    uint8_t header[30];
    if (!ReadAt(zip, header, sizeof header, entry.headerOffset) || Get32(header) != kLocalSignature) return NO;
    unsigned long long start = entry.headerOffset + 30 + Get16(header + 26) + Get16(header + 28);
    if (start + entry.size > dataLimit) return NO;
    int out = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
    if (out < 0) return NO;
    NSMutableData* buffer = [NSMutableData dataWithLength:kChunk];
    uint32_t crc = 0;
    BOOL ok = YES;
    for (unsigned long long done = 0; ok && done < entry.size;) {
        size_t length = (size_t)MIN((unsigned long long)kChunk, entry.size - done);
        ok = ReadAt(zip, buffer.mutableBytes, length, start + done) && WriteAll(out, buffer.bytes, length);
        crc = CRCUpdate(crc, (const uint8_t*)buffer.bytes, length);
        done += length;
    }
    ok = close(out) == 0 && ok;
    return ok && crc == entry.crc;
}

BOOL SPDFMacFriendsZipExtract(NSString* zipPath, NSArray<SPDFMacFriendsZipEntry*>* entries, NSString* directory) {
    int zip = open(zipPath.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (zip < 0) return NO;
    struct stat info = {};
    unsigned long long dataLimit = fstat(zip, &info) == 0 ? (unsigned long long)info.st_size : 0;
    BOOL ok = YES;
    for (SPDFMacFriendsZipEntry* entry in entries) {
        NSString* body = entry.folder ? [entry.name substringToIndex:entry.name.length - 1] : entry.name;
        NSArray* components = [body componentsSeparatedByString:@"/"];
        NSArray* folders = entry.folder ? components : [components subarrayWithRange:NSMakeRange(0, components.count - 1)];
        ok = MakeFolders(directory, folders) &&
            (entry.folder || ExtractFile(zip, entry, [directory stringByAppendingPathComponent:body], dataLimit));
        if (!ok) break;
    }
    close(zip);
    return ok;
}
