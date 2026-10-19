#import "SPDFMacFriendsRevision.h"
#import <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

NSString* const SPDFMacFriendsRevisionSourceCollection = @"com.intuition.shenzhenpdf";
NSString* const SPDFMacFriendsRevisionSourceFile = @"file";
const unsigned long long SPDFMacFriendsMainThreadHashLimit = 64ULL * 1024 * 1024;
const unsigned long long SPDFMacFriendsBackgroundHashLimit = 1024ULL * 1024 * 1024;

static NSString* StatKey(NSString* path, const struct stat* st) {
    return [NSString stringWithFormat:@"%@\n%llu\n%llu\n%lld\n%ld\n%ld", path, (unsigned long long)st->st_dev,
        (unsigned long long)st->st_ino, (long long)st->st_size, (long)st->st_mtimespec.tv_sec,
        (long)st->st_mtimespec.tv_nsec];
}

static NSCache<NSString*, NSString*>* DigestCache(void) {
    static NSCache* cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; cache.countLimit = 512; });
    return cache;
}

static BOOL SameFile(const struct stat* a, const struct stat* b) {
    return a->st_dev == b->st_dev && a->st_ino == b->st_ino && a->st_size == b->st_size &&
        a->st_mtimespec.tv_sec == b->st_mtimespec.tv_sec && a->st_mtimespec.tv_nsec == b->st_mtimespec.tv_nsec;
}

NSString* SPDFMacFriendsFileSHA256(NSString* path, unsigned long long limit, unsigned long long* size) {
    if (size) *size = 0;
    if (!path.length) return nil;
    // The file itself, never a link's target, and a pipe never waited on: `#` and drops offer only regular files.
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) return nil;
    struct stat before = {};
    if (fstat(fd, &before) != 0 || !S_ISREG(before.st_mode)) { close(fd); return nil; }
    if (size) *size = (unsigned long long)before.st_size;
    NSString* key = StatKey(path, &before);
    NSString* cached = [DigestCache() objectForKey:key];
    if (cached || (unsigned long long)before.st_size > limit) { close(fd); return cached; }
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    NSMutableData* buffer = [NSMutableData dataWithLength:1024 * 1024];
    BOOL failed = NO;
    for (;;) {
        ssize_t count = read(fd, buffer.mutableBytes, buffer.length);
        if (count == 0) break;
        if (count < 0) { failed = YES; break; }
        CC_SHA256_Update(&context, buffer.bytes, (CC_LONG)count);
    }
    struct stat after = {};
    // A file rewritten while it was read has no single digest; report none rather than one of a mixture.
    if (fstat(fd, &after) != 0 || !SameFile(&before, &after)) failed = YES;
    close(fd);
    if (failed) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    NSMutableString* hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    [DigestCache() setObject:hex forKey:key];
    return hex;
}

static NSString* Format(NSDate* date, NSString* template_, NSCalendar* calendar, NSLocale* locale) {
    NSDateFormatter* formatter = [NSDateFormatter new];
    formatter.locale = locale;
    formatter.calendar = calendar;
    formatter.timeZone = calendar.timeZone;
    [formatter setLocalizedDateFormatFromTemplate:template_];
    return [formatter stringFromDate:date];
}

NSString* SPDFMacFriendsVersionLabel(NSDate* captured, NSDate* now, NSCalendar* calendar, NSLocale* locale) {
    NSString* time = Format(captured, @"jjmm", calendar, locale);
    if ([calendar isDate:captured inSameDayAsDate:now])
        return [NSString stringWithFormat:@"version saved today, %@", time];
    NSDate* yesterday = [calendar dateByAddingUnit:NSCalendarUnitDay value:-1 toDate:now options:0];
    if (yesterday && [calendar isDate:captured inSameDayAsDate:yesterday])
        return [NSString stringWithFormat:@"version saved yesterday, %@", time];
    // Older saves name the day; the time only matters while two saves on one day could be confused, and a
    // different year needs the year instead.
    NSInteger year = [calendar component:NSCalendarUnitYear fromDate:now];
    if ([calendar component:NSCalendarUnitYear fromDate:captured] != year)
        return [NSString stringWithFormat:@"version saved %@", Format(captured, @"dMMMy", calendar, locale)];
    return [NSString stringWithFormat:@"version saved %@, %@", Format(captured, @"dMMM", calendar, locale), time];
}

