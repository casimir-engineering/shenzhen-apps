// Received files into Collection (SPDFMacFriendsReceivedFiles.h) with real helpers: Ana's helper sends Ben a PDF and
// a file ShenzhenPDF does not open; Ben's ShenzhenPDF side (the reader's host, the views' link to Ben's helper and the
// received-files follower, as SPDFMacFriendsIntegration.mm builds them) captures the PDF into Collection with reason
// "Received" and opens nothing. Collection off or not yet chosen captures nothing, the same snapshot delivered again
// (or heard by another window) captures nothing more, and files received before the first run stay out.
//
// Usage: SPDFMacFriendsReceivedTests <e2e helper> <animal manifest>
//
// Hidden: no window, no Dock icon. Every helper runs in a temporary home with SZFRIENDS_STATE_DIR,
// SZFRIENDS_DOWNLOADS_DIR and HOME inside this run's folder, the file key store and a loopback-only Bonjour type;
// every Collection is a temporary root (initWithRootURL:), never the reader's own.

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>

#ifdef __cplusplus
extern "C" {
#endif
#import "SZFriendsE2EHarness.h"
#ifdef __cplusplus
}
#endif
#import "mac/SZFriendsHelperLink.h"
#import "SPDFMacCollectionStore.h"
#import "SPDFMacDocumentFormats.h"
#import "SPDFMacFriendsAppearance.h"
#import "SPDFMacFriendsHost.h"
#import "SPDFMacFriendsReceivedFiles.h"
#import "SPDFMacFriendsTestSupport.h"

static NSString* gRoot;

static void RemoveRoot(void) {
    if (gRoot.length && [gRoot.lastPathComponent hasPrefix:@"szfrx."])
        [NSFileManager.defaultManager removeItemAtPath:gRoot error:nil];
}

// The reader's side of the bridge, recording what Friends asks of it instead of opening anything.
@interface ReceivedBridge : NSObject <SPDFMacFriendsReaderBridge>
@property(nonatomic, strong) NSMutableArray<NSString*>* opened;
@end
@implementation ReceivedBridge
- (instancetype)init {
    if ((self = [super init])) _opened = [NSMutableArray array];
    return self;
}
- (void)friendsBridgeInstallTitleBarButton:(NSView*)button { (void)button; }
- (void)friendsBridgeRemoveTitleBarButton:(NSView*)button { (void)button; }
- (NSArray<NSDictionary*>*)friendsBridgeOpenDocuments { return @[]; }
- (id<SPDFMacFriendsCollectionLookup>)friendsBridgeCollectionLookup { return nil; }
- (void)friendsBridgeOpenPaths:(NSArray<NSString*>*)paths { [self.opened addObjectsFromArray:paths]; }
- (void)friendsBridgeRevealFiles:(NSArray<NSURL*>*)fileURLs { (void)fileURLs; }
- (void)friendsBridgeServicesChanged:(id<SZFriendsServices>)services { (void)services; }
- (SZFriendsAppearance*)friendsBridgeAppearance { return SPDFMacFriendsReaderAppearance(); }
@end

// Runs the main run loop (the link's sources, Collection's completions) and every harness client.
static BOOL Wait(NSTimeInterval seconds, BOOL (^condition)(void)) {
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!condition()) {
        if (deadline.timeIntervalSinceNow <= 0) return NO;
        @autoreleasepool {
            [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
            SZFE2EPump(0);
        }
    }
    return YES;
}

#pragma mark - Two people (the two-helper harness's steps, as friends/tests/e2e/SZFriendsE2ETests.m takes them)

static NSDictionary* RowTitled(NSDictionary* list, NSString* title) {
    for (NSDictionary* row in list[@"rows"])
        if ([row[@"title"] isEqual:title]) return row;
    return nil;
}

