// The `#` items (open and Collection documents, each bound to an exact revision) and the host adapter object,
// driven through a fake reader bridge.

#import <AppKit/AppKit.h>
#import <pthread.h>
#import "mac/SZFriendsDrops.h"
#import "mac/SZFriendsHost.h"
#import "SPDFMacFriendsAttachItems.h"
#import "SPDFMacFriendsHost.h"
#import "SPDFMacFriendsTabPasteboard.h"
#import "SPDFMacTabDragSignature.h"
#import "SPDFMacFriendsFakeCollection.h"
#import "SPDFMacFriendsTestSupport.h"
#include <unistd.h>

static NSString* gDirectory;

static NSData* Bytes(NSString* text) { return [text dataUsingEncoding:NSUTF8StringEncoding]; }

static NSDictionary* Version(NSString* identifier, NSData* bytes, double capturedAt) {
    return @{@"id" : identifier, @"hash" : SPDFMacFriendsTestSHA256(bytes), @"size" : @(bytes.length),
             @"capturedAt" : @(capturedAt)};
}

static void TestOpenThenCollection(void) {
    NSString* a = SPDFMacFriendsTestWriteFile(gDirectory, @"Supplier contract v3.pdf", Bytes(@"contract v3"));
    NSString* b = SPDFMacFriendsTestWriteFile(gDirectory, @"Résumé.md", Bytes(@"# CV"));
    NSData* cBytes = Bytes(@"site photos"), *dSaved = Bytes(@"budget saved"), *gBytes = Bytes(@"gone original");
    NSString* c = SPDFMacFriendsTestWriteFile(gDirectory, @"Site photos.pdf", cBytes);
    NSString* d = SPDFMacFriendsTestWriteFile(gDirectory, @"Budget.pdf", Bytes(@"budget EDITS"));  // same size, edited
    NSString* dArchive = SPDFMacFriendsTestWriteFile(gDirectory, @"Budget-archive.pdf", dSaved);
    NSString* gArchive = SPDFMacFriendsTestWriteFile(gDirectory, @"Gone-archive.pdf", gBytes);
    SPDFMacFriendsFakeCollection* collection = [SPDFMacFriendsFakeCollection new];
    collection.enabled = YES;
    collection.documents = @[
        @{@"id" : @"d_c", @"path" : c, @"title" : @"Site photos", @"latestVersionID" : @"v_c"},
        @{@"id" : @"d_d", @"path" : d, @"title" : @"Budget", @"latestVersionID" : @"v_d"},
        @{@"id" : @"d_a", @"path" : a, @"title" : @"Supplier contract", @"latestVersionID" : @"v_a"},
        @{@"id" : @"d_x", @"path" : c, @"title" : @"Excluded", @"excluded" : @YES},
        @{@"id" : @"d_g", @"path" : [gDirectory stringByAppendingPathComponent:@"Gone.pdf"], @"title" : @"Gone",
          @"latestVersionID" : @"v_g"}];
    collection.versions = @{@"d_c" : @[Version(@"v_c", cBytes, 3000)], @"d_d" : @[Version(@"v_d", dSaved, 2000)],
                            @"d_a" : @[Version(@"v_a", Bytes(@"contract v3"), 500)],
                            @"d_g" : @[Version(@"v_g", gBytes, 1000)], @"d_x" : @[Version(@"v_x", cBytes, 9000)]};
    collection.materialized = @{@"v_d" : dArchive, @"v_g" : gArchive};
    NSArray* open = @[@{@"path" : a, @"title" : @"Supplier contract v3.pdf", @"inThisWindow" : @YES},
                      @{@"path" : b, @"title" : @"Résumé.md", @"inThisWindow" : @NO},
                      @{@"path" : a, @"title" : @"duplicate in a second window", @"inThisWindow" : @NO}];
    NSArray<SZFriendsAttachableItem*>* items = SPDFMacFriendsAttachItems(@"", open, collection, NSDate.date);
    NSArray* titles = [items valueForKey:@"title"];
    NSArray* expected = @[@"Supplier contract v3.pdf", @"Résumé.md", @"Site photos.pdf", @"Budget.pdf", @"Gone.pdf"];
    Expect([titles isEqual:expected], @"items %@", titles);
    Expect([items[0].detail hasPrefix:@"Open in this window"] && [items[1].detail isEqual:@"Open in another window"],
           @"open details %@ / %@", items[0].detail, items[1].detail);
    Expect([items[0].revision[@"revision_id"] isEqual:@"v_a"],
           @"an open document saved in Collection binds that version");
    Expect([items[2].fileURL.path isEqual:c] && [items[2].revision[@"revision_id"] isEqual:@"v_c"] &&
           [items[2].detail hasPrefix:@"Collection · version saved "], @"intact original %@ %@", items[2].fileURL,
           items[2].detail);
    // The original was edited after the save without changing size: the chip must carry the saved bytes.
    Expect([items[3].fileURL.path isEqual:dArchive] &&
           [items[3].revision[@"sha256"] isEqual:SPDFMacFriendsTestSHA256(dSaved)],
           @"an edited original slipped into the chip: %@", items[3].fileURL);
    Expect([items[4].fileURL.path isEqual:gArchive], @"a missing original must send the version's archive copy");

    NSArray* filtered = [SPDFMacFriendsAttachItems(@"CONTRACT", open, collection, NSDate.date) valueForKey:@"title"];
    Expect([filtered isEqual:@[@"Supplier contract v3.pdf"]], @"case-insensitive match %@", filtered);
    filtered = [SPDFMacFriendsAttachItems(@"resume", open, collection, NSDate.date) valueForKey:@"title"];
    Expect([filtered isEqual:@[@"Résumé.md"]], @"diacritic-insensitive match %@", filtered);

    collection.enabled = NO;
    collection.calls = 0;
    Expect(SPDFMacFriendsAttachItems(@"", open, collection, NSDate.date).count == 2 && collection.calls == 0,
           @"Collection was consulted while it is off");
}

