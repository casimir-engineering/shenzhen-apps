// friends-helper-check: getting a file again in the helper (SZFriendsNearbyService+Again.m, ADR 0016). On a profile of
// two computers, a file the person deleted on A shows as moved or deleted and is fetched from B with Get while B holds
// it; once nobody holds it, Get again asks the friend who sent it (its errors, Cancel). As the friend's computer, A
// gives a file it sent only to the person it went to, from the file it was sent from while unchanged, never one
// another person was sent or one that changed, says "not now" when another of its computers has it, and checks at most
// 20 files an hour for one person.

#import <sodium.h>

#import "SZFriendsHelperNearbyTests.h"

#import "service/helper/SZFriendsHelperFacts.h"
#import "service/helper/nearby/SZFriendsNearbyDevices.h"
#import "service/identity/SZFriendsDeviceChain.h"
#import "service/store/SZFriendsStoreDevices.h"
#import "service/store/SZFriendsStoreSync.h"
#import "service/sync/SZFriendsAgain.h"
#import "service/sync/SZFriendsSync.h"

@interface SZFriendsNearbyService (AgainTesting)
- (nullable NSString *)againPathToServe:(NSString *)transferID
                           conversation:(NSString *)conversationID
                                   size:(uint64_t *)size
                                 answer:(SZFriendsAgainAnswer *)answer;
@end

static void SZFNShare(SZFriendsNearbyService *a, SZFriendsNearbyService *b) {
    SZFriendsIdentity *first = a.services.identity, *second = b.services.identity;
    SZFriendsDeviceChain *chain = [a.services.store ownDeviceChainCreatingGenesisWithIdentity:first error:NULL];
    chain = [chain chainByAddingDeviceKey:second.publicKey staticKey:second.staticPublicKey
                                  consent:SZFriendsDeviceConsent(second, chain.rootKey) name:@"Studio Mac"
                                   system:@"macOS 26.1" signedBy:first date:[NSDate date] error:NULL];
    EXPECT(chain != nil && [a.services.store mergeOwnDeviceChain:chain error:NULL] == SZFriendsChainMergeChanged &&
               [b.services.store adoptOwnDeviceChain:chain localDeviceKey:second.publicKey error:NULL],
           "one profile on two computers");
    [a noticeOwnDevicesChange];
    [b noticeOwnDevicesChange];
}

// A file the friend sent, received on A at `path`, with its history item and the profile's record.
static SZFriendsTransferRecord *SZFNReceived(SZFriendsNearbyService *a, NSString *conversationID, NSString *path,
                                             NSArray<NSData *> *holders) {
    NSData *content = [@"factory audit photos" dataUsingEncoding:NSUTF8StringEncoding];
    [content writeToFile:path atomically:YES];
    uint8_t digest[32];
    crypto_generichash(digest, sizeof digest, content.bytes, content.length, NULL, 0);
    SZFriendsTransferRecord *transfer = [[SZFriendsTransferRecord alloc] init];
    transfer.transferID = @"5a90c3e15a90c3e15a90c3e15a90c3e1";
    transfer.conversationID = conversationID;
    transfer.state = SZFriendsTransferStateReceived;
    transfer.fileName = @"Site photos.pdf";
    transfer.size = content.length;
    transfer.contentDigest = [NSData dataWithBytes:digest length:32];
    transfer.createdAt = [NSDate date];
    SZFriendsStore *store = a.services.store;
    EXPECT([store insertCopiedTransfer:transfer path:path source:SZFriendsReceivedSourceFriend error:NULL],
           "received on A");
    SZFriendsItemRecord *item = [[SZFriendsItemRecord alloc] init];
    item.itemID = transfer.transferID;
    item.conversationID = conversationID;
    item.kind = SZFriendsItemKindTransfer;
    item.transferID = transfer.transferID;
    item.direction = SZFriendsDirectionIncoming;
    item.sentAt = [NSDate date];
    item.receivedAt = item.sentAt;
    EXPECT([store insertItem:item error:NULL], "in the history");
    SZFriendsSyncFileRecord *file = [[SZFriendsSyncFileRecord alloc] init];
    file.transferID = transfer.transferID;
    file.conversationID = conversationID;
    file.itemID = item.itemID;
    file.state = SZFriendsTransferStateReceived;
    file.fileName = transfer.fileName;
    file.size = transfer.size;
    file.contentDigest = transfer.contentDigest;
    file.createdAt = transfer.createdAt;
    file.holders = holders;
    EXPECT([store saveSyncFile:file error:NULL], "the profile's record");
    return transfer;
}