static SZFE2EClient* StartPerson(SZFE2EWorld* world, NSString* name, NSString* displayName, SZFE2EHelper** helper,
                                 NSString** list) {
    *helper = [world helperNamed:name];
    NSString* home = [(*helper).stateDirectory stringByAppendingString:@"-home"];
    NSString* downloads = [(*helper).stateDirectory stringByAppendingString:@"-downloads"];
    for (NSString* folder in @[ home, downloads ])
        [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES
                                                 attributes:@{NSFilePosixPermissions : @0700} error:nil];
    (*helper).extraEnvironment = @{@"HOME" : home, @"SZFRIENDS_DOWNLOADS_DIR" : downloads,
                                   @"SZFRIENDS_E2E_DEVICE_NAME" : [@"Test computer " stringByAppendingString:name],
                                   @"SZFRIENDS_E2E_DEVICE_SYSTEM" : @"Test system 1.0"};
    Expect([*helper start], @"%@'s helper did not start", name);
    SZFE2EClient* client = [SZFE2EClient clientForHelper:*helper];
    Expect(client != nil, @"%@'s client never reached READY:\n%@", name, (*helper).log);
    Expect([[client intent:@"activate" fields:nil][@"ok"] boolValue], @"activate %@", name);
    Expect([[client intent:@"set_name" fields:@{@"name" : displayName}][@"ok"] boolValue], @"set_name %@", name);
    *list = [client subscribe:@"list" params:nil];
    Expect(*list != nil, @"no list subscription for %@", name);
    return client;
}

// Ben visible, Ana asks from Nearby, Ben accepts; returns Ana's conversation at Ben's and Ben's at Ana's.
static void Befriend(SZFE2EClient* a, NSString* listA, SZFE2EClient* b, NSString* listB, NSString** aAtB,
                     NSString** bAtA) {
    Expect([[b intent:@"start_visibility" fields:nil][@"result"][@"deadline"] length] > 0, @"Ben is not visible");
    NSString* nearby = [a subscribe:@"nearby" params:nil];
    __block NSString* nearbyID = nil;
    Expect(Wait(20, ^BOOL {
               for (NSDictionary* person in [a dataFor:nearby][@"people"])
                   if ([person[@"title"] isEqual:@"Ben"] && [person[@"nearby_id"] isKindOfClass:NSString.class])
                       nearbyID = person[@"nearby_id"];
               return nearbyID != nil;
           }), @"Ana never saw Ben in Nearby: %@", [a dataFor:nearby]);
    Expect([[a intent:@"send_request" fields:@{@"nearby_id" : nearbyID}][@"ok"] boolValue], @"send_request");
    [a intent:@"unsubscribe" fields:@{@"subscription" : nearby}];
    Expect(Wait(20, ^BOOL { return [RowTitled([b dataFor:listB], @"Ana")[@"waiting"][@"kind"] isEqual:@"request"]; }),
           @"Ben never saw Ana's request: %@", [b dataFor:listB]);
    *aAtB = RowTitled([b dataFor:listB], @"Ana")[@"conversation_id"];
    *bAtA = RowTitled([a dataFor:listA], @"Ben")[@"conversation_id"];
    Expect(*aAtB && *bAtA, @"no rows: %@ / %@", [a dataFor:listA], [b dataFor:listB]);
    NSDictionary* reply = [b intent:@"accept_request" fields:@{@"conversation_id" : *aAtB}];
    Expect([reply[@"ok"] boolValue], @"accept_request: %@", reply);
    NSString* atA = *bAtA, *atB = *aAtB;
    Expect(Wait(15, ^BOOL {
               id dropA = nil, dropB = nil;
               for (NSDictionary* row in [a dataFor:listA][@"rows"])
                   if ([row[@"conversation_id"] isEqual:atA]) dropA = row[@"drop_label"];
               for (NSDictionary* row in [b dataFor:listB][@"rows"])
                   if ([row[@"conversation_id"] isEqual:atB]) dropB = row[@"drop_label"];
               return [dropA isKindOfClass:NSString.class] && [dropB isKindOfClass:NSString.class];
           }), @"never friends: %@ / %@", [a dataFor:listA], [b dataFor:listB]);
    [b intent:@"stop_visibility" fields:nil];
}

#pragma mark - Collection

