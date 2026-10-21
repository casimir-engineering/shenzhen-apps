// friends-notify-check: the notifier's decisions and words (SZFriendsNotify.h, ADR 0017) on a real store in a scratch
// state directory, posting to the test home's JSON-lines sink. Nothing here touches the notification centre.

#import <Foundation/Foundation.h>

#import "avatars/SZFriendsAvatars.h"
#import "service/notify/SZFriendsNotify.h"
#import "service/store/SZFriendsStoreSync.h"

static int Failures;
static NSMutableArray<NSString *> *Scratch;

#define EXPECT(condition, ...)                                                                                     \
    do {                                                                                                           \
        if (!(condition)) {                                                                                        \
            Failures++;                                                                                            \
            fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, [NSString stringWithFormat:__VA_ARGS__].UTF8String); \
        }                                                                                                          \
    } while (0)

static NSString *ScratchDirectory(NSString *name) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                                 [NSString stringWithFormat:@"sznotify-%d-%@", getpid(), name]];
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    if (Scratch == nil) Scratch = [NSMutableArray array];
    [Scratch addObject:path];
    [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions : @0700} error:NULL];
    return path;
}

static NSData *Bytes(uint8_t value) {
    NSMutableData *data = [NSMutableData dataWithLength:32];
    memset(data.mutableBytes, value, 32);
    return data;
}

// The world of one test: a store with Mei (a friend), the sink and a notifier on the main queue.
@interface World : NSObject
@property(nonatomic) NSString *directory;
@property(nonatomic) SZFriendsStore *store;
@property(nonatomic) SZFriendsTransfers *transfers;
@property(nonatomic) SZFriendsNotifyFileSink *sink;
@property(nonatomic) SZFriendsNotifier *notifier;
@property(nonatomic) NSMutableSet<NSString *> *focused;
@property(nonatomic) NSMutableArray<NSString *> *replies;
@end

@implementation World
@end

static SZFriendsPersonRecord *AddPerson(SZFriendsStore *store, NSString *conversationID, NSString *name, uint8_t key,
                                        SZFriendsRelation relation) {
    SZFriendsPersonRecord *person = [[SZFriendsPersonRecord alloc] init];
    person.conversationID = conversationID;
    person.identityKey = Bytes(key);
    person.staticKey = Bytes(key + 100);
    person.name = name;
    person.picture = [SZFriendsPicture placeholder];
    person.relation = relation;
    person.lastInteractionAt = [NSDate date];
    NSError *error = nil;
    EXPECT([store savePerson:person error:&error], @"save %@: %@", name, error);
    return person;
}

static World *MakeWorld(NSString *name, NSDictionary *environment) {
    World *world = [World new];
    world.directory = ScratchDirectory(name);
    world.store = [SZFriendsStore storeInDirectory:world.directory error:NULL];
    world.transfers = [[SZFriendsTransfers alloc] initWithStore:world.store stateDirectory:world.directory];
    world.sink = [[SZFriendsNotifyFileSink alloc] initWithStateDirectory:world.directory
                                                             environment:environment ?: @{}];
    SZFriendsNotifySettings *settings = [[SZFriendsNotifySettings alloc] initWithStateDirectory:world.directory];
    world.notifier = [[SZFriendsNotifier alloc] initWithStore:world.store transfers:world.transfers settings:settings
                                                       poster:world.sink queue:dispatch_get_main_queue()];
    world.notifier.burstInterval = 0.05;
    world.focused = [NSMutableSet set];
    world.replies = [NSMutableArray array];
    World *weakWorld = world;
    world.notifier.focusedConversations = ^NSSet<NSString *> * { return weakWorld.focused; };
    world.notifier.sendReply = ^(NSString *conversationID, NSString *text) {
        [weakWorld.replies addObject:[NSString stringWithFormat:@"%@:%@", conversationID, text]];
    };
    AddPerson(world.store, @"c_mei", @"Mei", 1, SZFriendsRelationFriend);
    return world;
}

static void Settle(void) {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.2, false);
}

static NSArray<NSDictionary *> *Lines(World *world) {
    NSString *text = [NSString stringWithContentsOfFile:world.sink.path encoding:NSUTF8StringEncoding error:NULL];
    NSMutableArray *lines = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (line.length == 0) continue;
        id object = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0
                                                      error:NULL];
        if (object) [lines addObject:object];
    }
    return lines;
}

static NSArray<NSDictionary *> *Requests(World *world) {
    return [Lines(world) filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"key != nil"]];
}