// `#` never offers a symbolic link (README § Hosting): the helper refuses one, so an open tab whose file is a link
// is left out, and a Collection document whose original is a link offers its version's archive copy or nothing.
static void TestLinksLeftOut(void) {
    NSData* bytes = Bytes(@"linked contract");
    NSString* real = SPDFMacFriendsTestWriteFile(gDirectory, @"Real.pdf", bytes);
    NSString* (^linkTo)(NSString*, NSString*) = ^NSString*(NSString* target, NSString* name) {
        NSString* path = [gDirectory stringByAppendingPathComponent:name];
        unlink(path.fileSystemRepresentation);
        symlink(target.fileSystemRepresentation, path.fileSystemRepresentation);
        return path;
    };
    NSString* tabLink = linkTo(real, @"Plan.pdf");
    NSString* collectedLink = linkTo(real, @"Collected.pdf");
    NSString* bareLink = linkTo(real, @"Bare.pdf");
    NSString* archive = SPDFMacFriendsTestWriteFile(gDirectory, @"Collected-archive.pdf", bytes);
    NSString* linkedArchive = linkTo(real, @"Bare-archive.pdf");
    Expect(!SPDFMacFriendsRevisionForFile(tabLink, nil, SPDFMacFriendsBackgroundHashLimit, NSDate.date) &&
           !SPDFMacFriendsFileSHA256(tabLink, SPDFMacFriendsBackgroundHashLimit, NULL) &&
           SPDFMacFriendsRevisionForFile(real, nil, SPDFMacFriendsBackgroundHashLimit, NSDate.date),
           @"a link has no revision of its own; the file it names does");
    SPDFMacFriendsFakeCollection* collection = [SPDFMacFriendsFakeCollection new];
    collection.enabled = YES;
    collection.documents = @[
        @{@"id" : @"d_l", @"path" : collectedLink, @"title" : @"Collected", @"latestVersionID" : @"v_l"},
        @{@"id" : @"d_b", @"path" : bareLink, @"title" : @"Bare", @"latestVersionID" : @"v_b"}];
    collection.versions = @{@"d_l" : @[Version(@"v_l", bytes, 100)], @"d_b" : @[Version(@"v_b", bytes, 90)]};
    collection.materialized = @{@"v_l" : archive, @"v_b" : linkedArchive};
    NSArray* open = @[@{@"path" : tabLink, @"title" : @"Plan.pdf", @"inThisWindow" : @YES},
                      @{@"path" : real, @"title" : @"Real.pdf", @"inThisWindow" : @YES}];
    NSArray<SZFriendsAttachableItem*>* items = SPDFMacFriendsAttachItems(@"", open, collection, NSDate.date);
    NSArray* titles = [items valueForKey:@"title"];
    Expect([titles isEqual:(@[@"Real.pdf", @"Collected.pdf"])], @"links left out: %@", titles);
    Expect(items.count == 2 && [items[1].fileURL.path isEqual:archive],
           @"a linked Collection original sends its archive copy, never the link: %@",
           items.count == 2 ? items[1].fileURL.path : @"");
    for (NSString* path in @[tabLink, collectedLink, bareLink, linkedArchive]) unlink(path.fileSystemRepresentation);
}