static SPDFMacCollectionStore* Store(NSString* name, NSString* choice) {
    SPDFMacCollectionStore* store =
        [[SPDFMacCollectionStore alloc] initWithRootURL:[NSURL fileURLWithPath:[gRoot stringByAppendingPathComponent:name]]];
    if (choice) Expect([store updateSettings:@{@"choice" : choice} error:nil], @"Collection %@ not set %@", name, choice);
    return store;
}

// A follower recording every snapshot it handled and every capture it finished.
@interface Follower : NSObject
@property(nonatomic, strong) SPDFMacFriendsReceivedFiles* received;
@property(nonatomic) NSInteger snapshots;
@property(nonatomic, strong) NSMutableArray<NSString*>* capturing;
@property(nonatomic, strong) NSMutableDictionary<NSString*, id>* captured; // path -> document or NSNull
@end
@implementation Follower
@end

static Follower* Follow(SPDFMacCollectionStore* store) {
    Follower* follower = [Follower new];
    follower.capturing = [NSMutableArray array];
    follower.captured = [NSMutableDictionary dictionary];
    follower.received = [[SPDFMacFriendsReceivedFiles alloc] initWithStore:store
        isDocument:^BOOL(NSString* path) { return SPDFReadableDocumentPath(path); }];
    __weak Follower* weak = follower;
    follower.received.snapshotHandled = ^(NSArray<NSString*>* paths) {
        weak.snapshots++;
        [weak.capturing addObjectsFromArray:paths];
    };
    follower.received.captured = ^(NSString* path, NSDictionary* document, NSError* error) {
        Expect(!error, @"capturing %@ failed: %@", path, error);
        weak.captured[path] = document ?: (id)NSNull.null;
    };
    return follower;
}

// Hands `data` to the follower and waits until it has been handled; returns the paths it began capturing.
static NSArray<NSString*>* Deliver(Follower* follower, NSDictionary* data) {
    NSInteger before = follower.snapshots;
    NSUInteger capturing = follower.capturing.count;
    [follower.received takeSnapshot:data];
    Expect(Wait(5, ^BOOL { return follower.snapshots > before; }), @"the snapshot was never handled");
    // A capture that did start has to finish before anything is counted.
    Wait(1, ^BOOL { return follower.captured.count >= follower.capturing.count; });
    return [follower.capturing subarrayWithRange:NSMakeRange(capturing, follower.capturing.count - capturing)];
}

static NSString* WritePDF(NSString* path) {
    CGRect box = CGRectMake(0, 0, 200, 200);
    CGContextRef context = CGPDFContextCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], &box, NULL);
    Expect(context, @"no PDF context");
    CGPDFContextBeginPage(context, NULL);
    CGContextFillRect(context, CGRectMake(20, 20, 60, 60));
    CGPDFContextEndPage(context);
    CGPDFContextClose(context);
    CGContextRelease(context);
    return path;
}

