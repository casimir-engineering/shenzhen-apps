#import "SPDFMacFriendsTabPasteboard.h"
#import "SPDFMacTabDragSignature.h"
#import "mac/SZFriendsHost.h"
#import <CommonCrypto/CommonDigest.h>
#include <sys/stat.h>

NSPasteboardType const SPDFMacFriendsTabPasteboardType = @"com.intuition.shenzhenpdf.tab";

static NSDictionary* JSONDictionary(NSString* string) {
    NSData* data = [string dataUsingEncoding:NSUTF8StringEncoding];
    id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

static NSString* NonEmptyString(id value) {
    return [value isKindOfClass:NSString.class] && [value length] ? value : nil;
}

NSArray<NSDictionary*>* SPDFMacFriendsTabDictionariesFromPasteboardWithKey(NSPasteboard* pasteboard, NSData* key,
                                                                           NSDate* now) {
    NSMutableArray* tabs = [NSMutableArray array];
    // Every item, not only the first: AppKit may hand a drop several pasteboard items, and the strip writes one.
    for (NSPasteboardItem* item in pasteboard.pasteboardItems) {
        NSDictionary* payload = JSONDictionary(SPDFMacTabDragVerifiedPayload(item, key, now));
        if (!payload) continue;
        NSArray* group = [payload[@"groupTabs"] isKindOfClass:NSArray.class] ? payload[@"groupTabs"] : nil;
        for (id tab in group ?: @[payload])
            if ([tab isKindOfClass:NSDictionary.class] && NonEmptyString(tab[@"path"])) [tabs addObject:tab];
    }
    return tabs;
}

NSArray<NSDictionary*>* SPDFMacFriendsTabDictionariesFromPasteboard(NSPasteboard* pasteboard) {
    if (![pasteboard availableTypeFromArray:@[SPDFMacFriendsTabPasteboardType]]) return @[];
    return SPDFMacFriendsTabDictionariesFromPasteboardWithKey(pasteboard, SPDFMacTabDragKey(), NSDate.date);
}

BOOL SPDFMacFriendsPasteboardHasSendableTabs(NSPasteboard* pasteboard) {
    return SPDFMacFriendsTabDictionariesFromPasteboard(pasteboard).count > 0;
}

NSString* SPDFMacFriendsTabDisplayedFile(NSDictionary* tab) {
    NSString* path = NonEmptyString(tab[@"path"]);
    NSString* working = NonEmptyString(tab[@"workingPath"]);
    // A read-only tab renders its working copy (SPDFMacModels.h: path stays the source everywhere the person
    // perceives the file; workingPath is the render/read copy), so the copy holds the bytes on screen.
    if ([tab[@"readOnly"] boolValue] && working) return working;
    return path;
}

NSString* SPDFMacFriendsReadOnlyCopyPath(NSString* source, NSString* stateDirectory) {
    // The reader's own derivation: SHA-256 of the standardized path, first 16 bytes in hex, the source's extension
    // or "pdf", in ReadOnlyCopies/ of the state directory.
    NSString* standardized = source.stringByStandardizingPath ?: source;
    NSData* bytes = [standardized dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, digest);
    NSMutableString* hex = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < 16; ++i) [hex appendFormat:@"%02x", digest[i]];
    NSString* extension = source.pathExtension.length ? source.pathExtension : @"pdf";
    NSString* name = [NSString stringWithFormat:@"ro-%@.%@", hex, extension];
    return [[stateDirectory stringByAppendingPathComponent:@"ReadOnlyCopies"] stringByAppendingPathComponent:name];
}

NSString* SPDFMacFriendsDraggedTabFile(NSDictionary* tab, NSString* stateDirectory) {
    NSString* path = NonEmptyString(tab[@"path"]);
    if (!path || ![tab[@"readOnly"] boolValue]) return path;
    NSString* copy = SPDFMacFriendsReadOnlyCopyPath(path, stateDirectory);
    struct stat st = {};
    // lstat: the reader writes the copy as a plain file; anything else there is not the copy it shows.
    if (lstat(copy.fileSystemRepresentation, &st) == 0 && S_ISREG(st.st_mode)) return copy;
    return path;
}

NSArray<NSString*>* SPDFMacFriendsDraggedTabFiles(NSArray<NSDictionary*>* tabs, NSString* stateDirectory) {
    NSMutableArray* files = [NSMutableArray array];
    NSMutableSet* seen = [NSMutableSet set];
    for (NSDictionary* tab in tabs) {
        NSString* file = SPDFMacFriendsDraggedTabFile(tab, stateDirectory);
        struct stat st = {};
        // lstat: a link is reported as the link, never as the file it names, so Friends refuses it.
        if (!file || [seen containsObject:file.stringByStandardizingPath] ||
            lstat(file.fileSystemRepresentation, &st) != 0)
            continue;
        [seen addObject:file.stringByStandardizingPath];
        [files addObject:file];
    }
    return files;
}

static NSString* Detail(NSDictionary* revision) {
    id label = revision[@"label"];
    return [label isKindOfClass:NSString.class] && [label length]
        ? [NSString stringWithFormat:@"Open in this window · %@", label] : @"Open in this window";
}

NSArray<SZFriendsAttachableItem*>* SPDFMacFriendsItemsForTabs(NSArray<NSDictionary*>* tabs,
                                                              id<SPDFMacFriendsCollectionLookup> lookup,
                                                              unsigned long long hashLimit, NSDate* now,
                                                              NSString* stateDirectory) {
    NSMutableArray* items = [NSMutableArray array];
    NSMutableSet* seen = [NSMutableSet set];
    for (NSDictionary* tab in tabs) {
        NSString* source = NonEmptyString(tab[@"path"]);
        NSString* sent = SPDFMacFriendsDraggedTabFile(tab, stateDirectory);
        if (!source || !sent || [seen containsObject:sent.stringByStandardizingPath]) continue;
        struct stat st = {};
        if (lstat(sent.fileSystemRepresentation, &st) != 0 || !S_ISREG(st.st_mode)) continue;  // never a link
        NSDictionary* revision = SPDFMacFriendsRevisionForFile(sent, lookup, hashLimit, now);
        if (!revision) continue;
        [seen addObject:sent.stringByStandardizingPath];
        SZFriendsAttachableItem* item = [SZFriendsAttachableItem new];
        // The name friends see belongs to the file sent: its own name, or, for the reading copy (named after a digest
        // of the source's path, so it is the copy of exactly that file), the source's name.
        BOOL readingCopy = [sent isEqual:SPDFMacFriendsReadOnlyCopyPath(source, stateDirectory)];
        NSString* name = readingCopy ? source.lastPathComponent : sent.lastPathComponent;
        item.title = name;
        item.kindLabel = SPDFMacFriendsKindLabel(name);
        item.detail = Detail(revision);
        item.fileURL = [NSURL fileURLWithPath:sent];
        item.revision = revision;
        [items addObject:item];
    }
    return items;
}
