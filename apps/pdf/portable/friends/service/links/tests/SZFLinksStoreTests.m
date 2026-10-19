// What a link holds (SZFriendsLinkSource.m) and what the store keeps of links (SZFriendsStoreLinks.h, schema v7).

#import "SZFLinksTestSupport.h"

#import "service/store/SZFriendsStoreInternal.h"

#include <sys/stat.h>
#include <unistd.h>

#import <sodium.h>

static NSString *WriteFile(NSString *directory, NSString *name, NSData *bytes) {
    NSString *path = [directory stringByAppendingPathComponent:name];
    [bytes writeToFile:path atomically:NO];
    return path;
}

static NSData *SHA256(NSData *data) {
    NSMutableData *digest = [NSMutableData dataWithLength:32];
    crypto_hash_sha256(digest.mutableBytes, data.bytes, data.length);
    return digest;
}

#pragma mark - The file a link holds

static void TestAClonedFileIsTheLinksForEver(void) {
    NSString *directory = SZFLTemporaryDirectory(@"clone");
    NSData *bytes = SZFLRandom(200000);
    NSString *path = WriteFile(directory, @"Site photos.pdf", bytes);
    NSString *clone = [directory stringByAppendingPathComponent:@"clone"];
    SZFriendsDownloadLinkRecord *link = SZFriendsLinkHoldFile(path, clone, NULL);
    SZFL_CHECK(link.snapshotPath != nil && link.sourcePath == nil, @"APFS clones the file (on this Mac's /tmp)");
    SZFL_CHECK(link.size == bytes.length && [link.sha256 isEqualToData:SHA256(bytes)], @"size and SHA-256");
    [SZFLRandom(10) writeToFile:path atomically:NO];
    SZFL_CHECK(SZFriendsLinkSourceUnchanged(link), @"editing the original never reaches the clone");
    struct stat info;
    SZFL_CHECK(stat(clone.fileSystemRepresentation, &info) == 0 && (info.st_mode & 0777) == 0600, @"0600");
    SZFriendsLinkReleaseFile(link, @"/elsewhere");
    SZFL_CHECK([[NSFileManager defaultManager] fileExistsAtPath:clone], @"only a clone in the links directory goes");
    SZFriendsLinkReleaseFile(link, directory);
    SZFL_CHECK(![[NSFileManager defaultManager] fileExistsAtPath:clone], @"released");
    SZFL_CHECK(SZFriendsLinkHoldFile(directory, [directory stringByAppendingPathComponent:@"x"], NULL) == nil,
               @"a folder is refused");
}

static void TestAnOriginalIsServedOnlyWhileUnchanged(void) {
    SZFriendsLinkClonesRefused = YES;
    NSString *directory = SZFLTemporaryDirectory(@"original");
    NSData *bytes = SZFLRandom(100000);
    NSString *path = WriteFile(directory, @"Contract.pdf", bytes);
    SZFriendsDownloadLinkRecord *link = SZFriendsLinkHoldFile(path, [directory stringByAppendingPathComponent:@"c"],
                                                              NULL);
    SZFriendsLinkClonesRefused = NO;
    SZFL_CHECK(link.sourcePath != nil && link.snapshotPath == nil, @"no clone: the original's facts");
    SZFL_CHECK(SZFriendsLinkSourceUnchanged(link), @"unchanged");
    // A metadata change (permissions) moves only the change time: the hash decides, and the bytes are the same.
    chmod(path.fileSystemRepresentation, 0640);
    SZFL_CHECK(SZFriendsLinkSourceUnchanged(link), @"same bytes after a metadata change");
    // Same size, same modification date, other bytes: the change time moved, and the hash catches it.
    struct stat before;
    stat(path.fileSystemRepresentation, &before);
    NSMutableData *other = [bytes mutableCopy];
    ((uint8_t *)other.mutableBytes)[5000] ^= 0xff;
    [other writeToFile:path atomically:NO];
    struct timespec times[2] = {before.st_atimespec, before.st_mtimespec};
    utimensat(AT_FDCWD, path.fileSystemRepresentation, times, 0);
    SZFL_CHECK(!SZFriendsLinkSourceUnchanged(link), @"other bytes behind the same size and date");
    [bytes writeToFile:path atomically:NO];
    [[NSFileHandle fileHandleForWritingAtPath:path] truncateFileAtOffset:10];
    SZFL_CHECK(!SZFriendsLinkSourceUnchanged(link), @"a shorter file");
}