static SZFriendsItemRecord *Receive(World *world, NSString *itemID, NSString *text, NSDate *sentAt) {
    SZFriendsItemRecord *item = [[SZFriendsItemRecord alloc] init];
    item.itemID = itemID;
    item.conversationID = @"c_mei";
    item.kind = SZFriendsItemKindMessage;
    item.direction = SZFriendsDirectionIncoming;
    item.sentAt = sentAt ?: [NSDate date];
    item.receivedAt = [NSDate date];
    item.text = text;
    EXPECT([world.store insertItem:item error:NULL], @"insert %@", itemID);
    return item;
}

static void TestMessage(void) {
    World *world = MakeWorld(@"message", nil);
    [world.notifier noteMessage:Receive(world, @"m1", @"Can you check the bracket?", nil)];
    Settle();
    NSArray *requests = Requests(world);
    EXPECT(requests.count == 1, @"one request: %@", requests);
    NSDictionary *request = requests.firstObject;
    EXPECT([request[@"key"] isEqual:@"message:m1"] && [request[@"kind"] isEqual:@"message"] &&
               [request[@"channel"] isEqual:@"messages"] && [request[@"conversation_id"] isEqual:@"c_mei"] &&
               [request[@"thread"] isEqual:@"c_mei"] && [request[@"title"] isEqual:@"Mei"] &&
               [request[@"body"] isEqual:@"Can you check the bracket?"],
           @"the message: %@", request);
    EXPECT([request[@"reply"] isEqual:(@{@"label" : @"Reply", @"placeholder" : @"Message Mei", @"send" : @"Send"})],
           @"reply: %@", request[@"reply"]);
    EXPECT([request[@"open"] isEqual:(@{@"url" : @"shenzhenpdf://friends/conversation/c_mei",
                                        @"app_id" : @"com.intuition.shenzhenpdf",
                                        @"app_path" : [NSNull null]})],
           @"open: %@", request[@"open"]);

    // A burst: one notification, for the newest.
    [world.notifier noteMessage:Receive(world, @"m2", @"one", nil)];
    [world.notifier noteMessage:Receive(world, @"m3", @"two", nil)];
    Settle();
    requests = Requests(world);
    EXPECT(requests.count == 2 && [requests.lastObject[@"key"] isEqual:@"message:m3"] &&
               [requests.lastObject[@"body"] isEqual:@"two"],
           @"a burst is one: %@", requests);

    // Read: withdrawn.
    [world.store markConversationRead:@"c_mei" error:NULL];
    [world.notifier withdrawReadConversations];
    EXPECT([Lines(world).lastObject isEqual:@{@"withdraw" : @{@"thread" : @"c_mei"}}], @"withdrawn: %@",
           Lines(world).lastObject);
    NSUInteger before = Lines(world).count;
    [world.notifier withdrawReadConversations];
    EXPECT(Lines(world).count == before, @"withdrawn once");

    // Show message text off.
    world.notifier.settings.preview = NO;
    [world.notifier noteMessage:Receive(world, @"m4", @"secret", nil)];
    [world.notifier noteMessage:Receive(world, @"m5", @"secret", nil)];
    [world.notifier noteMessage:Receive(world, @"m6", @"secret", nil)];
    Settle();
    EXPECT([Requests(world).lastObject[@"body"] isEqual:@"3 new messages"], @"hidden: %@", Requests(world).lastObject);
    SZFriendsNotifySettings *reloaded = [[SZFriendsNotifySettings alloc] initWithStateDirectory:world.directory];
    EXPECT(!reloaded.preview && reloaded.enabled, @"the switch is kept on this Mac");
}

