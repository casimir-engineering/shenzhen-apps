// File previews in the store (schema v6): the migration, what each side may record, the one picture per offer, the
// local picture that replaces the sender's, and every way a picture is deleted (decline, cancel, an offer that
// failed, Delete history, Reset Friends, leftovers at start).

#import "SZFriendsStoreTestSupport.h"

#import "service/store/SZFriendsTransferThumbnails.h"

static SZFriendsTransfers *ThumbnailTransfers(SZFriendsStore *store) {
    SZFriendsTransfers *transfers = [[SZFriendsTransfers alloc] initWithStore:store
                                                               stateDirectory:store.stateDirectory];
    transfers.freeBytesProvider = ^uint64_t(NSString *path) {
        (void)path;
        return 1ULL << 40;
    };
    return transfers;
}

// A PNG file as the thumbnails area writes them: a random 32-hex-digit name in the directory. The bytes do not matter
// to the store.
static NSString *WritePicture(SZFriendsTransfers *transfers) {
    [NSFileManager.defaultManager createDirectoryAtPath:transfers.thumbnailDirectory withIntermediateDirectories:YES
                                             attributes:nil error:NULL];
    NSData *random = SZFTRandomData(16);
    NSMutableString *name = [NSMutableString string];
    for (NSUInteger i = 0; i < random.length; i++) [name appendFormat:@"%02x", ((const uint8_t *)random.bytes)[i]];
    [name appendString:@".png"];
    NSString *path = [transfers.thumbnailDirectory stringByAppendingPathComponent:name];
    [SZFTRandomData(100) writeToFile:path atomically:NO];
    return path;
}

static BOOL Exists(NSString *path) {
    return [NSFileManager.defaultManager fileExistsAtPath:path];
}

static NSString *Offer(SZFriendsTransfers *transfers, NSString *transferID, NSString *conversationID) {
    NSData *contents = [transferID dataUsingEncoding:NSUTF8StringEncoding];
    [transfers recordIncomingOfferWithID:transferID conversationID:conversationID fileName:@"Site photos.pdf"
                             uniformType:@"com.adobe.pdf" size:contents.length contentDigest:SZFTBlake2b(contents)
                                  sentAt:[NSDate date] error:NULL];
    return transferID;
}

static NSString *Staged(SZFriendsTransfers *transfers, NSString *conversationID) {
    NSString *source = [SZFTTemporaryDirectory(@"source") stringByAppendingPathComponent:@"Contract.pdf"];
    [SZFTRandomData(5000) writeToFile:source atomically:NO];
    return [transfers stageOutgoingFileAtPath:source revision:nil conversationID:conversationID error:NULL].transferID;
}

static void TestV6Migration(void) {
    NSString *directory = SZFTTemporaryDirectory(@"v5");
    SZFriendsStoreOptions *v5 = [[SZFriendsStoreOptions alloc] init];
    v5.migrations = [SZFriendsStoreShippedMigrations() subarrayWithRange:NSMakeRange(0, 5)];
    NSError *error = nil;
    SZFriendsStore *older = SZFTOpenStoreWithOptions(directory, v5, &error);
    SZFTExpect(older.schemaVersion == 5, @"a v5 store: %@", error);
    [older close];
    SZFriendsStore *store = SZFTOpenStoreWithOptions(directory, nil, &error);
    SZFTExpect(store.schemaVersion == SZFriendsStoreSchemaVersion && SZFriendsStoreSchemaVersion >= 6, @"v5 to v6: %@",
               error);
    SZFTExpect([SZFTScalar(store, @"SELECT count(*) FROM transfer_thumbnails", @[]) integerValue] == 0, @"empty table");
    SZFTExpect([SZFTScalar(store, @"SELECT value FROM meta WHERE key = 'min_reader_version'", @[]) isEqual:@"2"],
               @"additive: a v5 helper still opens it");
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    SZFriendsTransfers *transfers = ThumbnailTransfers(store);
    NSString *picture = WritePicture(transfers);
    [transfers recordReceivedThumbnailForTransfer:Offer(transfers, @"t1", @"mei") fromConversation:@"mei"
                                             path:picture width:136 height:192 error:NULL];
    [store close];
    // An older helper keeps working on the new store, and its deletes take the rows with them (the cascade).
    SZFriendsStore *again = SZFTOpenStoreWithOptions(directory, v5, &error);
    SZFTExpect(again != nil, @"a v5 helper opens a v6 store: %@", error);
    SZFTScalar(again, @"DELETE FROM transfers WHERE transfer_id = 't1'", @[]);
    SZFTExpect([SZFTScalar(again, @"SELECT count(*) FROM transfer_thumbnails", @[]) integerValue] == 0,
               @"the row went with its transfer");
    [again close];
    // The file it left is removed by the next helper that knows the table.
    SZFriendsStore *current = SZFTOpenStore(directory);
    SZFTExpect(Exists(picture), @"left behind by the older helper");
    [ThumbnailTransfers(current) removeUnreferencedThumbnailFiles];
    SZFTExpect(!Exists(picture), @"removed at start");
}

