// Process test: file previews from someone the person blocks or removes, against a store seeded the way an earlier
// helper run would have left it.

#import <Foundation/Foundation.h>

#import <signal.h>
#import <sodium.h>

#import "SZFriendsHelperProcessHarness.h"
#import "service/store/SZFriendsStore.h"
#import "service/store/SZFriendsTransferThumbnails.h"

static NSData *SZFHPreviewRandom(NSUInteger count) {
    NSMutableData *data = [NSMutableData dataWithLength:count];
    randombytes_buf(data.mutableBytes, count);
    return data;
}

static BOOL SZFHPreviewFriend(SZFriendsStore *store, NSString *conversationID, NSString *friendsID) {
    SZFriendsPersonRecord *person = [[SZFriendsPersonRecord alloc] init];
    person.conversationID = conversationID;
    person.identityKey = SZFHPreviewRandom(32);
    person.staticKey = SZFHPreviewRandom(32);
    person.friendsID = friendsID;
    person.picture = [SZFriendsPicture placeholder];
    person.relation = SZFriendsRelationFriend;
    person.lastInteractionAt = [NSDate dateWithTimeIntervalSinceNow:-3600];
    return [store savePerson:person error:NULL];
}

// An offer from `conversationID` still waiting for an answer, with the sender's picture recorded as the helper records
// one it received: a PNG under a name of this Mac's in the thumbnails folder, and its row.
static NSString *_Nullable SZFHOfferWithPicture(SZFriendsTransfers *transfers, NSString *conversationID,
                                                NSString *_Nullable *_Nonnull picture) {
    NSString *transferID = SZFriendsNewIdentifier();
    if (![transfers recordIncomingOfferWithID:transferID conversationID:conversationID fileName:@"Site photos.pdf"
                                  uniformType:@"com.adobe.pdf" size:1000 contentDigest:SZFHPreviewRandom(32)
                                       sentAt:[NSDate date] error:NULL])
        return nil;
    [NSFileManager.defaultManager createDirectoryAtPath:transfers.thumbnailDirectory withIntermediateDirectories:YES
                                             attributes:@{NSFilePosixPermissions : @0700} error:NULL];
    NSString *name = [SZFriendsNewIdentifier() stringByAppendingPathExtension:@"png"];
    *picture = [transfers.thumbnailDirectory stringByAppendingPathComponent:name];
    [SZFHPreviewRandom(200) writeToFile:*picture atomically:NO];
    BOOL recorded = [transfers recordReceivedThumbnailForTransfer:transferID fromConversation:conversationID
                                                             path:*picture width:136 height:192 error:NULL];
    return recorded ? transferID : nil;
}

static BOOL SZFHPictureExists(NSString *path) {
    return [NSFileManager.defaultManager fileExistsAtPath:path];
}

// Security review, wave 6a (thumbnails store): previews were deleted only when an offer's state changed, and blocking
// or removing someone changes none, so their unanswered offers kept the sender's picture, row and PNG, until the
// offers expired. Both now decline those offers, without telling them, and the pictures go with the decline. Another
// friend's offer keeps its picture.
BOOL SZFHTestBlockAndRemoveDropPreviews(SZFHHarness *harness) {
    if (sodium_init() < 0) return NO;
    NSString *state = [harness makeDirectory];
    SZFriendsStore *store = [SZFriendsStore storeInDirectory:state error:NULL];
    CHECK(store != nil, "a store to seed");
    SZFriendsTransfers *transfers = [[SZFriendsTransfers alloc] initWithStore:store stateDirectory:state];
    CHECK(SZFHPreviewFriend(store, @"c_blocked", @"tulip-canyon") &&
              SZFHPreviewFriend(store, @"c_removed", @"amber-otter") &&
              SZFHPreviewFriend(store, @"c_kept", @"cedar-lantern"),
          "three friends");
    NSString *blockedPicture = nil, *removedPicture = nil, *keptPicture = nil;
    NSString *blocked = SZFHOfferWithPicture(transfers, @"c_blocked", &blockedPicture);
    NSString *removed = SZFHOfferWithPicture(transfers, @"c_removed", &removedPicture);
    NSString *kept = SZFHOfferWithPicture(transfers, @"c_kept", &keptPicture);
    CHECK(blocked && removed && kept && SZFHPictureExists(blockedPicture), "an offer with a picture from each");
    [store close];

    pid_t pid = [harness spawnHelperWithStateDirectory:state timeScale:1];
    SZFHClient *client = [SZFHClient connectToSocket:[harness socketPathForStateDirectory:state] timeout:5];
    CHECK([[client helloWithEmbeddedBuild:0][@"type"] isEqual:@"welcome"]);
    NSDictionary *reply = [client intent:@"block" fields:@{@"conversation_id" : @"c_blocked"}];
    CHECK([reply[@"ok"] boolValue], "block: %@", reply);
    reply = [client intent:@"remove_friend" fields:@{@"conversation_id" : @"c_removed"}];
    CHECK([reply[@"ok"] boolValue], "remove: %@", reply);
    [client close];
    kill(pid, SIGTERM);
    CHECK([harness waitForExit:pid timeout:3 status:NULL]);

    store = [SZFriendsStore storeInDirectory:state error:NULL];
    CHECK(store != nil);
    transfers = [[SZFriendsTransfers alloc] initWithStore:store stateDirectory:state];
    SZFriendsTransferState blockedState = [transfers transferWithID:blocked].state;
    SZFriendsTransferState removedState = [transfers transferWithID:removed].state;
    SZFriendsTransferState keptState = [transfers transferWithID:kept].state;
    BOOL blockedRow = [transfers thumbnailForTransfer:blocked] != nil;
    BOOL removedRow = [transfers thumbnailForTransfer:removed] != nil;
    BOOL keptRow = [transfers thumbnailForTransfer:kept] != nil;
    [store close];
    CHECK(blockedState == SZFriendsTransferStateDeclined && !blockedRow && !SZFHPictureExists(blockedPicture),
          "blocking declines their waiting offer and deletes its picture (state %ld)", (long)blockedState);
    CHECK(removedState == SZFriendsTransferStateDeclined && !removedRow && !SZFHPictureExists(removedPicture),
          "removing them does the same (state %ld)", (long)removedState);
    CHECK(keptState == SZFriendsTransferStateWaitingForYou && keptRow && SZFHPictureExists(keptPicture),
          "another friend's offer keeps its picture (state %ld)", (long)keptState);
    return YES;
}