#pragma mark - The store

// Schema v7 is additive: a v6 helper (an older Shenzhen Files) still opens the store and ignores the link tables.
static void TestV7MigrationIsAdditive(void) {
    NSString *directory = SZFLTemporaryDirectory(@"v6");
    SZFriendsStoreOptions *v6 = [[SZFriendsStoreOptions alloc] init];
    v6.migrations = [SZFriendsStoreShippedMigrations() subarrayWithRange:NSMakeRange(0, 6)];
    SZFriendsStore *older = [SZFriendsStore storeInDirectory:directory options:v6 error:NULL];
    SZFL_CHECK(older.schemaVersion == 6, @"a v6 store");
    [older close];
    SZFriendsStore *store = [SZFriendsStore storeInDirectory:directory error:NULL];
    SZFL_CHECK(store.schemaVersion == SZFriendsStoreSchemaVersion && SZFriendsStoreSchemaVersion >= 7 &&
                   [store standingInviteCreatingIfNeeded:YES error:NULL] != nil, @"v6 to v7 and on");
    [store close];
    SZFriendsStore *again = [SZFriendsStore storeInDirectory:directory options:v6 error:NULL];
    SZFL_CHECK(again != nil && again.schemaVersion == SZFriendsStoreSchemaVersion, @"a v6 helper opens a newer store");
    [again close];
}

static void TestOurRequestsKeepTheirInvite(void) {
    SZFriendsStore *store = [SZFriendsStore storeInDirectory:SZFLTemporaryDirectory(@"requests") error:NULL];
    SZFriendsPersonRecord *asked = [SZFriendsPersonRecord new];
    asked.conversationID = @"asked";
    asked.friendsID = @"brave-otter";
    asked.relation = SZFriendsRelationOutgoingRequest;
    asked.lastInteractionAt = [NSDate date];
    [store savePerson:asked error:NULL];
    SZFriendsIDRequestRecord *request = [SZFriendsIDRequestRecord new];
    request.conversationID = @"asked";
    request.targetFriendsID = @"brave-otter";
    request.requestToken = SZFLRandom(16);
    request.callbackSecret = SZFLRandom(32);
    request.createdAt = [NSDate date];
    request.expiresAt = [NSDate dateWithTimeIntervalSinceNow:3600];
    SZFL_CHECK([store saveIDRequest:request error:NULL], @"request");
    NSData *invite = SZFLRandom(16);
    SZFL_CHECK([store setInviteToken:invite forIDRequestConversation:@"asked" error:NULL] &&
                   [[store inviteTokenForIDRequestConversation:@"asked"] isEqualToData:invite],
               @"kept with the request");
    SZFL_CHECK(![store setInviteToken:invite forIDRequestConversation:@"nobody" error:NULL], @"only for a request");
    [store deleteIDRequestForConversation:@"asked" error:NULL];
    SZFL_CHECK([store inviteTokenForIDRequestConversation:@"asked"] == nil, @"and gone with it");
}

static SZFriendsDownloadLinkRecord *Link(NSDate *expires) {
    SZFriendsDownloadLinkRecord *link = [SZFriendsDownloadLinkRecord new];
    link.linkID = SZFLRandom(16);
    link.secret = SZFLRandom(32);
    link.fileName = @"Site photos.pdf";
    link.size = 5;
    link.sha256 = SZFLRandom(32);
    link.blake2b = SZFLRandom(32);
    link.sourcePath = @"/tmp/x";
    link.createdAt = [NSDate date];
    link.expiresAt = expires;
    return link;
}