static NSDictionary* ReceivedEntry(NSDictionary* data, NSString* name) {
    for (NSDictionary* file in data[@"files"])
        if ([file[@"file_name"] isEqual:name]) return file;
    return nil;
}

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "usage: SPDFMacFriendsReceivedTests <e2e helper> <animal manifest>\n");
            return 2;
        }
        NSString* executable = @(argv[1]);
        Expect([NSFileManager.defaultManager isExecutableFileAtPath:executable], @"no helper at %@", executable);
        // Short (helper sockets live under it) and private, under the per-user temp folder.
        char pattern[1024];
        strlcpy(pattern, [NSTemporaryDirectory() stringByAppendingPathComponent:@"szfrx.XXXXXX"].fileSystemRepresentation,
                sizeof pattern);
        Expect(mkdtemp(pattern), @"no temporary folder");
        gRoot = @(pattern);
        atexit(RemoveRoot);
        setenv("SZFRIENDS_KEY_STORE", "file", 1);
        SPDFMacFriendsTestUseReaderStateDirectory([gRoot stringByAppendingPathComponent:@"reader"]);

        SZFE2EWorld* world = [[SZFE2EWorld alloc] initWithExecutable:executable manifest:@(argv[2]) root:gRoot];
        [world beginScenario:@"r"];
        SZFE2EHelper *helperA = nil, *helperB = nil;
        NSString *listA = nil, *listB = nil, *aAtB = nil, *bAtA = nil;
        SZFE2EClient* a = StartPerson(world, @"a", @"Ana", &helperA, &listA);
        SZFE2EClient* b = StartPerson(world, @"b", @"Ben", &helperB, &listB);
        Befriend(a, listA, b, listB, &aAtB, &bAtA);
        NSDictionary* reply = [b intent:@"set_auto_accept" fields:@{@"conversation_id" : aAtB, @"enabled" : @YES}];
        Expect([reply[@"ok"] boolValue], @"set_auto_accept: %@", reply);

        // Ben's ShenzhenPDF: the reader's host and the views' link to Ben's helper. A bundle with no embedded helper,
        // so the link connects to the one this run started and never spawns another.
        setenv("SZFRIENDS_STATE_DIR", helperB.stateDirectory.fileSystemRepresentation, 1);
        ReceivedBridge* bridge = [ReceivedBridge new];
        NSBundle* bundle = [NSBundle bundleWithPath:gRoot] ?: NSBundle.mainBundle;
        SPDFMacFriendsHost* host = [[SPDFMacFriendsHost alloc] initWithBridge:bridge bundle:bundle
            formats:[NSSet setWithArray:SPDFReadableDocumentExtensions()]];
        SZFriendsHelperLink* link = [[SZFriendsHelperLink alloc] initWithHost:host];

        SPDFMacCollectionStore* on = Store(@"collection-on", @"enabled");
        SPDFMacCollectionStore* off = Store(@"collection-off", @"disabled");
        SPDFMacCollectionStore* unset = Store(@"collection-unset", nil);
        NSArray<Follower*>* followers = @[ Follow(on), Follow(off), Follow(unset) ];
        __weak SZFriendsHelperLink* weakLink = link;
        link.onStateChange = ^(SZFriendsLinkState state) {
            (void)state;
            for (Follower* follower in followers) [follower.received followLink:weakLink];
        };
        [link start];
        Expect(Wait(10, ^BOOL { return link.state == SZFriendsLinkStateReady; }),
               @"the reader's link never reached Ben's helper (state %ld):\n%@", (long)link.state, helperB.log);
        Expect([link.helperCapabilities containsObject:SPDFMacFriendsReceivedFolderCapability],
               @"Ben's helper does not announce received.folder: %@", link.helperCapabilities);
        for (Follower* follower in followers) [follower.received followLink:link];
        // The first snapshot is the first run: it records when ShenzhenPDF began taking received files.
        Expect(Wait(10, ^BOOL {
                   for (Follower* follower in followers)
                       if (!follower.snapshots) return NO;
                   return YES;
               }), @"the received view never answered");

        NSString* outbox = [world.scenarioDirectory stringByAppendingPathComponent:@"outbox"];
        [NSFileManager.defaultManager createDirectoryAtPath:outbox withIntermediateDirectories:YES attributes:nil error:nil];
        NSString* pdf = WritePDF([outbox stringByAppendingPathComponent:@"Supplier contract.pdf"]);
        NSString* other = SPDFMacFriendsTestWriteFile(outbox, @"firmware.bin", [NSMutableData dataWithLength:4096]);
        Expect(!SPDFReadableDocumentPath(other), @"firmware.bin must be a file ShenzhenPDF does not open");
        for (NSString* path in @[ pdf, other ]) {
            reply = [a intent:@"send_files" fields:@{@"conversation_id" : bAtA, @"files" : @[ @{@"path" : path} ],
                                                    @"client_token" : NSUUID.UUID.UUIDString}];
            Expect([reply[@"ok"] boolValue], @"send_files %@: %@", path.lastPathComponent, reply);
        }
        // What Ben's helper lists, as an observer on its own connection sees it.
        NSString* receivedView = [b subscribe:@"received" params:nil];
        Expect(receivedView, @"no received subscription");
        Expect(Wait(30, ^BOOL {
                   NSDictionary* data = [b dataFor:receivedView];
                   return ReceivedEntry(data, @"Supplier contract.pdf") && ReceivedEntry(data, @"firmware.bin");
               }), @"Ben never received both files: %@\n%@", [b dataFor:receivedView], helperB.log);
        NSDictionary* snapshot = [b dataFor:receivedView];
        NSString* published = ReceivedEntry(snapshot, @"Supplier contract.pdf")[@"path"];
        NSString* downloads = [helperB.stateDirectory stringByAppendingString:@"-downloads"];
        Expect([published.stringByResolvingSymlinksInPath hasPrefix:downloads.stringByResolvingSymlinksInPath],
               @"the PDF was not saved to Ben's downloads folder: %@", published);

        Follower* follower = followers[0];
        Expect(Wait(15, ^BOOL { return follower.captured[published] != nil; }),
               @"Collection never captured the received PDF; capturing %@", follower.capturing);
        NSArray<NSDictionary*>* documents = on.documents;
        Expect(documents.count == 1 && [documents[0][@"path"] isEqual:published],
               @"Collection should list exactly the received PDF: %@", documents);
        NSDictionary* version = [documents[0][@"versions"] lastObject];
        Expect([version[@"reason"] isEqual:@"Received"], @"captured with reason %@", version[@"reason"]);
        // Collection opens it like any captured document: the original while it is there, else the saved copy.
        NSURL* copy = [on materializeVersionID:version[@"id"] documentID:documents[0][@"id"] error:nil];
        Expect(copy && [[NSData dataWithContentsOfURL:copy] isEqual:[NSData dataWithContentsOfFile:pdf]],
               @"Collection's copy of the received PDF does not open: %@", copy);
        Expect(!bridge.opened.count, @"a received file was opened: %@", bridge.opened);
        Expect(![follower.capturing containsObject:ReceivedEntry(snapshot, @"firmware.bin")[@"path"]],
               @"a file ShenzhenPDF does not open was captured");

        // Collection off: nothing captured. Not yet chosen: nothing captured, and no Collection created for it.
        Expect(!off.documents.count && !followers[1].capturing.count, @"Collection off captured %@", off.documents);
        Expect(!followers[2].capturing.count && ![NSFileManager.defaultManager fileExistsAtPath:unset.rootURL.path],
               @"Collection not chosen captured or created something");

        // The same snapshot again, and heard by another window (a second follower on the same Collection): no second
        // capture, no second version.
        Expect(!Deliver(follower, snapshot).count, @"the same snapshot captured again");
        Follower* otherWindow = Follow(on);
        Expect(!Deliver(otherWindow, snapshot).count, @"another window captured the same file again");
        Expect(on.documents.count == 1 && [on.documents[0][@"versions"] count] == 1,
               @"a second delivery changed Collection: %@", on.documents);
        Expect(!Deliver(followers[1], snapshot).count && !off.documents.count, @"Collection off captured on redelivery");

        // Turning Collection on later does not import what was received while it was off.
        Expect([off updateSettings:@{@"choice" : @"enabled"} error:nil], @"Collection not turned on");
        Expect(!Deliver(Follow(off), snapshot).count, @"files received while Collection was off were imported");

        // A first run never imports history: the same files, received an hour before it began, stay out.
        NSMutableDictionary* old = [ReceivedEntry(snapshot, @"Supplier contract.pdf") mutableCopy];
        old[@"received_at"] = @([old[@"received_at"] longLongValue] - 3600);
        old[@"transfer_id"] = @"t_history";
        SPDFMacCollectionStore* fresh = Store(@"collection-fresh", @"enabled");
        Expect(!Deliver(Follow(fresh), @{@"files" : @[ old ]}).count && !fresh.documents.count,
               @"a file received before the first run was imported");

        for (Follower* each in followers) [each.received stop];
        [link stopDisablingFriends:NO];
        [world endScenario];
        printf("SPDFMacFriendsReceivedTests passed\n");
    }
    return 0;
}