static void TestNever(void) {
    World *world = MakeWorld(@"never", nil);
    [world.focused addObject:@"c_mei"];
    [world.notifier noteMessage:Receive(world, @"f1", @"seen", nil)];
    Settle();
    EXPECT(Requests(world).count == 0, @"focused: %@", Requests(world));
    [world.focused removeAllObjects];
    // Focused only after it arrived but before the burst ended: still nothing.
    [world.notifier noteMessage:Receive(world, @"f2", @"seen", nil)];
    [world.focused addObject:@"c_mei"];
    Settle();
    EXPECT(Requests(world).count == 0, @"focused within the burst: %@", Requests(world));
    [world.focused removeAllObjects];

    SZFriendsItemRecord *mine = Receive(world, @"o1", @"mine", nil);
    mine.direction = SZFriendsDirectionOutgoing;
    [world.notifier noteMessage:mine];
    AddPerson(world.store, @"c_kim", @"Kim", 7, SZFriendsRelationBlocked);
    SZFriendsItemRecord *blocked = Receive(world, @"b1", @"hi", nil);
    blocked.conversationID = @"c_kim";
    [world.notifier noteMessage:blocked];
    world.notifier.settings.enabled = NO;
    [world.notifier noteMessage:Receive(world, @"x1", @"off", nil)];
    Settle();
    EXPECT(Requests(world).count == 0, @"outgoing, blocked, switched off: %@", Requests(world));
    world.notifier.settings.enabled = YES;

    // By sync: fresh and unread notifies; older than 10 minutes, or read on the other device, does not.
    [world.store markConversationRead:@"c_mei" error:NULL];
    SZFriendsItemRecord *old = Receive(world, @"s1", @"old", [NSDate dateWithTimeIntervalSinceNow:-11 * 60]);
    [world.notifier noteSyncedItems:@[ old ]];
    Settle();
    EXPECT(Requests(world).count == 0, @"stale: %@", Requests(world));
    SZFriendsItemRecord *fresh = Receive(world, @"s2", @"fresh", [NSDate dateWithTimeIntervalSinceNow:-60]);
    [world.notifier noteSyncedItems:@[ fresh ]];
    Settle();
    EXPECT(Requests(world).count == 1 && [Requests(world).lastObject[@"key"] isEqual:@"message:s2"], @"fresh: %@",
           Requests(world));
    SZFriendsItemRecord *readThere = Receive(world, @"s3", @"read", nil);
    [world.store markConversationRead:@"c_mei" error:NULL];
    [world.notifier noteSyncedItems:@[ readThere ]];
    Settle();
    EXPECT(Requests(world).count == 1, @"read on the other device: %@", Requests(world));

    // Permission refused or not asked yet: nothing.
    for (NSString *permission in @[ @"denied", @"not_asked" ]) {
        World *other = MakeWorld(permission, @{@"SZFRIENDS_NOTIFY_PERMISSION" : permission});
        [other.notifier noteMessage:Receive(other, @"p1", @"hi", nil)];
        Settle();
        EXPECT(Requests(other).count == 0, @"%@: %@", permission, Requests(other));
    }
}

static void TestFilesAndRequests(void) {
    World *world = MakeWorld(@"files", nil);
    SZFriendsTransferRecord *offer = [world.transfers recordIncomingOfferWithID:@"0123456789abcdef0123456789abcdef"
                                                                 conversationID:@"c_mei"
                                                                       fileName:@"Bracket.step"
                                                                    uniformType:nil
                                                                           size:10
                                                                  contentDigest:Bytes(9)
                                                                         sentAt:[NSDate date]
                                                                          error:NULL];
    EXPECT(offer != nil, @"an offer");
    [world.notifier noteOffer:offer automatic:NO];
    Settle();
    NSDictionary *request = Requests(world).lastObject;
    EXPECT([request[@"key"] isEqual:@"file:0123456789abcdef0123456789abcdef"] && [request[@"kind"] isEqual:@"file"] &&
               [request[@"channel"] isEqual:@"files"] &&
               [request[@"body"] isEqual:@"Mei wants to send you Bracket.step"] &&
               request[@"reply"] == [NSNull null],
           @"offer: %@", request);

    SZFriendsPersonRecord *lena = AddPerson(world.store, @"c_lena", @"Lena", 3, SZFriendsRelationIncomingRequest);
    [world.notifier noteRequestFrom:lena];
    request = Requests(world).lastObject;
    EXPECT([request[@"kind"] isEqual:@"request"] && [request[@"channel"] isEqual:@"requests"] &&
               [request[@"title"] isEqual:@"Lena"] && [request[@"body"] isEqual:@"Wants to be friends"] &&
               [request[@"key"] hasPrefix:@"request:c_lena:"],
           @"request: %@", request);
    SZFriendsPersonRecord *jo = AddPerson(world.store, @"c_jo", @"Jo", 4, SZFriendsRelationFriend);
    [world.notifier noteLinkAddedWith:jo];
    [world.notifier noteAcceptedBy:jo];
    NSArray *requests = Requests(world);
    EXPECT(requests.count == 3 && [requests.lastObject[@"key"] isEqual:@"link:c_jo"] &&
               [requests.lastObject[@"body"] isEqual:@"You’re now friends"],
           @"a link's acceptance is one notification: %@", requests);
    SZFriendsPersonRecord *ana = AddPerson(world.store, @"c_ana", @"Ana", 5, SZFriendsRelationFriend);
    [world.notifier noteAcceptedBy:ana];
    EXPECT([Requests(world).lastObject[@"body"] isEqual:@"Accepted your friend request"], @"accepted");
    [world.notifier noteJoinRequest:@"j1" deviceName:@"Pixel 8"];
    [world.notifier noteJoinRequest:@"j1" deviceName:@"Pixel 8"];
    request = Requests(world).lastObject;
    EXPECT(Requests(world).count == 5 && [request[@"title"] isEqual:@"Pixel 8 wants to join your profile"] &&
               request[@"conversation_id"] == [NSNull null] &&
               [request[@"open"][@"url"] isEqual:@"shenzhenpdf://friends"],
           @"join, once: %@", Requests(world));
}