static void TestDownloadLinksInTheStore(void) {
    SZFriendsStore *store = [SZFriendsStore storeInDirectory:SZFLTemporaryDirectory(@"store") error:NULL];
    SZFL_CHECK(store.schemaVersion == SZFriendsStoreSchemaVersion, @"schema %ld", (long)store.schemaVersion);
    SZFriendsDownloadLinkRecord *live = Link([NSDate dateWithTimeIntervalSinceNow:3600]);
    SZFriendsDownloadLinkRecord *old = Link([NSDate dateWithTimeIntervalSinceNow:-1]);
    SZFL_CHECK([store saveDownloadLink:live error:NULL] && [store saveDownloadLink:old error:NULL], @"saved");
    SZFriendsDownloadLinkRecord *both = Link(live.expiresAt);
    both.snapshotPath = @"/tmp/y";
    SZFL_CHECK(![store saveDownloadLink:both error:NULL], @"a clone and an original at once is refused");
    SZFL_CHECK([store countDownloadOfLink:live.linkID error:NULL] &&
                   [store downloadLinkWithID:live.linkID].downloads == 1,
               @"downloads count");
    NSArray *expired = [store removeDownloadLinksExpiredAtDate:[NSDate date] error:NULL];
    SZFL_CHECK(expired.count == 1 && [[expired[0] linkID] isEqualToData:old.linkID], @"expiry takes the old one");
    SZFL_CHECK([store removeDownloadLink:live.linkID error:NULL] != nil && [store downloadLinks].count == 0, @"revoke");
    NSError *error = nil;
    SZFL_CHECK([store removeDownloadLink:live.linkID error:&error] == nil && error.code == SZFriendsStoreErrorNotFound,
               @"twice");
    for (NSUInteger i = 0; i < SZFriendsDownloadLinksMax; i++) [store saveDownloadLink:Link(live.expiresAt) error:NULL];
    SZFL_CHECK(![store saveDownloadLink:Link(live.expiresAt) error:&error] &&
                   error.code == SZFriendsStoreErrorConstraint,
               @"no more than the host keeps: %@", error);
}

static void TestInvites(void) {
    SZFriendsStore *store = [SZFriendsStore storeInDirectory:SZFLTemporaryDirectory(@"invites") error:NULL];
    SZFL_CHECK([store standingInviteCreatingIfNeeded:NO error:NULL] == nil, @"none until asked");
    SZFriendsInviteRecord *standing = [store standingInviteCreatingIfNeeded:YES error:NULL];
    SZFL_CHECK([[store standingInviteCreatingIfNeeded:YES error:NULL].token isEqualToData:standing.token], @"stable");
    NSDate *now = [NSDate date];
    SZFL_CHECK([store useInvite:standing.token atDate:now error:NULL] &&
                   [store useInvite:standing.token atDate:now error:NULL],
               @"the standing link works again and again");
    SZFriendsInviteRecord *reset = [store resetStandingInviteAtDate:now error:NULL];
    SZFL_CHECK(![reset.token isEqualToData:standing.token] && ![store useInvite:standing.token atDate:now error:NULL],
               @"Reset stops the old link");
    SZFriendsInviteRecord *once = [store createOneTimeInviteAtDate:now error:NULL];
    SZFL_CHECK([store useInvite:once.token atDate:now error:NULL] &&
                   ![store useInvite:once.token atDate:now error:NULL],
               @"a one-time link works once");
    SZFriendsInviteRecord *late = [store createOneTimeInviteAtDate:now error:NULL];
    NSDate *after = [now dateByAddingTimeInterval:SZFriendsOneTimeInviteLifetime + 1];
    SZFL_CHECK(![store useInvite:late.token atDate:after error:NULL], @"and only within 30 days");
    SZFL_CHECK([store liveInvitesAtDate:now].count == 2, @"the reset link and the unused one-time link");
}

// A standing link accepts at most 20 requests in any 24 hours; the 21st waits for the person (Constraint).
static void TestStandingInviteDailyCap(void) {
    SZFriendsStore *store = [SZFriendsStore storeInDirectory:SZFLTemporaryDirectory(@"invite-cap") error:NULL];
    NSData *token = [store standingInviteCreatingIfNeeded:YES error:NULL].token;
    // A start whose fraction of a millisecond rounds up when kept: the window must count what it keeps, every run.
    NSDate *start = [NSDate dateWithTimeIntervalSince1970:floor([NSDate date].timeIntervalSince1970) + 0.0006];
    BOOL all = YES;
    for (NSUInteger i = 0; i < SZFriendsInviteAcceptsPerDay; i++) {
        all = all && [store useInvite:token atDate:[start dateByAddingTimeInterval:i * 60] error:NULL];
    }
    SZFL_CHECK(all && SZFriendsInviteAcceptsPerDay == 20, @"twenty in a day are accepted at once");
    NSError *error = nil;
    NSDate *sameDay = [start dateByAddingTimeInterval:3600];
    SZFL_CHECK(![store useInvite:token atDate:sameDay error:&error] && error.code == SZFriendsStoreErrorConstraint,
               @"the 21st waits: %@", error);
    SZFL_CHECK([store liveInvitesAtDate:sameDay].count == 1, @"the link itself still works");
    // A day after the first, it has room for one again, and only one.
    NSDate *nextDay = [start dateByAddingTimeInterval:86400 + 1];
    SZFL_CHECK([store useInvite:token atDate:nextDay error:NULL] && ![store useInvite:token atDate:nextDay error:NULL],
               @"the window rolls");
    // Reset makes a new link with its own count; one-time links are used once anyway.
    NSData *fresh = [store resetStandingInviteAtDate:nextDay error:NULL].token;
    SZFL_CHECK([store useInvite:fresh atDate:nextDay error:NULL], @"Reset starts afresh");
    NSData *once = [store createOneTimeInviteAtDate:nextDay error:NULL].token;
    SZFL_CHECK([store useInvite:once atDate:nextDay error:NULL], @"one-time links are not capped");
}