static SZFriendsItemFacts *SZFNFacts(SZFriendsNearbyService *a, SZFriendsTransferRecord *transfer) {
    SZFriendsItemRecord *item = [a.services.store itemWithID:transfer.transferID inConversation:transfer.conversationID];
    return SZFriendsItemFactsFromRecord(item, a.services);
}

static void TestPersonSide(NSString *scratch, SZFriendsNearbyService *a, SZFriendsNearbyService *b) {
    SZFriendsStore *store = a.services.store;
    SZFriendsPersonRecord *mei = SZFNSavePerson(store, SZFriendsRelationFriend);
    NSString *path = [scratch stringByAppendingPathComponent:@"Site photos.pdf"];
    SZFriendsTransferRecord *photos = SZFNReceived(a, mei.conversationID, path, @[ b.services.identity.publicKey ]);
    NSString *reason = nil;
    EXPECT([[a fetchFileFromFriend:photos.transferID reason:&reason] isEqual:@"not_allowed"], "it is here");
    EXPECT(SZFNFacts(a, photos).localPath != nil && !SZFNFacts(a, photos).fileMissing, "saved, as received");

    // The person deletes it on A; B still has it: Get, as for a file that was never here.
    [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
    SZFriendsItemFacts *facts = SZFNFacts(a, photos);
    EXPECT(facts.fileMissing && facts.localPath == nil, "moved or deleted");
    SZFriendsDeviceFileFacts *onB = [a devicesFactsAtDate:[NSDate date]].files[photos.transferID];
    EXPECT(onB != nil && !onB.fetching && [onB.deviceName isEqual:@"Studio Mac"], "on Studio Mac, not copying by itself");
    EXPECT([[a fetchFileFromFriend:photos.transferID reason:&reason] isEqual:@"not_allowed"], "Get applies, not again");
    EXPECT([a fetchFileFromDevice:photos.transferID] == nil && [a cancelFetchOfFile:photos.transferID], "Get, Cancel");

    // B deleted it too: nobody holds it, so Get again asks Mei.
    SZFriendsSyncFileRecord *record = [store syncFileWithID:photos.transferID];
    record.holders = @[];
    [store saveSyncFile:record error:NULL];
    EXPECT([a devicesFactsAtDate:[NSDate date]].files[photos.transferID] == nil, "on no computer");
    EXPECT([[a fetchFileFromDevice:photos.transferID] isEqual:@"not_found"], "Get has nowhere to copy from");
    EXPECT([[a fetchFileFromFriend:@"00000000000000000000000000000000" reason:&reason] isEqual:@"not_found"] &&
               [reason isEqual:@"again"], "an unknown file");
    a.services.transfers.freeBytesProvider = ^uint64_t(NSString *p) { (void)p; return 3; };
    EXPECT([[a fetchFileFromFriend:photos.transferID reason:&reason] isEqual:@"disk_full"], "no room for it");
    a.services.transfers.freeBytesProvider = ^uint64_t(NSString *p) { (void)p; return UINT64_MAX; };
    EXPECT([a fetchFileFromFriend:photos.transferID reason:&reason] == nil, "Get again");
    facts = SZFNFacts(a, photos);
    EXPECT(facts.again == SZFriendsAgainAsked && !facts.againConnected &&
               [a hasAgainRequestsForConversation:mei.conversationID],
           "asked, waiting for Mei");
    EXPECT([a cancelAgainOfFile:photos.transferID] && ![a cancelAgainOfFile:photos.transferID], "Cancel, once");
    EXPECT(SZFNFacts(a, photos).again == SZFriendsAgainNone, "moved or deleted again");

    mei.relation = SZFriendsRelationRemoved;
    [store savePerson:mei error:NULL];
    EXPECT([[a fetchFileFromFriend:photos.transferID reason:&reason] isEqual:@"not_allowed"], "only from a friend");
}

static void TestFriendSide(NSString *scratch, SZFriendsNearbyService *a, SZFriendsNearbyService *b) {
    SZFriendsStore *store = a.services.store;
    SZFriendsTransfers *transfers = a.services.transfers;
    SZFriendsPersonRecord *raph = SZFNSavePerson(store, SZFriendsRelationFriend);
    SZFriendsPersonRecord *other = SZFNSavePerson(store, SZFriendsRelationFriend);
    NSString *source = [scratch stringByAppendingPathComponent:@"Floor plan.pdf"];
    [[@"floor plan, first version" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:source atomically:YES];
    SZFriendsTransferRecord *sent = [transfers stageOutgoingFileAtPath:source revision:nil
                                                        conversationID:raph.conversationID error:NULL];
    NSString *conversation = raph.conversationID, *transferID = sent.transferID;
    uint64_t size = 0;
    SZFriendsAgainAnswer answer = SZFriendsAgainAnswerNotNow;
    EXPECT([a againPathToServe:transferID conversation:conversation size:&size answer:&answer] == nil &&
               answer == SZFriendsAgainAnswerNotHere, "not before Raph has it");
    EXPECT([transfers markOfferDelivered:transferID fromConversation:conversation error:NULL] &&
               [transfers peerAnsweredTransfer:transferID accepted:YES offset:0 fromConversation:conversation
                                         error:NULL] &&
               [transfers peerVerifiedTransfer:transferID fromConversation:conversation error:NULL],
           "delivered: the snapshot goes");
    NSString *path = [a againPathToServe:transferID conversation:conversation size:&size answer:&answer];
    EXPECT([path isEqualToString:sent.sourcePath] && size == sent.size, "from the file it was sent from: %@", path);
    EXPECT([a againPathToServe:transferID conversation:other.conversationID size:&size answer:&answer] == nil &&
               answer == SZFriendsAgainAnswerNotHere, "never to someone else");

    // Twenty checks an hour for one person, then "not now".
    BOOL limited = NO;
    for (int i = 0; i < 21 && !limited; i++) {
        [a.againVerified removeAllObjects];
        limited = [a againPathToServe:transferID conversation:conversation size:&size answer:&answer] == nil;
    }
    EXPECT(limited && answer == SZFriendsAgainAnswerNotNow, "checks are limited");
    [a.againChecks removeAllObjects];

    // Edited since: not the file it sent. Deleted while B holds it: not now.
    [[@"floor plan, second version" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:source atomically:YES];
    EXPECT([a againPathToServe:transferID conversation:conversation size:&size answer:&answer] == nil &&
               answer == SZFriendsAgainAnswerNotHere, "a changed file is not given");
    [NSFileManager.defaultManager removeItemAtPath:source error:NULL];
    SZFriendsSyncFileRecord *file = [[SZFriendsSyncFileRecord alloc] init];
    file.transferID = transferID;
    file.conversationID = conversation;
    file.outgoing = YES;
    file.state = SZFriendsTransferStateDelivered;
    file.fileName = sent.fileName;
    file.size = sent.size;
    file.contentDigest = sent.contentDigest;
    file.createdAt = [NSDate date];
    file.holders = @[ b.services.identity.publicKey ];
    [store saveSyncFile:file error:NULL];
    EXPECT([a againPathToServe:transferID conversation:conversation size:&size answer:&answer] == nil &&
               answer == SZFriendsAgainAnswerNotNow, "another of its computers has it: not now");
}

void SZFNTestAgain(NSString *scratch) {
    SZFriendsHelperServices *one = SZFNOpenServices(scratch, @"again-a"), *two = SZFNOpenServices(scratch, @"again-b");
    if (one == nil || two == nil) return;
    SZFriendsNearbyService *a = SZFNNearbyWith(one, @[]), *b = SZFNNearbyWith(two, @[]);
    SZFNShare(a, b);
    TestPersonSide(scratch, a, b);
    TestFriendSide(scratch, a, b);
}
