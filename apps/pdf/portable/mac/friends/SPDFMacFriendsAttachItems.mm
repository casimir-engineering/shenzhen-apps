#import "SPDFMacFriendsAttachItems.h"
#import "SPDFMacFriendsTabPasteboard.h"
#import "mac/SZFriendsHost.h"
#include <sys/stat.h>

NSString* const SPDFMacFriendsAttachPlaceholder = @"Search open and Collection documents";
const NSUInteger SPDFMacFriendsAttachItemLimit = 30;

static BOOL Matches(NSString* query, NSString* title, NSString* path) {
    if (!query.length) return YES;
    NSStringCompareOptions options = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;
    return (title.length && [title rangeOfString:query options:options].location != NSNotFound) ||
        [path.lastPathComponent rangeOfString:query options:options].location != NSNotFound;
}

static NSString* String(id value) { return [value isKindOfClass:NSString.class] ? value : nil; }

static NSString* WithLabel(NSString* place, NSDictionary* revision) {
    NSString* label = String(revision[@"label"]);
    return label.length ? [NSString stringWithFormat:@"%@ · %@", place, label] : place;
}

static SZFriendsAttachableItem* Item(NSString* name, NSString* detail, NSString* file, NSDictionary* revision) {
    SZFriendsAttachableItem* item = [SZFriendsAttachableItem new];
    item.title = name;
    item.detail = detail;
    item.kindLabel = SPDFMacFriendsKindLabel(name);
    item.fileURL = [NSURL fileURLWithPath:file];
    item.revision = revision;
    return item;
}

static NSDictionary* LatestVersion(NSDictionary* document, NSArray<NSDictionary*>* versions) {
    NSString* latestID = String(document[@"latestVersionID"]);
    NSDictionary* latest = nil;
    for (NSDictionary* version in versions) {
        if (latestID.length && [version[@"id"] isEqual:latestID]) return version;
        if (!latest || [version[@"capturedAt"] doubleValue] > [latest[@"capturedAt"] doubleValue]) latest = version;
    }
    return latest;
}

// A regular file at `path` itself: never a symbolic link, which the helper refuses (README § Hosting, `#`).
static BOOL IsRegularFile(NSString* path, struct stat* st) {
    return path.length && lstat(path.fileSystemRepresentation, st) == 0 && S_ISREG(st->st_mode);
}

// The original when it still holds exactly the latest version's bytes; otherwise that version's archive copy.
// Checked by digest, not by size or date: an edit that keeps the size must not slip a newer file into the chip.
// An original that is a symbolic link is never offered; the version's archive copy stands in, as for an edited one.
static NSString* FileHoldingVersion(NSDictionary* document, NSDictionary* version,
                                    id<SPDFMacFriendsCollectionLookup> lookup) {
    NSString* original = String(document[@"path"]);
    struct stat st = {};
    BOOL replaced = [document[@"sourceReplaced"] boolValue] || [document[@"originalUnavailable"] boolValue];
    if (original.length && !replaced && IsRegularFile(original, &st) &&
        (unsigned long long)st.st_size == [version[@"size"] unsignedLongLongValue]) {
        NSString* digest = SPDFMacFriendsFileSHA256(original, SPDFMacFriendsBackgroundHashLimit, NULL);
        if (digest && [digest isEqual:version[@"hash"]]) return original;
    }
    NSString* versionID = String(version[@"id"]), *documentID = String(document[@"id"]);
    if (!versionID.length || !documentID.length) return nil;
    NSString* copy = [lookup friendsFileForVersionID:versionID documentID:documentID].path;
    return IsRegularFile(copy, &st) ? copy : nil;
}

static void AddCollectionItems(NSMutableArray* items, NSString* query, NSSet<NSString*>* openPaths,
                               id<SPDFMacFriendsCollectionLookup> lookup, NSDate* now) {
    if (!lookup.friendsCollectionEnabled) return;
    NSMutableArray* candidates = [NSMutableArray array];
    for (NSDictionary* document in [lookup friendsDocuments]) {
        NSString* path = String(document[@"path"]), *documentID = String(document[@"id"]);
        if (!path.length || !documentID.length || [document[@"excluded"] boolValue]) continue;
        if ([openPaths containsObject:path.stringByStandardizingPath]) continue;  // already listed as open
        if (!Matches(query, String(document[@"title"]), path)) continue;
        NSDictionary* latest = LatestVersion(document, [lookup friendsVersionsForDocumentID:documentID]);
        if (latest) [candidates addObject:@{@"document" : document, @"version" : latest}];
    }
    [candidates sortUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
        return [b[@"version"][@"capturedAt"] compare:a[@"version"][@"capturedAt"]];
    }];
    for (NSDictionary* candidate in candidates) {
        if (items.count >= SPDFMacFriendsAttachItemLimit) return;
        NSDictionary* document = candidate[@"document"], *version = candidate[@"version"];
        NSString* file = FileHoldingVersion(document, version, lookup);
        if (!file.length) continue;
        NSDate* captured = [NSDate dateWithTimeIntervalSince1970:[version[@"capturedAt"] doubleValue]];
        NSString* label = SPDFMacFriendsVersionLabel(captured, now, NSCalendar.currentCalendar, NSLocale.currentLocale);
        NSDictionary* revision = SPDFMacFriendsCollectionRevision(document, version, label);
        [items addObject:Item(String(document[@"path"]).lastPathComponent, WithLabel(@"Collection", revision), file,
                              revision)];
    }
}

NSArray<SZFriendsAttachableItem*>* SPDFMacFriendsAttachItems(NSString* query, NSArray<NSDictionary*>* openDocuments,
                                                            id<SPDFMacFriendsCollectionLookup> lookup, NSDate* now) {
    NSString* trimmed = [query ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray* items = [NSMutableArray array];
    NSMutableSet* openPaths = [NSMutableSet set];
    for (NSDictionary* document in openDocuments) {
        NSString* path = String(document[@"path"]);
        if (!path.length || [openPaths containsObject:path.stringByStandardizingPath]) continue;
        [openPaths addObject:path.stringByStandardizingPath];
        if (items.count >= SPDFMacFriendsAttachItemLimit) continue;
        if (!Matches(trimmed, String(document[@"title"]), path)) continue;
        NSString* displayed = SPDFMacFriendsTabDisplayedFile(document);
        NSDictionary* revision = displayed
            ? SPDFMacFriendsRevisionForFile(displayed, lookup, SPDFMacFriendsBackgroundHashLimit, now) : nil;
        if (!revision) continue;  // gone, unreadable, a folder or a link: nothing that could be sent
        NSString* place = [document[@"inThisWindow"] boolValue] ? @"Open in this window" : @"Open in another window";
        [items addObject:Item(path.lastPathComponent, WithLabel(place, revision), displayed, revision)];
    }
    AddCollectionItems(items, trimmed, openPaths, lookup, now);
    return items;
}
