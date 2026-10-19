// What a download link leaves once it ends (SZFriendsStoreLinks.h): a tombstone of its id's hash, never the id or
// the secret, "revoked" for 31 days from Revoke or "expired" for 31 days from its expiry, at most 500 with those
// ending soonest dropped first; the helper sends them to its host so an opener is told why the link ended.

#import "SZFLinksTestSupport.h"

#import <CommonCrypto/CommonDigest.h>

static SZFriendsDownloadLinkRecord *StoredLink(SZFriendsStore *store, NSDate *expires) {
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
    SZFL_CHECK([store saveDownloadLink:link error:NULL], @"saved");
    return link;
}

static NSData *ExpectedHash(NSData *linkID) {
    NSMutableData *input = [[@"SZFriends link tombstone v1" dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [input appendData:linkID];
    NSMutableData *digest = [NSMutableData dataWithLength:32];
    CC_SHA256(input.bytes, (CC_LONG)input.length, digest.mutableBytes);
    return digest;
}

static void TestEndedLinksLeaveTombstonesOfTheirHashOnly(void) {
    NSString *directory = SZFLTemporaryDirectory(@"tombstones");
    SZFriendsStore *store = [SZFriendsStore storeInDirectory:directory error:NULL];
    NSDate *now = [NSDate date];
    SZFriendsDownloadLinkRecord *revoked = StoredLink(store, [now dateByAddingTimeInterval:3600]);
    SZFriendsDownloadLinkRecord *expired = StoredLink(store, [now dateByAddingTimeInterval:-60]);
    SZFriendsDownloadLinkRecord *live = StoredLink(store, [now dateByAddingTimeInterval:7200]);
    SZFL_CHECK([store linkTombstonesAtDate:now].count == 0, @"none while every link lives");
    SZFL_CHECK([store removeDownloadLink:revoked.linkID error:NULL] != nil, @"revoked");
    SZFL_CHECK([store removeDownloadLinksExpiredAtDate:now error:NULL].count == 1, @"expired");
    NSArray<SZFriendsLinkTombstone *> *tombstones = [store linkTombstonesAtDate:now];
    SZFL_CHECK(tombstones.count == 2, @"%lu tombstones", (unsigned long)tombstones.count);
    NSMutableDictionary<NSData *, SZFriendsLinkTombstone *> *byHash = [NSMutableDictionary dictionary];
    for (SZFriendsLinkTombstone *tombstone in tombstones) byHash[tombstone.linkHash] = tombstone;
    SZFriendsLinkTombstone *r = byHash[ExpectedHash(revoked.linkID)], *e = byHash[ExpectedHash(expired.linkID)];
    SZFL_CHECK([SZFriendsLinkTombstoneHash(revoked.linkID) isEqualToData:ExpectedHash(revoked.linkID)], @"the hash");
    SZFL_CHECK([r.reason isEqual:@"revoked"] && fabs(r.until.timeIntervalSinceNow - 31 * 86400) < 120,
               @"revoked, for 31 days from now: %@ %@", r.reason, r.until);
    SZFL_CHECK([e.reason isEqual:@"expired"] &&
                   fabs([e.until timeIntervalSinceDate:expired.expiresAt] - 31 * 86400) < 2,
               @"expired, for 31 days from its expiry: %@ %@", e.reason, e.until);
    SZFL_CHECK(byHash[ExpectedHash(live.linkID)] == nil, @"a live link has none");
    SZFL_CHECK([store linkTombstonesAtDate:[now dateByAddingTimeInterval:32 * 86400]].count == 0,
               @"gone after 31 days");

    // Nothing in the store file names an ended link: neither its id nor its secret.
    [store close];
    NSMutableData *everything = [NSMutableData data];
    for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:NULL]) {
        NSData *data = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:name]];
        if (data) [everything appendData:data];
    }
    for (NSData *secret in @[ revoked.linkID, revoked.secret, expired.linkID, expired.secret ]) {
        SZFL_CHECK([everything rangeOfData:secret options:0 range:NSMakeRange(0, everything.length)].location ==
                       NSNotFound,
                   @"no id or secret of an ended link left in the store");
    }
}

static void TestAtMostFiveHundredTombstones(void) {
    SZFriendsStore *store = [SZFriendsStore storeInDirectory:SZFLTemporaryDirectory(@"tombstone-cap") error:NULL];
    NSDate *now = [NSDate date];
    NSMutableArray<NSData *> *ids = [NSMutableArray array];
    for (NSUInteger i = 0; i < SZFriendsLinkTombstonesMax + 5; i++) {
        // Expired links, each a minute later than the last: the first ones end soonest.
        SZFriendsDownloadLinkRecord *link = StoredLink(store, [now dateByAddingTimeInterval:-100000 + 60.0 * i]);
        [ids addObject:link.linkID];
        [store removeDownloadLinksExpiredAtDate:now error:NULL];
    }
    NSArray<SZFriendsLinkTombstone *> *tombstones = [store linkTombstonesAtDate:now];
    NSSet<NSData *> *hashes = [NSSet setWithArray:[tombstones valueForKey:@"linkHash"]];
    SZFL_CHECK(tombstones.count == SZFriendsLinkTombstonesMax, @"%lu kept", (unsigned long)tombstones.count);
    SZFL_CHECK(![hashes containsObject:ExpectedHash(ids[4])] && [hashes containsObject:ExpectedHash(ids[5])] &&
                   [hashes containsObject:ExpectedHash(ids.lastObject)],
               @"those ending soonest went");
}

void SZFLRunTombstoneTests(void) {
    TestEndedLinksLeaveTombstonesOfTheirHashOnly();
    TestAtMostFiveHundredTombstones();
}