static void TestLimit(void) {
    NSMutableArray* open = [NSMutableArray array];
    for (int i = 0; i < 45; i++)
        [open addObject:@{@"path" : SPDFMacFriendsTestWriteFile(gDirectory, [NSString stringWithFormat:@"n%02d.pdf", i],
                                                                Bytes([NSString stringWithFormat:@"%d", i])),
                          @"title" : @"", @"inThisWindow" : @YES}];
    Expect(SPDFMacFriendsAttachItems(@"", open, nil, NSDate.date).count == SPDFMacFriendsAttachItemLimit,
           @"the picker must stop at %lu items", (unsigned long)SPDFMacFriendsAttachItemLimit);
}

@interface FakeBridge : NSObject <SPDFMacFriendsReaderBridge>
@property NSMutableArray* opened, *revealed, *installed;
@property NSArray* openDocuments;
@property SPDFMacFriendsFakeCollection* collection;
@property id<SZFriendsServices> services;
@property NSInteger servicesChanges;
@property BOOL openDocumentsReadOffMain;
@end
@implementation FakeBridge
- (instancetype)init {
    if ((self = [super init])) { _opened = [NSMutableArray array]; _revealed = [NSMutableArray array];
                                 _installed = [NSMutableArray array]; }
    return self;
}
- (void)friendsBridgeInstallTitleBarButton:(NSView*)button { [self.installed addObject:button]; }
- (void)friendsBridgeRemoveTitleBarButton:(NSView*)button { [self.installed removeObject:button]; }
- (NSArray*)friendsBridgeOpenDocuments {
    if (!pthread_main_np()) self.openDocumentsReadOffMain = YES;
    return self.openDocuments ?: @[];
}
- (id<SPDFMacFriendsCollectionLookup>)friendsBridgeCollectionLookup { return self.collection; }
- (void)friendsBridgeOpenPaths:(NSArray<NSString*>*)paths { [self.opened addObjectsFromArray:paths]; }
- (void)friendsBridgeRevealFiles:(NSArray<NSURL*>*)urls { [self.revealed addObjectsFromArray:urls]; }
- (void)friendsBridgeServicesChanged:(id<SZFriendsServices>)services {
    self.services = services;
    self.servicesChanges++;
}
- (SZFriendsAppearance*)friendsBridgeAppearance { return [SZFriendsAppearance new]; }
@end

@interface FakeDrag : NSObject
@property NSPasteboard* draggingPasteboard;
@end
@implementation FakeDrag
@end