NSDictionary* SPDFMacFriendsCollectionRevision(NSDictionary* document, NSDictionary* version, NSString* label) {
    id hash = [version[@"hash"] isKindOfClass:NSString.class] ? version[@"hash"] : NSNull.null;
    return @{@"source" : SPDFMacFriendsRevisionSourceCollection, @"document_id" : document[@"id"] ?: @"",
             @"revision_id" : version[@"id"] ?: @"", @"label" : label ?: (id)NSNull.null, @"sha256" : hash,
             @"size" : @([version[@"size"] unsignedLongLongValue])};
}

static NSDate* CapturedDate(NSDictionary* version) {
    return [NSDate dateWithTimeIntervalSince1970:[version[@"capturedAt"] doubleValue]];
}

static NSDictionary* CollectionMatch(NSString* path, NSString* digest, unsigned long long size,
                                     id<SPDFMacFriendsCollectionLookup> lookup, NSDate* now) {
    if (!lookup.friendsCollectionEnabled) return nil;
    NSCalendar* calendar = NSCalendar.currentCalendar;
    NSDictionary* archive = [lookup friendsArchiveInfoForPath:path];
    NSDictionary* archived = archive[@"version"];
    // Archive previews are immutable copies of one version; a size mismatch means the file is not that copy.
    if ([archived isKindOfClass:NSDictionary.class] && [archived[@"size"] unsignedLongLongValue] == size &&
        (!digest || [archived[@"hash"] isEqual:digest])) {
        NSString* label = SPDFMacFriendsVersionLabel(CapturedDate(archived), now, calendar, NSLocale.currentLocale);
        return SPDFMacFriendsCollectionRevision(archive[@"document"], archived, label);
    }
    if (!digest) return nil;
    NSDictionary* document = [lookup friendsDocumentForPath:path];
    NSString* documentID = [document[@"id"] isKindOfClass:NSString.class] ? document[@"id"] : nil;
    if (!documentID.length) return nil;
    // Newest first, so a document saved twice with the same bytes binds the version the person saw last.
    NSArray* versions = [[lookup friendsVersionsForDocumentID:documentID] sortedArrayUsingComparator:
        ^NSComparisonResult(NSDictionary* a, NSDictionary* b) { return [b[@"capturedAt"] compare:a[@"capturedAt"]]; }];
    for (NSDictionary* version in versions) {
        if (![version[@"hash"] isEqual:digest]) continue;
        NSString* label = SPDFMacFriendsVersionLabel(CapturedDate(version), now, calendar, NSLocale.currentLocale);
        return SPDFMacFriendsCollectionRevision(document, version, label);
    }
    return nil;
}

NSDictionary* SPDFMacFriendsRevisionForFile(NSString* path, id<SPDFMacFriendsCollectionLookup> lookup,
                                            unsigned long long hashLimit, NSDate* now) {
    struct stat st = {};
    // lstat: a symbolic link is not the file it names, and the helper refuses it (README § Hosting, `#`).
    if (!path.length || lstat(path.fileSystemRepresentation, &st) != 0 || !S_ISREG(st.st_mode)) return nil;
    unsigned long long size = 0;
    NSString* digest = SPDFMacFriendsFileSHA256(path, hashLimit, &size);
    if (!size && st.st_size) return nil;  // unreadable
    NSDictionary* collection = CollectionMatch(path, digest, size, lookup, now);
    if (collection) return collection;
    NSString* documentID = [NSString stringWithFormat:@"f_%llu_%llu", (unsigned long long)st.st_dev,
                                                      (unsigned long long)st.st_ino];
    NSString* revisionID = digest ? [@"s_" stringByAppendingString:[digest substringToIndex:32]]
        : [NSString stringWithFormat:@"m_%llu_%ld_%ld", size, (long)st.st_mtimespec.tv_sec,
                                     (long)st.st_mtimespec.tv_nsec];
    return @{@"source" : SPDFMacFriendsRevisionSourceFile, @"document_id" : documentID, @"revision_id" : revisionID,
             @"label" : NSNull.null, @"sha256" : digest ?: (id)NSNull.null, @"size" : @(size)};
}

NSString* SPDFMacFriendsKindLabel(NSString* path) {
    NSString* extension = path.pathExtension.lowercaseString;
    NSDictionary* names = @{@"pdf" : @"PDF", @"md" : @"Markdown", @"markdown" : @"Markdown", @"mdown" : @"Markdown",
                            @"epub" : @"EPUB", @"xps" : @"XPS", @"oxps" : @"XPS", @"txt" : @"Text",
                            @"jpg" : @"JPEG", @"jpeg" : @"JPEG", @"tif" : @"TIFF", @"tiff" : @"TIFF"};
    return names[extension] ?: (extension.length ? extension.uppercaseString : @"File");
}
