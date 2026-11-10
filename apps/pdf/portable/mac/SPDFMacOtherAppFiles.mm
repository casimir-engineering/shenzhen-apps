#import "SPDFMacOtherAppFiles.h"
#import "SPDFMacStateDirectory.h"
#import <AppKit/AppKit.h>
#import <CommonCrypto/CommonDigest.h>
#include <sys/stat.h>

NSString* SPDFOtherAppContainerOfPath(NSString* path) {
    NSString* found = SPDFOtherAppContainerOfPathSpelling(path);
    if (found || ![path isKindOfClass:NSString.class] || ![path hasPrefix:@"/"]) return found;
    NSMutableArray<NSString*>* pending = [path.pathComponents mutableCopy];
    [pending removeObjectAtIndex:0];
    NSString* current = @"/";
    for (int links = 0; pending.count && links < 40;) {
        NSString* part = pending.firstObject;
        [pending removeObjectAtIndex:0];
        if ([part isEqual:@"."] || [part isEqual:@"/"]) continue;
        if ([part isEqual:@".."]) {
            current = current.stringByDeletingLastPathComponent;
            continue;
        }
        NSString* next = [current stringByAppendingPathComponent:part];
        if ((found = SPDFOtherAppContainerOfPathSpelling(next))) return found; // never step inside
        // The containers folders themselves are not links worth asking about.
        if (SPDFOtherAppContainerOfPathSpelling([next stringByAppendingString:@"/x"])) {
            current = next;
            continue;
        }
        char target[PATH_MAX];
        ssize_t length = readlink(next.fileSystemRepresentation, target, sizeof(target) - 1);
        if (length <= 0) {
            current = next;
            continue;
        }
        links++;
        NSString* link = [NSFileManager.defaultManager stringWithFileSystemRepresentation:target length:(NSUInteger)length];
        NSArray<NSString*>* linkParts = link.pathComponents;
        if ([link hasPrefix:@"/"]) {
            current = @"/";
            linkParts = [linkParts subarrayWithRange:NSMakeRange(1, linkParts.count - 1)];
        }
        [pending replaceObjectsInRange:NSMakeRange(0, 0) withObjectsFromArray:linkParts];
    }
    return SPDFOtherAppContainerOfPathSpelling(current);
}

NSString* SPDFOtherAppNameForContainer(NSString* container) {
    if (!container.length) return nil;
    NSString* identifier = container;
    if ([identifier.lowercaseString hasPrefix:@"group."]) identifier = [identifier substringFromIndex:6];
    // A team-prefixed group ("5A4RE8SF68.com.tencent.xinWeChat") names the app after its team identifier.
    NSRange dot = [identifier rangeOfString:@"."];
    if (dot.location == 10 &&
        [[identifier substringToIndex:10] rangeOfCharacterFromSet:NSCharacterSet.lowercaseLetterCharacterSet].location ==
            NSNotFound)
        identifier = [identifier substringFromIndex:11];
    NSURL* app = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:identifier];
    if (!app) return nil;
    NSString* name = [NSFileManager.defaultManager displayNameAtPath:app.path];
    return [name.pathExtension.lowercaseString isEqual:@"app"] ? name.stringByDeletingPathExtension : name;
}

NSString* SPDFOtherAppUnavailableMessage(NSString* source) {
    NSString* name = SPDFOtherAppNameForContainer(SPDFOtherAppContainerOfPathSpelling(source));
    if (name.length)
        return [NSString stringWithFormat:@"This document is in %@’s files.\nOpen it again from %@ to read it here.",
                                          name, name];
    return @"This document is in another app’s files.\nOpen it again from that app to read it here.";
}

NSString* SPDFOtherAppCopiesFolder(void) {
    return [SPDFMacStateDirectoryPath() stringByAppendingPathComponent:@"Documents from other apps"];
}

static NSString* SourceKey(NSString* source) {
    NSData* bytes = [source dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, digest);
    NSMutableString* hex = [NSMutableString stringWithCapacity:16];
    for (int i = 0; i < 8; ++i) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

NSString* SPDFOtherAppCopyPathForSource(NSString* source) {
    NSString* name = source.lastPathComponent.length ? source.lastPathComponent : @"Document.pdf";
    return [[SPDFOtherAppCopiesFolder() stringByAppendingPathComponent:SourceKey(source)]
        stringByAppendingPathComponent:name];
}

static NSString* RecordPath(NSString* copyPath) {
    return [copyPath.stringByDeletingLastPathComponent stringByAppendingPathComponent:@".original.plist"];
}

static NSLock* gLock;
static NSMutableDictionary<NSString*, NSDictionary*>* gRecords;
static NSMutableSet<NSString*>* gUnreadable;
static NSMutableSet<NSString*>* gChecked;
static void Setup(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLock = [[NSLock alloc] init];
        gRecords = [NSMutableDictionary dictionary];
        gUnreadable = [NSMutableSet set];
        gChecked = [NSMutableSet set];
    });
}

