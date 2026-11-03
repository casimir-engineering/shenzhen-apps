#import "SPDFMacFriendsMarkdownBundle.h"

#import <CommonCrypto/CommonDigest.h>
#import "SPDFMacFriendsZip.h"
#import "SPDFMacMarkdownComments.h"
#import "markdown/SPDFMarkdownParser.h"

#include <fcntl.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>

// Documents larger than this go as they are: the reader parses up to about this much, and a send waits for it.
static const unsigned long long kDocumentLimit = 16ULL << 20;
// What a bundle may hold in all; a linked file that would pass it stays out (the document still goes).
static const unsigned long long kBundleLimit = 1ULL << 30;
static const NSTimeInterval kScratchLifetime = 24 * 60 * 60;
// On a received archive: the folder Open unpacked it into, so the next Open finds it there.
static const char* const kUnpackedAttribute = "com.intuition.shenzhenpdf.unpacked";

static BOOL IsMarkdownName(NSString* name) {
    NSString* extension = name.pathExtension.lowercaseString;
    return [extension isEqualToString:@"md"] || [extension isEqualToString:@"markdown"] ||
        [extension isEqualToString:@"mdown"];
}

static NSString* StringField(NSDictionary* object, NSString* key) {
    id value = [object isKindOfClass:NSDictionary.class] ? object[key] : nil;
    return [value isKindOfClass:NSString.class] && [value length] ? value : nil;
}

#pragma mark - What a document uses

// A local target as the reader resolves one (SPDFMarkdownResources.mm): relative, no scheme, host, query, "..",
// "~" or absolute path; percent-escapes decoded and the fragment dropped. nil for anything else.
static NSArray<NSString*>* LocalComponents(NSString* target) {
    NSString* decoded = [target stringByRemovingPercentEncoding] ?: target;
    NSURLComponents* parts = [NSURLComponents componentsWithString:decoded];
    if (!parts || parts.scheme.length || parts.host.length || parts.user.length || parts.password.length ||
        [decoded hasPrefix:@"//"] || [decoded hasPrefix:@"data:"])
        return nil;
    NSString* path = [decoded componentsSeparatedByString:@"#"].firstObject;
    if (!path.length || [path hasPrefix:@"/"] || [path hasPrefix:@"~"] || [path containsString:@"?"]) return nil;
    NSMutableArray* components = [NSMutableArray array];
    for (NSString* component in path.pathComponents) {
        if ([component isEqualToString:@"."] || !component.length) continue;
        if ([component isEqualToString:@".."] || [component isEqualToString:@"~"] || [component containsString:@"/"] ||
            [component rangeOfString:@"\0"].location != NSNotFound)
            return nil;
        [components addObject:component];
    }
    return components.count ? components : nil;
}

// Pictures and links, wherever they are in the document (lists, quotes, tables), in reading order.
static void CollectTargets(NSArray<SPDFMarkdownBlock*>* blocks, NSMutableOrderedSet<NSString*>* targets) {
    for (SPDFMarkdownBlock* block in blocks) {
        for (SPDFMarkdownInlineRun* run in block.runs)
            if ((run.traits & (SPDFMarkdownInlineTraitImage | SPDFMarkdownInlineTraitLink)) && run.destination.length)
                [targets addObject:run.destination];
        CollectTargets(block.children, targets);
    }
}

// The plain file at `components` below `folder`, every step a real folder (never a link, as the reader reads them).
static BOOL PlainFileBelow(NSString* folder, NSArray<NSString*>* components, unsigned long long* size) {
    NSString* path = folder;
    struct stat info = {};
    for (NSUInteger i = 0; i < components.count; i++) {
        path = [path stringByAppendingPathComponent:components[i]];
        if (lstat(path.fileSystemRepresentation, &info) != 0) return NO;
        BOOL last = i + 1 == components.count;
        if (last ? !S_ISREG(info.st_mode) : !S_ISDIR(info.st_mode)) return NO;
    }
    *size = (unsigned long long)info.st_size;
    return YES;
}

static NSData* ReadPlainFile(NSString* path, unsigned long long limit) {
    struct stat info = {};
    if (lstat(path.fileSystemRepresentation, &info) != 0 || !S_ISREG(info.st_mode) ||
        (unsigned long long)info.st_size > limit)
        return nil;
    return [NSData dataWithContentsOfFile:path options:0 error:nil];
}

