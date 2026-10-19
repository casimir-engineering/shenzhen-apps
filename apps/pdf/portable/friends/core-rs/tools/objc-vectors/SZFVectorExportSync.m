// Vector export: sync between own devices (ADR 0014), from the helper's own sync engine and store. A store is filled
// with a profile, a friend and history in a temporary directory, the engine captures it with a fixed clock, and every
// event it signs is exported with the HELLO it opens a session with; the Rust engine must capture the same store state
// into the same bytes. Codec cases and the device tag secrets come with them.

#import "SZFVectorExport.h"

#import "avatars/SZFriendsAvatars.h"
#import "service/identity/SZFriendsDeviceChain.h"
#import "service/identity/SZFriendsIdentity.h"
#import "service/store/SZFriendsStoreDevices.h"
#import "service/sync/SZFriendsSyncInternal.h"

static const NSTimeInterval SZFT0 = 1760000000.125;

static NSDate *SZFAt(NSTimeInterval offset) { return [NSDate dateWithTimeIntervalSince1970:SZFT0 + offset]; }

static NSDictionary *SZFCodecCases(void) {
    SZFriendsSyncVector *vector = @{
        SZFVectorIdentity(@"bob").publicKey : @7, SZFVectorIdentity(@"alice").publicKey : @3,
        SZFVectorIdentity(@"carol").publicKey : @0,
    };
    NSData *encoded = SZFriendsSyncEncodeVector(vector);
    // The same two entries, authors out of order.
    NSMutableData *descending = [[encoded subdataWithRange:NSMakeRange(0, 2)] mutableCopy];
    [descending appendData:[encoded subdataWithRange:NSMakeRange(42, 40)]];
    [descending appendData:[encoded subdataWithRange:NSMakeRange(2, 40)]];
    NSMutableArray *refused = [NSMutableArray array];
    for (NSData *data in @[ descending, [encoded subdataWithRange:NSMakeRange(0, encoded.length - 1)] ]) {
        BOOL decodes = SZFriendsSyncDecodeVector(data, NULL) != nil;
        [refused addObject:@{@"data" : SZFHexString(data), @"decodes" : @(decodes)}];
    }
    SZFriendsSyncFields *fields = [[SZFriendsSyncFields alloc] init];
    [fields setString:@"conversation" forTag:1];
    [fields setUInt64:42 forTag:2];
    [fields setDate:SZFAt(0.333) forTag:9];
    [fields setData:[NSData data] forTag:4];
    NSData *ownSecret = SZFDerive(@"own devices secret", 32), *presence = SZFDerive(@"presence secret", 32);
    NSData *bob = SZFVectorIdentity(@"bob").publicKey;
    return @{
        @"vector" : SZFHexString(encoded), @"refused_vectors" : refused, @"fields" : SZFHexString(fields.encodedData),
        @"device_tag_secret" : SZFHexString(SZFriendsSyncDeviceTagSecret(ownSecret, bob)),
        @"friend_device_tag_secret" : SZFHexString(SZFriendsSyncFriendDeviceTagSecret(presence, bob)),
    };
}

static SZFriendsDeviceChain *SZFTwoDeviceChain(void) {
    SZFriendsIdentity *alice = SZFVectorIdentity(@"alice"), *bob = SZFVectorIdentity(@"bob");
    SZFriendsDeviceChain *genesis = [SZFriendsDeviceChain genesisChainWithIdentity:alice name:@"Alice's Mac"
                                                                            system:@"macOS 26.1" date:SZFAt(0)
                                                                             error:NULL];
    return [genesis chainByAddingDeviceKey:bob.publicKey staticKey:bob.staticPublicKey
                                   consent:SZFriendsDeviceConsent(bob, alice.publicKey) name:@"Bob's PC"
                                    system:@"Windows 11" signedBy:alice date:SZFAt(10) error:NULL];
}