static NSDictionary* Record(NSString* copyPath) {
    NSString* folder = [SPDFOtherAppCopiesFolder() stringByAppendingString:@"/"];
    if (![copyPath isKindOfClass:NSString.class] || ![copyPath hasPrefix:folder] ||
        [copyPath substringFromIndex:folder.length].pathComponents.count != 2)
        return nil;
    Setup();
    [gLock lock];
    NSDictionary* record = gRecords[copyPath];
    [gLock unlock];
    if (record) return record;
    record = [NSDictionary dictionaryWithContentsOfFile:RecordPath(copyPath)];
    if (![record[@"source"] isKindOfClass:NSString.class]) return nil;
    [gLock lock];
    gRecords[copyPath] = record;
    [gLock unlock];
    return record;
}

NSString* SPDFOtherAppSourceOfCopy(NSString* copyPath) { return Record(copyPath)[@"source"]; }

BOOL SPDFOtherAppRecordSource(NSString* source, NSString* copyPath, NSDictionary* fingerprint) {
    if (!source.length || !copyPath.length) return NO;
    NSMutableDictionary* record = [@{@"source" : source} mutableCopy];
    if (fingerprint[@"size"] && fingerprint[@"mtime"]) {
        record[@"size"] = fingerprint[@"size"];
        record[@"mtime"] = fingerprint[@"mtime"];
        record[@"mtimeNS"] = fingerprint[@"mtimeNS"] ?: @0;
    }
    [NSFileManager.defaultManager createDirectoryAtPath:copyPath.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    if (![record writeToFile:RecordPath(copyPath) atomically:YES]) return NO;
    Setup();
    [gLock lock];
    gRecords[copyPath] = record;
    [gLock unlock];
    return YES;
}

BOOL SPDFOtherAppRefreshCopy(NSString* source, NSString* copyPath, BOOL onlyWhenChanged, BOOL* changed, NSError** error) {
    if (changed) *changed = NO;
    struct stat before = {};
    if (stat(source.fileSystemRepresentation, &before) != 0 || !S_ISREG(before.st_mode)) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno ?: ENOENT userInfo:nil];
        return NO;
    }
    NSDictionary* fingerprint = @{@"size" : @((unsigned long long)before.st_size),
                                  @"mtime" : @((long long)before.st_mtimespec.tv_sec),
                                  @"mtimeNS" : @(before.st_mtimespec.tv_nsec)};
    NSDictionary* record = Record(copyPath);
    struct stat existing = {};
    if (onlyWhenChanged && lstat(copyPath.fileSystemRepresentation, &existing) == 0 &&
        [record[@"size"] isEqual:fingerprint[@"size"]] && [record[@"mtime"] isEqual:fingerprint[@"mtime"]] &&
        [record[@"mtimeNS"] isEqual:fingerprint[@"mtimeNS"]])
        return YES;
    NSError* failure = nil;
    NSData* bytes = [NSData dataWithContentsOfFile:source options:NSDataReadingMappedIfSafe error:&failure];
    struct stat after = {};
    if (!bytes || stat(source.fileSystemRepresentation, &after) != 0 || (unsigned long long)after.st_size != bytes.length ||
        after.st_mtimespec.tv_sec != before.st_mtimespec.tv_sec || after.st_mtimespec.tv_nsec != before.st_mtimespec.tv_nsec) {
        if (error) *error = failure ?: [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnknownError userInfo:nil];
        return NO;
    }
    [NSFileManager.defaultManager createDirectoryAtPath:copyPath.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    // Fresh bytes, never a file copy: the other app's attributes would make macOS ask about the copy too.
    if (![bytes writeToFile:copyPath options:NSDataWritingAtomic error:&failure]) {
        if (error) *error = failure;
        return NO;
    }
    SPDFOtherAppRecordSource(source, copyPath, fingerprint);
    if (changed) *changed = YES;
    return YES;
}

void SPDFOtherAppNoteUnreadable(NSString* source, BOOL unreadable) {
    if (!source.length) return;
    Setup();
    [gLock lock];
    if (unreadable) [gUnreadable addObject:source];
    else [gUnreadable removeObject:source];
    [gLock unlock];
}

BOOL SPDFOtherAppIsUnreadable(NSString* source) {
    Setup();
    [gLock lock];
    BOOL unreadable = source && [gUnreadable containsObject:source];
    [gLock unlock];
    return unreadable;
}

BOOL SPDFOtherAppClaimUpdateCheck(NSString* source) {
    if (!source.length) return NO;
    Setup();
    [gLock lock];
    BOOL first = ![gChecked containsObject:source];
    [gChecked addObject:source];
    [gLock unlock];
    return first;
}