static void TestSenderSide(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"sender"));
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    SZFriendsTransfers *transfers = ThumbnailTransfers(store);
    NSString *ours = Staged(transfers, @"mei");
    NSData *qoi = SZFTRandomData(500);
    NSString *picture = WritePicture(transfers);
    NSError *error = nil;
    SZFTExpect([transfers setOutgoingThumbnailForTransfer:ours path:picture width:192 height:136 qoi:qoi error:&error],
               @"our pending offer's picture: %@", error);
    SZFriendsThumbnailRecord *record = [transfers thumbnailForTransfer:ours];
    SZFTExpect(record.source == SZFriendsThumbnailSourceLocal && [record.path isEqualToString:picture] &&
                   record.width == 192 && record.height == 136 && [record.qoi isEqualToData:qoi] && !record.delivered,
               @"recorded as made here");
    SZFTExpect(![transfers setOutgoingThumbnailForTransfer:ours path:WritePicture(transfers) width:1 height:1 qoi:qoi
                                                     error:&error] && error.code == SZFriendsStoreErrorStale,
               @"one picture per offer");
    SZFTExpect([[[transfers thumbnailsToSendInConversation:@"mei"] valueForKey:@"transferID"] isEqual:@[ ours ]],
               @"waiting to go after the offer");
    SZFTExpect([transfers thumbnailsToSendInConversation:@"kenji"].count == 0, @"only to Mei");
    SZFTExpect(![transfers markThumbnailDelivered:ours fromConversation:@"kenji" error:&error], @"Kenji's ACK no");
    SZFTExpect([transfers markThumbnailDelivered:ours fromConversation:@"mei" error:&error], @"Mei's ACK: %@", error);
    record = [transfers thumbnailForTransfer:ours];
    SZFTExpect(record.delivered && record.qoi == nil && Exists(picture), @"sent: the QOI goes, the PNG stays");
    SZFTExpect([transfers thumbnailsToSendInConversation:@"mei"].count == 0, @"nothing more to send");
    NSString *outside = [SZFTTemporaryDirectory(@"elsewhere") stringByAppendingPathComponent:picture.lastPathComponent];
    SZFTExpect(![transfers setOutgoingThumbnailForTransfer:Staged(transfers, @"mei") path:outside width:9 height:9
                                                       qoi:qoi error:&error] &&
                   error.code == SZFriendsStoreErrorInvalid,
               @"a path outside the thumbnails directory is refused");
    NSString *withdrawn = Staged(transfers, @"mei");
    [transfers cancelTransfer:withdrawn error:NULL];
    SZFTExpect(![transfers setOutgoingThumbnailForTransfer:withdrawn path:WritePicture(transfers) width:9 height:9
                                                       qoi:qoi error:&error] && error.code == SZFriendsStoreErrorStale,
               @"too late for a withdrawn offer");
    // Cancelling our offer deletes its picture, as a decline on their side does.
    NSString *cancelled = Staged(transfers, @"mei");
    NSString *cancelledPicture = WritePicture(transfers);
    [transfers setOutgoingThumbnailForTransfer:cancelled path:cancelledPicture width:9 height:9 qoi:qoi error:NULL];
    SZFTExpect([transfers cancelTransfer:cancelled error:NULL] && [transfers thumbnailForTransfer:cancelled] == nil &&
                   !Exists(cancelledPicture),
               @"cancel deletes the picture");
    // An offer that failed before anyone answered (30 days undelivered, or refused) loses its picture too.
    NSString *expired = Staged(transfers, @"mei");
    NSString *expiredPicture = WritePicture(transfers);
    [transfers setOutgoingThumbnailForTransfer:expired path:expiredPicture width:9 height:9 qoi:qoi error:NULL];
    [transfers failTransfer:expired reason:@"not_delivered_30_days" error:NULL];
    SZFTExpect([transfers thumbnailForTransfer:expired] == nil && !Exists(expiredPicture), @"expired: gone");
}