static SZFriendsPersonRecord *Person(SZFriendsStore *store, SZFriendsRelation relation) {
    SZFriendsPersonRecord *person = [SZFriendsPersonRecord new];
    person.conversationID = SZFriendsNewIdentifier();
    person.identityKey = SZFLRandom(32);
    person.relation = relation;
    person.lastInteractionAt = [NSDate date];
    SZFL_CHECK([store savePerson:person error:NULL], @"person");
    return person;
}

static void TestLinkTransfersAndContacts(void) {
    NSString *directory = SZFLTemporaryDirectory(@"transfers");
    SZFriendsStore *store = [SZFriendsStore storeInDirectory:directory error:NULL];
    SZFriendsTransfers *transfers = [[SZFriendsTransfers alloc] initWithStore:store stateDirectory:directory];
    SZFriendsPersonRecord *stranger = Person(store, SZFriendsRelationRemoved);
    SZFriendsPersonRecord *blocked = Person(store, SZFriendsRelationBlocked);
    SZFL_CHECK([store markLinkContact:stranger.conversationID error:NULL] &&
                   [[store linkContactConversationIDs] containsObject:stranger.conversationID],
               @"a link contact");
    NSData *file = SZFLRandom(3000);
    NSMutableData *digest = [NSMutableData dataWithLength:32];
    crypto_generichash(digest.mutableBytes, 32, file.bytes, file.length, NULL, 0);
    SZFriendsTransferRecord *transfer = [transfers recordLinkTransferWithID:SZFriendsNewIdentifier()
                                                             conversationID:stranger.conversationID
                                                                   fileName:@"../Site photos.pdf"
                                                                uniformType:nil size:file.length
                                                              contentDigest:digest error:NULL];
    SZFL_CHECK(transfer.state == SZFriendsTransferStateReceiving && ![transfer.fileName containsString:@"/"],
               @"accepted from the start, name sanitized: %@", transfer.fileName);
    SZFL_CHECK([transfers appendChunk:file atOffset:0 toTransfer:transfer.transferID
                     fromConversation:stranger.conversationID error:NULL] &&
                   [transfers finishTransfer:transfer.transferID finalDigest:digest
                            fromConversation:stranger.conversationID error:NULL],
               @"the transfer code publishes it");
    SZFriendsTransferRecord *done = [transfers transferWithID:transfer.transferID];
    SZFL_CHECK(done.state == SZFriendsTransferStateReceived &&
                   [[NSData dataWithContentsOfFile:done.receivedPath] isEqualToData:file],
               @"in received/: %@", done.receivedPath);
    SZFL_CHECK([transfers recordLinkTransferWithID:SZFriendsNewIdentifier() conversationID:blocked.conversationID
                                          fileName:@"x" uniformType:nil size:1 contentDigest:digest error:NULL] == nil,
               @"nothing from someone blocked");
    stranger.relation = SZFriendsRelationFriend;
    [store savePerson:stranger error:NULL];
    SZFL_CHECK(![[store linkContactConversationIDs] containsObject:stranger.conversationID], @"friends now");
}

void SZFLRunSourceTests(void) {
    TestAClonedFileIsTheLinksForEver();
    TestAnOriginalIsServedOnlyWhileUnchanged();
}

void SZFLRunStoreTests(void) {
    TestV7MigrationIsAdditive();
    TestOurRequestsKeepTheirInvite();
    TestDownloadLinksInTheStore();
    TestInvites();
    TestStandingInviteDailyCap();
    TestLinkTransfersAndContacts();
}
