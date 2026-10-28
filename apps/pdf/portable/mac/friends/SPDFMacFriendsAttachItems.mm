#import "SPDFMacFriendsAttachItems.h"
#import "SPDFMacFriendsTabPasteboard.h"
#import "mac/SZFriendsHost.h"
#include <sys/stat.h>

NSString* const SPDFMacFriendsAttachPlaceholder = @"Search open and Collection documents";
NSString* const SPDFMacFriendsAttachCurrentBadge = @"Current";
const NSUInteger SPDFMacFriendsAttachItemLimit = 30;

// One listing's view of Collection: whether it is on, its documents (and their versions) read once, and each path
// asked about once. Each of these reads the whole manifest in the store (430 KB of JSON for 256 documents), so asking
// per document cost 0.4 to 0.6 s on every keystroke with ~100 tabs open.
@interface SPDFMacFriendsLookupSnapshot : NSObject <SPDFMacFriendsCollectionLookup>
- (instancetype)initWithLookup:(id<SPDFMacFriendsCollectionLookup>)lookup;
@end

@implementation SPDFMacFriendsLookupSnapshot {
    id<SPDFMacFriendsCollectionLookup> _lookup;
    NSArray<NSDictionary*>* _documents;
    NSMutableDictionary<NSString*, id>* _byPath;
    NSNumber* _enabled;
}
- (instancetype)initWithLookup:(id<SPDFMacFriendsCollectionLookup>)lookup {
    if (!(self = [super init])) return nil;
    _lookup = lookup;
    _byPath = [NSMutableDictionary dictionary];
    return self;
}
- (BOOL)friendsCollectionEnabled {
    if (!_enabled) _enabled = @(_lookup.friendsCollectionEnabled); // reads the manifest twice
    return _enabled.boolValue;
}
- (NSDictionary*)friendsArchiveInfoForPath:(NSString*)path { return [_lookup friendsArchiveInfoForPath:path]; }
- (NSDictionary*)friendsDocumentForPath:(NSString*)path {
    id found = _byPath[path];
    if (!found) _byPath[path] = found = [_lookup friendsDocumentForPath:path] ?: (id)NSNull.null;
    return found == NSNull.null ? nil : found;
}
- (NSArray<NSDictionary*>*)friendsDocuments { return _documents ?: (_documents = [_lookup friendsDocuments]); }
- (NSArray<NSDictionary*>*)friendsVersionsForDocumentID:(NSString*)documentID {
    for (NSDictionary* document in [self friendsDocuments])
        if ([document[@"id"] isEqual:documentID] && [document[@"versions"] isKindOfClass:NSArray.class])
            return document[@"versions"];
    return [_lookup friendsVersionsForDocumentID:documentID];
}
- (NSURL*)friendsFileForVersionID:(NSString*)versionID documentID:(NSString*)documentID {
    return [_lookup friendsFileForVersionID:versionID documentID:documentID];
}
@end

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
    // Open documents alone can fill the list (about 100 tabs): then the Collection is not read at all.
    if (items.count >= SPDFMacFriendsAttachItemLimit || !lookup.friendsCollectionEnabled) return;
    NSMutableArray* candidates = [NSMutableArray array];
    for (NSDictionary* document in [lookup friendsDocuments]) {
        NSString* path = String(document[@"path"]), *documentID = String(document[@"id"]);
        if (!path.length || !documentID.length || [document[@"excluded"] boolValue]) continue;
        if ([openPaths containsObject:path.stringByStandardizingPath]) continue;  // already listed as open
        if (!Matches(query, String(document[@"title"]), path)) continue;
        // The listing already carries each document's versions; asking for them again rereads the whole manifest,
        // which took 1.7 ms a document (0.4 s for 256).
        NSArray* versions = [document[@"versions"] isKindOfClass:NSArray.class]
            ? document[@"versions"] : [lookup friendsVersionsForDocumentID:documentID];
        NSDictionary* latest = LatestVersion(document, versions);
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

NSArray<SZFriendsAttachableItem*>* SPDFMacFriendsAttachPreview(NSString* query, NSArray<NSDictionary*>* openDocuments) {
    NSString* trimmed = [query ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray* items = [NSMutableArray array];
    NSMutableSet* openPaths = [NSMutableSet set];
    for (NSDictionary* document in openDocuments) {
        NSString* path = String(document[@"path"]);
        if (!path.length || [openPaths containsObject:path.stringByStandardizingPath]) continue;
        [openPaths addObject:path.stringByStandardizingPath];
        if (items.count >= SPDFMacFriendsAttachItemLimit) break;
        if (!Matches(trimmed, String(document[@"title"]), path)) continue;
        // As SPDFMacFriendsAttachItems skips what could not be sent, so the rows it answers with land where these are.
        NSString* displayed = SPDFMacFriendsTabDisplayedFile(document);
        struct stat st = {};
        if (!IsRegularFile(displayed, &st)) continue;
        NSString* place = [document[@"inThisWindow"] boolValue] ? @"Open in this window" : @"Open in another window";
        SZFriendsAttachableItem* item = Item(path.lastPathComponent, place, displayed, nil);
        if ([document[@"current"] boolValue] && !items.count) item.badge = SPDFMacFriendsAttachCurrentBadge;
        [items addObject:item];
    }
    return items;
}

NSArray<SZFriendsAttachableItem*>* SPDFMacFriendsAttachItems(NSString* query, NSArray<NSDictionary*>* openDocuments,
                                                            id<SPDFMacFriendsCollectionLookup> lookup, NSDate* now) {
    NSString* trimmed = [query ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (lookup) lookup = [[SPDFMacFriendsLookupSnapshot alloc] initWithLookup:lookup];
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
        SZFriendsAttachableItem* item = Item(path.lastPathComponent, WithLabel(place, revision), displayed, revision);
        if ([document[@"current"] boolValue] && !items.count) item.badge = SPDFMacFriendsAttachCurrentBadge;
        [items addObject:item];
    }
    AddCollectionItems(items, trimmed, openPaths, lookup, now);
    return items;
}