static NSDictionary *SZFCaptureScenario(void) {
    char template[] = "/tmp/szf-vectors-sync-XXXXXX";
    NSString *home = [NSString stringWithUTF8String:mkdtemp(template)];
    SZFriendsStore *store = [SZFriendsStore storeInDirectory:home error:NULL];
    SZFriendsIdentity *alice = SZFVectorIdentity(@"alice"), *carol = SZFVectorIdentity(@"carol");
    SZFriendsDeviceChain *chain = SZFTwoDeviceChain();
    [store adoptOwnDeviceChain:chain localDeviceKey:alice.publicKey error:NULL];
    [SZFriendsSyncEngine adoptOwnDevicesSecret:SZFDerive(@"own devices secret", 32) inStore:store];
    store.ownPresenceSecret = SZFDerive(@"presence secret", 32);
    store.profileName = @"Alice";
    store.profilePicture = [SZFriendsPicture animalWithSet:1 index:7];
    SZFriendsPersonRecord *person = [[SZFriendsPersonRecord alloc] init];
    person.conversationID = @"carolconv";
    person.identityKey = carol.publicKey;
    person.staticKey = carol.staticPublicKey;
    person.name = @"Carol";
    person.friendsID = @"maple-otter";
    person.picture = [SZFriendsPicture animalWithSet:2 index:3];
    person.relation = SZFriendsRelationFriend;
    person.verified = YES;
    person.verifiedAt = SZFAt(1);
    person.comparisonCode = @"1234 5678";
    person.presenceSecret = SZFDerive(@"carol presence", 32);
    person.lastInteractionAt = SZFAt(2);
    [store savePerson:person error:NULL];
    SZFriendsItemRecord *message = [[SZFriendsItemRecord alloc] init];
    message.itemID = @"m1";
    message.conversationID = @"carolconv";
    message.kind = SZFriendsItemKindMessage;
    message.direction = SZFriendsDirectionIncoming;
    message.sentAt = SZFAt(2.5);
    message.receivedAt = SZFAt(3);
    message.text = @"hi / there";
    [store insertItem:message error:NULL];
    SZFriendsItemRecord *event = [[SZFriendsItemRecord alloc] init];
    event.itemID = @"e1";
    event.conversationID = @"carolconv";
    event.kind = SZFriendsItemKindEvent;
    event.direction = SZFriendsDirectionIncoming;
    event.sentAt = SZFAt(4);
    event.receivedAt = SZFAt(4);
    event.eventKind = @"friend_added";
    event.eventArguments = @{@"name" : @"Carol/C", @"b" : @"x\nyé"};
    [store insertItem:event error:NULL];
    [store markConversationRead:@"carolconv" error:NULL];
    SZFriendsSyncEngine *engine = [[SZFriendsSyncEngine alloc] initWithStore:store identity:alice
                                                           receivedDirectory:[home stringByAppendingPathComponent:
                                                                                       @"received"]];
    engine.clock = ^NSDate * { return SZFAt(100); };
    NSUInteger captured = [engine captureLocalChanges];
    NSMutableArray *events = [NSMutableArray array];
    for (SZFriendsSyncLogEvent *log in [store syncEventsMissingFrom:@{} limit:1000]) {
        [events addObject:@{@"header" : SZFHexString(log.header), @"body" : log.body ? SZFHexString(log.body)
                                                                                     : [NSNull null]}];
    }
    __block NSData *hello = nil;
    SZFriendsSyncExchange *exchange = [[SZFriendsSyncExchange alloc] initWithEngine:engine
                                                                            peerKey:SZFVectorIdentity(@"bob").publicKey
                                                                               send:^(NSData *m) { hello = m; }];
    [exchange start];
    [store close];
    [NSFileManager.defaultManager removeItemAtPath:home error:NULL];
    return @{
        @"chain" : SZFHexString(chain.encodedData), @"own_devices_secret" : SZFHexString(SZFDerive(@"own devices "
                                                                                                    @"secret", 32)),
        @"presence_secret" : SZFHexString(SZFDerive(@"presence secret", 32)),
        @"carol_presence" : SZFHexString(SZFDerive(@"carol presence", 32)), @"t0" : @(SZFT0),
        @"captured" : @(captured), @"events" : events, @"hello" : SZFHexString(hello),
    };
}

NSDictionary *SZFExportSync(void) {
    return @{@"codec" : SZFCodecCases(), @"capture" : SZFCaptureScenario()};
}