static void TestRecipientSide(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"recipient"));
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    SZFTAddPerson(store, @"kenji", 2, SZFriendsRelationFriend, 1000);
    SZFriendsTransfers *transfers = ThumbnailTransfers(store);
    NSString *offer = Offer(transfers, @"in1", @"mei");
    SZFTExpect([transfers mayRecordReceivedThumbnailForTransfer:offer fromConversation:@"mei"], @"Mei's offer");
    SZFTExpect(![transfers mayRecordReceivedThumbnailForTransfer:offer fromConversation:@"kenji"], @"not Kenji's");
    SZFTExpect(![transfers mayRecordReceivedThumbnailForTransfer:@"nothing" fromConversation:@"mei"], @"unsolicited");
    NSString *first = WritePicture(transfers);
    NSError *error = nil;
    SZFTExpect([transfers recordReceivedThumbnailForTransfer:offer fromConversation:@"mei" path:first width:136
                                                      height:192 error:&error],
               @"the first picture: %@", error);
    SZFTExpect([transfers thumbnailForTransfer:offer].source == SZFriendsThumbnailSourceSender, @"from the sender");
    SZFTExpect(![transfers mayRecordReceivedThumbnailForTransfer:offer fromConversation:@"mei"] &&
                   ![transfers recordReceivedThumbnailForTransfer:offer fromConversation:@"mei"
                                                             path:WritePicture(transfers) width:5 height:5
                                                            error:&error] &&
                   error.code == SZFriendsStoreErrorStale,
               @"a second picture for the same offer is refused");
    SZFTExpect([[transfers thumbnailForTransfer:offer].path isEqualToString:first], @"the first one stands");
    SZFTExpect(![transfers recordReceivedThumbnailForTransfer:Staged(transfers, @"mei") fromConversation:@"mei"
                                                         path:WritePicture(transfers) width:5 height:5 error:&error],
               @"never on one of our own offers");
    NSString *wide = Offer(transfers, @"in9", @"mei");
    NSString *widePicture = WritePicture(transfers);
    SZFTExpect(![transfers recordReceivedThumbnailForTransfer:wide fromConversation:@"mei" path:widePicture width:193
                                                       height:5 error:&error] &&
                   error.code == SZFriendsStoreErrorInvalid,
               @"sizes over 192 are refused");
    // Accepted: still waiting for the file, so a picture that arrives now is kept.
    NSString *accepted = Offer(transfers, @"in2", @"mei");
    [transfers acceptTransfer:accepted automatically:NO error:NULL];
    SZFTExpect([transfers mayRecordReceivedThumbnailForTransfer:accepted fromConversation:@"mei"], @"receiving");
    // Declined: the picture goes, file and row.
    SZFTExpect([transfers declineTransfer:offer error:NULL] && [transfers thumbnailForTransfer:offer] == nil &&
                   !Exists(first),
               @"decline deletes the picture");
    SZFTExpect(![transfers mayRecordReceivedThumbnailForTransfer:offer fromConversation:@"mei"], @"and no new one");
    // Withdrawn by Mei: the same.
    NSString *withdrawn = Offer(transfers, @"in3", @"mei");
    NSString *picture = WritePicture(transfers);
    [transfers recordReceivedThumbnailForTransfer:withdrawn fromConversation:@"mei" path:picture width:5 height:5
                                            error:NULL];
    SZFTExpect([transfers peerCancelledTransfer:withdrawn fromConversation:@"mei" error:NULL] &&
                   [transfers thumbnailForTransfer:withdrawn] == nil && !Exists(picture),
               @"their cancel deletes it");
}