static void TestResponses(void) {
    World *world = MakeWorld(@"responses", nil);
    [world.notifier rememberAppID:@"com.example.tool" urlScheme:nil appPath:nil];
    EXPECT([world.notifier.settings.target.appID isEqual:@"com.intuition.shenzhenpdf"],
           @"an app no click can open is not remembered");
    [world.notifier rememberAppID:@"com.shenzhen3d.viewer" urlScheme:nil appPath:@"/Applications/Shenzhen 3D.app"];
    [world.notifier noteMessage:Receive(world, @"r1", @"hello", nil)];
    Settle();
    EXPECT([Requests(world).lastObject[@"open"][@"url"] isEqual:@"shenzhen3d://friends/conversation/c_mei"],
           @"open names the last app: %@", Requests(world).lastObject);
    [world.notifier rememberAppID:@"com.intuition.shenzhenfiles" urlScheme:@"shenzhenfiles" appPath:nil];
    EXPECT([world.notifier respondToKey:@"message:r1" action:@"open" text:nil], @"open");
    EXPECT([Lines(world).lastObject isEqual:(@{@"opened" : @{@"url" : @"shenzhenfiles://friends/conversation/c_mei",
                                                             @"app_id" : @"com.intuition.shenzhenfiles",
                                                             @"app_path" : [NSNull null]}})],
           @"a click opens the app used last: %@", Lines(world).lastObject);
    EXPECT([world.notifier respondToKey:@"message:r1" action:@"reply" text:@"On it"], @"reply");
    EXPECT([world.replies isEqual:@[ @"c_mei:On it" ]], @"the reply is sent: %@", world.replies);
    EXPECT(![world.notifier respondToKey:@"message:nope" action:@"open" text:nil], @"unknown key");
    SZFriendsNotifySettings *reloaded = [[SZFriendsNotifySettings alloc] initWithStateDirectory:world.directory];
    EXPECT([reloaded.target.urlScheme isEqual:@"shenzhenfiles"], @"the target survives a restart");

    World *asking = MakeWorld(@"ask", @{@"SZFRIENDS_NOTIFY_PERMISSION" : @"not_asked"});
    EXPECT(asking.notifier.facts.permission == SZFriendsNotifyPermissionFactsNotAsked, @"not asked");
    __block BOOL done = NO;
    [asking.notifier askWithCompletion:^{ done = YES; }];
    EXPECT(done && [Lines(asking).lastObject isEqual:@{@"asked" : @YES}] &&
               asking.notifier.facts.permission == SZFriendsNotifyPermissionFactsGranted,
           @"asked: %@", Lines(asking));
}

int main(void) {
    @autoreleasepool {
        TestMessage();
        TestNever();
        TestFilesAndRequests();
        TestResponses();
        EXPECT(SZFriendsNotifyBundlePath(@"/Applications/ShenzhenPDF.app/Contents/MacOS/ShenzhenPDF") != nil &&
                   [SZFriendsNotifyBundlePath(@"/Applications/ShenzhenPDF.app/Contents/MacOS/ShenzhenPDF")
                       isEqual:@"/Applications/ShenzhenPDF.app"] &&
                   SZFriendsNotifyBundlePath(@"/usr/local/bin/tool") == nil,
               @"bundle path");
        for (NSString *path in Scratch) [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
        if (Failures > 0) {
            fprintf(stderr, "SZFriendsNotifyTests: %d failure(s)\n", Failures);
            return 1;
        }
        printf("SZFriendsNotifyTests passed\n");
        return 0;
    }
}