// When the file object binds a revision, the bytes read must be it (the helper would refuse anything else).
static BOOL MatchesRevision(NSData* data, NSDictionary* file) {
    id revision = file[@"revision"];
    if (![revision isKindOfClass:NSDictionary.class]) return YES;
    id size = revision[@"size"];
    if ([size isKindOfClass:NSNumber.class] && [size unsignedLongLongValue] != data.length) return NO;
    NSString* digest = StringField(revision, @"sha256");
    if (!digest) return YES;
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, bytes);
    NSMutableString* hex = [NSMutableString stringWithCapacity:64];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", bytes[i]];
    return [hex isEqualToString:digest.lowercaseString];
}

// The document a file is: itself, or for a copy in Collection's archive, the document it is a version of.
static NSString* DocumentPath(NSString* path, id<SPDFMacFriendsCollectionLookup> lookup) {
    if (!lookup.friendsCollectionEnabled) return path;
    NSString* original = StringField([lookup friendsArchiveInfoForPath:path][@"document"], @"path");
    return original ?: path;
}

// The folder name and title inside the archive: the name the friend sees, safe as one path component.
static NSString* SafeStem(NSString* name) {
    NSString* stem = [[name.stringByDeletingPathExtension stringByReplacingOccurrencesOfString:@"/" withString:@"-"]
        stringByReplacingOccurrencesOfString:@":" withString:@"-"];
    stem = [stem stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    while ([stem hasPrefix:@"."]) stem = [stem substringFromIndex:1];
    return stem.length ? stem : @"Document";
}

#pragma mark - Sending

// A new folder of its own in `scratch` for one archive; bundles from earlier sends go once a day has passed (the
// helper copies a file the moment it is sent, so nothing still needs them).
static NSString* NewScratchFolder(NSString* scratch) {
    NSFileManager* files = NSFileManager.defaultManager;
    [files createDirectoryAtPath:scratch withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions : @0700}
                           error:nil];
    NSDate* cutoff = [NSDate dateWithTimeIntervalSinceNow:-kScratchLifetime];
    for (NSString* name in [files contentsOfDirectoryAtPath:scratch error:nil] ?: @[]) {
        NSString* old = [scratch stringByAppendingPathComponent:name];
        NSDate* made = [files attributesOfItemAtPath:old error:nil].fileModificationDate;
        if (made && [made compare:cutoff] == NSOrderedAscending) [files removeItemAtPath:old error:nil];
    }
    NSString* folder = [scratch stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    return mkdir(folder.fileSystemRepresentation, 0700) == 0 ? folder : nil;
}

static NSDictionary* BundleFor(NSDictionary* file, id<SPDFMacFriendsCollectionLookup> lookup, NSString* scratch,
                               NSString** bundledComments) {
    NSString* path = StringField(file, @"path");
    NSString* name = StringField(file, @"display_name") ?: path.lastPathComponent;
    if (!path || !(IsMarkdownName(name) || IsMarkdownName(path)) || SPDFMarkdownIsCommentsFilePath(name) ||
        SPDFMarkdownIsCommentsFilePath(path))
        return nil;
    NSData* document = ReadPlainFile(path, kDocumentLimit);
    if (!document || !MatchesRevision(document, file)) return nil;
    NSString* source = DocumentPath(path, lookup);
    NSString* folder = source.stringByDeletingLastPathComponent;
    NSString* stem = SafeStem(name);
    NSString* extension = IsMarkdownName(name) ? name.pathExtension : path.pathExtension;
    NSString* mainName = [stem stringByAppendingPathExtension:extension];
    NSMutableArray<SPDFMacFriendsZipSource*>* entries = [NSMutableArray array];
    [entries addObject:[SPDFMacFriendsZipSource folder:stem]];
    [entries addObject:[SPDFMacFriendsZipSource file:[NSString stringWithFormat:@"%@/%@", stem, mainName]
                                                data:document]];
    // Lowercased: APFS and HFS+ would take two names differing in case for one file.
    NSMutableSet<NSString*>* taken = [NSMutableSet setWithObject:mainName.lowercaseString];
    unsigned long long total = document.length;

    NSString* comments = SPDFMarkdownCommentsFilePath(source);
    NSData* commentsData = ReadPlainFile(comments, kDocumentLimit);
    NSString* commentsText = commentsData ? [[NSString alloc] initWithData:commentsData encoding:NSUTF8StringEncoding]
                                          : nil;
    BOOL hasComments = commentsText && SPDFMarkdownCommentsParseFile(commentsText).count > 0;
    if (hasComments) {
        NSString* commentsName = SPDFMarkdownCommentsFilePath(mainName);
        [entries addObject:[SPDFMacFriendsZipSource file:[NSString stringWithFormat:@"%@/%@", stem, commentsName]
                                                    data:commentsData]];
        [taken addObject:commentsName.lowercaseString];
        total += commentsData.length;
    }

    NSUInteger beforeFiles = entries.count;
    SPDFMarkdownDocumentModel* model = [[SPDFMarkdownParser new] parseData:document sourceURL:nil error:nil];
    NSMutableOrderedSet<NSString*>* targets = [NSMutableOrderedSet orderedSet];
    CollectTargets(model.blocks ?: @[], targets);
    for (NSString* target in targets) {
        NSArray<NSString*>* components = LocalComponents(target);
        NSString* relative = [components componentsJoinedByString:@"/"];
        unsigned long long size = 0;
        if (!components || [taken containsObject:relative.lowercaseString] ||
            !PlainFileBelow(folder, components, &size) || total + size > kBundleLimit)
            continue;
        // Its folders first, once each, so every unzip tool makes them as they were.
        for (NSUInteger depth = 1; depth < components.count; depth++) {
            NSString* sub = [[components subarrayWithRange:NSMakeRange(0, depth)] componentsJoinedByString:@"/"];
            NSString* key = [sub.lowercaseString stringByAppendingString:@"/"];
            if ([taken containsObject:key]) continue;
            [taken addObject:key];
            [entries addObject:[SPDFMacFriendsZipSource folder:[NSString stringWithFormat:@"%@/%@", stem, sub]]];
        }
        [taken addObject:relative.lowercaseString];
        NSString* sourceFile = [folder stringByAppendingPathComponent:[components componentsJoinedByString:@"/"]];
        [entries addObject:[SPDFMacFriendsZipSource file:[NSString stringWithFormat:@"%@/%@", stem, relative]
                                                    path:sourceFile]];
        total += size;
    }
    if (!hasComments && entries.count == beforeFiles) return nil; // nothing goes with it: the document as it is

    NSString* scratchFolder = NewScratchFolder(scratch);
    NSString* zipName = hasComments ? [NSString stringWithFormat:@"%@ (with comments).zip", stem]
                                    : [stem stringByAppendingPathExtension:@"zip"];
    NSString* zipPath = [scratchFolder stringByAppendingPathComponent:zipName];
    if (!scratchFolder || !SPDFMacFriendsZipWrite(zipPath, entries)) {
        if (scratchFolder) rmdir(scratchFolder.fileSystemRepresentation);
        return nil;
    }
    if (hasComments) *bundledComments = comments.stringByStandardizingPath;
    return @{@"path" : zipPath, @"display_name" : zipName, @"revision" : NSNull.null};
}

NSArray<NSDictionary*>* SPDFMacFriendsFilesWithMarkdownBundles(NSArray<NSDictionary*>* files,
                                                               id<SPDFMacFriendsCollectionLookup> lookup,
                                                               NSString* scratch) {
    NSMutableArray* sent = [NSMutableArray arrayWithCapacity:files.count];
    NSMutableSet<NSString*>* bundledComments = [NSMutableSet set];
    NSMutableIndexSet* bundles = [NSMutableIndexSet indexSet];
    for (NSDictionary* file in files) {
        NSString* comments = nil;
        NSDictionary* bundle = [file isKindOfClass:NSDictionary.class] ? BundleFor(file, lookup, scratch, &comments)
                                                                       : nil;
        if (bundle) [bundles addIndex:sent.count];
        if (comments) [bundledComments addObject:comments];
        [sent addObject:bundle ?: file];
    }
    if (!bundledComments.count) return sent;
    // The same send also named a bundled document's comments file: it is in the bundle already.
    NSMutableArray* kept = [NSMutableArray arrayWithCapacity:sent.count];
    [sent enumerateObjectsUsingBlock:^(NSDictionary* file, NSUInteger index, BOOL* stop) {
        (void)stop;
        NSString* path = StringField(file, @"path").stringByStandardizingPath;
        if ([bundles containsIndex:index] || !path || ![bundledComments containsObject:path]) [kept addObject:file];
    }];
    return kept;
}

#pragma mark - Receiving

// "Report" for an archive whose every entry is in "Report/" and which holds "Report/Report.md" (or .markdown,
// .mdown); *mainName gets that document's name.
static NSString* BundleFolder(NSArray<SPDFMacFriendsZipEntry*>* entries, NSString** mainName) {
    NSString* top = [entries.firstObject.name componentsSeparatedByString:@"/"].firstObject;
    if (!top.length || [top hasPrefix:@"."]) return nil;
    NSString* prefix = [top stringByAppendingString:@"/"];
    NSString* main = nil;
    for (SPDFMacFriendsZipEntry* entry in entries) {
        if (![entry.name hasPrefix:prefix]) return nil;
        NSString* rest = [entry.name substringFromIndex:prefix.length];
        if (!entry.folder && ![rest containsString:@"/"] && IsMarkdownName(rest) &&
            [rest.stringByDeletingPathExtension isEqualToString:top])
            main = rest;
    }
    *mainName = main;
    return main ? top : nil;
}

BOOL SPDFMacFriendsIsMarkdownBundle(NSString* path) {
    if (![path.pathExtension.lowercaseString isEqualToString:@"zip"]) return NO;
    NSArray<SPDFMacFriendsZipEntry*>* entries = SPDFMacFriendsZipEntries(path);
    NSString* mainName = nil;
    return entries && BundleFolder(entries, &mainName) != nil;
}

static NSString* Attribute(NSString* path, const char* name) {
    char value[1024];
    ssize_t length = getxattr(path.fileSystemRepresentation, name, value, sizeof value, 0, 0);
    return length > 0 ? [[NSString alloc] initWithBytes:value length:(NSUInteger)length encoding:NSUTF8StringEncoding]
                      : nil;
}

// Files a friend sent stay marked as from elsewhere when unpacked, as the archive is: Gatekeeper asks before
// opening them, and the reader withholds their remote pictures (SPDFMacMarkdownRemoteImagePolicy.h).
static void CarryQuarantine(NSString* zipPath, NSString* folder) {
    char value[1024];
    ssize_t length = getxattr(zipPath.fileSystemRepresentation, "com.apple.quarantine", value, sizeof value, 0, 0);
    if (length <= 0) return;
    setxattr(folder.fileSystemRepresentation, "com.apple.quarantine", value, (size_t)length, 0, 0);
    NSDirectoryEnumerator* walk = [NSFileManager.defaultManager enumeratorAtPath:folder];
    for (NSString* relative in walk) {
        NSString* path = [folder stringByAppendingPathComponent:relative];
        setxattr(path.fileSystemRepresentation, "com.apple.quarantine", value, (size_t)length, 0, XATTR_NOFOLLOW);
    }
}

NSString* SPDFMacFriendsOpenableMarkdownInBundle(NSString* zipPath) {
    NSArray<SPDFMacFriendsZipEntry*>* entries = SPDFMacFriendsZipEntries(zipPath);
    NSString* mainName = nil;
    NSString* top = entries ? BundleFolder(entries, &mainName) : nil;
    if (!top) return nil;
    NSString* directory = zipPath.stringByDeletingLastPathComponent;
    struct stat info = {};
    NSString* earlier = Attribute(zipPath, kUnpackedAttribute);
    if (earlier.length && ![earlier containsString:@"/"] && ![earlier hasPrefix:@"."]) {
        NSString* document = [[directory stringByAppendingPathComponent:earlier] stringByAppendingPathComponent:mainName];
        if (lstat(document.fileSystemRepresentation, &info) == 0 && S_ISREG(info.st_mode)) return document;
    }
    // Unpacked out of sight first, then moved in whole under a name nothing else has, so a half-written folder never
    // shows and nothing already there is replaced.
    NSString* pattern = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@".%@.unpacking.XXXXXX",
                                                                                              top]];
    char temporary[PATH_MAX];
    if (strlcpy(temporary, pattern.fileSystemRepresentation, sizeof temporary) >= sizeof temporary ||
        !mkdtemp(temporary))
        return nil;
    NSString* staging = [NSFileManager.defaultManager stringWithFileSystemRepresentation:temporary
                                                                                  length:strlen(temporary)];
    NSString* unpacked = [staging stringByAppendingPathComponent:top];
    NSString* placed = nil;
    if (SPDFMacFriendsZipExtract(zipPath, entries, staging)) {
        CarryQuarantine(zipPath, unpacked);
        for (int n = 1; n <= 100 && !placed; n++) {
            NSString* name = n == 1 ? top : [NSString stringWithFormat:@"%@ (%d)", top, n];
            NSString* destination = [directory stringByAppendingPathComponent:name];
            if (renamex_np(unpacked.fileSystemRepresentation, destination.fileSystemRepresentation, RENAME_EXCL) == 0)
                placed = name;
            else if (errno != EEXIST)
                break;
        }
    }
    [NSFileManager.defaultManager removeItemAtPath:staging error:nil];
    if (!placed) return nil;
    NSData* value = [placed dataUsingEncoding:NSUTF8StringEncoding];
    setxattr(zipPath.fileSystemRepresentation, kUnpackedAttribute, value.bytes, value.length, 0, 0);
    return [[directory stringByAppendingPathComponent:placed] stringByAppendingPathComponent:mainName];
}