@interface FakeServices : NSObject <SZFriendsServices>
@end
@implementation FakeServices
- (void)searchMessages:(NSString*)q limit:(NSUInteger)l completion:(void (^)(NSArray<SZFriendsSearchResult*>*))c {
    (void)q; (void)l; c(@[]);
}
- (void)showMessage:(NSString*)m inConversation:(NSString*)c { (void)m; (void)c; }
- (void)openChatScopeForConversations:(NSArray<NSString*>*)ids
                           completion:(void (^)(id<SZFriendsChatScope>, NSError*))completion {
    (void)ids; completion(nil, nil);
}
@end

static BOOL AcceptsDrag(SPDFMacFriendsHost* host, NSPasteboard* pasteboard) {
    FakeDrag* drag = [FakeDrag new];
    drag.draggingPasteboard = pasteboard;
    return [host friendsButtonAcceptsDrag:(id<NSDraggingInfo>)drag];
}

static void TestHostObject(void) {
    FakeBridge* bridge = [FakeBridge new];
    NSString* pdf = SPDFMacFriendsTestWriteFile(gDirectory, @"Received.PDF", Bytes(@"%PDF"));
    NSString* zip = SPDFMacFriendsTestWriteFile(gDirectory, @"Model.step", Bytes(@"ISO-10303"));
    bridge.openDocuments = @[@{@"path" : pdf, @"title" : @"Received.PDF", @"inThisWindow" : @YES}];
    SPDFMacFriendsHost* host = [[SPDFMacFriendsHost alloc] initWithBridge:bridge bundle:NSBundle.mainBundle
                                                                  formats:[NSSet setWithArray:@[@"PDF", @"md"]]];
    Expect([host.friendsAppName isEqual:@"ShenzhenPDF"] && [host.friendsRevealInName isEqual:@"Finder"] &&
           [host.friendsHelperPath isEqual:@""] && host.friendsAssistantReadsChats &&
           [host.friendsAttachPlaceholder isEqual:@"Search open and Collection documents"] &&
           [host.friendsURLScheme isEqual:@"shenzhenpdf"],
           @"identity strings, URL scheme or placeholder are wrong");
    NSSet* lowercase = [NSSet setWithArray:@[@"pdf", @"md"]];
    Expect([host.friendsFormatsOpenedInPlace isEqual:lowercase], @"formats must be lowercase");
    Expect(([host.friendsExtraPasteboardTypes isEqual:@[SPDFMacFriendsTabPasteboardType]]), @"extra pasteboard types");

    [host friendsOpenReceivedFileAtURL:[NSURL fileURLWithPath:pdf]];
    [host friendsOpenReceivedFileAtURL:[NSURL fileURLWithPath:zip]];
    [host friendsOpenReceivedFileAtURL:[NSURL fileURLWithPath:gDirectory]];
    [host friendsOpenReceivedFileAtURL:[NSURL fileURLWithPath:[gDirectory stringByAppendingPathComponent:@"none.pdf"]]];
    Expect(([bridge.opened isEqual:@[pdf]]), @"Open must go through the reader's own open (Collection consent): %@",
           bridge.opened);
    Expect(bridge.revealed.count == 2 && [[bridge.revealed[0] path] isEqual:zip] &&
           [[bridge.revealed[1] path] isEqual:gDirectory],
           @"other formats and folders show in Finder: %@", bridge.revealed);

    __block NSArray* items = nil;
    __block BOOL completedOnMain = NO;
    [host friendsAttachableItemsMatching:@"recei" completion:^(NSArray* result) {
        items = result; completedOnMain = pthread_main_np() != 0;
    }];
    Expect(SPDFMacFriendsTestRunUntil(5, ^BOOL { return items != nil; }), @"# items never completed");
    Expect(items.count == 1 && completedOnMain && !bridge.openDocumentsReadOffMain,
           @"# items: %lu, on main %d, tabs read off main %d", (unsigned long)items.count, completedOnMain,
           bridge.openDocumentsReadOffMain);

    NSPasteboard* tabs = [NSPasteboard pasteboardWithUniqueName];
    [tabs clearContents];
    // Written the way the tab strip writes it, signed with this process's key (SPDFMacTabDragSignature.h).
    NSString* json = [NSString stringWithFormat:@"{\"path\":\"%@\",\"title\":\"x\"}", pdf];
    [tabs writeObjects:@[SPDFMacTabDragPasteboardItem(json, SPDFMacTabDragKey(), NSDate.date)]];
    Expect([host friendsItemsFromPasteboard:tabs].count == 1 && AcceptsDrag(host, tabs), @"a tab drag must resolve");
    NSArray* dragged = [host friendsDraggedFileURLsFromPasteboard:tabs];
    Expect(dragged.count == 1 && [[dragged.firstObject path] isEqual:pdf], @"the verdict's files: %@", dragged);
    // A tab whose file is a link: the verdict is given the link itself (refused), and nothing resolves to send.
    NSString* link = [gDirectory stringByAppendingPathComponent:@"Linked.pdf"];
    symlink(pdf.fileSystemRepresentation, link.fileSystemRepresentation);
    [tabs clearContents];
    json = [NSString stringWithFormat:@"{\"path\":\"%@\",\"title\":\"x\"}", link];
    [tabs writeObjects:@[SPDFMacTabDragPasteboardItem(json, SPDFMacTabDragKey(), NSDate.date)]];
    dragged = [host friendsDraggedFileURLsFromPasteboard:tabs];
    Expect(dragged.count == 1 && [[dragged.firstObject path] isEqual:link] &&
           ![host friendsItemsFromPasteboard:tabs].count, @"a linked tab reaches the verdict as a link: %@", dragged);
    unlink(link.fileSystemRepresentation);
    json = [NSString stringWithFormat:@"{\"path\":\"%@\",\"title\":\"x\"}", pdf];
    [tabs clearContents];
    NSPasteboardItem* unsigned_ = [NSPasteboardItem new];
    [unsigned_ setString:json forType:SPDFMacFriendsTabPasteboardType];
    [tabs writeObjects:@[unsigned_]];
    Expect(![host friendsItemsFromPasteboard:tabs].count && !AcceptsDrag(host, tabs),
           @"another app's unsigned tab payload must send nothing");
    [tabs clearContents];
    [tabs writeObjects:@[SPDFMacTabDragPasteboardItem(@"{\"groupTabs\":[]}", SPDFMacTabDragKey(), NSDate.date)]];
    Expect(!AcceptsDrag(host, tabs) && ![host friendsItemsFromPasteboard:tabs].count, @"an empty group sends nothing");
    [tabs clearContents];
    [tabs writeObjects:@[[NSURL fileURLWithPath:pdf]]];
    Expect(AcceptsDrag(host, tabs), @"Finder files spring-load the button");
    [tabs clearContents];
    [tabs setString:@"plain text" forType:NSPasteboardTypeString];
    Expect(!AcceptsDrag(host, tabs), @"text alone is nothing Friends can send");
    [tabs releaseGlobally];

    NSView* button = [NSView new];
    [host friendsInstallButton:button];
    Expect(bridge.installed.count == 1, @"install goes to the reader's title bar");
    [host friendsRemoveButton:button];
    Expect(!bridge.installed.count, @"remove takes it away");
    FakeServices* services = [FakeServices new];
    [host friendsServicesDidBecomeAvailable:services];
    Expect(host.services == services && bridge.services == services, @"services must reach the reader");
    [host friendsServicesDidBecomeUnavailable];
    Expect(!host.services && !bridge.services && bridge.servicesChanges == 2, @"withdrawn services must be dropped");
}