static void TestLocalReplacement(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"replace"));
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    SZFriendsTransfers *transfers = ThumbnailTransfers(store);
    NSData *contents = SZFTRandomData(3000);
    [transfers recordIncomingOfferWithID:@"r1" conversationID:@"mei" fileName:@"Site photos.pdf" uniformType:nil
                                    size:contents.length contentDigest:SZFTBlake2b(contents) sentAt:[NSDate date]
                                   error:NULL];
    NSString *sent = WritePicture(transfers);
    [transfers recordReceivedThumbnailForTransfer:@"r1" fromConversation:@"mei" path:sent width:20 height:30
                                            error:NULL];
    NSError *error = nil;
    SZFTExpect(![transfers replaceThumbnailOfReceivedTransfer:@"r1" localPath:WritePicture(transfers) width:9
                                                       height:9 error:&error] &&
                   error.code == SZFriendsStoreErrorStale,
               @"not before the file arrived and checked");
    [transfers acceptTransfer:@"r1" automatically:NO error:NULL];
    BOOL arrived = [transfers appendChunk:contents atOffset:0 toTransfer:@"r1" fromConversation:@"mei" error:&error] &&
                   [transfers finishTransfer:@"r1" finalDigest:SZFTBlake2b(contents) fromConversation:@"mei"
                                       error:&error];
    SZFTExpect(arrived, @"received and verified: %@", error);
    SZFTExpect([transfers thumbnailForTransfer:@"r1"].source == SZFriendsThumbnailSourceSender,
               @"the sender's picture until ours is made");
    NSString *local = WritePicture(transfers);
    SZFTExpect([transfers replaceThumbnailOfReceivedTransfer:@"r1" localPath:local width:136 height:192 error:&error],
               @"replaced: %@", error);
    SZFriendsThumbnailRecord *record = [transfers thumbnailForTransfer:@"r1"];
    SZFTExpect(record.source == SZFriendsThumbnailSourceLocal && [record.path isEqualToString:local] &&
                   record.width == 136 && !Exists(sent),
               @"ours replaces theirs, and theirs is deleted");
    SZFTExpect([transfers replaceThumbnailOfReceivedTransfer:@"r1" localPath:nil width:0 height:0 error:&error] &&
                   [transfers thumbnailForTransfer:@"r1"] == nil && !Exists(local),
               @"no picture of the real file: none at all");
}

static void TestDeletes(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"deletes"));
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    SZFTAddPerson(store, @"kenji", 2, SZFriendsRelationFriend, 1000);
    SZFriendsTransfers *transfers = ThumbnailTransfers(store);
    NSString *meiPicture = WritePicture(transfers), *kenjiPicture = WritePicture(transfers);
    [transfers recordReceivedThumbnailForTransfer:Offer(transfers, @"m1", @"mei") fromConversation:@"mei"
                                             path:meiPicture width:9 height:9 error:NULL];
    [transfers recordReceivedThumbnailForTransfer:Offer(transfers, @"k1", @"kenji") fromConversation:@"kenji"
                                             path:kenjiPicture width:9 height:9 error:NULL];
    NSString *stray = WritePicture(transfers);
    [transfers removeUnreferencedThumbnailFiles];
    SZFTExpect(!Exists(stray) && Exists(meiPicture) && Exists(kenjiPicture), @"only leftovers are removed");
    SZFTExpect([store deleteHistoryInConversation:@"mei" error:NULL], @"delete Mei's history");
    SZFTExpect(!Exists(meiPicture) && Exists(kenjiPicture), @"her pictures went with it, Kenji's stayed");
    SZFTExpect([store deleteEverythingExceptReceivedFilesWithError:NULL], @"Reset Friends");
    SZFTExpect(!Exists(transfers.thumbnailDirectory), @"no picture survives a reset");
}

void SZFTRunThumbnailTests(void) {
    TestV6Migration();
    TestSenderSide();
    TestRecipientSide();
    TestLocalReplacement();
    TestDeletes();
}
