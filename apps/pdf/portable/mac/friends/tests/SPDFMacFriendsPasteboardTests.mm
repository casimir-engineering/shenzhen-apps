// Reader tabs dragged onto Friends resolve to the file and the exact revision on screen (brief § Drag and drop),
// through a private pasteboard written the way the tab strip writes it: signed with the reader's per-user key.

#import <AppKit/AppKit.h>
#import "mac/SZFriendsHost.h"
#import "SPDFMacFriendsTabPasteboard.h"
#import "SPDFMacTabDragSignature.h"
#import "SPDFMacFriendsFakeCollection.h"
#import "SPDFMacFriendsTestSupport.h"

static NSString* gDirectory;

static NSString* JSONText(id payload) {
    NSData* json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    return [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
}

static NSPasteboard* PasteboardWithItem(NSPasteboardItem* item) {
    NSPasteboard* pasteboard = [NSPasteboard pasteboardWithUniqueName];
    [pasteboard clearContents];
    [pasteboard writeObjects:@[item]];
    return pasteboard;
}

static NSPasteboard* PasteboardWithPayload(id payload) {
    return PasteboardWithItem(SPDFMacTabDragPasteboardItem(JSONText(payload), SPDFMacTabDragKey(), NSDate.date));
}

static NSArray<SZFriendsAttachableItem*>* Items(NSArray* tabs, id<SPDFMacFriendsCollectionLookup> lookup) {
    return SPDFMacFriendsItemsForTabs(tabs, lookup, SPDFMacFriendsMainThreadHashLimit, NSDate.date, gDirectory);
}

// The keys spdf_dictionary_from_tab writes (SPDFMacModels.mm); only path, title, readOnly, workingPath and the
// Collection labels matter here, the rest is carried to prove they are ignored.
static NSDictionary* Tab(NSString* path, NSDictionary* extra) {
    NSMutableDictionary* tab = [@{@"path" : path, @"title" : path.lastPathComponent, @"page" : @3, @"zoom" : @1.25,
        @"readOnly" : @NO, @"workingPath" : @"", @"sourcePID" : @1, @"sourceWindow" : @7} mutableCopy];
    [tab addEntriesFromDictionary:extra ?: @{}];
    return tab;
}

static void TestTypeMatchesTheTabStrip(void) {
    NSString* header = [NSString stringWithContentsOfFile:@"mac/SPDFMacTabStripViewPrivate.h"
                                                 encoding:NSUTF8StringEncoding error:nil];
    NSString* expected = [NSString stringWithFormat:@"SPDFTabDragPasteboardType = @\"%@\";",
                          SPDFMacFriendsTabPasteboardType];
    Expect([header containsString:expected], @"the tab strip's drag type is no longer %@",
           SPDFMacFriendsTabPasteboardType);
    Expect([SPDFMacTabDragPayloadType isEqual:SPDFMacFriendsTabPasteboardType], @"the signed type differs");
    // Both of the strip's drags (a tab, a group) sign what they write, and nothing writes the type unsigned.
    NSString* drag = [NSString stringWithContentsOfFile:@"mac/SPDFMacTabStripDrag.mm" encoding:NSUTF8StringEncoding
                                                  error:nil];
    Expect([drag componentsSeparatedByString:@"SPDFMacTabDragPasteboardItem(json, SPDFMacTabDragKey(), "
                                             "NSDate.date)"].count == 3 &&
           ![drag containsString:@"forType:SPDFTabDragPasteboardType]"], @"the tab strip writes an unsigned payload");
    // The reading copy's place is the reader's own derivation (ShenzhenPDFMac.mm), so the two must not drift.
    NSString* reader = [NSString stringWithContentsOfFile:@"mac/ShenzhenPDFMac.mm" encoding:NSUTF8StringEncoding
                                                    error:nil];
    for (NSString* line in @[@"stringByAppendingPathComponent:@\"ReadOnlyCopies\"]",
                             @"NSString* standardized = sourcePath.stringByStandardizingPath ?: sourcePath;",
                             @"CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, digest);",
                             @"for (int i = 0; i < 16; ++i) [hex appendFormat:@\"%02x\", digest[i]];",
                             @"NSString* ext = sourcePath.pathExtension.length ? sourcePath.pathExtension : @\"pdf\";",
                             @"return [NSString stringWithFormat:@\"ro-%@.%@\", hex, ext];"])
        Expect([reader containsString:line], @"the reader no longer derives its reading copy with: %@", line);
    NSString* copy = SPDFMacFriendsReadOnlyCopyPath(@"/Users/x/./Protected.pdf", @"/state");
    Expect([copy isEqual:@"/state/ReadOnlyCopies/ro-c17d939c1ba18527473f7a2a6f667c2a.pdf"] &&
           [SPDFMacFriendsReadOnlyCopyPath(@"/Users/x/notes", @"/s").pathExtension isEqual:@"pdf"],
           @"reading copy path %@", copy);
}

static void TestLiveTab(void) {
    NSData* bytes = [@"%PDF-1.7 supplier contract" dataUsingEncoding:NSUTF8StringEncoding];
    NSString* path = SPDFMacFriendsTestWriteFile(gDirectory, @"Supplier contract v3.pdf", bytes);
    SPDFMacFriendsFakeCollection* off = [SPDFMacFriendsFakeCollection new];
    NSPasteboard* pasteboard = PasteboardWithPayload(Tab(path, nil));
    Expect(SPDFMacFriendsPasteboardHasSendableTabs(pasteboard), @"a tab drag must spring-load the button");
    NSArray<SZFriendsAttachableItem*>* items = Items(SPDFMacFriendsTabDictionariesFromPasteboard(pasteboard), off);
    Expect(items.count == 1, @"one tab gave %lu items", (unsigned long)items.count);
    SZFriendsAttachableItem* item = items.firstObject;
    Expect([item.fileURL.path isEqual:path] && [item.title isEqual:@"Supplier contract v3.pdf"] &&
           [item.kindLabel isEqual:@"PDF"], @"item %@ %@ %@", item.fileURL, item.title, item.kindLabel);
    Expect([item.revision[@"source"] isEqual:@"file"] &&
           [item.revision[@"sha256"] isEqual:SPDFMacFriendsTestSHA256(bytes)] &&
           [item.revision[@"size"] unsignedLongLongValue] == bytes.length &&
           [item.revision[@"document_id"] hasPrefix:@"f_"],
           @"revision %@", item.revision);
    Expect(off.calls == 0, @"Collection was consulted while it is off");
    [pasteboard releaseGlobally];
}

static void TestCollectionVersionOfLiveTab(void) {
    NSData* bytes = [@"%PDF-1.7 saved twice" dataUsingEncoding:NSUTF8StringEncoding];
    NSString* path = SPDFMacFriendsTestWriteFile(gDirectory, @"Plan.pdf", bytes);
    SPDFMacFriendsFakeCollection* collection = [SPDFMacFriendsFakeCollection new];
    collection.enabled = YES;
    collection.documents = @[@{@"id" : @"d_7f3a", @"path" : path, @"title" : @"Plan", @"latestVersionID" : @"r_new"}];
    collection.versions = @{@"d_7f3a" : @[
        @{@"id" : @"r_old", @"hash" : @"00ff", @"size" : @4, @"capturedAt" : @1000},
        @{@"id" : @"r_match", @"hash" : SPDFMacFriendsTestSHA256(bytes), @"size" : @(bytes.length),
          @"capturedAt" : @2000},
        @{@"id" : @"r_new", @"hash" : @"abcd", @"size" : @9, @"capturedAt" : @3000}]};
    NSDictionary* revision = Items(@[Tab(path, nil)], collection).firstObject.revision;
    // The version holding the bytes on screen, not the newest version: a tab shows what is on disk now.
    Expect([revision[@"source"] isEqual:@"com.intuition.shenzhenpdf"] && [revision[@"document_id"] isEqual:@"d_7f3a"] &&
           [revision[@"revision_id"] isEqual:@"r_match"] && [revision[@"label"] hasPrefix:@"version saved "],
           @"revision %@", revision);
}

static void TestReadOnlyTabSendsItsWorkingCopy(void) {
    NSData* sourceBytes = [@"source bytes" dataUsingEncoding:NSUTF8StringEncoding];
    NSString* source = SPDFMacFriendsTestWriteFile(gDirectory, @"Protected.pdf", sourceBytes);
    NSString* decoy = SPDFMacFriendsTestWriteFile(gDirectory, @"decoy.txt", [@"not on screen" dataUsingEncoding:4]);
    NSDictionary* tab = Tab(source, @{@"readOnly" : @YES, @"workingPath" : decoy});
    // Before the reader made a reading copy, the tab's own file is sent, under its own name.
    SZFriendsAttachableItem* item = Items(@[tab], nil).firstObject;
    Expect([item.fileURL.path isEqual:source] && [item.title isEqual:@"Protected.pdf"] &&
           [item.revision[@"sha256"] isEqual:SPDFMacFriendsTestSHA256(sourceBytes)],
           @"without a reading copy the source is sent: %@ %@", item.fileURL, item.title);
    // With one, the copy's bytes go under the source's name, found from the reader's state, not workingPath.
    NSString* copy = SPDFMacFriendsReadOnlyCopyPath(source, gDirectory);
    [NSFileManager.defaultManager createDirectoryAtPath:copy.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    NSData* copyBytes = [@"copy bytes on screen" dataUsingEncoding:NSUTF8StringEncoding];
    [copyBytes writeToFile:copy atomically:YES];
    item = Items(@[tab], nil).firstObject;
    Expect([item.fileURL.path isEqual:copy] && [item.title isEqual:@"Protected.pdf"] &&
           [item.revision[@"sha256"] isEqual:SPDFMacFriendsTestSHA256(copyBytes)],
           @"a read-only tab must send the reading copy's bytes under the source's name: %@ %@", item.fileURL,
           item.title);
    // A symlink where the copy belongs is not the reader's copy.
    [NSFileManager.defaultManager removeItemAtPath:copy error:nil];
    symlink(decoy.fileSystemRepresentation, copy.fileSystemRepresentation);
    Expect([Items(@[tab], nil).firstObject.fileURL.path isEqual:source], @"a symlinked reading copy was followed");
    [NSFileManager.defaultManager removeItemAtPath:copy error:nil];
}

// The review's probe (TabProbe.mm): another app writes the tab type naming a photo but pointing workingPath at a
// secret. Nothing unsigned, altered, expired or signed with another key is read; a genuine read-only payload never
// sends workingPath; and the name shown is always the name of the file whose bytes are sent.
static void TestForgedPayloadsAreRefused(void) {
    NSString* photo = SPDFMacFriendsTestWriteFile(gDirectory, @"holiday.jpg", [@"jpeg" dataUsingEncoding:4]);
    NSString* secret = SPDFMacFriendsTestWriteFile(gDirectory, @"secret.txt", [@"PRIVATE KEY" dataUsingEncoding:4]);
    NSString* forged = JSONText(@{@"path" : photo, @"readOnly" : @YES, @"workingPath" : secret});
    NSPasteboardItem* unsignedItem = [NSPasteboardItem new];
    [unsignedItem setString:forged forType:SPDFMacFriendsTabPasteboardType];
    NSPasteboard* pasteboard = PasteboardWithItem(unsignedItem);
    Expect(!SPDFMacFriendsTabDictionariesFromPasteboard(pasteboard).count &&
           !SPDFMacFriendsPasteboardHasSendableTabs(pasteboard), @"an unsigned tab payload was read");
    [pasteboard releaseGlobally];

    NSData* key = SPDFMacTabDragKey();
    NSMutableData* otherKey = [key mutableCopy];
    ((unsigned char*)otherKey.mutableBytes)[0] ^= 1;
    NSDate* now = NSDate.date;
    NSString* expired = SPDFMacTabDragSignature(forged, [now dateByAddingTimeInterval:-16 * 60], key);
    NSString* other = JSONText(@{@"path" : secret});
    for (NSString* signature in @[SPDFMacTabDragSignature(forged, now, otherKey), expired,
                                  SPDFMacTabDragSignature(other, now, key), @"v1.1.00", @""]) {
        NSPasteboardItem* item = [NSPasteboardItem new];
        [item setString:forged forType:SPDFMacFriendsTabPasteboardType];
        [item setString:signature forType:SPDFMacTabDragSignatureType];
        NSPasteboard* board = PasteboardWithItem(item);
        Expect(!SPDFMacFriendsTabDictionariesFromPasteboardWithKey(board, key, now).count,
               @"a payload with signature %@ was read", signature);
        [board releaseGlobally];
    }

    // Signed but naming a working copy elsewhere: the photo itself is sent, as holiday.jpg, never the secret.
    pasteboard = PasteboardWithItem(SPDFMacTabDragPasteboardItem(forged, key, now));
    NSArray<SZFriendsAttachableItem*>* items = Items(SPDFMacFriendsTabDictionariesFromPasteboard(pasteboard), nil);
    Expect(items.count == 1 && [items[0].fileURL.path isEqual:photo] && [items[0].title isEqual:@"holiday.jpg"],
           @"a payload's workingPath was trusted: %@ %@", items.firstObject.fileURL, items.firstObject.title);
    [pasteboard releaseGlobally];
}

// The key: 32 bytes, private to its owner, made once and then reused; an unsafe key file is refused, never replaced.
static void TestDragKey(void) {
    NSString* directory = [gDirectory stringByAppendingPathComponent:@"keys"];
    NSData* first = SPDFMacTabDragKeyInDirectory(directory);
    NSString* path = [directory stringByAppendingPathComponent:SPDFMacTabDragKeyFileName];
    NSDictionary* attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    Expect(first.length == 32 && [attributes[NSFilePosixPermissions] integerValue] == 0600,
           @"key %lu bytes, mode %@", (unsigned long)first.length, attributes[NSFilePosixPermissions]);
    Expect([SPDFMacTabDragKeyInDirectory(directory) isEqual:first], @"a second read made a new key");
    Expect([SPDFMacTabDragKey() isEqual:SPDFMacTabDragKeyInDirectory(gDirectory)], @"the process key is not the state "
           "directory's");
    chmod(path.fileSystemRepresentation, 0644);
    Expect(!SPDFMacTabDragKeyInDirectory(directory) && [[NSData dataWithContentsOfFile:path] isEqual:first],
           @"a readable-by-others key must be refused and left alone");
    NSString* linked = [gDirectory stringByAppendingPathComponent:@"linked"];
    [NSFileManager.defaultManager createDirectoryAtPath:linked withIntermediateDirectories:YES attributes:nil
                                                  error:nil];
    chmod(path.fileSystemRepresentation, 0600);
    symlink(path.fileSystemRepresentation,
            [linked stringByAppendingPathComponent:SPDFMacTabDragKeyFileName].fileSystemRepresentation);
    Expect(!SPDFMacTabDragKeyInDirectory(linked), @"a symlinked key file must be refused");
}

static void TestCollectionArchiveTab(void) {
    NSData* bytes = [@"archived version 9" dataUsingEncoding:NSUTF8StringEncoding];
    NSString* archive = SPDFMacFriendsTestWriteFile(gDirectory, @"Report.pdf", bytes);
    SPDFMacFriendsFakeCollection* collection = [SPDFMacFriendsFakeCollection new];
    collection.enabled = YES;
    NSDictionary* version = @{@"id" : @"v_9", @"hash" : SPDFMacFriendsTestSHA256(bytes), @"size" : @(bytes.length),
                              @"capturedAt" : @1700000000};
    NSDictionary* document = @{@"id" : @"d_2", @"path" : @"/Users/x/Report.pdf"};
    collection.archives = @{archive : @{@"document" : document, @"version" : version}};
    NSDictionary* tab = Tab(archive, @{@"collectionVersionLabel" : @"3 Oct, 09:12", @"collectionHistoryID" : @"d_2"});
    NSDictionary* revision = Items(@[tab], collection).firstObject.revision;
    Expect([revision[@"document_id"] isEqual:@"d_2"] && [revision[@"revision_id"] isEqual:@"v_9"],
           @"archive %@", revision);
    // An archive record whose size differs is not this file: never claim a version the bytes do not match.
    NSMutableDictionary* wrong = [version mutableCopy];
    wrong[@"size"] = @(bytes.length + 1);
    collection.archives = @{archive : @{@"document" : @{@"id" : @"d_2"}, @"version" : wrong}};
    revision = Items(@[tab], collection).firstObject.revision;
    Expect([revision[@"source"] isEqual:@"file"], @"a mismatched archive record was trusted: %@", revision);
}

static void TestGroupsMissingFilesAndFolders(void) {
    NSString* a = SPDFMacFriendsTestWriteFile(gDirectory, @"A.md", [@"# A" dataUsingEncoding:NSUTF8StringEncoding]);
    NSString* b = SPDFMacFriendsTestWriteFile(gDirectory, @"B.epub", [@"epub" dataUsingEncoding:NSUTF8StringEncoding]);
    NSString* folder = [gDirectory stringByAppendingPathComponent:@"Site visit.pdf"];
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:NO attributes:nil error:nil];
    NSPasteboard* pasteboard = PasteboardWithPayload(@{@"groupTabs" : @[Tab(a, nil), Tab(b, nil), Tab(a, nil),
        Tab([gDirectory stringByAppendingPathComponent:@"gone.pdf"], nil), Tab(folder, nil)], @"sourcePID" : @1});
    NSArray<SZFriendsAttachableItem*>* items = Items(SPDFMacFriendsTabDictionariesFromPasteboard(pasteboard), nil);
    Expect(items.count == 2 && [items[0].title isEqual:@"A.md"] && [items[1].title isEqual:@"B.epub"] &&
           [items[0].kindLabel isEqual:@"Markdown"], @"group drag gave %@", [items valueForKey:@"title"]);
    [pasteboard releaseGlobally];

    NSPasteboard* files = [NSPasteboard pasteboardWithUniqueName];
    [files clearContents];
    [files writeObjects:@[[NSURL fileURLWithPath:a]]];
    Expect(!SPDFMacFriendsPasteboardHasSendableTabs(files) && !SPDFMacFriendsTabDictionariesFromPasteboard(files).count,
           @"a Finder file drag is not a tab drag");
    [files releaseGlobally];
}

// The drag verdict's files (review 6d: a tab whose file is a link said "Send to Mei" and sent nothing). Each tab's
// file as it is on disk, read without hashing: links, folders and FIFOs are reported so Friends refuses them; gone
// files and repeats are not. A read-only tab reports the reading copy when the reader made one, else its own file.
static void TestDraggedTabFiles(void) {
    NSString* dir = [gDirectory stringByAppendingPathComponent:@"verdict"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString* real = SPDFMacFriendsTestWriteFile(dir, @"Plan source.pdf", [@"%PDF plan" dataUsingEncoding:4]);
    NSString* (^at)(NSString*) = ^NSString*(NSString* name) { return [dir stringByAppendingPathComponent:name]; };
    symlink(real.fileSystemRepresentation, at(@"Plan.pdf").fileSystemRepresentation);
    symlink(at(@"nowhere.pdf").fileSystemRepresentation, at(@"Dangling.pdf").fileSystemRepresentation);
    mkfifo(at(@"Pipe.pdf").fileSystemRepresentation, 0600);
    [NSFileManager.defaultManager createDirectoryAtPath:at(@"Folder.pdf") withIntermediateDirectories:NO
                                             attributes:nil error:nil];
    NSArray* names = @[@"Plan.pdf", @"Dangling.pdf", @"Pipe.pdf", @"Folder.pdf", @"Plan source.pdf"];
    NSMutableArray* tabs = [NSMutableArray array];
    for (NSString* name in names) [tabs addObject:Tab(at(name), nil)];
    [tabs addObject:Tab(at(@"gone.pdf"), nil)];
    [tabs addObject:Tab([dir stringByAppendingString:@"/./Plan.pdf"], nil)];
    NSPasteboard* pasteboard = PasteboardWithPayload(@{@"groupTabs" : tabs});
    NSArray* files = SPDFMacFriendsDraggedTabFiles(SPDFMacFriendsTabDictionariesFromPasteboard(pasteboard), gDirectory);
    Expect([[files valueForKey:@"lastPathComponent"] isEqual:names], @"dragged files %@", files);
    NSArray* titles = [Items(tabs, nil) valueForKey:@"title"];
    Expect([titles isEqual:@[@"Plan source.pdf"]], @"only the regular file becomes an item: %@", titles);
    [pasteboard releaseGlobally];
    // Read-only: before the reader's copy exists the tab's own file (here a link) is what would be sent.
    NSDictionary* readOnly = Tab(at(@"Plan.pdf"), @{@"readOnly" : @YES, @"workingPath" : real});
    Expect([SPDFMacFriendsDraggedTabFiles(@[readOnly], gDirectory) isEqual:@[at(@"Plan.pdf")]],
           @"a read-only link tab without a reading copy must report the link");
    NSString* copy = SPDFMacFriendsReadOnlyCopyPath(at(@"Plan.pdf"), gDirectory);
    [NSFileManager.defaultManager createDirectoryAtPath:copy.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    [[@"copy" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:copy atomically:YES];
    Expect([SPDFMacFriendsDraggedTabFiles(@[readOnly], gDirectory) isEqual:@[copy]],
           @"a read-only tab with a reading copy reports the copy, whose bytes are sent");
    [NSFileManager.defaultManager removeItemAtPath:copy error:nil];
    [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
}

static void TestBindsExactBytes(void) {
    NSString* path = SPDFMacFriendsTestWriteFile(gDirectory, @"Draft.pdf", [@"first version" dataUsingEncoding:4]);
    NSDictionary* first = SPDFMacFriendsRevisionForFile(path, nil, SPDFMacFriendsMainThreadHashLimit, NSDate.date);
    // Same length, so only the content and the nanosecond modification time differ: the digest cache must notice.
    [[@"other version" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:NO];
    NSDictionary* second = SPDFMacFriendsRevisionForFile(path, nil, SPDFMacFriendsMainThreadHashLimit, NSDate.date);
    Expect(![first[@"sha256"] isEqual:second[@"sha256"]] && ![first[@"revision_id"] isEqual:second[@"revision_id"]],
           @"a changed file kept the earlier digest: %@ %@", first, second);
    // A fresh file: a digest already known for these exact bytes is reused whatever the limit, which is correct.
    NSString* large = SPDFMacFriendsTestWriteFile(gDirectory, @"Large.pdf", [@"thirteen byte" dataUsingEncoding:4]);
    NSDictionary* big = SPDFMacFriendsRevisionForFile(large, nil, 4, NSDate.date);
    Expect(big[@"sha256"] == NSNull.null && [big[@"revision_id"] hasPrefix:@"m_"] && [big[@"size"] integerValue] == 13,
           @"over the hashing limit a revision binds size and identity only: %@", big);
    Expect(!SPDFMacFriendsRevisionForFile(gDirectory, nil, 100, NSDate.date), @"a folder has no revision");
}

static void TestVersionLabels(void) {
    NSCalendar* calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = [NSTimeZone timeZoneWithName:@"Asia/Hong_Kong"];
    NSLocale* locale = [NSLocale localeWithLocaleIdentifier:@"en_GB"];
    NSDate* now = [NSDate dateWithTimeIntervalSince1970:1791787668];  // Monday 12 October 2026, 14:47:48 HKT
    NSString* today = SPDFMacFriendsVersionLabel([now dateByAddingTimeInterval:-46 * 60], now, calendar, locale);
    NSString* yesterday = SPDFMacFriendsVersionLabel([now dateByAddingTimeInterval:-86400], now, calendar, locale);
    NSDate* thirdOfOctober = [NSDate dateWithTimeIntervalSince1970:1790989920];  // 3 Oct 2026, 09:12 HKT
    NSDate* aYearBefore = [NSDate dateWithTimeIntervalSince1970:1759453920];     // 3 Oct 2025, 09:12 HKT
    NSString* earlier = SPDFMacFriendsVersionLabel(thirdOfOctober, now, calendar, locale);
    NSString* lastYear = SPDFMacFriendsVersionLabel(aYearBefore, now, calendar, locale);
    Expect([today isEqual:@"version saved today, 14:01"], @"today: %@", today);
    Expect([yesterday isEqual:@"version saved yesterday, 14:47"], @"yesterday: %@", yesterday);
    Expect([earlier isEqual:@"version saved 3 Oct, 09:12"], @"earlier: %@", earlier);
    Expect([lastYear isEqual:@"version saved 3 Oct 2025"], @"last year: %@", lastYear);
}

int main(void) {
    @autoreleasepool {
        gDirectory = SPDFMacFriendsTestTemporaryDirectory(@"pasteboard");
        SPDFMacFriendsTestUseReaderStateDirectory(gDirectory);
        TestTypeMatchesTheTabStrip();
        TestDragKey();
        TestForgedPayloadsAreRefused();
        TestLiveTab();
        TestCollectionVersionOfLiveTab();
        TestReadOnlyTabSendsItsWorkingCopy();
        TestCollectionArchiveTab();
        TestGroupsMissingFilesAndFolders();
        TestDraggedTabFiles();
        TestBindsExactBytes();
        TestVersionLabels();
        [NSFileManager.defaultManager removeItemAtPath:gDirectory error:nil];
    }
    puts("SPDFMacFriendsPasteboardTests passed");
    return 0;
}