static NSPasteboard* TabDrag(NSArray<NSString*>* paths) {
    NSMutableArray* tabs = [NSMutableArray array];
    for (NSString* path in paths) [tabs addObject:@{@"path" : path, @"title" : path.lastPathComponent}];
    NSData* json = [NSJSONSerialization dataWithJSONObject:@{@"groupTabs" : tabs} options:0 error:nil];
    NSString* text = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    NSPasteboard* pasteboard = [NSPasteboard pasteboardWithUniqueName];
    [pasteboard clearContents];
    [pasteboard writeObjects:@[SPDFMacTabDragPasteboardItem(text, SPDFMacTabDragKey(), NSDate.date)]];
    return pasteboard;
}

// Review 6d: a tab whose file is a link said "Send to Mei", and the drop sent nothing and left an empty promise
// folder. Through the views' own verdict and reading: the link is refused with drop_not_a_file while dragging, one
// link among regular files refuses the whole drag, and a tab drag resolving to nothing never reaches the promises.
static void TestTabDragVerdict(void) {
    SPDFMacFriendsHost* host = [[SPDFMacFriendsHost alloc] initWithBridge:[FakeBridge new] bundle:NSBundle.mainBundle
                                                                  formats:[NSSet set]];
    NSString* real = SPDFMacFriendsTestWriteFile(gDirectory, @"Plan source.pdf", Bytes(@"%PDF plan"));
    NSString* link = [gDirectory stringByAppendingPathComponent:@"Plan.pdf"];
    symlink(real.fileSystemRepresentation, link.fileSystemRepresentation);
    NSString* gone = [gDirectory stringByAppendingPathComponent:@"gone.pdf"];
    struct { NSArray* paths; SZFriendsDropVerdict verdict; } cases[] = {
        {@[real], SZFriendsDropVerdictAccept}, {@[link], SZFriendsDropVerdictRefuseNotAFile},
        {@[real, link], SZFriendsDropVerdictRefuseNotAFile}, {@[gDirectory], SZFriendsDropVerdictRefuseFolder},
        {@[gone], SZFriendsDropVerdictNone}, {@[real, gone], SZFriendsDropVerdictAccept}};
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; ++i) {
        NSPasteboard* pasteboard = TabDrag(cases[i].paths);
        SZFriendsDropVerdict verdict = [SZFriendsDrops verdictForPasteboard:pasteboard host:host];
        Expect(verdict == cases[i].verdict, @"tab drag %@: verdict %ld", cases[i].paths, (long)verdict);
        [pasteboard releaseGlobally];
    }
    NSPasteboard* linked = TabDrag(@[link]);
    Expect([SZFriendsDropRefusalKey([SZFriendsDrops verdictForPasteboard:linked host:host]) isEqual:@"drop_not_a_file"]
           && ![SZFriendsDrops fileCountForPasteboard:linked host:host], @"a linked tab must show drop_not_a_file");
    [linked releaseGlobally];
    // A drag accepted while dragging whose items resolve to none (here a file the reader cannot read, so it has no
    // revision) sends nothing and makes no promise folder.
    NSString* drops = [gDirectory stringByAppendingPathComponent:@"drops"];
    __block NSArray* read = nil;
    NSPasteboard* empty = TabDrag(@[real]);
    chmod(real.fileSystemRepresentation, 0);
    Expect([SZFriendsDrops verdictForPasteboard:empty host:host] == SZFriendsDropVerdictAccept &&
           ![host friendsItemsFromPasteboard:empty].count, @"an unreadable tab is accepted and resolves to nothing");
    [SZFriendsDrops readItemsFromPasteboard:empty host:host promiseDirectory:drops
                                 completion:^(NSArray* items, BOOL folder) { (void)folder; read = items; }];
    Expect(SPDFMacFriendsTestRunUntil(5, ^BOOL { return read != nil; }) && !read.count &&
           ![NSFileManager.defaultManager fileExistsAtPath:drops], @"an unresolved tab drag fell through to promises");
    [empty releaseGlobally];
    unlink(real.fileSystemRepresentation);
    unlink(link.fileSystemRepresentation);
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        gDirectory = SPDFMacFriendsTestTemporaryDirectory(@"attach");
        SPDFMacFriendsTestUseReaderStateDirectory(gDirectory);
        TestOpenThenCollection();
        TestLinksLeftOut();
        TestLimit();
        TestHostObject();
        TestTabDragVerdict();
        [NSFileManager.defaultManager removeItemAtPath:gDirectory error:nil];
    }
    puts("SPDFMacFriendsAttachTests passed");
    return 0;
}
